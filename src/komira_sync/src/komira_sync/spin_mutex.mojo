# =============================================================================
# komira_sync/spin_mutex.mojo -- SpinMutex
# =============================================================================
#
# One atomic word: 0 is free, 1 is held. `lock()` takes it with a
# compare-and-swap from 0 to 1 and `unlock()` stores 0.
#
# WAITING. A failed attempt is retried at once `_SPINS_BEFORE_SLEEP` times with
# a `sched_yield` between attempts, then every further attempt is followed by a
# `usleep` of `_SLEEP_MICROS`. The sleep is what keeps a waiter from burning a
# core while the holder is blocked on I/O. `usleep` rather than the standard
# library's `sleep`: the latter declares `nanosleep`, which conflicts with the
# declaration komira_async's reactor makes, and one binary cannot hold both.
#
# NOT REENTRANT, NOT FAIR, NO POISONING. A thread that locks twice deadlocks
# itself. A holder that raises must unlock on every path; the callers in this
# repository do so with try / except around the critical section.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, alloc

from komira_atomic_alias import AtomicI32


comptime _SPINS_BEFORE_SLEEP = 32
comptime _SLEEP_MICROS = 200


struct SpinMutex(Movable, Deinitable):
    """A mutual-exclusion lock whose state is one atomic word on the heap.

    `lock` and `unlock` take `mut self`: reach the mutex through an
    `ArcPointer` shared by the threads, as the shared-state types in this
    repository do.
    """

    # 0 = free, 1 = held. On the heap because `Atomic` is not movable, so it
    # cannot be a direct field of a movable struct.
    var _word: OwnedPointer[AtomicI32]

    def __init__(out self):
        # SAFETY: `alloc` returns storage for one `AtomicI32`; it is
        # initialised before the `OwnedPointer` takes ownership, and the
        # `OwnedPointer` frees it once, when this struct is destroyed.
        var raw = alloc[AtomicI32](1)
        raw[] = AtomicI32(Int32(0))
        self._word = OwnedPointer[AtomicI32](unsafe_from_raw_pointer=raw)

    def try_lock(mut self) -> Bool:
        """Takes the lock if it is free. True when this call took it."""
        var expected = Int32(0)
        return self._word[].compare_exchange(expected, Int32(1))

    def lock(mut self):
        """Blocks until the lock is taken by this call."""
        var failures = 0
        while not self.try_lock():
            failures += 1
            if failures <= _SPINS_BEFORE_SLEEP:
                _ = external_call["sched_yield", Int32]()
            else:
                _ = external_call["usleep", Int32](UInt32(_SLEEP_MICROS))

    def unlock(mut self):
        """Releases the lock. The caller holds it."""
        var expected = Int32(1)
        _ = self._word[].compare_exchange(expected, Int32(0))
