# =============================================================================
# cut_shared -- the cutter's PLAN_CSE_REF arm: a shared subplan, cut once
# =============================================================================
#
# A shared subplan is a subtree that occurs more than once in a plan (a CTE
# the query reads twice, two equal UNION ALL branches). The plan keeps its
# first occurrence whole, the canonical subtree, and holds every later one as
# a PLAN_CSE_REF leaf carrying the canonical subtree's `structural_hash()`
# (`optimizer.plan_cse`). The canonical subtree is the first node of that
# hash the walk reaches; the cutter walks a node before its children and the
# children in order (a union's branches first to last, and in a plan that
# holds a reference a join's right child before its left), the order the
# plan's producer visits them in.
#
# Before the walk the cutter collects the hashes the plan's references name
# (`_referenced_hashes`). While it is not empty, the walk hashes each node once
# its children are cut; a node whose hash is named and has not been cut is a
# canonical subtree. The hash is that of the node as the producer saw it: the
# producer hashes every subtree before it folds any, so a canonical subtree
# that holds a reference (a repeat inside it, or one of a subtree that stood
# before it) is hashed with each reference replaced by the subtree it names
# (`_expanded`), every one of which is cut by then. Two subtrees of one hash
# never nest, so the first to finish is the first in the producer's order. A canonical subtree is cut in one of two ways, judged on
# that expanded form:
#
#   materialized  the subtree holds an aggregation, a distinct, a sort, a
#                 top-n, a window, a limit or a user function (a frame or a
#                 step, whose calls run once): it ends in a segment of its
#                 own (the breaker's, or a SINK_COLLECT one, as a union
#                 branch does),
#                 and the canonical position and every reference read that
#                 segment's output over an E3 edge (SOURCE_SINK_OUTPUT). Each
#                 reader gets the same rows: the engine hands each the
#                 output, a copy to all but the last (`PublishedOutputs`).
#                 A reader of a sort's output, or of a keyed window's (one
#                 with a partition or an order key), is a sorted input, as the
#                 sort's own reader is, so a limit above it is refused.
#   streaming     the subtree is scans, filters, projections and unions of
#                 them only: it is cut again at every reference, over the
#                 same scans (the scan count restarts at the subtree's first
#                 scan, so the references take no input of their own). The
#                 recut is of the subtree as it stands in the plan, so a
#                 reference inside it is cut again over its own subtree's
#                 scans. Its
#                 rows are a function of its files alone, and recutting it
#                 keeps a scan's dictionary-encoded string keys and parallel
#                 read where a copy would hold the whole input in memory.
#
# A node whose hash is named but was cut already is cut as itself: inside the
# recut of a streaming subtree it is a streaming subtree within it (a recut
# holds no breaker, so never a materialized one), and anywhere else it is
# another subtree of that hash the producer left whole (two subtrees with one
# 64-bit hash and different text).
#
# Refused (LOWERING_UNCUTTABLE_NODE, naming PLAN_CSE_REF): a reference reached
# before its canonical subtree, or with no canonical subtree in the plan, and
# a reference whose schema is not the canonical subtree's (the column count,
# and per column the name, the Arrow type, the decimal precision and scale
# and the timezone; nullability is not compared).
# =============================================================================

from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.cut_union import _end_branch, _schema_difference
from lowering.lowered_plan import LoweringInputs
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_SORT,
    PLAN_PARTITION_BY,
    PLAN_TOPN,
    PLAN_LIMIT,
    PLAN_UNION,
    PLAN_JOIN,
    PLAN_ASOF_JOIN,
    PLAN_CSE_REF,
    PLAN_MAP_BATCHES,
)


def _referenced_hashes(plan: LogicalPlan, mut out: List[UInt64]):
    """Append the canonical hash of every PLAN_CSE_REF under the node kinds
    the cutter cuts; a reference under any other node is refused with that
    node."""
    var tag = plan.tag
    if tag == PLAN_CSE_REF:
        var h = plan.cse_ref_data_ref().canonical_hash
        if not _names(out, h):
            out.append(h)
    elif tag == PLAN_FILTER:
        _referenced_hashes(plan.filter_data_ref().child[], out)
    elif tag == PLAN_PROJECT:
        _referenced_hashes(plan.project_data_ref().child[], out)
    elif tag == PLAN_LIMIT:
        _referenced_hashes(plan.limit_data_ref().child[], out)
    elif tag == PLAN_AGGREGATE:
        _referenced_hashes(plan.aggregate_data_ref().child[], out)
    elif tag == PLAN_DISTINCT:
        _referenced_hashes(plan.distinct_data_ref().child[], out)
    elif tag == PLAN_SORT:
        _referenced_hashes(plan.sort_data_ref().child[], out)
    elif tag == PLAN_PARTITION_BY:
        _referenced_hashes(plan.partition_by_data_ref().child[], out)
    elif tag == PLAN_TOPN:
        _referenced_hashes(plan.topn_data_ref().child[], out)
    elif tag == PLAN_MAP_BATCHES:
        _referenced_hashes(plan.map_batches_data_ref().child[], out)
    elif tag == PLAN_UNION:
        ref ud = plan.union_data_ref()
        for i in range(len(ud.children)):
            _referenced_hashes(ud.children[i][], out)
    elif tag == PLAN_JOIN:
        ref jd = plan.join_data_ref()
        _referenced_hashes(jd.left[], out)
        _referenced_hashes(jd.right[], out)
    elif tag == PLAN_ASOF_JOIN:
        ref ad = plan.asof_join_data_ref()
        _referenced_hashes(ad.left[], out)
        _referenced_hashes(ad.right[], out)


def _scan_count(plan: LogicalPlan) -> Int:
    """The scans of `plan` under the node kinds the cutter cuts: the entries
    `LoweringInputs` holds for it. A reference holds none."""
    var tag = plan.tag
    if tag == PLAN_SCAN:
        return 1
    if tag == PLAN_FILTER:
        return _scan_count(plan.filter_data_ref().child[])
    if tag == PLAN_PROJECT:
        return _scan_count(plan.project_data_ref().child[])
    if tag == PLAN_LIMIT:
        return _scan_count(plan.limit_data_ref().child[])
    if tag == PLAN_AGGREGATE:
        return _scan_count(plan.aggregate_data_ref().child[])
    if tag == PLAN_DISTINCT:
        return _scan_count(plan.distinct_data_ref().child[])
    if tag == PLAN_SORT:
        return _scan_count(plan.sort_data_ref().child[])
    if tag == PLAN_PARTITION_BY:
        return _scan_count(plan.partition_by_data_ref().child[])
    if tag == PLAN_TOPN:
        return _scan_count(plan.topn_data_ref().child[])
    if tag == PLAN_MAP_BATCHES:
        return _scan_count(plan.map_batches_data_ref().child[])
    if tag == PLAN_UNION:
        ref ud = plan.union_data_ref()
        var n = 0
        for i in range(len(ud.children)):
            n += _scan_count(ud.children[i][])
        return n
    if tag == PLAN_JOIN:
        ref jd = plan.join_data_ref()
        return _scan_count(jd.left[]) + _scan_count(jd.right[])
    if tag == PLAN_ASOF_JOIN:
        ref ad = plan.asof_join_data_ref()
        return _scan_count(ad.left[]) + _scan_count(ad.right[])
    return 0


def _names(hashes: List[UInt64], h: UInt64) -> Bool:
    for i in range(len(hashes)):
        if hashes[i] == h:
            return True
    return False


def _is_streaming(node: LogicalPlan) -> Bool:
    """True when `node` is scans, filters, projections and unions of them,
    and nothing else."""
    var tag = node.tag
    if tag == PLAN_SCAN:
        return True
    if tag == PLAN_FILTER:
        return _is_streaming(node.filter_data_ref().child[])
    if tag == PLAN_PROJECT:
        return _is_streaming(node.project_data_ref().child[])
    if tag == PLAN_UNION:
        ref ud = node.union_data_ref()
        for i in range(len(ud.children)):
            if not _is_streaming(ud.children[i][]):
                return False
        return True
    return False


def _read_shared(mut cutter: _Cutter, at: Int, node: LogicalPlan) -> _Pipe:
    """A pipeline reading the segment of materialized shared subtree `at`
    for `node` (the canonical subtree or a reference to it), in the schema
    that segment writes."""
    var schema = cutter.shared_read_schemas[at].copy()
    var pipe = cutter._reopen(cutter.shared_segs[at], schema)
    pipe.sorted_input = cutter.shared_sorted[at]
    return pipe^


def _expand_inplace(mut plan: LogicalPlan, cutter: _Cutter):
    """Replace, in `plan`, each reference to a shared subtree cut so far by
    that subtree's expanded copy. A reference to one not cut yet is left; the
    walk refuses it when it reaches it."""
    var tag = plan.tag
    if tag == PLAN_CSE_REF:
        var at = cutter._shared_at(plan.cse_ref_data_ref().canonical_hash)
        if at >= 0:
            plan = cutter.shared_plans[at].copy()
    elif tag == PLAN_FILTER:
        _expand_inplace(plan._filter.value()[].child[], cutter)
    elif tag == PLAN_PROJECT:
        _expand_inplace(plan._project.value()[].child[], cutter)
    elif tag == PLAN_LIMIT:
        _expand_inplace(plan._limit.value()[].child[], cutter)
    elif tag == PLAN_AGGREGATE:
        _expand_inplace(plan._aggregate.value()[].child[], cutter)
    elif tag == PLAN_DISTINCT:
        _expand_inplace(plan._distinct.value()[].child[], cutter)
    elif tag == PLAN_SORT:
        _expand_inplace(plan._sort.value()[].child[], cutter)
    elif tag == PLAN_PARTITION_BY:
        _expand_inplace(plan._partition_by.value()[].child[], cutter)
    elif tag == PLAN_TOPN:
        _expand_inplace(plan._topn.value()[].child[], cutter)
    elif tag == PLAN_MAP_BATCHES:
        _expand_inplace(plan._map_batches.value()[].child[], cutter)
    elif tag == PLAN_UNION:
        var n = len(plan._union.value()[].children)
        for i in range(n):
            _expand_inplace(plan._union.value()[].children[i][], cutter)
    elif tag == PLAN_JOIN:
        _expand_inplace(plan._join.value()[].left[], cutter)
        _expand_inplace(plan._join.value()[].right[], cutter)
    elif tag == PLAN_ASOF_JOIN:
        _expand_inplace(plan._asof_join.value()[].left[], cutter)
        _expand_inplace(plan._asof_join.value()[].right[], cutter)


def _expanded(cutter: _Cutter, node: LogicalPlan) -> LogicalPlan:
    """A copy of `node` with every reference to a shared subtree cut so far
    replaced by that subtree: `node` as its producer saw it before folding
    the repeats inside it (`optimizer.plan_cse` hashes every subtree before it
    rewrites any), so its `structural_hash()` is the hash a reference to it
    carries."""
    var out = node.copy()
    _expand_inplace(out, cutter)
    return out^


def _end_canonical(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var expanded: LogicalPlan,
    h: UInt64,
    first_scan: Int,
    var pipe: _Pipe,
    inputs: LoweringInputs,
) -> _Pipe:
    """Record canonical subtree `node` of hash `h` (`expanded` is its copy
    with the references in it replaced), whose cut began at scan `first_scan`
    and delivered `pipe`, and return the pipeline its parent continues:
    `pipe` itself for a streaming subtree, and a reader of the subtree's
    segment for a materialized one."""
    var streaming = _is_streaming(expanded)
    cutter.shared_hashes.append(h)
    cutter.shared_schemas.append(node.output_schema.copy())
    cutter.shared_first_scan.append(first_scan)
    cutter.shared_plans.append(expanded^)
    cutter.shared_recuts.append(node.copy())
    if streaming:
        cutter.shared_segs.append(-1)
        cutter.shared_read_schemas.append(node.output_schema.copy())
        cutter.shared_sorted.append(False)
        return pipe^
    var sorted = pipe.sorted_input
    cutter.shared_read_schemas.append(pipe.schema.copy())
    var seg = _end_branch(cutter, pipe^, inputs)
    cutter.shared_segs.append(seg)
    cutter.shared_sorted.append(sorted)
    return _read_shared(cutter, len(cutter.shared_hashes) - 1, node)


def _check_reference(cutter: _Cutter, node: LogicalPlan) raises -> Int:
    """The canonical subtree reference `node` names. Raises when none was cut
    before it, or when its schema is not the subtree's."""
    var h = node.cse_ref_data_ref().canonical_hash
    var at = cutter._shared_at(h)
    if at < 0:
        raise _uncuttable(
            node,
            "a reference to shared subplan "
            + String(h)
            + ", which is not cut before it",
        )
    var why = _schema_difference(
        cutter.shared_schemas[at], node.output_schema, "the shared subplan"
    )
    if why != "":
        raise _uncuttable(
            node,
            "a reference to shared subplan "
            + String(h)
            + " that "
            + why,
        )
    return at
