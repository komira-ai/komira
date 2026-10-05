# =============================================================================
# parallel_fork_join_shared — the LocalDispatcher binding of the shared-payload
# fork-join layer.
#
# The SHARED-DESTINATION sibling of `parallel_fork_join`: where that helper
# gives each chunk its OWN `Optional[O]` output slot, this one hands every
# chunk a `mut` reference to ONE driver-owned payload `P` that the chunks
# write DISJOINT slices of. That is the shape of every phase of the parallel
# SORT family (per-slice permutation sort, co-rank merge, histogram, scatter,
# rank-map) — a pre-sized destination whose slices tile the row space — and
# the sort's stage-4 `gather_batch` as well.
#
# The State / Task / driver live in
# `komira_async_api.fork_join_shared`, genericized over
# `D: ParallelDispatch`, because `gather_batch` (stage 4 of every `ORDER BY`)
# is in the core packages, which `komira_async` depends on, so it cannot import
# them from here. There is exactly ONE shared-payload fork-join driver; this
# file binds it to `D = LocalDispatcher[NoopSink]` and keeps every public
# signature below unchanged.
#
# Owns ONCE (so call sites can't break it) — via the core driver:
#   * the State/Task wrapper + the `run_with_state` dispatch,
#   * the immutable concrete-origin input borrow (`in_o: ImmutOrigin`, NO
#     wildcard),
#   * the payload MOVED onto the State for the dispatch window and reclaimed
#     via `Optional.take()` (the ownership-reclaim rule) — a `List`/`Slab` move is
#     an O(1) handle move, so a phase loop can move the same buffers through
#     wave after wave with no data copy,
#   * the per-chunk error channel with chunk errors CAUGHT so the reclaim
#     always runs,
#   * the hardware-derived worker count (`dispatcher.worker_count()`),
#   * the nested-dispatch inline fallback (pool depth > 0 runs chunks inline),
#   * the serial fallback for dispatcher-less callers.
#
# WHY THIS EXISTS: the sort family was the last
# hot-path user of stdlib `parallelize(...)`. That runs on Mojo's AsyncRT thread
# pool ("Thread0..Thread7") — a SECOND worker-class thread pool that our
# topology scheduler cannot see, pin, or govern, and that oversubscribes the
# box whenever an engine worker is still bounded-spinning. Everything
# parallel now runs on OUR runtime; this helper is the substrate for the
# disjoint-write half of that migration.
#
# =============================================================================

from komira_async.runtime.sched_trace import SITE_GENERIC_FORK_JOIN

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async_api.fork_join_shared import fork_join_shared
from komira_async_api.shared_chunk_work import SharedChunkWork


# =============================================================================
# The public 2-entry surface: dispatcher-aware + serial fallback.
# =============================================================================


def parallel_fork_join_shared[
    W: SharedChunkWork,
    In: Deinitable,
    P: Movable & Deinitable,
    in_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    var work: W,
    ref [in_o] input: In,
    var payload: P,
    n_chunks: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    min_parallel_chunks: Int = 2,
    max_workers: Int = 0,
    site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
) raises -> P:
    """Dispatcher-aware entry. Caller threads the engine dispatcher +
    cancellation token; the payload is returned to the caller after the
    fork-join barrier.

    Worker count is HARDWARE-DERIVED from the dispatcher's pool
    (`dispatcher.worker_count()`). There is NO hardcoded worker cap.

    Args:
      min_parallel_chunks: Below this chunk count the helper runs the chunks
        inline (avoids dispatch overhead on tiny work).
      max_workers: OPTIONAL explicit caller cap on the shard count. Default 0
        means "use the dispatcher's hardware-derived worker count".
      site_id: sched-trace call-site label for the fork this helper
        dispatches. Defaults to SITE_GENERIC_FORK_JOIN so
        a caller that does not care still lands in a NAMED bucket instead of the
        anonymous id-0 "OTHER". A caller that wants its own SCHED_SITE row passes
        its own SITE_* id (add the constant to `sched_trace.mojo` AND the
        `_sched_site_name` switch in `_posix_shim.c`). Plain runtime UInt32, not
        a comptime axis; zero cost when tracing is off.
    """
    return fork_join_shared[
        W, In, P, in_o,
        LocalDispatcher[NoopSink],
        has_pool=True,
        disp_o=disp_o,
    ](
        work^,
        input,
        payload^,
        n_chunks,
        min_parallel_chunks,
        max_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
        site_id,
    )


def parallel_fork_join_shared_serial[
    W: SharedChunkWork,
    In: Deinitable,
    P: Movable & Deinitable,
    in_o: ImmOrigin,
](
    var work: W,
    ref [in_o] input: In,
    var payload: P,
    n_chunks: Int,
) raises -> P:
    """Serial-fallback entry (no dispatcher). Callers without an engine-owned
    dispatcher (unit tests, standalone probes) hit this; the result is
    byte-identical to the parallel path."""
    return fork_join_shared[
        W, In, P, in_o,
        LocalDispatcher[NoopSink],
        has_pool=False,
        disp_o=MutAnyOrigin,
    ](
        work^,
        input,
        payload^,
        n_chunks,
        2,
        0,  # max_workers unused on the serial path (has_pool=False).
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
        SITE_GENERIC_FORK_JOIN,
    )


# =============================================================================
# SharedForkJoinHandle — a threadable "the pool, or nothing" dispatch handle
# =============================================================================
#
# Multi-PHASE kernels (the sort family: per-slice sort -> co-rank merge ->
# histogram -> scatter -> rank-map) dispatch several fork-join waves from a
# CHAIN of private helper functions. Threading
# `(Optional[Pointer[LocalDispatcher]], CancellationToken)` through every link
# of that chain is noisy and easy to get wrong; this handle collapses it into
# ONE comptime-parameterized value that carries the pool (or the explicit
# "no pool, run inline" case) and exposes a single `run` method.
#
# `has_pool` is a COMPTIME parameter, so the serial construction
# (`SharedForkJoinHandle.serial()`) compiles the dispatch branch out entirely —
# a dispatcher-less caller (unit test, standalone probe) pays nothing and needs
# no runtime.
#
# `ptr` is PUBLIC on purpose: an engine caller that reaches a CORE entry point
# taking `Optional[Pointer[D, disp_o]]` (e.g.
# `compiler_helpers.gather_batch_dispatch`, the migrated stage-4 gather) passes
# `handle.ptr` straight through with `D = LocalDispatcher[NoopSink]`. That is how
# a core-side kernel gets the pool without core naming `LocalDispatcher`.
# =============================================================================


@fieldwise_init
struct SharedForkJoinHandle[
    has_pool: Bool,
    disp_o: Origin[mut=True],
](Copyable, Movable):
    """A pool handle threadable through a multi-phase kernel's helper chain.

    Construct with `SharedForkJoinHandle[True, __origin_of(d)](Pointer(to=d))`
    on the hot path, or `SharedForkJoinHandle.serial()` where no dispatcher is
    reachable. Every phase of the kernel then calls `handle.run[...](...)`
    without re-plumbing the pointer + token pair.
    """

    var ptr: Optional[Pointer[LocalDispatcher[NoopSink], Self.disp_o]]

    def run[
        W: SharedChunkWork,
        In: Deinitable,
        P: Movable & Deinitable,
        in_o: ImmOrigin,
    ](
        self,
        var work: W,
        ref [in_o] input: In,
        var payload: P,
        n_chunks: Int,
        min_parallel_chunks: Int = 2,
        site_id: UInt32 = SITE_GENERIC_FORK_JOIN,
    ) raises -> P:
        """Run ONE fork-join wave of `n_chunks` chunks over the shared
        `payload`, on the pool when this handle carries one and inline when it
        does not. Returns the payload.

        `site_id` labels the fork in the sched-trace SCHED_SITE histogram. It
        defaults to `SITE_GENERIC_FORK_JOIN` for back-compat with the phase
        callers that have not been individually named yet; pass a real SITE_* id
        so the driver-serial attribution gets a named row instead of
        the anonymous id-35 bucket."""
        comptime if Self.has_pool:
            return parallel_fork_join_shared[W, In, P, in_o, Self.disp_o](
                work^,
                input,
                payload^,
                n_chunks,
                self.ptr.value(),
                CancellationToken.never(),
                min_parallel_chunks,
                0,
                site_id,
            )
        else:
            return parallel_fork_join_shared_serial[W, In, P, in_o](
                work^, input, payload^, n_chunks
            )


def serial_fork_join_handle() -> SharedForkJoinHandle[False, MutAnyOrigin]:
    """The no-dispatcher handle: every `run` on it executes its chunks inline.

    A free function rather than a `SharedForkJoinHandle` static method because
    Mojo 1.0.0b2 cannot infer the parent struct's parameters for a static
    method call on a parameterized struct."""
    return SharedForkJoinHandle[False, MutAnyOrigin](
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None)
    )
