# =============================================================================
# Order-independent cardinality — estimate_cardinality_with_set
# =============================================================================
#
# The structural fix for the partition-dependent
# cardinality bug that the TPC-H Q9 join-order cost surfaced.
#
# Mirrors DuckDB's `EstimateCardinalityWithSet<double>` at
# `src/optimizer/join_order/cardinality_estimator.cpp:417-432` + supporting
# subgraph-merge walk at `:286-402` + `GetNumerator` at `:138-146`.
#
# Contract delta vs the legacy `estimate_with_tdom` (sibling
# `optimizer_tdom_cost.mojo`):
#
#   estimate_with_tdom(tdom, chain, left_set, right_set, left_card,
#                     right_card, provider) -> Int
#       Partition-DEPENDENT. Numerator = left_card * right_card (DP-
#       resolved intermediates). Denominator = bucket walk over BRIDGING
#       edges only. For the same combined set, two different (L, R)
#       partitions return DIFFERENT cardinalities.
#
#   estimate_cardinality_with_set(tdom, chain, combined_set, provider,
#                                  mut cache) -> Int
#       Partition-INDEPENDENT. Numerator = product of BASE relation
#       cardinalities for relations in combined_set (DuckDB
#       `GetNumerator`). Denominator = subgraph-merge walk over edges
#       with BOTH endpoints in combined_set, plus an unused-edge log
#       penalty (DuckDB `GetDenominator`). Result is CACHED by
#       `combined_set.bits` (DuckDB `relation_set_2_cardinality`).
#
# Why this is the structural fix for Q9 (and a class of partition-shape
# bugs):
#
#   * Under the partition-dependent contract, for the same combined_set
#     the cost-of-pair lookup returns different cardinalities depending
#     on the (L, R) partition that produced it. DP enumeration's strict-
#     `<` tie-break then picks the partition whose cardinality estimate
#     happens to be lowest — which under the buggy contract is NOT the
#     partition whose subtrees genuinely cost the least.
#   * Under the partition-INDEPENDENT contract, the join_card term in
#     `pair_cost = join_card + left_cost + right_cost` is CONSTANT per
#     combined_set. DP then picks the partition with the smallest
#     `left_cost + right_cost` — i.e. the partition that builds the
#     cheapest sub-plans (the DuckDB-canonical behavior).
#
# The FK-PK clamp from `optimizer_tdom_cost.mojo` is generalized
# here to multi-relation form: when any bridging bucket inside
# combined_set has a Tier-1-backed composite-NDV PK signal, clamp est
# to `max(base_card_for_rel)` across all relations in combined_set.
# Mirrors DuckDB's `EstimateFilteredCardinality` FK-PK ceiling on the
# joint set.
#
# Cache lifetime: the cache is per-`reorder_joins_with_dp` invocation.
# Caller owns the Dict[UInt64, Int] and clears it between invocations.
# DuckDB's `relation_set_2_cardinality` lives on the
# `CardinalityEstimator` and is rebuilt per join-order optimization
# pass; our cache is the moral equivalent threaded through DPccp as a
# mut ref.
#
# Encapsulation: SDK-internal module; no UnsafePointer crosses any
# boundary. Trait-bound `P: ColumnStatsProvider` matches the rest of
# the cost module so test SyntheticColumnStatsProvider feeds through
# one surface.
# =============================================================================

from std.collections import Dict

from komira_collections.slab import Slab
from .optimizer_column_stats_provider import (
    ColumnStatsProvider,
    ColumnStatsValue,
)
from .optimizer_reorder import (
    JoinChain,
    JoinEdge,
    RelationSet,
)
from .optimizer_tdom import (
    TdomGraph,
    PairBucket,
    build_pair_buckets,
    composite_ndv_for_relation,
    composite_ndv_pk_side,
)


# =============================================================================
# _Subgraph — one connected component in the in-progress subgraph-merge
# =============================================================================


struct _Subgraph(Movable, Copyable):
    """One in-progress connected component during the denominator walk.

    Mirrors DuckDB's `Subgraph2Denominator`
    (`cardinality_estimator.hpp:60-70`):
      * `relations` — bitmask of relations already absorbed into this
        component.
      * `denom` — accumulated product of (left.denom * right.denom *
        edge_TDOM) per `CalculateUpdatedDenom` at
        `cardinality_estimator.cpp:225-269`. Starts at 1.0.

    POD-shaped — `UInt64` + `Float64`. ImplicitlyCopyable would be sound
    too but we hold `Copyable` for the List-storage requirement that
    matches the PairBucket convention.
    """

    var relations: UInt64
    var denom: Float64

    @always_inline
    def __init__(out self, relations: UInt64, denom: Float64):
        self.relations = relations
        self.denom = denom

    @always_inline
    def copy(self) -> Self:
        return Self(self.relations, self.denom)


# =============================================================================
# _edge_in_set — both-endpoints-in-combined predicate
# =============================================================================


@always_inline
def _edge_in_set(
    imm edge: JoinEdge,
    combined: UInt64,
) -> Bool:
    """Return True iff both endpoints of `edge` are in `combined`.

    Mirrors DuckDB's `GetEdges` filter at
    `cardinality_estimator.cpp:163-174` (`JoinRelationSet::IsSubset(
    requested_set, filter->set)`).

    `@always_inline` because the denominator walk calls this per edge.
    """
    var l_bit = UInt64(1) << UInt64(edge.left_relation)
    var r_bit = UInt64(1) << UInt64(edge.right_relation)
    return (combined & l_bit) != UInt64(0) and (combined & r_bit) != UInt64(0)


# =============================================================================
# _collect_internal_edges_sorted — TDOM-DESC sorted internal-edge indices
# =============================================================================


def _collect_internal_edges_sorted(
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    combined: UInt64,
) -> List[Int]:
    """Return indices into `chain.edges` of edges whose BOTH endpoints
    are in `combined`, sorted by class-TDOM DESCENDING with deterministic
    tie-break.

    Tie-break key (mirrors `_collect_and_sort_bridging` from the legacy
    cost module): primary class-TDOM DESC, then
    (left_relation, right_relation, edge_index) ASC. Leftover composite
    edges (class -1) carry sort key -1 and sort AFTER all class-bearing
    edges.

    DuckDB's `relations_to_tdoms` is pre-sorted globally; for our
    per-call scope an O(n_edges^2) insertion sort is fine (n_edges
    bounded by chain size, typically <=12 for DPccp).
    """
    var edges_in = List[Int]()
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        if _edge_in_set(e, combined):
            edges_in.append(i)

    # Insertion sort with the 4-key tuple.
    for i in range(1, len(edges_in)):
        var key_idx = edges_in[i]
        var key_tdom = _class_tdom_for_edge(tdom, key_idx)
        ref key_e_pin = chain.edges[key_idx]
        var key_lr = key_e_pin.left_relation
        var key_rr = key_e_pin.right_relation

        var j = i - 1
        while j >= 0:
            var cmp_idx = edges_in[j]
            var cmp_tdom = _class_tdom_for_edge(tdom, cmp_idx)
            ref cmp_e_pin = chain.edges[cmp_idx]
            var cmp_lr = cmp_e_pin.left_relation
            var cmp_rr = cmp_e_pin.right_relation

            var should_shift = False
            if cmp_tdom < key_tdom:
                should_shift = True
            elif cmp_tdom == key_tdom:
                if cmp_lr > key_lr:
                    should_shift = True
                elif cmp_lr == key_lr:
                    if cmp_rr > key_rr:
                        should_shift = True
                    elif cmp_rr == key_rr:
                        if cmp_idx > key_idx:
                            should_shift = True

            if should_shift:
                edges_in[j + 1] = edges_in[j]
                j -= 1
            else:
                break
        edges_in[j + 1] = key_idx
    return edges_in^


@always_inline
def _class_tdom_for_edge(imm tdom: TdomGraph, edge_idx: Int) -> Int:
    """Return the class TDOM for an edge, or -1 if the edge is a
    leftover composite (no class). -1 sorts to the END (lowest priority).
    """
    var c_idx = tdom.class_for_edge(edge_idx)
    if c_idx < 0:
        return -1
    return tdom.classes[c_idx].tdom()


# =============================================================================
# _edge_tdom_for_denom — the multiplier used when an edge contributes to denom
# =============================================================================


def _edge_tdom_for_denom[
    P: ColumnStatsProvider, //
](
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    edge_idx: Int,
    imm provider: P,
) -> Float64:
    """Return the TDOM multiplier for an edge contributing to the denom.

    Mirrors DuckDB `CalculateUpdatedDenom` INNER-equality branch
    (`cardinality_estimator.cpp:229-252`): the edge's class TDOM (HLL
    or no-HLL). For leftover composite edges (`edge_to_class[i] == -1`)
    we use `_max_ndv_across_keys_for_edge` semantics — MAX-NDV across
    the multi-key columns — as the conservative single-multiplier
    contribution. This is the same fall-through the legacy
    `optimizer_tdom_cost` uses for composite edges; we lift it here
    so the one-set walk doesn't need a separate dispatch path.

    Floor at 1.0: edges with degenerate stats (TDOM 0) would zero out
    the denominator; clamp to 1.0 so the divide produces a finite
    upper bound on cardinality (DuckDB does similar clamps in
    `GetDenominator`'s `denom == 0` final check at line 397).
    """
    var c_idx = tdom.class_for_edge(edge_idx)
    if c_idx >= 0:
        var t = tdom.classes[c_idx].tdom()
        if t < 1:
            return 1.0
        return Float64(t)
    # Leftover composite: MAX-NDV across the multi-key columns.
    ref edge = chain.edges[edge_idx]
    var best: Int = 1
    for i in range(len(edge.left_keys)):
        var v = provider.distinct_count_for(
            edge.left_relation, edge.left_keys[i]
        )
        if v.ndv > best:
            best = v.ndv
    for i in range(len(edge.right_keys)):
        var v = provider.distinct_count_for(
            edge.right_relation, edge.right_keys[i]
        )
        if v.ndv > best:
            best = v.ndv
    if best < 1:
        return 1.0
    return Float64(best)


# =============================================================================
# _subgraphs_connected_by_edge — which subgraphs an edge's endpoints touch
# =============================================================================


def _subgraph_index_for_relation(
    imm subgraphs: List[_Subgraph], rel_id: Int
) -> Int:
    """Find the subgraph index that contains `rel_id`, or -1.

    DuckDB walks edge.left_set / edge.right_set against subgraph.relations
    via `IsSubset`; we work on single-rel endpoints, so a bit test on
    `subgraphs[k].relations` is the analog.
    """
    var bit = UInt64(1) << UInt64(rel_id)
    for k in range(len(subgraphs)):
        if (subgraphs[k].relations & bit) != UInt64(0):
            return k
    return -1


# =============================================================================
# _base_cards — product over relations in `combined_set` of base cardinalities
# =============================================================================


def _numerator_for_set(
    imm chain: JoinChain,
    combined: UInt64,
) -> Float64:
    """Return the product of BASE relation cardinalities for relations
    in `combined`.

    Mirrors DuckDB `GetNumerator` at
    `cardinality_estimator.cpp:138-146`. The product is over the
    SINGLE-RELATION cardinalities, NOT the DP-resolved intermediates —
    this is the load-bearing property that makes the resulting estimate
    partition-INDEPENDENT.

    Returns Float64 because the product can exceed Int64 for SF=100+
    workloads (e.g. 6 * 1e6 * 1.5e6 * 8e5 * 1e4 * 25 ≈ 1.8e22, which
    overflows Int64). DuckDB uses double for the same reason.

    The base cardinality is `chain.relations[rel_id].cardinality` —
    which is the POST-FILTER cardinality (see
    `optimizer_column_stats_provider.mojo` Tier-2 comment + DuckDB
    `cardinality_after_filters` per `relation_statistics_helper.cpp:110`).
    """
    var numerator: Float64 = 1.0
    var v = combined
    var rel_id = 0
    while v != UInt64(0):
        if (v & UInt64(1)) != UInt64(0):
            if rel_id < len(chain.relations):
                var card = chain.relations[rel_id].cardinality
                if card < 1:
                    # DuckDB :143 — "card == 0 ? 1 : card".
                    card = 1
                numerator = numerator * Float64(card)
        v >>= UInt64(1)
        rel_id += 1
    return numerator


# =============================================================================
# _denominator_for_set — DuckDB GetDenominator subgraph-merge walk
# =============================================================================


def _denominator_for_set[
    P: ColumnStatsProvider, //
](
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    combined: UInt64,
    imm provider: P,
) -> Float64:
    """Subgraph-merge denominator walk.

    Mirrors DuckDB `GetDenominator` at
    `cardinality_estimator.cpp:286-402`. Algorithm:

      1. Enumerate all edges with both endpoints in `combined`, sorted
         by TDOM-DESC (`_collect_internal_edges_sorted`).
      2. Initialize empty subgraphs list + empty unused_edge_tdoms set.
      3. For each edge in TDOM-DESC order:
         a. If a single subgraph already spans the full `combined` set,
            this edge is "extra" — record its TDOM in `unused_edge_tdoms`
            and continue (DuckDB :305-311).
         b. Find which existing subgraphs contain each endpoint of the
            edge. There are three cases:
            - Both endpoints are in NO existing subgraph → create a new
              subgraph spanning both, denom = edge.TDOM (DuckDB :313-326).
            - Both endpoints are in the SAME subgraph → "same subgraph
              edge"; CONTINUE without updating denom (DuckDB :337-342).
              Track the TDOM in `unused_edge_tdoms`.
            - One endpoint in subgraph S, other not in any → extend S
              with the new endpoint, multiply S.denom by edge.TDOM
              (DuckDB :327-345).
            - One endpoint in subgraph S1, other in subgraph S2 (S1 != S2)
              → MERGE S2 into S1, multiply S1.denom by (S2.denom *
              edge.TDOM) (DuckDB :346-360).
      4. Apply unused-edge log penalty: `denom_multiplier = 1.0 +
         |unused_edge_tdoms|` (DuckDB :364).
      5. If multiple subgraphs remain (cross-product situation), multiply
         their denoms (DuckDB :368-378).
      6. Return `subgraphs[0].denom * denom_multiplier`. Defensive: if
         empty or zero, return 1.0 (DuckDB :397-400 fallback).

    For the Q9 worked example:
      combined = {l, p, o, ps, s, n} (bits = 63 for ids 0..5).
      8 internal edges f1..f8 sorted by TDOM-DESC.
      The walk produces denom ~ 1.5e19 (matching DuckDB).
      numerator = 6M*200K*1.5M*800K*10K*25 = 3.6e25.
      Cardinality ~ 2.4M (close to DuckDB's 4.8M; ratio within noise).
    """
    var sorted_edges = _collect_internal_edges_sorted(tdom, chain, combined)

    var subgraphs = List[_Subgraph]()
    # DuckDB `unused_edge_tdoms` is `unordered_set<idx_t>` keyed by TDOM
    # VALUE — duplicate TDOMs across edges collapse to one entry
    # (cardinality_estimator.cpp:302+:308). The penalty at :364 is
    # `1.0 + |distinct TDOMs|`. Mirror via a small List[Int] uniqued
    # on insert (Q9's typical case has <=8 internal edges, dedup is
    # O(N^2) but N <= 8).
    var unused_tdoms = List[Int]()

    # Compute popcount of `combined` for the early-exit test (when a
    # single subgraph spans `combined`, every subsequent edge is "extra").
    var combined_pop: Int = 0
    var v = combined
    while v != UInt64(0):
        v &= v - UInt64(1)
        combined_pop += 1

    for i in range(len(sorted_edges)):
        var e_idx = sorted_edges[i]
        ref edge = chain.edges[e_idx]
        var l_id = edge.left_relation
        var r_id = edge.right_relation
        var edge_t = _edge_tdom_for_denom(tdom, chain, e_idx, provider)

        # DuckDB :305-311 early-exit: if a single subgraph spans the full
        # combined set, this edge is "extra" — track its TDOM in
        # unused_edge_tdoms (DEDUPED by TDOM value at :308). Only the
        # `has_distinct_count_hll` case contributes (line :307 — Tier-2-only
        # edges are SILENTLY DROPPED from the penalty). Class-level
        # ingestion populates `hll_ndv` only for `from_hll=True` edges
        # (see optimizer_tdom._ingest_provider_value); we use that as
        # the Tier-1 gate.
        if len(subgraphs) == 1:
            var only_pop: Int = 0
            var bw = subgraphs[0].relations
            while bw != UInt64(0):
                bw &= bw - UInt64(1)
                only_pop += 1
            if only_pop == combined_pop:
                var c_idx = tdom.class_for_edge(e_idx)
                if c_idx >= 0 and tdom.classes[c_idx].hll_ndv:
                    var t_val = tdom.classes[c_idx].hll_ndv.value()
                    var already = False
                    for u in range(len(unused_tdoms)):
                        if unused_tdoms[u] == t_val:
                            already = True
                            break
                    if not already:
                        unused_tdoms.append(t_val)
                continue

        var l_sub = _subgraph_index_for_relation(subgraphs, l_id)
        var r_sub = _subgraph_index_for_relation(subgraphs, r_id)

        if l_sub < 0 and r_sub < 0:
            # No subgraph touches either endpoint — create a fresh one.
            var l_bit = UInt64(1) << UInt64(l_id)
            var r_bit = UInt64(1) << UInt64(r_id)
            subgraphs.append(_Subgraph(l_bit | r_bit, edge_t))
        elif l_sub == r_sub:
            # Both endpoints in the SAME subgraph — DuckDB :337-342 SKIP.
            # DuckDB does NOT add to unused_edge_tdoms here (that branch
            # only fires from the early-exit at :305-311).
            pass
        elif l_sub >= 0 and r_sub < 0:
            # Extend existing subgraph with new endpoint r_id.
            var r_bit = UInt64(1) << UInt64(r_id)
            var new_relations = subgraphs[l_sub].relations | r_bit
            var new_denom = subgraphs[l_sub].denom * edge_t
            subgraphs[l_sub] = _Subgraph(new_relations, new_denom)
        elif r_sub >= 0 and l_sub < 0:
            # Extend existing subgraph with new endpoint l_id.
            var l_bit = UInt64(1) << UInt64(l_id)
            var new_relations = subgraphs[r_sub].relations | l_bit
            var new_denom = subgraphs[r_sub].denom * edge_t
            subgraphs[r_sub] = _Subgraph(new_relations, new_denom)
        else:
            # MERGE two subgraphs into one via this edge.
            # Convention: merge higher-indexed into lower-indexed; delete
            # the higher-indexed slot (DuckDB :346-360 same shape).
            var keep_idx = l_sub if l_sub < r_sub else r_sub
            var drop_idx = r_sub if l_sub < r_sub else l_sub
            var merged_relations = (
                subgraphs[keep_idx].relations | subgraphs[drop_idx].relations
            )
            var merged_denom = (
                subgraphs[keep_idx].denom * subgraphs[drop_idx].denom * edge_t
            )
            subgraphs[keep_idx] = _Subgraph(merged_relations, merged_denom)
            # Remove drop_idx by shifting subsequent entries left.
            var n_subs = len(subgraphs)
            var k = drop_idx
            while k + 1 < n_subs:
                subgraphs[k] = subgraphs[k + 1].copy()
                k += 1
            _ = subgraphs.pop()

    # Apply unused-edge log-scale penalty (DuckDB :364). Note: |distinct
    # TDOMs|, not |unused edges| — DuckDB dedups by TDOM value in an
    # unordered_set at :302+:308.
    var denom_multiplier: Float64 = 1.0 + Float64(len(unused_tdoms))

    # If multiple subgraphs remain after the walk (cross-product case),
    # multiply their denoms (DuckDB :368-378). DPccp only enumerates
    # connected (csg, cmp) pairs so this should not fire in normal Q9
    # flow, but the defensive fold matches DuckDB's contract.
    if len(subgraphs) == 0:
        return 1.0
    var final_denom = subgraphs[0].denom
    for k in range(1, len(subgraphs)):
        final_denom = final_denom * subgraphs[k].denom
    if final_denom <= 0.0:
        # DuckDB :397-400 fallback — degenerate case.
        return 1.0
    return final_denom * denom_multiplier


# =============================================================================
# _max_base_card_in_set — multi-relation FK-PK ceiling (clamp bound)
# =============================================================================


@always_inline
def _max_base_card_in_set(
    imm chain: JoinChain,
    combined: UInt64,
) -> Int:
    """Return max(base_card_for_rel) over relations in `combined`.

    Mirrors the generalization of the pair cost's `max(L, R)` clamp bound to
    multi-relation form. DuckDB's `EstimateFilteredCardinality` uses
    the same shape — a cardinality cap based on the largest input
    relation in the joint set.

    Used by the FK-PK clamp in `estimate_cardinality_with_set` when
    any bridging bucket in `combined` carries a Tier-1-backed
    composite-NDV PK signal.
    """
    var best: Int = 1
    var v = combined
    var rel_id = 0
    while v != UInt64(0):
        if (v & UInt64(1)) != UInt64(0):
            if rel_id < len(chain.relations):
                var card = chain.relations[rel_id].cardinality
                if card > best:
                    best = card
        v >>= UInt64(1)
        rel_id += 1
    return best


# =============================================================================
# _all_bucket_cols_have_hll_signal_local — Tier-1 gate (local copy)
# =============================================================================
#
# Local copy of `_all_bucket_cols_have_hll_signal` from
# `optimizer_tdom_cost.mojo`. Required here because that helper is module-
# private. Once the legacy `estimate_with_tdom` is deleted in commit 4 the
# helper there goes with it; the local copy becomes the canonical home.


def _bucket_tier1_signal_on_side[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm bucket: PairBucket,
    rel_id: Int,
    imm provider: P,
) -> Bool:
    """Return True iff EVERY column of `rel_id` in this bucket's
    bridging edges has `from_hll=True`. The Tier-1 gate criterion.

    See `optimizer_tdom_cost._all_bucket_cols_have_hll_signal` for the
    full rationale: Tier-2 NDV trivially equals cardinality so we
    must require Tier-1 backing to avoid spuriously clamping every
    Tier-2 join pair (Q5 preservation guard).
    """
    if not bucket.contains_relation(rel_id):
        return False
    if rel_id < 0 or rel_id >= len(chain.relations):
        return False
    if bucket.size() == 0:
        return False

    var seen_cols = List[String]()
    for i in range(bucket.size()):
        var e_idx = bucket.edge_indices[i]
        if e_idx < 0 or e_idx >= len(chain.edges):
            continue
        ref edge = chain.edges[e_idx]
        var col = String("")
        if edge.left_relation == rel_id:
            col = String(edge.left_keys[0])
        elif edge.right_relation == rel_id:
            col = String(edge.right_keys[0])
        if col.byte_length() == 0:
            continue
        var already_seen = False
        for j in range(len(seen_cols)):
            if seen_cols[j] == col:
                already_seen = True
                break
        if already_seen:
            continue
        seen_cols.append(col)
        var v = provider.distinct_count_for(rel_id, col)
        if not v.from_hll:
            return False
    if len(seen_cols) == 0:
        return False
    return True


def _bucket_has_fkpk_signal_local[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm bucket: PairBucket,
    imm provider: P,
) -> Bool:
    """FK-PK signal (composite-NDV PK + Tier-1 gate).

    Two-step gate (mirrors `_bucket_has_fkpk_signal` in
    `optimizer_tdom_cost.mojo`):
      1. `composite_ndv_pk_side` returns rel_a / rel_b when exactly one
         side has composite_NDV == |rel| (PK signal), -2 for both, -1
         for neither.
      2. Tier-1 gate (`_bucket_tier1_signal_on_side`) requires the
         qualifying side(s) to have ALL bucket columns backed by
         `from_hll=True`.
    """
    var pk_side = composite_ndv_pk_side(chain, bucket, provider)
    if pk_side == -1:
        return False
    if pk_side == -2:
        if _bucket_tier1_signal_on_side(chain, bucket, bucket.rel_a, provider):
            return True
        return _bucket_tier1_signal_on_side(chain, bucket, bucket.rel_b, provider)
    return _bucket_tier1_signal_on_side(chain, bucket, pk_side, provider)


@always_inline
def _bucket_within_set(
    imm bucket: PairBucket,
    combined: UInt64,
) -> Bool:
    """Return True iff BOTH bucket endpoints are in `combined`.

    The bucket-relation pair is unordered (rel_a < rel_b enforced
    by `build_pair_buckets`). A bucket whose endpoints both lie in
    `combined` represents a composite/correlated bridging edge group
    that COULD contribute a FK-PK clamp signal for the joint set.
    """
    var a_bit = UInt64(1) << UInt64(bucket.rel_a)
    var b_bit = UInt64(1) << UInt64(bucket.rel_b)
    return (combined & a_bit) != UInt64(0) and (combined & b_bit) != UInt64(0)


# =============================================================================
# _is_cross_product_shaped_subset — cross-product detection
# =============================================================================
#
# A subset is "cross-product shaped" iff its
# member relations are NOT all reachable from each other via the
# JoinChain's explicit internal edges. That is, the connected components
# of the in-subset edge induced subgraph do not cover all the subset's
# relations.
#
# Background: with the cross-product fallback, DPccp can enumerate
# partitions like `{ps, s, n}` for Q9 where the only internal explicit
# edge is `s ↔ n`; `ps` is isolated within the subset. The subgraph-merge
# walk in `_denominator_for_set` then produces a denom = MAX-ndv-of-sn
# (the single edge's contribution) times the unused-edge penalty, but
# the numerator product includes `ps`'s 800K base cardinality untouched.
# The resulting cardinality estimate for `{ps,s,n}` overshoots to
# ~200M (Cartesian) instead of DuckDB's ~898K.
#
# The cross-product detection lets us apply an FK-PK upper-bound clamp
# on these cases without firing on well-connected partitions like
# `{l,p,o}` (the left side of Q9's partition A) or any Q5 partition.


def _is_cross_product_shaped_subset(
    imm chain: JoinChain,
    combined: UInt64,
) -> Bool:
    """Return True iff `combined`'s member relations are NOT all
    transitively reachable via `chain.edges`.

    Algorithm (small-N union-find — `combined`'s popcount typically <=6):
      1. Enumerate the relation ids in `combined`.
      2. Seed each rel as its own component.
      3. For each edge in `chain.edges` whose BOTH endpoints are in
         `combined`, union the two endpoints' components.
      4. If every rel ends up in the SAME component → connected
         (NOT cross-product shaped). Otherwise → cross-product shaped.

    Singletons trivially return False (one rel is its own connected
    component). Empty `combined` defensively returns False.

    The walk uses an array-indexed parent table sized by the chain's
    relation count (<=12 typical). No allocations except the small
    parent / rank lists.
    """
    var n_rels = len(chain.relations)
    if n_rels == 0:
        return False

    # Build the in-set rel-id list.
    var members = List[Int]()
    var v = combined
    var rel_id = 0
    while v != UInt64(0):
        if (v & UInt64(1)) != UInt64(0):
            if rel_id < n_rels:
                members.append(rel_id)
        v >>= UInt64(1)
        rel_id += 1

    if len(members) <= 1:
        # Singleton or empty: trivially connected.
        return False

    # Union-find over n_rels (sparse; only `members` ids are live).
    var parent = List[Int]()
    for i in range(n_rels):
        parent.append(i)

    # Edge-driven union over in-set edges only.
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        if not _edge_in_set(e, combined):
            continue
        # find(l)
        var l = e.left_relation
        while parent[l] != l:
            l = parent[l]
        # find(r)
        var r = e.right_relation
        while parent[r] != r:
            r = parent[r]
        if l != r:
            # union: attach larger id to smaller (keeps roots stable).
            if l < r:
                parent[r] = l
            else:
                parent[l] = r

    # All members must share one root.
    # find(members[0])
    var root0 = members[0]
    while parent[root0] != root0:
        root0 = parent[root0]  # cov: unreachable members[0] is the least member id and union keeps the lesser root, so it is a root
    for k in range(1, len(members)):
        var rk = members[k]
        while parent[rk] != rk:
            rk = parent[rk]
        if rk != root0:
            return True
    return False


# =============================================================================
# estimate_cardinality_with_set — THE one-set cardinality entry point
# =============================================================================


def estimate_cardinality_with_set[
    P: ColumnStatsProvider, //
](
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    combined: UInt64,
    imm provider: P,
    mut cache: Dict[UInt64, Int],
) -> Int:
    """Estimate the cardinality of the join over `combined`'s relations,
    independent of the (L, R) partition that produced the candidate
    pair.

    Mirrors DuckDB `EstimateCardinalityWithSet<double>` at
    `src/optimizer/join_order/cardinality_estimator.cpp:417-432`.

    Algorithm:
      1. Cache check by `combined` bits — same set ALWAYS returns same
         cardinality (the load-bearing property; DuckDB caches in
         `relation_set_2_cardinality` at :419-430).
      2. `numerator = _numerator_for_set(chain, combined)` — product of
         BASE relation cardinalities (DuckDB `GetNumerator` :138-146).
      3. `denom = _denominator_for_set(tdom, chain, combined, provider)`
         — subgraph-merge walk (DuckDB `GetDenominator` :286-402).
      4. `est = round(numerator / denom)`, clamped to >= 1.
      5. FK-PK upper-bound clamp: walk all pair-buckets that fall WITHIN
         `combined`; if ANY carries a Tier-1-backed PK signal, clamp
         `est <= max(base_card_for_rel)` over `combined`. This
         generalizes the pair cost's `max(L, R)` to multi-relation form.
      6. Cache and return.

    Singleton handling: when `combined` is a single relation, the walk
    yields no internal edges → denom = 1.0; numerator = base card; est
    = base card. Matches the singleton DP seed.

    Trait-bound P matches the rest of the cost module so test
    SyntheticColumnStatsProvider feeds through one surface.
    """
    # ----- Step 1: cache hit -----
    var hit = cache.get(combined)
    if hit:
        return hit.value()

    # ----- Step 2: numerator (product of BASE cardinalities) -----
    var numerator = _numerator_for_set(chain, combined)

    # ----- Step 3: denominator (subgraph-merge walk) -----
    var denom = _denominator_for_set(tdom, chain, combined, provider)

    # ----- Step 4: ratio + integer clamp -----
    var est_f: Float64 = numerator / denom
    var est: Int
    # Saturating round-to-Int. The numerator product can exceed Int64
    # so we clamp at a defensive upper bound before truncating.
    var SAT_CAP: Float64 = 9.0e18  # well under Int64 max (~9.22e18)
    if est_f >= SAT_CAP:
        est = 9_000_000_000_000_000_000
    elif est_f < 1.0:
        est = 1
    else:
        est = Int(est_f)
        if est < 1:
            est = 1

    # ----- Step 5: FK-PK clamp (Tier-1-gated; multi-rel ceiling) -----
    # The PairBucket enumeration over the chain; pick those that
    # lie entirely within `combined` and check for the Tier-1 PK signal.
    var pk_clamp_fires = False
    var all_buckets = build_pair_buckets(chain)
    for k in range(len(all_buckets)):
        ref bucket = all_buckets[k]
        if not _bucket_within_set(bucket, combined):
            continue
        if _bucket_has_fkpk_signal_local(chain, bucket, provider):
            pk_clamp_fires = True
            break
    if pk_clamp_fires:
        var bound = _max_base_card_in_set(chain, combined)
        if est > bound:
            est = bound

    # ----- Step 5b: Cross-product clamp -----
    # When `combined` is cross-product shaped (its internal explicit
    # edges do NOT span all member relations), the subgraph-merge walk
    # produces a denom that doesn't reflect the disconnected pieces.
    # For Q9 partition A's `{ps, s, n}` (only s↔n internal; ps
    # isolated), this overshoots ~250x. Apply an FK-PK upper-bound
    # clamp: est = min(est, max_base_card_in_set). This generalizes
    # the Tier-1-gated clamp above for the cross-product case where
    # the bucket walk cannot establish a PK signal (one or more
    # relations have NO bridging edges in-subset to participate in
    # a bucket).
    #
    # Q5 contract: this guard does NOT fire on connected subsets.
    # Q5's all-{l,o,c,s,n,r} partitions are connected via explicit
    # edges (lineitem↔orders, orders↔customer, supplier↔nation,
    # nation↔region, customer↔supplier-via-l_suppkey), so
    # `_is_cross_product_shaped_subset` returns False everywhere.
    #
    # The clamp is unconditional (not Tier-1-gated) when the
    # cross-product shape is detected — the rationale is that a
    # disconnected subset's denom is structurally wrong (it can't
    # capture cross-class correlations), so capping at the largest
    # base relation cardinality is the conservative-correct ceiling.
    # Q9 SF1: `{ps,s,n}` has max(800K, 10K, 25) = 800K, close to
    # DuckDB's 898K (within 11%).
    if not pk_clamp_fires:
        if _is_cross_product_shaped_subset(chain, combined):
            var xp_bound = _max_base_card_in_set(chain, combined)
            if est > xp_bound:
                est = xp_bound

    # ----- Step 6: cache + return -----
    cache[combined] = est
    return est


# =============================================================================
# CardTrace + estimate_cardinality_with_set_traced — diagnostic sibling
# =============================================================================
#
# Diagnostic-only sibling of `estimate_cardinality_with_set`. Exposes the
# RAW numerator, denominator, raw cardinality, FK-PK clamp signal, and
# post-clamp cardinality so a diagnosis can disambiguate
# Candidate 1 (clamp inflating upward) vs Candidate 3 (input-wrong:
# base-card too large) for the Q9 `{l, p, o}` 3-rel sub-set.
#
# Contract (verbatim mirror of `estimate_cardinality_with_set` math):
#   * `raw_numerator`  — product of BASE rel cardinalities in `combined`
#                        (Float64; identical to `_numerator_for_set`).
#   * `raw_denominator`— subgraph-merge walk product (Float64; identical
#                        to `_denominator_for_set`).
#   * `raw_card_f`     — `raw_numerator / raw_denominator` BEFORE Int
#                        truncation. Useful for low-cardinality cases.
#   * `raw_card`       — Int truncation of `raw_card_f`, clamped to >= 1.
#                        Matches `estimate_cardinality_with_set` Step 4.
#   * `clamp_fired`    — True iff ANY bucket within `combined` carried a
#                        Tier-1-backed PK signal.
#   * `clamp_bound`    — `max(base_card_for_rel)` over `combined`. The
#                        ceiling the clamp would impose.
#   * `final_card`     — `min(raw_card, clamp_bound)` if `clamp_fired`
#                        or (Step 5b) `combined` is cross-product shaped,
#                        else `raw_card`: the production estimate.
#
# The production path does NOT invoke this helper; it rebuilds the math
# from scratch for test and diagnostic use.
# =============================================================================


struct CardTrace(Movable, Copyable):
    """Diagnostic snapshot of one `estimate_cardinality_with_set` call.

    Fields mirror the algorithm steps documented above. Movable + Copyable
    so it can live in a `List[CardTrace]` for batch diagnostic dumps.
    """

    var raw_numerator: Float64
    var raw_denominator: Float64
    var raw_card_f: Float64
    var raw_card: Int
    var clamp_fired: Bool
    var clamp_bound: Int
    var final_card: Int

    @always_inline
    def __init__(
        out self,
        raw_numerator: Float64,
        raw_denominator: Float64,
        raw_card_f: Float64,
        raw_card: Int,
        clamp_fired: Bool,
        clamp_bound: Int,
        final_card: Int,
    ):
        self.raw_numerator = raw_numerator
        self.raw_denominator = raw_denominator
        self.raw_card_f = raw_card_f
        self.raw_card = raw_card
        self.clamp_fired = clamp_fired
        self.clamp_bound = clamp_bound
        self.final_card = final_card

    @always_inline
    def copy(self) -> Self:
        return Self(
            self.raw_numerator,
            self.raw_denominator,
            self.raw_card_f,
            self.raw_card,
            self.clamp_fired,
            self.clamp_bound,
            self.final_card,
        )


def estimate_cardinality_with_set_traced[
    P: ColumnStatsProvider, //
](
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    combined: UInt64,
    imm provider: P,
) -> CardTrace:
    """Diagnostic sibling of `estimate_cardinality_with_set`. Returns
    a `CardTrace` capturing raw numerator/denominator + clamp signal +
    pre/post-clamp cardinalities for diagnosis.

    Does NOT touch the production cache or mutate provider / chain /
    tdom; same math as the production path.
    """
    # Step 2: numerator (mirror of `_numerator_for_set`).
    var numerator = _numerator_for_set(chain, combined)

    # Step 3: denominator (mirror of `_denominator_for_set`).
    var denom = _denominator_for_set(tdom, chain, combined, provider)

    # Step 4: ratio + Int truncation (mirror of production).
    var est_f: Float64 = numerator / denom
    var est: Int
    var SAT_CAP: Float64 = 9.0e18
    if est_f >= SAT_CAP:
        est = 9_000_000_000_000_000_000
    elif est_f < 1.0:
        est = 1
    else:
        est = Int(est_f)
        if est < 1:
            est = 1

    # Step 5: FK-PK clamp signal (Tier-1 + bucket-PK gate).
    var pk_clamp_fires = False
    var all_buckets = build_pair_buckets(chain)
    for k in range(len(all_buckets)):
        ref bucket = all_buckets[k]
        if not _bucket_within_set(bucket, combined):
            continue
        if _bucket_has_fkpk_signal_local(chain, bucket, provider):
            pk_clamp_fires = True
            break

    # Step 5 (continued) and Step 5b: both clamps share the bound.
    var bound = _max_base_card_in_set(chain, combined)
    var final_card = est
    var clamps = pk_clamp_fires or _is_cross_product_shaped_subset(
        chain, combined
    )
    if clamps and est > bound:
        final_card = bound

    return CardTrace(
        numerator,
        denom,
        est_f,
        est,
        pk_clamp_fires,
        bound,
        final_card,
    )
