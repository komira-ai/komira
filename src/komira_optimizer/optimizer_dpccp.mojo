# =============================================================================
# Optimizer DPccp -- connected-subgraph / complement pair DP join enumeration
# =============================================================================
#
# Literal port of v0.3 `solve_dpccp` and its five companions in
# v0.3's join-order planner. DPccp is the classical
# Moerkotte/Neumann dynamic-programming join enumerator: it enumerates every
# connected subgraph (csg) of the join graph, then for each csg every
# connected complement (cmp), and memoizes the best join tree per relation
# subset. This port is not the canonical enumerator: it grows a csg or a
# complement one neighbour at a time and excludes only that neighbour, so
# on dense graphs the same csg-cmp pair is emitted many times (a clique of
# n relations: 40, 236, 1,541, 11,327, 93,528, 860,736 emits for n = 4..9,
# against the canonical (3^n - 2^(n+1) + 1) / 2 = 25..9,330). Plans stay
# optimal (the DP table keeps the cheaper entry); the cost is time. The
# relation bound (more than 12 relations fall back to greedy) and the
# iteration cap keep it bounded; a 9-relation clique already exceeds the
# cap and falls back to greedy. komira-ai/komira#1176 tracks the fix.
#
# Selection (no feature flag; the row-count fallback relaxes it):
#   `should_use_dpccp(chain)` decides DPccp vs greedy based on intrinsic
#   chain shape. The rule (defined below):
#     - chain length in [DPCCP_MIN_RELATIONS, DPCCP_MAX_RELATIONS], AND
#     - at least one relation carries EITHER (a) writer-emitted NDV
#       stats (`table_stats`) OR (b) a populated `row_count` on its
#       underlying scan (the row-count fallback for a scan that carries
#       `row_count` while its relation has no `table_stats`).
#   Outside those bounds `reorder_joins_with_dp` uses `greedy_join_order`.
#   Greedy also remains the fallback when DPccp returns None (iteration
#   overflow, or a plan whose top join is a synthesized cross product).
#
# Cost model:
#   `solve_dpccp_with_cost` builds a TDOM graph for the chain, and
#   `_cost_for_pair` prices every pair with `estimate_cardinality_with_set`
#   over the combined relation set. Without a TDOM graph (direct callers of
#   the enumerators), it calls `estimate_join_cardinality_with_ndv`
#   (NDV-aware FK-PK formula) with the `table_stats` of whichever side is a
#   singleton base relation; for composite subsets it leaves stats None so
#   the helper falls through to the conservative `max(l, r)`.
#   Row-count fallback (no-TDOM path only): when a singleton lacks
#   `table_stats` but its leaf carries `row_count`, the helper synthesizes
#   a single-key TableStats with NDV ~= row_count // ESTIMATED_DISTINCT_RATIO_DEN
#   (with NUM=1, DEN=10 -> NDV ~= row_count / 10, at least 1) so the FK-PK
#   formula has a divisor. See `_synth_row_count_table_stats` for the shape.
#
# Test-only cost injection:
#   To exercise DPccp with a biased cost function in unit tests,
#   `solve_dpccp_with_cost` accepts a
#   `cost_override: Dict[UInt64, Int]` keyed by
#   `combined.bits` (left_set.union(right_set).bits). When the dict has an
#   entry for a given pair, `_cost_for_pair` returns it as the join
#   cardinality in place of its own estimate. `solve_dpccp` passes an
#   empty dict. Tests pass a hand-built dict to steer DPccp towards a known
#   optimum on synthetic chains.
#
# v0.3 divergences:
#
#   (1) Cost model: v0.3 calls `estimate_join_cardinality_for_reorder`
#       with (left_card, right_card, left_plan, right_plan, &lk, &rk)
#       which does per-key NDV lookup. Here `_cost_for_pair` uses the TDOM
#       set estimator `estimate_cardinality_with_set`, and
#       `estimate_join_cardinality_with_ndv` when no TDOM graph is set.
#       The `find_representative_plan` helper is still ported
#       (returns the leaf that owns the first bit of the set) because the
#       DP-table reconstruction step needs it to recover leaf plans.
#
#   (2) Iteration counting: v0.3 increments `iterations` by the return
#       value of each recursive call. v0.4 passes one `_IterCounter`
#       struct by `mut` reference through the recursion instead of
#       "return the delta" plumbing. Cap check identical: bail with None
#       on overflow.
#
#   (3) RelationSet API: v0.4's `RelationSet` already exists (see
#       optimizer_reorder.mojo) with singleton/union/contains. We use it
#       unchanged. The `iter()` helper returns a small `List[Int]` rather
#       than a Rust-style iterator.
#
#   (4) DP table: v0.3 uses `HashMap<u64, DPNode>`; v0.4 uses Mojo stdlib
#       `Dict[UInt64, DPNode]`. Same semantics (insertion-order preserving
#       in Mojo, which we do not rely on).
#
#   (5) `or_insert` / entry pattern: v0.3 uses the HashMap entry API.
#       `emit_pair` does a manual "lookup-then-update-or-insert", which is
#       slightly less efficient (two hash probes on the update path) but
#       semantically identical.
#
# =============================================================================

from std.collections import Dict
from komira_async.runtime.sched_trace import join_reorder_fire_inc

from std.memory import OwnedPointer

from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JOIN_INNER,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    ExprArray,
)
from .optimizer_reorder import (
    _is_rename_free_passthrough_project,
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
    find_connecting_edge,
    collect_connecting_keys,
    estimate_join_cardinality_for_reorder,
    estimate_join_cardinality_with_ndv,
    extract_join_chain,
    greedy_join_order,
)
from .optimizer_transitive_edges import derive_transitive_edges
from .optimizer_join import (
    join_reorder_output_names,
    narrow_reordered_join_to_declared_columns,
)
from komira_plan_ir.plan_helpers import (
    _copy_plan,
    _take_join_left,
    _take_join_right,
)
from .optimizer_column_stats_provider import DefaultColumnStatsProvider
from .optimizer_tdom import TdomGraph, build_tdom_graph
from .optimizer_tdom_cost import estimate_with_tdom, has_classes_for
from .optimizer_tdom_card import estimate_cardinality_with_set
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
    STATS_SOURCE_SYNTHETIC_ROW_COUNT,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Bounds (intrinsic-selection rules in `should_use_dpccp`, NOT a feature flag)
# =============================================================================
#
# No ENABLE_DPCCP flag, by design. Selection is code-driven
# based on chain shape (see `should_use_dpccp` below).

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
# Intrinsic selection: should the optimizer use DPccp for this chain?
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


def should_use_dpccp(chain: JoinChain) -> Bool:
    """Decide DPccp vs greedy based on chain shape, not a feature flag.

    Selection rule (the row-count fallback relaxes the original
    NDV-required clause):
      1. chain length must be in [DPCCP_MIN_RELATIONS, DPCCP_MAX_RELATIONS], AND
      2. at least one relation must carry EITHER (a) writer-emitted NDV
         stats (`table_stats`), OR (b) a populated `row_count` on its
         underlying scan (a scan that carries `row_count` while its
         relation has no `table_stats`).

    Returns False otherwise -- the caller should fall through to
    `greedy_join_order`. Keeps DPccp's CPU cost (exponential in n, and
    above canonical on dense graphs: komira-ai/komira#1176) bounded
    to chains where the cost model has SOME signal to work with.

    Row-count fallback rationale:
      A relation whose scan carries only `row_count` has
      `table_stats=None`. Under an NDV-required gate, a chain of such
      relations would never activate DPccp and would always fall back to
      greedy. The solver still has a cost signal for it:
      `solve_dpccp_with_cost` prices pairs through the TDOM graph, whose
      `DefaultColumnStatsProvider` falls back to each relation's
      cardinality, and without a TDOM graph `_cost_for_pair` synthesizes
      NDV from `row_count` via the `ESTIMATED_DISTINCT_RATIO_*` constants.

    Limits (locked in by test_optimizer_dpccp.mojo and
    test_optimizer_dpccp_row_count_fallback.mojo):
      * 1-rel / 2-rel / 3-rel chains: always False (below
        DPCCP_MIN_RELATIONS).
      * Above the relation cap: always False (the pair count is
        exponential in n).
      * Chain at [4, 12] with neither table_stats nor row_count: False
        (no stats signal).
      * Chain at [4, 12] with row_count only (row-count path): True.
      * Chain at [4, 12] with table_stats: True (legacy NDV path).
    """
    var n = len(chain.relations)
    if n < DPCCP_MIN_RELATIONS:
        return False
    if n > DPCCP_MAX_RELATIONS:
        return False
    for i in range(n):
        if chain.relations[i].table_stats:
            return True
        if _leaf_has_row_count(chain.relations[i].plan[]):
            return True
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


# =============================================================================
# emit_pair -- score one (left_set, right_set) candidate and update DP
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


def emit_pair(
    left_set: RelationSet,
    right_set: RelationSet,
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
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

    # Manual "entry or insert" (divergence #5).
    var existing = dp.get(combined.bits)
    if existing:
        var e = existing.value().copy()
        if pair_cost < e.cost:
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

def emit_csg_complements(
    csg: RelationSet,
    exclusion: RelationSet,
    neighbors: List[List[Int]],
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
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
            card_cache, allow_cross,
        )
        if counter.is_over():
            return
        var compl_excl = exclusion.union(csg)
        enumerate_complement_rec(
            complement, csg, compl_excl,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, allow_cross,
        )
        if counter.is_over():
            return


def enumerate_csg_rec(
    csg: RelationSet,
    exclusion: RelationSet,
    neighbors: List[List[Int]],
    imm chain: JoinChain,
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
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
            card_cache, allow_cross,
        )
        if counter.is_over():
            return
        var further_excl = exclusion.union(RelationSet.singleton(nb))
        enumerate_csg_rec(
            new_csg, further_excl,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, allow_cross,
        )
        if counter.is_over():
            return


def enumerate_complement_rec(
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
            card_cache, allow_cross,
        )
        if counter.is_over():
            return
        var new_excl = exclusion.union(RelationSet.singleton(nb))
        enumerate_complement_rec(
            new_compl, csg, new_excl,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, allow_cross,
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


def _run_dpccp_passes(
    n: Int,
    imm chain: JoinChain,
    neighbors: List[List[Int]],
    mut dp: Dict[UInt64, DPNode],
    mut counter: _IterCounter,
    cost_override: Dict[UInt64, Int],
    imm tdom_opt: Optional[TdomGraph],
    mut card_cache: Dict[UInt64, Int],
    allow_cross: Bool,
) -> Bool:
    """Run the three nested DPccp enumerators i from n-1 down to 0.

    Returns False on iteration overflow, True on clean completion. The
    `allow_cross` flag is forwarded to every emit_pair callsite via the
    enumerator stack — when True, cross-product pairs (no real edge
    connecting the two halves) are admitted (costed by `_cost_for_pair`
    when a TDOM graph is set, by the Cartesian product otherwise).
    """
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
            card_cache, allow_cross,
        )
        if counter.is_over():
            return False

        enumerate_csg_rec(
            start, exclusion,
            neighbors, chain, dp, counter, cost_override, tdom_opt,
            card_cache, allow_cross,
        )
        if counter.is_over():
            return False

        i -= 1
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
    var n = len(chain.relations)
    if n < 2:
        return None
    if n > DPCCP_MAX_RELATIONS:
        return None

    var dp = Dict[UInt64, DPNode]()
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
        card_cache, False,
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
            tdom_opt, card_cache_aug, True,
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


# =============================================================================
# ⛔ A REORDER MUST PRESERVE THE SUBTREE'S OUTPUT SCHEMA — RESTORE THE NARROW.
#
# `_extract_join_chain_inner` PIERCES a rename-free col-ref Project on a join
# side and drops the node, on a written assumption: "the greedy rebuild produces
# a superset schema (all leaf columns concatenated at every join level), which
# preserves all referenced names." That is true of NAME REFERENCES and false of
# the SUBTREE'S OWN OUTPUT. A `Project([pk, pv])` on a join input is not a
# downstream name reference — it is a statement about WHICH COLUMNS THE RESULT
# CARRIES — so piercing it silently WIDENS the answer.
#
# Example: `Join(Project([pk, pv])(Filter(pflag == 1)(Scan L)), Scan R)` on
# pk == bk, with L = [pk, pv, pflag] and R = [bk, bval]:
#
#   BOUND      output = [pk, pv, bk, bval]
#   REORDERED  the pierce drops the Project, so the rebuilt join carries
#              every leaf column: [pk, pv, pflag, bk, bval] in some order.
#              `pflag`, the column the Project dropped, is back in the
#              output: one column too many.
#
# The pierce is worth keeping — it is what lets a chain reorder through an
# intermediate column-narrowing Project — so the fix is not to stop piercing, it is to put the
# narrow back. Same shape as `select_join_build_side`'s
# `_swap_outer_join_with_reprojection`: a rewrite that changes the shape restores
# the user-visible columns above it.
#
# ⚠ BY NAME IS EXACT HERE, AND ONLY HERE. `_swap_outer_join_with_reprojection`
# had to derive POSITIONALLY because an operand exchange MIGRATES the `_right`
# collision suffix, so a by-name projection cannot undo it. This site is
# downstream of the `_chain_relations_share_column_name` barrier — a chain whose
# relations share ANY column name is NOT reordered at all — so within a
# reorderable chain every leaf column name is unique, `LogicalPlan.join` never
# appended `_right`, and the original subtree's names denote exactly one column
# each in the rebuilt superset.
#
# DECLINES rather than guesses: if any original output name is absent from the
# reordered schema the reorder is ABANDONED and the un-reordered rebuild is
# returned. A reorder that cannot be shown to preserve the answer is not worth
# the plan it produces.
# =============================================================================


def _restore_chain_output_schema(
    var reordered: LogicalPlan, var unreordered: LogicalPlan,
) raises -> LogicalPlan:
    """Return `reordered` presenting `unreordered`'s output schema.

    ⛔ WIDENING ONLY. A pure PERMUTATION is deliberately left alone — that is
    what `optimizer_join.restore_join_reorder_output_columns` restores, and
    duplicating it
    here would put a `Project` on top of every reordered chain. Plan-SHAPE
    consumers walk only JOIN/SCAN (`test_q5_plan_shape._plan_leaf_scan_paths`
    is the worked example — a `Project` root makes it report ZERO leaves), so a
    node added on the common path is a behaviour change with no correctness
    story. The widening case is different in kind:
    `restore_join_reorder_output_columns` DECLINES it outright
    (`if n != len(want): return plan^`), so this function and
    `narrow_reordered_join_to_declared_columns` are what repair it.

    Returns `reordered` unchanged when the schemas agree name-for-name in order,
    and when they are permutations of one another. Wraps `reordered` in a
    by-name `LogicalPlan.project` when the subtree's names are a strict SUBSET
    of the rebuilt ones. Returns `unreordered` — i.e. DECLINES the reorder —
    when the restore cannot be expressed by name.

    ⚠ THE DECLINE PATH LEAVES `_join_reorder_fire()` ALREADY BUMPED, so the
    process-global reorder counter over-reports by one there. Stated rather than
    plumbed around: the chain extractor's own superset contract says the path is
    unreachable, and moving the fire would put the counter's meaning
    ("the reorderer emitted a chain") behind a restore decision it does not
    describe.
    """
    # Snapshot both name lists FIRST so neither plan stays borrowed while the
    # other is moved out below.
    var want = List[String]()
    for i in range(unreordered.output_schema.num_columns()):
        want.append(String(unreordered.output_schema.field_name(i)))
    var got = List[String]()
    for i in range(reordered.output_schema.num_columns()):
        got.append(String(reordered.output_schema.field_name(i)))

    if len(got) == len(want):
        var same = True
        for i in range(len(want)):
            if got[i] != want[i]:
                same = False
                break
        if same:
            _ = unreordered^
            return reordered^
        # Same arity, different order: a PERMUTATION iff the name multisets
        # agree. Leave it entirely alone — see the docstring's WIDENING ONLY
        # block. (Checked as a multiset, not a set, so a rebuild that turned two
        # distinct names into two copies of one name is NOT mistaken for a
        # permutation and falls through to the distinctness refusal below.)
        var perm = True
        for i in range(len(want)):
            var c_want = 0
            var c_got = 0
            for j in range(len(want)):
                if want[j] == want[i]:
                    c_want += 1
                if got[j] == want[i]:
                    c_got += 1
            if c_want != c_got:
                perm = False
                break
        if perm:
            _ = unreordered^
            return reordered^

    # Every name the subtree promised must denote EXACTLY ONE column of the
    # rebuilt superset. Present-once, not merely present: a name carried twice
    # makes the by-name projection ambiguous, and picking either occurrence
    # would convert a schema-widening defect into a wrong ANSWER. Same
    # distinctness test `restore_join_reorder_output_columns` applies for the
    # same reason.
    for i in range(len(want)):
        var hits = 0
        for j in range(len(got)):
            if got[j] == want[i]:
                hits += 1
        if hits != 1:
            _ = reordered^
            return unreordered^

    var exprs = ExprArray()
    for i in range(len(want)):
        exprs.append(Expr.col_ref(want[i]))
    _ = unreordered^
    return LogicalPlan.project(exprs^, reordered^)


def _join_reorder_fire():
    """Bump the process-global
    join-reorder fire counter — the test-observable decision pin that the
    reorderer emitted a reordered INNER-join chain. Calls
    `komira_async.runtime.sched_trace.join_reorder_fire_inc`, the safe wrapper
    over the `_posix_shim.c` TU-static relaxed atomic. ZERO overhead on any
    path that does not emit a chain."""
    join_reorder_fire_inc()


# =============================================================================
# reorder_joins_with_dp -- top-level driver with intrinsic DPccp/greedy split
# =============================================================================
#
# Sibling of `optimizer_reorder.reorder_joins` (greedy-only). This variant
# inspects each chain and picks DPccp or greedy via `should_use_dpccp`.
# Lives here (not in optimizer_reorder.mojo) because it imports
# `solve_dpccp` -- importing dpccp from reorder would create a cycle.

# ⛔ THIS BARRIER IS CHAIN-WIDE, NOT TWO-OPERAND.
# Asking whether the JOIN NODE's own two operands collide is a strictly
# weaker question than the one the barrier needs, and is bypassed by every
# chain of three or more relations — see
# `_chain_relations_share_column_name` below for the counterexample.
# `optimizer_join.join_operands_share_column_name` answers the two-operand
# form; do not use it to arm this barrier.


def _collect_chain_relation_names(
    plan: LogicalPlan, mut acc: List[List[String]]
) raises:
    """Append the output column names of every relation `extract_join_chain`
    would flatten this subtree into.

    ⛔ MIRRORS `_extract_join_chain_inner`'S OWN RECURSION, ARM FOR ARM: pierce
    a rename-free passthrough Project, descend through a residual-free
    JOIN_INNER, treat everything else as a leaf. It has to, because the
    question is what the SOLVER will be handed — a barrier derived from a
    different traversal than the one it guards is a barrier with holes in it,
    which is precisely the defect this function exists to close."""
    if _is_rename_free_passthrough_project(plan):
        _collect_chain_relation_names(plan._project.value()[].child[], acc)
        return
    if (
        plan.tag == PLAN_JOIN
        and plan._join.value()[].join_type == JOIN_INNER
        and not plan._join.value()[].has_residual()
    ):
        ref jd = plan._join.value()[]
        _collect_chain_relation_names(jd.left[], acc)
        _collect_chain_relation_names(jd.right[], acc)
        return
    var names = List[String]()
    for i in range(plan.output_schema.num_columns()):
        names.append(plan.output_schema.field_name(i))
    acc.append(names^)


def _chain_relations_share_column_name(plan: LogicalPlan) raises -> Bool:
    """True if ANY TWO relations in this join chain share a column name.

    ⛔ THE BARRIER'S REAL QUESTION, AND THE TWO-OPERAND FORM ABOVE IS NOT IT.
    `_extract_join_chain_inner` recurses through nested JOIN_INNER nodes with
    no collision check of its own, so a barrier evaluated only at the node it
    is written on is BYPASSED by any ancestor that flattens through it.

    Counterexample for a two-operand barrier: three-way chain
    `(A JOIN B) JOIN C` where A and B carry IDENTICAL schemas `(skey, val)`
    and C is disjoint. The TOP join's operands are `(A JOIN B)` and `C`, which
    share NO name, so a two-operand predicate is False there and the barrier
    does not arm — while the solver then re-plans {A, B, C} and may emit B
    before A. Provenance per output column:

        before  [A, A, B, B, C, C]
        after   [B, B, A, A, C, C]      <- A and B EXCHANGED

    with the output NAMES `[skey, val, skey_right, val_right, ckey, cval]`
    IDENTICAL in both — so `restore_join_reorder_output_columns` compares equal
    and declines, and the wrong relation is served under every name. It
    takes a reorder that exchanges the two colliding relations with each
    other; a two-relation join is covered by the two-operand question.

    ⚠ ANY pairwise collision is disqualifying, not just one between the two
    immediate operands: whichever of the two colliding relations the rebuild
    places FIRST keeps the bare name and the other takes `_right`, so their
    relative order alone decides which relation each name denotes. The chain
    rebuild carries no provenance map to restore that from (DuckDB's
    `left/right_projection_map`, which our IR does not have), so the only
    sound answer here is to decline — exactly as a residual-carrying join
    declines."""
    var rels = List[List[String]]()
    _collect_chain_relation_names(plan, rels)
    for i in range(len(rels)):
        for j in range(i + 1, len(rels)):
            var seen = Dict[String, Bool]()
            for a in range(len(rels[i])):
                seen[rels[i][a]] = True
            for b in range(len(rels[j])):
                if rels[j][b] in seen:
                    return True
    return False


def reorder_joins_with_dp(var plan: LogicalPlan) raises -> LogicalPlan:
    """Walk the plan tree and reorder each maximal INNER-join subtree.

    Per-chain solver selection (no feature flag):
      - DPccp when `should_use_dpccp(chain)` returns True (chain length
        in [4, 12] AND at least one leaf has NDV stats or a row count).
      - Greedy otherwise (or as fallback when DPccp returns None:
        iteration overflow, or a plan whose top join is a synthesized
        cross).

    For non-INNER joins (LEFT / RIGHT / FULL / SEMI / ANTI / CROSS),
    residual-carrying INNER joins and INNER joins whose chain relations
    share a column name, we only recurse -- they're reorder barriers.
    """
    var tag = plan.tag

    if tag == PLAN_JOIN:
        var jt = plan._join.value()[].join_type
        # A residual-carrying join (`predicate=` non-equi /
        # range / complex) is NOT reorderable — flattening it into a join
        # chain would lose the residual condition. Recurse into the
        # children and rebuild PRESERVING the residual.
        var has_resid = plan._join.value()[].has_residual()
        # ⛔ A NAME-COLLIDING *CHAIN* IS A REORDER BARRIER.
        # ⚠ CHAIN, NOT OPERANDS. The two-operand question is bypassed by
        # every chain of three or more — see
        # `_chain_relations_share_column_name` for the three-way
        # counterexample that is silent in both the names and the verdict.
        # `LogicalPlan.join` appends `_right` to a colliding RIGHT name, so for
        # such a join the output schema depends on operand ORDER for more than
        # order: after an exchange the bare name denotes the OTHER relation.
        # This solver rebuilds a chain from scratch and has no provenance map
        # to restore from (DuckDB's `left/right_projection_map`, which our IR
        # does not carry), so reordering here would silently REASSIGN names:
        # in an INNER join whose sides both carry `val`, putting the right
        # side first makes `val` name the right side's column.
        # Treat it as a barrier, the same way a residual-carrying join is one.
        # `select_join_build_side` still orients such a join and CAN restore,
        # because its exchange is a single swap it derives positionally.
        var _shares = _chain_relations_share_column_name(plan)
        if jt == JOIN_INNER and not has_resid and not _shares:
            var left = _take_join_left(plan)
            var right = _take_join_right(plan)
            var new_left = reorder_joins_with_dp(left^)
            var new_right = reorder_joins_with_dp(right^)
            var lk = plan._join.value()[].left_on.copy()
            var rk = plan._join.value()[].right_on.copy()
            var rebuilt = LogicalPlan.join(
                new_left^, new_right^, lk^, rk^, JOIN_INNER
            )

            var rebuilt_copy = _copy_plan(rebuilt)
            # ⛔ THE CHAIN EXTRACTOR MAY WIDEN THIS NODE'S OUTPUT. Its Project
            # pierce flattens through a column-narrowing projection and drops
            # it, so the rebuilt chain can carry leaf columns this node had
            # projected away. Capture what THIS node declares, before the
            # extractor sees it, and narrow the rebuild back to it. Full
            # argument:
            # `optimizer_join.narrow_reordered_join_to_declared_columns`.
            var declared_out = join_reorder_output_names(rebuilt_copy)
            var maybe_chain = extract_join_chain(rebuilt^)
            if maybe_chain:
                var chain = maybe_chain.take()
                # Densify the chain
                # graph with transitive equi-join edges derived from join-
                # key equivalence classes. Faithful port of DuckDB's
                # `filter_combiner.cpp:GenerateFilters` O(N**2) closure.
                # Lets DPccp's neighbor traversal form CSGs like Q9's
                # {ps, s, n} that depend on a derived
                # `partsupp <-> supplier` edge from the suppkey class
                # {l_suppkey, s_suppkey, ps_suppkey}. The densification is
                # purely connectivity-level — cost / TDOM machinery is
                # unchanged.
                _ = derive_transitive_edges(chain)
                # Intrinsic selection: DPccp vs greedy.
                var use_dp = should_use_dpccp(chain)
                if use_dp:
                    var dp_result = solve_dpccp(chain)
                    if dp_result:
                        var out = dp_result.take()
                        _join_reorder_fire()
                        # ⚠ TWO LAYERS FOR THE SAME PIERCE DEFECT, COMPOSED.
                        # The inner call
                        # restores the pierced narrow (and DECLINES the reorder
                        # entirely if it cannot); the outer fires only on a
                        # STRICTLY WIDER output (`n <= len(declared)` returns
                        # untouched), so after the inner has run it is a
                        # no-op — a second layer, not a second rewrite.
                        return narrow_reordered_join_to_declared_columns(
                            _restore_chain_output_schema(
                                out^, rebuilt_copy^
                            ),
                            declared_out.copy(),
                        )
                    # Fall through to greedy when DPccp returns None.
                var greedy_out = greedy_join_order(chain^)
                _join_reorder_fire()
                # Same composition as the dpccp arm above — the
                # widening-only outer layer a no-op once the inner
                # restore has succeeded.
                return narrow_reordered_join_to_declared_columns(
                    _restore_chain_output_schema(
                        greedy_out^, rebuilt_copy^
                    ),
                    declared_out^,
                )
            return rebuilt_copy^

        # Non-INNER (or residual-carrying) join: recurse into children
        # and rebuild, preserving the residual.
        var algo = plan._join.value()[].algo_hint
        var residual: Optional[OwnedPointer[Expr]] = None
        if has_resid:
            residual = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        var left = _take_join_left(plan)
        var right = _take_join_right(plan)
        var new_left = reorder_joins_with_dp(left^)
        var new_right = reorder_joins_with_dp(right^)
        var lk = plan._join.value()[].left_on.copy()
        var rk = plan._join.value()[].right_on.copy()
        return LogicalPlan.join(
            new_left^, new_right^, lk^, rk^, jt, algo, residual^,
        )

    elif tag == PLAN_FILTER:
        var child_in = _copy_plan(plan._filter.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._filter.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_PROJECT:
        var child_in = _copy_plan(plan._project.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._project.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_AGGREGATE:
        var child_in = _copy_plan(plan._aggregate.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._aggregate.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_SORT:
        var child_in = _copy_plan(plan._sort.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._sort.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_LIMIT:
        var child_in = _copy_plan(plan._limit.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._limit.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_DISTINCT:
        var child_in = _copy_plan(plan._distinct.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._distinct.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_TOPN:
        var child_in = _copy_plan(plan._topn.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._topn.value()[].child = OwnedPointer(new_child^)

    return plan^
