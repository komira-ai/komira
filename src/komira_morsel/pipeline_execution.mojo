# =============================================================================
# PipelineExecution -- per-pipeline fused scheduler + context (Phase 2E.1)
# =============================================================================
#
# RFC v4 §3.1: fused scheduler + context type (Option B, 2-type collapse).
#
# Matches v0.3 `komira-engine/src/morsel_scheduler.rs::MorselScheduler`
# 1:1 in structure and error semantics. Holds the pipeline-wide
# scheduler STATE (cancel flag, panic flag, error slot, metrics) inline
# -- there is no separate `PipelineScheduler` type.
#
# Ownership model:
#   * Caller builds `PipelineExecution` on its stack (typically
#     `EngineContext.execute_pipeline()` or a benchmark harness).
#   * The pool is borrowed via `ref [pool_origin] WorkerPool` -- the
#     only struct-level origin parameter (`pool_origin: Origin[mut=True]`).
#   * NOT Movable: inline `Atomic[...]` fields would be UB under a
#     memcpy mem-move. Declared `Deinitable`. Caller passes
#     the pipeline by `mut ref` through driver functions.
#
# Why `Origin[mut=True]` on the pool origin?
#   Bare `Origin` on a struct parameter defaults to `mut=False` which
#   produces an immutable pool borrow and rejects `mut pool` usages
#   downstream. Spike Repro 3/9 use `Origin[mut=True]`; that is the
#   shape the dispatch call chain requires.
#
# References:
#   * RFC v4 §3.1 -- an internal doc
#   * v0.3 Rust -- komira-engine/src/morsel_scheduler.rs:203-219
#   * Spike Repro 1 -- an internal doc
#     phase2e0_repro1_pipeline_execution_non_movable.mojo
#   * Spike Repro 8 -- cancel + first-error propagation via CAS
#   * Atomic[int8] convention: semi_join.mojo:918 precedent (Mojo
#     rejects Atomic[DType.bool] due to LLVM i1 restriction).
# =============================================================================

from komira_atomic_alias import AtomicI8, AtomicI32
from std.memory import UnsafePointer

from komira_collections.slab import Slab

from komira_exec_types.engine_error import EngineError


struct PipelineExecution(
    Deinitable
):
    """Per-pipeline execution context. Fused scheduler + context.

    Matches v0.3 `MorselScheduler` in structure and error semantics:
      * `_cancel_flag`  -- worker-visible cancel; checked at batch boundaries.
      * `_panic_flag`   -- scheduler-level panic flag (any worker panicked).
      * `_error_slot`   -- CAS first-error-wins slot (-1 = no error, >= 0 =
        payload index in `_error_payloads`).
      * `_error_payloads` -- `Slab[EngineError]` carrying the captured error.
        Currently sized 1 (single-error capture model). Expandable to a
        true slot table if multi-error capture becomes a requirement.

    Phase 3.2 (an internal doc §5): pipeline-wide
    `PipelineMetrics` was deleted. Per-operator timing now lives on each
    `MorselOperatorImpl` instance's `OwnedPointer[MetricsSet]` and is
    surfaced via the `MorselOperatorImpl.metrics_snapshot()` trait
    accessor (Phase 3.3 EXPLAIN ANALYZE consumer). The
    `num_operators` __init__ parameter is retained as a no-op for
    binary backwards-compat with the SDK / test call sites pending a
    follow-up signature cleanup.

    Phase 1 Layer B-residual: the previous `_pool:
    Pointer[WorkerPool, pool_origin]` field is gone. PipelineExecution
    no longer borrows the pool — it stores the worker count as a plain
    `Int` and reaches the substrate dispatcher via the per-dispatch
    `LocalDispatcher + CancellationToken` parameters threaded through
    the migrated call chain. As a result the struct is no longer
    parameterized; callers construct via
    `PipelineExecution(num_workers, num_operators)`.

    Atomic[int8] convention (Mojo):
      * LLVM i1 atomic is unsupported, so `Atomic[DType.bool]` is rejected
        by the compiler.
      * Fallback: `Atomic[DType.int8]` with `0 = false`, `1 = true`.

    Not Movable. Caller keeps the pipeline on its stack and passes
    `mut ref` through driver functions. SegmentExecution receives the
    pipeline ref per-dispatch via its `dispatch(...)` method argument.

    Scope (Phase 2E.1): construction, error API, cancel, metrics access,
    `num_workers()`. Does NOT attempt segment-graph traversal, multi-
    segment concurrent execution, or backpressure. Those land in later
    waves per RFC §3.5.
    """

    # Worker count snapshot. Phase 1 Layer B-residual closed the
    # `_pool` borrow; the substrate dispatcher + cancel_token are
    # now threaded explicitly through the migrated dispatch APIs.
    var _num_workers: Int

    # Scheduler state inline (v0.3 MorselScheduler shape). Since
    # PipelineExecution is NOT Movable, raw Atomic fields are fine --
    # the Movable-breaks-on-Atomic-field restriction does not apply.
    var _cancel_flag: AtomicI8
    var _panic_flag: AtomicI8

    # First-error-wins CAS slot. -1 = no error; 0 = payload[0] valid.
    # (Single-error capture; expandable to a slot table later.)
    var _error_slot: AtomicI32

    # Error payload storage. Heap-backed `Slab[EngineError]`; index 0
    # holds the captured error when `_error_slot >= 0`.
    var _error_payloads: Slab[EngineError]

    # Phase 3.2 (an internal doc §5.5): per-pipeline rollup
    # `PipelineMetrics` deleted — never wired into operator hot paths.
    # Per-operator timing now lives on each MorselOperatorImpl instance's
    # MetricsSet. Pipeline-level rollups are reconstructed (when needed)
    # by reducing every operator's snapshot in EXPLAIN ANALYZE.

    # ---------------------------------------------------------------------
    # Lifecycle
    # ---------------------------------------------------------------------

    def __init__(
        out self,
        num_workers: Int,
        num_operators: Int,
    ) raises:
        """Construct per-pipeline on the caller's stack.

        ~150ns amortized (validated by spike Repro 6). Cheaper than v3's
        target because no separate PipelineScheduler constructor.

        `num_workers` is the parallelism degree the caller intends to
        dispatch at; PipelineExecution stores it as a plain `Int` rather
        than borrowing the pool. The substrate dispatcher and cancel
        token are threaded through the per-dispatch API surface
        (LocalDispatcher + CancellationToken).

        `num_operators` is kept in the signature for source-compat with
        callers that still pass an operator-count hint; it is unused
        post-Phase 3.2 (per-operator metrics live on each operator
        instance, not on the pipeline). Drop the argument in a follow-
        up signature cleanup that touches every PipelineExecution
        construction site.
        """
        _ = num_operators  # intentionally unused; see docstring.
        self._num_workers = num_workers
        self._cancel_flag = AtomicI8(Int8(0))
        self._panic_flag = AtomicI8(Int8(0))
        self._error_slot = AtomicI32(Int32(-1))
        # Single-slot payload storage; expandable later if needed.
        self._error_payloads = Slab[EngineError].create_prefilled(1)

    # ---------------------------------------------------------------------
    # Cancel API
    # ---------------------------------------------------------------------

    @always_inline
    def cancel(mut self):
        """Set `_cancel_flag`. Workers check at batch boundaries.

        int8 convention: 1 = cancelled, 0 = running.
        """
        # SAFETY: Atomic.store on an inline Atomic field. `UnsafePointer(to=...)`
        # against the inline field is a pattern validated by
        # semi_join.mojo:918 and spike Repro 1.
        AtomicI8.store(
            UnsafePointer(to=self._cancel_flag)
            .unsafe_bitcast[Scalar[DType.int8]](),
            Int8(1),
        )

    @always_inline
    def is_cancelled(self) -> Bool:
        return self._cancel_flag.load() != Int8(0)

    # ---------------------------------------------------------------------
    # Panic API (scheduler-level panic flag; matches v0.3 global_panic)
    # ---------------------------------------------------------------------

    @always_inline
    def set_panic(mut self):
        """Mark the pipeline as panicked. Separate from cancel -- panic
        indicates a worker thread encountered an unrecoverable fault."""
        AtomicI8.store(
            UnsafePointer(to=self._panic_flag)
            .unsafe_bitcast[Scalar[DType.int8]](),
            Int8(1),
        )

    @always_inline
    def is_panicked(self) -> Bool:
        return self._panic_flag.load() != Int8(0)

    # ---------------------------------------------------------------------
    # Error API (first-error-wins CAS)
    # ---------------------------------------------------------------------

    def set_error_cas(mut self, var err: EngineError) -> Bool:
        """First-error-wins: CAS `_error_slot` from -1 to 0 and, on win,
        write `err` into `_error_payloads[0]`.

        Returns True if this call won the CAS; False otherwise. The loser
        silently drops its `err` (the owning move consumes it).

        Matches v0.3 `SegmentState::set_error`
        (morsel_scheduler.rs:163-177 -- compare_exchange on null, drop
        on lose).
        """
        var expected = Int32(-1)
        var won = AtomicI32.compare_exchange(
            UnsafePointer(to=self._error_slot)
            .unsafe_bitcast[Scalar[DType.int32]](),
            expected,
            Int32(0),
        )
        if won:
            ref payload = self._error_payloads.get_mut_interior(0)
            payload = err^
        return won

    @always_inline
    def has_error(self) -> Bool:
        return self._error_slot.load() >= Int32(0)

    def take_error(mut self) -> Optional[EngineError]:
        """Swap the error slot atomically. If a payload was captured,
        return a copy of it and reset the slot to -1 so subsequent
        polls see no error.

        Matches v0.3 `SegmentState::take_error` (`&self`-callable,
        morsel_scheduler.rs:119-126).
        """
        var slot = self._error_slot.load()
        if slot < Int32(0):
            return None
        var expected = slot
        var reset = AtomicI32.compare_exchange(
            UnsafePointer(to=self._error_slot)
            .unsafe_bitcast[Scalar[DType.int32]](),
            expected,
            Int32(-1),
        )
        if not reset:
            # Another thread raced us to take_error; they got it.
            return None
        ref payload = self._error_payloads.get_mut_interior(0)
        # EngineError is Copyable (not ImplicitlyCopyable); explicit
        # `.copy()` is required for the Optional construction.
        # The Slab slot retains its payload until the next set_error_cas
        # overwrites it.
        return Optional[EngineError](payload.copy())

    # ---------------------------------------------------------------------
    # Pool access
    # ---------------------------------------------------------------------

    @always_inline
    def num_workers(self) -> Int:
        """Return the worker count snapshot taken at construction time."""
        return self._num_workers

    # ---------------------------------------------------------------------
    # Metrics access (Phase 3.2: deleted)
    # ---------------------------------------------------------------------
    #
    # The pipeline-wide rollup accessors (metrics_source_ns, ...,
    # metrics_per_op_commit) are gone. They read from the dead
    # PipelineMetrics scratch / commit slabs that no operator ever
    # wrote into. Per-operator timing now lives on each
    # MorselOperatorImpl instance's MetricsSet (see
    # `MorselOperatorImpl.metrics_snapshot()`); EXPLAIN ANALYZE
    # (Phase 3.3) walks the operator tree and reduces every snapshot.
