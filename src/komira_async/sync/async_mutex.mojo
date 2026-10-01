# =============================================================================
# komira_async.sync.async_mutex — exclusive async lock
# =============================================================================
#
#
# AsyncMutex[T]: Movable wrapper around `_shared: ArcPointer[_MutexShared[T]]`
# heap state. The shared state holds an Atomic[int32] state word (0=unlocked,
# 1=locked) and the protected data T. ArcPointer-internal, the same shape as
# CancellationToken and JoinHandle.
#
# MutexGuard[T]: RAII guard that CLONES AsyncMutex's `_shared` ArcPointer.
# Holds the lock; drop releases it + wakes one waiter (FIFO). Lifetime is
# decoupled from the AsyncMutex wrapper via the refcount — see "Destructor
# ordering" below.
#
# This is a synchronous-park form: lock() blocks the calling thread
# on wait_on_address until acquired. An IoOp-returning shape needs the
# scheduler step + reactor-driven wake.
#
# Mechanism D wake-by-address: same primitives as JoinHandle's slot
# (komira_async.runtime.wake_primitives.wait_on_address /
# wake_one_by_address). Drep lost-wakeup-safe protocol.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO wildcard origins on public surface.
#   - ArcPointer encapsulated as `_shared:` internal field.
#   - UnsafePointer ONLY for in-module Atomic-storage pointer arithmetic
#     (`UnsafePointer(to=...)` the canonical shape). Each site has SAFETY block.
#
# Memory ordering: Mojo 0.26.3's compare_exchange / load / store appear to
# default to SeqCst (the bare-2-arg / no-ordering form is what stdlib
# exposes; explicit AcqRel/Acquire/Release args are not in the public API
# surface). SeqCst is correct (slower but safe); future tightening to
# AcqRel-on-success / Release-on-store can land if Mojo 0.26.3 surfaces
# explicit-ordering APIs.
#
# Destructor ordering:
#   MutexGuard must NOT hold `Pointer[AsyncMutex[T], mutex_origin]` — an
#   origin-parametric borrow into the AsyncMutex wrapper. With
#   `Optional[MutexGuard[T, mutex_origin]]` from try_lock, the Optional severs
#   origin propagation, and the AOT optimizer is then free to hoist the guard
#   destructor's _shared deref above the AsyncMutex's ArcPointer drop — a
#   use-after-free whose appearance depends on allocator state (size class of
#   _MutexShared[T], allocator pressure, codegen). Semaphore has the same
#   shape and hits it.
#
#   So MutexGuard CLONES `_shared: ArcPointer[_MutexShared[T]]` from the
#   AsyncMutex at construction. The guard's destructor operates on its own
#   ArcPointer clone — the refcount keeps the heap state alive regardless of
#   when the AsyncMutex wrapper drops. This is the tokio batch_semaphore
#   Arc-clone shape, and the same shape Semaphore's permit uses.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32

from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_one_by_address,
)


# State sentinels.
comptime _MUTEX_UNLOCKED: Int32 = 0
comptime _MUTEX_LOCKED: Int32 = 1


# =============================================================================
# _MutexShared[T] — heap-allocated shared state
# =============================================================================
# OwnedPointer[Atomic[int32]] indirection because Atomic is non-Movable on
# Mojo 0.26.3; ArcPointer requires T: Movable. Same shape as _AtomicSlot
# / _SpawnSlot[T] in (cancellation/token.mojo, spawner/join_handle.mojo).
# =============================================================================


struct _MutexShared[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Heap-allocated shared state. ArcPointer-shared between the
    AsyncMutex wrapper, all live MutexGuards (each holds an ArcPointer
    clone), and any parked waiters' wait-on-address frames.

    `_state` is the lock word — a single Int32 0/1. We store it as
    OwnedPointer[Atomic[int32]] because Atomic is non-Movable on Mojo
    0.26.3 and ArcPointer wants T: Movable.
    """

    var _state: OwnedPointer[AtomicI32]
    var _data: Self.T

    def __init__(out self, var data: Self.T):
        var raw = alloc[AtomicI32](1)
        # SAFETY: raw is a fresh allocation we own. Atomic ctor accepts a
        # Scalar value. Ownership transfers to OwnedPointer.
        raw[] = AtomicI32(_MUTEX_UNLOCKED)
        self._state = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw,
        )
        self._data = data^


# =============================================================================
# AsyncMutex[T] — public Movable wrapper
# =============================================================================


@fieldwise_init
struct AsyncMutex[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Async mutex.

    Movable wrapper over ArcPointer[_MutexShared[T]] heap state.
    Multiple guards / cloned mutex handles share the same _shared
    ArcPointer and observe the same lock word.

    This form ships:
      * `new(data)`: construct with initial protected value.
      * `lock(mut self)`: blocking acquire (parks via Mechanism D until
        the lock is free; returns MutexGuard[T]).
      * `try_lock(mut self)`: lock-free CAS attempt; returns
        Optional[MutexGuard].

    An IoOp-returning shape needs the scheduler step.
    The current synchronous form
    is correct semantics for application-level mutex use.

    MutexGuard clones `self._shared` so
    guard lifetime is decoupled from this wrapper.
    """

    var _shared: ArcPointer[_MutexShared[Self.T]]

    @staticmethod
    def new(var data: Self.T) -> AsyncMutex[Self.T]:
        """Construct a free mutex with the given protected value."""
        return AsyncMutex[Self.T](
            _shared=ArcPointer[_MutexShared[Self.T]](
                _MutexShared[Self.T](data^)
            )
        )

    def try_lock(mut self) -> Optional[MutexGuard[Self.T]]:
        """Single-CAS attempt; returns
        None if the lock is held.

        The returned `MutexGuard`
        clones `self._shared` so its lifetime is decoupled from this
        AsyncMutex. Guards MAY safely outlive the wrapper that produced
        them — each holds an ArcPointer share of the underlying heap
        state.
        """
        # Instance-method compare_exchange.
        # Returns Bool;
        # `expected` is a value, not a pointer.
        var expected = _MUTEX_UNLOCKED
        if self._shared[]._state[].compare_exchange(expected, _MUTEX_LOCKED):
            return Optional[MutexGuard[Self.T]](
                MutexGuard[Self.T](_shared=self._shared)
            )
        return Optional[MutexGuard[Self.T]]()

    def lock(mut self) raises -> MutexGuard[Self.T]:
        """Blocking acquire.

        Fast path: single CAS (UNLOCKED → LOCKED) — returns guard
        immediately if uncontested.

        Slow path: park on the state word via wait_on_address; on wake
        retry the CAS. Drep lost-wakeup-safe protocol — the
        kernel's value-compare-on-park returns -EAGAIN immediately if a
        producer flipped the word between snapshot and syscall.

        Synchronous-park form: blocks the calling thread.
        An IoOp[MutexGuard[T]] form needs the
        scheduler step is wired.

        The returned guard clones
        `self._shared` (see try_lock docstring).
        """
        while True:
            # Fast path: try CAS first.
            var expected = _MUTEX_UNLOCKED
            if self._shared[]._state[].compare_exchange(
                expected, _MUTEX_LOCKED,
            ):
                return MutexGuard[Self.T](_shared=self._shared)
            # Slow path: park. expected=_MUTEX_LOCKED; the kernel will
            # return immediately (-EAGAIN) if the word was flipped to
            # UNLOCKED between our CAS-fail and the syscall.
            #
            # 1ms timeout matches JoinHandle.join: serves as cancel-poll
            # cadence (doesn't yet wire CancellationToken
            # at this surface — Tier 2 lock_with_token is a later step).
            _ = wait_on_address(
                self._shared[]._state[],
                expected=_MUTEX_LOCKED,
                timeout_ns=Int64(1_000_000),
            )

    def lock_with_token(
        mut self, var token: Bool
    ) raises -> MutexGuard[Self.T]:
        """Tier 2 explicit-token form.

        Stub: the `token` param is intentionally typed `Bool`
        rather than `CancellationToken` to avoid a circular import. The
        token is consumed but not yet checked; follow-on swaps
        the param to CancellationToken when the IoOp[MutexGuard[...]]
        form lands and Tier 2 token-checks compose with the IoOp-poll
        loop.
        """
        _ = token
        # Delegate to the no-token path.
        return self.lock()


# =============================================================================
# MutexGuard[T] — RAII handle
# =============================================================================
# MutexGuard owns a CLONED ArcPointer
# to the shared heap state, decoupling its lifetime from any specific
# AsyncMutex wrapper. Same shape as Semaphore's SemPermit.
#
# An origin-parametric shape (`Pointer[AsyncMutex[T], mutex_origin]` + origin-
# parametric struct) has the trap in its purest form: the
# `mutex_origin` parameter is captured into `Optional[MutexGuard[T,
# mutex_origin]]` at try_lock, where Mojo 0.26.3's borrow checker fails
# to propagate the inner type's origin parameter through Optional's
# payload. The AOT optimizer is free to hoist the guard destructor's
# _shared deref above the wrapper's ArcPointer drop.
#
# NOT Copyable — exclusive access is held by exactly one guard. Movable so
# Optional[MutexGuard] works (Mojo 0.26.3 Optional requires payload
# Movable + Deinitable).
# =============================================================================


@fieldwise_init
struct MutexGuard[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """RAII handle. Drop releases the
    lock + wakes one waiter (FIFO).

    NOT Copyable — exclusive access is held by exactly one guard.

    Owns an ArcPointer clone of the producing AsyncMutex's `_shared`
    heap state. Guard lifetime is decoupled from the AsyncMutex wrapper
    that produced it (see the destructor-ordering note in the module
    docstring).
    """

    var _shared: ArcPointer[_MutexShared[Self.T]]

    def data(self) -> Self.T:
        """Borrow the protected data by COPY.

        Returns by COPY. The struct-level trait bound is
        widened to require `T: Copyable & ImplicitlyCopyable & Movable
        & Deinitable` so this compiles cleanly. The
        narrower bound (`T: Movable & Deinitable`)
        is preserved at the public-API level via the AsyncMutex[T]
        struct's bound; the guard adds the Copyable requirement
        because the reading API returns by copy.

        may add `data_ref()` returning `ref T` once the trait
        surface stabilizes; that variant won't need Copyable.
        """
        return self._shared[]._data

    def set_data(mut self, var value: Self.T):
        """Replace the protected data with `value`. The old value is
        dropped (consumed by `^=` semantics)."""
        self._shared[]._data = value^

    def __deinit__(deinit self):
        """Drop releases the lock +
        wakes one waiter (FIFO).

        store UNLOCKED; wake_one_by_address.

        SAFETY: self._shared is an ArcPointer clone — the underlying
        _MutexShared[T] remains alive until the LAST refcount holder
        (this guard, the AsyncMutex wrapper, or any other live guard
        clone) drops. The destructor needs ONLY the shared state, which
        is guaranteed alive by our own ArcPointer.
        """
        AtomicI32.store(
            UnsafePointer(to=self._shared[]._state[]).unsafe_bitcast[Scalar[DType.int32]](),
            _MUTEX_UNLOCKED,
        )
        _ = wake_one_by_address(self._shared[]._state[])
