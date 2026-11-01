# =============================================================================
# test_wave_uaf_candidate_c.mojo — regression test for the Wave UAF fix.
# =============================================================================
#
# Reproduces the gap6-shape UAF from the Wave 5 Task-trait tcmalloc bug
# via a NestedSegment with List[List[Int]] inner fields (carried on the
# borrowed State) and a stress loop that provokes tcmalloc recycling.
# Under the pre-fix code (before Candidate C), this test reliably lost
# data (slot0_len stayed at 32 instead of growing to 1056) in 20/20
# iterations.
#
# With the pool-owned task buffer + post-drain keepalive in
# `WorkerPool.run_with_state` (which inherited the Task-path Candidate C
# shielding), all 20 iterations complete cleanly.
#
# Phase 2E.7: migrated from `run_owned[T: Task]` to
# `run_with_state[State, T: Segment]` when the legacy `Task` trait +
# `run_owned` were deleted. The gap6-shape coverage is preserved — the
# heap-owning `List[List[Int]]` now lives on the borrowed State, and the
# per-(State, T) trampoline's keepalive branch is the same shield that
# defeated the original UAF.
#
# Bug-fixing protocol: this test guards the fix forever. Any regression
# that weakens the pool-owned pattern or removes the keepalive branch
# will fail this test under JIT or AOT.
# =============================================================================

from std.memory import UnsafePointer
from std.atomic import Atomic

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


struct NestedState(KeepAlive):
    """Gap6-shape State: heap-owning inner fields via List[List[Int]].

    The State is borrowed for the dispatch window; the pool's post-drain
    State-keepalive trampoline anchors the compiler's view of its inner
    heap buffers across the barrier (the same shield that ran_owned used
    for the Task value pre-Phase-2E.7).
    """
    var slots: List[List[Int]]
    var counter: Int  # non-atomic; data race on counter is OK — we
                      # validate the heap buffer's contents, not counter

    def __init__(out self, num_slots: Int):
        self.slots = List[List[Int]]()
        for _ in range(num_slots):
            var s = List[Int]()
            for k in range(32):
                s.append(k)
            self.slots.append(s^)
        self.counter = 0


@fieldwise_init
struct NestedSegment(Segment, Deinitable):
    """Segment that appends 1024 ints to `state.slots[task_id]`. POD body
    (_pad field) — the heap-owning data lives on the borrowed State."""
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[NestedState]()
        var tid = Int(task_id)
        if tid < len(sp[].slots):
            # Many appends = many _realloc calls. If ASAP has dropped
            # the inner List's heap buffer, the next _realloc call
            # inside tcmalloc crashes (or silently corrupts data).
            for k in range(1024):
                sp[].slots[tid].append(k)
            sp[].counter += 1


def test_nested_state_roundtrip() raises:
    """Run a gap6-shape Segment through run_with_state 20x with a tcmalloc
    stress loop between iterations. All iterations must preserve slot
    lengths."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=HardwareTopology(2, 2).num_workers(),
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var lost = 0
    for i in range(20):
        var state = NestedState(num_slots=4)
        var seg = NestedSegment(0)
        var _seg_back = disp.run_with_state[NestedState, NestedSegment](
            state, seg^, 4, ct.clone()
        )
        _ = _seg_back^
        var s0 = len(state.slots[0])
        if s0 != 1056:
            lost += 1
        _ = state^
        # Stress tcmalloc to surface silent UAFs.
        var stress = List[List[Int]]()
        for _ in range(16):
            var s = List[Int]()
            for k in range(256):
                s.append(k)
            stress.append(s^)
        _ = len(stress)
    if lost != 0:
        raise Error(
            "test_nested_state_roundtrip: "
            + String(lost)
            + " / 20 iterations lost data (UAF regression)"
        )
    print("test_nested_state_roundtrip OK (20 iterations clean)")


def main() raises:
    test_nested_state_roundtrip()
    print("All Wave UAF Candidate C tests PASS")
