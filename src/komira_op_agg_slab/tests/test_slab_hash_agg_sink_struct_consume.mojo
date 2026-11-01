# =============================================================================
# Tests -- SlabHashAggSinkStruct end to end, one aggregate and one key
# =============================================================================
#
# The sink is driven directly (init_global, init_local, consume per worker,
# combine, combine_partition for every partition, finalize), so a defect in
# any of those steps, or in the per-storage state strides `init_global`
# passes, shows in the output batch. One aggregate and one key take the
# fused consume path.
#
#   1. test_stddev_samp_consume_correctness -- 100K rows over 1000 Int64
#      keys, half to each of two workers; every group's STDDEV_SAMP matches a
#      Welford reference to 1e-9. Catches a lost or double-counted row, a
#      wrong partition merge, and keys and values emitted out of step.
#   2. test_stddev_samp_vs_scalar_count -- 100 rows over 5 keys split across
#      two workers; 5 groups after the merge, each stddev matching the
#      single-pass reference.
# =============================================================================

from std.collections import Array
from std.collections.optional import Optional
from std.math import sqrt
from std.memory import OwnedPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_collections.slab import Slab

from komira_plan_expr.agg_expr import AGG_STDDEV_SAMP, AggExpr
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)

from komira_op_agg_slab.slab_hash_agg_sink_struct_state import (
    N_PARTITIONS_SHAPE_B,
    SlabHashAggGlobal,
    SlabHashAggLocal,
)
from komira_op_agg_slab.slab_hash_agg_sink_struct import (
    SlabHashAggSinkStruct,
)
from komira_op_agg_state.aggregators_struct_builtin import (
    StddevSampAggregator,
    WelfordState,
)
from komira_operator_api.memory_reservation import MemoryReservation
from komira_operator_api.morsel_sink import MorselSink
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher


# =============================================================================
# Reference + helper math
# =============================================================================


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64 = 1e-9) -> Bool:
    """Float64 approx-equal with absolute + relative tolerance.

    Used to compare Welford-recurrence outputs across split-then-merge
    paths against the single-pass reference. m2 may differ in the last
    few ULPs due to op-order; relative tolerance handles that.
    """
    var diff = _abs(a - b)
    if diff <= tol:
        return True
    var mag = _abs(a) + _abs(b)
    return diff <= tol * mag


def _stddev_samp_reference(values: List[Float64]) -> Float64:
    """numpy.std(values, ddof=1)-equivalent reference via the same
    Welford recurrence the kernel uses (so split-then-merge is
    bit-comparable up to the merge-formula's ULP drift)."""
    var n = len(values)
    if n <= 1:
        return Float64(0.0) / Float64(0.0)  # NaN
    var s = WelfordState()
    for i in range(n):
        s.count += UInt64(1)
        var delta = values[i] - s.mean
        s.mean += delta / Float64(s.count)
        s.m2 += delta * (values[i] - s.mean)
    return sqrt(s.m2 / Float64(s.count - UInt64(1)))


# =============================================================================
# Fixture builders — RecordBatch + AggSinkData for STDDEV_SAMP(v) GROUP BY k
# =============================================================================


def _make_batch_keys_one_value(
    var keys: List[Int64], var values: List[Float64]
) raises -> RecordBatch:
    """Two-column batch: col 0 = Int64 'k', col 1 = Float64 'v'.

    Same shape used by the scalar-sink consume tests.
    """
    var n = len(keys)
    var k_arr = PrimitiveArray[DType.int64].allocate(n)
    var k_ptr = k_arr._typed_ptr_mut()
    for i in range(n):
        (k_ptr + i)[] = keys[i]

    var v_arr = PrimitiveArray[DType.float64].allocate(n)
    var v_ptr = v_arr._typed_ptr_mut()
    for i in range(n):
        (v_ptr + i)[] = values[i]

    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](k_arr^))
    b.add_column(Column.from_primitive[DType.float64](v_arr^))
    return b.build(sb.build())


def _agg_sink_data_stddev_samp() raises -> AggSinkData:
    """STDDEV_SAMP(v) GROUP BY k, built directly as an AggExpr."""
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    var none_alias: Optional[String] = None
    aggs.append(AggExpr(AGG_STDDEV_SAMP, col("v").copy_expr(), none_alias^))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.INT64, False))
    osb.add_field(Field("stddev_v", ArrowType.FLOAT64, False))
    return AggSinkData(group_by^, aggs^, osb.build(), False, 0)


def _empty_pq_data() raises -> ParquetSourceData:
    return ParquetSourceData(
        String(""),
        Optional[List[String]](None),
        Optional[Expr](None),
    )


# =============================================================================
# Sink factory + driver helper
# =============================================================================


comptime _COLS_STDDEV_AT_1: Array[Int, 8] = [1, -1, -1, -1, -1, -1, -1, -1]


def _new_sink_stddev(
    num_workers: Int,
) raises -> SlabHashAggSinkStruct[
        _COLS_STDDEV_AT_1, StddevSampAggregator,
    ]:
    """Single STDDEV_SAMP sink, parametric on worker count."""
    return SlabHashAggSinkStruct[
        _COLS_STDDEV_AT_1, StddevSampAggregator,
    ].new(
        _agg_sink_data_stddev_samp(),
        _empty_pq_data(),
        Slab[MorselOp](),
        num_workers=num_workers,
        key_col_idx=0,
    )


def _finalize_and_extract_batch[
    K: MorselSink, disp_o: Origin[mut=True]
](
    sink: K,
    var sink_global: K.Global,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> K.Output:
    """Drive `sink.finalize` and take its single output.

    Generic over `K: MorselSink` so `K.Output` is resolved through the
    trait rather than on the concrete sink type with its variadic pack.
    """
    var fr = sink.finalize(sink_global^, dispatcher_ptr, cancel_token^)
    if len(fr.output) != 1:
        raise Error(
            "_finalize_and_extract_batch: the sink returned output of"
            " length != 1. Expected exactly one Output."
        )
    var out = fr.output.take_slot_unchecked(0)
    fr.output.set_len_unchecked(0)
    _ = fr^
    return out^


def _drive_sink_two_workers(
    var batch_a: RecordBatch,
    var batch_b: RecordBatch,
) raises -> RecordBatch:
    """Drive the SlabHashAggSinkStruct end-to-end with TWO workers:
    init_global → per-worker init_local + consume → combine →
    combine_partition → finalize.

    Worker 0 consumes `batch_a`, worker 1 consumes `batch_b`. The
    two-worker shape exercises:
      - per-worker storage allocation in init_global with
        agg_state_strides_in plumbed,
      - per-worker partitioned probe/commit,
      - per-partition combine across two donors (last worker is
        survivor; w=0 is the donor).
    """
    var sink = _new_sink_stddev(num_workers=2)
    var sink_global = sink.init_global()

    var local_0 = sink.init_local()
    var local_1 = sink.init_local()

    sink.consume(0, local_0, sink_global, batch_a^)
    sink.consume(1, local_1, sink_global, batch_b^)

    # Build a Slab[OwnedPointer[Local]] for combine.
    var states = Slab[OwnedPointer[SlabHashAggLocal]]()
    states.append(OwnedPointer[SlabHashAggLocal](local_0^))
    states.append(OwnedPointer[SlabHashAggLocal](local_1^))

    var reservation = MemoryReservation()
    sink.combine(sink_global, states^, reservation)

    for p in range(N_PARTITIONS_SHAPE_B):
        sink.combine_partition(sink_global, p)

    # The sink's finalize uses neither the dispatcher nor the token; the
    # trait requires them.
    var disp = LocalDispatcher[NoopSink]()
    var ct = CancellationToken.never()
    var batch = _finalize_and_extract_batch(
        sink, sink_global^, Pointer(to=disp), ct^,
    )
    return batch^


# =============================================================================
# Test 1 — 100K rows × 1000 keys, multi-worker correctness
# =============================================================================


def test_stddev_samp_consume_correctness() raises:
    """100K rows × 1000 distinct Int64 keys × Float64 values from a
    deterministic formula. Drive multi-worker (2 workers, half rows
    each); verify per-group stddev_samp matches the reference within
    1e-9 relative tolerance.

    Value formula: `value(i) = sin(i * 0.001) * 100.0 + i * 0.5`
    is replaced with a deterministic non-trigonometric formula so the
    test does not depend on libm precision. We use a polynomial:
    `value(i) = (i * 0.5) + ((i % 17) * 0.125) - ((i % 31) * 0.07)`.
    Per-group rows are interleaved by `i % K`, so each group sees
    100 rows; 100 rows × 1000 groups = 100K total.
    """
    comptime N = 100_000
    comptime K = 1_000

    var keys = List[Int64](capacity=N)
    var values = List[Float64](capacity=N)
    # Precompute per-group reference value lists for the stddev_samp
    # reference function. Store one List per group; total memory ~800KB
    # (100K Float64 + per-group List headers).
    var per_group_values = List[List[Float64]]()
    for _ in range(K):
        per_group_values.append(List[Float64](capacity=N // K))

    for i in range(N):
        var k = i % K
        var v = (Float64(i) * 0.5
                 + Float64(i % 17) * 0.125
                 - Float64(i % 31) * 0.07)
        keys.append(Int64(k))
        values.append(v)
        per_group_values[k].append(v)

    # Split into two batches for two workers. Half the rows each.
    var half = N // 2
    var keys_a = List[Int64](capacity=half)
    var vals_a = List[Float64](capacity=half)
    var keys_b = List[Int64](capacity=N - half)
    var vals_b = List[Float64](capacity=N - half)
    for i in range(half):
        keys_a.append(keys[i])
        vals_a.append(values[i])
    for i in range(half, N):
        keys_b.append(keys[i])
        vals_b.append(values[i])
    _ = keys^
    _ = values^

    var batch_a = _make_batch_keys_one_value(keys_a^, vals_a^)
    var batch_b = _make_batch_keys_one_value(keys_b^, vals_b^)

    var out = _drive_sink_two_workers(batch_a^, batch_b^)

    # Verify shape: K rows, 2 columns (key, stddev_v).
    assert_equal(out.num_rows(), K)
    assert_equal(out.num_columns(), 2)

    # Pull out per-row (key, stddev) pairs and check each against
    # reference. Output ordering follows the partition + insertion
    # walk — we map by reading the key column.
    var key_arr = out.column_as_primitive_int64(0)
    var std_arr = out.column_as_primitive_float64(1)

    var seen = List[Bool](capacity=K)
    for _ in range(K):
        seen.append(False)

    for r in range(K):
        var k = Int(key_arr.get_typed[Int64](r))
        var std_actual = Float64(std_arr.get_typed[Float64](r))
        # Each key should appear exactly once.
        assert_true(0 <= k and k < K)
        assert_true(not seen[k])
        seen[k] = True
        var std_ref = _stddev_samp_reference(per_group_values[k])
        assert_true(_approx_equal(std_actual, std_ref, Float64(1e-9)))

    for k in range(K):
        assert_true(seen[k])

    _ = out^
    _ = per_group_values^


# =============================================================================
# Test 2 — small fixture, combine produces correct merged state
# =============================================================================


def test_stddev_samp_vs_scalar_count() raises:
    """100 rows × 5 keys; verify post-combine group count + stddev_samp
    match the reference for split-then-merge.

    Each key appears 20 times. Worker 0 sees rows 0..49 (10 rows per
    key), worker 1 sees rows 50..99 (10 rows per key). After combine,
    per-group state is the union of the two halves; finalize must
    produce stddev_samp values equal to the single-pass reference
    over the full 20-row sequence.
    """
    comptime N = 100
    comptime K = 5

    var keys = List[Int64](capacity=N)
    var values = List[Float64](capacity=N)
    var per_group_values = List[List[Float64]]()
    for _ in range(K):
        per_group_values.append(List[Float64](capacity=N // K))

    for i in range(N):
        var k = i % K
        var v = Float64(i) * 0.3 + Float64(k) * 1.7
        keys.append(Int64(k))
        values.append(v)
        per_group_values[k].append(v)

    # Split into two halves.
    var half = N // 2
    var keys_a = List[Int64](capacity=half)
    var vals_a = List[Float64](capacity=half)
    var keys_b = List[Int64](capacity=N - half)
    var vals_b = List[Float64](capacity=N - half)
    for i in range(half):
        keys_a.append(keys[i])
        vals_a.append(values[i])
    for i in range(half, N):
        keys_b.append(keys[i])
        vals_b.append(values[i])
    _ = keys^
    _ = values^

    var batch_a = _make_batch_keys_one_value(keys_a^, vals_a^)
    var batch_b = _make_batch_keys_one_value(keys_b^, vals_b^)

    var out = _drive_sink_two_workers(batch_a^, batch_b^)

    assert_equal(out.num_rows(), K)
    assert_equal(out.num_columns(), 2)

    var key_arr = out.column_as_primitive_int64(0)
    var std_arr = out.column_as_primitive_float64(1)

    var seen = List[Bool](capacity=K)
    for _ in range(K):
        seen.append(False)

    for r in range(K):
        var k = Int(key_arr.get_typed[Int64](r))
        var std_actual = Float64(std_arr.get_typed[Float64](r))
        assert_true(0 <= k and k < K)
        assert_true(not seen[k])
        seen[k] = True
        var std_ref = _stddev_samp_reference(per_group_values[k])
        # Both halves merge via Chan-merge; reference is single-pass
        # over the full sequence. ULP drift is bounded; 1e-9 relative
        # tolerance matches the storage T6 acceptance.
        assert_true(_approx_equal(std_actual, std_ref, Float64(1e-9)))

    for k in range(K):
        assert_true(seen[k])

    _ = out^
    _ = per_group_values^


# =============================================================================
# Test runner
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_stddev_samp_consume_correctness]()
    suite.test[test_stddev_samp_vs_scalar_count]()
    suite^.run()
