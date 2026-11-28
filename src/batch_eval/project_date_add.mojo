# =============================================================================
# project_date_add: the projection arm for EXPR_DATE_ADD
# =============================================================================
#
# One arm of `eval_column._eval_column_expr`. `date_add(months, days, child)`
# moves a DATE32 child by `months` calendar months (day of month clamped to
# the target month) and then by `days` days, and answers a DATE32 column.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.schema import RecordBatch
from byte_buffer.heap_region import HeapRegion
from kernels.date_add import date32_add_months_days
from plan_expr.expr import Expr

from .column_decimal import _expr_name_hint, _resolve_temporal_arrow_type
from .eval_column import _eval_column_expr


def _project_date_add(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_DATE_ADD` arm of `_eval_column_expr`.

    The child's date type comes from `_resolve_temporal_arrow_type`, so a
    column a parquet or CSV scan stamped INT32 while its schema field says
    DATE32 is served like a DATE32-stamped one. The answer is stamped DATE32.
    """
    var child_col = _eval_column_expr(expr.date_add_child_ref(), batch)
    var src_at = _resolve_temporal_arrow_type(child_col, batch, _expr_name_hint(expr.date_add_child_ref()))
    if src_at != ArrowType.DATE32:
        raise Error(
            "PipelineCompiler: EXPR_DATE_ADD child must be DATE32, got "
            + String(child_col.arrow_type)
            + " and the batch schema does not declare it a date either"
        )
    var out = date32_add_months_days(
        child_col.as_primitive[DType.int32](), expr.date_add_months(), expr.date_add_days()
    )
    var col_out = Column.from_primitive[DType.int32](out^)
    col_out.arrow_type = ArrowType.DATE32
    return col_out^
