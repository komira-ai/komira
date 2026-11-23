# =============================================================================
# cut_map_batches -- the cutter's PLAN_MAP_BATCHES arm: a streaming operator
# =============================================================================
#
# An ungrouped frame (a MAP_BATCHES_FRAME function called once per batch) is
# fused onto the open pipeline as an OP_UDF_FRAME. It receives exactly the
# columns of its read set, in the set's order, and its output, the node's
# schema, replaces the morsel. The rows it returns are not bounded by the
# rows it reads, and its columns are not the scan's, so past it the pipeline
# keeps no row estimate, no dictionary encoded key and no sort order.
#
# Before the child is walked the call is held to its `UdfRef` (`udf_check`):
# a function of another kind, one that declares no read set or one whose read
# set names a column its child lacks is refused, a group key that reads a
# column outside the read set is refused with LOWERING_UDF_UNDECLARED_READ,
# and a grouped frame is refused with LOWERING_UDF_UNSERVED (one call per
# group needs the group's rows gathered, which no segment does yet).
# =============================================================================

from lowering.cut_state import _Pipe
from lowering.lowered_plan import LoweringInputs
from lowering.udf_check import _frame_call_spec
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import MorselOp, OP_UDF_FRAME


def _map_batches_op(
    node: LogicalPlan, inputs: LoweringInputs
) raises -> MorselOp:
    """The operator a PLAN_MAP_BATCHES node fuses, or its refusal. Called
    before the child is walked."""
    return MorselOp.udf_call(OP_UDF_FRAME, _frame_call_spec(node, inputs))


def _fuse_map_batches(mut pipe: _Pipe, node: LogicalPlan, var op: MorselOp):
    """Fuse the frame's operator onto its child's pipeline."""
    pipe.append_op(op^)
    pipe.schema = node.output_schema.copy()
    pipe.has_project = True
    pipe.has_join = True
    pipe.sorted_input = False
