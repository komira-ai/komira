# =============================================================================
# batch_filter — a WHERE predicate applied to one decoded batch
# =============================================================================
#
# The sub-row-group executors filter each decoded chunk here: the predicate is
# evaluated by the morsel filter's evaluator (`evaluate_filter_narrowed`:
# three-valued logic, UNKNOWN dropped) and the survivors are gathered, so the
# rows match the engine's filter operator on the same batch. A batch every row
# of which survives is returned as it is.
#
# A numeric dictionary column is resolved to flat values first: the evaluator
# reads a column by its schema type and is not dictionary-aware for it.
# =============================================================================

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_batch_eval.conjunction import evaluate_filter_narrowed
from komira_column_kernels.compiler_helpers import gather_batch
from komira_plan_expr.expr import Expr


def resolve_numeric_dict_cols_to_flat(var batch: RecordBatch) raises -> RecordBatch:
    """`batch` with every numeric dictionary column resolved to its flat
    values (the schema already names the value type); `batch` itself when
    it has none."""
    var n_cols = batch.num_columns()
    var any_dict = False
    for c in range(n_cols):
        if batch.column_at(c).is_numeric_dict():
            any_dict = True
            break
    if not any_dict:
        return batch^
    var builder = RecordBatchBuilder.with_capacity(n_cols)
    var sb = SchemaBuilder()
    for c in range(n_cols):
        sb.add_field(batch.schema.field_at(c))
        ref col = batch.column_at(c)
        if col.is_numeric_dict():
            builder.add_column(col.resolve_numeric_dict_to_flat())
        else:
            builder.add_column(col.share())
    return builder.build(sb.build())


def filter_batch_by_predicate(var batch: RecordBatch, predicate: Expr) raises -> RecordBatch:
    """The rows of `batch` for which `predicate` is TRUE, in order.

    Raises:
        If the evaluator cannot decide `predicate` on `batch`.
    """
    var flat = resolve_numeric_dict_cols_to_flat(batch^)
    var sv = evaluate_filter_narrowed(flat, predicate)
    if sv.is_all(flat.num_rows()):
        return flat^
    var n = sv.length()
    var indices = List[Int](capacity=n)
    for i in range(n):
        indices.append(Int(sv.indices.get_typed[Scalar[DType.int32]](i)))
    return gather_batch(flat, indices)
