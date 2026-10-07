# =============================================================================
# spsc_ring.mojo -- SpscRing[T]: a bounded single-producer / single-consumer ring
# =============================================================================
#
# One thread pushes, one thread pops. The producer publishes a slot by
# advancing `tail` AFTER writing it; the consumer retires one by advancing
# `head` AFTER reading it. Capacity is rounded up to a power of two and the slot
# index is `position & (capacity - 1)`.
#
# Overflow policy (chosen at construction):
#   * OVERFLOW_BLOCK (default) -- a push onto a full ring spins until the
#     consumer frees a slot, so `try_push` never returns False. Correctness over
#     throughput.
#   * OVERFLOW_DROP -- a push onto a full ring counts the drop and returns False
#     without touching a slot.
# Both are accounted: `overflow_dropped_count()` and `overflow_blocked_count()`.
#
# Lazy slots. The constructor records the logical capacity but allocates no
# slot storage; the first `try_push` materializes it. A ring that is never
# pushed to (an idle worker's ring) costs no slot memory, and `try_pop` on it is
# a clean empty. Only the producer materializes the store, strictly before its
# first `tail` advance, and the consumer touches slots only after observing
# `tail` advance, so the store is visible to the consumer by the time it needs
# it.
#
# Element contract, enforced at compile time: `T` must be trivially
# destructible. Slots come zero-filled and a push assigns over one
# (`slot = record.copy()`), which runs `T`'s destructor on the old slot value.
# For a type that owns heap memory that would free zeroed garbage, so such a
# type fails to instantiate rather than corrupt the heap.
#
# Layout. The ring is `Movable`: its four counters (head, tail, dropped,
# blocked) are atomics, which cannot be moved, so they live in one boxed block
# (`_Cursors`) owned through an `OwnedPointer`. Head and tail sit on separate
# `SPSC_PAD_BYTES` strides inside that block, so the producer's tail writes do
# not invalidate the cache line the consumer polls for head. All counter
# operations use the default (sequentially consistent) ordering. A ring is moved
# only before first use -- constructed and placed on one thread before any
# worker starts -- so the slot store (still empty then) moves with it.
# =============================================================================

from std.memory import OwnedPointer, alloc

from komira_atomic_alias import AtomicI64

from komira_collections.slab import Slab


# Stride between independently-written counters. 128 bytes covers the
# adjacent-line prefetch pair on x86_64 and the 128-byte lines on Apple
# silicon; it is deliberately not the 64-byte Arrow buffer alignment.
comptime SPSC_PAD_BYTES: Int = 128

comptime DEFAULT_RING_CAPACITY: Int = 4096

comptime OVERFLOW_BLOCK: UInt8 = UInt8(0)  # default: correctness > throughput
comptime OVERFLOW_DROP: UInt8 = UInt8(1)  # opt-in via `overflow_policy`


struct _Cursors(Deinitable):
    """The ring's four atomic counters, each on its own `SPSC_PAD_BYTES` stride.

    Not Movable (it holds atomics); it only ever lives behind the
    `OwnedPointer` that `SpscRing` allocates for it.
    """

    var _lead_pad: Array[UInt8, SPSC_PAD_BYTES]
    var head: AtomicI64
    var _head_pad: Array[UInt8, SPSC_PAD_BYTES - 8]
    var tail: AtomicI64
    var _tail_pad: Array[UInt8, SPSC_PAD_BYTES - 8]
    var dropped: AtomicI64
    var _dropped_pad: Array[UInt8, SPSC_PAD_BYTES - 8]
    var blocked: AtomicI64
    var _trail_pad: Array[UInt8, SPSC_PAD_BYTES - 8]


def _new_cursors() -> OwnedPointer[_Cursors]:
    """Allocate a zeroed `_Cursors` and hand it straight to an `OwnedPointer`.

    `OwnedPointer(value^)` needs a Movable value and the atomics are not, so
    the block is allocated and its fields assigned in place.

    SAFETY: `raw` is one fresh `_Cursors`-sized allocation, written field by
    field before it is wrapped; it is never stored or returned raw, and after
    the wrap the `OwnedPointer` is its only owner (it frees the block).
    """
    var raw = alloc[_Cursors](1)
    raw[]._lead_pad = Array[UInt8, SPSC_PAD_BYTES](fill=UInt8(0))
    raw[].head = AtomicI64(Int64(0))
    raw[]._head_pad = Array[UInt8, SPSC_PAD_BYTES - 8](fill=UInt8(0))
    raw[].tail = AtomicI64(Int64(0))
    raw[]._tail_pad = Array[UInt8, SPSC_PAD_BYTES - 8](fill=UInt8(0))
    raw[].dropped = AtomicI64(Int64(0))
    raw[]._dropped_pad = Array[UInt8, SPSC_PAD_BYTES - 8](fill=UInt8(0))
    raw[].blocked = AtomicI64(Int64(0))
    raw[]._trail_pad = Array[UInt8, SPSC_PAD_BYTES - 8](fill=UInt8(0))
    return OwnedPointer[_Cursors](unsafe_from_raw_pointer=raw)


struct SpscRing[T: Copyable & Movable & Deinitable](Movable, Deinitable):
    """A bounded SPSC ring of trivially-destructible `T`.

    Exactly one thread may call `try_push` and exactly one may call `try_pop`
    (they may be the same thread). `capacity()`, the counters and the
    introspection methods may be read from either side.
    """

    var _capacity: Int
    var _slots: Slab[Self.T]
    var _cursors: OwnedPointer[_Cursors]
    var _overflow_policy: UInt8

    def __init__(
        out self,
        capacity: Int = DEFAULT_RING_CAPACITY,
        overflow_policy: UInt8 = OVERFLOW_BLOCK,
    ) raises:
        comptime assert Self.T.__del__is_trivial, (
            "SpscRing[T] requires a trivially destructible T: slots are"
            " zero-filled and overwritten by assignment"
        )
        if capacity <= 0:
            raise Error("SpscRing: capacity must be > 0")
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        self._capacity = cap
        self._slots = Slab[Self.T]()
        self._cursors = _new_cursors()
        self._overflow_policy = overflow_policy

    @always_inline
    def capacity(self) -> Int:
        """The logical capacity, rounded up to a power of two."""
        return self._capacity

    @always_inline
    def slots_allocated(self) -> Bool:
        """True once the slot store has been materialized (first push).

        A freshly constructed ring reports False and still reports
        `capacity()` as its logical capacity.
        """
        return len(self._slots) == self._capacity

    @always_inline
    def _ensure_slots(mut self) -> None:
        """Materialize the slot store. Idempotent; producer side only.

        SAFETY (SPSC): only `try_push` calls this, and it has exactly one
        caller thread by the ring's contract, so the write to `_slots` races
        nothing. The consumer reads `_slots` only after loading a `tail` the
        producer advanced after this call.
        """
        if len(self._slots) != self._capacity:
            self._slots = Slab[Self.T].create_prefilled(self._capacity)

    @always_inline
    def overflow_dropped_count(self) -> Int64:
        """Pushes refused under OVERFLOW_DROP because the ring was full."""
        return self._cursors[].dropped.load()

    @always_inline
    def overflow_blocked_count(self) -> Int64:
        """Pushes that found the ring full and waited under OVERFLOW_BLOCK."""
        return self._cursors[].blocked.load()

    def try_push(mut self, record: Self.T) -> Bool:
        """Producer side. Write `record` into the ring.

        Returns True on success, and False only when the ring is full under
        OVERFLOW_DROP. Under OVERFLOW_BLOCK the call never returns False: it
        spins on `head` until the consumer frees a slot.
        """
        var tail = self._cursors[].tail.load()
        var head = self._cursors[].head.load()
        var capacity_i64 = Int64(self._capacity)

        if tail - head >= capacity_i64:
            if self._overflow_policy == OVERFLOW_DROP:
                _ = self._cursors[].dropped.fetch_add(Int64(1))
                return False
            _ = self._cursors[].blocked.fetch_add(Int64(1))
            while True:
                head = self._cursors[].head.load()
                if tail - head < capacity_i64:
                    break

        self._ensure_slots()
        var idx = Int(tail) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        slot = record.copy()

        _ = self._cursors[].tail.fetch_add(Int64(1))
        return True

    def try_pop(mut self) -> Optional[Self.T]:
        """Consumer side. Read the next record, or None if the ring is empty."""
        var head = self._cursors[].head.load()
        var tail = self._cursors[].tail.load()
        if head >= tail:
            return Optional[Self.T]()

        var idx = Int(head) & (self._capacity - 1)
        ref slot = self._slots.get_mut_interior(idx)
        var record = slot.copy()

        _ = self._cursors[].head.fetch_add(Int64(1))
        return Optional[Self.T](record^)

    @always_inline
    def is_empty(self) -> Bool:
        return self._cursors[].head.load() >= self._cursors[].tail.load()

    @always_inline
    def approximate_size(self) -> Int64:
        """Records pushed and not yet popped (a snapshot; either side may move)."""
        return self._cursors[].tail.load() - self._cursors[].head.load()
