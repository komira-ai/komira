# =============================================================================
# gather_recordbatch.mojo — BatchView + RowSelectionVector → RecordBatch
# substrate primitive.
# =============================================================================
#
# Purpose
# -------
# Bridges the impedance between the row-mode filter path
# (`ExpressionExecutor.select_expression*` produces a survivor count in
# a `RowSelectionVector`) and the `FusedMorselOp.process_batch[bo](
# BatchView[bo]) -> RecordBatch` consumer shape:
#
#     batch_view  --select_expression_from_view-->  RowSelectionVector
#     batch_view + sel  --gather_into_recordbatch-->  RecordBatch
#
# The downstream operators that need survivor gather (the untyped wrapper
# and the scalar-agg, join-probe, sort, topn and window templates) all share
# this primitive instead of each re-deriving the per-DType gather logic.
#
# Implementation strategy (additive substrate)
# --------------------------------------------
# The existing `komira_core.helpers.compiler_helpers.gather_batch(batch:
# RecordBatch, indices: List[Int]) -> RecordBatch` already handles every
# DType in the Arrow set (primitives, strings, dictionaries, nested
# LIST/STRUCT/MAP, unions, validity bitmaps, decimals). Re-implementing
# the per-DType gather here would duplicate ~250 LOC of complex
# nested-type handling — bug-bait, not substrate value.
#
# The primitive therefore:
#   1. Dereferences the BatchView's `Pointer[RecordBatch, bo]` to a
#      `ref [bo] RecordBatch`. This is the canonical typed-borrow shape
#      and the only step that the BatchView origin parameter is needed
#      for — gather_batch's RecordBatch parameter is `read self`, so
#      the inner borrow is consumed locally within this call.
#   2. Materializes the RowSelectionVector indices into a `List[Int]`
#      (one O(N) walk; cost dwarfed by the per-column gather inside
#      gather_batch). This is an explicit substrate cost — a future
#      `gather_batch_from_sel[bo](batch_view, sel)` could add a
#      pipeline that fuses the index-list materialization into the
#      per-column gather inner loop, eliding the temporary List[Int].
#   3. Delegates to `gather_batch(batch, indices)`.
#
# Empty-selection contract: when `sel.len() == 0`, the returned
# RecordBatch has zero rows but preserves the source schema (matches
# Arrow IPC reader semantics for filtered-out batches).
#
# Encapsulation invariants
# ------------------------
# - NO UnsafePointer in the public signature.
# - The BatchView's `bo: Origin[mut=False]` parameter is the only origin
#   tracked; the per-call RecordBatch deref consumes the sub-origin
#   locally and never escapes.
# - Returned RecordBatch is a freshly-constructed value (gather_batch
#   builds it via RecordBatchBuilder); no lifetime entanglement with
#   the source batch.
#
# Mojo 1.0.0b1 capability notes
# -----------------------------
# - `BatchView[bo]._batch[]` returns a `ref [bo] RecordBatch` — consumed
#   by the `gather_batch(batch: RecordBatch, ...)` parameter which is
#   read self (def-style without `mut`). Verified at expression_executor
#   M3's _dispatch_comparison body (the existing precedent that calls
#   `batch.column_by_name(...)` against a `mut batch: RecordBatch` but
#   only invokes read-self methods on the batch).
# - The `RowSelectionVector` is borrowed (read-only) — `sel.get(k)` is
#   `read self` per its `@always_inline fn get(self, k: Int) -> UInt32`
#   signature; safe to call against a ref borrow.
#
# Cross-references
# ----------------
# - komira_core.helpers.compiler_helpers.gather_batch (delegate).
# - komira_core.collections.batch_view (BatchView definition).
# - komira_core.eval.selection_vector_row.RowSelectionVector (input shape).
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import SchemaBuilder
from komira_core.collections.batch_view import BatchView
from komira_core.helpers.compiler_helpers import gather_batch
from komira_core.eval.selection_vector_row import RowSelectionVector


def gather_into_recordbatch[
    bo: Origin[mut=False],
](
    batch_view: BatchView[bo],
    sel: RowSelectionVector,
) raises -> RecordBatch:
    """Gather rows from `batch_view` selected by `sel` into a new RecordBatch.

    Substrate primitive. Used by the untyped wrapper and the typed
    templates that need to materialize a downstream RecordBatch
    after a row-mode filter pass produces a survivor selection vector.

    Contract:
      - `sel.len()` survivors are emitted; row ordering preserved
        (`sel.get(k)` for k in [0, sel.len()) yields the source row
        positions in emit order).
      - When `sel.len() == 0`: returns an empty RecordBatch with the
        source's schema (zero rows, full column set with zero-length
        columns).
      - Every DType in the Arrow set is supported via the underlying
        `gather_batch` (primitives, strings, dictionaries, decimals,
        nested LIST/STRUCT/MAP, unions, validity bitmaps).
      - Returned RecordBatch is freshly allocated; no lifetime
        entanglement with the source batch.

    Args:
        batch_view: Read-only typed borrow over the source RecordBatch.
            The `bo: Origin[mut=False]` parameter pins the source's
            lifetime to the caller's frame; the deref to a `ref [bo]
            RecordBatch` consumed locally within this call.
        sel: Row-survivor selection. `sel.get(k)` yields the source row
            index at output position `k`.

    Returns:
        A freshly-allocated RecordBatch with `sel.len()` rows and the
        same schema as the source.

    Raises:
        Error if any source row index in `sel` is out of bounds. The
        underlying `gather_batch` performs the bounds check.
    """
    # Empty-selection short-circuit: build a 0-row batch from the source
    # schema. Mirrors RecordBatch.from_columns_0 semantics — schema is
    # preserved, _columns is empty (no zero-length per-column buffers
    # are required because num_rows=0 makes the per-column buffer
    # contents unreachable to consumers).
    var n_surv = sel.len()
    if n_surv == 0:
        # Clone the source schema by walking field_at_unchecked for each
        # column; this preserves Phase B/C/X1a metadata (decimal p/s, tz,
        # union type ids, nested children, kv-metadata). Equivalent to
        # RecordBatch.schema.clone() if one existed; the loop is the
        # established pattern (`compiler_helpers.py:746` precedent inside
        # gather_batch itself uses `sb.add_field(batch.schema.field_at(c))`
        # for the same purpose).
        ref source_batch = batch_view._batch[]
        var n_cols = source_batch.num_columns()
        var sb = SchemaBuilder()
        for c in range(n_cols):
            sb.add_field(source_batch.schema.field_at(c))
        var out_schema = sb.build()
        # Empty 0-column case: from_columns_0 only accepts 0-field schemas.
        # For N>0 columns, build a zero-row batch by invoking gather_batch
        # with an empty indices list — gather_batch builds per-column
        # zero-length buffers correctly.
        if n_cols == 0:
            return RecordBatch.from_columns_0(out_schema^)
        var empty_indices = List[Int]()
        return gather_batch(source_batch, empty_indices)

    # Non-empty path: materialize sel indices into a List[Int] and
    # delegate to gather_batch. The List[Int] cost is O(n_surv) with a
    # ~1 ns per index pointer dereference + append; gather_batch's
    # per-column copy work dominates total wall (>=8 bytes/row/column
    # vs the 8 bytes/row from this materialization).
    var indices = List[Int](capacity=n_surv)
    for k in range(n_surv):
        indices.append(Int(sel.get(k)))

    # Deref the BatchView to a ref [bo] RecordBatch. gather_batch's
    # parameter is `read self` (def-style without explicit mut), so the
    # sub-origin from the deref is consumed locally and never escapes.
    return gather_batch(batch_view._batch[], indices)
