# =============================================================================
# test_local_dispatcher.mojo
# =============================================================================
# LocalDispatcher[S] unit tests.
#
# Coverage:
#   * empty dispatch (n=0 short-circuit) — fast path, no enqueue.
#   * n=1 trivial Segment — single task; counter == 1.
#   * n=4 with multiple workers — confirms execute() called the right
#     number of times via shared atomic counter on State.
#   * n=1024 high-count — stresses the per-shard [lo, hi) range
#     distribution.
#   * negative-n raise — input validation.
#   * worker raise — first-error-wins propagated to driver.
#   * dispatcher accessor compiles and binds correctly through
#     `ref d = rt.dispatcher()`.
#   * concurrent re-entrance: a Segment whose execute() tries to run a
#     nested dispatch raises the re-entrance error (validates the CAS guard).
#   * no-workers-attached raise — the dispatcher requires attach + start before
#     run_with_state.
#
# The dispatcher REQUIRES at least one started worker. Every
# test attaches workers + starts the runtime + tears down with shutdown.
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import (
    LocalDispatcher,
    _LdErrorSlot,
)
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PLACEMENT_MAX_SPREAD,
    PerCoreAsyncRuntime,
)
from komira_core.runtime_traits.worker_pool_traits import KeepAlive, Segment


# -----------------------------------------------------------------------------
# Test State + Test Segment helpers
# -----------------------------------------------------------------------------

struct _CounterState(KeepAlive, Movable, Deinitable):
    """State carrying a shared atomic counter."""

    var counter: OwnedPointer[AtomicI64]

    def __init__(out self):
        var raw = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own.
        raw[] = AtomicI64(Int64(0))
        self.counter = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw,
        )

    def load(self) -> Int64:
        return self.counter[].load()


@fieldwise_init
struct _CountSegment(Segment, Deinitable):
    """Trivial Segment whose execute() fetch_adds State.counter by 1."""

    var _pad: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_CounterState]()
        _ = sp[].counter[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id


@fieldwise_init
struct _MultiplierSegment(Segment, Deinitable):
    """Regression Segment — carries a per-segment `multiplier` field that
    EVERY shard reads through the SHARED Segment (the dispatcher moves ONE
    Segment into `_seg_buf` and every shard reaches it via the bound
    `_DispatchCtx`). Each execute() fetch_adds `multiplier` into State.counter.
    If the new concrete-origin `_DispatchShard`/`_DispatchCtx` dispatch did NOT
    share the SAME Segment across shards (e.g. a per-shard copy, or a severed
    borrow), the observed multiplier would be wrong/garbage and the summed
    counter would not equal n*multiplier."""

    var multiplier: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_CounterState]()
        # Read the SHARED Segment's own field (self.multiplier) AND fold into
        # the SHARED State — both reached through the bound concrete-origin ctx.
        _ = sp[].counter[].fetch_add(self.multiplier)
        _ = worker_id
        _ = task_id


@fieldwise_init
struct _RaisingSegment(Segment, Deinitable):
    """Segment whose execute() raises on a designated tid."""

    var raise_on_tid: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        _ = state
        _ = worker_id
        if task_id == self.raise_on_tid:
            raise Error(
                "raising_segment: forced error on tid="
                + String(task_id)
            )


@fieldwise_init
struct _NestedDispatchSegment(Segment, Deinitable):
    """Segment whose execute() tries a nested dispatch — must trigger
    the re-entrance CAS guard. Recovers the dispatcher pointer via FFI
    laundering (TEST-ONLY shape).
    """

    var _disp_addr_int: Int

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        _ = state
        _ = worker_id
        _ = task_id
        var disp_ptr = UnsafePointer[
            LocalDispatcher[NoopSink], MutUntrackedOrigin,
        ](unsafe_from_address=self._disp_addr_int)
        var s = _CounterState()
        var inner_seg = _CountSegment(_pad=0)
        # This MUST raise "nested dispatch detected" — outer
        # run_with_state holds the CAS at 1.
        _ = disp_ptr[].run_with_state[_CounterState, _CountSegment](
            s, inner_seg^, 1, CancellationToken.never(),
        )


# -----------------------------------------------------------------------------
# Helper: build, attach N workers, start. Returns the runtime ready to
# drive dispatches. Caller MUST call shutdown() before drop.
# -----------------------------------------------------------------------------

def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


# -----------------------------------------------------------------------------
# CHARGE-LOSS GUARD — the shard's error-publish expressions must not raise
# -----------------------------------------------------------------------------
#
# WHAT THIS PROTECTS. `_DispatchShard.run` publishes into the error slot from
# TWO sites that are OUTSIDE any `try` (local_dispatcher.mojo, the cancel branch
# and the `except e:` handler for `execute`):
#
#     _ = self.ctx_ref().error_slot_ref().try_set(
#             String("CancelledError: ") + self.ctx_ref().cancel_ref().reason())
#     ...
#     except e:
#         _ = self.ctx_ref().error_slot_ref().try_set(String(e))
#
# A raise out of EITHER expression escapes the shard body, escapes the bare
# `handle.run()` in the worker's drain loop, and skips the
# `in_flight_p[].fetch_sub(Int64(1))` at the bottom of `run` — the decrement
# that RETURNS THIS SHARD'S CHARGE. The barrier's only exit is
# `in_flight <= stranded`, so a lost charge makes it unsatisfiable: the driver
# spins 1 ms waits FOREVER on a customer query, prints one `[BARRIER-STALL]`
# line at ~10 s, and then is indistinguishable from a healthy slow query while
# pinning a core.
#
# WHY THIS IS SAFE TODAY, AND WHY THE COMPILER WILL NOT TELL YOU IF IT STOPS
# BEING SAFE. Every call in those two expressions is a plain `def` with no
# `raises` — on the pinned Mojo 1.0.0b2 a `def` is NON-raising unless it writes
# `raises`. So no raise can occur and the
# sites are sound as written. But `_DispatchShard.run` itself MUST be declared
# `raises` to satisfy `ErasableWork`, which means adding `raises` to
# `_LdErrorSlot.try_set` — or to `CancellationToken.reason`, or to `String`'s
# concat / `Error` conversion — silently turns both sites into permanent-hang
# sites WITH NO COMPILE ERROR AT EITHER ONE. Measured: with `try_set` marked
# `raises`, `local_dispatcher.mojo` still compiles clean.
#
# THE GUARD. `_shard_error_publish_must_not_raise` is deliberately declared
# NON-raising and performs the two expression shapes verbatim. It is the only
# place in the repo where the compiler is asked that question, so if any of
# those calls gains `raises` this file fails to build with
# "cannot call function that may raise in a context that cannot raise" pointing
# at the offending expression. Falsified by mutation: marking
# `_LdErrorSlot.try_set` `raises` reds exactly these two lines.
#
# Do NOT "fix" a future red here by adding `raises` to this helper or by
# wrapping its body in `try`. The red means the shard body must be re-guarded
# so its charge is still returned; the helper is the alarm, not the problem.


def _guard_forced_raise() raises -> None:
    """A raising callee, so the guard below can reach a real `except e:` and
    exercise the `String(e)` conversion the shard's handler performs."""
    raise Error("charge-loss guard probe")


def _shard_error_publish_must_not_raise(
    mut slot: _LdErrorSlot, mut tok: CancellationToken
) -> None:
    """COMPILE-TIME GUARD — NON-RAISING BY DESIGN. See the section header.

    Mirrors `_DispatchShard.run`'s two unguarded error-publish expressions. If
    any call in them ever becomes `raises`, THIS FUNCTION stops compiling.
    """
    # Site 1 — the cancel branch.
    _ = slot.try_set(String("CancelledError: ") + tok.reason())
    # Site 2 — the `except e:` handler for `Segment.execute`.
    try:
        _guard_forced_raise()
    except e:
        _ = slot.try_set(String(e))


# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------


def test_shard_error_publish_is_non_raising() raises:
    """Charge-loss guard. The COMPILE of this file is the assertion (see the
    section header); the runtime body additionally pins first-error-wins, so
    the guard cannot be satisfied by a `try_set` that silently stopped writing.
    """
    var slot = _LdErrorSlot()
    var tok = CancellationToken.never()
    assert_false(slot.is_set())
    _shard_error_publish_must_not_raise(slot, tok)
    # Site 1 won the CAS; site 2 observed it set and did NOT overwrite.
    assert_true(slot.is_set())
    assert_equal(slot.message(), String("CancelledError: "))


def test_dispatcher_accessor_compiles() raises:
    """accessor returns ref to stored
    LocalDispatcher façade. n=0 short-circuit doesn't require running
    workers (early return BEFORE the no-workers check).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, 0, CancellationToken.never(),  # n=0 short-circuit
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(0))


def test_run_with_state_n0_short_circuit() raises:
    """n=0 short-circuit: no enqueue, counter
    not bumped, segment returned by value.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, 0, CancellationToken.never(),
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(0))


def test_run_with_state_n1_trivial() raises:
    """n=1: single task; counter == 1."""
    var rt = _make_started_runtime(2)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, 1, CancellationToken.never(),
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(1))
    rt.shutdown()


def test_run_with_state_n4_concurrent() raises:
    """n=4: per-worker MPSC enqueue + drain;
    counter == 4 (each tid bumps once).
    """
    var rt = _make_started_runtime(4)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, 4, CancellationToken.never(),
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(4))
    rt.shutdown()


def test_run_with_state_n1024_high_count() raises:
    """n=1024: stresses the per-shard
    [lo, hi) range distribution; counter == 1024.
    """
    var rt = _make_started_runtime(4)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, 1024, CancellationToken.never(),
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(1024))
    rt.shutdown()


def test_run_with_state_negative_n_raises() raises:
    """n < 0: validation raises (release CAS
    first); CAS released so a follow-up dispatch works.
    """
    var rt = _make_started_runtime(2)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var raised = False
    try:
        var _back = d.run_with_state[_CounterState, _CountSegment](
            s, seg^, -1, CancellationToken.never(),
        )
        _ = _back^
    except:
        raised = True
    assert_true(raised)
    var s2 = _CounterState()
    var seg2 = _CountSegment(_pad=0)
    var _back2 = d.run_with_state[_CounterState, _CountSegment](
        s2, seg2^, 1, CancellationToken.never(),
    )
    _ = _back2^
    assert_equal(s2.load(), Int64(1))
    rt.shutdown()


def test_run_with_state_worker_raise_propagates() raises:
    """Segment.execute raises on a tid; first-
    error-wins propagation to the driver via the shared error slot.
    """
    var rt = _make_started_runtime(2)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _RaisingSegment(raise_on_tid=Int64(2))
    var raised = False
    try:
        var _back = d.run_with_state[_CounterState, _RaisingSegment](
            s, seg^, 8, CancellationToken.never(),
        )
        _ = _back^
    except:
        raised = True
    assert_true(raised)
    var s2 = _CounterState()
    var seg2 = _CountSegment(_pad=0)
    var _back2 = d.run_with_state[_CounterState, _CountSegment](
        s2, seg2^, 1, CancellationToken.never(),
    )
    _ = _back2^
    assert_equal(s2.load(), Int64(1))
    rt.shutdown()


def test_nested_dispatch_raises_re_entrance() raises:
    """Segment.execute attempting a nested
    dispatch on the SAME LocalDispatcher must raise the re-entrance
    error.

    The error path also exercises the worker_raise_propagates path
    (the inner re-entrance error is reported via the shared error slot).
    """
    var rt = _make_started_runtime(1)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var disp_addr = Int(UnsafePointer(to=d))
    var seg = _NestedDispatchSegment(_disp_addr_int=disp_addr)
    var raised = False
    try:
        var _back = d.run_with_state[
            _CounterState, _NestedDispatchSegment,
        ](s, seg^, 1, CancellationToken.never())
        _ = _back^
    except:
        raised = True
    assert_true(raised)
    rt.shutdown()


def test_run_with_state_no_workers_raises() raises:
    """calling run_with_state(n>0) on a
    runtime with no workers attached raises the typed
    "no workers attached" Error.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var raised = False
    try:
        var _back = d.run_with_state[_CounterState, _CountSegment](
            s, seg^, 4, CancellationToken.never(),
        )
        _ = _back^
    except:
        raised = True
    assert_true(raised)


def test_run_with_state_pre_cancelled_raises() raises:
    """Passing an already-cancelled token to run_with_state
    short-circuits before any enqueue and raises CancelledError.
    """
    var rt = _make_started_runtime(2)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var token = CancellationToken.new()
    token.cancel(String("test pre-cancel"))
    var raised = False
    try:
        var _back = d.run_with_state[_CounterState, _CountSegment](
            s, seg^, 1024, token^,
        )
        _ = _back^
    except:
        raised = True
    assert_true(raised)
    # Counter was never bumped (short-circuited before enqueue).
    assert_equal(s.load(), Int64(0))
    # And a follow-up dispatch with `never()` runs normally.
    var s2 = _CounterState()
    var seg2 = _CountSegment(_pad=0)
    var _back2 = d.run_with_state[_CounterState, _CountSegment](
        s2, seg2^, 4, CancellationToken.never(),
    )
    _ = _back2^
    assert_equal(s2.load(), Int64(4))
    rt.shutdown()


def test_run_with_state_never_token_succeeds() raises:
    """`CancellationToken.never()` is the documented "no
    cancellation" sentinel; dispatch runs to completion with counter
    bumped fully.
    """
    var rt = _make_started_runtime(2)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var seg = _CountSegment(_pad=0)
    var seg_back = d.run_with_state[_CounterState, _CountSegment](
        s, seg^, 16, CancellationToken.never(),
    )
    _ = seg_back^
    assert_equal(s.load(), Int64(16))
    rt.shutdown()


def test_run_with_state_shared_segment_field_observed_by_all_shards() raises:
    """Regression — the production `run_with_state`
    path shares ONE Segment across all shards through the concrete-origin
    `_DispatchCtx`. A `_MultiplierSegment` carries a per-segment `multiplier`
    field; every one of the n task invocations (spread across the worker shards)
    reads the SHARED Segment's field and folds it into the SHARED State. If the
    new concrete-origin `_DispatchShard` did NOT share the SAME Segment value
    across shards (per-shard copy / severed borrow), the summed counter would
    not equal n*multiplier.

    Guards the shared-Segment-same-value-across-shards invariant on the
    PRODUCTION dispatch path (the unit-level same-ADDRESS guard lives in
    test_shared_erasure_real_shapes.mojo for the StateBoundWork primitive)."""
    var rt = _make_started_runtime(4)
    ref d = rt.dispatcher()
    var s = _CounterState()
    var multiplier = Int64(7)
    var n = 1000
    var seg = _MultiplierSegment(multiplier=multiplier)
    var seg_back = d.run_with_state[_CounterState, _MultiplierSegment](
        s, seg^, n, CancellationToken.never(),
    )
    # The returned Segment must carry the SAME multiplier back (moved through
    # _seg_buf and out again — proving the shared Segment was not corrupted).
    assert_equal(seg_back.multiplier, multiplier)
    _ = seg_back^
    # Every tid read the SHARED multiplier; sum == n * multiplier.
    assert_equal(s.load(), Int64(n) * multiplier)
    rt.shutdown()


def main() raises:
    test_shard_error_publish_is_non_raising()
    test_dispatcher_accessor_compiles()
    test_run_with_state_n0_short_circuit()
    test_run_with_state_n1_trivial()
    test_run_with_state_n4_concurrent()
    test_run_with_state_n1024_high_count()
    test_run_with_state_negative_n_raises()
    test_run_with_state_worker_raise_propagates()
    test_nested_dispatch_raises_re_entrance()
    test_run_with_state_no_workers_raises()
    test_run_with_state_pre_cancelled_raises()
    test_run_with_state_never_token_succeeds()
    test_run_with_state_shared_segment_field_observed_by_all_shards()
    print(
        "PASS komira_async.runtime.local_dispatcher"
        " (per-worker MPSC enqueue,"
        " cancel_token)"
    )
