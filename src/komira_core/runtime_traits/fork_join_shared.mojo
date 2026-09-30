# =============================================================================
# fork_join_shared — the DISPATCHER-GENERIC shared-payload fork-join driver.
# =============================================================================
#
# This is the ONE implementation of the shared-payload fork-join wave,
# generic over `D: ParallelDispatch`. `komira_async`'s
# `parallel_fork_join_shared` / `parallel_fork_join_shared_serial` /
# `SharedForkJoinHandle` are thin `D = LocalDispatcher[NoopSink]` bindings over
# it.
#
# WHY IT LIVES IN CORE. `komira_core/helpers/compiler_helpers.gather_batch` is
# stage 4 of EVERY `ORDER BY` (and of filter / join-output assembly). Running
# its parallel waves on Mojo's stdlib `parallelize(...)` pool would mean a
# second worker-class thread pool the topology scheduler cannot see, pin, or
# govern. `komira_core` is the foundational leaf that `komira_async` DEPENDS
# ON, so the gather cannot import an async-side driver; the driver therefore
# lives here, generic over the `ParallelDispatch` trait `komira_core` owns.
# The alternative — a second hand-rolled State/Task/driver inside core — would
# be a duplicate fork-join substrate. There is ONE disjoint-write fork-join,
# shared by the sort phases and the sort GATHER.
#
# WHY THE HANDLE IS NOT HERE. `SharedForkJoinHandle` stays in `komira_async`
# bound to the concrete `LocalDispatcher[NoopSink]`; genericizing it over `D`
# would re-parameterize a widely-named type for zero behavioural gain.
# Callers that need to hand a pooled dispatcher to a CORE entry point pass
# `handle.ptr` — an `Optional[Pointer[D, disp_o]]` — which is exactly the
# parameter shape below.
#
# DISPATCH-BOUNDARY SAFETY: see `_fork_join_shared_impl`'s docstring.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer

from komira_core.cancellation.token import CancellationToken
from komira_core.runtime_traits.parallel_dispatch import ParallelDispatch
from komira_core.runtime_traits.shared_chunk_work import SharedChunkWork
from komira_core.runtime_traits.worker_pool_traits import KeepAlive, Segment


@always_inline
def fork_join_pool_depth() -> Int64:
    """The process-global on-pool dispatch depth (`_OnPoolDispatchGuard` in
    `komira_async/reactor/_posix_shim.c`). > 0 == a `run_with_state` window is
    already live on this thread's process, so a nested wave must run its chunks
    INLINE (`run_with_state` raises "nested dispatch detected" otherwise).

    Read via `external_call` rather than through
    `komira_async.runtime.sched_trace.sched_trace_pool_depth` because this
    module is BELOW `komira_async`. Same symbol, same relaxed atomic load; the
    async-side reader remains the one the tracer uses."""
    return external_call["komira_on_pool_depth", Int64]()


# =============================================================================
# _SharedForkJoinState[W, In, P, in_o] — generic dispatch State.
# =============================================================================


struct _SharedForkJoinState[
    W: SharedChunkWork,
    In: Deinitable,
    P: Movable & Deinitable,
    in_o: ImmOrigin,
](KeepAlive, Movable):
    """Dispatch State for the shared-payload fork-join wave.

    Mirrors `_ForkJoinState` field-for-field except that the per-chunk
    `Slab[Optional[O]]` output slab is replaced by ONE `Optional[P]` payload
    that every chunk mutates at its own disjoint slots.
    """

    # SAFETY: internal typed pointer to the caller's read-only input.
    # `in_o` is CONCRETE (not wildcard); the wake-word barrier in
    # run_with_state guarantees no worker dereferences it after the caller's
    # input could go out of scope. Never exposed publicly.
    var input_ptr: UnsafePointer[Self.In, Self.in_o]

    # The ONE shared destination, MOVED in for the dispatch window and
    # reclaimed by the driver via `Optional.take()` after the barrier.
    var payload: Optional[Self.P]

    var errors: Optional[List[Optional[String]]]
    var work: Self.W
    var n_chunks: Int
    var n_workers: Int

    def __init__(
        out self,
        input_ptr: UnsafePointer[Self.In, Self.in_o],
        var payload: Self.P,
        var errors: List[Optional[String]],
        var work: Self.W,
        n_chunks: Int,
        n_workers: Int,
    ):
        self.input_ptr = input_ptr
        self.payload = Optional[Self.P](payload^)
        self.errors = Optional[List[Optional[String]]](errors^)
        self.work = work^
        self.n_chunks = n_chunks
        self.n_workers = n_workers


# =============================================================================
# _SharedForkJoinTask[W, In, P, in_o] — POD Segment.
# =============================================================================


@fieldwise_init
struct _SharedForkJoinTask[
    W: SharedChunkWork,
    In: Deinitable,
    P: Movable & Deinitable,
    in_o: ImmOrigin,
](Segment):
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: parameterized over the concrete
        # (_SharedForkJoinState[W,In,P,in_o], _SharedForkJoinTask[W,In,P,in_o])
        # at the run_with_state[State,T] site; the bitcast resolves to the
        # concrete State the driver built.
        var sp = UnsafePointer(to=state).bitcast[
            _SharedForkJoinState[Self.W, Self.In, Self.P, Self.in_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var n_chunks = sp[].n_chunks
        var c = tid
        while c < n_chunks:
            try:
                # SAFETY: every concurrent shard takes a `mut` reference to the
                # SAME payload. That aliasing is the documented
                # DISPATCH-BOUNDARY contract of `SharedChunkWork`: chunk `c`
                # writes ONLY slots that no other chunk writes, and the payload
                # is pre-sized by the driver so no chunk can realloc it under a
                # peer.
                ref pay = sp[].payload.value()
                sp[].work.process[Self.In, Self.P](
                    c, n_chunks, sp[].input_ptr[], pay
                )
            except e:
                sp[].errors.value()[c] = Optional[String](String(e))
            c = c + n_workers


# =============================================================================
# The driver: serial fallback + the dispatcher-generic impl.
# =============================================================================


def _run_shared_serial[
    W: SharedChunkWork,
    In: Deinitable,
    P: Movable & Deinitable,
](
    work: W,
    ref input: In,
    n_chunks: Int,
    mut payload: P,
    mut errors: List[Optional[String]],
) raises:
    """Serial fallback — byte-identical to the parallel path (the chunks write
    the same disjoint slots, just one after another). No dispatcher, no
    State/Task."""
    var c = 0
    while c < n_chunks:
        try:
            work.process[In, P](c, n_chunks, input, payload)
        except e:
            errors[c] = Optional[String](String(e))
        c = c + 1


def raise_first_chunk_error(imm errors: List[Optional[String]]) raises:
    """Drain the per-chunk error channel; re-raise the first failure."""
    var e = 0
    while e < len(errors):
        if errors[e]:
            var msg = errors[e].value().copy()
            raise Error(
                "parallel_fork_join_shared: chunk " + String(e)
                + " failed: " + msg
            )
        e = e + 1


def fork_join_shared[
    W: SharedChunkWork,
    In: Deinitable,
    P: Movable & Deinitable,
    in_o: ImmOrigin,
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    var payload: P,
    n_chunks: Int,
    min_parallel_chunks: Int,
    max_workers: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
    site_id: UInt32,
) raises -> P:
    """Dispatch the `n_chunks` chunks across `D`'s workers (or run them inline
    on the serial path), then hand the payload back to the caller.

    `D` is the monomorphized concrete dispatcher (`LocalDispatcher[NoopSink]` in
    production, `NoDispatch` on a pruned serial arm), so `run_with_state` +
    `worker_count` DEVIRTUALIZE per instantiation — no vtable, no perf cost vs.
    a hard-coded dispatcher.

    `max_workers` is an OPTIONAL caller cap: 0 (the sentinel default) means
    "use the dispatcher's hardware-derived worker_count()"; > 0 caps the shard
    count below the pool. The effective worker count is always hardware-derived
    from the dispatcher, never a constant.

    `site_id` is the sched-trace call-site label for the fork. It is
    REQUIRED here (no default) because a defaulted one leaves waves anonymous
    in `SITE_GENERIC_FORK_JOIN`: every caller states its own id, so each wave
    gets a NAMED row in the trace.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: shard `tid` runs chunks `c` with `c % n_workers == tid`.
        `input` is read-only. WHICH slots of `payload` chunk `c` writes is the
        call site's contract — the SAME contract the hand-written parallelize
        bodies carried, restated in each call site's own safety block.
      * Liveness: run_with_state is a synchronous wake-word barrier; State is
        borrowed-mut by the driver for the whole window, `input` outlives the
        call by stack discipline (`in_o` concrete, no wildcard), and `payload`
        is MOVED onto the State (so it is owned, not borrowed, across the
        barrier).
      * No-realloc: the payload's containers are pre-sized by the caller before
        the move; chunks only `setitem` live slots.
    """
    var errors = List[Optional[String]]()
    for _ in range(n_chunks):
        errors.append(Optional[String](None))

    if n_chunks == 0:
        _ = cancel_token^
        _ = work^
        return payload^

    # NESTED-DISPATCH FALLBACK. `run_with_state` RAISES "nested dispatch
    # detected" if a pool worker re-enters it. A kernel whose chunks themselves
    # reach a pooled wave (for example a cross-shard fan-out whose every chunk
    # runs a per-shard enumerate + decode wave) could otherwise not thread ONE
    # handle down BOTH levels — each level would have to statically pick
    # pooled-or-serial, and picking wrong would be a hard runtime error rather
    # than a slowdown.
    #
    # `komira_on_pool_depth` (the process-global `_OnPoolDispatchGuard` counter
    # that already brackets every `run_with_state` window) makes the choice
    # DYNAMIC instead: a wave that finds a dispatch already live runs its chunks
    # INLINE — on the worker thread it is already executing on, which is
    # precisely where the parallelism already is. The interlock covers every
    # shared-payload wave in one place.
    #
    # NO parallelism is lost: the outer wave already has all N workers busy, so
    # the inner wave had nothing left to fan out onto. What is gained is that a
    # pooled handle becomes SAFE to thread down an arbitrarily deep chain — the
    # outermost wave that finds depth 0 takes the pool and every nested one
    # degrades to inline, automatically.
    #
    # THE COUNTER IS PROCESS-GLOBAL, NOT PER-DISPATCHER — deliberately. With more
    # than one pool alive in a process (the engine's, plus e.g. a storage
    # reader's own pool), a wave on pool B while pool A is
    # mid-dispatch ALSO runs inline. Per-dispatcher state would let it fan out,
    # since the re-entrance CAS in `run_with_state` is per-dispatcher and would
    # not have objected. Global is the better default and the reason the second
    # pool is safe to add: it is an admission-control interlock between pools —
    # while the engine is actively dispatching and its workers own the box, a
    # concurrent reader wave declines to add N more runnable threads and
    # just does its (IO-blocked) work on the calling thread. The cost is a
    # conservative loss of parallelism in the genuinely-disjoint case; the
    # benefit is that two pools cannot stack their fan-outs on one box.
    #
    # Cost: ONE relaxed atomic load per wave, on the `has_pool=True` arm only
    # (the `@parameter if` below compiles it out entirely when has_pool=False),
    # and only when the wave would otherwise have dispatched.
    var go_parallel: Bool = has_pool and n_chunks >= min_parallel_chunks

    comptime if has_pool:
        if go_parallel and fork_join_pool_depth() > Int64(0):
            go_parallel = False

    comptime if has_pool:
        if go_parallel:
            # Effective shard count is HARDWARE-DERIVED from the dispatcher's
            # pool (worker_count() == the attached-worker count == the
            # runtime's core-sized pool). NOT a hardcoded constant.
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
            var state = _SharedForkJoinState[W, In, P, in_o](
                input_ptr,
                payload^,
                errors^,
                work^,
                n_chunks,
                n_workers,
            )
            var task = _SharedForkJoinTask[W, In, P, in_o](Int32(0))
            _ = disp[].run_with_state[
                _SharedForkJoinState[W, In, P, in_o],
                _SharedForkJoinTask[W, In, P, in_o],
            ](state, task^, n_workers, cancel_token^, site_id=site_id)
            # Reclaim via Optional.take (never a partial move via take_pointee).
            var done = state.payload.take()
            var errs = state.errors.take()
            _ = state^
            raise_first_chunk_error(errs)
            _ = errs^
            return done^
        else:
            _ = cancel_token^
            var pay = payload^
            _run_shared_serial[W, In, P](
                work, input, n_chunks, pay, errors
            )
            _ = work^
            raise_first_chunk_error(errors)
            return pay^
    else:
        _ = cancel_token^
        var pay = payload^
        _run_shared_serial[W, In, P](work, input, n_chunks, pay, errors)
        _ = work^
        raise_first_chunk_error(errors)
        return pay^
