# =============================================================================
# test_span_microbench.mojo — span producer hot path, counters not clocks
# =============================================================================
#
# WHAT THIS TEST GATES. 8 threads each emit 10,000 start_span/end_span pairs on
# their own ring of one shared Tracer. The properties of the hot path that the
# old "< 5000 ns/op" ceiling stood in for are asserted as counts, which do not
# depend on the builder's speed or load:
#
#   - no blocking ring push: every ring reports zero blocked pushes (the
#     tracer uses the default OVERFLOW_BLOCK policy, so a push that found the
#     ring full would wait) and zero dropped pushes;
#   - exactly two packets per pair: every ring holds 2 * (warm-up + timed)
#     packets, no more (a doubled push) and no fewer (a lost one);
#   - no per-pair registration or stack growth: the name registry holds the
#     one name and every worker's span stack is back at depth 0;
#   - the drain returns one closed record per pair.
#
# The ns/pair the wave took is printed as information; nothing asserts on it.
# This repository has no allocation counter hook, so "no heap allocation per
# span" is not asserted directly: the packets are fixed-size copies into a
# ring whose slot store is allocated once per ring.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_equal
from std.time import perf_counter_ns

from komira_fork_join import fork_join, ForkJoinBody
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter
from komira_trace.span_record import SPAN_STATUS_CLOSED


# =============================================================================
# THE FORK-JOIN -- real pthreads, through `komira_fork_join`.
#
# MOJO 1.0.0 removed `parallelize` from the stdlib. A SERIAL LOOP WAS NOT TAKEN:
# the properties below are about what N threads do to ONE shared Tracer, which
# is only meaningful when the N threads run at once. `fork_join` is synchronous,
# so the caller's `perf_counter_ns()` bracket still measures the whole wave. If
# a thread cannot be started it raises, so the test never reports on a narrower
# width than it claims.
# =============================================================================


struct _SpanPairsBody[o: Origin[mut=True]](ForkJoinBody):
    """Each worker emits `iters` start/end span pairs on its own ring."""

    var tracer: Pointer[Tracer, Self.o]
    var iters: Int

    def __init__(out self, tracer: Pointer[Tracer, Self.o], iters: Int):
        self.tracer = tracer
        self.iters = iters

    def run(self, tid: Int) raises:
        ref tracer = self.tracer[]
        for _i in range(self.iters):
            var s = tracer.start_span["bench.span"](worker_id=tid)
            tracer.end_span(s, worker_id=tid)


comptime N_WORKERS = 8
comptime ITERATIONS_PER_WORKER = 10_000
comptime WARMUP_ITERATIONS = 100


def run_microbench() raises -> Float64:
    """Runs the wave, asserts the hot-path counters, and returns the wave's
    ns per pair per thread (for printing only)."""
    # Sized so one wave never fills a ring: no block, no drop.
    var tracer = Tracer(
        num_workers=N_WORKERS, ring_capacity=ITERATIONS_PER_WORKER * 4
    )
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    # Warmup — populate workers + name registry.
    fork_join(_SpanPairsBody(Pointer(to=tracer), WARMUP_ITERATIONS), N_WORKERS)

    var t0 = perf_counter_ns()
    fork_join(
        _SpanPairsBody(Pointer(to=tracer), ITERATIONS_PER_WORKER), N_WORKERS
    )
    var t1 = perf_counter_ns()

    var pairs_per_worker = WARMUP_ITERATIONS + ITERATIONS_PER_WORKER
    for w in range(N_WORKERS):
        assert_equal(
            tracer.ring_size(w), Int64(2 * pairs_per_worker),
            "exactly one OPEN and one CLOSE packet per pair",
        )
        assert_equal(
            tracer.ring_blocked_count(w), Int64(0), "no push waited on a full ring"
        )
        assert_equal(
            tracer.ring_dropped_count(w), Int64(0), "no push was dropped"
        )
        assert_equal(tracer.depth_of(w), 0, "every span of the worker ended")
    assert_equal(tracer.name_registry_count(), 1, "one name, registered once")

    var exp = CapturingExporter()
    tracer.drain_into_capture(exp)
    assert_equal(
        exp.count(), N_WORKERS * pairs_per_worker, "one record per pair"
    )
    for i in range(exp.count()):
        assert_equal(
            exp.captured_spans[i].status, SPAN_STATUS_CLOSED, "every span closed"
        )

    # Per-thread per-pair latency: each thread does ITERATIONS pairs in
    # parallel, so wall = max-thread time ≈ per-thread time.
    return Float64(t1 - t0) / Float64(ITERATIONS_PER_WORKER)


def main() raises:
    print("test_span_microbench — span producer hot path")
    print("================================================")
    var ns_per_pair = run_microbench()
    print("  per-thread per-pair (start+end) latency:", ns_per_pair, "ns (not asserted)")
    print("  per-op latency: ~", ns_per_pair / Float64(2), "ns (not asserted)")
    print()
    print("test PASS")
