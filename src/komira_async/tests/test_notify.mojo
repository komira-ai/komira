# =============================================================================
# test_notify.mojo
# =============================================================================
# Notify real-impl tests.
#
#
#
# Stateless event. notify_one wakes 1 (lost if no waiter); notify_waiters
# wakes all; notify_one_permit stores at-most-1 permit if no waiter.
#
# This form ships the synchronous-park form. Multi-thread tests where
# notified() actually parks are deferred (would require
# pthread orchestration; this file tests the no-park / permit-consume
# paths).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.sync.notify import Notify


# -----------------------------------------------------------------------------
# Construction
# -----------------------------------------------------------------------------


def test_notify_construct() raises:
    """Notify.new() initializes with no permit + gen=0."""
    var n = Notify.new()
    assert_false(n.has_stored_permit())
    assert_equal(Int(n.gen_value()), 0)
    _ = n^


# -----------------------------------------------------------------------------
# notify_one_permit + notified consume path
# -----------------------------------------------------------------------------


def test_notify_one_permit_then_notified_consumes() raises:
    """notify_one_permit stores a permit; next notified() returns
    immediately by consuming it (no park)."""
    var n = Notify.new()
    n.notify_one_permit()
    assert_true(n.has_stored_permit())
    n.notified()
    assert_false(n.has_stored_permit())


def test_notify_one_permit_idempotent() raises:
    """Multiple notify_one_permit calls coalesce to at-most-1 permit."""
    var n = Notify.new()
    n.notify_one_permit()
    n.notify_one_permit()
    n.notify_one_permit()
    assert_true(n.has_stored_permit())  # Still 1, not 3.
    # Consume one.
    n.notified()
    assert_false(n.has_stored_permit())


# -----------------------------------------------------------------------------
# Gen counter advances on notify_*
# -----------------------------------------------------------------------------


def test_notify_one_advances_gen() raises:
    """notify_one bumps the generation counter."""
    var n = Notify.new()
    var g0 = n.gen_value()
    n.notify_one()
    var g1 = n.gen_value()
    assert_equal(Int(g1 - g0), 1)


def test_notify_waiters_advances_gen() raises:
    """notify_waiters bumps the generation counter."""
    var n = Notify.new()
    var g0 = n.gen_value()
    n.notify_waiters()
    var g1 = n.gen_value()
    assert_equal(Int(g1 - g0), 1)


def test_notify_one_permit_advances_gen() raises:
    """notify_one_permit bumps gen too (in addition to storing permit)."""
    var n = Notify.new()
    var g0 = n.gen_value()
    n.notify_one_permit()
    var g1 = n.gen_value()
    assert_equal(Int(g1 - g0), 1)


def test_notify_repeated_notifies_advance_gen() raises:
    """100 notify_one calls advance gen by 100."""
    var n = Notify.new()
    var g0 = n.gen_value()
    for _ in range(100):
        n.notify_one()
    var g1 = n.gen_value()
    assert_equal(Int(g1 - g0), 100)


# -----------------------------------------------------------------------------
# notify_one without waiter is LOST (no permit stored)
# -----------------------------------------------------------------------------


def test_notify_one_no_permit_stored() raises:
    """notify_one (NOT notify_one_permit) does NOT store a permit;
    subsequent notified would park forever (we don't test the park
    here — just verify no permit was stored)."""
    var n = Notify.new()
    n.notify_one()
    assert_false(n.has_stored_permit())


# -----------------------------------------------------------------------------
# Top-level driver
# -----------------------------------------------------------------------------


def main() raises:
    test_notify_construct()
    test_notify_one_permit_then_notified_consumes()
    test_notify_one_permit_idempotent()
    test_notify_one_advances_gen()
    test_notify_waiters_advances_gen()
    test_notify_one_permit_advances_gen()
    test_notify_repeated_notifies_advance_gen()
    test_notify_one_no_permit_stored()
    print("PASS komira_async.sync.notify 8 tests")
