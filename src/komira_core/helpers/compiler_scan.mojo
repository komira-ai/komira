# =============================================================================
# Simple-filter extraction for scan-level predicate pushdown
# =============================================================================
#
# A single helper -- `extract_simple_filter` -- used by the metadata-only
# fast paths (a bare COUNT(*), a MIN/MAX answered from statistics) and by
# pushed-filter pruning in the morsel executor.
# =============================================================================

from ..plan.expr import Expr, EXPR_COL_REF, EXPR_BINARY_OP, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND
from komira_core.dtype_sentinel import DTYPE_NONE


def extract_simple_filter(expr: Expr) -> Tuple[String, UInt8, Int64, Float64, DType, Bool]:
    """Try to extract a simple column-op-literal filter from an Expr.

    Returns (col_name, op, int_val, float_val, dtype, success).
    success=True if the filter is a simple comparison that can be used for
    row group statistics pruning.

    Handles:
      - col op lit  (direct comparison)
      - AND of two comparisons on the SAME column (range filter)
        For AND, returns the tighter bounds:
          col >= 5 AND col <= 10 -> (col, EQ, 5, 0, int64, True) with min=5, max=10
        But since we can only return one op, for AND we return the first
        arm and let the caller handle both arms. For simple AND, we handle
        the first comparison arm as the primary filter.

    Only supports comparison ops: EQ, NE, LT, LE, GT, GE.
    """
    if expr.tag != EXPR_BINARY_OP:
        return (String(""), UInt8(0), Int64(0), Float64(0.0), DTYPE_NONE, False)

    var op = expr.binary_op()

    # Handle AND: try to extract from left arm (which is usually the
    # first filter pushed down). This gets us at least one arm for pruning.
    if op == BIN_AND:
        return extract_simple_filter(expr.binary_left_ref())

    # Must be a comparison op.
    if op != BIN_EQ and op != BIN_NE and op != BIN_LT and op != BIN_LE and op != BIN_GT and op != BIN_GE:
        return (String(""), UInt8(0), Int64(0), Float64(0.0), DTYPE_NONE, False)

    # Left must be column ref, right must be literal.
    if expr.binary_left_ref().tag != EXPR_COL_REF:
        return (String(""), UInt8(0), Int64(0), Float64(0.0), DTYPE_NONE, False)

    if not expr.binary_right_ref().is_literal():
        return (String(""), UInt8(0), Int64(0), Float64(0.0), DTYPE_NONE, False)

    var col_name = expr.binary_left_ref().col_ref_name()
    var lit_val = expr.binary_right_ref().literal_value()

    # NE cannot prune row groups (a != 5 still needs all RGs except those
    # where all values == 5, which is rare and min==max==5 is the only case).
    # We skip NE for stats pruning but still return success=True so the
    # caller knows the filter column name for late materialization.
    if op == BIN_NE:
        return (col_name^, op, lit_val.int_val, lit_val.float_val, lit_val.dtype, True)

    return (col_name^, op, lit_val.int_val, lit_val.float_val, lit_val.dtype, True)

