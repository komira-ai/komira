# =============================================================================
# test_optimizer_driver_expr_sites -- steps 6 and 8 of
# `optimizer_driver.optimize` on plans whose only work for an expression rule
# is an aggregate argument or a join residual
# =============================================================================
#
# `fold_constants`, `simplify_predicates` (step 6) and `rewrite_in_clauses`
# (step 8) each run behind a check. All three passes rewrite the argument
# slots of an Aggregate's aggregate functions and a Join's residual
# condition, so their checks must read those sites too: a check that skips a
# site answers False on a plan whose one piece of work sits there, and the
# pass is skipped. Each test is one such plan run through `optimize`,
# compared as a whole render.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_EQ, BIN_GT, BIN_AND, BIN_OR, UN_NOT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, JOIN_INNER, JOIN_LEFT, JOIN_ALGO_AUTO,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, names: List[String]) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names), None, None, None)


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _true() -> Expr:
    return Expr.literal(ScalarValue.from_bool(True))


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _one_plus_two() -> Expr:
    return Expr.binary(BIN_ADD, _lit(1), _lit(2))


def _lines(l: List[String]) -> String:
    """A render: one line per node, each ending in a newline."""
    var s = String("")
    for i in range(len(l)):
        s += l[i] + "\n"
    return s^


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


def _run(var p: LogicalPlan) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(p^, OptimizerConfig(), deps)


def _sum_over_scan(var arg: Expr) -> LogicalPlan:
    """`Aggregate(SUM(arg) AS s)` directly over a scan of `s(a, b)`."""
    var n: List[String] = ["a", "b"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(arg^), Optional(String("s"))))
    return LogicalPlan.aggregate(ExprArray(), aggs^, _scan("s.parquet", n))


def _join_tu(var residual: Expr, join_type: UInt8 = JOIN_INNER) -> LogicalPlan:
    """`t(a, ta) JOIN u(b, ub) ON a = b` with `residual`."""
    var jt: List[String] = ["a", "ta"]
    var ju: List[String] = ["b", "ub"]
    var lon: List[String] = ["a"]
    var ron: List[String] = ["b"]
    return LogicalPlan.join(
        _scan("t.parquet", jt), _scan("u.parquet", ju), lon^, ron^,
        join_type, JOIN_ALGO_AUTO, Optional[OwnedPointer[Expr]](OwnedPointer(residual^)),
    )


# -----------------------------------------------------------------------------
# komira#1306: the reproducers, one per (pass, site)
# -----------------------------------------------------------------------------


def test_a_constant_in_an_aggregate_argument_is_folded() raises:
    """`Aggregate(SUM(a + (1 + 2)) AS s)` over a scan: step 6 folds the
    argument to `a + 3`, which step 15 then materializes under the Aggregate.

    Defect caught: the folding precheck skipping aggregate arguments
    (komira#1306; mutant: the Aggregate slots visited only when rewriting).
    The argument then keeps `1 + 2`."""
    var arg = Expr.binary(BIN_ADD, _c("a"), _one_plus_two())
    assert_equal(_render(_run(_sum_over_scan(arg^))), _want_agg_folded())


def test_a_constant_in_the_second_aggregate_function_is_folded() raises:
    """`Aggregate(SUM(a) AS s0, SUM(b + (1 + 2)) AS s1)` over a scan: the
    first function holds no work, and step 6 folds the second's argument to
    `b + 3`.

    Defect caught: the folding precheck reading only the first aggregate
    function (mutant: the check walk's function loop bounded to
    `min(len(aggs), 1)`). The second argument then keeps `1 + 2`."""
    var n: List[String] = ["a", "b"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_c("a")), Optional(String("s0"))))
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.binary(BIN_ADD, _c("b"), _one_plus_two())), Optional(String("s1"))))
    var p = LogicalPlan.aggregate(ExprArray(), aggs^, _scan("s.parquet", n))
    assert_equal(_render(_run(p^)), _want_second_agg_folded())


def test_a_constant_in_a_join_residual_is_folded() raises:
    """`t(a, ta) JOIN u(b, ub) ON a = b` with the residual `ta > ub + (1 + 2)`:
    step 6 folds the residual to `ta > ub + 3`.

    Defect caught: the folding precheck skipping join residuals (komira#1306;
    mutant: the residual visited only when rewriting)."""
    var res = Expr.binary(BIN_GT, _c("ta"), Expr.binary(BIN_ADD, _c("ub"), _one_plus_two()))
    assert_equal(_render(_run(_join_tu(res^))), _want_join(_ta_gt_ub_plus_3()))


def test_a_literal_conjunct_in_a_join_residual_is_simplified() raises:
    """The same join with the residual `(ta > ub) AND true`: step 6 simplifies
    it to `ta > ub`.

    Defect caught: the simplification precheck skipping join residuals
    (komira#1306; same mutant as above, on the simplification walk)."""
    var res = Expr.binary(BIN_AND, Expr.binary(BIN_GT, _c("ta"), _c("ub")), _true())
    assert_equal(_render(_run(_join_tu(res^))), _want_join(_ta_gt_ub()))


def test_a_double_negation_in_an_aggregate_argument_is_removed() raises:
    """`Aggregate(SUM(NOT NOT (a > b)) AS s)` over a scan: step 6 removes the
    double negation.

    Defect caught: the simplification precheck skipping aggregate arguments
    (komira#1306's fourth (pass, site) pair)."""
    var arg = Expr.unary(UN_NOT, Expr.unary(UN_NOT, Expr.binary(BIN_GT, _c("a"), _c("b"))))
    assert_equal(_render(_run(_sum_over_scan(arg^))), _want_agg_simplified())


def test_a_constant_conjunct_in_a_join_residual_is_folded_away() raises:
    """The join with the residual `(ta > ub) AND (1 = 1)`: step 5 leaves the
    column-free conjunct in the residual, and step 6 folds `1 = 1` to `true`
    and drops it.

    Defect caught: the folding precheck skipping join residuals, on a
    residual step 5 has already read."""
    var res = Expr.binary(
        BIN_AND, Expr.binary(BIN_GT, _c("ta"), _c("ub")), Expr.binary(BIN_EQ, _lit(1), _lit(1))
    )
    assert_equal(_render(_run(_join_tu(res^))), _want_join(_ta_gt_ub()))


# -----------------------------------------------------------------------------
# The same family at step 8: the IN rewrite's gate
# -----------------------------------------------------------------------------


def test_an_or_chain_in_a_left_join_residual_becomes_an_in_list() raises:
    """`t LEFT JOIN u ON a = b` with the residual `ta = 1 OR ta = 2`: step 5
    cannot move a preserved-side conjunct of a LEFT join, so the plan holds
    no Filter, Project or Aggregate, and step 8 still rewrites the residual
    to `ta IN (1, 2)`.

    Defect caught: the IN rewrite gated on Filter, Project or Aggregate
    nodes, which never reads join residuals (mutant: the gate
    `if has_filter or has_project or has_aggregate:` in place of
    `_plan_has_in_sites`). The OR chain then stays."""
    var res = Expr.binary(
        BIN_OR, Expr.binary(BIN_EQ, _c("ta"), _lit(1)), Expr.binary(BIN_EQ, _c("ta"), _lit(2))
    )
    var l: List[String] = [
        "Join(type=LEFT, on=[a=b], residual=InList(ColRef(ta), [ScalarValue(int64, 1), ScalarValue(int64, 2)]), build=right)",
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "  Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    assert_equal(_render(_run(_join_tu(res^, JOIN_LEFT))), _lines(l))


def test_an_or_chain_inside_an_inner_join_residual_becomes_an_in_list() raises:
    """`t JOIN u ON a = b` with the residual `(ta = 1 OR ta = 2) OR ta > ub`:
    the residual names both sides, so step 5 leaves it, and step 8 rewrites
    the inner chain to `ta IN (1, 2)`.

    Defect caught: the same IN gate mutant, on an INNER join."""
    var ors = Expr.binary(
        BIN_OR, Expr.binary(BIN_EQ, _c("ta"), _lit(1)), Expr.binary(BIN_EQ, _c("ta"), _lit(2))
    )
    var res = Expr.binary(BIN_OR, ors^, Expr.binary(BIN_GT, _c("ta"), _c("ub")))
    assert_equal(
        _render(_run(_join_tu(res^))),
        _want_join(
            "BinaryOp(OR, InList(ColRef(ta), [ScalarValue(int64, 1), ScalarValue(int64, 2)]), "
            + "BinaryOp(GT, ColRef(ta), ColRef(ub)))"
        ),
    )


# -----------------------------------------------------------------------------
# Expected renders (from the driver's output on these plans)
# -----------------------------------------------------------------------------


def _ta_gt_ub() -> String:
    return "BinaryOp(GT, ColRef(ta), ColRef(ub))"


def _ta_gt_ub_plus_3() -> String:
    return "BinaryOp(GT, ColRef(ta), BinaryOp(ADD, ColRef(ub), Literal(ScalarValue(int64, 3))))"


def _want_join(residual: String) -> String:
    var l: List[String] = [
        "Join(type=INNER, on=[a=b], residual=" + residual + ", build=right)",
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "  Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_agg_folded() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[], aggs=[SUM(ColRef(__agg_in_0)).alias(\"s\")])",
        "  Project(exprs=[Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 3))), \"__agg_in_0\")])",
        "    Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def _want_agg_simplified() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[], aggs=[SUM(ColRef(__agg_in_0)).alias(\"s\")])",
        "  Project(exprs=[Alias(BinaryOp(GT, ColRef(a), ColRef(b)), \"__agg_in_0\")])",
        "    Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_second_agg_folded() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[], aggs=[SUM(ColRef(a)).alias(\"s0\"), SUM(ColRef(__agg_in_0)).alias(\"s1\")])",
        "  Project(exprs=[ColRef(a), Alias(BinaryOp(ADD, ColRef(b), Literal(ScalarValue(int64, 3))), \"__agg_in_0\")])",
        "    Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
