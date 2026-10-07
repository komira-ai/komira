"""Tests of `komira_optimizer.flatten_dependent_joins` on correlated
subqueries and inner column references nested inside CASE WHEN, alias,
IN-list and aggregate expressions.

Each test names the defect it catches.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_AGG_FN,
    BIN_EQ,
    BIN_LT,
    BIN_GT,
    BIN_AND,
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
    WhenCaseData,
)
from komira_plan_expr.agg_expr import AGG_MAX
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_JOIN,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    JOIN_SEMI,
    ExprArray,
)

from komira_optimizer.flatten_dependent_joins import (
    flatten_dependent_joins,
    _expr_contains_correlated_subquery,
    _rewrite_inner_none_to_right,
)
from komira_optimizer.join_predicate_decompose import join_predicate_decompose


def _t() -> LogicalPlan:
    """Table `t(k, v)`, used on both sides of the self-correlation."""
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _kv() -> List[String]:
    var out = List[String]()
    out.append("k")
    out.append("v")
    return out^


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _case_v_or_zero() -> Expr:
    """`CASE WHEN v > 0 THEN v ELSE 0 END` over the inner `v`."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(
        Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(0)), Expr.col_ref("v")
    ))
    return Expr.when(cases^, _lit(0))


def test_inner_ref_inside_when_reads_the_right_column_after_decompose() raises:
    """`EXISTS (SELECT 1 FROM t i WHERE i.k = o.k AND
    o.v < CASE WHEN i.v > 0 THEN i.v ELSE 0 END)` over `t o`. The EQ lifts
    to the SEMI join key; the non-equi conjunct becomes the residual. After
    `join_predicate_decompose` the inner `v` inside the CASE must read
    `v_right` (the joined row's right-hand `v`); the outer `v` reads `v`.

    Catches: the inner refs under a WHEN left plain by the residual lift,
    so they bind to the outer `v` in the joined row."""
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_EQ, Expr.col_ref("k"), Expr.left("k")),
        Expr.binary(BIN_LT, Expr.left("v"), _case_v_or_zero()),
    )
    var inner = LogicalPlan.filter(pred^, _t())
    var c = Expr.correlated_subquery(inner^, _kv(), CORR_KIND_EXISTS)
    var out = flatten_dependent_joins(LogicalPlan.filter(c^, _t()))
    assert_equal(out.tag, PLAN_JOIN)
    assert_equal(out._join.value()[].join_type, JOIN_SEMI)
    assert_true(out._join.value()[].has_residual())

    var decomposed = join_predicate_decompose(out^)
    ref r = decomposed._join.value()[].residual.value()[]
    assert_equal(r.binary_op(), BIN_LT)
    assert_equal(r.binary_left_ref().col_ref_name(), String("v"))
    ref w = r.binary_right_ref()
    assert_equal(w.tag, EXPR_WHEN)
    ref wd = w._when.value()
    ref cond = wd.cases[0].condition[]
    assert_equal(cond.binary_left_ref().col_ref_name(), String("v_right"))
    assert_equal(cond.binary_left_ref().col_ref_side(), COL_SIDE_NONE)
    assert_equal(wd.cases[0].result[].col_ref_name(), String("v_right"))


def test_rewrite_inner_none_to_right_descends_alias_when_in_list_and_agg() raises:
    """`_rewrite_inner_none_to_right` marks the plain refs RIGHT and keeps
    the LEFT refs LEFT under an alias, every WHEN arm (condition, result,
    default), an IN-list child and an aggregate child, keeping each
    wrapper's payload (alias name, IN values, aggregate op).

    Catches: any of these arms copied as is, which leaves its inner refs
    plain for `join_predicate_decompose` to bind to the outer column."""
    var a = _rewrite_inner_none_to_right(Expr.alias(Expr.col_ref("v"), "w"))
    assert_equal(a.tag, EXPR_ALIAS)
    assert_equal(a.alias_name(), String("w"))
    assert_equal(a.alias_child_ref().col_ref_side(), COL_SIDE_RIGHT)

    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(
        Expr.binary(BIN_GT, Expr.col_ref("v"), Expr.left("v")), Expr.col_ref("k")
    ))
    var w = _rewrite_inner_none_to_right(Expr.when(cases^, Expr.col_ref("v")))
    assert_equal(w.tag, EXPR_WHEN)
    ref wd = w._when.value()
    assert_equal(len(wd.cases), 1)
    assert_equal(wd.cases[0].condition[].binary_op(), BIN_GT)
    assert_equal(wd.cases[0].condition[].binary_left_ref().col_ref_side(), COL_SIDE_RIGHT)
    assert_equal(wd.cases[0].condition[].binary_right_ref().col_ref_side(), COL_SIDE_LEFT)
    assert_equal(wd.cases[0].result[].col_ref_side(), COL_SIDE_RIGHT)
    assert_equal(wd.cases[0].result[].col_ref_name(), String("k"))
    assert_equal(wd.default[].col_ref_side(), COL_SIDE_RIGHT)

    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    vals.append(ScalarValue.from_int(2))
    var il = _rewrite_inner_none_to_right(Expr.in_list_node(Expr.col_ref("v"), vals^))
    assert_equal(il.tag, EXPR_IN_LIST)
    assert_equal(len(il._in_list.value().values), 2)
    assert_equal(il._in_list.value().values[1].int_val, Int64(2))
    assert_equal(il._in_list.value().child[].col_ref_side(), COL_SIDE_RIGHT)

    var g = _rewrite_inner_none_to_right(Expr.agg_fn(AGG_MAX, Expr.col_ref("v")))
    assert_equal(g.tag, EXPR_AGG_FN)
    assert_equal(g.agg_fn_op(), AGG_MAX)
    assert_equal(g.agg_fn_child_ref().col_ref_side(), COL_SIDE_RIGHT)


def _exists() -> Expr:
    """`EXISTS (SELECT 1 FROM t)` correlated on `k` (bare inner scan)."""
    var refs = List[String]()
    refs.append("k")
    return Expr.correlated_subquery(_t(), refs^, CORR_KIND_EXISTS)


def _bool(b: Bool) -> Expr:
    return Expr.literal(ScalarValue.from_bool(b))


def _when_with_exists_at(slot: Int) -> Expr:
    """A CASE with the EXISTS in its condition (0), result (1) or default (2)."""
    var cases = List[WhenCaseData]()
    if slot == 0:
        cases.append(WhenCaseData(_exists(), _bool(True)))
    elif slot == 1:
        cases.append(WhenCaseData(_bool(True), _exists()))
    else:
        cases.append(WhenCaseData(_bool(True), _bool(True)))
    if slot == 2:
        return Expr.when(cases^, _exists())
    return Expr.when(cases^, _bool(False))


def _raises_with(var plan: LogicalPlan, needle: String) raises -> Bool:
    try:
        _ = flatten_dependent_joins(plan^)
    except e:
        return String(e).find(needle) >= 0
    return False


def test_subquery_inside_when_is_seen_and_refused() raises:
    """A correlated EXISTS in a CASE condition, result or default is found
    by `_expr_contains_correlated_subquery`, and the pass refuses the shape
    (it has no lowering for it) in a Filter and in a Project instead of
    returning a plan that still holds the subquery node.

    Catches: the walker not descending WHEN (or one of its three slots), so
    the subquery survives the pass that promises to remove every one."""
    for slot in range(3):
        assert_true(_expr_contains_correlated_subquery(_when_with_exists_at(slot)))
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_bool(True), Expr.col_ref("v")))
    assert_false(_expr_contains_correlated_subquery(Expr.when(cases^, _bool(False))))

    assert_true(_raises_with(
        LogicalPlan.filter(_when_with_exists_at(0), _t()),
        "unsupported parent-shape for correlated subquery",
    ))
    var exprs = ExprArray()
    exprs.append(_when_with_exists_at(1))
    assert_true(_raises_with(
        LogicalPlan.project(exprs^, _t()),
        "correlated subquery in Project not yet supported",
    ))


def main() raises:
    test_inner_ref_inside_when_reads_the_right_column_after_decompose()
    test_rewrite_inner_none_to_right_descends_alias_when_in_list_and_agg()
    test_subquery_inside_when_is_seen_and_refused()
    print("All flatten_dependent_joins nested-expression tests passed.")
