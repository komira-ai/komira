# =============================================================================
# consume_pushdown.mojo
#   `_apply_consume_pushdown`: the decode-time filter-then-project over one
#   decoded batch, shared by both tiers of the dual-tier consume so they return
#   the same row set.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_column_kernels.compiler_helpers import project_batch_by_names
from komira_engine_runtime.column_filter_predicate import (
    filter_record_batch_via_predicate,
)
from komira_plan_expr.expr import Expr


def _apply_consume_pushdown(
    var batch: RecordBatch,
    var predicate: Optional[Expr],
    var projection: Optional[List[String]],
) raises -> RecordBatch:
    """Apply the consume-pushdown row filter and column projection to one
    decoded `RecordBatch`. The filter runs BEFORE the projection (the
    predicate may reference columns the projection drops):

      1. If `predicate` is `Some`, filter the rows with
         `filter_record_batch_via_predicate`, the same predicate evaluation a
         filter operator uses, so the row set is identical.
      2. If `projection` is `Some`, select that column subset, in that order,
         with `project_batch_by_names`.

    `None` on either side skips that step."""
    var filtered = batch^
    if predicate:
        filtered = filter_record_batch_via_predicate(
            filtered^, predicate.value()
        )
    if projection:
        filtered = project_batch_by_names(filtered, projection.value())
    return filtered^
