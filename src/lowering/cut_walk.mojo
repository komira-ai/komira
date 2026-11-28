# =============================================================================
# cut_walk -- the cutter: a bound plan to segments, edges and a ParamTable
# =============================================================================
#
# One walk of the plan, bottom up. Every node has one of these roles:
#
#   source    PLAN_SCAN: opens a pipeline (SOURCE_PARQUET, SOURCE_BATCH for
#             an in-memory scan, SOURCE_CSV, SOURCE_ICEBERG for an Iceberg
#             table scan, SOURCE_JSONL for one JSON Lines file, or
#             SOURCE_ORC for one ORC file; `cut_scan`); PLAN_STEP, a user function run once, opens
#             one whose source is SOURCE_UDF_STEP (`cut_step`);
#   streaming PLAN_FILTER, PLAN_PROJECT, PLAN_LIMIT, and PLAN_MAP_BATCHES (an
#             ungrouped frame, OP_UDF_FRAME): appended to the open pipeline's
#             `ops`; a projection column that is a user-function call adds an
#             OP_UDF_APPLY before its OP_PROJECT (`cut_project`);
#   breaker   PLAN_AGGREGATE, PLAN_DISTINCT, PLAN_SORT, PLAN_TOPN,
#             PLAN_PARTITION_BY (a window): ends the open pipeline in a sink
#             and opens a pipeline whose source is that segment's output
#             (SOURCE_SINK_OUTPUT), joined by an E3 edge.
#   range     a PLAN_LIMIT that reaches a PLAN_SORT or a PLAN_TOPN through
#             only projections and limits: the chain is one range of the
#             sort's order, cut as a PLAN_TOPN is (`_walk_range`), with the
#             projections fused above it.
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
# `cut_aggregate`, `cut_distinct`, `cut_sort`, `cut_topn`, `cut_window`,
# `cut_union`, `cut_join`, `cut_map_batches`, `cut_step` and `cut_shared`; what
# they share (the open pipeline, the cutter's state and the close and reopen of
# a breaker) is `cut_state`, and what a user-function call is held to is
# `udf_check`. The filter, project, limit, top-n, aggregate, distinct, frame,
# join and window arms have two halves: the first holds every check that
# refuses the node itself and runs before the child (or the children) is
# walked; the second fuses onto, or closes, the child's pipeline. The sort arm
# has only the second. The union arm checks its branches' schemas before it
# walks them, walks them in order, ends each in a segment and opens the
# concatenation.
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
from lowering.cut_limit import (
    RowRange,
    _check_limit,
    _fuse_limit,
    _limit_op,
    _reaches_sort,
    _sorted_stream_refusal,
)
from lowering.cut_map_batches import _map_batches_op, _fuse_map_batches
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
from lowering.cut_step import _open_step
from lowering.cut_state import CutResult, _Cutter, _Pipe, _uncuttable
from lowering.cut_topn import _check_topn, _close_topn
from lowering.cut_union import _check_union, _end_branch, _open_concat
from lowering.cut_window import _window_data, _close_window
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_INPUTS_SCAN_COUNT,
    _copy_udfs,
)
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_TOPN,
    PLAN_JOIN,
    PLAN_UNION,
    PLAN_PARTITION_BY,
    PLAN_CSE_REF,
    PLAN_VIEW_REF,
    PLAN_MAP_BATCHES,
    PLAN_STEP,
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
        var ops = _project_op(node, inputs)
        var pipe = _walk(cutter, node.project_data_ref().child[], inputs)
        _fuse_project(pipe, node, ops^)
        return pipe^
    if tag == PLAN_MAP_BATCHES:
        var op = _map_batches_op(node, inputs)
        var pipe = _walk(cutter, node.map_batches_data_ref().child[], inputs)
        _fuse_map_batches(pipe, node, op^)
        return pipe^
    if tag == PLAN_STEP:
        return _open_step(node, inputs)
    if tag == PLAN_LIMIT:
        if _reaches_sort(node):
            var pipe = _walk_range(cutter, node, RowRange.every_row(), inputs)
            # A shared sort, or a shared node above it, is read whole by its
            # other readers, so its rows are a sorted stream to this limit.
            if len(cutter.referenced) > 0 and _range_holds_shared(
                cutter, node.limit_data_ref().child[]
            ):
                raise _sorted_stream_refusal(node)
            return pipe^
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
    if tag == PLAN_TOPN:
        return _walk_range(cutter, node, RowRange.every_row(), inputs)
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


def _range_holds_shared(cutter: _Cutter, node: LogicalPlan) -> Bool:
    """True when `node`, a node of a range's chain below its top limit (a
    projection, a limit, or the sort or top-n that ends the chain), or a node
    of the chain below it, is a canonical subtree: its hash is one a reference
    names and no node of that hash was cut before. `_walk_range` cuts these
    nodes without `_walk`, so such a node would be neither recorded nor read
    whole by its other readers. Called after the range is cut, when every
    reference under `node` names a subtree cut already, so its expanded form
    is the one its producer hashed (`cut_shared._expanded`)."""
    var h = _expanded(cutter, node).structural_hash()
    if _names(cutter.referenced, h) and cutter._shared_at(h) < 0:
        return True
    if node.tag == PLAN_LIMIT:
        return _range_holds_shared(cutter, node.limit_data_ref().child[])
    if node.tag == PLAN_PROJECT:
        return _range_holds_shared(cutter, node.project_data_ref().child[])
    return False


def _walk_range(
    mut cutter: _Cutter,
    node: LogicalPlan,
    rows: RowRange,
    inputs: LoweringInputs,
) raises -> _Pipe:
    """Cut `node`, a limit, projection, sort or top-n of a chain that ends
    in a sort, keeping `rows` of its output: the range its ancestors in the
    chain keep. A limit narrows the range and passes it on; a projection
    passes it on and is fused above the range's segment; the sort or top-n
    at the end closes its child in that segment."""
    var tag = node.tag
    if tag == PLAN_LIMIT:
        _check_limit(node)
        ref ld = node.limit_data_ref()
        return _walk_range(
            cutter, ld.child[], rows.under_limit(ld.n, ld.offset), inputs
        )
    if tag == PLAN_PROJECT:
        var op = _project_op(node, inputs)
        var pipe = _walk_range(
            cutter, node.project_data_ref().child[], rows, inputs
        )
        _fuse_project(pipe, node, op^)
        return pipe^
    if tag == PLAN_TOPN:
        _check_topn(node)
        ref td = node.topn_data_ref()
        # A top-n is the first `n` rows of its sort: a limit of `n`.
        var pipe = _walk(cutter, td.child[], inputs)
        return _close_topn(
            cutter,
            td.keys.copy(),
            td.descending.copy(),
            td.nulls_first.copy(),
            rows.under_limit(td.n, 0),
            pipe^,
            node.output_schema,
            inputs,
        )
    ref sd = node.sort_data_ref()
    var pipe = _walk(cutter, sd.child[], inputs)
    return _close_topn(
        cutter,
        sd.keys.copy(),
        sd.descending.copy(),
        sd.nulls_first.copy(),
        rows,
        pipe^,
        node.output_schema,
        inputs,
    )


def cut_plan(plan: LogicalPlan, inputs: LoweringInputs) raises -> CutResult:
    """Cut `plan` into segments. Raises a named refusal for a node it does not
    cut, a sink no row serves, a scan the Parquet arm cannot carry, or an
    `inputs` whose scan count is not the plan's."""
    var cutter = _Cutter()
    cutter.params.udfs = _copy_udfs(inputs.udfs)
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
