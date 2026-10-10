# =============================================================================
# test_ipc_body_compression_edges.mojo: compressed messages at their edges,
# malformed compressed frames, and codec failures surfacing as errors
# =============================================================================
#
# Edges: a batch of NULL columns has no buffer to compress or decompress;
# an incompressible megabyte is stored raw (the -1 length prefix) and makes
# the encoder grow its compact body past its first estimate. Both round-trip.
#
# Malformed frames: a compressed buffer shorter than its 8-byte length
# prefix, a prefix below -1, and a Message of the wrong kind are refused by
# decompress_record_batch_frame, by the coalesced multi-frame decompress's
# per-frame context build (_build_rb_context) and by
# decompress_dictionary_batch_frame, each naming itself and the buffer.
#
# Codec failures: `Planted[MODE]` is an LZ4-frame codec (on the wire it is
# LZ4) that fails on purpose: MODE 0 raises from compress_into, MODE 1
# returns one byte fewer than it decompressed, MODE 2 raises from
# decompress_into. Each failure reaches the caller as an error naming the
# buffer, through the serial path and through a dispatcher (InlineDispatch
# runs the tasks on the calling thread), so a worker's error is never
# dropped and a short decompress is never served.
#
# FFI-BOUNDARY: `Planted` conforms to the codec trait, whose create_dctx /
# free_dctx / decompress_into_with_dctx spell the codec's opaque
# decompression context with MutUntrackedOrigin, so a conformer must too
# (tests/pointer_lint_ffi.tsv lists this file). Ownership: the context is
# LZ4's; Planted forwards it to Lz4Frame, which creates and frees it.
# =============================================================================

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression import ArrowIpcCompression
from komira_compression.compression_codecs import Lz4Frame
from komira_async_api.parallel_dispatch import NoDispatch, ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_arrow_ipc.ipc_body_compression import (
    _build_rb_context,
    decompress_all_rbs_into_with_dispatcher,
    decompress_dictionary_batch_frame,
    decompress_record_batch_frame,
    decompress_record_batch_frame_with_dispatcher,
    encode_record_batch_message_compressed,
    encode_record_batch_message_compressed_with_dispatcher,
    peek_dictionary_batch_codec_from_frame,
)
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    write_body_compression,
    write_dictionary_batch,
    write_ipc_message,
    write_message,
    write_record_batch,
    write_record_batch_compressed,
)


# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------


struct InlineDispatch(ParallelDispatch, Movable, Deinitable):
    """Runs the n tasks of a dispatch in order on the calling thread."""

    def __init__(out self):
        pass

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        for t in range(n):
            seg.execute[State](state, Int32(0), Int64(t))
        return seg^

    def worker_count(self) -> Int:
        return 4


comptime COMPRESS_FAILS = 0
comptime DECOMPRESS_SHORT = 1
comptime DECOMPRESS_FAILS = 2


struct Planted[MODE: Int](ArrowIpcCompression):
    """Lz4Frame with one planted failure (see the file header)."""

    comptime PARQUET_CODEC_ID: Int8 = -1
    comptime ARROW_IPC_CODEC_ID: Int8 = 0
    comptime FILE_EXTENSION: StaticString = ".lz4"
    comptime NAME: StaticString = "planted"

    def __init__(out self):
        pass

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        return Lz4Frame.compress(input)

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        return Lz4Frame.decompress(input, expected_size)

    @staticmethod
    def decompress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        comptime if Self.MODE == DECOMPRESS_FAILS:
            raise Error("planted decompress failure")
        var got = Lz4Frame.decompress_into(src, dst, dst_capacity)
        comptime if Self.MODE == DECOMPRESS_SHORT:
            return got - 1
        return got

    @staticmethod
    def create_dctx() raises -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        return Lz4Frame.create_dctx()

    @staticmethod
    def free_dctx(var dctx: UnsafePointer[UInt8, MutUntrackedOrigin]):
        Lz4Frame.free_dctx(dctx)

    @staticmethod
    def decompress_into_with_dctx[
        o: Origin[mut=True], //,
    ](
        dctx: UnsafePointer[UInt8, MutUntrackedOrigin],
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        comptime if Self.MODE == DECOMPRESS_FAILS:
            raise Error("planted decompress failure")
        var got = Lz4Frame.decompress_into_with_dctx(
            dctx, src, dst, dst_capacity
        )
        comptime if Self.MODE == DECOMPRESS_SHORT:
            return got - 1
        return got

    @staticmethod
    def compress_bound(src_size: Int) raises -> Int:
        return Lz4Frame.compress_bound(src_size)

    @staticmethod
    def compress_into[
        o: Origin[mut=True], //,
    ](
        src: Span[UInt8, _],
        dst: UnsafePointer[UInt8, o],
        dst_capacity: Int,
    ) raises -> Int:
        comptime if Self.MODE == COMPRESS_FAILS:
            raise Error("planted compress failure")
        return Lz4Frame.compress_into(src, dst, dst_capacity)


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

comptime ROWS = 64


def _int_col(seed: Int, rows: Int = ROWS) -> Column[HeapRegion]:
    """Compressible values: a short repeating pattern."""
    var v = List[Int64]()
    for i in range(rows):
        v.append(Int64(i % 4 + seed))
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(v)
    )


def _cols(n: Int) -> Slab[Column[HeapRegion]]:
    var cols = Slab[Column[HeapRegion]]()
    for s in range(n):
        cols.append(_int_col(s + 1))
    return cols^


def _types(n: Int) -> List[ArrowType]:
    var t = List[ArrowType]()
    for _ in range(n):
        t.append(ArrowType.INT64)
    return t^


def _null_col(rows: Int) -> Column[HeapRegion]:
    var data = OwnedAlignedBuffer(1)
    data.set_length(Int64(0))
    return Column[HeapRegion](
        arrow_type=ArrowType.NULL,
        data=data^,
        offsets=None,
        validity=None,
        length=rows,
        null_count=rows,
        offset=0,
    )


# ---------------------------------------------------------------------------
# Edges that round-trip
# ---------------------------------------------------------------------------


def test_null_only_batch_round_trips_compressed() raises:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_null_col(5))
    var frame = encode_record_batch_message_compressed[Lz4Frame](cols^)
    var plain = decompress_record_batch_frame[Lz4Frame](frame^)
    var types = List[ArrowType]()
    types.append(ArrowType.NULL)
    var back = decode_record_batch_message(plain^, types)
    assert_equal(back[0].arrow_type, ArrowType.NULL)
    assert_equal(back[0]._length, 5)


def test_incompressible_megabyte_is_stored_raw_and_round_trips() raises:
    """2.4M INT64 values (19.2 MB) from a 64-bit LCG do not compress: the
    encoder stores the buffer behind the -1 prefix. The LZ4 frame of an
    incompressible buffer carries 4 bytes per 64 KiB block, so past about
    17 MB the compact body outgrows the encoder's first estimate (raw + 64
    per buffer + 1024) and is reallocated."""
    comptime N = 2400000
    var v = List[Int64]()
    var x = UInt64(0x9E3779B97F4A7C15)
    for _ in range(N):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        v.append(Int64(x >> 1))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(v)
        )
    )
    var frame = encode_record_batch_message_compressed[Lz4Frame](cols^)
    var back = decode_record_batch_message(
        decompress_record_batch_frame[Lz4Frame](frame^), _types(1)
    )
    for i in range(0, N, 65537):
        assert_equal(back[0]._data.read_i64_le_at(i * 8), v[i])
    assert_equal(back[0]._data.read_i64_le_at((N - 1) * 8), v[N - 1])


# ---------------------------------------------------------------------------
# Malformed compressed frames
# ---------------------------------------------------------------------------


def _rb_table(
    mut w: FlatbufWriter, buf_len: Int, prefix_at_0: Int64
) raises -> Int:
    """A compressed (LZ4) RecordBatch of one INT64 column of 2 rows whose
    values buffer is (0, buf_len)."""
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(2), null_count=Int64(0)))
    var bufs = List[BufferDescriptor]()
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(0)))
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(buf_len)))
    var bc = write_body_compression(w, Int8(0))
    return write_record_batch_compressed(w, Int64(2), nodes, bufs, bc)


def _frame(
    header: UInt8, buf_len: Int, prefix: Int64
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A RecordBatch (or, for a DictionaryBatch header, a DictionaryBatch
    wrapping it) over a 32-byte body whose first 8 bytes are `prefix`."""
    var w = FlatbufWriter(2048)
    var rb = _rb_table(w, buf_len, prefix)
    var head_pos = rb
    if header == MESSAGE_HEADER_DICTIONARY_BATCH:
        head_pos = write_dictionary_batch(w, Int64(3), rb, False)
    var msg = write_message(w, Int16(4), header, head_pos, Int64(32))
    var fb = w^.finalize(msg)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(32)
    body.zero()
    body.write_i64_le_at(0, prefix)
    body.set_length(32)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(
        w2, fb^, body.view_range_ro(0, 32).into_span(), True
    )


def _rb_error(var frame: SharedAlignedBuffer[HeapRegion]) -> String:
    try:
        _ = decompress_record_batch_frame[Lz4Frame](frame^)
    except e:
        return String(e)
    return String("no error")


def _all_error(var frame: SharedAlignedBuffer[HeapRegion]) -> String:
    """The coalesced decompress's per-frame context build, called directly:
    through decompress_all_rbs_into_with_dispatcher a frame it refuses
    crashes the process after the error is raised (the frame slab is
    dropped with the refused frame's slot already taken,
    komira-ai/komira#1062), so the refusals are checked on the helper."""
    try:
        _ = _build_rb_context[Lz4Frame](frame^)
    except e:
        return String(e)
    return String("no error")


def _dict_error(var frame: SharedAlignedBuffer[HeapRegion]) -> String:
    try:
        _ = decompress_dictionary_batch_frame[Lz4Frame](frame^)
    except e:
        return String(e)
    return String("no error")


def test_short_buffer_is_refused_by_each_decompressor() raises:
    """A 4-byte compressed buffer cannot hold its 8-byte prefix."""
    var tail = " has length 4 < 8 (the i64 uncompressed_length prefix);"
    assert_equal(
        _rb_error(_frame(MESSAGE_HEADER_RECORD_BATCH, 4, Int64(16))),
        String("decompress_record_batch_frame: buffer 1") + tail
        + " malformed compressed body",
    )
    assert_equal(
        _all_error(_frame(MESSAGE_HEADER_RECORD_BATCH, 4, Int64(16))),
        String("_build_rb_context: buffer 1") + tail
        + " malformed compressed body",
    )
    assert_equal(
        _dict_error(_frame(MESSAGE_HEADER_DICTIONARY_BATCH, 4, Int64(16))),
        String("decompress_dictionary_batch_frame: buffer 1") + tail
        + " malformed compressed body",
    )


def test_prefix_below_minus_one_is_refused_by_each_decompressor() raises:
    """-1 means "stored raw"; -2 means nothing."""
    assert_equal(
        _rb_error(_frame(MESSAGE_HEADER_RECORD_BATCH, 24, Int64(-2))),
        "decompress_record_batch_frame: buffer 1 has negative"
        " uncompressed_length -2 (only -1 sentinel is valid; malformed"
        " compressed body)",
    )
    assert_equal(
        _all_error(_frame(MESSAGE_HEADER_RECORD_BATCH, 24, Int64(-2))),
        "_build_rb_context: buffer 1 has negative uncompressed_length -2"
        " (only -1 sentinel is valid)",
    )
    assert_equal(
        _dict_error(_frame(MESSAGE_HEADER_DICTIONARY_BATCH, 24, Int64(-2))),
        "decompress_dictionary_batch_frame: buffer 1 has negative"
        " uncompressed_length -2 (only -1 sentinel is valid; malformed"
        " compressed body)",
    )


def test_stored_raw_control_decompresses() raises:
    """The control for the two refusals above: prefix -1 and 16 raw bytes
    after it (two INT64 zeros) decompress to a 16-byte values buffer."""
    var out = decompress_record_batch_frame[Lz4Frame](
        _frame(MESSAGE_HEADER_RECORD_BATCH, 24, Int64(-1))
    )
    var cols = decode_record_batch_message(out^, _types(1))
    assert_equal(cols[0]._length, 2)
    assert_equal(cols[0]._data.read_i64_le_at(8), Int64(0))


def test_wrong_message_kind_is_refused() raises:
    assert_equal(
        _rb_error(_frame(MESSAGE_HEADER_DICTIONARY_BATCH, 24, Int64(-1))),
        "decompress_record_batch_frame: expected RECORD_BATCH header (tag 3),"
        " got 2",
    )
    assert_equal(
        _all_error(_frame(MESSAGE_HEADER_DICTIONARY_BATCH, 24, Int64(-1))),
        "_build_rb_context: expected RECORD_BATCH header (tag 3), got 2",
    )
    assert_equal(
        _dict_error(_frame(MESSAGE_HEADER_RECORD_BATCH, 24, Int64(-1))),
        "decompress_dictionary_batch_frame: expected DICTIONARY_BATCH header"
        " (tag 2), got 3",
    )
    var rb = _frame(MESSAGE_HEADER_RECORD_BATCH, 24, Int64(-1))
    var msg = String("")
    try:
        _ = peek_dictionary_batch_codec_from_frame(rb)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "peek_dictionary_batch_codec_from_frame: expected DICTIONARY_BATCH"
        " header (tag 2), got 3",
    )


# ---------------------------------------------------------------------------
# Planted codec failures
# ---------------------------------------------------------------------------


def test_a_compress_failure_names_the_buffer_serial_and_dispatched() raises:
    var msg = String("")
    try:
        _ = encode_record_batch_message_compressed[Planted[COMPRESS_FAILS]](
            _cols(1)
        )
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("_compress_buffers_into: buffer 1 (raw_len=512, bound="),
        msg,
    )
    assert_true(msg.endswith("): planted compress failure"), msg)
    var d = InlineDispatch()
    msg = String("")
    try:
        _ = encode_record_batch_message_compressed_with_dispatcher[
            Planted[COMPRESS_FAILS]
        ](_cols(4), Pointer(to=d), CancellationToken.never())
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("_compress_buffers_into: buffer 1 (raw_len=512, bound="),
        msg,
    )
    assert_true(msg.endswith("): planted compress failure"), msg)
    # Below the dispatch threshold under a dispatcher: the same message.
    msg = String("")
    try:
        _ = encode_record_batch_message_compressed_with_dispatcher[
            Planted[COMPRESS_FAILS]
        ](_cols(1), Pointer(to=d), CancellationToken.never())
    except e:
        msg = String(e)
    assert_true(msg.endswith("): planted compress failure"), msg)


def test_a_short_decompress_is_refused_serial_and_dispatched() raises:
    """512 bytes in, the codec says 511 out: never served as a buffer."""
    var msg = _rb_error_planted_short(
        encode_record_batch_message_compressed[Lz4Frame](_cols(1)), False
    )
    assert_equal(
        msg,
        "decompress_record_batch_frame: buffer 1 decompressed size 511 does"
        " not match prefix 512",
    )
    msg = _rb_error_planted_short(
        encode_record_batch_message_compressed[Lz4Frame](_cols(1)), True
    )
    assert_equal(
        msg,
        "decompress_record_batch_frame: buffer 1 decompressed size 511 does"
        " not match prefix 512",
    )
    msg = _rb_error_planted_short(
        encode_record_batch_message_compressed[Lz4Frame](_cols(4)), True
    )
    assert_true(
        msg.startswith("decompress_record_batch_frame: buffer 1: "), msg
    )
    assert_true("decompressed size 511 does not match prefix 512" in msg, msg)


def _rb_error_planted_short(
    var frame: SharedAlignedBuffer[HeapRegion], dispatched: Bool
) -> String:
    try:
        if dispatched:
            var d = InlineDispatch()
            _ = decompress_record_batch_frame_with_dispatcher[
                Planted[DECOMPRESS_SHORT]
            ](frame^, Pointer(to=d), CancellationToken.never())
        else:
            _ = decompress_record_batch_frame[Planted[DECOMPRESS_SHORT]](
                frame^
            )
    except e:
        return String(e)
    return String("no error")


def test_a_decompress_failure_is_raised_through_a_dispatcher() raises:
    var d = InlineDispatch()
    var msg = String("")
    try:
        _ = decompress_record_batch_frame_with_dispatcher[
            Planted[DECOMPRESS_FAILS]
        ](
            encode_record_batch_message_compressed[Lz4Frame](_cols(4)),
            Pointer(to=d),
            CancellationToken.never(),
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "decompress_record_batch_frame: buffer 1: planted decompress failure",
    )


def _coalesced_error[
    MODE: Int
](n_frames: Int, cols_per_frame: Int) -> String:
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    try:
        for _ in range(n_frames):
            frames.append(
                encode_record_batch_message_compressed[Lz4Frame](
                    _cols(cols_per_frame)
                )
            )
        var d = InlineDispatch()
        _ = decompress_all_rbs_into_with_dispatcher[Planted[MODE]](
            frames^, Pointer(to=d), CancellationToken.never()
        )
    except e:
        return String(e)
    return String("no error")


def test_coalesced_decompress_surfaces_codec_failures() raises:
    # Serial walk (one frame, one non-empty buffer): a short decompress.
    assert_equal(
        _coalesced_error[DECOMPRESS_SHORT](1, 1),
        "decompress_all_rbs_into: rb=0 buf=1: decompressed size 511 does not"
        " match prefix 512",
    )
    # Dispatched (two frames, four non-empty buffers each): the worker's
    # failure is raised, naming the frame.
    var msg = _coalesced_error[DECOMPRESS_FAILS](2, 4)
    assert_true(
        msg.startswith("decompress_all_rbs_into_with_dispatcher: "), msg
    )
    assert_true("planted decompress failure" in msg, msg)
    msg = _coalesced_error[DECOMPRESS_SHORT](2, 4)
    assert_true(
        msg.startswith("decompress_all_rbs_into_with_dispatcher: "), msg
    )
    assert_true("decompressed size 511 does not match prefix 512" in msg, msg)
    # One frame of four non-empty buffers (1, 3, 5, 7): dispatched over
    # buffers; a failing buffer is reported for the frame. Which one
    # depends on the worker count (each short worker writes the one slot),
    # so only its being one of the four is checked.
    msg = _coalesced_error[DECOMPRESS_SHORT](1, 4)
    assert_true(
        msg.startswith("decompress_all_rbs_into_with_dispatcher: rb=0 buf="),
        msg,
    )
    assert_true(
        msg.endswith(": decompressed size 511 does not match prefix 512"), msg
    )
    assert_true(
        "rb=0 buf=1:" in msg or "rb=0 buf=3:" in msg or "rb=0 buf=5:" in msg
        or "rb=0 buf=7:" in msg,
        msg,
    )
    msg = _coalesced_error[DECOMPRESS_FAILS](1, 4)
    assert_equal(
        msg,
        "decompress_all_rbs_into_with_dispatcher: rb=0: planted decompress"
        " failure",
    )
    msg = _coalesced_error[DECOMPRESS_SHORT](2, 4)
    assert_true(
        msg.startswith("decompress_all_rbs_into_with_dispatcher: "), msg
    )
    assert_true("decompressed size 511 does not match prefix 512" in msg, msg)


def test_coalesced_serial_walk_decompresses() raises:
    """The control for the serial-walk failure: one frame of one INT64
    column decompresses through the coalesced entry (no dispatch)."""
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    frames.append(encode_record_batch_message_compressed[Lz4Frame](_cols(1)))
    var nd = NoDispatch()
    var outs = decompress_all_rbs_into_with_dispatcher[Lz4Frame](
        frames^, Pointer(to=nd), CancellationToken.never()
    )
    var last = outs.pop()
    var cols = decode_record_batch_message(last.take(), _types(1))
    assert_equal(cols[0]._data.read_i64_le_at(8 * 5), Int64(5 % 4 + 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
