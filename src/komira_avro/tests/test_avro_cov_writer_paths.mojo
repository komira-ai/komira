# =============================================================================
# test_avro_cov_writer_paths.mojo -- the writer's control paths: the timing
# report on each pipeline (null inline, serial compress, parallel compress),
# an empty schema, a zero-row batch, the null-codec arms of both finalize
# passes, and the file entry points.
# =============================================================================
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   P1  with `print_timing` on, the null, serial-deflate and parallel-deflate
#       pipelines each produce a file that reads back to the input, in the
#       expected number of blocks (the timing lines only add to counters
#       that are printed; no assertion can see them, the case proves they do
#       not change the bytes). Mutant: the null inline path's trailing
#       partial block `block_rows > 0` -> `> 1`: red, 2 blocks vs 3.
#   P2  a batch with no columns is refused before any byte is written; a
#       zero-row batch writes a header and no block. Mutant: the writer's
#       own empty-schema check made False: red, the schema emitter's
#       "AvroSchemaError.EMPTY_SCHEMA" vs "AvroWriteError.EMPTY_SCHEMA".
#   P3  the null-codec arms of `_finalize_blocks_serial` and
#       `_finalize_blocks_parallel` frame each raw block unchanged: a header
#       plus their output reads back to the batch, and the two are byte-
#       identical. (The public entry points send the null codec down the
#       inline path, so only a direct call reaches these arms.) Mutant: the
#       serial arm frames `object_counts[0]` for every block: red,
#       "TRUNCATED: long varint overrun".
#   P4  write_avro_file / write_avro_file_with_dispatcher write a stream that
#       read_avro_file reads back. Mutant: the file write keeps half the
#       bytes: red, "TRUNCATED_HEADER: metadata value ... declares length".
# =============================================================================

from std.testing import assert_equal, assert_true

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

from komira_avro import (
    AvroWriterOptions,
    write_avro_bytes,
    write_avro_bytes_with_dispatcher,
    write_avro_file,
    write_avro_file_with_dispatcher,
    read_avro_bytes,
    read_avro_file,
    scan_ocf_blocks,
    emit_ocf_header,
    from_arrow_schema_json,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    OCF_SYNC_LEN,
)
from komira_avro.avro_ocf_writer import (
    _encode_row_loop_to_blocks,
    _finalize_blocks_serial,
    _finalize_blocks_parallel,
)


def _batch(n: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, True))
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var names = List[String]()
    for i in range(n):
        ids.set(i, Int64(i * 1000 - 7))
        names.append(String("n") + String(i))
    var bb = RecordBatchBuilder.with_capacity(2)
    bb.add_column(Column.from_primitive[DType.int64](ids^))
    bb.add_column(Column.from_string(StringArray.from_strings(names)))
    return bb.build(sb.build())


def _check(rb: RecordBatch, n: Int, label: String) raises:
    assert_equal(rb.num_rows(), n, label + " rows")
    var ids = rb.column_as_primitive_int64(0)
    var names = rb.column_as_string(1)
    for i in range(n):
        assert_equal(Int(ids.get(i)), i * 1000 - 7, label + " id")
        assert_equal(names.get(i), String("n") + String(i), label + " name")


def _opts(codec: Int, timing: Bool) -> AvroWriterOptions:
    return AvroWriterOptions(
        codec, 1 << 20, 2, True, String("R"), True, timing
    )


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def test_timing_on_every_pipeline() raises:
    """P1."""
    var rb = _batch(5)
    var null_bytes = write_avro_bytes(rb, _opts(AVRO_CODEC_NULL, True))
    assert_equal(len(scan_ocf_blocks(Span(null_bytes))), 3, "null blocks")
    _check(read_avro_bytes(Span(null_bytes)), 5, "null+timing")
    var def_bytes = write_avro_bytes(rb, _opts(AVRO_CODEC_DEFLATE, True))
    assert_equal(len(scan_ocf_blocks(Span(def_bytes))), 3, "deflate blocks")
    _check(read_avro_bytes(Span(def_bytes)), 5, "deflate+timing")
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var big = _batch(11)
    var par_bytes = write_avro_bytes_with_dispatcher[origin_of(disp)](
        big,
        _opts(AVRO_CODEC_DEFLATE, True),
        Pointer(to=disp),
        CancellationToken.never(),
    )
    assert_equal(len(scan_ocf_blocks(Span(par_bytes))), 6, "parallel blocks")
    _check(read_avro_bytes(Span(par_bytes)), 11, "parallel+timing")


def test_empty_schema_and_zero_rows() raises:
    """P2."""
    var no_fields = SchemaBuilder()
    var no_cols = RecordBatchBuilder.with_capacity(0)
    var empty = no_cols.build(no_fields.build())
    var got = String("(accepted)")
    try:
        _ = write_avro_bytes(empty, AvroWriterOptions(AVRO_CODEC_NULL))
    except e:
        got = String(e)
    assert_equal(got, "AvroWriteError.EMPTY_SCHEMA: RecordBatch has no columns")
    var zero = _batch(0)
    var bytes = write_avro_bytes(zero, _opts(AVRO_CODEC_NULL, False))
    assert_equal(len(scan_ocf_blocks(Span(bytes))), 0, "no block")
    var header = List[UInt8]()
    var sync = Array[UInt8, OCF_SYNC_LEN](fill=0)
    emit_ocf_header(
        from_arrow_schema_json(zero.schema, String("R"), True),
        AVRO_CODEC_NULL,
        sync,
        header,
    )
    assert_equal(len(bytes), len(header), "header only")
    assert_equal(read_avro_bytes(Span(bytes)).num_rows(), 0)


def _sync() -> Array[UInt8, OCF_SYNC_LEN]:
    var s = Array[UInt8, OCF_SYNC_LEN](fill=0)
    for i in range(OCF_SYNC_LEN):
        s[i] = UInt8(0x30 + i)
    return s^


def _header_for(rb: RecordBatch) raises -> List[UInt8]:
    var out = List[UInt8]()
    emit_ocf_header(
        from_arrow_schema_json(rb.schema, String("R"), True),
        AVRO_CODEC_NULL,
        _sync(),
        out,
    )
    return out^


def test_finalize_null_codec_arms() raises:
    """P3."""
    var rb = _batch(5)
    var opts = _opts(AVRO_CODEC_NULL, True)
    var serial = _header_for(rb)
    var enc = _encode_row_loop_to_blocks(rb, rb.schema, opts, True)
    _ = _finalize_blocks_serial(enc^, _sync(), opts, serial, True)
    assert_equal(len(scan_ocf_blocks(Span(serial))), 3, "serial blocks")
    _check(read_avro_bytes(Span(serial)), 5, "serial null finalize")

    var rt = _runtime()
    ref disp = rt.dispatcher()
    var par = _header_for(rb)
    var enc2 = _encode_row_loop_to_blocks(rb, rb.schema, opts, False)
    _ = _finalize_blocks_parallel[origin_of(disp)](
        enc2^, _sync(), opts, par, Pointer(to=disp),
        CancellationToken.never(), True,
    )
    assert_equal(len(par), len(serial), "same framing")
    for i in range(len(par)):
        assert_equal(Int(par[i]), Int(serial[i]), "byte " + String(i))


def test_file_entry_points() raises:
    """P4."""
    var rb = _batch(3)
    var dir = test_tmpdir()
    var p1 = dir + "/cov_writer_serial.avro"
    write_avro_file(rb, p1, _opts(AVRO_CODEC_DEFLATE, False))
    _check(read_avro_file(p1), 3, "file serial")
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var p2 = dir + "/cov_writer_parallel.avro"
    write_avro_file_with_dispatcher[origin_of(disp)](
        rb,
        p2,
        _opts(AVRO_CODEC_DEFLATE, False),
        Pointer(to=disp),
        CancellationToken.never(),
    )
    _check(read_avro_file(p2), 3, "file parallel")


def main() raises:
    test_timing_on_every_pipeline()
    test_empty_schema_and_zero_rows()
    test_finalize_null_codec_arms()
    test_file_entry_points()
    print("test_avro_cov_writer_paths: ALL PASS")
