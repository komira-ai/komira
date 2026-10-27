# =============================================================================
# test_ipc_decoder_refusals.mojo: the flat decoders' refusals, the
# zero-copy flat decoder's NULL and nullable var-len arms, and the decoder's
# type tables
# =============================================================================
#
# Every frame here is written with the ipc_flatbuf writers, so each test
# changes exactly one thing against a frame that decodes:
#   * a Message whose header is a DictionaryBatch is refused by each of the
#     six RecordBatch decoders, with the tag expected (3) and the tag got
#     (2): by the flat zero-copy decoder's own check, and by the codec peek
#     every other decoder runs first;
#   * a BodyCompression codec no version defines (2) is refused by the
#     copy-on-read decoders, with and without a dispatcher; a compressed
#     frame (LZ4, 0) is refused by the nested zero-copy decoder;
#   * a DICTIONARY column is refused by the flat copy-on-read decoder (its
#     values live in a DictionaryBatch it never sees) and by the flat
#     zero-copy decoder;
#   * the flat zero-copy decoder refuses node and buffer counts that
#     disagree with the schema, and decodes a NULL column (no buffers) and
#     a STRING column with a null;
#   * _fixed_width_bytes_for, _buffer_count_for and _decode_column, called
#     directly with types the public decoders refuse earlier.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env
from komira_async_api.parallel_dispatch import NoDispatch
from komira_async_api.token import CancellationToken
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message,
    decode_record_batch_message_mmap,
    decode_record_batch_message_nested,
    decode_record_batch_message_nested_zerocopy,
    decode_record_batch_message_with_dicts,
    decode_record_batch_message_with_dispatcher,
    decode_record_batch_zerocopy,
    _buffer_count_for,
    _decode_column,
    _fixed_width_bytes_for,
)
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    write_body_compression,
    write_ipc_message,
    write_message,
    write_record_batch,
    write_record_batch_compressed,
)


comptime BODY = 64


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------


def _frame(
    header: UInt8,
    rows: Int,
    var nodes: List[FieldNode],
    var bufs: List[BufferDescriptor],
    codec: Int = -1,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A Message of `header` over a RecordBatch of `rows` rows, `nodes` and
    `bufs` (with a BodyCompression of `codec` unless it is -1), and a
    64-byte body: Int64 5, 6, 7 at 0; STRING offsets 0, 1, 1, 3 at 24
    (16 bytes) and data "abc" at 40; a validity bitmap 0b101 at 56."""
    var w = FlatbufWriter(2048)
    var rb_pos: Int
    if codec < 0:
        rb_pos = write_record_batch(w, Int64(rows), nodes, bufs)
    else:
        var bc = write_body_compression(w, Int8(codec))
        rb_pos = write_record_batch_compressed(w, Int64(rows), nodes, bufs, bc)
    var msg_pos = write_message(w, Int16(4), header, rb_pos, Int64(BODY))
    var fb = w^.finalize(msg_pos)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(BODY)
    body.zero()
    body.write_i64_le_at(0, Int64(5))
    body.write_i64_le_at(8, Int64(6))
    body.write_i64_le_at(16, Int64(7))
    body.write_i32_le_at(24, Int32(0))
    body.write_i32_le_at(28, Int32(1))
    body.write_i32_le_at(32, Int32(1))
    body.write_i32_le_at(36, Int32(3))
    body.write_u8_at(40, UInt8(ord("a")))
    body.write_u8_at(41, UInt8(ord("b")))
    body.write_u8_at(42, UInt8(ord("c")))
    body.write_u8_at(56, UInt8(0b101))
    body.set_length(BODY)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(
        w2, fb^, body.view_range_ro(0, BODY).into_span(), True
    )


def _node(length: Int, nulls: Int) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(nulls))


def _buf(off: Int, length: Int) -> BufferDescriptor:
    return BufferDescriptor(offset=Int64(off), length=Int64(length))


def _int64_frame(header: UInt8, codec: Int = -1) raises -> SharedAlignedBuffer[HeapRegion]:
    """One INT64 column of 3 rows (5, 6, 7), no nulls."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    return _frame(header, 3, nodes^, bufs^, codec)


def _types(t: ArrowType) -> List[ArrowType]:
    var out = List[ArrowType]()
    out.append(t)
    return out^


def _specs(t: ArrowType) raises -> Slab[ColumnTypeSpec]:
    var s = Slab[ColumnTypeSpec]()
    s.append(ColumnTypeSpec.leaf(t))
    return s^


def _scratch(name: String) -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_ipc_decoder_refusals_" + name


def _map(
    frame: SharedAlignedBuffer[HeapRegion], name: String
) raises -> ArcPointer[MmapRegion]:
    var bytes = List[UInt8](capacity=frame.len())
    for i in range(frame.len()):
        bytes.append(frame.read_u8_at(i))
    var path = _scratch(name)
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^
    return ArcPointer[MmapRegion](MmapRegion.open_readonly(path))


# ---------------------------------------------------------------------------
# Header refusals
# ---------------------------------------------------------------------------


comptime GOT_2 = ": expected RECORD_BATCH header (tag 3), got 2"
# Every decoder but the flat zero-copy one first peeks the frame's codec,
# and the peek refuses a frame that is not a RecordBatch before the
# decoder's own header check runs.
comptime PEEK = "peek_record_batch_codec_from_frame"


def _one_slot() -> Slab[Column[HeapRegion]]:
    """with_dicts takes one dictionary slot per column (unused here)."""
    var s = Slab[Column[HeapRegion]]()
    s.append(Column[HeapRegion]())
    return s^


def test_peeking_decoders_refuse_a_dictionary_batch_header() raises:
    var msg = String("")
    try:
        _ = decode_record_batch_message(
            _int64_frame(MESSAGE_HEADER_DICTIONARY_BATCH), _types(ArrowType.INT64)
        )
    except e:
        msg = String(e)
    assert_equal(msg, String(PEEK) + GOT_2)
    msg = String("")
    var flags = List[Bool]()
    flags.append(False)
    try:
        _ = decode_record_batch_message_with_dicts(
            _int64_frame(MESSAGE_HEADER_DICTIONARY_BATCH),
            _types(ArrowType.INT64),
            flags,
            _one_slot(),
        )
    except e:
        msg = String(e)
    assert_equal(msg, String(PEEK) + GOT_2)
    msg = String("")
    try:
        _ = decode_record_batch_message_nested(
            _int64_frame(MESSAGE_HEADER_DICTIONARY_BATCH),
            _specs(ArrowType.INT64),
        )
    except e:
        msg = String(e)
    assert_equal(msg, String(PEEK) + GOT_2)


def test_zero_copy_decoders_refuse_a_dictionary_batch_header() raises:
    var frame = _int64_frame(MESSAGE_HEADER_DICTIONARY_BATCH)
    var msg = String("")
    try:
        _ = decode_record_batch_zerocopy(frame, _types(ArrowType.INT64))
    except e:
        msg = String(e)
    assert_equal(msg, String("decode_record_batch_zerocopy") + GOT_2)
    msg = String("")
    try:
        _ = decode_record_batch_message_nested_zerocopy(
            frame, _specs(ArrowType.INT64)
        )
    except e:
        msg = String(e)
    assert_equal(msg, String(PEEK) + GOT_2)
    msg = String("")
    var region = _map(frame, "dict_header")
    try:
        _ = decode_record_batch_message_mmap(
            frame^, _types(ArrowType.INT64), region, 0
        )
    except e:
        msg = String(e)
    assert_equal(msg, String(PEEK) + GOT_2)


def test_the_record_batch_header_control_decodes_everywhere() raises:
    """The same frame with a RecordBatch header decodes through each
    decoder the refusals above name."""
    var flat = decode_record_batch_message(
        _int64_frame(MESSAGE_HEADER_RECORD_BATCH), _types(ArrowType.INT64)
    )
    assert_equal(flat[0]._data.read_i64_le_at(16), Int64(7))
    var flags = List[Bool]()
    flags.append(False)
    var dicts = decode_record_batch_message_with_dicts(
        _int64_frame(MESSAGE_HEADER_RECORD_BATCH),
        _types(ArrowType.INT64),
        flags,
        _one_slot(),
    )
    assert_equal(dicts[0]._data.read_i64_le_at(8), Int64(6))
    var nested = decode_record_batch_message_nested(
        _int64_frame(MESSAGE_HEADER_RECORD_BATCH), _specs(ArrowType.INT64)
    )
    assert_equal(nested[0]._data.read_i64_le_at(0), Int64(5))
    var frame = _int64_frame(MESSAGE_HEADER_RECORD_BATCH)
    var zc = decode_record_batch_zerocopy(frame, _types(ArrowType.INT64))
    assert_equal(zc[0]._data.read_i64_le_at(16), Int64(7))
    var nzc = decode_record_batch_message_nested_zerocopy(
        frame, _specs(ArrowType.INT64)
    )
    assert_equal(nzc[0]._data.read_i64_le_at(16), Int64(7))
    var region = _map(frame, "rb_header")
    var mm = decode_record_batch_message_mmap(
        frame^, _types(ArrowType.INT64), region, 0
    )
    assert_equal(mm[0]._data.read_i64_le_at(8), Int64(6))


# ---------------------------------------------------------------------------
# Compression refusals
# ---------------------------------------------------------------------------


def test_copy_on_read_decoder_refuses_an_unknown_codec() raises:
    var msg = String("")
    try:
        _ = decode_record_batch_message(
            _int64_frame(MESSAGE_HEADER_RECORD_BATCH, 2), _types(ArrowType.INT64)
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "_decompress_frame_if_needed: unknown BodyCompression.codec 2 (valid:"
        " -1 Uncompressed, 0 LZ4_FRAME, 1 ZSTD)",
    )


def test_dispatcher_decoder_refuses_an_unknown_codec() raises:
    var nd = NoDispatch()
    var msg = String("")
    try:
        _ = decode_record_batch_message_with_dispatcher(
            _int64_frame(MESSAGE_HEADER_RECORD_BATCH, 2),
            _types(ArrowType.INT64),
            Pointer(to=nd),
            CancellationToken.never(),
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "_decompress_frame_if_needed_with_dispatcher: unknown"
        " BodyCompression.codec 2 (valid: -1 Uncompressed, 0 LZ4_FRAME,"
        " 1 ZSTD)",
    )


def test_nested_zero_copy_decoder_refuses_a_compressed_frame() raises:
    var frame = _int64_frame(MESSAGE_HEADER_RECORD_BATCH, 0)
    var msg = String("")
    try:
        _ = decode_record_batch_message_nested_zerocopy(
            frame, _specs(ArrowType.INT64)
        )
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "decode_record_batch_message_nested_zerocopy: frame carries"
            " BodyCompression.codec=0 (compressed); zero-copy decode requires"
            " uncompressed bodies."
        ),
        msg,
    )


# ---------------------------------------------------------------------------
# DICTIONARY in the flat decoders
# ---------------------------------------------------------------------------


def _dict_frame() raises -> SharedAlignedBuffer[HeapRegion]:
    """One DICTIONARY column: 3 Int32 codes (validity + codes buffers)."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 12))
    return _frame(MESSAGE_HEADER_RECORD_BATCH, 3, nodes^, bufs^)


def test_flat_decoders_refuse_a_dictionary_column() raises:
    var msg = String("")
    try:
        _ = decode_record_batch_message(
            _dict_frame(), _types(ArrowType.DICTIONARY)
        )
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "_decode_column: DICTIONARY columns require dict-aware decode"
        ),
        msg,
    )
    msg = String("")
    var frame = _dict_frame()
    try:
        _ = decode_record_batch_zerocopy(frame, _types(ArrowType.DICTIONARY))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "decode_record_batch_zerocopy: ArrowType 19 not supported in the flat"
        " zero-copy decoder (nested types go through the nested zero-copy"
        " decoder)",
    )


# ---------------------------------------------------------------------------
# The flat zero-copy decoder
# ---------------------------------------------------------------------------


def test_zero_copy_refuses_node_and_buffer_count_mismatches() raises:
    var frame = _int64_frame(MESSAGE_HEADER_RECORD_BATCH)
    var two = _types(ArrowType.INT64)
    two.append(ArrowType.INT64)
    var msg = String("")
    try:
        _ = decode_record_batch_zerocopy(frame, two)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "decode_record_batch_zerocopy: FieldNode count mismatch (got 1,"
        " expected 2)",
    )
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    bufs.append(_buf(0, 0))
    var three = _frame(MESSAGE_HEADER_RECORD_BATCH, 3, nodes^, bufs^)
    msg = String("")
    try:
        _ = decode_record_batch_zerocopy(three, _types(ArrowType.INT64))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "decode_record_batch_zerocopy: Buffer count mismatch (got 3,"
        " expected 2)",
    )


def test_zero_copy_null_column_then_int64() raises:
    """A NULL column has a node and no buffer: the INT64 column after it
    reads the first two buffers."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 3))
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    var frame = _frame(MESSAGE_HEADER_RECORD_BATCH, 3, nodes^, bufs^)
    var types = _types(ArrowType.NULL)
    types.append(ArrowType.INT64)
    var cols = decode_record_batch_zerocopy(frame, types)
    assert_equal(len(cols), 2)
    assert_equal(cols[0].arrow_type, ArrowType.NULL)
    assert_equal(cols[0]._length, 3)
    assert_equal(cols[0]._null_count, 3)
    assert_equal(cols[1]._data.read_i64_le_at(8), Int64(6))


def test_zero_copy_string_column_with_a_null() raises:
    """STRING rows "a", null, "bc": validity 0b101 at 56, offsets at 24,
    data at 40."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 1))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(56, 1))
    bufs.append(_buf(24, 16))
    bufs.append(_buf(40, 3))
    var frame = _frame(MESSAGE_HEADER_RECORD_BATCH, 3, nodes^, bufs^)
    var cols = decode_record_batch_zerocopy(frame, _types(ArrowType.STRING))
    ref c = cols[0]
    assert_equal(c.arrow_type, ArrowType.STRING)
    assert_equal(c._null_count, 1)
    assert_false(c.is_null_at(0))
    assert_true(c.is_null_at(1))
    assert_false(c.is_null_at(2))
    var s = c.as_string()
    assert_equal(s.get(0), String("a"))
    assert_equal(s.get(2), String("bc"))


# ---------------------------------------------------------------------------
# Type tables and the per-column decoder, called directly
# ---------------------------------------------------------------------------


def test_fixed_width_bytes_for_every_arm() raises:
    """Run-time lookups (the types come out of a List) of the widths the
    round-trip tests do not reach."""
    var rows = List[Tuple[ArrowType, Int]]()
    rows.append((ArrowType.INT8, 1))
    rows.append((ArrowType.UINT8, 1))
    rows.append((ArrowType.INT16, 2))
    rows.append((ArrowType.UINT16, 2))
    rows.append((ArrowType.DATE64, 8))
    rows.append((ArrowType.TIME64_US, 8))
    rows.append((ArrowType.TIME64_NS, 8))
    rows.append((ArrowType.INTERVAL_YEAR_MONTH, 4))
    rows.append((ArrowType.INTERVAL_DAY_TIME, 8))
    rows.append((ArrowType.INTERVAL_MONTH_DAY_NANO, 16))
    rows.append((ArrowType.DECIMAL256, 32))
    rows.append((ArrowType.STRING, 0))
    rows.append((ArrowType.LIST, 0))
    for i in range(len(rows)):
        assert_equal(
            _fixed_width_bytes_for(rows[i][0]), rows[i][1], String(rows[i][0])
        )


def test_buffer_count_and_decode_column_refuse_a_nested_type() raises:
    """The public flat decoders refuse a LIST at _node_count_for, before
    these two run; called directly they refuse it too."""
    var msg = String("")
    try:
        _ = _buffer_count_for(ArrowType.LIST)
    except e:
        msg = String(e)
    assert_equal(
        msg, "_buffer_count_for: ArrowType 20 not supported in the flat decoder"
    )
    var frame = _int64_frame(MESSAGE_HEADER_RECORD_BATCH)
    msg = String("")
    try:
        _ = _decode_column(
            ArrowType.LIST,
            List[FieldNode](),
            List[BufferDescriptor](),
            0,
            0,
            frame,
            0,
            0,
        )
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "_decode_column: ArrowType 20 not wired in the flat decoder"
        ),
        msg,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
