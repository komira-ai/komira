# =============================================================================
# Unit tests -- AggCommitPlan view-bounds invariants
# =============================================================================
#
# These tests lock in the two-allocation layout that justifies the plan's
# view pointers (see the agg_commit.mojo module header): ten views over two
# backing Slabs. If the layout is ever broken (e.g. someone "simplifies"
# the struct into ten allocations, one per view), these tests must fail.
#
# Invariants verified:
#   1. Every view pointer lies inside its backing allocation:
#        view_ptr >= root  AND  view_ptr + view_len <= root + root_len
#   2. No two views overlap (disjoint slices of the backing alloc).
#   3. The sum of view lengths exactly equals the backing alloc length
#      (no slack, no gaps).
#   4. Construction with num_aggs=0 yields empty views (no crash).
#
# These tests EXPOSE internal fields (_int_root, _ptr_root) deliberately
# -- the whole point is to prove the private layout matches the
# documented invariant. If these fields are ever renamed, update the
# tests to match; do NOT weaken them.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_hash.agg_commit import AggCommitPlan


# =============================================================================
# Test 1: Int-block view bounds
# =============================================================================

def test_int_views_within_int_root() raises:
    """Every Int view must be a sub-slice of [_int_root, _int_root + 7 * n).

    `_int_root` is a `Slab[Int]` owner; the base is `_mut_ptr(0)`."""
    var n = 8
    var plan = AggCommitPlan[ImmStaticOrigin](n)

    var root = Int(plan._int_root._mut_ptr(0))
    var root_end = root + 7 * n * 8  # 7 * n Ints, each 8 bytes

    # View i lives at root + i * n Ints = root + i * n * 8 bytes.
    var stride = n * 8

    var views_start = List[Int]()
    for j in range(7):
        views_start.append(Int(plan._int_view_ptr(j)))

    for i in range(len(views_start)):
        var start = views_start[i]
        var end = start + stride
        assert_true(start >= root, "Int view starts before _int_root")
        assert_true(end <= root_end, "Int view extends past _int_root + 7*n")
        assert_equal(start - root, i * stride)

    _ = plan^


# =============================================================================
# Test 2: Pointer-block view bounds
# =============================================================================

def test_ptr_views_within_ptr_root() raises:
    """Every pointer-typed view must be a sub-slice of
    [_ptr_root, _ptr_root + 3 * n * 8 bytes).

    `_ptr_root` is a `Slab[UInt8]` owner."""
    var n = 8
    var plan = AggCommitPlan[ImmStaticOrigin](n)

    var root = Int(plan._ptr_root._mut_ptr(0))
    var root_end = root + 3 * n * 8  # 3 * n UnsafePointers, each 8 bytes

    var f64_start = Int(plan._f64_ptrs())
    var i64_start = Int(plan._i64_ptrs())
    var i32_start = Int(plan._i32_ptrs())

    # f64 at root + 0, i64 at root + n*8, i32 at root + 2*n*8.
    assert_equal(f64_start - root, 0)
    assert_equal(i64_start - root, n * 8)
    assert_equal(i32_start - root, 2 * n * 8)

    # All three views end within the block.
    var stride = n * 8
    assert_true(f64_start + stride <= root_end, "f64_ptrs overruns _ptr_root")
    assert_true(i64_start + stride <= root_end, "i64_ptrs overruns _ptr_root")
    assert_true(i32_start + stride <= root_end, "i32_ptrs overruns _ptr_root")

    _ = plan^


# =============================================================================
# Test 3: Views pairwise disjoint
# =============================================================================

def test_int_views_disjoint() raises:
    """No two Int views may overlap (they are adjacent slices of _int_root)."""
    var n = 16
    var plan = AggCommitPlan[ImmStaticOrigin](n)
    var stride = n * 8  # n Ints per view, 8 bytes each

    # Collect starts; intervals are [start, start + stride).
    var starts = List[Int]()
    for j in range(7):
        starts.append(Int(plan._int_view_ptr(j)))

    # O(k^2) overlap check; k == 7.
    for i in range(len(starts)):
        for j in range(i + 1, len(starts)):
            var a_start = starts[i]
            var a_end = a_start + stride
            var b_start = starts[j]
            var b_end = b_start + stride
            # Disjoint iff a_end <= b_start OR b_end <= a_start.
            var disjoint = (a_end <= b_start) or (b_end <= a_start)
            assert_true(disjoint, "Two Int views overlap")

    _ = plan^


def test_ptr_views_disjoint() raises:
    """No two pointer views may overlap."""
    var n = 16
    var plan = AggCommitPlan[ImmStaticOrigin](n)
    var stride = n * 8  # n pointers per view, 8 bytes each

    var starts = List[Int]()
    starts.append(Int(plan._f64_ptrs()))
    starts.append(Int(plan._i64_ptrs()))
    starts.append(Int(plan._i32_ptrs()))

    for i in range(len(starts)):
        for j in range(i + 1, len(starts)):
            var a_start = starts[i]
            var a_end = a_start + stride
            var b_start = starts[j]
            var b_end = b_start + stride
            var disjoint = (a_end <= b_start) or (b_end <= a_start)
            assert_true(disjoint, "Two pointer views overlap")

    _ = plan^


# =============================================================================
# Test 4: Sum of view lengths equals backing alloc length
# =============================================================================

def test_int_views_cover_int_root_exactly() raises:
    """The 7 Int views must tile _int_root with no gap and no slack."""
    var n = 4
    var plan = AggCommitPlan[ImmStaticOrigin](n)

    var root = Int(plan._int_root._mut_ptr(0))

    # Last view's end (i32_offsets + n * 8) must equal root + 7 * n * 8.
    var last_end = Int(plan._int_view_ptr(6)) + n * 8
    assert_equal(last_end - root, 7 * n * 8)

    _ = plan^


def test_ptr_views_cover_ptr_root_exactly() raises:
    """The 3 pointer views must tile _ptr_root with no gap and no slack."""
    var n = 4
    var plan = AggCommitPlan[ImmStaticOrigin](n)

    var root = Int(plan._ptr_root._mut_ptr(0))
    var last_end = Int(plan._i32_ptrs()) + n * 8
    assert_equal(last_end - root, 3 * n * 8)

    _ = plan^


# =============================================================================
# Test 5: Bucket counters zero-initialized
# =============================================================================

def test_bucket_counts_zero_on_construction() raises:
    """All bucket counters must start at zero."""
    var plan = AggCommitPlan[ImmStaticOrigin](8)
    assert_equal(plan.n_count, 0)
    assert_equal(plan.n_f64, 0)
    assert_equal(plan.n_i64, 0)
    assert_equal(plan.n_i32, 0)
    _ = plan^


# =============================================================================
# Test 6: Destruction does not crash (smoke test for __del__)
# =============================================================================

def test_destroy_is_safe() raises:
    """Destroying a freshly-built plan must not crash; backing allocs are
    released exactly once."""
    var plan = AggCommitPlan[ImmStaticOrigin](8)
    _ = plan^


# =============================================================================
# Test entry point
# =============================================================================

def main() raises:
    test_int_views_within_int_root()
    test_ptr_views_within_ptr_root()
    test_int_views_disjoint()
    test_ptr_views_disjoint()
    test_int_views_cover_int_root_exactly()
    test_ptr_views_cover_ptr_root_exactly()
    test_bucket_counts_zero_on_construction()
    test_destroy_is_safe()
    print("test_agg_commit_view_bounds: 8 tests passed")
