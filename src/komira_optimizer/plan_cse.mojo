# =============================================================================
# plan_cse.mojo -- plan-level common subexpression elimination: a pure subtree
# that occurs more than once in a plan is kept once and every other occurrence
# becomes a `PLAN_CSE_REF` leaf naming it.
#
# This is wider than expression-level CSE (`optimizer_expr`). If two siblings
# both hold `Scan(t) -> Filter(p) -> Project(c)`, the whole subtree is the
# shared unit, not its expressions.
#
# WHAT IT DOES
# ============
# 1. COUNT. `count_scan_subtrees(pure_only=True)` walks the plan and counts,
#    per `structural_hash()`, every pure subtree that holds a scan. A hash
#    counted at least twice is a candidate group. Subtrees without a scan are
#    never candidates (nothing to read twice), and a subtree that is not pure
#    (a typed UDF anywhere in it, or a node kind off the allowlist in
#    `subtree_hash_walk.plan_is_pure`) is never a candidate.
# 2. REWRITE. `_cse_rewrite_inplace` walks top-down. The first occurrence of a
#    candidate hash it reaches is the canonical one: it keeps its full subtree
#    and the walk continues inside it (so a duplicate nested in the canonical
#    is shared too). Every later occurrence is replaced by
#    `LogicalPlan.cse_ref(hash, schema)`, a leaf carrying the canonical hash
#    and a copy of the replaced node's output schema, and the walk does not
#    descend into it. The IR stays a tree: a reference is a leaf, not a second
#    parent of the canonical subtree.
#
# VISIT ORDER. Children are visited build side first: a Join and an AsofJoin
# visit `right` before `left`, a Union visits its branches left to right, every
# other node visits its one child. The canonical occurrence is therefore the
# one a consumer that finishes a join's build side before its probe side
# reaches first.
#
# SCOPE. A reference only names a hash. Whoever consumes the rewritten plan
# resolves it to the canonical result, and must reach the canonical occurrence
# before any reference to it. This pass is not part of `optimizer_driver`'s
# fixed order, so `optimize` never produces a reference; a caller that can
# consume one calls this pass on the optimized plan.
#
# A repeated subtree that holds a UDF is left alone on purpose. The UDF's body
# is opaque and may keep state, and a clone of a plan (`plan.copy()`) carries
# the UDF's call-site salt with it, so equal rendered text does not say that
# one execution may stand in for two.
#
# `plan_cse_eliminate_forest` is the same rewrite over a list of plans that
# are consumed in list order: the canonical occurrence is the first one in the
# first plan that holds the hash, and a later plan's occurrence is a reference.
# =============================================================================

from std.collections import Dict

from komira_plan_ir.logical_plan import (
    LogicalPlan,
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
)

from komira_optimizer.subtree_hash_walk import (
    plan_is_pure,
    plan_has_scan,
    count_scan_subtrees,
    count_duplicate_groups,
)


def _cse_rewrite_inplace(
    mut plan: LogicalPlan,
    candidates: Dict[UInt64, Int],
    mut claimed: Dict[UInt64, Int],
) raises:
    """Rewrite `plan` in place: the first occurrence of each candidate hash
    stays, later ones become CSE references.

    Args:
        plan: The node to rewrite; its subtree is mutated.
        candidates: Hashes of pure scan-bearing subtrees counted at least
            twice.
        claimed: Hashes whose canonical occurrence has been visited. Only
            membership matters.
    """
    var h = plan.structural_hash()

    if h in candidates and plan_is_pure(plan) and plan_has_scan(plan):
        if h in claimed:
            var schema_snap = plan.output_schema.copy()
            plan = LogicalPlan.cse_ref(h, schema_snap^)
            return
        claimed[h] = 1

    if plan.tag == PLAN_FILTER:
        _cse_rewrite_inplace(
            plan._filter.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_PROJECT:
        _cse_rewrite_inplace(
            plan._project.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_AGGREGATE:
        _cse_rewrite_inplace(
            plan._aggregate.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_JOIN:
        _cse_rewrite_inplace(plan._join.value()[].right[], candidates, claimed)
        _cse_rewrite_inplace(plan._join.value()[].left[], candidates, claimed)
    elif plan.tag == PLAN_SORT:
        _cse_rewrite_inplace(plan._sort.value()[].child[], candidates, claimed)
    elif plan.tag == PLAN_LIMIT:
        _cse_rewrite_inplace(
            plan._limit.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_DISTINCT:
        _cse_rewrite_inplace(
            plan._distinct.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_TOPN:
        _cse_rewrite_inplace(plan._topn.value()[].child[], candidates, claimed)
    elif plan.tag == PLAN_PARTITION_BY:
        _cse_rewrite_inplace(
            plan._partition_by.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_PARTITION_TOPN:
        _cse_rewrite_inplace(
            plan._partition_topn.value()[].child[], candidates, claimed
        )
    elif plan.tag == PLAN_ASOF_JOIN:
        _cse_rewrite_inplace(
            plan._asof_join.value()[].right[], candidates, claimed
        )
        _cse_rewrite_inplace(
            plan._asof_join.value()[].left[], candidates, claimed
        )
    elif plan.tag == PLAN_UNION:
        var n = len(plan._union.value()[].children)
        for i in range(n):
            _cse_rewrite_inplace(
                plan._union.value()[].children[i][], candidates, claimed
            )


def _candidates_of(counts: Dict[UInt64, Int]) -> Dict[UInt64, Int]:
    """The entries of `counts` whose count is at least two."""
    var out = Dict[UInt64, Int]()
    for kv in counts.items():
        if kv.value > 1:
            out[kv.key] = kv.value
    return out^


def detect_cse_candidates(plan: LogicalPlan) raises -> Int:
    """The number of candidate groups in `plan`: distinct pure scan-bearing
    subtrees whose hash occurs at least twice. A repeated Filter over a scan
    is two groups, the Filter subtree and the bare scan inside it."""
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(plan, counts, True)
    return count_duplicate_groups(counts)


def count_subtree_occurrences(
    plan: LogicalPlan, target_hash: UInt64
) raises -> Int:
    """How many pure scan-bearing subtrees of `plan` have `structural_hash()
    == target_hash`; zero when none does."""
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(plan, counts, True)
    if target_hash in counts:
        return counts[target_hash]
    return 0


def plan_cse_eliminate(var plan: LogicalPlan) raises -> LogicalPlan:
    """Replace the second and later occurrence of each duplicated pure
    scan-bearing subtree with a `PLAN_CSE_REF` leaf naming the first.

    A plan with no candidate is returned unchanged.

    Args:
        plan: The plan to rewrite. Consumed.

    Returns:
        The rewritten plan.
    """
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(plan, counts, True)
    var candidates = _candidates_of(counts)
    if len(candidates) == 0:
        return plan^

    var claimed = Dict[UInt64, Int]()
    _cse_rewrite_inplace(plan, candidates, claimed)
    return plan^


def plan_cse_eliminate_forest(mut plans: List[LogicalPlan]) raises:
    """`plan_cse_eliminate` across a list of plans, in place.

    A pure scan-bearing subtree that occurs at least twice across the whole
    list keeps its first occurrence in list order (first plan first); every
    other occurrence, in the same plan or a later one, becomes a CSE
    reference. The list order is the order a consumer must reach the plans in.
    """
    var counts = Dict[UInt64, Int]()
    for i in range(len(plans)):
        count_scan_subtrees(plans[i], counts, True)
    var candidates = _candidates_of(counts)
    if len(candidates) == 0:
        return

    var claimed = Dict[UInt64, Int]()
    for i in range(len(plans)):
        _cse_rewrite_inplace(plans[i], candidates, claimed)
