# =============================================================================
# spsc_ring_bench.mojo -- ring-level SPSC microbenchmark of komira_spsc_ring
# =============================================================================
#
# One producer thread and one consumer thread over one ring; three ops, each at
# every capacity asked for (`--caps`):
#
#   push_only  one thread pushes `cap` records into an empty ring (timed), then
#              drains it (untimed); repeated. ns per push.
#   push_pop   producer and consumer run together under OVERFLOW_BLOCK; the
#              clock runs from the producer's first push to the consumer's last
#              pop. ns per record moved.
#   drop_push  a full OVERFLOW_DROP ring refuses every push. ns per refused
#              push.
#
# The element is a 40-byte packet, the size of a span record. Every op moves
# `--total-ops` records in all (push_only in rounds of `cap`, at least one).
# One `RESULT <op> cap=<n> ns_per_op=<x>` line per measurement (harness.mojo).
#
# Run it on a quiet machine, pinned to one core, several times, and compare the
# minimum: one run on a shared box is noise.
# =============================================================================

from std.memory import Pointer
from std.time import perf_counter_ns

from komira_atomic_alias import AtomicI64
from komira_spsc_ring._test_threads import SpawnJoinBody, spawn_join
from komira_spsc_ring.spsc_ring import (
    SpscRing,
    OVERFLOW_BLOCK,
    OVERFLOW_DROP,
)

from komira_bench.harness import BenchArgs, Param, result_line

comptime DEFAULT_TOTAL_OPS = 20_000_000


def default_caps() -> List[Int]:
    var caps = List[Int]()
    caps.append(64)
    caps.append(1024)
    caps.append(4096)
    caps.append(65536)
    return caps^


struct Pkt(Copyable, Movable, Deinitable):
    """A 40-byte record, the size of a span packet."""

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


def _mk(i: Int) -> Pkt:
    var p = Pkt()
    p.span_id = UInt64(i)
    p.ts_ns = UInt64(i)
    return p^


def bench_push_only(cap: Int, total_ops: Int) raises -> Float64:
    var ring = Ring(cap, OVERFLOW_BLOCK)
    var pkt = _mk(7)
    for _ in range(cap):
        _ = ring.try_push(pkt)
    for _ in range(cap):
        _ = ring.try_pop()
    var rounds = max(1, total_ops // cap)
    var total = 0
    for _ in range(rounds):
        var t0 = Int(perf_counter_ns())
        for _ in range(cap):
            _ = ring.try_push(pkt)
        total += Int(perf_counter_ns()) - t0
        for _ in range(cap):
            _ = ring.try_pop()
    return Float64(total) / Float64(rounds * cap)


def bench_drop_push(cap: Int, total_ops: Int) raises -> Float64:
    var ring = Ring(cap, OVERFLOW_DROP)
    var pkt = _mk(7)
    for _ in range(cap):
        _ = ring.try_push(pkt)
    var t0 = Int(perf_counter_ns())
    for _ in range(total_ops):
        _ = ring.try_push(pkt)
    var dt = Int(perf_counter_ns()) - t0
    return Float64(dt) / Float64(total_ops)


struct _Shared(Movable):
    var t0: AtomicI64
    var t1: AtomicI64

    def __init__(out self):
        self.t0 = AtomicI64(Int64(0))
        self.t1 = AtomicI64(Int64(0))


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


def bench_push_pop(cap: Int, total_ops: Int) raises -> Float64:
    var ring = Ring(cap, OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _Body(Pointer(to=ring), Pointer(to=shared), total_ops)
    spawn_join(body, 2)
    return Float64(Int(shared.t1.load() - shared.t0.load())) / Float64(
        total_ops
    )


def _line(op: String, cap: Int, value: Float64, hide: Bool) -> String:
    var params = List[Param]()
    params.append(Param("cap", cap))
    return result_line(op, params, "ns_per_op", value, hide)


def bench_lines(cap: Int, args: BenchArgs) raises -> List[String]:
    """The three `RESULT` lines of one capacity, in the order push_only,
    push_pop, drop_push."""
    var lines = List[String]()
    lines.append(
        _line("push_only", cap, bench_push_only(cap, args.total_ops), args.hide_times)
    )
    lines.append(
        _line("push_pop", cap, bench_push_pop(cap, args.total_ops), args.hide_times)
    )
    lines.append(
        _line("drop_push", cap, bench_drop_push(cap, args.total_ops), args.hide_times)
    )
    return lines^
