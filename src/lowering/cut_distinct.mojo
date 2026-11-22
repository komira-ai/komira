# =============================================================================
# cut_distinct -- the cutter's PLAN_DISTINCT arm: a breaker
# =============================================================================
#
# SELECT DISTINCT is a grouping on every column with no aggregate: one output
# row per distinct row, and NULL is a value of its own, so the rows that are
# NULL in a column and equal in the others are one row. A distinct ends the
# open pipeline in a SINK_AGG segment whose AggSinkData has the node's columns,
# in order, as its group keys and no aggregate, and opens a pipeline that reads
# that segment's output. The sink's `(key_dtype, orientation)` is the one an
# aggregation with those group keys gets (`cut_aggregate._agg_triple`), so the
# columns a distinct is served over are the group keys a host serves, and any
# other is LOWERING_SINK_UNSERVED by the same name.
#
# Refused (LOWERING_UNCUTTABLE_NODE) before the child is walked: a distinct
# over an explicit column list (the binder never makes one: it dedups over the
# whole row), a distinct over no column, and a distinct over two columns of one
# name (a group key is a column reference by name, so the second would read
# the first).
# =============================================================================

from lowering.cut_aggregate import _agg_triple
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import LoweringInputs
from plan_expr.expr import Expr
from plan_ir.logical_plan import LogicalPlan, AggExprArray, ExprArray
from physical_plan.physical_plan import AggSinkData, SINK_AGG


def _distinct_keys(node: LogicalPlan) raises -> ExprArray:
    """The group keys of a PLAN_DISTINCT node's sink, a reference to each of
    its columns in order, or its refusal. Called before the child is walked."""
    ref dd = node.distinct_data_ref()
    if dd.columns:
        raise _uncuttable(node, "a distinct over a column list")
    ref schema = node.output_schema
    var n = schema.num_columns()
    if n == 0:
        raise _uncuttable(node, "a distinct over no column")
    var keys = ExprArray()
    for i in range(n):
        var name = schema.field_name(i)
        for j in range(i):
            if schema.field_name(j) == name:
                raise _uncuttable(
                    node,
                    "a distinct over two columns both named `" + name + "`",
                )
        keys.append(Expr.col_ref(name))
    return keys^


def _close_distinct(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var pipe: _Pipe,
    var keys: ExprArray,
    inputs: LoweringInputs,
) raises -> _Pipe:
    """End the distinct's child pipeline in its sink and open the pipeline
    that reads the distinct rows."""
    var triple = _agg_triple(keys, node.output_schema, pipe, inputs)
    var pid = len(cutter.params.agg)
    cutter.params.agg.append(
        AggSinkData(keys^, AggExprArray(), node.output_schema.copy())
    )
    var seg = cutter._close(
        pipe^, SINK_AGG, triple.key_dtype, triple.orientation, pid, inputs
    )
    return cutter._reopen(seg, node.output_schema)
