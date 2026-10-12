# =============================================================================
# test_optimizer_driver_order_steps -- step boundaries of
# `optimizer_driver.optimize`: whole steps swapped, and one named move
# =============================================================================
#
# `test_optimizer_driver_order.mojo` pins swaps of two adjacent pass calls.
# This file pins the step boundaries that file does not reach: the last call
# of a step swapped with the first call of the next, a whole step swapped with
# the whole next step, and step 6 moved after step 8. Each test is one plan
# whose whole render changes under the named reorders.
#
# Boundaries whose two orders gave the same plan on every plan tried are
# argued in the pull request that added this file, not tested here.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_MUL, BIN_EQ, BIN_GT, BIN_AND, BIN_OR, UN_NOT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, JOIN_INNER, JOIN_ALGO_AUTO,
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


def _scan(path: String, names: List[String], rows: Optional[Int] = None) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names), None, None, rows)


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _eq(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_EQ, _c(c), _lit(v))


def _gt(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, _c(c), _lit(v))


def _and(var a: Expr, var b: Expr) -> Expr:
    return Expr.binary(BIN_AND, a^, b^)


def _l1(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


def _cols(var names: List[String]) -> ExprArray:
    var pe = ExprArray()
    for i in range(len(names)):
        pe.append(Expr.col_ref(names[i]))
    return pe^


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


# -----------------------------------------------------------------------------
# Steps 5-8
# -----------------------------------------------------------------------------


def test_a_residual_moved_to_a_filter_is_then_folded() raises:
    """`t(a, ta) JOIN u(b, ub) ON a = b` with the residual `ta > 1 + 2`: step 5
    moves the residual into a Filter on t, step 6's folding precheck then sees
    that Filter, and the t scan ends with the filter `ta > 3`.

    Defect caught: step 6 before step 5, as a whole or as its first call
    (`fold_constants` before `push_join_residual_to_side`). The precheck does
    not read join residuals (komira#1306), so folding is skipped and a
    `Filter(ta > 1 + 2)` stays over the t scan."""
    var jt: List[String] = ["a", "ta"]
    var ju: List[String] = ["b", "ub"]
    var res = Expr.binary(BIN_GT, _c("ta"), Expr.binary(BIN_ADD, _lit(1), _lit(2)))
    var j = LogicalPlan.join(
        _scan("t.parquet", jt), _scan("u.parquet", ju), _l1("a"), _l1("b"),
        JOIN_INNER, JOIN_ALGO_AUTO, Optional[OwnedPointer[Expr]](OwnedPointer(res^)),
    )
    assert_equal(_render(_run(j^)), _want_residual_folded())


def test_a_double_negation_is_removed_before_the_first_or_factoring() raises:
    """`NOT NOT ((a + b > 1 AND c = 2) OR (a + b > 1 AND c = 3))`: step 6
    removes the double negation, step 7 then factors the shared `a + b > 1`
    out of the OR, and the IN rewrite and pushdown leave `c IN (2, 3)` on the
    scan under a Filter on `a + b > 1`.

    Defect caught: step 7 before step 6, as a whole or as the swap of
    `simplify_predicates` and the first `factor_or_conjuncts`; also step 8
    before step 7, and step 6 moved after step 8. Factoring then meets the
    OR only after CSE has hoisted the repeated `a + b > 1` into a
    synthesized column: the plan keeps a Filter over a CSE Project, and
    `c = 2 OR c = 3` is never an IN list on the scan."""
    var ab = Expr.binary(BIN_ADD, _c("a"), _c("b"))
    var sh = Expr.binary(BIN_GT, ab^, _lit(1))
    var o = Expr.binary(BIN_OR, _and(sh.copy(), _eq("c", 2)), _and(sh.copy(), _eq("c", 3)))
    var pred = Expr.unary(UN_NOT, Expr.unary(UN_NOT, o^))
    var n: List[String] = ["a", "b", "c"]
    assert_equal(_render(_run(LogicalPlan.filter(pred^, _scan("t.parquet", n)))), _want_notnot_factored())


def test_constants_fold_before_cse_compares_expressions() raises:
    """`Project[(a + (1 + 2)) * 2 AS x, (a + 3) * 3 AS y]` over s(a, b): step
    6 folds `1 + 2`, so CSE in step 8 sees `a + 3` twice and names it
    (`_cse_..._0` in both expressions).

    Defect caught: step 6 moved after `rewrite_in_clauses`, inside the step-8
    gate. CSE then compares `a + (1 + 2)` with `a + 3`, finds no repeat, and
    the folded expressions keep no `_cse_` alias."""
    var pe = ExprArray()
    pe.append(Expr.alias(Expr.binary(BIN_MUL, Expr.binary(BIN_ADD, _c("a"), Expr.binary(BIN_ADD, _lit(1), _lit(2))), _lit(2)), "x"))
    pe.append(Expr.alias(Expr.binary(BIN_MUL, Expr.binary(BIN_ADD, _c("a"), _lit(3)), _lit(3)), "y"))
    var n: List[String] = ["a", "b"]
    assert_equal(_render(_run(LogicalPlan.project(pe^, _scan("s.parquet", n)))), _want_fold_then_cse())


# -----------------------------------------------------------------------------
# Steps 13-17
# -----------------------------------------------------------------------------


def test_projects_merge_before_eager_aggregation() raises:
    """`SUM(measure) GROUP BY dim_attr` over `Project[dim_attr, measure]` over
    `Project[measure, dim_attr, fk_id]` over fact JOIN dim: step 13 merges the
    two Projects into one column Project, and step 14's eager aggregation then
    puts a partial `__eager_sum_total` aggregate on the fact side.

    Defect caught: step 14 before step 13. Eager aggregation meets an
    Aggregate over two stacked Projects and declines; the plan keeps one
    Aggregate over the join."""
    var fnm: List[String] = ["fk_id", "measure"]
    var dnm: List[String] = ["dim_id", "dim_attr"]
    var j = LogicalPlan.join(_scan("fact.parquet", fnm), _scan("dim.parquet", dnm), _l1("fk_id"), _l1("dim_id"), JOIN_INNER)
    var inner: List[String] = ["measure", "dim_attr", "fk_id"]
    var outer: List[String] = ["dim_attr", "measure"]
    var p = LogicalPlan.project(_cols(outer^), LogicalPlan.project(_cols(inner^), j^))
    var gb = ExprArray()
    gb.append(_c("dim_attr"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_c("measure")), Optional(String("total"))))
    assert_equal(_render(_run(LogicalPlan.aggregate(gb^, aggs^, p^))), _want_merged_then_eager())


def test_a_limit_is_pushed_below_the_join_order_restoring_project() raises:
    """`Limit 5` over (a(100000 rows) JOIN b(10) ON ak = bk) JOIN d(1000) ON
    bk = dk: step 16 reorders the joins and puts a Project restoring the
    query's column order under the Limit; step 17 then pushes the Limit below
    that Project, onto the reordered join.

    Defect caught: step 17 before step 16. The Limit is still directly on the
    join when step 17 runs, so it is not moved, and the Project step 16 adds
    afterwards stays under it."""
    var an: List[String] = ["ak", "av"]
    var bn: List[String] = ["bk", "bv"]
    var dn: List[String] = ["dk", "dv"]
    var ab = LogicalPlan.join(_scan("a", an, 100000), _scan("b", bn, 10), _l1("ak"), _l1("bk"), JOIN_INNER)
    var abd = LogicalPlan.join(ab^, _scan("d", dn, 1000), _l1("bk"), _l1("dk"), JOIN_INNER)
    assert_equal(_render(_run(LogicalPlan.limit(5, abd^))), _want_limit_under_restore())


# -----------------------------------------------------------------------------
# Expected renders (taken from the driver's output)
# -----------------------------------------------------------------------------


def _want_residual_folded() -> String:
    var l: List[String] = [
        "Join(type=INNER, on=[a=b], build=left)",
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(GT, ColRef(ta), Literal(ScalarValue(int64, 3))))",
        "  Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_notnot_factored() -> String:
    var l: List[String] = [
        "Filter(predicate=BinaryOp(GT, BinaryOp(ADD, ColRef(a), ColRef(b)), Literal(ScalarValue(int64, 1))))",
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=InList(ColRef(c), [ScalarValue(int64, 2), ScalarValue(int64, 3)]))",
    ]
    return _lines(l)


def _want_fold_then_cse() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(BinaryOp(MUL, Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 3))), \"_cse_8cdb2257_0\"), Literal(ScalarValue(int64, 2))), \"x\"), Alias(BinaryOp(MUL, Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 3))), \"_cse_8cdb2257_0\"), Literal(ScalarValue(int64, 3))), \"y\")])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def _want_merged_then_eager() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[ColRef(dim_attr)], aggs=[SUM(ColRef(__eager_sum_total)).alias(\"total\")])",
        "  Join(type=INNER, on=[fk_id=dim_id], build=left)",
        "    Aggregate(group_by=[ColRef(fk_id)], aggs=[SUM(ColRef(measure)).alias(\"__eager_sum_total\")])",
        "      Scan(path=\"fact.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "    Scan(path=\"dim.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_limit_under_restore() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(ak), ColRef(av), ColRef(bk), ColRef(bv), ColRef(dk), ColRef(dv)])",
        "  Limit(n=5)",
        "    Join(type=INNER, on=[bk=ak, dk=ak], build=left)",
        "      Join(type=INNER, on=[bk=dk], build=left)",
        "        Scan(path=\"b\", type=PARQUET, source_kind=COLUMNAR)",
        "        Scan(path=\"d\", type=PARQUET, source_kind=COLUMNAR)",
        "      Scan(path=\"a\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
