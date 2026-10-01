# =============================================================================
# komira_async.sync.async_rwlock — multiple-readers / single-writer
# =============================================================================
#
#
# Reader-writer async lock. Writer-preference (a writer waiting blocks NEW
# readers — prevents writer starvation under continuous read traffic).
# Tokio default. Hard-coded; v0.2 may add a fairness knob.
#
# AsyncRwLock[T]: Movable wrapper around `_shared: ArcPointer[_RwLockShared[T]]`
# heap state. Same shape as AsyncMutex / Semaphore.
#
# State encoding (single Atomic[int64]):
#   * bit 63 (WRITER_BIT): 1 = a writer holds the lock.
#   * bit 62 (WRITER_PENDING_BIT): 1 = at least one writer is queued.
#   * bits 0-61 (reader_count): number of readers currently holding.
#
# Read-acquire: if WRITER_BIT == 0 AND WRITER_PENDING_BIT == 0, CAS to
# bump reader_count. If either bit is set, park (writer-preference).
#
# Write-acquire: set WRITER_PENDING_BIT (atomic OR via load + CAS loop).
# Wait until reader_count == 0 AND WRITER_BIT == 0; CAS to set WRITER_BIT
# (clear PENDING). Loop on CAS failure (other writer raced).
#
# Read-release (ReadGuard.__del__): fetch_sub(1) on reader_count. If we
# were the last reader AND WRITER_PENDING_BIT was set, wake_all (writer
# wakes; readers re-park because PENDING is set).
#
# Write-release (WriteGuard.__del__): clear WRITER_BIT (preserves
# PENDING if another writer is queued). wake_all — readers and the next
# writer race; writer-preference means the writer wins.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO wildcard origins on public surface.
#   - ArcPointer encapsulated as `_shared:` internal field.
#   - UnsafePointer ONLY for in-module Atomic-storage pointer arithmetic.
#
# Destructor ordering:
#   ReadGuard / WriteGuard must NOT hold `Pointer[AsyncRwLock[T], lock_origin]`
#   — origin-parametric borrows into the AsyncRwLock wrapper. With
#   `Optional[ReadGuard[T, lock_origin]]` / `Optional[WriteGuard[T,
#   lock_origin]]` from try_read / try_write, the Optional severs origin
#   propagation, and the AOT optimizer is then free to hoist a guard
#   destructor's _shared deref above the AsyncRwLock's ArcPointer drop — a
#   use-after-free whose appearance depends on allocator state. Semaphore has
#   the same shape and hits it.
#
#   So ReadGuard and WriteGuard CLONE `_shared: ArcPointer[_RwLockShared[T]]`
#   from the AsyncRwLock at construction. Each guard's destructor operates on
#   its own ArcPointer clone — the refcount keeps the heap state alive
#   regardless of when the AsyncRwLock wrapper drops (the same shape as
#   Semaphore's permit).
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32, AtomicI64

from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_all_by_address,
)


# State bit encoding constants.
comptime _WRITER_BIT: Int64 = 0x4000_0000_0000_0000
comptime _WRITER_PENDING_BIT: Int64 = 0x2000_0000_0000_0000
comptime _READER_MASK: Int64 = 0x1FFF_FFFF_FFFF_FFFF


# =============================================================================
# _RwLockShared[T] — heap-allocated shared state
# =============================================================================


struct _RwLockShared[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Heap-allocated shared state. ArcPointer-shared between the
    AsyncRwLock wrapper, all live ReadGuards/WriteGuards (each holds an
    ArcPointer clone), and any parked waiters.

    `_state` encodes WRITER_BIT | WRITER_PENDING_BIT | reader_count in
    a single Atomic[int64]. Single state word means a single park-
    address shared by readers and writers (Drep generation
    semantics: any state change wakes everyone).

    `_wake_gen` is a separate Atomic[int32] for the wait_on_address
    park (which only supports int32 per the Linux-futex shim). Bumped
    on every release.
    """

    var _state: OwnedPointer[AtomicI64]
    var _wake_gen: OwnedPointer[AtomicI32]
    var _data: Self.T

    def __init__(out self, var data: Self.T):
        var raw_s = alloc[AtomicI64](1)
        # SAFETY: raw_s is a fresh allocation we own. Atomic ctor accepts
        # a Scalar value. Ownership transfers to OwnedPointer.
        raw_s[] = AtomicI64(Int64(0))
        self._state = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw_s,
        )
        var raw_g = alloc[AtomicI32](1)
        # SAFETY: same pattern as _state.
        raw_g[] = AtomicI32(Int32(0))
        self._wake_gen = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_g,
        )
        self._data = data^


# =============================================================================
# AsyncRwLock[T] — public Movable wrapper
# =============================================================================


@fieldwise_init
struct AsyncRwLock[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Reader-writer async lock.

    Movable wrapper over ArcPointer[_RwLockShared[T]] heap state.
    Writer-preference by design.

    This form ships:
      * `new(data)`: construct with initial value.
      * `read(mut self)` / `write(mut self)`: blocking acquire.
      * `try_read(mut self)` / `try_write(mut self)`: lock-free.

    lifts to IoOp[ReadGuard/WriteGuard]-returning form once
    scheduler step + reactor wake are wired.

    ReadGuard / WriteGuard clone
    `self._shared` so guard lifetime is decoupled from this wrapper.
    """

    var _shared: ArcPointer[_RwLockShared[Self.T]]

    @staticmethod
    def new(var data: Self.T) -> AsyncRwLock[Self.T]:
        return AsyncRwLock[Self.T](
            _shared=ArcPointer[_RwLockShared[Self.T]](
                _RwLockShared[Self.T](data^)
            )
        )

    def reader_count(self) -> Int64:
        """Diagnostic: current reader count (snapshot)."""
        return self._shared[]._state[].load() & _READER_MASK

    def has_writer(self) -> Bool:
        """Diagnostic: whether a writer currently holds the lock."""
        return (self._shared[]._state[].load() & _WRITER_BIT) != Int64(0)

    def writer_pending(self) -> Bool:
        """Diagnostic: whether a writer is queued waiting."""
        return (self._shared[]._state[].load() & _WRITER_PENDING_BIT) != Int64(0)

    def try_read(mut self) -> Optional[ReadGuard[Self.T]]:
        """Single-CAS attempt; returns None
        if a writer holds OR is pending (writer-preference)."""
        while True:
            var s = self._shared[]._state[].load()
            if (s & _WRITER_BIT) != Int64(0) or (s & _WRITER_PENDING_BIT) != Int64(0):
                return Optional[ReadGuard[Self.T]]()
            var expected = s
            if self._shared[]._state[].compare_exchange(expected, s + Int64(1)):
                return Optional[ReadGuard[Self.T]](
                    ReadGuard[Self.T](_shared=self._shared)
                )
            # CAS failed; another reader/writer raced. Retry.

    def try_write(mut self) -> Optional[WriteGuard[Self.T]]:
        """Single-CAS attempt; returns None
        if any reader/writer holds. NB: try_write does NOT set
        WRITER_PENDING_BIT — that bit is for QUEUED writers, not
        instantaneous attempts."""
        var expected = Int64(0)  # only succeeds if state is fully-clean.
        if self._shared[]._state[].compare_exchange(expected, _WRITER_BIT):
            return Optional[WriteGuard[Self.T]](
                WriteGuard[Self.T](_shared=self._shared)
            )
        return Optional[WriteGuard[Self.T]]()

    def read(mut self) raises -> ReadGuard[Self.T]:
        """Blocking shared read.

        Fast path: CAS bump reader_count if no writer holding/pending.
        Slow path: park on wake_gen; on wake retry.
        """
        while True:
            var s = self._shared[]._state[].load()
            if (s & _WRITER_BIT) == Int64(0) and (s & _WRITER_PENDING_BIT) == Int64(0):
                var expected = s
                if self._shared[]._state[].compare_exchange(
                    expected, s + Int64(1),
                ):
                    return ReadGuard[Self.T](_shared=self._shared)
                continue
            # Slow path: park.
            var gen_snapshot = self._shared[]._wake_gen[].load()
            var s_recheck = self._shared[]._state[].load()
            if (s_recheck & _WRITER_BIT) == Int64(0) and (s_recheck & _WRITER_PENDING_BIT) == Int64(0):
                continue
            _ = wait_on_address(
                self._shared[]._wake_gen[],
                expected=gen_snapshot,
                timeout_ns=Int64(1_000_000),
            )

    def write(mut self) raises -> WriteGuard[Self.T]:
        """Blocking exclusive write.

        Step 1: set WRITER_PENDING_BIT via load + CAS loop. This blocks
        new readers from joining (writer-preference).

        Step 2: wait until reader_count == 0 AND WRITER_BIT == 0; CAS
        from PENDING-only to WRITER_BIT (clearing PENDING). Loop on
        CAS failure (other writer raced).
        """
        # Step 1: set PENDING bit.
        while True:
            var s = self._shared[]._state[].load()
            var expected = s
            if self._shared[]._state[].compare_exchange(
                expected, s | _WRITER_PENDING_BIT,
            ):
                break
            # CAS failed; retry with fresh load.

        # Step 2: wait for clean state, then CAS to WRITER_BIT.
        while True:
            var s = self._shared[]._state[].load()
            # Check: no writer holds AND no readers.
            if (s & _WRITER_BIT) == Int64(0) and (s & _READER_MASK) == Int64(0):
                # We expect the state to be PENDING-only (no holders).
                # CAS from PENDING-only to WRITER_BIT (without PENDING,
                # since we're absorbing it).
                var expected = _WRITER_PENDING_BIT
                # However, there may be ANOTHER writer also queued; we
                # observe their PENDING contribution as the same bit
                # (PENDING is a flag, not a count). After the CAS
                # success, all PENDING writers see WRITER_BIT and re-
                # park; they'll re-set PENDING when WRITER_BIT clears.
                if self._shared[]._state[].compare_exchange(
                    expected, _WRITER_BIT,
                ):
                    return WriteGuard[Self.T](_shared=self._shared)
                # CAS failed; some reader/writer raced. Loop and retry.
                continue
            # State has readers or writer; park.
            var gen_snapshot = self._shared[]._wake_gen[].load()
            var s_recheck = self._shared[]._state[].load()
            if (s_recheck & _WRITER_BIT) == Int64(0) and (s_recheck & _READER_MASK) == Int64(0):
                continue
            _ = wait_on_address(
                self._shared[]._wake_gen[],
                expected=gen_snapshot,
                timeout_ns=Int64(1_000_000),
            )


# =============================================================================
# ReadGuard[T] — RAII shared read access
# =============================================================================
# ReadGuard owns a CLONED ArcPointer
# to the shared heap state. See module docstring for diagnosis. Same shape
# as Semaphore's SemPermit.
# =============================================================================


@fieldwise_init
struct ReadGuard[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """RAII shared read access.
    Drop decrements reader count; if last reader and writer waiting,
    wakes the next writer.

    Owns an ArcPointer clone of the producing AsyncRwLock's `_shared`
    heap state. Guard lifetime is decoupled from the AsyncRwLock wrapper
    that produced it (see the destructor-ordering note in the module
    docstring).
    """

    var _shared: ArcPointer[_RwLockShared[Self.T]]

    def data(self) -> Self.T:
        """Returns the protected data by COPY."""
        return self._shared[]._data

    def __deinit__(deinit self):
        """Drop decrements reader count; wakes pending writer if last.

        SAFETY: self._shared is an ArcPointer clone — _RwLockShared[T]
        is alive until the LAST refcount holder drops.
        """
        var prev = self._shared[]._state[].fetch_sub(Int64(1))
        # If we were the last reader AND a writer is pending, wake.
        if (prev & _READER_MASK) == Int64(1) and (prev & _WRITER_PENDING_BIT) != Int64(0):
            _ = self._shared[]._wake_gen[].fetch_add(Int32(1))
            _ = wake_all_by_address(self._shared[]._wake_gen[])


# =============================================================================
# WriteGuard[T] — RAII exclusive write access
# =============================================================================
# WriteGuard owns a CLONED ArcPointer
# to the shared heap state. See module docstring for diagnosis.
# =============================================================================


@fieldwise_init
struct WriteGuard[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """RAII exclusive write access.
    Drop sets state to 0 (unlocked) and wakes either the next writer
    (preference) or up to N readers.

    Owns an ArcPointer clone of the producing AsyncRwLock's `_shared`
    heap state. Guard lifetime is decoupled from the AsyncRwLock wrapper
    that produced it (see the destructor-ordering note in the module
    docstring).
    """

    var _shared: ArcPointer[_RwLockShared[Self.T]]

    def data(self) -> Self.T:
        """Returns the protected data by COPY."""
        return self._shared[]._data

    def set_data(mut self, var value: Self.T):
        """Replace the protected data."""
        self._shared[]._data = value^

    def __deinit__(deinit self):
        """Drop clears WRITER_BIT (preserves PENDING for queued writers)
        + wakes all. wake_all is correct for writer-preference: the next
        writer (queued behind PENDING) wins the CAS race; readers re-
        park on their fresh gen snapshot.

        SAFETY: self._shared is an ArcPointer clone — _RwLockShared[T]
        is alive until the LAST refcount holder drops.
        """
        # Clear WRITER_BIT atomically. We can't simply fetch_and; we use
        # CAS-loop to clear only the WRITER_BIT preserving PENDING and
        # any future PENDING bits other writers may have set.
        while True:
            var s = self._shared[]._state[].load()
            var new_s = s & ~_WRITER_BIT
            var expected = s
            if self._shared[]._state[].compare_exchange(
                expected, new_s,
            ):
                break
        _ = self._shared[]._wake_gen[].fetch_add(Int32(1))
        _ = wake_all_by_address(self._shared[]._wake_gen[])
