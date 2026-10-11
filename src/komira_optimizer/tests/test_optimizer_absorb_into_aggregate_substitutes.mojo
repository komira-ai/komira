# =============================================================================
# Rule 13 (`absorb_expression_into_aggregate`) folds Aggregate(Project(gc)) into
# Aggregate(gc) by SUBSTITUTING each aggregand / group key's column references
# with the Project's expressions, through the shared substitution walk in
# `optimizer_project_merge_guard`. The defect these tests catch: a walk that
# descends ColRef / Binary / Unary / Cast / Alias / CASE / IN list only and
# returns every other node AS BUILT. For
# `SELECT g, sum(sqrt(x)) FROM (SELECT g, x*4.0 AS x FROM t) GROUP BY g`
# such a walk leaves `sqrt` reading the ORIGINAL x, so the sum comes out at
# HALF its value (sqrt(4x) = 2 sqrt(x)). The rule has no join condition: it
# absorbs any Aggregate(Project), as `_plan` below (no join) shows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_MUL
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, PLAN_AGGREGATE, PLAN_SCAN,
    PLAN_PROJECT, SOURCE_PARQUET,
)
from komira_plan_expr.col_expr import col
from komira_optimizer.optimizer_join import absorb_expression_into_aggregate


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("g"), ArrowType.INT64, True))
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, True))
    return sb.build()


def _plan(var aggregand: Expr) -> LogicalPlan:
    """Aggregate(g; sum(<aggregand>) AS s) over Project([g, x * 4.0 AS x])."""
    var scan = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())
    var pe = ExprArray()
    pe.append(Expr.col_ref("g"))
    pe.append(
        Expr.alias(
            Expr.binary(
                BIN_MUL, Expr.col_ref("x"),
                Expr.literal(ScalarValue.from_float(4.0)),
            ),
            "x",
        )
    )
    var proj = LogicalPlan.project(pe^, scan^)
    var keys = ExprArray()
    keys.append(Expr.col_ref("g"))
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(UInt8(0), Optional[Expr](aggregand^), Optional[String](String("s")))
    )
    return LogicalPlan.aggregate(keys^, aggs^, proj^)


def _aggregand_render(p: LogicalPlan) -> String:
    var s = String("")
    p._aggregate.value()[].agg_exprs[0].child.value().write_to(s)
    return s


def test_a_math_fn_aggregand_over_a_REPLACED_column_reads_the_NEW_column() raises:
    var out = absorb_expression_into_aggregate(_plan(Expr.sqrt(Expr.col_ref("x"))))
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE))
    # ABSORBED (the guarded walk descends a MathFn), and the aggregand reads
    # x * 4.0, never the scan's own x. ⛔ The tag check is unconditional: a
    # rule that stopped absorbing fails it rather than skipping the aggregand
    # check.
    assert_equal(
        Int(out._aggregate.value()[].child[].tag), Int(PLAN_SCAN),
        "sqrt(x) over x * 4.0 AS x is absorbed",
    )
    var r = _aggregand_render(out)
    assert_true(r.find("BinaryOp(MUL, ColRef(x)") >= 0, r)


def test_a_plain_column_aggregand_is_absorbed_the_control() raises:
    var out = absorb_expression_into_aggregate(_plan(Expr.col_ref("x")))
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_SCAN))
    var r = _aggregand_render(out)
    assert_true(r.find("BinaryOp(MUL, ColRef(x)") >= 0, r)


# -----------------------------------------------------------------------------
# The GUARD: an aggregand that reads
# a REPLACED column under a node `substitute_project_refs` returns AS BUILT (a
# regexp) must leave Aggregate(Project) standing. With
# `expr_substitutes_safely` returning True, the two tests above still pass
# (their aggregands substitute safely) and only the test below fails:
# absorbing would make `regexp_like(s, '^Z')` over `upper(s) AS s` read the
# scan's ORIGINAL lower-case s.
# -----------------------------------------------------------------------------


def _s_plan(var aggregand: Expr) -> LogicalPlan:
    """Aggregate(g; sum(<aggregand>) AS z) over Project([g, <s replaced by a
    computed expression> AS s])."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("g"), ArrowType.INT64, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    var scan = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())
    var pe = ExprArray()
    pe.append(Expr.col_ref("g"))
    pe.append(Expr.alias(col("s").upper(), "s"))
    var proj = LogicalPlan.project(pe^, scan^)
    var keys = ExprArray()
    keys.append(Expr.col_ref("g"))
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(UInt8(0), Optional[Expr](aggregand^), Optional[String](String("z")))
    )
    return LogicalPlan.aggregate(keys^, aggs^, proj^)


def test_an_aggregand_under_a_node_returned_AS_BUILT_leaves_the_project_standing() raises:
    # `regexp_like(s, '^Z')` over a REPLACED s: the substitution returns the
    # regexp AS BUILT, so absorbing would re-point it at the scan's own s.
    var out = absorb_expression_into_aggregate(
        _s_plan(Expr.regexp_like(Expr.col_ref("s"), "^Z"))
    )
    assert_equal(
        Int(out._aggregate.value()[].child[].tag), Int(PLAN_PROJECT),
        "the guard must leave Aggregate(Project) standing",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
