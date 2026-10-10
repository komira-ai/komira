# =============================================================================
# ColumnStatsProvider — runtime three-tier per-column NDV provider
# =============================================================================
#
# Join-order cost-model foundation. Mirrors DuckDB's runtime three-tier
# cardinality-estimator mechanism for per-column NDV signal:
#
#   Tier 1 (HLL-derived NDV)         — writer-emitted distinct_count from
#                                       table_stats (DuckDB equivalent:
#                                       `BaseStatistics::DistinctStats` populated
#                                       at scan time with HLL register
#                                       sketches).
#   Tier 2 (row-count heuristic)     — fall through to relation cardinality
#                                       (DuckDB equivalent:
#                                       `relation_statistics_helper.cpp:110`
#                                       returns `DistinctCount(
#                                          cardinality_after_filters, false)`).
#   Tier 3 (runtime sampling)        — future scope. Constant declared
#                                       here but unreachable.
#
# Why this lives in the optimizer (and not engine-internal): join-order
# enumeration (DPccp, greedy) runs at plan-compile time. The provider
# is consumed by the TDOM modules (`optimizer_tdom`, `optimizer_tdom_card`,
# `optimizer_tdom_cost`) — optimizer rules. A DPccp enumerator
# (`optimizer_dpccp`) is designed to consume it too; it is not in this tree.
#
# The trait is the load-bearing behavioral contract: `distinct_count_for`
# ALWAYS returns a value (no Optional). Callers do not need to handle
# "no signal" — Tier 2 / Tier 3 fall-through guarantees a meaningful
# answer for every (relation, column) query.
#
# Empirical citation: DuckDB's `parquet_statistics.cpp`
# has ZERO `SetDistinctCount` calls; `BaseStatistics::distinct_count`
# defaults to 0; `relation_statistics_helper.cpp:110` is the
# row-count-as-NDV fall-through. For Q5's
# {customer.c_nationkey, supplier.s_nationkey, nation.n_nationkey}
# equivalence class, the MIN(150K, 10K, 25) = 25 — exactly the right
# TDOM ceiling.
#
# Encapsulation rule: the trait + structs are optimizer-internal. No
# UnsafePointer crosses any boundary; the slab borrow is a typed
# `ref [origin] Slab[JoinRelation]`.
# =============================================================================

from std.collections import Dict

from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
    STATS_SOURCE_SYNTHETIC_ROW_COUNT,
)
from .optimizer_reorder import JoinRelation


# =============================================================================
# _leaf_raw_row_count — the join-key DOMAIN proxy
# =============================================================================


def _leaf_raw_row_count(imm plan: LogicalPlan) -> Int:
    """Walk a chain leaf (Scan / Filter(Scan) / Project(Scan)) down to its base
    SCAN and return the RAW (pre-filter) footer `row_count` — the join-key DOMAIN
    size. Returns -1 when no scan / row_count is reachable (a SEMI-join barrier
    leaf, or a scan with no footer row_count), so the Tier-2 caller falls back to
    the post-filter `relation.cardinality`.

    Domain proxy: a WHERE filter reduces a relation's
    ROW COUNT (`relation.cardinality` = cardinality_after_filters), but a join key
    still ranges over the ORIGINAL, un-filtered key DOMAIN. For an FK-PK join
    `lineitem ⋈ orders WHERE o_orderdate IN 1994`, the orderkey equivalence-class
    TDOM must be the domain (~1.5M distinct orders), NOT the post-filter 135K —
    otherwise `|l|·|o_filtered| / TDOM` cancels the filter (6M·135K/135K = 6M) and
    the fact-side reduction of threading lineitem through the date-filtered orders
    is INVISIBLE to the cost model. The raw footer row_count is that domain proxy,
    and it is already visible on the scan (the scan reader threads it off the footer)."""
    if plan.tag == PLAN_SCAN and plan._scan:
        ref sd = plan._scan.value()[]
        if sd.row_count:
            return sd.row_count.value()
        return -1
    if plan.tag == PLAN_FILTER and plan._filter:
        return _leaf_raw_row_count(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT and plan._project:
        return _leaf_raw_row_count(plan._project.value()[].child[])
    return -1


# =============================================================================
# ColumnStatsSource — provenance flag for the returned NDV value
# =============================================================================
#
# Mirrors the three-tier dispatch outcome. Callers that want to weight
# the signal (e.g. discount a row-count fallback in a cost-model
# tie-breaker) read this field.

comptime TIER_PARQUET_METADATA: UInt8 = 0
comptime TIER_ROW_COUNT_HEURISTIC: UInt8 = 1
# Future scope: runtime sampling Tier 3. Declared here so consumers can
# pattern-match all 3 outcomes without rev-bumping when sampling lands.
# Currently unreachable from DefaultColumnStatsProvider.
comptime TIER_SAMPLED: UInt8 = 2


# =============================================================================
# ColumnStatsValue — the three-tier dispatch result
# =============================================================================


struct ColumnStatsValue(Movable, Copyable, ImplicitlyCopyable):
    """The result of a `ColumnStatsProvider.distinct_count_for` query.

    Fields:
        ndv: The per-column distinct count. Always >= 1 (cost-model
            safe: avoids divide-by-zero in `(L*R)/max(NDV(lk), NDV(rk))`
            formulas).
        from_hll: True iff the value originated from a writer-emitted
            HLL-derived NDV (Tier 1). False for row-count fallback or
            sampled (Tier 2 / 3). The TDOM cost model (`estimate_with_tdom`) may
            apply a confidence discount when `from_hll=False`.
        source: Which tier produced this value. See TIER_* constants.

    Trait bounds: `ImplicitlyCopyable` so that providers can return
    bare values out of a `Dict[..., ColumnStatsValue]` lookup without
    explicit `.copy()` ceremony at every call site. All fields are
    POD (Int / Bool / UInt8) so copy is byte-trivial.
    """

    var ndv: Int
    var from_hll: Bool
    var source: UInt8

    @always_inline
    def __init__(out self, ndv: Int, from_hll: Bool, source: UInt8):
        # Clamp to >= 1 for cost-model safety.
        var safe_ndv = ndv
        if safe_ndv < 1:
            safe_ndv = 1
        self.ndv = safe_ndv
        self.from_hll = from_hll
        self.source = source

    @always_inline
    def copy(self) -> Self:
        return Self(self.ndv, self.from_hll, self.source)


# =============================================================================
# ColumnStatsProvider — trait contract
# =============================================================================


trait ColumnStatsProvider:
    """Per-column NDV signal provider for join-order cost models.

    The load-bearing behavioral contract: `distinct_count_for` ALWAYS
    returns a `ColumnStatsValue` (no Optional). Implementations
    guarantee a meaningful answer for every (relation_id, column_name)
    query via three-tier dispatch (Parquet metadata → row-count
    heuristic → sampled).

    This trait is what distinguishes the design from its predecessor, which had
    an Optional return that pushed the "no signal" branch onto every
    caller. The three-tier guarantee makes that unnecessary — and
    matches DuckDB's `relation_statistics_helper.cpp:110` fall-through
    exactly.

    Callers (the TDOM modules; a DPccp cost model, not in this tree) consume
    the returned `ColumnStatsValue.ndv` directly. The `from_hll` /
    `source` fields are advisory (used by the cost model's confidence
    discounting).
    """

    def distinct_count_for(self, relation_id: Int, column_name: String) -> ColumnStatsValue:
        """Return the per-column NDV for `(relation_id, column_name)`.

        ALWAYS returns a meaningful value (no Optional). The three-tier
        dispatch in `DefaultColumnStatsProvider` guarantees coverage;
        synthetic / test providers must uphold the same contract.

        `relation_id` is the dense 0..n-1 id assigned at
        `extract_join_chain` time (equivalent to the relation's
        position in `JoinChain.relations`). `column_name` is the
        unqualified column name as it appears in the leaf scan's
        schema (qualified-side prefixes are stripped at the
        cost-model boundary).
        """
        ...


# =============================================================================
# DefaultColumnStatsProvider — three-tier dispatch over a JoinChain
# =============================================================================


struct DefaultColumnStatsProvider[origin: Origin[mut=False]](
    ColumnStatsProvider, Movable, Deinitable
):
    """Production three-tier dispatch provider.

    Construct with a borrowed ref to `JoinChain.relations`. The slab's
    lifetime is encoded in the `origin` parameter — the provider
    cannot outlive the chain (compiler-enforced via the
    `ref [origin] Slab[JoinRelation]` field type).

    Tier dispatch (in priority order):
        Tier 1 — Parquet metadata: consult
            `relation.table_stats.column_distinct_count(column_name)`.
            On hit, return
            `ColumnStatsValue(ndv=hit, from_hll=<provenance>,
                              source=TIER_PARQUET_METADATA)`.

            from_hll provenance: the
            `from_hll` flag now reflects ACTUAL register-merge
            provenance, not "Tier-1 won". It is True iff the
            writer emitted HLL register state for every row group
            AND `build_table_stats_from_provider` populated the
            `TableStats.from_hll` parallel array via
            `provider.column_ndv_estimate_from_hll`. False on SUM
            fallback (legacy / parquet-rs / DuckDB) — even though
            Tier-1 won, the cost model should treat the value as
            lower-confidence.

        Tier 2 — row-count heuristic: fall through to
            `relation.cardinality` (the existing field at
            `optimizer_reorder.mojo:198`, semantically equivalent to
            DuckDB's `cardinality_after_filters` per
            `relation_statistics_helper.cpp:110`). Return
            `ColumnStatsValue(ndv=relation.cardinality, from_hll=False,
                              source=TIER_ROW_COUNT_HEURISTIC)`.

        Tier 3 — sampling: unreachable. Future scope.

    # AUDIT:
    # `JoinRelation.cardinality` at `optimizer_reorder.mojo:198` is
    # produced by `estimate_cardinality(plan)` at extraction time.
    # `optimizer_stats.estimate_cardinality` DOES apply
    # `DEFAULT_SCAN_FILTER_SELECTIVITY` (50%) when the leaf scan has a
    # filter, and recursively walks PLAN_FILTER nodes (50% generic /
    # 1% HAVING). So `JoinRelation.cardinality` is semantically
    # `cardinality_after_filters`, NOT raw footer `num_rows`.
    """

    var _relations: Pointer[Slab[JoinRelation], Self.origin]

    @always_inline
    def __init__(
        out self,
        ref [Self.origin] relations: Slab[JoinRelation],
    ):
        self._relations = Pointer(to=relations)

    @always_inline
    def distinct_count_for(
        self, relation_id: Int, column_name: String
    ) -> ColumnStatsValue:
        # JoinRelation.id == its index in the relations slab (assigned
        # dense 0..n-1 at extraction time — see
        # `optimizer_reorder.mojo`). Index directly.
        ref relations = self._relations[]
        if relation_id < 0 or relation_id >= len(relations):
            # Defensive: out-of-range id can never happen on a
            # well-formed JoinChain, but the trait contract demands a
            # value — return a cost-model-safe sentinel rather than
            # raise. Cardinality 1 is the cost-model identity (no
            # multiplicative effect on intermediate sizes).
            return ColumnStatsValue(1, False, TIER_ROW_COUNT_HEURISTIC)

        ref relation = relations[relation_id]

        # ---- Tier 1: Parquet metadata (writer-emitted NDV) ----
        if relation.table_stats:
            ref ts = relation.table_stats.value()
            # STATS_SOURCE_SYNTHETIC_ROW_COUNT carries a synthesized
            # distinct_count derived from row_count (the
            # `_synth_row_count_table_stats` fallback of `optimizer_dpccp`,
            # not in this tree). Treat that as Tier 2 — it's
            # the row-count heuristic in a different wrapper.
            if ts.source != STATS_SOURCE_SYNTHETIC_ROW_COUNT:
                var dc = ts.column_distinct_count(column_name)
                if dc:
                    # from_hll provenance:
                    # discriminate HLL-merged NDV from SUM fallback.
                    # `column_distinct_count_from_hll` returns True
                    # iff the writer emitted HLL register state for
                    # every RG and the merged-HLL path produced the
                    # NDV. The cost-model FK-PK clamp +
                    # composite-NDV path may apply a
                    # confidence discount when `from_hll=False`.
                    var dc_from_hll = ts.column_distinct_count_from_hll(
                        column_name
                    )
                    return ColumnStatsValue(
                        dc.value(), dc_from_hll, TIER_PARQUET_METADATA
                    )

        # ---- Tier 2: row-count heuristic (domain-aware) ----
        # Domain proxy: use the leaf scan's RAW
        # (pre-filter) footer `row_count` as the join-key DOMAIN proxy when
        # available, falling back to the post-filter `relation.cardinality`
        # only when no scan row_count is reachable (a SEMI-join barrier leaf).
        #
        # WHY (not the bare `cardinality_after_filters` mirror of DuckDB's
        # `relation_statistics_helper.cpp:110`): a WHERE filter reduces the
        # relation's ROW COUNT, but a join key still ranges over the ORIGINAL
        # key domain. The equivalence-class TDOM is a DOMAIN quantity — using
        # the post-filter cardinality collapses the domain and cancels the
        # FK-PK fact-side reduction (`|l|·|o_filtered| / MIN(NDV_l, o_filtered)`
        # = |l|, no reduction). The raw row_count restores the domain so
        # `MIN(NDV_l, o_domain)` divides by the original 1.5M and the reduction
        # of threading lineitem through the date-filtered orders becomes
        # visible. The NUMERATOR (`_numerator_for_set`) still uses the
        # post-filter `relation.cardinality`, so only the denominator/domain
        # is corrected — the actual row counts flowing are unchanged.
        # Unfiltered relations have raw == cardinality, so this is a no-op for
        # them; only filtered relations' domain contribution changes.
        var domain = _leaf_raw_row_count(relation.plan[])
        if domain < 1:
            domain = relation.cardinality
        return ColumnStatsValue(domain, False, TIER_ROW_COUNT_HEURISTIC)


# =============================================================================
# SyntheticColumnStatsProvider — test-time injection
# =============================================================================


struct SyntheticColumnStatsProvider(
    ColumnStatsProvider, Movable, Deinitable
):
    """Test-only deterministic provider.

    Backed by a `Dict[(Int, String), ColumnStatsValue]` injection
    map keyed by `(relation_id, column_name)`. Used by
    cost-model unit tests to construct deterministic NDV signals
    without building a full `JoinChain` + Parquet fixture.

    Misses (unknown key) return a cost-model-safe sentinel
    `ColumnStatsValue(1, False, TIER_ROW_COUNT_HEURISTIC)` — matches
    the `DefaultColumnStatsProvider`'s defensive out-of-range
    behavior so test wiring + production wiring degrade identically.

    Design choice: test injection lives ON this provider,
    NOT on the `cost_override` Dict of `solve_dpccp_with_cost` (DPccp, not in
    this tree). The two mechanisms target different
    layers (provider = per-column NDV; cost_override = per-RelationSet
    cost); keeping them separate avoids cross-coupling test fixtures.
    """

    var _map: Dict[String, ColumnStatsValue]

    @always_inline
    def __init__(out self):
        self._map = Dict[String, ColumnStatsValue]()

    @always_inline
    @staticmethod
    def _key(relation_id: Int, column_name: String) -> String:
        # Tuple-key flattening: Mojo 0.26.3 Dict's hash on
        # `Tuple[Int, String]` is not stable across the (Int, String)
        # variants we encounter. Flatten to a delimited string to
        # avoid the trait-bound dance; the dict is small (one entry
        # per test column) so the flatten cost is irrelevant.
        return String(relation_id) + "|" + column_name

    @always_inline
    def inject(
        mut self,
        relation_id: Int,
        var column_name: String,
        ndv: Int,
        from_hll: Bool = True,
        source: UInt8 = TIER_PARQUET_METADATA,
    ):
        """Test-time map injection. Replace any existing entry for the
        same key."""
        self._map[Self._key(relation_id, column_name^)] = ColumnStatsValue(
            ndv, from_hll, source
        )

    @always_inline
    def distinct_count_for(
        self, relation_id: Int, column_name: String
    ) -> ColumnStatsValue:
        var k = Self._key(relation_id, column_name)
        var hit = self._map.get(k)
        if hit:
            return hit.value()
        # Test miss → cost-model-safe sentinel.
        return ColumnStatsValue(1, False, TIER_ROW_COUNT_HEURISTIC)
