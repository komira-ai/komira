# =============================================================================
# test_ring_variants.mojo -- the ring contract over every configuration of the
# ONE ring (`lazy` x capacity), on a 40-byte span-packet element.
# =============================================================================
#
# The ring study compared thirteen design variants (ordering, cursor cache,
# stride, comptime capacity, inline slots, lazy/eager store, policy). The
# winning algorithm is the only one that is implemented, with `lazy` its only
# parameter, so the thirteen cases here are thirteen configurations of that ring:
# lazy and eager, at capacities 1 to 4096. Per case: FIFO + wrap-around over
# three laps + drop accounting; a 200k-record BLOCK stress (FIFO, nothing lost);
# a BLOCK run where the consumer waits until the producer has really blocked; a
# free-running DROP run (delivered + dropped == pushed, order kept); and the
# data-race regression: the consumer is already polling the still-empty ring
# when the producer's first push creates the slot store.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64
from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join
from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK, OVERFLOW_DROP, SpscRing

comptime _WAIT_NS = 20_000_000_000


struct Pkt(Copyable, Movable, Deinitable):
    """The layout of the tracer's span packet (40 bytes)."""

    var kind: UInt8
    var _pad0: Array[UInt8, 3]
    var name_id: UInt32
    var span_id: UInt64
    var parent_id: UInt64
    var ts_ns: UInt64
    var worker_id: UInt16
    var flags: UInt16
    var trace_id_lo: UInt32

    def __init__(out self):
        self.kind = UInt8(0)
        self._pad0 = Array[UInt8, 3](fill=UInt8(0))
        self.name_id = UInt32(0)
        self.span_id = UInt64(0)
        self.parent_id = UInt64(0)
        self.ts_ns = UInt64(0)
        self.worker_id = UInt16(0)
        self.flags = UInt16(0)
        self.trace_id_lo = UInt32(0)


def _mk(i: Int) -> Pkt:
    var p = Pkt()
    p.span_id = UInt64(i)
    return p^


struct _Shared(Movable):
    var producer_done: AtomicI64
    var accepted: AtomicI64
    var delivered: AtomicI64
    var out_of_order: AtomicI64
    var consumer_polling: AtomicI64

    def __init__(out self):
        self.producer_done = AtomicI64(Int64(0))
        self.accepted = AtomicI64(Int64(0))
        self.delivered = AtomicI64(Int64(0))
        self.out_of_order = AtomicI64(Int64(0))
        self.consumer_polling = AtomicI64(Int64(0))


struct _Body[lazy: Bool, ro: MutOrigin, so: MutOrigin](SpawnJoinBody):
    """wait_for: 0 consume at once; 1 consume only once the producer has
    blocked; 3 the producer holds its first push until the consumer is polling
    the empty ring, then waits 2 ms."""

    var ring: Pointer[SpscRing[Pkt, Self.lazy], Self.ro]
    var shared: Pointer[_Shared, Self.so]
    var pushes: Int
    var wait_for: Int
    var drop_policy: Bool

    def __init__(
        out self,
        ring: Pointer[SpscRing[Pkt, Self.lazy], Self.ro],
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
            if self.wait_for == 3:
                var t0 = perf_counter_ns()
                while self.shared[].consumer_polling.load() == Int64(0):
                    if Int(perf_counter_ns() - t0) > _WAIT_NS:
                        raise Error("the consumer never started polling")
                var t1 = perf_counter_ns()
                while Int(perf_counter_ns() - t1) < 2_000_000:
                    pass
            for i in range(self.pushes):
                if self.ring[].try_push(_mk(i)):
                    _ = self.shared[].accepted.fetch_add(Int64(1))
            _ = self.shared[].producer_done.fetch_add(Int64(1))
        else:
            var t0 = perf_counter_ns()
            if self.wait_for == 1:
                while self.ring[].overflow_blocked_count() == Int64(0):
                    if Int(perf_counter_ns() - t0) > _WAIT_NS:
                        raise Error("the producer never blocked")
            var last = -1
            var announced = False
            while True:
                if not announced:
                    _ = self.shared[].consumer_polling.fetch_add(Int64(1))
                    announced = True
                var done = self.shared[].producer_done.load() != Int64(0)
                var r = self.ring[].try_pop()
                if r:
                    var id = Int(r.value().span_id)
                    if id <= last or (not self.drop_policy and id != last + 1):
                        _ = self.shared[].out_of_order.fetch_add(Int64(1))
                    last = id
                    _ = self.shared[].delivered.fetch_add(Int64(1))
                elif done:
                    break
                elif Int(perf_counter_ns() - t0) > _WAIT_NS:
                    raise Error("consumer starved")


def _single_thread[lazy: Bool](cap: Int) raises:
    var ring = SpscRing[Pkt, lazy](cap, OVERFLOW_DROP)
    assert_true(not ring.try_pop().__bool__(), "empty pop is None")
    for i in range(cap):
        assert_true(ring.try_push(_mk(i)), "push below capacity")
    assert_true(not ring.try_push(_mk(999)), "push on a full DROP ring refused")
    assert_equal(ring.overflow_dropped_count(), Int64(1), "one drop counted")
    for lap in range(3):
        for i in range(cap):
            var r = ring.try_pop()
            assert_true(r.__bool__(), "ring drained in order")
            assert_equal(Int(r.value().span_id), (i if lap == 0 else i + 1000 * lap))
        for i in range(cap):
            assert_true(ring.try_push(_mk(i + 1000 * (lap + 1))), "refill")
    assert_true(ring.slots_allocated(), "slots exist after pushes")


def _concurrent[lazy: Bool](cap: Int, n: Int, wait_for: Int, drop: Bool) raises:
    var ring = SpscRing[Pkt, lazy](cap, OVERFLOW_DROP if drop else OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _Body[lazy, _, _](Pointer(to=ring), Pointer(to=shared), n, wait_for, drop)
    spawn_join(body, 2)
    assert_equal(shared.out_of_order.load(), Int64(0), "order held")
    assert_equal(shared.accepted.load(), shared.delivered.load(), "accepted == delivered")
    if drop:
        assert_equal(
            shared.delivered.load() + ring.overflow_dropped_count(),
            Int64(n),
            "delivered + dropped == pushed",
        )
    else:
        assert_equal(shared.delivered.load(), Int64(n), "every record delivered")
    if wait_for == 1:
        assert_true(ring.overflow_blocked_count() > Int64(0), "the producer really blocked")


def _all[lazy: Bool](cap: Int) raises:
    _single_thread[lazy](cap)
    _concurrent[lazy](cap, 200000, 0, False)  # BLOCK stress
    _concurrent[lazy](cap, 200000, 1, False)  # BLOCK: producer must block, nothing lost
    _concurrent[lazy](cap, 200000, 0, True)  # DROP free-running accounting
    _concurrent[lazy](cap, 100000, 3, False)  # consumer polling before the store exists
    print("  lazy=" + String(lazy) + " cap=" + String(cap) + " PASS")


def main() raises:
    print("test_ring_variants")
    _all[True](1)
    _all[True](2)
    _all[True](4)
    _all[True](16)
    _all[True](64)
    _all[True](1024)
    _all[True](4096)
    _all[False](1)
    _all[False](2)
    _all[False](16)
    _all[False](64)
    _all[False](1024)
    _all[False](4096)
    print("ALL TESTS PASS")
