# =============================================================================
# Optimizer DPccp -- the relation graph: adjacency, connectivity and the
# cross-product augmentation
# =============================================================================
#
# Part of the DPccp join enumerator; `optimizer_dpccp` holds the overview and
# re-exports every name defined here. This module builds the adjacency list
# the enumerators walk, decides when the cross-product pass runs, and builds
# the augmented adjacency that pass walks.
#
# =============================================================================

from std.collections import Dict

from komira_collections.slab import Slab
from .optimizer_reorder import (
    RelationSet,
    JoinEdge,
    find_connecting_edge,
)
from .optimizer_dpccp_cost import DPNode


# =============================================================================
# Neighbor-list construction
# =============================================================================

def _build_neighbors(
    n: Int, edges: Slab[JoinEdge]
) -> List[List[Int]]:
    """Build an adjacency list of size `n` from the chain edges.

    Entry `i` lists each neighbor relation id of `i` once, in the order
    the edges first name it; the lists are not sorted. For every edge the
    body appends each endpoint to the other's list unless a linear scan
    of that list already finds it, so a repeated edge adds nothing and
    the duplicate check runs per edge as the lists are built, not as a
    separate pass.
    """
    var out = List[List[Int]]()
    for _ in range(n):
        out.append(List[Int]())

    for i in range(len(edges)):
        ref e = edges[i]
        var l = e.left_relation
        var r = e.right_relation
        # Dedup: skip if already present.
        var found_r = False
        for k in range(len(out[l])):
            if out[l][k] == r:
                found_r = True
                break
        if not found_r:
            out[l].append(r)

        var found_l = False
        for k in range(len(out[r])):
            if out[r][k] == l:
                found_l = True
                break
        if not found_l:
            out[r].append(l)
    return out^


# =============================================================================
# Cross-product fallback (narrow trigger)
# =============================================================================
#
# After DPccp's first pass, if the DP table holds no plan for the full set
# (`_should_trigger_cross_product_augmentation`), the join graph has at least
# one disconnected component. Inject pseudo cross-product edges between every
# pair of relations not already adjacent and re-run DPccp on the augmented
# graph.
#
# Connectivity: `_relation_graph_is_connected` runs a relation-level BFS
# over the `_build_neighbors` adjacency list rather than reusing
# `optimizer_tdom.build_tdom_graph`, which is a COLUMN-level union-find
# (grouping join-key column bindings into equivalence classes), not a
# RELATION-level connectivity primitive.
#
# Pseudo-edge representation: kept ONLY in the augmented neighbors list, NOT
# in `chain.edges`. The augmented enumerator (`emit_pair(allow_cross=True)`) skips the
# `find_connecting_edge` check so it can grow CSGs across pseudo-edge
# boundaries. A pair with no real edge is costed by `_cost_for_pair`
# (TDOM-clamped) when a TDOM graph is set, and by the Cartesian product
# `join_card = left_card * right_card` otherwise.
#
# Reconstruction guard: `reconstruct_plan_from_dp` walks
# `chain.edges` (real edges only) via `collect_connecting_keys` to extract
# join keys for each DP node. A pseudo-edge-derived partition (no real edge
# between its halves) returns empty key lists. The solver rejects a plan
# whose ROOT join is keyless (`_plan_top_join_is_synthesized_cross`).
# `_plan_has_synthesized_cross` reports a keyless `JOIN_INNER` at any depth;
# only tests call it (`test_optimizer_dpccp_reorder_arms` on hand-built
# keyless joins, `test_optimizer_dpccp_enumeration` on a solved plan).
# =============================================================================


def _compute_relation_components(
    n: Int, neighbors: List[List[Int]]
) -> List[Int]:
    """Return a `parent`-array such that two relations are in the same
    connected component iff their entries are equal.

    Iterative BFS from each unvisited node. O(n + E) time over DPccp's
    n<=12 chains.
    """
    var parent = List[Int]()
    for _ in range(n):
        parent.append(-1)

    var comp_id = 0
    for seed in range(n):
        if parent[seed] != -1:
            continue
        parent[seed] = comp_id

        # Iterative BFS expanding the component.
        var stack = List[Int]()
        stack.append(seed)
        while len(stack) > 0:
            var rel = stack[len(stack) - 1]
            _ = stack.pop()
            ref nbs = neighbors[rel]
            for j in range(len(nbs)):
                var nb = nbs[j]
                if parent[nb] == -1:
                    parent[nb] = comp_id
                    stack.append(nb)
        comp_id += 1

    return parent^


def _relation_graph_is_connected(
    n: Int, neighbors: List[List[Int]]
) -> Bool:
    """True iff every relation belongs to a single transitively-reachable
    component (BFS-reachability from any seed covers all n).

    Only the enumeration tests call it. The cross-product trigger
    (`_should_trigger_cross_product_augmentation` below) does not: it
    checks only whether the first pass produced a `dp[full_set]` plan.
    """
    if n <= 1:
        return True
    var parent = _compute_relation_components(n, neighbors)
    if len(parent) == 0:
        return True  # cov: unreachable _compute_relation_components returns n entries and n > 1 here
    var first = parent[0]
    for i in range(1, len(parent)):
        if parent[i] != first:
            return False
    return True


def _should_trigger_cross_product_augmentation(
    dp: Dict[UInt64, DPNode], full_set_bits: UInt64,
) -> Bool:
    """Trigger: True iff the first-pass DP table did NOT produce a
    plan for the full-set (i.e. `dp[full_set]` is missing).

    Mirrors DuckDB `plan_enumerator.cpp:478-508 SolveJoinOrder`:

        auto final_plan = plans.find(total_relation);
        if (final_plan == plans.end()) {
            // ... force_no_cross_product check ...
            GenerateCrossProducts();
            return SolveJoinOrder();
        }

    Cross-product augmentation is purely a *recovery* mechanism for
    disconnected query graphs that DPccp cannot otherwise solve — it
    is NOT a search-space expansion tool for connected graphs. For a
    connected graph such as TPC-H Q9's (lineitem is the hub), the first
    pass populates `dp[full_set]`, the trigger returns False, and
    augmentation does NOT fire: DPccp enumerates only the CSGs of the
    original sparse graph.

    Caller contract: call this AFTER `_run_dpccp_passes` over the
    literal-edge `neighbors` adjacency. If True → run a second pass
    over `_augment_neighbors_with_cross_products(...)` to recover a
    plan for the disconnected components.
    """
    var full_hit = dp.get(full_set_bits)
    return not full_hit


def _augment_neighbors_with_cross_products(
    n: Int,
    neighbors: List[List[Int]],
) -> List[List[Int]]:
    """Build an augmented adjacency list by injecting pseudo cross-product
    edges between EVERY pair of relations that are not already directly
    connected.

    Mirrors DuckDB `plan_enumerator.cpp:79-96 GenerateCrossProducts`,
    which iterates every (i, j) pair and calls `CreateQueryGraphCrossProduct`
    for non-self pairs. Our version only adds edges between pairs NOT
    already connected (idempotent) — same end-state as DuckDB's "every
    pair adjacent" post-augmentation graph.

    Pseudo edges only live in the returned neighbors list — they NEVER
    enter `chain.edges`. The augmented DPccp pass uses these to expand
    CSGs across non-edge pairs; reconstruction continues to read
    `chain.edges` only, so synthesized cross-products are detectable
    via `_plan_has_synthesized_cross`.

    Cost: O(n^2) for the n<=12 DPccp ceiling.
    """
    var aug = List[List[Int]]()
    for i in range(n):
        var row = List[Int]()
        ref orig = neighbors[i]
        for k in range(len(orig)):
            row.append(orig[k])
        aug.append(row^)

    for i in range(n):
        for j in range(i + 1, n):
            # Skip if already directly adjacent.
            var has_j = False
            for k in range(len(aug[i])):
                if aug[i][k] == j:
                    has_j = True
                    break
            if has_j:
                continue
            aug[i].append(j)
            aug[j].append(i)
    return aug^


@always_inline
def _has_real_connecting_edge(
    left_set: RelationSet,
    right_set: RelationSet,
    edges: Slab[JoinEdge],
) -> Bool:
    """True iff at least one real edge in `chain.edges` connects the two
    sets. Mirrors `find_connecting_edge` shape but returns Bool directly
    to avoid an Int round-trip in the augmented enumerator hot path.
    """
    return find_connecting_edge(left_set, right_set, edges) >= 0
