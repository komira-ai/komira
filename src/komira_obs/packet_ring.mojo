# =============================================================================
# packet_ring.mojo — SPSC ring of compact `SpanPacket`s
# =============================================================================
#
# Hot-path split. Mirrors `ring_buffer.mojo` but carries 32-byte
# `SpanPacket`s instead of 192-byte `SpanRecord`s — 6x smaller per-slot
# copy on the producer's hot path.
#
# Design parity with `SpanRingBuffer`: same SPSC invariant, same
# cacheline-padded head/tail, same backpressure semantics. The drain
# (single-thread) reads packets, joins matching OPEN+CLOSE pairs by
# span_id in a small dict, and reconstructs `SpanRecord`s for the JSONL
# exporter.
# =============================================================================

from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI64

from komira_core.collections import Slab

from komira_obs.ring_buffer import (
    CACHELINE_BYTES,
    DEFAULT_RING_CAPACITY,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
)
from komira_obs.span_packet import SpanPacket


struct SpanPacketRingBuffer(Deinitable):
    """Per-worker SPSC ring of `SpanPacket`s.

    Same shape as `SpanRingBuffer` but parameterized on the compact
    32-byte packet. See `ring_buffer.mojo` for the full SPSC invariant
    + ordering rationale; this module is a copy at the slot-type
    boundary only — adding a generic `Ring[T]` would require a wider
    Mojo trait than 0.26.3 currently exposes for non-Movable Atomic
    fields. The 80-line duplication is the cheapest path; consolidate
    when 0.27 lands generic Atomic-bearing struct fields.
    """

    var _capacity: Int
    # LAZY SLOTS. `_capacity` is the LOGICAL capacity from the
    # moment of construction — every index/mask/backpressure computation below
    # reads it and is unchanged. `_slots` is the BACKING STORE, and it is
    # allocated on the FIRST `try_push`, not at construction.
    #
    # WHY: an engine context builds one of these per worker pthread
    # unconditionally, and tracing is off unless `enable_tracer()` is called.
    # At 44 workers the eager form would `memset` 44 x 4096 x 40 B = 7.04 MiB
    # of slots that never receive a packet — milliseconds and thousands of
    # first-touch faults of pure startup cost.
    #
    # SPSC SAFETY: the producer is the only writer of the `_slots` HANDLE, and
    # it writes it exactly once, before the `_tail.fetch_add` that publishes the
    # first packet. `try_pop` touches `_slots` only when `tail > head`, which it
    # learns from a seq_cst `_tail.load()`; that load synchronizes-with the
    # producer's `fetch_add`, so the handle write is visible before any consumer
    # dereference. Subsequent pushes never touch the handle again.
    var _slots: Slab[SpanPacket]
    var _head: AtomicI64
    var _head_pad: Array[UInt8, CACHELINE_BYTES - 8]
    var _tail: AtomicI64
    var _tail_pad: Array[UInt8, CACHELINE_BYTES - 8]
    var _overflow_dropped: AtomicI64
    var _overflow_blocked: AtomicI64
    var _overflow_policy: UInt8

    def __init__(
        out self,
        capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        if capacity <= 0:
            raise Error("SpanPacketRingBuffer: capacity must be > 0")
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        self._capacity = cap
        # Deferred: allocated by `_ensure_slots` on the first `try_push`.
        self._slots = Slab[SpanPacket]()
        self._head = AtomicI64(Int64(0))
        self._head_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        self._tail = AtomicI64(Int64(0))
        self._tail_pad = Array[UInt8, CACHELINE_BYTES - 8](fill=UInt8(0))
        self._overflow_dropped = AtomicI64(Int64(0))
        self._overflow_blocked = AtomicI64(Int64(0))
        self._overflow_policy = overflow_policy

    @staticmethod
    def init_in_place[o: Origin[mut=True], //](
        ptr: UnsafePointer[SpanPacketRingBuffer, o],
        capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        """In-place init for callers holding a `Slab[SpanPacketRingBuffer]`
        slot. Parallels `SpanRingBuffer.init_in_place`.

        SAFETY (init-only): `ptr` points at
        zero-initialized bytes from `Slab.create_prefilled`; the slot
        is uninitialized BEFORE this call and initialized AFTER.

        The origin is a PARAMETER, not a wildcard: Mojo 1.0.0 does not
        coerce the concrete origin that `UnsafePointer(to=...)` yields into
        a wildcard, and the caller's Slab-slot origin is exactly what should
        be tracked here. `o` is inferred at the call site.
        """
        if capacity <= 0:
            raise Error(
                "SpanPacketRingBuffer.init_in_place: capacity must be > 0"
            )
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        ptr[]._capacity = cap
        # Deferred: allocated by `_ensure_slots` on the first `try_push`.
        ptr[]._slots = Slab[SpanPacket]()
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
    def slots_allocated(self) -> Bool:
        """True once the backing store has been materialized (first push).

        Introspection for the lazy-slots guard — a freshly constructed ring
        reports False and still reports `capacity()` as its logical capacity.
        """
        return len(self._slots) == self._capacity

    @always_inline
    def _ensure_slots(mut self) -> None:
        """Materialize the backing store. Idempotent; producer-side only.

        SAFETY (SPSC): only `try_push` calls this, and `try_push` has exactly
        one producer by the ring's contract, so the handle write races nothing.
        See the `_slots` field comment for the consumer-visibility argument.
        """
        if len(self._slots) != self._capacity:
            self._slots = Slab[SpanPacket].create_prefilled(self._capacity)

    @always_inline
    def overflow_dropped_count(self) -> Int64:
        return self._overflow_dropped.load()

    @always_inline
    def overflow_blocked_count(self) -> Int64:
        return self._overflow_blocked.load()

    def try_push(mut self, packet: SpanPacket) -> Bool:
        """Producer-side. Write `packet` into the ring.

        Returns True on success, False if the ring is full and policy
        is DROP. Under BLOCK policy the call **never** returns False —
        instead it spins on `_head` until a slot frees up.
        """
        var tail = self._tail.load()
        var head = self._head.load()
        var capacity_i64 = Int64(self._capacity)
        var occupied = tail - head

        if occupied >= capacity_i64:
            if self._overflow_policy == OVERFLOW_DROP:
                _ = self._overflow_dropped.fetch_add(Int64(1))
                return False
            _ = self._overflow_blocked.fetch_add(Int64(1))
            while True:
                head = self._head.load()
                if tail - head < capacity_i64:
                    break

        self._ensure_slots()
        var idx = Int(tail) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        slot = packet.copy()

        _ = self._tail.fetch_add(Int64(1))
        return True

    def try_pop(mut self) -> Optional[SpanPacket]:
        """Drain-side. Read the next packet. Returns None if empty."""
        var head = self._head.load()
        var tail = self._tail.load()
        if head >= tail:
            return Optional[SpanPacket]()

        var idx = Int(head) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        var packet = slot.copy()

        _ = self._head.fetch_add(Int64(1))
        return Optional[SpanPacket](packet^)

    @always_inline
    def is_empty(self) -> Bool:
        return self._head.load() >= self._tail.load()

    @always_inline
    def approximate_size(self) -> Int64:
        return self._tail.load() - self._head.load()
