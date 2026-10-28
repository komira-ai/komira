# The MemoryReservation budget contract: with no budget every grow succeeds and
# is tallied; with a budget, a grow that would pass it is refused, counted, and
# leaves the tally unchanged; a grow that lands exactly on the budget succeeds;
# release takes bytes back so a refused grow then fits; a negative budget means
# no budget.

from std.testing import assert_equal, assert_false, assert_true

from komira_operator_api.memory_reservation import (
    BUDGET_UNSET,
    MemoryReservation,
)


def test_no_budget_always_grows() raises:
    var r = MemoryReservation()
    assert_false(r.has_budget(), "default has no budget")
    assert_equal(r.budget_bytes(), BUDGET_UNSET)
    assert_true(r.try_grow(1 << 40), "huge grow with no budget")
    assert_true(r.try_grow(7), "second grow with no budget")
    assert_equal(r.held_bytes(), (1 << 40) + 7, "tally kept without a budget")
    assert_equal(r.try_grow_denied_count(), 0)
    r.release(7)
    assert_equal(r.held_bytes(), 1 << 40)


def test_budget_refuses_and_counts() raises:
    var r = MemoryReservation.with_budget(100)
    assert_true(r.has_budget())
    assert_equal(r.budget_bytes(), 100)
    assert_true(r.try_grow(60), "60 of 100")
    assert_false(r.try_grow(41), "60 + 41 passes 100")
    assert_equal(r.held_bytes(), 60, "a refused grow leaves the tally")
    assert_equal(r.try_grow_denied_count(), 1)
    assert_true(r.try_grow(40), "60 + 40 lands exactly on the budget")
    assert_equal(r.held_bytes(), 100)
    assert_false(r.try_grow(1), "full")
    assert_equal(r.try_grow_denied_count(), 2)
    r.release(50)
    assert_equal(r.held_bytes(), 50)
    assert_true(r.try_grow(41), "fits after the release")
    assert_equal(r.held_bytes(), 91)
    assert_equal(r.try_grow_denied_count(), 2)


def test_zero_and_negative_budget() raises:
    var z = MemoryReservation.with_budget(0)
    assert_true(z.has_budget(), "zero is a budget")
    assert_true(z.try_grow(0), "a zero grow fits a zero budget")
    assert_false(z.try_grow(1), "one byte does not")
    var n = MemoryReservation.with_budget(-5)
    assert_false(n.has_budget(), "a negative budget is no budget")
    assert_true(n.try_grow(1 << 30))


def main() raises:
    test_no_budget_always_grows()
    test_budget_refuses_and_counts()
    test_zero_and_negative_budget()
    print("test_memory_reservation: OK")
