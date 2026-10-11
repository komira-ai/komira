# =============================================================================
# test_optimizer_driver_gates -- each arm of a node-kind gate in
# `optimizer_driver.optimize`, pinned by a plan that only that arm admits
# =============================================================================
#
# A gate such as `if has_filter or has_project or has_aggregate:` runs its
# passes when ANY arm holds. A plan that holds a Filter passes the gate through
# its first arm whatever the others say, so a test built on a Filter cannot see
# a deleted second or third arm. Each test here builds a plan with exactly the
# node kinds one arm reads (no Filter, no PartitionBy, ...), so deleting that
# arm skips the pass and changes the whole render. The defect each test
# catches is the driver's gate, not the rule's behaviour.
#
# Arms pinned elsewhere: the Filter arms of steps 6 and 8
# (`test_optimizer_driver.mojo`), the Project arm of step 8
# (`test_cse_hoists_a_repeated_projection_subtree` in
# `test_optimizer_driver_passes.mojo`) and the PartitionBy arm of step 18
# (`test_window_rewrite_fuses_partition_bys_and_elides_a_sort` in
# `test_optimizer_driver_passes_late.mojo`).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_MUL, BIN_EQ, BIN_GT, BIN_AND
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET
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


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


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


def _project_a_and(var x: Expr, child_names: List[String]) -> LogicalPlan:
    """`Project[a, x AS x]` directly over a scan: no Filter anywhere."""
    var pe = ExprArray()
    pe.append(_c("a"))
    pe.append(Expr.alias(x^, "x"))
    return LogicalPlan.project(pe^, _scan("s.parquet", child_names))


# -----------------------------------------------------------------------------
# Step 6: expression simplification on a plan with no Filter
# -----------------------------------------------------------------------------


def test_constants_fold_in_a_project_with_no_filter() raises:
    """`Project[a, 1 + 2 AS x]` over a scan: step 6 folds `1 + 2` to `3`.

    Defect caught: the `fold_constants` gate narrowed to plans with a Filter
    (mutant `if has_filter and _plan_has_foldable_exprs(plan):`). The Project
    then keeps `BinaryOp(ADD, 1, 2)`."""
    var n: List[String] = ["a", "b"]
    var x = Expr.binary(BIN_ADD, _lit(1), _lit(2))
    assert_equal(_render(_run(_project_a_and(x^, n))), _want_fold())


def test_a_literal_conjunct_is_simplified_in_a_project_with_no_filter() raises:
    """`Project[a, (a = 1) AND true AS x]` over a scan: step 6 simplifies the
    conjunction to `a = 1`.

    Defect caught: the `simplify_predicates` gate narrowed to plans with a
    Filter (mutant `if has_filter and _plan_has_simplifiable_exprs(plan):`).
    The Project then keeps `BinaryOp(AND, ..., Literal(true))`."""
    var n: List[String] = ["a", "b"]
    var x = Expr.binary(
        BIN_AND, Expr.binary(BIN_EQ, _c("a"), _lit(1)), Expr.literal(ScalarValue.from_bool(True))
    )
    assert_equal(_render(_run(_project_a_and(x^, n))), _want_simp())


def test_constants_fold_in_a_filter_under_an_aggregate() raises:
    """`Aggregate(SUM(a))` over `Filter(a > 1 + 2)` over a scan: step 6 folds
    `1 + 2`, and the folded `a > 3` is pushed into the scan.

    Defect caught: the `fold_constants` gate narrowed to plans with no
    Aggregate (the verifier's o11, `if _plan_has_foldable_exprs(plan) and not
    has_aggregate:`). The Filter then keeps `a > 1 + 2` above the scan."""
    var n: List[String] = ["a", "b"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_c("a")), Optional(String("s"))))
    var f = LogicalPlan.filter(Expr.binary(BIN_GT, _c("a"), Expr.binary(BIN_ADD, _lit(1), _lit(2))), _scan("s.parquet", n))
    assert_equal(_render(_run(LogicalPlan.aggregate(ExprArray(), aggs^, f^))), _want_fold_under_agg())


# -----------------------------------------------------------------------------
# Step 8: CSE on a plan whose only expression-holding node is an Aggregate
# -----------------------------------------------------------------------------


def test_cse_runs_on_an_aggregate_with_no_filter_or_project() raises:
    """`Aggregate(SUM(a + b) AS s1, SUM((a + b) * c) AS s2)` directly over a
    scan: step 8's aggregate-argument axis names the shared `a + b` a `_cse_*`
    column under the Aggregate.

    Defect caught: the Aggregate arm deleted from the CSE gate (mutant
    `if has_filter or has_project:`). CSE is skipped and step 15 materializes
    the two arguments separately, with no `_cse_*` column."""
    var n: List[String] = ["a", "b", "c"]
    var ab = Expr.binary(BIN_ADD, _c("a"), _c("b"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(ab.copy()), Optional(String("s1"))))
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.binary(BIN_MUL, ab.copy(), _c("c"))), Optional(String("s2"))))
    var p = LogicalPlan.aggregate(ExprArray(), aggs^, _scan("s.parquet", n))
    assert_equal(_render(_run(p^)), _want_agg_cse())


# -----------------------------------------------------------------------------
# Step 18: a window function held in a Project, no PartitionBy yet
# -----------------------------------------------------------------------------


def test_a_window_function_in_a_project_becomes_a_partition_by() raises:
    """`Project[g, v, rank() OVER (PARTITION BY g) AS r]` over a scan, with no
    PartitionBy in the plan: step 18 lowers the window function into a
    PartitionBy under the Project, which then reads `r` as a column.

    Defect caught: the Project arm deleted from the window gate (mutant
    `if _plan_has_tag(plan, PLAN_PARTITION_BY):`). The window function then
    stays inside the Project and no PartitionBy is created."""
    var n: List[String] = ["g", "v"]
    var pe = ExprArray()
    pe.append(_c("g"))
    pe.append(_c("v"))
    pe.append(col("v").rank().over("g").alias("r"))
    assert_equal(_render(_run(LogicalPlan.project(pe^, _scan("w.parquet", n)))), _want_win())


# -----------------------------------------------------------------------------
# Expected renders (from the driver's output on these plans)
# -----------------------------------------------------------------------------


def _want_fold() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(a), Alias(Literal(ScalarValue(int64, 3)), \"x\")])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def _want_fold_under_agg() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[], aggs=[SUM(ColRef(a)).alias(\"s\")])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a], filter=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 3))))",
    ]
    return _lines(l)


def _want_simp() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(a), Alias(BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 1))), \"x\")])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def _want_agg_cse() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[], aggs=[SUM(ColRef(_cse_ce64410d_0)).alias(\"s1\"), SUM(ColRef(__agg_in_0)).alias(\"s2\")])",
        "  Project(exprs=[Alias(BinaryOp(ADD, ColRef(a), ColRef(b)), \"_cse_ce64410d_0\"), Alias(BinaryOp(MUL, Alias(BinaryOp(ADD, ColRef(a), ColRef(b)), \"_cse_ce64410d_0\"), Alias(ColRef(c), \"c\")), \"__agg_in_0\")])",
        "    Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_win() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(g), ColRef(v), ColRef(r)])",
        "  PartitionBy(partition=[g], order=[], funcs=[RANK(, offset=0, frame=ROWS[0:0..2:0]) AS r])",
        "    Scan(path=\"w.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
