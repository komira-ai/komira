# =============================================================================
# test_segment_execution.mojo -- Phase 2E.1 landing test for SegmentExecution
# =============================================================================
#
# Covers (RFC v4 §3.2):
#   1. Construction with (segment_id, op_slot_start, op_slot_end). Zero
#      struct origin params.
#   2. Per-segment metric fields readable + incrementable.
#   3. Dispatch: method-level origins (state_o, pipe_o) + (S, T) trait
#      bounds compile cleanly.
#   4. Dispatch routes correctly: workers receive state + execute.
#   5. Cancel short-circuit: dispatch propagates pool.run_with_state's
#      cancelled error when PipelineExecution is cancelled mid-dispatch.
#
# Reference: spike Repro 2 (zero struct origin), Repro 3 (method-level
# origin dispatch), Repro 9 (@always_inline AOT).
# =============================================================================

from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_true, assert_false

from komira_engine_runtime.hardware_topology import HardwareTopology
from komira_morsel.pipeline_execution import PipelineExecution
from komira_engine_runtime.segment_execution import SegmentExecution

# PERCORE-DIRECT-MIGRATION S1.e: KeepAlive + Segment moved
# to their canonical home in komira_async_api.worker_pool_traits.
# Dispatch routes through PerCoreAsyncRuntime[NoopSink] directly.
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Test fixtures: minimal State + Segment impl
# =============================================================================


struct CounterState(KeepAlive):
    var counter: AtomicI64

    def __init__(out self):
        self.counter = AtomicI64(Int64(0))


@fieldwise_init
struct IncSegment(Segment, Deinitable):
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[CounterState]()
        _ = sp[].counter.fetch_add(Int64(1))


# =============================================================================
# Tests
# =============================================================================


def test_construct_zero_origin() raises:
    """SegmentExecution has zero struct-level origin params -- this just
    verifies it builds without them."""
    var segment = SegmentExecution(Int32(7), Int32(2), Int32(5))
    assert_equal(segment.segment_id, Int32(7))
    assert_equal(segment.op_slot_start, Int32(2))
    assert_equal(segment.op_slot_end, Int32(5))
    assert_equal(segment.source_ns.load(), Int64(0))
    assert_equal(segment.morsel_count.load(), Int64(0))
    print("  test_construct_zero_origin PASS")


def test_metric_fields() raises:
    var segment = SegmentExecution(Int32(0), Int32(0), Int32(4))
    segment.add_source_ns(Int64(100))
    segment.add_operator_ns(Int64(200))
    segment.add_sink_ns(Int64(300))
    segment.add_combine_ns(Int64(400))
    segment.bump_morsel_count()
    segment.bump_morsel_count()
    assert_equal(segment.source_ns.load(), Int64(100))
    assert_equal(segment.operator_ns.load(), Int64(200))
    assert_equal(segment.sink_ns.load(), Int64(300))
    assert_equal(segment.combine_ns.load(), Int64(400))
    assert_equal(segment.morsel_count.load(), Int64(2))
    print("  test_metric_fields PASS")


def test_dispatch_routes_correctly() raises:
    """dispatch routes the task across n workers, incrementing the
    state's counter exactly n times."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var segment = SegmentExecution(Int32(0), Int32(0), Int32(1))
    var state = CounterState()

    # PERCORE-DIRECT-MIGRATION S1.e: SegmentExecution.dispatch
    # takes the substrate dispatcher + cancel_token directly.
    var _ct = CancellationToken.new()
    ref _disp = runtime.dispatcher()
    var returned = segment.dispatch[
        origin_of(state), origin_of(_disp), CounterState, IncSegment
    ](_disp, _ct.clone(), state, IncSegment(0), 8)

    assert_equal(
        state.counter.load(),
        Int64(8),
        "counter should be incremented 8 times",
    )

    # Task is returned to caller (run_with_state convention).
    _ = returned^
    print("  test_dispatch_routes_correctly PASS")


def test_dispatch_zero_n() raises:
    """n=0 dispatch short-circuits cleanly; counter stays at zero."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var segment = SegmentExecution(Int32(0), Int32(0), Int32(1))
    var state = CounterState()

    var _ct = CancellationToken.new()
    ref _disp = runtime.dispatcher()
    var returned = segment.dispatch[
        origin_of(state), origin_of(_disp), CounterState, IncSegment
    ](_disp, _ct.clone(), state, IncSegment(0), 0)

    assert_equal(state.counter.load(), Int64(0))
    _ = returned^
    print("  test_dispatch_zero_n PASS")


def test_pipeline_cancel_flag_is_worker_visible() raises:
    """pipeline.cancel() sets a flag that operators consult at batch
    boundaries. This test verifies the pipeline-level flag wiring on
    the now pool-agnostic PipelineExecution.

    Note: dispatcher.run_with_state uses the per-call CancellationToken;
    a pre-cancelled pipeline-level flag is IGNORED by the dispatch on a
    fresh token. Pipeline-level cancel lives on PipelineExecution and is
    observed by operators that consult it at batch boundaries -- a
    workload-level convention.
    """
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var topology = HardwareTopology(2, 0)
    var pipeline = PipelineExecution(topology.num_workers(), 1)

    pipeline.cancel()
    assert_true(pipeline.is_cancelled(), "cancel() must be visible")

    # Separately verify the substrate is not perturbed by pipeline
    # cancel -- the two flags are independent axes.
    var state = CounterState()
    var segment = SegmentExecution(Int32(0), Int32(0), Int32(1))
    var _ct = CancellationToken.new()
    ref _disp = runtime.dispatcher()
    var returned = segment.dispatch[
        origin_of(state), origin_of(_disp), CounterState, IncSegment
    ](_disp, _ct.clone(), state, IncSegment(0), 2)
    _ = returned^
    assert_equal(
        state.counter.load(),
        Int64(2),
        "pipeline.cancel() must not abort dispatch with a fresh CancellationToken",
    )
    # Pipeline flag still set after the dispatch.
    assert_true(pipeline.is_cancelled())
    print("  test_pipeline_cancel_flag_is_worker_visible PASS")


def test_dispatch_multi_iter() raises:
    """100-iter stress: construct/dispatch/destroy repeatedly to catch any
    leak or lifetime drift."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var state = CounterState()

    var num_iters = 100
    var n_per = 4
    for _ in range(num_iters):
        var segment = SegmentExecution(Int32(0), Int32(0), Int32(1))
        var _ct = CancellationToken.new()
        ref _disp = runtime.dispatcher()
        var returned = segment.dispatch[
            origin_of(state), origin_of(_disp), CounterState, IncSegment
        ](_disp, _ct.clone(), state, IncSegment(0), n_per)
        _ = returned^

    var expected = Int64(num_iters * n_per)
    assert_equal(state.counter.load(), expected)
    print("  test_dispatch_multi_iter PASS")


def main() raises:
    test_construct_zero_origin()
    test_metric_fields()
    test_dispatch_routes_correctly()
    test_dispatch_zero_n()
    test_pipeline_cancel_flag_is_worker_visible()
    test_dispatch_multi_iter()
    print("PASS")
