# =============================================================================
# komira_async.sync.notify — signal/wait coordination
# =============================================================================
#
#
# Stateless event. notified() parks; notify_one wakes ONE waiter (FIFO);
# notify_waiters wakes ALL.
#
# Unlike a flag, Notify has no persistent "is set" state. notify_one()
# called when no one is waiting is LOST (unless permit-style semantics are
# used — see notify_one_permit below).
#
# Notify: Movable wrapper around `_shared: ArcPointer[_NotifyShared]` heap
# state. Same shape as AsyncMutex / Semaphore / AsyncRwLock.
#
# Internal mechanism:
#   * `_gen`: Atomic[int32] bumped on every notify_one / notify_waiters /
#     notify_one_permit. Parked notified() callers wait on this.
#   * `_stored_permit`: Atomic[uint8] (0/1). Set by notify_one_permit if
#     no waiter was woken. Consumed by next notified() before parking.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO wildcard origins on public surface.
#   - ArcPointer encapsulated as `_shared:` internal field.
#   - UnsafePointer ONLY for in-module Atomic-storage pointer arithmetic.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32

from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_all_by_address,
    wake_one_by_address,
)


# =============================================================================
# _NotifyShared — heap-allocated shared state
# =============================================================================


struct _NotifyShared(Movable, Deinitable):
    """Heap-allocated shared state. ArcPointer-shared between the
    Notify wrapper, all parked notified() callers, and any threads
    issuing notify_one / notify_waiters / notify_one_permit.

    `_gen` is the wake-by-address parking word. Bumped on every
    notification; parked threads observe the bump via -EAGAIN or
    explicit wake.

    `_stored_permit` is the at-most-1 storage slot for
    notify_one_permit. CAS'd 0→1 on permit-store; 1→0 on consume by
    notified().
    """

    var _gen: OwnedPointer[AtomicI32]
    var _stored_permit: OwnedPointer[AtomicI32]

    def __init__(out self):
        var raw_g = alloc[AtomicI32](1)
        # SAFETY: raw_g is a fresh allocation we own. Atomic ctor accepts
        # a Scalar value. Ownership transfers to OwnedPointer.
        raw_g[] = AtomicI32(Int32(0))
        self._gen = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_g,
        )
        var raw_p = alloc[AtomicI32](1)
        # SAFETY: same pattern. uint8 lacks compare_exchange on Mojo
        # 0.26.3 (finding 4) — use int32 for the permit slot too.
        raw_p[] = AtomicI32(Int32(0))
        self._stored_permit = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_p,
        )


# =============================================================================
# Notify — public Movable wrapper
# =============================================================================


@fieldwise_init
struct Notify(Movable, Deinitable):
    """Stateless event.

    Movable wrapper over ArcPointer[_NotifyShared] heap state.

    This form ships:
      * `new()`: construct.
      * `notify_one(mut self)`: wake ONE parked waiter; lost if none.
      * `notify_one_permit(mut self)`: wake ONE; if none, store at-most-1
        permit so the next notified() returns immediately.
      * `notify_waiters(mut self)`: wake ALL parked waiters.
      * `notified(self)`: synchronous-park; consumes a stored permit if
        present, else parks on _gen until a notify fires.

    An IoOp[(), NoopSink, never_origin] form needs
    the scheduler step.
    """

    var _shared: ArcPointer[_NotifyShared]

    @staticmethod
    def new() -> Notify:
        return Notify(_shared=ArcPointer[_NotifyShared](_NotifyShared()))

    def has_stored_permit(self) -> Bool:
        """Diagnostic: whether a permit is currently stored."""
        return self._shared[]._stored_permit[].load() != Int32(0)

    def gen_value(self) -> Int32:
        """Diagnostic: current generation counter."""
        return self._shared[]._gen[].load()

    def notify_one(mut self):
        """Wake exactly ONE waiter.

        If no waiter parked, the notification is LOST. Bumps gen + calls
        wake_one_by_address.
        """
        _ = self._shared[]._gen[].fetch_add(Int32(1))
        _ = wake_one_by_address(self._shared[]._gen[])

    def notify_one_permit(mut self):
        """Wake one OR store a permit.

        bump gen + wake_one + unconditionally store permit.
        Race semantics: if a waiter was just woken, the permit is extra
        — but it's bounded at most-1 (CAS'd 0→1) and the next
        notified() call consumes it. This matches the
        "at most ONE permit" guarantee.
        """
        # Try to wake a waiter first.
        _ = self._shared[]._gen[].fetch_add(Int32(1))
        _ = wake_one_by_address(self._shared[]._gen[])
        # Store permit (bounded; CAS 0→1 is idempotent).
        var expected = Int32(0)
        _ = self._shared[]._stored_permit[].compare_exchange(
            expected, Int32(1),
        )

    def notify_waiters(mut self):
        """Wake ALL waiters.

        Future notified() calls park as usual (no permit storage).
        """
        _ = self._shared[]._gen[].fetch_add(Int32(1))
        _ = wake_all_by_address(self._shared[]._gen[])

    def notified(self) raises:
        """Park until notified.

        Step 1: try to consume a stored permit (CAS 1→0). On success,
        return immediately.

        Step 2: park on _gen via Drep protocol. Snapshot gen,
        re-check permit, then park.

        synchronous-park form. An IoOp[(),
        NoopSink, never_origin] form is a later step.
        """
        # Step 1: try permit consume.
        var p_expected = Int32(1)
        if self._shared[]._stored_permit[].compare_exchange(
            p_expected, Int32(0),
        ):
            return  # Consumed permit; immediate return.
        # Step 2: park on _gen.
        var gen_snapshot = self._shared[]._gen[].load()
        while True:
            # Re-try permit consume between iterations (a permit may
            # have been stored after our initial check).
            var p_expected_inner = Int32(1)
            if self._shared[]._stored_permit[].compare_exchange(
                p_expected_inner, Int32(0),
            ):
                return  # Consumed permit.
            # Check gen advance (someone notify'd while we were prepping).
            var current_gen = self._shared[]._gen[].load()
            if current_gen != gen_snapshot:
                return  # Notify fired.
            # Park.
            _ = wait_on_address(
                self._shared[]._gen[],
                expected=gen_snapshot,
                timeout_ns=Int64(1_000_000),  # 1ms cancel-poll cadence.
            )

    def notified_with_token(self, var token: Bool) raises:
        """Tier 2 with-token form.

        Stub: token is Bool placeholder; swaps to
        CancellationToken.
        """
        _ = token
        self.notified()
