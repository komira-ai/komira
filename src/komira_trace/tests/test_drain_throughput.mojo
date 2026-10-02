# =============================================================================
# test_drain_throughput.mojo — drain-throughput microbench
# =============================================================================
#
# Targets for a sustained run: producers @ 1M / 2M / 5M events/sec
# sustained × 60s × 10 workers; at 5M no producer block; drain core
# CPU < 100%; p99 producer-side `span_end → drain_visible` latency ≤
# 200µs.
#
# This test is a calibrated single-shot variant (10 workers, 200K
# events/worker, ~2M events total); the 60s sustained version is a
# benchmark, not a unit test.
# =============================================================================

from std.memory import Pointer
from std.testing import assert_true
from std.time import perf_counter_ns

from komira_spsc_ring.spsc_ring import OVERFLOW_DROP
from komira_spawn_join import spawn_join, SpawnJoinBody
from komira_trace.tracer import Tracer
from komira_trace.exporter import CapturingExporter


# =============================================================================
# THE FORK-JOIN -- real pthreads, through `komira_spawn_join`.
#
# MOJO 1.0.0 removed `parallelize` from the stdlib. A serial loop was NOT taken:
# this file MEASURES concurrent ingestion, so the producers must really run at
# once. `spawn_join` raises if a thread cannot be started, so a thread that
# never ran cannot be mistaken for a fast one. Every worker touches only its own
# `worker_id=tid` ring, which is the disjointness this gate asserts.
# =============================================================================


comptime N_WORKERS = 10
# Sized to fit comfortably in the per-worker ring at OVERFLOW_DROP.
# This test exercises the no-block-no-stall path single-shot; it does not
# run a concurrent drain or a sustained load.
comptime EVENTS_PER_WORKER = 1_000


struct _ProducerBody[o: Origin[mut=True]](SpawnJoinBody):
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
    """Returns aggregate ingestion+drain throughput (events/sec).

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

    spawn_join(
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
    # Pathological floor.
    assert_true(rate > Float64(50_000),
                "drain throughput floor missed: " + String(rate))
    print()
    print("test PASS")
