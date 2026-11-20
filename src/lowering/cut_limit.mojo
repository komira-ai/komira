# =============================================================================
# cut_limit -- the cutter's PLAN_LIMIT arm: a streaming operator
# =============================================================================
#
# A limit is fused onto the open pipeline as an OP_LIMIT of its count.
# Refused (LOWERING_UNCUTTABLE_NODE): a limit with an offset or a negative
# count, before its child is walked; and a limit above a sort (with only
# filters and projections between), after it: a segment records no order, so
# the rows a limit would keep are not defined.
# =============================================================================

from lowering.cut_state import _Pipe, _uncuttable
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import MorselOp


def limit_op(node: LogicalPlan) raises -> MorselOp:
    """The operator a PLAN_LIMIT node fuses, or its refusal. Called before
    the child is walked."""
    ref ld = node.limit_data_ref()
    if ld.offset != 0:
        raise _uncuttable(node, "a limit with an offset")
    if ld.n < 0:
        raise _uncuttable(node, "a limit with a negative count")
    return MorselOp.limit(ld.n)


def fuse_limit(mut pipe: _Pipe, node: LogicalPlan, var op: MorselOp) raises:
    """Fuse the limit's operator onto its child's pipeline, or refuse a limit
    over a sorted stream."""
    if pipe.sorted_input:
        raise _uncuttable(
            node,
            "a limit over a sorted stream; no order is recorded on a segment",
        )
    pipe.append_op(op^)
