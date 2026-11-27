# =============================================================================
# cut_unnest -- the cutter's PLAN_UNNEST arm: a streaming operator
# =============================================================================
#
# An Unnest is fused onto the open pipeline as an OP_UNNEST naming its list
# column and its `keep_empty` flag. Its output, the node's schema, replaces
# the morsel: the list column becomes its element type in place, and each
# input row gives as many rows as its list has elements. The rows it returns
# are not bounded by the rows it reads and the list column is no longer the
# scan's, so past it the pipeline keeps no row estimate, no dictionary encoded
# key and no sort order.
# =============================================================================

from lowering.cut_state import _Pipe
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import MorselOp


def _unnest_op(node: LogicalPlan) -> MorselOp:
    """The OP_UNNEST a PLAN_UNNEST node fuses."""
    ref d = node.unnest_data_ref()
    return MorselOp.unnest(d.column, d.keep_empty)


def _fuse_unnest(mut pipe: _Pipe, node: LogicalPlan, var op: MorselOp):
    """Fuse the unnest's operator onto its child's pipeline."""
    pipe.append_op(op^)
    pipe.schema = node.output_schema.copy()
    pipe.has_project = True
    pipe.has_join = True
    pipe.sorted_input = False
