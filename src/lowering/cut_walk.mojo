# =============================================================================
# cut_walk -- the cutter: a bound plan to segments, edges and a ParamTable
# =============================================================================
#
# One walk of the plan, bottom up. Every node is one of three roles:
#
#   source    PLAN_SCAN: opens a pipeline (SOURCE_PARQUET, or SOURCE_BATCH for
#             an in-memory scan);
#   streaming PLAN_FILTER, PLAN_PROJECT, PLAN_LIMIT: appended to the open
#             pipeline's `ops`;
#   breaker   PLAN_AGGREGATE, PLAN_SORT: ends the open pipeline in a sink and
#             opens a pipeline whose source is that segment's output
#             (SOURCE_SINK_OUTPUT), joined by an E3 edge.
#
# This module is only the dispatch on the node's tag. Each arm is its own
# module: `cut_scan`, `cut_filter`, `cut_project`, `cut_limit`,
# `cut_aggregate` and `cut_sort`; what they share (the open pipeline, the
# cutter's state and the close and reopen of a breaker) is `cut_state`. The
# filter, project, limit and aggregate arms have two halves: the first holds
# every check that refuses the node itself and runs before the child is
# walked; the second fuses onto, or closes, the child's pipeline. The sort arm
# has only the second.
#
# The root is a SINK_COLLECT segment, unless the plan's top node is a breaker:
# then that breaker's segment is the result and nothing is appended.
#
# Any other node is refused with LOWERING_UNCUTTABLE_NODE naming its tag. The
# cutter never replaces a node it cannot cut by a resident batch or a generic
# collect.
# =============================================================================

from lowering.cut_aggregate import _aggregate_exprs, _close_aggregate
from lowering.cut_filter import _filter_op, _fuse_filter
from lowering.cut_limit import _limit_op, _fuse_limit
from lowering.cut_project import _project_op, _fuse_project
from lowering.cut_scan import _open_scan
from lowering.cut_sort import _close_sort
from lowering.cut_state import CutResult, _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import LoweringInputs, LOWERING_INPUTS_SCAN_COUNT
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
)
from physical_plan.physical_plan import (
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def _walk(
    mut cutter: _Cutter, node: LogicalPlan, inputs: LoweringInputs
) raises -> _Pipe:
    var tag = node.tag
    if tag == PLAN_SCAN:
        return _open_scan(cutter, node, inputs)
    if tag == PLAN_FILTER:
        var op = _filter_op(node)
        var pipe = _walk(cutter, node.filter_data_ref().child[], inputs)
        _fuse_filter(pipe, op^)
        return pipe^
    if tag == PLAN_PROJECT:
        var op = _project_op(node)
        var pipe = _walk(cutter, node.project_data_ref().child[], inputs)
        _fuse_project(pipe, node, op^)
        return pipe^
    if tag == PLAN_LIMIT:
        var op = _limit_op(node)
        var pipe = _walk(cutter, node.limit_data_ref().child[], inputs)
        _fuse_limit(pipe, node, op^)
        return pipe^
    if tag == PLAN_AGGREGATE:
        var aggs = _aggregate_exprs(node)
        var pipe = _walk(cutter, node.aggregate_data_ref().child[], inputs)
        return _close_aggregate(cutter, node, pipe^, aggs^, inputs)
    if tag == PLAN_SORT:
        var pipe = _walk(cutter, node.sort_data_ref().child[], inputs)
        return _close_sort(cutter, node, pipe^, inputs)
    raise _uncuttable(node, "no cutter arm for this node")


def cut_plan(plan: LogicalPlan, inputs: LoweringInputs) raises -> CutResult:
    """Cut `plan` into segments. Raises a named refusal for a node it does not
    cut, a sink no row serves, a scan the Parquet arm cannot carry, or an
    `inputs` whose scan count is not the plan's."""
    var cutter = _Cutter()
    var pipe = _walk(cutter, plan, inputs)
    if cutter.scans_seen != len(inputs.scans):
        raise Error(
            String(LOWERING_INPUTS_SCAN_COUNT)
            + ": the plan has "
            + String(cutter.scans_seen)
            + " scans and the inputs hold "
            + String(len(inputs.scans))
        )
    var result = pipe.broken_by
    if result < 0:
        result = cutter._close(
            pipe^, SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, inputs
        )
    return cutter^.finish(result)
