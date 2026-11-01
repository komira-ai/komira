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
# 1. ANALYZE. `analyze_subtrees` records, once per plan, which subtrees are
#    pure, which hold a scan, and each one's `structural_hash()`.
# 2. COUNT. `count_scan_subtrees(pure_only=True)` counts, per hash, every pure
#    subtree that holds a scan. A hash counted at least twice is a candidate
#    group. Subtrees without a scan are never candidates (nothing to read
#    twice), and a subtree that is not pure is never a candidate (see PURITY).
# 3. REWRITE. `_cse_rewrite_inplace` walks top-down. The first occurrence of a
#    candidate hash it reaches is the canonical one: it keeps its full subtree
#    and the walk continues inside it (so a duplicate nested in the canonical
#    is shared too). Every later occurrence is replaced by
#    `LogicalPlan.cse_ref(hash, schema)`, a leaf carrying the canonical hash
#    and a copy of the replaced node's output schema, and the walk does not
#    descend into it. The IR stays a tree: a reference is a leaf, not a second
#    parent of the canonical subtree.
#
# IDENTITY. A hash is a summary, and the rendered text it summarises leaves
# out a file scan's output schema, so equal hashes do not prove equal
# subtrees. The rewrite keeps the `subtree_identity` of each canonical
# occurrence (the full render plus every node's output schema) and replaces a
# later occurrence only when its identity is the same. An occurrence whose
# hash matches but whose identity differs is left in place and the walk goes
# on into it.
#
# PURITY (`subtree_hash_walk.plan_is_pure`). A subtree is shared only when no
# node in it carries a typed UDF, holds a registered UDF call in an
# expression, or holds a subquery expression (EXISTS, IN, scalar), and every
# node kind in it is on the allowlist. The subquery rule matters because a
# subquery expression renders only its kind, its outer-reference count and
# the tag of its inner plan: two Filters over the same scan that differ only
# in the inner plan render, and hash, identically, so a text key alone would
# replace the second by a reference to the first. This pass does not depend on
# the subquery lowering having run earlier; a subtree holding one is simply
# never shared.
#
# VISIT ORDER. Children are visited build side first: a Join and an AsofJoin
# visit `right` before `left`, a Union visits its branches left to right, every
# other node visits its one child. The canonical occurrence is therefore the
# one a consumer that finishes a join's build side before its probe side
# reaches first.
#
# SCOPE. A reference only names a hash. Whoever consumes the rewritten plan
# resolves it to the canonical result, and must reach the canonical occurrence
# before any reference to it. NO CONSUMER EXISTS IN THIS TREE YET: nothing
# resolves a `PLAN_CSE_REF`, so a plan this pass has rewritten cannot be
# lowered until one does. This pass is not part of `optimizer_driver`'s fixed
# order, so `optimize` never produces a reference; a caller that can consume
# one calls this pass on the optimized plan.
#
# COST. Analysis is linear in the plan apart from the hashes: each
# scan-bearing node costs one render of its subtree, so a deep chain of
# scan-bearing nodes costs the sum of those renders. Identity text is built
# only for occurrences whose hash is a candidate.
#
# A repeated subtree that holds a UDF is left alone on purpose. The UDF's body
# is opaque and may keep state, and a clone of a plan (`plan.copy()`) carries
# the UDF's call-site salt with it, so equal rendered text does not say that
# one execution may stand in for two.
#
# `plan_cse_eliminate_forest` is the same rewrite over a list of plans that
# are consumed in list order: the canonical occurrence is the first one in the
# first plan that holds the hash, and a later plan's occurrence is a reference.
#
# `detect_cse_candidates` and `count_pure_subtree_occurrences` only report;
# they change no plan.
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
    SubtreeFacts,
    analyze_subtrees,
    count_scan_subtrees,
    count_duplicate_groups,
    subtree_identity,
)


def _cse_rewrite_inplace(
    mut plan: LogicalPlan,
    facts: SubtreeFacts,
    idx: Int,
    candidates: Dict[UInt64, Int],
    mut claimed: Dict[UInt64, String],
) raises:
    """Rewrite `plan` in place: the first occurrence of each candidate hash
    stays, later ones with the same identity become CSE references.

    Args:
        plan: The node to rewrite; its subtree is mutated.
        facts: The analysis of the plan this node belongs to, taken before
            any rewrite; `idx` is this node's pre-order position in it.
        idx: This node's position in `facts`.
        candidates: Hashes of pure scan-bearing subtrees counted at least
            twice.
        claimed: For each hash whose canonical occurrence has been visited,
            that occurrence's `subtree_identity`.
    """
    if facts.pure[idx] and facts.has_scan[idx]:
        var h = facts.hash[idx]
        if h in candidates:
            var ident = subtree_identity(plan, facts, idx)
            if h in claimed:
                if claimed[h] == ident:
                    var schema_snap = plan.output_schema.copy()
                    plan = LogicalPlan.cse_ref(h, schema_snap^)
                    return
            else:
                claimed[h] = ident^

    var first = idx + 1
    if plan.tag == PLAN_FILTER:
        _cse_rewrite_inplace(
            plan._filter.value()[].child[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_PROJECT:
        _cse_rewrite_inplace(
            plan._project.value()[].child[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_AGGREGATE:
        _cse_rewrite_inplace(
            plan._aggregate.value()[].child[],
            facts,
            first,
            candidates,
            claimed,
        )
    elif plan.tag == PLAN_JOIN:
        var right = first + facts.size[first]
        _cse_rewrite_inplace(
            plan._join.value()[].right[], facts, right, candidates, claimed
        )
        _cse_rewrite_inplace(
            plan._join.value()[].left[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_SORT:
        _cse_rewrite_inplace(
            plan._sort.value()[].child[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_LIMIT:
        _cse_rewrite_inplace(
            plan._limit.value()[].child[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_DISTINCT:
        _cse_rewrite_inplace(
            plan._distinct.value()[].child[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_TOPN:
        _cse_rewrite_inplace(
            plan._topn.value()[].child[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_PARTITION_BY:
        _cse_rewrite_inplace(
            plan._partition_by.value()[].child[],
            facts,
            first,
            candidates,
            claimed,
        )
    elif plan.tag == PLAN_PARTITION_TOPN:
        _cse_rewrite_inplace(
            plan._partition_topn.value()[].child[],
            facts,
            first,
            candidates,
            claimed,
        )
    elif plan.tag == PLAN_ASOF_JOIN:
        var right = first + facts.size[first]
        _cse_rewrite_inplace(
            plan._asof_join.value()[].right[], facts, right, candidates, claimed
        )
        _cse_rewrite_inplace(
            plan._asof_join.value()[].left[], facts, first, candidates, claimed
        )
    elif plan.tag == PLAN_UNION:
        var n = len(plan._union.value()[].children)
        var at = first
        for i in range(n):
            _cse_rewrite_inplace(
                plan._union.value()[].children[i][],
                facts,
                at,
                candidates,
                claimed,
            )
            at += facts.size[at]


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
    is two groups, the Filter subtree and the bare scan inside it. Counts
    hashes, so it can exceed what `plan_cse_eliminate` replaces when two
    subtrees share a hash but not an identity."""
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(analyze_subtrees(plan), counts, True)
    return count_duplicate_groups(counts)


def count_pure_subtree_occurrences(
    plan: LogicalPlan, target_hash: UInt64
) raises -> Int:
    """How many pure scan-bearing subtrees of `plan` have `structural_hash()
    == target_hash`; zero when none does. A subtree that is not pure is not
    counted (contrast `scan_dedup_compile.count_all_subtree_occurrences`)."""
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(analyze_subtrees(plan), counts, True)
    if target_hash in counts:
        return counts[target_hash]
    return 0


def plan_cse_eliminate(var plan: LogicalPlan) raises -> LogicalPlan:
    """Replace the second and later occurrence of each duplicated pure
    scan-bearing subtree with a `PLAN_CSE_REF` leaf naming the first.

    A plan with no candidate is returned unchanged. The result holds
    references nothing in this tree resolves (see SCOPE in the file header).

    Args:
        plan: The plan to rewrite. Consumed.

    Returns:
        The rewritten plan.
    """
    var facts = analyze_subtrees(plan)
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(facts, counts, True)
    var candidates = _candidates_of(counts)
    if len(candidates) == 0:
        return plan^

    var claimed = Dict[UInt64, String]()
    _cse_rewrite_inplace(plan, facts, 0, candidates, claimed)
    return plan^


def plan_cse_eliminate_forest(mut plans: List[LogicalPlan]) raises:
    """`plan_cse_eliminate` across a list of plans, in place.

    A pure scan-bearing subtree that occurs at least twice across the whole
    list keeps its first occurrence in list order (first plan first); every
    other occurrence with the same identity, in the same plan or a later one,
    becomes a CSE reference. The list order is the order a consumer must reach
    the plans in.
    """
    var all_facts = List[SubtreeFacts]()
    var counts = Dict[UInt64, Int]()
    for i in range(len(plans)):
        all_facts.append(analyze_subtrees(plans[i]))
        count_scan_subtrees(all_facts[i], counts, True)
    var candidates = _candidates_of(counts)
    if len(candidates) == 0:
        return

    var claimed = Dict[UInt64, String]()
    for i in range(len(plans)):
        _cse_rewrite_inplace(plans[i], all_facts[i], 0, candidates, claimed)
