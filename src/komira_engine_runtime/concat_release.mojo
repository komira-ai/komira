# =============================================================================
# concat_release: destroy a concat's input batches on the pool.
# =============================================================================
#
# `release_concat_inputs_parallel` moves the destruction of the drained input
# batches off the driver: each worker drops a stride slice of them. It
# produces no value and changes no result, and it declines to a serial drop
# for one worker, fewer than two batches, or a teardown below
# `_CONCAT_RELEASE_MIN_ROWS`.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CONCAT_RELEASE
from std.collections.optional import Optional
from std.memory import UnsafePointer
from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab
from komira_async_api.worker_pool_traits import (
    KeepAlive,
    Segment,
)
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

# =============================================================================
# release_concat_inputs_parallel — DESTROY the concat INPUT batches on the POOL
# instead of on the driver.
#
# WHAT THIS IS FOR. `_concat_impl` swaps the input `Slab[Optional[RecordBatch]]`
# out of the State after the drain barrier and drops it with `_ = _drain_input^`
# -- on the DRIVER, one batch at a time, with every worker already rejoined and
# parked. Each `Optional[RecordBatch]` destructor cascades through its Columns'
# `ArcPointer`s into `free()`, so the whole storm lands on the serial spine.
#
# The destruction work is the batches' `Variant`, `ArcPointer` and `Slab`
# destructors and the allocator's `free()`, none of which a frame-pointer
# profile can unwind, so size this from a profile that walks the destructor
# chains. It has the same shape as `release_radix_srcs_parallel`'s teardown
# of radix sources, and is built to that template.
#
# WHY PER-BATCH AND NOT PER-COLUMN. One task per batch is the unit the concat
# already reads by, batches are independent allocations, and `n_batches` is
# typically >= pool width on the cells that matter. A finer (batch, column)
# space would only help when n_batches << nw, which is the case the decline
# below already sends to the driver.
#
# PARALLELIZE-BOUNDARY (run_with_state, fork-join synchronous):
#   Disjointness: task `t` moves out and drops slots `t, t+nw, t+2nw, ...` ONLY.
#     Each RecordBatch owns its own Columns; `take_slot_unchecked` does not
#     touch the slab's length, so the container header is never a shared write.
#   Liveness: the caller's own `run_with_state` barrier has ALREADY rejoined
#     every worker before this is called -- the module header states the input
#     slab is read-only across the dispatch window and that no thread reads it
#     afterwards -- so nothing can observe these batches.
#   No-observable-effect: destruction produces no output. This wave cannot
#     change any value; it decides only WHICH THREAD calls free().
#
# DECLINE (structural, no flag): a single worker, or fewer than 2 batches, drops
# on the driver. That serial arm is byte-for-byte the previous code and is the
# differential oracle, reached by `--workers 1`.
# =============================================================================


struct _ConcatReleaseState(KeepAlive):
    """Per-dispatch state of the input-teardown wave.

    OWNS the input slab outright (it is MOVED in by the driver), so the state
    carries no pointer and no origin parameter: the task reaches it through the
    concrete-type restore of the `run_with_state` pattern, exactly as the other
    concat states do. The driver moves the slab back out after the barrier.
    """

    var batches: Slab[Optional[RecordBatch]]
    var n: Int
    var nw: Int

    def __init__(
        out self,
        var batches: Slab[Optional[RecordBatch]],
        n: Int,
        nw: Int,
    ):
        self.batches = batches^
        self.n = n
        self.nw = nw

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _ConcatReleaseTask(Segment):
    """POD discriminator; `execute` moves this task's stride-slice of input
    batches out of the slab and drops them, so their `free()` storm lands on
    the worker rather than on the driver's serial spine."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the concrete State (the established
        # run_with_state Task pattern, identical to `_RadixReleaseTask`); the
        # State is non-parametric, so no origin is erased. Task `t` moves out
        # slots `t, t+nw, ...` ONLY -- disjoint across tasks -- and
        # `take_slot_unchecked` does not touch the slab's length, so the
        # container header is never concurrently written. The driver restores
        # the destructor contract with `set_len_unchecked(0)` AFTER the barrier.
        comptime ConcreteState = _ConcatReleaseState
        var sp = UnsafePointer(to=state).bitcast[ConcreteState]()
        var t = Int(task_id)
        var n = sp[].n
        var nw = sp[].nw
        var w = t
        while w < n:
            var dead = sp[].batches.take_slot_unchecked(w)
            _ = dead^
            w += nw

    def __keep_alive(mut self):
        pass


# THE WORK THRESHOLD.
#
# The wave declines on an amount of WORK, not only on `n_batches < 2`: forking
# a whole pool to free the buffers of a tiny teardown costs more wakeups than
# it saves. 65,536 rows is a point well inside the wide gap between a
# teardown too small to repay a fork (thousands of rows) and one that does
# (tens of millions). It is a bracket, not a measured crossover; a workload
# that lands between the two should be measured rather than nudging this
# number. It is deliberately not the threshold of a hash build, which prices a
# different mechanism.
comptime _CONCAT_RELEASE_MIN_ROWS: Int = 65536


def release_concat_inputs_parallel(
    var batches: Slab[Optional[RecordBatch]],
    total_rows: Int,
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
) raises:
    """Destroy every input batch on the POOL. Consumes `batches`.

    Produces no value and changes no result -- it only moves N RecordBatch
    destructions off the driver's serial spine. Declines to a serial drop for a
    single worker, fewer than 2 batches, or a teardown too small to amortise the
    fork (`total_rows < _CONCAT_RELEASE_MIN_ROWS`).
    """
    var n = len(batches)
    var nw = dispatcher.worker_count()
    if nw < 1:
        nw = 1
    var eff_nw = nw
    if eff_nw > n:
        eff_nw = n

    if total_rows < _CONCAT_RELEASE_MIN_ROWS:
        # BELOW THE GATE THIS IS BYTE-FOR-BYTE THE PREVIOUS DROP. `total_rows`
        # is the caller's own count, already computed for its tiling decision,
        # so the test itself costs nothing.
        _ = cancel_token^
        _ = batches^
        return

    if eff_nw <= 1:
        # Serial arm (the oracle): plain driver-side drop, unchanged behaviour.
        _ = cancel_token^
        _ = batches^
        return

    comptime StateT = _ConcatReleaseState
    var st = StateT(batches^, n, eff_nw)
    var task = _ConcatReleaseTask(_pad=Int32(0))
    # ★ `set_len_unchecked(0)` MUST run on the RAISING path too. The tasks move
    # slots out with `take_slot_unchecked`, which deliberately does NOT adjust
    # the length -- so a slab that still counts a moved-out slot as live will
    # `destroy_pointee` it a SECOND time when it drops. If the dispatch raises
    # (cancellation) with some slots already taken, letting the error escape
    # before the length is fixed converts a cancel into a DOUBLE FREE. Zeroing
    # the length on both paths degrades that to a leak of the slots no task got
    # to, which is the correct trade. (Verbatim the reasoning in
    # `release_radix_srcs_parallel`, which this mirrors.)
    var err = Optional[Error](None)
    try:
        var _back = dispatcher.run_with_state[
            StateT, _ConcatReleaseTask
        ](
            st,
            task^,
            eff_nw,
            cancel_token^,
            site_id=SITE_CONCAT_RELEASE,
        )
        _ = _back^
    except e:
        err = Optional[Error](e^)

    st.batches.set_len_unchecked(0)
    _ = st^
    if err:
        raise err.take()
