# =============================================================================
# test_orc_dispatcher_and_file_io.mojo — the dispatcher-backed column decode,
# the file read / write entry points, and the small public helpers no other
# test calls.
# =============================================================================
#
#   T1  read_orc_bytes_with_dispatcher / _opts_with_dispatcher /
#       _projected_with_dispatcher decode a 3-stripe, 3-column file to the
#       same values as the serial read (projection in caller order, a
#       repeated index read once).
#   T2  A column whose DATA stream does not decode fails the dispatcher read
#       with that column's error, named by output column.
#   T3  write_orc_file / write_orc_file_with_dispatcher and read_orc_file /
#       read_orc_file_opts / read_orc_file_with_dispatcher round-trip through
#       this run's scratch directory; the two writers write the same bytes.
#   T4  OrcWriterOptions.default() and .copy(); encode_vulong (read back by
#       OrcIntReader); OrcBloomFilter.copy() is independent of its source.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED
from komira_runtime_paths import test_tmpdir

from komira_orc import (
    OrcWriterOptions,
    OrcIntReader,
    OrcBloomFilter,
    write_orc_bytes,
    write_orc_file,
    write_orc_file_with_dispatcher,
    read_orc_bytes,
    read_orc_bytes_with_dispatcher,
    read_orc_bytes_opts_with_dispatcher,
    read_orc_bytes_projected_with_dispatcher,
    read_orc_file,
    read_orc_file_opts,
    read_orc_file_with_dispatcher,
    encode_vulong,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)

comptime N = 25


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var a = PrimitiveArray[DType.int64].allocate(N)
    var d = PrimitiveArray[DType.float64].allocate(N)
    var ss = List[String]()
    for i in range(N):
        a.set(i, Int64(i * 7 - 50))
        d.set(i, Float64(i) * 0.25)
        ss.append(String("v") + String(i))
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    b.add_column(Column.from_primitive[DType.float64](d^))
    b.add_column(Column.from_string(StringArray.from_strings(ss)))
    return b.build(sb.build())


def _check_full(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), N, label + ": rows")
    assert_equal(rb.num_columns(), 3, label + ": columns")
    var a = rb.column_as_primitive_int64(0)
    var d = rb.column_as_primitive_float64(1)
    var s = rb.column_as_string(2)
    for i in range(N):
        assert_equal(Int(a.get(i)), i * 7 - 50, label + ": id")
        assert_equal(d.get(i), Float64(i) * 0.25, label + ": x")
        assert_equal(s.get(i), String("v") + String(i), label + ": s")


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=3,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


# -----------------------------------------------------------------------------
# T1 / T2 — dispatcher-backed reads.
# -----------------------------------------------------------------------------


def test_dispatcher_reads() raises:
    var rt = _runtime()
    ref disp = rt.dispatcher()
    for c in range(2):
        var codec = ORC_COMPRESSION_NONE if c == 0 else ORC_COMPRESSION_ZSTD
        var label = String("NONE") if c == 0 else String("ZSTD")
        # 10-row stripes: 3 stripes (10 / 10 / 5).
        var file = write_orc_bytes(_batch(), OrcWriterOptions(codec, 10, "UTC"))
        _check_full(read_orc_bytes(Span(file)), label + " serial")
        _check_full(
            read_orc_bytes_with_dispatcher[origin_of(disp)](
                Span(file), Pointer(to=disp), CancellationToken.never()
            ),
            label + " dispatcher",
        )
        _check_full(
            read_orc_bytes_opts_with_dispatcher[origin_of(disp)](
                Span(file), True, Pointer(to=disp), CancellationToken.never()
            ),
            label + " opts dispatcher",
        )
        var proj = List[Int]()
        proj.append(2)
        proj.append(0)
        proj.append(2)
        var p = read_orc_bytes_projected_with_dispatcher[origin_of(disp)](
            Span(file), proj, Pointer(to=disp), CancellationToken.never()
        )
        assert_equal(p.num_columns(), 2, label + ": projected columns")
        assert_equal(p.schema.field_name(0), "s", label + ": projected order")
        assert_equal(p.schema.field_name(1), "id", label + ": projected order")
        assert_equal(p.column_as_string(0).get(24), "v24", label + ": projected s")
        assert_equal(Int(p.column_as_primitive_int64(1).get(24)), 118, label + ": projected id")
    _ = rt^


def test_dispatcher_column_failure() raises:
    # One bigint column, one 4-row stripe, NONE codec: the DATA stream starts
    # right after the 3-byte header. A SHORT_REPEAT header of 10 values there
    # (0x07) overruns the 4-row column.
    var a = PrimitiveArray[DType.int64].allocate(4)
    for i in range(4):
        a.set(i, Int64(i * 1000))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    var file = write_orc_bytes(b.build(sb.build()), OrcWriterOptions(ORC_COMPRESSION_NONE, 10, "UTC"))
    assert_equal(Int(read_orc_bytes(Span(file)).column_as_primitive_int64(0).get(3)), 3000)
    file[3] = 0x07
    var rt = _runtime()
    ref disp = rt.dispatcher()
    with assert_raises(
        contains="OrcDecodeError: column-parallel decode of output column 0 failed: OrcRleError.RUN_OVERRUN"
    ):
        _ = read_orc_bytes_with_dispatcher[origin_of(disp)](
            Span(file), Pointer(to=disp), CancellationToken.never()
        )
    _ = rt^


# -----------------------------------------------------------------------------
# T3 — file entry points.
# -----------------------------------------------------------------------------


def _read_all(path: String) raises -> List[UInt8]:
    from komira_arrow_ipc.chunked_read import read_chunked

    var buf = read_chunked(path)
    var view = buf.view_range_ro(0, buf.len()).into_span()
    var out = List[UInt8]()
    for i in range(len(view)):
        out.append(view[i])
    return out^


def test_file_entry_points() raises:
    var dir = test_tmpdir()
    var serial_path = dir + "/serial.orc"
    var par_path = dir + "/dispatcher.orc"
    var opts = OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10, "UTC")
    write_orc_file(_batch(), serial_path, opts)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    write_orc_file_with_dispatcher[origin_of(disp)](
        _batch(), par_path, opts, Pointer(to=disp), CancellationToken.never()
    )
    var s_bytes = _read_all(serial_path)
    var p_bytes = _read_all(par_path)
    assert_equal(len(s_bytes), len(p_bytes))
    for i in range(len(s_bytes)):
        assert_equal(s_bytes[i], p_bytes[i], "writers differ at byte " + String(i))
    var mem = write_orc_bytes(_batch(), opts)
    assert_equal(len(mem), len(s_bytes))

    _check_full(read_orc_file(serial_path), "read_orc_file")
    _check_full(read_orc_file_opts(par_path, False), "read_orc_file_opts")
    _check_full(
        read_orc_file_with_dispatcher[origin_of(disp)](
            serial_path, Pointer(to=disp), CancellationToken.never()
        ),
        "read_orc_file_with_dispatcher",
    )
    _ = rt^


# -----------------------------------------------------------------------------
# T4 — small helpers.
# -----------------------------------------------------------------------------


def test_small_helpers() raises:
    var d = OrcWriterOptions.default()
    assert_equal(d.compression, ORC_COMPRESSION_ZSTD)
    assert_equal(d.row_index_stride, 10000)
    assert_equal(d.stripe_size_rows, 10000)
    assert_false(d.emit_row_index)
    assert_equal(d.writer_timezone, "UTC")

    var names = List[String]()
    names.append("a")
    var o = OrcWriterOptions.with_bloom(ORC_COMPRESSION_NONE, 5, 20, names^, 0.05)
    var c = o.copy()
    assert_equal(c.compression, ORC_COMPRESSION_NONE)
    assert_equal(c.row_index_stride, 5)
    assert_equal(c.stripe_size_rows, 20)
    assert_true(c.emit_row_index)
    assert_equal(len(c.bloom_columns), 1)
    assert_equal(c.bloom_columns[0], "a")
    assert_equal(c.bloom_fpp, 0.05)

    var buf = List[UInt8]()
    encode_vulong(buf, 0)
    encode_vulong(buf, 300)
    encode_vulong(buf, UInt64.MAX)
    assert_equal(len(buf), 1 + 2 + 10)
    assert_equal(Int(buf[1]), 0xAC)
    assert_equal(Int(buf[2]), 0x02)
    var r = OrcIntReader(Span(buf))
    assert_equal(r.read_vulong(), 0)
    assert_equal(r.read_vulong(), 300)
    assert_equal(r.read_vulong(), UInt64.MAX)

    var bf = OrcBloomFilter(3, 2)
    bf.add_long(77)
    var cp = bf.copy()
    assert_true(cp.test_long(77))
    assert_equal(cp.num_hash_functions, 3)
    assert_equal(len(cp.bitset), 16)
    cp.add_long(12345)
    var differs = False
    for i in range(16):
        if cp.bitset[i] != bf.bitset[i]:
            differs = True
    assert_true(differs, "adding to the copy changed nothing, or changed the source too")


def main() raises:
    test_dispatcher_reads()
    test_dispatcher_column_failure()
    test_file_entry_points()
    test_small_helpers()
    print("test_orc_dispatcher_and_file_io: ALL PASS")
