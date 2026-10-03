# =============================================================================
# test_async_mutex.mojo
# =============================================================================
# AsyncMutex + MutexGuard real-impl tests.
#
#
#
# Tests the lock-free fast path (try_lock + uncontested lock), the RAII
# guard release, and the data-mutation round-trip. Multi-thread contested
# tests are deferred until IoOp scheduling is wired (this form
# ships the synchronous-park form; testing contended-park requires pthread
# orchestration which lands in integration).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.sync.async_mutex import AsyncMutex, MutexGuard


# -----------------------------------------------------------------------------
# Fast-path tests (single-threaded; no parking)
# -----------------------------------------------------------------------------


def test_mutex_construct_and_drop() raises:
    """AsyncMutex[Int].new(42); construct + destructor."""
    var m = AsyncMutex[Int].new(42)
    # Drop at end of scope; no SIGSEGV / leak (verified by ASAN-style
    # builds; this test is a smoke for construction.).
    _ = m^


def test_mutex_try_lock_unlocked() raises:
    """try_lock on free mutex returns Some; data() reads the value."""
    var m = AsyncMutex[Int].new(7)
    var maybe_g = m.try_lock()
    assert_true(maybe_g.__bool__(), "try_lock on free mutex returns Some")
    # MutexGuard is NOT Copyable. Use Optional.take() to move out.
    var g = maybe_g.take()
    assert_equal(g.data(), 7)
    # Drop g at end of scope releases the lock.
    _ = g^
    _ = maybe_g^


def test_mutex_try_lock_when_held_returns_none() raises:
    """Holding a guard makes try_lock return None."""
    var m = AsyncMutex[Int].new(13)
    var maybe_g1 = m.try_lock()
    var g1 = maybe_g1.take()
    assert_equal(g1.data(), 13)
    var g2_opt = m.try_lock()
    assert_false(g2_opt.__bool__(), "try_lock on held mutex returns None")
    # Drop g2_opt (None) + g1 in reverse order.
    _ = g2_opt^
    _ = g1^
    _ = maybe_g1^


def test_mutex_drop_guard_unlocks() raises:
    """Dropping the guard releases the lock; subsequent try_lock succeeds."""
    var m = AsyncMutex[Int].new(99)
    var maybe_g1 = m.try_lock()
    var g1 = maybe_g1.take()
    _ = g1^  # Drop -> unlocks.
    _ = maybe_g1^
    var g2_opt = m.try_lock()
    assert_true(g2_opt.__bool__(), "try_lock after guard drop succeeds")
    var g2 = g2_opt.take()
    _ = g2^
    _ = g2_opt^


def test_mutex_lock_uncontested() raises:
    """lock() on free mutex returns immediately without parking."""
    var m = AsyncMutex[Int].new(123)
    var g = m.lock()
    assert_equal(g.data(), 123)
    _ = g^


def test_mutex_data_mut_round_trip() raises:
    """Lock + mutate + drop + lock + observe mutation."""
    var m = AsyncMutex[Int].new(0)
    var g1 = m.lock()
    g1.set_data(42)
    _ = g1^  # Drop releases the lock.
    var g2 = m.lock()
    assert_equal(g2.data(), 42)
    _ = g2^


def test_mutex_repeated_lock_unlock() raises:
    """100 consecutive lock/unlock cycles on a single thread."""
    var m = AsyncMutex[Int].new(0)
    for i in range(100):
        var g = m.lock()
        g.set_data(i)
        _ = g^
    var g_final = m.lock()
    assert_equal(g_final.data(), 99)
    _ = g_final^


# -----------------------------------------------------------------------------
# Guard borrow check (compile-time enforcement check)
# -----------------------------------------------------------------------------
# We can't test compile-time rejection of guard-outliving-mutex from inside
# Mojo source; that would require a should-fail-compile harness. Instead,
# we test the positive: the guard's data() returns a ref tied to the mutex
# and the data is correctly mutated through it within scope.


def test_mutex_guard_origin_borrow_positive() raises:
    """Guard.data() returns a borrow valid for the mutex's lifetime."""
    var m = AsyncMutex[Int].new(1)
    var g = m.lock()
    # Read through the guard's ref-borrow.
    var v = g.data()
    assert_equal(v, 1)
    g.set_data(2)
    var v2 = g.data()
    assert_equal(v2, 2)
    _ = g^


# -----------------------------------------------------------------------------
# Regression tests for the destructor-ordering hazard
# -----------------------------------------------------------------------------
# Same architectural shape as the Semaphore destructor-ordering bug in
# MutexGuard's `_mutex: Pointer[AsyncMutex[T],
# mutex_origin]` field, wrapped in `Optional[MutexGuard[T, mutex_origin]]` at
# try_lock return, lets Mojo 0.26.3's borrow checker LOSE the origin
# propagation through the Optional payload. AOT-darwin-arm64 optimizer is
# then free to hoist the guard destructor's _shared deref above the mutex's
# ArcPointer drop (CSE / load-hoist), and the guard reads freed memory on
# scope-end.
#
# The bug is allocator-state-dependent: surfaces when tcmalloc's per-thread
# cache reuses the freed _MutexShared block. The Semaphore version surfaced
# at iteration 3 with `_SemaphoreShared` size class 32 bytes; _MutexShared[T]
# is parametric on T and lands in a different size class but same trap
# shape. We do 5 iterations and exercise both `take()` and scope-end-drop
# variants for parity with the Semaphore regression tests.
#
# With the fix, MutexGuard holds an ArcPointer
# clone of _MutexShared; the guard's destructor body operates on its own
# refcount share and is decoupled from the AsyncMutex wrapper's drop
# schedule. 3+ cycles MUST be safe.


def test_regression_mutex_destructor_order_3x() raises:
    """REGRESSION. 30x construct + try_lock + take + drop
    cycles. Pre-fix: bug latent on Mac for _MutexShared[Int]'s size class
    (allocator-state-dependent — surfaces decisively in the rwlock variant
    where _RwLockShared[Int] hits a different size class with denser
    metadata layout). The mutex variant is included as a forward-looking
    guardrail: if a future Mojo codegen change or a different T payload
    makes _MutexShared[T] hit the same trap conditions, this regression
    test will catch it. Post-fix: clean — guard's ArcPointer clone
    decouples lifetime from wrapper.
    """
    for _ in range(30):
        var m = AsyncMutex[Int].new(42)
        var maybe_g = m.try_lock()
        assert_true(maybe_g.__bool__())
        var g = maybe_g.take()
        _ = g^
        _ = maybe_g^
        _ = m^


def test_regression_mutex_optional_drop_only_3x() raises:
    """REGRESSION. Optional[MutexGuard] never unwrapped —
    relies entirely on Mojo's scope-end drop scheduling. 30 iterations to
    push allocator state past tcmalloc's per-thread cache fill threshold.
    Pre-fix: latent (see destructor_order_3x docstring). Post-fix: the
    ArcPointer-cloned guard is independent of the wrapper's drop
    schedule.
    """
    for _ in range(30):
        var m = AsyncMutex[Int].new(7)
        var maybe_g = m.try_lock()
        assert_true(maybe_g.__bool__())
        # Drops at scope end: maybe_g first (must run MutexGuard destructor),
        # then m.
        _ = maybe_g^
        _ = m^


# -----------------------------------------------------------------------------
# Top-level driver
# -----------------------------------------------------------------------------


def main() raises:
    test_mutex_construct_and_drop()
    test_mutex_try_lock_unlocked()
    test_mutex_try_lock_when_held_returns_none()
    test_mutex_drop_guard_unlocks()
    test_mutex_lock_uncontested()
    test_mutex_data_mut_round_trip()
    test_mutex_repeated_lock_unlock()
    test_mutex_guard_origin_borrow_positive()
    test_regression_mutex_destructor_order_3x()
    test_regression_mutex_optional_drop_only_3x()
    print("PASS komira_async.sync.async_mutex 10 tests")
