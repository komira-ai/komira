# =============================================================================
# TDOM cost computation — estimate_with_tdom + bridging-edge enumeration
# =============================================================================
#
# A two-card cost function for a DP join enumerator's (left_set, right_set)
# cost lookups. In this tree only tests call `estimate_with_tdom`: DPccp
# (`optimizer_dpccp._cost_for_pair`) uses the one-set
# `optimizer_tdom_card.estimate_cardinality_with_set` instead. The `TdomGraph`
# data structure + `build_tdom_graph` live in sibling file `optimizer_tdom.mojo`.
# This module closes the loop: given a `TdomGraph` + the candidate joining pair,
# compute the denominator product across bridging edges, DEDUPED by
# equivalence class (the load-bearing win — DuckDB `cardinality_estimator.cpp:336-341`).
#
# Mirrors DuckDB's
#   - `cardinality_estimator.cpp:285-401` (`GetDenominator`) — the sort by
#     class TDOM (decreasing) + redundant-edge skip via seen_classes.
#   - `cardinality_estimator.cpp:336-341` — the `IsSubset` / bridging predicate
#     replicated here as `edge_bridges`.
#
# Inputs:
#   * `TdomGraph` (from `optimizer_tdom.mojo`) — per-equivalence-class TDOMs
#     + `edge_to_class` mapping.
#   * `JoinChain` (from `optimizer_reorder.mojo`) — relations + edges (the
#     edge geometry the chain extractor emitted).
#   * `left_set`, `right_set` (`RelationSet`) — the candidate joining pair
#     from a DP enumerator.
#   * `left_card`, `right_card` (`Int`) — cumulative cardinalities for each
#     side, supplied by the DP table entries.
#   * `provider` (`P: ColumnStatsProvider`) — required for the leftover-
#     composite branch (edge with `edge_to_class[i] == -1`), where the
#     legacy `_max_ndv_across_keys` denominator is reconstructed from per-
#     column NDV signals. For the common per-class path the provider is
#     not consulted (the TDOM is already cached on the class).
#
# Outputs:
#   * `Int` — the estimated join cardinality. Identical units as the legacy
#     `estimate_join_cardinality_with_ndv`. Only tests call it: DPccp's
#     `_cost_for_pair` takes join_card from `estimate_cardinality_with_set`
#     and sums `pair_cost = join_card + left_cost + right_cost` itself.
#
# Tie-break determinism:
#   Within the primary TDOM-decreasing sort, ties resolve by
#   `(edge.left_relation, edge.right_relation, edge_index)` ASCENDING. Mojo's
#   stdlib sort is implementation-dependent; we use an explicit insertion
#   sort with the tuple key so consumers get the same `seen_classes` order
#   across builds. Test #5 in `test_optimizer_tdom_estimate_with_tdom.mojo`
#   pins this.
#
# Saturating numerator:
#   Option (b) — NO in-function saturation. The numerator
#   `left_card * right_card` can in principle overflow Int on SF=100+ data
#   (1e9 * 1e9 = 1e18 is near the Int64 edge), and nothing clamps it here or
#   after the divide: `estimate_join_cardinality_with_ndv` in
#   `optimizer_reorder.mojo` saturates only its own product. Mojo's Int is
#   64-bit; the test suite includes a near-overflow case (#7) for a product
#   that still fits Int64. To admit larger products, saturate at
#   `REORDER_CARDINALITY_MAX` here the way `optimizer_reorder` does.
#
# Encapsulation rule: package-internal module; no UnsafePointer
# crosses any boundary. The trait-bound `P: ColumnStatsProvider` keeps the
# leftover-composite path closed under the same dispatch surface that
# `build_tdom_graph` uses, so test injection works through one interface.
# =============================================================================

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
# edge_bridges — DuckDB IsSubset semantics
# =============================================================================


@always_inline
def edge_bridges(
    imm edge: JoinEdge,
    imm left_set: RelationSet,
    imm right_set: RelationSet,
) -> Bool:
    """Return True iff the edge bridges (left_set, right_set).

    An edge BRIDGES the candidate joining pair iff one endpoint is in
    `left_set` and the other is in `right_set`. This is the exact analog
    of DuckDB `cardinality_estimator.cpp:336-341` `IsSubset` semantics
    for a 2-endpoint edge.

    # CONTRACT:
    #   An edge with BOTH endpoints in left_set (or both in right_set)
    #   does NOT bridge — it's internal to one subgraph and already
    #   counted in the subgraph's cumulative cost. An edge with NEITHER
    #   endpoint in either set is unreachable from this candidate pair.
    #   Test #4 in `test_optimizer_tdom_estimate_with_tdom.mojo` covers
    #   all four boundary cases.

    `@always_inline` because every cost lookup calls this for every edge
    of the candidate pair (n_edges * n_pairs per chain under DP).
    """
    var l_in_left = left_set.contains(edge.left_relation)
    var l_in_right = right_set.contains(edge.left_relation)
    var r_in_left = left_set.contains(edge.right_relation)
    var r_in_right = right_set.contains(edge.right_relation)
    return (l_in_left and r_in_right) or (l_in_right and r_in_left)


# =============================================================================
# has_classes_for — fall-through gate
# =============================================================================


def has_classes_for(
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    imm left_set: RelationSet,
    imm right_set: RelationSet,
) -> Bool:
    """Return True iff at least one bridging edge has a non-(-1) class id.

    Fall-through gate for a cost caller: when False, the
    legacy `estimate_join_cardinality_with_ndv` path applies (e.g. a chain with
    all-leftover composite edges, or a candidate pair connected only by
    a composite). When True, `estimate_with_tdom` is the load-bearing
    denominator.

    This is a fast O(n_edges) scan; no allocation.
    """
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        if not edge_bridges(e, left_set, right_set):
            continue
        if tdom.class_for_edge(i) >= 0:
            return True
    return False


# =============================================================================
# _bridging_edge_tdom — bridging-edge cost contribution lookup
# =============================================================================


@always_inline
def _class_tdom_or_none(imm tdom: TdomGraph, edge_idx: Int) -> Int:
    """Return the class TDOM for an edge, or -1 if the edge is leftover
    composite (no class). -1 signals "use legacy max-NDV per-edge path"
    to `estimate_with_tdom`.

    The leftover-composite contribution is computed by the caller via the
    per-key provider lookup (see `_max_ndv_across_keys_for_edge`); this
    helper only reports the class-id status.
    """
    var c_idx = tdom.class_for_edge(edge_idx)
    if c_idx < 0:
        return -1
    # All compacted classes have non-negative TDOMs by construction (the
    # tdom() floor is 1; see optimizer_tdom.EquivalenceClass.tdom).
    return tdom.classes[c_idx].tdom()


# =============================================================================
# _max_ndv_across_keys_for_edge — leftover composite denominator (fallback)
# =============================================================================


def _max_ndv_across_keys_for_edge[
    P: ColumnStatsProvider, //
](
    imm edge: JoinEdge,
    imm provider: P,
) -> Int:
    """Compute MAX-NDV across an edge's keys via the provider.

    Mirrors `optimizer_reorder._max_ndv_across_keys` semantics but works
    through the `ColumnStatsProvider` trait so the leftover-composite
    branch in `estimate_with_tdom` doesn't need to pull TableStats out of
    JoinRelations. The provider's three-tier dispatch (Tier 1 parquet
    metadata → Tier 2 row count) supplies the NDV signal for every key,
    so this function always returns a value >= 1.

    Walks BOTH `edge.left_keys` and `edge.right_keys` because for a
    composite (la, lb) = (ra, rb) edge, the left and right keys can have
    different NDVs and the cost-model denominator should be the
    upper bound across all columns. This matches DuckDB's behavior for
    the multi-key fallback at `cardinality_estimator.cpp:387-397`.

    Trait-bound P so test `SyntheticColumnStatsProvider` works through
    the same path.
    """
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
        return 1
    return best


# =============================================================================
# _collect_and_sort_bridging — bridging-edge enumeration + TDOM-desc sort
# =============================================================================
#
# Returns a `List[Int]` of edge indices that bridge (left_set, right_set),
# sorted by `(class_tdom DESCENDING, left_relation ASCENDING,
# right_relation ASCENDING, edge_index ASCENDING)`. Leftover-composite
# edges (class_for_edge == -1) participate in the sort with TDOM = -1
# (LOWEST); they get processed AFTER all class-bearing edges, which means
# their fixed denominators apply on top of the dedupped class denominators.
# This ordering matches the DuckDB cost-model convention: dedup the
# strongest (largest-TDOM) class first, then accumulate the small TDOMs
# (which can each only reduce cost), then finally the leftover-composite
# legacy contributions.
#
# Insertion sort over typically <=6 bridging edges; O(n_edges^2) worst case.
# Total cost: O(n_edges^2) per cost-of-pair lookup, which is negligible
# next to DP enumeration (3^n) for n<=12.


def _collect_and_sort_bridging(
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    imm left_set: RelationSet,
    imm right_set: RelationSet,
) -> List[Int]:
    """Return bridging edge indices in cost-application order.

    Sort key (descending TDOM primary, then the deterministic tuple
    `(left_relation, right_relation, edge_index)` ASCENDING for ties):
    ensures the seen-class dedup picks the highest-TDOM equivalent edge
    first (DuckDB :336-341 invariant). Leftover-composite edges (class
    -1) carry sort key -1; they sort AFTER all class-bearing edges.

    # CONTRACT (tie-break determinism):
    #   Ties on TDOM resolve by (left_relation, right_relation,
    #   edge_index) ascending. Tested in #5 of
    #   `test_optimizer_tdom_estimate_with_tdom.mojo`.
    """
    var bridging = List[Int]()
    for i in range(len(chain.edges)):
        ref e = chain.edges[i]
        if edge_bridges(e, left_set, right_set):
            bridging.append(i)

    # Insertion sort: pull index `key_idx` (one of the edge ids in `bridging`)
    # into the correct slot among `bridging[:i]` per the 4-key tuple.
    for i in range(1, len(bridging)):
        var key_idx = bridging[i]
        var key_tdom = _class_tdom_or_none(tdom, key_idx)
        ref key_e_pin = chain.edges[key_idx]
        var key_lr = key_e_pin.left_relation
        var key_rr = key_e_pin.right_relation

        var j = i - 1
        while j >= 0:
            var cmp_idx = bridging[j]
            var cmp_tdom = _class_tdom_or_none(tdom, cmp_idx)
            ref cmp_e_pin = chain.edges[cmp_idx]
            var cmp_lr = cmp_e_pin.left_relation
            var cmp_rr = cmp_e_pin.right_relation

            # Want bridging[0..i] in DESCENDING TDOM, ASCENDING (lr, rr,
            # idx). So we shift cmp right if `cmp` should come AFTER `key`.
            var should_shift = False
            if cmp_tdom < key_tdom:
                # cmp has smaller TDOM → cmp goes right (after key).
                should_shift = True
            elif cmp_tdom == key_tdom:
                # tie on TDOM: smaller (lr, rr, idx) tuple goes left.
                if cmp_lr > key_lr:
                    should_shift = True
                elif cmp_lr == key_lr:
                    if cmp_rr > key_rr:
                        should_shift = True
                    elif cmp_rr == key_rr:
                        if cmp_idx > key_idx:
                            should_shift = True

            if should_shift:
                bridging[j + 1] = bridging[j]
                j -= 1
            else:
                break
        bridging[j + 1] = key_idx
    return bridging^


# =============================================================================
# _bucket_bridges — bucket-level analog of edge_bridges
# =============================================================================


@always_inline
def _bucket_bridges(
    imm bucket: PairBucket,
    imm left_set: RelationSet,
    imm right_set: RelationSet,
) -> Bool:
    """Return True iff the bucket bridges (left_set, right_set).

    A pair-bucket has a canonical (rel_a, rel_b) endpoint pair with
    `rel_a < rel_b`. Bucket bridges iff (rel_a in left and rel_b in
    right) OR (rel_a in right and rel_b in left). Equivalent to
    `edge_bridges` applied to any edge in the bucket (all share the
    same canonical endpoints by construction in `build_pair_buckets`).
    """
    var a_in_left = left_set.contains(bucket.rel_a)
    var a_in_right = right_set.contains(bucket.rel_a)
    var b_in_left = left_set.contains(bucket.rel_b)
    var b_in_right = right_set.contains(bucket.rel_b)
    return (a_in_left and b_in_right) or (a_in_right and b_in_left)


# =============================================================================
# _all_bucket_cols_have_hll_signal — FK-PK clamp gating
# =============================================================================


def _all_bucket_cols_have_hll_signal[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm bucket: PairBucket,
    rel_id: Int,
    imm provider: P,
) -> Bool:
    """Return True iff EVERY column of `rel_id` participating in the
    bucket's bridging edges has `from_hll=True` (Tier-1 / writer-side
    NDV signal).

    FK-PK clamp gate: the clamp `est <=
    max(L, R)` is the FK-PK upper bound. The composite-NDV signal
    (`composite_ndv == |rel|`) is a heuristic proxy for PK-ness. Under
    Tier-2 (row-count fallback), `NDV(col) == cardinality` is
    TRIVIALLY satisfied for every column — every relation looks
    "PK-on-every-column". To avoid spuriously clamping every join
    pair, the gate requires the PK signal to be backed by Tier-1
    (`from_hll=True`) NDV evidence on the qualifying side.

    Defensive: returns False if any column is missing the signal,
    if the bucket is empty, or if `rel_id` is out of range. The
    conservative default keeps the cost model in its pre-clamp regime
    when the signal is weak.

    Trait-bound P matches the rest of the cost module so test
    SyntheticColumnStatsProvider feeds through one surface.
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
        # Identify rel_id's column in this single-key edge.
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
    # If we never observed any column, the signal is vacuous → False.
    if len(seen_cols) == 0:
        return False
    return True


# =============================================================================
# _bucket_has_fkpk_signal — composite FK-PK detection (pair-bucket signal + Tier-1
#                            gate)
# =============================================================================


def _bucket_has_fkpk_signal[
    P: ColumnStatsProvider, //
](
    imm chain: JoinChain,
    imm bucket: PairBucket,
    imm provider: P,
) -> Bool:
    """Return True iff this bucket has a Tier-1-backed FK-PK signal.

    Two-step gate:
      1. `composite_ndv_pk_side(...)` returns rel_a / rel_b
         (>= 0) when exactly one side has `composite_NDV == |rel|`,
         or -2 when BOTH qualify. -1 means neither qualifies.
      2. The Tier-1 gate: the qualifying side (or at least one
         side under -2 ambiguity) must have ALL its bucket columns
         backed by `from_hll=True` (Tier-1 / writer-side NDV signal).
         This rejects the Tier-2 row-count-fallback case where
         `NDV == |rel|` is trivially satisfied (and the heuristic is
         unreliable).

    The clamp `est = min(est, max(L, R))` is gated on True here. The
    clamp is algebraically valid whenever AT
    LEAST ONE side is PK — we don't need to know WHICH side. For -2
    (both qualify), Tier-1 backing on either side is sufficient.
    """
    var pk_side = composite_ndv_pk_side(chain, bucket, provider)
    if pk_side == -1:
        return False
    if pk_side == -2:
        # Both sides qualify. Require Tier-1 backing on AT LEAST ONE
        # side — the contract that -2 still clamps survives
        # any-side-evidence.
        if _all_bucket_cols_have_hll_signal(
            chain, bucket, bucket.rel_a, provider
        ):
            return True
        return _all_bucket_cols_have_hll_signal(
            chain, bucket, bucket.rel_b, provider
        )
    # pk_side >= 0: exactly one side. That side must have Tier-1
    # backing across all its bucket columns.
    return _all_bucket_cols_have_hll_signal(
        chain, bucket, pk_side, provider
    )


# =============================================================================
# estimate_with_tdom — the load-bearing cost function
# =============================================================================


def estimate_with_tdom[
    P: ColumnStatsProvider, //
](
    imm tdom: TdomGraph,
    imm chain: JoinChain,
    imm left_set: RelationSet,
    imm right_set: RelationSet,
    left_card: Int,
    right_card: Int,
    imm provider: P,
) -> Int:
    """Estimate join cardinality using the TDOM equivalence-set
    denominator, with MAX-within-relation-pair-bucket algebra and the
    FK-PK upper-bound clamp.

    Algorithm (mirrors DuckDB
    `cardinality_estimator.cpp:285-401` + `MultiplyDenominator` +
    `EstimateCrossProduct` / `EstimateFilteredCardinality`):

      1. Enumerate bridging edges via `edge_bridges` and sort
         by (TDOM-DESC, lr-ASC, rr-ASC, idx-ASC) for deterministic
         dedup.
      2. Walk sorted edges. For each edge:
         * If class == -1 (leftover composite): contribute
           `_max_ndv_across_keys_for_edge(edge, provider)` as a flat
           multiplier into `composite_denom` (legacy path).
         * Else if class already seen: SKIP (DuckDB :336-341 dedup —
           THE redundant-edge skip).
         * Else: classify the edge by its canonical relation-pair
           bucket `(min(lr,rr), max(lr,rr))` and record the class TDOM
           in the bucket's running MAX. Mark class as seen.
      3. Aggregate denominator: `denom = composite_denom *
         prod_buckets(MAX_TDOM_in_bucket)`. The MAX-within-bucket is
         the algebra fix for a correlated composite predicate;
         the PRODUCT-across-buckets is the Q5-preserving independence
         assumption (uncorrelated equivalence classes between
         different relation pairs).
      4. `est = max(1, (lc * rc) // denom)`.
      5. FK-PK upper-bound clamp: walk all pair-buckets that bridge
         (left_set, right_set); if ANY bucket has a Tier-1-backed
         composite-NDV PK signal (per `_bucket_has_fkpk_signal`),
         clamp `est <= max(lc, rc)`. The clamp implements DuckDB's
         `EstimateFilteredCardinality` FK-PK ceiling.

    # CONTRACT (bucket algebra):
    #   Before: dedup-by-class + PRODUCT across all classes
    #     → independent-NDV assumption between classes that share a
    #     relation pair (the Q9 bug — l_partkey∼ps_partkey and
    #     l_suppkey∼ps_suppkey are correlated, not independent).
    #   Now: MAX-within-bucket × PRODUCT-across-buckets
    #     → correlation-aware aggregation. The redundant-edge SKIP
    #     by class survives because the dedup walks ALL classes
    #     across all buckets ONCE before assigning to a bucket; a
    #     class that appears in multiple buckets contributes only via
    #     its first-occurrence bucket (the highest-TDOM edge per the
    #     sort).

    # CONTRACT (FK-PK clamp gating):
    #   The clamp `est <= max(L, R)` fires only when at least one
    #   bridging bucket has a Tier-1-backed PK signal. Tier-2
    #   (row-count fallback) NDV trivially equals cardinality, so the
    #   gate rejects that case to avoid spuriously clamping Tier-2-only
    #   join pairs.

    # CONTRACT (saturation policy):
    #   Numerator can overflow Int64 on SF=100+ data; nothing saturates it
    #   (see the module header). The product must fit Int64.

    Trait-bound P so test SyntheticColumnStatsProvider feeds through
    one surface (matches `build_tdom_graph[P: ColumnStatsProvider, //]`).

    Complexity: O(n_bridging_edges^2 + n_buckets) — dominated by the
    sort, with an O(n_buckets) clamp pass at the tail. For Q5/Q9 with
    ~6-8 edges and ~5 buckets this is < 100 ops; negligible vs DP
    enumeration.
    """
    var bridging = _collect_and_sort_bridging(
        tdom, chain, left_set, right_set
    )

    # Aggregate denominator by relation-pair bucket.
    # Parallel arrays `bucket_keys` (canonical UInt64 packed
    # `(rel_lo << 32) | rel_hi`) and `bucket_max_tdom` (MAX of class
    # TDOMs that first-occur for this bucket).
    var seen_classes = List[Int]()
    var bucket_keys = List[UInt64]()
    var bucket_max_tdom = List[Int]()
    var composite_denom: Int = 1

    for i in range(len(bridging)):
        var e_idx = bridging[i]
        var c_idx = tdom.class_for_edge(e_idx)

        if c_idx < 0:
            # Leftover composite — flat multiplier (`build_pair_buckets`
            # explicitly skips multi-key composite edges from
            # bucketing; they enter the legacy fallback path here).
            ref edge_lc = chain.edges[e_idx]
            var contribution = _max_ndv_across_keys_for_edge(
                edge_lc, provider
            )
            composite_denom *= contribution
            continue

        # Class-level dedup (DuckDB :336-341). A class contributes at
        # most once, via the highest-TDOM edge by sort order.
        var already_seen = False
        for j in range(len(seen_classes)):
            if seen_classes[j] == c_idx:
                already_seen = True
                break
        if already_seen:
            continue
        seen_classes.append(c_idx)

        # Route this class into its relation-pair bucket. MAX-within-
        # bucket (correlated composite); PRODUCT-across-buckets
        # (independent equivalence classes between different pairs).
        ref edge = chain.edges[e_idx]
        var lr = edge.left_relation
        var rr = edge.right_relation
        var lo = lr if lr < rr else rr
        var hi = rr if lr < rr else lr
        var key = (UInt64(lo) << UInt64(32)) | UInt64(hi)
        var tdom_val = tdom.classes[c_idx].tdom()

        var found = -1
        for j in range(len(bucket_keys)):
            if bucket_keys[j] == key:
                found = j
                break
        if found < 0:
            bucket_keys.append(key)
            bucket_max_tdom.append(tdom_val)
        else:
            if tdom_val > bucket_max_tdom[found]:
                bucket_max_tdom[found] = tdom_val  # cov: unreachable bridging is sorted by TDOM descending, so the first class in a bucket holds its maximum

    var denom: Int = composite_denom
    for j in range(len(bucket_max_tdom)):
        denom *= bucket_max_tdom[j]
    if denom <= 0:
        denom = 1

    # Numerator: no saturation in this function.
    var lc = left_card
    var rc = right_card
    if lc < 1:
        lc = 1
    if rc < 1:
        rc = 1
    var numerator = lc * rc

    var est = numerator // denom
    if est < 1:
        est = 1

    # ----- FK-PK upper-bound clamp -----
    # Walk all chain buckets; if ANY bridges this candidate pair AND
    # carries a Tier-1-backed PK signal, clamp est to max(lc, rc).
    # `build_pair_buckets` already skips multi-key composite
    # edges, so the bucket set here corresponds to the per-column-split
    # edge geometry of the chain extractor.
    var all_buckets = build_pair_buckets(chain)
    var pk_clamp_fires = False
    for k in range(len(all_buckets)):
        ref bucket = all_buckets[k]
        if not _bucket_bridges(bucket, left_set, right_set):
            continue
        if _bucket_has_fkpk_signal(chain, bucket, provider):
            pk_clamp_fires = True
            break

    if pk_clamp_fires:
        var bound = lc if lc > rc else rc
        if est > bound:
            est = bound

    return est
