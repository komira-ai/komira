# =============================================================================
# Tests -- MIN/MAX through AggCommitPlan's batch commits, under the
# NaN-greatest float order
# =============================================================================
#
# The batch commit folds the 32B quartet slot inline (agg_commit_batch.mojo)
# into entries the tables seed with each fold's identity: MIN with the
# canonical NaN, MAX with -inf. That order (NaN above +inf) is the one
# komira_op_agg_state's MinF64/MaxF64 use and DuckDB answers with. Every
# case is one group:
#
#   values                  MIN    MAX
#   {+inf}                  +inf   +inf
#   {-inf}                  -inf   -inf
#   {NaN}                   NaN    NaN
#   {NaN, 1.0}              1.0    NaN
#   {1.0, NaN, -inf, +inf}  -inf   NaN
#
#   1. test_commit_batch_min_max_float_order -- commit_batch into one
#      FlatHashAggregator.
#   2. test_commit_batch_partitioned_min_max_float_order -- the same rows
#      through commit_batch_partitioned.
#   3. test_commit_batch_indexed_min_max_float_order -- the same rows
#      through commit_batch_indexed, one partition's bucket at a time.
#
# What fails without them: the old Float64.MAX / lowest-finite seeds make
# MIN of {+inf} and {NaN} answer 1.797e308 and MAX of {-inf} answer
# -1.797e308; folding MIN with a bare `<` (the old fold) against the NaN
# seed leaves every MIN at NaN. Both were planted and all three tests went
# red.
# =============================================================================

from std.math import inf, isnan
from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_true

from komira_agg_api.agg_layout import AggLayout
from komira_op_agg_hash.agg_commit import AggCommitPlan
from komira_op_agg_hash.flat_hash_agg import (
    EntryHandle,
    FlatHashAggregator,
    _fib_hash_1,
)
from komira_op_agg_hash.partitioned_flat_hash_agg import (
    NUM_PARTITIONS,
    PartitionedFlatHashAggregator,
)


comptime _NUM_CASES: Int = 5


def _nan() -> Float64:
    var zero = Float64(0.0)
    return zero / zero


def _rows() -> Tuple[List[Int64], List[Float64]]:
    """The cases as (key, value) rows, key = case index, interleaved so
    each group's rows are not adjacent."""
    var keys = List[Int64]()
    var vals = List[Float64]()
    var pos = inf[DType.float64]()
    var neg = -inf[DType.float64]()
    # Row order: case 4's values are spread through the batch.
    keys.append(4)
    vals.append(1.0)
    keys.append(0)
    vals.append(pos)
    keys.append(3)
    vals.append(_nan())
    keys.append(4)
    vals.append(_nan())
    keys.append(1)
    vals.append(neg)
    keys.append(2)
    vals.append(_nan())
    keys.append(4)
    vals.append(neg)
    keys.append(3)
    vals.append(1.0)
    keys.append(4)
    vals.append(pos)
    return (keys^, vals^)


def _assert_f64(got: Float64, want: Float64, what: String) raises:
    if isnan(want):
        assert_true(isnan(got), what + ": want NaN, got " + String(got))
    else:
        assert_equal(got, want, what)


def _check(c: Int, got_min: Float64, got_max: Float64, where: String) raises:
    var want_min: Float64
    var want_max: Float64
    if c == 0:
        want_min = inf[DType.float64]()
        want_max = inf[DType.float64]()
    elif c == 1:
        want_min = -inf[DType.float64]()
        want_max = -inf[DType.float64]()
    elif c == 2:
        want_min = _nan()
        want_max = _nan()
    elif c == 3:
        want_min = 1.0
        want_max = _nan()
    else:
        want_min = -inf[DType.float64]()
        want_max = _nan()
    _assert_f64(got_min, want_min, where + " MIN case " + String(c))
    _assert_f64(got_max, want_max, where + " MAX case " + String(c))


def test_commit_batch_min_max_float_order() raises:
    var rows = _rows()
    var n = len(rows[0])
    var col_buf = alloc[Float64](n)
    for r in range(n):
        (col_buf + r)[] = rows[1][r]
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)
    var entries = List[EntryHandle](capacity=n)
    for r in range(n):
        entries.append(agg.find_or_create_1(rows[0][r]))
    var plan = AggCommitPlan[ImmStaticOrigin](1)
    plan._push_f64(
        0,
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin](),
        0,
    )
    plan.bind_layout(AggLayout.default_quartet(1), agg._aggs_offset)
    plan.commit_batch(agg, Span(entries))
    assert_equal(agg.num_groups(), _NUM_CASES)
    for c in range(_NUM_CASES):
        var h = agg.find_or_create_1(Int64(c))
        assert_equal(agg.get_count(h, 0), 4 if c == 4 else (2 if c == 3 else 1))
        _check(c, agg.get_min(h, 0), agg.get_max(h, 0), "commit_batch")
    col_buf.free()
    _ = plan^


def test_commit_batch_partitioned_min_max_float_order() raises:
    var rows = _rows()
    var n = len(rows[0])
    var col_buf = alloc[Float64](n)
    for r in range(n):
        (col_buf + r)[] = rows[1][r]
    var pagg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
    var parts = List[UInt8](capacity=n)
    var entries = List[EntryHandle](capacity=n)
    for r in range(n):
        var key = rows[0][r]
        var hit = pagg.find_or_create_1_prehashed(key, _fib_hash_1(key))
        parts.append(UInt8(hit[0]))
        entries.append(hit[1])
    var plan = AggCommitPlan[ImmStaticOrigin](1)
    plan._push_f64(
        0,
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin](),
        0,
    )
    plan.bind_layout(AggLayout.default_quartet(1), pagg.partition(0)._aggs_offset)
    plan.commit_batch_partitioned(pagg, Span(parts), Span(entries))
    for c in range(_NUM_CASES):
        var hit = pagg.find_or_create_1_prehashed(Int64(c), _fib_hash_1(Int64(c)))
        ref sub = pagg.partition(hit[0])
        _check(c, sub.get_min(hit[1], 0), sub.get_max(hit[1], 0), "partitioned")
    col_buf.free()
    _ = plan^


def test_commit_batch_indexed_min_max_float_order() raises:
    var rows = _rows()
    var n = len(rows[0])
    var col_buf = alloc[Float64](n)
    for r in range(n):
        (col_buf + r)[] = rows[1][r]
    var pagg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
    var parts = List[Int](capacity=n)
    var entries = List[EntryHandle](capacity=n)
    for r in range(n):
        var key = rows[0][r]
        var hit = pagg.find_or_create_1_prehashed(key, _fib_hash_1(key))
        parts.append(hit[0])
        entries.append(hit[1])
    var plan = AggCommitPlan[ImmStaticOrigin](1)
    plan._push_f64(
        0,
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin](),
        0,
    )
    plan.bind_layout(AggLayout.default_quartet(1), pagg.partition(0)._aggs_offset)
    var committed = 0
    for p in range(NUM_PARTITIONS):
        var idx = List[Int32]()
        for r in range(n):
            if parts[r] == p:
                idx.append(Int32(r))
        if len(idx) > 0:
            plan.commit_batch_indexed(pagg.partition(p), Span(entries), Span(idx))
            committed += len(idx)
    assert_equal(committed, n)
    for c in range(_NUM_CASES):
        var hit = pagg.find_or_create_1_prehashed(Int64(c), _fib_hash_1(Int64(c)))
        ref sub = pagg.partition(hit[0])
        _check(c, sub.get_min(hit[1], 0), sub.get_max(hit[1], 0), "indexed")
    col_buf.free()
    _ = plan^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
