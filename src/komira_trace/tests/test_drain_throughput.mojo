# =============================================================================
# test_drain_throughput.mojo — drain correctness under concurrent producers
# =============================================================================
#
# Targets for a sustained run: producers @ 1M / 2M / 5M events/sec
# sustained × 60s × 10 workers; at 5M no producer block; drain core
# CPU < 100%; p99 producer-side `span_end → drain_visible` latency ≤
# 200µs.
#
# This test is a single-shot variant (10 workers, 1_000 events/worker, 10_000
# events total, asserted record for record) that reads no clock; the 60s
# sustained version is a benchmark, not a unit test.
# =============================================================================

from std.collections import Dict
from std.memory import Pointer
from std.testing import assert_equal, assert_true

from komira_spsc_ring.spsc_ring import OVERFLOW_DROP
from komira_fork_join import fork_join, ForkJoinBody
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter
from komira_trace.span_record import SPAN_STATUS_CLOSED
from komira_trace.testing import MockClock


# =============================================================================
# WHAT THIS TEST GATES (and what it does not).
#
# The gate is CORRECTNESS of the drain: every span a producer emitted comes back
# out of the drain, closed, exactly once, attributed to the worker that made it.
# A drain that loses, duplicates or mis-attributes a record fails the test no
# matter how fast it is.
#
# A stalled drain is caught by the build action's timeout, not by this test:
# the old events/sec floor was a speed check and is gone. The counters below
# are exact counts written by the producers, the ring and the table, not by
# the test:
#
#   - No producer blocks or drops: after the fork_join wave every worker's ring
#     holds exactly 2 * EVENTS_PER_WORKER packets and reports zero blocked and
#     zero dropped pushes, so a producer that stalled on a full ring (or lost a
#     packet) fails here.
#   - The drain's OPEN/CLOSE join is linear: `Tracer.join_probes()` equals the
#     number of CLOSE packets. The table counts each record read as a probe, so
#     a join that scans the records once per CLOSE (5e7 comparisons for these
#     10,000 spans) probes far more often. The
#     growth law is also gated at two sizes by test_drain_join_scales.mojo.
#
# The performance target belongs to the sustained benchmark.
# =============================================================================


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


def run_drain_throughput() raises:
    """Runs the producer wave and the drain, and asserts the ring counters,
    the join probe count and every drained record. Reads no clock.

    Uses OVERFLOW_DROP — a sustained version would BLOCK and run a
    concurrent drain thread. The single-shot DROP variant exercises the data path
    without conflating with concurrent-drain scheduler tuning.
    """
    # ring_capacity = 4096; 1000 open + 1000 close = 2000 records per
    # worker fits comfortably (no block, no drop).
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=4096,
                        overflow_policy=OVERFLOW_DROP)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    # A fixed clock, never advanced: the producers only read it, and the
    # stamps are exact instead of wall time.
    tracer.install_mock_clock(MockClock(start_ns=UInt64(777)))

    # Phase A: producers.
    fork_join(
        _ProducerBody(Pointer(to=tracer), EVENTS_PER_WORKER), N_WORKERS
    )

    # No producer blocked or dropped: every worker's ring holds exactly its
    # own OPEN + CLOSE packets.
    for w in range(N_WORKERS):
        assert_equal(
            tracer.ring_size(w), Int64(2 * EVENTS_PER_WORKER),
            "each ring holds the packets of its own worker's spans",
        )
        assert_equal(
            tracer.ring_blocked_count(w), Int64(0), "no producer blocked"
        )
        assert_equal(
            tracer.ring_dropped_count(w), Int64(0), "no packet dropped"
        )

    # Phase B: drain.
    var exp = CapturingExporter()
    tracer.drain_into_capture(exp)

    print("  total events:", N_WORKERS * EVENTS_PER_WORKER * 2)
    print("  drained:", exp.count(), "records")

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
        assert_equal(rec.start_ns, UInt64(777), "start stamped by the clock")
        assert_equal(rec.end_ns, UInt64(777), "end stamped by the clock")
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
    # One join probe per CLOSE packet, one CLOSE per span: a linear join.
    assert_equal(
        tracer.join_probes(), N_WORKERS * EVENTS_PER_WORKER,
        "the drain join probes once per CLOSE packet",
    )


def main() raises:
    print("test_drain_throughput — drain correctness, no clock")
    print("=============================================================")
    run_drain_throughput()
    print()
    print("test PASS")
