# =============================================================================
# Q5 join order — DPccp cost-model regression w/ synthetic NDVs
# =============================================================================
#
# Verifies that `solve_dpccp_with_cost` (with its TDOM graph) emits a plan
# with a JOIN that has `lineitem` on one side, `supplier` on the other and
# `l_suppkey = s_suppkey` among its keys, for the Q5-shaped 6-relation
# chain. Call this Plan B — the lineitem-supplier-early shape; the TDOM
# cost tests price its lineitem-supplier pair at ~6M rows against ~60M
# for the customer-supplier fan-out pair (Plan A).
#
# We construct deterministic NDVs by writing `TableStats` directly onto
# each `JoinRelation` (Tier-1 path through `DefaultColumnStatsProvider`),
# mirroring the production data flow inside `_cost_for_pair`:
#   solve_dpccp_with_cost
#     ├─ build_tdom_graph(chain, DefaultColumnStatsProvider(chain.relations))
#     └─ _cost_for_pair(..., tdom_opt=<built graph>, ...)
#          └─ estimate_cardinality_with_set(tdom, chain, ..., DefaultColumnStatsProvider(chain.relations))
# Both call sites resolve NDVs through Tier-1 `relation.table_stats` when
# we pre-populate them — so the NDVs we inject DETERMINISTICALLY drive the
# DPccp cost ranking.
#
# Assertion shape: we assert on the
# emitted LogicalPlan tree, NOT on `final_card` (which is path-independent
# under TDOM). The structural check looks for a JOIN node whose left
# subtree contains lineitem and right subtree supplier (or the reverse),
# neither holding both, with `l_suppkey = s_suppkey` among its keys
# (Plan B shape). Other leaves may sit on either side.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_reorder import (
    RelationSet,
    JoinRelation,
    JoinEdge,
    JoinChain,
)
from komira_optimizer.optimizer_dpccp import (
    solve_dpccp,
    solve_dpccp_with_cost,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Q5 fixture constants (mirror the TDOM design's worked example)
# =============================================================================

comptime R_LINEITEM: Int = 0
comptime R_ORDERS: Int = 1
comptime R_CUSTOMER: Int = 2
comptime R_SUPPLIER: Int = 3
comptime R_NATION: Int = 4
comptime R_REGION: Int = 5

# SF1 row counts (Q5 worked-example baseline).
comptime SF1_LINEITEM: Int = 6_001_215
comptime SF1_ORDERS: Int = 1_500_000
comptime SF1_CUSTOMER: Int = 150_000
comptime SF1_SUPPLIER: Int = 10_000
comptime SF1_NATION: Int = 25
comptime SF1_REGION: Int = 5


# =============================================================================
# Fixture helpers
# =============================================================================


def _two_col_schema(col_a: String, col_b: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(col_a, ArrowType.INT64, False))
    b.add_field(Field(col_b, ArrowType.INT64, False))
    return b.build()


def _three_col_schema(c1: String, c2: String, c3: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    b.add_field(Field(c2, ArrowType.INT64, False))
    b.add_field(Field(c3, ArrowType.INT64, False))
    return b.build()


def _scan(path: String, var schema: Schema, n: Int) -> LogicalPlan:
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, rc^
    )


def _column_stats(distinct: Int) -> ColumnStats:
    """Build a ColumnStats with only `distinct_count` populated."""
    var dc: Optional[Int] = distinct
    var min_v: Optional[ScalarValue] = None
    var max_v: Optional[ScalarValue] = None
    var nc: Optional[Int] = None
    return ColumnStats(dc^, min_v^, max_v^, nc^)


def _ts(
    cardinality: Int,
    var col_names: List[String],
    col_distincts: List[Int],
) -> Optional[TableStats]:
    """Build a Tier-1 TableStats with one (name, distinct) pair per column."""
    var stats = List[ColumnStats]()
    for i in range(len(col_distincts)):
        stats.append(_column_stats(col_distincts[i]))
    return TableStats(
        cardinality, col_names^, stats^, STATS_SOURCE_PARQUET_METADATA
    )


def _mk_edge(
    lr: Int, rr: Int, lk: String, rk: String
) -> JoinEdge:
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return JoinEdge(lr, rr, lks^, rks^)


# =============================================================================
# Build the full Q5-shaped chain with Tier-1 NDVs that match the design
# =============================================================================


def _build_q5_chain_tier1() -> JoinChain:
    """Construct Q5's 6-relation chain WITH Tier-1 distinct counts on every
    join key. NDVs match the TDOM design's worked example:
        l_orderkey: 1.5M    (FK into orders → matches o_orderkey)
        l_suppkey:  10K     (FK into supplier → matches s_suppkey)
        o_orderkey: 1.5M, o_custkey: 150K
        c_custkey:  150K,   c_nationkey: 25
        s_suppkey:  10K,    s_nationkey: 25
        n_nationkey: 25,    n_regionkey: 5
        r_regionkey: 5
    These are the canonical PK-FK identities for the SF1 fixture.
    """
    var chain = JoinChain()

    # lineitem(0): keys l_orderkey, l_suppkey.
    var lineitem_names = List[String]()
    lineitem_names.append("l_orderkey")
    lineitem_names.append("l_suppkey")
    var lineitem_distincts = List[Int]()
    lineitem_distincts.append(1_500_000)  # NDV(l_orderkey)
    lineitem_distincts.append(10_000)     # NDV(l_suppkey)
    var ts_li = _ts(SF1_LINEITEM, lineitem_names^, lineitem_distincts^)
    var li_schema = _two_col_schema("l_orderkey", "l_suppkey")
    chain.relations.append(JoinRelation(
        R_LINEITEM,
        _scan("lineitem.parquet", li_schema^, SF1_LINEITEM),
        SF1_LINEITEM,
        ts_li^,
    ))

    # orders(1): keys o_orderkey, o_custkey.
    var orders_names = List[String]()
    orders_names.append("o_orderkey")
    orders_names.append("o_custkey")
    var orders_distincts = List[Int]()
    orders_distincts.append(1_500_000)  # NDV(o_orderkey)
    orders_distincts.append(150_000)    # NDV(o_custkey)
    var ts_o = _ts(SF1_ORDERS, orders_names^, orders_distincts^)
    var o_schema = _two_col_schema("o_orderkey", "o_custkey")
    chain.relations.append(JoinRelation(
        R_ORDERS,
        _scan("orders.parquet", o_schema^, SF1_ORDERS),
        SF1_ORDERS,
        ts_o^,
    ))

    # customer(2): keys c_custkey, c_nationkey.
    var customer_names = List[String]()
    customer_names.append("c_custkey")
    customer_names.append("c_nationkey")
    var customer_distincts = List[Int]()
    customer_distincts.append(150_000)  # NDV(c_custkey)
    customer_distincts.append(25)       # NDV(c_nationkey)
    var ts_c = _ts(SF1_CUSTOMER, customer_names^, customer_distincts^)
    var c_schema = _two_col_schema("c_custkey", "c_nationkey")
    chain.relations.append(JoinRelation(
        R_CUSTOMER,
        _scan("customer.parquet", c_schema^, SF1_CUSTOMER),
        SF1_CUSTOMER,
        ts_c^,
    ))

    # supplier(3): keys s_suppkey, s_nationkey.
    var supplier_names = List[String]()
    supplier_names.append("s_suppkey")
    supplier_names.append("s_nationkey")
    var supplier_distincts = List[Int]()
    supplier_distincts.append(10_000)   # NDV(s_suppkey)
    supplier_distincts.append(25)       # NDV(s_nationkey)
    var ts_s = _ts(SF1_SUPPLIER, supplier_names^, supplier_distincts^)
    var s_schema = _two_col_schema("s_suppkey", "s_nationkey")
    chain.relations.append(JoinRelation(
        R_SUPPLIER,
        _scan("supplier.parquet", s_schema^, SF1_SUPPLIER),
        SF1_SUPPLIER,
        ts_s^,
    ))

    # nation(4): keys n_nationkey, n_regionkey.
    var nation_names = List[String]()
    nation_names.append("n_nationkey")
    nation_names.append("n_regionkey")
    var nation_distincts = List[Int]()
    nation_distincts.append(25)         # NDV(n_nationkey)
    nation_distincts.append(5)          # NDV(n_regionkey)
    var ts_n = _ts(SF1_NATION, nation_names^, nation_distincts^)
    var n_schema = _two_col_schema("n_nationkey", "n_regionkey")
    chain.relations.append(JoinRelation(
        R_NATION,
        _scan("nation.parquet", n_schema^, SF1_NATION),
        SF1_NATION,
        ts_n^,
    ))

    # region(5): key r_regionkey.
    var region_names = List[String]()
    region_names.append("r_regionkey")
    var region_distincts = List[Int]()
    region_distincts.append(5)          # NDV(r_regionkey)
    var ts_r = _ts(SF1_REGION, region_names^, region_distincts^)
    var r_b = SchemaBuilder()
    r_b.add_field(Field("r_regionkey", ArrowType.INT64, False))
    var r_schema = r_b.build()
    chain.relations.append(JoinRelation(
        R_REGION,
        _scan("region.parquet", r_schema^, SF1_REGION),
        SF1_REGION,
        ts_r^,
    ))

    # 6 per-column edges:
    chain.edges.append(_mk_edge(R_LINEITEM, R_ORDERS, "l_orderkey", "o_orderkey"))      # e0a
    chain.edges.append(_mk_edge(R_LINEITEM, R_SUPPLIER, "l_suppkey", "s_suppkey"))      # e0b
    chain.edges.append(_mk_edge(R_ORDERS, R_CUSTOMER, "o_custkey", "c_custkey"))        # e1
    chain.edges.append(_mk_edge(R_CUSTOMER, R_SUPPLIER, "c_nationkey", "s_nationkey"))  # e2
    chain.edges.append(_mk_edge(R_SUPPLIER, R_NATION, "s_nationkey", "n_nationkey"))    # e3
    chain.edges.append(_mk_edge(R_NATION, R_REGION, "n_regionkey", "r_regionkey"))      # e4
    return chain^


# =============================================================================
# Plan-shape walker
# =============================================================================


def _plan_leaf_scan_paths(plan: LogicalPlan, mut out: List[String]):
    """Recurse the plan tree, collecting every leaf-scan source_path into
    `out`. Used by the structural assertion to identify which leaves live
    under which subtree.
    """
    if plan.tag == PLAN_SCAN and plan._scan:
        out.append(String(plan._scan.value()[].source_path))
        return
    if plan.tag == PLAN_JOIN and plan._join:
        _plan_leaf_scan_paths(plan._join.value()[].left[], out)
        _plan_leaf_scan_paths(plan._join.value()[].right[], out)
        return
    # Other node kinds (Project, Filter, etc.) contribute no leaves: the
    # walk does not descend into them.
    if plan.tag != PLAN_SCAN and plan.tag != PLAN_JOIN:
        # No child plumbing needed for this test — the solved plans it
        # walks are Scan/Join only.
        pass


def _subtree_contains(plan: LogicalPlan, path_substr: String) -> Bool:
    """True iff some leaf-scan path under `plan` contains `path_substr`."""
    var paths = List[String]()
    _plan_leaf_scan_paths(plan, paths)
    for i in range(len(paths)):
        # String.find returns Int (-1 on miss).
        if paths[i].find(path_substr) >= 0:
            return True
    return False


def _find_customer_supplier_leading_pair(p: LogicalPlan) -> Bool:
    """Find a JOIN whose two immediate subtrees are exactly {customer}
    and {supplier} (one leaf each) — the legacy fan-out leading-pair
    shape that the TDOM cost model should NOT pick.
    """
    if p.tag != PLAN_JOIN or not p._join:
        return False
    ref jd = p._join.value()[]
    var l_paths = List[String]()
    _plan_leaf_scan_paths(jd.left[], l_paths)
    var r_paths = List[String]()
    _plan_leaf_scan_paths(jd.right[], r_paths)
    if len(l_paths) == 1 and len(r_paths) == 1:
        var l_is_c = l_paths[0].find("customer") >= 0
        var r_is_s = r_paths[0].find("supplier") >= 0
        var l_is_s = l_paths[0].find("supplier") >= 0
        var r_is_c = r_paths[0].find("customer") >= 0
        if (l_is_c and r_is_s) or (l_is_s and r_is_c):
            return True
    if _find_customer_supplier_leading_pair(jd.left[]):
        return True
    if _find_customer_supplier_leading_pair(jd.right[]):
        return True
    return False


def _find_lineitem_supplier_adjacent_join(plan: LogicalPlan) -> Bool:
    """Recursively search for a JOIN node whose two immediate subtrees
    are on OPPOSITE sides of lineitem and supplier — i.e. one side
    contains lineitem (and possibly others) AND the other side contains
    supplier (and possibly others). Their join condition (left_on /
    right_on) MUST include the `l_suppkey = s_suppkey` per-column edge
    or `s_suppkey = l_suppkey` reversed.

    The helper does not require lineitem and supplier to be direct
    singleton-each siblings: the TDOM-aware plan may be bushy, with the
    two inside opposite halves of a split. The TDOM cost test
    `test_q5_lineitem_supplier_early_cost_pair` prices
    `lineitem ⋈ supplier` at 6_001_215 rows, against 60M for the
    customer-supplier pair (`test_q5_customer_supplier_fanout_cost_pair`).

    What we MUST confirm: the plan threads lineitem and supplier via the
    `l_suppkey = s_suppkey` join condition (i.e. they end up joined to
    each other SOMEWHERE), NOT via the legacy `c_nationkey = s_nationkey`
    fan-out as a leading pair. This is the structural rebalancing.
    """
    if plan.tag != PLAN_JOIN or not plan._join:
        return False
    ref jd = plan._join.value()[]
    var left_has_li = _subtree_contains(jd.left[], "lineitem")
    var right_has_li = _subtree_contains(jd.right[], "lineitem")
    var left_has_s = _subtree_contains(jd.left[], "supplier")
    var right_has_s = _subtree_contains(jd.right[], "supplier")

    # opposite-sides shape: lineitem on one side, supplier on the other.
    var li_left_s_right = left_has_li and right_has_s and not right_has_li and not left_has_s
    var s_left_li_right = left_has_s and right_has_li and not right_has_s and not left_has_li
    if li_left_s_right or s_left_li_right:
        # Confirm the join condition includes the `l_suppkey = s_suppkey`
        # equality (or its reverse) — the lineitem-supplier per-column
        # edge from the chain extractor. If this holds, lineitem-supplier are
        # logically joined at THIS node.
        for i in range(len(jd.left_on)):
            var lk = jd.left_on[i]
            var rk = jd.right_on[i]
            if (lk == "l_suppkey" and rk == "s_suppkey") or (
                lk == "s_suppkey" and rk == "l_suppkey"
            ):
                return True

    # Recurse into both subtrees.
    if _find_lineitem_supplier_adjacent_join(jd.left[]):
        return True
    if _find_lineitem_supplier_adjacent_join(jd.right[]):
        return True
    return False


# =============================================================================
# Tests
# =============================================================================


def test_q5_chain_builds_with_tier1_ndvs() raises:
    """Fixture sanity: the Q5 chain constructs cleanly with 6 relations
    and 6 per-column edges; every relation carries Tier-1 stats."""
    var chain = _build_q5_chain_tier1()
    assert_equal(len(chain.relations), 6)
    assert_equal(len(chain.edges), 6)
    # Confirm every relation has table_stats (Tier-1 NDV signal present).
    for i in range(6):
        assert_true(
            Bool(chain.relations[i].table_stats),
            "every Q5 relation must carry Tier-1 NDV stats for the cost model",
        )


def test_q5_solve_dpccp_returns_plan() raises:
    """The TDOM cost model produces a non-None plan for the Q5 chain
    (DPccp completes within iteration bounds; full-set DP entry is
    populated)."""
    var chain = _build_q5_chain_tier1()
    var plan_opt = solve_dpccp(chain)
    assert_true(
        Bool(plan_opt),
        "solve_dpccp must return a plan for the Q5 6-relation chain",
    )


def test_q5_plan_shape_lineitem_supplier_adjacent() raises:
    """The load-bearing correctness check: with the TDOM-aware cost
    model, DPccp produces the lineitem-supplier-early plan (Plan B).

    Asserts on plan STRUCTURE (final_card
    is path-independent under TDOM; sum_intermediate / plan-shape is the
    discriminating signal):
        * The emitted plan tree contains a JOIN node with lineitem in one
          immediate subtree and supplier in the other (neither subtree
          holding both; other leaves allowed), whose keys include
          `l_suppkey = s_suppkey`.

    Under the TDOM cost model the lineitem-supplier pair is ~10× cheaper
    than the customer-supplier pair (per the design and the TDOM cost
    tests), so DPccp joins lineitem and supplier on that key.
    """
    var chain = _build_q5_chain_tier1()
    var plan_opt = solve_dpccp(chain)
    assert_true(
        Bool(plan_opt),
        "solve_dpccp must return a plan for Q5 fixture",
    )
    var plan = plan_opt.take()
    assert_true(
        _find_lineitem_supplier_adjacent_join(plan),
        "plan-shape: lineitem and supplier must sit on opposite sides "
        "of a join keyed on l_suppkey = s_suppkey (Plan B shape). "
        "If this fails, the TDOM cost model is not influencing DPccp — "
        "verify build_tdom_graph is wired into solve_dpccp_with_cost.",
    )


def test_q5_plan_does_not_lead_with_customer_supplier_fanout() raises:
    """Negative check: the emitted plan does NOT have a JOIN whose
    immediate subtrees are {customer} ⋈ {supplier} (the earlier fan-out
    shape, Plan A).

    The legacy customer-supplier-via-nationkey join carries the 60M
    cost under the TDOM denominator (per the design +
    test_q5_customer_supplier_fanout_cost_pair), against 6M for the
    lineitem-supplier pair. This test asserts that no JOIN in the plan
    pairs the single leaves customer and supplier.
    """
    var chain = _build_q5_chain_tier1()
    var plan_opt = solve_dpccp(chain)
    assert_true(Bool(plan_opt))
    var plan = plan_opt.take()

    assert_false(
        _find_customer_supplier_leading_pair(plan),
        "plan-shape: customer⋈supplier must NOT be picked as a "
        "leading pair under the TDOM cost model (Plan A is rejected).",
    )


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
