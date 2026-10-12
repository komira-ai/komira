# =============================================================================
# Unit tests -- AggCommitPlan.commit_row under entry-buffer growth
# =============================================================================
#
# A multi-group aggregation that grows `FlatHashAggregator._entries` during
# the probe phase, then commits every row through `commit_row`'s bound
# thunk dispatch. commit_row resolves each entry pointer afresh from the
# aggregator (by the handle's entry index), so the writes land in the
# current buffer; an entry pointer captured before a growth (or an address
# round-tripped through an Int) would write to the freed buffer and
# produce wrong sums and counts -- not always a crash, always a value
# divergence. Final sum + count values must be byte-correct.
#
# The test uses `find_or_create_1` + `commit_row` in the same shape as the
# sinks (the plan is bound BEFORE the first commit_row).
# =============================================================================

from std.memory import alloc
from std.testing import assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator, EntryHandle
from komira_op_agg_hash.agg_commit import AggCommitPlan
from komira_agg_api.agg_layout import (
    AggLayout,
    ACC_SUM_COUNT_F64,
    ACC_SUM_COUNT_MIN_MAX_F64,
)


# =============================================================================
# Test 1: commit_row correct under mid-phase resizes (quartet layout)
# =============================================================================

def test_commit_row_after_resizes_quartet() raises:
    """Force multiple HT resizes during find_or_create; verify commit_row
    writes to the (post-resize) correct entry addresses. A regressed
    thunk that laundered entry addresses through Int would either crash
    or produce wrong sums when a resize relocated the entries buffer."""
    print("test_commit_row_after_resizes_quartet...")

    # Tiny initial capacity forces several resizes while we insert 200
    # unique groups. Each resize reallocates `_entries` -- a Int-laundered
    # thunk could leak a stale pre-resize pointer if not hardened.
    var agg = FlatHashAggregator(
        num_keys=1, num_aggs=1, initial_capacity=8
    )

    # Build an f64 column: 200 values, one per distinct key, contiguous.
    var num_rows = 200
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        col_buf.unsafe_write(Float64(r) + 0.5)
        col_buf += 1
    # Reset to the beginning for reading.
    col_buf -= num_rows

    # AggCommitPlan directly (bypass build_agg_commit_plan -- that helper
    # reads from a RecordBatch which is overkill for this unit test).
    #
    # AggCommitPlan is parametric on the batch's origin and bakes
    # value-column pointers tied to it. This `alloc`-owned buffer outlives
    # the plan, so it is labeled with the static origin.
    var plan = AggCommitPlan[ImmStaticOrigin](1)
    var col_ptr = (
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin]()
    )
    plan._push_f64(0, col_ptr, 0)

    # Default quartet layout (32B/slot): exercises the
    # row_sum_count_min_max_f64 thunk path.
    var tags = List[UInt8]()
    tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    # Phase 1 + 2 interleaved: probe, commit. The probe may trigger a
    # _resize which reallocates `_entries`; the handle returned is
    # always fresh, so commit_row always writes to the current buffer.
    for r in range(num_rows):
        var entry = agg.find_or_create_1(Int64(r))
        plan.commit_row(agg, entry, r)

    # Verify every group got its expected value: sum = r + 0.5, count = 1.
    for r in range(num_rows):
        var e = agg.find_or_create_1(Int64(r))
        assert_equal(agg.get_count(e, 0), 1)
        # Float64 equality is exact here (no accumulation).
        assert_equal(agg.get_sum(e, 0), Float64(r) + 0.5)

    col_buf.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 2: commit_row correct with repeat keys (many updates per entry)
# =============================================================================

def test_commit_row_repeat_keys_quartet() raises:
    """10K rows with wrap-around keys in 100 groups. Every entry receives
    multiple updates. Correctness of sum + count validates the thunk's
    entry-pointer write path without Int laundering."""
    print("test_commit_row_repeat_keys_quartet...")

    var agg = FlatHashAggregator(
        num_keys=1, num_aggs=1, initial_capacity=16
    )
    var num_rows = 10_000
    var num_groups = 100

    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        col_buf.unsafe_write(Float64(1.0))
        col_buf += 1
    col_buf -= num_rows

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

    for r in range(num_rows):
        var key = Int64(r % num_groups)
        var entry = agg.find_or_create_1(key)
        plan.commit_row(agg, entry, r)

    # Each group gets exactly num_rows / num_groups = 100 updates of 1.0.
    assert_equal(agg.num_groups(), num_groups)
    for g in range(num_groups):
        var e = agg.find_or_create_1(Int64(g))
        assert_equal(agg.get_count(e, 0), num_rows // num_groups)
        assert_equal(agg.get_sum(e, 0), Float64(num_rows // num_groups))

    col_buf.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 3: commit_row produces identical results regardless of layout
# =============================================================================

def test_commit_row_narrow_matches_quartet_sum_count() raises:
    """Same workload under narrow (16B ACC_SUM_COUNT_F64) and quartet
    (32B ACC_SUM_COUNT_MIN_MAX_F64) layouts. Sum + count MUST match byte-
    identically (only min/max are missing from narrow)."""
    print("test_commit_row_narrow_matches_quartet_sum_count...")

    var num_rows = 1000
    var num_groups = 50

    # Shared value buffer.
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        col_buf.unsafe_write(Float64(r) / 10.0)
        col_buf += 1
    col_buf -= num_rows
    var col_ptr = (
        col_buf.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin]()
    )

    # --- Quartet run ---
    var agg_q = FlatHashAggregator(
        num_keys=1, num_aggs=1, initial_capacity=8
    )
    var plan_q = AggCommitPlan[ImmStaticOrigin](1)
    plan_q._push_f64(0, col_ptr, 0)
    var tags_q = List[UInt8]()
    tags_q.append(ACC_SUM_COUNT_MIN_MAX_F64)
    var layout_q = AggLayout(tags_q^)
    plan_q.bind_layout(layout_q, agg_q._aggs_offset)
    for r in range(num_rows):
        var entry = agg_q.find_or_create_1(Int64(r % num_groups))
        plan_q.commit_row(agg_q, entry, r)

    # --- Narrow run ---
    var agg_n = FlatHashAggregator.with_layout(
        num_keys=1, layout=AggLayout.sum_count_f64(1)
    )
    var plan_n = AggCommitPlan[ImmStaticOrigin](1)
    plan_n._push_f64(0, col_ptr, 0)
    var tags_n = List[UInt8]()
    tags_n.append(ACC_SUM_COUNT_F64)
    var layout_n = AggLayout(tags_n^)
    plan_n.bind_layout(layout_n, agg_n._aggs_offset)
    for r in range(num_rows):
        var entry = agg_n.find_or_create_1(Int64(r % num_groups))
        plan_n.commit_row(agg_n, entry, r)

    # Sum + count must match for every group.
    for g in range(num_groups):
        var eq = agg_q.find_or_create_1(Int64(g))
        var en = agg_n.find_or_create_1(Int64(g))
        assert_equal(agg_q.get_count(eq, 0), agg_n.get_count(en, 0))
        assert_equal(agg_q.get_sum(eq, 0), agg_n.get_sum(en, 0))

    col_buf.free()
    _ = plan_q^
    _ = plan_n^
    _ = agg_q^
    _ = agg_n^


# =============================================================================
# Test entry point
# =============================================================================

def main() raises:
    test_commit_row_after_resizes_quartet()
    test_commit_row_repeat_keys_quartet()
    test_commit_row_narrow_matches_quartet_sum_count()
    print("test_agg_commit_cross_realloc: 3 tests passed")
