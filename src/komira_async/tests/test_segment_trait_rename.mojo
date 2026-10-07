# =============================================================================
# test_segment_trait_rename.mojo -- Segment trait rename sanity
# =============================================================================
#
# Verifies:
#   1. `Segment` resolves from its canonical home in
#      `komira_async_api.worker_pool_traits`.
#   2. A struct annotated `Segment, Deinitable` compiles
#      and satisfies run_with_state's `T: Segment` bound.
#
# 7 DELETED the backward-compat `LightTask` alias (final step
# of the Segment rename). The alias-still-resolves subtest was removed
# in concert with that deletion; the remaining subtest keeps
# ongoing coverage for the Segment trait name.
#
# The import names the canonical trait location (the substrate's own
# `local_dispatcher.mojo` imports it the same way), not a re-export. Dispatch now
# goes through `PerCoreAsyncRuntime[NoopSink].dispatcher()`.
#
# This is a LANDING test -- confirms the rename is mechanical and safe,
# nothing more.
# =============================================================================

from std.memory import UnsafePointer
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_true

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


struct BumpState(KeepAlive):
    var hits: AtomicI64

    def __init__(out self):
        self.hits = AtomicI64(Int64(0))


# Task declared via the NEW name (Segment).
@fieldwise_init
struct SegmentImplTask(Segment, Deinitable):
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[BumpState]()
        _ = sp[].hits.fetch_add(Int64(1))


def test_segment_trait_dispatches() raises:
    """New-name task via run_with_state dispatches correctly."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var state = BumpState()
    var ct = CancellationToken.new()

    var t = SegmentImplTask(0)
    ref disp = runtime.dispatcher()
    var returned = disp.run_with_state[BumpState, SegmentImplTask](
        state, t^, 4, ct.clone()
    )
    _ = returned^

    assert_equal(state.hits.load(), Int64(4))
    print("  test_segment_trait_dispatches PASS")


def main() raises:
    test_segment_trait_dispatches()
    print("PASS")
