# =============================================================================
# MorselOperatorImpl -- Rev 4 trait for operator extensibility
# =============================================================================
#
# Per an internal doc §4.2.1 / §4.4. Mirrors
# MorselSourceImpl: operator types are closed-world (FilterOp, ProjectOp,
# AggOp, ...) and monomorphized via @parameter generics. No vtable.
#
# Phase 0 ships the minimum surface (`execute`) so the pipeline drive test
# can compile. Phase 1+ adds `take_output` for HAVE_MORE_OUTPUT operators
# (unnest, window expansion) alongside the first such operator.
#
# ---------------------------------------------------------------------------
# HAVE_MORE_OUTPUT scheduler contract (Phase 3e, slice 1)
# ---------------------------------------------------------------------------
# Per an internal doc §3.1-§3.4. The ExecResult
# tag `HAVE_MORE_OUTPUT` is now a load-bearing scheduler signal, not a
# documentation hint:
#
#   When `execute` returns ExecResult(HAVE_MORE_OUTPUT), the scheduler MUST
#   re-invoke `execute` on the SAME Morsel instance (same `morsel` parameter)
#   before pulling a new morsel from the source. The operator MUST replace
#   `morsel.batch` with the next bounded output chunk on each call, and MUST
#   eventually return NEED_MORE_INPUT (or FINISHED) to release the input.
#
#   Operators that cannot buffer multi-chunk output (MapOp, FilterOp, single-
#   shot JOIN SEMI/ANTI, ...) MUST always return NEED_MORE_INPUT. The new
#   scheduler loop degenerates to single-pass behavior for them: one
#   execute() call, one consume(), advance to next input.
#
# Slice-2: scheduler clone-shallow handoff landed in
# generic_executor.mojo (`_handoff_chunk`). HMO no longer raises.
# When an operator returns HMO, the scheduler:
#   1. Moves the chunk OUT of `morsel.batch` into a fresh Morsel that
#      goes to the sink (preserves morsel_id / partition_id /
#      origin_hint).
#   2. Resets `morsel.batch` to an empty RecordBatch shell.
#   3. Re-invokes execute() on the same morsel; the operator must
#      materialize the next chunk into `morsel.batch` from its own
#      pending state. Slice 3 is the first real consumer (resumable
#      JoinProbeOp INNER/LEFT).
#
# Resume-state location (RFC §3.4, OQ-1)
# --------------------------------------
# Per an internal doc §1.1 + maintainer directive
# (Pattern 1 fix). The trait is Movable-only: per-worker operator
# instances are constructed by the driver into a `Slab[O]` of size N
# and moved into `execute_collect_op`, which hands each worker a mutable ref
# to its own slot via `_mut_ptr(wid)`. The prior `op_shared.copy()` shape
# required `MorselOperatorImpl: Copyable` -- which in turn forced every
# operator to store plan-lifetime references as raw bitwise-copyable pointer
# fields. Dropping the Copyable bound + switching to Slab[O] in the
# executor + Arc-wrapping the shared plan-lifetime refs at the JoinProbeOp /
# MapOp boundary eliminates the root cause of Cluster 2 in the unsafe-
# pointer elimination proposal.
#
# Resumable operators (e.g., JoinProbeOp Phase 3e slices 3-5) hold
# `pending_probe_input: Optional[RecordBatch]` + resume cursors directly
# on the struct. The Slab slot survives across morsels within a
# worker, and concurrent workers don't alias because each worker only
# touches slot[wid].
#
# A second resumable operator (window expansion, unnest, ...) would be the
# trigger to extract `OperatorLocalState` as its own trait. Until then:
# resume fields live on the operator struct, cleared-not-freed between
# morsels to preserve the v0.3 "allocation-free after warmup" invariant.
# =============================================================================

from .morsel import Morsel
from komira_core.traits.exec_result import ExecResult

from komira_obs.metrics_set import MetricsSet, MetricsSnapshot


trait MorselOperatorImpl(Movable, Deinitable):
    """Per §4.2.1. Concrete operators (FilterOp, ProjectOp, ...) implement
    this trait and are composed into a pipeline monomorphized per
    (Source, [Operators...], Sink) at the user's compile time.

    `execute` is the hot path -- after monomorphization this is a direct
    call with a real chance of inlining into the scheduler loop.

    Contract
    --------
    Return one of the ExecResult tags. The scheduler honors:

      * NEED_MORE_INPUT / FILTERED_EMPTY: advance to next input morsel.
      * HAVE_MORE_OUTPUT: re-invoke execute() on the same morsel; the
        operator MUST have replaced morsel.batch with the next chunk.
      * FINISHED: stop pulling input for this worker.

    Operators that never amplify output (1:1 or <=1:1) must always return
    NEED_MORE_INPUT / FILTERED_EMPTY. Only many-to-many amplifying
    operators (resumable JoinProbeOp INNER/LEFT, future unnest/window)
    ever return HAVE_MORE_OUTPUT.

    Per-operator MetricsSet (Phase 3.2)
    -----------------------------------
    Each conforming operator MUST expose a `metrics(self) -> ref [self]
    MetricsSet` accessor. The canonical shape is an
    `OwnedPointer[MetricsSet]` field initialized in `__init__` with the
    metrics this operator emits registered up front (DataFusion-style).
    `execute()` records into the per-worker disjoint slots via
    `Counter.inc_in_pipeline` / `Time.record_ns_in_pipeline`. EXPLAIN
    ANALYZE (Phase 3.3) walks the operator tree and reduces every
    MetricsSet. See an internal doc §5.

    Movable-only (NOT Copyable)
    ---------------------------
    The trait carries `Movable, Deinitable` only. Per-worker
    instances are constructed by the driver into a `Slab[O]` sized
    to `num_workers` and moved into `execute_collect_op`. This frees
    operator structs from the "every field must be bitwise-Copyable"
    trap that previously forced plan-lifetime references to be raw
    non-owning pointer fields -- plan-lifetime state now lives behind
    `ArcPointer[T]` (cheap refcount bump per worker at construction; no
    per-morsel cost).
    """

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult: ...

    def metrics_snapshot(self) -> MetricsSnapshot:
        """Return a reduced snapshot of this operator's per-instance
        MetricsSet (Phase 3.2 of an internal doc §5.5).

        Each `MorselOperatorImpl` instance owns one `MetricsSet` (typically
        as `OwnedPointer[MetricsSet]` field) and registers the metrics it
        emits (`rows_processed` Counter, `elapsed_compute` Time, optional
        Gauges) in `__init__`. Hot-path `execute()` records into the
        per-worker disjoint slots through the operator's own concrete
        accessor (which is monomorphized by the executor — no virtual
        call). This trait method exists so the embedder / EXPLAIN ANALYZE
        driver (Phase 3.3) can reduce every operator's metrics through a
        uniform interface.

        Default: returns an empty `MetricsSnapshot`. Operators that have
        not yet adopted MetricsSet (transitional) keep this default;
        EXPLAIN ANALYZE renders a 0-entry block for them. Operators that
        own a MetricsSet override to call `self._metrics[].reduce()`.

        Returning a value (not a ref) sidesteps Mojo's "cannot
        return self's origin from a RegisterPassable trait member" — the
        trait carries Movable, Deinitable only and any
        register-passable concrete type would defeat a `ref [self] X`
        return shape.
        """
        return MetricsSnapshot()
