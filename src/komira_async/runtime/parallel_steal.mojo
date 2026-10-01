# =============================================================================
# parallel_steal — the WORK-STEALING fork-join layer over
# LocalDispatcher.run_with_state. The dynamic-load-balance sibling of
# `parallel_fork_join` (static task_id-stride chunking).
#
# Owns ONCE: the State/Task wrapper, the run_with_state call, the
# _serial/_with_dispatcher/_impl 3-entry split, the immutable-origin
# borrow, the SHARED ATOMIC WORK-COUNTER, the per-worker-state ownership
# (`Slab[Optional[WS]]`, reclaimed via `Optional.take`), and the
# error-caught safety contract. Call sites provide only the StealWork
# descriptor (the per-worker-state factory + the per-item fold), the
# borrowed input, and the item count.
#
# THE LOAD-BEARING SAFETY QUESTION (work-stealing-specific):
#   The work-counter is a REAL shared `Atomic[int64]` that every worker
#   `fetch_add(1)`s concurrently to claim the next item index. It MUST
#   live at a STABLE address that does not move while workers race on it.
#   We hold it as an `OwnedPointer[Atomic[int64]]` field on the State
#   (Atomic is non-Movable; the OwnedPointer is the POD 8-byte handle and
#   the Atomic lives at a fixed heap address). Workers reach it through
#   `state.counter[].fetch_add(...)`. The wake-word barrier in
#   run_with_state guarantees every worker has exited before the State
#   (and hence the OwnedPointer, and hence the Atomic) drops. This is the
#   exact shape proven in `spill_parallel_insert.mojo` / `agg_radix.mojo`
#   — centralized here.
#
# The helper OWNS the full safety contract so call sites can't break it:
#   * immutable-origin input borrow (`in_o: ImmutOrigin`, NO wildcard)
#   * shared atomic counter at a stable heap address (OwnedPointer[Atomic])
#   * disjoint per-worker `Slab[Optional[WS]]` (worker `wid` writes ONLY
#     slot `wid`; reclaimed via `Optional.take`, the ownership-reclaim rule)
#   * keepalive-through-barrier (run_with_state is a synchronous wake-word
#     barrier; State is borrowed-mut by the driver)
#
# =============================================================================

from komira_async.runtime.sched_trace import SITE_GENERIC_FORK_JOIN
from std.memory import alloc, OwnedPointer, UnsafePointer
from komira_atomic_alias import AtomicI64

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.steal_work import StealWork
from komira_core.collections.slab import Slab
from komira_core.runtime_traits.worker_pool_traits import KeepAlive, Segment


# =============================================================================
# _StealState[W, In, WS, in_o] — generic work-stealing dispatch State.
# =============================================================================


struct _StealState[
    W: StealWork,
    In: Deinitable,
    WS: Movable & Deinitable,
    in_o: ImmOrigin,
](KeepAlive, Movable):
    # SAFETY: internal typed pointer to the caller's read-only input.
    # `in_o` is CONCRETE (not wildcard); the wake-word barrier in
    # run_with_state guarantees no worker dereferences it after the
    # caller's input could go out of scope. Never exposed publicly.
    var input_ptr: UnsafePointer[Self.In, Self.in_o]

    # OWNED per-worker accumulator Slab (length == n_workers). Worker
    # `wid` mutates ONLY slot `wid` (`worker_states[wid]`) — disjoint
    # per-worker destinations, no length change across the dispatch.
    # Reclaimed via Optional.take after the barrier.
    var worker_states: Optional[Slab[Optional[Self.WS]]]

    # Per-worker error channel (length == n_workers). Worker `wid`
    # writes ONLY slot `wid` on its own failure.
    var errors: Optional[List[Optional[String]]]

    # SAFETY: the SHARED work-stealing counter. Held as an
    # OwnedPointer[Atomic] so the Atomic lives at a STABLE heap address
    # that does not move while workers race `fetch_add` on it. Atomic is
    # non-Movable; the OwnedPointer is the POD handle. Every worker
    # reaches it via `state.counter[].fetch_add(1)`. The wake-word
    # barrier guarantees all workers exit before this (and the Atomic)
    # drops. This is the ONLY shared mutable state in the dispatch.
    var counter: OwnedPointer[AtomicI64]

    var work: Self.W
    var n_items: Int
    var n_workers: Int

    def __init__(
        out self,
        input_ptr: UnsafePointer[Self.In, Self.in_o],
        var worker_states: Slab[Optional[Self.WS]],
        var errors: List[Optional[String]],
        var work: Self.W,
        n_items: Int,
        n_workers: Int,
    ):
        self.input_ptr = input_ptr
        self.worker_states = Optional[Slab[Optional[Self.WS]]](worker_states^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.work = work^
        self.n_items = n_items
        self.n_workers = n_workers

        # Shared atomic counter at a stable heap address. Non-Movable
        # inner; in-place init on the `.value` slot (Repro 1b / 8).
        var raw = alloc[AtomicI64](1)
        raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
            Scalar[DType.int64](0)
        )
        self.counter = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw
        )


# =============================================================================
# _StealTask[W, In, WS, in_o] — POD Segment. Dispatched as n_workers
# task instances; task_id == the worker's own slot index.
# =============================================================================


@fieldwise_init
struct _StealTask[
    W: StealWork,
    In: Deinitable,
    WS: Movable & Deinitable,
    in_o: ImmOrigin,
](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: parameterized over the concrete
        # (_StealState[W,In,WS,in_o], _StealTask[W,In,WS,in_o]) at the
        # run_with_state[State,T] site; bitcast resolves to concrete.
        var sp = UnsafePointer(to=state).bitcast[
            _StealState[Self.W, Self.In, Self.WS, Self.in_o]
        ]()
        # task_id is this worker's OWN disjoint slot index in [0,n_workers).
        var slot = Int(task_id)
        var n_items = sp[].n_items
        var n_workers = sp[].n_workers
        if slot >= n_workers:
            return

        # Reach this worker's own accumulator slot (disjoint per-worker).
        ref ws_slot = sp[].worker_states.value().get_mut_interior(slot)
        if not ws_slot:
            return
        ref ws = ws_slot.value()

        # WORK-STEALING LOOP: pull the next item off the SHARED atomic
        # counter until the item space is exhausted. Faster workers grab
        # more items (dynamic load balance). The fetch_add is the ONLY
        # synchronization; each item index is returned to exactly one
        # worker (no double-grab, no skip).
        while True:
            # Short-circuit: another worker already failed.
            if sp[].errors.value()[slot]:
                return
            var item = Int(sp[].counter[].fetch_add(Int64(1)))
            if item >= n_items:
                return
            try:
                sp[].work.process_item[Self.In, Self.WS](
                    item,
                    n_items,
                    sp[].input_ptr[],
                    ws,
                )
            except e:
                sp[].errors.value()[slot] = Optional[String](String(e))
                return


# =============================================================================
# Serial fallback — byte-identical to the parallel path. ONE worker
# state; every item folds into it in ascending order.
# =============================================================================


def _run_serial_steal[
    W: StealWork,
    In: Deinitable,
    WS: Movable & Deinitable,
](
    work: W,
    ref input: In,
    n_items: Int,
    mut worker_states: Slab[Optional[WS]],
) raises:
    """Serial fallback. A single worker-state in slot 0 absorbs every
    item in ascending index order. The CALLER's merge of a length-1
    Slab[Optional[WS]] is the identity (one accumulator)."""
    if worker_states.len() == 0:
        return
    ref ws_slot = worker_states.get_mut_interior(0)
    if not ws_slot:
        return
    ref ws = ws_slot.value()
    var item = 0
    while item < n_items:
        work.process_item[In, WS](item, n_items, input, ws)
        item = item + 1


# =============================================================================
# Shared impl — builds the per-worker accumulator Slab (one fresh WS per
# worker), dispatches via run_with_state (parallel) or _run_serial_steal
# (fallback), drains the error channel, returns the per-worker states.
# =============================================================================


def _parallel_steal_impl[
    W: StealWork,
    In: Deinitable,
    WS: Movable & Deinitable,
    in_o: ImmOrigin,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    n_items: Int,
    min_parallel_items: Int,
    max_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> Slab[Optional[WS]]:
    """Shared body. Returns a `Slab[Optional[WS]]` of per-worker
    accumulators (length == effective worker count, or 1 on the serial
    path). The CALLER merges them.

    `max_workers` is an OPTIONAL caller cap: 0 (the sentinel default)
    means "use the dispatcher's hardware-derived worker_count()"; > 0
    caps the shard count below the pool. The effective worker count is
    always hardware-derived from the dispatcher, never a constant.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: worker `wid` (== task_id) accumulates ONLY into
        `worker_states[wid]` and writes ONLY `errors[wid]`. `input` is
        read-only. Items are claimed off the SHARED atomic counter via
        `fetch_add` — each item to exactly one worker (no double-grab).
        The WORK's own disjointness (which bytes of `input` item `i`
        reads) is the call site's contract.
      * Liveness: run_with_state is a synchronous wake-word barrier;
        State is borrowed-mut by the driver, `input` outlives the call
        by stack discipline (in_o concrete), State moved in atomically.
        The shared Atomic lives at a stable heap address (OwnedPointer)
        for the whole race; the barrier guarantees no worker touches it
        after it could drop.
      * No-realloc: `worker_states` + `errors` pre-sized to n_workers
        before dispatch; workers ONLY index-assign their own slot.
    """
    # n_items == 0: no work. Return an empty per-worker Slab.
    if n_items == 0:
        _ = cancel_token^
        _ = work^
        return Slab[Optional[WS]]()

    var go_parallel: Bool = has_pool and n_items >= min_parallel_items

    # Decide the effective worker count.
    var n_workers: Int = 1

    comptime if has_pool:
        if go_parallel:
            # Effective worker count is HARDWARE-DERIVED from the
            # dispatcher's pool. NOT a hardcoded constant. `max_workers`
            # is an OPTIONAL explicit caller cap.
            var disp = dispatcher_ptr.value()
            var wc = disp[].worker_count()
            if max_workers > 0 and wc > max_workers:
                wc = max_workers
            # Never spin up more workers than items.
            if wc > n_items:
                wc = n_items
            if wc < 1:
                wc = 1
            n_workers = wc

    # Build the per-worker accumulator Slab (one fresh WS per worker).
    # The factory fills a None out_slot in place (avoids the opaque-WS
    # default-ctor wall — see StealWork.init_worker_state).
    var worker_states = Slab[Optional[WS]]()
    for _ in range(n_workers):
        var slot = Optional[WS](None)
        work.init_worker_state[WS](n_items, slot)
        worker_states.append(slot^)

    var errors = List[Optional[String]]()
    for _ in range(n_workers):
        errors.append(Optional[String](None))

    comptime if has_pool:
        if go_parallel:
            var disp = dispatcher_ptr.value()

            # Borrow input through its CONCRETE IMMUTABLE origin.
            var input_ptr = UnsafePointer(to=input).unsafe_origin_cast[in_o]()
            var state = _StealState[W, In, WS, in_o](
                input_ptr,
                worker_states^,
                errors^,
                work^,
                n_items,
                n_workers,
            )
            var task = _StealTask[W, In, WS, in_o](Int32(0))
            # Dispatch EXACTLY n_workers task instances — task_id is the
            # worker's own slot index. (run_with_state clamps to
            # min(worker_count, n) internally.)
            _ = disp[].run_with_state[
                _StealState[W, In, WS, in_o],
                _StealTask[W, In, WS, in_o],
            ](state, task^, n_workers, cancel_token^, site_id=site_id)
            # Reclaim via Optional.take (the ownership-reclaim rule).
            worker_states = state.worker_states.take()
            errors = state.errors.take()
            _ = state^
        else:
            _ = cancel_token^
            _run_serial_steal[W, In, WS](work, input, n_items, worker_states)
            _ = work^
    else:
        _ = cancel_token^
        _run_serial_steal[W, In, WS](work, input, n_items, worker_states)
        _ = work^

    # Drain error channel; re-raise first failure.
    var e = 0
    while e < worker_states.len():
        if e < len(errors) and errors[e]:
            var msg = errors[e].value().copy()
            _ = worker_states^
            raise Error(
                "parallel_steal: worker " + String(e) + " failed: " + msg
            )
        e = e + 1
    return worker_states^


# =============================================================================
# parallel_steal — the public dispatcher-aware entry.
# =============================================================================


def parallel_steal[
    W: StealWork,
    In: Deinitable,
    WS: Movable & Deinitable,
    in_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    n_items: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    min_parallel_items: Int = 2,
    max_workers: Int = 0,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> Slab[Optional[WS]]:
    """Dispatcher-aware work-stealing entry. Caller threads
    `ctx.dispatcher()` + `ctx.cancel_token()`.

    Dispatches `n_workers` task instances over a shared atomic
    work-counter; every worker pulls item indices off the counter via
    `fetch_add(1)` and folds each into its OWN per-worker accumulator
    `WS`. Returns a `Slab[Optional[WS]]` of length `n_workers` (the
    per-worker accumulators) — the CALLER merges them.

    Worker count is HARDWARE-DERIVED by default from the dispatcher's
    pool (`dispatcher.worker_count()`). There is NO hardcoded worker
    cap.

    Args:
      n_items: Total number of work items (the counter exhausts at this).
      min_parallel_items: Below this item count the helper runs the
        serial fallback (avoids dispatch overhead on tiny work).
      max_workers: OPTIONAL explicit caller cap on the shard count.
        Default 0 means "use the dispatcher's hardware-derived worker
        count". When > 0 the effective count is
        min(n_items, max_workers, dispatcher.worker_count()).
      site_id: sched-trace call-site label for the fork this helper
        dispatches. Defaults to SITE_GENERIC_FORK_JOIN so
        a caller that does not care still lands in a NAMED bucket instead of the
        anonymous id-0 "OTHER". A caller that wants its own SCHED_SITE row passes
        its own SITE_* id (add the constant to `sched_trace.mojo` AND the
        `_sched_site_name` switch in `_posix_shim.c`). Plain runtime UInt32, not
        a comptime axis; zero cost when tracing is off."""
    return _parallel_steal_impl[
        W, In, WS, in_o, has_pool=True, disp_o=disp_o
    ](
        work^,
        input,
        n_items,
        min_parallel_items,
        max_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
        site_id=site_id,
    )


def parallel_steal_serial[
    W: StealWork,
    In: Deinitable,
    WS: Movable & Deinitable,
    in_o: ImmOrigin,
](
    var work: W,
    ref [in_o] input: In,
    n_items: Int,
) raises -> Slab[Optional[WS]]:
    """Serial-fallback entry (no dispatcher). Returns a length-1
    `Slab[Optional[WS]]` (the single accumulator). Callers without a
    EngineContext-owned dispatcher hit this; the byte-faithful
    reference path for the parallel dispatch."""
    return _parallel_steal_impl[
        W, In, WS, in_o, has_pool=False, disp_o=MutAnyOrigin
    ](
        work^,
        input,
        n_items,
        2,
        0,  # max_workers unused on the serial path (has_pool=False).
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )
