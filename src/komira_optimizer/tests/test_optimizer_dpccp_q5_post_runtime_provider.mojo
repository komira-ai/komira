# =============================================================================
# Q5 join order — end-to-end DPccp w/ DefaultColumnStatsProvider Tier-2
# =============================================================================
#
# Sibling of `test_optimizer_dpccp_q5_synthetic.mojo`. Same plan-shape
# acceptance test, but exercises the Tier-2 row-count fallback path
# inside `DefaultColumnStatsProvider` — the case where no relation
# carries `table_stats`, so no column has a per-column NDV.
#
# Under Tier-2: NDV(key) = the leaf scan's row_count, which equals
# relation.cardinality in this fixture. The TDOM module's
# `_ingest_provider_value` takes `MIN-across-class` for `from_hll=False`
# values (as DuckDB's cardinality_estimator.cpp does), so each class's TDOM
# collapses to the smallest row count of any relation in that class:
#     C(suppkey)    = MIN(SF1_LINEITEM=6M, SF1_SUPPLIER=10K)              = 10K
#     C(orderkey)   = MIN(SF1_LINEITEM=6M, SF1_ORDERS=1.5M)               = 1.5M
#     C(custkey)    = MIN(SF1_ORDERS=1.5M, SF1_CUSTOMER=150K)             = 150K
#     C(nationkey)  = MIN(SF1_CUSTOMER=150K, SF1_SUPPLIER=10K, SF1_NATION=25) = 25
#     C(regionkey)  = MIN(SF1_NATION=25, SF1_REGION=5)                    = 5
#
# Why this path matters: a Q5 chain whose relations carry no `table_stats`
# takes it for every edge (no per-column NDV → Tier-2).
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
)
from komira_plan_stats.table_stats import TableStats


# =============================================================================
# Q5 fixture constants — SF1 worked example.
# =============================================================================

comptime R_LINEITEM: Int = 0
comptime R_ORDERS: Int = 1
comptime R_CUSTOMER: Int = 2
comptime R_SUPPLIER: Int = 3
comptime R_NATION: Int = 4
comptime R_REGION: Int = 5

comptime SF1_LINEITEM: Int = 6_001_215
comptime SF1_ORDERS: Int = 1_500_000
comptime SF1_CUSTOMER: Int = 150_000
comptime SF1_SUPPLIER: Int = 10_000
comptime SF1_NATION: Int = 25
comptime SF1_REGION: Int = 5


# =============================================================================
# Fixture helpers
# =============================================================================


def _two_col_schema(c1: String, c2: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    b.add_field(Field(c2, ArrowType.INT64, False))
    return b.build()


def _one_col_schema(c1: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    return b.build()


def _scan(path: String, var schema: Schema, n: Int) -> LogicalPlan:
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, rc^
    )


def _mk_edge(lr: Int, rr: Int, lk: String, rk: String) -> JoinEdge:
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return JoinEdge(lr, rr, lks^, rks^)


def _build_q5_chain_tier2_only() -> JoinChain:
    """Construct Q5's 6-relation chain WITHOUT Tier-1 table_stats. The
    `DefaultColumnStatsProvider` falls through to Tier-2 row-count
    (the leaf scan's row_count, equal to `relation.cardinality` here)
    for every per-column edge — the path with no per-column NDV.
    """
    var chain = JoinChain()
    var ns: Optional[TableStats] = None
    chain.relations.append(JoinRelation(
        R_LINEITEM,
        _scan("lineitem.parquet", _two_col_schema("l_orderkey", "l_suppkey"), SF1_LINEITEM),
        SF1_LINEITEM,
        ns^,
    ))
    var ns2: Optional[TableStats] = None
    chain.relations.append(JoinRelation(
        R_ORDERS,
        _scan("orders.parquet", _two_col_schema("o_orderkey", "o_custkey"), SF1_ORDERS),
        SF1_ORDERS,
        ns2^,
    ))
    var ns3: Optional[TableStats] = None
    chain.relations.append(JoinRelation(
        R_CUSTOMER,
        _scan("customer.parquet", _two_col_schema("c_custkey", "c_nationkey"), SF1_CUSTOMER),
        SF1_CUSTOMER,
        ns3^,
    ))
    var ns4: Optional[TableStats] = None
    chain.relations.append(JoinRelation(
        R_SUPPLIER,
        _scan("supplier.parquet", _two_col_schema("s_suppkey", "s_nationkey"), SF1_SUPPLIER),
        SF1_SUPPLIER,
        ns4^,
    ))
    var ns5: Optional[TableStats] = None
    chain.relations.append(JoinRelation(
        R_NATION,
        _scan("nation.parquet", _two_col_schema("n_nationkey", "n_regionkey"), SF1_NATION),
        SF1_NATION,
        ns5^,
    ))
    var ns6: Optional[TableStats] = None
    chain.relations.append(JoinRelation(
        R_REGION,
        _scan("region.parquet", _one_col_schema("r_regionkey"), SF1_REGION),
        SF1_REGION,
        ns6^,
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
# Plan-shape walker (mirror of test_optimizer_dpccp_q5_synthetic)
# =============================================================================


def _plan_leaf_scan_paths(plan: LogicalPlan, mut out: List[String]):
    if plan.tag == PLAN_SCAN and plan._scan:
        out.append(String(plan._scan.value()[].source_path))
        return
    if plan.tag == PLAN_JOIN and plan._join:
        _plan_leaf_scan_paths(plan._join.value()[].left[], out)
        _plan_leaf_scan_paths(plan._join.value()[].right[], out)
        return


def _subtree_contains(plan: LogicalPlan, path_substr: String) -> Bool:
    var paths = List[String]()
    _plan_leaf_scan_paths(plan, paths)
    for i in range(len(paths)):
        if paths[i].find(path_substr) >= 0:
            return True
    return False


def _find_lineitem_supplier_adjacent_join(plan: LogicalPlan) -> Bool:
    """Find a JOIN whose two immediate subtrees have lineitem on one
    side and supplier on the other, with the join condition including
    the `l_suppkey = s_suppkey` per-column edge.

    lineitem and supplier need not be singleton siblings: each may sit
    inside a larger subtree, lineitem only on one side and supplier only
    on the other, joined via `l_suppkey = s_suppkey`. See the
    docstring on the sibling test
    `test_optimizer_dpccp_q5_synthetic._find_lineitem_supplier_adjacent_join`
    for the rationale.
    """
    if plan.tag != PLAN_JOIN or not plan._join:
        return False
    ref jd = plan._join.value()[]
    var left_has_li = _subtree_contains(jd.left[], "lineitem")
    var right_has_li = _subtree_contains(jd.right[], "lineitem")
    var left_has_s = _subtree_contains(jd.left[], "supplier")
    var right_has_s = _subtree_contains(jd.right[], "supplier")

    var li_left_s_right = left_has_li and right_has_s and not right_has_li and not left_has_s
    var s_left_li_right = left_has_s and right_has_li and not right_has_s and not left_has_li
    if li_left_s_right or s_left_li_right:
        for i in range(len(jd.left_on)):
            var lk = jd.left_on[i]
            var rk = jd.right_on[i]
            if (lk == "l_suppkey" and rk == "s_suppkey") or (
                lk == "s_suppkey" and rk == "l_suppkey"
            ):
                return True

    if _find_lineitem_supplier_adjacent_join(jd.left[]):
        return True
    if _find_lineitem_supplier_adjacent_join(jd.right[]):
        return True
    return False


def _find_customer_supplier_leading_pair(p: LogicalPlan) -> Bool:
    """Find a JOIN whose two immediate subtrees are exactly {customer}
    and {supplier} singletons — the fan-out pair (joined on nationkey
    alone) that the TDOM cost model should NOT pick."""
    if p.tag != PLAN_JOIN or not p._join:
        return False
    ref jd = p._join.value()[]
    var l_paths = List[String]()
    _plan_leaf_scan_paths(jd.left[], l_paths)
    var r_paths = List[String]()
    _plan_leaf_scan_paths(jd.right[], r_paths)
    if len(l_paths) == 1 and len(r_paths) == 1:
        var l_c = l_paths[0].find("customer") >= 0
        var r_s = r_paths[0].find("supplier") >= 0
        var l_s = l_paths[0].find("supplier") >= 0
        var r_c = r_paths[0].find("customer") >= 0
        if (l_c and r_s) or (l_s and r_c):
            return True
    if _find_customer_supplier_leading_pair(jd.left[]):
        return True
    if _find_customer_supplier_leading_pair(jd.right[]):
        return True
    return False


# =============================================================================
# Tests
# =============================================================================


def test_q5_tier2_solve_dpccp_returns_plan() raises:
    """With Tier-2-only stats, DPccp completes within iteration bounds
    and returns a non-None plan."""
    var chain = _build_q5_chain_tier2_only()
    var plan_opt = solve_dpccp(chain)
    assert_true(
        Bool(plan_opt),
        "Tier-2 Q5 chain: solve_dpccp must produce a plan",
    )


def test_q5_tier2_plan_shape_lineitem_supplier_adjacent() raises:
    """End-to-end Tier-2 verification: with every NDV from Tier-2 of
    `DefaultColumnStatsProvider`, the Q5 chain's plan has a join with
    lineitem on one side, supplier on the other, on `l_suppkey = s_suppkey`.

    This is the path a Q5 chain with no `table_stats` takes; it pins the
    plan shape on that input.
    """
    var chain = _build_q5_chain_tier2_only()
    var plan_opt = solve_dpccp(chain)
    assert_true(Bool(plan_opt))
    var plan = plan_opt.take()
    assert_true(
        _find_lineitem_supplier_adjacent_join(plan),
        "Tier-2 path: expected a join with lineitem and supplier on "
        "opposite sides on l_suppkey = s_suppkey; the plan has "
        "none.",
    )


def test_q5_tier2_no_customer_supplier_fanout() raises:
    """Negative check: the Tier-2 path does NOT emit the
    customer-supplier fan-out (nationkey only) as a leading pair."""
    var chain = _build_q5_chain_tier2_only()
    var plan_opt = solve_dpccp(chain)
    assert_true(Bool(plan_opt))
    var plan = plan_opt.take()

    assert_false(
        _find_customer_supplier_leading_pair(plan),
        "Tier-2 path must NOT lead with customer-supplier fan-out",
    )


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
