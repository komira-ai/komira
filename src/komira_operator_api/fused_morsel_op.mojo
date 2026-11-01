# =============================================================================
# fused_morsel_op.mojo — FusedMorselOp trait (WSC PHASE-D-INFRA)
# =============================================================================
#
# WSC PHASE-D-INFRA deliverable per slot brief.
#
# The architectural one-liner: a `FusedMorselOp` conformer is a struct whose
# `process_batch` method takes a per-batch BatchView borrow and emits a
# downstream RecordBatch directly. Pipeline-breaker primitives (HashAggTable,
# CompositeHashTable, ProbeStage, SortStage, WindowStage, TopNStage,
# JoinBuildStage) live as FIELDS of the conforming struct and drain via
# `finalize` at end-of-input.
#
# This is the simpler trait shape introduced by the WSC-PHASE-D-INFRA
# repartition (). Compared to `FusedStage` (the PHASE-B/C
# trait at `komira_engine_dispatch.fused_stage`), FusedMorselOp:
#
#   - Returns `RecordBatch` directly from `process_batch` rather than
#     threading through a `PipelineContext._sink_outputs` slot.
#   - Carries only ONE parametric origin (`bo` on BatchView) on the trait
#     method instead of FusedStage's 7 origins (1 BatchView + 6
#     PipelineContext origins).
#   - Surfaces `finalize` returning `Optional[RecordBatch]` — pipeline-
#     breakers populate the Optional; non-breakers return None.
#
# Both traits coexist post-INFRA. FusedStage continues to serve the
# landed sub-conformers (sub-1 CompiledStage_Filter1, sub-3a
# CompiledStage_Sort1I64 + CompiledStage_TopN1I64) from the
# PHASE-B/C/D-sub work-stream; FusedMorselOp is the trait the 7 generic
# templates + UNTYPED-WRAPPER + PLAN-COMPILER consume (per WORK_QUEUE.md
# lines 459-720). Sub-2 Step 1's CompiledStage_HashAggSingleKey_{F64,I64}
# (a FusedStage conformer) was SUBSUMED at TEMPLATE-GROUP-AGG Step 1
# (commit chain leading to compiled_group_agg_stage.mojo) per the internal development notes
# hard ban #6 (no additive parallel API); the per-DType + composite-key
# logic ports into the new generic template. A future post-PHASE-E
# cleanup may collapse the two traits if a uniform shape emerges; that
# is OUT OF SCOPE for INFRA.
#
# Encapsulation invariants (the internal development notes hard ban #1, #3):
#   - NO `UnsafePointer` in trait surface.
#   - NO wildcard origins (only the 1-origin `bo: Origin[mut=False]` on
#     BatchView, parametric on the trait method).
#   - All borrows tracked via the BatchView's typed origin parameter.
#
# Mojo capability cross-checks:
#   - 1-origin parametric trait method: covered by sub-1 R-A precedent
#     (FusedStage's 7-origin shape compiles GREEN at sub-1 commit
#    ; the 1-origin shape here is strictly simpler).
#   - Trait bound `(Movable, Deinitable)`: matches sub-2's
#     ratified FusedStage relaxation (fused_stage.mojo:75-104 rationale
#     block).
#
# Cross-references:
#   - WSC RFC v0.4 §2.2 (consumer of FusedMorselOp shape).
#   - WORK_QUEUE.md slot WSC-PHASE-D-INFRA (this deliverable).
#   - an internal module (sibling trait,
#     unchanged).
#   - an internal module (the Engine[Op] driver
#     consuming this trait).
#   - an internal module (UNIFIED-STAGE-U2 — the
#     uniform `Stage[Filter, Projects, Breaker]` conformer that supersedes
#     the 14 already-shipped `Compiled*Stage` conformers at U5. Per
#     RFC v2.2.4 §4.1 "the 14 already-shipped Compiled*Stage conformers
#     ARE structurally a 6-flavor outer-struct family today; the unified
#     design *renames* them rather than introducing new struct count."
#     Stage[F, P, B] conforms to FusedMorselOp directly per U2 preflight
#     Option A trait conformance, preserving the Engine driver
#     substrate unchanged at U2).
# =============================================================================

from komira_arrow.schema import RecordBatch
from komira_arrow.batch_view import BatchView
from komira_exec_types.process_result import ProcessResult


# =============================================================================
# §1 — FusedMorselOp trait
# =============================================================================
#
# Trait declaration intentionally minimal: one per-batch consume method
# returning a RecordBatch, and one terminator method returning an
# Optional[RecordBatch]. The BatchView's single `bo: Origin[mut=False]`
# parameter is the only origin tracked; everything else (per-op state,
# pipeline-breaker primitives) lives as private fields on the conforming
# struct.
#
# `process_batch` returns a RecordBatch by VALUE — the per-batch hot-path
# emission target. For non-breaker stages (filter / project /
# scalar-agg-update) the returned batch is the downstream-ready output.
# For pipeline-breaker stages, `process_batch` may return an empty batch
# while the breaker accumulates state; `finalize` emits the accumulated
# output at end-of-input.
#
# `finalize` consumes `self` (var self) — the conformer is no longer
# usable after finalize. Returns `Optional[RecordBatch]`:
#   - None: non-breaker stages whose per-batch outputs are sufficient.
#   - Some(batch): pipeline-breakers (HashAgg final emit, Sort emit,
#     TopN emit, Window final emit).
#
# Why `var self` on finalize: pipeline-breakers may own heap-backed
# accumulator state (HashAggTable's slabs, SortBuffer's row pointers)
# that the emit consumes / drains. Taking self by value cleanly transfers
# ownership of the breaker's internal state into the emit body.
# =============================================================================


trait FusedMorselOp(Movable, Deinitable):
    """One fused morsel-level operator chain.

    A FusedMorselOp consumes per-batch BatchView borrows via
    `process_batch` and emits downstream RecordBatch values. Pipeline-
    breaker primitives are private fields; `finalize` drains the breaker's
    accumulated state at end-of-input.

    Per WSC RFC v0.4 §2.2 and the PHASE-D-INFRA slot brief, conformers
    are produced by ONE of:
      1. The TYPED path: PLAN-COMPILER classifies a LogicalPlan along
         3 axes (filter shape / projection shape / breaker terminator)
         and selects one of 7 generic stage templates (filter_project,
         scalar_agg, group_agg, join_probe, sort, topn, window) with
         concrete comptime params (Pred: ExprXBool, Outs: ExprXList,
         etc.).
      2. The UNTYPED path: `runtime_compile(plan)` returns a
         `RuntimeFusedMorselOp` (one conformer) wrapping Wave 11's
         ExpressionExecutor + SelectionVector + AdaptiveFilter for
         DuckDB-style runtime expression evaluation. (UNTYPED-WRAPPER
         slot, blocked on this INFRA slot.)

    Trait bound `(Movable, Deinitable)` matches the sub-2
    ratified `FusedStage` relaxation at `komira_engine_dispatch.
    fused_stage:75-104` — minimum bound that the `Engine[Op]` driver
    actually requires (move the conformer into Engine.run, drop at
    end-of-call).

    Origin parameter conventions:
      - bo: BatchView's parent RecordBatch origin. Per-batch fresh — each
        morsel arriving via the source's `next_morsel` carries a distinct
        immutable borrow whose lifetime ends at the end of the per-batch
        iteration of the Engine.run loop body.
    """

    def process_batch[
        bo: Origin[mut=False],
    ](
        mut self,
        batch: BatchView[bo],
    ) raises -> ProcessResult:
        """Consume one input batch; return a ProcessResult dispatch outcome.

        UDF-PROCESSRESULT-1A migration: the return type was
        bare `RecordBatch` pre-migration; every conformer's body now wraps
        its emit in a `ProcessResult` variant per RFC v2.2.4 §2.4 / §3.5.

        Variant semantics (driver loop dispatches on `result.tag`):
          - `ProcessResult.need_input(Optional(rb))`: stage fully consumed
            input, emitted ONE output batch. Driver pushes rb to sink and
            advances source. The canonical non-breaker filter/project/
            scalar-update return shape.
          - `ProcessResult.need_input(None)`: stage fully consumed input,
            emitted NO output (breaker accumulator updated state). Driver
            advances source without push. HashAgg / Sort / TopN / Window /
            JoinBuild use this on per-batch calls; their actual emission
            happens in `finalize`.
          - `ProcessResult.have_output(rb)`: stage emitted partial output
            without consuming the full input batch (high-fanout streaming
            JoinProbe; Phase 2 Stage_TableExpand). Driver pushes rb, then
            RE-invokes process_batch on the SAME input morsel (retry-loop).
            ZERO existing v0.4 conformers emit this variant — exercised
            first by UDF-TABLEFN.
          - `ProcessResult.done()`: end-of-input from stage side. Rare;
            typically the source signals end via None-returning next_morsel.
        """
        ...

    def finalize(var self) raises -> Optional[RecordBatch]:
        """Drain accumulated state at end-of-input.

        Pipeline-breaker stages (HashAgg / Sort / TopN / Window) emit
        their accumulated final output here — the per-group hash-agg
        result table, the sorted run, the top-N heap, the per-partition
        window output.

        Non-breaker stages return None — their per-batch
        `process_batch` outputs are the complete downstream stream.

        Consumes `self` (var self) — the conformer is no longer usable
        after finalize. This cleanly transfers ownership of any
        heap-backed breaker state (HashAggTable slabs, SortBuffer row
        pointers) into the emit body.
        """
        ...
