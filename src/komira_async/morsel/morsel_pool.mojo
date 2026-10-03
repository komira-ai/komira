# =============================================================================
# komira_async.morsel.morsel_pool — single-owner Vyukov MPMC
# =============================================================================
# A single-owner OwnedPointer queue with a scope-origin borrow; batched
# draining measured a large wall reduction at batch=16 vs a
# static partition on 10:1 skewed workloads.
#
# MorselPool[T] is a NOT-Movable, single-owner queue. Workers borrow via
# `ref [pool_origin] MorselPool[T]` per-spawn parameter — Mojo's lifetime
# tracker enforces "pool outlives all spawned tasks" statically. NO
# ArcPointer in any field. NO refcount traffic.
#
# KEY DISTINCTION from work-stealing tasks: MorselPool steals data chunks
# (T = morsel descriptor — file URL + byte range, hash partition id,
# etc.), NOT parked tasks with working sets. The compute kernel
# processing morsels is already on the stealing worker; only morsel data
# is loaded fresh. No cross-worker task wakes; no cache-line ping-pong.
#
# Internal queue: Vyukov MPMC (same pattern as channel/mpsc.mojo). Two
# storage arrays:
#   (a) `_slots: List[Optional[T]]` — value slots; Optional.take() for
#       move-out (no partial move through a pointer).
#   (b) `_seq_array: OwnedPointer[Atomic[uint64]]` — single contiguous
#       allocation of capacity * sizeof(Atomic[uint64]) bytes. Indexed
#       via `seq_base + idx` pointer arithmetic INSIDE this module per
#       encapsulation rule (UnsafePointer never crosses module
#       boundary).
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO ArcPointer in any field — single-owner.
#   - ZERO wildcard origins on public surface.
#   - UnsafePointer ONLY for in-module Atomic-storage pointer arithmetic
#     and `Atomic[D].store(unsafe_ptr, value)` static-method form (Mojo
#     0.26.3 instance-store does not exist). Each site has SAFETY block.
#
# Self.T qualification mandatory in field decls + method bodies.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32, AtomicI64, AtomicU64


# =============================================================================
# State sentinels
# =============================================================================
comptime _CLOSED_OPEN: Int32 = 0
comptime _CLOSED_CLOSED: Int32 = 1


# =============================================================================
# _VyukovMpmcQueue[T] — internal Vyukov MPMC ring buffer
# =============================================================================
# Same shape as _MpscShared in channel/mpsc.mojo. Multiple producers (and
# multiple consumers, in MorselPool's MPMC use case) contend on
# _enqueue_pos / _dequeue_pos via compare_exchange-loops. Per-slot
# sequence numbers stored in a contiguous heap allocation accessed via
# `seq_base + idx` pointer arithmetic (encapsulated; no cross-module
# pointer crossings).
#
# Movable + Deinitable (so OwnedPointer[_VyukovMpmcQueue[T]]
# works inside MorselPool).


struct _VyukovMpmcQueue[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Movable, Deinitable):
    """Vyukov MPMC ring. Layout matches channel/mpsc.mojo's _MpscShared.

    Per-slot sequence numbers stored in a contiguous heap allocation
    (`_seq_array`). Each Atomic[uint64] takes sizeof(uint64) = 8 bytes.

    Slots: List[Optional[T]] — Optional wraps T so move-in/move-out works
    via Optional.take() (no partial move through a pointer).
    """

    var _slots: List[Optional[Self.T]]
    var _seq_array: OwnedPointer[AtomicU64]   # contiguous; indexed via offset
    var _enqueue_pos: OwnedPointer[AtomicU64]
    var _dequeue_pos: OwnedPointer[AtomicU64]
    var _mask: UInt64
    var _capacity: UInt64

    def __init__(out self, capacity: UInt) raises:
        if capacity < UInt(2):
            raise Error("MorselPool: capacity must be >= 2")
        if (capacity & (capacity - UInt(1))) != UInt(0):
            raise Error("MorselPool: capacity must be a power of 2")

        var cap_u64 = UInt64(capacity)

        # SAFETY: seq_raw is a fresh capacity-sized allocation we own.
        # OwnedPointer absorbs ownership and frees on drop. Indexed
        # access via `seq_base + idx` is bounded by `& _mask`.
        var seq_raw = alloc[AtomicU64](Int(capacity))
        for i in range(Int(capacity)):
            (seq_raw + i)[] = AtomicU64(UInt64(i))
        self._seq_array = OwnedPointer[AtomicU64](
            unsafe_from_raw_pointer=seq_raw
        )

        # Pre-allocate value slots, all None.
        self._slots = List[Optional[Self.T]]()
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

        self._mask = cap_u64 - UInt64(1)
        self._capacity = cap_u64

    def try_enqueue(mut self, var value: Self.T) -> Bool:
        """Vyukov MPMC enqueue. Returns False if the queue is full at
        the current position (caller may retry; for MorselPool the
        ring is sized to absorb the full morsel-set so this should
        rarely return False in practice).

        SAFETY: pointer arithmetic on `_seq_array` via `seq_base + idx`
        is INSIDE this module. The OwnedPointer's origin is stable for
        the lifetime of self._seq_array. idx is bounded by `& _mask`
        so always within [0, capacity).
        """
        var seq_base = UnsafePointer(to=self._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        var max_attempts = Int(self._capacity) * 2
        var attempts = 0
        while attempts < max_attempts:
            var pos = self._enqueue_pos[].load()
            var idx = Int(pos & self._mask)
            var slot_seq_ptr = seq_base + idx
            var slot_seq = AtomicU64.fetch_add(slot_seq_ptr, UInt64(0))
            if slot_seq == pos:
                # Slot is free; CAS-claim pos.
                if self._enqueue_pos[].compare_exchange(pos, pos + UInt64(1)):
                    # We claimed pos. Write value + bump slot seq.
                    self._slots[idx] = Optional[Self.T](value^)
                    AtomicU64.store(slot_seq_ptr, pos + UInt64(1))
                    return True
                # Lost the race; retry.
            elif slot_seq < pos:
                # Slot is being consumed; queue is full at this position.
                return False
            attempts += 1
        return False

    def try_dequeue(mut self) -> Optional[Self.T]:
        """Vyukov MPMC dequeue.

        SAFETY: pointer arithmetic on `_seq_array` via `seq_base + idx`
        is INSIDE this module. idx is bounded by `& _mask`.
        """
        var seq_base = UnsafePointer(to=self._seq_array[]).unsafe_bitcast[Scalar[DType.uint64]]()
        var max_attempts = Int(self._capacity) * 2
        var attempts = 0
        while attempts < max_attempts:
            var pos = self._dequeue_pos[].load()
            var idx = Int(pos & self._mask)
            var slot_seq_ptr = seq_base + idx
            var slot_seq = AtomicU64.fetch_add(slot_seq_ptr, UInt64(0))
            if slot_seq == pos + UInt64(1):
                # Slot has a value; CAS-claim dequeue_pos.
                if self._dequeue_pos[].compare_exchange(pos, pos + UInt64(1)):
                    # We claimed pos. Take value out + reopen the slot.
                    var taken_value = self._slots[idx].take()
                    AtomicU64.store(
                        slot_seq_ptr, pos + self._capacity
                    )
                    return Optional[Self.T](taken_value^)
                # Lost the race; retry.
            elif slot_seq < pos + UInt64(1):
                # Producer hasn't written yet; queue is empty at this position.
                return Optional[Self.T]()
            attempts += 1
        return Optional[Self.T]()

    def approx_len(self) -> UInt64:
        """Approximate length: enqueue_pos - dequeue_pos. Snapshot
        only — concurrent producers/consumers may race; the value is
        correct at point-of-observation but may be stale by the next
        instruction. Used for is_drained() heuristic."""
        var enq = self._enqueue_pos[].load()
        var deq = self._dequeue_pos[].load()
        if enq >= deq:
            return enq - deq
        return UInt64(0)


# =============================================================================
# MorselPool[T] — public single-owner shape
# =============================================================================


struct MorselPool[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Deinitable):
    """Owned, scoped morsel pool. NOT
    Movable (fixed heap location).

    Single-owner pattern. Workers borrow the pool via
    `ref [pool_origin] MorselPool[T]` parameters threaded through
    TaskScope.spawn — Mojo's borrow checker enforces "pool outlives all
    spawned tasks" statically. NO ArcPointer in any field; NO runtime
    refcount.

    KEY DISTINCTION from work-stealing: MorselPool steals data chunks
    (T is a morsel descriptor), NOT parked tasks with working sets. The
    compute kernel processing morsels is already on the stealing worker;
    only morsel data is loaded fresh. No cross-worker task wakes, no
    cache-line ping-pong on parked-task state.
    """

    var _queue: OwnedPointer[_VyukovMpmcQueue[Self.T]]
    var _closed: OwnedPointer[AtomicI32]      # 0 = open, 1 = closed
    var _claimed_count: OwnedPointer[AtomicI64]
    var _capacity: UInt64

    @staticmethod
    def new() raises -> MorselPool[Self.T]:
        """Construct an unbounded
        morsel pool. v0.1 ships fixed-capacity 1024 (power of 2);
        future bounded variant deferred to v0.2."""
        return MorselPool[Self.T].with_capacity(UInt(1024))

    @staticmethod
    def with_capacity(initial: UInt) raises -> MorselPool[Self.T]:
        """Construct a pool with the
        given initial capacity. Capacity MUST be a power of 2 (Vyukov
        ring index masking)."""
        var queue = _VyukovMpmcQueue[Self.T](initial)

        var c_raw = alloc[AtomicI32](1)
        c_raw[] = AtomicI32(_CLOSED_OPEN)
        var closed_op = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=c_raw
        )

        var cnt_raw = alloc[AtomicI64](1)
        cnt_raw[] = AtomicI64(Int64(0))
        var claimed_op = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=cnt_raw
        )

        return MorselPool[Self.T](
            _queue=OwnedPointer[_VyukovMpmcQueue[Self.T]](value=queue^),
            _closed=closed_op^,
            _claimed_count=claimed_op^,
            _capacity=UInt64(initial),
        )

    def __init__(
        out self,
        var _queue: OwnedPointer[_VyukovMpmcQueue[Self.T]],
        var _closed: OwnedPointer[AtomicI32],
        var _claimed_count: OwnedPointer[AtomicI64],
        _capacity: UInt64,
    ):
        self._queue = _queue^
        self._closed = _closed^
        self._claimed_count = _claimed_count^
        self._capacity = _capacity

    def submit(mut self, var morsel: Self.T) raises:
        """Submit one morsel for
        consumption. Lock-free MPMC enqueue. Raises if called after
        close()."""
        if self._closed[].load() != _CLOSED_OPEN:
            raise Error("MorselPool.submit: pool is closed")
        if not self._queue[].try_enqueue(morsel^):
            raise Error("MorselPool.submit: queue full (increase capacity)")

    def try_claim(mut self) -> Optional[Self.T]:
        """Lock-free MPMC dequeue.
        Returns Optional[T]; None when the queue is empty at point-of-
        observation (caller may retry or check is_drained())."""
        var item = self._queue[].try_dequeue()
        if item.__bool__():
            # SAFETY: claim counter Atomic-incremented via static fetch_add
            # method on the address of `_claimed_count[].value`. The
            # OwnedPointer's origin is stable for the lifetime of self.
            _ = AtomicI64.fetch_add(
                UnsafePointer(to=self._claimed_count[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(1)
            )
        return item^

    def try_claim_batch(mut self, max_n: UInt) -> List[Self.T]:
        """Canonical hot-path for OLAP
        workloads — amortizes the cross-worker MPMC cache-line round-
        trip across the batch.

        Batched draining measured a large wall reduction at batch=16 vs static partition
        on 10:1 skew. Canonical batch size is 16. List length is
        in [0, max_n]. Empty result + pool closed + queue drained ⇒
        no more work.

        Note: `batch ≤ heavy_count / N_workers` rule
        — if a single worker claims more than `(total_heavy_morsels /
        N_workers)` morsels in one batch, load-balance breaks. Document;
        callers tune.
        """
        var result = List[Self.T]()
        for _ in range(Int(max_n)):
            var item = self._queue[].try_dequeue()
            if not item.__bool__():
                break
            result.append(item.value())
        if len(result) > 0:
            # SAFETY: see try_claim().
            _ = AtomicI64.fetch_add(
                UnsafePointer(to=self._claimed_count[]).unsafe_bitcast[Scalar[DType.int64]](),
                Int64(len(result)),
            )
        return result^

    def close(mut self):
        """Mark the pool closed.
        Subsequent submit() raises. Already-submitted morsels remain
        claimable until drained. Idempotent via CAS on _closed."""
        # SAFETY: Atomic.store on _closed[].value via static-method
        # form (Mojo 0.26.3 instance-store does not exist).
        AtomicI32.store(
            UnsafePointer(to=self._closed[]).unsafe_bitcast[Scalar[DType.int32]](),
            _CLOSED_CLOSED,
        )

    def is_closed(self) -> Bool:
        """Snapshot read: is the pool closed?"""
        return self._closed[].load() != _CLOSED_OPEN

    def is_drained(self) -> Bool:
        """Returns True iff the pool
        is closed AND no morsels remain. Used by worker drain loops to
        exit cleanly.

        Note: approx_len() is a snapshot; under contended drain it may
        race with a producer that is mid-enqueue. The pool's contract
        is that callers only call is_drained() AFTER having called
        close() AND observed empty try_claim() results — at that point
        no producer can be mid-enqueue."""
        if self._closed[].load() == _CLOSED_OPEN:
            return False
        return self._queue[].approx_len() == UInt64(0)

    def claimed_count(self) -> Int64:
        """Diagnostics: total morsels claimed across all workers
        (cumulative). Useful for assertions in tests + for telemetry."""
        return self._claimed_count[].load()

    def capacity(self) -> UInt64:
        """The pool's ring capacity. Power of 2."""
        return self._capacity
