# =============================================================================
# Cost-model FK-PK clamp on cross-product
# =============================================================================
#
# An FK-PK upper-bound clamp applies to cross-product-shaped subsets at the
# `estimate_cardinality_with_set` Step 5b path. The clamp fires when a
# subset's internal explicit edges do NOT span all its member relations
# (e.g. Q9's `{ps, s, n}`, where only s↔n is an explicit edge —
# partsupp is "disconnected" within the subset).
#
# Without the clamp, the subgraph-merge walk produces a denom that
# under-estimates the join multiplier for disconnected pieces, and the
# numerator's full base-card product over-counts the disconnected
# relations' rows. Q9's `{ps,s,n}` cardinality overshoots DuckDB's ~898K to
# a Cartesian-scale estimate, which would make a DPccp enumerator (not in
# this tree) pick a degenerate partition over partition A.
#
# This test file pins:
#   1. The `_is_cross_product_shaped_subset` helper detection (unit).
#   2. Q5 contract: no clamp fires on connected subsets (regression-guard).
#   3. Q9 cross-product-shaped `{ps,s,n}` clamp lifts the estimate to
#      max(base_cards in set), bounded by 800K (DuckDB shape).
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_optimizer.optimizer_reorder import (
    JoinRelation,
    JoinEdge,
    JoinChain,
)
from komira_optimizer.optimizer_tdom_card import (
    _is_cross_product_shaped_subset,
    estimate_cardinality_with_set,
    estimate_cardinality_with_set_traced,
    _max_base_card_in_set,
)
from komira_optimizer.optimizer_tdom import (
    build_tdom_graph,
    TdomGraph,
)
from komira_optimizer.optimizer_column_stats_provider import (
    SyntheticColumnStatsProvider,
)
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
)
from komira_plan_expr.expr import Expr
from komira_plan_stats.table_stats import TableStats


# =============================================================================
# Q9 SF1 fixture
# =============================================================================

comptime R_LINEITEM: Int = 0
comptime R_PART: Int = 1
comptime R_ORDERS: Int = 2
comptime R_PARTSUPP: Int = 3
comptime R_SUPPLIER: Int = 4
comptime R_NATION: Int = 5

comptime SF1_LINEITEM: Int = 6_001_215
comptime SF1_PART_POST_FILTER: Int = 40_000
comptime SF1_ORDERS: Int = 1_500_000
comptime SF1_PARTSUPP: Int = 800_000
comptime SF1_SUPPLIER: Int = 10_000
comptime SF1_NATION: Int = 25


def _scan(name: String, card: Int) -> LogicalPlan:
    """Build a one-column SCAN plan with a known cardinality."""
    var b = SchemaBuilder()
    b.add_field(Field(name + "_pk", ArrowType.INT64, False))
    var schema = b.build()
    var ts: Optional[TableStats] = None
    var rc: Optional[Int] = Optional[Int](card)
    var filt: Optional[Expr] = None
    var proj: Optional[List[String]] = None
    return LogicalPlan.scan(
        name + ".parquet", SOURCE_PARQUET, schema^, proj^, filt^, rc^, ts^,
    )


def _mk_edge(l_rel: Int, r_rel: Int, l_key: String, r_key: String) -> JoinEdge:
    var lks = List[String](); lks.append(l_key)
    var rks = List[String](); rks.append(r_key)
    return JoinEdge(l_rel, r_rel, lks^, rks^)


def _build_q9_6edge_chain_40k() -> JoinChain:
    """6-relation Q9 fixture with 6 explicit edges + post-filter 40K part.

    Edges (per-column split, NO transitive partsupp-supplier edge):
      0. l_orderkey  = o_orderkey   (lineitem ↔ orders)
      1. l_partkey   = p_partkey    (lineitem ↔ part)
      2. l_partkey   = ps_partkey   (lineitem ↔ partsupp; composite key 1)
      3. l_suppkey   = ps_suppkey   (lineitem ↔ partsupp; composite key 2)
      4. l_suppkey   = s_suppkey    (lineitem ↔ supplier)
      5. s_nationkey = n_nationkey  (supplier ↔ nation)
    """
    var chain = JoinChain()
    chain.relations.append(JoinRelation(R_LINEITEM, _scan("lineitem", SF1_LINEITEM),
                                        SF1_LINEITEM, Optional[TableStats]()))
    chain.relations.append(JoinRelation(R_PART, _scan("part_filtered",
                                                      SF1_PART_POST_FILTER),
                                        SF1_PART_POST_FILTER,
                                        Optional[TableStats]()))
    chain.relations.append(JoinRelation(R_ORDERS, _scan("orders", SF1_ORDERS),
                                        SF1_ORDERS, Optional[TableStats]()))
    chain.relations.append(JoinRelation(R_PARTSUPP, _scan("partsupp", SF1_PARTSUPP),
                                        SF1_PARTSUPP, Optional[TableStats]()))
    chain.relations.append(JoinRelation(R_SUPPLIER, _scan("supplier", SF1_SUPPLIER),
                                        SF1_SUPPLIER, Optional[TableStats]()))
    chain.relations.append(JoinRelation(R_NATION, _scan("nation", SF1_NATION),
                                        SF1_NATION, Optional[TableStats]()))

    chain.edges.append(_mk_edge(R_LINEITEM, R_ORDERS, "l_orderkey", "o_orderkey"))
    chain.edges.append(_mk_edge(R_LINEITEM, R_PART, "l_partkey", "p_partkey"))
    chain.edges.append(_mk_edge(R_LINEITEM, R_PARTSUPP, "l_partkey", "ps_partkey"))
    chain.edges.append(_mk_edge(R_LINEITEM, R_PARTSUPP, "l_suppkey", "ps_suppkey"))
    chain.edges.append(_mk_edge(R_LINEITEM, R_SUPPLIER, "l_suppkey", "s_suppkey"))
    chain.edges.append(_mk_edge(R_SUPPLIER, R_NATION, "s_nationkey", "n_nationkey"))

    return chain^


def _q9_provider() -> SyntheticColumnStatsProvider:
    """SF1 NDV provider matching Q9's composite-NDV truth.

    All injections use `from_hll=True` (Tier-1 backing) so the
    composite-NDV PK signal is reachable for any bucket
    that fits within the subset under test.
    """
    var p = SyntheticColumnStatsProvider()
    p.inject(R_LINEITEM, "l_orderkey",  SF1_ORDERS, True)
    p.inject(R_LINEITEM, "l_partkey",   200_000, True)
    p.inject(R_LINEITEM, "l_suppkey",   SF1_SUPPLIER, True)
    p.inject(R_PART,     "p_partkey",   SF1_PART_POST_FILTER, True)
    p.inject(R_ORDERS,   "o_orderkey",  SF1_ORDERS, True)
    p.inject(R_PARTSUPP, "ps_partkey",  200_000, True)
    p.inject(R_PARTSUPP, "ps_suppkey",  SF1_SUPPLIER, True)
    p.inject(R_SUPPLIER, "s_suppkey",   SF1_SUPPLIER, True)
    p.inject(R_SUPPLIER, "s_nationkey", SF1_NATION, True)
    p.inject(R_NATION,   "n_nationkey", SF1_NATION, True)
    return p^


# =============================================================================
# Unit tests for _is_cross_product_shaped_subset
# =============================================================================


def test_b6_xprod_detection_q9_psn_is_cross_product() raises:
    """`{partsupp, supplier, nation}` over the Q9 6-edge graph has only
    `s↔n` as internal edge — partsupp is isolated → cross-product shaped.
    """
    var chain = _build_q9_6edge_chain_40k()
    var psn_bits = (
        (UInt64(1) << UInt64(R_PARTSUPP))
        | (UInt64(1) << UInt64(R_SUPPLIER))
        | (UInt64(1) << UInt64(R_NATION))
    )
    var is_xp = _is_cross_product_shaped_subset(chain, psn_bits)
    assert_true(is_xp,
                "{ps,s,n} should be detected as cross-product shaped — "
                "only s↔n is an internal explicit edge, ps is isolated.")


def test_b6_xprod_detection_q9_lpo_is_connected() raises:
    """`{lineitem, part, orders}` over Q9 6-edge graph has both
    `lineitem↔orders` AND `lineitem↔part` as internal edges → CONNECTED.
    """
    var chain = _build_q9_6edge_chain_40k()
    var lpo_bits = (
        (UInt64(1) << UInt64(R_LINEITEM))
        | (UInt64(1) << UInt64(R_PART))
        | (UInt64(1) << UInt64(R_ORDERS))
    )
    var is_xp = _is_cross_product_shaped_subset(chain, lpo_bits)
    assert_false(is_xp,
                 "{l,p,o} is connected through lineitem-hub — must not "
                 "be flagged as cross-product shaped.")


def test_b6_xprod_detection_singleton_is_connected() raises:
    """A single-relation subset is trivially connected (NOT cross-product)."""
    var chain = _build_q9_6edge_chain_40k()
    var s_bits = UInt64(1) << UInt64(R_PARTSUPP)
    var is_xp = _is_cross_product_shaped_subset(chain, s_bits)
    assert_false(is_xp, "Singleton must be reported connected.")


def test_b6_xprod_detection_full_q9_is_connected() raises:
    """The full 6-rel Q9 graph is connected through lineitem (the hub).

    Even though `{ps,s,n}` alone is cross-product shaped, the FULL set
    `{l,p,o,ps,s,n}` is connected: lineitem links to every other rel
    directly or via lineitem-orders → lineitem-supplier → supplier-nation.
    """
    var chain = _build_q9_6edge_chain_40k()
    var full_bits = (UInt64(1) << UInt64(6)) - UInt64(1)
    var is_xp = _is_cross_product_shaped_subset(chain, full_bits)
    assert_false(is_xp,
                 "Full Q9 graph is connected via lineitem hub. Must not "
                 "be flagged cross-product.")


def test_b6_xprod_detection_pure_singletons_two_rels_no_edge() raises:
    """Two relations with no explicit edge between them in the subset
    → cross-product shaped."""
    var chain = _build_q9_6edge_chain_40k()
    # part + nation — neither is connected to the other in the 6-edge graph
    # (part connects only to lineitem; nation connects only to supplier).
    var pn_bits = (UInt64(1) << UInt64(R_PART)) | (UInt64(1) << UInt64(R_NATION))
    var is_xp = _is_cross_product_shaped_subset(chain, pn_bits)
    assert_true(is_xp,
                "{part, nation} has no internal explicit edge in the "
                "6-edge Q9 graph; must be cross-product shaped.")


# =============================================================================
# Cross-product clamp wiring: cross-product set's estimate is bounded by max_base_card
# =============================================================================


def test_b6_q9_psn_card_clamped_to_max_base() raises:
    """The load-bearing assertion: `{ps,s,n}` cardinality is clamped at
    max(SF1_PARTSUPP, SF1_SUPPLIER, SF1_NATION) = 800K.

    Without a clamp: a Cartesian-scale estimate (8e9 raw in the
    no-Tier-1 trace below). With one: clamped at 800K.

    Two clamps can cap `{ps,s,n}`. With the Tier-1 provider the FK-PK
    clamp (Step 5) fires first: in the supplier-nation bucket, nation's
    key NDV 25 equals |nation|. The second half drops the Tier-1
    backing, so the FK-PK gate rejects and only the cross-product clamp
    (Step 5b) can cap the estimate.

    DuckDB's Q9 cardinality for `{ps,s,n}` is ~898K, the external
    reference. The 800K ceiling sits below it by design (the (b) clamp
    approximation is the chosen tradeoff vs the deeper (a)
    equivalence-class-driven denom walk); the test accepts down to 700K.
    """
    var chain = _build_q9_6edge_chain_40k()
    var provider = _q9_provider()
    var tdom = build_tdom_graph(chain, provider)

    var psn_bits = (
        (UInt64(1) << UInt64(R_PARTSUPP))
        | (UInt64(1) << UInt64(R_SUPPLIER))
        | (UInt64(1) << UInt64(R_NATION))
    )

    var cache = Dict[UInt64, Int]()
    var card = estimate_cardinality_with_set(
        tdom, chain, psn_bits, provider, cache,
    )

    # Clamp bound = max(800K, 10K, 25) = 800K.
    var bound = _max_base_card_in_set(chain, psn_bits)
    assert_equal(bound, SF1_PARTSUPP)

    # The cardinality should be capped at the bound. Without a clamp it
    # would be Cartesian-scale; we assert <= bound.
    assert_true(card <= bound,
                "clamp must cap {ps,s,n} cardinality at max base card "
                "(800K). Got card=" + String(card))

    # Lower bound 700K: the clamp ceiling is max_base (800K), not the
    # post-join card, so an estimate under DuckDB's 898K is accepted.
    assert_true(card >= 700_000,
                "clamp should not crush {ps,s,n} below 700K. Got "
                + String(card))

    # The Tier-1 run above is capped by the FK-PK clamp (Step 5).
    var trace = estimate_cardinality_with_set_traced(
        tdom, chain, psn_bits, provider,
    )
    assert_true(trace.clamp_fired,
                "Tier-1: the FK-PK clamp fires on {ps,s,n}")

    # Same NDVs without Tier-1 backing: the FK-PK gate rejects, so the
    # cross-product clamp (Step 5b) alone must cap the estimate. The
    # traced sibling applies Step 5b too: its raw card is the unclamped
    # 800K * 10K * 25 / 25 = 8e9 and its final card the 800K estimate.
    # Catches: Step 5b removed, or its cross-product test inverted, in
    # either the estimate or the traced sibling.
    var provider2 = SyntheticColumnStatsProvider()
    provider2.inject(R_LINEITEM, "l_orderkey",  SF1_ORDERS, False)
    provider2.inject(R_LINEITEM, "l_partkey",   200_000, False)
    provider2.inject(R_LINEITEM, "l_suppkey",   SF1_SUPPLIER, False)
    provider2.inject(R_PART,     "p_partkey",   SF1_PART_POST_FILTER, False)
    provider2.inject(R_ORDERS,   "o_orderkey",  SF1_ORDERS, False)
    provider2.inject(R_PARTSUPP, "ps_partkey",  200_000, False)
    provider2.inject(R_PARTSUPP, "ps_suppkey",  SF1_SUPPLIER, False)
    provider2.inject(R_SUPPLIER, "s_suppkey",   SF1_SUPPLIER, False)
    provider2.inject(R_SUPPLIER, "s_nationkey", SF1_NATION, False)
    provider2.inject(R_NATION,   "n_nationkey", SF1_NATION, False)
    var tdom2 = build_tdom_graph(chain, provider2)
    var trace2 = estimate_cardinality_with_set_traced(
        tdom2, chain, psn_bits, provider2,
    )
    assert_false(trace2.clamp_fired,
                 "no Tier-1 backing: the FK-PK gate must reject")
    assert_equal(trace2.raw_card, 8_000_000_000)
    assert_equal(trace2.final_card, SF1_PARTSUPP)
    var cache2 = Dict[UInt64, Int]()
    var card2 = estimate_cardinality_with_set(
        tdom2, chain, psn_bits, provider2, cache2,
    )
    assert_equal(card2, SF1_PARTSUPP,
                 "the cross-product clamp alone caps {ps,s,n} at 800K")


def test_b6_q9_lpo_card_unchanged_by_xprod_clamp() raises:
    """`{l,p,o}` is connected → cross-product clamp does NOT fire.

    Regression-guard: the cross-product clamp must NOT misfire on connected
    subsets. `{l,p,o}` should reach DuckDB's ~1.26M (within 10%
    of it).
    """
    var chain = _build_q9_6edge_chain_40k()
    var provider = _q9_provider()
    var tdom = build_tdom_graph(chain, provider)

    var lpo_bits = (
        (UInt64(1) << UInt64(R_LINEITEM))
        | (UInt64(1) << UInt64(R_PART))
        | (UInt64(1) << UInt64(R_ORDERS))
    )

    var cache = Dict[UInt64, Int]()
    var card = estimate_cardinality_with_set(
        tdom, chain, lpo_bits, provider, cache,
    )

    # The cross-product clamp must not fire on the connected `{l,p,o}`
    # subset, so the estimate stays where the unclamped walk puts it.
    # Acceptance window: within 10% of DuckDB's 1.26M, as the docstring
    # states (1_134_000 to 1_386_000).
    assert_true(card >= 1_134_000 and card <= 1_386_000,
                "must preserve {l,p,o} cardinality near DuckDB's "
                "1.26M. Got card=" + String(card))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
