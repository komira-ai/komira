# =============================================================================
# komira_async.sync.select — multi-source first-fires combinator
# =============================================================================
# HTTP client (PendingCheckout late-binding race): a consumer that
# wants to await EITHER of two notifies (e.g., a connection-checkout-ready
# signal OR a cancellation signal) needs a `select` / `race` / `first_of`
# combinator, and komira_async had
# no such combinator on its closed
# 8-trait / 39-struct surface (Notify is single-source, OneshotReceiver is
# single-source non-blocking, Mpsc/Spsc/Broadcast are channels not select-
# style, IoOp / TaskScope.wait_all are all-of).
#
# This module grows the surface by adding `SelectFirstNotify`: two-source,
# constant-time first-fires gating, idempotent second-fires.
#
# Internal mechanism (mirrors Notify / oneshot precedent):
#   * `_gate: Atomic[int32]` — 0 = no fire, 1 = source 0 won, 2 = source 1
#     won. CAS'd by fire_source_* to claim the first-fires slot. Public
#     API returns UInt8 (0 or 1) — int32 used internally because
#     Atomic[uint8] lacks compare_exchange on Mojo 0.26.3/1.0.0b1
#     (finding 4 — see oneshot.mojo:13).
#   * `_wake_word: Atomic[int32]` — Drep generation counter, bumped
#     by either fire_source_*. await_first parks via wait_on_address on
#     this word; wakes on either source's fire.
#
# Both atomics held via OwnedPointer<Atomic> per Notify precedent
# (Atomic[T] is non-Movable on 0.26.3, so heap-stable indirection is
# required for the Movable handle).
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO wildcard origins on public surface.
#   - ArcPointer encapsulated as `_shared:` internal field (matches
#     Notify / Semaphore / AsyncMutex / oneshot — last resort for true
#     shared-state ownership between parked awaiter + remote firers).
#   - No additive parallel API; no `unsafe_from_address`; no take_pointee.
#
# Cross-pthread safety: SelectFirstNotify can be moved (Movable handle =
# ArcPointer) and cloned by `from_handle()` so multiple workers can fire
# their respective sources. The gate CAS + wake-by-address combination
# is safe under arbitrary pthread interleaving.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from komira_atomic_alias import AtomicI32

from komira_async.runtime.wake_primitives import (
    wait_on_address,
    wake_one_by_address,
)


# =============================================================================
# Gate values (also exposed as comptime int32 constants for internal use).
# Public API returns UInt8 (0 or 1).
# =============================================================================

comptime _GATE_NO_FIRE: Int32 = 0
comptime _GATE_SOURCE_0: Int32 = 1
comptime _GATE_SOURCE_1: Int32 = 2


# =============================================================================
# _SelectFirstShared — heap-allocated shared state
# =============================================================================


struct _SelectFirstShared(Movable, Deinitable):
    """Heap-allocated shared state for SelectFirstNotify.

    `_gate` is the first-fires gate. 0 = no fire yet; 1 = source 0 won;
    2 = source 1 won. The CAS in fire_source_* is the single point of
    arbitration — whichever source's CAS succeeds first wins.

    `_wake_word` is the Drep generation counter. Bumped on every
    fire_source_*; parked await_first callers park on it via
    wait_on_address with the snapshot from BEFORE the gate-recheck.

    ArcPointer-shared between the SelectFirstNotify handle, all parked
    await_first callers, and any threads issuing fire_source_*.
    """

    var _gate: OwnedPointer[AtomicI32]
    var _wake_word: OwnedPointer[AtomicI32]

    def __init__(out self):
        var raw_g = alloc[AtomicI32](1)
        # SAFETY: raw_g is a fresh allocation we own. Atomic ctor accepts
        # a Scalar value. Ownership transfers to OwnedPointer.
        raw_g[] = AtomicI32(_GATE_NO_FIRE)
        self._gate = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_g,
        )
        var raw_w = alloc[AtomicI32](1)
        # SAFETY: same pattern as _gate.
        raw_w[] = AtomicI32(Int32(0))
        self._wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw_w,
        )


# =============================================================================
# SelectFirstNotify — public Movable wrapper
# =============================================================================


@fieldwise_init
struct SelectFirstNotify(Movable, Deinitable):
    """Two-source first-fires combinator.

    Use case: a `PendingCheckout` wants to wait
    for EITHER of:
      - source 0: a connection becomes idle in the pool, or
      - source 1: the request's cancellation token fires.

    Whichever fires first wins; `await_first` returns the index (0 or 1)
    of the winner. Second fires are no-ops on the result (the gate is
    CAS-claimed by the first fire; subsequent fires still bump the wake
    word but cannot change the gate's value).

    Constructed via `SelectFirstNotify.new()`. Use `from_handle()` to
    clone the ArcPointer handle for cross-thread firing — one thread
    fires source 0 from its own SelectFirstNotify handle while another
    fires source 1 from its own clone of the same shared state.

    Movable wrapper over ArcPointer[_SelectFirstShared] heap state.
    Pointer discipline: ZERO UnsafePointer in public methods; ZERO
    wildcard origins.
    """

    var _shared: ArcPointer[_SelectFirstShared]

    @staticmethod
    def new() -> SelectFirstNotify:
        """Construct a fresh SelectFirstNotify in the no-fire state."""
        return SelectFirstNotify(
            _shared=ArcPointer[_SelectFirstShared](_SelectFirstShared()),
        )

    def from_handle(self) -> SelectFirstNotify:
        """Clone this handle for cross-pthread firing.

        Both clones share the same `_SelectFirstShared` heap state via
        ArcPointer copy. Use this to give worker pthread A a handle that
        calls fire_source_0() while pthread B fires source 1.
        """
        return SelectFirstNotify(
            _shared=ArcPointer[_SelectFirstShared](copy=self._shared),
        )

    def gate_value(self) -> Int32:
        """Diagnostic: current gate state.

        Returns 0 (no fire), 1 (source 0 won), or 2 (source 1 won).
        Public API consumers should call `await_first` instead.
        """
        return self._shared[]._gate[].load()

    def wake_word_value(self) -> Int32:
        """Diagnostic: current wake_word generation counter."""
        return self._shared[]._wake_word[].load()

    def fire_source_0(mut self):
        """Fire source 0.

        Race-CAS the gate from 0 → 1 (source 0 wins) ONLY if no prior
        fire has succeeded. If the CAS fails (gate already 1 or 2), the
        fire is a no-op on the gate but still bumps wake_word to wake
        any parked awaiter.

        Always bumps wake_word + wakes one parked thread by address.

        Idempotent: a second fire_source_0 after the gate is already 1
        does NOT change the gate; await_first still returns 0.
        """
        var expected = _GATE_NO_FIRE
        _ = self._shared[]._gate[].compare_exchange(
            expected, _GATE_SOURCE_0,
        )
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))
        _ = wake_one_by_address(self._shared[]._wake_word[])

    def fire_source_1(mut self):
        """Fire source 1.

        Race-CAS the gate from 0 → 2 (source 1 wins) ONLY if no prior
        fire has succeeded. If the CAS fails (gate already 1 or 2), the
        fire is a no-op on the gate but still bumps wake_word.

        Symmetric to fire_source_0. Idempotent: a second fire_source_1
        after the gate is already 2 does NOT change the gate; await_first
        still returns 1.
        """
        var expected = _GATE_NO_FIRE
        _ = self._shared[]._gate[].compare_exchange(
            expected, _GATE_SOURCE_1,
        )
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))
        _ = wake_one_by_address(self._shared[]._wake_word[])

    def await_first(mut self) raises -> UInt8:
        """Park until either source fires; return the winning index.

        Returns 0 if source 0 fired first; 1 if source 1 fired first.

        Drep lost-wakeup-safe protocol:
          1. Load gate; if set, return immediately.
          2. Snapshot wake_word.
          3. Re-load gate (a fire may have happened between step 1 and
             step 2); if set, return.
          4. wait_on_address(wake_word, expected=ww_snapshot, timeout_ns=
             1_000_000ns = 1ms). Returns either on wake or timeout
             (kernel value-compare mismatch == race-benign).
          5. Loop.

        The 1ms timeout is a cancel-poll cadence (matches Notify's
        `notified()` in notify.mojo — same protocol).

        Synchronous-park form; lifts to IoOp[(),
        NoopSink, never_origin] form when the scheduler step is in
        place (consistent with Notify's deferred lift).
        """
        while True:
            var gate = self._shared[]._gate[].load()
            if gate == _GATE_SOURCE_0:
                return UInt8(0)
            if gate == _GATE_SOURCE_1:
                return UInt8(1)
            # Drepper snapshot: wake_word before re-checking gate.
            var ww_snapshot = self._shared[]._wake_word[].load()
            # Re-check gate AFTER snapshot — a fire between the first load
            # and the snapshot must NOT be lost.
            var gate2 = self._shared[]._gate[].load()
            if gate2 == _GATE_SOURCE_0:
                return UInt8(0)
            if gate2 == _GATE_SOURCE_1:
                return UInt8(1)
            # Park on wake_word. -EAGAIN / wake / timeout all loop back
            # to the gate-load at the top.
            _ = wait_on_address(
                self._shared[]._wake_word[],
                expected=ww_snapshot,
                timeout_ns=Int64(1_000_000),  # 1ms cancel-poll cadence.
            )

    def await_first_or_timeout(
        mut self, total_timeout_ns: Int64,
    ) raises -> Optional[UInt8]:
        """Park up to `total_timeout_ns`; return Some(winning index) or None.

        Single-shot timeout (NOT a polling cadence). Returns:
          - Some(0) — source 0 fired first within the timeout.
          - Some(1) — source 1 fired first within the timeout.
          - None   — neither source fired within the timeout.

        Implementation uses `wait_on_address` with the full timeout
        passed through directly; on a single wake (or timeout) we
        re-check the gate. If still no-fire, we return None. If the
        gate was set by a CAS that raced with our park, the wake
        protocol catches it via -EAGAIN.

        For multi-source race with a single deadline, this is the
        canonical form. Callers that need cancellation-aware polling
        should use `await_first` (which has the 1ms internal poll
        cadence).
        """
        # Fast-path: check gate before parking.
        var gate = self._shared[]._gate[].load()
        if gate == _GATE_SOURCE_0:
            return Optional[UInt8](UInt8(0))
        if gate == _GATE_SOURCE_1:
            return Optional[UInt8](UInt8(1))
        # Drepper snapshot.
        var ww_snapshot = self._shared[]._wake_word[].load()
        # Re-check gate.
        var gate2 = self._shared[]._gate[].load()
        if gate2 == _GATE_SOURCE_0:
            return Optional[UInt8](UInt8(0))
        if gate2 == _GATE_SOURCE_1:
            return Optional[UInt8](UInt8(1))
        # Park with the full deadline.
        _ = wait_on_address(
            self._shared[]._wake_word[],
            expected=ww_snapshot,
            timeout_ns=total_timeout_ns,
        )
        # Re-check gate after wake/timeout. If set, return the winner.
        var gate_final = self._shared[]._gate[].load()
        if gate_final == _GATE_SOURCE_0:
            return Optional[UInt8](UInt8(0))
        if gate_final == _GATE_SOURCE_1:
            return Optional[UInt8](UInt8(1))
        # Timeout — no fire happened.
        return Optional[UInt8](None)
