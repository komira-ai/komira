# =============================================================================
# TDOM equivalence-set graph — data structures + build_tdom_graph
# =============================================================================
#
# The algorithmic centerpiece of DuckDB's
# join-order cost model, replicated in Mojo. This module owns the
# union-find construction (`build_tdom_graph`) + the supporting data shapes
# (`ColumnBinding`, `EquivalenceClass`, `TdomGraph`). The downstream cost
# computation (`estimate_with_tdom`) lives in the sibling module
# `optimizer_tdom_cost.mojo`; keeping the split keeps each file smaller.
#
# Mirrors DuckDB's
#   - `cardinality_estimator.cpp:73-128` (`InitEquivalentRelations` +
#     `AddToEquivalenceSets`) — union-find construction.
#   - `cardinality_estimator.cpp:479-509` (`UpdateTotalDomains`) — per-column
#     NDV ingestion via the provider, with from_hll splitting.
#   - `cardinality_estimator.cpp:130-135` (`RemoveEmptyTotalDomains`) —
#     post-merge compaction.
#
# Inputs:
#   * `JoinChain` (from `optimizer_reorder`) — relations + per-column edges.
#     Edges arrive in INSERTION ORDER (the edge split's
#     order); leftover composite edges have `len(left_keys) > 1` and are
#     explicitly tagged via `edge_to_class[i] = -1`.
#   * `ColumnStatsProvider` (from `optimizer_column_stats_provider`) —
#     three-tier NDV dispatch. ALWAYS returns a value (no Optional);
#     `from_hll=True` selects the Tier-1 cross-class MAX path,
#     `from_hll=False` selects the Tier-2 MIN-across-class path.
#
# Outputs:
#   * `TdomGraph` — per-equivalence-class TDOMs + `edge_to_class` mapping.
#     Read by `estimate_with_tdom` (`optimizer_tdom_cost.mojo`) for each
#     cost-of-pair lookup; the DP join enumerator that would issue those
#     lookups is not in this tree.
#
# Worked Q5 example:
#   6 per-column edges produce 5 equivalence classes:
#     C0 = {nation.n_regionkey, region.r_regionkey},                TDOM 5
#     C1 = {supplier.s_nationkey, customer.c_nationkey,
#           nation.n_nationkey},                                    TDOM 25
#     C2 = {orders.o_custkey, customer.c_custkey},                  TDOM 150000
#     C3 = {lineitem.l_orderkey, orders.o_orderkey},                TDOM 1500000
#     C4 = {lineitem.l_suppkey, supplier.s_suppkey},                TDOM 10000
#   Each TDOM is the MIN of the member relations' row counts at TPC-H scale
#   factor 1 (the row-count fallback, which DuckDB also falls back to).
#
# Encapsulation rule: optimizer-internal module; no UnsafePointer
# crosses any boundary. The provider's borrowed Slab[JoinRelation] ref is
# the canonical access path; we use the trait-bound `P: ColumnStatsProvider`
# parameter on `build_tdom_graph` so the production `DefaultColumnStatsProvider`
# AND test `SyntheticColumnStatsProvider` can both feed the algorithm
# without changing the surface.
# =============================================================================

from komira_collections.slab import Slab
from .optimizer_column_stats_provider import (
    ColumnStatsProvider,
    ColumnStatsValue,
)
from .optimizer_reorder import JoinChain, JoinEdge, JoinRelation


# =============================================================================
# ColumnBinding — one (relation_id, column_name) pair
# =============================================================================


struct ColumnBinding(Movable, Copyable, ImplicitlyCopyable):
    """One (relation_id, column_name) pair in an equivalence class.

    Mirrors DuckDB's `ColumnBinding{table_index, column_index}` from
    `cardinality_estimator.hpp`. We use a column NAME (not a positional
    index) because Komira's LogicalPlan schemas are name-keyed and the
    per-column edge split yields name-keyed left_keys/right_keys.

    `relation_id` is the dense 0..n-1 id assigned at `extract_join_chain`
    time (matches the slab index in `JoinChain.relations`).

    `ImplicitlyCopyable`: an implicit copy is an Int plus a String copy,
    and it lets us materialize bindings out of `List` indexing without
    explicit `.copy()` ceremony.
    """

    var relation_id: Int
    var column_name: String

    @always_inline
    def __init__(out self, relation_id: Int, var column_name: String):
        self.relation_id = relation_id
        self.column_name = column_name^

    @always_inline
    def copy(self) -> Self:
        return Self(self.relation_id, String(self.column_name))

    @always_inline
    def eq(self, other: Self) -> Bool:
        return (
            self.relation_id == other.relation_id
            and self.column_name == other.column_name
        )


# =============================================================================
# EquivalenceClass — one set of transitively-equal column bindings
# =============================================================================


struct EquivalenceClass(Movable, Copyable):
    """One set of columns transitively connected by equi-join filters.

    Mirrors DuckDB `RelationsSetToStats` (cardinality_estimator.hpp:29-44):
    "column binding sets that are equivalent in a join plan. if you have
    A.x = B.y and B.y = C.z, then one set is {A.x, B.y, C.z}."

    Fields:
      * `bindings` — the equivalence-class members. List (not Slab) because
        the class size is bounded by num_relations in practice (<=12 in any
        realistic chain) and we need cheap `for binding in class.bindings`
        iteration in tests + the cost model.
      * `hll_ndv` — HLL-merged NDV across the class. Populated when ANY
        contributor returned `from_hll=True` from the provider. Stored as
        `Optional[Int]` so we can distinguish "unset" from "computed".
        See `tdom()` for the load-bearing read.
      * `no_hll_ndv` — Conservative MIN-across-class NDV. Populated when
        ANY contributor returned `from_hll=False`. Mirrors DuckDB
        `cardinality_estimator.cpp:503-504` (MinValue across no-HLL
        contributors).
      * `contributing_edges` — edge indices (into chain.edges) that
        touched this class during union-find. Used by the cost model's
        bridging-edge enumeration to detect "edge subsumed by a higher-TDOM
        equivalent edge" (DuckDB cardinality_estimator.cpp:336-341
        skip-redundant path) — also a diagnostic for tests.

    Movable + Copyable. Copyable is required for `List[EquivalenceClass]`
    storage in `TdomGraph.classes`; every field
    is itself Copyable (`List[ColumnBinding]` with Copyable bindings,
    `Optional[Int]`, `List[Int]`), and `copy()` below copies each one.
    Hot-path consumers should still bind via `ref c = classes[i]`
    to avoid the deep-copy cost of the `List[ColumnBinding]` String field.
    """

    var bindings: List[ColumnBinding]
    var hll_ndv: Optional[Int]
    var no_hll_ndv: Optional[Int]
    var contributing_edges: List[Int]

    @always_inline
    def __init__(
        out self,
        var bindings: List[ColumnBinding],
        var hll_ndv: Optional[Int],
        var no_hll_ndv: Optional[Int],
        var contributing_edges: List[Int],
    ):
        self.bindings = bindings^
        self.hll_ndv = hll_ndv^
        self.no_hll_ndv = no_hll_ndv^
        self.contributing_edges = contributing_edges^

    @always_inline
    def copy(self) -> Self:
        var b = List[ColumnBinding]()
        for i in range(len(self.bindings)):
            b.append(self.bindings[i].copy())
        var ce = List[Int]()
        for i in range(len(self.contributing_edges)):
            ce.append(self.contributing_edges[i])
        var hll = self.hll_ndv
        var no_hll = self.no_hll_ndv
        return Self(b^, hll^, no_hll^, ce^)

    @always_inline
    def tdom(self) -> Int:
        """Return the load-bearing TDOM for cost computation.

        Preference order:
          1. `hll_ndv` if set — Tier-1 cross-class MAX (mirrors DuckDB
             `cardinality_estimator.cpp:496-498`).
          2. `no_hll_ndv` if set — Tier-2 MIN-across-class fallback.
          3. `1` defensive floor — should not fire because
             the provider ALWAYS returns a value, but cost-model safety
             requires a non-zero denominator.

        Both branches return `max(1, value)` to defend against any
        clamping slip from upstream stats.
        """
        if self.hll_ndv:
            var v = self.hll_ndv.value()
            if v < 1:
                return 1
            return v
        if self.no_hll_ndv:
            var v = self.no_hll_ndv.value()
            if v < 1:
                return 1
            return v
        return 1

    @always_inline
    def contains(self, binding: ColumnBinding) -> Bool:
        """O(class_size) membership test. Class size is bounded by
        num_relations (<=12 in any practical chain), so linear scan is the
        right call — saves the trait-bound dance a Dict[ColumnBinding,_]
        would require.
        """
        for i in range(len(self.bindings)):
            if self.bindings[i].eq(binding):
                return True
        return False


# =============================================================================
# TdomGraph — the per-chain equivalence-set graph
# =============================================================================


struct TdomGraph(Movable):
    """Equivalence-set TDOM graph for one JoinChain.

    Built once per chain by `build_tdom_graph`; read by
    `estimate_with_tdom` (`optimizer_tdom_cost.mojo`) for each
    cost-of-pair lookup.

    Fields:
      * `classes` — one `EquivalenceClass` per equivalence class
        (post-`_compact_classes`; all entries have non-empty
        bindings).
      * `edge_to_class` — `len(chain.edges)`-sized list mapping edge index
        to class index. `-1` means the edge belongs to NO class (leftover
        composite, `len(left_keys) > 1`); the cost model dispatches those via
        the legacy `_max_ndv_across_keys` path.

    Movable-only. The cost model holds a `ref` to consume.
    """

    var classes: List[EquivalenceClass]
    var edge_to_class: List[Int]

    @always_inline
    def __init__(
        out self,
        var classes: List[EquivalenceClass],
        var edge_to_class: List[Int],
    ):
        self.classes = classes^
        self.edge_to_class = edge_to_class^

    @always_inline
    def class_for_edge(self, edge_idx: Int) -> Int:
        """Return the class index for an edge, or -1 if the edge belongs
        to no class.

        Class -1 indicates a leftover composite (multi-key) edge: the cost model
        will dispatch it through the legacy `_max_ndv_across_keys` path
        (the canonical fix for composite over-estimation
        is the per-column split itself).

        `@always_inline` because `estimate_with_tdom` calls this for
        every bridging edge of a candidate pair.
        """
        if edge_idx < 0 or edge_idx >= len(self.edge_to_class):
            return -1
        return self.edge_to_class[edge_idx]

    @always_inline
    def num_classes(self) -> Int:
        return len(self.classes)


# =============================================================================
# build_tdom_graph — union-find construction + NDV ingestion
# =============================================================================
#
# Algorithm mirror (DuckDB cardinality_estimator.cpp):
#   1. `InitEquivalentRelations` + `AddToEquivalenceSets` (lines 73-128):
#      for each per-column edge, find the 0, 1, or 2 existing classes that
#      contain either endpoint binding; create/extend/merge accordingly.
#      Leftover composite edges (len(left_keys) > 1) are explicitly skipped
#      (DuckDB's per-comparison loop only sees per-comparison FilterInfos).
#
#   2. `RemoveEmptyTotalDomains` (lines 130-135): post-merge compaction.
#      Merging two classes leaves the second one empty; we either compact
#      the `classes` list or leave the empty slot in place. We compact
#      AND remap `edge_to_class` so consumers can iterate `classes` without
#      checking `len(c.bindings) > 0`.
#
#   3. `UpdateTotalDomains` (lines 479-509): per-column NDV ingestion.
#      For each binding in each class, query the provider; merge into
#      `hll_ndv` (cross-class MAX, defensively conservative — see §AUDIT)
#      or `no_hll_ndv` (MIN-across-class, mirror DuckDB :503-504).
#
# Complexity: O(n_edges * n_classes) <= O(n_edges^2). For Q5's 6 edges
# this is ~36 work units. Negligible.
# =============================================================================


def _find_classes_touching(
    classes: List[EquivalenceClass],
    lb: ColumnBinding,
    rb: ColumnBinding,
) -> List[Int]:
    """Return class indices that contain `lb` or `rb` (at most 2 — DuckDB
    invariant).

    The list is returned in CLASS-INDEX-ASCENDING order because the caller
    relies on a deterministic "first" class identity for the 1-class extend
    path. Linear scan is O(n_classes) per edge; total O(n_edges *
    n_classes).
    """
    var out = List[Int]()
    for i in range(len(classes)):
        ref c = classes[i]
        # Skip empty (merged-out) classes — pre-compaction this can fire if
        # the merge happens earlier in the loop. Post-compaction the check
        # is defensive only.
        if len(c.bindings) == 0:
            continue
        if c.contains(lb) or c.contains(rb):
            out.append(i)
    return out^


def _ingest_provider_value[
    P: ColumnStatsProvider, //
](
    mut cls: EquivalenceClass,
    relation_id: Int,
    column_name: String,
    imm provider: P,
):
    """Apply one (relation_id, column_name) NDV signal to `cls`.

    Mirrors DuckDB `cardinality_estimator.cpp:489-509`:
      * `from_hll=True`  → merge into `hll_ndv`. True register-level
        HLL merge requires the writer to populate `ColumnStats.hll_registers`
        (future wiring); for now we take the cross-class MAX of the
        per-column NDVs as the merged sketch's distinct count. The MAX is a
        LOWER bound on the distinct count of the union a register-level
        merge would estimate (the union lies between the MAX and the SUM).
        A larger TDOM is a larger join denominator, so a smaller estimate
        for joins that traverse this class.

      * `from_hll=False` → merge into `no_hll_ndv` via MIN-across-class.
        Exact mirror of DuckDB :503-504. The MIN encodes the soundness
        property: if every contributor's NDV is an upper bound on the
        column's distinct count, then any value flowing through ALL of
        the equivalent columns is bounded by the smallest upper bound.

    # AUDIT (HLL merge):
    #   The HLL merge takes MAX-of-NDV when from_hll=True; true
    #   register-level merge requires writer-side wiring.
    #   `ColumnStats.hll_registers` field exists (typed
    #   Optional[List[UInt8]]) but the stats builder does NOT populate
    #   it yet. When the writer wiring lands, swap this MAX-of-NDV for a
    #   proper register-level HLL union; the field already exists.
    """
    var v = provider.distinct_count_for(relation_id, column_name)
    if v.from_hll:
        if cls.hll_ndv:
            var cur = cls.hll_ndv.value()
            var new_v = cur if cur > v.ndv else v.ndv
            cls.hll_ndv = Optional[Int](new_v)
        else:
            cls.hll_ndv = Optional[Int](v.ndv)
    else:
        if cls.no_hll_ndv:
            var cur = cls.no_hll_ndv.value()
            var new_v = cur if cur < v.ndv else v.ndv
            cls.no_hll_ndv = Optional[Int](new_v)
        else:
            cls.no_hll_ndv = Optional[Int](v.ndv)


def _compact_classes(
    var classes: List[EquivalenceClass],
    mut edge_to_class: List[Int],
) -> List[EquivalenceClass]:
    """Drop empty (merged-out) classes; remap `edge_to_class` indices.

    Mirrors DuckDB `RemoveEmptyTotalDomains` (cardinality_estimator.cpp:130-
    135). Linear-time single pass over `classes`, single pass to remap
    `edge_to_class`. The remap table is built first so the remap pass can
    be O(n_edges) instead of O(n_edges * n_classes).
    """
    var n_old = len(classes)
    var remap = List[Int]()  # remap[old_idx] = new_idx or -1 (dropped)
    var out = List[EquivalenceClass]()
    for i in range(n_old):
        if len(classes[i].bindings) > 0:
            remap.append(len(out))
            # Deep-copy via the auto-synthesized Copyable; can't partial-
            # move-through-List-index in Mojo 1.0.0b1 (Slab.__getitem__ /
            # List.__getitem__ return a ref, not a movable value), so the
            # copy is the production-correct shape. EquivalenceClass is
            # Copyable expressly for this reason. The cost is one
            # List[ColumnBinding] String-deep-copy per surviving class —
            # negligible (Q5 has 5 classes).
            out.append(classes[i].copy())
        else:
            remap.append(-1)
    # Remap edge_to_class. -1 stays -1 (leftover composite); previously-
    # valid indices remap through the table. The pre-compact build phase
    # already maintained the "all edge_to_class entries point at the most-
    # recent class id after every merge" invariant — so the only remap
    # work here is to collapse the index space.
    for k in range(len(edge_to_class)):
        var old = edge_to_class[k]
        if old < 0:
            continue
        # The pre-compact merge path tightens to surviving class ids only;
        # `remap[old]` is always >= 0 at this point. Defensive:
        if old < len(remap) and remap[old] >= 0:
            edge_to_class[k] = remap[old]
    return out^


def build_tdom_graph[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm provider: P,
) -> TdomGraph:
    """Build the equivalence-set TDOM graph from a JoinChain.

    Algorithm (mirrors DuckDB cardinality_estimator.cpp:73-128 + 479-509):
      1. For each edge in `chain.edges` (in INSERTION ORDER —
         Slab insertion order is the contract):
         * If `len(left_keys) > 1` OR `len(right_keys) > 1`: leftover
           composite. `edge_to_class[i] = -1`, skip.
         * Else: union-find the (left_relation, left_keys[0]) and
           (right_relation, right_keys[0]) bindings.
           - 0 matching classes  → create new class with both bindings.
           - 1 matching class    → extend with the new binding(s).
           - 2 matching classes  → merge them (transitive equality).
      2. `_compact_classes`: drop empty (merged-out) entries; remap
         `edge_to_class` indices to the compacted space.
      3. For each surviving class, for each binding in the class: query
         `provider.distinct_count_for(...)`; merge into `hll_ndv` (Tier-1
         MAX) or `no_hll_ndv` (Tier-2 MIN) per `_ingest_provider_value`.

    `P: ColumnStatsProvider` is trait-bound so the production
    `DefaultColumnStatsProvider` AND test `SyntheticColumnStatsProvider`
    can both feed this without changing the surface. The trait's
    `distinct_count_for` ALWAYS returns a value (a trait invariant) —
    no Optional branching here.

    Complexity: O(n_edges * n_classes) <= O(n_edges^2); Q5 = ~36 ops.
    """
    var classes = List[EquivalenceClass]()
    var edge_to_class = List[Int]()

    # ---- Step 1: union-find construction over chain.edges ----
    for e_idx in range(len(chain.edges)):
        ref e = chain.edges[e_idx]

        # Leftover composite edges do not participate in equivalence
        # classes. The cost model dispatches them through _max_ndv_across_keys.
        if len(e.left_keys) > 1 or len(e.right_keys) > 1:
            edge_to_class.append(-1)
            continue

        # Per-column edge — exactly one key on each side.
        var lb = ColumnBinding(e.left_relation, e.left_keys[0])
        var rb = ColumnBinding(e.right_relation, e.right_keys[0])

        var touching = _find_classes_touching(classes, lb, rb)

        if len(touching) == 0:
            # Create new class with both bindings.
            var b = List[ColumnBinding]()
            b.append(lb.copy())
            b.append(rb.copy())
            var ce = List[Int]()
            ce.append(e_idx)
            var none_hll: Optional[Int] = None
            var none_no_hll: Optional[Int] = None
            classes.append(
                EquivalenceClass(b^, none_hll^, none_no_hll^, ce^)
            )
            edge_to_class.append(len(classes) - 1)

        elif len(touching) == 1:
            # Extend existing class with whichever binding(s) are new.
            var c_idx = touching[0]
            if not classes[c_idx].contains(lb):
                classes[c_idx].bindings.append(lb.copy())
            if not classes[c_idx].contains(rb):
                classes[c_idx].bindings.append(rb.copy())
            classes[c_idx].contributing_edges.append(e_idx)
            edge_to_class.append(c_idx)

        else:
            # Merge two classes (DuckDB invariant: at most 2 matches).
            # Convention: keep the lower-indexed class, drain the higher-
            # indexed one into it, then leave the higher-indexed empty
            # for `_compact_classes` to drop.
            var keep_idx = touching[0]
            var drain_idx = touching[1]

            # 1) snapshot the drained class via Copyable (cannot partial-
            # move-through-List-index in Mojo 1.0.0b1 — List.__getitem__
            # returns a ref). The drained class is then overwritten with
            # an empty marker for `_compact_classes` to drop. Deep copy is
            # the right shape: drained_bindings carries Strings, which we
            # need to keep alive past the overwrite. EquivalenceClass is
            # Copyable for exactly this case.
            var drained = classes[drain_idx].copy()
            var empty_b = List[ColumnBinding]()
            var empty_e = List[Int]()
            var none_hll: Optional[Int] = None
            var none_no_hll: Optional[Int] = None
            classes[drain_idx] = EquivalenceClass(
                empty_b^, none_hll^, none_no_hll^, empty_e^
            )

            # 2) append drained bindings into keep (dedup).
            for i in range(len(drained.bindings)):
                if not classes[keep_idx].contains(drained.bindings[i]):
                    classes[keep_idx].bindings.append(drained.bindings[i])

            # 3) append drained edge ids + the new edge itself.
            for i in range(len(drained.contributing_edges)):
                classes[keep_idx].contributing_edges.append(
                    drained.contributing_edges[i]
                )
            classes[keep_idx].contributing_edges.append(e_idx)

            # 4) also fold in lb/rb (one or both may have been the
            # bridging element; either way they belong in keep now).
            if not classes[keep_idx].contains(lb):
                classes[keep_idx].bindings.append(lb.copy())  # cov: unreachable classes stay disjoint, so one touched class held lb and the drained one rb; keep now holds both
            if not classes[keep_idx].contains(rb):
                classes[keep_idx].bindings.append(rb.copy())  # cov: unreachable classes stay disjoint, so one touched class held lb and the drained one rb; keep now holds both

            # 5) remap any prior edge_to_class entries that pointed at
            # `drain_idx` to `keep_idx`. After this loop the invariant
            # "edge_to_class entries point at the surviving class id"
            # holds for every edge processed so far.
            for j in range(len(edge_to_class)):
                if edge_to_class[j] == drain_idx:
                    edge_to_class[j] = keep_idx

            edge_to_class.append(keep_idx)

            # NOTE on drained NDVs (drained.hll_ndv / drained.no_hll_ndv):
            # not folded here — the union-find stage builds class
            # MEMBERSHIP only. The NDV ingestion below (step 3) walks
            # every surviving class AND every binding, so any merged-
            # class NDV signal is re-derived from the provider — no risk
            # of dropping signal. The drained snapshot is dropped at the
            # end of this branch.

    # ---- Step 2: compact empty (merged-out) classes ----
    var compacted = _compact_classes(classes^, edge_to_class)

    # ---- Step 3: per-binding NDV ingestion via the provider ----
    # For each surviving class, iterate its bindings; for each binding,
    # query the provider and merge the signal into hll_ndv / no_hll_ndv
    # per _ingest_provider_value.
    for c_idx in range(len(compacted)):
        # The iteration is destructure-then-rebind: we need to iterate
        # the bindings (read) AND mutate hll_ndv/no_hll_ndv (write) on
        # the SAME class. We copy each binding's id and name into locals
        # first so the mutation doesn't conflict with the borrow on bindings.
        var n_bind = len(compacted[c_idx].bindings)
        for i in range(n_bind):
            var rel_id = compacted[c_idx].bindings[i].relation_id
            var col_name = String(compacted[c_idx].bindings[i].column_name)
            _ingest_provider_value(
                compacted[c_idx], rel_id, col_name, provider
            )

    return TdomGraph(compacted^, edge_to_class^)


# =============================================================================
# Composite-key NDV tracking per relation-pair bucket
# =============================================================================
#
# This section only computes the composite-NDV signal; the cost model in
# `optimizer_tdom_cost.mojo` consumes it to gate its FK-PK clamp
# (`_bucket_has_fkpk_signal`).
#
# Background: post-split (per-column edge split), a composite equi-join
# `(a, b) = (c, d)` between rels L and R lowers to TWO single-column
# JoinEdges that share the same (left_relation, right_relation) endpoint
# pair. Treating those two edges as
# INDEPENDENT denominator contributions (PRODUCT) is wrong — they're a
# correlated composite predicate on one relation pair (MAX-within-bucket
# is the right algebra). MAX-within-bucket alone has a second-order gap:
# without an FK-PK upper-bound clamp a composite step (lineitem⋈partsupp
# in TPC-H Q9) is over-estimated, which can push the join order to a
# worse (bushy) plan.
#
# This section's job is to expose the signal the clamp needs:
#
#   For each relation-pair bucket (a "bucket" = the set of bridging edges
#   that connect rels (min_rel, max_rel) in the same equi-join cluster),
#   for each rel that participates in the bucket:
#
#       composite_NDV[rel] = min(prod_i(single_col_NDV_i), |rel|)
#
#   where the product is over the columns of `rel` that appear in any
#   bridging edge of the bucket. The min(.., |rel|) cap is the structural
#   upper bound: |rel| rows cannot have more than |rel| distinct
#   (composite) values.
#
# Why this is the right FK-PK signal: when `composite_NDV[rel] == |rel|`,
# every row of `rel` is unique on the composite key — that is the PK side
# of an FK-PK relationship (a DuckDB MSc thesis §5.3). The cost model gates
# the clamp `est = min(est, max(|L|, |R|))` on this predicate. The signal is
# approximate (the single-col-NDV product is an upper bound on the true
# composite NDV under independence; correlated columns produce lower true
# NDV) — so the heuristic over-detects PK on the side whose row count is
# >> the product. `_bucket_has_fkpk_signal` therefore also requires the PK
# side's bucket columns to carry `from_hll=True` NDVs.
#
# Mirrors DuckDB's `cardinality_estimator.cpp:MultiplyDenominator` +
# `EstimateCrossProduct` + `EstimateFilteredCardinality`. DuckDB uses
# catalog-PK metadata; we use composite-NDV-from-stats as the equivalent.
#
# Encapsulation: this module is optimizer-internal; the trait-bound
# `P: ColumnStatsProvider` keeps the production / test dispatch surface
# unchanged. No UnsafePointer crosses any boundary.
# =============================================================================


struct PairBucket(Movable, Copyable):
    """One relation-pair bucket of bridging edges.

    A bucket groups bridging edges by their unordered endpoint pair
    `(rel_a, rel_b)` where `rel_a < rel_b` is the canonical ordering. A
    bucket of size >= 2 corresponds to a (potentially correlated)
    composite predicate between rel_a and rel_b; a bucket of size == 1
    is a single-column equi-join (the legacy shape).

    Fields:
      * `rel_a`, `rel_b` — the unordered endpoint pair, with
        `rel_a < rel_b` enforced by `build_pair_buckets`. Both are dense
        0-based relation ids assigned at `extract_join_chain` time.
      * `edge_indices` — `len(chain.edges)`-indexed slot ids of the
        bridging edges in this bucket, in INSERTION ORDER (do
        not re-sort).

    Multi-key composite edges (`len(left_keys) > 1`) are NOT bucketed —
    they enter the `_max_ndv_across_keys` legacy fallback path. This
    only models per-column-split edges (`len(left_keys) == 1`).

    Movable + Copyable — Copyable is required because `List[PairBucket]`
    is the natural return shape from `build_pair_buckets`, and Mojo
    1.0.0b1 `List[T]` requires `T: Copyable`. Fields are POD-shaped
    (two Ints + List[Int]) so the auto-synthesized copy is cheap.
    """

    var rel_a: Int
    var rel_b: Int
    var edge_indices: List[Int]

    @always_inline
    def __init__(
        out self,
        rel_a: Int,
        rel_b: Int,
        var edge_indices: List[Int],
    ):
        # Invariant: rel_a <= rel_b. Caller is responsible for sorting;
        # `build_pair_buckets` always emits in canonical order.
        self.rel_a = rel_a
        self.rel_b = rel_b
        self.edge_indices = edge_indices^

    @always_inline
    def copy(self) -> Self:
        var ei = List[Int]()
        for i in range(len(self.edge_indices)):
            ei.append(self.edge_indices[i])
        return Self(self.rel_a, self.rel_b, ei^)

    @always_inline
    def contains_relation(self, rel_id: Int) -> Bool:
        """True iff `rel_id` is one of the bucket's two endpoints."""
        return rel_id == self.rel_a or rel_id == self.rel_b

    @always_inline
    def size(self) -> Int:
        """Number of bridging edges in this bucket. A composite key
        between rel_a and rel_b produces `size() >= 2`."""
        return len(self.edge_indices)


def build_pair_buckets(imm chain: JoinChain) -> List[PairBucket]:
    """Group all per-column bridging edges by `(min(lr,rr), max(lr,rr))`.

    Iterates `chain.edges` in INSERTION ORDER
    and bins each single-key edge into a bucket keyed by the canonical
    unordered endpoint pair. Multi-key composite edges
    (`len(left_keys) > 1` or `len(right_keys) > 1`) are explicitly
    skipped — they don't participate in composite-NDV tracking because
    the per-column NDV signal is unavailable at the bucket layer (the
    legacy `_max_ndv_across_keys` fallback handles them).

    Returns: `List[PairBucket]` in the order each pair was first seen.
    Per-bucket `edge_indices` lists preserve insertion order.

    Complexity: O(n_edges * n_buckets) ≤ O(n_edges^2). For Q9's 6 edges
    this is ~36 work units. Negligible. Tests must not depend on
    pair-bucket ordering across runs (insertion-order is deterministic
    per-chain but not stable across schema-level reorderings).
    """
    var out = List[PairBucket]()
    for e_idx in range(len(chain.edges)):
        ref e = chain.edges[e_idx]
        # Multi-key composite edges enter the legacy fallback path; we
        # model only per-column-split.
        if len(e.left_keys) > 1 or len(e.right_keys) > 1:
            continue
        var a = e.left_relation
        var b = e.right_relation
        var lo = a if a < b else b
        var hi = b if a < b else a
        # Find or create the bucket for (lo, hi).
        var found = -1
        for j in range(len(out)):
            if out[j].rel_a == lo and out[j].rel_b == hi:
                found = j
                break
        if found < 0:
            var ei = List[Int]()
            ei.append(e_idx)
            out.append(PairBucket(lo, hi, ei^))
        else:
            out[found].edge_indices.append(e_idx)
    return out^


@always_inline
def _column_for_relation_in_edge(
    imm edge: JoinEdge, rel_id: Int
) -> String:
    """Return the column name belonging to `rel_id` in this single-key
    edge. Defensive: returns empty string if `rel_id` is neither
    endpoint (shouldn't happen on a well-formed bucket lookup).

    Precondition: `edge` is a per-column-split edge (`len(left_keys)`
    and `len(right_keys)` are both 1). `build_pair_buckets` enforces
    this by construction.
    """
    if edge.left_relation == rel_id:
        return String(edge.left_keys[0])
    if edge.right_relation == rel_id:
        return String(edge.right_keys[0])
    return String("")


def composite_ndv_for_relation[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm bucket: PairBucket,
    rel_id: Int,
    imm provider: P,
) -> Int:
    """Compute composite NDV for `rel_id` across the bucket's bridging
    edges.

    Algorithm (purely additive, no cost-model side-effects):

        ndv_product = 1
        seen_cols = []   # dedup per (rel, column) — repeated single-column
                         # bridging edges shouldn't multiply more than once
        for e_idx in bucket.edge_indices:
            col = column_for_relation_in_edge(edge, rel_id)
            if col in seen_cols:
                continue
            seen_cols.add(col)
            ndv_i = provider.distinct_count_for(rel_id, col).ndv
            ndv_product = saturating_mul(ndv_product, ndv_i)
        return min(max(ndv_product, 1), |rel_id|)

    Where `|rel_id|` is the relation's post-filter cardinality (from
    `JoinRelation.cardinality`, mirroring DuckDB's
    `cardinality_after_filters` per `relation_statistics_helper.cpp:110`).

    The saturating multiply guards against Int64 overflow on
    pathological 3+ way composites at SF=100. We saturate at
    `Int.MAX / 2` so the subsequent `min(.., |rel|)` still does the
    right thing (any saturated value is much larger than any plausible
    cardinality and gets clamped to `|rel|`).

    Defensive behavior:
      * If `rel_id` is not in the bucket (not rel_a / rel_b): return 1
        (cost-model identity — no multiplicative effect).
      * If `bucket.size() == 0`: return 1 (vacuous bucket — shouldn't
        happen via `build_pair_buckets` but be safe).
      * If `rel_id` is out of `chain.relations` range: return 1.

    The FK-PK clamp gate uses this to detect PK side: `composite_ndv == |rel|`
    flags `rel` as PK on the bucket's composite key. The signal is
    approximate (independence assumption); see module-header rationale.
    """
    if not bucket.contains_relation(rel_id):
        return 1
    if rel_id < 0 or rel_id >= len(chain.relations):
        return 1
    if bucket.size() == 0:
        return 1

    # Saturating-multiply cap. INT_MAX/2 leaves plenty of headroom for
    # subsequent comparisons without risking signed overflow on a
    # later `min(.., |rel|)`. Int is 64-bit on every supported target.
    var SAT_CAP: Int = 4_611_686_018_427_387_903  # ~Int.MAX / 2

    var seen_cols = List[String]()
    var ndv_product: Int = 1
    for i in range(bucket.size()):
        var e_idx = bucket.edge_indices[i]
        # Defensive: edge indices come from build_pair_buckets which
        # only enumerates valid chain.edges slots; bounds-check anyway.
        if e_idx < 0 or e_idx >= len(chain.edges):
            continue
        ref edge = chain.edges[e_idx]
        var col = _column_for_relation_in_edge(edge, rel_id)
        # An empty column name would indicate a build_pair_buckets
        # invariant violation; skip defensively.
        if col.byte_length() == 0:
            continue
        # Dedup: if a bucket contains two edges that BOTH reference the
        # SAME column of `rel_id` (e.g. self-join shapes), the column's
        # NDV should multiply only once into the composite.
        var already_seen = False
        for j in range(len(seen_cols)):
            if seen_cols[j] == col:
                already_seen = True
                break
        if already_seen:
            continue
        seen_cols.append(col)
        var v = provider.distinct_count_for(rel_id, col)
        # Saturating multiply. Once we hit SAT_CAP, stay there — the
        # subsequent `min(.., |rel|)` will clamp to the relation size.
        if ndv_product >= SAT_CAP or v.ndv >= SAT_CAP:
            ndv_product = SAT_CAP
            continue
        # Overflow guard: if the next multiply would exceed SAT_CAP,
        # clamp instead of overflowing.
        if v.ndv > 0 and ndv_product > SAT_CAP // v.ndv:
            ndv_product = SAT_CAP
            continue
        ndv_product = ndv_product * v.ndv

    var rel_card = chain.relations[rel_id].cardinality
    if rel_card < 1:
        # Defensive: cost-model identity. A 0-row relation has a
        # composite NDV of 0; but downstream cost paths expect >= 1.
        rel_card = 1
    if ndv_product < 1:
        # A provider NDV of 0 (one that bypasses the ColumnStatsValue
        # clamp) makes the product 0; floor it like `rel_card`.
        ndv_product = 1
    if ndv_product > rel_card:
        return rel_card
    return ndv_product


def composite_ndv_pk_side[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm bucket: PairBucket,
    imm provider: P,
) -> Int:
    """Return the relation_id whose composite_NDV equals its cardinality
    in this bucket — the FK-PK PK-side candidate — or -1 if neither
    side qualifies, or -2 if BOTH sides qualify (ambiguous).

    A bucket is PK-qualified on `rel` when
    `composite_ndv_for_relation(rel) == |rel|`. `_bucket_has_fkpk_signal`
    (`optimizer_tdom_cost.mojo`) gates the FK-PK clamp on this signal.

    Return values:
      *  rel_a / rel_b — exactly one side is PK-qualified.
      * -1            — neither side is PK-qualified (multi-set
                         composite; no FK-PK signal).
      * -2            — both sides are PK-qualified (e.g. a 1-to-1
                         join, or the heuristic over-detects because
                         the single-col-NDV product saturates at |rel|
                         on the larger side). The clamp gate accepts
                         -2 when either side's bucket columns carry
                         `from_hll=True` NDVs.

    A bucket endpoint outside `chain.relations` answers -1 (no FK-PK
    signal); `build_pair_buckets` never emits one.

    It surfaces this as a convenience. It does NOT alter cost
    model behavior; pure read.
    """
    var n_rel = len(chain.relations)
    if bucket.rel_a < 0 or bucket.rel_a >= n_rel:
        return -1
    if bucket.rel_b < 0 or bucket.rel_b >= n_rel:
        return -1
    var ndv_a = composite_ndv_for_relation(chain, bucket, bucket.rel_a, provider)
    var ndv_b = composite_ndv_for_relation(chain, bucket, bucket.rel_b, provider)
    var card_a = chain.relations[bucket.rel_a].cardinality
    var card_b = chain.relations[bucket.rel_b].cardinality
    var a_is_pk = ndv_a == card_a
    var b_is_pk = ndv_b == card_b
    if a_is_pk and b_is_pk:
        return -2
    if a_is_pk:
        return bucket.rel_a
    if b_is_pk:
        return bucket.rel_b
    return -1
