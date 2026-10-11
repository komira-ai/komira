# =============================================================================
# Optimizer DPccp -- the enumerators and DP-table reconstruction
# =============================================================================
#
# Part of the DPccp join enumerator; `optimizer_dpccp` holds the overview
# (including the v0.3 divergences these functions follow) and re-exports every
# name defined here. This module holds `emit_pair` (score one candidate and
# update the DP table), the three mutually recursive enumerators, and the walk
# that rebuilds a plan from the DP table.
#
# =============================================================================

from std.collections import Dict

from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import LogicalPlan, JOIN_INNER
from .optimizer_reorder import (
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
    collect_connecting_keys,
)
from komira_plan_ir.plan_helpers import _copy_plan
from .optimizer_tdom import TdomGraph
from .optimizer_dpccp_cost import DPNode, _IterCounter, _cost_for_pair
from .optimizer_dpccp_graph import _has_real_connecting_edge
from .optimizer_dpccp_observer import DPCandidate, DPccpObserver
from .optimizer_cost_order import dp_pair_beats


# =============================================================================
# emit_pair -- score one (left_set, right_set) candidate and update DP
# =============================================================================

def emit_pair[O: DPccpObserver](
    left_set: RelationSet,
    right_set: RelationSet,
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
    mut observer: O,
    allow_cross: Bool = False,
):
    """Score the candidate join (left_set, right_set) and update DP table.

    Literal port of v0.3's `emit_pair`. Both sets must already have DP
    entries (otherwise the subtree has not been reached through a valid
    connected-subgraph enumeration, and emitting a pair for it would
    double-count). Unless `allow_cross` is set, also requires that at
    least one edge connect the two sets -- otherwise the pair would
    synthesize a CROSS join, which the first DPccp pass does not consider.

    `tdom_opt` is the TDOM equivalence-set graph for the chain.
    When set, `_cost_for_pair` uses the TDOM-aware denominator; when
    None (`solve_dpccp_with_cost` always sets it), the
    legacy `estimate_join_cardinality_with_ndv` is used.

    `card_cache` is the partition-independent cardinality
    cache keyed by `combined.bits`. Threaded through every enumerator
    so the same combined set is computed once and reused across all
    partitions that DP enumeration emits for it.

    `allow_cross` (default False) gates the
    real-edge connectivity check. The augmented DPccp pass (post-pseudo-
    edge injection) passes `True` so cross-product pairs can be emitted
    (TDOM-clamped cost when a graph is set, else the Cartesian product
    `join_card = left_card * right_card`). Each pass gets its own
    card_cache.

    `observer` receives every pair that passes the entry and edge guards
    (`DPccpObserver.on_pair_scored`), after it is costed and before the
    table update, repeats of the same pair included.
    """
    var left_entry = dp.get(left_set.bits)
    if not left_entry:
        return
    var right_entry = dp.get(right_set.bits)
    if not right_entry:
        return
    var left_cost = left_entry.value().cost
    var left_card = left_entry.value().cardinality
    var right_cost = right_entry.value().cost
    var right_card = right_entry.value().cardinality

    var has_real = _has_real_connecting_edge(
        left_set, right_set, chain.edges
    )
    if not has_real and not allow_cross:
        return

    var join_card: Int
    if not has_real:
        # When a TDOM graph is
        # available, even pseudo-edge cross-product pairs flow through
        # `estimate_cardinality_with_set` so the cross-product clamp at
        # `optimizer_tdom_card._is_cross_product_shaped_subset` can cap
        # the combined cardinality at `max_base_card_in_set`. Without
        # it, the Cartesian join_card (left_card * right_card; 800K * 10K
        # = 8B for TPC-H SF1 partsupp x supplier) would enter the DP
        # entry's cost and outweigh partitions that join on real edges.
        #
        # Falls through to the literal Cartesian product when no TDOM
        # is present (callers of the enumerators that pass no graph;
        # `solve_dpccp_with_cost` always builds one).
        if tdom_opt:
            join_card = _cost_for_pair(
                left_set, right_set, left_card, right_card,
                chain, cost_override, tdom_opt, card_cache,
            )
        else:
            # Pseudo-edge cross product: Cartesian product cardinality.
            # Mirrors DuckDB's no-filter null-FilterInfo cost path. A
            # product of large cardinalities can overflow Int64; we clamp
            # at ~Int64.MAX/2 to keep downstream arithmetic safe. The
            # clamp is fine for comparison semantics because anything
            # that reaches it is already astronomically worse than the
            # alternatives.
            var SAT_CAP: Int = 4_611_686_018_427_387_903  # ~Int.MAX / 2
            if left_card <= 0 or right_card <= 0:
                if left_card > right_card:
                    join_card = left_card
                else:
                    join_card = right_card
            elif left_card > SAT_CAP // right_card:
                join_card = SAT_CAP
            else:
                join_card = left_card * right_card
    else:
        join_card = _cost_for_pair(
            left_set, right_set, left_card, right_card,
            chain, cost_override, tdom_opt, card_cache,
        )
    var pair_cost = Float64(join_card) + left_cost + right_cost
    var combined = left_set.union(right_set)
    observer.on_pair_scored(DPCandidate(
        left_set.bits, right_set.bits, pair_cost, join_card,
        left_cost, right_cost, left_card, right_card, allow_cross,
    ))

    # Manual "entry or insert" (divergence #5).
    var existing = dp.get(combined.bits)
    if existing:
        var e = existing.value().copy()
        if dp_pair_beats(
            pair_cost, left_set.bits, right_set.bits,
            e.cost, e.best_left.bits, e.best_right.bits,
        ):
            dp[combined.bits] = DPNode(
                pair_cost, join_card, left_set, right_set
            )
    else:
        dp[combined.bits] = DPNode(
            pair_cost, join_card, left_set, right_set
        )


# =============================================================================
# The three mutually recursive enumerators
# =============================================================================

def emit_csg_complements[O: DPccpObserver](
    csg: RelationSet,
    exclusion: RelationSet,
    neighbors: List[List[Int]],
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
    mut observer: O,
    allow_cross: Bool = False,
):
    """For a connected subgraph `csg`, enumerate its connected complements.

    Literal port of v0.3's `emit_csg_complements`. Seeds are the neighbor relations
    of `csg` that are not already in `csg` and not in `exclusion`. For
    each seed:
        1. emit_pair(csg, seed-as-singleton)
        2. Recurse into `enumerate_complement_rec` to grow the complement.
    Sorted seed iteration keeps the emit order deterministic so the DP
    table is independent of Dict/HashMap iteration order.
    """
    if counter.is_over():
        return

    var seeds = List[Int]()
    var csg_ids = csg.iter()
    for i in range(len(csg_ids)):
        var rel_id = csg_ids[i]
        ref nb_list = neighbors[rel_id]
        for j in range(len(nb_list)):
            var nb = nb_list[j]
            if csg.contains(nb):
                continue
            if exclusion.contains(nb):
                continue
            # Dedup against already-collected seeds.
            var already = False
            for k in range(len(seeds)):
                if seeds[k] == nb:
                    already = True
                    break
            if not already:
                seeds.append(nb)
    # Stable sort (insertion sort over small lists).
    for i in range(1, len(seeds)):
        var v = seeds[i]
        var j = i
        while j > 0 and seeds[j - 1] > v:
            seeds[j] = seeds[j - 1]
            j -= 1
        seeds[j] = v

    for i in range(len(seeds)):
        var seed = seeds[i]
        var complement = RelationSet.singleton(seed)
        counter.bump()
        emit_pair(
            csg, complement, chain, dp, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            return
        var compl_excl = exclusion.union(csg)
        enumerate_complement_rec(
            complement, csg, compl_excl,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            return


def enumerate_csg_rec[O: DPccpObserver](
    csg: RelationSet,
    exclusion: RelationSet,
    neighbors: List[List[Int]],
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
    mut observer: O,
    allow_cross: Bool = False,
):
    """Grow a connected subgraph by one neighbor, recursively.

    Literal port of v0.3's `enumerate_csg_rec`. For each non-excluded neighbor
    of `csg`, form a new larger csg, recurse to enumerate complements of
    the new csg, and recurse to grow it further. Exclusion is widened
    only by the neighbour just added, so a csg can be reached through
    several orders of adding its members: on dense graphs the same csg
    (and its pairs) is emitted many times. Canonical DPccp grows by every
    subset of the neighbourhood and excludes the whole neighbourhood
    (komira-ai/komira#1176).
    """
    if counter.is_over():
        return

    var nbs = List[Int]()
    var csg_ids = csg.iter()
    for i in range(len(csg_ids)):
        var rel_id = csg_ids[i]
        ref nb_list = neighbors[rel_id]
        for j in range(len(nb_list)):
            var nb = nb_list[j]
            if csg.contains(nb):
                continue
            if exclusion.contains(nb):
                continue
            var already = False
            for k in range(len(nbs)):
                if nbs[k] == nb:
                    already = True
                    break
            if not already:
                nbs.append(nb)
    for i in range(1, len(nbs)):
        var v = nbs[i]
        var j = i
        while j > 0 and nbs[j - 1] > v:
            nbs[j] = nbs[j - 1]
            j -= 1
        nbs[j] = v

    for i in range(len(nbs)):
        var nb = nbs[i]
        var new_csg = csg.union(RelationSet.singleton(nb))
        emit_csg_complements(
            new_csg, exclusion,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            return
        var further_excl = exclusion.union(RelationSet.singleton(nb))
        enumerate_csg_rec(
            new_csg, further_excl,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            return


def enumerate_complement_rec[O: DPccpObserver](
    complement: RelationSet,
    csg: RelationSet,
    exclusion: RelationSet,
    neighbors: List[List[Int]],
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
    mut observer: O,
    allow_cross: Bool = False,
):
    """Grow a connected complement by one neighbor, recursively.

    Literal port of v0.3's `enumerate_complement_rec`. Symmetric to
    `enumerate_csg_rec` but grows the complement rather than the csg,
    and emits a pair with the fixed `csg` at every step. Neighbors come
    from the complement's frontier (not the csg's).
    """
    if counter.is_over():
        return

    var nbs = List[Int]()
    var cmp_ids = complement.iter()
    for i in range(len(cmp_ids)):
        var rel_id = cmp_ids[i]
        ref nb_list = neighbors[rel_id]
        for j in range(len(nb_list)):
            var nb = nb_list[j]
            if complement.contains(nb):
                continue
            if csg.contains(nb):
                continue
            if exclusion.contains(nb):
                continue
            var already = False
            for k in range(len(nbs)):
                if nbs[k] == nb:
                    already = True
                    break
            if not already:
                nbs.append(nb)
    for i in range(1, len(nbs)):
        var v = nbs[i]
        var j = i
        while j > 0 and nbs[j - 1] > v:
            nbs[j] = nbs[j - 1]
            j -= 1
        nbs[j] = v

    for i in range(len(nbs)):
        var nb = nbs[i]
        var new_compl = complement.union(RelationSet.singleton(nb))
        counter.bump()
        emit_pair(
            csg, new_compl, chain, dp, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            return
        var new_excl = exclusion.union(RelationSet.singleton(nb))
        enumerate_complement_rec(
            new_compl, csg, new_excl,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, observer, allow_cross,
        )
        if counter.is_over():
            return


# =============================================================================
# find_representative_plan -- DP reconstruction helper
# =============================================================================

def find_representative_plan(
    set: RelationSet, relations: Slab[JoinRelation]
) -> Int:
    """Return the index (into `relations`) of the first bit of `set`.

    Mirrors v0.3 `find_representative_plan`, which
    returns a `&LogicalPlan`. In v0.4 the DP reconstruction needs the
    leaf plan to clone, and the only clean way to expose a reference
    through a helper that may call into `_copy_plan` is to return the
    index and let the caller index `relations` directly. Semantically
    identical: the "first bit" is the leaf whose dense id equals the
    lowest set bit index.
    """
    var ids = set.iter()
    # Caller guarantees non-empty.
    debug_assert(len(ids) > 0, "find_representative_plan on empty set")
    return ids[0]


# =============================================================================
# reconstruct_plan_from_dp -- walk the DP table to build the final plan
# =============================================================================

def reconstruct_plan_from_dp(
    dp: Dict[UInt64, DPNode],
    set: RelationSet,
    relations: Slab[JoinRelation],
    edges: Slab[JoinEdge],
) raises -> LogicalPlan:
    """Rebuild a LogicalPlan from the DP table rooted at `set`.

    Literal port of v0.3's `reconstruct_plan_from_dp`. For a base relation (empty
    best_left and best_right), clones the leaf plan. Otherwise
    recursively rebuilds both children and joins them with the keys
    extracted from the edges connecting the two halves.

    Pre: `set` is a key present in `dp`.
    """
    var entry = dp.get(set.bits)
    debug_assert(Bool(entry), "reconstruct_plan_from_dp: set missing from DP")
    var node = entry.value().copy()

    if node.best_left.is_empty() and node.best_right.is_empty():
        # Base relation: clone the leaf plan.
        var idx = find_representative_plan(set, relations)
        return _copy_plan(relations[idx].plan[])

    var left_plan = reconstruct_plan_from_dp(
        dp, node.best_left, relations, edges
    )
    var right_plan = reconstruct_plan_from_dp(
        dp, node.best_right, relations, edges
    )
    var keys = collect_connecting_keys(
        node.best_left, node.best_right, edges
    )
    var lk = keys.left.copy()
    var rk = keys.right.copy()
    return LogicalPlan.join(
        left_plan^, right_plan^, lk^, rk^, JOIN_INNER
    )
