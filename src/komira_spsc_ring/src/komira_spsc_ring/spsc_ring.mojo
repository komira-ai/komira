# =============================================================================
# spsc_ring.mojo -- SpscRing[T]: a bounded single-producer / single-consumer ring
# =============================================================================
#
# One thread pushes, one thread pops (they may be the same thread). The producer
# publishes a slot by advancing `tail` AFTER writing it; the consumer retires one
# by advancing `head` AFTER reading it. Capacity is rounded up to a power of two
# at run time and the slot index is `position & (capacity - 1)`.
#
# Overflow policy (chosen at construction, at run time):
#   * OVERFLOW_BLOCK (default) -- a push onto a full ring spins until the
#     consumer frees a slot, so `try_push` never returns False.
#   * OVERFLOW_DROP -- a push onto a full ring counts the drop and returns False
#     without touching a slot.
# Both are accounted: `overflow_dropped_count()` and `overflow_blocked_count()`.
#
# `lazy` (a parameter, default True). With `lazy`, the constructor records the
# logical capacity but allocates no slot storage; the first `try_push`
# materializes it, so a ring that is never pushed to (an idle worker's ring)
# costs no slot memory and `try_pop` on it is a clean empty. With `lazy=False`
# the constructor allocates the store. Nothing else differs.
#
# Element contract, enforced at compile time: `T` must be trivially destructible
# AND trivially copyable. Slots are zero-filled and a push assigns over one, so
# a `T` that owns memory would run its destructor and copy on a slot that was
# never constructed.
#
# -----------------------------------------------------------------------------
# MEMORY-ORDERING ARGUMENT
# -----------------------------------------------------------------------------
# P is the one producer thread, C the one consumer thread. `tail` is written
# only by P, `head` only by C, both count positions from 0 and only increase.
# Invariant: 0 <= tail - head <= capacity. Slots are plain (non-atomic) memory.
#
# What each side does:
#   push (P):  t = tail (relaxed: P is its only writer)
#              h = cached head; if t - h >= cap: h = head.load(ACQUIRE), and
#              refresh the cache only if h changed; if still full, drop or spin
#              (re-reading head with ACQUIRE).
#              write slot[t & mask]; tail.store(t + 1, RELEASE).
#   pop  (C):  h = head (relaxed: C is its only writer)
#              t = cached tail; if h >= t: t = tail.load(ACQUIRE), refresh the
#              cache only if it changed; if still h >= t the ring is empty.
#              read slot[h & mask]; head.store(h + 1, RELEASE).
#
# (1) Slot contents are visible before the slot is used (P -> C). P's write to
#     slot n is sequenced before its release-store of tail = n + 1. C reads the
#     slot only after an acquire-load that returned a value v > n. That load
#     reads from P's release store of v (or of a later value: P is the only
#     writer and the values increase, and every later store is also sequenced
#     after the slot-n write), so the store synchronizes-with the load and the
#     write of slot n happens-before C's read of it. No torn or stale record.
# (2) A slot is not overwritten while C is still reading it (C -> P). P reuses
#     slot n only when it has seen head > n - cap, i.e. head >= n - cap + 1,
#     through an acquire-load. C's read of position n - cap is sequenced before
#     its release-store of head = n - cap + 1, so by the same argument that read
#     happens-before P's overwrite.
# (3) Each cursor has one writer, so the writer's own reads of it are relaxed
#     and its update is a plain release STORE of `old + 1`, not a read-modify-
#     write: nothing can have changed it in between. The sequentially
#     consistent `fetch_add` that publishes each cursor in the older rings is a
#     locked instruction; it cannot retire until the store buffer is drained and
#     the line is owned, which was the whole ~90 ns of a cross-core hand-off.
# (4) Why release/acquire is SUFFICIENT and seq-cst is not needed. Safety is
#     (1) and (2) alone, and both are pairwise synchronizes-with edges on ONE
#     variable each. Neither side ever needs a total order across the two
#     variables (a store-to-load ordering, the Dekker shape "I store mine, then
#     load yours, and one of us must see the other"). If P's load of `head`
#     misses a store C just made, P merely sees the ring as fuller than it is; if
#     C's load of `tail` misses P's store, C sees it emptier. Either is a
#     spurious full/empty answer that the next call resolves; it can delay, never
#     corrupt. (BLOCK re-reads `head` in its spin, and a store becomes visible
#     in finite time, so the spin ends.)
# (5) The cursor caches (`head_cache`, `tail_cache`) are plain integers private
#     to ONE thread (head_cache to P, tail_cache to C), so they need no
#     ordering. Each is an acquire-loaded value taken earlier, and cursors only
#     increase, so a cache is always a lower bound of the peer's cursor. A stale
#     cache can therefore only make the ring look fuller (P) or emptier (C) than
#     it is, never admit an unpublished slot or an unretired one. Refreshing
#     only when the ring looks full/empty keeps the peer's cache line (the one
#     holding its cursor) out of the fast path; rewriting the cache only when it
#     changed avoids a store in front of the next statistics write.
# (6) `dropped` / `blocked` are producer-only statistics: a relaxed load + store
#     (no RMW). A reader on another thread may see a stale value. Calling
#     `try_push` from two threads would lose increments (and break (3)); the
#     one-producer contract is what makes them cheap.
# (7) The lazy slot store is a field of the SHARED BLOCK, not of the ring
#     struct. P creates it strictly before its first release-store of `tail`;
#     C touches it only after an acquire-load that saw `tail` > `head`, i.e.
#     after that store, so (1) covers the store handle too. A pop on an empty
#     ring never touches slots, so a consumer already polling before the store
#     exists is fine. It must be in the block, not the struct: both sides call
#     their method through `mut self`, so the compiler may keep the struct's own
#     fields in registers across a polling loop, and a field the OTHER thread
#     writes would then be read once, stale, and indexed as null. This was
#     measured: with the slot store in the struct, a producer/consumer loop
#     crashed on a null slot pointer in most runs, and the regression test below
#     (the consumer polling before the first push) reproduces it. Through the
#     block pointer, every call re-reads it after the acquire-load, which the
#     compiler may not hoist above.
#
# x86-64: release-store and acquire-load are plain MOVs (TSO already orders
# store-store, load-load and load-store; the one reordering it allows,
# store-load, is exactly what (4) shows the algorithm does not need). So on x86
# this ring has NO fence and NO locked instruction on its fast path.
#
# arm64 (UNTESTED: nothing here ran on arm64, and x86 cannot falsify a missing
# ordering because it provides more than release/acquire). The orderings map to
# `stlr` (release store) and `ldar` (acquire load); relaxed is `str`/`ldr`. What
# would break if one were weakened, because arm64 reorders all four pairs:
#   * `tail` stored relaxed: C can see the new tail before the slot bytes ->
#     reads a stale or partly written record. (violates (1))
#   * `tail` loaded relaxed by C: the slot read can be issued before the tail
#     load resolves -> stale record. (violates (1))
#   * `head` stored relaxed by C: its slot read can complete AFTER the head store
#     is visible, P overwrites the slot, C reads the new bytes. (violates (2))
#   * `head` loaded relaxed by P: P's slot write can be performed before the load
#     that proved the slot free. (violates (2))
# With the orderings as written those four edges are exactly stlr/ldar pairs and
# the argument above applies unchanged (the C++/Mojo memory model, not x86). The
# 128-byte pad stride is the Apple-silicon cache line. Run
# `test_ring_variants` on a real arm64 machine before relying on this there.
#
# -----------------------------------------------------------------------------
# Layout. The ring is `Movable`, but atomics cannot be moved, so everything the
# two threads share lives in one boxed block (`_RingBlock`) owned through an
# `OwnedPointer`. Four `SPSC_PAD_BYTES` strides: [head | tail_cache] (the
# consumer's line), [tail | head_cache] (the producer's line), [dropped |
# blocked] (producer-only statistics), then the slot-store handle. Each
# independently written word sits on its own stride, so the producer's tail
# writes do not invalidate the line the consumer polls for head. A ring is moved
# only before first use (constructed and placed on one thread before any worker
# starts): moving re-creates the block's atomics with the same values.
# =============================================================================

from std.atomic import Ordering
from std.memory import OwnedPointer

from komira_atomic_alias import AtomicI64

from komira_collections.slab import Slab


# Stride between independently-written words. 128 bytes covers the
# adjacent-line prefetch pair on x86_64 and the 128-byte lines on Apple
# silicon; it is deliberately not the 64-byte Arrow buffer alignment.
comptime SPSC_PAD_BYTES: Int = 128

comptime DEFAULT_RING_CAPACITY: Int = 4096

comptime OVERFLOW_BLOCK: UInt8 = UInt8(0)  # default: correctness > throughput
comptime OVERFLOW_DROP: UInt8 = UInt8(1)  # opt-in via `overflow_policy`


struct _RingBlock[T: Copyable & Movable & Deinitable](Movable):
    """Everything both threads touch. See the layout note in the file header."""

    var _lead_pad: Array[UInt8, SPSC_PAD_BYTES]
    var head: AtomicI64  # written only by the consumer
    var tail_cache: Int64  # consumer-private lower bound of `tail`
    var _head_pad: Array[UInt8, SPSC_PAD_BYTES - 16]
    var tail: AtomicI64  # written only by the producer
    var head_cache: Int64  # producer-private lower bound of `head`
    var _tail_pad: Array[UInt8, SPSC_PAD_BYTES - 16]
    var dropped: AtomicI64  # producer-only statistic
    var blocked: AtomicI64  # producer-only statistic
    var _stat_pad: Array[UInt8, SPSC_PAD_BYTES - 16]
    var slots: Slab[Self.T]

    def __init__(out self, eager_slots: Int):
        self._lead_pad = Array[UInt8, SPSC_PAD_BYTES](fill=UInt8(0))
        self.head = AtomicI64(Int64(0))
        self.tail_cache = Int64(0)
        self._head_pad = Array[UInt8, SPSC_PAD_BYTES - 16](fill=UInt8(0))
        self.tail = AtomicI64(Int64(0))
        self.head_cache = Int64(0)
        self._tail_pad = Array[UInt8, SPSC_PAD_BYTES - 16](fill=UInt8(0))
        self.dropped = AtomicI64(Int64(0))
        self.blocked = AtomicI64(Int64(0))
        self._stat_pad = Array[UInt8, SPSC_PAD_BYTES - 16](fill=UInt8(0))
        if eager_slots > 0:
            self.slots = Slab[Self.T].create_prefilled(eager_slots)
        else:
            self.slots = Slab[Self.T]()

    def __init__(out self, *, deinit move: Self):
        # Re-creates the atomics with the same values: only valid before the
        # ring is shared with another thread (see the file header).
        self._lead_pad = Array[UInt8, SPSC_PAD_BYTES](fill=UInt8(0))
        self.head = AtomicI64(move.head.load())
        self.tail_cache = move.tail_cache
        self._head_pad = Array[UInt8, SPSC_PAD_BYTES - 16](fill=UInt8(0))
        self.tail = AtomicI64(move.tail.load())
        self.head_cache = move.head_cache
        self._tail_pad = Array[UInt8, SPSC_PAD_BYTES - 16](fill=UInt8(0))
        self.dropped = AtomicI64(move.dropped.load())
        self.blocked = AtomicI64(move.blocked.load())
        self._stat_pad = Array[UInt8, SPSC_PAD_BYTES - 16](fill=UInt8(0))
        self.slots = move.slots^


@always_inline
def _bump(mut counter: AtomicI64):
    """Producer-only statistic: relaxed load + store, no RMW (header, point 6)."""
    counter.store[ordering=Ordering.RELAXED](
        counter.load[ordering=Ordering.RELAXED]() + Int64(1)
    )


struct SpscRing[T: Copyable & Movable & Deinitable, lazy: Bool = True](
    Movable, Deinitable
):
    """A bounded SPSC ring of trivially-copyable, trivially-destructible `T`.

    Exactly one thread may call `try_push` and exactly one may call `try_pop`
    (they may be the same thread). `capacity()`, the counters and the
    introspection methods may be read from either side.
    """

    var _capacity: Int
    var _block: OwnedPointer[_RingBlock[Self.T]]
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
        comptime assert Self.T.__copy_ctor_is_trivial, (
            "SpscRing[T] requires a trivially copyable T: a push copies the"
            " record over a slot that was never constructed"
        )
        if capacity <= 0:
            raise Error("SpscRing: capacity must be > 0")
        var cap = 1
        while cap < capacity:
            cap = cap * 2
        self._capacity = cap
        var eager = 0 if Self.lazy else cap
        self._block = OwnedPointer[_RingBlock[Self.T]](_RingBlock[Self.T](eager))
        self._overflow_policy = overflow_policy

    @always_inline
    def capacity(self) -> Int:
        """The logical capacity, rounded up to a power of two."""
        return self._capacity

    @always_inline
    def slots_allocated(self) -> Bool:
        """True once the slot store exists (always, when not `lazy`).

        A diagnostic: from a thread other than the producer the answer may be
        stale.
        """
        return len(self._block[].slots) == self._capacity

    @always_inline
    def overflow_dropped_count(self) -> Int64:
        """Pushes refused under OVERFLOW_DROP because the ring was full."""
        return self._block[].dropped.load[ordering=Ordering.RELAXED]()

    @always_inline
    def overflow_blocked_count(self) -> Int64:
        """Pushes that found the ring full and waited under OVERFLOW_BLOCK."""
        return self._block[].blocked.load[ordering=Ordering.RELAXED]()

    # `@always_inline` on try_push / try_pop is load-bearing: without it the
    # same code measured ~75 ns per record in the two-thread hand-off instead of
    # ~2.4 ns (cause not isolated; the out-of-line call is the only difference).
    @always_inline
    def try_push(mut self, record: Self.T) -> Bool:
        """Producer side. Write `record` into the ring.

        Returns True on success, and False only when the ring is full under
        OVERFLOW_DROP. Under OVERFLOW_BLOCK the call never returns False: it
        spins on `head` until the consumer frees a slot.
        """
        var cap = self._capacity
        var cap64 = Int64(cap)
        var tail = self._block[].tail.load[ordering=Ordering.RELAXED]()
        var head = self._block[].head_cache
        if tail - head >= cap64:
            var seen = head
            head = self._block[].head.load[ordering=Ordering.ACQUIRE]()
            if head != seen:
                self._block[].head_cache = head
            if tail - head >= cap64:
                if self._overflow_policy == OVERFLOW_DROP:
                    _bump(self._block[].dropped)
                    return False
                _bump(self._block[].blocked)
                while True:
                    head = self._block[].head.load[ordering=Ordering.ACQUIRE]()
                    if tail - head < cap64:
                        break
                self._block[].head_cache = head

        comptime if Self.lazy:
            # SAFETY (SPSC): only the producer creates the store, strictly
            # before its first release-store of `tail` (header, point 7).
            if len(self._block[].slots) != cap:
                self._block[].slots = Slab[Self.T].create_prefilled(cap)
        ref slot = self._block[].slots.get_mut_interior(Int(tail) & (cap - 1))
        slot = record.copy()

        self._block[].tail.store[ordering=Ordering.RELEASE](tail + Int64(1))
        return True

    @always_inline
    def try_pop(mut self) -> Optional[Self.T]:
        """Consumer side. Read the next record, or None if the ring is empty."""
        var head = self._block[].head.load[ordering=Ordering.RELAXED]()
        var tail = self._block[].tail_cache
        if head >= tail:
            var seen = tail
            tail = self._block[].tail.load[ordering=Ordering.ACQUIRE]()
            if tail != seen:
                self._block[].tail_cache = tail
            if head >= tail:
                return Optional[Self.T]()

        ref slot = self._block[].slots.get_mut_interior(
            Int(head) & (self._capacity - 1)
        )
        var record = slot.copy()

        self._block[].head.store[ordering=Ordering.RELEASE](head + Int64(1))
        return Optional[Self.T](record^)

    @always_inline
    def is_empty(self) -> Bool:
        return self.approximate_size() <= Int64(0)

    @always_inline
    def approximate_size(self) -> Int64:
        """Records pushed and not yet popped (a snapshot; either side may move)."""
        var head = self._block[].head.load[ordering=Ordering.ACQUIRE]()
        var tail = self._block[].tail.load[ordering=Ordering.ACQUIRE]()
        return tail - head
