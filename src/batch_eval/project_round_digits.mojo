# The `EXPR_ROUND_DIGITS` arm of `_eval_column_expr`: `round(x, d)`,
# `trunc(x, d)` and the half-even `Series.round` over INT8..INT64, FLOAT32,
# FLOAT64 and DECIMAL128 columns. The output type is the one
# `walk_expr_field` declares (the input's own, DECIMAL128 with the rescaled
# (precision, scale)); the kernels live in `column_kernels.round_digits`.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.schema import RecordBatch
from byte_buffer.heap_region import HeapRegion
from column_kernels.round_digits import (
    eval_round_digits_decimal,
    eval_round_digits_float,
    eval_round_digits_int,
)
from plan_expr.expr import Expr

from .eval_column import _eval_column_expr


def _project_round_digits(
    expr: Expr, batch: RecordBatch
) raises -> Column[HeapRegion]:
    """Evaluate the child column, then the rounding kernel for its type."""
    var child = _eval_column_expr(expr.round_digits_child_ref(), batch)
    var op = expr.round_digits_op()
    var digits = Int(expr.round_digits_count())
    var at = child.arrow_type
    if at == ArrowType.FLOAT64:
        return Column.from_primitive[DType.float64](
            eval_round_digits_float[DType.float64](
                op, digits, child.as_primitive[DType.float64]()
            )
        )
    elif at == ArrowType.FLOAT32:
        return Column.from_primitive[DType.float32](
            eval_round_digits_float[DType.float32](
                op, digits, child.as_primitive[DType.float32]()
            )
        )
    elif at == ArrowType.INT64:
        return Column.from_primitive[DType.int64](
            eval_round_digits_int[DType.int64](
                op, digits, child.as_primitive[DType.int64]()
            )
        )
    elif at == ArrowType.INT32:
        return Column.from_primitive[DType.int32](
            eval_round_digits_int[DType.int32](
                op, digits, child.as_primitive[DType.int32]()
            )
        )
    elif at == ArrowType.INT16:
        return Column.from_primitive[DType.int16](
            eval_round_digits_int[DType.int16](
                op, digits, child.as_primitive[DType.int16]()
            )
        )
    elif at == ArrowType.INT8:
        return Column.from_primitive[DType.int8](
            eval_round_digits_int[DType.int8](
                op, digits, child.as_primitive[DType.int8]()
            )
        )
    elif at == ArrowType.DECIMAL128:
        return Column.from_decimal128(
            eval_round_digits_decimal(op, digits, child.as_decimal128())
        )
    raise Error(
        "PipelineCompiler: round(x, digits) / trunc(x, digits) support INT8 /"
        " INT16 / INT32 / INT64 / FLOAT32 / FLOAT64 / DECIMAL128 columns;"
        " got arrow type " + String(Int(at.type_id)) + ". CAST the column to"
        " DOUBLE or DECIMAL first."
    )
