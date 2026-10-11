# =============================================================================
# Optimizer transitive-edge derivation
# =============================================================================
#
# Ports DuckDB's equivalence-class O(N**2) filter generation
# (`src/optimizer/filter_combiner.cpp:GenerateFilters` lines 113-185) into
# Komira's JoinChain layer. This is the load-bearing mechanism that lets
# DuckDB enumerate Q9's partition A on a sparse query graph: when three or
# more relations share an equi-join column equivalence class (e.g. Q9's
# {l_partkey, p_partkey, ps_partkey}), DuckDB emits the full O(N**2)
# cross-product of pairwise equality comparisons, which the join-order
# optimizer then sees as additional graph edges. The chain extractor
# (`extract_join_chain`) reads edges directly from the LogicalPlan's
# JOIN_INNER `left_on`/`right_on` lists and does not derive the transitive
# pairs, so a DPccp enumerator's neighbor traversal cannot form CSGs like
# Q9's {ps, s, n}, which depends on `partsupp <-> supplier` (derived from the
# suppkey equivalence class {l_suppkey, s_suppkey, ps_suppkey}).
#
# This module ADDS the missing derivation: `derive_transitive_edges` appends
# to a JoinChain's edges in place. It is not a pass of its own:
# `optimizer_dpccp.reorder_joins_with_dp` calls it AFTER
# extraction and BEFORE join enumeration (DPccp).
#
# Algorithm (faithful to DuckDB's mechanism, adapted to Komira's
# JoinChain representation):
#
#   1. Build union-find over `(rel_id, col_name)` pairs. Each pair is a
#      node identified by a string key `"<rel_id>:<col_name>"`. Pairs join
#      the same equivalence class iff some join edge equates them.
#   2. For each edge `(rel_a, rel_b, left_keys, right_keys)`, walk per-
#      column key pairs `(left_keys[i], right_keys[i])` and union the two
#      `(rel_id, col_name)` nodes. After all edges processed, each
#      equivalence class represents one logical join column (e.g. partkey
#      across {lineitem, part, partsupp}).
#   3. For each class of size >= 3 (a class with N <= 2 already has all
#      its pairwise edges in the original chain), enumerate the N(N-1)/2
#      pairs. For each pair `((rel_x, col_x), (rel_y, col_y))` where
#      `rel_x != rel_y`, check if a direct edge between `rel_x` and
#      `rel_y` already exists in the chain that mentions `(col_x, col_y)`
#      or `(col_y, col_x)`. If not, append a synthetic single-key
#      `JoinEdge(rel_x, rel_y, [col_x], [col_y])`.
#
# CORRECTNESS / SOUNDNESS argument:
#
#   (a) Each synthetic edge is logically implied by the chain's existing
#       edges. E.g. if the chain has `l_partkey = p_partkey` AND
#       `l_partkey = ps_partkey`, then `p_partkey = ps_partkey` follows
#       by transitivity. The synthetic edge ADDS no constraint to the
#       join query — it's a redundant condition that execution may
#       enforce or not without changing the answer.
#
#   (b) DPccp (`optimizer_dpccp`) consumes `chain.edges` through
#       `_build_neighbors`, which deduplicates per-pair neighbors.
#       Synthetic edges densify the relation graph for DPccp's CSG
#       traversal without affecting cost estimation: the cost model
#       (`optimizer_tdom_cost.estimate_with_tdom`) keys denominator
#       computation off equivalence classes assembled in `build_tdom_graph`,
#       which use the SAME join-key bindings as our union-find here. The
#       per-bucket TDOM is unchanged.
#
#   (c) Plan reconstruction (`collect_connecting_keys` in optimizer_reorder,
#       which `greedy_join_order` calls) walks `chain.edges` in Slab insertion
#       order. Per the M1 contract in the chain extractor of
#       optimizer_reorder, per-column edges from one composite source must be
#       appended CONTIGUOUSLY in INDEX ORDER. Synthetic edges are
#       appended AFTER all real edges; each synthetic edge has exactly
#       one (col_x, col_y) pair, so M1 holds trivially.
#
#   (d) Synthetic edges contribute a single key per side, so every
#       JOIN_INNER the reconstructed plan builds from them has at least
#       one key on each side: no synthesized cross join.
#
# NOT a transitive-edge inference for general equality combinators (range
# predicates, BETWEEN, etc.). Only handles equi-join edges, which is the
# entire surface DPccp targets.
#
# Cite-anchors:
#   - DuckDB `src/optimizer/filter_combiner.cpp:113-185` (GenerateFilters,
#     O(N**2) equivalence-class derivation).
#   - DuckDB `src/optimizer/filter_combiner.cpp:904-1003`
#     (AddBoundComparisonFilter, equivalence-class union).
# =============================================================================

from std.collections import Dict

from .optimizer_reorder import (
    JoinChain,
    JoinEdge,
)


# =============================================================================
# Union-find primitive (string-keyed)
# =============================================================================


def _uf_key(rel_id: Int, col_name: String) -> String:
    """Build the union-find node key for `(rel_id, col_name)`."""
    return String(rel_id) + ":" + col_name


def _uf_find(mut parent: Dict[String, String], var key: String) -> String:
    """Path-compressing find on the string-keyed union-find."""
    var cur = key^
    while True:
        var p = parent.get(cur)
        if not p:
            # Unknown key; insert as its own root and return.
            parent[cur] = cur
            return cur^
        var p_val = p.value()
        if p_val == cur:
            return cur^
        cur = p_val^



def _uf_union(mut parent: Dict[String, String], var a: String, var b: String):
    """Union the two equivalence classes containing `a` and `b`.

    Idempotent and self-edge-safe (`a == b` is a no-op).
    """
    var ra = _uf_find(parent, a^)
    var rb = _uf_find(parent, b^)
    if ra == rb:
        return
    # Attach rb under ra (no rank/size tracking — one node per (relation,
    # join column) pair, so tree depth is bounded by that small node count).
    parent[rb] = ra^


# =============================================================================
# Edge existence check
# =============================================================================


def _has_real_edge_for_columns(
    imm chain: JoinChain,
    rel_a: Int,
    rel_b: Int,
    col_a: String,
    col_b: String,
) -> Bool:
    """Return True iff the chain already contains an edge between rel_a
    and rel_b (in either direction) whose left_keys/right_keys list
    contains both `col_a` and `col_b` at corresponding indices.

    Used by `derive_transitive_edges` to skip pairs that are already
    represented by a real per-column edge from the original chain. The
    check is intentionally per-column (NOT per-relation-pair) because the
    chain extractor may emit MULTIPLE edges between the same relation
    pair (composite keys split into per-column edges, see optimizer_reorder
    M1 invariant) and a synthetic edge on a DIFFERENT column pair within
    the same equivalence class is still useful (different column =>
    different cost-model contribution; though cost is unchanged today the
    edge densifies the neighbor graph identically).
    """
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        var lr = e.left_relation
        var rr = e.right_relation
        # Forward direction: (rel_a, rel_b) == (lr, rr) with (col_a, col_b)
        # at the same index in (left_keys, right_keys).
        if lr == rel_a and rr == rel_b:
            for j in range(len(e.left_keys)):
                if e.left_keys[j] == col_a and j < len(e.right_keys) \
                        and e.right_keys[j] == col_b:
                    return True
        # Reverse direction.
        if lr == rel_b and rr == rel_a:
            for j in range(len(e.left_keys)):
                if e.left_keys[j] == col_b and j < len(e.right_keys) \
                        and e.right_keys[j] == col_a:
                    return True
    return False


# =============================================================================
# The derivation pass
# =============================================================================


def derive_transitive_edges(mut chain: JoinChain) -> Int:
    """Append synthetic transitive equi-join edges to `chain.edges` by
    enumerating the O(N**2) pairwise closure of each join-key
    equivalence class.

    Returns the count of synthetic edges appended (0 if no class has
    size >= 3). Idempotent: calling twice on the same chain is a no-op
    on the second call because every pair already has either a real or a
    synthetic edge after the first call.

    Implementation notes:
      - The union-find is built from `chain.edges` ONLY (no cross-
        reference into LogicalPlan / Schema). This keeps the pass
        decoupled from upstream chain-construction details.
      - Synthetic edges are SINGLE-KEY by construction (one column on
        each side). They append AFTER all real edges; the M1/M2
        invariants of `collect_connecting_keys` hold trivially (single-
        key edges are by definition "contiguous in index order").
      - For each equivalence class C with members
        `[(rel_0, col_0), (rel_1, col_1), ..., (rel_{|C|-1}, col_{|C|-1})]`,
        the inner loop enumerates pairs (i, j) with i < j. We skip
        `rel_i == rel_j` (self-pair on same relation) and skip pairs
        whose direct edge already exists (forward OR reverse).
      - The class enumeration order is determined by Dict iteration over
        the underlying nodes plus a per-class member-list construction.
        Mojo 0.26 Dict iteration is insertion-ordered, so the synthetic
        edges land deterministically.
    """
    # Phase 1: build the union-find. For each real edge, union each
    # per-column key pair.
    var parent = Dict[String, String]()
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        var k = len(e.left_keys)
        if k > len(e.right_keys):
            k = len(e.right_keys)
        for j in range(k):
            var ka = _uf_key(e.left_relation, e.left_keys[j])
            var kb = _uf_key(e.right_relation, e.right_keys[j])
            # Ensure both keys exist as roots before union.
            _ = _uf_find(parent, ka)
            _ = _uf_find(parent, kb)
            var ka2 = _uf_key(e.left_relation, e.left_keys[j])
            var kb2 = _uf_key(e.right_relation, e.right_keys[j])
            _uf_union(parent, ka2^, kb2^)

    # Phase 2: group nodes by root. members[root] = List of (rel_id, col).
    # We carry rel_id and col separately so we can reconstruct synthetic
    # JoinEdges without re-parsing the string key.
    var class_rels = Dict[String, List[Int]]()
    var class_cols = Dict[String, List[String]]()

    # Re-scan edges to collect all `(rel_id, col_name)` nodes that
    # appeared in the chain. Skipping nodes that are NOT in any edge is
    # correct: a relation column that never participates in a join key
    # cannot contribute a transitive edge.
    var seen_nodes = Dict[String, Bool]()
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        var k = len(e.left_keys)
        if k > len(e.right_keys):
            k = len(e.right_keys)
        for j in range(k):
            var ka = _uf_key(e.left_relation, e.left_keys[j])
            var kb = _uf_key(e.right_relation, e.right_keys[j])
            if not seen_nodes.get(ka):
                seen_nodes[ka] = True
                var root_a = _uf_find(parent, ka)
                var existing = class_rels.get(root_a)
                if not existing:
                    var rl = List[Int]()
                    rl.append(e.left_relation)
                    class_rels[root_a] = rl^
                    var cl = List[String]()
                    cl.append(e.left_keys[j])
                    class_cols[root_a] = cl^
                else:
                    # Mojo 0.26 Dict has no entry/mutate API; re-fetch as
                    # owning copy, modify, and re-insert.
                    var cur_rels = existing.value().copy()
                    var cur_cols_opt = class_cols.get(root_a)
                    var cur_cols = cur_cols_opt.value().copy()
                    cur_rels.append(e.left_relation)
                    cur_cols.append(e.left_keys[j])
                    var root_a_copy = root_a
                    class_rels[root_a_copy] = cur_rels^
                    var root_a_copy2 = root_a
                    class_cols[root_a_copy2] = cur_cols^
            if not seen_nodes.get(kb):
                seen_nodes[kb] = True
                var root_b = _uf_find(parent, kb)
                var existing = class_rels.get(root_b)
                if not existing:
                    var rl = List[Int]()  # cov: unreachable ka shares the root of kb and was recorded on this edge or an earlier one, so the class exists
                    rl.append(e.right_relation)  # cov: unreachable see the line above
                    class_rels[root_b] = rl^  # cov: unreachable see the line above
                    var cl = List[String]()  # cov: unreachable see the line above
                    cl.append(e.right_keys[j])  # cov: unreachable see the line above
                    class_cols[root_b] = cl^  # cov: unreachable see the line above
                else:
                    var cur_rels = existing.value().copy()
                    var cur_cols_opt = class_cols.get(root_b)
                    var cur_cols = cur_cols_opt.value().copy()
                    cur_rels.append(e.right_relation)
                    cur_cols.append(e.right_keys[j])
                    var root_b_copy = root_b
                    class_rels[root_b_copy] = cur_rels^
                    var root_b_copy2 = root_b
                    class_cols[root_b_copy2] = cur_cols^

    # Phase 3: enumerate pairs within each class of size >= 3, append
    # synthetic JoinEdges for pairs that do not already have a real edge.
    var added = 0
    for root in class_rels.keys():
        var rels_opt = class_rels.get(root)
        if not rels_opt:
            continue  # cov: unreachable root comes from class_rels.keys()
        var rels = rels_opt.value().copy()
        var cols_opt = class_cols.get(root)
        if not cols_opt:
            continue  # cov: unreachable class_cols gets a key whenever class_rels does
        var cols = cols_opt.value().copy()
        var sz = len(rels)
        if sz < 3:
            # A class of size <= 2 has at most one pair, which (if it
            # exists) is the original edge that generated the class. No
            # synthetic edges to derive.
            continue

        for i in range(sz):
            for j in range(i + 1, sz):
                var ri = rels[i]
                var rj = rels[j]
                if ri == rj:
                    # Same relation — column self-reference within one
                    # relation cannot contribute a join edge.
                    continue
                var ci = cols[i]
                var cj = cols[j]
                if _has_real_edge_for_columns(chain, ri, rj, ci, cj):
                    continue
                # Append the synthetic edge. M1 invariant trivially holds
                # (single-key, contiguous append).
                var lk = List[String]()
                lk.append(ci)
                var rk = List[String]()
                rk.append(cj)
                chain.edges.append(JoinEdge(ri, rj, lk^, rk^))
                added += 1

    return added
