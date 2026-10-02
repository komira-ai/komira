# The consumer-polling-before-the-slot-store regression, as a stand-alone
# program. `RING_MODULE` is replaced by the script that builds it. Exit status
# 0 = every record arrived in order; anything else (a crash on a null slot
# store, a lost or reordered record) is the bug.

from std.memory import Pointer
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64
from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join
from RING_MODULE import OVERFLOW_BLOCK, SpscRing


struct Rec(Copyable, Movable, Deinitable):
    var id: UInt64
    var pad: UInt64

    def __init__(out self):
        self.id = UInt64(0)
        self.pad = UInt64(0)

    def __init__(out self, id: Int):
        self.id = UInt64(id)
        self.pad = UInt64(0)


struct _Shared(Movable):
    var polling: AtomicI64
    var delivered: AtomicI64
    var bad: AtomicI64

    def __init__(out self):
        self.polling = AtomicI64(Int64(0))
        self.delivered = AtomicI64(Int64(0))
        self.bad = AtomicI64(Int64(0))


struct _Body[ro: MutOrigin, so: MutOrigin](SpawnJoinBody):
    var ring: Pointer[SpscRing[Rec], Self.ro]
    var shared: Pointer[_Shared, Self.so]
    var n: Int

    def __init__(
        out self,
        ring: Pointer[SpscRing[Rec], Self.ro],
        shared: Pointer[_Shared, Self.so],
        n: Int,
    ):
        self.ring = ring
        self.shared = shared
        self.n = n

    def run(self, tid: Int) raises:
        if tid == 0:
            # Hold the first push until the consumer is polling the empty ring,
            # then 2 ms more: the consumer's loop is running before the store
            # exists.
            var t0 = perf_counter_ns()
            while self.shared[].polling.load() == Int64(0):
                if Int(perf_counter_ns() - t0) > 20_000_000_000:
                    raise Error("the consumer never started polling")
            var t1 = perf_counter_ns()
            while Int(perf_counter_ns() - t1) < 2_000_000:
                pass
            for i in range(self.n):
                _ = self.ring[].try_push(Rec(i))
        else:
            _ = self.shared[].polling.fetch_add(Int64(1))
            var t0 = perf_counter_ns()
            var next = 0
            while next < self.n:
                var r = self.ring[].try_pop()
                if r:
                    if Int(r.value().id) != next:
                        _ = self.shared[].bad.fetch_add(Int64(1))
                    next += 1
                    _ = self.shared[].delivered.fetch_add(Int64(1))
                elif Int(perf_counter_ns() - t0) > 20_000_000_000:
                    raise Error("consumer starved")


def main() raises:
    var n = 100000
    var ring = SpscRing[Rec](64, OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _Body(Pointer(to=ring), Pointer(to=shared), n)
    spawn_join(body, 2)
    if shared.bad.load() != Int64(0) or shared.delivered.load() != Int64(n):
        raise Error("records lost or reordered")
    print("OK")
