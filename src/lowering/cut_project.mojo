# =============================================================================
# cut_project -- the cutter's PLAN_PROJECT arm: a streaming operator
# =============================================================================
#
# A projection is fused onto the open pipeline as an OP_PROJECT over its
# expressions, named by the node's output schema; the pipeline then delivers
# that schema and is marked as having a projection (a dictionary encoded group
# key is no longer recognised past it). A projection that carries a UDF of the
# registered kind (`ProjectData.has_udf`) is refused
# (LOWERING_UNCUTTABLE_NODE) before its child is walked.
#
# A column that is wholly a call of a `UdfRef` (an EXPR_UDF_APPLY, under any
# aliases) is cut as an OP_UDF_APPLY fused before the OP_PROJECT: the call is
# evaluated over the projection's input and appended as column
# `__udf_apply:<i>`, `i` the column's position, which the OP_PROJECT then
# reads in the call's place. Each call is held to its `UdfRef` first
# (`udf_check`): a ROW call whose argument reads a column outside its read set
# is refused with LOWERING_UDF_UNDECLARED_READ. A call anywhere else in an
# expression (under an operator, a function, a CASE or another call) is
# refused with LOWERING_UDF_UNSERVED: such a call is evaluated only on the rows
# its enclosing expression selects, which an appended column does not do.
# =============================================================================

from containers.slab import Slab
from lowering.cut_state import _Pipe, _uncuttable
from lowering.lowered_plan import LoweringInputs
from lowering.udf_check import _apply_call_spec, _udf_apply_count, _udf_unserved
from plan_expr.expr import Expr, EXPR_ALIAS, EXPR_UDF_APPLY
from plan_ir.logical_plan import ExprArray, LogicalPlan
from physical_plan.physical_plan import MorselOp, OP_UDF_APPLY


comptime _UDF_APPLY_COLUMN_PREFIX = "__udf_apply:"
"""The name of the column an OP_UDF_APPLY appends is this prefix and the
position of the projection column it computes."""


def _unaliased(e: Expr) -> Expr:
    """`e` without the aliases around it."""
    if e.tag == EXPR_ALIAS:
        return _unaliased(e.alias_child_ref())
    return e.copy()


def _project_op(
    node: LogicalPlan, inputs: LoweringInputs
) raises -> Slab[MorselOp]:
    """The operators a PLAN_PROJECT node fuses, in order (an OP_UDF_APPLY per
    column that is a call, then the OP_PROJECT), or its refusal. Called before
    the child is walked."""
    ref pd = node.project_data_ref()
    if pd.has_udf():
        raise _uncuttable(node, "a projection with a UDF")
    ref input = pd.child[].output_schema
    var ops = Slab[MorselOp]()
    var exprs = ExprArray()
    for i in range(len(pd.exprs)):
        var inner = _unaliased(pd.exprs[i])
        if inner.tag != EXPR_UDF_APPLY:
            if _udf_apply_count(pd.exprs[i]) > 0:
                raise _udf_unserved(
                    node,
                    "a call of a user function inside the expression of"
                    " column " + String(i),
                )
            exprs.append(pd.exprs[i].copy())
            continue
        var column = String(_UDF_APPLY_COLUMN_PREFIX) + String(i)
        for c in range(input.num_columns()):
            if input.field_name(c) == column:
                raise _udf_unserved(
                    node,
                    "its input already has a column named '" + column + "'",
                )
        ops.append(
            MorselOp.udf_call(
                OP_UDF_APPLY,
                _apply_call_spec(node, inner, input, inputs, column.copy()),
            )
        )
        exprs.append(Expr.col_ref(column))
    var names = List[String]()
    for i in range(node.output_schema.num_columns()):
        names.append(node.output_schema.field_name(i))
    ops.append(MorselOp.project(exprs^, names^))
    return ops^


def _fuse_project(mut pipe: _Pipe, node: LogicalPlan, var ops: Slab[MorselOp]):
    """Fuse the projection's operators onto its child's pipeline."""
    pipe.append_ops(ops^)
    pipe.has_project = True
    pipe.schema = node.output_schema.copy()
