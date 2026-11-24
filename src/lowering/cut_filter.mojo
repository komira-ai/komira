# =============================================================================
# cut_filter -- the cutter's PLAN_FILTER arm: a streaming operator
# =============================================================================
#
# A filter is fused onto the open pipeline as an OP_FILTER over its predicate.
# A filter that carries a UDF of the registered kind is refused
# (LOWERING_UNCUTTABLE_NODE), and one whose predicate calls a `UdfRef` (an
# EXPR_UDF_APPLY) is refused with LOWERING_UDF_UNSERVED, before its child is
# walked: a predicate's call is evaluated only on the rows the predicate
# selects, which no operator does yet.
# =============================================================================

from lowering.cut_state import _Pipe, _uncuttable
from lowering.udf_check import _udf_apply_count, _udf_unserved
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import MorselOp


def _filter_op(node: LogicalPlan) raises -> MorselOp:
    """The operator a PLAN_FILTER node fuses, or its refusal. Called before
    the child is walked."""
    ref fd = node.filter_data_ref()
    if fd.has_udf():
        raise _uncuttable(node, "a filter with a UDF")
    if _udf_apply_count(fd.predicate) > 0:
        raise _udf_unserved(node, "a call of a user function in a predicate")
    return MorselOp.filter(fd.predicate.copy())


def _fuse_filter(mut pipe: _Pipe, var op: MorselOp):
    """Fuse the filter's operator onto its child's pipeline."""
    pipe.append_op(op^)
