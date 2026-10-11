# =============================================================================
# Optimizer DPccp -- the solver: passes, the cross-product fallback and the
# reconstruction guard
# =============================================================================
#
# Part of the DPccp join enumerator; `optimizer_dpccp` holds the overview and
# re-exports every name defined here. This module seeds the DP table, runs
# the literal-edge pass and, when it finds no plan for the full set, the
# cross-product pass, rebuilds the plan and rejects one whose top join is a
# synthesized cross product.
#
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
)
from .optimizer_reorder import RelationSet, JoinChain
from .optimizer_column_stats_provider import DefaultColumnStatsProvider
from .optimizer_tdom import TdomGraph, build_tdom_graph
from .optimizer_dpccp_cost import (
    DPCCP_MAX_RELATIONS,
    DPCCP_MAX_ITERATIONS,
    DPNode,
    _IterCounter,
)
from .optimizer_dpccp_graph import (
    _build_neighbors,
    _should_trigger_cross_product_augmentation,
    _augment_neighbors_with_cross_products,
)
from .optimizer_dpccp_enum import (
    emit_csg_complements,
    enumerate_csg_rec,
    reconstruct_plan_from_dp,
)
from .optimizer_dpccp_observer import DPccpObserver, NoDPccpObserver


# =============================================================================
# Top-level solver
# =============================================================================

def _empty_cost_override() -> Dict[UInt64, Int]:
    """Production default: no injected costs."""
    return Dict[UInt64, Int]()


def solve_dpccp(
    chain: JoinChain
) raises -> Optional[LogicalPlan]:
    """Entry point without injected costs: `solve_dpccp_with_cost` with
    an empty override.

    Returns None if the chain has < 2 relations, > DPCCP_MAX_RELATIONS
    relations, or an enumeration pass blew past DPCCP_MAX_ITERATIONS.
    None is also returned when no full-set DP entry exists after the
    cross-product pass, and when the reconstructed plan's top join is a
    synthesized cross product (`_plan_top_join_is_synthesized_cross`).
    """
    var empty = _empty_cost_override()
    return solve_dpccp_with_cost(chain, empty)


def _seed_dp_base_relations(
    n: Int,
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
):
    """Seed DP table with each base relation as a singleton entry."""
    for i in range(n):
        var rel_id = chain.relations[i].id
        var set = RelationSet.singleton(rel_id)
        dp[set.bits] = DPNode(
            Float64(0.0),
            chain.relations[i].cardinality,
            RelationSet.empty(),
            RelationSet.empty(),
        )


def _run_dpccp_passes[O: DPccpObserver](
    n: Int,
    imm chain: JoinChain,
    neighbors: List[List[Int]],
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
    allow_cross: Bool,
    mut observer: O,
) -> Bool:
    """Run the three nested DPccp enumerators i from n-1 down to 0.

    Returns False on iteration overflow, True on clean completion. The
    `allow_cross` flag is forwarded to every emit_pair callsite via the
    enumerator stack — when True, cross-product pairs (no real edge
    connecting the two halves) are admitted (costed by `_cost_for_pair`
    when a TDOM graph is set, by the Cartesian product otherwise).

    `observer` is told when the pass begins and when it ends, with the
    counter's value (the `emit_pair` calls this counter has seen) and
    whether the pass completed.
    """
    observer.on_pass_begin(allow_cross)
    var i = n - 1
    while i >= 0:
        var start = RelationSet.singleton(i)
        var exclusion: RelationSet
        if i == 0:
            exclusion = RelationSet.empty()
        else:
            exclusion = RelationSet(
                (UInt64(1) << UInt64(i)) - UInt64(1)
            )

        emit_csg_complements(
            start, exclusion,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            observer.on_pass_end(counter.n, False)
            return False

        enumerate_csg_rec(
            start, exclusion,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            observer.on_pass_end(counter.n, False)
            return False

        i -= 1
    observer.on_pass_end(counter.n, True)
    return True


def _plan_has_synthesized_cross(plan: LogicalPlan) -> Bool:
    """Recursive walk of a reconstructed LogicalPlan; returns True iff
    ANY PLAN_JOIN node has empty key lists on either side.

    Reconstruction diagnostic helper. A JOIN_INNER node with empty
    `left_on`/`right_on` originates from a pseudo cross-product edge
    injected during the augmented pass. The test suite uses this helper
    to assert invariants; the production solver uses the LESS STRICT
    `_plan_top_join_is_synthesized_cross` (top-level only) for its
    fallback decision.
    """
    if plan.tag == PLAN_JOIN and plan._join:
        ref jd = plan._join.value()[]
        if len(jd.left_on) == 0 or len(jd.right_on) == 0:
            return True
        if _plan_has_synthesized_cross(jd.left[]):
            return True
        if _plan_has_synthesized_cross(jd.right[]):
            return True
        return False
    if plan.tag == PLAN_FILTER and plan._filter:
        return _plan_has_synthesized_cross(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT and plan._project:
        return _plan_has_synthesized_cross(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE and plan._aggregate:
        return _plan_has_synthesized_cross(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_SORT and plan._sort:
        return _plan_has_synthesized_cross(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT and plan._limit:
        return _plan_has_synthesized_cross(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT and plan._distinct:
        return _plan_has_synthesized_cross(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN and plan._topn:
        return _plan_has_synthesized_cross(plan._topn.value()[].child[])
    return False


def _plan_top_join_is_synthesized_cross(plan: LogicalPlan) -> Bool:
    """True iff the ROOT join (descending only through pass-through
    wrappers like FILTER/PROJECT/AGGREGATE) is a JOIN_INNER with empty
    keys — the "synthesized CROSS at the top" condition.

    The solver rejects a plan whose TOP-level join is a synthesized
    CROSS, but accepts plans where the synthesized CROSS is deeper
    inside (a sub-tree of the disconnected partition). A CROSS at the
    root feeds every operator above the join with the full cross
    product; a deeper one is confined to a disconnected sub-set.
    """
    if plan.tag == PLAN_JOIN and plan._join:
        ref jd = plan._join.value()[]
        return len(jd.left_on) == 0 or len(jd.right_on) == 0
    if plan.tag == PLAN_FILTER and plan._filter:
        return _plan_top_join_is_synthesized_cross(
            plan._filter.value()[].child[]
        )
    if plan.tag == PLAN_PROJECT and plan._project:
        return _plan_top_join_is_synthesized_cross(
            plan._project.value()[].child[]
        )
    if plan.tag == PLAN_AGGREGATE and plan._aggregate:
        return _plan_top_join_is_synthesized_cross(
            plan._aggregate.value()[].child[]
        )
    if plan.tag == PLAN_SORT and plan._sort:
        return _plan_top_join_is_synthesized_cross(
            plan._sort.value()[].child[]
        )
    if plan.tag == PLAN_LIMIT and plan._limit:
        return _plan_top_join_is_synthesized_cross(
            plan._limit.value()[].child[]
        )
    if plan.tag == PLAN_DISTINCT and plan._distinct:
        return _plan_top_join_is_synthesized_cross(
            plan._distinct.value()[].child[]
        )
    if plan.tag == PLAN_TOPN and plan._topn:
        return _plan_top_join_is_synthesized_cross(
            plan._topn.value()[].child[]
        )
    return False


def solve_dpccp_with_cost(
    chain: JoinChain,
    cost_override: Dict[UInt64, Int],
) raises -> Optional[LogicalPlan]:
    """Core DPccp driver, test-injectable cost variant.

    Literal port of v0.3's `solve_dpccp`. Seeds the DP table with each
    base relation (cost = 0, cardinality = leaf row count), then iterates
    i from n-1 down to 0, running `emit_csg_complements` and
    `enumerate_csg_rec` with start = {i} and exclusion = {0..i-1}. On a
    chain this emits each (csg, cmp) pair once; on dense graphs the
    one-neighbour growth emits pairs repeatedly (K4: 40 emits against the
    canonical 25; komira-ai/komira#1176). The best plan is unchanged.

    Cross-product fallback:
    after the first pass, if it produced no `dp[full_set]` entry (a
    disconnected graph), run a second pass with pseudo cross-
    product edges injected between every pair of relations not already
    adjacent. The first pass's `dp[full_set]` (if any) and
    the augmented pass's are compared; the lower-cost entry wins.
    Pseudo edges live only in the augmented neighbors list — they NEVER
    enter `chain.edges`, so `reconstruct_plan_from_dp` produces empty
    key lists for any partition that depends on a pseudo edge.
    `_plan_top_join_is_synthesized_cross` checks the final plan; if its
    top join is a synthesized cross, this returns None and the caller
    falls back to greedy. A synthesized cross below the root is kept.
    """
    var dp = Dict[UInt64, DPNode]()
    var observer = NoDPccpObserver()
    return solve_dpccp_observed(chain, cost_override, dp, observer)


def solve_dpccp_observed[O: DPccpObserver](
    chain: JoinChain,
    cost_override: Dict[UInt64, Int],
    mut dp: Dict[UInt64, DPNode],
    mut observer: O,
) raises -> Optional[LogicalPlan]:
    """`solve_dpccp_with_cost` with the DP table and the observer supplied
    by the caller (`optimizer_dpccp_diagnostic` passes a recording one).

    `dp` is cleared first. When the chain is enumerated, it holds on return
    the table the solver read: the literal-edge pass's table, or the
    cross-product pass's when that pass supplied the full-set entry. On an
    iteration-cap overflow it holds the partial table of the pass that
    overflowed (the first pass), or the first pass's table (the cross pass).
    The observer sees each pass begin and end and every scored pair
    (`DPccpObserver`). The return value is `solve_dpccp_with_cost`'s.
    """
    dp.clear()
    var n = len(chain.relations)
    if n < 2:
        return None
    if n > DPCCP_MAX_RELATIONS:
        return None

    _seed_dp_base_relations(n, chain, dp)

    var neighbors = _build_neighbors(n, chain.edges)
    var full_set = RelationSet(
        (UInt64(1) << UInt64(n)) - UInt64(1)
        if n < 64 else ~UInt64(0)
    )

    var counter = _IterCounter(UInt64(DPCCP_MAX_ITERATIONS))

    # Construct the TDOM equivalence-
    # set graph ONCE per chain, then thread the `Optional[TdomGraph]` into
    # every `_cost_for_pair` callsite via the three enumerators. This is
    # where the TDOM graph enters DPccp — the
    # `tdom_opt` parameter of `_cost_for_pair` /
    # `emit_pair` / `enumerate_*` carries a real graph here instead of
    # `None`.
    #
    # `reorder_joins_with_dp` calls `solve_dpccp` only for chains that
    # `should_use_dpccp` accepts (>= DPCCP_MIN_RELATIONS (4) leaves);
    # shorter chains go to `greedy_join_order`, whose cost model does not
    # use the TDOM graph.
    #
    # Provider construction is O(1) — `DefaultColumnStatsProvider` holds a
    # `ref [origin]` to the chain's relation slab (no deep copy). The
    # TdomGraph construction is bounded by the chain size
    # (n <= DPCCP_MAX_RELATIONS).
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom_opt: Optional[TdomGraph] = build_tdom_graph(chain, provider)

    # Partition-independent cardinality cache.
    # Mirrors DuckDB `relation_set_2_cardinality` at
    # `cardinality_estimator.cpp:419-430` — same set ALWAYS returns
    # same cardinality, regardless of which (L, R) partition produced
    # the candidate pair. Lifetime is one `solve_dpccp_with_cost`
    # invocation; cleared implicitly by going out of scope.
    var card_cache = Dict[UInt64, Int]()

    # First pass — DPccp over literal edges only (no cross-product
    # augmentation).
    var ok = _run_dpccp_passes(
        n, chain, neighbors, dp, counter, cost_override, tdom_opt,
        card_cache, False, observer,
    )
    if not ok:
        return None

    # Cross-product augmentation
    # trigger, at literal DuckDB parity. Mirrors DuckDB
    # `plan_enumerator.cpp:478-508 SolveJoinOrder` + `:79-96
    # GenerateCrossProducts`: augment iff `dp.find(total_relation) ==
    # dp.end()` after the first pass — the EXACT condition under which
    # DuckDB falls back to cross-product recovery.
    #
    # A connected graph (TPC-H Q9's, for instance): first pass succeeds →
    # trigger False → augmentation does NOT fire → DPccp's plan comes
    # from the CSGs of the original sparse graph only, as in DuckDB.
    #
    # A disconnected graph (the first pass produces no full_set entry):
    # trigger True → augmentation fires → recovery plan emitted (the
    # cross-product clamp still applies in `_cost_for_pair` to keep
    # cardinalities bounded). The reconstruction guard still rejects
    # top-level synthesized CROSS plans.
    if _should_trigger_cross_product_augmentation(dp, full_set.bits):
        var aug_neighbors = _augment_neighbors_with_cross_products(
            n, neighbors,
        )

        # Second pass: build a fresh DP table on the augmented graph.
        # We do NOT replay into `dp` because the augmented graph admits
        # cross-product pairs whose presence would corrupt the literal-
        # edge winners stored from the first pass — DPccp's pair-emit
        # update replaces an entry whenever `pair_cost < existing.cost`,
        # so a cross-product winner could overwrite the first-pass winner
        # of a connected subset.
        var dp_aug = Dict[UInt64, DPNode]()
        _seed_dp_base_relations(n, chain, dp_aug)
        var card_cache_aug = Dict[UInt64, Int]()
        var counter_aug = _IterCounter(UInt64(DPCCP_MAX_ITERATIONS))
        var ok_aug = _run_dpccp_passes(
            n, chain, aug_neighbors, dp_aug, counter_aug, cost_override,
            tdom_opt, card_cache_aug, True, observer,
        )
        if ok_aug:
            var aug_full_hit = dp_aug.get(full_set.bits)
            if aug_full_hit:
                # Compare against the first-pass entry (if any) and pick
                # the lower-cost winner. The trigger fires only when the
                # first pass has no full-set entry, so on this path the
                # augmented winner is the only candidate.
                var first_hit = dp.get(full_set.bits)
                var take_aug = False
                if not first_hit:
                    take_aug = True
                else:
                    var aug_cost = aug_full_hit.value().cost  # cov: unreachable the trigger fires only when the first pass has no full-set entry, so first_hit is empty
                    var first_cost = first_hit.value().cost  # cov: unreachable see the line above
                    if aug_cost < first_cost:  # cov: unreachable see the line above
                        take_aug = True
                if take_aug:
                    # Replay every dp_aug entry into dp. The reconstruction
                    # walk traces (best_left, best_right) pointers through
                    # the table, so we need the full augmented DP state to
                    # produce a coherent plan.
                    dp.clear()
                    for kv in dp_aug.items():
                        dp[kv.key] = kv.value.copy()

    var full_hit = dp.get(full_set.bits)
    if not full_hit:
        return None

    var rebuilt = reconstruct_plan_from_dp(
        dp, full_set, chain.relations, chain.edges
    )

    # Reconstruction guard.
    # Reject only TOP-level synthesized CROSS:
    # if the root join has empty key lists, the augmented pass landed
    # a Cartesian product at the very top of the plan, which would
    # feed every operator above it with the full cross-product.
    # Deeper-level synthesized CROSS is permitted because it is
    # confined to a disconnected sub-set; it is what remains when the
    # derived transitive edges do not connect that sub-set.
    if _plan_top_join_is_synthesized_cross(rebuilt):
        return None

    return Optional[LogicalPlan](rebuilt^)
