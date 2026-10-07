# =============================================================================
# test_spin_mutex.mojo -- SpinMutex excludes, hands over, and does not leak
# =============================================================================
#
# 1. A held lock is not taken: `try_lock` on a held mutex is False, and after
#    `unlock` it is True.
# 2. Mutual exclusion under real threads: n threads each take the lock many
#    times and, inside it, do a NON-atomic read-modify-write of a shared
#    counter and check that nobody else is inside. A lock that did not
#    exclude loses increments and sees another thread inside.
# 3. A waiter that blocked is let in by `unlock`: the main thread holds the
#    lock while a forked body waits in `lock()`, which only returns after the
#    main thread unlocks.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_false, assert_true
from std.time import sleep

from komira_atomic_alias import AtomicI32, AtomicI64
from komira_fork_join import ForkJoinBody, fork_join
from komira_sync import SpinMutex


comptime _ITERS = 3000


struct _Cells(Movable):
    var mutex: SpinMutex
    var counter: Int  # plain: only ever touched inside the lock
    var inside: AtomicI32
    var violations: AtomicI64

    def __init__(out self):
        self.mutex = SpinMutex()
        self.counter = 0
        self.inside = AtomicI32(Int32(0))
        self.violations = AtomicI64(Int64(0))


struct _Body[o: MutOrigin](ForkJoinBody):
    var cells: Pointer[_Cells, Self.o]

    def __init__(out self, cells: Pointer[_Cells, Self.o]):
        self.cells = cells

    def run(self, tid: Int) raises:
        ref c = self.cells[]
        for _ in range(_ITERS):
            c.mutex.lock()
            if c.inside.fetch_add(Int32(1)) != Int32(0):
                _ = c.violations.fetch_add(Int64(1))
            var seen = c.counter
            c.counter = seen + 1
            _ = c.inside.fetch_sub(Int32(1))
            c.mutex.unlock()


def test_try_lock_on_a_held_mutex() raises:
    var m = SpinMutex()
    assert_true(m.try_lock(), "a free mutex was not taken")
    assert_false(m.try_lock(), "a held mutex was taken")
    m.unlock()
    assert_true(m.try_lock(), "an unlocked mutex was not taken")
    m.unlock()


def test_mutual_exclusion_under_threads() raises:
    var n = 8
    var cells = _Cells()
    var body = _Body(Pointer(to=cells))
    fork_join(body, n)
    assert_equal(cells.violations.load(), Int64(0), "two threads inside at once")
    assert_equal(cells.counter, n * _ITERS, "an increment was lost")


struct _Waiter[o: MutOrigin](ForkJoinBody):
    var cells: Pointer[_Cells, Self.o]

    def __init__(out self, cells: Pointer[_Cells, Self.o]):
        self.cells = cells

    def run(self, tid: Int) raises:
        # tid 0 waits for the lock the test holds; tid 1 releases it later.
        ref c = self.cells[]
        if tid == 0:
            c.mutex.lock()
            c.counter = 1
            c.mutex.unlock()
        else:
            sleep(0.050)
            assert_equal(c.counter, 0, "the waiter got in while the lock was held")
            c.mutex.unlock()


def test_unlock_lets_a_waiter_in() raises:
    var cells = _Cells()
    cells.mutex.lock()
    var body = _Waiter(Pointer(to=cells))
    fork_join(body, 2)
    assert_equal(cells.counter, 1, "the waiter never got in")


def main() raises:
    test_try_lock_on_a_held_mutex()
    test_mutual_exclusion_under_threads()
    test_unlock_lets_a_waiter_in()
    print("OK")
