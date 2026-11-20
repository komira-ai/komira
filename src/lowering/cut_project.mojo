# =============================================================================
# cut_project -- the cutter's PLAN_PROJECT arm: a streaming operator
# =============================================================================
#
# A projection is fused onto the open pipeline as an OP_PROJECT over its
# expressions, named by the node's output schema; the pipeline then delivers
# that schema and is marked as having a projection (a dictionary encoded group
# key is no longer recognised past it). A projection that carries a UDF is
# refused (LOWERING_UNCUTTABLE_NODE) before its child is walked.
# =============================================================================

from lowering.cut_state import _Pipe, _uncuttable
from plan_ir.logical_plan import LogicalPlan, copy_expr_array
from physical_plan.physical_plan import MorselOp


def project_op(node: LogicalPlan) raises -> MorselOp:
    """The operator a PLAN_PROJECT node fuses, or its refusal. Called before
    the child is walked."""
    ref pd = node.project_data_ref()
    if pd.has_udf():
        raise _uncuttable(node, "a projection with a UDF")
    var names = List[String]()
    for i in range(node.output_schema.num_columns()):
        names.append(node.output_schema.field_name(i))
    return MorselOp.project(copy_expr_array(pd.exprs), names^)


def fuse_project(mut pipe: _Pipe, node: LogicalPlan, var op: MorselOp):
    """Fuse the projection's operator onto its child's pipeline."""
    pipe.append_op(op^)
    pipe.has_project = True
    pipe.schema = node.output_schema.copy()
