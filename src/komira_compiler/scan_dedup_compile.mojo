# =============================================================================
# scan_dedup_compile.mojo
# =============================================================================
#
# Compiler rule `scan_dedup_at_materialize` -- detects identical scan SUBTREES
# within a single LogicalPlan keyed on `LogicalPlan.structural_hash` (FNV-1a of
# the display string). It builds a per-call cache (`Dict[UInt64, Int]`) that
# lives on this function's stack frame and drops at return: a planner-scope
# cache would outlive the plans it describes (a cross-call use-after-free).
#
# Keying on `structural_hash` is strictly stronger than keying on
# `(path, predicate)`: it catches duplicate join subtrees, duplicate
# post-aggregate filters and duplicate post-project scans the scan-level key
# misses. The session-cache pass `optimizer_scan_dedup` (in the optimizer)
# operates on `(source_path, filter_fingerprint)` keys with a session-scope
# cache; this pass is its compile-time complement, operating on STRUCTURAL
# subtree identity with a PER-CALL cache (e.g. project(filter(scan)) twice
# under a join where both copies have already been pushed down identically).
#
# Scope: DETECTION only. The pass does not mutate the plan; an optional trace
# line per call reports the number of duplicate-subtree groups. The rewrite to
# a shared reference lives in `plan_cse` (a `PLAN_CSE_REF` leaf node), so this
# surface stays a stable detection hook.
# =============================================================================

from std.collections import Optional, Dict

from komira_core.plan.logical_plan import (
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
)


# =============================================================================
# Plan subtree walker -- count occurrences of each scan-bearing subtree
# =============================================================================
#
# We hash ONLY subtrees that contain at least one scan. Higher-level subtrees
# (e.g. an entire aggregate over a join over two scans) WILL also be hashed
# and counted -- that is intentional. If two aggregates over the same join
# happen to occur in the same plan (CTE-via-self-join), the rule should
# observe it at the highest level.
#
# `_subtree_has_scan` is a cheap O(n) walk; we use it as a gate so we do not
# hash join nodes whose only children are values nodes (zero scans -- nothing
# to dedup).
#
# `_count_subtrees_by_hash` populates a `Dict[UInt64, Int]` keyed on
# structural_hash. We hash THIS node first, then recurse children so the
# enclosing parent is visible to the outer caller before we walk down.


def _subtree_has_scan(plan: LogicalPlan) -> Bool:
    """True if `plan` or any descendant has a PLAN_SCAN node."""
    if plan.tag == PLAN_SCAN:
        return True
    if plan.tag == PLAN_FILTER:
        return _subtree_has_scan(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        return _subtree_has_scan(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        return _subtree_has_scan(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        if _subtree_has_scan(plan._join.value()[].left[]):
            return True
        return _subtree_has_scan(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return _subtree_has_scan(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return _subtree_has_scan(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _subtree_has_scan(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return _subtree_has_scan(plan._topn.value()[].child[])
    if plan.tag == PLAN_PARTITION_BY:
        return _subtree_has_scan(plan._partition_by.value()[].child[])
    if plan.tag == PLAN_PARTITION_TOPN:
        return _subtree_has_scan(plan._partition_topn.value()[].child[])
    if plan.tag == PLAN_ASOF_JOIN:
        if _subtree_has_scan(plan._asof_join.value()[].left[]):
            return True
        return _subtree_has_scan(plan._asof_join.value()[].right[])
    return False


def _count_subtrees_by_hash(
    plan: LogicalPlan,
    mut counts: Dict[UInt64, Int],
) raises:
    """Populate `counts[structural_hash(subtree)] += 1` for every node that
    contains at least one scan. Recurses into children.
    """
    if not _subtree_has_scan(plan):
        return

    var h = plan.structural_hash()
    if h in counts:
        counts[h] = counts[h] + 1
    else:
        counts[h] = 1

    if plan.tag == PLAN_FILTER:
        _count_subtrees_by_hash(plan._filter.value()[].child[], counts)
    elif plan.tag == PLAN_PROJECT:
        _count_subtrees_by_hash(plan._project.value()[].child[], counts)
    elif plan.tag == PLAN_AGGREGATE:
        _count_subtrees_by_hash(plan._aggregate.value()[].child[], counts)
    elif plan.tag == PLAN_JOIN:
        _count_subtrees_by_hash(plan._join.value()[].left[], counts)
        _count_subtrees_by_hash(plan._join.value()[].right[], counts)
    elif plan.tag == PLAN_SORT:
        _count_subtrees_by_hash(plan._sort.value()[].child[], counts)
    elif plan.tag == PLAN_LIMIT:
        _count_subtrees_by_hash(plan._limit.value()[].child[], counts)
    elif plan.tag == PLAN_DISTINCT:
        _count_subtrees_by_hash(plan._distinct.value()[].child[], counts)
    elif plan.tag == PLAN_TOPN:
        _count_subtrees_by_hash(plan._topn.value()[].child[], counts)
    elif plan.tag == PLAN_PARTITION_BY:
        _count_subtrees_by_hash(plan._partition_by.value()[].child[], counts)
    elif plan.tag == PLAN_PARTITION_TOPN:
        _count_subtrees_by_hash(plan._partition_topn.value()[].child[], counts)
    elif plan.tag == PLAN_ASOF_JOIN:
        _count_subtrees_by_hash(plan._asof_join.value()[].left[], counts)
        _count_subtrees_by_hash(plan._asof_join.value()[].right[], counts)


# =============================================================================
# Public API: scan_dedup_at_materialize
# =============================================================================


def scan_dedup_at_materialize(
    var plan: LogicalPlan, *, trace: Bool = False
) raises -> LogicalPlan:
    """Detect identical scan SUBTREES within `plan` keyed on structural_hash.

    Detection + optional trace only.
    The plan is returned unchanged.

    Per-call cache discipline:
        var counts = Dict[UInt64, Int]
    is a stack-local variable. It drops at function return -- no cross-call
    state leaks.

    The rewrite to a shared reference lives in `plan_cse`. Surfacing
    detection here validates the structural_hash key + the per-call cache
    discipline against real plans (TPC-H Q11 / Q22 / Q17 / Q15).

    Args:
        plan: The plan to inspect (consumed and returned unchanged).
        trace: When `True`, print one line with the number of
            duplicate-subtree groups found (nothing when there are none).
    """
    # Per-call cache.
    # Scope: this function body. Dropped on return; cannot escape.
    var counts = Dict[UInt64, Int]()
    _count_subtrees_by_hash(plan, counts)

    if trace:
        var n_dup_groups = 0
        for kv in counts.items():
            if kv.value > 1:
                n_dup_groups += 1
        if n_dup_groups > 0:
            print(
                "[SCAN_DEDUP_COMPILE] detected ", n_dup_groups,
                " duplicate-subtree group(s) (per-call cache size=",
                len(counts), ")", sep="",
            )

    return plan^


# =============================================================================
# Test-visible helpers
# =============================================================================
#
# Exported for `tests/test_scan_dedup_within_plan.mojo`. Not part of the
# stable public surface.


def detect_duplicate_subtree_groups(plan: LogicalPlan) raises -> Int:
    """Return the number of structural_hash groups with count >= 2.

    Pure helper for tests / observability. Mirrors the body of
    `scan_dedup_at_materialize` but returns the count instead of tracing.
    """
    var counts = Dict[UInt64, Int]()
    _count_subtrees_by_hash(plan, counts)
    var n = 0
    for kv in counts.items():
        if kv.value > 1:
            n += 1
    return n


def count_subtree_occurrences(plan: LogicalPlan, target_hash: UInt64) raises -> Int:
    """Return the count of subtrees with `structural_hash == target_hash`.

    Used by tests to verify the per-call cache observes the expected
    duplicate count for a known subtree shape.
    """
    var counts = Dict[UInt64, Int]()
    _count_subtrees_by_hash(plan, counts)
    if target_hash in counts:
        return counts[target_hash]
    return 0
