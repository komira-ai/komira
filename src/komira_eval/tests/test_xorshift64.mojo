# =============================================================================
# Tests for `XorShift64` — per-worker RNG primitive.
#
# Coverage:
#   - Constructors: `from_seed` (explicit) + `from_worker_id` (derived).
#   - `next_u64()` advances state and returns non-zero output (state
#     non-zero by construction).
#   - Determinism: same seed → same sequence.
#   - Distinct workers produce DISTINCT streams (the property the
#     design relies on for AdaptiveFilter EXPLORATION).
#   - Zero-seed defensive: `from_seed(0)` substitutes the golden ratio
#     so the stream does NOT lock at zero.
#   - `next_in_range(n)` returns values in [0, n).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_eval.xorshift64 import (
    XorShift64,
    XORSHIFT64_GOLDEN_RATIO,
    XORSHIFT64_SEED_MULTIPLIER,
)


# -----------------------------------------------------------------------------
# Constructors
# -----------------------------------------------------------------------------


def test_from_seed_records_state() raises:
    """`from_seed(s)` initializes state to s for non-zero s."""
    var r = XorShift64.from_seed(UInt64(42))
    assert_equal(r.state, UInt64(42))


def test_from_seed_zero_substitutes_golden_ratio() raises:
    """A zero seed would lock xorshift at zero — defensive substitution."""
    var r = XorShift64.from_seed(UInt64(0))
    assert_equal(r.state, XORSHIFT64_GOLDEN_RATIO)


def test_from_worker_id_matches_combiner_formula() raises:
    """`from_worker_id(wid)` matches the documented combiner formula."""
    for wid in range(0, 8):
        var r = XorShift64.from_worker_id(wid)
        var expected = (
            UInt64(wid + 1) * XORSHIFT64_SEED_MULTIPLIER
            + XORSHIFT64_GOLDEN_RATIO
        )
        assert_equal(r.state, expected)


# -----------------------------------------------------------------------------
# Mutation / determinism
# -----------------------------------------------------------------------------


def test_next_u64_advances_state() raises:
    """`next_u64()` mutates state (xorshift step changes the value)."""
    var r = XorShift64.from_seed(UInt64(1))
    var s0 = r.state
    _ = r.next_u64()
    assert_true(r.state != s0)


def test_same_seed_yields_same_sequence() raises:
    """Determinism: two RNGs seeded identically produce the same stream."""
    var r1 = XorShift64.from_seed(UInt64(123456789))
    var r2 = XorShift64.from_seed(UInt64(123456789))
    for _ in range(64):
        var v1 = r1.next_u64()
        var v2 = r2.next_u64()
        assert_equal(v1, v2)


def test_distinct_worker_ids_yield_distinct_streams() raises:
    """Adjacent worker_ids produce distinct first values.

    The AdaptiveFilter design relies on this: each per-worker
    AdaptiveFilter must follow its OWN EXPLORATION path, not lockstep
    with sibling workers. This test covers the smaller adjacent-pair guarantee.
    """
    var prev_v = UInt64(0)
    var prev_set = False
    for wid in range(0, 8):
        var r = XorShift64.from_worker_id(wid)
        var v = r.next_u64()
        if prev_set:
            assert_true(v != prev_v)
        prev_v = v
        prev_set = True


# -----------------------------------------------------------------------------
# Range bounding
# -----------------------------------------------------------------------------


def test_next_in_range_bounded() raises:
    """`next_in_range(n)` returns values in [0, n)."""
    var r = XorShift64.from_seed(UInt64(0xABCDEF12_34567890))
    for _ in range(1000):
        var v = r.next_in_range(UInt64(16))
        assert_true(v < UInt64(16))


def test_next_in_range_covers_range() raises:
    """Over enough draws, all buckets in a small range should be hit.

    Sanity check on the stream's mixing — if every draw collided, the
    state machine using this RNG would never explore alternatives.
    """
    var r = XorShift64.from_seed(UInt64(7))
    var hits = List[Bool]()
    for _ in range(8):
        hits.append(False)
    # 8 buckets, 1000 draws — by birthday-paradox / coupon-collector,
    # expected all-bucket coverage in ~20 draws. 1000 is overkill.
    for _ in range(1000):
        var v = Int(r.next_in_range(UInt64(8)))
        hits[v] = True
    for i in range(8):
        assert_true(hits[i], "bucket " + String(i) + " never hit")


# -----------------------------------------------------------------------------
# Movability / copyability under composition (Slab-compatible)
# -----------------------------------------------------------------------------


def test_xorshift_is_movable_and_copyable() raises:
    """XorShift64 must be Movable + Copyable for `Slab[T]` storage and
    for being held as a field of `AdaptiveFilter` (which is itself
    Movable for slab storage)."""
    var r = XorShift64.from_seed(UInt64(99))
    var moved = r^  # move ctor
    assert_equal(moved.state, UInt64(99))
    var copied = moved  # implicit copy
    assert_equal(copied.state, moved.state)


# -----------------------------------------------------------------------------
# Suite entry
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
