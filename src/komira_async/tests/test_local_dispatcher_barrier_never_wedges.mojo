# =============================================================================
# test_local_dispatcher_barrier_never_wedges.mojo
# =============================================================================
# Dispatch use-after-free: the regression guard for the stranded-charge settlement.
#
# WHAT FIX 6 ACTUALLY CHANGED, and therefore what this pins.
#
# A shard that takes the generation guard's stale-generation guard returns WITHOUT decrementing
# `_in_flight` — deliberately, because that counter may belong to a different
# dispatch and an extra decrement there cascades. The consequence nobody had
# closed: each refusal permanently removes one decrement, so
# `_drain_in_flight_barrier` was waiting for a value the counter could never
# reach. `in_flight=1`, `stale_refusals=1`, every worker queue empty, forever —
# a PERMANENT PROCESS WEDGE, in a fork-join barrier, on the engine's hot path.
#
# Fix 6 changed the barrier's predicate from "the counter is zero" to
#
#     in_flight <= (refusals raised since this dispatch began)
#
# which is the same predicate whenever nothing is refused and is REACHABLE when
# something is. The dispatch then raises, because the refused shard's task range
# never ran and returning a short result silently would be worse than failing.
#
# WHY THIS IS A SEPARATE FILE FROM THE FALSIFIER.
# `test_local_dispatcher_barrier_leak_stress.mojo` asserts
# `stale_shard_refusals_snapshot() == 0` — that no shard is EVER refused. That
# is the real bug and it is STILL RED: a worker still writes the previous
# generation's shard struct back into its pooled `_shard_buf` slot after
# releasing the barrier, and the next generation's shard then reads the reverted
# stamp. That test must stay red until the reversion is fixed; it is the open-bug
# marker and must not be weakened to make a lane green.
#
# THIS test pins the strictly weaker property the stranded-charge settlement does deliver, and it is the
# property whose absence wedged the process:
#
#   * every dispatch TERMINATES. Pre-fix this file does not fail, it HANGS —
#     which is exactly the failure mode being guarded against.
#   * `in_flight_snapshot() == 0` after EVERY dispatch, including the ones that
#     raised. Pre-fix a refused dispatch could not reach this line at all; the
#     stranded charges are now settled inside the barrier, which is what keeps
#     `entry_leftover_snapshot()` meaning what it says for the NEXT dispatch.
#   * a dispatch that loses work SAYS SO. If a refusal ever surfaces as anything
#     other than a raised error, the engine is silently returning short results.
#
# The dispatch shape is the field shape (the same WIDE / NARROW / TINY rotation
# and worker-count churn as the falsifier), because the refusal is a race and
# this guard is only meaningful if it drives the substrate hard enough to hit it.
# It passes whether or not a refusal happens to fire in a given run — the
# assertion is about the OUTCOME of a refusal, not about provoking one.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import OwnedPointer, alloc
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment


comptime _N_WORKERS: Int = 20
comptime _CYCLES: Int = 120


struct _CounterState(KeepAlive, Movable, Deinitable):
    """Task ledger owned by the TEST frame, which outlives every dispatch, so
    reading it after a dispatch is sound whatever happened to the dispatcher's
    stack frames."""

    var _ran: OwnedPointer[AtomicI64]

    def __init__(out self):
        var p = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; ownership transfers to OwnedPointer,
        # whose __del__ frees it.
        p[] = AtomicI64(Int64(0))
        self._ran = OwnedPointer[AtomicI64](unsafe_from_raw_pointer=p)

    def ran(self) -> Int64:
        return self._ran[].load()

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _TickSegment(Segment, Deinitable):
    var _pad: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_CounterState]()
        _ = sp[]._ran[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id

    def __keep_alive(mut self):
        pass


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_invariant_a_refused_shard_never_wedges_the_barrier() raises:
    """A refused shard must surface as a raised error, never as a hung barrier.

    THIS TEST HANGS rather than failing — `_drain_in_flight_barrier`
    waits for `in_flight == 0` while a refusal has permanently removed one
    decrement. That is the regression being guarded: a wedge, not a wrong value.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_N_WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    var w = d.worker_count()
    assert_equal(w, _N_WORKERS, "expected the full field-size compute pool")

    var state = _CounterState()
    var dispatched = 0
    var raised = 0
    var if_all_ran = Int64(0)

    for _c in range(_CYCLES):
        # WIDE (n >> workers) / NARROW (n == workers) / TINY (rewrites slot 0
        # only, leaving every higher `_shard_buf` slot holding the previous
        # generation's bytes) / then a sweep across the worker-count boundary.
        # This is the slot-recycling shape the field core captured.
        for phase in range(4):
            var n: Int
            if phase == 0:
                n = 64
            elif phase == 2:
                n = 1 + (_c % (2 * w))
            else:
                n = w
            var seg = _TickSegment(_pad=Int64(0))
            dispatched += 1
            if_all_ran += Int64(n)
            try:
                var back = d.run_with_state[_CounterState, _TickSegment](
                    state, seg^, n, CancellationToken.never(),
                )
                _ = back^
            except e:
                # A dispatch that loses work MUST say so. Any other error here
                # is a different defect and should not be swallowed.
                assert_true(
                    String(e).find("refused by the stale-generation guard")
                    >= 0,
                    "run_with_state raised something other than the"
                    " stale-generation refusal: " + String(e),
                )
                raised += 1
            # THE PREDICATE. Pre-fix a refused dispatch could not reach
            # this line at all (the barrier never returned); post-fix the
            # stranded charges are settled inside the barrier, so the counter is
            # clean for the next dispatch whether or not this one lost work.
            assert_equal(
                d.in_flight_snapshot(),
                Int64(0),
                "in_flight must be zero after EVERY barrier exit, including"
                " the ones that lost a shard",
            )

    # A settled stranded charge is the difference between this counter meaning
    # "the previous dispatch leaked" and it meaning "the previous dispatch was
    # refused" — two different defects that must not be conflated.
    assert_equal(
        d.entry_leftover_snapshot(),
        Int64(0),
        "no dispatch may begin with a charge left over from the previous one",
    )
    # Work accounting, stated honestly: a clean sweep must be exact; a sweep
    # that raised has LOST the refused shards' ranges and must be short, never
    # over-counted (an over-count would mean a shard ran twice, the UAF face).
    if raised == 0:
        assert_equal(
            state.ran(),
            if_all_ran,
            "with no refusal every task must run exactly once",
        )
    else:
        assert_true(
            state.ran() < if_all_ran,
            "a refused dispatch must LOSE work, not silently complete",
        )
    assert_true(
        state.ran() <= if_all_ran,
        "no task may run twice — an over-count is the double-run/UAF face",
    )
    var tasks_ran = state.ran()
    _ = state^
    _ = rt^
    print(
        "[never-wedges] dispatches=", dispatched,
        " raised=", raised,
        " tasks_ran=", tasks_ran,
        " if_all_ran=", if_all_ran,
    )


def main() raises:
    test_invariant_a_refused_shard_never_wedges_the_barrier()
    print("OK test_local_dispatcher_barrier_never_wedges")
