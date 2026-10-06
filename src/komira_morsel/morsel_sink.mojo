# =============================================================================
# MorselSinkImpl -- Rev 4 trait for sink extensibility
# =============================================================================
#
# Per an internal doc §4.2.1 / §4.4. Mirrors
# MorselSourceImpl / MorselOperatorImpl: sink types are chosen by the user
# (or a closed-world SinkSpec enum) and monomorphized at compile time.
#
# Phase 0 surface: consume + finalize. Phase 2a adds `take_output` to the
# trait surface (pipeline breakers -- FlatHashAggSink, SortTopNSink --
# produce a materialized RecordBatch after combine()). Rev 4 §4.2.1 also
# names `capabilities() -> SinkCapabilities` -- still deferred.
# =============================================================================

from komira_arrow.schema import RecordBatch
from .morsel import Morsel
from .pipeline_execution import PipelineExecution


trait MorselSinkImpl(Movable, Deinitable):
    """Per §4.2.1 and §4.2.5.1. Concrete sinks (PipelineSpy, FlatHashAggSink,
    ParquetWriterSink, ...) implement this trait and are the terminal
    type parameter K in execute[S, K].

    Concurrent-consume contract (§4.2.5.1 answer 3)
    -----------------------------------------------
    `consume` takes `self` (borrowed, immutable reference) so the generic
    executor can call it from multiple worker threads without aliasing a
    `mut` binding. In Mojo, `def f(self)` means immutable borrow --
    NOT by-value like Rust's `fn f(self)`. Sinks that need per-worker
    mutable state hold it behind an `UnsafePointer[...]`-backed slab (one
    slot per worker, indexed by `worker_id`) allocated in
    `resize_worker_state`. The UnsafePointer slab provides interior
    mutability through the borrowed self. `combine()` then merges the
    per-worker slots single-threaded after all workers have joined.

    Copyable is NOT required. The generic executor captures the sink by
    reference in its `@parameter def worker` closure and never copies it.
    Sinks are Movable-only: they are moved into the executor and moved
    back out after combine().

    `resize_worker_state` and `combine` ship with no-op defaults: sinks that
    don't partition state (simple append-only sinks, tests with a shared
    counter) can ignore them.
    """

    def consume(self, worker_id: Int, var morsel: Morsel) raises: ...
    def finalize(mut self) raises: ...

    # Capability hooks with no-op defaults (§4.2.5.1).

    def resize_worker_state(mut self, num_workers: Int) -> None:
        """Allocate per-worker state slabs. Called once before the first
        `consume` on a sink. Sinks without per-worker state leave this as
        the default no-op.
        """
        pass

    def combine(
        mut self, mut pipeline: PipelineExecution
    ) raises -> None:
        """Single-threaded merge of per-worker state after all workers have
        joined. Runs exactly once per execution, after `parallelize` returns
        and before the caller reads results. No-op default for sinks without
        per-worker state.

        Phase 1 Layer B-residual: the previous `pool_o`
        origin parameter and the `pipeline._pool[]` access path are
        gone — PipelineExecution no longer borrows the pool. Sinks that
        need parallel dispatch under combine() should use the
        `MorselSink.finalize` shape (LocalDispatcher + CancellationToken)
        instead. Sinks with no per-worker state ignore the parameter
        and still get cancel/error visibility via
        `pipeline.is_cancelled()` / `pipeline.has_error()`.
        """
        pass

    def take_output(mut self) raises -> RecordBatch:
        """Move the materialized output out of the sink (pipeline breaker
        contract -- Rev 4.2 §7 Phase 2a).

        Called exactly once by the caller after `combine()` has returned.
        Sinks that do not produce a single combined RecordBatch (e.g. a
        streaming writer sink that persists to disk) leave the default,
        which raises. ParquetCollectSink and FlatHashAggSink override.
        """
        raise Error(
            "MorselSinkImpl.take_output: not implemented by this sink type"
        )
