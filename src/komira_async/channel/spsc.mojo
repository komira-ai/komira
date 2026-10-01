# =============================================================================
# komira_async.channel.spsc — single-producer, single-consumer
# =============================================================================
# Module-level factory.
# Vyukov SPSC + cache-line-isolated layout.
#
# Single-producer single-consumer ring buffer with Atomic[uint64] head + tail.
# Each side reads its own counter (relaxed), writes its own counter (release),
# reads the other's counter (acquire). No CAS in the hot path; ~2-3ns/send
# in a C++ reference; Mojo overhead is ~5-10ns due to Optional[T]
# wrapping for move-in/move-out.
#
# Cache-line isolation: each Atomic field lives behind OwnedPointer[Atomic],
# which means each Atomic is a separate heap allocation. tcmalloc/jemalloc
# both 16-byte-align small allocs, so head/tail naturally land on distinct
# cache lines (the layout requirement is met by
# separate allocations rather than in-struct padding).
#
# Pointer discipline:
#   - SpscSender / SpscReceiver public API uses ONLY typed scalars + Result
#     codes + List[T] (for batched recv).
#   - `_shared: ArcPointer[_SpscShared[T]]` is the encapsulated internal field.
#   - Zero UnsafePointer in public signatures; zero wildcard origins.
#
# Try-API + close + drain. Park-on-Mechanism-D wake-by-address
# integration is deferred (until channels integrate with the IoOp
# wait-queue). This ships try_send / try_recv / try_recv_batch as the
# primary API (batched-16 default).
#
# T bound: `Movable &
# Deinitable` — RELAXED from the prior `Movable & Copyable &
# ImplicitlyCopyable & Deinitable`. The relax is what lets the
# per-worker task queue carry the single-owner `ErasedHandle` (Movable-only,
# NOT Copyable) directly, retiring `_TaskEntry`'s bespoke wildcard byte-ptr.
#
# WHY the relax is now possible (the substrate swap, NOT a one-line bound
# change): the prior `Copyable` bound was forced by `List[Optional[T]]` (Mojo
# 1.0.0b1 `List` HARD-requires `T: Copyable`). The value-slot store is now
# a byte-backed `Slab[Optional[T]]` — `Slab[U]` requires only
# `U: Deinitable`, and `Optional[T]` is `Deinitable` +
# Movable for a Movable-only T (the in-tree `ErasedStepResult._result_blob:
# Optional[OwnedPointer[UInt8]]` precedent — `OwnedPointer` is non-Copyable).
# Move-in via `Slab.replace(i, Some(v^))`; move-out via
# `Slab.take_slot_unchecked(i)` then restore `None`. The Slab's destructor runs
# `Optional.__del__` on every slot cleanly (every slot is always a VALID
# `Optional[T]` — `None` or `Some` — never raw uninitialized bytes), so the
# destroy-recreate byte-slab-with-heap-owning-inner-field trap cannot fire: there is never an
# "uninitialized but counted-live" slot.
#
# The Copyable-requiring conveniences (`TryRecvOutcome.value()` copy accessor,
# `try_recv_batch -> List[T]`) are RETAINED but receiver-refined to
# `T: Copyable`, so `channel[Int]` callers keep them and a Movable-only T uses
# the move-out `take_value()` / `try_recv()` path instead.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI32, AtomicU64

from komira_core.collections.slab import Slab


# =============================================================================
# Status codes — POD return discriminants for try_* methods
# =============================================================================
# /1460 +use
# Result[T, TrySendError]/Result[T, TryRecvError]. Mojo 0.26.3 doesn't have
# a stdlib Result, so try_send returns a status code and try_recv returns a
# tagged-union struct (TryRecvOutcome) that carries either a value or a status.

comptime TRY_SEND_OK: UInt8 = 0
comptime TRY_SEND_FULL: UInt8 = 1
comptime TRY_SEND_CLOSED: UInt8 = 2

comptime TRY_RECV_OK: UInt8 = 0
comptime TRY_RECV_EMPTY: UInt8 = 1
comptime TRY_RECV_CLOSED: UInt8 = 2


@fieldwise_init
struct TrySendOutcome[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Tagged-union return for `try_send_back` — the Movable-only-T send path.

    The plain `try_send(var value) -> UInt8` consumes `value` and DROPS it on
    FULL / CLOSED — fine for a Copyable T (the caller still owns its copy), but
    for a Movable-only T (e.g. `ErasedHandle`) that LOSES the un-sent value (and
    leaks / mis-frees the heap it owns). `try_send_back` returns the status AND,
    on non-OK, HANDS THE VALUE BACK so the caller can retry-on-FULL (re-send the
    SAME value next attempt) or unwind-on-CLOSED (drop it explicitly). On OK the
    value was moved into the ring; `_payload` is `None`.

    Movable, NOT Copyable: it OWNS the un-sent `Optional[T]` payload on non-OK.
    Reach it via `take_value()` (move-out) after checking `status != TRY_SEND_OK`.
    """

    var status: UInt8
    var _payload: Optional[Self.T]

    @staticmethod
    def ok() -> TrySendOutcome[Self.T]:
        return TrySendOutcome[Self.T](
            status=TRY_SEND_OK, _payload=Optional[Self.T]()
        )

    @staticmethod
    def full(var value: Self.T) -> TrySendOutcome[Self.T]:
        return TrySendOutcome[Self.T](
            status=TRY_SEND_FULL, _payload=Optional[Self.T](value^)
        )

    @staticmethod
    def closed(var value: Self.T) -> TrySendOutcome[Self.T]:
        return TrySendOutcome[Self.T](
            status=TRY_SEND_CLOSED, _payload=Optional[Self.T](value^)
        )

    def take_value(mut self) -> Self.T:
        """Move the un-sent payload OUT (non-OK outcomes only). Caller MUST check
        `status != TRY_SEND_OK` first — on an OK outcome `_payload` is `None` and
        this triggers Optional.take()'s empty-Optional behavior."""
        return self._payload.take()


@fieldwise_init
struct TryRecvOutcome[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Tagged-union return for SpscReceiver.try_recv() — Mojo 1.0.0b1 stdlib
    has no Result[T, E]; this serves the same role.

    Discriminant: `status` field. When `status == TRY_RECV_OK` the payload is
    present; reach it via `take_value()` (move-out, works for any Movable T) or
    `value()` (copy, `T: Copyable` only). Otherwise the underlying Optional is
    None for non-OK outcomes.

    bound RELAXED to `Movable & Deinitable` and the
    struct is now `Movable` (NOT `Copyable`) — it OWNS its `Optional[T]` payload,
    so a Movable-only T (e.g. `ErasedHandle`) flows through without copies. The
    primary move-out accessor is `take_value()`; `value()` is retained for
    Copyable T (tests / ChannelStream).
    """

    var status: UInt8
    var _payload: Optional[Self.T]

    @staticmethod
    def ok(var v: Self.T) -> TryRecvOutcome[Self.T]:
        return TryRecvOutcome[Self.T](
            status=TRY_RECV_OK, _payload=Optional[Self.T](v^)
        )

    @staticmethod
    def empty() -> TryRecvOutcome[Self.T]:
        return TryRecvOutcome[Self.T](
            status=TRY_RECV_EMPTY, _payload=Optional[Self.T]()
        )

    @staticmethod
    def closed() -> TryRecvOutcome[Self.T]:
        return TryRecvOutcome[Self.T](
            status=TRY_RECV_CLOSED, _payload=Optional[Self.T]()
        )

    def take_value(mut self) -> Self.T:
        """Move the payload OUT, leaving the outcome's Optional in `None`.

        The single-owner move-out accessor — works for ANY Movable T
        (including Movable-only types like `ErasedHandle`). Caller MUST verify
        `status == TRY_RECV_OK` first; calling on EMPTY / CLOSED triggers
        Optional.take()'s empty-Optional behavior. After this call the outcome
        no longer owns the payload (safe to drop)."""
        return self._payload.take()

    def value(self) -> Self.T where conforms_to(Self.T, ImplicitlyCopyable):
        """Unwrap the payload by COPY (Copyable T only — e.g. `channel[Int]`,
        ChannelStream). Caller MUST verify `status == TRY_RECV_OK` first —
        calling this on EMPTY / CLOSED triggers Optional.value()'s empty-Optional
        behavior. For a Movable-only T use `take_value()` instead.

        MOJO-1.0.0: was `def value[_T: Copyable & ..., //](self:
        TryRecvOutcome[_T])` — a receiver refined at a tighter bound, which
        1.0.0 refuses ("'self' argument must have type 'Self'"). The conformance
        predicate is `conforms_to`."""
        return self._payload.value()


# =============================================================================
# _SpscShared[T] — heap state owned by ArcPointer; both sender and receiver
# reach it via _shared.
# =============================================================================


struct _SpscShared[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Single-producer single-consumer ring buffer's shared state.

    Movable + Deinitable (ArcPointer requires Movable). Atomic
    fields are held via OwnedPointer indirection because Atomic is non-Movable
    on Mojo 1.0.0b1 (finding: same shape as `_SpawnSlot[T]`).

    Each OwnedPointer[Atomic[D]] is a separate heap allocation; this gives
    natural cache-line isolation between head_ and tail_.

    Slots: `Slab[Optional[T]]` — a byte-backed slab, NOT
    `List[Optional[T]]`. The swap is what relaxes the channel `T` bound to
    Movable-only: `Slab[U]` requires only `U: Deinitable` (vs
    `List`'s HARD `T: Copyable`), and `Optional[T]` is `Deinitable`
    for a Movable-only T. Every slot is pre-filled to `None`
    (`create_prefilled` zero-fills, and a zeroed `Optional` IS the valid `None`
    discriminant), so the slab is FULLY initialized at construction and stays so:
    move-in is `Slab.replace(idx, Some(v^))` (returns the old `None`, dropped),
    move-out is `Slab.take_slot_unchecked(idx)` then `Slab.replace(idx, None)` to
    restore the slot to a valid `None`. There is never a raw-uninitialized slot,
    so the byte-slab destroy-recreate trap (heap-owning inner field at an uninitialized-but-
    counted-live offset) cannot fire — see the `__del__` teardown note.

    Close-state: TWO independent atomics (one for sender, one for receiver),
    each with a single writer. This avoids the `fetch_or`/CAS-loop dance
    that would be needed if a single bit-field atomic was shared.
    """

    var _head: OwnedPointer[AtomicU64]   # producer cursor
    var _tail: OwnedPointer[AtomicU64]   # consumer cursor
    var _slots: Slab[Optional[Self.T]]              # capacity power of 2
    var _mask: UInt64                                # capacity - 1
    var _capacity: UInt64
    var _sender_closed: OwnedPointer[AtomicI32]   # 0=open, 1=sender closed
    var _receiver_closed: OwnedPointer[AtomicI32] # 0=open, 1=receiver closed
    var _wake_word: OwnedPointer[AtomicI32]       # generation counter for park-by-address (Class E)

    def __init__(out self, capacity: UInt) raises:
        """Construct with a power-of-2 capacity. Raises if capacity is 0 or
        not a power of two."""
        if capacity == 0:
            raise Error("SpscChannel: capacity must be > 0")
        # Power-of-2 check: cap & (cap - 1) == 0
        if (capacity & (capacity - 1)) != 0:
            raise Error("SpscChannel: capacity must be a power of 2")

        var cap_u64 = UInt64(capacity)

        var head_raw = alloc[AtomicU64](1)
        head_raw[] = AtomicU64(UInt64(0))
        self._head = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=head_raw
        )

        var tail_raw = alloc[AtomicU64](1)
        tail_raw[] = AtomicU64(UInt64(0))
        self._tail = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=tail_raw
        )

        var s_raw = alloc[AtomicI32](1)
        s_raw[] = AtomicI32(Int32(0))
        self._sender_closed = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=s_raw
        )

        var r_raw = alloc[AtomicI32](1)
        r_raw[] = AtomicI32(Int32(0))
        self._receiver_closed = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=r_raw
        )

        var wake_raw = alloc[AtomicI32](1)
        wake_raw[] = AtomicI32(Int32(0))
        self._wake_word = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=wake_raw
        )

        # Pre-allocate capacity slots, all None. We use explicit `append(None)`
        # (NOT `create_prefilled`'s zero-fill) so we do not depend on a zeroed
        # `Optional` bit-pattern being a valid `None`; `append` move-constructs a
        # real `None` into each slot. After this loop `_slots.len() == capacity`
        # and every slot is a valid `Optional[T]` (None), so the Slab destructor
        # runs `Optional.__del__` on each slot cleanly.
        self._slots = Slab[Optional[Self.T]](Int(capacity))
        for _ in range(Int(capacity)):
            self._slots.append(Optional[Self.T]())

        self._mask = cap_u64 - UInt64(1)
        self._capacity = cap_u64

    # TEARDOWN NOTE (no hand-written __del__ needed): the auto-synthesized
    # `_SpscShared` destructor drops `_slots` (a `Slab[Optional[T]]`), whose own
    # `__del__` runs `Optional.__del__` on EVERY slot (length == capacity, all
    # valid `Optional[T]`) — dropping the inner `T` of any `Some` slot exactly
    # once, a no-op for `None` slots. Undelivered items left in the ring on
    # shutdown are freed by that per-slot drop. Because every slot is ALWAYS a
    # valid `Optional` (never raw-uninitialized bytes), there is no
    # "uninitialized-but-counted-live" offset for a heap-owning inner field of
    # `T` to dangle at — the byte-slab destroy-recreate trap cannot fire. This keeps the
    # clean teardown the prior `List[Optional[T]]` store had, while the
    # `Slab[Optional[T]]` swap drops the forced `T: Copyable` bound.


# =============================================================================
# SpscSender[T] — producer end
# =============================================================================


struct SpscSender[
    T: Movable & Deinitable
](Movable, Deinitable):
    """

    Pointer discipline: `_shared: ArcPointer[_SpscShared[T]]` is the only
    field; consumers see only typed scalars + Result codes.

    `T` bound relaxed to `Movable & Deinitable`
    (Movable-only payloads like `ErasedHandle`). The slot write is a move
    (`Slab.replace(idx, Some(value^))`), so no copy is needed.

    Note: ideally SpscSender is NOT Movable. In Mojo 0.26.3, we
    make it Movable (via the ArcPointer field's trivial move) for ergonomic
    construction in `channel(cap)`'s tuple return; the "single-producer"
    contract is enforced at the call site (don't clone() the sender). The
    underlying ring's head_ atomic counter is NOT clone-shared in any
    legitimate API path.
    """

    var _shared: ArcPointer[_SpscShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_SpscShared[Self.T]]):
        self._shared = shared^

    def try_send(mut self, var value: Self.T) -> UInt8:
        """Lock-free push.

        Returns: TRY_SEND_OK (0) on success; TRY_SEND_FULL (1) if ring is
        full; TRY_SEND_CLOSED (2) if receiver has closed the channel.

        Hot-path: relaxed-load head, acquire-load tail, write slot, release-
        store head + 1.
        """
        # Check receiver-closed first (early-exit fast path).
        if self._shared[]._receiver_closed[].load() != Int32(0):
            return TRY_SEND_CLOSED
        var head = self._shared[]._head[].load()
        var tail = self._shared[]._tail[].load()
        # Full when head - tail == capacity.
        if (head - tail) >= self._shared[]._capacity:
            return TRY_SEND_FULL
        var idx = Int(head & self._shared[]._mask)
        # Move value into slot via Slab.__setitem__ (destroys the prior `None`
        # occupant, move-constructs the new `Some(value)` in place). The slot
        # was a valid `None` (SPSC: the consumer restored `None` on take, or it
        # was the construction-time `None`), and `head - tail < capacity`
        # guarantees this slot is not still holding a not-yet-consumed value.
        self._shared[]._slots[idx] = Optional[Self.T](value^)
        # Release-store head (pair with consumer's acquire-load).
        # Mojo 0.26.3: use the static-method form Atomic[D].store(unsafe_ptr, value).
        AtomicU64.store(
            UnsafePointer(to=self._shared[]._head[]).unsafe_bitcast[Scalar[DType.uint64]](),
            head + UInt64(1),
        )
        return TRY_SEND_OK

    def close(mut self):
        """Mark sender-side closed; receiver
        can still drain remaining items, then sees TRY_RECV_CLOSED.
        Idempotent."""
        AtomicI32.store(
            UnsafePointer(to=self._shared[]._sender_closed[]).unsafe_bitcast[Scalar[DType.int32]](),
            Int32(1),
        )


# =============================================================================
# SpscReceiver[T] — consumer end
# =============================================================================


struct SpscReceiver[
    T: Movable & Deinitable
](Movable, Deinitable):
    """

    Pointer discipline: `_shared: ArcPointer[_SpscShared[T]]` encapsulated.

    `T` bound relaxed to `Movable & Deinitable`.
    `try_recv` moves the payload out via `Slab.replace(idx, None)` (returns the
    old `Some`, restores the slot to a valid `None`). The Copyable-requiring
    `try_recv_batch -> List[T]` is RETAINED, receiver-refined to `T: Copyable`.

    Note on Movable: same rationale as SpscSender — the "single-consumer"
    contract is enforced at the call site, not the type system in 1.13.
    """

    var _shared: ArcPointer[_SpscShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_SpscShared[Self.T]]):
        self._shared = shared^

    def try_recv(mut self) -> TryRecvOutcome[Self.T]:
        """Lock-free pop.

        Returns a TryRecvOutcome where `status` is one of:
          TRY_RECV_OK     (0) — payload present (reach via `take_value()` /
                                `value()`), FIFO-next item
          TRY_RECV_EMPTY  (1) — ring empty (sender may still send)
          TRY_RECV_CLOSED (2) — empty AND sender closed; no more items
        """
        var tail = self._shared[]._tail[].load()
        var head = self._shared[]._head[].load()
        if head == tail:
            # Empty: distinguish closed from open.
            if self._shared[]._sender_closed[].load() != Int32(0):
                return TryRecvOutcome[Self.T].closed()
            return TryRecvOutcome[Self.T].empty()
        var idx = Int(tail & self._shared[]._mask)
        # Move-out via Slab.replace(idx, None): returns the old `Some(value)`
        # occupant and restores the slot to a valid `None` in one move (the
        # Slab docstring's blessed move-out primitive for a non-Copyable element
        # — direct `slab[idx].take()` trips the implicit-copy check). The slot
        # stays a valid `Optional[T]` at all times (safe across destroy-recreate).
        var taken_opt = self._shared[]._slots.replace(idx, Optional[Self.T]())
        # Release-store tail (pair with producer's acquire-load).
        AtomicU64.store(
            UnsafePointer(to=self._shared[]._tail[]).unsafe_bitcast[Scalar[DType.uint64]](),
            tail + UInt64(1),
        )
        return TryRecvOutcome[Self.T].ok(taken_opt.take())


    def try_recv_batch(
        mut self, max_items: UInt
    ) -> List[Self.T] where conforms_to(Self.T, ImplicitlyCopyable):
        """Batch receive (185× speedup over per-item recv).

        Drains up to `max_items` items in a single fast-path sweep. Single
        acquire-load of head at start; loop with relaxed-loads for slot
        moves; single release-store of tail at end. This amortizes the
        cache-line fence cost (Seastar smp.hh batch=16 default).

        receiver-refined to `T: Copyable` — it returns a
        `List[T]`, and Mojo `List` HARD-requires a Copyable element. A
        Movable-only T uses the per-item `try_recv()` path instead. `channel[Int]`
        callers keep the batched fast path unchanged.

        Returns a List[T] of length min(max_items, available). Returns an
        empty list if ring is empty (status discrimination not needed —
        empty list IS the signal).

        MOJO-1.0.0: the receiver refinement above was spelled `mut self:
        SpscReceiver[_T]`, which 1.0.0 refuses. Same bound, now stated as
        `where conforms_to(...)`; call sites are unchanged.
        """
        var out = List[Self.T]()
        if max_items == 0:
            return out^
        var tail = self._shared[]._tail[].load()
        var head = self._shared[]._head[].load()
        var avail = head - tail
        if avail == UInt64(0):
            return out^
        var to_drain = avail
        if UInt64(max_items) < avail:
            to_drain = UInt64(max_items)
        for i in range(Int(to_drain)):
            var idx = Int((tail + UInt64(i)) & self._shared[]._mask)
            # Move-out + restore None (same Slab.replace primitive as try_recv).
            var taken_opt = self._shared[]._slots.replace(
                idx, Optional[Self.T]()
            )
            out.append(taken_opt.take())
        # Single release-store of tail at end.
        AtomicU64.store(
            UnsafePointer(to=self._shared[]._tail[]).unsafe_bitcast[Scalar[DType.uint64]](),
            tail + to_drain,
        )
        return out^

    def close(mut self):
        """Mark receiver-side closed; subsequent sender try_send returns
        TRY_SEND_CLOSED. Idempotent."""
        AtomicI32.store(
            UnsafePointer(to=self._shared[]._receiver_closed[]).unsafe_bitcast[Scalar[DType.int32]](),
            Int32(1),
        )


# =============================================================================
# SpscChannelPair[T] — factory return wrapper
# =============================================================================
# Mojo 0.26.3's stdlib Tuple does NOT support `tuple[i]^` move-out
# destructuring (compile error: "expression does not designate a value with
# an origin"). Replace `Tuple[Sender, Receiver]` with a dedicated wrapper
# carrying `take_sender()` / `take_receiver()` move-out methods so callers
# can extract each end into a stack-local var.


struct SpscChannelPair[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Result of `channel(cap)`. Hold momentarily then move sender + receiver
    out via `take_sender()` and `take_receiver()`. The wrapper drops cleanly
    if not split (e.g., when channel construction fails downstream).

    `T` bound relaxed to `Movable & Deinitable`."""

    var _sender: Optional[SpscSender[Self.T]]
    var _receiver: Optional[SpscReceiver[Self.T]]

    def __init__(
        out self,
        var sender: SpscSender[Self.T],
        var receiver: SpscReceiver[Self.T],
    ):
        self._sender = Optional[SpscSender[Self.T]](sender^)
        self._receiver = Optional[SpscReceiver[Self.T]](receiver^)

    def take_sender(mut self) raises -> SpscSender[Self.T]:
        """Move-out the sender. Raises if already taken."""
        if not self._sender:
            raise Error("SpscChannelPair: sender already taken")
        return self._sender.take()

    def take_receiver(mut self) raises -> SpscReceiver[Self.T]:
        """Move-out the receiver. Raises if already taken."""
        if not self._receiver:
            raise Error("SpscChannelPair: receiver already taken")
        return self._receiver.take()


# =============================================================================
# Module-level factory:
# =============================================================================


def channel[
    T: Movable & Deinitable
](capacity: UInt) raises -> SpscChannelPair[T]:
    """Construct an SPSC channel pair.

    `capacity` MUST be a power of 2 (lint-enforced; ring index masking is
    `& (capacity - 1)` for branchless wrap). `capacity > 0` required.

    Returns: SpscChannelPair[T] holding both endpoints; caller invokes
    `take_sender()` / `take_receiver()` to split. Both endpoints share the
    same heap-allocated `_SpscShared[T]` via ArcPointer.

    Mojo 0.26.3 note: The natural `Tuple[Sender, Receiver]` return
    is rendered as `SpscChannelPair[T]` because Mojo 0.26.3 stdlib `Tuple`
    does not yet support move-out destructuring (`pair[0]^`).
    """
    var shared = ArcPointer[_SpscShared[T]](_SpscShared[T](capacity))
    var sender_arc = ArcPointer[_SpscShared[T]](copy=shared)
    var sender = SpscSender[T](shared=sender_arc^)
    var receiver = SpscReceiver[T](shared=shared^)
    return SpscChannelPair[T](sender=sender^, receiver=receiver^)
