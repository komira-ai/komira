# =============================================================================
# Direct tests for optimizer_tdom_card: the one-set cardinality estimate
# =============================================================================
#
# The other welded test (test_optimizer_tdom_card_b6_xprod) drives
# estimate_cardinality_with_set through a TPC-H Q9 fixture. These tests pin
# the branches that fixture does not reach: the subgraph-merge walk (extend
# on either side, merge in either order, same-subgraph skip, the
# unused-edge penalty), the sort tie-breaks, the numerator and ceiling
# guards, the cache, the saturation cap, both clamps, the traced sibling
# and the FK-PK signal helpers.
#
# TdomGraphs are built by hand (class TDOMs chosen per test) so each
# expected value is plain arithmetic, written next to its assertion.
# =============================================================================

from std.collections import Dict
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
from komira_optimizer.optimizer_tdom_card import (
    _numerator_for_set,
    _max_base_card_in_set,
    _is_cross_product_shaped_subset,
    _collect_internal_edges_sorted,
    _edge_tdom_for_denom,
    _denominator_for_set,
    _bucket_tier1_signal_on_side,
    _bucket_has_fkpk_signal_local,
    estimate_cardinality_with_set,
    estimate_cardinality_with_set_traced,
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
    """A class whose TDOM is `ndv` from a Tier-1 (HLL) signal."""
    return EquivalenceClass(
        List[ColumnBinding](), Optional[Int](ndv), Optional[Int](), List[Int]()
    )


def _no_hll(ndv: Int) -> EquivalenceClass:
    """A class whose TDOM is `ndv` with no Tier-1 signal (hll_ndv unset)."""
    return EquivalenceClass(
        List[ColumnBinding](), Optional[Int](), Optional[Int](ndv), List[Int]()
    )


def _bucket(a: Int, b: Int, var ei: List[Int]) -> PairBucket:
    return PairBucket(a, b, ei^)


def _bits(var ids: List[Int]) -> UInt64:
    var out = UInt64(0)
    for i in range(len(ids)):
        out |= UInt64(1) << UInt64(ids[i])
    return out


# =============================================================================
# Numerator, ceiling and connectivity helpers
# =============================================================================


def test_numerator_floors_zero_cards_and_ignores_unknown_bits() raises:
    """cards [0, 7, 3] and bit 5 set on a 3-relation chain: 1 * 7 * 3.

    Catches: the `card < 1` floor removed (product 0), or the range check
    removed (reads relation 5 of 3).
    """
    var cards: List[Int] = [0, 7, 3]
    var chain = _chain(cards)
    var combined = _bits([0, 1, 2, 5])
    assert_equal(_numerator_for_set(chain, combined), Float64(21.0))


def test_max_base_card_starts_at_one_and_ignores_unknown_bits() raises:
    """cards [5, 0, 9]: {0, 1, 7} gives 5, {1} gives the floor 1, {2} 9.

    Catches: the running max starting at 0 ({1} would give 0) or the
    range check removed.
    """
    var cards: List[Int] = [5, 0, 9]
    var chain = _chain(cards)
    assert_equal(_max_base_card_in_set(chain, _bits([0, 1, 7])), 5)
    assert_equal(_max_base_card_in_set(chain, _bits([1])), 1)
    assert_equal(_max_base_card_in_set(chain, _bits([2])), 9)


def test_cross_product_shape_edge_cases() raises:
    """An empty chain is never cross-product shaped; a set whose only
    in-range member is one relation is connected; an edge stored as
    (2, 1) unions 2 under 1, so {1, 2} is connected and {0, 1, 2} (0
    isolated) is not.

    Catches: the empty-chain guard removed (indexing an empty parent
    table), out-of-range bits counted as members ({0, 9} would be
    reported cross-product shaped), and the root comparison inverted.
    """
    var empty = JoinChain()
    assert_false(_is_cross_product_shaped_subset(empty, _bits([0, 1])))

    var cards: List[Int] = [1, 1, 1]
    var chain = _chain(cards)
    chain.edges.append(_edge(2, 1, "c", "b"))
    assert_false(_is_cross_product_shaped_subset(chain, _bits([0, 9])))
    assert_false(_is_cross_product_shaped_subset(chain, _bits([1, 2])))
    assert_true(_is_cross_product_shaped_subset(chain, _bits([0, 1, 2])))


# =============================================================================
# Internal-edge sort and per-edge TDOM
# =============================================================================


def test_internal_edges_sort_tdom_desc_then_lr_rr_index() raises:
    """Edges (class TDOM): e0 (0,1) 10, e1 (2,3) 50, e2 (1,2) leftover,
    e3 (0,1) 50, e4 (0,2) 50, e5 (0,1) 50, e6 (3,4) 99 outside the set.
    Over {0,1,2,3}: TDOM 50 first by (lr, rr, index): e3, e5, e4, e1;
    then e0 (10); then the leftover e2 (-1). e6 is excluded.

    Catches: the TDOM comparison inverted, the lr or rr tie-break
    inverted or dropped, the leftover sort key not lowest, and edges
    with an endpoint outside the set kept.
    """
    var cards: List[Int] = [1, 1, 1, 1, 1]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(2, 3, "c", "d"))
    chain.edges.append(_edge(1, 2, "e", "f"))
    chain.edges.append(_edge(0, 1, "g", "h"))
    chain.edges.append(_edge(0, 2, "i", "j"))
    chain.edges.append(_edge(0, 1, "k", "l"))
    chain.edges.append(_edge(3, 4, "m", "n"))
    var classes = List[EquivalenceClass]()
    classes.append(_hll(10))
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(50))
    classes.append(_hll(99))
    var e2c: List[Int] = [0, 1, -1, 2, 3, 4, 5]
    var tdom = TdomGraph(classes^, e2c^)

    var got = _collect_internal_edges_sorted(tdom, chain, _bits([0, 1, 2, 3]))
    var want: List[Int] = [3, 5, 4, 1, 0, 2]
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "sorted position " + String(i))


def test_edge_tdom_for_denom_class_and_leftover() raises:
    """A class edge contributes its class TDOM; a leftover composite edge
    the MAX NDV over both sides' keys (x 100, y 50, p 200, q 25 gives
    200); a leftover edge with no known NDV the floor 1.

    Catches: the right-key loop dropped (100 instead of 200) or the class
    path ignored.
    """
    var cards: List[Int] = [1, 1]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge2(0, 1, "x", "y", "p", "q"))
    chain.edges.append(_edge2(0, 1, "m", "o", "n", "s"))
    var classes = List[EquivalenceClass]()
    classes.append(_hll(42))
    var e2c: List[Int] = [0, -1, -1]
    var tdom = TdomGraph(classes^, e2c^)
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 100, True)
    p.inject(0, "y", 50, True)
    p.inject(1, "p", 200, True)
    p.inject(1, "q", 25, True)
    assert_equal(_edge_tdom_for_denom(tdom, chain, 0, p), Float64(42.0))
    assert_equal(_edge_tdom_for_denom(tdom, chain, 1, p), Float64(200.0))
    assert_equal(_edge_tdom_for_denom(tdom, chain, 2, p), Float64(1.0))


# =============================================================================
# Subgraph-merge denominator walk
# =============================================================================


def test_denominator_walk_extend_merge_and_unused_penalty() raises:
    """Five relations, all edges inside the set, already in TDOM order:
      e0 (0,1) 100   new subgraph {0,1}, denom 100
      e1 (1,0)  90   same subgraph: skipped
      e2 (2,3)  80   new subgraph {2,3}, denom 80
      e3 (4,1)  60   right end in {0,1}: extend to {0,1,4}, 100*60 = 6000
      e4 (1,2)  40   merge (lower index kept): 6000*80*40 = 19_200_000
      e5 (0,2)  30   spanning: unused TDOM 30 recorded
      e6 (1,3)  30   spanning: 30 already recorded
      e7 (0,3)  20   spanning, no HLL signal: not recorded
      e8 (0,4)  leftover composite, spanning: not recorded
    Penalty 1 + |{30}| = 2, so the denominator is 38_400_000.

    Catches: the same-subgraph edge multiplied in, the right-side extend
    dropped, the merge not multiplying both denominators, the unused TDOMs
    not deduplicated (penalty 3), or the HLL gate dropped.
    """
    var cards: List[Int] = [1, 1, 1, 1, 1]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(1, 0, "b", "a"))
    chain.edges.append(_edge(2, 3, "c", "d"))
    chain.edges.append(_edge(4, 1, "e", "f"))
    chain.edges.append(_edge(1, 2, "g", "h"))
    chain.edges.append(_edge(0, 2, "i", "j"))
    chain.edges.append(_edge(1, 3, "k", "l"))
    chain.edges.append(_edge(0, 3, "m", "n"))
    chain.edges.append(_edge2(0, 4, "o", "p", "q", "r"))
    var classes = List[EquivalenceClass]()
    classes.append(_hll(100))
    classes.append(_hll(90))
    classes.append(_hll(80))
    classes.append(_hll(60))
    classes.append(_hll(40))
    classes.append(_hll(30))
    classes.append(_hll(30))
    classes.append(_no_hll(20))
    var e2c: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7, -1]
    var tdom = TdomGraph(classes^, e2c^)
    var p = SyntheticColumnStatsProvider()

    var d = _denominator_for_set(tdom, chain, _bits([0, 1, 2, 3, 4]), p)
    assert_equal(d, Float64(38_400_000.0))


def test_denominator_walk_merge_drops_middle_and_folds_remaining() raises:
    """Six relations: e0 (0,1) 100, e1 (2,3) 80, e2 (4,5) 70 make three
    subgraphs; e3 (3,0) 40 merges subgraph 1 into subgraph 0 (left end in
    the higher index) and shifts {4,5} down. Two subgraphs remain and
    their denominators multiply: 100*80*40 * 70 = 22_400_000. No single
    subgraph ever spans the set, so there is no penalty.

    Catches: the removal not shifting later subgraphs (the {2,3} entry
    would survive: 320_000 * 80), and the final fold over remaining
    subgraphs dropped (320_000).
    """
    var cards: List[Int] = [1, 1, 1, 1, 1, 1]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(2, 3, "c", "d"))
    chain.edges.append(_edge(4, 5, "e", "f"))
    chain.edges.append(_edge(3, 0, "g", "h"))
    var classes = List[EquivalenceClass]()
    classes.append(_hll(100))
    classes.append(_hll(80))
    classes.append(_hll(70))
    classes.append(_hll(40))
    var e2c: List[Int] = [0, 1, 2, 3]
    var tdom = TdomGraph(classes^, e2c^)
    var p = SyntheticColumnStatsProvider()

    var d = _denominator_for_set(tdom, chain, _bits([0, 1, 2, 3, 4, 5]), p)
    assert_equal(d, Float64(22_400_000.0))
    # A singleton has no internal edge and no subgraph: denominator 1.
    assert_equal(_denominator_for_set(tdom, chain, _bits([4]), p), Float64(1.0))


# =============================================================================
# estimate_cardinality_with_set and its traced sibling
# =============================================================================


def _pair_chain(card0: Int, card1: Int) -> JoinChain:
    var cards: List[Int] = [card0, card1]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    return chain^


def _one_class(var c: EquivalenceClass) -> TdomGraph:
    var classes = List[EquivalenceClass]()
    classes.append(c^)
    var e2c: List[Int] = [0]
    return TdomGraph(classes^, e2c^)


def test_estimate_caches_and_returns_cached_value() raises:
    """cards 10 and 20, one edge of TDOM 5: 200 / 5 = 40, stored under
    the set's bits; a pre-filled entry is returned as is.

    Catches: the cache lookup or the cache store removed.
    """
    var chain = _pair_chain(10, 20)
    var tdom = _one_class(_hll(5))
    var p = SyntheticColumnStatsProvider()
    var cache = Dict[UInt64, Int]()
    var s = _bits([0, 1])
    assert_equal(estimate_cardinality_with_set(tdom, chain, s, p, cache), 40)
    assert_equal(cache.get(s).value(), 40)
    cache[s] = 12345
    assert_equal(estimate_cardinality_with_set(tdom, chain, s, p, cache), 12345)


def test_estimate_saturates_at_cap() raises:
    """4e9 * 4e9 / 1 = 1.6e19 is over the 9e18 cap: the estimate is the
    cap. No FK-PK signal (unknown NDVs are 1), and the set is connected.
    The traced sibling reports the same raw values and no clamp.

    Catches: the cap removed (Int conversion of 1.6e19 overflows).
    """
    var chain = _pair_chain(4_000_000_000, 4_000_000_000)
    var tdom = _one_class(_no_hll(1))
    var p = SyntheticColumnStatsProvider()
    var cache = Dict[UInt64, Int]()
    var s = _bits([0, 1])
    var cap = 9_000_000_000_000_000_000
    assert_equal(estimate_cardinality_with_set(tdom, chain, s, p, cache), cap)
    var t = estimate_cardinality_with_set_traced(tdom, chain, s, p)
    assert_equal(t.raw_numerator, Float64(1.6e19))
    assert_equal(t.raw_denominator, Float64(1.0))
    assert_equal(t.raw_card, cap)
    assert_false(t.clamp_fired)
    assert_equal(t.clamp_bound, 4_000_000_000)
    assert_equal(t.final_card, cap)


def test_estimate_floors_below_one() raises:
    """1 * 1 / 10 = 0.1: the estimate is 1. Both sides look like keys
    (unknown NDV 1 equals cardinality 1) but neither has a Tier-1
    signal, so the FK-PK clamp does not fire.

    Catches: the ratio truncated without the floor (0), and the -2
    (both sides) gate accepting Tier-2 evidence.
    """
    var chain = _pair_chain(1, 1)
    var tdom = _one_class(_hll(10))
    var p = SyntheticColumnStatsProvider()
    var cache = Dict[UInt64, Int]()
    var s = _bits([0, 1])
    assert_equal(estimate_cardinality_with_set(tdom, chain, s, p, cache), 1)
    var t = estimate_cardinality_with_set_traced(tdom, chain, s, p)
    assert_equal(t.raw_card_f, Float64(0.1))
    assert_equal(t.raw_card, 1)
    assert_false(t.clamp_fired)
    assert_equal(t.final_card, 1)


def test_estimate_fkpk_clamp_fires_above_and_below_bound() raises:
    """cards 100 and 10; relation 1's key b has Tier-1 NDV 10 = |1|, so
    relation 1 is the PK side. TDOM 1: 1000 is clamped to max(100, 10)
    = 100. TDOM 100: 10 is under the bound and stays 10.

    Catches: the single-side PK path rejected, the clamp bound taken as
    the min, and (traced) the clamp applied without the `est > bound`
    test (the second case would report 100).
    """
    var chain = _pair_chain(100, 10)
    var p = SyntheticColumnStatsProvider()
    p.inject(1, "b", 10, True)
    var s = _bits([0, 1])

    var tdom1 = _one_class(_no_hll(1))
    var cache1 = Dict[UInt64, Int]()
    assert_equal(estimate_cardinality_with_set(tdom1, chain, s, p, cache1), 100)
    var t1 = estimate_cardinality_with_set_traced(tdom1, chain, s, p)
    assert_equal(t1.raw_card, 1000)
    assert_true(t1.clamp_fired)
    assert_equal(t1.clamp_bound, 100)
    assert_equal(t1.final_card, 100)
    var t1c = t1.copy()
    assert_equal(t1c.final_card, 100)
    assert_equal(t1c.raw_numerator, t1.raw_numerator)

    var tdom2 = _one_class(_no_hll(100))
    var cache2 = Dict[UInt64, Int]()
    assert_equal(estimate_cardinality_with_set(tdom2, chain, s, p, cache2), 10)
    var t2 = estimate_cardinality_with_set_traced(tdom2, chain, s, p)
    assert_true(t2.clamp_fired)
    assert_equal(t2.final_card, 10)


def test_estimate_cross_product_clamp() raises:
    """Three relations of 1000 rows, one edge (0,1); relation 2 has no
    edge inside {0,1,2}. TDOM 10: 1e9 / 10 = 1e8, cut to the largest
    base card 1000 by the cross-product clamp (no FK-PK signal: unknown
    NDVs are 1). TDOM 1e7: 100 is under 1000 and stays. The traced
    sibling applies the same clamp: its final card equals the estimate
    (1000 and 100) while its raw card keeps the unclamped 1e8.
    The connected pair {0,1} with TDOM 10 estimates 1e6 / 10 = 1e5,
    above its largest base card 1000, and keeps it.

    Catches: the cross-product clamp removed (1e8), applied without
    its `est > bound` test (the second case would give 1000), or
    applied without its cross-product-shape test (the connected pair
    would give 1000), in either the estimate or the traced sibling.
    """
    var cards: List[Int] = [1000, 1000, 1000]
    var chain = _chain(cards)
    chain.edges.append(_edge(0, 1, "a", "b"))
    var p = SyntheticColumnStatsProvider()
    var s = _bits([0, 1, 2])

    var tdom1 = _one_class(_no_hll(10))
    var cache1 = Dict[UInt64, Int]()
    assert_equal(estimate_cardinality_with_set(tdom1, chain, s, p, cache1), 1000)
    var t1 = estimate_cardinality_with_set_traced(tdom1, chain, s, p)
    assert_false(t1.clamp_fired)
    assert_equal(t1.raw_card, 100_000_000)
    assert_equal(t1.final_card, 1000)

    var tdom2 = _one_class(_no_hll(10_000_000))
    var cache2 = Dict[UInt64, Int]()
    assert_equal(estimate_cardinality_with_set(tdom2, chain, s, p, cache2), 100)
    var t2 = estimate_cardinality_with_set_traced(tdom2, chain, s, p)
    assert_equal(t2.final_card, 100)

    var cache3 = Dict[UInt64, Int]()
    var pair = _bits([0, 1])
    assert_equal(
        estimate_cardinality_with_set(tdom1, chain, pair, p, cache3),
        100_000,
    )
    var t3 = estimate_cardinality_with_set_traced(tdom1, chain, pair, p)
    assert_equal(t3.final_card, 100_000)


# =============================================================================
# FK-PK signal helpers
# =============================================================================


def test_tier1_signal_defensive_and_dedup_paths() raises:
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

    assert_false(_bucket_tier1_signal_on_side(chain, _bucket(0, 1, [0]), 5, p))
    assert_false(_bucket_tier1_signal_on_side(chain, _bucket(0, 7, [0]), 7, p))
    assert_false(_bucket_tier1_signal_on_side(chain, _bucket(-1, 0, [0]), -1, p))
    assert_false(
        _bucket_tier1_signal_on_side(chain, _bucket(0, 1, List[Int]()), 0, p)
    )
    assert_false(
        _bucket_tier1_signal_on_side(chain, _bucket(0, 1, [-1, 99]), 0, p)
    )
    assert_false(_bucket_tier1_signal_on_side(chain, _bucket(0, 1, [2]), 0, p))
    assert_true(_bucket_tier1_signal_on_side(chain, _bucket(0, 1, [0, 1]), 0, p))
    assert_false(
        _bucket_tier1_signal_on_side(chain, _bucket(0, 1, [0, 1]), 1, p)
    )
    assert_true(_bucket_tier1_signal_on_side(chain, _bucket(0, 1, [0]), 1, p))


def _fkpk(a_ndv: Int, a_hll: Bool, b_ndv: Int, b_hll: Bool) raises -> Bool:
    """cards 10 and 20, one edge 0.a = 1.b; a side is a PK candidate when
    its NDV equals its cardinality."""
    var chain = _pair_chain(10, 20)
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "a", a_ndv, a_hll)
    p.inject(1, "b", b_ndv, b_hll)
    return _bucket_has_fkpk_signal_local(chain, _bucket(0, 1, [0]), p)


def test_fkpk_signal_sides() raises:
    """Both sides PK (-2): True if either side is Tier-1, rel_a checked
    first, then rel_b; False if neither. One side PK: that side's Tier-1
    signal decides. Neither PK (-1): False.

    Catches: the rel_b fallback of the -2 case removed (the first case
    would be False), and the single-side case not consulting Tier-1.
    """
    assert_true(_fkpk(10, False, 20, True))
    assert_true(_fkpk(10, True, 20, False))
    assert_false(_fkpk(10, False, 20, False))
    assert_true(_fkpk(3, True, 20, True))
    assert_false(_fkpk(3, True, 20, False))
    assert_false(_fkpk(3, True, 4, True))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
