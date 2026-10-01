# =============================================================================
# test_sync_smoke.mojo
# =============================================================================
# smoke test for komira_async.sync.
# =============================================================================

from std.testing import assert_equal

from komira_async.sync.async_mutex import AsyncMutex, MutexGuard
from komira_async.sync.async_rwlock import AsyncRwLock, ReadGuard, WriteGuard
from komira_async.sync.notify import Notify
from komira_async.sync.semaphore import Semaphore, SemPermit


def test_async_mutex_imports() raises:
    """AsyncMutex[T] imports + constructs.

    The real ArcPointer[_MutexShared[T]]-backed AsyncMutex; .new() is the canonical ctor.
    """
    var m = AsyncMutex[Int].new(0)
    _ = m^


def test_async_rwlock_imports() raises:
    """AsyncRwLock[T] imports + constructs.

    ArcPointer[_RwLockShared[T]]-backed AsyncRwLock; .new() is the canonical ctor.
    """
    var l = AsyncRwLock[Int].new(0)
    assert_equal(Int(l.reader_count()), 0)
    _ = l^


def test_semaphore_imports() raises:
    """Semaphore + ctor signature import.

    ArcPointer-backed Semaphore; Semaphore.new(n) is the canonical ctor.
    """
    var s = Semaphore.new(8)
    assert_equal(Int(s.max_permits()), 8)


def test_notify_imports() raises:
    """Notify + ctor import.

    ArcPointer[_NotifyShared]-backed Notify; .new() is the canonical ctor.
    """
    var n = Notify.new()
    assert_equal(Int(n.gen_value()), 0)


def main() raises:
    test_async_mutex_imports()
    test_async_rwlock_imports()
    test_semaphore_imports()
    test_notify_imports()
    print("PASS komira_async.sync smoke")
