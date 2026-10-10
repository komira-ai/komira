# =============================================================================
# test_ipc_unreached_helpers.mojo: the package's functions that nothing in
# the package calls
# =============================================================================
#
# These are compiled only when a test calls them, so no other test measures
# them. Each is checked against an oracle that does not use it:
#   * the serial and dispatcher-aware per-buffer compress produce the same
#     compact body; the serial and dispatcher-aware per-buffer decompress of
#     it rebuild the raw body byte for byte;
#   * the 8-byte alignment helpers and _slice_body_bytes on edge values;
#   * the two internal BodySinks report the bytes written (body-relative
#     for the offset sink);
#   * FlatbufReader.read_string reads a string written by write_string;
#     the four field-less type tables read back with no field;
#   * c_data_stream's _build_column_schema, _parse_small_uint and
#     _arrow_type_to_dtype.
#
# FFI-BOUNDARY: release_c_schema takes the C Data Interface struct pointer
# with MutUntrackedOrigin, so the pointers to the two schemas built here are
# cast to it (tests/pointer_lint_ffi.tsv lists this file). Ownership: the
# test owns both CArrowSchema values (stack locals); the release frees what
# they point to and NULLs it, never the structs.
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
from komira_compression.compression_codecs import Lz4Frame
from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_arrow_ipc.c_data_interface import ARROW_FLAG_NULLABLE
from komira_arrow_ipc.c_data_stream import (
    CArrowSchema,
    _arrow_type_to_dtype,
    _c_str_to_mojo,
    _build_column_schema,
    _parse_small_uint,
    release_c_schema,
)
from komira_arrow_ipc.ipc_body_compression import (
    _align_to_8 as _bc_align_to_8,
    _compress_buffers_into,
    _compress_buffers_into_with_dispatcher,
    _decompress_buffers_into,
    _decompress_buffers_into_with_dispatcher,
    _slice_body_bytes,
)
from komira_arrow_ipc.ipc_body_sink import AlignedBufferBodySink
from komira_arrow_ipc.ipc_encoder_dispatch import (
    _BodyOffsetSink,
    _NullBodySink,
    _align_to_8 as _enc_align_to_8,
)
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FlatbufWriter,
    add_field_offset,
    end_table,
    flatbuf_reader_over,
    start_table,
    write_type_large_list,
    write_type_large_list_view,
    write_type_list_view,
    write_type_utf8_view,
    _read_table_field_offset,
)


struct InlineDispatch(ParallelDispatch, Movable, Deinitable):
    """Runs the n tasks of a dispatch in order on the calling thread."""

    var dispatches: Int

    def __init__(out self):
        self.dispatches = 0

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        self.dispatches += 1
        for t in range(n):
            seg.execute[State](state, Int32(0), Int64(t))
        return seg^

    def worker_count(self) -> Int:
        return 4


# ---------------------------------------------------------------------------
# Per-buffer compress / decompress
# ---------------------------------------------------------------------------


comptime N_BUFS = 5
comptime BUF_LEN = 200


def _raw_body() raises -> SharedAlignedBuffer[HeapRegion]:
    """Five 200-byte buffers back to back (a compressible pattern each),
    with a 0-byte buffer after the second."""
    var b = SharedAlignedBuffer[HeapRegion].heap_owned(N_BUFS * BUF_LEN)
    for i in range(N_BUFS * BUF_LEN):
        b.write_u8_at(i, UInt8((i // BUF_LEN) * 3 + (i % 5)))
    b.set_length(N_BUFS * BUF_LEN)
    return b^


def _raw_buffers() -> List[BufferDescriptor]:
    var bufs = List[BufferDescriptor]()
    for k in range(N_BUFS):
        bufs.append(
            BufferDescriptor(offset=Int64(k * BUF_LEN), length=Int64(BUF_LEN))
        )
        if k == 1:
            bufs.append(
                BufferDescriptor(offset=Int64(2 * BUF_LEN), length=Int64(0))
            )
    return bufs^


def test_dispatched_compress_equals_serial_and_both_decompress_back() raises:
    var raw = _raw_body()
    var raw_bufs = _raw_buffers()
    var ser_body = OwnedAlignedBuffer(4096)
    var ser_bufs = List[BufferDescriptor]()
    var ser_len = _compress_buffers_into[Lz4Frame](
        raw, raw_bufs, ser_body, ser_bufs
    )
    var d = InlineDispatch()
    var par_body = OwnedAlignedBuffer(4096)
    var par_bufs = List[BufferDescriptor]()
    var par_len = _compress_buffers_into_with_dispatcher[Lz4Frame](
        raw, raw_bufs, par_body, par_bufs, Pointer(to=d),
        CancellationToken.never(),
    )
    assert_equal(d.dispatches, 1)
    assert_equal(par_len, ser_len)
    assert_equal(len(par_bufs), len(ser_bufs))
    for i in range(len(ser_bufs)):
        assert_equal(par_bufs[i].offset, ser_bufs[i].offset)
        assert_equal(par_bufs[i].length, ser_bufs[i].length)
    for i in range(ser_len):
        assert_equal(par_body.read_u8_at(i), ser_body.read_u8_at(i), String(i))
    # Decompress the compact body back into the raw layout, both ways.
    ser_body.set_length(Int64(ser_len))
    var frame = SharedAlignedBuffer.from_owned(ser_body^)
    var u_lens = List[Int]()
    for i in range(len(raw_bufs)):
        u_lens.append(Int(raw_bufs[i].length))
    for way in range(2):
        var out = SharedAlignedBuffer[HeapRegion].heap_owned(N_BUFS * BUF_LEN)
        out.zero()
        out.set_length(N_BUFS * BUF_LEN)
        var back: SharedAlignedBuffer[HeapRegion]
        if way == 0:
            back = _decompress_buffers_into[Lz4Frame](
                frame, 0, ser_bufs, raw_bufs, u_lens, out^, 0, String("t")
            )
        else:
            var d2 = InlineDispatch()
            back = _decompress_buffers_into_with_dispatcher[Lz4Frame](
                frame, 0, ser_bufs, raw_bufs, u_lens, out^, 0, String("t"),
                Pointer(to=d2), CancellationToken.never(),
            )
            assert_equal(d2.dispatches, 1)
        for i in range(N_BUFS * BUF_LEN):
            assert_equal(back.read_u8_at(i), raw.read_u8_at(i), String(i))


def test_alignment_and_slice_helpers() raises:
    var cases = List[Tuple[Int, Int]]()
    cases.append((0, 0))
    cases.append((1, 8))
    cases.append((7, 8))
    cases.append((8, 8))
    cases.append((9, 16))
    for i in range(len(cases)):
        assert_equal(_bc_align_to_8(cases[i][0]), cases[i][1])
        assert_equal(_enc_align_to_8(cases[i][0]), cases[i][1])
    var raw = _raw_body()
    var s = _slice_body_bytes(raw, 199, 3)
    assert_equal(len(s), 3)
    assert_equal(s[0], raw.read_u8_at(199))
    assert_equal(s[1], raw.read_u8_at(200))
    assert_equal(s[2], raw.read_u8_at(201))
    assert_equal(len(_slice_body_bytes(raw, 5, 0)), 0)


# ---------------------------------------------------------------------------
# Internal sinks
# ---------------------------------------------------------------------------


def test_internal_sinks_count_bytes() raises:
    var null_sink = _NullBodySink()
    assert_equal(null_sink.bytes_written(), 0)
    null_sink.write_u8_at(4, UInt8(1))
    assert_equal(null_sink.bytes_written(), 5)
    # A write below the high-water mark does not lower it.
    null_sink.write_u8_at(1, UInt8(1))
    assert_equal(null_sink.bytes_written(), 5)
    var inner = AlignedBufferBodySink(64)
    inner.write_u8_at(0, UInt8(7))
    inner.write_u8_at(1, UInt8(7))
    comptime O = origin_of(inner)
    var off = _BodyOffsetSink[AlignedBufferBodySink, O](Pointer(to=inner), 8)
    # Two header bytes are below the offset: the body has none yet.
    assert_equal(off.bytes_written(), 0)
    off.write_u8_at(2, UInt8(9))
    assert_equal(off.bytes_written(), 3)
    assert_equal(off.capacity(), inner.capacity())


# ---------------------------------------------------------------------------
# Flatbuffer
# ---------------------------------------------------------------------------


def test_read_string_reads_what_write_string_wrote() raises:
    var w = FlatbufWriter(256)
    var sp = w.write_string("komira")
    var tb = start_table()
    add_field_offset(tb, 0, sp)
    var pos = end_table(w, tb^)
    var buf = w^.finalize(pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    var vt = root - Int(r.read_i32_le(root))
    var slot = root + Int(r.read_u16_le(vt + 4))
    assert_equal(r.read_string(slot), String("komira"))


def test_field_less_type_tables() raises:
    var w = FlatbufWriter(512)
    var a = write_type_large_list(w)
    var b = write_type_utf8_view(w)
    var c = write_type_list_view(w)
    var d = write_type_large_list_view(w)
    var outer = start_table()
    add_field_offset(outer, 0, a)
    add_field_offset(outer, 1, b)
    add_field_offset(outer, 2, c)
    add_field_offset(outer, 3, d)
    var pos = end_table(w, outer^)
    var buf = w^.finalize(pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    for k in range(4):
        var t = _read_table_field_offset(r, root, k)
        assert_true(t > 0)
        # No field: the vtable is [u16 size = 4, u16 inline size].
        var vt = t - Int(r.read_i32_le(t))
        assert_equal(Int(r.read_u16_le(vt)), 4)


# ---------------------------------------------------------------------------
# c_data_stream
# ---------------------------------------------------------------------------


def test_build_column_schema() raises:
    var v = List[Int64]()
    v.append(1)
    var col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(v)
    )
    var s = _build_column_schema(col, String("x"), True)
    assert_equal(_c_str_to_mojo(s.format), String("l"))
    assert_equal(_c_str_to_mojo(s.name), String("x"))
    assert_equal(s.flags, ARROW_FLAG_NULLABLE)
    assert_equal(s.n_children, Int64(0))
    assert_true(not s.is_released())
    var s2 = _build_column_schema(col, String("y"), False)
    assert_equal(s2.flags, Int64(0))
    release_c_schema(UnsafePointer(to=s).unsafe_origin_cast[MutUntrackedOrigin]())
    release_c_schema(UnsafePointer(to=s2).unsafe_origin_cast[MutUntrackedOrigin]())


def test_parse_small_uint() raises:
    assert_equal(_parse_small_uint(String("12")), 12)
    assert_equal(_parse_small_uint(String(" \t305\t ")), 305)
    assert_equal(_parse_small_uint(String("0")), 0)
    assert_equal(_parse_small_uint(String("")), -1)
    assert_equal(_parse_small_uint(String("  ")), -1)
    assert_equal(_parse_small_uint(String("1a")), -1)
    assert_equal(_parse_small_uint(String("/")), -1)
    assert_equal(_parse_small_uint(String(":")), -1)


def test_arrow_type_to_dtype() raises:
    var rows = List[Tuple[ArrowType, DType]]()
    rows.append((ArrowType.BOOL, DType.bool))
    rows.append((ArrowType.INT8, DType.int8))
    rows.append((ArrowType.INT16, DType.int16))
    rows.append((ArrowType.INT32, DType.int32))
    rows.append((ArrowType.DATE32, DType.int32))
    rows.append((ArrowType.TIME32_S, DType.int32))
    rows.append((ArrowType.TIME32_MS, DType.int32))
    rows.append((ArrowType.INTERVAL_YEAR_MONTH, DType.int32))
    rows.append((ArrowType.INT64, DType.int64))
    rows.append((ArrowType.DATE64, DType.int64))
    rows.append((ArrowType.TIMESTAMP_MS, DType.int64))
    rows.append((ArrowType.TIME64_US, DType.int64))
    rows.append((ArrowType.TIME64_NS, DType.int64))
    rows.append((ArrowType.DURATION_S, DType.int64))
    rows.append((ArrowType.INTERVAL_DAY_TIME, DType.int64))
    rows.append((ArrowType.UINT8, DType.uint8))
    rows.append((ArrowType.UINT16, DType.uint16))
    rows.append((ArrowType.UINT32, DType.uint32))
    rows.append((ArrowType.UINT64, DType.uint64))
    rows.append((ArrowType.FLOAT16, DType.float16))
    rows.append((ArrowType.FLOAT32, DType.float32))
    rows.append((ArrowType.FLOAT64, DType.float64))
    rows.append((ArrowType.STRING, DType.int64))
    for i in range(len(rows)):
        assert_equal(_arrow_type_to_dtype(rows[i][0]), rows[i][1], String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
