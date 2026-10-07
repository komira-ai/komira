# =============================================================================
# agg_output_naming: polars' output name of an unaliased aggregate, arm by arm.
# =============================================================================
#
# `polars_root_name` is the leftmost leaf of an expression. Each node kind it
# descends gets a test whose leftmost column is `x` under that node, so an arm
# that is dropped (returns None) or that descends the wrong operand (the right
# side of a binary or of a two-argument function) fails by name.
# `author_polars_agg_names` gets one test per rule: an alias wins, `count(*)`
# is `len`, another childless aggregate keeps the engine's word, a column
# argument names it, a literal-rooted argument is refused, and a second pass
# changes nothing.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_GT,
    UN_NOT,
    STR_CONTAINS,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM, AGG_MAX
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import AggExprArray

from komira_sdk.agg_output_naming import (
    COUNT_STAR_OUTPUT_NAME,
    author_polars_agg_names,
    polars_agg_out_name,
    polars_root_name,
)


def _x() -> Expr:
    return Expr.col_ref("x")


def _y() -> Expr:
    return Expr.col_ref("y")


def _one() -> Expr:
    return Expr.literal(ScalarValue.from_int(1))


def _root_is(e: Expr, want: String, what: String) raises:
    var r = polars_root_name(e)
    assert_true(Bool(r), what + ": a root name")
    assert_equal(r.value(), want, what)


def test_polars_agg_out_name() raises:
    """A rooted aggregate is its root; `count(*)` is `len`; any other
    childless aggregate keeps the engine's base name."""
    assert_equal(polars_agg_out_name(AGG_SUM, True, String("v")), "v")
    assert_equal(polars_agg_out_name(AGG_COUNT, True, String("k")), "k")
    assert_equal(polars_agg_out_name(AGG_COUNT, False, String()), "len")
    assert_equal(String(COUNT_STAR_OUTPUT_NAME), "len")
    assert_equal(polars_agg_out_name(AGG_SUM, False, String()), "sum")
    assert_equal(polars_agg_out_name(AGG_MAX, False, String()), "max")


def test_root_leaves() raises:
    _root_is(_x(), "x", "a column")
    _root_is(Expr.alias(_y(), "named"), "named", "an alias inside wins")
    assert_false(Bool(polars_root_name(_one())), "a literal has no root")
    var lit_named = polars_root_name(_one(), True)
    assert_true(Bool(lit_named), "literal_named names a literal")
    assert_equal(lit_named.value(), "literal")


def test_root_descends_the_left_operand() raises:
    """Binary and two-argument functions take their FIRST operand."""
    _root_is(Expr.binary(BIN_ADD, _x(), _y()), "x", "binary left")
    _root_is(Expr.atan2(_x(), _y()), "x", "math_fn2 left")
    # A literal on the left: no root, unless literals are named.
    var lit_left = Expr.binary(BIN_ADD, _one(), _y())
    assert_false(Bool(polars_root_name(lit_left)), "literal left, unnamed")
    var named = polars_root_name(lit_left, True)
    assert_equal(named.value(), "literal", "literal_named passes down")


def test_root_one_child_arms() raises:
    _root_is(Expr.unary(UN_NOT, _x()), "x", "unary")
    _root_is(Expr.cast(_x(), DType.float64), "x", "cast")
    _root_is(Expr.sqrt(_x()), "x", "math_fn")
    _root_is(Expr.string_op(STR_CONTAINS, _x(), "a"), "x", "string_op")
    _root_is(Expr.upper(_x()), "x", "string_fn")
    _root_is(Expr.substring(_x(), 1, 2), "x", "substring")
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(3))
    _root_is(Expr.in_list_node(_x(), vals^), "x", "in_list")
    _root_is(Expr.agg_fn(AGG_MAX, _x()), "x", "aggregate as expression")


def test_root_case_takes_first_then() raises:
    """A CASE is its FIRST `then`; a CASE with no branch has no root."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _y(), _one()), _x()))
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _y(), _one()), _y()))
    _root_is(Expr.when(cases^, _y()), "x", "case")
    var none = Expr.when(List[WhenCaseData](), _x())
    assert_false(Bool(polars_root_name(none)), "a CASE with no branch")


def test_root_other_nodes_have_none() raises:
    """A node the walk does not descend (a regexp) has no root name."""
    assert_false(Bool(polars_root_name(Expr.regexp_like(_x(), "a+"))))


def test_author_names_every_rule() raises:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](_x()), Optional[String]("s")))
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]()))
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](), Optional[String]()))
    aggs.append(
        AggExpr(
            AGG_MAX,
            Optional[Expr](Expr.binary(BIN_ADD, _y(), _one())),
            Optional[String](),
        )
    )
    author_polars_agg_names(aggs)
    assert_equal(aggs[0].alias_name.value(), "s", "an alias is kept")
    assert_equal(aggs[1].alias_name.value(), "len", "count(*)")
    assert_equal(aggs[2].alias_name.value(), "sum", "childless, not count")
    assert_equal(aggs[3].alias_name.value(), "y", "the leftmost column")
    # Idempotent: every aggregate is aliased now, so nothing changes.
    author_polars_agg_names(aggs)
    assert_equal(aggs[1].alias_name.value(), "len")
    assert_equal(aggs[3].alias_name.value(), "y")


def test_author_refuses_a_literal_root() raises:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](_one()), Optional[String]()))
    var raised = False
    try:
        author_polars_agg_names(aggs)
    except e:
        raised = True
        assert_true(String(e).find("LEFTMOST") != -1, String(e))
        assert_true(String(e).find(".alias(") != -1, String(e))
    assert_true(raised, "a literal-rooted aggregate is refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
