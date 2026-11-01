# =============================================================================
# test_wave_uaf_batch_shape.mojo — stress test with a Slab-containing State.
# =============================================================================
#
# The original gap6/wave-uaf crash appeared with CollectOpTask[S, O, K]
# which carried a `Slab[O]` field (byte-slab). The minimal NestedState
# test in test_wave_uaf_candidate_c.mojo validates that pool-owned
# dispatch preserves simple heap-owning inner lists. This test adds a
# Slab[InnerOp] field to close the gap — exactly the shape the HMO
# handoff test exercises.
#
# Phase 2E.7: migrated from `run_owned[T: Task]` to
# `run_with_state[State, T: Segment]` when the legacy `Task` trait was
# deleted. The gap6-shape coverage is preserved — Slab[InnerOp] +
# outer List now live on the borrowed State, and the same post-drain
# keepalive trampoline shields both slots from ASAP-destruction.

from std.memory import UnsafePointer

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


@fieldwise_init
struct InnerOp(Movable, Deinitable):
    """Movable inner struct stored inside Slab[InnerOp]."""
    var payload: List[Int]
    var counter: Int


struct BatchState(KeepAlive):
    """State with Slab[InnerOp] field — matches CollectOpTask's shape.

    Lives on the caller's stack, borrowed through run_with_state for the
    dispatch window. The per-State keepalive trampoline anchors both the
    outer Slab byte-storage AND the inner InnerOp.payload List across
    the post-drain barrier.
    """
    var ops: Slab[InnerOp]
    var outer_slots: List[List[Int]]

    def __init__(out self, num_ops: Int):
        self.ops = Slab[InnerOp].create(num_ops)
        for _ in range(num_ops):
            var pl = List[Int]()
            for k in range(32):
                pl.append(k)
            self.ops.append(InnerOp(pl^, 0))
        self.outer_slots = List[List[Int]]()
        for _ in range(num_ops):
            var s = List[Int]()
            for k in range(32):
                s.append(k)
            self.outer_slots.append(s^)


@fieldwise_init
struct BatchSegment(Segment, Deinitable):
    """Segment that appends 1024 ints to both outer-List slot AND inner
    Slab[InnerOp].payload for `task_id`. POD body — heap-owning data
    lives on the borrowed State."""
    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[BatchState]()
        var tid = Int(task_id)
        if tid < len(sp[].outer_slots):
            # Two parallel paths that both hit heap buffers:
            # (a) outer List[List[Int]] slot — outer-struct heap.
            # (b) Slab[InnerOp]'s inner InnerOp.payload — gap6 shape.
            for k in range(1024):
                sp[].outer_slots[tid].append(k)
            var op_ptr = UnsafePointer(to=sp[].ops.get_mut_interior(tid))
            for k in range(1024):
                op_ptr[].payload.append(k)
            op_ptr[].counter += 1


def test_batch_state_roundtrip() raises:
    """Run a BatchState (Slab + outer List) through run_with_state 10x
    with tcmalloc stress between iterations."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=HardwareTopology(2, 2).num_workers(),
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var lost = 0
    for i in range(10):
        var state = BatchState(num_ops=4)
        var seg = BatchSegment(0)
        var _seg_back = disp.run_with_state[BatchState, BatchSegment](
            state, seg^, 4, ct.clone()
        )
        _ = _seg_back^
        var s0 = len(state.outer_slots[0])
        var op0_payload = len(state.ops.get_mut_interior(0).payload)
        if s0 != 1056 or op0_payload != 1056:
            lost += 1
            print("  iter", i, "s0=", s0, "op0_payload=", op0_payload)
        _ = state^
        var stress = List[List[Int]]()
        for _ in range(16):
            var s = List[Int]()
            for k in range(256):
                s.append(k)
            stress.append(s^)
        _ = len(stress)
    if lost != 0:
        raise Error(
            "test_batch_state_roundtrip: "
            + String(lost)
            + " / 10 iterations lost data (UAF regression)"
        )
    print("test_batch_state_roundtrip OK (10 iterations clean)")


def test_two_back_to_back_dispatches() raises:
    """Mimic the HMO-test sequence: dispatch a small-N Segment, then a
    larger-N Segment, both through the same persistent runtime. This
    matches the test 1 → test 2 shape that exposes the unfixed variant."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=HardwareTopology(2, 2).num_workers(),
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()

    # First dispatch — small N.
    var state1 = BatchState(num_ops=4)
    var seg1 = BatchSegment(0)
    var _seg1_back = disp.run_with_state[BatchState, BatchSegment](
        state1, seg1^, 4, ct.clone()
    )
    _ = _seg1_back^
    var s1 = len(state1.outer_slots[0])
    if s1 != 1056:
        raise Error("state1 s0=" + String(s1))
    _ = state1^

    # Allocate between dispatches (drives tcmalloc activity).
    var middle = List[List[Int]]()
    for _ in range(4):
        var s = List[Int]()
        for k in range(25):
            s.append(k)
        middle.append(s^)
    _ = len(middle)

    # Second dispatch — larger N (same shape, bigger).
    var state2 = BatchState(num_ops=8)
    var seg2 = BatchSegment(0)
    var _seg2_back = disp.run_with_state[BatchState, BatchSegment](
        state2, seg2^, 8, ct.clone()
    )
    _ = _seg2_back^
    var s2 = len(state2.outer_slots[0])
    if s2 != 1056:
        raise Error("state2 s0=" + String(s2))
    _ = state2^
    print("test_two_back_to_back_dispatches OK")


def main() raises:
    test_batch_state_roundtrip()
    test_two_back_to_back_dispatches()
    print("All Wave UAF batch-shape tests PASS")
