# =============================================================================
# Unit tests -- AggCommitPlan.commit_batch per-slot devirtualization
# =============================================================================
#
# For the dominant accumulator tags (COUNT_STAR / COUNT_NONNULL / SUM_F64 /
# SUM_COUNT_F64 / SUM_COUNT_MIN_MAX_F64) commit_batch runs an inlined slot
# write instead of the stored row thunk, with the per-slot tag check
# hoisted out of the per-row loop.
#
# This test drives `commit_batch` DIRECTLY (test_agg_commit_cross_realloc
# covers `commit_row`). It pins byte-exact results for every specialized
# tag:
#   - COUNT(*)            -> ACC_COUNT_STAR    (count bucket)
#   - SUM                 -> ACC_SUM_F64       (f64 bucket, 8B sum-only)
#   - SUM+COUNT           -> ACC_SUM_COUNT_F64 (f64 bucket, 16B narrow)
#   - SUM/COUNT/MIN/MAX   -> ACC_SUM_COUNT_MIN_MAX_F64 (f64 bucket, 32B)
#
# An i64 value column exercises the i64 bucket's Int->Float64 widen path.
#
# The math is computed against an independent scalar oracle, so a regressed
# inline body (wrong offset / wrong reduction / NaN-comparison flip) shows
# as a value divergence, not just a crash.
# =============================================================================

from std.memory import alloc
from std.testing import assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import (
    FlatHashAggregator,
    EntryHandle,
)
from komira_op_agg_hash.agg_commit import AggCommitPlan
from komira_agg_api.agg_layout import (
    AggLayout,
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    ACC_SUM_COUNT_F64,
    ACC_SUM_COUNT_MIN_MAX_F64,
)


# =============================================================================
# Test 1: COUNT(*) via commit_batch -- ACC_COUNT_STAR inline path.
# =============================================================================


def test_commit_batch_count_star() raises:
    """Group-by COUNT(*) over 10K rows in 64 groups, driven through
    commit_batch. Each group's count must equal the number of rows whose
    `r % 64` lands in that group."""
    print("test_commit_batch_count_star...")

    var num_rows = 10_000
    var num_groups = 64
    # The aggregator's slot layout MUST match the plan's bound layout, so
    # that get_count() reads the same byte offset the inline COUNT writes.
    var count_tags = List[UInt8]()
    count_tags.append(ACC_COUNT_STAR)
    var agg = FlatHashAggregator.with_layout(
        num_keys=1, layout=AggLayout(count_tags^), initial_capacity=8
    )

    # Phase 1: probe-or-insert each row, stash the EntryHandle.
    var entries_buf = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        var key = Int64(r % num_groups)
        var e = agg.find_or_create_1(key)
        entries_buf.append(e)

    # COUNT(*) needs no value column. Layout = single ACC_COUNT_STAR slot.
    var plan = AggCommitPlan[ImmStaticOrigin](1)
    plan._push_count(0)
    var tags = List[UInt8]()
    tags.append(ACC_COUNT_STAR)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    # Phase 2: the inlined COUNT path.
    plan.commit_batch(agg, Span(entries_buf))

    # Oracle: each group g gets ceil/floor of num_rows/num_groups.
    for g in range(num_groups):
        var expected = 0
        for r in range(num_rows):
            if r % num_groups == g:
                expected += 1
        var e = agg.find_or_create_1(Int64(g))
        assert_equal(agg.get_count(e, 0), expected)

    _ = plan^
    _ = agg^


# =============================================================================
# Test 2: SUM-only via commit_batch -- ACC_SUM_F64 inline path.
# =============================================================================


def test_commit_batch_sum_f64() raises:
    """Group-by SUM(f64) over 10K rows in 50 groups. Each group's sum must
    equal the oracle sum of its member values."""
    print("test_commit_batch_sum_f64...")

    var num_rows = 10_000
    var num_groups = 50
    var agg_tags = List[UInt8]()
    agg_tags.append(ACC_SUM_F64)
    var agg = FlatHashAggregator.with_layout(
        num_keys=1, layout=AggLayout(agg_tags^)
    )

    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = Float64(r) * 0.25 - 3.0

    var entries_buf = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        var key = Int64(r % num_groups)
        entries_buf.append(agg.find_or_create_1(key))

    var plan = AggCommitPlan[ImmStaticOrigin](1)
    var col_ptr = (
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin]()
    )
    plan._push_f64(0, col_ptr, 0)
    var tags = List[UInt8]()
    tags.append(ACC_SUM_F64)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    plan.commit_batch(agg, Span(entries_buf))

    for g in range(num_groups):
        var oracle = Float64(0.0)
        for r in range(num_rows):
            if r % num_groups == g:
                oracle += Float64(r) * 0.25 - 3.0
        var e = agg.find_or_create_1(Int64(g))
        assert_equal(agg.get_sum(e, 0), oracle)

    col_buf.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 3: SUM+COUNT via commit_batch -- ACC_SUM_COUNT_F64 inline path.
# =============================================================================


def test_commit_batch_sum_count_f64() raises:
    """Group-by SUM+COUNT (narrow 16B slot) over 8K rows in 32 groups."""
    print("test_commit_batch_sum_count_f64...")

    var num_rows = 8_000
    var num_groups = 32
    var agg = FlatHashAggregator.with_layout(
        num_keys=1, layout=AggLayout.sum_count_f64(1)
    )

    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = Float64(r % 13) + 0.5

    var entries_buf = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        entries_buf.append(agg.find_or_create_1(Int64(r % num_groups)))

    var plan = AggCommitPlan[ImmStaticOrigin](1)
    var col_ptr = (
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin]()
    )
    plan._push_f64(0, col_ptr, 0)
    var tags = List[UInt8]()
    tags.append(ACC_SUM_COUNT_F64)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    plan.commit_batch(agg, Span(entries_buf))

    for g in range(num_groups):
        var osum = Float64(0.0)
        var ocount = 0
        for r in range(num_rows):
            if r % num_groups == g:
                osum += Float64(r % 13) + 0.5
                ocount += 1
        var e = agg.find_or_create_1(Int64(g))
        assert_equal(agg.get_count(e, 0), ocount)
        assert_equal(agg.get_sum(e, 0), osum)

    col_buf.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 4: SUM/COUNT/MIN/MAX quartet via commit_batch -- 32B inline path.
# =============================================================================


def test_commit_batch_quartet() raises:
    """Group-by full quartet (sum/count/min/max) over 6K rows in 40 groups.
    Verifies the inline min/max reduction matches the MinF64/MaxF64.update
    semantics (load-compare-store), not just sum/count."""
    print("test_commit_batch_quartet...")

    var num_rows = 6_000
    var num_groups = 40
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=8)

    # Spread values so each group sees a distinct min and max.
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = Float64((r * 7) % 1000) - 250.0

    var entries_buf = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        entries_buf.append(agg.find_or_create_1(Int64(r % num_groups)))

    var plan = AggCommitPlan[ImmStaticOrigin](1)
    var col_ptr = (
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin]()
    )
    plan._push_f64(0, col_ptr, 0)
    var tags = List[UInt8]()
    tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    plan.commit_batch(agg, Span(entries_buf))

    for g in range(num_groups):
        var osum = Float64(0.0)
        var ocount = 0
        var omin = Float64(1.0e30)
        var omax = Float64(-1.0e30)
        for r in range(num_rows):
            if r % num_groups == g:
                var v = Float64((r * 7) % 1000) - 250.0
                osum += v
                ocount += 1
                if v < omin:
                    omin = v
                if v > omax:
                    omax = v
        var e = agg.find_or_create_1(Int64(g))
        assert_equal(agg.get_count(e, 0), ocount)
        assert_equal(agg.get_sum(e, 0), osum)
        assert_equal(agg.get_min(e, 0), omin)
        assert_equal(agg.get_max(e, 0), omax)

    col_buf.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 5: i64 value column via commit_batch -- Int->Float64 widen + inline.
# =============================================================================


def test_commit_batch_i64_sum() raises:
    """Group-by SUM over an Int64 value column (i64 bucket). Exercises the
    Int64->Float64 widen at the call site followed by the inline sum body."""
    print("test_commit_batch_i64_sum...")

    var num_rows = 5_000
    var num_groups = 25
    var agg = FlatHashAggregator.with_layout(
        num_keys=1, layout=AggLayout.sum_count_f64(1)
    )

    var col_buf = alloc[Int64](num_rows)
    for r in range(num_rows):
        (col_buf + r)[] = Int64((r % 100) - 40)

    var entries_buf = List[EntryHandle](capacity=num_rows)
    for r in range(num_rows):
        entries_buf.append(agg.find_or_create_1(Int64(r % num_groups)))

    var plan = AggCommitPlan[ImmStaticOrigin](1)
    var col_ptr = (
        col_buf.bitcast[Scalar[DType.int64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin]()
    )
    plan._push_i64(0, col_ptr, 0)
    var tags = List[UInt8]()
    tags.append(ACC_SUM_COUNT_F64)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    plan.commit_batch(agg, Span(entries_buf))

    for g in range(num_groups):
        var osum = Float64(0.0)
        var ocount = 0
        for r in range(num_rows):
            if r % num_groups == g:
                osum += Float64(Int((r % 100) - 40))
                ocount += 1
        var e = agg.find_or_create_1(Int64(g))
        assert_equal(agg.get_count(e, 0), ocount)
        assert_equal(agg.get_sum(e, 0), osum)

    col_buf.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test entry point
# =============================================================================


def main() raises:
    test_commit_batch_count_star()
    test_commit_batch_sum_f64()
    test_commit_batch_sum_count_f64()
    test_commit_batch_quartet()
    test_commit_batch_i64_sum()
    print("test_agg_commit_batch_devirt: 5 tests passed")
