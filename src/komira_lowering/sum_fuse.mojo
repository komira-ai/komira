# =============================================================================
# sum_fuse -- the SQL integer sum, lowered to the integer fold
# =============================================================================
#
# The SQL binder widens `sum(<integer>)` to DuckDB's HUGEINT by casting its
# argument: SUM(CAST(<integer> AS DECIMAL(38, 0))), declared DECIMAL(38, 0).
# Run as written, every row of the argument is first written as a 16-byte
# DECIMAL128 value and then read back by the DECIMAL fold. The aggregation sinks
# already fold a signed integer column in 128 bits (`komira_pipeline_exec`
# `agg_fold`), so the cast adds nothing to the arithmetic: the value of a
# signed integer, as a DECIMAL(38, 0), is the integer itself, and the sum of
# the integers in 128 bits is the sum of the DECIMALs in 128 bits.
#
# `lowered_agg_expr` therefore replaces SUM(CAST(e AS DECIMAL(38, 0))) by
# SUM(e) in the data a sink is built from, when and only when
#
#   * the aggregate is a SUM of one argument;
#   * the argument is a plain CAST (not a TRY_CAST) to DECIMAL128 with
#     precision 38 and scale 0;
#   * the type of `e` over the input schema of the aggregation is INT8, INT16,
#     INT32 or INT64. Not a float (the cast rounds), not a DECIMAL (the cast
#     rounds or refuses), not an unsigned integer (the sinks fold signed
#     integers only), not a type that cannot be inferred.
#
# The node's output schema is not touched: it still declares DECIMAL(38, 0),
# and a sink writes an integer sum into that column when the declared type is
# exactly DECIMAL(38, 0) (`agg_output`). The refusals are the cast form's: a
# total with more than 38 digits is refused by name, and a total outside 128
# bits is refused by the fold.
#
# Both forms evaluate `e` the same way, so a wrap inside `e` itself (an INT64
# multiplication, say) is the same in both.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, EXPR_CAST
from komira_plan_ir.logical_plan import _infer_expr_field


def _is_signed_integer(t: ArrowType) -> Bool:
    return (
        t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.INT64
    )


def lowered_agg_expr(agg: AggExpr, input_schema: Schema) raises -> AggExpr:
    """A copy of `agg` for the data of a sink: `SUM(CAST(e AS DECIMAL(38, 0)))`
    over a signed integer `e` becomes `SUM(e)`, every other aggregate is
    copied as it is. `input_schema` is the schema of the rows the aggregation
    reads."""
    var out = agg.copy()
    if agg.func != AGG_SUM or not agg.child or agg.num_children() != 1:
        return out^
    ref arg = agg.child.value()
    if arg.tag != EXPR_CAST:
        return out^
    if (
        arg.cast_is_try()
        or arg.cast_target_arrow() != ArrowType.DECIMAL128
        or arg.cast_decimal_precision() != 38
        or arg.cast_decimal_scale() != 0
    ):
        return out^
    ref inner = arg.cast_child_ref()
    if not _is_signed_integer(_infer_expr_field(inner, input_schema).arrow_type):
        return out^
    out.child = Optional[Expr](arg.cast_child())
    return out^
