# =============================================================================
# select_aggregates, the expression half: where an aggregate sits, whether an
# expression reads a row, hoisting, the output names and the refusals.
# =============================================================================
#
# Each predicate gets the aggregate in every slot of every node kind it walks
# (the left and the right of a binary, each part of a CASE), so an arm that
# looks at one operand only, or not at all, fails here. `hoist_aggregates` is
# checked by the text of what it rebuilds and the aggregates it collects, in
# order. The plan builders are `test_select_aggregates_plans`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.agg_expr import AGG_MAX, AGG_MEAN, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_DIV,
    BIN_GT,
    BIN_MUL,
    EXPR_AGG_FN,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_UNARY_OP,
    EXPR_WHEN,
    UN_NEGATE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_sdk.select_aggregates import (
    HIDDEN_AGG_PREFIX,
    _is_top_aggregate,
    _output_name,
    _rebuildable,
    aggregate_expr_refusal,
    has_aggregate,
    has_nested_aggregate,
    hoist_aggregates,
    name_unaliased,
    predicate_aggregate_refusal,
    reads_a_row,
)


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _lit() -> Expr:
    return Expr.literal(ScalarValue.from_int(2))


def _agg() -> Expr:
    return Expr.agg_fn(AGG_MAX, _c("v"))


def _bin(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_ADD, l^, r^)


def _case(var cond: Expr, var result: Expr, var default: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(cond^, result^))
    return Expr.when(cases^, default^)


def test_rebuildable_tags() raises:
    var yes: List[UInt8] = [
        EXPR_ALIAS, EXPR_BINARY_OP, EXPR_UNARY_OP, EXPR_CAST, EXPR_MATH_FN,
        EXPR_MATH_FN2, EXPR_WHEN,
    ]
    for i in range(len(yes)):
        assert_true(_rebuildable(yes[i]), String(Int(yes[i])))
    assert_false(_rebuildable(EXPR_COL_REF))
    assert_false(_rebuildable(EXPR_AGG_FN))


def test_is_top_aggregate() raises:
    assert_true(_is_top_aggregate(_agg()))
    assert_true(_is_top_aggregate(Expr.alias(_agg(), "m")))
    assert_false(_is_top_aggregate(Expr.alias(_c("v"), "m")))
    assert_false(_is_top_aggregate(_bin(_agg(), _lit())))


def test_has_aggregate_every_slot() raises:
    assert_true(has_aggregate(_agg()), "the aggregate itself")
    assert_true(has_aggregate(Expr.alias(_agg(), "x")), "alias")
    assert_true(has_aggregate(_bin(_agg(), _lit())), "binary left")
    assert_true(has_aggregate(_bin(_lit(), _agg())), "binary right")
    assert_true(has_aggregate(Expr.unary(UN_NEGATE, _agg())), "unary")
    assert_true(has_aggregate(Expr.cast(_agg(), DType.float64)), "cast")
    assert_true(has_aggregate(Expr.sqrt(_agg())), "math_fn")
    assert_true(has_aggregate(Expr.atan2(_agg(), _lit())), "math_fn2 left")
    assert_true(has_aggregate(Expr.atan2(_lit(), _agg())), "math_fn2 right")
    assert_true(has_aggregate(_case(_agg(), _lit(), _lit())), "case condition")
    assert_true(has_aggregate(_case(_lit(), _agg(), _lit())), "case result")
    assert_true(has_aggregate(_case(_lit(), _lit(), _agg())), "case default")
    assert_false(has_aggregate(_case(_c("v"), _lit(), _lit())), "case without")
    assert_false(has_aggregate(_bin(_c("v"), _lit())), "binary without")
    assert_false(has_aggregate(Expr.alias(_c("v"), "x")), "alias without")
    assert_false(has_aggregate(Expr.atan2(_c("v"), _lit())), "math_fn2 without")
    assert_false(has_aggregate(Expr.upper(_agg())), "a node it does not walk")


def test_reads_a_row_every_slot() raises:
    assert_false(reads_a_row(_agg()), "an aggregate reduces")
    assert_true(reads_a_row(_c("v")), "a column")
    assert_false(reads_a_row(_lit()), "a literal")
    assert_true(reads_a_row(Expr.alias(_c("v"), "x")), "alias")
    assert_true(reads_a_row(_bin(_c("v"), _agg())), "binary left")
    assert_true(reads_a_row(_bin(_agg(), _c("v"))), "binary right")
    assert_false(reads_a_row(_bin(_agg(), _lit())), "binary of no row")
    assert_true(reads_a_row(Expr.unary(UN_NEGATE, _c("v"))), "unary")
    assert_true(reads_a_row(Expr.cast(_c("v"), DType.float64)), "cast")
    assert_true(reads_a_row(Expr.sqrt(_c("v"))), "math_fn")
    assert_true(reads_a_row(Expr.atan2(_c("v"), _agg())), "math_fn2 left")
    assert_true(reads_a_row(Expr.atan2(_agg(), _c("v"))), "math_fn2 right")
    assert_true(reads_a_row(_case(_c("v"), _lit(), _lit())), "case condition")
    assert_true(reads_a_row(_case(_lit(), _c("v"), _lit())), "case result")
    assert_true(reads_a_row(_case(_lit(), _lit(), _c("v"))), "case default")
    assert_false(reads_a_row(_case(_lit(), _agg(), _lit())), "case of no row")
    assert_true(reads_a_row(Expr.upper(_c("s"))), "any other node: its columns")
    assert_false(reads_a_row(Expr.upper(_lit())), "any other node without one")


def _hidden(i: Int) -> String:
    return String(HIDDEN_AGG_PREFIX) + String(i)


def test_hoist_every_arm() raises:
    var aggs = List[Expr]()
    var a = hoist_aggregates(_agg(), aggs)
    assert_equal(a.col_ref_name(), _hidden(0))
    assert_equal(len(aggs), 1)
    assert_equal(Int(aggs[0].tag), Int(EXPR_AGG_FN))

    aggs = List[Expr]()
    var al = hoist_aggregates(Expr.alias(_agg(), "m"), aggs)
    assert_equal(al.alias_name(), "m")
    assert_equal(al.alias_child_ref().col_ref_name(), _hidden(0))

    aggs = List[Expr]()
    var div = Expr.binary_with_division_intent(
        BIN_DIV, _c("v"), Expr.agg_fn(AGG_SUM, _c("w")), 1
    )
    var b = hoist_aggregates(div, aggs)
    assert_equal(Int(b.binary_op()), Int(BIN_DIV))
    assert_equal(Int(b.binary_division_intent()), Int(div.binary_division_intent()))
    assert_equal(b.binary_left_ref().col_ref_name(), "v")
    assert_equal(b.binary_right_ref().col_ref_name(), _hidden(0))

    aggs = List[Expr]()
    var u = hoist_aggregates(Expr.unary(UN_NEGATE, _agg()), aggs)
    assert_equal(Int(u.unary_op()), Int(UN_NEGATE))
    assert_equal(u.unary_child_ref().col_ref_name(), _hidden(0))

    aggs = List[Expr]()
    var cast = Expr.cast(_agg(), DType.float32)
    var ct = hoist_aggregates(cast, aggs)
    assert_equal(Int(ct.tag), Int(EXPR_CAST))
    assert_true(ct.cast_target() == cast.cast_target(), "the cast target is kept")
    assert_equal(ct.cast_child_ref().col_ref_name(), _hidden(0))

    aggs = List[Expr]()
    var m = hoist_aggregates(Expr.sqrt(_agg()), aggs)
    assert_equal(Int(m.tag), Int(EXPR_MATH_FN))
    assert_equal(Int(m.math_fn_op()), Int(Expr.sqrt(_lit()).math_fn_op()))
    assert_equal(m.math_fn_child_ref().col_ref_name(), _hidden(0))

    aggs = List[Expr]()
    var m2 = hoist_aggregates(Expr.atan2(_agg(), Expr.agg_fn(AGG_MEAN, _c("w"))), aggs)
    assert_equal(Int(m2.tag), Int(EXPR_MATH_FN2))
    assert_equal(m2.math_fn2_left_ref().col_ref_name(), _hidden(0))
    assert_equal(m2.math_fn2_right_ref().col_ref_name(), _hidden(1))
    assert_equal(len(aggs), 2, "both aggregates, left first")
    assert_equal(Int(aggs[1].agg_fn_op()), Int(AGG_MEAN))

    aggs = List[Expr]()
    var w = hoist_aggregates(_case(_bin(_agg(), _lit()), _agg(), _agg()), aggs)
    assert_equal(Int(w.tag), Int(EXPR_WHEN))
    assert_equal(len(aggs), 3, "condition, result, default")
    assert_equal(w.when_case_result_ref(0).col_ref_name(), _hidden(1))
    assert_equal(w.when_default_ref().col_ref_name(), _hidden(2))

    aggs = List[Expr]()
    var other = hoist_aggregates(Expr.upper(_agg()), aggs)
    assert_equal(len(aggs), 0, "a node it does not rebuild is kept as built")
    assert_equal(String(other), String(Expr.upper(_agg())))


def test_has_nested_aggregate() raises:
    var top = ExprArray()
    top.append(_agg())
    top.append(Expr.alias(_agg(), "m"))
    top.append(_c("v"))
    assert_false(has_nested_aggregate(top))
    var nested = ExprArray()
    nested.append(_c("v"))
    nested.append(_bin(_agg(), _lit()))
    assert_true(has_nested_aggregate(nested))


def test_output_name() raises:
    assert_equal(_output_name(Expr.alias(_bin(_lit(), _agg()), "n")).value(), "n")
    assert_equal(_output_name(_bin(_c("q"), _agg())).value(), "q")
    assert_false(Bool(_output_name(_bin(_lit(), _agg()))))


def test_aggregate_expr_refusal() raises:
    var fine = ExprArray()
    fine.append(_c("v"))
    fine.append(_bin(_c("v"), _agg()))
    assert_equal(aggregate_expr_refusal(fine, False), "")
    assert_equal(aggregate_expr_refusal(fine, True), "", "a plain operand")
    var unnamed = ExprArray()
    unnamed.append(_bin(_lit(), _agg()))
    var why = aggregate_expr_refusal(unnamed, False)
    assert_true(why.find("no column as its LEFTMOST leaf") != -1, why)
    var computed = ExprArray()
    computed.append(
        _bin(_c("v"), Expr.agg_fn(AGG_MEAN, Expr.binary(BIN_MUL, _c("v"), _lit())))
    )
    assert_equal(aggregate_expr_refusal(computed, False), "", "reduce: served")
    var b = aggregate_expr_refusal(computed, True)
    assert_true(b.find("an aggregate of a COMPUTED expression") != -1, b)


def test_predicate_aggregate_refusal() raises:
    assert_equal(predicate_aggregate_refusal(Expr.binary(BIN_GT, _c("v"), _agg())), "")
    var computed = Expr.binary(
        BIN_GT, _c("v"), Expr.agg_fn(AGG_MEAN, _bin(_c("v"), _lit()))
    )
    var why = predicate_aggregate_refusal(computed)
    assert_true(why.find("COMPUTED") != -1, why)


def test_name_unaliased() raises:
    var ex = ExprArray()
    ex.append(Expr.alias(_bin(_c("a"), _lit()), "kept"))
    ex.append(_c("b"))
    ex.append(_agg())
    ex.append(Expr.binary(BIN_MUL, _c("a"), _lit()))
    ex.append(_bin(_lit(), _c("a")))
    ex.append(Expr.regexp_like(_c("s"), "x"))
    var out = name_unaliased(ex)
    assert_equal(len(out), 6)
    assert_equal(out[0].alias_name(), "kept", "an alias is left alone")
    assert_equal(Int(out[1].tag), Int(EXPR_COL_REF), "a column is left alone")
    assert_equal(Int(out[2].tag), Int(EXPR_AGG_FN), "a top aggregate is left alone")
    assert_equal(out[3].alias_name(), "a", "the leftmost column")
    assert_equal(out[4].alias_name(), "literal", "a literal-rooted expression")
    assert_equal(Int(out[5].tag), Int(Expr.regexp_like(_c("s"), "x").tag), "no root")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
