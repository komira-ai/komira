# =============================================================================
# Tests -- the partitioned, indexed and perfect-hash commit forms of
# AggCommitPlan
# =============================================================================
#
# Every value below is an exact small integer in Float64, so each sum,
# count, min and max is compared bit-exactly against a scalar oracle.
#
#   1. test_commit_batch_partitioned -- the prehashed probe returns
#      (partition, handle); commit_batch_partitioned folds every row into
#      the sub-table its partition id names. Catches an entry resolved
#      against the wrong sub-table (wrong sums, or a write out of bounds).
#   2. test_commit_batch_indexed -- rows bucketed by partition are committed
#      one bucket at a time into that partition's sub-table through
#      `row_indices`. Catches an index/row mix-up (values folded from the
#      wrong rows).
#   3. test_commit_row_ph -- commit_row_ph drives a PerfectHashAggregator
#      by key from a plan; results match `update` fed directly.
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal

from komira_agg_api.agg_layout import AggLayout
from komira_op_agg_hash.agg_commit import AggCommitPlan
from komira_op_agg_hash.flat_hash_agg import EntryHandle, _fib_hash_1
from komira_op_agg_hash.flat_hash_agg_perfect import PerfectHashAggregator
from komira_op_agg_hash.partitioned_flat_hash_agg import (
    NUM_PARTITIONS,
    PartitionedFlatHashAggregator,
)


def _value(r: Int) -> Float64:
    return Float64((r * 13) % 97) - 40.0


def test_commit_batch_partitioned() raises:
    var pagg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
    var num_rows = 5_000
    var num_groups = 700
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = _value(r)

    var parts = List[UInt8](capacity=num_rows)
    var entries = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        var key = Int64(r % num_groups)
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

    for g in range(num_groups):
        var osum = Float64(0.0)
        var ocount = 0
        var omin = Float64(1.0e30)
        var omax = Float64(-1.0e30)
        for r in range(num_rows):
            if r % num_groups == g:
                var v = _value(r)
                osum += v
                ocount += 1
                omin = min(omin, v)
                omax = max(omax, v)
        var hit = pagg.find_or_create_1_prehashed(Int64(g), _fib_hash_1(Int64(g)))
        ref sub = pagg.partition(hit[0])
        assert_equal(sub.get_sum(hit[1], 0), osum)
        assert_equal(sub.get_count(hit[1], 0), ocount)
        assert_equal(sub.get_min(hit[1], 0), omin)
        assert_equal(sub.get_max(hit[1], 0), omax)
    col_buf.free()
    _ = plan^


def test_commit_batch_indexed() raises:
    var pagg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
    var num_rows = 4_000
    var num_groups = 333
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = _value(r)

    var parts = List[Int](capacity=num_rows)
    var entries = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        var key = Int64(r % num_groups)
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
    # One bucket of row indices per partition, committed bucket by bucket.
    var committed = 0
    for p in range(NUM_PARTITIONS):
        var rows = List[Int32]()
        for r in range(num_rows):
            if parts[r] == p:
                rows.append(Int32(r))
        if len(rows) > 0:
            plan.commit_batch_indexed(pagg.partition(p), Span(entries), Span(rows))
            committed += len(rows)
    assert_equal(committed, num_rows)

    for g in range(num_groups):
        var osum = Float64(0.0)
        var ocount = 0
        for r in range(num_rows):
            if r % num_groups == g:
                osum += _value(r)
                ocount += 1
        var hit = pagg.find_or_create_1_prehashed(Int64(g), _fib_hash_1(Int64(g)))
        ref sub = pagg.partition(hit[0])
        assert_equal(sub.get_sum(hit[1], 0), osum)
        assert_equal(sub.get_count(hit[1], 0), ocount)
    col_buf.free()
    _ = plan^


def test_commit_row_ph() raises:
    var num_rows = 1_024
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = _value(r)
    var plan = AggCommitPlan[ImmStaticOrigin](2)
    plan._push_f64(
        0,
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin](),
        0,
    )
    plan._push_count(1)
    var via_plan = PerfectHashAggregator(domain_size=16, key_offset=8, num_aggs=2)
    var direct = PerfectHashAggregator(domain_size=16, key_offset=8, num_aggs=2)
    for r in range(num_rows):
        var key = Int64(r % 16 - 8)
        plan.commit_row_ph(via_plan, key, r)
        direct.update(key, 0, _value(r))
        direct.update_count_only(key, 1)
    for slot in range(16):
        assert_equal(via_plan.get_sum(slot, 0), direct.get_sum(slot, 0))
        assert_equal(via_plan.get_count(slot, 0), direct.get_count(slot, 0))
        assert_equal(via_plan.get_min(slot, 0), direct.get_min(slot, 0))
        assert_equal(via_plan.get_max(slot, 0), direct.get_max(slot, 0))
        assert_equal(via_plan.get_count(slot, 1), num_rows // 16)
    col_buf.free()
    _ = plan^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
