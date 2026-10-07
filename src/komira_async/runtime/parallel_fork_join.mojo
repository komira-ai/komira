# =============================================================================
# parallel_fork_join — the shared fork-join layer over
# LocalDispatcher.run_with_state.
#
# Owns ONCE: the State/Task wrapper, the run_with_state call, the
# _serial/_with_dispatcher/_impl 3-entry split, the immutable-origin
# borrow, the Optional.take owned-output reclaim, and the error-caught
# safety contract. Call sites provide only (n_chunks, the ChunkWork
# descriptor, the borrowed input, and bind In/O).
#
# Promoted from the poc_parallel_fork_join probe (never committed, so nothing
# in git recovers it) — 3 GREEN POCs: poc_drive / poc_two_shapes /
# poc_parallel, the last drives the FULL parallel path through a real
# multi-worker PerCoreAsyncRuntime.
#
# The helper OWNS the full safety contract so call sites can't break it:
#   * immutable-origin borrow (`in_o: ImmutOrigin`, NO wildcard)
#   * `Optional.take()` reclaim with chunk errors CAUGHT so reclaim
#     always runs (the ownership-reclaim rule)
#   * disjoint pre-sized `Slab[Optional[O]]` (workers ONLY index-assign)
#   * keepalive-through-barrier (run_with_state is a synchronous wake-word
#     barrier; State is borrowed-mut by the driver)
#
# =============================================================================

from komira_async.runtime.sched_trace import SITE_GENERIC_FORK_JOIN
from std.memory import UnsafePointer

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_collections.slab import Slab
from komira_async_api.worker_pool_traits import KeepAlive, Segment


# =============================================================================
# _ForkJoinState[W, In, O, in_o] — generic dispatch State.
# =============================================================================


struct _ForkJoinState[
    W: ChunkWork,
    In: Deinitable,
    O: Movable & Deinitable,
    in_o: ImmOrigin,
](KeepAlive, Movable):
    # SAFETY: internal typed pointer to the caller's read-only input.
    # `in_o` is CONCRETE (not wildcard); the wake-word barrier in
    # run_with_state guarantees no worker dereferences it after the
    # caller's input could go out of scope. Never exposed publicly.
    var input_ptr: UnsafePointer[Self.In, Self.in_o]
    var outputs: Optional[Slab[Optional[Self.O]]]
    var errors: Optional[List[Optional[String]]]
    var work: Self.W
    var n_chunks: Int
    var n_workers: Int

    def __init__(
        out self,
        input_ptr: UnsafePointer[Self.In, Self.in_o],
        var outputs: Slab[Optional[Self.O]],
        var errors: List[Optional[String]],
        var work: Self.W,
        n_chunks: Int,
        n_workers: Int,
    ):
        self.input_ptr = input_ptr
        self.outputs = Optional[Slab[Optional[Self.O]]](outputs^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.work = work^
        self.n_chunks = n_chunks
        self.n_workers = n_workers


# =============================================================================
# _ForkJoinTask[W, In, O, in_o] — POD Segment.
# =============================================================================


@fieldwise_init
struct _ForkJoinTask[
    W: ChunkWork,
    In: Deinitable,
    O: Movable & Deinitable,
    in_o: ImmOrigin,
](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: parameterized over the concrete
        # (_ForkJoinState[W,In,O,in_o], _ForkJoinTask[W,In,O,in_o]) at
        # the run_with_state[State,T] site; bitcast resolves to concrete.
        var sp = UnsafePointer(to=state).bitcast[
            _ForkJoinState[Self.W, Self.In, Self.O, Self.in_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var n_chunks = sp[].n_chunks
        var c = tid
        while c < n_chunks:
            if sp[].errors.value()[c]:
                c = c + n_workers
                continue
            try:
                ref out_slot = sp[].outputs.value().get_mut_interior(c)
                sp[].work.process[Self.In, Self.O](
                    c,
                    n_chunks,
                    sp[].input_ptr[],
                    out_slot,
                )
            except e:
                sp[].errors.value()[c] = Optional[String](String(e))
            c = c + n_workers


# =============================================================================
# parallel_fork_join — the public 3-entry surface, collapsed into ONE
# generic helper. Returns a Slab[Optional[O]] of per-chunk outputs (one
# slot per chunk, in chunk order) — the caller fans them in.
#
# The three historical entry points (_serial / _with_dispatcher / _impl)
# collapse to: (a) `parallel_fork_join` (dispatcher-aware) and (b)
# `parallel_fork_join_serial` (no dispatcher). Both route through
# `_parallel_fork_join_impl[..., has_pool]`.
# =============================================================================


def _run_serial[
    W: ChunkWork,
    In: Deinitable,
    O: Movable & Deinitable,
](
    work: W,
    ref input: In,
    n_chunks: Int,
    mut outputs: Slab[Optional[O]],
) raises:
    """Serial fallback — byte-identical to the parallel path; no
    dispatcher, no State/Task. Each chunk's WORK runs inline."""
    var c = 0
    while c < n_chunks:
        ref out_slot = outputs.get_mut_interior(c)
        work.process[In, O](c, n_chunks, input, out_slot)
        c = c + 1


def _parallel_fork_join_impl[
    W: ChunkWork,
    In: Deinitable,
    O: Movable & Deinitable,
    in_o: ImmOrigin,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    n_chunks: Int,
    min_parallel_chunks: Int,
    max_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> Slab[Optional[O]]:
    """Shared body. Builds the per-chunk output Slab (pre-filled None),
    dispatches via run_with_state (parallel) or _run_serial (fallback),
    drains the error channel, returns the outputs Slab.

    `max_workers` is an OPTIONAL caller cap: 0 (the sentinel default)
    means "use the dispatcher's hardware-derived worker_count()"; > 0
    caps the shard count below the pool. The effective worker count is
    always hardware-derived from the dispatcher, never a constant.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: worker `tid` writes ONLY chunk-`c` slots with
        `c % n_workers == tid` in `outputs` + `errors`. `input` is
        read-only. The WORK's own disjointness (which bytes of `input`
        chunk `c` reads) is the call site's contract — the SAME contract
        the hand-written bodies carried.
      * Liveness: run_with_state is a synchronous wake-word barrier;
        State is borrowed-mut by the driver, `input` outlives the call
        by stack discipline (in_o concrete), State moved in atomically.
      * No-realloc: `outputs` + `errors` pre-sized to n_chunks before
        dispatch; workers ONLY index-assign.
    """
    # Build per-chunk output Slab (Movable-only O -> Slab, not List).
    var outputs = Slab[Optional[O]]()
    for _ in range(n_chunks):
        outputs.append(Optional[O](None))
    if n_chunks == 0:
        _ = cancel_token^
        _ = work^
        return outputs^

    var errors = List[Optional[String]]()
    for _ in range(n_chunks):
        errors.append(Optional[String](None))

    var go_parallel: Bool = has_pool and n_chunks >= min_parallel_chunks

    comptime if has_pool:
        if go_parallel:
            # Effective worker count is HARDWARE-DERIVED from the
            # dispatcher's pool (the dispatcher's worker_count() == the
            # number of attached workers == the runtime's core-sized
            # pool). NOT a hardcoded constant. `max_workers` is an
            # OPTIONAL explicit caller cap: when 0 (the default) it is
            # ignored and the dispatcher count is used directly; when
            # > 0 it caps below the pool. The effective count never
            # exceeds n_chunks. run_with_state ALSO clamps to
            # min(worker_count, n) internally, so this is the
            # belt-and-suspenders shard count we ask for.
            var disp = dispatcher_ptr.value()
            var n_workers = disp[].worker_count()
            if max_workers > 0 and n_workers > max_workers:
                n_workers = max_workers
            if n_workers > n_chunks:
                n_workers = n_chunks
            if n_workers < 1:
                n_workers = 1

            # Borrow input through its CONCRETE IMMUTABLE origin.
            var input_ptr = UnsafePointer(to=input).unsafe_origin_cast[in_o]()
            var state = _ForkJoinState[W, In, O, in_o](
                input_ptr,
                outputs^,
                errors^,
                work^,
                n_chunks,
                n_workers,
            )
            var task = _ForkJoinTask[W, In, O, in_o](Int32(0))
            _ = disp[].run_with_state[
                _ForkJoinState[W, In, O, in_o],
                _ForkJoinTask[W, In, O, in_o],
            ](state, task^, n_workers, cancel_token^, site_id=site_id)
            # Reclaim via Optional.take (the ownership-reclaim rule).
            outputs = state.outputs.take()
            errors = state.errors.take()
            _ = state^
        else:
            _ = cancel_token^
            _run_serial[W, In, O](work, input, n_chunks, outputs)
            _ = work^
    else:
        _ = cancel_token^
        _run_serial[W, In, O](work, input, n_chunks, outputs)
        _ = work^

    # Drain error channel; re-raise first failure.
    var e = 0
    while e < n_chunks:
        if errors[e]:
            var msg = errors[e].value().copy()
            _ = outputs^
            raise Error(
                "parallel_fork_join: chunk " + String(e) + " failed: " + msg
            )
        e = e + 1
    return outputs^


def parallel_fork_join[
    W: ChunkWork,
    In: Deinitable,
    O: Movable & Deinitable,
    in_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    n_chunks: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    min_parallel_chunks: Int = 2,
    max_workers: Int = 0,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> Slab[Optional[O]]:
    """Dispatcher-aware entry. Caller threads `ctx.dispatcher()` +
    `ctx.cancel_token()`.

    Worker count is HARDWARE-DERIVED by default from the dispatcher's
    pool (`dispatcher.worker_count()` == the number of attached workers
    == the runtime's core-sized pool). There is NO hardcoded worker
    cap.

    Args:
      min_parallel_chunks: Below this chunk count the helper runs the
        serial fallback (avoids dispatch overhead on tiny work). A small
        fixed threshold; intentionally NOT core-related.
      max_workers: OPTIONAL explicit caller cap on the shard count.
        Default 0 means "use the dispatcher's hardware-derived worker
        count". When > 0 the effective count is
        min(n_chunks, max_workers, dispatcher.worker_count()) — an
        explicit cap that still never exceeds the pool.
      site_id: sched-trace call-site label for the fork this helper
        dispatches. Defaults to SITE_GENERIC_FORK_JOIN so
        a caller that does not care still lands in a NAMED bucket instead of the
        anonymous id-0 "OTHER". These helpers
        have many callers (csv / jsonl
        / avro / row-streaming) which would otherwise share ONE bucket — a caller
        that wants its own SCHED_SITE row passes its own SITE_* id (add the
        constant to `sched_trace.mojo` AND the `_sched_site_name` switch in
        `_posix_shim.c`). Plain runtime UInt32, not a comptime axis: no extra
        elaboration, and zero cost when tracing is off."""
    return _parallel_fork_join_impl[
        W, In, O, in_o, has_pool=True, disp_o=disp_o
    ](
        work^,
        input,
        n_chunks,
        min_parallel_chunks,
        max_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
        site_id=site_id,
    )


def parallel_fork_join_serial[
    W: ChunkWork,
    In: Deinitable,
    O: Movable & Deinitable,
    in_o: ImmOrigin,
](
    var work: W,
    ref [in_o] input: In,
    n_chunks: Int,
) raises -> Slab[Optional[O]]:
    """Serial-fallback entry (no dispatcher). Callers without a
    EngineContext-owned dispatcher hit this."""
    return _parallel_fork_join_impl[
        W, In, O, in_o, has_pool=False, disp_o=MutAnyOrigin
    ](
        work^,
        input,
        n_chunks,
        2,
        0,  # max_workers unused on the serial path (has_pool=False).
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )
