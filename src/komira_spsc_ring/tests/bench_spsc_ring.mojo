# =============================================================================
# bench_spsc_ring.mojo -- ring-level SPSC microbenchmark (not a gated test)
# =============================================================================
#
# One producer thread and one consumer thread over one ring; three ops, each at
# four capacities:
#
#   push_only  one thread pushes `cap` records into an empty ring (timed), then
#              drains it (untimed); repeated. ns per push.
#   push_pop   producer and consumer run together under OVERFLOW_BLOCK; the
#              clock runs from the producer's first push to the consumer's last
#              pop. ns per record moved.
#   drop_push  a full OVERFLOW_DROP ring refuses every push. ns per refused
#              push.
#
# The element is a 40-byte packet with the layout of the tracer's span packet.
# The timed code is shared with a build against the previous
# `SpanPacketRingBuffer`: only the block between the RING SELECTION markers
# differs, so both rings run the same timed code. Output: one `RESULT <op> cap=<n> ns_per_op=<x>` line per
# measurement.
# =============================================================================

from std.memory import Pointer
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64

from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join

# --- RING SELECTION (begin) ---
from komira_spsc_ring.spsc_ring import (
    SpscRing,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
)


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


comptime Ring = SpscRing[Pkt]
# --- RING SELECTION (end) ---


comptime _TOTAL_OPS = 20_000_000


def _mk(i: Int) -> Pkt:
    var p = Pkt()
    p.span_id = UInt64(i)
    p.ts_ns = UInt64(i)
    return p^


def bench_push_only(cap: Int) raises -> Float64:
    var ring = Ring(cap, OVERFLOW_BLOCK)
    var pkt = _mk(7)
    for _ in range(cap):
        _ = ring.try_push(pkt)
    for _ in range(cap):
        _ = ring.try_pop()
    var rounds = _TOTAL_OPS // cap
    var total = 0
    for _ in range(rounds):
        var t0 = Int(perf_counter_ns())
        for _ in range(cap):
            _ = ring.try_push(pkt)
        total += Int(perf_counter_ns()) - t0
        for _ in range(cap):
            _ = ring.try_pop()
    return Float64(total) / Float64(rounds * cap)


def bench_drop_push(cap: Int) raises -> Float64:
    var ring = Ring(cap, OVERFLOW_DROP)
    var pkt = _mk(7)
    for _ in range(cap):
        _ = ring.try_push(pkt)
    var t0 = Int(perf_counter_ns())
    for _ in range(_TOTAL_OPS):
        _ = ring.try_push(pkt)
    var dt = Int(perf_counter_ns()) - t0
    return Float64(dt) / Float64(_TOTAL_OPS)


struct _Shared(Movable):
    var t0: AtomicI64
    var t1: AtomicI64
    var sum: AtomicI64

    def __init__(out self):
        self.t0 = AtomicI64(Int64(0))
        self.t1 = AtomicI64(Int64(0))
        self.sum = AtomicI64(Int64(0))


struct _Body[ro: MutOrigin, so: MutOrigin](SpawnJoinBody):
    var ring: Pointer[Ring, Self.ro]
    var shared: Pointer[_Shared, Self.so]
    var n: Int

    def __init__(
        out self,
        ring: Pointer[Ring, Self.ro],
        shared: Pointer[_Shared, Self.so],
        n: Int,
    ):
        self.ring = ring
        self.shared = shared
        self.n = n

    def run(self, tid: Int) raises:
        var pkt = _mk(7)
        if tid == 0:
            _ = self.shared[].t0.fetch_add(Int64(Int(perf_counter_ns())))
            for _ in range(self.n):
                _ = self.ring[].try_push(pkt)
        else:
            var got = 0
            while got < self.n:
                var r = self.ring[].try_pop()
                if r:
                    got += 1
            _ = self.shared[].t1.fetch_add(Int64(Int(perf_counter_ns())))
            _ = self.shared[].sum.fetch_add(Int64(got))


def bench_push_pop(cap: Int) raises -> Float64:
    var ring = Ring(cap, OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _Body(Pointer(to=ring), Pointer(to=shared), _TOTAL_OPS)
    spawn_join(body, 2)
    if shared.sum.load() != Int64(_TOTAL_OPS):
        raise Error("push_pop: the consumer did not receive every record")
    return Float64(Int(shared.t1.load() - shared.t0.load())) / Float64(
        _TOTAL_OPS
    )


def main() raises:
    var caps = List[Int]()
    caps.append(64)
    caps.append(1024)
    caps.append(4096)
    caps.append(65536)
    for i in range(len(caps)):
        var c = caps[i]
        print("RESULT push_only cap=" + String(c) + " ns_per_op=" + String(bench_push_only(c)))
        print("RESULT push_pop cap=" + String(c) + " ns_per_op=" + String(bench_push_pop(c)))
        print("RESULT drop_push cap=" + String(c) + " ns_per_op=" + String(bench_drop_push(c)))
