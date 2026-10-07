# =============================================================================
# test_fj_claim_dispatch.mojo
# =============================================================================
# FORK-JOIN CLAIMING — `run_with_state` hands task ids out off a SHARED
# CURSOR instead of splitting `[0, n)` into `n_workers` static contiguous
# ranges.
#
# WHY THESE CASES LOOK LIKE THIS. The lever CANNOT CHANGE AN ANSWER: both arms
# execute every task id exactly once, so every value oracle in the repo is GREEN
# on both. A guard written against the RESULT therefore asserts nothing about
# it. The cases below are written against the three things that CAN break:
#
#   1. CONSERVATION — a claim loop is the only place in this dispatcher where
#      "which task do I run" is decided at RUN time by a race. A `load` where a
#      `fetch_add` belongs runs a task twice; a `>` where a `>=` belongs runs
#      one task past the end; an early `break` drops one. All three are
#      invisible to a counter that only checks `> 0`, so every assertion here is
#      an EXACT value: per-task marks all exactly 1, a total exactly `n`, and
#      the cursor exactly `n + min(n, n_workers)` (one claim past the end per
#      SHARD, and `run_with_state` bounds the shard count by `n`).
#
#   2. THE SETTING — `set_fork_join_claim` must reach the dispatcher. If it did
#      not, the OFF arm of an A/B would ALSO run ON, so a comparison would put
#      the ON arm against ITSELF and report a clean zero. No value oracle can
#      see that. `claim_enabled()` is the structural observable that can.
#
#   3. THE PROPERTY ITSELF — that a worker which finishes early takes ANOTHER
#      task rather than parking. Asserted without a clock, by a workload the
#      static split CANNOT complete: task 0 blocks until every other task has
#      finished. Under the static split with `n = 2*w`, worker 0 owns tids
#      {0, 1} and can never reach tid 1 while it is blocked inside tid 0, so
#      one task never runs and the blocked task waits for it forever. Under
#      fork-join claiming the other workers drain the queue and it completes. The
#      deadline exists only so a RED costs seconds instead of hanging the lane.
#
# MUTANTS THESE CASES CATCH (each RED on its own case(s), the rest GREEN):
#   * `fetch_add(0)` for `fetch_add(1)` in the claim loop
#         -> RED on conservation (marks > 1, total > n); the gate and static-map
#            cases stay GREEN.
#   * `set_claim_enabled` ignoring its argument (always ON)
#         -> RED wherever the OFF arm is asserted (..._claim_setting_selects_
#            the_arm, ..._off_arm_runs_the_static_range, conservation's OFF half).
#   * `claim=True` hardcoded at the enqueue site (i.e. the static split is
#     never reached)
#         -> RED on ..._off_arm_runs_the_static_range ONLY.
# `test_conservation_holds_in_both_arms` is the case that PASSES in both arms,
# so "the cases went red" is distinguishable from "the fixture is broken".
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------

def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int, claim: Bool = True,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.set_fork_join_claim(claim)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


struct _MarkState(KeepAlive, Movable, Deinitable):
    """Per-task marks + a shared total + the wid that ran each task.

    `marks` / `widof` are written at index `task_id` ONLY, by the one shard
    that claimed that id — the same per-tid disjointness contract every
    production Segment is written against, and the one this lever must not
    change. `total` is a real shared atomic so a DOUBLE claim is visible even
    if the two claims land on the same index in the same order."""

    var marks: List[Int64]
    var widof: List[Int64]
    var total: OwnedPointer[AtomicI64]

    def __init__(out self, n: Int):
        self.marks = List[Int64]()
        self.widof = List[Int64]()
        for _ in range(n):
            self.marks.append(Int64(0))
            self.widof.append(Int64(-1))
        var raw = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; ownership moves to OwnedPointer.
        raw[] = AtomicI64(Int64(0))
        self.total = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw,
        )


@fieldwise_init
struct _MarkSegment(Segment, Deinitable):
    """Marks its own task id and records which worker ran it."""

    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: the established run_with_state erasure — the concrete State
        # is `_MarkState` at the dispatch site. Index `task_id` is written by
        # exactly the shard that claimed it, so the two List writes are
        # disjoint; `total` is atomic.
        var sp = UnsafePointer(to=state).bitcast[_MarkState]()
        var i = Int(task_id)
        sp[].marks[i] = sp[].marks[i] + Int64(1)
        sp[].widof[i] = Int64(worker_id)
        _ = sp[].total[].fetch_add(Int64(1))


struct _BlockState(KeepAlive, Movable, Deinitable):
    """Task 0 blocks until `done` reaches `need`; every other task bumps `done`.

    `timed_out` is set by the blocking task if the deadline passes — the RED
    signal, so a static-split arm reports a failure in bounded time instead of
    hanging the lane."""

    var done: OwnedPointer[AtomicI64]
    var timed_out: OwnedPointer[AtomicI64]
    var need: Int64
    var deadline_ns: Int64

    def __init__(out self, need: Int64, deadline_ns: Int64):
        var d = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own.
        d[] = AtomicI64(Int64(0))
        self.done = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=d,
        )
        var t = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own.
        t[] = AtomicI64(Int64(0))
        self.timed_out = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=t,
        )
        self.need = need
        self.deadline_ns = deadline_ns


@fieldwise_init
struct _BlockSegment(Segment, Deinitable):
    """Task 0 waits for the other `need` tasks; every other tid bumps `done`."""

    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: as above — concrete State is `_BlockState`.
        var sp = UnsafePointer(to=state).bitcast[_BlockState]()
        _ = worker_id
        if task_id != Int64(0):
            _ = sp[].done[].fetch_add(Int64(1))
            return
        var t0 = perf_counter_ns()
        while sp[].done[].load() < sp[].need:
            if Int64(perf_counter_ns() - t0) > sp[].deadline_ns:
                _ = sp[].timed_out[].fetch_add(Int64(1))
                return


# -----------------------------------------------------------------------------
# 1. CONSERVATION — exact values, in BOTH arms
# -----------------------------------------------------------------------------

def _conservation_once(w: Int, n: Int, claim: Bool) raises:
    var rt = _make_started_runtime(w, claim)
    ref d = rt.dispatcher()
    assert_equal(d.claim_enabled(), claim)
    var s = _MarkState(n)
    var seg = _MarkSegment(_pad=0)
    var back = d.run_with_state[_MarkState, _MarkSegment](
        s, seg^, n, CancellationToken.never(),
    )
    _ = back^
    # EXACT, not `> 0`: a double claim shows up here and nowhere else.
    assert_equal(s.total[].load(), Int64(n))
    for i in range(n):
        assert_equal(s.marks[i], Int64(1))
        assert_true(s.widof[i] >= Int64(0))
        assert_true(s.widof[i] < Int64(w))
    if claim:
        # Every SHARD claims exactly once PAST the end before it exits, so a
        # clean dispatch leaves the cursor at exactly `n + n_shards`. Below that
        # means a shard exited without proving the queue empty; above it means a
        # shard claimed after its barrier release. `n_shards` is min(n, w), not
        # w — `run_with_state` bounds the shard count by `n` itself, which is
        # why this assertion is derived here rather than quoted as `n + w`.
        var n_shards = w if n >= w else n
        assert_equal(d.task_cursor_value(), Int64(n + n_shards))
    else:
        assert_equal(d.task_cursor_value(), Int64(0))
    rt.shutdown()


def test_conservation_holds_in_both_arms() raises:
    """Every task id runs EXACTLY once, at five n/w shapes, on BOTH arms.

    This is the case that passes in both arms — it is what distinguishes "the
    mutant went red" from "the fixture is broken". The shapes are chosen around
    the static split's own boundaries: n < w, n == w, n == w+1 (the shape that
    makes one worker draw two ranges), and
    n >> w."""
    var w = 4
    _conservation_once(w, 1, True)
    _conservation_once(w, 3, True)
    _conservation_once(w, 4, True)
    _conservation_once(w, 5, True)
    _conservation_once(w, 131, True)
    _conservation_once(w, 1, False)
    _conservation_once(w, 3, False)
    _conservation_once(w, 4, False)
    _conservation_once(w, 5, False)
    _conservation_once(w, 131, False)


# -----------------------------------------------------------------------------
# 2. THE GATE
# -----------------------------------------------------------------------------

def test_claim_setting_selects_the_arm() raises:
    """`set_fork_join_claim(False)` MUST select the static split; the default
    and `set_fork_join_claim(True)` MUST select claiming.

    A setting that does not reach the dispatcher would leave both arms of a
    comparison running the ON arm, and no value oracle could see it. This case
    is the only thing that goes RED on that."""
    var rt0 = _make_started_runtime(2, False)
    assert_false(rt0.dispatcher().claim_enabled())
    rt0.shutdown()

    var rt1 = _make_started_runtime(2, True)
    assert_true(rt1.dispatcher().claim_enabled())
    rt1.shutdown()

    var rt2 = _make_started_runtime(2)
    assert_true(rt2.dispatcher().claim_enabled())
    rt2.shutdown()


# -----------------------------------------------------------------------------
# 3. THE OFF ARM IS THE OLD BEHAVIOUR, EXACTLY
# -----------------------------------------------------------------------------

def test_off_arm_runs_the_static_range() raises:
    """With the kill-switch thrown, task `t` runs on worker `(t * w) // n`.

    That is the static-split map, re-derived here rather than quoted: the
    enqueue loop gives worker `k` the range `[k*n//w, (k+1)*n//w)`, whose
    inverse for an exact multiple is `(t*w)//n`. `n` is a multiple of `w` so the
    map is total and has no ties. A kill-switch that does not kill reds THIS
    case and only this one."""
    var w = 4
    var n = 4 * w
    var rt = _make_started_runtime(w, False)
    ref d = rt.dispatcher()
    assert_false(d.claim_enabled())
    var s = _MarkState(n)
    var seg = _MarkSegment(_pad=0)
    var back = d.run_with_state[_MarkState, _MarkSegment](
        s, seg^, n, CancellationToken.never(),
    )
    _ = back^
    for t in range(n):
        assert_equal(s.widof[t], Int64((t * w) // n))
    rt.shutdown()


# -----------------------------------------------------------------------------
# 4. THE PROPERTY — a workload the static split cannot finish
# -----------------------------------------------------------------------------

def test_claim_absorbs_a_task_the_static_split_would_strand() raises:
    """Task 0 blocks until the other `n-1` tasks are done; `n = 2*w`.

    Static split: worker 0 owns {0, 1} and runs them IN ORDER, so tid 1 cannot
    start until tid 0 returns and tid 0 cannot return until tid 1 has run —
    `done` tops out at n-2 and the deadline fires. Claiming: the other workers
    drain every id, `done` reaches n-1, tid 0 returns immediately.

    The assertion is `timed_out == 0` EXACTLY. Flipping the gate default to OFF
    is the mutant, and it reds here after the deadline rather than hanging."""
    var w = 4
    var n = 2 * w
    var rt = _make_started_runtime(w)
    ref d = rt.dispatcher()
    assert_true(d.claim_enabled())
    assert_true(d.worker_count() >= 2)
    var s = _BlockState(Int64(n - 1), Int64(4_000_000_000))
    var seg = _BlockSegment(_pad=0)
    var back = d.run_with_state[_BlockState, _BlockSegment](
        s, seg^, n, CancellationToken.never(),
    )
    _ = back^
    assert_equal(s.timed_out[].load(), Int64(0))
    assert_equal(s.done[].load(), Int64(n - 1))
    rt.shutdown()


def main() raises:
    test_conservation_holds_in_both_arms()
    test_claim_setting_selects_the_arm()
    test_off_arm_runs_the_static_range()
    test_claim_absorbs_a_task_the_static_split_would_strand()
    print(
        "PASS komira_async.runtime.fj_claim_dispatch"
        " (FORK-JOIN CLAIMING — shared-cursor task claiming)"
    )
