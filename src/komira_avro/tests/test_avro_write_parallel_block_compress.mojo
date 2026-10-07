# =============================================================================
# test_avro_write_parallel_block_compress.mojo
# =============================================================================
#
# Acceptance for the per-block parallel compress path: a write that goes through
# `write_avro_bytes_with_dispatcher` must SELF-ROUND-TRIP through
# `read_avro_bytes` (decode produces the original RecordBatch) across every
# codec, AND must produce the SAME logical content as the serial path
# (`write_avro_bytes`) when both write the same batch with the same options
# (file bytes may differ by sync marker — generated freshly each call from OS
# entropy — but the decoded RecordBatch must be identical).
#
# This is the load-bearing parallel-WRITE byte-identity gate. If this test ever
# broke, `ctx.write_avro` would silently emit corrupt OCF (block frame
# misordered / dropped / compressed-payload-not-matching-object-count).
#
# Why no fixed-sync-marker entry: the marker is generated INTERNALLY in both
# entries (serial + parallel) via OS entropy. Bytes-of-output differ between
# any two runs even of the same writer entry. Decoded-RecordBatch equality is
# the canonical correctness contract.
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

from komira_avro import (
    AvroWriterOptions,
    write_avro_bytes,
    write_avro_bytes_with_dispatcher,
    read_avro_bytes,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_ZSTANDARD,
)


# =============================================================================
# Fixture: multi-block batch (deliberately exceed AVRO_DEFAULT_BLOCK_SIZE_BYTES
# of 64 KiB so the parallel path actually fans out across multiple blocks).
# =============================================================================
#
# 6,000 rows × ~50 b/row INT64 + STRING-of-12 = ~300 KB raw → ~5+ blocks at
# 64 KiB block size → enough fan-out to exercise the stride partition with
# multiple worker tasks.


def _build_multi_block_batch(n_rows: Int) raises -> RecordBatch:
    var schema = SchemaBuilder()
    schema.add_field(Field("idx", ArrowType.INT64, True))
    schema.add_field(Field("dbl", ArrowType.FLOAT64, True))
    schema.add_field(Field("name", ArrowType.STRING, True))

    var idx_arr = PrimitiveArray[DType.int64].allocate(n_rows)
    var dbl_arr = PrimitiveArray[DType.float64].allocate(n_rows)
    var names = List[String]()
    for i in range(n_rows):
        idx_arr.set(i, Int64(i))
        # Deterministic Float64 with no NaN: i * 1.25 + 0.5
        dbl_arr.set(i, Float64(i) * 1.25 + 0.5)
        # 12-char strings to inflate row width (push past block-size more
        # quickly so we get many blocks within the test row count).
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
            Int(ai.get(i)), Int(ei.get(i)), "idx mismatch row " + String(i)
        )
        assert_true(
            ad.get(i) == ed.get(i), "dbl mismatch row " + String(i)
        )
        assert_equal(
            ans.get(i), ens.get(i), "name mismatch row " + String(i)
        )


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    """RAII runtime ctor — mirrors EngineContext's default construction
    (BACKEND_MOCK, fixed placement, 4 workers for test determinism)."""
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _roundtrip_via_parallel_path(
    codec: Int, n_rows: Int, label: String
) raises:
    """Build a batch, write via the PARALLEL dispatcher entry, read back via
    the serial reader, assert byte-for-byte equal to the original batch."""
    var rb = _build_multi_block_batch(n_rows)

    var rt = _make_runtime()
    ref disp = rt.dispatcher()
    var tok = CancellationToken.never()

    var opts = AvroWriterOptions(codec)
    var bytes = write_avro_bytes_with_dispatcher[origin_of(disp)](
        rb, opts, Pointer(to=disp), tok^,
    )
    assert_true(
        len(bytes) > 4, label + ": parallel output is non-empty"
    )
    # OCF magic prefix sanity.
    assert_equal(Int(bytes[0]), Int(ord("O")), label + ": magic[0]")
    assert_equal(Int(bytes[1]), Int(ord("b")), label + ": magic[1]")
    assert_equal(Int(bytes[2]), Int(ord("j")), label + ": magic[2]")
    assert_equal(Int(bytes[3]), 1, label + ": magic[3] (version)")

    var decoded = read_avro_bytes(bytes)
    _assert_batches_equal(decoded, rb)

    # Compare against the serial path's decoded result (BOTH should round-trip
    # to the same RecordBatch; the file bytes differ only by sync marker).
    var rb2 = _build_multi_block_batch(n_rows)
    var bytes_serial = write_avro_bytes(rb2, opts)
    var decoded_serial = read_avro_bytes(bytes_serial)
    _assert_batches_equal(decoded_serial, decoded)


def test_parallel_null_codec_roundtrip() raises:
    """Parallel-path NULL codec: takes the fast raw-frame path (no per-block
    compress). Output must round-trip byte-for-byte at the RecordBatch level."""
    _roundtrip_via_parallel_path(AVRO_CODEC_NULL, 6000, "null-parallel")


def test_parallel_snappy_codec_roundtrip() raises:
    """Parallel-path SNAPPY codec — the load-bearing per-block parallel
    compress path. 6,000 rows × ~50 b/row → multi-block layout (>= 5 blocks
    at 64 KiB default block size). Validates: (a) all blocks land in INDEX
    order; (b) compressed payload per block is correct; (c) decode produces
    the original RecordBatch."""
    _roundtrip_via_parallel_path(AVRO_CODEC_SNAPPY, 6000, "snappy-parallel")


def test_parallel_zstandard_codec_roundtrip() raises:
    """Parallel-path ZSTANDARD codec — different codec, same parallel path."""
    _roundtrip_via_parallel_path(
        AVRO_CODEC_ZSTANDARD, 6000, "zstd-parallel"
    )


def test_parallel_deflate_codec_roundtrip() raises:
    """Parallel-path DEFLATE codec — third codec to lock in the
    codec-agnostic shape of the parallel dispatch."""
    _roundtrip_via_parallel_path(
        AVRO_CODEC_DEFLATE, 6000, "deflate-parallel"
    )


def test_parallel_small_batch_below_threshold() raises:
    """Below `_MIN_PARALLEL_COMPRESS_BLOCKS` blocks the helper falls back to
    a SERIAL per-block compress loop (same code path, just no dispatch). A
    20-row batch fits in 1 block — the parallel entry must short-circuit
    correctly without dispatching."""
    _roundtrip_via_parallel_path(AVRO_CODEC_SNAPPY, 20, "snappy-1block")


def test_parallel_empty_batch_short_circuit() raises:
    """0-row batch: parallel entry must produce a valid 0-block OCF (header +
    no blocks) without dispatching. Reader gets back a 0-row RecordBatch."""
    var rb = _build_multi_block_batch(0)
    var rt = _make_runtime()
    ref disp = rt.dispatcher()
    var tok = CancellationToken.never()

    var opts = AvroWriterOptions(AVRO_CODEC_SNAPPY)
    var bytes = write_avro_bytes_with_dispatcher[origin_of(disp)](
        rb, opts, Pointer(to=disp), tok^,
    )
    var decoded = read_avro_bytes(bytes)
    assert_equal(decoded.num_rows(), 0, "0-row roundtrip")
    assert_equal(decoded.num_columns(), 3, "schema preserved on empty")


def main() raises:
    test_parallel_null_codec_roundtrip()
    test_parallel_snappy_codec_roundtrip()
    test_parallel_zstandard_codec_roundtrip()
    test_parallel_deflate_codec_roundtrip()
    test_parallel_small_batch_below_threshold()
    test_parallel_empty_batch_short_circuit()
    print(
        "OK: test_avro_write_parallel_block_compress — 6/6 PASS"
    )
