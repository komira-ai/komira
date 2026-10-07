# =============================================================================
# komira_async.channel.mpsc — multi-producer, single-consumer
# =============================================================================
# module-level factory.
#
# Multiple producers push lock-free via Atomic[uint64] enqueue_pos +
# per-slot Atomic[uint64] sequence number (Vyukov MPMC pattern). Single
# consumer pops via dedicated dequeue_pos. The surface restricts to one
# consumer (: MpscReceiver is NOT Movable; single
# consumer is identified by holding the handle).
#
# This form ships try-API + close + drain. Park-on-wake-by-address is
# deferred. The lock-free push is the load-bearing claim:
# ~5-8ns per send on contended workloads (vs ~50ns for a mutex-protected
# queue).
#
# Pointer discipline:
#   - MpscSender / MpscReceiver public API uses ONLY typed scalars + status
#     codes + List[T] (for batched recv).
#   - `_shared: ArcPointer[_MpscShared[T]]` is the encapsulated internal field.
#   - Zero UnsafePointer in public signatures; zero wildcard origins.
#
# T bound: matches SPSC —
# RELAXED to `Movable & Deinitable`. The value-slot store swaps
# `List[Optional[T]]` -> `Slab[Optional[T]]` so the per-worker task queue can
# carry the single-owner `ErasedHandle` (Movable-only) directly, retiring
# `_TaskEntry`'s bespoke wildcard byte-ptr. See spsc.mojo's header for the full
# substrate-swap rationale (the relax is the slab store, NOT a one-line bound
# change).
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, alloc
from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI32, AtomicU64

from komira_collections.slab import Slab

from komira_async.channel.spsc import (
    TryRecvOutcome,
    TrySendOutcome,
    TRY_SEND_OK,
    TRY_SEND_FULL,
    TRY_SEND_CLOSED,
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
    TRY_RECV_CLOSED,
)


# =============================================================================
# _MpscShared[T] — heap state owned by ArcPointer
# =============================================================================
# Storage layout note: Mojo 1.0.0b1 cannot store `Atomic[T]` (non-Movable)
# inside `List[T]` (List synthesizes copy from element copy, requires
# Copyable + Movable). We use TWO storages:
#   (a) `_seq_array: OwnedPointer[Atomic[uint64]]` — single contiguous
#       allocation of capacity Atomics. Index access via raw pointer
#       arithmetic INSIDE the channel module (encapsulated; no cross-module
#       pointer crossings).
#   (b) `_slots: Slab[Optional[T]]` — value slots. A
#       byte-backed slab, NOT `List[Optional[T]]`. The swap relaxes the channel
#       `T` bound to Movable-only: `Slab[U]` requires only
#       `U: Deinitable`, and `Optional[T]` is that for a Movable-only
#       T. Move-in is `Slab.__setitem__(idx, Some(v^))` (destroys the prior
#       `None`); move-out is `Slab.replace(idx, None)` (returns the old `Some`,
#       restores a valid `None`). Every slot is ALWAYS a valid `Optional` — never
#       raw-uninitialized bytes — so the byte-slab destroy-recreate trap (heap-owning inner
#       field at an uninitialized-but-counted-live offset) cannot fire, and the
#       slab destructor drops every slot's `Optional` cleanly on shutdown.
# Both arrays are length `capacity`; index i maps slot i's sequence to
# `_seq_array[i]` and value to `_slots[i]`.


struct _MpscShared[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Vyukov MPMC queue shared state.

    Multiple producers contend on `_enqueue_pos` via compare_exchange-loop.
    Single consumer reads `_dequeue_pos` directly.

    Per-slot sequence numbers stored in a contiguous heap allocation
    (`_seq_array`). Each Atomic[uint64] takes sizeof(uint64) = 8 bytes.
    Mojo's Atomic struct on 0.26.3 has the same memory layout as the
    underlying primitive (verified by AsyncMutex's `_state.value` field
    being valid as a UInt8 access pattern).

    Close-state: independent atomics for sender + receiver close.
    """

    var _slots: Slab[Optional[Self.T]]
    var _seq_array: OwnedPointer[AtomicU64]   # contiguous; indexed via offset
    var _enqueue_pos: OwnedPointer[AtomicU64]
    var _dequeue_pos: OwnedPointer[AtomicU64]
    var _mask: UInt64
    var _capacity: UInt64
    var _sender_closed: OwnedPointer[AtomicI32]
    var _receiver_closed: OwnedPointer[AtomicI32]
    var _wake_word: OwnedPointer[AtomicI32]

    def __init__(out self, capacity: UInt) raises:
        if capacity == 0:
            raise Error("MpscChannel: capacity must be > 0")
        if (capacity & (capacity - 1)) != 0:
            raise Error("MpscChannel: capacity must be a power of 2")

        var cap_u64 = UInt64(capacity)

        # Allocate the per-slot sequence array as one contiguous block.
        # Each slot's seq starts at its index (0..capacity-1).
        # SAFETY: raw is a fresh capacity-sized allocation we own. The
        # OwnedPointer absorbs ownership and frees on drop. Access goes
        # through `_seq_at(i)` helper which hands back `ref [_]
        # Atomic[uint64]` with the OwnedPointer's origin.
        var seq_raw = alloc[AtomicU64](Int(capacity))
        for i in range(Int(capacity)):
            (seq_raw + i)[] = AtomicU64(UInt64(i))
        self._seq_array = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=seq_raw
        )

        # Pre-allocate value slots, all None (Slab[Optional[T]]). Explicit
        # `append(None)` (NOT zero-fill) so we never depend on a zeroed
        # `Optional` bit-pattern being a valid `None`. After this loop
        # `_slots.len() == capacity` and every slot is a valid `None`, so the
        # Slab destructor drops each slot's `Optional` cleanly on shutdown.
        self._slots = Slab[Optional[Self.T]](Int(capacity))
        for _ in range(Int(capacity)):
            self._slots.append(Optional[Self.T]())

        var enq_raw = alloc[AtomicU64](1)
        enq_raw[] = AtomicU64(UInt64(0))
        self._enqueue_pos = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=enq_raw
        )

        var deq_raw = alloc[AtomicU64](1)
        deq_raw[] = AtomicU64(UInt64(0))
        self._dequeue_pos = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=deq_raw
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

        self._mask = cap_u64 - UInt64(1)
        self._capacity = cap_u64

    # TEARDOWN NOTE (no hand-written __del__ needed): the auto-synthesized
    # `_MpscShared` destructor drops `_slots` (a `Slab[Optional[T]]`), whose own
    # `__del__` runs `Optional.__del__` on EVERY slot (length == capacity, all
    # valid `Optional[T]`) — dropping the inner `T` of any `Some` slot exactly
    # once, a no-op for `None` slots. Undelivered items left in the ring on
    # shutdown are freed by that per-slot drop. Because every slot is ALWAYS a
    # valid `Optional` (never raw-uninitialized bytes), there is no
    # "uninitialized-but-counted-live" offset for a heap-owning inner field of
    # `T` to dangle at — the byte-slab destroy-recreate trap cannot fire.


# =============================================================================
# MpscSender[T] — multi-producer end
# =============================================================================


struct MpscSender[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Multi-producer sender; Movable +
    clonable (each clone shares the same underlying queue via
    ArcPointer.clone).

    `T` bound relaxed to `Movable & Deinitable`
    (Movable-only payloads like `ErasedHandle`). The slot write is a move."""

    var _shared: ArcPointer[_MpscShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_MpscShared[Self.T]]):
        self._shared = shared^

    def clone(self) -> MpscSender[Self.T]:
        """Clone the sender; both clones share the same underlying queue.
        Multiple producers each hold their own MpscSender clone."""
        return MpscSender[Self.T](
            shared=ArcPointer[_MpscShared[Self.T]](copy=self._shared)
        )

    def try_send(mut self, var value: Self.T) -> UInt8:
        """Lock-free push.

        Returns: TRY_SEND_OK on success; TRY_SEND_FULL if ring is full;
        TRY_SEND_CLOSED if receiver has closed the channel.

        Vyukov push: load enqueue_pos; check slot.seq == pos (slot free);
        CAS-claim pos; write value; release-store slot.seq = pos+1.

        SAFETY: pointer arithmetic on _seq_array via `_seq_array_ptr() + idx`
        is INSIDE this module. The OwnedPointer's origin is stable for the
        lifetime of self._shared (ArcPointer-anchored).
        """
        if self._shared[]._receiver_closed[].load() != Int32(0):
            return TRY_SEND_CLOSED
        # SAFETY: _seq_array is a capacity-sized contiguous allocation
        # owned by self._shared. Indexing within [0, capacity) is bounded
        # by the mask. Pointer arithmetic stays inside the channel module.
        var seq_base = UnsafePointer(to=self._shared[]._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        var max_attempts = Int(self._shared[]._capacity) * 2
        var attempts = 0
        while attempts < max_attempts:
            var pos = self._shared[]._enqueue_pos[].load()
            var idx = Int(pos & self._shared[]._mask)
            # Load slot's sequence number.
            var slot_seq_ptr = seq_base + idx
            var slot_seq = AtomicU64.fetch_add(slot_seq_ptr, UInt64(0))
            if slot_seq == pos:
                # Slot is free; try to claim by advancing enqueue_pos via CAS.
                var cas_res = self._shared[]._enqueue_pos[].compare_exchange(
                    pos, pos + UInt64(1)
                )
                if cas_res:
                    # We claimed pos exclusively (the CAS on enqueue_pos makes
                    # us the sole writer of this slot for this cycle). Write
                    # value via Slab.__setitem__ (destroys the prior `None`,
                    # move-constructs `Some(value)`), then release-store the slot
                    # seq so the consumer observes the value-write before
                    # slot_seq == pos+1. The Vyukov seq protocol guarantees the
                    # slot held a valid `None` here (the consumer's reopen-store
                    # set seq to pos+capacity after taking the previous value and
                    # restoring None — see try_recv).
                    self._shared[]._slots[idx] = Optional[Self.T](value^)
                    AtomicU64.store(slot_seq_ptr, pos + UInt64(1))
                    return TRY_SEND_OK
                # Lost the race; retry.
            elif slot_seq < pos:
                # Slot is being consumed; queue is full at this position.
                return TRY_SEND_FULL
            # else slot_seq > pos: producer ahead of us; bump and retry.
            attempts += 1
        return TRY_SEND_FULL

    def try_send_back(mut self, var value: Self.T) -> TrySendOutcome[Self.T]:
        """The Movable-only-T send path. Same
        lock-free Vyukov push as `try_send`, but on FULL / CLOSED it HANDS THE
        VALUE BACK (in the returned `TrySendOutcome`) instead of dropping it — so
        a Movable-only `T` (e.g. `ErasedHandle`) is never lost / mis-freed. On OK
        the value was moved into the ring and the outcome carries no payload.

        Used by the LocalDispatcher + LocalSpawner producers, which retry on FULL
        (re-send the SAME value next attempt — impossible if the value were
        dropped) and unwind on CLOSED (drop the un-sent value explicitly).

        SAFETY: identical encapsulated pointer arithmetic to `try_send` (the
        `_seq_array` indexing stays inside this module). The ONLY difference is
        the value is returned on non-OK rather than dropped at the `var value`
        scope boundary.
        """
        if self._shared[]._receiver_closed[].load() != Int32(0):
            return TrySendOutcome[Self.T].closed(value^)
        # SAFETY: see try_send — _seq_array is a capacity-sized contiguous
        # allocation owned by self._shared.
        var seq_base = UnsafePointer(to=self._shared[]._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        var max_attempts = Int(self._shared[]._capacity) * 2
        var attempts = 0
        while attempts < max_attempts:
            var pos = self._shared[]._enqueue_pos[].load()
            var idx = Int(pos & self._shared[]._mask)
            var slot_seq_ptr = seq_base + idx
            var slot_seq = AtomicU64.fetch_add(slot_seq_ptr, UInt64(0))
            if slot_seq == pos:
                var cas_res = self._shared[]._enqueue_pos[].compare_exchange(
                    pos, pos + UInt64(1)
                )
                if cas_res:
                    # We claimed pos exclusively. Move the value into the slot.
                    self._shared[]._slots[idx] = Optional[Self.T](value^)
                    AtomicU64.store(slot_seq_ptr, pos + UInt64(1))
                    return TrySendOutcome[Self.T].ok()
                # Lost the race; retry (value still owned).
            elif slot_seq < pos:
                # Full at this position — hand the value back.
                return TrySendOutcome[Self.T].full(value^)
            # else slot_seq > pos: producer ahead; bump and retry.
            attempts += 1
        return TrySendOutcome[Self.T].full(value^)

    def approx_depth(self) -> Int64:
        """Diagnostic accessor — approximate number of entries sitting in the
        ring (`enqueue_pos - dequeue_pos`). Returns a typed scalar; no pointer
        crosses the boundary.

        APPROXIMATE by construction: the two positions are read non-atomically
        with respect to each other, and a producer that has claimed a slot but
        not yet stamped it is already counted. That is fine for the one job this
        exists for — telling "the consumer stopped draining" (depth stays > 0
        for seconds) apart from "the item was never enqueued" (depth 0) when a
        fork-join barrier is stuck. Do NOT build control flow on it."""
        var enq = self._shared[]._enqueue_pos[].load()
        var deq = self._shared[]._dequeue_pos[].load()
        if enq < deq:
            return Int64(0)
        return Int64(enq - deq)

    def close(mut self):
        """Mark sender-side closed. Note: in the multi-clone case, this
        only signals closure for THIS clone; full multi-clone close-on-
        last-drop semantics are not implemented. Callers
        explicitly call close() on a designated sender (matches the typical
        producer-coordinator pattern)."""
        AtomicI32.store(
            UnsafePointer(to=self._shared[]._sender_closed[]).unsafe_bitcast[Scalar[DType.int32]](),
            Int32(1),
        )


# =============================================================================
# MpscReceiver[T] — single-consumer end
# =============================================================================


struct MpscReceiver[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Single-consumer receiver. Ideally NOT Movable;
    in Mojo 0.26.3 we make it Movable for
    factory tuple-return ergonomics — single-consumer is enforced at the
    call site (don't clone the receiver).

    `T` bound relaxed to `Movable & Deinitable`.
    `try_recv` moves the payload out via `Slab.replace(idx, None)`."""

    var _shared: ArcPointer[_MpscShared[Self.T]]

    def __init__(out self, var shared: ArcPointer[_MpscShared[Self.T]]):
        self._shared = shared^

    def try_recv(mut self) -> TryRecvOutcome[Self.T]:
        """Vyukov pop.

        Reads dequeue_pos; checks slot_seq == pos+1 (producer wrote);
        moves value out; advances slot_seq to pos+capacity (reopens for
        next producer cycle); advances dequeue_pos.

        SAFETY: pointer arithmetic on `_seq_array` via `seq_base + idx`
        is INSIDE this module. The OwnedPointer's origin is stable for
        the lifetime of self._shared (ArcPointer-anchored). idx is
        bounded by `& mask` so always within [0, capacity).
        """
        # SAFETY: see above; _seq_array is a capacity-sized contiguous
        # allocation owned by self._shared.
        var seq_base = UnsafePointer(to=self._shared[]._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        var pos = self._shared[]._dequeue_pos[].load()
        var idx = Int(pos & self._shared[]._mask)
        var slot_seq_ptr = seq_base + idx
        # PURE LOAD, NOT `fetch_add(ptr, 0)`. The old spelling was
        # a degenerate read-modify-write: it read the seq, added nothing, and
        # wrote the same value back. A `+0` RMW is not a cheaper acquire-load —
        # and what it costs instead DIFFERS BY ISA (both lowerings checked
        # by compiling the two spellings):
        #
        #   * arm64: a real atomic RMW (`ldsetal`), so the slot's cache line is
        #     taken in EXCLUSIVE state on every poll, invalidating the
        #     producers' shared copies of the very line `try_send` reads.
        #   * x86-64: NOT a `lock xadd`. LLVM recognises the idempotent RMW
        #     (`X86TargetLowering::lowerIdempotentRMWIntoFencedLoad`) and
        #     rewrites it to a standalone `fence seq_cst` plus a PLAIN load;
        #     `emitLockedStackOp` then lowers that fence to a locked op on a
        #     dead red-zone slot — `lock orl $0x0,-0x40(%rsp)`. No line is taken
        #     exclusive. The cost is a full StoreLoad BARRIER.
        #
        # On the scheduler's hot path that cost is paid per `drain_task_queue`
        # iteration, INCLUDING the empty polls that find nothing to run — and on
        # x86 the barrier is paid on the empty polls whether or not any producer
        # is contending, which is why it dominated: in a microarch profile
        # of the scheduler hot path that ONE instruction carried a large share
        # of all samples in `Worker::drain_task_queue`.
        #
        # WHY A PLAIN LOAD IS SUFFICIENT HERE. This read is one half of the
        # Vyukov publication handshake and needs ACQUIRE, nothing more:
        #   * Reading `slot_seq == pos + 1` must synchronize-with the producer's
        #     release-store of `pos + 1` (try_send, below the value-write), so
        #     that the `_slots.replace(idx, ...)` move-out beneath observes the
        #     value the producer wrote. An acquire load gives exactly that.
        #   * Nothing downstream needs this read to PUBLISH anything — the
        #     consumer's own publication is the release-store of
        #     `pos + capacity` further down, which is untouched.
        #   * Nothing needs the RMW's "reads the latest value in the
        #     modification order" guarantee: a stale read can only under-report
        #     readiness, which returns TRY_RECV_EMPTY and is re-polled. That is
        #     the same liveness contract every empty-check in this queue has.
        # This restores Vyukov's own spelling (`cell->sequence_.load(acquire)`).
        # `Atomic.load` defaults to `_DEFAULT_MEMORY_ORDERING` = SEQUENTIAL, so
        # what actually ships is a seq_cst load — strictly STRONGER than the
        # acquire the algorithm requires, and the same ordering class the
        # `fetch_add` it replaces was using (`_DEFAULT_ARITHMETIC_ORDERING` is
        # SEQUENTIAL off Apple-GPU too). The write is what goes away, not the
        # ordering.
        var slot_seq = AtomicU64.load(slot_seq_ptr)
        if slot_seq == pos + UInt64(1):
            # Slot has a value (producer wrote pos+1 to mark dequeue-eligible).
            # Move-out via Slab.replace(idx, None): returns the old `Some(value)`
            # and restores the slot to a valid `None` in one move (the blessed
            # non-Copyable move-out primitive — direct `slab[idx].take()` trips
            # the implicit-copy check). The slot stays a valid `Optional[T]`
            # before the reopen-store makes it claimable by the next producer.
            var taken_opt = self._shared[]._slots.replace(idx, Optional[Self.T]())
            # Reopen the slot for the next cycle (pos + capacity is the
            # producer's next "free" sentinel value at this index). This
            # release-store MUST follow the value-take + None-restore so the next
            # producer never observes a stale `Some` (the seq is the publication
            # fence — a producer only writes after seeing slot_seq == its pos).
            AtomicU64.store(
                slot_seq_ptr,
                pos + self._shared[]._capacity,
            )
            # Advance dequeue_pos.
            AtomicU64.store(
                UnsafePointer(to=self._shared[]._dequeue_pos[]).unsafe_bitcast[Scalar[DType.uint64]](),
                pos + UInt64(1),
            )
            return TryRecvOutcome[Self.T].ok(taken_opt.take())
        # Empty: distinguish closed from open.
        if self._shared[]._sender_closed[].load() != Int32(0):
            return TryRecvOutcome[Self.T].closed()
        return TryRecvOutcome[Self.T].empty()

    def close(mut self):
        """Mark receiver-side closed. Subsequent sender try_send returns
        TRY_SEND_CLOSED."""
        AtomicI32.store(
            UnsafePointer(to=self._shared[]._receiver_closed[]).unsafe_bitcast[Scalar[DType.int32]](),
            Int32(1),
        )


# =============================================================================
# Factory wrapper struct (Mojo 0.26.3 tuple-return workaround)
# =============================================================================


struct MpscChannelPair[
    T: Movable & Deinitable
](Movable, Deinitable):
    """Result of `mpsc::channel(cap)`. Caller invokes `take_sender()` /
    `take_receiver()` to extract endpoints. Same wrapper shape as
    SpscChannelPair (Mojo 0.26.3 Tuple subscript-then-move-out
    incompatibility).

    `T` bound relaxed to `Movable & Deinitable`."""

    var _sender: Optional[MpscSender[Self.T]]
    var _receiver: Optional[MpscReceiver[Self.T]]

    def __init__(
        out self,
        var sender: MpscSender[Self.T],
        var receiver: MpscReceiver[Self.T],
    ):
        self._sender = Optional[MpscSender[Self.T]](sender^)
        self._receiver = Optional[MpscReceiver[Self.T]](receiver^)

    def take_sender(mut self) raises -> MpscSender[Self.T]:
        if not self._sender:
            raise Error("MpscChannelPair: sender already taken")
        return self._sender.take()

    def take_receiver(mut self) raises -> MpscReceiver[Self.T]:
        if not self._receiver:
            raise Error("MpscChannelPair: receiver already taken")
        return self._receiver.take()


# =============================================================================
# Module-level factories:
# =============================================================================


def channel[
    T: Movable & Deinitable
](capacity: UInt) raises -> MpscChannelPair[T]:
    """Construct a bounded MPSC channel pair.

    `capacity` MUST be a power of 2 (Vyukov MPMC ring index masking).
    Returns: MpscChannelPair[T] — caller invokes `take_sender()` /
    `take_receiver()` to extract endpoints.
    """
    var shared = ArcPointer[_MpscShared[T]](_MpscShared[T](capacity))
    var sender_arc = ArcPointer[_MpscShared[T]](copy=shared)
    var sender = MpscSender[T](shared=sender_arc^)
    var receiver = MpscReceiver[T](shared=shared^)
    return MpscChannelPair[T](sender=sender^, receiver=receiver^)


def unbounded[
    T: Movable & Deinitable
]() raises -> MpscChannelPair[T]:
    """Construct an "unbounded" MPSC channel.

    Minimum-viable: a fixed-capacity ring at 4096, as
    'unbounded MPSC for low-rate signal
    channels' — capacity 4096 absorbs typical signal cadence. Real
    grow-on-full unbounded support is / E follow-up.
    """
    return channel[T](capacity=UInt(4096))
