# =============================================================================
# Optimizer DPccp -- bounds, the DP table entry and the cost of one pair
# =============================================================================
#
# Part of the DPccp join enumerator; `optimizer_dpccp` holds the overview
# (selection, cost model, test-only cost injection, observation, v0.3
# divergences) and re-exports every name defined here. This module holds the
# relation and iteration bounds, `DPNode` (one DP table entry), the
# iteration counter the enumerators share, and `_cost_for_pair` with the
# row-count fallback it uses when no TDOM graph is set.
#
# =============================================================================

from std.collections import Dict

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_SCAN,
)
from .optimizer_reorder import (
    RelationSet,
    JoinChain,
    collect_connecting_keys,
    estimate_join_cardinality_with_ndv,
)
from .optimizer_column_stats_provider import DefaultColumnStatsProvider
from .optimizer_tdom import TdomGraph
from .optimizer_tdom_card import estimate_cardinality_with_set
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_SYNTHETIC_ROW_COUNT,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Bounds (intrinsic-selection rules in `should_use_dpccp`, NOT a feature flag)
# =============================================================================
#
# No ENABLE_DPCCP flag, by design. Selection is code-driven
# based on chain shape (see `should_use_dpccp` in `optimizer_dpccp`).

# Bailout: chains with more than this many relations always fall back to
# greedy. For canonical DPccp a 12-relation clique has 261,625 csg-cmp
# pairs, under DPCCP_MAX_ITERATIONS; this enumerator emits pairs
# repeatedly on dense graphs (komira-ai/komira#1176), so dense graphs from
# about 9 relations up hit the iteration cap before this bound.
comptime DPCCP_MAX_RELATIONS: Int = 12

# Lower bound: chains shorter than this go to greedy. With <= 3
# relations there are at most three join trees up to commutativity, so
# the DP table buys little over greedy's choice.
comptime DPCCP_MIN_RELATIONS: Int = 4

# Absolute iteration cap. If the enumerators burn through this many pair
# emits (csg+cmp seeds or complement extensions) we give up and return
# None so the caller can fall back to greedy. Protects against dense
# graphs. With this enumerator's repeated emits (komira-ai/komira#1176) a
# 9-relation clique (860,736 emits) and most random 10-relation graphs
# with ~30% extra edges exceed it and fall back to greedy.
comptime DPCCP_MAX_ITERATIONS: Int = 500_000

# Estimated-distinct-ratio for the row_count-only NDV fallback of
# `_cost_for_pair`'s no-TDOM path. When a scan carries `row_count` but
# its relation has no `table_stats`, the cost function has nothing to plug
# into the `(L*R)/max(NDV)` FK-PK formula. The fallback approximates
# NDV(k) on the unknown-stats side as `(NUM/DEN) * row_count`. Two
# choices in tension:
#   * `NDV ~= row_count` (ratio = 1): divisor = max(L, R), estimate =
#     min(L, R). Picks small-side-first; same ordering as greedy's
#     max(L, R) tie-break only because every pair gets the same treatment.
#   * `NDV ~= 0.1 * row_count` (ratio = 1/10): divisor = 0.1*max(L,R),
#     estimate = 10*min(L, R). Same ORDERING as the ratio=1 case (the
#     scaling cancels in pair-vs-pair comparisons), but produces
#     non-degenerate cumulative costs that differ from greedy's accumulator.
# We pick 1/10, the estimated-distinct form `min(row_count, ratio *
# row_count)` with ratio < 1; ordering is identical for either choice
# within a single chain. Smaller ratios make the divisor tinier and
# inflate intermediate cost magnitudes (no harm, DPccp compares costs
# internally).
comptime ESTIMATED_DISTINCT_RATIO_NUM: Int = 1
comptime ESTIMATED_DISTINCT_RATIO_DEN: Int = 10


# =============================================================================
# Row-count signal of a leaf (selection and the row-count cost fallback)
# =============================================================================

def _leaf_has_row_count(plan: LogicalPlan) -> Bool:
    """True iff the leaf plan walks down to a SCAN whose row_count is
    populated.

    Mirrors `optimizer_reorder._find_leaf_table_stats` for the row_count
    field. The chain extractor's leaves are typically Scan,
    Filter(Scan), Project(Scan), or Project(Filter(Scan)). Aggregate /
    sort / topn leaves do not carry meaningful row counts (they're
    intermediate results), so we stop and return False.

    Used by `should_use_dpccp` (row-count fallback) to decide whether a chain has
    SOME cost signal -- `table_stats` (NDV-aware) or `row_count` only.
    """
    if plan.tag == PLAN_SCAN and plan._scan:
        if plan._scan.value()[].row_count:
            return True
        return False
    if plan.tag == PLAN_FILTER and plan._filter:
        return _leaf_has_row_count(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT and plan._project:
        return _leaf_has_row_count(plan._project.value()[].child[])
    return False


# =============================================================================
# DPNode -- DP table entry, one per reachable RelationSet
# =============================================================================

struct DPNode(Copyable, Movable):
    """One entry in the DPccp DP table.

    `best_left` / `best_right` are RelationSet subsets whose union equals
    the key this node is stored under. They are set by `emit_pair` when a
    cheaper decomposition is found. For singleton leaves both are empty
    (signaling "this is a base relation, don't recurse further during
    reconstruction"), and `cardinality` is taken straight from the
    JoinRelation's estimated row count.

    Fields:
        cost: Cumulative cost along the best-known plan rooted at this
              subset. Units are "rows produced across all intermediate
              joins" -- simple sum over left + right + emitted join card.
        cardinality: Estimated output rows for the subset's join (or the
              leaf row count for singletons).
        best_left: Subset for the left child of the best plan. Empty iff
              this node is a base relation.
        best_right: Subset for the right child of the best plan. Empty
              iff this node is a base relation.
    """
    var cost: Float64
    var cardinality: Int
    var best_left: RelationSet
    var best_right: RelationSet

    @always_inline
    def __init__(
        out self,
        cost: Float64,
        cardinality: Int,
        best_left: RelationSet,
        best_right: RelationSet,
    ):
        self.cost = cost
        self.cardinality = cardinality
        self.best_left = best_left.copy()
        self.best_right = best_right.copy()


# =============================================================================
# Internal mutable iteration counter (see divergence #2)
# =============================================================================

struct _IterCounter(Movable):
    """Heap-free counter passed by `mut` reference through the enumerators.

    v0.3 returns the delta from each recursive call and the caller adds
    it in. Here the enumerators return nothing and share one explicit
    counter. The bail-out check hits the same spot: after each
    increment, `is_over()` is consulted; if True, the current call
    returns early and the top-level `solve_dpccp` converts it to None.
    """
    var n: UInt64
    var cap: UInt64

    @always_inline
    def __init__(out self, cap: UInt64):
        self.n = UInt64(0)
        self.cap = cap

    @always_inline
    def bump(mut self, amount: UInt64 = UInt64(1)):
        self.n += amount

    @always_inline
    def is_over(self) -> Bool:
        return self.n > self.cap


# =============================================================================
# _cost_for_pair -- the join cardinality of one (left_set, right_set) candidate
# =============================================================================

@always_inline
def _row_count_ndv_estimate(side_card: Int) -> Int:
    """Row_count-only NDV fallback.

    Returns `min(side_card, max(1, (side_card * NUM) // DEN))`. With
    NUM=1, DEN=10 this is `side_card // 10`, at least 1 (so 1 to 9 rows
    give 1). The clamp against `side_card` is an upper bound: NDV cannot
    exceed row_count by definition, and the explicit min keeps any other
    NUM/DEN from over-shooting side_card.

    Returns 0 (no signal) for non-positive cardinalities -- the caller
    (`_synth_row_count_table_stats`) then returns None and that side
    carries no stats.
    """
    if side_card <= 0:
        return 0
    var raw = (side_card * ESTIMATED_DISTINCT_RATIO_NUM) // ESTIMATED_DISTINCT_RATIO_DEN
    if raw < 1:
        raw = 1
    if raw > side_card:
        return side_card
    return raw


def _cost_for_pair(
    left_set: RelationSet,
    right_set: RelationSet,
    left_card: Int,
    right_card: Int,
    imm chain: JoinChain,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
) -> Int:
    """Resolve the join cardinality for a candidate pair.

    With a TDOM graph (`tdom_opt` set), the cardinality is the
    PARTITION-INDEPENDENT `estimate_cardinality_with_set` (one-set
    contract; mirrors DuckDB `EstimateCardinalityWithSet`). The
    `left_card`/`right_card` arguments are IGNORED on this path — the
    estimator computes cardinality from BASE relation cardinalities +
    the subgraph-merge denominator walk, both of which are properties of
    the COMBINED set, not the (L, R) partition, so every partition of
    one set gets the same cardinality.

    The two-card `estimate_with_tdom` in `optimizer_tdom_cost.mojo` is
    not used here. The `left_card`/`right_card` parameters serve the
    legacy NDV path below, which runs only when `tdom_opt` is None
    (`solve_dpccp_with_cost` always builds a graph; direct callers of
    the enumerators may pass None). With a graph set, every pair,
    cross-product pairs included, goes through
    `estimate_cardinality_with_set`.

    Legacy NDV-aware path (no TDOM graph): when `left_set`
    or `right_set` is a singleton (a single base relation), look up the
    relation's `table_stats` and apply the FK-PK formula via
    `estimate_join_cardinality_with_ndv`. For composite subsets, leave
    stats None so the helper falls through to `max(l, r)` for that side.

    Row-count fallback (legacy path only): synthesize a row-count-only
    NDV estimate when `table_stats` is None but the leaf scan carries
    `row_count`.

    Tests can inject a biased cost by populating `cost_override` with
    combined.bits -> desired cardinality; an override entry is returned
    before either path runs.

    Cache semantics: `card_cache` is keyed by
    `combined.bits`; the one-set estimator caches its result so
    later DP-emits asking about the same combined set get O(1) lookup.
    `solve_dpccp_with_cost` creates a fresh cache for each enumeration
    pass.
    """
    var combined_key = left_set.union(right_set).bits
    var hit = cost_override.get(combined_key)
    if hit:
        return hit.value()

    # One-set order-independent estimator. The result is
    # cached by `combined.bits` (DuckDB `relation_set_2_cardinality`
    # equivalent at `cardinality_estimator.cpp:419-430`) so subsequent
    # emits for partitions of the same combined set get O(1) lookup.
    #
    # When TDOM is set, route THROUGH
    # `estimate_cardinality_with_set` even for cross-product pairs (no
    # bridging edge). The cross-product clamp at
    # `optimizer_tdom_card._is_cross_product_shaped_subset` caps
    # the combined cardinality at `max_base_card_in_set` for disconnected
    # subsets. Without this routing, cross-product pairs would fall through
    # to the legacy NDV path (`estimate_join_cardinality_with_ndv`), which
    # has no upper-bound clamp on disconnected subsets.
    if tdom_opt:
        var provider = DefaultColumnStatsProvider(chain.relations)
        return estimate_cardinality_with_set(
            tdom_opt.value(),
            chain,
            combined_key,
            provider,
            card_cache,
        )

    # Legacy fall-through (the earlier cost model).
    var keys = collect_connecting_keys(left_set, right_set, chain.edges)
    var lk = keys.left.copy()
    var rk = keys.right.copy()

    # Pull per-relation TableStats for whichever side is a singleton, OR
    # synthesize row_count-only stats when table_stats is None but the
    # relation's leaf scan carries `row_count` (row-count fallback).
    var left_stats: Optional[TableStats] = None
    if left_set.count() == 1:
        var ids = left_set.iter()
        for i in range(len(chain.relations)):
            if chain.relations[i].id == ids[0]:
                if chain.relations[i].table_stats:
                    left_stats = Optional[TableStats](
                        chain.relations[i].table_stats.value().copy()
                    )
                else:
                    left_stats = _synth_row_count_table_stats(
                        chain.relations[i].plan[],
                        chain.relations[i].cardinality,
                        lk,
                    )
                break
    var right_stats: Optional[TableStats] = None
    if right_set.count() == 1:
        var ids = right_set.iter()
        for i in range(len(chain.relations)):
            if chain.relations[i].id == ids[0]:
                if chain.relations[i].table_stats:
                    right_stats = Optional[TableStats](
                        chain.relations[i].table_stats.value().copy()
                    )
                else:
                    right_stats = _synth_row_count_table_stats(
                        chain.relations[i].plan[],
                        chain.relations[i].cardinality,
                        rk,
                    )
                break

    return estimate_join_cardinality_with_ndv(
        left_card, right_card, left_stats^, right_stats^, lk^, rk^
    )


def _synth_row_count_table_stats(
    plan: LogicalPlan, cardinality: Int, key_names: List[String]
) -> Optional[TableStats]:
    """Synthesize a TableStats for the row_count-only fallback.

    Returns None if the plan's leaf scan does NOT have `row_count`
    populated (true "no signal" case -- that side then carries no stats
    into `estimate_join_cardinality_with_ndv`), if `key_names` is empty,
    or if the estimate is not positive. Otherwise builds a single-key TableStats whose
    `column_distinct_count(key)` returns the row-count NDV estimate
    for every key in `key_names`.

    Why per-key: `_max_ndv_across_keys` walks the full key list and
    returns None if ANY key is missing. We populate every key with the
    same estimate so the helper never short-circuits.
    """
    if not _leaf_has_row_count(plan):
        return None
    if len(key_names) == 0:
        return None

    var ndv = _row_count_ndv_estimate(cardinality)
    if ndv <= 0:
        return None

    var names = List[String]()
    var stats_list = List[ColumnStats]()
    for i in range(len(key_names)):
        names.append(key_names[i])
        var dc: Optional[Int] = ndv
        var min_v: Optional[ScalarValue] = None
        var max_v: Optional[ScalarValue] = None
        var nc: Optional[Int] = None
        stats_list.append(ColumnStats(dc^, min_v^, max_v^, nc^))
    # This TableStats is synthesized
    # from row_count, NOT from Parquet footer metadata. The
    # source flag is distinguished so downstream consumers (cost
    # model, ColumnStatsProvider Tier 1 inspection) can tell whether
    # the NDV signal is genuine or fallback-derived.
    return Optional[TableStats](
        TableStats(cardinality, names^, stats_list^, STATS_SOURCE_SYNTHETIC_ROW_COUNT)
    )
