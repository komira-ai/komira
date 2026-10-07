# =============================================================================
# test_orc_write_parallel_stream_compress.mojo
# Parallel per-stream compress is byte-identical to the serial writer.
# =============================================================================
#
# Acceptance for the per-stream parallel compress path: a write that goes
# through `write_orc_bytes_with_dispatcher` must SELF-ROUND-TRIP through
# `read_orc_bytes` AND must produce BYTE-IDENTICAL bytes versus the serial
# entry `write_orc_bytes` for the same RecordBatch + options.
#
# This is the load-bearing parallel-WRITE byte-identity gate. If this test ever
# broke, a dispatcher-backed ORC write would silently emit corrupt ORC (stream
# proto misordered / dropped / compressed-payload-not-matching-length).
#
# The same collect-then-parallel-compress shape as the Avro writer's parallel
# block compress, over streams instead of blocks.
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

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    write_orc_bytes_with_dispatcher,
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_LZ4,
)


# =============================================================================
# Fixture: multi-stripe batch (deliberately exceed row_index_stride so the
# parallel path actually fans out across stripes; each stripe has ~30 streams
# at 21 columns × {PRESENT? + DATA + LENGTH?}).
# =============================================================================
#
# 35000 rows × 3 columns at row_index_stride=10000 → 4 stripes × ~9 streams =
# ~36 streams total. Each stripe's stream count clears the
# _MIN_PARALLEL_COMPRESS_STREAMS=4 threshold so the parallel dispatch fires.


def _build_multi_stripe_batch(n_rows: Int) raises -> RecordBatch:
    var schema = SchemaBuilder()
    schema.add_field(Field("idx", ArrowType.INT64, True))
    schema.add_field(Field("dbl", ArrowType.FLOAT64, True))
    schema.add_field(Field("name", ArrowType.STRING, True))

    var idx_arr = PrimitiveArray[DType.int64].allocate(n_rows)
    var dbl_arr = PrimitiveArray[DType.float64].allocate(n_rows)
    var names = List[String]()
    for i in range(n_rows):
        idx_arr.set(i, Int64(i))
        dbl_arr.set(i, Float64(i) * 1.25 + 0.5)
        names.append(String("row_") + String(i) + String("_xx"))
    var str_arr = StringArray.from_strings(names)

    var builder = RecordBatchBuilder.with_capacity(n_rows)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            idx_arr^, ArrowType.INT64
        )
    )
    builder.add_column(Column.from_primitive[DType.float64](dbl_arr^))
    builder.add_column(Column.from_string(str_arr^))
    return builder.build(schema.build())


def _assert_batches_equal(actual: RecordBatch, expected: RecordBatch) raises:
    assert_equal(
        actual.num_columns(), expected.num_columns(), "num_columns mismatch"
    )
    assert_equal(actual.num_rows(), expected.num_rows(), "num_rows mismatch")

    var n = actual.num_rows()
    var ai = actual.column_as_primitive_int64(0)
    var ei = expected.column_as_primitive_int64(0)
    var ad = actual.column_as_primitive_float64(1)
    var ed = expected.column_as_primitive_float64(1)
    var ans = actual.column_as_string(2)
    var ens = expected.column_as_string(2)
    for i in range(n):
        assert_equal(
            Int(ai.get(i)), Int(ei.get(i)),
            "idx mismatch row " + String(i),
        )
        assert_true(
            ad.get(i) == ed.get(i), "dbl mismatch row " + String(i)
        )
        assert_equal(
            ans.get(i), ens.get(i),
            "name mismatch row " + String(i),
        )


def _assert_bytes_equal(
    a: List[UInt8], b: List[UInt8], label: String
) raises:
    """Byte-for-byte equality assertion — the load-bearing parallel-byte-identity
    contract. Either entry produces the same on-disk bytes for the same batch +
    opts (no random padding; deterministic stripe/stream encode order)."""
    assert_equal(
        len(a), len(b), label + ": output byte-length mismatch"
    )
    for i in range(len(a)):
        if a[i] != b[i]:
            assert_true(False, label + ": byte mismatch at offset " + String(i))


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _roundtrip_via_parallel_path(
    batch: RecordBatch, compression: Int
) raises -> RecordBatch:
    """Drive `write_orc_bytes_with_dispatcher` end-to-end with a fresh runtime
    + 4-worker dispatcher + read-back through `read_orc_bytes`. Returns the
    decoded RecordBatch for caller assertions."""
    # Spin up a small runtime so we have a real LocalDispatcher.
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var tok = CancellationToken.never()

    var opts = OrcWriterOptions(compression, 10000, String("UTC"))
    var bytes_par = write_orc_bytes_with_dispatcher[origin_of(disp)](
        batch, opts, Pointer(to=disp), tok^,
    )

    # Byte-identity gate: identical to serial path.
    var bytes_ser = write_orc_bytes(batch, opts)
    _assert_bytes_equal(
        bytes_par, bytes_ser, "parallel-vs-serial byte identity"
    )

    # SELF-ROUND-TRIP gate: decoded RecordBatch matches input.
    var decoded = read_orc_bytes(bytes_par)
    _ = rt^
    return decoded^


def test_parallel_none_codec_byte_identity_and_roundtrip() raises:
    var batch = _build_multi_stripe_batch(35000)
    var decoded = _roundtrip_via_parallel_path(batch, ORC_COMPRESSION_NONE)
    _assert_batches_equal(decoded, batch)


def test_parallel_zstd_codec_byte_identity_and_roundtrip() raises:
    var batch = _build_multi_stripe_batch(35000)
    var decoded = _roundtrip_via_parallel_path(batch, ORC_COMPRESSION_ZSTD)
    _assert_batches_equal(decoded, batch)


def test_parallel_small_batch_below_threshold() raises:
    """Single-stripe small batch — n_streams may be below threshold; the
    parallel helper falls back to serial fallback inside
    `compress_streams_parallel`. Byte-identity must still hold."""
    var batch = _build_multi_stripe_batch(20)

    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var tok = CancellationToken.never()

    var opts = OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, String("UTC"))
    var bytes_par = write_orc_bytes_with_dispatcher[origin_of(disp)](
        batch, opts, Pointer(to=disp), tok^,
    )
    var bytes_ser = write_orc_bytes(batch, opts)
    _assert_bytes_equal(bytes_par, bytes_ser, "small-batch byte identity")

    var decoded = read_orc_bytes(bytes_par)
    _assert_batches_equal(decoded, batch)
    _ = rt^


def test_parallel_multistripe_byte_identity() raises:
    """Many-stripe batch (15+ stripes) — exercises the per-stripe parallel
    dispatch path in a loop; each stripe's stream collection is independent;
    byte-identity must hold across all stripes."""
    var batch = _build_multi_stripe_batch(150000)  # ~15 stripes

    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var tok = CancellationToken.never()

    var opts = OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, String("UTC"))
    var bytes_par = write_orc_bytes_with_dispatcher[origin_of(disp)](
        batch, opts, Pointer(to=disp), tok^,
    )
    var bytes_ser = write_orc_bytes(batch, opts)
    _assert_bytes_equal(bytes_par, bytes_ser, "multi-stripe byte identity")

    var decoded = read_orc_bytes(bytes_par)
    _assert_batches_equal(decoded, batch)
    _ = rt^


def main() raises:
    test_parallel_none_codec_byte_identity_and_roundtrip()
    test_parallel_zstd_codec_byte_identity_and_roundtrip()
    test_parallel_small_batch_below_threshold()
    test_parallel_multistripe_byte_identity()
    print("All parallel ORC stream compress tests passed.")
