# =============================================================================
# cut_filter -- the cutter's PLAN_FILTER arm: a streaming operator
# =============================================================================
#
# A filter is fused onto the open pipeline as an OP_FILTER over its predicate.
# A filter that carries a UDF is refused (LOWERING_UNCUTTABLE_NODE) before its
# child is walked.
# =============================================================================

from lowering.cut_state import _Pipe, _uncuttable
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import MorselOp


def _filter_op(node: LogicalPlan) raises -> MorselOp:
    """The operator a PLAN_FILTER node fuses, or its refusal. Called before
    the child is walked."""
    ref fd = node.filter_data_ref()
    if fd.has_udf():
        raise _uncuttable(node, "a filter with a UDF")
    return MorselOp.filter(fd.predicate.copy())


def _fuse_filter(mut pipe: _Pipe, var op: MorselOp):
    """Fuse the filter's operator onto its child's pipeline."""
    pipe.append_op(op^)
