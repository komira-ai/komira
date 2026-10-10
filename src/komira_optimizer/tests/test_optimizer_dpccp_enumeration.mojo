# =============================================================================
# optimizer_dpccp: selection helpers, the cost of one pair, the three
# enumerators and the cross-product fallback
# =============================================================================
#
# test_optimizer_dpccp and the Q5 tests drive `solve_dpccp` end to end on
# connected chains that always carry a TDOM graph. This file reaches what they do not: the
# row-count probe through Filter and Project (and the shapes it refuses),
# the neighbour, component and augmentation helpers, the legacy
# (no-TDOM) cost of a pair with real, synthesized and absent stats,
# every refusal and cardinality arm of `emit_pair`, the iteration cap at
# each of its return points, the seed sort, and the cross-product fallback
# of `solve_dpccp_with_cost` (top-level CROSS rejected, deeper CROSS
# accepted, augmented pass over the cap).
#
# Each test names the defect it catches.
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
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
from komira_optimizer.optimizer_reorder import (
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
)
from komira_optimizer.optimizer_tdom import TdomGraph, build_tdom_graph
from komira_optimizer.optimizer_column_stats_provider import (
    DefaultColumnStatsProvider,
)
from komira_optimizer.optimizer_dpccp import (
    DPNode,
    DPCCP_MAX_RELATIONS,
    _IterCounter,
    _leaf_has_row_count,
    _build_neighbors,
    _compute_relation_components,
    _relation_graph_is_connected,
    _should_trigger_cross_product_augmentation,
    _augment_neighbors_with_cross_products,
    _row_count_ndv_estimate,
    _synth_row_count_table_stats,
    _cost_for_pair,
    _seed_dp_base_relations,
    _run_dpccp_passes,
    _plan_has_synthesized_cross,
    emit_pair,
    emit_csg_complements,
    enumerate_csg_rec,
    enumerate_complement_rec,
    solve_dpccp_with_cost,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan(name: String, rows: Optional[Int]) -> LogicalPlan:
    """One INT64 column `name`; `rows` is the scan's row_count (or None)."""
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    var rc = rows
    return LogicalPlan.scan(name + ".parquet", SOURCE_PARQUET, _schema(name), proj^, filt^, rc^)


def _ndv_stats(key: String, ndv: Int, rows: Int) -> TableStats:
    var names = List[String]()
    names.append(key)
    var cols = List[ColumnStats]()
    cols.append(ColumnStats(Optional[Int](ndv)))
    return TableStats(rows, names^, cols^, STATS_SOURCE_PARQUET_METADATA)


def _chain(
    n: Int, card: Int, ls: List[Int], rs: List[Int], with_rows: Bool = True
) -> JoinChain:
    """Relations r0..r{n-1} (column k{i}, cardinality `card`, a scan row
    count iff `with_rows`), one edge k{ls[j]} = k{rs[j]} per index j."""
    var chain = JoinChain()
    for i in range(n):
        var rows: Optional[Int] = None
        if with_rows:
            rows = card
        chain.relations.append(JoinRelation(i, _scan("k" + String(i), rows), card))
    for j in range(len(ls)):
        var lk = List[String]()
        lk.append("k" + String(ls[j]))
        var rk = List[String]()
        rk.append("k" + String(rs[j]))
        chain.edges.append(JoinEdge(ls[j], rs[j], lk^, rk^))
    return chain^


def _k4() -> JoinChain:
    """The complete graph on four relations, edges in ascending order."""
    return _chain(4, 100, [0, 0, 0, 1, 1, 2], [1, 2, 3, 2, 3, 3])


def _bits(ids: List[Int]) -> UInt64:
    var out = UInt64(0)
    for i in range(len(ids)):
        out |= UInt64(1) << UInt64(ids[i])
    return out


def _seeded(n: Int, chain: JoinChain) -> Dict[UInt64, DPNode]:
    var dp = Dict[UInt64, DPNode]()
    _seed_dp_base_relations(n, chain, dp)
    return dp^


def _over_counter() -> _IterCounter:
    """A counter already past its cap of zero."""
    var c = _IterCounter(UInt64(0))
    c.bump()
    return c^


# =============================================================================
# _leaf_has_row_count
# =============================================================================


def test_leaf_row_count_through_filter_and_project() raises:
    """A row count under a Filter or a Project counts. Catches: the Filter
    or Project descent removed (the chain would lose its row-count signal
    and fall back to greedy)."""
    var pred = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
    assert_true(_leaf_has_row_count(LogicalPlan.filter(pred^, _scan("a", 10))))
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    assert_true(_leaf_has_row_count(LogicalPlan.project(e^, _scan("a", 10))))


def test_leaf_row_count_refuses_other_shapes() raises:
    """No row count, an Aggregate leaf, and Scan/Filter/Project nodes that
    carry no payload all answer False. Catches: a missing row count read as
    a signal, an Aggregate treated as a base relation, and a payload-less
    node dereferenced."""
    assert_false(_leaf_has_row_count(_scan("a", None)))
    var keys = ExprArray()
    keys.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    var none_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_child^, Optional[String](String("n"))))
    assert_false(_leaf_has_row_count(LogicalPlan.aggregate(keys^, aggs^, _scan("a", 10))))
    assert_false(_leaf_has_row_count(LogicalPlan(PLAN_SCAN, _schema("a"))))
    assert_false(_leaf_has_row_count(LogicalPlan(PLAN_FILTER, _schema("a"))))
    assert_false(_leaf_has_row_count(LogicalPlan(PLAN_PROJECT, _schema("a"))))


# =============================================================================
# Graph helpers
# =============================================================================


def test_build_neighbors_dedups_repeated_edges() raises:
    """Edges 0-1, 1-0 and 0-1 give one neighbour each way. Catches: the
    dedup removed (a repeated seed would be emitted twice)."""
    var chain = _chain(2, 10, [0, 1, 0], [1, 0, 1])
    var nb = _build_neighbors(2, chain.edges)
    assert_equal(len(nb[0]), 1)
    assert_equal(nb[0][0], 1)
    assert_equal(len(nb[1]), 1)
    assert_equal(nb[1][0], 0)


def test_components_and_connectivity() raises:
    """Edges 0-1, 1-2 and 3-4: components [0,0,0,1,1], not connected; the
    path 0-1-2 alone is connected; zero or one relation is connected.
    Catches: a visited relation re-seeded as a new component, and a
    disconnected graph reported connected."""
    var chain = _chain(5, 10, [0, 1, 3], [1, 2, 4])
    var nb = _build_neighbors(5, chain.edges)
    var parent = _compute_relation_components(5, nb)
    assert_equal(parent[0], 0)
    assert_equal(parent[1], 0)
    assert_equal(parent[2], 0)
    assert_equal(parent[3], 1)
    assert_equal(parent[4], 1)
    assert_false(_relation_graph_is_connected(5, nb))
    var path = _chain(3, 10, [0, 1], [1, 2])
    assert_true(_relation_graph_is_connected(3, _build_neighbors(3, path.edges)))
    var empty = List[List[Int]]()
    assert_true(_relation_graph_is_connected(0, empty))
    var single = List[List[Int]]()
    single.append(List[Int]())
    assert_true(_relation_graph_is_connected(1, single))


def test_augment_adds_only_missing_pairs() raises:
    """Three relations with the edge 0-1: augmentation adds 0-2 and 1-2 and
    does not repeat 0-1. Catches: the adjacency check removed (0-1 doubled)
    and a pair skipped."""
    var chain = _chain(3, 10, [0], [1])
    var aug = _augment_neighbors_with_cross_products(3, _build_neighbors(3, chain.edges))
    assert_equal(len(aug[0]), 2)
    assert_equal(aug[0][0], 1)
    assert_equal(aug[0][1], 2)
    assert_equal(len(aug[1]), 2)
    assert_equal(aug[1][1], 2)
    assert_equal(len(aug[2]), 2)
    assert_equal(aug[2][0], 0)
    assert_equal(aug[2][1], 1)


def test_trigger_fires_only_without_full_set() raises:
    """Catches: the trigger inverted (augmentation on a connected graph)."""
    var dp = Dict[UInt64, DPNode]()
    assert_true(_should_trigger_cross_product_augmentation(dp, UInt64(3)))
    dp[UInt64(3)] = DPNode(Float64(1.0), 1, RelationSet.singleton(0), RelationSet.singleton(1))
    assert_false(_should_trigger_cross_product_augmentation(dp, UInt64(3)))


# =============================================================================
# Row-count NDV fallback
# =============================================================================


def test_row_count_ndv_estimate_arms() raises:
    """card // 10, floored at 1 for 1..9 rows, 0 for no rows. Catches: the
    floor removed (a 0 divisor for small relations) and a non-positive
    card read as a signal."""
    assert_equal(_row_count_ndv_estimate(1000), 100)
    assert_equal(_row_count_ndv_estimate(7), 1)
    assert_equal(_row_count_ndv_estimate(0), 0)
    assert_equal(_row_count_ndv_estimate(-5), 0)


def test_synth_stats_arms() raises:
    """No row count, no keys, or no rows give None; otherwise every key gets
    the same NDV and the synthetic source. Catches: stats synthesized
    without a row count, a key left without NDV (the FK-PK helper would
    short-circuit), and the source marked as footer metadata."""
    var keys = List[String]()
    keys.append("x")
    keys.append("y")
    assert_false(Bool(_synth_row_count_table_stats(_scan("a", None), 100, keys)))
    assert_false(Bool(_synth_row_count_table_stats(_scan("a", 100), 100, List[String]())))
    assert_false(Bool(_synth_row_count_table_stats(_scan("a", 100), 0, keys)))
    var ts = _synth_row_count_table_stats(_scan("a", 100), 250, keys).value().copy()
    assert_equal(ts.column_distinct_count("x").value(), 25)
    assert_equal(ts.column_distinct_count("y").value(), 25)
    assert_equal(ts.source, STATS_SOURCE_SYNTHETIC_ROW_COUNT)
    assert_equal(ts.row_count, 250)


# =============================================================================
# _cost_for_pair without a TDOM graph (the legacy NDV path)
# =============================================================================


def test_cost_for_pair_uses_table_stats_of_a_singleton() raises:
    """r0 (1000 rows, NDV(k0) = 800) against r1 (100 rows, no stats, no row
    count): 1000 * 100 / 800 = 125. Catches: the table_stats branch
    replaced by the row-count synthesis (1000 * 100 / 100 = 1000) or
    dropped (max(1000, 100) = 1000)."""
    var chain = JoinChain()
    var ts: Optional[TableStats] = _ndv_stats("k0", 800, 1000)
    chain.relations.append(JoinRelation(0, _scan("k0", 1000), 1000, ts^))
    chain.relations.append(JoinRelation(1, _scan("k1", None), 100))
    chain.edges.append(JoinEdge(0, 1, ["k0"], ["k1"]))
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var c = _cost_for_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), 1000, 100,
        chain, Dict[UInt64, Int](), none_tdom, cache,
    )
    assert_equal(c, 125)


def test_cost_for_pair_synthesizes_from_row_count() raises:
    """Left = r1 (5000 rows, a row count, listed second), right = r0 (1000
    rows, nothing): NDV(k1) = 500, so 5000 * 1000 / 500 = 10000. Catches:
    the synthesis removed (max = 5000) and the id lookup stopping at the
    first relation instead of the matching one."""
    var chain = JoinChain()
    chain.relations.append(JoinRelation(0, _scan("k0", None), 1000))
    chain.relations.append(JoinRelation(1, _scan("k1", 5000), 5000))
    chain.edges.append(JoinEdge(0, 1, ["k0"], ["k1"]))
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var c = _cost_for_pair(
        RelationSet.singleton(1), RelationSet.singleton(0), 5000, 1000,
        chain, Dict[UInt64, Int](), none_tdom, cache,
    )
    assert_equal(c, 10000)


def test_cost_for_pair_composite_side_has_no_stats() raises:
    """Left = {r0, r1} (a composite whose r0 has NDV(k0) = 2000), right = r2
    with NDV(k2) = 400 over 1000 rows: only the singleton's stats count,
    3000 * 1000 / 400 = 7500. Catches: a composite side given its first
    relation's stats (divisor 2000, estimate 1500)."""
    var chain = JoinChain()
    var ts0: Optional[TableStats] = _ndv_stats("k0", 2000, 3000)
    chain.relations.append(JoinRelation(0, _scan("k0", None), 3000, ts0^))
    chain.relations.append(JoinRelation(1, _scan("k1", None), 3000))
    var ts2: Optional[TableStats] = _ndv_stats("k2", 400, 1000)
    chain.relations.append(JoinRelation(2, _scan("k2", None), 1000, ts2^))
    chain.edges.append(JoinEdge(0, 1, ["k0"], ["k1"]))
    chain.edges.append(JoinEdge(0, 2, ["k0"], ["k2"]))
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var c = _cost_for_pair(
        RelationSet(_bits([0, 1])), RelationSet.singleton(2), 3000, 1000,
        chain, Dict[UInt64, Int](), none_tdom, cache,
    )
    assert_equal(c, 7500)


# =============================================================================
# emit_pair
# =============================================================================


def test_emit_pair_needs_both_entries() raises:
    """A pair whose left or right subset has no DP entry is not scored.
    Catches: either presence check removed (a pair built on an unreached
    subset would enter the table)."""
    var chain = _chain(2, 10, [0], [1])
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var only_right = Dict[UInt64, DPNode]()
    only_right[UInt64(2)] = DPNode(Float64(0.0), 10, RelationSet.empty(), RelationSet.empty())
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, only_right,
        Dict[UInt64, Int](), none_tdom, cache,
    )
    assert_equal(len(only_right), 1)
    var only_left = Dict[UInt64, DPNode]()
    only_left[UInt64(1)] = DPNode(Float64(0.0), 10, RelationSet.empty(), RelationSet.empty())
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, only_left,
        Dict[UInt64, Int](), none_tdom, cache,
    )
    assert_equal(len(only_left), 1)


def test_emit_pair_needs_a_real_edge_unless_cross_is_allowed() raises:
    """Two relations (3 and 7 rows) with no edge: refused by default; with
    `allow_cross` and no TDOM graph the Cartesian product (21) is the join
    card and the cost. Catches: the real-edge gate removed, and the cross
    arm costing anything but the product."""
    var chain = _chain(2, 10, List[Int](), List[Int]())
    var dp = Dict[UInt64, DPNode]()
    dp[UInt64(1)] = DPNode(Float64(0.0), 3, RelationSet.empty(), RelationSet.empty())
    dp[UInt64(2)] = DPNode(Float64(0.0), 7, RelationSet.empty(), RelationSet.empty())
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, dp,
        Dict[UInt64, Int](), none_tdom, cache,
    )
    assert_equal(len(dp), 2)
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, dp,
        Dict[UInt64, Int](), none_tdom, cache, True,
    )
    var e = dp.get(UInt64(3)).value().copy()
    assert_equal(e.cardinality, 21)
    assert_equal(e.cost, Float64(21.0))


def _cross_card(left_card: Int, right_card: Int) raises -> Int:
    """The join card `emit_pair` records for a cross pair without TDOM."""
    var chain = _chain(2, 10, List[Int](), List[Int]())
    var dp = Dict[UInt64, DPNode]()
    dp[UInt64(1)] = DPNode(Float64(0.0), left_card, RelationSet.empty(), RelationSet.empty())
    dp[UInt64(2)] = DPNode(Float64(0.0), right_card, RelationSet.empty(), RelationSet.empty())
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, dp,
        Dict[UInt64, Int](), none_tdom, cache, True,
    )
    return dp.get(UInt64(3)).value().cardinality


def test_emit_pair_cross_card_non_positive_and_saturated() raises:
    """A non-positive side takes the larger card (0,7 -> 7; 5,-1 -> 5); a
    product past the cap saturates at 2^62 - 1; a product of exactly
    2^62 - 2 (left = SAT_CAP // right) does not. Catches: a 0 or negative
    product recorded, either side of the larger-card choice swapped, an
    overflowing product wrapping, and the saturation test widened to
    `>=` (the boundary row would read 2^62 - 1)."""
    assert_equal(_cross_card(0, 7), 7)
    assert_equal(_cross_card(5, -1), 5)
    assert_equal(_cross_card(1 << 40, 1 << 30), 4_611_686_018_427_387_903)
    assert_equal(
        _cross_card(4_611_686_018_427_387_903 // 2, 2),
        4_611_686_018_427_387_902,
    )


def test_emit_pair_cross_card_goes_through_tdom_when_present() raises:
    """With a TDOM graph the cross pair is costed by `_cost_for_pair` (here
    its override, 42), not the Cartesian product (21). Catches: the TDOM
    arm of the cross branch removed."""
    var chain = _chain(2, 10, List[Int](), List[Int]())
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom: Optional[TdomGraph] = build_tdom_graph(chain, provider)
    var dp = Dict[UInt64, DPNode]()
    dp[UInt64(1)] = DPNode(Float64(0.0), 3, RelationSet.empty(), RelationSet.empty())
    dp[UInt64(2)] = DPNode(Float64(0.0), 7, RelationSet.empty(), RelationSet.empty())
    var cost = Dict[UInt64, Int]()
    cost[UInt64(3)] = 42
    var cache = Dict[UInt64, Int]()
    emit_pair(
        RelationSet.singleton(0), RelationSet.singleton(1), chain, dp,
        cost, tdom, cache, True,
    )
    assert_equal(dp.get(UInt64(3)).value().cardinality, 42)


def test_emit_pair_keeps_the_cheaper_entry() raises:
    """Scoring the same pair at 100, then 50, then 70 leaves 50. Catches:
    the update condition inverted or made unconditional."""
    var chain = _chain(2, 10, [0], [1])
    var dp = _seeded(2, chain)
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var cards = List[Int]()
    cards.append(100)
    cards.append(50)
    cards.append(70)
    for i in range(3):
        var cost = Dict[UInt64, Int]()
        cost[UInt64(3)] = cards[i]
        emit_pair(
            RelationSet.singleton(0), RelationSet.singleton(1), chain, dp,
            cost, none_tdom, cache,
        )
    var e = dp.get(UInt64(3)).value().copy()
    assert_equal(e.cardinality, 50)
    assert_equal(e.cost, Float64(50.0))


# =============================================================================
# The enumerators and the iteration cap
# =============================================================================


def test_enumerators_return_when_the_counter_is_already_over() raises:
    """Each enumerator entered with an exhausted counter emits nothing and
    counts nothing. Catches: any of the three entry checks removed (the
    call would bump the counter and add DP entries)."""
    var chain = _k4()
    var nb = _build_neighbors(4, chain.edges)
    var dp = _seeded(4, chain)
    var cost = Dict[UInt64, Int]()
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var c1 = _over_counter()
    emit_csg_complements(
        RelationSet.singleton(0), RelationSet.empty(), nb, chain, dp, c1,
        cost, none_tdom, cache,
    )
    assert_equal(c1.n, UInt64(1))
    var c2 = _over_counter()
    enumerate_csg_rec(
        RelationSet.singleton(0), RelationSet.empty(), nb, chain, dp, c2,
        cost, none_tdom, cache,
    )
    assert_equal(c2.n, UInt64(1))
    var c3 = _over_counter()
    enumerate_complement_rec(
        RelationSet.singleton(1), RelationSet.singleton(0), RelationSet.empty(),
        nb, chain, dp, c3, cost, none_tdom, cache,
    )
    assert_equal(c3.n, UInt64(1))
    assert_equal(len(dp), 4)


def _passes(cap: Int, mut dp: Dict[UInt64, DPNode]) raises -> Tuple[Bool, UInt64]:
    var chain = _k4()
    var nb = _build_neighbors(4, chain.edges)
    var counter = _IterCounter(UInt64(cap))
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    var ok = _run_dpccp_passes(
        4, chain, nb, dp, counter, Dict[UInt64, Int](), none_tdom, cache, False
    )
    return (ok, counter.n)


def test_run_passes_stop_at_the_first_count_past_the_cap() raises:
    """On the complete graph K4 (40 pair emits in all): cap 9 overflows
    inside a complement extension (the complement, csg-complement and
    first-pass returns fire), cap 26 inside a csg extension (the
    csg-complement, csg and second-pass returns fire); both stop at
    exactly cap + 1. A cap of 1000 completes with all 40 and the full set.
    Catches: a pass reported complete after an overflow, and the
    complement-extension or csg-complement return after a recursive call
    removed (cap 9 would count 11). The other post-call returns are backed
    by the entry checks (tested above), so removing one alone changes no
    count; this test executes each of them."""
    var dp9 = Dict[UInt64, DPNode]()
    _seed_dp_base_relations(4, _k4(), dp9)
    var r9 = _passes(9, dp9)
    assert_false(r9[0])
    assert_equal(r9[1], UInt64(10))
    var dp26 = Dict[UInt64, DPNode]()
    _seed_dp_base_relations(4, _k4(), dp26)
    var r26 = _passes(26, dp26)
    assert_false(r26[0])
    assert_equal(r26[1], UInt64(27))
    var dp = Dict[UInt64, DPNode]()
    _seed_dp_base_relations(4, _k4(), dp)
    var r = _passes(1000, dp)
    assert_true(r[0])
    assert_equal(r[1], UInt64(40))
    assert_true(Bool(dp.get(UInt64(15))))


def test_seed_order_is_canonical() raises:
    """Edges (0,1), (1,3), (2,1) list relation 1's neighbours as 0, 3, 2.
    With every multi-relation subset costing 10, {1,2,3} ties between
    {1,2}|{3} and {1,3}|{2}; the first emitted wins, and sorted seeds emit
    {1,2}|{3} first. Catches: the seed sort removed (the DP table would
    depend on edge order: {1,3}|{2})."""
    var chain = _chain(4, 100, [0, 1, 2], [1, 3, 1])
    var nb = _build_neighbors(4, chain.edges)
    var dp = _seeded(4, chain)
    var cost = Dict[UInt64, Int]()
    for bits in range(1, 16):
        if bits & (bits - 1) != 0:
            cost[UInt64(bits)] = 10
    var counter = _IterCounter(UInt64(1000))
    var cache = Dict[UInt64, Int]()
    var none_tdom: Optional[TdomGraph] = None
    assert_true(
        _run_dpccp_passes(4, chain, nb, dp, counter, cost, none_tdom, cache, False)
    )
    var e = dp.get(_bits([1, 2, 3])).value().copy()
    assert_equal(e.best_left.bits, _bits([1, 2]))
    assert_equal(e.best_right.bits, _bits([3]))


# =============================================================================
# solve_dpccp_with_cost: the cross-product fallback
# =============================================================================


def _cost_all(n: Int, value: Int) -> Dict[UInt64, Int]:
    """Every subset of n relations with two or more members costs `value`."""
    var cost = Dict[UInt64, Int]()
    for bits in range(1, 1 << n):
        if bits & (bits - 1) != 0:
            cost[UInt64(bits)] = value
    return cost^


def test_solve_rejects_a_cross_product_at_the_top() raises:
    """Components {0,1} and {2,3}: the augmented pass's cheapest full plan
    joins the two components at the root with no keys, so the solver
    returns None (the caller falls back to greedy). Catches: the top-level
    CROSS guard removed (a keyless root join would be returned)."""
    var chain = _chain(4, 100, [0, 2], [1, 3])
    var cost = _cost_all(4, 1_000_000_000)
    cost[_bits([0, 1])] = 1
    cost[_bits([2, 3])] = 1
    cost[UInt64(15)] = 5
    assert_false(Bool(solve_dpccp_with_cost(chain, cost)))


def test_solve_accepts_a_cross_product_below_the_root() raises:
    """Edge 0-1, relation 2 isolated, {1,2} cheap: the plan is r0 joined on
    k0 = k1 to CROSS(r1, r2). The root has keys, so it is returned.
    Catches: the augmentation removed (no plan), the augmented winner not
    replayed into the table, and the guard rejecting a deeper CROSS."""
    var chain = _chain(3, 100, [0], [1])
    var cost = _cost_all(3, 1_000_000_000)
    cost[_bits([1, 2])] = 1
    cost[UInt64(7)] = 5
    var result = solve_dpccp_with_cost(chain, cost)
    assert_true(Bool(result))
    var plan = result.take()
    assert_true(plan.is_join())
    assert_equal(len(plan.join_data_ref().left_on), 1)
    assert_true(_plan_has_synthesized_cross(plan))


def test_solve_returns_none_when_the_augmented_pass_overflows() raises:
    """Twelve relations and no edges: the first pass emits nothing, the
    augmented pass runs on the complete graph and overflows the iteration
    cap, so there is no plan. Catches: an overflowed augmented table read
    as a result."""
    var chain = _chain(DPCCP_MAX_RELATIONS, 100, List[Int](), List[Int]())
    assert_false(Bool(solve_dpccp_with_cost(chain, Dict[UInt64, Int]())))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
