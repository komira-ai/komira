"""structural_hash stability.

Plan-level CSE detection requires that two structurally-identical subtrees
produce the same UInt64 hash. `LogicalPlan.copy()` is the canonical
deep-clone path; its output must round-trip the FNV-1a-of-display-string
hash that `logical_plan.structural_hash` returns. If this test fails, CSE
detection cannot rely on textual equality.

Coverage:
  Test 1: scan-only plan
  Test 2: filter(scan)
  Test 3: project(filter(scan)) -- the canonical pushdown shape
  Test 4: aggregate(project(filter(scan)))
  Test 5: join(scan, scan) -- the canonical CSE-target shape
  Test 6: nested join(project(filter(scan)), aggregate(scan))
  Test 7: two independently-built identical filter(scan) trees produce
          the same hash (the CSE bridge case -- two SDK calls landing on
          structurally-equivalent plans).
"""

from std.testing import assert_equal, assert_true

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_GT,
    BIN_AND,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
)


def _make_lineitem() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(
        String("lineitem.parquet"), SOURCE_PARQUET, schema^
    )


def _make_orders() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("o_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("o_custkey"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(
        String("orders.parquet"), SOURCE_PARQUET, schema^
    )


def test_scan_only_clone_stable() raises:
    var p = _make_lineitem()
    var q = p.copy()
    assert_equal(p.structural_hash(), q.structural_hash())


def test_filter_clone_stable() raises:
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var p = LogicalPlan.filter(pred^, _make_lineitem()^)
    var q = p.copy()
    assert_equal(p.structural_hash(), q.structural_hash())


def test_project_filter_scan_clone_stable() raises:
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var inner = LogicalPlan.filter(pred^, _make_lineitem()^)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("l_orderkey")))
    exprs.append(Expr.col_ref(String("l_quantity")))
    var p = LogicalPlan.project(exprs^, inner^)
    var q = p.copy()
    assert_equal(p.structural_hash(), q.structural_hash())


def test_aggregate_project_filter_scan_clone_stable() raises:
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var filt = LogicalPlan.filter(pred^, _make_lineitem()^)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("l_orderkey")))
    exprs.append(Expr.col_ref(String("l_quantity")))
    var proj = LogicalPlan.project(exprs^, filt^)
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("l_orderkey")))
    var aggs = AggExprArray()
    aggs.append(AggExpr(
        AGG_SUM,
        Optional(Expr.col_ref(String("l_quantity"))),
        Optional(String("sum_qty")),
    ))
    var p = LogicalPlan.aggregate(gb^, aggs^, proj^)
    var q = p.copy()
    assert_equal(p.structural_hash(), q.structural_hash())


def test_join_two_scans_clone_stable() raises:
    var left_on = List[String]()
    left_on.append(String("l_orderkey"))
    var right_on = List[String]()
    right_on.append(String("o_orderkey"))
    var p = LogicalPlan.join(
        _make_lineitem()^,
        _make_orders()^,
        left_on^,
        right_on^,
        JOIN_INNER,
        JOIN_ALGO_AUTO,
    )
    var q = p.copy()
    assert_equal(p.structural_hash(), q.structural_hash())


def test_nested_join_clone_stable() raises:
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var li_filt = LogicalPlan.filter(pred^, _make_lineitem()^)
    var li_exprs = ExprArray()
    li_exprs.append(Expr.col_ref(String("l_orderkey")))
    var li_proj = LogicalPlan.project(li_exprs^, li_filt^)

    var ord_gb = ExprArray()
    ord_gb.append(Expr.col_ref(String("o_orderkey")))
    var ord_aggs = AggExprArray()
    ord_aggs.append(AggExpr(
        AGG_SUM,
        Optional(Expr.col_ref(String("o_custkey"))),
        Optional(String("sum_cust")),
    ))
    var ord_agg = LogicalPlan.aggregate(ord_gb^, ord_aggs^, _make_orders()^)

    var left_on = List[String]()
    left_on.append(String("l_orderkey"))
    var right_on = List[String]()
    right_on.append(String("o_orderkey"))
    var p = LogicalPlan.join(
        li_proj^,
        ord_agg^,
        left_on^,
        right_on^,
        JOIN_INNER,
        JOIN_ALGO_AUTO,
    )
    var q = p.copy()
    assert_equal(p.structural_hash(), q.structural_hash())


def test_independently_built_identical_subtrees_match() raises:
    """The "CSE bridge" case: two filter(scan) trees built from scratch
    (NOT via copy()) produce the same hash when they are structurally
    identical. This is the prerequisite for CSE detection -- it can't
    just rely on copy() round-trips; it must detect identical subtrees
    that arrived through different SDK call paths.
    """
    var p1_pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var p1 = LogicalPlan.filter(p1_pred^, _make_lineitem()^)

    var p2_pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var p2 = LogicalPlan.filter(p2_pred^, _make_lineitem()^)

    assert_equal(p1.structural_hash(), p2.structural_hash())


def _asc_keys() -> List[String]:
    var k = List[String]()
    k.append(String("l_quantity"))
    return k^


def _asc_desc() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    return d^


def _deviating_override() -> Optional[List[Bool]]:
    """ASC with NULLS **FIRST** — the DEVIATION from the derived default.

    `null_order_policy.derived_nulls_first` is NULLS LAST in both
    directions, so NULLS LAST is what the plan DERIVES and cannot be a
    deviation from it. The literal must be re-derived from that policy if it
    ever changes: a stale boolean would make the deviation arm compare two
    IDENTICAL plans and the collapse arm compare two DIFFERENT ones."""
    var nf = List[Bool]()
    nf.append(True)
    return Optional(nf^)


def test_sort_nulls_placement_reaches_the_structural_hash() raises:
    """`SortData.nulls_first` — a per-key SQL `NULLS FIRST/LAST` override —
    must reach `_write_plan_node`. Otherwise `ORDER BY x ASC` (derived) and
    `ORDER BY x ASC NULLS <the other one>` render the identical text
    `Sort(keys=[l_quantity ASC])`, hash the same, and share a `factory_hash`
    in the plan-compile cache. The compiled plan for one would be returned for
    the other: rows come back with NULLs at the wrong end. (The same class as
    a scan binding whose params never reach the render.)

    ⚠ AND THE RENDER MUST STAY CONDITIONAL. A render that emitted the placement
    unconditionally would change every existing sort plan's `structural_hash`
    — a tree-wide cache invalidation with nothing going red. The second
    assertion pins that: an explicit override EQUAL to the derived default
    hashes identically to no override at all.

    Both literals below are derived from
    `null_order_policy.derived_nulls_first`: what is asserted is the
    RELATIONSHIP between a deviating request and the derived one.
    """
    var derived = LogicalPlan.sort(
        _asc_keys(), _asc_desc(), _make_lineitem()^
    )
    var overridden = LogicalPlan.sort(
        _asc_keys(), _asc_desc(), _make_lineitem()^, _deviating_override()
    )
    assert_true(
        derived.structural_hash() != overridden.structural_hash(),
        "an explicit ASC NULLS FIRST shares a plan-compile cache key with the"
        " derived ASC NULLS LAST;"
        " rendered as: " + String(derived),
    )

    # The default render did not move: an explicit override equal to the
    # derived placement must be byte-identical to passing none.
    var same_as_derived = List[Bool]()
    same_as_derived.append(False)  # the derived value: NULLS LAST, both directions
    var explicit_default = LogicalPlan.sort(
        _asc_keys(), _asc_desc(), _make_lineitem()^, Optional(same_as_derived^)
    )
    assert_equal(String(derived), String(explicit_default))
    assert_equal(derived.structural_hash(), explicit_default.structural_hash())


def test_topn_nulls_placement_reaches_the_structural_hash() raises:
    """`TopNData` carries the identical `nulls_first` field and must render it
    the same way."""
    var derived = LogicalPlan.topn(
        _asc_keys(), _asc_desc(), 10, _make_lineitem()^
    )
    var overridden = LogicalPlan.topn(
        _asc_keys(), _asc_desc(), 10, _make_lineitem(), _deviating_override()
    )
    assert_true(
        derived.structural_hash() != overridden.structural_hash(),
        "TopN: an explicit ASC NULLS FIRST shares a plan-compile cache key with"
        " the derived ASC NULLS LAST; rendered as: " + String(derived),
    )


def main() raises:
    test_scan_only_clone_stable()
    test_filter_clone_stable()
    test_project_filter_scan_clone_stable()
    test_aggregate_project_filter_scan_clone_stable()
    test_join_two_scans_clone_stable()
    test_nested_join_clone_stable()
    test_independently_built_identical_subtrees_match()
    test_sort_nulls_placement_reaches_the_structural_hash()
    test_topn_nulls_placement_reaches_the_structural_hash()
    print("test_structural_hash_stability_spike: all 9 cases PASS")
