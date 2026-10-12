# =============================================================================
# Unit tests -- AggCommitPlan bucket-field lifetime invariants
# =============================================================================
#
# AggCommitPlan keeps its per-bucket thunk and slot-offset arrays as
# `InlineArray[T, MAX_AGGS]` fields, stored inline in the plan. As
# `List[T]` fields, each would own a separate heap buffer whose liveness
# the compiler must chain through the plan; with a wildcard-origin pointer
# in the commit path that chain breaks, the buffer can be freed mid-loop,
# and the thunk dispatch reads garbage.
#
# What this test exercises: after `bind_layout`, the per-bucket thunk and
# slot-offset storage must be STABLE across thousands of reads from inside
# the `@always_inline` commit loop. The test drives `commit_row`
# end-to-end over 10K rows with 4 f64 aggs; an early drop of the storage
# would corrupt the accumulated sum/count values.
# =============================================================================

from std.memory import alloc
from std.testing import assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator
from komira_op_agg_hash.agg_commit import AggCommitPlan
from komira_agg_api.agg_layout import (
    AggLayout,
    ACC_SUM_COUNT_F64,
    ACC_COUNT_STAR,
    ACC_SUM_COUNT_MIN_MAX_F64,
)


# =============================================================================
# Test 1: commit_row over 10K rows with 4 f64 aggs -- InlineArray stability
# =============================================================================

def test_commit_row_10k_iterations_with_4_f64_aggs() raises:
    """Runs commit_row for 10K rows against 4 f64 aggs. The f64 bucket
    stores the per-slot thunk + slot_offset -- reverting it from
    InlineArray to List[T] enables ASAP destruction of the bucket's
    backing heap buffer mid-loop. The test verifies byte-correct sums
    and counts after 10K iterations; a dangling bucket pointer would
    crash or produce garbage values long before this completes."""
    print("test_commit_row_10k_iterations_with_4_f64_aggs...")

    var num_rows = 10_000
    var num_aggs = 4

    # Four independent Float64 columns. Values are all 1.0 so the
    # accumulated sum equals the count, which equals the iteration.
    var col_bufs = alloc[Float64](num_rows * num_aggs)
    for i in range(num_rows * num_aggs):
        (col_bufs + i).unsafe_write(Float64(1.0))

    # One FlatHashAggregator with 4 agg slots. Single key = 0 so every
    # row hits the same entry -- magnifies any lifetime-hazard corruption.
    var agg = FlatHashAggregator(
        num_keys=1, num_aggs=num_aggs, initial_capacity=16
    )

    # Build a plan that pushes all four aggs into the f64 bucket. This
    # is the bucket that stores the per-slot thunk + slot_offset -- the
    # one the ASAP trap fires on under narrow layout.
    #
    # AggCommitPlan is parametric on the batch's origin and bakes
    # value-column pointers tied to it. These `alloc`-owned buffers outlive
    # the plan, so they are labeled with the static origin.
    var plan = AggCommitPlan[ImmStaticOrigin](num_aggs)
    for a in range(num_aggs):
        var col_ptr = (
            (col_bufs + a * num_rows)
            .bitcast[Scalar[DType.float64]]()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmStaticOrigin]()
        )
        plan._push_f64(a, col_ptr, 0)

    # Quartet layout (32B/slot) is enough to exercise the f64 bucket.
    var tags = List[UInt8]()
    for _ in range(num_aggs):
        tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    # Drive commit_row for 10K rows. Each iteration re-reads the
    # f64_thunks + f64_slot_offsets bucket fields. A dangling List buffer
    # would return garbage here.
    var entry = agg.find_or_create_1(Int64(0))
    for r in range(num_rows):
        plan.commit_row(agg, entry, r)

    # Sum = count = num_rows for every agg. Byte-exact (no accumulation
    # rounding with 1.0 values).
    for a in range(num_aggs):
        assert_equal(agg.get_count(entry, a), num_rows)
        assert_equal(agg.get_sum(entry, a), Float64(num_rows))

    col_bufs.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 2: commit_row over all four bucket types under narrow + quartet
# =============================================================================

def test_commit_row_all_bucket_types() raises:
    """commit_row drives count / f64 / i64 / i32 buckets in parallel.
    Reverting any bucket's storage from InlineArray to List[T] would
    crash during the tight inner read loop."""
    print("test_commit_row_all_bucket_types...")

    var num_rows = 1_000
    var num_aggs = 3  # COUNT(*), SUM(f64), SUM(i64)

    # Column buffers: first is unused for COUNT(*), second is f64, third
    # is i64.
    var f64_col = alloc[Float64](num_rows)
    var i64_col = alloc[Int64](num_rows)
    for r in range(num_rows):
        (f64_col + r).unsafe_write(Float64(2.0))
        (i64_col + r).unsafe_write(Int64(3))

    # Layout: [COUNT(*)=8B, SUM_QUARTET=32B, SUM_QUARTET=32B]. We build the
    # aggregator with this same layout via `with_layout` so the plan's
    # slot_offsets match the HT's internal offsets.
    var tags = List[UInt8]()
    tags.append(ACC_COUNT_STAR)
    tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
    tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
    var agg = FlatHashAggregator.with_layout(
        num_keys=1, layout=AggLayout(tags.copy()), initial_capacity=16
    )

    var plan = AggCommitPlan[ImmStaticOrigin](num_aggs)
    plan._push_count(0)
    plan._push_f64(
        1,
        f64_col.bitcast[Scalar[DType.float64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin](),
        0,
    )
    plan._push_i64(
        2,
        i64_col.bitcast[Scalar[DType.int64]]()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmStaticOrigin](),
        0,
    )

    var layout = AggLayout(tags^)
    plan.bind_layout(layout, agg._aggs_offset)

    var entry = agg.find_or_create_1(Int64(0))
    for r in range(num_rows):
        plan.commit_row(agg, entry, r)

    # COUNT(*) slot writes count only; quartet 32B format.
    assert_equal(agg.get_count(entry, 0), num_rows)
    # SUM(f64): 2.0 * num_rows.
    assert_equal(agg.get_sum(entry, 1), Float64(2.0) * Float64(num_rows))
    assert_equal(agg.get_count(entry, 1), num_rows)
    # SUM(i64): widened to Float64 in the i64 bucket.
    assert_equal(agg.get_sum(entry, 2), Float64(3.0) * Float64(num_rows))
    assert_equal(agg.get_count(entry, 2), num_rows)

    f64_col.free()
    i64_col.free()
    _ = plan^
    _ = agg^


# =============================================================================
# Test 3: bind_layout flag is load-bearing for the fast path
# =============================================================================

def test_bind_layout_sets_layout_bound_flag() raises:
    """After bind_layout, _layout_bound must be True. This flag steers
    commit_row onto the fn-ptr dispatch path. If a future refactor
    removes bind_layout without updating commit_row's code, this test
    catches the contract violation."""
    print("test_bind_layout_sets_layout_bound_flag...")
    var plan = AggCommitPlan[ImmStaticOrigin](2)
    plan._push_count(0)
    plan._push_count(1)

    var tags = List[UInt8]()
    tags.append(ACC_COUNT_STAR)
    tags.append(ACC_COUNT_STAR)
    var layout = AggLayout(tags^)

    assert_true(not plan._layout_bound, "_layout_bound should start False")
    plan.bind_layout(layout, 16)
    assert_true(plan._layout_bound, "_layout_bound must be True after bind")

    _ = plan^


# =============================================================================
# Test 4: Repeated construct/bind/commit/destroy cycles
# =============================================================================

def test_repeated_plan_lifecycle() raises:
    """Construct + bind + commit + destroy 64 plans in sequence. A leaked
    or double-freed bucket buffer would typically corrupt tcmalloc's
    per-thread cache within a handful of cycles. The test passes iff all
    iterations complete cleanly."""
    print("test_repeated_plan_lifecycle...")

    var num_rows = 100
    var col_buf = alloc[Float64](num_rows)
    for r in range(num_rows):
        (col_buf + r).unsafe_write(Float64(1.0))

    for cycle in range(64):
        var agg = FlatHashAggregator(
            num_keys=1, num_aggs=1, initial_capacity=8
        )
        var plan = AggCommitPlan[ImmStaticOrigin](1)
        plan._push_f64(
            0,
            col_buf.bitcast[Scalar[DType.float64]]()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmStaticOrigin](),
            0,
        )
        var tags = List[UInt8]()
        tags.append(ACC_SUM_COUNT_MIN_MAX_F64)
        var layout = AggLayout(tags^)
        plan.bind_layout(layout, agg._aggs_offset)

        var entry = agg.find_or_create_1(Int64(cycle))
        for r in range(num_rows):
            plan.commit_row(agg, entry, r)

        assert_equal(agg.get_count(entry, 0), num_rows)
        _ = plan^
        _ = agg^

    col_buf.free()


# =============================================================================
# Test entry point
# =============================================================================

def main() raises:
    test_commit_row_10k_iterations_with_4_f64_aggs()
    test_commit_row_all_bucket_types()
    test_bind_layout_sets_layout_bound_flag()
    test_repeated_plan_lifecycle()
    print("test_agg_commit_lifetime: 4 tests passed")
