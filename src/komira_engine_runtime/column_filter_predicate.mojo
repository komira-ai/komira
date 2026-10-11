# =============================================================================
# column_filter_predicate: filter a RecordBatch or a ColumnNativeBatch by a
# predicate Expr.
# =============================================================================
#
# Both entry points evaluate the predicate with `evaluate_filter_narrowed`
# (komira_batch_eval, the evaluator a FILTER operator uses) and keep the
# surviving rows with `gather_batch`, so the result is the one a FILTER
# operator would produce for the same batch. They sit in the engine runtime so
# that a scan package can filter without depending on the operator packages.
# =============================================================================

from komira_arrow.schema import RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.column_native import ColumnNativeBatch
from komira_batch_eval.conjunction import evaluate_filter_narrowed
from komira_column_kernels.compiler_helpers import gather_batch
from komira_plan_expr.expr import Expr

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


def _resolve_numeric_dict_cols_to_flat(var batch: RecordBatch) raises -> RecordBatch:
    """Materialize every NUMERIC DICTIONARY column in `batch` to a flat
    primitive column; every other column is deep-copied unchanged, and a batch
    with no numeric dictionary column is returned as is.

    The RecordBatch -> ColumnNativeBatch bridge refuses DICTIONARY columns, so
    a numeric dictionary column must be resolved before it. The batch schema
    already reports the logical int/float dtype of such a column, so the
    resolved column matches its field.
    """
    var n_cols = batch.num_columns()
    var any_dict = False
    for c in range(n_cols):
        if batch.column_at(c).is_numeric_dict():
            any_dict = True
            break
    if not any_dict:
        return batch^

    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for c in range(n_cols):
        sb.add_field(batch.schema.field_at(c))
        ref col_ref = batch.column_at(c)
        if col_ref.is_numeric_dict():
            builder.add_column(col_ref.resolve_numeric_dict_to_flat())
        else:
            builder.add_column(col_ref.deep_copy())
    var out_schema = sb.build()
    var rebuilt = builder.build(out_schema^)
    _ = batch^
    return rebuilt^


def filter_column_native_via_predicate(
    var batch: ColumnNativeBatch, predicate: Expr
) raises -> ColumnNativeBatch:
    """Apply a filter `predicate` Expr over a `ColumnNativeBatch`, returning a
    DENSE `ColumnNativeBatch` of the surviving rows in input order.

    Bridges the batch to a RecordBatch, evaluates the predicate with
    `evaluate_filter_narrowed`, and keeps the surviving rows with
    `gather_batch`. When every row survives, the batch is returned without a
    gather.

    Args:
        batch: The input column-native batch (consumed). Must be dense (no
            selection vector); the bridge raises otherwise.
        predicate: The filter predicate Expr tree (borrowed; read-only).

    Returns:
        A DENSE `ColumnNativeBatch` carrying the surviving rows in input order.
    """
    var rb = record_batch_from_column_native(batch^)
    var sv = evaluate_filter_narrowed(rb, predicate)
    var n_total = rb.num_rows()

    if sv.is_all(n_total):
        # Every row survived: a gather would rebuild the same buffers.
        return column_native_from_record_batch(rb^)

    var surviving = sv.length()
    var indices = List[Int](capacity=surviving)
    for i in range(surviving):
        indices.append(Int(sv.indices.get_typed[Scalar[DType.int32]](i)))
    var filtered = gather_batch(rb, indices)
    return column_native_from_record_batch(filtered^)


def filter_record_batch_via_predicate(
    var batch: RecordBatch, predicate: Expr
) raises -> RecordBatch:
    """Apply a filter `predicate` over a RecordBatch, returning the dense
    filtered RecordBatch. The schema and column order are unchanged (a filter
    only removes rows), so column indices into the input still hold.

    Numeric DICTIONARY columns are resolved to flat columns first, because the
    RecordBatch -> ColumnNativeBatch bridge refuses DICTIONARY columns; a
    string DICTIONARY column is still refused. The rest is
    `filter_column_native_via_predicate` between the two bridges."""
    var flat = _resolve_numeric_dict_cols_to_flat(batch^)
    var native = column_native_from_record_batch(flat^)
    var filtered = filter_column_native_via_predicate(native^, predicate)
    return record_batch_from_column_native(filtered^)
