# =============================================================================
# komira_async.channel.oneshot — request/response single-shot
# =============================================================================
# module-level factory.
#
# Single value slot in `_OneshotShared` is heap-owned. State machine drives
# the send/recv handshake:
#
#   0 EMPTY  — initial; no value yet
#   1 SET    — sender wrote value; receiver can take it
#   2 CLOSED — one side dropped without send/recv
#
# State stored in `Atomic[int32]` (uint8 lacks compare_exchange). `send()` consumes `var self`, so a sender cannot send twice.
# `recv()` is similarly consumed; for try_recv() we keep the receiver alive
# (caller may want to poll for cancellation).
#
# This form ships try-API (synchronous, no parking). Park-on-Mechanism-D
# wake-by-address integration is deferred (when channels integrate
# with the IoOp wait-queue).
#
# Pointer discipline:
#   - OneshotSender / OneshotReceiver public API: typed scalars + status codes
#     + TryRecvOutcome[T] (reused from SPSC).
#   - `_shared: ArcPointer[_OneshotShared[T]]` is the encapsulated internal field.
#   - Zero UnsafePointer in public signatures; zero wildcard origins.
#
# T bound: matches SPSC + MPSC — `Movable & Copyable & ImplicitlyCopyable &
# Deinitable`.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI32

from komira_async.channel.spsc import (
    TryRecvOutcome,
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
    TRY_RECV_CLOSED,
)


# =============================================================================
# Send-side status codes
# =============================================================================
# A Result[(), T] would recover the value on
# receiver-dropped. Mojo 0.26.3 has no Result, so this ships a status
# code (matches SPSC's TRY_SEND_OK/CLOSED). Value-recovery on
# receiver-dropped is a possible refinement (would require returning the
# moved-in value; the test_send_after_receiver_close case exercises the
# CLOSED path).

comptime SEND_OK: UInt8 = 0
comptime SEND_CLOSED: UInt8 = 1

# State machine values for `_state: Atomic[int32]`.
comptime _STATE_EMPTY: Int32 = 0
comptime _STATE_SET: Int32 = 1
comptime _STATE_CLOSED: Int32 = 2


# =============================================================================
# _OneshotShared[T] — heap state owned by ArcPointer
# =============================================================================


struct _OneshotShared[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Movable, Deinitable):
    """single value slot + atomic state machine.

    State machine values (held in `_state`):
      0 EMPTY  — initial; sender has not written
      1 SET    — sender wrote; receiver can take
      2 CLOSED — one side dropped without complete handshake

    Atomic[int32] not uint8 because Mojo 0.26.3 uint8 atomics lack
    compare_exchange (finding 4).

    Slot held via `OwnedPointer[Optional[T]]` — heap-stable address; the
    Optional starts None and gets populated on send.
    """

    var _state: OwnedPointer[AtomicI32]
    var _slot: OwnedPointer[Optional[Self.T]]
    var _wake_word: OwnedPointer[AtomicI32]   # park-by-address gen counter

    def __init__(out self) raises:
        var s_raw = alloc[AtomicI32](1)
        s_raw[] = AtomicI32(_STATE_EMPTY)
        self._state = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=s_raw
        )

        # Heap-stable slot. Initially None; populated on send.
        # Use init_pointee_move / pthread_worker idiom — the
        # raw slot is uninitialized memory; assignment requires a
        # destructor on the prior value, which would read garbage.
        var slot_raw = alloc[Optional[Self.T]](1)
        UnsafePointer(to=slot_raw[]).unsafe_write(Optional[Self.T]())
        self._slot = OwnedPointer[Optional[Self.T]](
            unsafe_from_raw_pointer=slot_raw
        )

        var wake_raw = alloc[AtomicI32](1)
        wake_raw[] = AtomicI32(Int32(0))
        self._wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=wake_raw
        )


# =============================================================================
# OneshotSender[T] — single-shot producer
# =============================================================================


struct OneshotSender[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Movable, Deinitable):
    """Single-shot sender.

    `send()` consumes `var self` so the type system enforces at-most-once
    send. (Calling `tx^.send(v)` after a `take_sender()` is the canonical
    pattern; a second move is rejected because the original `tx` was
    already consumed.)

    Pointer discipline: `_shared: ArcPointer[_OneshotShared[T]]` encapsulated.
    """

    var _shared: ArcPointer[_OneshotShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_OneshotShared[Self.T]]):
        self._shared = shared^

    def send(var self, var value: Self.T) -> UInt8:
        """Single-shot send.

        Consumes `self` (self moves into the call frame and drops at end).
        Returns SEND_OK on success; SEND_CLOSED if the receiver has already
        closed (dropped without receiving).

        Value-recovery on receiver-dropped (a Result[(), T]
        Err arm) is deferred — the moved-in value drops with the sender's
        scope.

        CAS the state from EMPTY to SET. On success, write value into slot.
        On state-already-CLOSED (receiver dropped first), return
        SEND_CLOSED; the value drops with self's scope.
        """
        # CAS EMPTY → SET. Returns True iff the swap happened.
        # Mojo 0.26.3 compare_exchange takes `expected` as a local var
        # (not an alias literal) per AsyncMutex precedent.
        var expected = _STATE_EMPTY
        var cas_ok = self._shared[]._state[].compare_exchange(
            expected, _STATE_SET
        )
        if cas_ok:
            # We won; populate the slot.
            self._shared[]._slot[] = Optional[Self.T](value^)
            # Bump wake_word for any parked receivers.
            _ = self._shared[]._wake_word[].fetch_add(Int32(1))
            return SEND_OK
        # CAS failed — state was either already SET (impossible: only one
        # send can win) or CLOSED. Either way, sender path returns CLOSED.
        return SEND_CLOSED

    def close(var self):
        """Mark the channel CLOSED from the sender side. Drops `self` too.

        Idempotent if state was already SET / CLOSED (only the EMPTY → CLOSED
        transition does anything useful). After close(), receiver's
        try_recv() will return TRY_RECV_CLOSED.
        """
        var expected = _STATE_EMPTY
        var _cas = self._shared[]._state[].compare_exchange(
            expected, _STATE_CLOSED
        )
        # Bump wake_word so any parked receiver re-checks state.
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))


# =============================================================================
# OneshotReceiver[T] — single-shot consumer
# =============================================================================


struct OneshotReceiver[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Movable, Deinitable):
    """Single-shot receiver.

    This form ships try_recv (synchronous). The blocking `recv()` form
    (parking on wake_word for cancellation-aware wait) is deferred to
    a later step.

    Pointer discipline: `_shared: ArcPointer[_OneshotShared[T]]` encapsulated.
    """

    var _shared: ArcPointer[_OneshotShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_OneshotShared[Self.T]]):
        self._shared = shared^

    def try_recv(mut self) -> TryRecvOutcome[Self.T]:
        """Non-blocking try_recv.

        Returns:
          TRY_RECV_OK    — slot populated; value moved out and state
                           transitioned to CLOSED (one-shot drained).
          TRY_RECV_EMPTY — state is EMPTY; sender has not yet sent.
          TRY_RECV_CLOSED — state is CLOSED (sender dropped without send,
                            or value was already drained).
        """
        var s = self._shared[]._state[].load()
        if s == _STATE_SET:
            # We have a value. CAS SET → CLOSED to claim it; only one
            # receiver can win (we're single-consumer but still).
            var expected = _STATE_SET
            var cas_ok = self._shared[]._state[].compare_exchange(
                expected, _STATE_CLOSED
            )
            if cas_ok:
                # Move out the value.
                var taken_value = self._shared[]._slot[].take()
                return TryRecvOutcome[Self.T].ok(taken_value^)
            # CAS lost — state changed under us; re-load and report.
            s = self._shared[]._state[].load()
        if s == _STATE_CLOSED:
            return TryRecvOutcome[Self.T].closed()
        # _STATE_EMPTY remains.
        return TryRecvOutcome[Self.T].empty()

    def close(var self):
        """Mark CLOSED from the receiver side. Sender's subsequent send()
        returns SEND_CLOSED."""
        var expected = _STATE_EMPTY
        var _cas = self._shared[]._state[].compare_exchange(
            expected, _STATE_CLOSED
        )
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))


# =============================================================================
# OneshotChannelPair[T] — factory return wrapper
# =============================================================================
# Mojo 0.26.3 Tuple subscript-then-move-out incompatibility. Same shape as SpscChannelPair / MpscChannelPair.


struct OneshotChannelPair[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Movable, Deinitable):
    """Result of `oneshot::channel()`. Caller invokes `take_sender()` /
    `take_receiver()` to extract endpoints."""

    var _sender: Optional[OneshotSender[Self.T]]
    var _receiver: Optional[OneshotReceiver[Self.T]]

    def __init__(
        out self,
        var sender: OneshotSender[Self.T],
        var receiver: OneshotReceiver[Self.T],
    ):
        self._sender = Optional[OneshotSender[Self.T]](sender^)
        self._receiver = Optional[OneshotReceiver[Self.T]](receiver^)

    def take_sender(mut self) raises -> OneshotSender[Self.T]:
        if not self._sender:
            raise Error("OneshotChannelPair: sender already taken")
        return self._sender.take()

    def take_receiver(mut self) raises -> OneshotReceiver[Self.T]:
        if not self._receiver:
            raise Error("OneshotChannelPair: receiver already taken")
        return self._receiver.take()


# =============================================================================
# Module-level factory:
# =============================================================================


def channel[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
]() raises -> OneshotChannelPair[T]:
    """Construct a oneshot channel pair.

    Returns: OneshotChannelPair[T] — caller invokes `take_sender()` /
    `take_receiver()` to extract endpoints. Both endpoints share the same
    heap-allocated `_OneshotShared[T]` via ArcPointer.
    """
    var shared = ArcPointer[_OneshotShared[T]](_OneshotShared[T]())
    var sender_arc = ArcPointer[_OneshotShared[T]](copy=shared)
    var sender = OneshotSender[T](shared=sender_arc^)
    var receiver = OneshotReceiver[T](shared=shared^)
    return OneshotChannelPair[T](sender=sender^, receiver=receiver^)
