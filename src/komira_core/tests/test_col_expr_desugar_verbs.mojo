# =============================================================================
# The untyped Mojo door's desugared verbs + reflected operators — the TREE
# each one builds.
#
# ★ WHAT THIS PINS AND WHAT IT DOES NOT. Each verb here is a tree over nodes the
# engine already evaluates, built by `scalar_desugar` (shared with the SQL
# binder) or by an operator overload. This file pins the SHAPE — the literal
# on the LEFT for a reflected operator, the ungarded ELSE of `coalesce`, the
# NULL arm of `fill_nan`, the two comparison operators `closed=` picks — so a
# refactor that silently builds a different tree reds here in seconds. The
# VALUES are graded end-to-end against DuckDB elsewhere, over parquet
# fixtures.
#
# Comparisons use `plan_helpers._expr_fingerprint`, the engine's ONE
# structural fingerprint, against a hand-built expected tree. It sorts the
# children of AND/OR only, so `100 - v` and `v - 100` stay distinct, which
# `test_reflected_sub_is_not_the_unreflected_one` asserts (the control).
# =============================================================================

from std.math import inf
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import (
    Expr,
    WhenCaseData,
    EXPR_BINARY_OP,
    EXPR_WHEN,
    EXPR_UNARY_OP,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
    BIN_EQ, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR,
    UN_NOT, UN_IS_NULL, UN_IS_NOT_NULL,
    MATH2_POW,
    EXTRACT_YEAR, EXTRACT_MICROSECOND,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.plan_helpers import _expr_fingerprint
from komira_core.plan.col_expr import (
    ColExpr, col, lit, coalesce, greatest, least, max_horizontal,
    min_horizontal,
)


def _v() -> Expr:
    return Expr.col_ref(String("v"))


def _i(n: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(n))


def _f(x: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(x))


def _same(got: Expr, want: Expr, what: String) raises:
    assert_equal(_expr_fingerprint(got), _expr_fingerprint(want), what)


# ---- reflected operators: the SCALAR on the LEFT -----------------------------


def test_reflected_add_sub_mul_put_the_literal_on_the_left() raises:
    _same((100 + col("v")).copy_expr(), Expr.binary(BIN_ADD, _i(100), _v()), "100 + v")
    _same((100 - col("v")).copy_expr(), Expr.binary(BIN_SUB, _i(100), _v()), "100 - v")
    _same((3 * col("v")).copy_expr(), Expr.binary(BIN_MUL, _i(3), _v()), "3 * v")
    _same((2.0 * col("v")).copy_expr(), Expr.binary(BIN_MUL, _f(2.0), _v()), "2.0 * v")
    _same((1.0 - col("v")).copy_expr(), Expr.binary(BIN_SUB, _f(1.0), _v()), "1.0 - v")


def test_reflected_sub_is_not_the_unreflected_one() raises:
    """THE CONTROL: the fingerprint keeps operand order for `-`, so a
    reflected operator that built `v - 100` would red the test above."""
    assert_true(
        _expr_fingerprint((100 - col("v")).copy_expr())
        != _expr_fingerprint((col("v") - 100).copy_expr()),
        "100 - v and v - 100 must not fingerprint equal",
    )


def test_reflected_division_keeps_duckdb_meanings() raises:
    # `/` is TRUE division: an unproven integer left operand is cast.
    _same(
        (120 / col("v")).copy_expr(),
        Expr.binary(BIN_DIV, Expr.cast(_i(120), DType.float64), _v()),
        "120 / v casts the literal",
    )
    # A float literal PROVES floating: no cast.
    _same((1.5 / col("v")).copy_expr(), Expr.binary(BIN_DIV, _f(1.5), _v()), "1.5 / v")
    # `//` is DuckDB's truncating integer division = BIN_DIV unchanged.
    _same((100 // col("v")).copy_expr(), Expr.binary(BIN_DIV, _i(100), _v()), "100 // v")
    # `%` is DuckDB's truncating remainder.
    _same((100 % col("v")).copy_expr(), Expr.binary(BIN_MOD, _i(100), _v()), "100 % v")
    _same((col("v") % 7).copy_expr(), Expr.binary(BIN_MOD, _v(), _i(7)), "v % 7")
    _same(col("v").mod(7).copy_expr(), Expr.binary(BIN_MOD, _v(), _i(7)), "v.mod(7) == v % 7")


def test_pow_and_star_star_are_math2_pow() raises:
    _same(col("v").pow(2).copy_expr(), Expr.math_fn2(MATH2_POW, _v(), _i(2)), "v.pow(2)")
    _same((col("v") ** 3).copy_expr(), Expr.math_fn2(MATH2_POW, _v(), _i(3)), "v ** 3")
    _same((2 ** col("v")).copy_expr(), Expr.math_fn2(MATH2_POW, _i(2), _v()), "2 ** v")
    _same(
        (col("v") ** col("w")).copy_expr(),
        Expr.math_fn2(MATH2_POW, _v(), Expr.col_ref(String("w"))),
        "v ** w",
    )


# ---- coalesce / fill_null ----------------------------------------------------


def _coalesce2(var a: Expr, var b: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.unary(UN_IS_NOT_NULL, a.copy()), a^))
    return Expr.when(cases^, b^)


def test_coalesce_is_a_first_non_null_case_with_an_unguarded_else() raises:
    var z = Expr.literal(ScalarValue.from_string(String("Z")))
    _same(coalesce(col("v"), lit("Z")).copy_expr(), _coalesce2(_v(), z.copy()), "coalesce(v, 'Z')")
    var three = coalesce(col("v"), col("w"), lit("Z")).copy_expr()
    assert_equal(three.tag, EXPR_WHEN)
    assert_equal(three.when_num_cases(), 2, "3 args -> 2 guarded branches")
    _same(three.when_default_ref(), z, "the LAST argument is the unguarded ELSE")
    _same(coalesce(col("v")).copy_expr(), _v(), "coalesce(v) is v, no CASE")


def test_coalesce_of_nothing_raises() raises:
    var raised = False
    try:
        _ = coalesce()
    except e:
        raised = True
        assert_true(String(e).find("at least 1 argument") >= 0, String(e))
    assert_true(raised, "coalesce() must refuse zero arguments by name")


def test_fill_null_is_coalesce_self_value() raises:
    _same(col("v").fill_null(lit("Z")).copy_expr(), coalesce(col("v"), lit("Z")).copy_expr(), "ColExpr arg")
    _same(col("v").fill_null(String("Z")).copy_expr(), coalesce(col("v"), lit("Z")).copy_expr(), "String arg")
    _same(col("v").fill_null(0).copy_expr(), _coalesce2(_v(), _i(0)), "Int arg over an unproven column")


def test_fill_null_promotes_an_int_literal_when_the_value_proves_float() raises:
    """The CASE executor's one-dtype rule: `(v * 1.5)` PROVES float, so the
    integer fill becomes 0.0 — what the SQL binder does from the schema."""
    var e = (col("v") * 1.5).fill_null(0).copy_expr()
    assert_true(e.when_default_ref().literal_value().is_float(), "ELSE promoted to 0.0")
    var g = greatest(col("v") * 1.5, lit(3)).copy_expr()
    assert_true(g.when_default_ref().literal_value().is_float(), "greatest ELSE promoted")


# ---- greatest / least --------------------------------------------------------


def test_greatest_least_ignore_a_null_operand() raises:
    var w = Expr.col_ref(String("w"))
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.unary(UN_IS_NULL, _v()), w.copy()))
    cases.append(WhenCaseData(Expr.unary(UN_IS_NULL, w.copy()), _v()))
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _v(), w.copy()), _v()))
    var want = Expr.when(cases^, w.copy())
    _same(greatest(col("v"), col("w")).copy_expr(), want, "greatest(v, w)")
    _same(max_horizontal(col("v"), col("w")).copy_expr(), want, "max_horizontal == greatest")
    var l = least(col("v"), col("w")).copy_expr()
    assert_equal(l.when_case_condition_ref(2).binary_op(), BIN_LT, "least compares with <")
    _same(min_horizontal(col("v"), col("w")).copy_expr(), l, "min_horizontal == least")


# ---- float classification + fill_nan -----------------------------------------


def _isnan(x: Expr) -> Expr:
    var fin = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GT, x.copy(), _f(-inf[DType.float64]())),
        Expr.binary(BIN_LT, x.copy(), _f(inf[DType.float64]())),
    )
    var inf = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_EQ, x.copy(), _f(inf[DType.float64]())),
        Expr.binary(BIN_EQ, x.copy(), _f(-inf[DType.float64]())),
    )
    return Expr.binary(BIN_AND, Expr.unary(UN_NOT, fin^), Expr.unary(UN_NOT, inf^))


def test_nan_tests_are_comparisons_against_infinity() raises:
    _same(col("v").is_nan(), _isnan(_v()), "is_nan")
    _same(col("v").is_not_nan(), Expr.unary(UN_NOT, _isnan(_v())), "is_not_nan = NOT is_nan")
    var fin = col("v").is_finite()
    assert_equal(fin.binary_op(), BIN_AND, "is_finite is x > -inf AND x < inf")
    var inf = col("v").is_infinite()
    assert_equal(inf.binary_op(), BIN_OR, "is_infinite is x = inf OR x = -inf")


def test_fill_nan_keeps_a_null() raises:
    var keep = Expr.binary(
        BIN_OR, Expr.unary(UN_IS_NULL, _v()), Expr.unary(UN_NOT, _isnan(_v()))
    )
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(keep^, _v()))
    _same(col("v").fill_nan(0.0).copy_expr(), Expr.when(cases^, _f(0.0)), "fill_nan(0.0)")


# ---- is_between --------------------------------------------------------------


def _between(lo_op: UInt8, hi_op: UInt8) -> Expr:
    return Expr.binary(
        BIN_AND, Expr.binary(lo_op, _v(), _i(2)), Expr.binary(hi_op, _v(), _i(5))
    )


def test_is_between_closed_picks_the_two_comparisons() raises:
    _same(col("v").is_between(2, 5), _between(BIN_GE, BIN_LE), "default = both = SQL BETWEEN")
    _same(col("v").is_between(2, 5, "left"), _between(BIN_GE, BIN_LT), "left")
    _same(col("v").is_between(2, 5, "right"), _between(BIN_GT, BIN_LE), "right")
    _same(col("v").is_between(2, 5, "none"), _between(BIN_GT, BIN_LT), "none")


def test_is_between_refuses_an_unknown_closed_by_name() raises:
    var raised = False
    try:
        _ = col("v").is_between(2, 5, "open")
    except e:
        raised = True
        assert_true(String(e).find("'both', 'left', 'right', 'none'") >= 0, String(e))
    assert_true(raised, "closed='open' must raise naming the four words")


# ---- even + the temporal names -----------------------------------------------


def test_even_casts_then_rounds_away_from_zero() raises:
    var e = col("v").even().copy_expr()
    assert_equal(e.tag, EXPR_WHEN)
    assert_equal(e.when_num_cases(), 1)
    ref cond = e.when_case_condition_ref(0)
    assert_equal(cond.binary_op(), BIN_GE, "x >= 0 picks ceil")
    assert_true(cond.binary_left_ref().is_cast(), "the operand is CAST to DOUBLE")
    assert_true(cond.binary_left_ref().cast_target_arrow() == ArrowType.FLOAT64, "FLOAT64")


def test_year_derived_names_and_nanosecond() raises:
    _same(
        col("d").decade(),
        Expr.binary(
            BIN_DIV,
            Expr.extract(EXTRACT_YEAR, Expr.col_ref(String("d"))),
            Expr.literal(ScalarValue.from_int64(10)),
        ),
        "decade = year / 10",
    )
    _same(
        col("d").nanosecond(),
        Expr.binary(
            BIN_MUL,
            Expr.extract(EXTRACT_MICROSECOND, Expr.col_ref(String("d"))),
            Expr.literal(ScalarValue.from_int64(1000)),
        ),
        "nanosecond = microsecond * 1000",
    )
    for which in range(3):
        var e = col("d").century() if which == 0 else (
            col("d").millennium() if which == 1 else col("d").era()
        )
        assert_equal(e.tag, EXPR_WHEN)
        assert_equal(e.when_num_cases(), 2, "an AD arm and a BC arm")
        assert_true(
            e.when_default_ref().literal_value().is_null(),
            "the ELSE is the NULL arm (a NULL year reaches only it)",
        )


def test_days_in_month_has_twelve_branches_and_a_null_else() raises:
    var e = col("d").days_in_month()
    assert_equal(e.tag, EXPR_WHEN)
    assert_equal(e.when_num_cases(), 12)
    assert_true(e.when_default_ref().literal_value().is_null(), "NULL, not 31")
    ref feb = e.when_case_result_ref(1)
    assert_equal(feb.tag, EXPR_WHEN, "February is the ordered leap chain")
    assert_equal(feb.when_num_cases(), 3, "% 400, % 100, % 4")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
