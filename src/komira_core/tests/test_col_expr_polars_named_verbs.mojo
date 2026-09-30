# =============================================================================
# The untyped Mojo door's polars-named verbs — `is_in`, `.over()` on an
# AGGREGATE, `name()`
# prefix/suffix, `sum_horizontal`, `null_count` — the TREE each one builds.
#
# ★ `col("v").is_in([..])` is SQL's `v IN (..)`: `Expr.in_list`, the OR chain
#   of `=` the SQL parser desugars an IN list to (a NULL `v` answers NULL at
#   both doors).
# ★ `col("v").mean().over("g")` is polars' GROUP BROADCAST — SQL `avg(v) OVER
#   (PARTITION BY g)`: `Expr.with_window_spec` turns the `EXPR_AGG_FN` into the
#   whole-partition `EXPR_WINDOW_FN` of the same function. ⛔ Without that,
#   the same call would read a window payload the aggregate node does not
#   carry — undefined behaviour at the parent, not an error.
#
# The VALUES are graded end-to-end against DuckDB elsewhere, over parquet
# fixtures. This file pins the SHAPE, plus the AGG_* -> PF_* number mirror
# `expr.mojo` keeps (it cannot import either constant table).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.plan.expr import (
    Expr, BIN_ADD, BIN_EQ, BIN_OR, UN_IS_NULL, UN_IS_NOT_NULL, WhenCaseData,
    OVER_REFUSED_PREFIX,
)
from komira_core.plan.col_expr_bind import over_refusal
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.plan_helpers import _expr_fingerprint
from komira_core.plan.agg_expr import (
    AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN, AGG_COUNT_IF, null_count,
)
from komira_core.plan.partition_expr import (
    PF_SUM, PF_AVG, PF_COUNT, PF_MIN, PF_MAX,
)
from komira_core.plan.col_expr import ColExpr, col, sum_horizontal


def _v() -> Expr:
    return Expr.col_ref(String("v"))


def _same(got: Expr, want: Expr, what: String) raises:
    assert_equal(_expr_fingerprint(got), _expr_fingerprint(want), what)


# ---- is_in -------------------------------------------------------------------


def test_is_in_is_the_or_chain_sql_desugars_in_to() raises:
    var want = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_EQ, _v(), Expr.literal(ScalarValue.from_int(20))),
        Expr.binary(BIN_EQ, _v(), Expr.literal(ScalarValue.from_int(30))),
    )
    var ints: List[Int] = [20, 30]
    _same(col("v").is_in(ints), want, "v IN (20, 30)")
    var sv = List[ScalarValue]()
    sv.append(ScalarValue.from_int(20))
    sv.append(ScalarValue.from_int(30))
    _same(col("v").is_in(ints), Expr.in_list(_v(), sv^), "== Expr.in_list")


def test_is_in_float_and_string_members() raises:
    var fl: List[Float64] = [2.5, 3.5]
    var want_f = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_EQ, _v(), Expr.literal(ScalarValue.from_float(2.5))),
        Expr.binary(BIN_EQ, _v(), Expr.literal(ScalarValue.from_float(3.5))),
    )
    _same(col("v").is_in(fl), want_f, "v IN (2.5, 3.5)")
    var st: List[String] = [String("b"), String("c")]
    var want_s = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_EQ, _v(), Expr.literal(ScalarValue.from_string("b"))),
        Expr.binary(BIN_EQ, _v(), Expr.literal(ScalarValue.from_string("c"))),
    )
    _same(col("v").is_in(st), want_s, "v IN ('b', 'c')")


def test_is_in_empty_is_false_and_the_control_differs() raises:
    var none = List[Int]()
    _same(
        col("v").is_in(none),
        Expr.literal(ScalarValue.from_bool(False)),
        "IN () is FALSE",
    )
    var one: List[Int] = [20]
    var two: List[Int] = [20, 30]
    assert_true(
        _expr_fingerprint(col("v").is_in(one))
        != _expr_fingerprint(col("v").is_in(two)),
        "the CONTROL: a dropped member must change the tree",
    )


# ---- .over() on an aggregate -------------------------------------------------


def test_the_agg_to_window_number_mirror_matches_the_real_constants() raises:
    """`expr.mojo` maps AGG_* -> PF_* BY NUMBER (both tables import it). If
    either table renumbers, this reds instead of a window silently computing
    a different function."""
    assert_equal(Int(AGG_SUM), 0)
    assert_equal(Int(AGG_COUNT), 1)
    assert_equal(Int(AGG_MIN), 2)
    assert_equal(Int(AGG_MAX), 3)
    assert_equal(Int(AGG_MEAN), 4)
    assert_equal(Int(PF_SUM), 20)
    assert_equal(Int(PF_AVG), 21)
    assert_equal(Int(PF_COUNT), 22)
    assert_equal(Int(PF_MIN), 23)
    assert_equal(Int(PF_MAX), 24)


def _check_broadcast(e: Expr, func: UInt8, what: String) raises:
    assert_true(e.is_window_fn(), what + ": an EXPR_WINDOW_FN")
    ref w = e.window_fn_data_ref()
    assert_equal(Int(w.func), Int(func), what + ": the function")
    assert_equal(w.arg_col, String("v"), what + ": the argument column")
    assert_true(w.frame.is_full_partition(), what + ": the WHOLE partition")
    assert_equal(len(w.partition_by), 1, what + ": one partition key")
    assert_equal(w.partition_by[0], String("g"), what + ": partition g")
    assert_equal(len(w.order_by), 0, what + ": no order")


def test_mean_count_min_max_sum_over_g_are_whole_partition_windows() raises:
    _check_broadcast(col("v").mean().over("g"), PF_AVG, "mean().over(g)")
    _check_broadcast(col("v").avg().over("g"), PF_AVG, "avg().over(g)")
    _check_broadcast(col("v").count().over("g"), PF_COUNT, "count().over(g)")
    _check_broadcast(col("v").min().over("g"), PF_MIN, "min().over(g)")
    _check_broadcast(col("v").max().over("g"), PF_MAX, "max().over(g)")
    _check_broadcast(col("v").sum().over("g"), PF_SUM, "sum().over(g)")


def test_an_aggregate_over_with_an_order_keeps_the_whole_partition() raises:
    """Polars: an aggregate ignores `order_by`; the frame stays WHOLE (SQL's
    ordered `sum() OVER` would be a RUNNING sum — `cum_sum()` spells that)."""
    var pk: List[String] = [String("g")]
    var ok: List[String] = [String("k")]
    var e = col("v").sum().over(pk^, ok^)
    ref w = e.window_fn_data_ref()
    assert_true(w.frame.is_full_partition(), "still the whole partition")
    assert_equal(len(w.order_by), 1, "the order is recorded")


def test_an_aggregate_of_a_computed_operand_over_is_refused_by_name() raises:
    """`(col("v") * 2).sum().over("g")` — polars and DuckDB answer it, the
    window vocabulary names ONE input column. ⛔ This call must not ABORT the
    process: it returns a window CARRYING its refusal, which `over_refusal`
    reads and a raising verb raises. (At the parent an abort does not fail
    this test: it kills the runner.)"""
    var e = (col("v") * 2).sum().over("g")
    var why = over_refusal(e)
    assert_true(why.startswith(OVER_REFUSED_PREFIX), "a carried refusal")
    assert_true("COMPUTED" in why, "it names the shape: " + why)
    assert_equal(over_refusal(e.alias("s")), why, "seen through an alias")


def test_a_non_window_receiver_over_is_refused_by_name() raises:
    var e = col("v").copy_expr().over("g")
    assert_true("window function" in over_refusal(e), over_refusal(e))


def test_a_served_over_carries_no_refusal() raises:
    assert_equal(over_refusal(col("v").sum().over("g")), String(""), "sum")
    assert_equal(over_refusal(col("v").rank().over("g")), String(""), "rank")


def test_a_window_fn_over_is_unchanged_the_control() raises:
    """THE CONTROL: a real window function keeps ITS frame (`cum_sum`'s is
    the running one), so the aggregate arm did not capture every `.over`."""
    var e = col("v").cum_sum().over("g")
    ref w = e.window_fn_data_ref()
    assert_equal(Int(w.func), Int(PF_SUM))
    assert_true(not w.frame.is_full_partition(), "cum_sum is a RUNNING frame")


# ---- name() prefix / suffix --------------------------------------------------


def test_name_suffix_and_prefix_alias_the_current_name() raises:
    _same(col("v").name().suffix("_x"), Expr.alias(_v(), "v_x"), "v AS v_x")
    _same(col("v").name().prefix("p_"), Expr.alias(_v(), "p_v"), "v AS p_v")
    var e = col("v").name().suffix("_x")
    assert_equal(e.alias_name(), String("v_x"), "the alias NAME")


def test_name_of_an_alias_replaces_it_rather_than_stacking() raises:
    """Polars: `col("v").alias("w").name.suffix("_x")` is `w_x` (measured).
    (`ColExpr.alias` returns an `Expr`, so the door spells the re-wrap.)"""
    var aliased = ColExpr(col("v").alias("w"))
    var e = aliased.name().suffix("_x")
    assert_equal(e.alias_name(), String("w_x"))
    assert_true(e.alias_child_ref().is_col_ref(), "ONE alias over v, not two")


def test_name_of_a_computed_expression_refuses_by_name() raises:
    var raised = False
    try:
        _ = (col("v") * 2).name().suffix("_x")
    except e:
        raised = True
        assert_true(String(e).find("name().suffix()") >= 0, String(e))
    assert_true(raised, "a computed receiver has no current name here")


# ---- sum_horizontal ------------------------------------------------------------


def _coalesce0(e: Expr) -> Expr:
    """`coalesce(e, 0)` as `scalar_desugar.coalesce_of` builds it."""
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(Expr.unary(UN_IS_NOT_NULL, e.copy()), e.copy())
    )
    return Expr.when(cases^, Expr.literal(ScalarValue.from_int(0)))


def test_sum_horizontal_is_a_sum_of_null_ignoring_terms() raises:
    var want = Expr.binary(BIN_ADD, _coalesce0(Expr.col_ref("k")), _coalesce0(_v()))
    _same(sum_horizontal(col("k"), col("v")).copy_expr(), want, "k + v, nulls as 0")


def test_sum_horizontal_of_nothing_raises() raises:
    var raised = False
    try:
        _ = sum_horizontal()
    except e:
        raised = True
        assert_true(String(e).find("sum_horizontal") >= 0, String(e))
    assert_true(raised)


# ---- null_count ----------------------------------------------------------------


def test_null_count_is_count_if_is_null() raises:
    var a = null_count(col("v"))
    assert_equal(Int(a.func), Int(AGG_COUNT_IF), "COUNT_IF")
    _same(a.child.value().copy(), Expr.unary(UN_IS_NULL, _v()), "over v IS NULL")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
