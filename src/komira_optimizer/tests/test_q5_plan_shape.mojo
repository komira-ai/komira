# =============================================================================
# Q5 join order — Q5 plan-shape test (integration)
# =============================================================================
#
# Machine-independent test for the TDOM-aware DPccp: construct a
# synthetic Q5-shaped LogicalPlan, run the join-reorder pass
# (`reorder_joins_with_dp`), and assert structurally that the result has
# a join with `lineitem` on one side, `supplier` on the other and
# `l_suppkey = s_suppkey` among its keys (the lineitem-supplier-early
# plan).
#
# It checks plan shape only; it runs no query.
#
# Why integration: this test exercises `reorder_joins_with_dp` (the
# top-level join-reorder driver) end-to-end — chain extraction +
# `should_use_dpccp` gate + `solve_dpccp` + DPccp plan reconstruction.
# It needs no I/O.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_dpccp import reorder_joins_with_dp


# =============================================================================
# SF1 worked-example sizes (mirror the TDOM design's worked example).
# =============================================================================

comptime SF1_LINEITEM: Int = 6_001_215
comptime SF1_ORDERS: Int = 1_500_000
comptime SF1_CUSTOMER: Int = 150_000
comptime SF1_SUPPLIER: Int = 10_000
comptime SF1_NATION: Int = 25
comptime SF1_REGION: Int = 5


# =============================================================================
# Plan builders: each leaf is a SCAN(SOURCE_PARQUET, path=<table>.parquet,
# row_count=<SF1 size>); joins compose them in the canonical Q5 left-deep
# input shape that the optimizer is expected to RE-SHAPE into Plan B.
# =============================================================================


def _scan(path: String, var schema: Schema, n: Int) -> LogicalPlan:
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, rc^
    )


def _scan_lineitem() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field("l_orderkey", ArrowType.INT64, False))
    b.add_field(Field("l_suppkey", ArrowType.INT64, False))
    return _scan("lineitem.parquet", b.build(), SF1_LINEITEM)


def _scan_orders() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field("o_orderkey", ArrowType.INT64, False))
    b.add_field(Field("o_custkey", ArrowType.INT64, False))
    return _scan("orders.parquet", b.build(), SF1_ORDERS)


def _scan_customer() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field("c_custkey", ArrowType.INT64, False))
    b.add_field(Field("c_nationkey", ArrowType.INT64, False))
    return _scan("customer.parquet", b.build(), SF1_CUSTOMER)


def _scan_supplier() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field("s_suppkey", ArrowType.INT64, False))
    b.add_field(Field("s_nationkey", ArrowType.INT64, False))
    return _scan("supplier.parquet", b.build(), SF1_SUPPLIER)


def _scan_nation() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field("n_nationkey", ArrowType.INT64, False))
    b.add_field(Field("n_regionkey", ArrowType.INT64, False))
    return _scan("nation.parquet", b.build(), SF1_NATION)


def _scan_region() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field("r_regionkey", ArrowType.INT64, False))
    return _scan("region.parquet", b.build(), SF1_REGION)


def _join1(var left: LogicalPlan, var right: LogicalPlan, lk: String, rk: String) -> LogicalPlan:
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return LogicalPlan.join(left^, right^, lks^, rks^, JOIN_INNER)


def _build_q5_input_plan() -> LogicalPlan:
    """Construct a Q5-canonical left-deep input plan:
        ((((customer ⋈ orders) ⋈ lineitem) ⋈ supplier) ⋈ nation) ⋈ region
    This mirrors the order a naive user (or a query like Q5) would write.
    The optimizer's job is to RE-SHAPE this into Plan B (lineitem-supplier
    early). The 6-relation INNER-join chain is extracted, then DPccp is
    run (n=6 >= DPCCP_MIN_RELATIONS=4 gate).
    """
    # customer ⋈ orders on custkey
    var co = _join1(_scan_customer(), _scan_orders(), "c_custkey", "o_custkey")
    # ⋈ lineitem on orderkey
    var col = _join1(co^, _scan_lineitem(), "o_orderkey", "l_orderkey")
    # ⋈ supplier on suppkey
    var cols = _join1(col^, _scan_supplier(), "l_suppkey", "s_suppkey")
    # ⋈ nation on nationkey
    var colsn = _join1(cols^, _scan_nation(), "s_nationkey", "n_nationkey")
    # ⋈ region on regionkey
    var full = _join1(colsn^, _scan_region(), "n_regionkey", "r_regionkey")
    return full^


# =============================================================================
# Plan-shape introspection helpers
# =============================================================================


def _plan_leaf_scan_paths(plan: LogicalPlan, mut out: List[String]):
    """Recurse; collect every leaf-scan source_path under `plan`."""
    if plan.tag == PLAN_SCAN and plan._scan:
        out.append(String(plan._scan.value()[].source_path))
        return
    if plan.tag == PLAN_JOIN and plan._join:
        _plan_leaf_scan_paths(plan._join.value()[].left[], out)
        _plan_leaf_scan_paths(plan._join.value()[].right[], out)
        return


def _find_customer_supplier_leading_pair(p: LogicalPlan) -> Bool:
    """Find a JOIN whose two immediate subtrees are exactly {customer}
    and {supplier} (one leaf each) — the customer-supplier fan-out leading-
    pair shape that `reorder_joins_with_dp` should NOT produce."""
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


def _subtree_contains(plan: LogicalPlan, path_substr: String) -> Bool:
    var paths = List[String]()
    _plan_leaf_scan_paths(plan, paths)
    for i in range(len(paths)):
        if paths[i].find(path_substr) >= 0:
            return True
    return False


def _find_lineitem_supplier_adjacent_join(plan: LogicalPlan) -> Bool:
    """Find a JOIN node where lineitem and supplier sit on opposite
    subtrees AND the join condition includes `l_suppkey = s_suppkey`.

    The helper does not require singleton-each siblings: lineitem and
    supplier may sit inside two halves of a bushy split, joined via
    `l_suppkey = s_suppkey`. See the docstring
    on `test_optimizer_dpccp_q5_synthetic._find_lineitem_supplier_adjacent_join`
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


# =============================================================================
# Tests
# =============================================================================


def test_q5_input_plan_constructs() raises:
    """Fixture sanity: the canonical Q5 left-deep input plan builds
    cleanly with 6 leaves."""
    var plan = _build_q5_input_plan()
    var paths = List[String]()
    _plan_leaf_scan_paths(plan, paths)
    assert_equal(len(paths), 6)


def test_q5_reorder_joins_with_dp_returns_plan() raises:
    """`reorder_joins_with_dp` on the Q5-shaped input returns a join
    tree over the same 6 leaves."""
    var plan = _build_q5_input_plan()
    var reordered = reorder_joins_with_dp(plan^)
    # The reordered plan is still a 6-leaf join tree.
    var paths = List[String]()
    _plan_leaf_scan_paths(reordered, paths)
    assert_equal(
        len(paths), 6,
        "reorder_joins_with_dp must preserve the 6-leaf set",
    )


def test_q5_plan_shape_lineitem_supplier_adjacent_after_reorder() raises:
    """The LOAD-BEARING acceptance test: after
    `reorder_joins_with_dp` runs, some join has lineitem on one side,
    supplier on the other and `l_suppkey = s_suppkey` among its keys.

    Under the TDOM denominator the lineitem-supplier pair is
    ~10× cheaper than the customer-supplier pair (per the design), and
    DPccp joins lineitem and supplier on that key.
    """
    var plan = _build_q5_input_plan()
    var reordered = reorder_joins_with_dp(plan^)
    assert_true(
        _find_lineitem_supplier_adjacent_join(reordered),
        "plan-shape: lineitem and supplier must sit on opposite sides of "
        "a join keyed on l_suppkey = s_suppkey (lineitem-supplier-early). "
        "If this fails, the TDOM cost model is not reaching reorder_joins_with_dp.",
    )


def test_q5_no_customer_supplier_leading_pair_after_reorder() raises:
    """Negative check: after reorder, the plan does NOT contain a JOIN
    whose two immediate subtrees are {customer} + {supplier} (the
    customer-supplier fan-out leading-pair shape)."""
    var plan = _build_q5_input_plan()
    var reordered = reorder_joins_with_dp(plan^)

    assert_false(
        _find_customer_supplier_leading_pair(reordered),
        "customer-supplier fan-out must NOT survive as a "
        "leading join pair under the TDOM cost model.",
    )


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
