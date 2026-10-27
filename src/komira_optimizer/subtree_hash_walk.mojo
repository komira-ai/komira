# =============================================================================
# subtree_hash_walk.mojo -- the walk shared by `plan_cse` and
# `scan_dedup_compile`: which subtrees hold a scan, which are pure, and how
# many times each scan-bearing subtree occurs, keyed on `structural_hash`.
#
# The key is `LogicalPlan.structural_hash()`, the hash of the plan's rendered
# text, so two subtrees that render alike count as one occurrence group. A
# `Dict` handed to `count_scan_subtrees` belongs to that one call: nothing here
# keeps state between calls.
#
# PURITY. A subtree is pure when re-evaluating it has no observable effect, so
# two occurrences may be computed once. `plan_is_pure` answers from an
# allowlist of node kinds, and a node that carries a typed UDF answers False:
# the function body is opaque to the optimizer and may hold state, so two
# occurrences are never shared even when their rendered text (UDF id and call
# site salt included) is identical. A node kind that is not on the allowlist
# (cast, exchange, map_batches, step, or a kind added later) also answers
# False, so a new kind is not shared until it is listed here.
# =============================================================================

from std.collections import Dict

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
)


def plan_is_pure(plan: LogicalPlan) -> Bool:
    """True iff `plan` and every descendant is on the pure allowlist and
    carries no typed UDF.

    A view reference and a CSE reference are pure leaves: the first names a
    registered view, the second names an already-shared pure subtree.
    """
    if plan.tag == PLAN_SCAN:
        return True
    if plan.tag == PLAN_FILTER:
        if plan._filter.value()[].has_udf():
            return False
        return plan_is_pure(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        if plan._project.value()[].has_udf():
            return False
        return plan_is_pure(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        if plan._aggregate.value()[].has_udf():
            return False
        return plan_is_pure(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        if not plan_is_pure(plan._join.value()[].left[]):
            return False
        return plan_is_pure(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return plan_is_pure(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return plan_is_pure(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return plan_is_pure(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return plan_is_pure(plan._topn.value()[].child[])
    if plan.tag == PLAN_PARTITION_BY:
        return plan_is_pure(plan._partition_by.value()[].child[])
    if plan.tag == PLAN_PARTITION_TOPN:
        return plan_is_pure(plan._partition_topn.value()[].child[])
    if plan.tag == PLAN_ASOF_JOIN:
        if not plan_is_pure(plan._asof_join.value()[].left[]):
            return False
        return plan_is_pure(plan._asof_join.value()[].right[])
    if plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            if not plan_is_pure(ud.children[i][]):
                return False
        return True
    if plan.tag == PLAN_VIEW_REF or plan.tag == PLAN_CSE_REF:
        return True
    return False


def plan_has_scan(plan: LogicalPlan) -> Bool:
    """True iff `plan` or any descendant is a PLAN_SCAN node. A view or CSE
    reference is a leaf with no scan."""
    if plan.tag == PLAN_SCAN:
        return True
    if plan.tag == PLAN_FILTER:
        return plan_has_scan(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        return plan_has_scan(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        return plan_has_scan(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        if plan_has_scan(plan._join.value()[].left[]):
            return True
        return plan_has_scan(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return plan_has_scan(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return plan_has_scan(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return plan_has_scan(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return plan_has_scan(plan._topn.value()[].child[])
    if plan.tag == PLAN_PARTITION_BY:
        return plan_has_scan(plan._partition_by.value()[].child[])
    if plan.tag == PLAN_PARTITION_TOPN:
        return plan_has_scan(plan._partition_topn.value()[].child[])
    if plan.tag == PLAN_ASOF_JOIN:
        if plan_has_scan(plan._asof_join.value()[].left[]):
            return True
        return plan_has_scan(plan._asof_join.value()[].right[])
    if plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            if plan_has_scan(ud.children[i][]):
                return True
        return False
    return False


def count_scan_subtrees(
    plan: LogicalPlan,
    mut counts: Dict[UInt64, Int],
    pure_only: Bool,
) raises:
    """Add one to `counts[structural_hash(subtree)]` for every subtree of
    `plan` (the root included) that holds a scan.

    With `pure_only`, a subtree that is not pure is skipped together with
    everything below it, so a UDF-bearing node never reaches a count of two
    through its own text. Without it, every scan-bearing subtree is counted.
    Union branches are walked.
    """
    if pure_only and not plan_is_pure(plan):
        return
    if not plan_has_scan(plan):
        return

    var h = plan.structural_hash()
    if h in counts:
        counts[h] = counts[h] + 1
    else:
        counts[h] = 1

    if plan.tag == PLAN_FILTER:
        count_scan_subtrees(plan._filter.value()[].child[], counts, pure_only)
    elif plan.tag == PLAN_PROJECT:
        count_scan_subtrees(plan._project.value()[].child[], counts, pure_only)
    elif plan.tag == PLAN_AGGREGATE:
        count_scan_subtrees(
            plan._aggregate.value()[].child[], counts, pure_only
        )
    elif plan.tag == PLAN_JOIN:
        count_scan_subtrees(plan._join.value()[].left[], counts, pure_only)
        count_scan_subtrees(plan._join.value()[].right[], counts, pure_only)
    elif plan.tag == PLAN_SORT:
        count_scan_subtrees(plan._sort.value()[].child[], counts, pure_only)
    elif plan.tag == PLAN_LIMIT:
        count_scan_subtrees(plan._limit.value()[].child[], counts, pure_only)
    elif plan.tag == PLAN_DISTINCT:
        count_scan_subtrees(
            plan._distinct.value()[].child[], counts, pure_only
        )
    elif plan.tag == PLAN_TOPN:
        count_scan_subtrees(plan._topn.value()[].child[], counts, pure_only)
    elif plan.tag == PLAN_PARTITION_BY:
        count_scan_subtrees(
            plan._partition_by.value()[].child[], counts, pure_only
        )
    elif plan.tag == PLAN_PARTITION_TOPN:
        count_scan_subtrees(
            plan._partition_topn.value()[].child[], counts, pure_only
        )
    elif plan.tag == PLAN_ASOF_JOIN:
        count_scan_subtrees(
            plan._asof_join.value()[].left[], counts, pure_only
        )
        count_scan_subtrees(
            plan._asof_join.value()[].right[], counts, pure_only
        )
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            count_scan_subtrees(ud.children[i][], counts, pure_only)


def count_duplicate_groups(counts: Dict[UInt64, Int]) -> Int:
    """The number of hashes in `counts` seen at least twice."""
    var n = 0
    for kv in counts.items():
        if kv.value > 1:
            n += 1
    return n
