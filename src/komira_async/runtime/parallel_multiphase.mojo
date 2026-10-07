# =============================================================================
# parallel_multiphase — the MULTI-PHASE fork-join layer over
# LocalDispatcher.run_with_state. The agg-kernel sibling of
# `parallel_steal` (single work-stealing pass) and `parallel_fork_join`
# (single static-stride pass).
#
# Owns ONCE, ACROSS the phase barrier:
#   * the per-worker band Slab (`Slab[Optional[Band]]`, length n_workers)
#     — built once, kept LIVE at stable heap addresses from the Phase-1
#     work-stealing fill through every static Phase-N pass, reclaimed via
#     `Optional.take` only after the LAST phase.
#   * the SHARED ATOMIC morsel counter — held as an
#     `OwnedPointer[Atomic[int64]]` so the Atomic lives at a STABLE heap
#     address that does not move while Phase-1 workers race `fetch_add`.
#   * the immutable concrete-origin input borrow (`in_o: ImmutOrigin`,
#     NO wildcard).
#   * the hardware-derived worker count (`dispatcher.worker_count()`).
#   * the serial fallback + the error-caught contract.
#
# THE MAKE-OR-BREAK SAFETY QUESTION (multi-phase-specific):
#   The per-worker bands must survive the Phase-1 -> Phase-N barrier with
#   their heap intact (the destroy-recreate hazard) and at stable addresses (Phase-N tasks index
#   them by [worker]). We hold them on a SINGLE State struct
#   (`_MultiPhaseState`) that is borrowed-mut by the driver across EVERY
#   `run_with_state` dispatch. The bands live in an `Optional[Slab[...]]`
#   field on that State; the State is built once on the driver stack and
#   the SAME `state` reference flows into Phase 1 then each Phase-N
#   dispatch. No wildcard origin, no re-wrap, no flatten — the State's
#   own lifetime (which the compiler tracks) pins the bands across the
#   barriers, exactly the proven `agg_radix` RadixState shape, centralized.
#
# The helper OWNS the full safety contract so call sites can't break it:
#   * immutable-origin input borrow (`in_o: ImmutOrigin`, NO wildcard)
#   * shared atomic counter at a stable heap address (OwnedPointer[Atomic])
#   * persisted per-worker `Slab[Optional[Band]]` (worker `wid` writes ONLY
#     band `wid` in; Phase-N task `p` touches ONLY partition-p
#     slots across the bands; reclaimed via `Optional.take` after the last
#     phase — the ownership-reclaim rule)
#   * keepalive-through-barrier (run_with_state is a synchronous wake-word
#     barrier; State is borrowed-mut by the driver across every phase)
#
#
# =============================================================================

from komira_async.runtime.sched_trace import SITE_GENERIC_FORK_JOIN
from std.memory import alloc, OwnedPointer, UnsafePointer
from komira_atomic_alias import AtomicI64

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.multiphase_work import MultiPhaseWork
from komira_collections.slab import Slab
from komira_async_api.worker_pool_traits import KeepAlive, Segment


# =============================================================================
# _MultiPhaseState[W, In, Band, in_o] — generic multi-phase dispatch State.
# Built ONCE on the driver stack; borrowed-mut by the Phase-1 task AND
# every Phase-N task. The bands + atomic counter + input borrow all live
# on it for the WHOLE multi-phase window.
# =============================================================================


struct _MultiPhaseState[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
    in_o: ImmOrigin,
](KeepAlive, Movable):
    # SAFETY: internal typed pointer to the caller's read-only input.
    # `in_o` is CONCRETE (not wildcard); the wake-word barrier in
    # run_with_state guarantees no worker dereferences it after the
    # caller's input could go out of scope. Read-only during Phase 1 (the
    # only phase that touches `input`). Never exposed publicly.
    var input_ptr: UnsafePointer[Self.In, Self.in_o]

    # OWNED per-worker band Slab (length == n_workers). PERSISTED across
    # the Phase-1 -> Phase-N barrier: built once, NOT reclaimed between
    # phases, lives at a stable heap address (the Slab's own backing
    # buffer) for the whole multi-phase window. worker `wid`
    # mutates ONLY band `wid`. Phase N: task `p` touches ONLY partition-p
    # slots across all bands. Reclaimed via Optional.take after the LAST
    # phase.
    var bands: Optional[Slab[Optional[Self.Band]]]

    # Per-worker error channel (length == n_workers). Worker `wid` writes
    # ONLY slot `wid` on its own failure; a Phase-N partition
    # task `p` writes slot `min(p, n_workers-1)` on failure (folded back
    # in the driver's drain).
    var errors: Optional[List[Optional[String]]]

    # SAFETY: the SHARED Phase-1 work-stealing counter. Held as an
    # OwnedPointer[Atomic] so the Atomic lives at a STABLE heap address
    # that does not move while Phase-1 workers race `fetch_add`. Atomic is
    # non-Movable; the OwnedPointer is the POD handle. Every Phase-1 worker
    # reaches it via `state.counter[].fetch_add(1)`. The wake-word barrier
    # guarantees all workers exit before this drops. Touched ONLY in
    #
    var counter: OwnedPointer[AtomicI64]

    var work: Self.W
    var n_items: Int
    var n_workers: Int
    var n_partitions: Int
    # The 1-based static-pass index the CURRENT Phase-N dispatch is running
    # (set by the driver before each Phase-N run_with_state). Phase-N tasks
    # read it to know which pass they are (merge vs emit ...).
    var phase_no: Int

    def __init__(
        out self,
        input_ptr: UnsafePointer[Self.In, Self.in_o],
        var bands: Slab[Optional[Self.Band]],
        var errors: List[Optional[String]],
        var work: Self.W,
        n_items: Int,
        n_workers: Int,
        n_partitions: Int,
    ):
        self.input_ptr = input_ptr
        self.bands = Optional[Slab[Optional[Self.Band]]](bands^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.work = work^
        self.n_items = n_items
        self.n_workers = n_workers
        self.n_partitions = n_partitions
        self.phase_no = 0

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
# _MultiPhaseProcessTask — Phase 1 (work-stealing fill) POD Segment.
# Dispatched as n_workers task instances; task_id == the worker's own
# band index. Each worker `wid` claims morsels off the shared atomic
# counter and scatters each into band[wid].
# =============================================================================


@fieldwise_init
struct _MultiPhaseProcessTask[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
    in_o: ImmOrigin,
](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: parameterized over the concrete
        # (_MultiPhaseState[W,In,Band,in_o], _MultiPhaseProcessTask[...]) at
        # the run_with_state[State,T] site; bitcast resolves to concrete.
        var sp = UnsafePointer(to=state).bitcast[
            _MultiPhaseState[Self.W, Self.In, Self.Band, Self.in_o]
        ]()
        var slot = Int(task_id)
        var n_items = sp[].n_items
        var n_workers = sp[].n_workers
        if slot >= n_workers:
            return

        # Reach this worker's own band slot (disjoint per-worker).
        ref band_slot = sp[].bands.value().get_mut_interior(slot)
        if not band_slot:
            return
        ref band = band_slot.value()

        # WORK-STEALING LOOP: pull the next morsel off the SHARED atomic
        # counter until exhausted. Each morsel index goes to exactly one
        # worker (the fetch_add is the only synchronization).
        while True:
            if sp[].errors.value()[slot]:
                return
            var item = Int(sp[].counter[].fetch_add(Int64(1)))
            if item >= n_items:
                return
            try:
                sp[].work.process_morsel[Self.In, Self.Band](
                    item,
                    n_items,
                    sp[].input_ptr[],
                    band,
                )
            except e:
                sp[].errors.value()[slot] = Optional[String](String(e))
                return


# =============================================================================
# _MultiPhasePartitionTask —..N (static partition pass) POD
# Segment. Dispatched as n_partitions task instances; task_id == the
# partition this task owns. Operates on partition-p across ALL worker
# bands. Re-used for every static pass; reads `state.phase_no` to know
# which pass it is.
# =============================================================================


@fieldwise_init
struct _MultiPhasePartitionTask[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
    in_o: ImmOrigin,
](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[
            _MultiPhaseState[Self.W, Self.In, Self.Band, Self.in_o]
        ]()
        var p = Int(task_id)
        var n_partitions = sp[].n_partitions
        if p >= n_partitions:
            return
        var n_workers = sp[].n_workers
        var phase_no = sp[].phase_no
        # Error slot for a partition task: fold into a worker slot (the
        # error channel is sized to n_workers; partition tasks reuse it).
        var err_slot = p
        if err_slot >= n_workers:
            err_slot = n_workers - 1
        if err_slot < 0:
            err_slot = 0
        if sp[].errors.value()[err_slot]:
            return
        try:
            sp[].work.process_partition[Self.Band](
                phase_no,
                p,
                n_partitions,
                n_workers,
                sp[].bands.value(),
            )
        except e:
            sp[].errors.value()[err_slot] = Optional[String](String(e))


# =============================================================================
# Serial fallback — byte-identical to the parallel path. ONE band; every
# morsel folds into it in ascending order, then each static
# partition pass runs serially over the single band (n_workers == 1).
# =============================================================================


def _run_serial_multiphase[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
](
    work: W,
    ref input: In,
    n_items: Int,
    n_partitions: Int,
    n_static_phases: Int,
    mut bands: Slab[Optional[Band]],
) raises:
    """Serial fallback. A single band in slot 0 absorbs every morsel in
    ascending index order, then each static partition pass runs
    serially (n_workers == 1) over that single band. The CALLER's merge of
    a length-1 Slab[Optional[Band]] is the identity (one band)."""
    if bands.len() == 0:
        return
    #
    ref band_slot = bands.get_mut_interior(0)
    if not band_slot:
        return
    var item = 0
    while item < n_items:
        work.process_morsel[In, Band](
            item, n_items, input, band_slot.value()
        )
        item = item + 1
    # run each static pass serially over the single band.
    var phase = 1
    while phase <= n_static_phases:
        var p = 0
        while p < n_partitions:
            work.process_partition[Band](phase, p, n_partitions, 1, bands)
            p = p + 1
        phase = phase + 1


# =============================================================================
# Shared impl — builds the per-worker band Slab (one fresh Band per
# worker), runs Phase 1 (work-stealing) then each static Phase-N over the
# SAME persisted bands, drains the error channel, returns the bands.
# =============================================================================


def _parallel_multiphase_impl[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
    in_o: ImmOrigin,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    n_items: Int,
    n_partitions: Int,
    n_static_phases: Int,
    min_parallel_items: Int,
    max_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> Slab[Optional[Band]]:
    """Shared body. Returns the per-worker `Slab[Optional[Band]]` (length
    == effective worker count on the parallel path, or 1 on the serial
    path) AFTER all phases have run. The CALLER does the final
    driver-side fold of worker-0's partitions.

    `max_workers` is an OPTIONAL caller cap: 0 (the sentinel default)
    means "use the dispatcher's hardware-derived worker_count()"; > 0
    caps the shard count below the pool.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: worker `wid` (== task_id) scatters ONLY
        into band `wid`; morsels are claimed off the SHARED atomic counter
        (each to exactly one worker, no double-grab). `input` is read-only.
      * Disjointness: partition task `p` touches ONLY partition-p
        slots across the bands (the consumer's contract).
      * Liveness: the SAME State (and hence the bands + the atomic counter)
        is borrowed-mut across EVERY phase's run_with_state; each is a
        synchronous wake-word barrier so workers cannot outlive the State.
        The bands persist (stable address) for the whole window.
      * No-realloc: `bands` + `errors` pre-sized to n_workers before any
        dispatch; the band Slab length never changes across phases.
    """
    if n_items == 0:
        _ = cancel_token^
        _ = work^
        return Slab[Optional[Band]]()

    var go_parallel: Bool = has_pool and n_items >= min_parallel_items

    # Decide the effective worker count (HARDWARE-DERIVED).
    var n_workers: Int = 1

    comptime if has_pool:
        if go_parallel:
            var disp = dispatcher_ptr.value()
            var wc = disp[].worker_count()
            if max_workers > 0 and wc > max_workers:
                wc = max_workers
            if wc > n_items:
                wc = n_items
            if wc < 1:
                wc = 1
            n_workers = wc

    # Build the per-worker band Slab (one fresh Band per worker). The
    # factory fills a None out_slot in place (avoids the opaque-Band
    # default-ctor wall — see MultiPhaseWork.init_band).
    var bands = Slab[Optional[Band]]()
    for _ in range(n_workers):
        var slot = Optional[Band](None)
        work.init_band[Band](n_partitions, n_items, slot)
        bands.append(slot^)

    var errors = List[Optional[String]]()
    for _ in range(n_workers):
        errors.append(Optional[String](None))

    comptime if has_pool:
        if go_parallel:
            var disp = dispatcher_ptr.value()

            # Borrow input through its CONCRETE IMMUTABLE origin.
            var input_ptr = UnsafePointer(to=input).unsafe_origin_cast[in_o]()
            var state = _MultiPhaseState[W, In, Band, in_o](
                input_ptr,
                bands^,
                errors^,
                work^,
                n_items,
                n_workers,
                n_partitions,
            )

            # --- n_workers task instances ---
            var proc_task = _MultiPhaseProcessTask[W, In, Band, in_o](
                Int32(0)
            )
            _ = disp[].run_with_state[
                _MultiPhaseState[W, In, Band, in_o],
                _MultiPhaseProcessTask[W, In, Band, in_o],
            ](state, proc_task^, n_workers, cancel_token.clone(), site_id=site_id)

            # ---..N (static partition passes): n_partitions tasks
            # each, over the SAME persisted bands on `state`. Each phase
            # clones the cancel_token (the parameter token is consumed once
            # after the loop — keeps the move out of the loop body so the
            # compiler can prove single-consume). ---
            var phase = 1
            while phase <= n_static_phases:
                state.phase_no = phase
                var part_task = _MultiPhasePartitionTask[W, In, Band, in_o](
                    Int32(0)
                )
                _ = disp[].run_with_state[
                    _MultiPhaseState[W, In, Band, in_o],
                    _MultiPhasePartitionTask[W, In, Band, in_o],
                ](state, part_task^, n_partitions, cancel_token.clone(), site_id=site_id)
                phase = phase + 1

            # Consume the parameter cancel_token exactly once (and
            # every static phase used clones).
            _ = cancel_token^

            # Reclaim via Optional.take (the ownership-reclaim rule) AFTER all
            # phases.
            bands = state.bands.take()
            errors = state.errors.take()
            _ = state^
        else:
            _ = cancel_token^
            _run_serial_multiphase[W, In, Band](
                work, input, n_items, n_partitions, n_static_phases, bands
            )
            _ = work^
    else:
        _ = cancel_token^
        _run_serial_multiphase[W, In, Band](
            work, input, n_items, n_partitions, n_static_phases, bands
        )
        _ = work^

    # Drain error channel; re-raise first failure.
    var e = 0
    while e < len(errors):
        if errors[e]:
            var msg = errors[e].value().copy()
            _ = bands^
            raise Error(
                "parallel_multiphase: worker/partition "
                + String(e)
                + " failed: "
                + msg
            )
        e = e + 1
    return bands^


# =============================================================================
# parallel_multiphase — the public dispatcher-aware entry.
# =============================================================================


def parallel_multiphase[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
    in_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    n_items: Int,
    n_partitions: Int,
    n_static_phases: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    min_parallel_items: Int = 2,
    max_workers: Int = 0,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> Slab[Optional[Band]]:
    """Dispatcher-aware multi-phase entry. Caller threads
    `ctx.dispatcher()` + `ctx.cancel_token()`.

    Runs a work-stealing Phase 1 (`n_workers` task instances pulling
    `n_items` morsels off a shared atomic counter, each scattered into the
    worker's own `Band`) followed by `n_static_phases` STATIC
    partition-strided passes (`n_partitions` task instances each, over the
    SAME persisted bands). Returns the per-worker `Slab[Optional[Band]]`
    (length `n_workers`) AFTER all phases — the CALLER does the final
    driver-side fold (read worker 0's now-merged partitions out).

    Worker count is HARDWARE-DERIVED by default from the dispatcher's pool
    (`dispatcher.worker_count()`). There is NO hardcoded worker cap.

    Args:
      n_items: Total Phase-1 work items (morsels); the counter exhausts
        at this.
      n_partitions: Per-band partition count; each static phase dispatches
        `n_partitions` task instances (task p owns partition p).
      n_static_phases: How many static partition passes to run after the
        Phase-1 fill (e.g. 1 = merge-only; 2 = merge + emit). `phase_no`
        (1-based) is passed to `process_partition` so one impl serves all.
      min_parallel_items: Below this item count the helper runs the serial
        fallback (avoids dispatch overhead on tiny work).
      max_workers: OPTIONAL explicit caller cap on the shard count.
        Default 0 means "use the dispatcher's hardware-derived worker
        count".
      site_id: sched-trace call-site label for the forks this helper
        dispatches. Defaults to SITE_GENERIC_FORK_JOIN so
        a caller that does not care still lands in a NAMED bucket instead of the
        anonymous id-0 "OTHER". A caller that wants its own SCHED_SITE row passes
        its own SITE_* id (add the constant to `sched_trace.mojo` AND the
        `_sched_site_name` switch in `_posix_shim.c`). Plain runtime UInt32, not
        a comptime axis; zero cost when tracing is off. NB all phases of one
        multiphase run share the label."""
    return _parallel_multiphase_impl[
        W, In, Band, in_o, has_pool=True, disp_o=disp_o
    ](
        work^,
        input,
        n_items,
        n_partitions,
        n_static_phases,
        min_parallel_items,
        max_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
        site_id=site_id,
    )


def parallel_multiphase_serial[
    W: MultiPhaseWork,
    In: Deinitable,
    Band: Movable & Deinitable,
    in_o: ImmOrigin,
](
    var work: W,
    ref [in_o] input: In,
    n_items: Int,
    n_partitions: Int,
    n_static_phases: Int,
) raises -> Slab[Optional[Band]]:
    """Serial-fallback entry (no dispatcher). Returns a length-1
    `Slab[Optional[Band]]` (the single band, AFTER all phases run
    serially over it). The byte-faithful reference path for the parallel
    dispatch."""
    return _parallel_multiphase_impl[
        W, In, Band, in_o, has_pool=False, disp_o=MutAnyOrigin
    ](
        work^,
        input,
        n_items,
        n_partitions,
        n_static_phases,
        2,
        0,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )
