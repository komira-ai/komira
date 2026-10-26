# =============================================================================
# Tests -- SlabHashAggSinkStruct end to end, two keys and two aggregates
# =============================================================================
#
# STDDEV_SAMP(v3) and COUNT(v1) GROUP BY (k0, k1) through
# `SlabHashAggSinkStruct[_, StddevSampAggregator, CountAggregator]`, which
# takes the staged consume path (probe, scatter by partition, commit per
# aggregate) and the (Int64, Int64) register probe.
#
#   1. test_two_keys_two_workers_correctness_2000x200 -- 2000 rows over a 20 x 10
#      (k0, k1) grid (200 groups, 10 rows each), half to each of two workers;
#      every group's stddev matches a Welford reference to 1e-9 and its count
#      is 10. Catches an aggregate committed from the wrong input column, a
#      lost row, and a broken merge.
#   2. test_two_keys_collision_asymmetry_two_keys -- (0, 1) and (1, 0) are two
#      groups through the whole sink: catches a symmetric two-key hash.
#   3. test_two_keys_single_worker_basic -- 100 rows over 5 (k0, k1) pairs on one
#      worker (no donor to merge): 5 groups with the right counts.
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

from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_STDDEV_SAMP,
    AggExpr,
)
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
    CountAggregator,
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
    """Float64 approx-equal with absolute + relative tolerance."""
    var diff = _abs(a - b)
    if diff <= tol:
        return True
    var mag = _abs(a) + _abs(b)
    return diff <= tol * mag


def _stddev_samp_reference(values: List[Float64]) -> Float64:
    """numpy.std(values, ddof=1)-equivalent reference via Welford."""
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
# Fixture builders — RecordBatch + AggSinkData for STDDEV_SAMP(v3)+COUNT(v1)
# GROUP BY (k0, k1)
# =============================================================================


def _make_batch_two_keys_v3_v1(
    var k0s: List[Int64],
    var k1s: List[Int64],
    var v3s: List[Float64],
    var v1s: List[Int64],
) raises -> RecordBatch:
    """Four-column batch: col 0 = Int64 'k0', col 1 = Int64 'k1',
    col 2 = Float64 'v3', col 3 = Int64 'v1'."""
    var n = len(k0s)

    var k0_arr = PrimitiveArray[DType.int64].allocate(n)
    var k0_ptr = k0_arr._typed_ptr_mut()
    for i in range(n):
        (k0_ptr + i)[] = k0s[i]

    var k1_arr = PrimitiveArray[DType.int64].allocate(n)
    var k1_ptr = k1_arr._typed_ptr_mut()
    for i in range(n):
        (k1_ptr + i)[] = k1s[i]

    var v3_arr = PrimitiveArray[DType.float64].allocate(n)
    var v3_ptr = v3_arr._typed_ptr_mut()
    for i in range(n):
        (v3_ptr + i)[] = v3s[i]

    var v1_arr = PrimitiveArray[DType.int64].allocate(n)
    var v1_ptr = v1_arr._typed_ptr_mut()
    for i in range(n):
        (v1_ptr + i)[] = v1s[i]

    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, False))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("v3", ArrowType.FLOAT64, False))
    sb.add_field(Field("v1", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](k0_arr^))
    b.add_column(Column.from_primitive[DType.int64](k1_arr^))
    b.add_column(Column.from_primitive[DType.float64](v3_arr^))
    b.add_column(Column.from_primitive[DType.int64](v1_arr^))
    return b.build(sb.build())


def _agg_sink_data_two_keys() raises -> AggSinkData:
    """STDDEV_SAMP(v3) + COUNT(v1) GROUP BY (k0, k1).

    Output schema: 4 cols [k0, k1, sd_v3, cnt_v1] (Int64, Int64,
    Float64, Int64). Matches what the planner emits for the SDK
    `group_by(["k0","k1"]).agg(stddev_samp("v3"), count("v1"))`.
    """
    var group_by = ExprArray()
    group_by.append(col("k0").copy_expr())
    group_by.append(col("k1").copy_expr())
    var aggs = AggExprArray()
    var none_alias_a: Optional[String] = None
    aggs.append(
        AggExpr(AGG_STDDEV_SAMP, col("v3").copy_expr(), none_alias_a^)
    )
    var none_alias_b: Optional[String] = None
    aggs.append(AggExpr(AGG_COUNT, col("v1").copy_expr(), none_alias_b^))
    var osb = SchemaBuilder()
    osb.add_field(Field("k0", ArrowType.INT64, False))
    osb.add_field(Field("k1", ArrowType.INT64, False))
    osb.add_field(Field("sd_v3", ArrowType.FLOAT64, False))
    osb.add_field(Field("cnt_v1", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build(), False, 0)


def _empty_pq_data() raises -> ParquetSourceData:
    return ParquetSourceData(
        String(""),
        Optional[List[String]](None),
        Optional[Expr](None),
    )


# =============================================================================
# Sink factory + driver helpers
# =============================================================================


comptime _TWO_KEY_COLS: Array[Int, 8] = [2, 3, -1, -1, -1, -1, -1, -1]
"""Aggregate 0 reads col 2 (v3), aggregate 1 reads col 3 (v1)."""


def _new_sink_two_keys(
    num_workers: Int,
) raises -> SlabHashAggSinkStruct[
    _TWO_KEY_COLS, StddevSampAggregator, CountAggregator,
]:
    """2-key + [stddev_samp, count] sink, parametric on worker count."""
    return SlabHashAggSinkStruct[
        _TWO_KEY_COLS, StddevSampAggregator, CountAggregator,
    ].new(
        _agg_sink_data_two_keys(),
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
    """Drive `sink.finalize` and take its single output."""
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


def _drive_sink_two_workers_two_keys(
    var batch_a: RecordBatch,
    var batch_b: RecordBatch,
) raises -> RecordBatch:
    """Drive the two-key sink end to end with two workers."""
    var sink = _new_sink_two_keys(num_workers=2)
    var sink_global = sink.init_global()

    var local_0 = sink.init_local()
    var local_1 = sink.init_local()

    sink.consume(0, local_0, sink_global, batch_a^)
    sink.consume(1, local_1, sink_global, batch_b^)

    var states = Slab[OwnedPointer[SlabHashAggLocal]]()
    states.append(OwnedPointer[SlabHashAggLocal](local_0^))
    states.append(OwnedPointer[SlabHashAggLocal](local_1^))

    var reservation = MemoryReservation()
    sink.combine(sink_global, states^, reservation)

    for p in range(N_PARTITIONS_SHAPE_B):
        sink.combine_partition(sink_global, p)

    var disp = LocalDispatcher[NoopSink]()
    var ct = CancellationToken.never()
    var batch = _finalize_and_extract_batch(
        sink, sink_global^, Pointer(to=disp), ct^,
    )
    return batch^


def _drive_sink_single_worker_two_keys(
    var batch: RecordBatch,
) raises -> RecordBatch:
    """Drive the two-key sink with one worker (nothing to merge)."""
    var sink = _new_sink_two_keys(num_workers=1)
    var sink_global = sink.init_global()
    var local_0 = sink.init_local()

    sink.consume(0, local_0, sink_global, batch^)

    var states = Slab[OwnedPointer[SlabHashAggLocal]]()
    states.append(OwnedPointer[SlabHashAggLocal](local_0^))

    var reservation = MemoryReservation()
    sink.combine(sink_global, states^, reservation)

    for p in range(N_PARTITIONS_SHAPE_B):
        sink.combine_partition(sink_global, p)

    var disp = LocalDispatcher[NoopSink]()
    var ct = CancellationToken.never()
    var out = _finalize_and_extract_batch(
        sink, sink_global^, Pointer(to=disp), ct^,
    )
    return out^


# =============================================================================
# Test 1 — 2000 rows × 200 distinct (k0, k1) groups, two-worker correctness
# =============================================================================


def test_two_keys_two_workers_correctness_2000x200() raises:
    """2000 rows, k0 in [0, 20), k1 in [0, 10) => 200 distinct groups,
    10 rows per group. Drive 2 workers (1000 rows each). Verify
    per-group stddev_samp(v3) within 1e-9 relative tolerance and
    count(v1) == 10.

    Per-row formula: row i has (k0=i%20, k1=(i//20)%10), v3 from a
    polynomial in i, v1=42 (the count kernel ignores its input value
    so we're really testing it produces 10 per group).
    """
    comptime N = 2_000
    comptime K0_RANGE = 20
    comptime K1_RANGE = 10
    comptime N_GROUPS = K0_RANGE * K1_RANGE  # 200
    comptime PER_GROUP = N // N_GROUPS  # 10

    var k0s = List[Int64](capacity=N)
    var k1s = List[Int64](capacity=N)
    var v3s = List[Float64](capacity=N)
    var v1s = List[Int64](capacity=N)
    var per_group_v3 = List[List[Float64]]()
    for _ in range(N_GROUPS):
        per_group_v3.append(List[Float64](capacity=PER_GROUP))

    for i in range(N):
        var k0 = i % K0_RANGE
        var k1 = (i // K0_RANGE) % K1_RANGE
        var g = k1 * K0_RANGE + k0  # group id in [0, 200)
        var v = (Float64(i) * 0.5
                 + Float64(i % 17) * 0.125
                 - Float64(i % 31) * 0.07)
        k0s.append(Int64(k0))
        k1s.append(Int64(k1))
        v3s.append(v)
        v1s.append(Int64(42))
        per_group_v3[g].append(v)

    # Split into two halves.
    var half = N // 2
    var k0a = List[Int64](capacity=half)
    var k1a = List[Int64](capacity=half)
    var v3a = List[Float64](capacity=half)
    var v1a = List[Int64](capacity=half)
    var k0b = List[Int64](capacity=N - half)
    var k1b = List[Int64](capacity=N - half)
    var v3b = List[Float64](capacity=N - half)
    var v1b = List[Int64](capacity=N - half)
    for i in range(half):
        k0a.append(k0s[i])
        k1a.append(k1s[i])
        v3a.append(v3s[i])
        v1a.append(v1s[i])
    for i in range(half, N):
        k0b.append(k0s[i])
        k1b.append(k1s[i])
        v3b.append(v3s[i])
        v1b.append(v1s[i])
    _ = k0s^
    _ = k1s^
    _ = v3s^
    _ = v1s^

    var batch_a = _make_batch_two_keys_v3_v1(k0a^, k1a^, v3a^, v1a^)
    var batch_b = _make_batch_two_keys_v3_v1(k0b^, k1b^, v3b^, v1b^)

    var out = _drive_sink_two_workers_two_keys(batch_a^, batch_b^)

    # Verify shape: 200 rows, 4 columns (k0, k1, sd_v3, cnt_v1).
    assert_equal(out.num_rows(), N_GROUPS)
    assert_equal(out.num_columns(), 4)

    var k0_arr = out.column_as_primitive_int64(0)
    var k1_arr = out.column_as_primitive_int64(1)
    var sd_arr = out.column_as_primitive_float64(2)
    var cnt_arr = out.column_as_primitive_int64(3)

    var seen = List[Bool](capacity=N_GROUPS)
    for _ in range(N_GROUPS):
        seen.append(False)

    for r in range(N_GROUPS):
        var k0 = Int(k0_arr.get_typed[Int64](r))
        var k1 = Int(k1_arr.get_typed[Int64](r))
        var sd_actual = Float64(sd_arr.get_typed[Float64](r))
        var cnt_actual = Int(cnt_arr.get_typed[Int64](r))

        assert_true(0 <= k0 and k0 < K0_RANGE)
        assert_true(0 <= k1 and k1 < K1_RANGE)
        var g = k1 * K0_RANGE + k0
        assert_true(not seen[g])
        seen[g] = True

        # Each group has exactly PER_GROUP=10 rows.
        assert_equal(cnt_actual, PER_GROUP)

        # stddev_samp matches reference within tolerance.
        var sd_ref = _stddev_samp_reference(per_group_v3[g])
        assert_true(_approx_equal(sd_actual, sd_ref, Float64(1e-9)))

    for g in range(N_GROUPS):
        assert_true(seen[g])

    _ = out^
    _ = per_group_v3^


# =============================================================================
# Test 2 — Collision asymmetry (0,1) vs (1,0) -> 2 distinct groups
# =============================================================================


def test_two_keys_collision_asymmetry_two_keys() raises:
    """(k0=0, k1=1) and (k0=1, k1=0) MUST land in 2 distinct groups
    (not 1). The 2-key combiner `_fib_hash_2(k0, k1) != _fib_hash_2(k1,
    k0)` is the load-bearing invariant; this test exercises it through
    the full sink stack (probe + insert + finalize).

    Single-worker fixture; 2 rows total."""
    var k0s = List[Int64](capacity=2)
    var k1s = List[Int64](capacity=2)
    var v3s = List[Float64](capacity=2)
    var v1s = List[Int64](capacity=2)
    k0s.append(Int64(0)); k1s.append(Int64(1))
    k0s.append(Int64(1)); k1s.append(Int64(0))
    v3s.append(Float64(1.0)); v3s.append(Float64(2.0))
    v1s.append(Int64(42)); v1s.append(Int64(42))

    var batch = _make_batch_two_keys_v3_v1(k0s^, k1s^, v3s^, v1s^)
    var out = _drive_sink_single_worker_two_keys(batch^)

    # 2 distinct groups, not 1.
    assert_equal(out.num_rows(), 2)
    assert_equal(out.num_columns(), 4)

    var k0_arr = out.column_as_primitive_int64(0)
    var k1_arr = out.column_as_primitive_int64(1)
    var cnt_arr = out.column_as_primitive_int64(3)

    # Verify both pairs surfaced exactly once (order is partition-walk
    # dependent; we accept either ordering).
    var saw_01 = False
    var saw_10 = False
    for r in range(2):
        var k0 = Int(k0_arr.get_typed[Int64](r))
        var k1 = Int(k1_arr.get_typed[Int64](r))
        var cnt = Int(cnt_arr.get_typed[Int64](r))
        # Each group has exactly 1 row.
        assert_equal(cnt, 1)
        if k0 == 0 and k1 == 1:
            saw_01 = True
        elif k0 == 1 and k1 == 0:
            saw_10 = True
    assert_true(saw_01)
    assert_true(saw_10)

    _ = out^


# =============================================================================
# Test 3 — Single worker, 100 rows × 5 unique (k0, k1) pairs
# =============================================================================


def test_two_keys_single_worker_basic() raises:
    """100 rows, 5 unique (k0, k1) pairs (each appearing 20 times).
    Single worker; smoke test for the per-row probe + finalize path
    without going through combine across donor workers.

    Grid: (k0, k1) in {(0,0), (1,0), (0,1), (1,1), (2,0)}."""
    comptime N = 100
    comptime K = 5

    # Predefine the 5 (k0, k1) pairs.
    var pair_k0 = List[Int64]()
    var pair_k1 = List[Int64]()
    pair_k0.append(Int64(0)); pair_k1.append(Int64(0))
    pair_k0.append(Int64(1)); pair_k1.append(Int64(0))
    pair_k0.append(Int64(0)); pair_k1.append(Int64(1))
    pair_k0.append(Int64(1)); pair_k1.append(Int64(1))
    pair_k0.append(Int64(2)); pair_k1.append(Int64(0))

    var k0s = List[Int64](capacity=N)
    var k1s = List[Int64](capacity=N)
    var v3s = List[Float64](capacity=N)
    var v1s = List[Int64](capacity=N)
    var per_group_v3 = List[List[Float64]]()
    for _ in range(K):
        per_group_v3.append(List[Float64]())

    for i in range(N):
        var g = i % K
        var v = Float64(i) * 0.3 + Float64(g) * 1.7
        k0s.append(pair_k0[g])
        k1s.append(pair_k1[g])
        v3s.append(v)
        v1s.append(Int64(7))
        per_group_v3[g].append(v)

    var batch = _make_batch_two_keys_v3_v1(k0s^, k1s^, v3s^, v1s^)
    var out = _drive_sink_single_worker_two_keys(batch^)

    assert_equal(out.num_rows(), K)
    assert_equal(out.num_columns(), 4)

    var k0_arr = out.column_as_primitive_int64(0)
    var k1_arr = out.column_as_primitive_int64(1)
    var sd_arr = out.column_as_primitive_float64(2)
    var cnt_arr = out.column_as_primitive_int64(3)

    var seen = List[Bool](capacity=K)
    for _ in range(K):
        seen.append(False)

    for r in range(K):
        var k0 = Int(k0_arr.get_typed[Int64](r))
        var k1 = Int(k1_arr.get_typed[Int64](r))
        var sd_actual = Float64(sd_arr.get_typed[Float64](r))
        var cnt_actual = Int(cnt_arr.get_typed[Int64](r))

        # Find which g this is.
        var found_g = -1
        for g in range(K):
            if Int64(k0) == pair_k0[g] and Int64(k1) == pair_k1[g]:
                found_g = g
                break
        assert_true(found_g >= 0)
        assert_true(not seen[found_g])
        seen[found_g] = True

        # Each group has 100/5 = 20 rows.
        assert_equal(cnt_actual, 20)

        var sd_ref = _stddev_samp_reference(per_group_v3[found_g])
        assert_true(_approx_equal(sd_actual, sd_ref, Float64(1e-9)))

    for g in range(K):
        assert_true(seen[g])

    _ = out^
    _ = per_group_v3^


# =============================================================================
# Test runner
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_two_keys_two_workers_correctness_2000x200]()
    suite.test[test_two_keys_collision_asymmetry_two_keys]()
    suite.test[test_two_keys_single_worker_basic]()
    suite^.run()
