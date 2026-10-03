# =============================================================================
# komira_async.sync.semaphore — bounded concurrent permits
# =============================================================================
#
#
# Counted permit primitive: acquire(n) parks the calling task on empty pool;
# release() (via SemPermit drop) wakes parked tasks via Mechanism D wake-by-
# address. Used for application-level rate limiting, connection pool
# capacity, bounded concurrent fan-out.
#
# Semaphore: Movable wrapper around `_shared: ArcPointer[_SemaphoreShared]`
# heap state. Same shape as AsyncMutex.
#
# SemPermit: RAII handle that CLONES Semaphore's `_shared` ArcPointer.
# Holds n permits; drop releases them back to the semaphore + wakes waiters
# proportionally. Lifetime is decoupled from the Semaphore wrapper via the
# refcount — see "Destructor ordering" below.
#
# This is the synchronous-park form. Wake strategy: wake_all on
# release (thundering-herd is correct for small N; tokio's batch_semaphore
# uses the same approach for its slow-path wake-up). A proper FIFO wait queue
# could refine this to "wake exactly N waiters".
#
# Semaphore is a standalone application-facing primitive with no AIMD
# (load-shedding) coupling; per-worker self-balancing handles load shedding
# cooperatively.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO wildcard origins on public surface.
#   - ArcPointer encapsulated as `_shared:` internal field.
#   - UnsafePointer ONLY for in-module Atomic-storage pointer arithmetic.
#
# Destructor ordering:
#   SemPermit must NOT hold `Pointer[Semaphore, sem_origin]` — an
#   origin-parametric borrow into the Semaphore wrapper. With both in the
#   same scope (e.g., `var s = Semaphore.new(N); var maybe_p =
#   s.try_acquire(1)`), the Optional[SemPermit[sem_origin]] wrap severs
#   lifetime tracking (Mojo 0.26.3's borrow checker does not propagate the
#   inner type's origin parameter through Optional's payload), and the AOT
#   optimizer can hoist the SemPermit destructor's pointer-into-
#   _SemaphoreShared above the Semaphore's ArcPointer drop: the destructor
#   then runs AFTER ArcPointer freed _SemaphoreShared, dereferencing freed
#   memory and confusing tcmalloc on a later allocation cycle.
#
#   So SemPermit CLONES `_shared: ArcPointer[_SemaphoreShared]` from the
#   Semaphore at construction. The permit's destructor operates on its own
#   ArcPointer clone — the refcount keeps the heap state alive regardless of
#   when the Semaphore wrapper drops. This matches tokio's batch_semaphore
#   design (each permit holds an Arc to the inner state, not a borrow into
#   the wrapper).
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32, AtomicI64

from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_all_by_address,
)


# =============================================================================
# _SemaphoreShared — heap-allocated shared state
# =============================================================================
# `_permits` is an int64 counter for the permit balance.
#
# `_wake_gen` is a separate int32 counter bumped on every release, used as
# the parking address for wait_on_address (which takes int32 per the
# Linux-futex shim shape). Drep lost-wakeup-safe pattern: acquirer
# snapshots gen, checks permits, parks on gen=snapshot — if a release fires
# fetch_add(1) between the snapshot and the syscall, the kernel-side compare
# returns -EAGAIN and the park returns immediately.
# =============================================================================


struct _SemaphoreShared(Movable, Deinitable):
    """Heap-allocated shared state. ArcPointer-shared between the
    Semaphore wrapper, all live SemPermits, and any parked acquirers.
    """

    var _permits: OwnedPointer[AtomicI64]
    var _wake_gen: OwnedPointer[AtomicI32]
    var _max: Int64

    def __init__(out self, max_permits: Int64):
        var raw_p = alloc[AtomicI64](1)
        # SAFETY: raw_p is a fresh allocation we own. Atomic ctor accepts
        # a Scalar value. Ownership transfers to OwnedPointer.
        raw_p[] = AtomicI64(max_permits)
        self._permits = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw_p,
        )
        var raw_g = alloc[AtomicI32](1)
        # SAFETY: same pattern as _permits.
        raw_g[] = AtomicI32(Int32(0))
        self._wake_gen = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_g,
        )
        self._max = max_permits


# =============================================================================
# Semaphore — public Movable wrapper
# =============================================================================


@fieldwise_init
struct Semaphore(Movable, Deinitable):
    """Bounded concurrent permits.

    Movable wrapper over ArcPointer[_SemaphoreShared] heap state.

    This form ships:
      * `new(n)`: construct with n initial permits.
      * `acquire(mut self, n=1)`: blocking acquire (parks via Mechanism D
        until permits available; returns SemPermit).
      * `try_acquire(mut self, n=1)`: lock-free CAS attempt; returns
        Optional[SemPermit].
      * `available_permits() -> Int64`: diagnostic.
      * `max_permits() -> Int64`: diagnostic (the initial capacity).
      * `add_permits(mut self, n)`: increase the pool; wakes waiters.
      * `close(mut self)`: a stub (raises) — a ChannelClosed-shaped
        wake is not wired.

    An IoOp[SemPermit] form needs
    the scheduler step is in place.
    """

    var _shared: ArcPointer[_SemaphoreShared]

    @staticmethod
    def new(n: UInt) -> Semaphore:
        """Construct a fresh semaphore with `n` initial permits."""
        return Semaphore(
            _shared=ArcPointer[_SemaphoreShared](
                _SemaphoreShared(Int64(n))
            )
        )

    def available_permits(self) -> Int64:
        """diagnostic helper. Returns the current
        permit count (a snapshot; concurrent acquirers/releasers may
        have changed it by the time the caller reads).
        """
        return self._shared[]._permits[].load()

    def max_permits(self) -> Int64:
        """The initial capacity passed to new()."""
        return self._shared[]._max

    def try_acquire(mut self, n: UInt = 1) -> Optional[SemPermit]:
        """Single-CAS attempt; returns
        None if fewer than n permits available.

        The returned `SemPermit` clones
        `self._shared` so its lifetime is decoupled from this Semaphore.
        Permits MAY safely outlive the Semaphore wrapper that produced
        them — each holds an ArcPointer share of the underlying heap
        state.
        """
        var n_signed = Int64(n)
        # Snapshot current permits + try CAS. Loop on CAS failure (some
        # other thread changed the counter) until either we succeed or
        # we observe insufficient permits.
        while True:
            var current = self._shared[]._permits[].load()
            if current < n_signed:
                return Optional[SemPermit]()
            var expected = current
            if self._shared[]._permits[].compare_exchange(
                expected, current - n_signed,
            ):
                return Optional[SemPermit](
                    SemPermit(_shared=self._shared, _n=n_signed)
                )
            # CAS failed; another thread won. Retry with fresh load.

    def acquire(mut self, n: UInt = 1) raises -> SemPermit:
        """Blocking acquire.

        Fast path: CAS as in try_acquire — returns permit immediately if
        the pool has >= n free permits.

        Slow path: park on _wake_gen via wait_on_address; on wake (a
        SemPermit released back permits + bumped wake_gen), retry the
        CAS.

        Drep lost-wakeup-safe protocol: snapshot wake_gen FIRST,
        then re-check permits; if still insufficient, park. If a release
        fires fetch_add(1) on _wake_gen between snapshot and syscall, the
        kernel returns -EAGAIN and acquire re-loops.

        Synchronous-park form: blocks the calling thread.
        An IoOp[SemPermit] form needs the scheduler
        step is wired.

        The returned `SemPermit` clones
        `self._shared` (see try_acquire docstring).
        """
        var n_signed = Int64(n)
        while True:
            var current = self._shared[]._permits[].load()
            if current >= n_signed:
                # Fast path: CAS attempt.
                var expected = current
                if self._shared[]._permits[].compare_exchange(
                    expected, current - n_signed,
                ):
                    return SemPermit(_shared=self._shared, _n=n_signed)
                # CAS failed; loop and retry without parking — the
                # competing thread may have left enough permits.
                continue
            # Slow path: park on wake_gen. Drep lost-wakeup-safe.
            var gen_snapshot = self._shared[]._wake_gen[].load()
            # Re-check permits AFTER snapshot (lost-wakeup safe).
            if self._shared[]._permits[].load() >= n_signed:
                continue  # Try fast path again.
            _ = wait_on_address(
                self._shared[]._wake_gen[],
                expected=gen_snapshot,
                timeout_ns=Int64(1_000_000),  # 1ms cancel-poll cadence.
            )

    def add_permits(mut self, n: UInt) raises:
        """Increase the permit pool;
        wake all waiters proportionally.

        fetch_add(_permits) + bump _wake_gen + wake_all.
        Thundering-herd is correct but sub-optimal for large N; a later step
        may refine.
        """
        _ = self._shared[]._permits[].fetch_add(Int64(n))
        _ = self._shared[]._wake_gen[].fetch_add(Int32(1))
        _ = wake_all_by_address(self._shared[]._wake_gen[])

    def close(mut self) raises:
        """Permanently close.

        stub. wires the ChannelClosed-shaped wake
        protocol for outstanding waiters.
        """
        raise Error("Semaphore.close: not implemented")


# =============================================================================
# SemPermit — RAII handle
# =============================================================================
# SemPermit owns a CLONED ArcPointer to the
# shared heap state, decoupling its lifetime from any specific Semaphore
# wrapper. This is the canonical "permit holds an Arc to inner state" shape
# used by tokio's batch_semaphore (apple/swift's DispatchSemaphore uses an
# equivalent refcount-shared shape).
#
# The previous shape (`Pointer[Semaphore, sem_origin]` + origin-parametric
# struct) hit a Mojo 0.26.3 + AOT-darwin-arm64 destructor-ordering bug:
# Optional[SemPermit[sem_origin]] severed origin propagation, the AOT
# optimizer hoisted the permit destructor's _shared deref above the
# Semaphore's ArcPointer drop, and on the 3rd construct/try_acquire/drop
# cycle tcmalloc detected an invalid free.
#
# NOT Copyable — a permit is the unique handle for n permits. Movable so
# Optional[SemPermit] works. The clone of `_shared` is implicit via
# ArcPointer's copyability (refcount bump).
# =============================================================================


@fieldwise_init
struct SemPermit(Movable, Deinitable):
    """RAII handle. Holds n permits.
    Drop releases them back to the semaphore via the shared heap state
    + wakes waiters via Mechanism D.

    Owns an ArcPointer clone of the producing Semaphore's `_shared`
    heap state. Permit lifetime is decoupled from the Semaphore wrapper
    that produced it (see the destructor-ordering note in the module docstring).

    NOT Copyable. Movable so that Optional[SemPermit] works — Mojo
    0.26.3 Optional requires payload Movable + Deinitable.
    """

    var _shared: ArcPointer[_SemaphoreShared]
    var _n: Int64

    def permits(self) -> Int64:
        """Diagnostic: the number of permits this handle holds."""
        return self._n

    def __deinit__(deinit self):
        """Drop releases the permits +
        wakes waiters.

        fetch_add(_n) on _permits, fetch_add(1) on _wake_gen,
        then wake_all_by_address. Drep protocol pairs with
        acquire's slow-path.

        SAFETY: self._shared is an ArcPointer clone — the underlying
        _SemaphoreShared remains alive until the LAST refcount holder
        (this permit, the Semaphore wrapper, or any other live permit
        clone) drops. The destructor needs ONLY the shared state, which
        is guaranteed alive by our own ArcPointer.
        """
        _ = self._shared[]._permits[].fetch_add(self._n)
        _ = self._shared[]._wake_gen[].fetch_add(Int32(1))
        _ = wake_all_by_address(self._shared[]._wake_gen[])
