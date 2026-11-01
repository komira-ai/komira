# =============================================================================
# test_streaming_microbench.mojo — micro-bench for per-dispatch wake cost.
# =============================================================================
# Task #122 / Phase D.2: measure the marginal wakeup overhead of the new
# wake-by-address primitive vs the old per-worker semaphore loop.
#
# Methodology: run 1000 back-to-back `pool.run_with_state(state, task, N)`
# calls where each task is empty (just a fetch_add). Per-dispatch wall
# is dominated by:
#   (a) queue push N times
#   (b) wake all workers (this is what we changed)
#   (c) drain on done_sem
#
# The per-dispatch wall - (a) - (c) is the wake cost we're measuring.
# We can't easily isolate (b) from (a)+(c), so the absolute number
# captures all three. Comparing baseline vs D.2 isolates the wake
# delta.
#
# Run:
#   bazel test an internal Bazel target --test_arg=--report-only
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import UnsafePointer
from std.time import perf_counter_ns

from komira_collections.slab import Slab
from komira_engine_runtime.hardware_topology import HardwareTopology

# PERCORE-DIRECT-MIGRATION S1.e: direct substrate. The
# WorkerPool shim is being deleted in S2.
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import (
    KeepAlive,
    Segment,
)


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


struct EmptyState(KeepAlive):
    """Single-counter state for the streaming microbench."""
    var counter: AtomicI64

    def __init__(out self):
        self.counter = AtomicI64(Int64(0))


@fieldwise_init
struct EmptyTask(Segment, Deinitable):
    """Empty task — just records that it ran."""
    var _pad: Int
    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var s = UnsafePointer(to=state).bitcast[EmptyState]()
        _ = s[].counter.fetch_add(Int64(1))


def main() raises:
    print("================================================================")
    print("Streaming microbench — per-dispatch wakeup wall")
    print("================================================================")
    var topo = HardwareTopology.detect()
    var n_workers = topo.num_workers()
    print("Workers:", n_workers)

    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=n_workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()

    comptime N_DISPATCHES = 1000
    comptime TASKS_PER_DISPATCH = 10
    print("Dispatches:", N_DISPATCHES)
    print("Tasks/dispatch:", TASKS_PER_DISPATCH)

    var state = EmptyState()
    var task = EmptyTask(_pad=0)

    ref disp = runtime.dispatcher()

    # Warmup — first dispatch always pays JIT + cache warmup.
    for _ in range(3):
        var task_back = disp.run_with_state[EmptyState, EmptyTask](
            state, task^, TASKS_PER_DISPATCH, ct.clone()
        )
        task = task_back^

    # Measurement loop.
    var t0 = perf_counter_ns()
    for _ in range(N_DISPATCHES):
        var task_back = disp.run_with_state[EmptyState, EmptyTask](
            state, task^, TASKS_PER_DISPATCH, ct.clone()
        )
        task = task_back^
    var t1 = perf_counter_ns()

    var total_ns = Int64(Int(t1)) - Int64(Int(t0))
    var per_dispatch_ns = total_ns // Int64(N_DISPATCHES)
    var per_dispatch_us = per_dispatch_ns // Int64(1000)

    print()
    print("Result:")
    print("  total ns        =", total_ns)
    print("  per-dispatch ns =", per_dispatch_ns)
    print("  per-dispatch us =", per_dispatch_us)
    var expected_count = Int64(N_DISPATCHES) * Int64(TASKS_PER_DISPATCH) + Int64(3 * TASKS_PER_DISPATCH)
    var observed = state.counter.load()
    print("  expected count =", expected_count)
    print("  observed count =", observed)
    if observed != expected_count:
        print("FAIL — counter mismatch")
    else:
        print("PASS — counter matches; per-dispatch", per_dispatch_us, "us")
