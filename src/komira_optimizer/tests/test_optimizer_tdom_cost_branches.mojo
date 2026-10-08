# =============================================================================
# Direct tests for optimizer_tdom_cost: the branches the welded
# test_optimizer_tdom_estimate_with_tdom does not reach
# =============================================================================
#
# Pinned here: the bridging-edge sort tie-breaks (lr, rr, index) and the
# leftover sort key, the cardinality floors, the zero-denominator guard,
# the single-side FK-PK clamp, the -2 case's rel_b fallback, and the
# defensive paths of the Tier-1 gate. TdomGraphs are built by hand so each
# expected value is plain arithmetic, written next to its assertion.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from komira_plan_stats.table_stats import TableStats
from komira_optimizer.optimizer_reorder import (
    JoinRelation,
    JoinEdge,
    JoinChain,
    RelationSet,
)
from komira_optimizer.optimizer_column_stats_provider import (
    SyntheticColumnStatsProvider,
)
from komira_optimizer.optimizer_tdom import (
    ColumnBinding,
    EquivalenceClass,
    PairBucket,
    TdomGraph,
)
from komira_optimizer.optimizer_tdom_cost import (
    _collect_and_sort_bridging,
    _all_bucket_cols_have_hll_signal,
    _bucket_has_fkpk_signal,
    estimate_with_tdom,
)


# =============================================================================
# Fixture helpers
# =============================================================================


def _scan(name: String, card: Int) -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(name + "_k", ArrowType.INT64, False))
    var schema = b.build()
    var ts: Optional[TableStats] = None
    var rc: Optional[Int] = Optional[Int](card)
    var filt: Optional[Expr] = None
    var proj: Optional[List[String]] = None
    return LogicalPlan.scan(
        name + ".parquet", SOURCE_PARQUET, schema^, proj^, filt^, rc^, ts^,
    )


def _chain(cards: List[Int]) -> JoinChain:
    """A chain whose relation i has cardinality cards[i] and no edges."""
    var chain = JoinChain()
    for i in range(len(cards)):
        chain.relations.append(
            JoinRelation(
                i, _scan("r" + String(i), cards[i]), cards[i],
                Optional[TableStats](),
            )
        )
    return chain^


def _edge(l: Int, r: Int, lk: String, rk: String) -> JoinEdge:
    var lks: List[String] = [lk]
    var rks: List[String] = [rk]
    return JoinEdge(l, r, lks^, rks^)


def _edge2(
    l: Int, r: Int, lk1: String, lk2: String, rk1: String, rk2: String
) -> JoinEdge:
    var lks: List[String] = [lk1, lk2]
    var rks: List[String] = [rk1, rk2]
    return JoinEdge(l, r, lks^, rks^)


def _hll(ndv: Int) -> EquivalenceClass:
    return EquivalenceClass(
        List[ColumnBinding](), Optional[Int](ndv), Optional[Int](), List[Int]()
    )


def _no_hll(ndv: Int) -> EquivalenceClass:
    return EquivalenceClass(
        List[ColumnBinding](), Optional[Int](), Optional[Int](ndv), List[Int]()
    )


def _one_class(var c: EquivalenceClass) -> TdomGraph:
    var classes = List[EquivalenceClass]()
    classes.append(c^)
    var e2c: List[Int] = [0]
    return TdomGraph(classes^, e2c^)


def _bucket(a: Int, b: Int, var ei: List[Int]) -> PairBucket:
    return PairBucket(a, b, ei^)


def _pair_chain(card0: Int, card1: Int) -> JoinChain:
    var cards: List[Int] = [card0, card1]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    return chain^


# =============================================================================
# Bridging-edge sort
# =============================================================================


def test_bridging_sort_tie_breaks_and_leftover_last() raises:
    """left {0,1}, right {2,3}. Edges (class TDOM): e0 (1,2) 50,
    e1 (0,3) 50, e2 (0,2) 50, e3 (0,2) 50, e4 (1,2) leftover,
    e5 (0,1) 50 internal to the left (not bridging), e6 (3,0) 70.
    Order: e6 (70); then TDOM 50 by (lr, rr, index): e2, e3, e1, e0;
    then the leftover e4.

    Catches: the lr tie-break inverted or dropped (e0 would lead the
    50s), the rr tie-break inverted (e1 before e2), the leftover not
    sorting last, a non-bridging edge kept, and the TDOM order inverted.
    """
    var cards: List[Int] = [1, 1, 1, 1]
    var chain = _chain(cards)
    chain.edges.append(_edge(1, 2, "a", "b"))
    chain.edges.append(_edge(0, 3, "c", "d"))
    chain.edges.append(_edge(0, 2, "e", "f"))
    chain.edges.append(_edge(0, 2, "g", "h"))
    chain.edges.append(_edge(1, 2, "i", "j"))
    chain.edges.append(_edge(0, 1, "k", "l"))
    chain.edges.append(_edge(3, 0, "m", "n"))
    var classes = List[EquivalenceClass]()
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(70))
    var e2c: List[Int] = [0, 1, 2, 3, -1, 4, 5]
    var tdom = TdomGraph(classes^, e2c^)
    var left = RelationSet.singleton(0).union(RelationSet.singleton(1))
    var right = RelationSet.singleton(2).union(RelationSet.singleton(3))

    var got = _collect_and_sort_bridging(tdom, chain, left, right)
    var want: List[Int] = [6, 2, 3, 1, 0, 4]
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "sorted position " + String(i))


# =============================================================================
# estimate_with_tdom floors and guards
# =============================================================================


def test_estimate_floors_cards_and_result() raises:
    """cards 1000 and 1000, one edge of TDOM 10, unknown NDVs (1, so no
    FK-PK signal). A left or right cardinality under 1 counts as 1:
    1 * 1000 / 10 = 100 either way. 1 * 1 / 10 = 0 is raised to 1.

    Catches: the left or right floor removed (0 * 1000 gives 0, then 1;
    -5 * 1000 gives a negative, then 1), and the result floor removed
    (0).
    """
    var chain = _pair_chain(1000, 1000)
    var tdom = _one_class(_no_hll(10))
    var p = SyntheticColumnStatsProvider()
    var l = RelationSet.singleton(0)
    var r = RelationSet.singleton(1)
    assert_equal(estimate_with_tdom(tdom, chain, l, r, 0, 1000, p), 100)
    assert_equal(estimate_with_tdom(tdom, chain, l, r, 1000, 0, p), 100)
    assert_equal(estimate_with_tdom(tdom, chain, l, r, 1000, -5, p), 100)
    assert_equal(estimate_with_tdom(tdom, chain, l, r, 1, 1, p), 1)


def test_estimate_zero_denominator_guard() raises:
    """Two leftover composite edges whose max NDVs are 2^32 each: the Int
    product 2^64 wraps to 0 (Mojo Int multiplication wraps), and the
    guard sets the denominator to 1, so 100 * 7 / 1 = 700. Composite
    edges form no pair bucket, so no clamp applies.

    Catches: the `denom <= 0` guard removed (a division by zero).
    """
    var cards: List[Int] = [100, 7]
    var chain = _chain(cards)
    chain.edges.append(_edge2(0, 1, "a", "b", "c", "d"))
    chain.edges.append(_edge2(0, 1, "e", "f", "g", "h"))
    var classes = List[EquivalenceClass]()
    var e2c: List[Int] = [-1, -1]
    var tdom = TdomGraph(classes^, e2c^)
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "a", 4_294_967_296, True)
    p.inject(0, "e", 4_294_967_296, True)
    var l = RelationSet.singleton(0)
    var r = RelationSet.singleton(1)
    assert_equal(estimate_with_tdom(tdom, chain, l, r, 100, 7, p), 700)


def test_estimate_single_side_fkpk_clamp() raises:
    """cards 1000 and 50; relation 1's key b has NDV 50 = |1|, relation
    0's key a is unknown (1), so relation 1 alone is the PK side.
      - b Tier-1, TDOM 1: 1000 * 50 = 50_000 is clamped to 1000;
      - b not Tier-1, TDOM 1: no clamp, 50_000;
      - b Tier-1, TDOM 100: 500 is under the bound and stays.

    Catches: the single-side branch skipping the Tier-1 gate (the second
    case would be 1000), the clamp not firing for one PK side, and the
    clamp applied without its `est > bound` test (the third case would
    be 1000).
    """
    var chain = _pair_chain(1000, 50)
    var l = RelationSet.singleton(0)
    var r = RelationSet.singleton(1)

    var p1 = SyntheticColumnStatsProvider()
    p1.inject(1, "b", 50, True)
    var t1 = _one_class(_no_hll(1))
    assert_equal(estimate_with_tdom(t1, chain, l, r, 1000, 50, p1), 1000)

    var p2 = SyntheticColumnStatsProvider()
    p2.inject(1, "b", 50, False)
    assert_equal(estimate_with_tdom(t1, chain, l, r, 1000, 50, p2), 50_000)

    var t3 = _one_class(_no_hll(100))
    assert_equal(estimate_with_tdom(t3, chain, l, r, 1000, 50, p1), 500)


# =============================================================================
# FK-PK signal helpers
# =============================================================================


def test_fkpk_both_sides_falls_back_to_rel_b() raises:
    """cards 10 and 20, edge 0.a = 1.b, NDVs equal to the cards on both
    sides (-2). Only b is Tier-1: the rel_a check fails and the rel_b
    check passes.

    Catches: the -2 case returning the rel_a result alone.
    """
    var chain = _pair_chain(10, 20)
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "a", 10, False)
    p.inject(1, "b", 20, True)
    assert_true(_bucket_has_fkpk_signal(chain, _bucket(0, 1, [0]), p))


def test_tier1_gate_defensive_and_dedup_paths() raises:
    """Edges e0 (0,1) a=b, e1 (0,1) a=c, e2 (2,3) u=v; a and b Tier-1,
    c not.
      - a relation outside the bucket, a bucket endpoint out of range
        (7, -1), an empty bucket, edge indices out of range, and an edge
        that does not touch the relation all give False;
      - relation 0 sees column a twice and is Tier-1: True;
      - relation 1 sees b (Tier-1) then c (not): False;
      - relation 1 through e0 alone (the right-side column): True.

    Catches: the Tier-1 rejection removed (relation 1 would pass), a
    vacuous bucket accepted, or the right-side column lookup dropped.
    """
    var cards: List[Int] = [10, 10]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(0, 1, "a", "c"))
    chain.edges.append(_edge(2, 3, "u", "v"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "a", 10, True)
    p.inject(1, "b", 10, True)
    p.inject(1, "c", 10, False)

    assert_false(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 1, [0]), 5, p)
    )
    assert_false(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 7, [0]), 7, p)
    )
    assert_false(
        _all_bucket_cols_have_hll_signal(chain, _bucket(-1, 0, [0]), -1, p)
    )
    assert_false(
        _all_bucket_cols_have_hll_signal(
            chain, _bucket(0, 1, List[Int]()), 0, p
        )
    )
    assert_false(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 1, [-1, 99]), 0, p)
    )
    assert_false(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 1, [2]), 0, p)
    )
    assert_true(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 1, [0, 1]), 0, p)
    )
    assert_false(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 1, [0, 1]), 1, p)
    )
    assert_true(
        _all_bucket_cols_have_hll_signal(chain, _bucket(0, 1, [0]), 1, p)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
