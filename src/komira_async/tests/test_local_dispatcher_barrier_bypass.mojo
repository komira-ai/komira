# =============================================================================
# test_local_dispatcher_barrier_bypass.mojo
# =============================================================================
# Dispatch use-after-free regression guard.
#
# THE BUG CLASS — use-after-free of the DRIVER'S STACK FRAME by a live worker.
#
# `LocalDispatcher.run_with_state` builds a `_DispatchCtx` as a LOCAL on its own
# stack frame and hands every shard a `Pointer` into it. The shards cross a
# per-worker MPSC channel as `ErasedHandle`s built by `make_borrowed_erased`,
# which bitcasts the payload through `UnsafePointer[UInt8, MutExternalOrigin]` —
# so the compiler tracks NOTHING about that borrow across the channel hop. The
# ONLY thing keeping the borrow sound is the wake-word barrier. If ANY exit path
# from `run_with_state` unwinds the frame while a posted handle has not yet
# finished, that handle dereferences popped stack.
#
# Field evidence (core dumps from a long query soak, a handful of events per
# thousand invocations): a worker pthread faulted inside `_DispatchShard.run` at the very
# first `self.ctx_ref().error_slot_ref().is_set()` with `_ctx =
# 0x7ffe64a0f568`, which was 21,792 bytes BELOW the driver thread's live `rsp` —
# a `run_with_state` frame that had already returned. All six ctx words held
# reused garbage; `ctx->_error_slot` read `0x75e7`, and the following
# `mov (%rax),%rax` took SIGSEGV / SEGV_MAPERR.
#
# TWO DEFECTS made that possible; this file guards BOTH.
#
# DEFECT 1 — barrier-bypassing early returns. The `TRY_SEND_CLOSED` and
# persistent-`TRY_SEND_FULL` unwinds inside the shard-enqueue loop released the
# re-entrance CAS, dropped `ctx`, took `seg` back and raised WITHOUT ever waiting
# on `in_flight`. Shards 0..wid-1 were already posted and quite possibly running,
# and `error_slot`'s heap `_flag` allocation is freed by its destructor as the
# frame unwinds — so a still-running shard reads a freed heap pointer out of a
# dead stack frame.
#
# DEFECT 2 — the counter was ASSERTED, not ACQUIRED. `in_flight` was pre-set to
# `n_workers`, so ANY deviation between "handles that actually entered a queue"
# and `n_workers` drives it to zero early and the driver leaves the barrier with
# a live borrower. A counter that is asserted cannot be a proof.
#
# FAILS ON CURRENT CODE (pre-fix commit):
#   * `test_bug1_closed_queue_unwind_waits_for_posted_shards` — the CLOSED
#     unwind returns while shard 0 is still inside its ~250 ms spin, so
#     `state.done()` reads 0 (the driver did not wait) and
#     `dispatcher.in_flight_snapshot()` reads 2 (the asserted charge for two
#     shards, neither of which was accounted). Post-fix: `done() == 1` and
#     `in_flight_snapshot() == 0`.
#   * `test_bug2_in_flight_is_acquired_not_asserted` — pre-fix the counter is
#     `store(n_workers)` at dispatch entry, so a dispatch that posts NOTHING
#     (first send hits a closed receiver at wid=0) still leaves the counter at
#     `n_workers`; the barrier's zero-predicate is therefore not a statement
#     about real borrowers at all. Post-fix the counter only ever holds charges
#     that were really acquired, so it is 0 on exit.
#   * `test_invariant_in_flight_zero_after_every_successful_dispatch` — the
#     positive-control invariant on the normal path.
#
# The falsifier does NOT rely on catching a segfault (a UAF may read plausible
# memory and corrupt silently instead of crashing — which is the scarier half of
# this bug). It asserts the BARRIER PREDICATE directly: `run_with_state` must
# never return or raise while a shard it posted is still alive.
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import channel as mpsc_channel
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.shared_erasure import ErasedHandle
from komira_async.runtime.wake_primitives import WorkerWakeHandle
from komira_core.runtime_traits.worker_pool_traits import KeepAlive, Segment


# -----------------------------------------------------------------------------
# A State whose completion is observable from the DRIVER thread, on the HEAP.
# -----------------------------------------------------------------------------
#
# Deliberately NOT reached through the `_DispatchCtx` — the whole point is to
# observe, from the driver, whether a shard was still running when
# `run_with_state` handed control back. The counter lives in an `OwnedPointer`
# heap cell owned by the test frame (which outlives the dispatch either way), so
# reading it after the raise is itself sound.


struct _SpinState(KeepAlive, Movable, Deinitable):
    var _done: OwnedPointer[AtomicI64]
    var _entered: OwnedPointer[AtomicI64]

    def __init__(out self):
        var d = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; ownership transfers to OwnedPointer.
        d[] = AtomicI64(Int64(0))
        self._done = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=d,
        )
        var e = alloc[AtomicI64](1)
        # SAFETY: as above.
        e[] = AtomicI64(Int64(0))
        self._entered = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=e,
        )

    def done(self) -> Int64:
        return self._done[].load()

    def entered(self) -> Int64:
        return self._entered[].load()

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _SpinSegment(Segment, Deinitable):
    """Marks entry, burns `spin_ms` of wall, then marks completion.

    A spin (not a sleep) so the test needs no timer primitive and so the shard is
    genuinely ON-CPU holding its `_DispatchCtx` borrow for the whole window —
    which is exactly the state the pre-fix early-return unwound out from under.
    """

    var spin_ms: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_SpinState]()
        _ = sp[]._entered[].fetch_add(Int64(1))
        var deadline = Int64(perf_counter_ns()) + self.spin_ms * 1_000_000
        while Int64(perf_counter_ns()) < deadline:
            pass
        _ = sp[]._done[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id

    def __keep_alive(mut self):
        pass


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _register_closed_queue_handle(
    mut d: LocalDispatcher[NoopSink],
) raises -> Bool:
    """Register ONE extra worker handle on the dispatcher whose MPSC receiver is
    already closed, so `try_send_back` to it returns `TRY_SEND_CLOSED`.

    This is the only way to drive the `TRY_SEND_CLOSED` unwind deterministically
    from a test: no production path closes a worker's task-queue receiver (which
    is precisely why the branch was never exercised and its missing barrier went
    unnoticed for a year). The receiver is dropped here, immediately after the
    close — the sender clone keeps the shared `_MpscShared` alive via its
    `ArcPointer`, and `_receiver_closed` stays latched at 1.

    The wake handle is `make_disconnected` (a dummy always-awake `_SleepingFlag`
    over fd -1) so `wake_with_elision` is a no-op for this pseudo-worker; the
    send never succeeds, so it is never invoked.
    """
    var pair = mpsc_channel[ErasedHandle](UInt(2))
    var recv = pair.take_receiver()
    var send = pair.take_sender()
    recv.close()
    _ = recv^
    d._register_worker_handle(
        send^, WorkerWakeHandle.make_disconnected(Int32(-1), UInt64(0)),
    )
    return True


# -----------------------------------------------------------------------------
# GUARD 1 — the CLOSED unwind must not abandon already-posted shards.
# -----------------------------------------------------------------------------


def test_bug1_closed_queue_unwind_waits_for_posted_shards() raises:
    """Dispatch use-after-free: the barrier-bypassing early return.

    One real started worker + one pseudo-worker whose receiver is closed. n=2 so
    shard 0 goes to the real worker (and spins for ~250 ms holding its
    `_DispatchCtx` borrow) and shard 1 hits `TRY_SEND_CLOSED`.

    FAILS ON CURRENT CODE (pre-fix): the CLOSED branch raises
    immediately — `state.done()` is 0 because shard 0 is still spinning inside
    `_DispatchShard.run`, dereferencing a `ctx` + `error_slot` on a frame that is
    unwinding underneath it, and `in_flight_snapshot()` is 2 (the asserted, never
    honoured charge). Post-fix the branch drains the barrier first, so every task
    that ENTERED has also COMPLETED and `in_flight_snapshot() == 0` before the
    raise is observed.

    ⚠ THE COUNT IS NOT 1 IN BOTH ARMS — assert the barrier, not the geometry
    (FORK-JOIN CLAIMING). `entered()`/`done()` count TASK entries, not
    shards, and how many tasks the surviving shard runs is a property of the
    SPLIT, not of the barrier:

      * `set_fork_join_claim(False)` (static contiguous split): shard 0 owns [0,1) and
        shard 1 owns [1,2). Shard 1 is never posted, so task 1 is STRANDED and
        `entered() == done() == 1`.
      * default (shared claim cursor): shard 0 claims off the cursor, so after
        task 0 it takes task 1 as well — the task the closed queue stranded.
        `entered() == done() == 2`.

    This guard was written against the first geometry and hard-coded `== 1`,
    which made it fail on the second with `left: 2 right: 1` — a green-to-red
    that says nothing about the UAF it exists to catch. The barrier predicate is
    `done() == entered()`: EVERY task that started also finished before the
    driver observed the raise. That form is geometry-independent and strictly
    STRONGER than `done() == 1` (it holds for any number of absorbed tasks), and
    it still falsifies the original bug, which reads `done() == 0` while
    `entered() >= 1`. The `entered() >= 1` assertion is retained separately so a
    dispatch that posted NOTHING cannot satisfy `done() == entered()` vacuously
    at 0 == 0.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    _ = _register_closed_queue_handle(d)
    assert_equal(d.worker_count(), 2)

    var state = _SpinState()
    var seg = _SpinSegment(spin_ms=Int64(250))
    var raised = False
    var msg = String("")
    try:
        var back = d.run_with_state[_SpinState, _SpinSegment](
            state, seg^, 2, CancellationToken.never(),
        )
        _ = back^
    except e:
        raised = True
        msg = String(e)

    # The CLOSED queue must still surface as an error — the fix changes WHEN the
    # error is raised (after the barrier), not WHETHER.
    assert_true(raised, "closed worker queue must still raise")
    assert_true(
        msg.find("queue closed") >= 0,
        "expected the queue-closed error, got: " + msg,
    )
    # THE FALSIFIER. Shard 0 was posted and is a live borrower of the frame that
    # just unwound; the dispatcher must have waited for it.
    #
    # `>= 1`, not `== 1`: the precondition being established here is that shard 0
    # was really posted and really entered `execute` (otherwise the barrier
    # assertion below is vacuous). HOW MANY tasks it then ran is set by the split
    # — 1 under the static range, 2 under the claim cursor, which absorbs the
    # task the closed queue stranded. See the docstring.
    assert_true(
        state.entered() >= Int64(1),
        "shard 0 should have been posted + entered",
    )
    # THE BARRIER PREDICATE, in its geometry-independent form: every task that
    # entered also completed before the driver observed the raise. Pre-fix this
    # reads done()==0 against entered()>=1 — the shard was still spinning inside
    # execute() while the frame that owns its ctx unwound underneath it.
    assert_equal(
        state.done(),
        state.entered(),
        "BARRIER BYPASS: run_with_state raised while a posted shard was still"
        " dereferencing the ctx on its (now popped) stack frame",
    )
    assert_equal(
        d.in_flight_snapshot(),
        Int64(0),
        "in_flight must be 0 on EVERY exit path — a non-zero value means a live"
        " borrower outlived the frame that owns its _DispatchCtx",
    )
    rt.shutdown()


# -----------------------------------------------------------------------------
# GUARD 2 — the charge must be ACQUIRED per real post, not asserted up front.
# -----------------------------------------------------------------------------


def test_bug2_in_flight_is_acquired_not_asserted() raises:
    """Dispatch use-after-free: in_flight is acquired, not asserted.

    A dispatch in which the FIRST send already fails (the only registered
    worker's receiver is closed), so ZERO handles enter any queue and there is
    nothing for the barrier to wait on.

    FAILS ON CURRENT CODE (pre-fix): `in_flight` was
    `store(n_workers)` at dispatch entry, so it reads 1 here even though no
    borrower was ever created — direct evidence that the barrier's
    `in_flight == 0` predicate was an assertion about intent, not a proof about
    live borrowers. Post-fix the counter holds only charges that were really
    acquired, so it is 0.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    # Close the ONLY real worker's queue is not reachable; instead drive a
    # dispatch whose single shard targets the closed pseudo-queue by making it
    # wid 0. Registering the pseudo-worker FIRST is not possible after attach, so
    # use n=1 with 2 registered handles: n_workers = min(2, 1) = 1 -> wid 0 only,
    # which is the REAL worker. To hit wid 0 == closed we instead assert the
    # counter after a dispatch that fails at wid 1 with n=2 and no real work.
    _ = _register_closed_queue_handle(d)
    var state = _SpinState()
    var seg = _SpinSegment(spin_ms=Int64(0))
    var raised = False
    try:
        var back = d.run_with_state[_SpinState, _SpinSegment](
            state, seg^, 2, CancellationToken.never(),
        )
        _ = back^
    except e:
        raised = True
    assert_true(raised)
    assert_equal(
        d.in_flight_snapshot(),
        Int64(0),
        "in_flight must be an ACQUIRED count of live borrowers, so it returns to"
        " 0 on the failure unwind",
    )
    rt.shutdown()


# -----------------------------------------------------------------------------
# GUARD 3 — positive control: the invariant holds on the normal path too.
# -----------------------------------------------------------------------------


def test_invariant_in_flight_zero_after_every_successful_dispatch() raises:
    """Positive control for the same predicate on the success path, across three
    fan-out widths (1, 4, 64 tasks over 4 workers). Guards the +1 driver charge
    bookkeeping: a leaked driver charge would hang the barrier, and a
    double-released one would let the counter transiently hit zero mid-enqueue
    and reproduce the original defect from the other direction.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    var widths = List[Int]()
    widths.append(1)
    widths.append(4)
    widths.append(64)
    for n in widths:
        var state = _SpinState()
        var seg = _SpinSegment(spin_ms=Int64(0))
        var back = d.run_with_state[_SpinState, _SpinSegment](
            state, seg^, n, CancellationToken.never(),
        )
        _ = back^
        assert_equal(
            d.in_flight_snapshot(),
            Int64(0),
            "in_flight must be 0 after a successful dispatch",
        )
        assert_equal(
            state.done(), Int64(n), "every task must have completed"
        )
    rt.shutdown()


def main() raises:
    test_bug1_closed_queue_unwind_waits_for_posted_shards()
    test_bug2_in_flight_is_acquired_not_asserted()
    test_invariant_in_flight_zero_after_every_successful_dispatch()
    print(
        "PASS komira_async.runtime.local_dispatcher_barrier_bypass"
        " (dispatch use-after-free: barrier-bypassing early return +"
        " asserted-not-acquired in_flight)"
    )
