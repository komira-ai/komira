# =============================================================================
# ring_buffer.mojo — internal SPSC ring buffer for span records
# =============================================================================
#
# One ring per worker (indexed by `tid` from `@parameter parallelize`).
# Producer = the worker that owns the ring; consumer = the single drain
# thread (one dedicated worker_id slot in the existing pool).
#
# Encapsulation rule: all `UnsafePointer` arithmetic is
# CONFINED to this file. Public API takes/returns POD `SpanRecord`
# values only. Underlying storage is `Slab[SpanRecord]` so the byte
# arithmetic is the Slab's, not ours — we just index it.
#
# Cacheline alignment: the head/tail counters live
# in 128-byte-padded fields to defeat false sharing between producer
# (cache line A: tail) and consumer (cache line B: head).
# =============================================================================

from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI64

from komira_core.collections import Slab

from komira_obs.span_record import SpanRecord


# Cacheline pad: most x86_64 / aarch64 servers use 64- or 128-byte
# cachelines. We pad to 128B which covers both "L1 line" and Apple
# silicon's "pair" prefetch pattern.
comptime CACHELINE_BYTES: Int = 128


# Ring capacity is a comptime constant so the modulo can JIT to a mask.
# 4096 is plenty — at 100ns/span and 10us drain interval, the
# producer can sustain ~10K spans/burst before pressure.
comptime DEFAULT_RING_CAPACITY: Int = 4096


# Backpressure policy when the ring is full.
comptime OVERFLOW_BLOCK: UInt8 = UInt8(0)  # default — correctness > throughput
comptime OVERFLOW_DROP: UInt8 = UInt8(1)  # opt-in via the `overflow_policy` argument


struct SpanRingBuffer(Deinitable):
    """Per-worker SPSC ring of `SpanRecord`s.

    Layout:
      * `_slots: Slab[SpanRecord]` — capacity-fixed slab; index is
        `pos % capacity`.
      * `_head: Atomic[Int64]` — drain-side cursor (next slot to read).
        Padded to a full cacheline.
      * `_tail: Atomic[Int64]` — producer-side cursor (next slot to
        write). Padded to a full cacheline.
      * `_capacity` — comptime constant, copied for runtime modulo.
      * `_overflow_dropped` — counter, incremented by producer when a
        record is dropped under OVERFLOW_DROP policy.

    SPSC invariant: ONE worker writes `_tail`, ONE drain thread reads
    `_head`. Both atomics use `Relaxed` ordering on the cursor; the
    payload write is safe because the producer publishes `_tail`
    AFTER the slot write (release semantics of the implicit
    `compare_exchange` we use as a fence).

    Encapsulation: this struct exposes `try_push(record)` / `try_pop()`
    only. No raw pointer access in the public API.
    """

    var _capacity: Int
    var _slots: Slab[SpanRecord]
    # Padded head — drain-side cursor. Producer never writes this.
    var _head: AtomicI64
    var _head_pad: Array[UInt8, CACHELINE_BYTES - 8]
    # Padded tail — producer-side cursor. Drain never writes this.
    var _tail: AtomicI64
    var _tail_pad: Array[UInt8, CACHELINE_BYTES - 8]
    # Counters (off the hot path).
    var _overflow_dropped: AtomicI64
    var _overflow_blocked: AtomicI64
    # Backpressure policy snapshot — set at construction.
    var _overflow_policy: UInt8

    def __init__(out self, capacity: Int = DEFAULT_RING_CAPACITY,
                overflow_policy: UInt8 = OVERFLOW_BLOCK) raises:
        if capacity <= 0:
            raise Error("SpanRingBuffer: capacity must be > 0")
        # Round up to the next power of two to keep modulo cheap.
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        self._capacity = cap
        self._slots = Slab[SpanRecord].create_prefilled(cap)
        self._head = AtomicI64(Int64(0))
        self._head_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        self._tail = AtomicI64(Int64(0))
        self._tail_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        self._overflow_dropped = AtomicI64(Int64(0))
        self._overflow_blocked = AtomicI64(Int64(0))
        self._overflow_policy = overflow_policy

    @staticmethod
    def init_in_place[o: Origin[mut=True], //](
        ptr: UnsafePointer[SpanRingBuffer, o],
        capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        """In-place init for callers holding a `Slab[SpanRingBuffer]`
        slot. Mirrors `MpmcQueue.init_in_place` — required because the
        ring's Atomic fields make the struct non-Movable.

        SAFETY (init-only): `ptr` points at
        zero-initialized bytes from `Slab.create_prefilled`; the slot
        is uninitialized BEFORE this call and initialized AFTER.

        The origin is a PARAMETER, not a wildcard: Mojo 1.0.0 does not
        coerce the concrete origin that `UnsafePointer(to=...)` yields into
        a wildcard, and the caller's Slab-slot origin is exactly what should
        be tracked here. `o` is inferred at the call site.
        """
        if capacity <= 0:
            raise Error("SpanRingBuffer.init_in_place: capacity must be > 0")
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        ptr[]._capacity = cap
        ptr[]._slots = Slab[SpanRecord].create_prefilled(cap)
        ptr[]._head = AtomicI64(Int64(0))
        ptr[]._head_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        ptr[]._tail = AtomicI64(Int64(0))
        ptr[]._tail_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        ptr[]._overflow_dropped = AtomicI64(Int64(0))
        ptr[]._overflow_blocked = AtomicI64(Int64(0))
        ptr[]._overflow_policy = overflow_policy

    @always_inline
    def capacity(self) -> Int:
        return self._capacity

    @always_inline
    def overflow_dropped_count(self) -> Int64:
        return self._overflow_dropped.load()

    @always_inline
    def overflow_blocked_count(self) -> Int64:
        return self._overflow_blocked.load()

    def try_push(mut self, record: SpanRecord) -> Bool:
        """Producer-side. Write `record` into the ring.

        Returns True on success, False if the ring is full and policy
        is DROP. Under BLOCK policy the call **never** returns False —
        instead it spins on `_head` until a slot frees up. The block
        spin-loop is the cheaper path when drain throughput dominates
        burst latency; a caller that prefers dropping passes
        `overflow_policy=OVERFLOW_DROP` at construction.
        """
        var tail = self._tail.load()
        var head = self._head.load()
        var capacity_i64 = Int64(self._capacity)
        var occupied = tail - head

        if occupied >= capacity_i64:
            # Full.
            if self._overflow_policy == OVERFLOW_DROP:
                _ = self._overflow_dropped.fetch_add(Int64(1))
                return False
            # BLOCK — count the event, then spin until drain advances.
            _ = self._overflow_blocked.fetch_add(Int64(1))
            while True:
                head = self._head.load()
                if tail - head < capacity_i64:
                    break
                # Tight spin; the drain thread will advance _head soon.
                # In production the spin is bounded by the drain latency
                # target (200µs p99).

        # Write the slot. SAFETY (Slab.get_mut_interior): we hold
        # disjoint-from-drain access because (a) drain only reads the
        # slot when head moves past it and (b) we have NOT advanced
        # tail yet, so drain treats this slot as "not yet published."
        var idx = Int(tail) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        slot = record.copy()

        # Publish the write — release semantics. Atomic store is
        # release-on-store on AArch64 / x86 default ordering.
        _ = self._tail.fetch_add(Int64(1))
        return True

    def try_pop(mut self) -> Optional[SpanRecord]:
        """Drain-side. Read the next record. Returns None if empty."""
        var head = self._head.load()
        var tail = self._tail.load()
        if head >= tail:
            return Optional[SpanRecord]()

        var idx = Int(head) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        var record = slot.copy()

        # Advance head to release the slot for reuse. Acquire on the
        # tail load above pairs with the producer's release-on-store.
        _ = self._head.fetch_add(Int64(1))
        return Optional[SpanRecord](record^)

    @always_inline
    def is_empty(self) -> Bool:
        return self._head.load() >= self._tail.load()

    @always_inline
    def approximate_size(self) -> Int64:
        return self._tail.load() - self._head.load()
