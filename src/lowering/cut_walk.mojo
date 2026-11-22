# =============================================================================
# cut_walk -- the cutter: a bound plan to segments, edges and a ParamTable
# =============================================================================
#
# One walk of the plan, bottom up. Every node has one of these roles:
#
#   source    PLAN_SCAN: opens a pipeline (SOURCE_PARQUET, or SOURCE_BATCH for
#             an in-memory scan);
#   streaming PLAN_FILTER, PLAN_PROJECT, PLAN_LIMIT: appended to the open
#             pipeline's `ops`;
#   breaker   PLAN_AGGREGATE, PLAN_DISTINCT, PLAN_SORT, PLAN_PARTITION_BY (a
#             window): ends the open pipeline in a sink and opens a pipeline
#             whose source is that segment's output (SOURCE_SINK_OUTPUT),
#             joined by an E3 edge.
#   union     PLAN_UNION: each branch ends in a segment of its own, and a
#             pipeline opens whose source is the concatenation of their
#             outputs in branch order (SOURCE_CONCAT), joined by an E3 edge to
#             each.
#   shared    PLAN_CSE_REF, a reference to a shared subplan, and the canonical
#             subtree it names: a subtree with a breaker or a limit is cut
#             once into a segment every reference reads over an E3 edge, and
#             one of scans, filters, projections and unions is cut again at
#             each reference (`cut_shared`).
#
# A PLAN_JOIN is both: its build child's pipeline ends in a SINK_HASH_BUILD
# segment, and its probe child's pipeline stays open with an OP_JOIN_PROBE
# fused onto it and an E3 edge to the build segment (`cut_join`). In a plan
# that holds a shared-subplan reference its right child is walked first, the
# order the plan's producer visits a join in (`cut_shared`); the scan count
# is set for each child, so its scans keep their pre-order indices.
#
# This module is the dispatch on the node's tag (`_walk_node`) and, around it,
# the resolution of shared subplans (`_walk`, `_resolve`). Each arm is its own
# module: `cut_scan`, `cut_filter`, `cut_project`, `cut_limit`,
# `cut_aggregate`, `cut_distinct`, `cut_sort`, `cut_window`, `cut_union`,
# `cut_join` and `cut_shared`; what they share (the open pipeline, the
# cutter's state and the close and reopen of a breaker) is `cut_state`. The
# filter, project, limit, aggregate, distinct, join and window arms have two
# halves: the first holds every check that refuses the node itself and runs
# before the child (or the children) is walked; the second fuses onto, or
# closes, the child's pipeline. The sort arm has only the second. The union
# arm checks its branches' schemas before it walks them, walks them in order,
# ends each in a segment and opens the concatenation.
#
# The root is a SINK_COLLECT segment, unless the plan's top node is a breaker:
# then that breaker's segment is the result and nothing is appended.
#
# Any other node is refused with LOWERING_UNCUTTABLE_NODE naming its tag; a
# view reference (PLAN_VIEW_REF) names a view registry lowering does not see,
# and the refusal says it is resolved before lowering. The cutter never
# replaces a node it cannot cut by a resident batch or a generic collect.
# =============================================================================

from lowering.cut_aggregate import _aggregate_exprs, _close_aggregate
from lowering.cut_distinct import _distinct_keys, _close_distinct
from lowering.cut_filter import _filter_op, _fuse_filter
from lowering.cut_join import join_shape, _close_join
from lowering.cut_limit import _limit_op, _fuse_limit
from lowering.cut_project import _project_op, _fuse_project
from lowering.cut_scan import _open_scan
from lowering.cut_shared import (
    _check_reference,
    _end_canonical,
    _expanded,
    _names,
    _read_shared,
    _referenced_hashes,
    _scan_count,
)
from lowering.cut_sort import _close_sort
from lowering.cut_state import CutResult, _Cutter, _Pipe, _uncuttable
from lowering.cut_union import _check_union, _end_branch, _open_concat
from lowering.cut_window import _window_data, _close_window
from lowering.lowered_plan import LoweringInputs, LOWERING_INPUTS_SCAN_COUNT
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_JOIN,
    PLAN_UNION,
    PLAN_PARTITION_BY,
    PLAN_CSE_REF,
    PLAN_VIEW_REF,
)
from physical_plan.physical_plan import (
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def _walk(
    mut cutter: _Cutter, node: LogicalPlan, inputs: LoweringInputs
) raises -> _Pipe:
    """Cut `node`: a shared-subplan reference, a canonical subtree a reference
    names, or any other node by its arm (`cut_shared`)."""
    if node.tag == PLAN_CSE_REF:
        var target = _check_reference(cutter, node)
        return _resolve(cutter, target, node, inputs)
    if len(cutter.referenced) == 0:
        return _walk_node(cutter, node, inputs)
    var first_scan = cutter.scans_seen
    var pipe = _walk_node(cutter, node, inputs)
    # The node as its producer saw it, before it folded the repeats inside it
    # into references: hashed after its children are cut, so every reference
    # inside it names a subtree cut already and expands.
    var expanded = _expanded(cutter, node)
    var h = expanded.structural_hash()
    # A named hash cut before is cut as itself: a streaming subtree inside the
    # recut of another, or a subtree of the same hash the producer left whole
    # (`cut_shared`).
    if _names(cutter.referenced, h) and cutter._shared_at(h) < 0:
        return _end_canonical(
            cutter, node, expanded^, h, first_scan, pipe^, inputs
        )
    return pipe^


def _resolve(
    mut cutter: _Cutter, at: Int, node: LogicalPlan, inputs: LoweringInputs
) raises -> _Pipe:
    """The pipeline of reference `node` to shared subtree `at`: a reader of
    its segment, or the streaming subtree cut again over its own scans."""
    if cutter.shared_segs[at] >= 0:
        return _read_shared(cutter, at, node)
    var copy = cutter.shared_recuts[at].copy()
    var resume = cutter.scans_seen
    cutter.scans_seen = cutter.shared_first_scan[at]
    var pipe = _walk_node(cutter, copy, inputs)
    cutter.scans_seen = resume
    return pipe^


def _walk_node(
    mut cutter: _Cutter, node: LogicalPlan, inputs: LoweringInputs
) raises -> _Pipe:
    """The dispatch on `node`'s tag."""
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
    if tag == PLAN_DISTINCT:
        var keys = _distinct_keys(node)
        var pipe = _walk(cutter, node.distinct_data_ref().child[], inputs)
        return _close_distinct(cutter, node, pipe^, keys^, inputs)
    if tag == PLAN_SORT:
        var pipe = _walk(cutter, node.sort_data_ref().child[], inputs)
        return _close_sort(cutter, node, pipe^, inputs)
    if tag == PLAN_PARTITION_BY:
        var data = _window_data(node)
        var pipe = _walk(cutter, node.partition_by_data_ref().child[], inputs)
        return _close_window(cutter, node, pipe^, data^, inputs)
    if tag == PLAN_JOIN:
        var shape = join_shape(node)
        ref jd = node.join_data_ref()
        if len(cutter.referenced) == 0:
            var left = _walk(cutter, jd.left[], inputs)
            var right = _walk(cutter, jd.right[], inputs)
            return _close_join(cutter, node, shape^, left^, right^, inputs)
        # The right child first, as the producer of the references visits a
        # join, so a canonical subtree there is cut before a reference to it
        # on the left; each child's scans keep their pre-order indices.
        var start = cutter.scans_seen
        cutter.scans_seen = start + _scan_count(jd.left[])
        var right = _walk(cutter, jd.right[], inputs)
        var end = cutter.scans_seen
        cutter.scans_seen = start
        var left = _walk(cutter, jd.left[], inputs)
        cutter.scans_seen = end
        return _close_join(cutter, node, shape^, left^, right^, inputs)
    if tag == PLAN_UNION:
        _check_union(node)
        ref ud = node.union_data_ref()
        var producers = List[Int]()
        for i in range(len(ud.children)):
            var branch = _walk(cutter, ud.children[i][], inputs)
            producers.append(_end_branch(cutter, branch^, inputs))
        return _open_concat(node, producers)
    if tag == PLAN_VIEW_REF:
        raise _uncuttable(
            node, "a view reference; views are resolved before lowering"
        )
    raise _uncuttable(node, "no cutter arm for this node")


def cut_plan(plan: LogicalPlan, inputs: LoweringInputs) raises -> CutResult:
    """Cut `plan` into segments. Raises a named refusal for a node it does not
    cut, a sink no row serves, a scan the Parquet arm cannot carry, or an
    `inputs` whose scan count is not the plan's."""
    var cutter = _Cutter()
    _referenced_hashes(plan, cutter.referenced)
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
