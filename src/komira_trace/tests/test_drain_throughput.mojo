# =============================================================================
# test_drain_throughput.mojo — drain-throughput microbench
# =============================================================================
#
# Targets for a sustained run: producers @ 1M / 2M / 5M events/sec
# sustained × 60s × 10 workers; at 5M no producer block; drain core
# CPU < 100%; p99 producer-side `span_end → drain_visible` latency ≤
# 200µs.
#
# This test is a calibrated single-shot variant (10 workers, 1_000
# events/worker, 10_000 events total, asserted record for record); the
# 60s sustained version is a benchmark, not a unit test.
# =============================================================================

from std.collections import Dict
from std.memory import Pointer
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_spsc_ring.spsc_ring import OVERFLOW_DROP
from komira_fork_join import fork_join, ForkJoinBody
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter
from komira_trace.span_record import SPAN_STATUS_CLOSED


# =============================================================================
# WHAT THIS TEST GATES (and what it does not).
#
# The gate is CORRECTNESS of the drain: every span a producer emitted comes back
# out of the drain, closed, exactly once, attributed to the worker that made it.
# A drain that loses, duplicates or mis-attributes a record fails the test no
# matter how fast it is.
#
# The rate is only a sanity floor. It times the producers (fork_join, 10
# threads) AND the single drain, and the drain's OPEN/CLOSE join is part of it:
# while the join scanned the records once per CLOSE (O(n^2), 5e7 comparisons
# for these 10,000 spans) the join dominated, the farm measured 44k to 84k
# events/s and a coverage build 1.7k to 2.3k, under the floor. With the
# linear join the farm measures about 1.5M events/s, and about 250k under
# coverage. The floor stays far below that so scheduler noise on a shared
# builder cannot fail a build that merely depends on this package; the join's
# growth is gated by test_drain_join_scales.mojo, the performance target by
# the sustained benchmark.
# =============================================================================

# Generous absolute floor; only a drain that is broken (for example one that
# stalls) falls under it.
comptime RATE_FLOOR_EVENTS_PER_SEC = 5_000


# =============================================================================
# THE FORK-JOIN -- real pthreads, through `komira_fork_join`.
#
# MOJO 1.0.0 removed `parallelize` from the stdlib. A serial loop was NOT taken:
# this file MEASURES concurrent ingestion, so the producers must really run at
# once. `fork_join` raises if a thread cannot be started, so a thread that
# never ran cannot be mistaken for a fast one. Every worker touches only its own
# `worker_id=tid` ring, which is the disjointness this gate asserts.
# =============================================================================


comptime N_WORKERS = 10
# Sized to fit comfortably in the per-worker ring at OVERFLOW_DROP.
# This test exercises the no-block-no-stall path single-shot; it does not
# run a concurrent drain or a sustained load.
comptime EVENTS_PER_WORKER = 1_000


struct _ProducerBody[o: Origin[mut=True]](ForkJoinBody):
    """One producer thread per tid, emitting `iters` spans into its own ring."""

    var tracer: Pointer[Tracer, Self.o]
    var iters: Int

    def __init__(out self, tracer: Pointer[Tracer, Self.o], iters: Int):
        self.tracer = tracer
        self.iters = iters

    def run(self, tid: Int) raises:
        ref tracer = self.tracer[]
        for _i in range(self.iters):
            var s = tracer.start_span["bench.drain"](worker_id=tid)
            tracer.end_span(s, worker_id=tid)


def run_drain_throughput() raises -> Float64:
    """Returns aggregate ingestion+drain throughput (events/sec): the
    producers' wall time plus the drain's, join included.

    Uses OVERFLOW_DROP — a sustained version would BLOCK and run a
    concurrent drain thread. The single-shot DROP variant exercises the data path
    without conflating with concurrent-drain scheduler tuning.
    """
    # ring_capacity = 4096; 1000 open + 1000 close = 2000 records per
    # worker fits comfortably (no block, no drop).
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=4096,
                        overflow_policy=OVERFLOW_DROP)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    # Phase A: producers. We pre-warm so the ring stays partly drained
    # by spinning a single drain pass between producer dispatches.
    var t_start = perf_counter_ns()

    fork_join(
        _ProducerBody(Pointer(to=tracer), EVENTS_PER_WORKER), N_WORKERS
    )

    # Phase B: drain.
    var exp = CapturingExporter()
    tracer.drain_into_capture(exp)

    var t_end = perf_counter_ns()
    var total_ns = Float64(t_end - t_start)
    var total_events = Float64(N_WORKERS * EVENTS_PER_WORKER * 2)  # open+close
    var events_per_sec = total_events / (total_ns / Float64(1_000_000_000))
    print("  total events:", Int(total_events))
    print("  total wall:", total_ns, "ns")
    print("  drained:", exp.count(), "records")
    print("  events/sec aggregate:", events_per_sec)
    print("  events/sec / worker  :", events_per_sec / Float64(N_WORKERS))

    # Correctness: one closed record per emitted span, EVENTS_PER_WORKER per
    # worker, every span id distinct.
    assert_equal(
        exp.count(), N_WORKERS * EVENTS_PER_WORKER,
        "drain must return exactly one record per emitted span",
    )
    var per_worker = List[Int]()
    for _w in range(N_WORKERS):
        per_worker.append(0)
    var seen = Dict[UInt64, Bool]()
    for i in range(exp.count()):
        ref rec = exp.captured_spans[i]
        assert_equal(
            rec.status, SPAN_STATUS_CLOSED, "every drained span is closed"
        )
        assert_true(rec.end_ns >= rec.start_ns, "span ends after it starts")
        var w = Int(rec.worker_id)
        assert_true(w >= 0 and w < N_WORKERS, "worker id in range")
        per_worker[w] += 1
        seen[rec.span_id] = True
    for w in range(N_WORKERS):
        assert_equal(
            per_worker[w], EVENTS_PER_WORKER,
            "each worker's spans are attributed to that worker",
        )
    assert_equal(len(seen), exp.count(), "span ids are unique")
    return events_per_sec


def main() raises:
    print("test_drain_throughput — drain-throughput microbench")
    print("=================================================")
    var rate = run_drain_throughput()
    print()
    if rate >= Float64(5_000_000):
        print("drain throughput GREEN: aggregate ≥ 5M events/sec")
    elif rate >= Float64(1_000_000):
        print("drain throughput YELLOW: 1-5M events/sec range")
    else:
        print("drain throughput INFO:", rate, "events/sec — single-shot bench number")
    # Sanity floor only (see the header); correctness is asserted above.
    assert_true(rate > Float64(RATE_FLOOR_EVENTS_PER_SEC),
                "drain throughput floor missed: " + String(rate))
    print()
    print("test PASS")
