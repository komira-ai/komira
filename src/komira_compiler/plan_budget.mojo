# =============================================================================
# plan_budget — per-operator memory budget computation
# =============================================================================
#
# `count_memory_operators` + `per_operator_budget`.
#
# Given a user-supplied total budget (0 = unlimited), computes a per-
# memory-intensive-operator share by dividing evenly across the count of
# Aggregate / Sort / TopN / Join / PartitionBy / PartitionTopN /
# MaterializedCTE nodes in the plan. Streaming operators (Filter,
# Project, Limit, Distinct) consume zero permanent memory and are not
# counted.
#
# =============================================================================

from komira_core.plan.logical_plan import (
    LogicalPlan,
    PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_JOIN,
    PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN, PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN,
)


def count_memory_operators(plan: LogicalPlan) -> Int:
    """Count memory-intensive operators in a LogicalPlan subtree.

    Memory-intensive = holds state proportional to input size during
    execution.

    Counts:
        Aggregate (hash table) — +1 per node.
        Sort — +1 per node.
        TopN — +1 per node (bounded heap, but still counted for parity).
        Join — +1 per node (build-side hash table).
        PartitionBy — +1 (includes internal sort).
        PartitionTopN — +1 (per-partition heaps bounded by P*K).
        ASOF Join — +1 (right-side materialization + walker state).

    Does NOT count:
        Scan, Filter, Project, Limit, Distinct — streaming, zero state.

    Args:
        plan: The plan subtree to walk.

    Returns:
        Count of memory-intensive operators in the subtree.

    Implementation note: LogicalPlan is not ImplicitlyCopyable, so child
    subtrees are accessed through `ref` bindings that borrow through the
    OwnedPointer dereference without triggering a deep copy.
    """
    if plan.tag == PLAN_SCAN:
        return 0

    if plan.tag == PLAN_AGGREGATE:
        ref c = plan._aggregate.value()[].child[]
        return 1 + count_memory_operators(c)

    if plan.tag == PLAN_SORT:
        ref c = plan._sort.value()[].child[]
        return 1 + count_memory_operators(c)

    if plan.tag == PLAN_TOPN:
        ref c = plan._topn.value()[].child[]
        return 1 + count_memory_operators(c)

    if plan.tag == PLAN_JOIN:
        ref l = plan._join.value()[].left[]
        ref r = plan._join.value()[].right[]
        return 1 + count_memory_operators(l) + count_memory_operators(r)

    if plan.tag == PLAN_ASOF_JOIN:
        ref l = plan._asof_join.value()[].left[]
        ref r = plan._asof_join.value()[].right[]
        return 1 + count_memory_operators(l) + count_memory_operators(r)

    if plan.tag == PLAN_PARTITION_BY:
        ref c = plan._partition_by.value()[].child[]
        return 1 + count_memory_operators(c)

    if plan.tag == PLAN_PARTITION_TOPN:
        ref c = plan._partition_topn.value()[].child[]
        return 1 + count_memory_operators(c)

    # Streaming operators: no state, just recurse into child.
    if plan.tag == PLAN_FILTER:
        ref c = plan._filter.value()[].child[]
        return count_memory_operators(c)

    if plan.tag == PLAN_PROJECT:
        ref c = plan._project.value()[].child[]
        return count_memory_operators(c)

    if plan.tag == PLAN_LIMIT:
        ref c = plan._limit.value()[].child[]
        return count_memory_operators(c)

    if plan.tag == PLAN_DISTINCT:
        ref c = plan._distinct.value()[].child[]
        return count_memory_operators(c)

    # Unknown tag — treat as zero-state leaf (Values / CTERef).
    return 0


def per_operator_budget(plan: LogicalPlan, total_budget: Int) -> Int:
    """Divide a total budget evenly across memory-intensive operators.

    Adapted to use an Int sentinel
    (0 = unlimited) instead of `Option<usize>`.

    Args:
        plan: The plan to inspect.
        total_budget: Total bytes across all memory-intensive ops.
            `0` = unlimited (return `0`).

    Returns:
        Per-operator budget in bytes. `0` when total is unlimited OR
        when the plan has no memory-intensive operators (no consumer).
    """
    if total_budget <= 0:
        return 0
    var n = count_memory_operators(plan)
    if n < 1:
        # A `.max(1)` would avoid div-by-zero even when the plan is
        # pure-streaming. We return 0 instead: if there are no memory-
        # intensive operators there is nothing to budget. Matches
        # "no consumer" shape and keeps the API self-consistent (no
        # spurious per-op budgets flowing into paths that ignore them).
        return 0
    return total_budget // n
