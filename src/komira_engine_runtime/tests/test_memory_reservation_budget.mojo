# =============================================================================
# test_memory_reservation_budget.mojo — MemoryReservation primitive tests
# =============================================================================
#
# What each test proves:
#   1. test_default_ctor_infinite_budget — default ctor leaves budget
#      at the unset sentinel; try_grow always returns True regardless
#      of the requested grow size; denied_count stays 0.
#   2. test_with_budget_under_threshold — finite budget with grows
#      summing to less than the budget all return True; denied_count
#      stays 0; held_bytes accumulates correctly.
#   3. test_with_budget_exceeded — finite budget where one grow pushes
#      tally past the budget returns False; denied_count == 1;
#      held_bytes is NOT incremented on the rejected grow.
#   4. test_with_budget_exceeded_multiple — repeated rejected grows
#      bump denied_count once per rejection.
#   5. test_release_symmetric — release decrements held_bytes; a
#      previously-rejected grow then succeeds after release frees
#      headroom.
#   6. test_with_budget_zero — explicit zero budget rejects any
#      positive grow.
#
#   7. test_for_host_takes_the_profile_budget: the budget is the host
#      profile's memory budget, to the byte.
#   8. test_for_host_reference_profile_is_constant: the reference profile
#      gives every machine the same budget.
#   9. test_with_budget_negative_means_none: a negative budget is "none".
#  10. test_grow_of_int_max_is_denied_not_wrapped: a huge grow is denied.
#  11. test_negative_grow_is_refused_and_counted: a negative grow is denied.
#  12. test_grow_of_exactly_budget_minus_held: the exact headroom fits.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_host_profile.host_profile import (
    HostProfile,
    reference_host_profile,
)
from komira_engine_runtime.memory.reservation import MemoryReservation


# =============================================================================
# Test 1 — default ctor: infinite budget, try_grow never denies
# =============================================================================


def test_default_ctor_infinite_budget() raises:
    """Default ctor leaves budget unset; try_grow always returns True."""
    var r = MemoryReservation()
    assert_false(r.has_budget(), "default ctor leaves budget unset")

    # Large grows all succeed; no denials.
    assert_true(r.try_grow(1_000_000), "1M-byte grow on infinite budget")
    assert_true(r.try_grow(10_000_000), "10M-byte grow on infinite budget")
    assert_true(r.try_grow(0), "zero-byte grow on infinite budget")
    assert_equal(r.held_bytes(), 11_000_000)
    assert_equal(r.try_grow_denied_count(), 0)


# =============================================================================
# Test 2 — finite budget, all grows under threshold
# =============================================================================


def test_with_budget_under_threshold() raises:
    """Finite budget; cumulative grows stay under the budget."""
    var r = MemoryReservation.with_budget(1024)
    assert_true(r.has_budget(), "with_budget configures a budget")
    assert_equal(r.budget_bytes(), 1024)

    assert_true(r.try_grow(100))
    assert_true(r.try_grow(200))
    assert_true(r.try_grow(700))  # exactly fits (100+200+700 = 1000 <= 1024)
    assert_equal(r.held_bytes(), 1000)
    assert_equal(r.try_grow_denied_count(), 0)


# =============================================================================
# Test 3 — finite budget exceeded by a single grow returns False
# =============================================================================


def test_with_budget_exceeded() raises:
    """A grow that pushes tally past the budget returns False;
    denied_count == 1; held_bytes NOT incremented."""
    var r = MemoryReservation.with_budget(1024)
    assert_true(r.try_grow(1000), "1000-byte grow under 1024 budget")
    assert_equal(r.held_bytes(), 1000)

    # 1000 + 100 = 1100 > 1024 → denied.
    var ok = r.try_grow(100)
    assert_false(ok, "1100-byte tally exceeds 1024 budget")
    assert_equal(r.try_grow_denied_count(), 1)
    # held_bytes NOT incremented on rejected grow — the caller must be
    # able to choose to spill before retrying with the same n_bytes.
    assert_equal(r.held_bytes(), 1000)


# =============================================================================
# Test 4 — multiple rejected grows bump denied_count repeatedly
# =============================================================================


def test_with_budget_exceeded_multiple() raises:
    """Each rejected grow bumps denied_count by one. A successful grow
    in between does not reset the counter."""
    var r = MemoryReservation.with_budget(1024)
    _ = r.try_grow(1000)  # OK
    assert_false(r.try_grow(100), "first reject")
    assert_false(r.try_grow(200), "second reject")
    assert_false(r.try_grow(50), "third reject (50 still > headroom 24)")
    assert_equal(r.try_grow_denied_count(), 3)

    # A small successful grow doesn't reset the counter.
    assert_true(r.try_grow(20))
    assert_equal(r.try_grow_denied_count(), 3)
    assert_equal(r.held_bytes(), 1020)


# =============================================================================
# Test 5 — release frees headroom, allowing previously-rejected grows
# =============================================================================


def test_release_symmetric() raises:
    """Release decrements held_bytes; a previously-rejected grow then
    succeeds with the freed headroom."""
    var r = MemoryReservation.with_budget(1024)
    _ = r.try_grow(1000)
    assert_false(r.try_grow(200), "200 over 1024 budget after 1000")
    assert_equal(r.try_grow_denied_count(), 1)

    # Release 800 bytes; new headroom = 1024 - 200 = 824.
    r.release(800)
    assert_equal(r.held_bytes(), 200)

    # 200 + 200 = 400 fits.
    assert_true(r.try_grow(200))
    assert_equal(r.held_bytes(), 400)
    # denied_count is sticky (cumulative observability counter).
    assert_equal(r.try_grow_denied_count(), 1)


# =============================================================================
# Test 6 — zero budget rejects any positive grow
# =============================================================================


def test_with_budget_zero() raises:
    """A budget of 0 rejects any positive grow; zero-byte grows are
    accepted (vacuous)."""
    var r = MemoryReservation.with_budget(0)
    assert_true(r.has_budget(), "zero is a budget, not unset")
    assert_equal(r.budget_bytes(), 0)

    # 0 + 0 = 0 <= 0 → allowed.
    assert_true(r.try_grow(0))
    # 0 + 1 = 1 > 0 → denied.
    assert_false(r.try_grow(1))
    assert_equal(r.try_grow_denied_count(), 1)


# =============================================================================
# Test 7-9: the budget comes from the host profile
# =============================================================================


def _profile_with_budget(budget: Int) raises -> HostProfile:
    var ref_profile = reference_host_profile(String("test"))
    return HostProfile(
        ref_profile.engine_build,
        ref_profile.hardware.copy(),
        ref_profile.thread_count,
        budget,
        ref_profile.spill_tiers,
    )


def test_for_host_takes_the_profile_budget() raises:
    """`for_host` budgets exactly the profile's `memory_budget_bytes`: a grow
    to the budget succeeds and one more byte is denied."""
    var r = MemoryReservation.for_host(_profile_with_budget(4096))
    assert_true(r.has_budget())
    assert_equal(r.budget_bytes(), 4096)
    assert_true(r.try_grow(4096), "a grow to exactly the budget fits")
    assert_false(r.try_grow(1), "one byte past the budget is denied")
    assert_equal(r.held_bytes(), 4096)
    assert_equal(r.try_grow_denied_count(), 1)


def test_for_host_reference_profile_is_constant() raises:
    """Two reservations for the reference profile get the same budget, so a
    breaker's spill decisions do not depend on the machine the plan is
    compared on."""
    var a = MemoryReservation.for_host(reference_host_profile(String("x")))
    var b = MemoryReservation.for_host(reference_host_profile(String("y")))
    assert_true(a.budget_bytes() > 0)
    assert_equal(a.budget_bytes(), b.budget_bytes())


def test_with_budget_negative_means_none() raises:
    """A negative budget is "no budget", the same as the default ctor; it is
    not a 0 budget that would deny everything."""
    var r = MemoryReservation.with_budget(-5)
    assert_false(r.has_budget())
    assert_true(r.try_grow(1 << 40))
    assert_equal(r.try_grow_denied_count(), 0)


def test_grow_of_int_max_is_denied_not_wrapped() raises:
    """`held + n` would wrap negative for a huge `n`; the grow must be denied
    and the tally untouched."""
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(50))
    assert_false(r.try_grow(Int.MAX), "Int.MAX over a budget of 100")
    assert_equal(r.held_bytes(), 50)
    assert_equal(r.try_grow_denied_count(), 1)


def test_negative_grow_is_refused_and_counted() raises:
    """A negative grow does not act as a release: it is denied, counted, and
    leaves the tally alone, with a budget and without one."""
    var b = MemoryReservation.with_budget(100)
    assert_true(b.try_grow(60))
    assert_false(b.try_grow(-30), "negative grow under a budget")
    assert_equal(b.held_bytes(), 60)
    assert_equal(b.try_grow_denied_count(), 1)

    var u = MemoryReservation()
    assert_true(u.try_grow(10))
    assert_false(u.try_grow(-4), "negative grow without a budget")
    assert_equal(u.held_bytes(), 10)
    assert_equal(u.try_grow_denied_count(), 1)


def test_grow_of_exactly_budget_minus_held() raises:
    """The headroom `budget - held` fits; one byte more does not."""
    var r = MemoryReservation.with_budget(100)
    assert_true(r.try_grow(37))
    assert_false(r.try_grow(64), "headroom is 63")
    assert_true(r.try_grow(63), "exactly the headroom fits")
    assert_equal(r.held_bytes(), 100)
    assert_equal(r.try_grow_denied_count(), 1)


# =============================================================================
# Test entry point
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_default_ctor_infinite_budget]()
    suite.test[test_with_budget_under_threshold]()
    suite.test[test_with_budget_exceeded]()
    suite.test[test_with_budget_exceeded_multiple]()
    suite.test[test_release_symmetric]()
    suite.test[test_with_budget_zero]()
    suite.test[test_for_host_takes_the_profile_budget]()
    suite.test[test_for_host_reference_profile_is_constant]()
    suite.test[test_with_budget_negative_means_none]()
    suite.test[test_grow_of_int_max_is_denied_not_wrapped]()
    suite.test[test_negative_grow_is_refused_and_counted]()
    suite.test[test_grow_of_exactly_budget_minus_held]()
    suite^.run()
