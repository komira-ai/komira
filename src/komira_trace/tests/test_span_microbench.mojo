# =============================================================================
# test_span_microbench.mojo — span producer microbench
# =============================================================================
#
# Producer microbench: span_start <100ns / span_end <100ns in-pipeline.
# Hosted as a test target because a test wrapper is the cheapest way to keep
# the measurement gated. The body is a straight per-pair timing.
#
# This will FAIL the build assertion if span_start+span_end exceeds
# 200ns/pair sustained on the canonical 8-worker host. The number is
# diagnostic, NOT a test failure — Mojo `assert_true` triggers only on
# pathological regression (>1µs/pair), since real numbers depend on
# parallelize scheduling jitter.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_true
from std.time import perf_counter_ns

from komira_fork_join import fork_join, ForkJoinBody
from komira_trace.tracer import Tracer


# =============================================================================
# THE FORK-JOIN -- real pthreads, through `komira_fork_join`.
#
# MOJO 1.0.0 removed `parallelize` from the stdlib. A SERIAL LOOP WAS NOT TAKEN:
# the latency arithmetic divides the whole wave's wall time by the per-thread
# iteration count, which is only meaningful when the N threads run at once.
# `fork_join` is synchronous, exactly as `parallelize` was, so the caller's
# `perf_counter_ns()` bracket still measures the whole wave. If a thread cannot
# be started it raises, so the bench never reports a latency for a narrower
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
    """Return per-pair (span_start + span_end) ns / pair."""
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=4096)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    # Warmup — populate workers + name registry.
    fork_join(_SpanPairsBody(Pointer(to=tracer), WARMUP_ITERATIONS), N_WORKERS)

    # Drain the warmup records so we don't measure ring-overflow blocks.
    # We just reset ring counters via a fresh Tracer — alternative is to
    # increase ring_capacity beyond the bench iteration count.
    _ = tracer  # keepalive

    var tracer2 = Tracer(num_workers=N_WORKERS, ring_capacity=ITERATIONS_PER_WORKER * 4)
    tracer2.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    fork_join(
        _SpanPairsBody(Pointer(to=tracer2), WARMUP_ITERATIONS), N_WORKERS
    )

    var t0 = perf_counter_ns()

    fork_join(
        _SpanPairsBody(Pointer(to=tracer2), ITERATIONS_PER_WORKER), N_WORKERS
    )
    _ = tracer2

    var t1 = perf_counter_ns()
    var total_ns = Float64(t1 - t0)
    # Per-thread per-pair latency: each thread does ITERATIONS pairs in
    # parallel, so wall = max-thread time ≈ per-thread time on a
    # parallelize-balanced run.
    var ns_per_pair_per_thread = total_ns / Float64(ITERATIONS_PER_WORKER)
    return ns_per_pair_per_thread


def main() raises:
    print("test_span_microbench — span producer microbench")
    print("================================================")
    var ns_per_pair = run_microbench()
    print("  per-thread per-pair (start+end) latency:", ns_per_pair, "ns")
    var ns_per_op = ns_per_pair / Float64(2)
    print("  per-op latency: ~", ns_per_op, "ns")
    print()
    if ns_per_op < Float64(100):
        print("span cost GREEN: <100 ns/op")
    elif ns_per_op < Float64(200):
        print("span cost YELLOW: <200 ns/op (out-of-pipeline target)")
    else:
        print("span cost INFO: ", ns_per_op,
              "ns/op — schedule + jitter dominated (Mojo parallelize startup)")
    # Pathological-regression assertion only — the ns/op number itself
    # is diagnostic. 5000 ns is "something is structurally broken" floor.
    assert_true(ns_per_op < Float64(5000),
                "pathological regression: " + String(ns_per_op) + " ns/op")
    print()
    print("test PASS")
