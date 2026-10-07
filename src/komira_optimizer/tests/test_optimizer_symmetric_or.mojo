# =============================================================================
# test_optimizer_symmetric_or -- swap ORs gain single-column IN conjuncts
# =============================================================================
#
# `(A == x AND B == y) OR (A == y AND B == x)` (form 1) and its transposed
# spelling `(A == x AND B == y) OR (B == x AND A == y)` (form 2) become
# `(A IN {x, y}) AND (B IN {x, y}) AND <the original OR>`, with each IN spelled
# `(col == x) OR (col == y)`. Anything that is not exactly two
# `column == literal` conjuncts per side is left alone.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_GT,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_plan_ir.plan_helpers import _expr_fingerprint

from komira_optimizer.optimizer_symmetric_or import (
    decompose_symmetric_or,
    decompose_symmetric_or_inplace,
    decompose_symmetric_or_expr,
)


# =============================================================================
# Fixtures
# =============================================================================


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _eq(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(c), _lit(v))


def _eq_lit_left(v: Int, c: String) -> Expr:
    return Expr.binary(BIN_EQ, _lit(v), Expr.col_ref(c))


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _or(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_OR, l^, r^)


def _fp(e: Expr) -> String:
    return _expr_fingerprint(e)


def _form1() -> Expr:
    """(a == 1 AND b == 2) OR (a == 2 AND b == 1)."""
    return _or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("a", 2), _eq("b", 1)))


def _expected(var orig: Expr) -> Expr:
    """(a IN {1, 2}) AND (b IN {1, 2}) AND orig."""
    var a_in = _or(_eq("a", 1), _eq("a", 2))
    var b_in = _or(_eq("b", 1), _eq("b", 2))
    return _and(_and(a_in^, b_in^), orig^)


def _unchanged(var e: Expr) raises:
    var before = _fp(e)
    var out = decompose_symmetric_or_expr(e^)
    assert_equal(_fp(out), before)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _filter() -> LogicalPlan:
    return LogicalPlan.filter(
        _form1(), LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())
    )


# =============================================================================
# The two forms
# =============================================================================


def test_form_one_gains_both_in_conjuncts_and_keeps_the_or() raises:
    # Catches: a rewrite that drops the original OR (it is the residual that
    # rejects off-diagonal pairs such as a == 1 AND b == 1), or builds the IN
    # lists from the wrong values or columns.
    var out = decompose_symmetric_or_expr(_form1())
    assert_equal(_fp(out), _fp(_expected(_form1())))


def test_form_two_transposed_columns_also_match() raises:
    # (a == 1 AND b == 2) OR (b == 1 AND a == 2). Catches: the form-2 check
    # dropped (the transposed spelling would be left unrewritten).
    var orig = _or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("b", 1), _eq("a", 2)))
    var out = decompose_symmetric_or_expr(orig.copy())
    assert_equal(_fp(out), _fp(_expected(orig^)))


def test_literal_on_the_left_is_accepted() raises:
    # (1 == a AND b == 2) OR (a == 2 AND 1 == b). Catches: the commuted
    # comparison arm dropped.
    var orig = _or(
        _and(_eq_lit_left(1, "a"), _eq("b", 2)),
        _and(_eq("a", 2), _eq_lit_left(1, "b")),
    )
    var out = decompose_symmetric_or_expr(orig.copy())
    assert_equal(out.tag, EXPR_BINARY_OP)
    assert_equal(Int(out.binary_op()), Int(BIN_AND))
    assert_equal(_fp(out.binary_right_ref()), _fp(orig))
    assert_equal(_fp(out.binary_left_ref()), _fp(_and(
        _or(_eq("a", 1), _eq("a", 2)), _or(_eq("b", 1), _eq("b", 2))
    )))


# =============================================================================
# What is left alone
# =============================================================================


def test_shapes_that_are_not_a_swap_are_unchanged() raises:
    # Catches: a matcher that ignores the values, the columns, the operator,
    # or the exact two-conjunct shape (each would add IN lists that are not
    # implied by the OR and so filter out rows the OR keeps).
    # Values not swapped.
    _unchanged(_or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("a", 3), _eq("b", 4))))
    # Columns match for form 1 but only one value pair agrees.
    _unchanged(_or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("a", 2), _eq("b", 3))))
    # Columns match for form 2 but only one value pair agrees.
    _unchanged(_or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("b", 1), _eq("a", 3))))
    # The same column on both conjuncts.
    _unchanged(_or(_and(_eq("a", 1), _eq("a", 2)), _and(_eq("a", 2), _eq("a", 1))))
    # A side that is a single comparison, not an AND, or not a binary op.
    _unchanged(_or(_eq("a", 1), _and(_eq("a", 2), _eq("b", 1))))
    _unchanged(_or(Expr.col_ref("a"), _and(_eq("a", 2), _eq("b", 1))))
    _unchanged(_or(_and(_eq("a", 1), _eq("b", 2)), _eq("a", 2)))
    # A conjunct that is not an equality.
    _unchanged(_or(
        _and(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(1)), _eq("b", 2)),
        _and(_eq("a", 2), _eq("b", 1)),
    ))
    _unchanged(_or(
        _and(_eq("a", 1), Expr.binary(BIN_GT, Expr.col_ref("b"), _lit(2))),
        _and(_eq("a", 2), _eq("b", 1)),
    ))
    # An equality that is not column == literal.
    _unchanged(_or(
        _and(Expr.binary(BIN_EQ, Expr.col_ref("a"), Expr.col_ref("b")), _eq("b", 2)),
        _and(_eq("a", 2), _eq("b", 1)),
    ))
    # A conjunct that is not a binary op.
    _unchanged(_or(
        _and(Expr.col_ref("a"), _eq("b", 2)), _and(_eq("a", 2), _eq("b", 1))
    ))
    # Not an OR at all: a leaf, and a comparison.
    _unchanged(Expr.col_ref("a"))
    _unchanged(_eq("a", 1))


def test_a_swap_nested_under_and_or_or_is_found() raises:
    # Catches: the AND arm or the no-match OR recursion dropped (a swap that is
    # not the root would be missed).
    var under_and = decompose_symmetric_or_expr(_and(_eq("c", 0), _form1()))
    assert_equal(_fp(under_and), _fp(_and(_eq("c", 0), _expected(_form1()))))
    var under_or = decompose_symmetric_or_expr(_or(_form1(), _eq("c", 5)))
    assert_equal(_fp(under_or), _fp(_or(_expected(_form1()), _eq("c", 5))))


# =============================================================================
# The plan walk
# =============================================================================


def _wrap(kind: Int) -> LogicalPlan:
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        return _filter()
    if kind == 1:
        var pe = ExprArray()
        pe.append(Expr.col_ref("a"))
        return LogicalPlan.project(pe^, _filter())
    if kind == 2:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("a")), Optional[String]("s")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, _filter())
    if kind == 3:
        return LogicalPlan.sort(keys^, desc^, _filter())
    if kind == 4:
        return LogicalPlan.limit(2, _filter())
    if kind == 5:
        return LogicalPlan.distinct(None, _filter())
    if kind == 6:
        return LogicalPlan.topn(keys^, desc^, 2, _filter())
    var lk = List[String]()
    lk.append(String("a"))
    var rk = List[String]()
    rk.append(String("a"))
    return LogicalPlan.join(_filter(), _filter(), lk^, rk^, JOIN_INNER)


def _filter_pred_fp(imm plan: LogicalPlan, kind: Int) -> String:
    if kind == 0:
        return _fp(plan.filter_data_ref().predicate)
    if kind == 1:
        return _fp(plan.project_data_ref().child[].filter_data_ref().predicate)
    if kind == 2:
        return _fp(plan.aggregate_data_ref().child[].filter_data_ref().predicate)
    if kind == 3:
        return _fp(plan.sort_data_ref().child[].filter_data_ref().predicate)
    if kind == 4:
        return _fp(plan.limit_data_ref().child[].filter_data_ref().predicate)
    if kind == 5:
        return _fp(plan.distinct_data_ref().child[].filter_data_ref().predicate)
    if kind == 6:
        return _fp(plan.topn_data_ref().child[].filter_data_ref().predicate)
    return (
        _fp(plan.join_data_ref().left[].filter_data_ref().predicate)
        + _fp(plan.join_data_ref().right[].filter_data_ref().predicate)
    )


def test_the_walk_rewrites_a_filter_under_every_node_kind() raises:
    # Filter itself, then a Filter under Project, Aggregate, Sort, Limit,
    # Distinct, TopN and both sides of a Join. Catches: a recursion arm
    # dropped (the Filter below that kind keeps the bare OR).
    var want = _fp(_expected(_form1()))
    var want_twice = want.copy()
    want_twice += want
    for kind in range(8):
        var plan = _wrap(kind)
        decompose_symmetric_or_inplace(plan)
        if kind == 7:
            assert_equal(_filter_pred_fp(plan, kind), want_twice)
        else:
            assert_equal(_filter_pred_fp(plan, kind), want)
    # The value-taking wrapper does the same; a scan is a leaf.
    var out = decompose_symmetric_or(_filter())
    assert_equal(_fp(out.filter_data_ref().predicate), want)
    var scan = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())
    var h = scan.structural_hash()
    decompose_symmetric_or_inplace(scan)
    assert_equal(scan.structural_hash(), h)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
