# =============================================================================
# test_spsc_ring.mojo -- SpscRing[T] correctness, overflow semantics, layout
# =============================================================================
#
# Three rings used to carry their own copy of this logic (a span-record ring, a
# span-packet ring and a log-record ring); they are now instances of
# SpscRing[T]. These tests pin the behaviour all three had, on a plain-data
# element, and the layout guards the generic version adds.
#
# Verifies:
#   1.  Construct, capacity rounded up to a power of two, empty at start.
#   2.  try_pop on an empty ring is None.
#   3.  Push/pop round-trips every field; pops come out in push order (FIFO).
#   4.  The index mask wraps correctly past the capacity boundary.
#   5.  OVERFLOW_DROP: a push onto a full ring returns False, counts the drop,
#       leaves the stored records and the size untouched, and the ring accepts
#       pushes again once drained.
#   6.  OVERFLOW_BLOCK is the default; it never counts a drop, and a ring that
#       is filled to exactly capacity and drained does not count a block.
#   7.  Slots are lazy: none until the first push; an empty pop allocates none;
#       the logical capacity is live from construction.
#   8.  DROP accounting is driven by the logical capacity, not the lazy store.
#   9.  Two rings keep independent cursors and counters.
#  10.  A moved ring keeps working (cursors travel with it).
#  11.  Zero and negative capacity raise.
#  12.  Concurrency (spawn_join, real producer and consumer threads): under
#       OVERFLOW_BLOCK the producer really blocks on a full ring until the
#       consumer drains, and every record arrives once, in order; under
#       OVERFLOW_DROP, delivered + dropped == pushed, in order, both when the
#       ring is saturated (consumer starts after the producer is done) and when
#       the two run free.
#  13.  Layout: the shared block is four SPSC_PAD_BYTES strides and the ring
#       struct holds no inline atomics (it stays small and Movable).
# =============================================================================

from std.memory import OwnedPointer, Pointer
from std.sys.info import size_of
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64

from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join
from komira_spsc_ring.spsc_ring import (
    DEFAULT_RING_CAPACITY,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
    SPSC_PAD_BYTES,
    SpscRing,
    _RingBlock,
)



struct Rec(Copyable, Movable, Deinitable):
    """A plain-data ring element: trivially destructible."""

    var id: UInt64
    var start_ns: UInt64
    var worker: UInt32

    def __init__(out self):
        self.id = UInt64(0)
        self.start_ns = UInt64(0)
        self.worker = UInt32(0)

    def __init__(out self, id: Int):
        self.id = UInt64(id)
        self.start_ns = UInt64(0)
        self.worker = UInt32(0)


def test_construct() raises:
    var ring = SpscRing[Rec](64, OVERFLOW_BLOCK)
    assert_equal(ring.capacity(), Int(64), "capacity 64")
    assert_true(ring.is_empty(), "empty initially")
    assert_equal(ring.approximate_size(), Int64(0), "size 0")
    print("  test_construct PASS")


def test_default_capacity_and_policy() raises:
    var ring = SpscRing[Rec]()
    assert_equal(ring.capacity(), DEFAULT_RING_CAPACITY, "default capacity")
    assert_equal(DEFAULT_RING_CAPACITY, Int(4096), "default is 4096")
    print("  test_default_capacity_and_policy PASS")


def test_capacity_rounds_up_pow2() raises:
    assert_equal(SpscRing[Rec](50, OVERFLOW_BLOCK).capacity(), Int(64), "50 -> 64")
    assert_equal(SpscRing[Rec](64, OVERFLOW_BLOCK).capacity(), Int(64), "64 -> 64")
    assert_equal(SpscRing[Rec](65, OVERFLOW_BLOCK).capacity(), Int(128), "65 -> 128")
    assert_equal(SpscRing[Rec](1, OVERFLOW_BLOCK).capacity(), Int(1), "1 -> 1")
    print("  test_capacity_rounds_up_pow2 PASS")


def test_pop_empty_returns_none() raises:
    var ring = SpscRing[Rec](16, OVERFLOW_BLOCK)
    assert_false(Bool(ring.try_pop()), "empty pop returns None")
    print("  test_pop_empty_returns_none PASS")


def test_push_pop_round_trip() raises:
    var ring = SpscRing[Rec](16, OVERFLOW_BLOCK)
    var rec = Rec()
    rec.id = UInt64(42)
    rec.start_ns = UInt64(1000)
    rec.worker = UInt32(2)
    assert_true(ring.try_push(rec), "push succeeds")
    assert_equal(ring.approximate_size(), Int64(1), "size 1 after push")
    var maybe = ring.try_pop()
    assert_true(Bool(maybe), "pop succeeds")
    ref got = maybe.value()
    assert_equal(got.id, UInt64(42), "id round-trip")
    assert_equal(got.start_ns, UInt64(1000), "start_ns round-trip")
    assert_equal(got.worker, UInt32(2), "worker round-trip")
    assert_true(ring.is_empty(), "empty after pop")
    print("  test_push_pop_round_trip PASS")


def test_fifo_order() raises:
    var ring = SpscRing[Rec](16, OVERFLOW_BLOCK)
    for i in range(8):
        assert_true(ring.try_push(Rec(i)), "push " + String(i))
    for i in range(8):
        var maybe = ring.try_pop()
        assert_true(Bool(maybe), "pop succeeds at " + String(i))
        assert_equal(maybe.value().id, UInt64(i), "FIFO at " + String(i))
    print("  test_fifo_order PASS")


def test_wrap_around() raises:
    """Push/pop one at a time across many multiples of the capacity."""
    var ring = SpscRing[Rec](4, OVERFLOW_BLOCK)
    for i in range(50):
        assert_true(ring.try_push(Rec(i + 1)), "push in flight")
        var got = ring.try_pop()
        assert_true(Bool(got), "pop returns the pushed record")
        assert_equal(got.value().id, UInt64(i + 1), "round-trip across the wrap")
    assert_true(ring.is_empty(), "drained")
    # Also wrap with the ring partly full: 3 in flight over capacity 4.
    var next_push = 0
    var next_pop = 0
    for _ in range(3):
        assert_true(ring.try_push(Rec(next_push)), "prime")
        next_push += 1
    for _ in range(40):
        assert_true(ring.try_push(Rec(next_push)), "steady push")
        next_push += 1
        var got = ring.try_pop()
        assert_equal(got.value().id, UInt64(next_pop), "steady FIFO")
        next_pop += 1
    print("  test_wrap_around PASS")


def test_drop_policy_on_full() raises:
    var ring = SpscRing[Rec](8, OVERFLOW_DROP)
    for i in range(8):
        assert_true(ring.try_push(Rec(i)), "fills to capacity")
    assert_false(ring.try_push(Rec(99)), "push fails at overflow")
    assert_equal(ring.overflow_dropped_count(), Int64(1), "drop counter = 1")
    assert_equal(ring.overflow_blocked_count(), Int64(0), "no block counted")
    assert_equal(ring.approximate_size(), Int64(8), "size unchanged by a drop")
    assert_false(ring.try_push(Rec(100)), "second drop")
    assert_equal(ring.overflow_dropped_count(), Int64(2), "drop counter = 2")
    # The dropped records never entered: the 8 originals pop in order.
    for i in range(8):
        assert_equal(ring.try_pop().value().id, UInt64(i), "stored record intact")
    assert_false(Bool(ring.try_pop()), "nothing else was stored")
    # Space again: pushes succeed and the drop count does not move.
    assert_true(ring.try_push(Rec(7)), "push after drain succeeds")
    assert_equal(ring.overflow_dropped_count(), Int64(2), "drop counter holds")
    print("  test_drop_policy_on_full PASS")


def test_block_policy_is_default_and_counts_nothing_when_not_full() raises:
    var ring = SpscRing[Rec](8)  # default policy
    for round in range(5):
        for i in range(8):
            assert_true(ring.try_push(Rec(i)), "block never refuses")
        for i in range(8):
            assert_equal(ring.try_pop().value().id, UInt64(i), "FIFO")
    assert_equal(ring.overflow_dropped_count(), Int64(0), "block never drops")
    assert_equal(
        ring.overflow_blocked_count(),
        Int64(0),
        "filling to exactly capacity is not a block",
    )
    print("  test_block_policy_is_default_and_counts_nothing_when_not_full PASS")


def test_slots_are_lazy() raises:
    var ring = SpscRing[Rec](64, OVERFLOW_BLOCK)
    assert_equal(ring.capacity(), Int(64), "logical capacity is live at ctor")
    assert_false(ring.slots_allocated(), "fresh ring owns no backing store")
    assert_true(ring.try_push(Rec()), "first push succeeds")
    assert_true(ring.slots_allocated(), "first push materializes the store")
    print("  test_slots_are_lazy PASS")


def test_pop_empty_before_any_push_allocates_nothing() raises:
    var ring = SpscRing[Rec](16, OVERFLOW_BLOCK)
    assert_false(ring.slots_allocated(), "no store yet")
    assert_true(ring.is_empty(), "fresh ring is empty")
    assert_false(Bool(ring.try_pop()), "empty pop returns None")
    assert_false(ring.slots_allocated(), "an empty pop allocates nothing")
    print("  test_pop_empty_before_any_push_allocates_nothing PASS")


def test_drop_accounting_uses_logical_capacity() raises:
    """The full point is the logical capacity, live before any slot exists."""
    var ring = SpscRing[Rec](4, OVERFLOW_DROP)
    for _ in range(4):
        assert_true(ring.try_push(Rec()), "fills to capacity")
    assert_false(ring.try_push(Rec()), "5th push on a 4-ring drops")
    assert_equal(ring.overflow_dropped_count(), Int64(1), "one drop accounted")
    print("  test_drop_accounting_uses_logical_capacity PASS")


def test_two_rings_have_independent_cursors() raises:
    var a = SpscRing[Rec](8, OVERFLOW_DROP)
    var b = SpscRing[Rec](8, OVERFLOW_DROP)
    for i in range(8):
        assert_true(a.try_push(Rec(i)), "fill a")
    assert_false(a.try_push(Rec()), "a overflows")
    assert_true(b.is_empty(), "b untouched by a's pushes")
    assert_equal(b.overflow_dropped_count(), Int64(0), "b has no drops")
    assert_true(b.try_push(Rec(5)), "b accepts")
    assert_equal(b.approximate_size(), Int64(1), "b size 1")
    assert_equal(a.approximate_size(), Int64(8), "a size 8")
    assert_equal(b.try_pop().value().id, UInt64(5), "b pops its own record")
    assert_equal(a.approximate_size(), Int64(8), "a unaffected by b's pop")
    print("  test_two_rings_have_independent_cursors PASS")


def test_moved_ring_keeps_working() raises:
    var ring = SpscRing[Rec](8, OVERFLOW_DROP)
    for i in range(3):
        assert_true(ring.try_push(Rec(i)), "push before move")
    var moved = ring^
    assert_equal(moved.approximate_size(), Int64(3), "cursors moved with it")
    assert_equal(moved.try_pop().value().id, UInt64(0), "FIFO survives the move")
    assert_true(moved.try_push(Rec(3)), "push after move")
    var boxed = OwnedPointer(moved^)
    assert_equal(boxed[].approximate_size(), Int64(3), "boxed ring intact")
    # A ring moved before its first push still materializes lazily.
    var fresh = SpscRing[Rec](4, OVERFLOW_BLOCK)
    var fresh_moved = fresh^
    assert_false(fresh_moved.slots_allocated(), "still lazy after a move")
    assert_true(fresh_moved.try_push(Rec(1)), "push after move of an empty ring")
    assert_equal(fresh_moved.try_pop().value().id, UInt64(1), "round-trip")
    print("  test_moved_ring_keeps_working PASS")


def test_bad_capacity_raises() raises:
    var raised = False
    try:
        _ = SpscRing[Rec](0)
    except e:
        raised = True
        assert_true("capacity must be > 0" in String(e), "message names the cause")
    assert_true(raised, "capacity 0 raises")
    raised = False
    try:
        _ = SpscRing[Rec](-5)
    except:
        raised = True
    assert_true(raised, "negative capacity raises")
    print("  test_bad_capacity_raises PASS")


comptime _WAIT_NS = 20_000_000_000  # a stuck handshake fails, never hangs


struct _Shared(Movable):
    """What the producer and consumer threads share besides the ring."""

    var producer_done: AtomicI64
    var accepted: AtomicI64  # pushes that returned True
    var delivered: AtomicI64  # records the consumer popped
    var out_of_order: AtomicI64
    var consumer_polling: AtomicI64

    def __init__(out self):
        self.producer_done = AtomicI64(Int64(0))
        self.accepted = AtomicI64(Int64(0))
        self.delivered = AtomicI64(Int64(0))
        self.out_of_order = AtomicI64(Int64(0))
        self.consumer_polling = AtomicI64(Int64(0))


struct _RingBody[ro: MutOrigin, so: MutOrigin](SpawnJoinBody):
    """tid 0 produces `pushes` records; tid 1 consumes them.

    wait_for: 0 = consume immediately; 1 = consume only after the ring has
    made the producer block (BLOCK rings); 2 = consume only after the producer
    finished (saturates a DROP ring); 3 = consume immediately, and the
    producer holds its first push until the consumer is already polling the
    still-empty ring and then waits a further 2 ms (the consumer's polling loop
    is running before the slot store exists). A wait that does not end raises.
    """

    var ring: Pointer[SpscRing[Rec], Self.ro]
    var shared: Pointer[_Shared, Self.so]
    var pushes: Int
    var wait_for: Int
    var drop_policy: Bool

    def __init__(
        out self,
        ring: Pointer[SpscRing[Rec], Self.ro],
        shared: Pointer[_Shared, Self.so],
        pushes: Int,
        wait_for: Int,
        drop_policy: Bool,
    ):
        self.ring = ring
        self.shared = shared
        self.pushes = pushes
        self.wait_for = wait_for
        self.drop_policy = drop_policy

    def run(self, tid: Int) raises:
        if tid == 0:
            self._produce()
        else:
            self._consume()

    def _produce(self) raises:
        if self.wait_for == 3:
            var t0 = perf_counter_ns()
            while self.shared[].consumer_polling.load() == Int64(0):
                if Int(perf_counter_ns() - t0) > _WAIT_NS:
                    raise Error("the consumer never started polling")
            var t1 = perf_counter_ns()
            while Int(perf_counter_ns() - t1) < 2_000_000:
                pass
        for i in range(self.pushes):
            if self.ring[].try_push(Rec(i)):
                _ = self.shared[].accepted.fetch_add(Int64(1))
        _ = self.shared[].producer_done.fetch_add(Int64(1))

    def _consume(self) raises:
        var t0 = perf_counter_ns()
        if self.wait_for == 1:
            while self.ring[].overflow_blocked_count() == Int64(0):
                if Int(perf_counter_ns() - t0) > _WAIT_NS:
                    raise Error("the producer never blocked on a full ring")
        elif self.wait_for == 2:
            while self.shared[].producer_done.load() == Int64(0):
                if Int(perf_counter_ns() - t0) > _WAIT_NS:
                    raise Error("the producer never finished")
        var last = -1
        var announced = False
        while True:
            if not announced:
                _ = self.shared[].consumer_polling.fetch_add(Int64(1))
                announced = True
            # Read `done` BEFORE popping: every push happened before the flag,
            # so an empty pop after seeing it set means the ring is drained.
            var done = self.shared[].producer_done.load() != Int64(0)
            var r = self.ring[].try_pop()
            if r:
                var id = Int(r.value().id)
                if id <= last or (not self.drop_policy and id != last + 1):
                    _ = self.shared[].out_of_order.fetch_add(Int64(1))
                last = id
                _ = self.shared[].delivered.fetch_add(Int64(1))
            elif done:
                break
            elif Int(perf_counter_ns() - t0) > _WAIT_NS:
                raise Error("consumer starved")


def test_block_producer_really_blocks_and_nothing_is_lost() raises:
    var n = 5000
    var ring = SpscRing[Rec](4, OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _RingBody(Pointer(to=ring), Pointer(to=shared), n, 1, False)
    spawn_join(body, 2)
    assert_true(
        ring.overflow_blocked_count() > Int64(0),
        "the full ring made the producer block",
    )
    assert_equal(ring.overflow_dropped_count(), Int64(0), "BLOCK never drops")
    assert_equal(shared.accepted.load(), Int64(n), "every push succeeded")
    assert_equal(shared.delivered.load(), Int64(n), "every record delivered")
    assert_equal(shared.out_of_order.load(), Int64(0), "FIFO order held")
    assert_true(ring.is_empty(), "ring drained")
    print("  test_block_producer_really_blocks_and_nothing_is_lost PASS")


def test_drop_saturated_ring_accounts_every_push() raises:
    var n = 3000
    var ring = SpscRing[Rec](8, OVERFLOW_DROP)
    var shared = _Shared()
    var body = _RingBody(Pointer(to=ring), Pointer(to=shared), n, 2, True)
    spawn_join(body, 2)
    # The consumer started after the producer finished, so the ring held its 8
    # slots and rejected every other push: the split is exact.
    assert_equal(shared.delivered.load(), Int64(8), "ring held its capacity")
    assert_equal(ring.overflow_dropped_count(), Int64(n - 8), "the rest dropped")
    assert_equal(
        shared.delivered.load() + ring.overflow_dropped_count(),
        Int64(n),
        "delivered + dropped == pushed",
    )
    assert_equal(shared.accepted.load(), shared.delivered.load(), "accepted == delivered")
    assert_equal(shared.out_of_order.load(), Int64(0), "order held")
    print("  test_drop_saturated_ring_accounts_every_push PASS")


def test_drop_free_running_accounts_every_push() raises:
    var n = 200000
    var ring = SpscRing[Rec](16, OVERFLOW_DROP)
    var shared = _Shared()
    var body = _RingBody(Pointer(to=ring), Pointer(to=shared), n, 0, True)
    spawn_join(body, 2)
    assert_equal(
        shared.delivered.load() + ring.overflow_dropped_count(),
        Int64(n),
        "delivered + dropped == pushed",
    )
    assert_equal(shared.accepted.load(), shared.delivered.load(), "accepted == delivered")
    assert_equal(shared.out_of_order.load(), Int64(0), "order held")
    assert_true(shared.delivered.load() > Int64(0), "something got through")
    print("  test_drop_free_running_accounts_every_push PASS")


def test_consumer_polling_before_the_slot_store_exists() raises:
    """The consumer is already inside its polling loop when the producer's
    first push creates the slot store, and must still see the store.

    Both threads call their method through `mut self`, so a field only the
    producer writes (the lazily created store) must be reached through the
    shared block on every call, not cached by the consumer's loop. A consumer
    that cached it read a null store and crashed on its first record.
    """
    var n = 100000
    var ring = SpscRing[Rec](64, OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _RingBody(Pointer(to=ring), Pointer(to=shared), n, 3, False)
    spawn_join(body, 2)
    assert_equal(shared.delivered.load(), Int64(n), "every record delivered")
    assert_equal(shared.out_of_order.load(), Int64(0), "FIFO order held")
    assert_true(ring.is_empty(), "ring drained")
    print("  test_consumer_polling_before_the_slot_store_exists PASS")


def test_eager_ring_allocates_in_the_constructor() raises:
    var ring = SpscRing[Rec, False](8, OVERFLOW_BLOCK)
    assert_true(ring.slots_allocated(), "lazy=False owns its store at once")
    assert_true(ring.is_empty(), "empty")
    for i in range(20):
        assert_true(ring.try_push(Rec(i)), "push")
        assert_equal(ring.try_pop().value().id, UInt64(i), "round-trip")
    var drop = SpscRing[Rec, False](4, OVERFLOW_DROP)
    for _ in range(4):
        assert_true(drop.try_push(Rec()), "fill")
    assert_false(drop.try_push(Rec()), "drop at capacity")
    assert_equal(drop.overflow_dropped_count(), Int64(1), "counted")
    print("  test_eager_ring_allocates_in_the_constructor PASS")


def test_refused_push_after_cache_staleness() raises:
    """A stale head cache must not admit a push the ring cannot hold, and must
    refresh once the consumer has freed space (conditional cache refresh)."""
    var ring = SpscRing[Rec](4, OVERFLOW_DROP)
    for i in range(4):
        assert_true(ring.try_push(Rec(i)), "fill")
    assert_false(ring.try_push(Rec()), "full: refused")
    assert_false(ring.try_push(Rec()), "still full: refused again")
    assert_equal(ring.try_pop().value().id, UInt64(0), "free one slot")
    assert_true(ring.try_push(Rec(4)), "refresh sees the freed slot")
    assert_false(ring.try_push(Rec()), "full again")
    assert_equal(ring.overflow_dropped_count(), Int64(3), "three refusals")
    print("  test_refused_push_after_cache_staleness PASS")


def test_layout_guards() raises:
    # lead pad + three counter strides ([head|tail_cache], [tail|head_cache],
    # [dropped|blocked]), each on its own SPSC_PAD_BYTES stride. The slot-store
    # handle sits after the last stride.
    var block = size_of[_RingBlock[Rec]]()
    assert_true(
        block >= 4 * SPSC_PAD_BYTES and block <= 4 * SPSC_PAD_BYTES + 64,
        "shared block is four pad strides plus the slot-store handle",
    )
    assert_true(SPSC_PAD_BYTES >= 128, "stride covers an adjacent-line pair")
    # The ring struct itself holds no atomics and no slot store: capacity +
    # box pointer + policy byte.
    assert_true(
        size_of[SpscRing[Rec]]() <= 32,
        "ring struct stays a small handle (counters and slots are boxed)",
    )
    print("  test_layout_guards PASS")


def main() raises:
    print("test_spsc_ring")
    print("==============")
    test_construct()
    test_default_capacity_and_policy()
    test_capacity_rounds_up_pow2()
    test_pop_empty_returns_none()
    test_push_pop_round_trip()
    test_fifo_order()
    test_wrap_around()
    test_drop_policy_on_full()
    test_block_policy_is_default_and_counts_nothing_when_not_full()
    test_slots_are_lazy()
    test_pop_empty_before_any_push_allocates_nothing()
    test_drop_accounting_uses_logical_capacity()
    test_two_rings_have_independent_cursors()
    test_moved_ring_keeps_working()
    test_bad_capacity_raises()
    test_block_producer_really_blocks_and_nothing_is_lost()
    test_drop_saturated_ring_accounts_every_push()
    test_drop_free_running_accounts_every_push()
    test_consumer_polling_before_the_slot_store_exists()
    test_eager_ring_allocates_in_the_constructor()
    test_refused_push_after_cache_staleness()
    test_layout_guards()
    print()
    print("ALL TESTS PASS")
