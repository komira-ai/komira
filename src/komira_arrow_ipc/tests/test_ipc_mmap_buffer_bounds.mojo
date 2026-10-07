# =============================================================================
# test_ipc_mmap_buffer_bounds.mojo: malformed Buffer descriptors and frame
# placements are refused on the decoders that borrow instead of copy.
# =============================================================================
#
# `decode_record_batch_message_mmap` hands each column a buffer that aliases
# the mapped file at `abs_frame_offset_in_mmap + body_pos + Buffer.offset`.
# Nothing is read while the columns are built, so a decoder that skips the
# bounds check returns columns whose buffers point outside the message body
# (or outside the mapping) and the first consumer reads out of bounds. The
# refusal is therefore observable without a crash: each case below asserts
# the exact validation text, and a decoder without the check returns columns
# instead (or raises a different, later message).
#
# Every malformed frame here is otherwise well formed: node and buffer counts
# match the schema and every length satisfies the per-column builders'
# "buffer too small" checks, so the only thing wrong is where a buffer lies.
# The mapped file is the frame followed by 4096 trailing bytes, so an
# unchecked borrow past the body stays inside the mapping and the unchecked
# decoder returns normally rather than faulting.
#
# The nested decoders (copy-on-read and zero-copy) had the same gap and are
# pinned with the same malformed frame.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_mmap,
    decode_record_batch_message_nested,
    decode_record_batch_message_nested_zerocopy,
    decode_record_batch_message_with_dicts,
)
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_RECORD_BATCH,
    parse_ipc_message,
    write_ipc_message,
    write_message,
    write_record_batch,
)


comptime BODY = 64
comptime TRAILING = 4096
comptime MMAP_CTX = "decode_record_batch_message_mmap"


# ---------------------------------------------------------------------------
# Frame and file plumbing
# ---------------------------------------------------------------------------


def _scratch(name: String) -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_ipc_mmap_bounds_" + name


def _frame(
    rows: Int, buffers: List[BufferDescriptor]
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A RecordBatch frame of one column with `rows` rows, the given Buffer
    descriptors and a BODY-byte body. Body bytes 0..23 hold the Int64
    values 5, 6, 7 and the rest are zero. No case reads a STRING or BOOL
    value, so the body needs no other layout."""
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(rows), null_count=Int64(0)))
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(w, Int64(rows), nodes, buffers)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(BODY)
    )
    var fb = w^.finalize(msg_pos)
    var body = List[UInt8](capacity=BODY)
    for i in range(BODY):
        var b = 0
        if i < 24 and i % 8 == 0:
            b = 5 + i // 8
        body.append(UInt8(b))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _map(
    frame: SharedAlignedBuffer[HeapRegion], name: String, trailing: Int
) raises -> ArcPointer[MmapRegion]:
    """Write `frame` followed by `trailing` zero bytes to a scratch file and
    map it."""
    var bytes = List[UInt8](capacity=frame.len() + trailing)
    for i in range(frame.len()):
        bytes.append(frame.read_u8_at(i))
    for _ in range(trailing):
        bytes.append(UInt8(0))
    var path = _scratch(name)
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^
    return ArcPointer[MmapRegion](MmapRegion.open_readonly(path))


def _types(t: ArrowType) -> List[ArrowType]:
    var out = List[ArrowType]()
    out.append(t)
    return out^


def _bufs(o0: Int64, l0: Int64, o1: Int64, l1: Int64) -> List[BufferDescriptor]:
    var out = List[BufferDescriptor]()
    out.append(BufferDescriptor(offset=o0, length=l0))
    out.append(BufferDescriptor(offset=o1, length=l1))
    return out^


def _bufs3(
    o0: Int64, l0: Int64, o1: Int64, l1: Int64, o2: Int64, l2: Int64
) -> List[BufferDescriptor]:
    var out = _bufs(o0, l0, o1, l1)
    out.append(BufferDescriptor(offset=o2, length=l2))
    return out^


def _mmap_error(
    t: ArrowType,
    rows: Int,
    buffers: List[BufferDescriptor],
    name: String,
    trailing: Int = TRAILING,
    abs_offset: Int = 0,
) raises -> String:
    """Decode through the mmap path; return the refusal text, or "" when
    the decoder returned columns."""
    var frame = _frame(rows, buffers)
    var region = _map(frame, name, trailing)
    try:
        _ = decode_record_batch_message_mmap(
            frame^, _types(t), region, abs_offset
        )
    except e:
        return String(e)
    return String("")


def _exceeds(
    ctx: String, rows: Int, buffers: List[BufferDescriptor], i: Int
) raises -> String:
    """The validator's out-of-body text for Buffer[i] of `_frame(rows,
    buffers)`. The body position is read from that frame, since the
    metadata (and so the body start) grows with the buffer count."""
    var body_pos = parse_ipc_message(_frame(rows, buffers)).body_pos
    return (
        ctx + ": Buffer[" + String(i) + "] range (offset="
        + String(buffers[i].offset) + ", length=" + String(buffers[i].length)
        + ") exceeds the message body (body_pos=" + String(body_pos)
        + ", body_size=" + String(BODY) + ", frame_len="
        + String(body_pos + BODY) + ")"
    )


def _expect_mmap_exceeds(
    t: ArrowType, buffers: List[BufferDescriptor], i: Int, name: String
) raises:
    """The mmap decoder refuses `buffers` (3 rows of type `t`) with the
    validator's text for Buffer[i]."""
    assert_equal(
        _mmap_error(t, 3, buffers, name),
        _exceeds(String(MMAP_CTX), 3, buffers, i),
    )


# ---------------------------------------------------------------------------
# Control: the harness frame is valid and decodes through the mmap path
# ---------------------------------------------------------------------------


def test_valid_frame_decodes_through_mmap() raises:
    """The unmodified frame decodes, so the refusals below are caused by the
    one malformed descriptor, not by the harness. A values buffer ending
    exactly at the body end (offset 40 + 24 == 64) is accepted, so an
    off-by-one `>=` in the bound would fail here."""
    var frame = _frame(3, _bufs(0, 0, 0, 24))
    var region = _map(frame, "valid.bin", TRAILING)
    var cols = decode_record_batch_message_mmap(
        frame^, _types(ArrowType.INT64), region, 0
    )
    assert_equal(cols[0]._length, 3)
    for i in range(3):
        assert_equal(cols[0]._data.read_i64_le_at(i * 8), Int64(5 + i))

    assert_equal(
        _mmap_error(ArrowType.INT64, 3, _bufs(0, 0, 40, 24), "at_end.bin"),
        String(""),
    )


def test_zero_length_buffer_offset_is_ignored() raises:
    """A zero-length buffer is never dereferenced, so its offset is not
    checked (the copy paths accept it too)."""
    assert_equal(
        _mmap_error(
            ArrowType.INT64, 3, _bufs(Int64.MAX, 0, 0, 24), "zero_len.bin"
        ),
        String(""),
    )


# ---------------------------------------------------------------------------
# Buffer descriptors outside the message body
# ---------------------------------------------------------------------------


def test_mmap_refuses_offset_past_body() raises:
    """Values buffer starting 8 bytes past the body end."""
    _expect_mmap_exceeds(
        ArrowType.INT64, _bufs(0, 0, BODY + 8, 24), 1, "off_past.bin"
    )


def test_mmap_refuses_length_past_body_end() raises:
    """Values buffer starting inside the body and ending 8 bytes past it."""
    _expect_mmap_exceeds(
        ArrowType.INT64, _bufs(0, 0, 48, 24), 1, "len_past.bin"
    )


def test_mmap_refuses_offset_plus_length_overflow() raises:
    """An offset, then a length, so large that offset + length wraps Int64:
    a bound written as `offset + length > body_size` alone passes both."""
    _expect_mmap_exceeds(
        ArrowType.INT64, _bufs(0, 0, Int64.MAX - 4, 24), 1, "ovf_off.bin"
    )
    _expect_mmap_exceeds(
        ArrowType.INT64, _bufs(0, 0, 8, Int64.MAX - 4), 1, "ovf_len.bin"
    )


def test_mmap_refuses_negative_offset_and_length() raises:
    """A negative offset would borrow the frame's metadata (or bytes before
    the frame); a negative length is refused before any builder sees it."""
    assert_equal(
        _mmap_error(ArrowType.INT64, 3, _bufs(0, 0, -8, 24), "neg_off.bin"),
        String(MMAP_CTX) + ": Buffer[1] has negative offset -8",
    )
    assert_equal(
        _mmap_error(ArrowType.INT64, 3, _bufs(0, -1, 0, 24), "neg_len.bin"),
        String(MMAP_CTX) + ": Buffer[0] has negative length -1",
    )


def test_mmap_refuses_bool_validity_past_body() raises:
    """BOOL arm: the validity bitmap starting past the body."""
    _expect_mmap_exceeds(
        ArrowType.BOOL, _bufs(BODY + 8, 1, 0, 1), 0, "bool.bin"
    )


def test_mmap_refuses_string_data_past_body() raises:
    """Var-len arm: the data buffer running past the body end."""
    _expect_mmap_exceeds(
        ArrowType.STRING, _bufs3(0, 0, 0, 16, 56, 16), 2, "string.bin"
    )


def test_mmap_dictionary_column_is_refused() raises:
    """The mmap path has no dictionary arm, so no DictionaryBatch is ever
    borrowed from the mapping: a DICTIONARY column with in-body buffers is
    refused by name, and one with a buffer past the body is refused by the
    bounds check first."""
    assert_equal(
        _mmap_error(ArrowType.DICTIONARY, 3, _bufs(0, 0, 0, 12), "dict.bin"),
        String(MMAP_CTX)
        + ": DICTIONARY columns require dict-aware decode. Caller"
        + " should use the copy-on-read dict-aware dispatch instead of the"
        + " mmap path for files containing dict-encoded columns.",
    )
    _expect_mmap_exceeds(
        ArrowType.DICTIONARY, _bufs(0, 0, BODY, 12), 1, "dict_bad.bin"
    )


def test_copy_path_refuses_with_the_same_text() raises:
    """The copy-on-read decoder refuses the same descriptor with the same
    validator text (under its own name)."""
    var bad = _bufs(0, 0, BODY + 8, 24)
    var no_dict: List[Bool] = [False]
    var placeholders = Slab[Column[HeapRegion]]()
    placeholders.append(Column[HeapRegion]())
    var got = String("")
    try:
        _ = decode_record_batch_message_with_dicts(
            _frame(3, bad), _types(ArrowType.INT64), no_dict, placeholders^
        )
    except e:
        got = String(e)
    assert_equal(
        got, _exceeds("decode_record_batch_message_with_dicts", 3, bad, 1)
    )


# ---------------------------------------------------------------------------
# The frame itself outside the mapping
# ---------------------------------------------------------------------------


def _region_error(abs_offset: Int, frame_len: Int, region_len: Int) -> String:
    return (
        String(MMAP_CTX) + ": frame (offset=" + String(abs_offset)
        + ", length=" + String(frame_len)
        + ") lies outside the mapped region (length=" + String(region_len)
        + ")"
    )


def test_mmap_refuses_frame_past_mapped_region() raises:
    """A valid frame whose claimed file offset puts its tail past the end of
    the mapping. The file holds only the frame; offset 8 moves the values
    buffer (which ends at the body end) 8 bytes past the mapping."""
    var good = _bufs(0, 0, 40, 24)
    var n = _frame(3, good).len()
    assert_equal(
        _mmap_error(
            ArrowType.INT64, 3, good, "region_tail.bin", trailing=0,
            abs_offset=8,
        ),
        _region_error(8, n, n),
    )


def test_mmap_refuses_negative_and_huge_frame_offset() raises:
    """A negative file offset, and one so large that offset + frame length
    wraps (an unguarded sum would compare as in range)."""
    var good = _bufs(0, 0, 0, 24)
    var n = _frame(3, good).len()
    assert_equal(
        _mmap_error(
            ArrowType.INT64, 3, good, "region_neg.bin", trailing=0,
            abs_offset=-8,
        ),
        _region_error(-8, n, n),
    )
    assert_equal(
        _mmap_error(
            ArrowType.INT64, 3, good, "region_huge.bin", trailing=0,
            abs_offset=Int.MAX - 8,
        ),
        _region_error(Int.MAX - 8, n, n),
    )


# ---------------------------------------------------------------------------
# The nested decoders (copy-on-read, and zero-copy borrow of the frame)
# ---------------------------------------------------------------------------


def _int64_spec() raises -> Slab[ColumnTypeSpec]:
    var s = Slab[ColumnTypeSpec]()
    s.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    return s^


def test_nested_decoders_refuse_offset_past_body() raises:
    """Both nested entry points validate before any column is decoded."""
    var bad = _bufs(0, 0, BODY + 8, 24)
    var got = String("")
    try:
        _ = decode_record_batch_message_nested(_frame(3, bad), _int64_spec())
    except e:
        got = String(e)
    assert_equal(got, _exceeds("decode_record_batch_message_nested", 3, bad, 1))

    var frame = _frame(3, bad)
    got = String("")
    try:
        _ = decode_record_batch_message_nested_zerocopy(frame, _int64_spec())
    except e:
        got = String(e)
    assert_equal(
        got, _exceeds("decode_record_batch_message_nested_zerocopy", 3, bad, 1)
    )


def test_nested_decoders_accept_valid_frame() raises:
    """Control for the nested refusals: the same frame with the values
    buffer inside the body decodes through both entry points."""
    var good = _bufs(0, 0, 0, 24)
    var a = decode_record_batch_message_nested(_frame(3, good), _int64_spec())
    assert_equal(a[0]._data.read_i64_le_at(16), Int64(7))
    var frame = _frame(3, good)
    var b = decode_record_batch_message_nested_zerocopy(frame, _int64_spec())
    assert_equal(b[0]._data.read_i64_le_at(16), Int64(7))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
