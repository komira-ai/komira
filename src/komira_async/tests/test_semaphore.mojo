# =============================================================================
# test_semaphore.mojo
# =============================================================================
# Semaphore + SemPermit real-impl tests.
#
#
#
# Bounded concurrent permits. acquire(n) parks if insufficient; release
# (via SemPermit drop) wakes waiters via Mechanism D.
#
# This is the synchronous-park form (mirrors AsyncMutex). Multi-thread contended-acquire tests are deferred
# integration.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.sync.semaphore import Semaphore, SemPermit


# -----------------------------------------------------------------------------
# Construction + try_acquire fast path
# -----------------------------------------------------------------------------


def test_semaphore_construct() raises:
    """Semaphore.new(4) initializes with 4 permits available."""
    var s = Semaphore.new(4)
    assert_equal(Int(s.available_permits()), 4)
    assert_equal(Int(s.max_permits()), 4)
    _ = s^


def test_semaphore_try_acquire_one() raises:
    """try_acquire(1) on 4-permit sem returns Some; counter -> 3."""
    var s = Semaphore.new(4)
    var maybe_p = s.try_acquire(1)
    assert_true(maybe_p.__bool__(), "try_acquire(1) on full sem returns Some")
    assert_equal(Int(s.available_permits()), 3)
    var p = maybe_p.take()
    _ = p^
    _ = maybe_p^


def test_semaphore_try_acquire_n() raises:
    """try_acquire(2) when 4 free; succeeds; counter -> 2."""
    var s = Semaphore.new(4)
    var maybe_p = s.try_acquire(2)
    assert_true(maybe_p.__bool__())
    assert_equal(Int(s.available_permits()), 2)
    var p = maybe_p.take()
    _ = p^
    _ = maybe_p^


def test_semaphore_acquire_uncontested() raises:
    """acquire() on free sem returns immediately without parking."""
    var s = Semaphore.new(4)
    var p = s.acquire(1)
    assert_equal(Int(s.available_permits()), 3)
    _ = p^
    assert_equal(Int(s.available_permits()), 4)


def test_semaphore_permit_drop_returns_count() raises:
    """A single permit acquire+drop round trip preserves permit count."""
    var s = Semaphore.new(2)
    var p = s.acquire(1)
    assert_equal(Int(s.available_permits()), 1)
    _ = p^
    assert_equal(Int(s.available_permits()), 2)


def test_semaphore_acquire_drop_cycle() raises:
    """100 acquire+drop cycles preserve permit count."""
    var s = Semaphore.new(2)
    for _ in range(100):
        var p = s.acquire(1)
        _ = p^
    assert_equal(Int(s.available_permits()), 2)


def test_semaphore_add_permits_grows_pool() raises:
    """add_permits raises pool size."""
    var s = Semaphore.new(2)
    s.add_permits(3)
    assert_equal(Int(s.available_permits()), 5)


# -----------------------------------------------------------------------------
# Regression test for destructor-ordering bug
# -----------------------------------------------------------------------------
# Repeatedly invoking try_acquire on a fresh Semaphore exposes a
# Mojo 0.26.3 destructor-ordering bug on darwin-arm64: the AOT optimizer
# hoists the SemPermit destructor's pointer-to-_SemaphoreShared above the
# Semaphore's ArcPointer drop, then the cached pointer is dangling when
# the SemPermit destructor body runs.
#
# Before the fix, this crashes with tcmalloc::Log "Attempt to free invalid
# pointer" + SIGABRT on the THIRD construct/try_acquire/drop cycle in a
# row (allocator state needs to cross a threshold).
#
# Crash signature:
#   `tcmalloc.cc:302] Attempt to free invalid pointer 0x...`
#   frame #6: tc_free
#   frame #7: ArcPointer<_SemaphoreShared>::__del__
#   frame #8: test_semaphore_try_acquire_one
#
# Root cause: the SemPermit's `_sem: Pointer[Semaphore, sem_origin]` field
# defers liveness tracking through an Optional wrapper, but Mojo 0.26.3's
# borrow checker doesn't propagate the `sem_origin` parameter through
# Optional's payload. The destructor schedule effectively drops `s` first,
# then runs SemPermit's drop body which dereferences the freed ArcPointer.
#
# Fix: SemPermit holds an ArcPointer[_SemaphoreShared] (a refcounted clone
# of Semaphore's _shared). The permit's destructor operates on the shared
# state via its own ArcPointer; SemPermit's lifetime no longer depends on
# the Semaphore wrapper outliving it.


def test_regression_semaphore_destructor_order_3x() raises:
    """REGRESSION TEST. 3x construct + try_acquire +
    drop cycles. Before the fix, this crashed at SIGABRT on the 3rd
    iteration via tc_free invalid-pointer detection. After the fix,
    SemPermit's ArcPointer-cloned ownership decouples its destructor
    from the Semaphore wrapper's drop schedule, and 3+ cycles are safe."""
    for _ in range(3):
        var s = Semaphore.new(4)
        var maybe_p = s.try_acquire(1)
        assert_true(maybe_p.__bool__())
        var p = maybe_p.take()
        _ = p^
        _ = maybe_p^
        _ = s^


def test_regression_semaphore_optional_drop_only_3x() raises:
    """REGRESSION TEST. The Optional[SemPermit] is
    NEVER unwrapped via take() — the test relies entirely on Mojo's
    scope-end drop scheduling for both maybe_p and s. Before the fix,
    crashed on iteration 3 because the destructor sequence dropped `s`
    before the Optional, leaving the SemPermit destructor body to read
    freed memory.
    """
    for _ in range(3):
        var s = Semaphore.new(4)
        var maybe_p = s.try_acquire(1)
        assert_true(maybe_p.__bool__())
        # Drops at scope end: maybe_p first (must run SemPermit destructor),
        # then s. Before the fix, optimizer hoisted the SemPermit body's
        # _shared pointer above s's drop, causing UAF.
        _ = maybe_p^
        _ = s^


# -----------------------------------------------------------------------------
# Top-level driver
# -----------------------------------------------------------------------------


def main() raises:
    test_semaphore_construct()
    test_semaphore_try_acquire_one()
    test_semaphore_try_acquire_n()
    test_semaphore_acquire_uncontested()
    test_semaphore_permit_drop_returns_count()
    test_semaphore_acquire_drop_cycle()
    test_semaphore_add_permits_grows_pool()
    test_regression_semaphore_destructor_order_3x()
    test_regression_semaphore_optional_drop_only_3x()
    print("PASS komira_async.sync.semaphore 9 tests")
