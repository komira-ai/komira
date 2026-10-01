# =============================================================================
# test_local_dispatcher_stale_shard_generation.mojo
# =============================================================================
# Dispatch use-after-free residual: the regression guard for the generation guard.
#
# ⚠ STATUS UPDATE: the DISPATCHER no longer works this way.
# `_shard_buf` is DELETED — each `_DispatchShard` now gets its own home via
# `make_erased`, because the pooled slot's cross-generation reuse turned out to
# BE the defect (a worker's compiler-emitted `mut self` store-back could land
# after the barrier released, reverting the slot one generation; measured 27/30
# -> 0/100 on `//tests:unit_test_streaming_forever_root_state`). See
# [[dispatch-ctx-uaf-fixed-pool-reuse]].
#
# THIS TEST STILL EARNS ITS PLACE and must NOT be deleted: it exercises the
# fix-4 generation stamp directly, over a pool it builds ITSELF (not the
# dispatcher's), so it remains a live falsifier for the guard that is now the
# belt-and-braces detector. The narrative below describes the dispatcher as it
# was when the bug was found — read it as history, not as current design.
#
# THE BUG CLASS — a BORROWED handle over a RECYCLED pool slot has no identity.
#
# `LocalDispatcher.run_with_state` writes one `_DispatchShard` per worker into the
# dispatcher's `_shard_buf` byte pool and hands each worker a NON-OWNING
# `ErasedHandle` over those bytes (`make_borrowed_erased`). The shard's `_ctx`
# field is a `Pointer` into the DRIVER'S STACK FRAME, and the pool slot is REUSED
# by every subsequent dispatch. So `_ctx` is meaningful for exactly ONE dispatch
# generation, and — before the generation guard — nothing in the handle recorded WHICH. Any
# handle that outlived its dispatch by any route re-read `_ctx` out of the slot
# and dereferenced a popped stack frame.
#
# Fixes 1-3 (acquired in-flight charges, barrier on every unwind,
# release-ordering) made the barrier a much better proof but did NOT eliminate
# the crash: a few SIGSEGVs per hundred pinned invocations remained.
#
# FIELD PROOF (a core from a long pinned query soak after the first three fixes). The
# faulting worker was inside `_DispatchShard.run`'s cancel poll. The driver was
# still inside `_drain_in_flight_barrier` for the radix-drain dispatch. The
# `_shard_buf` slab dump was unambiguous:
#
#   19 of 20 slots:  ctx=0x7fff6a17f0c0  lo=wid   hi=wid+1   (n=20 over 20w)
#                    -> ctx->_cancel = 0x7fff6a1804b8, a HEALTHY token (strong=5)
#   slot wid=8:      ctx=0x7fff6a180400  lo=25    hi=28      (n=64 over 20w)
#                    -> ctx->_cancel = 0x7fff6a181128, a DESTROYED token whose
#                       ArcPointer box had been recycled into unrelated heap data
#
# `lo=25, hi=28` for wid=8 is `(8*64)//20 .. (9*64)//20` — an n=64 dispatch, i.e.
# the COMBINE wave, not the drain wave that was running. So ONE handle from an
# EARLIER generation was executing against that generation's ctx while its slot
# had already been recycled. The `CancellationToken` was merely the first
# heap-owning field the shard touched — the VICTIM, not the cause. Replacing the
# token's `List[ArcPointer[...]]` with an `InlineArray` (the destroy-recreate reflex) would
# only have moved the fault to `error_slot` or `state`.
#
# THE FIX (the generation guard) — make the borrowed handle SELF-VERIFYING. Each shard is
# stamped with the dispatch generation that wrote its slot and carries a pointer
# to the dispatcher's heap generation counter. `run()` compares them FIRST and
# returns having touched NOTHING on a mismatch — critically without decrementing
# `in_flight`, since that counter now belongs to a different dispatch and an
# extra decrement there is what propagates one leaked handle into a cascade.
# The counter is bumped at dispatch entry and again at the END of
# `_drain_in_flight_barrier`, so "stamp matches" means exactly "the ctx I point
# at is still alive".
#
# FAILS ON CURRENT CODE:
#   * `test_bug4_shard_run_after_barrier_must_not_touch_stale_ctx` — the test
#     obtains a real posted shard handle, lets its dispatch complete normally,
#     and then runs the handle a second time (the exact "handle outlived its
#     dispatch" precondition the core dump caught). Pre-fix-4 the handle
#     dereferences the popped `run_with_state` frame's `ctx`, executes the task
#     body again (so `entered()` grows) and `fetch_sub`s a counter that now
#     belongs to nobody, driving `in_flight_snapshot()` NEGATIVE. Post-fix-4 it
#     refuses: `entered()` unchanged, `in_flight_snapshot() == 0`, and
#     `barrier_violations_snapshot() == 1`.
#   * `test_invariant_no_barrier_violations_on_healthy_dispatches` — the
#     positive control: a multi-generation sequence with VARYING worker counts
#     (the field shape — a wide dispatch followed by a narrow one leaves high
#     slots holding stale bytes) must report ZERO barrier violations.
#
# The falsifier does NOT rely on catching a segfault. Pre-fix-4 the stale run
# reads a popped stack frame, which MAY fault and may equally read plausible
# memory and corrupt silently — the scarier half. It asserts the INVARIANT
# instead: a shard whose dispatch generation has closed must not run.
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import (
    MpscReceiver,
    MpscSender,
    channel as mpsc_channel,
)
from komira_async.channel.spsc import TRY_RECV_OK, TRY_SEND_OK
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
# State: an observable task ledger PLUS the pseudo-worker channel ends.
# -----------------------------------------------------------------------------
#
# `_entered` is the ledger — it counts every `execute` body that actually ran.
# It lives in an `OwnedPointer` heap cell owned by the TEST frame (which outlives
# every dispatch), so reading it from the driver after a dispatch is itself sound
# regardless of what happened to the dispatcher's stack frames.
#
# `_recv` / `_send` are the two ends of the PSEUDO-WORKER's task queue. The trick
# this test turns on: the pseudo-worker has no pthread, so the handle the driver
# posts to it would never be consumed and the (correct, post-fix-1) barrier would
# block forever. So shard 0 — running on the ONE real worker — drains that queue
# itself, runs the handle (releasing its barrier charge legitimately, inside the
# generation), and then puts the handle BACK so the driver can re-run it AFTER
# the barrier has closed. That is the whole point: it manufactures, from public
# API only, the precondition the field core captured.


struct _LedgerState(KeepAlive, Movable, Deinitable):
    var _entered: OwnedPointer[AtomicI64]
    var _recv: OwnedPointer[MpscReceiver[ErasedHandle]]
    var _send: OwnedPointer[MpscSender[ErasedHandle]]

    def __init__(
        out self,
        var recv: MpscReceiver[ErasedHandle],
        var send: MpscSender[ErasedHandle],
    ):
        var e = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; ownership transfers to OwnedPointer.
        e[] = AtomicI64(Int64(0))
        self._entered = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=e,
        )
        self._recv = OwnedPointer[MpscReceiver[ErasedHandle]](value=recv^)
        self._send = OwnedPointer[MpscSender[ErasedHandle]](value=send^)

    def entered(self) -> Int64:
        return self._entered[].load()

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _LedgerSegment(Segment, Deinitable):
    """Records entry in the ledger. Task 0 additionally rescues the shard that
    the driver posted to the pseudo-worker: it pops the handle, RUNS it (so the
    dispatch's barrier can complete — that run is legitimate, it happens while
    the generation is still open), then re-queues the handle so the driver can
    re-run it after the barrier closes."""

    var rescue_ms: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_LedgerState]()
        _ = sp[]._entered[].fetch_add(Int64(1))
        _ = worker_id
        if task_id != Int64(0):
            return
        # Task 0 only: rescue + re-queue the pseudo-worker's shard.
        var deadline = Int64(perf_counter_ns()) + self.rescue_ms * 1_000_000
        while Int64(perf_counter_ns()) < deadline:
            var oc = sp[]._recv[].try_recv()
            if oc.status != TRY_RECV_OK:
                continue
            var h = oc.take_value()
            # The in-generation run: shard 1's body executes here, on this
            # worker's thread, and releases shard 1's in-flight charge.
            h.run()
            # Park the SAME handle back in the queue. It is a BORROWED handle
            # (its `__del__` no-ops; the `_shard_buf` pool owns the bytes), so
            # this is exactly the "a handle outlived its dispatch" state.
            var back = sp[]._send[].try_send_back(h^)
            if back.status != TRY_SEND_OK:
                _ = back^
            return

    def __keep_alive(mut self):
        pass


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# -----------------------------------------------------------------------------
# GUARD — a shard whose generation has closed must not run.
# -----------------------------------------------------------------------------


def test_bug4_shard_run_after_barrier_must_not_touch_stale_ctx() raises:
    """Dispatch use-after-free: the stale-generation residual.

    One real started worker + one pseudo-worker whose task queue this test owns.
    `n = 2`, so shard 0 goes to the real worker and shard 1 lands in the pseudo
    queue. Shard 0 rescues + runs + re-queues shard 1's handle, so the dispatch
    completes cleanly with `entered() == 2` and the handle still in hand.

    Then a SECOND dispatch (`n = 1`) recycles slot 0 but leaves slot 1 holding
    generation-1 bytes — the field shape exactly (a wide dispatch followed by a
    narrow one leaves high slots stale).

    Then the rescued handle is run once more. That is the precondition the
    core dump captured, reproduced deterministically.

    FAILS WITHOUT FIX 4: the handle dereferences the
    popped generation-1 `run_with_state` frame's `ctx`, re-runs the task body
    (`entered()` becomes 4 instead of 3) and `fetch_sub`s the dispatcher's
    in-flight counter, so `in_flight_snapshot()` reads -1 instead of 0.
    Post-fix-4 it refuses: the counters are untouched and the violation is
    COUNTED rather than silently corrupting memory.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()

    # Pseudo-worker: capacity-4 channel, receiver + a second sender kept here,
    # the first sender handed to the dispatcher. The wake handle is
    # `make_disconnected` so `wake_with_elision` is a harmless no-op (there is no
    # pthread behind this queue — shard 0 is the consumer).
    var pair = mpsc_channel[ErasedHandle](UInt(4))
    var recv = pair.take_receiver()
    var send_for_dispatcher = pair.take_sender()
    var send_for_test = send_for_dispatcher.clone()
    d._register_worker_handle(
        send_for_dispatcher^,
        WorkerWakeHandle.make_disconnected(Int32(-1), UInt64(0)),
    )
    assert_equal(d.worker_count(), 2)

    var state = _LedgerState(recv^, send_for_test^)

    # --- Generation 1: n = 2 (both slots written) ---
    var seg = _LedgerSegment(rescue_ms=Int64(4000))
    var back = d.run_with_state[_LedgerState, _LedgerSegment](
        state, seg^, 2, CancellationToken.never(),
    )
    _ = back^
    assert_equal(
        state.entered(),
        Int64(2),
        "both shards must have run inside generation 1",
    )
    assert_equal(
        d.in_flight_snapshot(),
        Int64(0),
        "generation 1 barrier must have settled to zero",
    )
    assert_equal(
        d.barrier_violations_snapshot(),
        Int64(0),
        "no violation yet — generation 1 was healthy",
    )

    # --- Generation 2: n = 1, so slot 0 is recycled and slot 1 is NOT ---
    var seg2 = _LedgerSegment(rescue_ms=Int64(0))
    var back2 = d.run_with_state[_LedgerState, _LedgerSegment](
        state, seg2^, 1, CancellationToken.never(),
    )
    _ = back2^
    assert_equal(state.entered(), Int64(3), "generation 2 ran one task")

    # --- THE FALSIFIER: run the generation-1 handle after its barrier closed ---
    var stale = state._recv[].try_recv()
    assert_true(
        stale.status == TRY_RECV_OK,
        "shard 0 should have re-queued generation 1's shard handle",
    )
    var stale_handle = stale.take_value()
    stale_handle.run()
    _ = stale_handle^

    # A shard whose generation has closed must have touched NOTHING.
    assert_equal(
        state.entered(),
        Int64(3),
        "a stale-generation shard must NOT execute its task body again"
        " (pre-fix-4 this is 4 — it ran against a popped stack frame)",
    )
    assert_equal(
        d.in_flight_snapshot(),
        Int64(0),
        "a stale-generation shard must NOT decrement in_flight — that counter"
        " belongs to another dispatch now (pre-fix-4 this is -1)",
    )
    assert_equal(
        d.barrier_violations_snapshot(),
        Int64(1),
        "the refusal must be COUNTED so a real field leak is attributable",
    )
    _ = state^
    _ = rt^


# -----------------------------------------------------------------------------
# POSITIVE CONTROL — healthy multi-generation traffic reports zero violations.
# -----------------------------------------------------------------------------


def test_invariant_no_barrier_violations_on_healthy_dispatches() raises:
    """The generation guard must never fire on legitimate traffic, INCLUDING the
    field shape that produced the crash: a wide dispatch (n much larger than the
    worker count, so each shard owns a multi-task range) immediately followed by
    a narrow one (n == worker count), which leaves the wide generation's bytes in
    any slot the narrow one does not rewrite.

    A regression that made the stamp compare wrongly would show up here as
    dropped work (`entered()` short) or as a non-zero violation count.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    var w = d.worker_count()
    assert_true(w >= 1, "expected at least one attached worker")

    # A no-rescue state: the pseudo-worker machinery is unused here, but the
    # State type is shared, so give it a real (empty) channel pair.
    var pair = mpsc_channel[ErasedHandle](UInt(2))
    var state = _LedgerState(pair.take_receiver()^, pair.take_sender()^)

    var expected = Int64(0)
    for rep in range(8):
        # Alternate WIDE (n = 8*w, multi-task ranges) and NARROW (n = 1).
        var n = 8 * w if (rep % 2) == 0 else 1
        var seg = _LedgerSegment(rescue_ms=Int64(0))
        var b = d.run_with_state[_LedgerState, _LedgerSegment](
            state, seg^, n, CancellationToken.never(),
        )
        _ = b^
        expected += Int64(n)
        assert_equal(
            d.in_flight_snapshot(),
            Int64(0),
            "in_flight must be zero after every dispatch",
        )
        assert_equal(
            d.barrier_violations_snapshot(),
            Int64(0),
            "no healthy dispatch may report a barrier violation",
        )
    assert_equal(
        state.entered(),
        expected,
        "every task must have executed exactly once across all generations",
    )
    _ = state^
    _ = rt^


def main() raises:
    test_bug4_shard_run_after_barrier_must_not_touch_stale_ctx()
    test_invariant_no_barrier_violations_on_healthy_dispatches()
    print("OK test_local_dispatcher_stale_shard_generation")
