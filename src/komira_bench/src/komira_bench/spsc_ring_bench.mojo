# =============================================================================
# spsc_ring_bench.mojo -- ring-level SPSC microbenchmark of komira_spsc_ring
# =============================================================================
#
# One producer thread and one consumer thread over one ring; three ops, each at
# every capacity asked for (`--caps`), and each timing exactly `--total-ops`
# operations:
#
#   push_only  one thread pushes into an empty ring (timed), then drains it
#              (untimed): rounds of `cap` pushes, and a last round of
#              `total_ops % cap` when that is not zero. ns per push.
#   push_pop   producer and consumer run together under OVERFLOW_BLOCK; the
#              clock runs from the producer's first push to the consumer's last
#              pop, after `total_ops` records. ns per record moved.
#   drop_push  a full OVERFLOW_DROP ring (filled to `capacity()`) refuses each
#              of `total_ops` pushes. ns per refused push.
#
# A capacity is a power of two from 1 to MAX_CAP: the ring rounds any other
# number up, and the line would then name a capacity that was not measured, so
# any other is refused by name before a ring is made. The element is a 40-byte
# packet, the size of a span record. One `RESULT <op> cap=<n> ns_per_op=<x>`
# line per measurement (harness.mojo).
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

from komira_bench.harness import BenchArgs, Param, parse_args, result_line, usage

# The operations each measurement times when `--total-ops` is not given.
comptime DEFAULT_TOTAL_OPS = 20_000_000

# The largest capacity `--caps` takes: 16777216 slots of 40 bytes.
comptime MAX_CAP = 1 << 24


def default_caps() -> List[Int]:
    """The capacities measured when `--caps` is not given."""
    var caps = List[Int]()
    caps.append(64)
    caps.append(1024)
    caps.append(4096)
    caps.append(65536)
    return caps^


struct _Pkt(Copyable, Movable, Deinitable):
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


comptime _Ring = SpscRing[_Pkt]


struct _Run(Copyable, Movable):
    """One measurement: the nanoseconds it took and the operations it timed."""

    var ns: Int
    var ops: Int

    def __init__(out self, ns: Int, ops: Int):
        self.ns = ns
        self.ops = ops

    def ns_per_op(self) -> Float64:
        return Float64(self.ns) / Float64(self.ops)


def _mk(i: Int) -> _Pkt:
    var p = _Pkt()
    p.span_id = UInt64(i)
    p.ts_ns = UInt64(i)
    return p^


def _check_caps(caps: List[Int]) raises:
    """Raises naming the first capacity that is not a power of two from 1 to
    MAX_CAP (each is at least 1 already: `BenchArgs` holds that)."""
    for i in range(len(caps)):
        var c = caps[i]
        if c > MAX_CAP or (c & (c - 1)) != 0:
            raise Error(
                "komira_bench: spsc_ring --caps takes powers of two from 1 to "
                + String(MAX_CAP)
                + ", got "
                + String(c)
            )


struct _Rounds(Copyable, Movable):
    """The timed rounds of push_only: `full` rounds of `cap` pushes, then one
    round of `last` (`total_ops % cap`) when that is not zero. They add up to
    `total_ops`. Three counters whatever the count: nothing is stored per
    round."""

    var cap: Int
    var full: Int
    var last: Int

    def __init__(out self, cap: Int, total_ops: Int):
        self.cap = cap
        self.full = total_ops // cap
        self.last = total_ops % cap

    def count(self) -> Int:
        """How many rounds there are."""
        if self.last != 0:
            return self.full + 1
        return self.full

    def size(self, r: Int) -> Int:
        """The pushes of round `r` (from 0, below `count()`)."""
        if r < self.full:
            return self.cap
        return self.last


def _push_only(cap: Int, total_ops: Int) raises -> _Run:
    var ring = _Ring(cap, OVERFLOW_BLOCK)
    var pkt = _mk(7)
    # One untimed round first, so the slots are written once before the clock.
    for _ in range(cap):
        _ = ring.try_push(pkt)
    for _ in range(cap):
        _ = ring.try_pop()
    var rounds = _Rounds(cap, total_ops)
    var ns = 0
    var ops = 0
    for r in range(rounds.count()):
        var n = rounds.size(r)
        var t0 = Int(perf_counter_ns())
        for _ in range(n):
            _ = ring.try_push(pkt)
        ns += Int(perf_counter_ns()) - t0
        ops += n
        for _ in range(n):
            _ = ring.try_pop()
    return _Run(ns, ops)


def _drop_push(cap: Int, total_ops: Int) raises -> _Run:
    var ring = _Ring(cap, OVERFLOW_DROP)
    var pkt = _mk(7)
    # Filled to the ring's own capacity, so every timed push is refused.
    for _ in range(ring.capacity()):
        _ = ring.try_push(pkt)
    var before = Int(ring.overflow_dropped_count())
    var t0 = Int(perf_counter_ns())
    for _ in range(total_ops):
        _ = ring.try_push(pkt)
    var ns = Int(perf_counter_ns()) - t0
    return _Run(ns, Int(ring.overflow_dropped_count()) - before)


struct _Shared(Movable):
    var t0: AtomicI64
    var t1: AtomicI64
    var popped: AtomicI64

    def __init__(out self):
        self.t0 = AtomicI64(Int64(0))
        self.t1 = AtomicI64(Int64(0))
        self.popped = AtomicI64(Int64(0))


struct _Body[ro: MutOrigin, so: MutOrigin](SpawnJoinBody):
    var ring: Pointer[_Ring, Self.ro]
    var shared: Pointer[_Shared, Self.so]
    var n: Int

    def __init__(
        out self,
        ring: Pointer[_Ring, Self.ro],
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
            _ = self.shared[].popped.fetch_add(Int64(got))


def _push_pop(cap: Int, total_ops: Int) raises -> _Run:
    var ring = _Ring(cap, OVERFLOW_BLOCK)
    var shared = _Shared()
    var body = _Body(Pointer(to=ring), Pointer(to=shared), total_ops)
    spawn_join(body, 2)
    return _Run(
        Int(shared.t1.load() - shared.t0.load()), Int(shared.popped.load())
    )


def _line(op: String, cap: Int, run: _Run, hide: Bool) raises -> String:
    var params = List[Param]()
    params.append(Param("cap", cap))
    return result_line(op, params, "ns_per_op", run.ns_per_op(), hide)


def _bench_lines(cap: Int, args: BenchArgs) raises -> List[String]:
    """The three `RESULT` lines of one capacity, in the order push_only,
    push_pop, drop_push."""
    var n = args.total_ops
    var hide = args.hide_times
    var lines = List[String]()
    lines.append(_line("push_only", cap, _push_only(cap, n), hide))
    lines.append(_line("push_pop", cap, _push_pop(cap, n), hide))
    lines.append(_line("drop_push", cap, _drop_push(cap, n), hide))
    return lines^


def _parse(arguments: List[String]) raises -> BenchArgs:
    """`parse_args` with spsc_ring's own capacity rule held in argument order.

    The harness checks each argument in turn; this program also requires each
    `--caps` to name powers of two from 1 to MAX_CAP. So that a bad `--caps`
    is refused where it stands, before a later argument is read and even when
    a later `--caps` replaces it, each argument is read as the end of the
    command line so far: the first prefix that is refused, by the harness or
    by `_check_caps` on the `--caps` that ends it, is the error. (A command
    line is a few arguments; reading it once per argument costs nothing.)"""
    var seen = List[String]()
    for i in range(len(arguments)):
        seen.append(arguments[i])
        var so_far = parse_args(seen, DEFAULT_TOTAL_OPS, default_caps())
        if arguments[i].startswith("--caps="):
            _check_caps(so_far.caps)
    return parse_args(arguments, DEFAULT_TOTAL_OPS, default_caps())


def program_lines(arguments: List[String]) raises -> List[String]:
    """What the `spsc_ring` program prints for `arguments` (the command line
    without the program name): the usage text for `--help`, else the lines of
    each capacity in the order given, a repeated capacity measured again.
    Raises on an argument `parse_args` refuses, and on a capacity that is not a
    power of two from 1 to MAX_CAP, `--help` or not, before anything is
    measured. The arguments are checked in order and the first refused one is
    the error, a `--caps` that a later one replaces included (`_parse`)."""
    var args = _parse(arguments)
    var out = List[String]()
    if args.help:
        out.append(usage("spsc_ring", DEFAULT_TOTAL_OPS, default_caps()))
        return out^
    for i in range(len(args.caps)):
        var lines = _bench_lines(args.caps[i], args)
        for j in range(len(lines)):
            out.append(lines[j])
    return out^


def run_program(arguments: List[String]) raises:
    """The body of the `spsc_ring` program: prints `program_lines(arguments)`
    one per line."""
    var lines = program_lines(arguments)
    for i in range(len(lines)):
        print(lines[i])
