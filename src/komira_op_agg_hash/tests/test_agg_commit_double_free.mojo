# =============================================================================
# Unit tests -- AggCommitPlan double-free + move-safety
# =============================================================================
#
# AggCommitPlan owns two heap allocations through its `_int_root` /
# `_ptr_root` Slabs, each freed exactly once by the Slab's destructor. Two
# hazards this test guards against:
#
#   1. Double-free after move. A move (`plan^`) transfers the roots to the
#      destination; the moved-from plan MUST NOT free them. The test
#      constructs, moves and destroys; a double free would abort in the
#      allocator.
#
#   2. Stale views after move. The view accessors derive their pointers
#      from the roots, so after a move the destination's views must point
#      into the transferred memory. The test confirms the view -> root
#      offset relationship survives.
#
# It also catches a regression to a Copyable plan or a hand-written
# non-transferring move constructor.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_hash.agg_commit import AggCommitPlan


# =============================================================================
# Test 1: Construct + destroy -- single ownership, single free
# =============================================================================

def test_construct_destroy_no_crash() raises:
    """A single plan constructed and destroyed must not crash.

    `_int_root` is a `Slab[Int]` owner, freed by the Slab's destructor.
    These tests construct plans with no value columns (they exercise
    root ownership/move/destroy only), so the batch origin parameter is
    a pure label: the static origin.
    """
    var plan = AggCommitPlan[ImmStaticOrigin](4)
    var addr = Int(plan._int_root._mut_ptr(0))
    # Invariant: root is non-null for a non-empty plan.
    assert_true(addr != 0, "int_root must be non-null for num_aggs > 0")
    _ = plan^


# =============================================================================
# Test 2: Move transfers ownership without double-free
# =============================================================================

def _consume_plan(var p: AggCommitPlan[ImmStaticOrigin]) raises -> Int:
    """Take ownership of a plan, return its int-root address, drop it."""
    var addr = Int(p._int_root._mut_ptr(0))
    _ = p^
    return addr


def test_move_transfers_ownership() raises:
    """After `plan^`, the destination owns the Slab fields and the
    source is gone. Running destructors on the moved-from value would
    be a double-free; Mojo's move semantics prevent that.
    """
    var plan = AggCommitPlan[ImmStaticOrigin](4)
    var addr_before = Int(plan._int_root._mut_ptr(0))

    # Transfer ownership into the helper. Helper frees it.
    var addr_seen = _consume_plan(plan^)

    # The address the helper saw must match the pre-move address:
    # a move must NOT reallocate or duplicate the backing memory.
    assert_equal(addr_before, addr_seen)


# =============================================================================
# Test 3: View pointers remain valid offsets after move
# =============================================================================

def _check_view_offsets(var p: AggCommitPlan[ImmStaticOrigin]) raises:
    """Verify all 10 views still live inside the two root allocs after
    a move into this helper's stack frame."""
    var int_root = Int(p._int_root._mut_ptr(0))
    var ptr_root = Int(p._ptr_root._mut_ptr(0))
    var n = 4  # must match the construction size below

    # Int views: each at root + j * n * 8 via accessor.
    for j in range(7):
        assert_equal(Int(p._int_view_ptr(j)) - int_root, j * n * 8)

    # Pointer views: each at root + i * n * 8.
    assert_equal(Int(p._f64_ptrs()) - ptr_root, 0 * n * 8)
    assert_equal(Int(p._i64_ptrs()) - ptr_root, 1 * n * 8)
    assert_equal(Int(p._i32_ptrs()) - ptr_root, 2 * n * 8)

    _ = p^


def test_views_survive_move() raises:
    """After a move, every view pointer still aliases the (moved)
    root. The offset arithmetic from test_agg_commit_view_bounds must
    still hold post-move."""
    var plan = AggCommitPlan[ImmStaticOrigin](4)
    _check_view_offsets(plan^)


# =============================================================================
# Test 4: Repeated construct/destroy cycles don't accumulate leaks / reuse
# =============================================================================

def test_repeated_construction() raises:
    """Construct and destroy many plans in sequence. Each must allocate
    cleanly and free cleanly. A double-free in __del__ would typically
    corrupt the allocator's free list and surface within a handful of
    cycles; we run 128.
    """
    for _ in range(128):
        var plan = AggCommitPlan[ImmStaticOrigin](4)
        assert_true(Int(plan._int_root._mut_ptr(0)) != 0)
        assert_true(Int(plan._ptr_root._mut_ptr(0)) != 0)
        _ = plan^


# =============================================================================
# Test entry point
# =============================================================================

def main() raises:
    test_construct_destroy_no_crash()
    test_move_transfers_ownership()
    test_views_survive_move()
    test_repeated_construction()
    print("test_agg_commit_double_free: 4 tests passed")
