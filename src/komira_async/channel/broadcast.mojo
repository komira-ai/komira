# =============================================================================
# komira_async.channel.broadcast — pub/sub fan-out
# =============================================================================
# module-level factory.
#
# Ring buffer of `capacity` slots. Producer increments `_pos: Atomic[uint64]`
# and writes value at pos % capacity. Each subscriber holds its own
# `_cursor: UInt64`. Slow-receiver: lag-then-error (tokio default).
#
# Bounds memory at `capacity * sizeof(T)` regardless of consumer behavior.
# Lag detection: if `pos > cursor + capacity`, the slot at cursor has been
# overwritten — we report LAGGED with the cursor advanced to
# `pos - capacity` so subsequent recvs see the latest available capacity
# values.
#
# Storage layout (mirrors the MPSC pattern):
#   - Per-slot sequence numbers in CONTIGUOUS `OwnedPointer[Atomic[uint64]]`
#     allocation of size capacity. Index access via `seq_base + idx` pointer
#     arithmetic INSIDE the channel module (encapsulated; SAFETY block).
#   - `_slots: List[Optional[T]]` for value storage. T must be Copyable so
#     each subscriber receives its own copy.
#
# This form ships try-API (synchronous, no parking). Park-on-Mechanism-D
# wake-by-address integration is deferred.
#
# Pointer discipline:
#   - BroadcastSender / BroadcastReceiver public API uses ONLY typed
#     scalars + status codes + BroadcastRecvOutcome.
#   - `_shared: ArcPointer[_BroadcastShared[T]]` is the encapsulated internal field.
#   - Zero UnsafePointer in public signatures; zero wildcard origins.
#
# T bound: `Copyable & ImplicitlyCopyable & Movable & Deinitable`
# (every subscriber gets a copy; T MUST be Copyable).
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI32, AtomicU64


# =============================================================================
# Status codes (POD discriminants)
# =============================================================================

comptime BCAST_RECV_OK: UInt8 = 0
comptime BCAST_RECV_EMPTY: UInt8 = 1
comptime BCAST_RECV_CLOSED: UInt8 = 2
comptime BCAST_RECV_LAGGED: UInt8 = 3


@fieldwise_init
struct BroadcastRecvOutcome[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Movable, Copyable, Deinitable):
    """Tagged-union return for BroadcastReceiver.try_recv() — extends
    SPSC's TryRecvOutcome shape with a LAGGED status.
    """

    var status: UInt8
    var _payload: Optional[Self.T]

    @staticmethod
    def ok(var v: Self.T) -> BroadcastRecvOutcome[Self.T]:
        return BroadcastRecvOutcome[Self.T](
            status=BCAST_RECV_OK, _payload=Optional[Self.T](v^)
        )

    @staticmethod
    def empty() -> BroadcastRecvOutcome[Self.T]:
        return BroadcastRecvOutcome[Self.T](
            status=BCAST_RECV_EMPTY, _payload=Optional[Self.T]()
        )

    @staticmethod
    def closed() -> BroadcastRecvOutcome[Self.T]:
        return BroadcastRecvOutcome[Self.T](
            status=BCAST_RECV_CLOSED, _payload=Optional[Self.T]()
        )

    @staticmethod
    def lagged() -> BroadcastRecvOutcome[Self.T]:
        return BroadcastRecvOutcome[Self.T](
            status=BCAST_RECV_LAGGED, _payload=Optional[Self.T]()
        )

    def value(self) -> Self.T:
        """Unwrap the payload. Caller MUST verify `status == BCAST_RECV_OK`
        first; otherwise the underlying Optional is None."""
        return self._payload.value()


# =============================================================================
# _BroadcastShared[T] — heap state owned by ArcPointer
# =============================================================================
# Per-slot sequence numbers stored in a contiguous heap allocation; values
# in a List[Optional[T]] of length capacity. Each slot holds its
# write-position in seq_array[idx]; receiver compares its cursor's expected
# position against seq_array[cursor & mask].


struct _BroadcastShared[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable
](Movable, Deinitable):
    """Broadcast ring buffer shared state.

    Producer writes via fetch_add on _pos; each producer write claims a
    unique pos and writes to slot[pos & mask]. Per-slot _seq_array stores
    the latest write-position (so receivers can detect overwrite/lag).

    State (sender close + sub count):
      _state: Atomic[int32] — 0=open, 1=sender-closed.
      _sub_count: Atomic[int32] — live subscriber count (decremented on
                                  receiver close).
    """

    var _slots: List[Optional[Self.T]]
    var _seq_array: OwnedPointer[AtomicU64]   # contiguous; indexed via offset
    var _pos: OwnedPointer[AtomicU64]         # producer fetch_add cursor
    var _mask: UInt64
    var _capacity: UInt64
    var _state: OwnedPointer[AtomicI32]        # 0=open, 1=sender closed
    var _sub_count: OwnedPointer[AtomicI32]    # live receivers
    var _wake_word: OwnedPointer[AtomicI32]    # park-by-address gen counter

    def __init__(out self, capacity: UInt) raises:
        if capacity == 0:
            raise Error("BroadcastChannel: capacity must be > 0")
        if (capacity & (capacity - 1)) != 0:
            raise Error("BroadcastChannel: capacity must be a power of 2")

        var cap_u64 = UInt64(capacity)

        # Per-slot sequence numbers. Initial value 0; producer's first write
        # at pos=0 sets seq[0]=1, etc.
        # SAFETY: seq_raw is a fresh capacity-sized allocation we own. Each
        # slot is initialized to 0 (no value yet at any position).
        var seq_raw = alloc[AtomicU64](Int(capacity))
        for i in range(Int(capacity)):
            (seq_raw + i)[] = AtomicU64(UInt64(0))
        self._seq_array = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=seq_raw
        )

        # Pre-allocate value slots.
        self._slots = List[Optional[Self.T]]()
        for _ in range(Int(capacity)):
            self._slots.append(Optional[Self.T]())

        var pos_raw = alloc[AtomicU64](1)
        pos_raw[] = AtomicU64(UInt64(0))
        self._pos = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=pos_raw
        )

        var state_raw = alloc[AtomicI32](1)
        state_raw[] = AtomicI32(Int32(0))
        self._state = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=state_raw
        )

        # Sub count starts at 1 (the receiver returned by `channel(cap)`).
        var sub_raw = alloc[AtomicI32](1)
        sub_raw[] = AtomicI32(Int32(1))
        self._sub_count = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=sub_raw
        )

        var wake_raw = alloc[AtomicI32](1)
        wake_raw[] = AtomicI32(Int32(0))
        self._wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=wake_raw
        )

        self._mask = cap_u64 - UInt64(1)
        self._capacity = cap_u64


# =============================================================================
# BroadcastSender[T] — publisher
# =============================================================================


struct BroadcastSender[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Multi-subscriber publisher.

    Pointer discipline: `_shared: ArcPointer[_BroadcastShared[T]]` encapsulated.
    """

    var _shared: ArcPointer[_BroadcastShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_BroadcastShared[Self.T]]):
        self._shared = shared^

    def send(mut self, var value: Self.T) -> Int32:
        """Send a value to all subscribers.

        Returns: live subscriber count after the send. 0 if no subscribers.

        Slow-subscriber behavior: lag-then-error. The
        sender always succeeds; slow subscribers detect lag on their next
        try_recv() and receive BCAST_RECV_LAGGED with cursor advanced.

        SAFETY: pointer arithmetic on _seq_array via `seq_base + idx`
        is INSIDE this module. Index is bounded by `& mask` so always
        in [0, capacity).
        """
        # Claim a position via fetch_add.
        var pos = self._shared[]._pos[].fetch_add(UInt64(1))
        var idx = Int(pos & self._shared[]._mask)
        # Write value into slot. Optional.take() is NOT used here — we
        # OVERWRITE any prior value at this slot index (this is the
        # ring-overflow path that defines "lag" for slow subscribers).
        # The prior Optional drops its prior payload (if any) on the
        # assignment.
        self._slots_set(idx, value^)
        # MOJO 1.0.0: `seq_base` is taken HERE and not before `_slots_set`.
        # It is an interior reference into `self._shared[]._seq_array[]`, and
        # `_slots_set` takes `mut self` — 1.0.0 invalidates the reference across
        # that borrow ("use of invalidated interior reference"). Taking it after
        # is EQUIVALENT, not a workaround: `_seq_array` is an
        # `OwnedPointer[Atomic[...]]`, a stable heap allocation, and `_slots_set`
        # writes only `_slots`, so the address is identical either way. The
        # release-store below already had to follow the slot write for the
        # memory ordering, so nothing about the ordering changed.
        #
        # SAFETY: see above; _seq_array is a capacity-sized contiguous
        # allocation owned by self._shared.
        var seq_base = UnsafePointer(to=self._shared[]._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        # Release-store slot's seq = pos + 1 (signals to receiver that
        # this slot now holds the value at write-position pos).
        AtomicU64.store(seq_base + idx, pos + UInt64(1))
        # Bump wake_word for parked subscribers.
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))
        return self._shared[]._sub_count[].load()

    def _slots_set(mut self, idx: Int, var value: Self.T):
        """Internal helper: overwrite slot[idx]'s Optional with the new value.

        The prior Optional (if Some) drops its T cleanly; we move the new
        value into a fresh Optional via `Optional[T](value^)`.
        """
        self._shared[]._slots[idx] = Optional[Self.T](value^)

    def subscribe(mut self) -> BroadcastReceiver[Self.T]:
        """New subscriber's cursor starts at current `_pos` so it sees only future sends."""
        # Increment sub_count first (preserves invariant: count is always
        # ≥ live receivers).
        _ = self._shared[]._sub_count[].fetch_add(Int32(1))
        # New cursor at current pos (prior values not replayed).
        var current_pos = self._shared[]._pos[].load()
        return BroadcastReceiver[Self.T](
            shared=ArcPointer[_BroadcastShared[Self.T]](copy=self._shared),
            cursor=current_pos,
        )

    def close(var self):
        """Mark sender-side closed. Subscribers' next try_recv after their
        ring drains returns BCAST_RECV_CLOSED."""
        AtomicI32.store(
            UnsafePointer(to=self._shared[]._state[]).unsafe_bitcast[Scalar[DType.int32]](),
            Int32(1),
        )
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))


# =============================================================================
# BroadcastReceiver[T] — subscriber
# =============================================================================


struct BroadcastReceiver[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """

    Pointer discipline: `_shared: ArcPointer[_BroadcastShared[T]]` encapsulated.
    Each receiver has its own `_cursor: UInt64` which advances on recv.
    """

    var _shared: ArcPointer[_BroadcastShared[Self.T]]
    var _cursor: UInt64

    def __init__(
        out self,
        var shared: ArcPointer[_BroadcastShared[Self.T]],
        cursor: UInt64,
    ):
        self._shared = shared^
        self._cursor = cursor

    def try_recv(mut self) -> BroadcastRecvOutcome[Self.T]:
        """Non-blocking recv.

        Returns:
          BCAST_RECV_OK     — slot at cursor populated; value copied out;
                              cursor advanced.
          BCAST_RECV_EMPTY  — pos == cursor (no new values yet).
          BCAST_RECV_LAGGED — pos > cursor + capacity (slow consumer
                              missed values); cursor auto-advances to
                              pos - capacity.
          BCAST_RECV_CLOSED — pos == cursor AND sender closed.

        SAFETY: pointer arithmetic on _seq_array via `seq_base + idx`
        is INSIDE this module.
        """
        # SAFETY: see above.
        var seq_base = UnsafePointer(to=self._shared[]._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        var pos = self._shared[]._pos[].load()
        if pos == self._cursor:
            # No new values. Distinguish closed from empty.
            if self._shared[]._state[].load() != Int32(0):
                return BroadcastRecvOutcome[Self.T].closed()
            return BroadcastRecvOutcome[Self.T].empty()
        # Lag check: if pos > cursor + capacity, the slot at cursor has
        # been overwritten. Advance cursor to pos - capacity (the oldest
        # still-available position) and report LAGGED.
        if pos > self._cursor + self._shared[]._capacity:
            self._cursor = pos - self._shared[]._capacity
            return BroadcastRecvOutcome[Self.T].lagged()
        # Read slot at cursor.
        var idx = Int(self._cursor & self._shared[]._mask)
        # Verify slot's seq matches expected (cursor + 1) — guard against
        # producer-overlap where the slot is being written right now.
        var expected_seq = self._cursor + UInt64(1)
        var slot_seq_ptr = seq_base + idx
        var slot_seq = AtomicU64.fetch_add(slot_seq_ptr, UInt64(0))
        if slot_seq != expected_seq:
            # Slot mid-write or has advanced (rare race). Treat as empty.
            # (This is the broadcast contract — the receiver re-checks
            # next try_recv.)
            return BroadcastRecvOutcome[Self.T].empty()
        # Copy value out (broadcast: subscribers see COPIES, slot retains).
        # T is Copyable so Optional.value() returns by copy.
        var v = self._shared[]._slots[idx].value()
        self._cursor = self._cursor + UInt64(1)
        return BroadcastRecvOutcome[Self.T].ok(v)

    def close(var self):
        """Decrement sub_count; subsequent send returns count - 1."""
        _ = self._shared[]._sub_count[].fetch_add(Int32(-1))
        _ = self._shared[]._wake_word[].fetch_add(Int32(1))


# =============================================================================
# BroadcastChannelPair[T] — factory return wrapper
# =============================================================================


struct BroadcastChannelPair[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Result of `broadcast::channel(cap)`. Caller invokes `take_sender()` /
    `take_receiver()` to extract endpoints. Same wrapper shape as
    SpscChannelPair / MpscChannelPair / OneshotChannelPair."""

    var _sender: Optional[BroadcastSender[Self.T]]
    var _receiver: Optional[BroadcastReceiver[Self.T]]

    def __init__(
        out self,
        var sender: BroadcastSender[Self.T],
        var receiver: BroadcastReceiver[Self.T],
    ):
        self._sender = Optional[BroadcastSender[Self.T]](sender^)
        self._receiver = Optional[BroadcastReceiver[Self.T]](receiver^)

    def take_sender(mut self) raises -> BroadcastSender[Self.T]:
        if not self._sender:
            raise Error("BroadcastChannelPair: sender already taken")
        return self._sender.take()

    def take_receiver(mut self) raises -> BroadcastReceiver[Self.T]:
        if not self._receiver:
            raise Error("BroadcastChannelPair: receiver already taken")
        return self._receiver.take()


# =============================================================================
# Module-level factory:
# =============================================================================


def channel[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](capacity: UInt) raises -> BroadcastChannelPair[T]:
    """Construct a Broadcast channel pair.

    `capacity` MUST be a power of 2 (ring index masking).
    Returns: BroadcastChannelPair[T] holding the sender + the FIRST
    subscriber. Additional subscribers via `sender.subscribe()`.
    """
    var shared = ArcPointer[_BroadcastShared[T]](_BroadcastShared[T](capacity))
    var sender_arc = ArcPointer[_BroadcastShared[T]](copy=shared)
    var sender = BroadcastSender[T](shared=sender_arc^)
    # First receiver's cursor at 0 (sees all values from pos=0 forward).
    var receiver = BroadcastReceiver[T](
        shared=shared^, cursor=UInt64(0)
    )
    return BroadcastChannelPair[T](sender=sender^, receiver=receiver^)
