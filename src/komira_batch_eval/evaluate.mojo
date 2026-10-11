# =============================================================================
# evaluate: the public entry points of the batch evaluator
# =============================================================================
#
# An operator evaluates an expression over a record batch through these two
# functions: a projection (`evaluate_column`) or a predicate
# (`evaluate_predicate`). Both take an expression and a batch and return a
# value; neither takes or returns a pointer.
#
# A filter that wants three-valued NULL semantics at its boundary (UNKNOWN is
# dropped, `TRUE OR NULL` is kept) uses `conjunction.evaluate_filter_narrowed`,
# which narrows a selection vector conjunct by conjunct.
# =============================================================================

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr

from .eval_column import _eval_column_expr
from .eval_predicate import _eval_predicate


def evaluate_column(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """Evaluate `expr` over every row of `batch` as a projection.

    Returns a column of `batch.num_rows()` values.

    Raises:
        If `expr` has a tag this evaluator has no arm for, if an operand's type
        is one the arm does not accept, or if integer arithmetic overflows (an
        SQL error, as in DuckDB). A UDF call raises unless its output column
        was materialized onto `batch` under `udf_call_column_key`.
    """
    return _eval_column_expr(expr, batch)


def evaluate_predicate(expr: Expr, batch: RecordBatch) raises -> BooleanArray:
    """Evaluate `expr` over every row of `batch` as a predicate.

    Returns one bit per row. A row whose value is UNKNOWN (an operand was NULL)
    has data bit 0 and, when any operand was nullable, a cleared validity bit;
    use `conjunction.evaluate_filter_narrowed` for a filter, which drops
    UNKNOWN rows and keeps three-valued logic across AND, OR and NOT.

    Raises:
        If `expr` is not a predicate this evaluator can decide, if a literal
        cannot be compared with the column it is compared with, or if
        arithmetic inside it overflows.
    """
    return _eval_predicate(expr, batch)
