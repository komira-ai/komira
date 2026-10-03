# =============================================================================
# test_async_rwlock.mojo
# =============================================================================
# AsyncRwLock + ReadGuard + WriteGuard real-impl tests.
#
#
#
# Writer-preference; multiple-readers / single-writer. This is
# the synchronous-park form (mirrors AsyncMutex). Multi-
# thread contended-acquire tests deferred.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.sync.async_rwlock import AsyncRwLock, ReadGuard, WriteGuard


# -----------------------------------------------------------------------------
# Construction
# -----------------------------------------------------------------------------


def test_rwlock_construct() raises:
    """AsyncRwLock[Int].new(42); construct + destructor."""
    var l = AsyncRwLock[Int].new(42)
    assert_equal(Int(l.reader_count()), 0)
    assert_false(l.has_writer())
    assert_false(l.writer_pending())
    _ = l^


# -----------------------------------------------------------------------------
# Read-side fast paths
# -----------------------------------------------------------------------------


def test_rwlock_try_read_uncontested() raises:
    """try_read on free lock returns Some; reader_count -> 1."""
    var l = AsyncRwLock[Int].new(7)
    var maybe_g = l.try_read()
    assert_true(maybe_g.__bool__())
    assert_equal(Int(l.reader_count()), 1)
    var g = maybe_g.take()
    assert_equal(g.data(), 7)
    _ = g^
    _ = maybe_g^


def test_rwlock_read_uncontested() raises:
    """read() on free lock returns immediately."""
    var l = AsyncRwLock[Int].new(13)
    var g = l.read()
    assert_equal(Int(l.reader_count()), 1)
    assert_equal(g.data(), 13)
    _ = g^
    assert_equal(Int(l.reader_count()), 0)


def test_rwlock_multiple_readers() raises:
    """3 simultaneous read-locks; reader_count == 3."""
    var l = AsyncRwLock[Int].new(99)
    var g1 = l.read()
    var g2 = l.read()
    var g3 = l.read()
    assert_equal(Int(l.reader_count()), 3)
    assert_equal(g1.data(), 99)
    assert_equal(g2.data(), 99)
    assert_equal(g3.data(), 99)
    _ = g1^
    _ = g2^
    _ = g3^
    assert_equal(Int(l.reader_count()), 0)


# -----------------------------------------------------------------------------
# Write-side fast paths
# -----------------------------------------------------------------------------


def test_rwlock_try_write_uncontested() raises:
    """try_write on free lock returns Some; has_writer == True."""
    var l = AsyncRwLock[Int].new(0)
    var maybe_g = l.try_write()
    assert_true(maybe_g.__bool__())
    assert_true(l.has_writer())
    var g = maybe_g.take()
    assert_equal(g.data(), 0)
    _ = g^
    _ = maybe_g^
    assert_false(l.has_writer())


def test_rwlock_write_uncontested() raises:
    """write() on free lock returns immediately."""
    var l = AsyncRwLock[Int].new(0)
    var g = l.write()
    assert_true(l.has_writer())
    g.set_data(42)
    assert_equal(g.data(), 42)
    _ = g^
    assert_false(l.has_writer())


# -----------------------------------------------------------------------------
# Writer-preference enforcement
# -----------------------------------------------------------------------------


def test_rwlock_try_write_when_readers_hold() raises:
    """try_write returns None when readers hold."""
    var l = AsyncRwLock[Int].new(0)
    var rg = l.read()
    var maybe_w = l.try_write()
    assert_false(maybe_w.__bool__())
    _ = maybe_w^
    _ = rg^


def test_rwlock_try_read_when_writer_holds() raises:
    """try_read returns None when writer holds."""
    var l = AsyncRwLock[Int].new(0)
    var wg = l.write()
    var maybe_r = l.try_read()
    assert_false(maybe_r.__bool__())
    _ = maybe_r^
    _ = wg^


# -----------------------------------------------------------------------------
# Round-trip mutation
# -----------------------------------------------------------------------------


def test_rwlock_write_then_read_observes_mutation() raises:
    """Write + mutate + drop + read observes mutation."""
    var l = AsyncRwLock[Int].new(0)
    var wg = l.write()
    wg.set_data(123)
    _ = wg^
    var rg = l.read()
    assert_equal(rg.data(), 123)
    _ = rg^


# -----------------------------------------------------------------------------
# Regression tests for the destructor-ordering hazard
# -----------------------------------------------------------------------------
# Same architectural shape as the Semaphore destructor-ordering bug in
# ReadGuard's `_lock: Pointer[AsyncRwLock[T],
# lock_origin]` field (and WriteGuard's mirror), wrapped in `Optional[
# ReadGuard[T, lock_origin]]` at try_read return (and similarly for
# WriteGuard at try_write), let Mojo 0.26.3's borrow checker LOSE the
# origin propagation through Optional's payload. AOT-darwin-arm64 optimizer
# is then free to hoist the guard destructor's _shared deref above the
# AsyncRwLock's ArcPointer drop (CSE / load-hoist), and the guard reads
# freed memory on scope-end.
#
# The bug is allocator-state-dependent: surfaces when tcmalloc's per-thread
# cache reuses the freed _RwLockShared block. We do 30 iterations and
# exercise both `take()` and scope-end-drop variants for parity with the
# Semaphore regression tests.
#
# With the fix, each guard holds an ArcPointer
# clone of _RwLockShared; the guard's destructor body operates on its own
# refcount share and is decoupled from the AsyncRwLock wrapper's drop
# schedule. 3+ cycles MUST be safe.


def test_regression_rwlock_read_destructor_order_3x() raises:
    """REGRESSION. 30x construct + try_read + take + drop
    cycles. Pre-fix: bug latent on Mac (allocator-state fragile, same as
    AsyncMutex). Post-fix: clean — guard's ArcPointer clone decouples
    lifetime from wrapper.
    """
    for _ in range(30):
        var l = AsyncRwLock[Int].new(42)
        var maybe_g = l.try_read()
        assert_true(maybe_g.__bool__())
        var g = maybe_g.take()
        _ = g^
        _ = maybe_g^
        _ = l^


def test_regression_rwlock_write_destructor_order_3x() raises:
    """REGRESSION. 30x construct + try_write + take + drop
    cycles. Same trap shape as the read variant; WriteGuard takes the
    exclusive path. Post-fix: clean.
    """
    for _ in range(30):
        var l = AsyncRwLock[Int].new(7)
        var maybe_g = l.try_write()
        assert_true(maybe_g.__bool__())
        var g = maybe_g.take()
        _ = g^
        _ = maybe_g^
        _ = l^


def test_regression_rwlock_read_optional_drop_only_3x() raises:
    """REGRESSION. Optional[ReadGuard] never unwrapped —
    relies entirely on Mojo's scope-end drop scheduling. 30 iterations to
    push allocator state past tcmalloc's per-thread cache fill threshold.
    Post-fix: the ArcPointer-cloned guard is independent of the wrapper's
    drop schedule.
    """
    for _ in range(30):
        var l = AsyncRwLock[Int].new(13)
        var maybe_g = l.try_read()
        assert_true(maybe_g.__bool__())
        # Drops at scope end: maybe_g first (must run ReadGuard
        # destructor → fetch_sub on _state), then l.
        _ = maybe_g^
        _ = l^


def test_regression_rwlock_interleaved_read_write_3x() raises:
    """REGRESSION. Interleave ReadGuard + WriteGuard
    destructors across cycles. Different drop body shapes in adjacent
    cycles maximize the chance of CSE-induced UAF if guard lifetime
    were still wrapper-coupled. Post-fix: clean.
    """
    for _ in range(30):
        var l = AsyncRwLock[Int].new(0)
        # Read cycle.
        var rg = l.read()
        assert_equal(Int(l.reader_count()), 1)
        _ = rg^
        # Write cycle.
        var wg = l.write()
        wg.set_data(99)
        assert_equal(wg.data(), 99)
        _ = wg^
        _ = l^


# -----------------------------------------------------------------------------
# Top-level driver
# -----------------------------------------------------------------------------


def main() raises:
    test_rwlock_construct()
    test_rwlock_try_read_uncontested()
    test_rwlock_read_uncontested()
    test_rwlock_multiple_readers()
    test_rwlock_try_write_uncontested()
    test_rwlock_write_uncontested()
    test_rwlock_try_write_when_readers_hold()
    test_rwlock_try_read_when_writer_holds()
    test_rwlock_write_then_read_observes_mutation()
    test_regression_rwlock_read_destructor_order_3x()
    test_regression_rwlock_write_destructor_order_3x()
    test_regression_rwlock_read_optional_drop_only_3x()
    test_regression_rwlock_interleaved_read_write_3x()
    print("PASS komira_async.sync.async_rwlock 13 tests")
