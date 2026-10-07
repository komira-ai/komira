# =============================================================================
# Order-pin regression for the Q5 join reorder
# =============================================================================
#
# This is an ORDER-PIN
# regression test: it pins the *decision* the
# DPccp cost model makes for the Q5 6-relation chain, not just a runtime
# result (pin the DECISION, not a possibly vacuous result, so drift is visible).
#
# It exercises TWO stat regimes on the SAME Q5 chain shape (mirroring
# `test_optimizer_dpccp_q5_synthetic.mojo`'s SF1 fixture):
#
#   1. WITH Tier-1 NDV `table_stats` (`_build_q5_chain(with_ndv=True)`): the
#      TDOM cost model has real distinct counts and picks the DuckDB-class
#      order — a join puts `lineitem` and `supplier` on opposite sides on
#      `l_suppkey = s_suppkey`, and the `customer ⋈ supplier`-via-nation
#      near-cartesian is NOT the leading pair. This is the KNOWN-GOOD
#      baseline (the sibling synthetic test pins the same shape).
#
#   2. ROW-COUNT-ONLY (`with_ndv=False`): every scan carries `row_count`
#      and every relation has `table_stats=None`, so the cost model has
#      NO per-column NDV.
#      This test PINS whichever order the row-count-only cost model emits, so a
#      future stats/cost-model change that shifts it is loud.
#
# SCOPE: these tests call `solve_dpccp` directly on hand-built chains; they
# pin the cost model's decision (does it pick the good order given only
# row_count?) and nothing downstream of it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    JOIN_SEMI,
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
from komira_optimizer.optimizer_dpccp import solve_dpccp
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_expr.scalar_value import ScalarValue


# =============================================================================
# Q5 fixture constants (mirror test_optimizer_dpccp_q5_synthetic.mojo)
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


def _two_col_schema(col_a: String, col_b: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(col_a, ArrowType.INT64, False))
    b.add_field(Field(col_b, ArrowType.INT64, False))
    return b.build()


def _scan(path: String, var schema: Schema, n: Int) -> LogicalPlan:
    """A Parquet scan carrying `row_count=n`, with no projection and no
    filter."""
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, rc^
    )


def _column_stats(distinct: Int) -> ColumnStats:
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
    var stats = List[ColumnStats]()
    for i in range(len(col_distincts)):
        stats.append(_column_stats(col_distincts[i]))
    return TableStats(
        cardinality, col_names^, stats^, STATS_SOURCE_PARQUET_METADATA
    )


def _mk_edge(lr: Int, rr: Int, lk: String, rk: String) -> JoinEdge:
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return JoinEdge(lr, rr, lks^, rks^)


def _rel(
    id: Int,
    path: String,
    var schema: Schema,
    card: Int,
    var ts: Optional[TableStats],
) -> JoinRelation:
    return JoinRelation(id, _scan(path, schema^, card), card, ts^)


def _build_q5_chain(with_ndv: Bool) -> JoinChain:
    """Q5's 6-relation chain + 6 per-column edges. When `with_ndv` the leaves
    carry Tier-1 NDV `table_stats`; otherwise row_count only (the
    row-count-only regime)."""
    var chain = JoinChain()

    # lineitem(0)
    var li_names = List[String]()
    li_names.append("l_orderkey")
    li_names.append("l_suppkey")
    var li_d = List[Int]()
    li_d.append(1_500_000)
    li_d.append(10_000)
    var ts_li: Optional[TableStats] = None
    if with_ndv:
        ts_li = _ts(SF1_LINEITEM, li_names^, li_d^)
    chain.relations.append(
        _rel(R_LINEITEM, "lineitem.parquet",
             _two_col_schema("l_orderkey", "l_suppkey"), SF1_LINEITEM, ts_li^)
    )

    # orders(1)
    var o_names = List[String]()
    o_names.append("o_orderkey")
    o_names.append("o_custkey")
    var o_d = List[Int]()
    o_d.append(1_500_000)
    o_d.append(150_000)
    var ts_o: Optional[TableStats] = None
    if with_ndv:
        ts_o = _ts(SF1_ORDERS, o_names^, o_d^)
    chain.relations.append(
        _rel(R_ORDERS, "orders.parquet",
             _two_col_schema("o_orderkey", "o_custkey"), SF1_ORDERS, ts_o^)
    )

    # customer(2)
    var c_names = List[String]()
    c_names.append("c_custkey")
    c_names.append("c_nationkey")
    var c_d = List[Int]()
    c_d.append(150_000)
    c_d.append(25)
    var ts_c: Optional[TableStats] = None
    if with_ndv:
        ts_c = _ts(SF1_CUSTOMER, c_names^, c_d^)
    chain.relations.append(
        _rel(R_CUSTOMER, "customer.parquet",
             _two_col_schema("c_custkey", "c_nationkey"), SF1_CUSTOMER, ts_c^)
    )

    # supplier(3)
    var s_names = List[String]()
    s_names.append("s_suppkey")
    s_names.append("s_nationkey")
    var s_d = List[Int]()
    s_d.append(10_000)
    s_d.append(25)
    var ts_s: Optional[TableStats] = None
    if with_ndv:
        ts_s = _ts(SF1_SUPPLIER, s_names^, s_d^)
    chain.relations.append(
        _rel(R_SUPPLIER, "supplier.parquet",
             _two_col_schema("s_suppkey", "s_nationkey"), SF1_SUPPLIER, ts_s^)
    )

    # nation(4)
    var n_names = List[String]()
    n_names.append("n_nationkey")
    n_names.append("n_regionkey")
    var n_d = List[Int]()
    n_d.append(25)
    n_d.append(5)
    var ts_n: Optional[TableStats] = None
    if with_ndv:
        ts_n = _ts(SF1_NATION, n_names^, n_d^)
    chain.relations.append(
        _rel(R_NATION, "nation.parquet",
             _two_col_schema("n_nationkey", "n_regionkey"), SF1_NATION, ts_n^)
    )

    # region(5)
    var r_names = List[String]()
    r_names.append("r_regionkey")
    var r_d = List[Int]()
    r_d.append(5)
    var ts_r: Optional[TableStats] = None
    if with_ndv:
        ts_r = _ts(SF1_REGION, r_names^, r_d^)
    var r_b = SchemaBuilder()
    r_b.add_field(Field("r_regionkey", ArrowType.INT64, False))
    chain.relations.append(
        _rel(R_REGION, "region.parquet", r_b.build(), SF1_REGION, ts_r^)
    )

    # 6 per-column edges:
    chain.edges.append(_mk_edge(R_LINEITEM, R_ORDERS, "l_orderkey", "o_orderkey"))
    chain.edges.append(_mk_edge(R_LINEITEM, R_SUPPLIER, "l_suppkey", "s_suppkey"))
    chain.edges.append(_mk_edge(R_ORDERS, R_CUSTOMER, "o_custkey", "c_custkey"))
    chain.edges.append(_mk_edge(R_CUSTOMER, R_SUPPLIER, "c_nationkey", "s_nationkey"))
    chain.edges.append(_mk_edge(R_SUPPLIER, R_NATION, "s_nationkey", "n_nationkey"))
    chain.edges.append(_mk_edge(R_NATION, R_REGION, "n_regionkey", "r_regionkey"))
    return chain^


# =============================================================================
# Emitted-order serialization (the DECISION pin)
# =============================================================================


def _leaf_tag(path: String) -> StaticString:
    """A one-letter table tag from a scan path (l/o/c/s/n/r), else '?'."""
    if path.find("lineitem") >= 0:
        return "l"
    if path.find("orders") >= 0:
        return "o"
    if path.find("customer") >= 0:
        return "c"
    if path.find("supplier") >= 0:
        return "s"
    if path.find("nation") >= 0:
        return "n"
    if path.find("region") >= 0:
        return "r"
    return "?"


def _serialize_order(plan: LogicalPlan) -> String:
    """A canonical, deterministic string of the emitted join tree — the pinned
    DECISION. Leaves render as their table tag; joins render parenthesized as
    `(<left> <right>)`. DPccp emits Scan/Join nodes only."""
    if plan.tag == PLAN_SCAN and plan._scan:
        return _leaf_tag(String(plan._scan.value()[].source_path))
    if plan.tag == PLAN_JOIN and plan._join:
        ref jd = plan._join.value()[]
        return "(" + _serialize_order(jd.left[]) + " " \
            + _serialize_order(jd.right[]) + ")"
    return "?"


def _plan_leaf_paths(plan: LogicalPlan, mut out: List[String]):
    if plan.tag == PLAN_SCAN and plan._scan:
        out.append(String(plan._scan.value()[].source_path))
        return
    if plan.tag == PLAN_JOIN and plan._join:
        _plan_leaf_paths(plan._join.value()[].left[], out)
        _plan_leaf_paths(plan._join.value()[].right[], out)


def _subtree_contains(plan: LogicalPlan, sub: String) -> Bool:
    var paths = List[String]()
    _plan_leaf_paths(plan, paths)
    for i in range(len(paths)):
        if paths[i].find(sub) >= 0:
            return True
    return False


def _has_customer_supplier_leading_pair(p: LogicalPlan) -> Bool:
    """True iff some JOIN's two immediate subtrees are exactly {customer} and
    {supplier} singletons — the near-cartesian fan-out leading pair (BAD)."""
    if p.tag != PLAN_JOIN or not p._join:
        return False
    ref jd = p._join.value()[]
    var l = List[String]()
    _plan_leaf_paths(jd.left[], l)
    var r = List[String]()
    _plan_leaf_paths(jd.right[], r)
    if len(l) == 1 and len(r) == 1:
        var lc = l[0].find("customer") >= 0
        var rs = r[0].find("supplier") >= 0
        var ls = l[0].find("supplier") >= 0
        var rc = r[0].find("customer") >= 0
        if (lc and rs) or (ls and rc):
            return True
    if _has_customer_supplier_leading_pair(jd.left[]):
        return True
    if _has_customer_supplier_leading_pair(jd.right[]):
        return True
    return False


def _has_lineitem_supplier_adjacent(plan: LogicalPlan) -> Bool:
    """True iff some JOIN threads lineitem and supplier onto opposite sides via
    the `l_suppkey = s_suppkey` per-column edge (the DuckDB-class Plan B)."""
    if plan.tag != PLAN_JOIN or not plan._join:
        return False
    ref jd = plan._join.value()[]
    var l_li = _subtree_contains(jd.left[], "lineitem")
    var r_li = _subtree_contains(jd.right[], "lineitem")
    var l_s = _subtree_contains(jd.left[], "supplier")
    var r_s = _subtree_contains(jd.right[], "supplier")
    var opp = (l_li and r_s and not r_li and not l_s) or (
        l_s and r_li and not r_s and not l_li
    )
    if opp:
        for i in range(len(jd.left_on)):
            var lk = jd.left_on[i]
            var rk = jd.right_on[i]
            if (lk == "l_suppkey" and rk == "s_suppkey") or (
                lk == "s_suppkey" and rk == "l_suppkey"
            ):
                return True
    if _has_lineitem_supplier_adjacent(jd.left[]):
        return True
    if _has_lineitem_supplier_adjacent(jd.right[]):
        return True
    return False


# =============================================================================
# Tests
# =============================================================================


def test_q5_ndv_regime_picks_duckdb_class_order() raises:
    """KNOWN-GOOD baseline pin: with Tier-1 NDV stats the DPccp cost model
    emits the DuckDB-class order — lineitem⋈supplier are threaded adjacent and
    customer⋈supplier is NOT the near-cartesian leading pair."""
    var chain = _build_q5_chain(True)
    var plan_opt = solve_dpccp(chain)
    assert_true(Bool(plan_opt), "solve_dpccp must return a plan (NDV regime)")
    var plan = plan_opt.take()
    var order = _serialize_order(plan)
    print("Q5 NDV-regime emitted order:", order)
    assert_true(
        _has_lineitem_supplier_adjacent(plan),
        "NDV regime: lineitem+supplier must be threaded adjacent (Plan B)."
        " Emitted: " + order,
    )
    assert_false(
        _has_customer_supplier_leading_pair(plan),
        "NDV regime: customer⋈supplier near-cartesian must NOT lead."
        " Emitted: " + order,
    )


def test_q5_rowcount_only_regime_pin() raises:
    """The row-count-only regime: row_count present, NDV absent. The test
    pins the answer to the question: DOES the cost model pick the good
    order given ONLY row_count?

    PINNED: YES. The emitted order is the bushy DuckDB-class plan
    `((l (o c)) (s (n r)))` — the FK chain `lineitem⋈orders⋈customer` joined to
    `supplier⋈nation⋈region` at the root via the `l_suppkey=s_suppkey` +
    `c_nationkey=s_nationkey` keys. The near-cartesian `customer⋈supplier`-via-
    nation pair is NOT the leading pair. So the cost model is not blind: the tiny
    `nation` relation's row_count (25) is a faithful proxy for its PK NDV, and
    that caps the nation-key equivalence-class TDOM to 25 even without
    `table_stats`. The cost model is NOT blind on the row-count-only regime.

    This PINS the DECISION (not only a runtime result): the exact emitted-order
    string + the two structural booleans. A future stats/cost-model change that
    shifts the row-count-only order fails this test."""
    var chain = _build_q5_chain(False)
    var plan_opt = solve_dpccp(chain)
    assert_true(
        Bool(plan_opt), "solve_dpccp must return a plan (row-count-only regime)"
    )
    var plan = plan_opt.take()
    var order = _serialize_order(plan)
    print("Q5 row-count-only emitted order:", order)
    var li_s_adjacent = _has_lineitem_supplier_adjacent(plan)
    var cust_supp_lead = _has_customer_supplier_leading_pair(plan)
    print("  lineitem_supplier_adjacent =", li_s_adjacent)
    print("  customer_supplier_leading  =", cust_supp_lead)
    # Pin the exact emitted order string.
    assert_equal(
        order, "((l (o c)) (s (n r)))",
        "row-count-only Q5 order drifted from the pinned DuckDB-class bushy plan",
    )
    assert_true(
        li_s_adjacent,
        "row-count-only regime: lineitem+supplier must be threaded adjacent",
    )
    assert_false(
        cust_supp_lead,
        "row-count-only regime: customer⋈supplier near-cartesian must NOT lead",
    )


# =============================================================================
# Additional multi-join shape pins (drift guards) — row-count-only regime
# =============================================================================
#
# These pin the emitted join order for two
# linear FK chains (4 and 5 relations) so future cost-model drift is visible.
# They are row-count-only (row_count only, NO NDV) and pin the
# exact emitted order string.


def _lin_rel(id: Int, tag: String, ca: String, cb: String, card: Int) -> JoinRelation:
    """A row-count-only relation (no table_stats), scan path == `tag` so the
    generic serializer can render it."""
    var ts: Optional[TableStats] = None
    return _rel(id, tag, _two_col_schema(ca, cb), card, ts^)


def _serialize_order_generic(plan: LogicalPlan) -> String:
    """Deterministic emitted-order string using the raw scan path as the leaf
    label (for shapes whose leaves are not TPC-H tables)."""
    if plan.tag == PLAN_SCAN and plan._scan:
        return String(plan._scan.value()[].source_path)
    if plan.tag == PLAN_JOIN and plan._join:
        ref jd = plan._join.value()[]
        return "(" + _serialize_order_generic(jd.left[]) + " " \
            + _serialize_order_generic(jd.right[]) + ")"
    return "?"


def test_linear_fk_chain_4_table_order_pin() raises:
    """4-relation linear FK chain, row-count-only: A(6M)-B(1.5M)-C(150K)-D(25),
    edges A-B, B-C, C-D. Pins the emitted DECISION."""
    var chain = JoinChain()
    chain.relations.append(_lin_rel(0, "A", "a_k", "ab_k", 6_000_000))
    chain.relations.append(_lin_rel(1, "B", "ab_k", "bc_k", 1_500_000))
    chain.relations.append(_lin_rel(2, "C", "bc_k", "cd_k", 150_000))
    chain.relations.append(_lin_rel(3, "D", "cd_k", "d_k", 25))
    chain.edges.append(_mk_edge(0, 1, "ab_k", "ab_k"))
    chain.edges.append(_mk_edge(1, 2, "bc_k", "bc_k"))
    chain.edges.append(_mk_edge(2, 3, "cd_k", "cd_k"))
    var plan_opt = solve_dpccp(chain)
    assert_true(Bool(plan_opt), "solve_dpccp must return a plan (4-table)")
    var plan = plan_opt.take()
    var order = _serialize_order_generic(plan)
    print("4-table linear FK chain emitted order:", order)
    assert_equal(
        order, "(A (B (C D)))",
        "4-table linear FK-chain order drifted from the pinned decision",
    )


def test_linear_fk_chain_5_table_order_pin() raises:
    """5-relation linear FK chain, row-count-only:
    A(6M)-B(1.5M)-C(150K)-D(10K)-E(25). Pins the emitted DECISION."""
    var chain = JoinChain()
    chain.relations.append(_lin_rel(0, "A", "a_k", "ab_k", 6_000_000))
    chain.relations.append(_lin_rel(1, "B", "ab_k", "bc_k", 1_500_000))
    chain.relations.append(_lin_rel(2, "C", "bc_k", "cd_k", 150_000))
    chain.relations.append(_lin_rel(3, "D", "cd_k", "de_k", 10_000))
    chain.relations.append(_lin_rel(4, "E", "de_k", "e_k", 25))
    chain.edges.append(_mk_edge(0, 1, "ab_k", "ab_k"))
    chain.edges.append(_mk_edge(1, 2, "bc_k", "bc_k"))
    chain.edges.append(_mk_edge(2, 3, "cd_k", "cd_k"))
    chain.edges.append(_mk_edge(3, 4, "de_k", "de_k"))
    var plan_opt = solve_dpccp(chain)
    assert_true(Bool(plan_opt), "solve_dpccp must return a plan (5-table)")
    var plan = plan_opt.take()
    var order = _serialize_order_generic(plan)
    print("5-table linear FK chain emitted order:", order)
    assert_equal(
        order, "(A (B (C (D E))))",
        "5-table linear FK-chain order drifted from the pinned decision",
    )


# =============================================================================
# LIVE-SHAPE fixture (`_build_q5_live_chain`)
# =============================================================================
#
# The pin tests above build the "textbook" q5 6-relation chain (nation + region
# separate, orders UNFILTERED). The `_build_q5_live_chain` fixture differs in TWO
# structural ways:
#   (1) `nation ⋈ region` is a SEMI join (region contributes no output cols) — a
#       reorder BARRIER — so it is ONE chain leaf (card 7, no scan row_count the
#       Tier-2 walk can reach, NO table_stats), NOT two separate scans.
#   (2) `orders` models a date-filtered relation: its chain cardinality is 135K
#       while its raw scan row_count is 1.5M.
# These helpers build that chain (5 relations, 6 edges — the 6th the
# s_nationkey=c_nationkey edge implied by the two n_nationkey edges) so the
# emitted order is pinned on that shape.


def _semi_nation_region(nation_card: Int, region_card: Int) -> LogicalPlan:
    """rel0 of the live-shape fixture: a `nation SEMI region` subtree (a reorder
    barrier -> one chain leaf). Tier-2 finds no scan row_count under a JOIN root and
    the leaf has no table_stats, so the cost model sees only its `cardinality`, never
    a per-column NDV for n_nationkey."""
    var nation = _scan(
        "nation.parquet", _two_col_schema("n_nationkey", "n_regionkey"), nation_card
    )
    var region = _scan(
        "region.parquet", _two_col_schema("r_regionkey", "r_name"), region_card
    )
    var lk: List[String] = ["n_regionkey"]
    var rk: List[String] = ["r_regionkey"]
    return LogicalPlan.join(nation^, region^, lk^, rk^, JOIN_SEMI)


def _live_rel_scan(
    id: Int, path: String, ca: String, cb: String, row_count: Int, card: Int
) -> JoinRelation:
    """A row-count-only scan leaf whose chain `cardinality` (post-filter) may differ
    from its raw scan `row_count` (the orders-filtered case: row_count 1.5M, card
    135K)."""
    var ts: Optional[TableStats] = None
    var rc: Optional[Int] = row_count
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    var plan = LogicalPlan.scan(
        path, SOURCE_PARQUET, _two_col_schema(ca, cb), none_proj^, none_filt^, rc^
    )
    return JoinRelation(id, plan^, card, ts^)


def _build_q5_live_chain(orders_card: Int, nation_merged: Bool) -> JoinChain:
    """Build the live-shape Q5 chain (5 relations, rel0 a SEMI barrier leaf).

    `nation_merged=True` (the shape the test pins): rel0 = nation SEMI region (card
    7, no table_stats). `orders_card` = the chain cardinality for orders (135K for
    the date-filtered shape / 1_500_000 to model the UNFILTERED counterfactual).

    Relation ids: 0=nation(⋈region), 1=supplier, 2=customer, 3=orders,
    4=lineitem. Edges (6, incl. the derived s_nationkey=c_nationkey):
      0<->1 n_nationkey=s_nationkey | 2<->3 c_custkey=o_custkey |
      0<->2 n_nationkey=c_nationkey | 1<->2 s_nationkey=c_nationkey (derived) |
      3<->4 o_orderkey=l_orderkey  | 1<->4 s_suppkey=l_suppkey."""
    var chain = JoinChain()
    # rel0 — nation(⋈region)
    if nation_merged:
        var ts0: Optional[TableStats] = None
        chain.relations.append(JoinRelation(0, _semi_nation_region(25, 1), 7, ts0^))
    else:
        # counterfactual: nation as a plain scan leaf carrying row_count 25.
        chain.relations.append(
            _live_rel_scan(0, "nation.parquet", "n_nationkey", "n_regionkey", 25, 7)
        )
    chain.relations.append(
        _live_rel_scan(1, "supplier.parquet", "s_suppkey", "s_nationkey", 10000, 10000)
    )
    chain.relations.append(
        _live_rel_scan(2, "customer.parquet", "c_custkey", "c_nationkey", 150000, 150000)
    )
    chain.relations.append(
        _live_rel_scan(
            3, "orders.parquet", "o_orderkey", "o_custkey", 1500000, orders_card
        )
    )
    chain.relations.append(
        _live_rel_scan(
            4, "lineitem.parquet", "l_orderkey", "l_suppkey", 6001215, 6001215
        )
    )
    chain.edges.append(_mk_edge(0, 1, "n_nationkey", "s_nationkey"))
    chain.edges.append(_mk_edge(2, 3, "c_custkey", "o_custkey"))
    chain.edges.append(_mk_edge(0, 2, "n_nationkey", "c_nationkey"))
    chain.edges.append(_mk_edge(1, 2, "s_nationkey", "c_nationkey"))
    chain.edges.append(_mk_edge(3, 4, "o_orderkey", "l_orderkey"))
    chain.edges.append(_mk_edge(1, 4, "s_suppkey", "l_suppkey"))
    return chain^


def _serialize_live(plan: LogicalPlan) -> String:
    """Serialize an emitted tree, rendering any SEMI join subtree (rel0) as the
    single tag `nr`."""
    if plan.tag == PLAN_SCAN and plan._scan:
        return _leaf_tag(String(plan._scan.value()[].source_path))
    if plan.tag == PLAN_JOIN and plan._join:
        ref jd = plan._join.value()[]
        if jd.join_type == JOIN_SEMI:
            # rel0's SEMI subtree — one leaf, rendered "nr".
            return "nr"
        return "(" + _serialize_live(jd.left[]) + " " + _serialize_live(jd.right[]) + ")"
    return "?"


def _is_single_table_leaf(plan: LogicalPlan, sub: String) -> Bool:
    """True iff `plan` is one scan whose path contains `sub`, or a SEMI barrier
    whose first (left-most) scan path contains `sub`."""
    var paths = List[String]()
    _plan_leaf_paths(plan, paths)
    if plan.tag == PLAN_JOIN and plan._join:
        # A SEMI barrier leaf (rel0 = nation SEMI region) renders as one logical
        # relation; its FIRST leaf (nation) is the table identity.
        if plan._join.value()[].join_type == JOIN_SEMI:
            return len(paths) >= 1 and paths[0].find(sub) >= 0
        return False
    return len(paths) == 1 and paths[0].find(sub) >= 0


def _lineitem_partner_tags(plan: LogicalPlan) -> List[String]:
    """Return the base-table tags of the sibling subtree at lineitem's DEEPEST join
    — the set of relations lineitem is FIRST joined against. `[o,...]` = the
    DuckDB-class order (thread the fact table through the date-filtered orders,
    reducing 6M -> ~540K); `[s]`/containing 's' = the blowup order (non-reducing
    l_suppkey=s_suppkey join)."""
    var out = List[String]()
    if plan.tag != PLAN_JOIN or not plan._join:
        return out^
    ref jd = plan._join.value()[]
    if _is_single_table_leaf(jd.left[], "lineitem"):
        var paths = List[String]()
        _plan_leaf_paths(jd.right[], paths)
        for i in range(len(paths)):
            out.append(_leaf_tag(paths[i]))
        return out^
    if _is_single_table_leaf(jd.right[], "lineitem"):
        var paths = List[String]()
        _plan_leaf_paths(jd.left[], paths)
        for i in range(len(paths)):
            out.append(_leaf_tag(paths[i]))
        return out^
    var l = _lineitem_partner_tags(jd.left[])
    if len(l) > 0:
        return l^
    return _lineitem_partner_tags(jd.right[])


def _tags_contains(tags: List[String], t: String) -> Bool:
    for i in range(len(tags)):
        if tags[i] == t:
            return True
    return False


def test_q5_live_flattened_shape_threads_lineitem_through_orders() raises:
    """LIVE-SHAPE order pin (the `_build_q5_live_chain` fixture).

    Builds the 5-relation Q5 chain of `_build_q5_live_chain`:
    nation⋈region collapsed to a SEMI barrier leaf (card 7),
    orders at chain cardinality 135K (raw scan row_count 1.5M, the
    date-filtered shape), and 6 edges incl. the
    s_nationkey=c_nationkey edge implied by the two n_nationkey edges.

    THE PIN (the DECISION, not a runtime result): the reorderer threads lineitem
    through the DATE-FILTERED orders FIRST (its deepest-join sibling contains
    'orders'), NOT the non-reducing supplier (l_suppkey=s_suppkey).

    RED BEFORE the fix: emitted `(((nr s) l) (c o))` — lineitem joined supplier
    early (its sibling = {nation,region,supplier}, a non-reducing suppkey
    join). ROOT CAUSE: the orderkey equivalence-class TDOM used
    orders' POST-FILTER cardinality (135K) as o_orderkey's NDV, so
    `|l|·|o_filtered| / MIN(NDV_l, 135K)` = 6M·135K/135K = 6M canceled the
    fact-side reduction, making `{l,o,c}` look like ~6.67M (worse than the 6M
    supplier blowup). GREEN AFTER the fix: `DefaultColumnStatsProvider` Tier-2
    uses the leaf scan's RAW (pre-filter) row_count (orders' 1.5M key domain) so
    MIN(6M, 1.5M) = 1.5M and `{l,o}` correctly reduces to ~540K — the DuckDB-class
    order wins."""
    var chain = _build_q5_live_chain(135000, True)
    var plan_opt = solve_dpccp(chain)
    assert_true(
        Bool(plan_opt), "solve_dpccp must return a plan (live-shape q5 chain)"
    )
    var plan = plan_opt.take()
    var order = _serialize_live(plan)
    print("live-shape q5 emitted order:", order)
    var partner = _lineitem_partner_tags(plan)
    var partner_str = String("[")
    for i in range(len(partner)):
        if i > 0:
            partner_str += ","
        partner_str += partner[i]
    partner_str += "]"
    print("  lineitem deepest-join sibling tables:", partner_str)

    assert_true(
        _tags_contains(partner, "o"),
        "live-shape: lineitem MUST thread through the date-filtered orders first"
        " (its deepest-join sibling must contain 'orders'). Emitted: " + order
        + " sibling=" + partner_str,
    )
    assert_false(
        _tags_contains(partner, "s"),
        "live-shape: lineitem must NOT be joined against supplier first (the"
        " non-reducing l_suppkey=s_suppkey blowup). Emitted: " + order
        + " sibling=" + partner_str,
    )
    # Exact-order DECISION pin (not only a runtime result). RED before the fix:
    # `(((nr s) l) (c o))`.
    assert_equal(
        order, "((nr s) ((c o) l))",
        "live-shape q5 order drifted from the pinned DuckDB-class plan (lineitem"
        " threaded through customer⋈date-filtered-orders, supplier joined last)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
