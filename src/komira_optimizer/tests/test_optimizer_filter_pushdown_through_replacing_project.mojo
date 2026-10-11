# =============================================================================
# `push_predicates_down` may push a FILTER below a PROJECT only when the
# predicate means the same thing on both sides. A check BY NAME alone
# (`_predicate_refs_in_schema(pred, <the Project's CHILD schema>)`) is not
# enough: a Project that REPLACES a name its child also has passes it, and the
# pushed predicate then reads the ORIGINAL column. In
#   SELECT k, v FROM (SELECT k, g, v*2 AS v FROM t) q WHERE v > 8
# the filter must test v*2, not t.v; a window that replaces a column
# (`max(x) OVER (PARTITION BY g) AS x`) must not be pushed at all. Each test
# below pins one shape: kept ABOVE the Project, or pushed with the Project's
# expression substituted (`predicate_below_project`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_MUL, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, PLAN_FILTER, PLAN_PROJECT, PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_plan_expr.col_expr import col
from komira_optimizer.optimizer_filter import push_predicates_down


def _scan() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    sb.add_field(Field(String("w"), ArrowType.INT64, True))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _gt(name: String, n: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int64(Int64(n)))
    )


def _filter_over(var pe: ExprArray, var pred: Expr) -> LogicalPlan:
    return LogicalPlan.filter(pred^, LogicalPlan.project(pe^, _scan()))


def _replacing() -> ExprArray:
    """[k, v * 2 AS v] -- v is REPLACED."""
    var pe = ExprArray()
    pe.append(Expr.col_ref("k"))
    pe.append(
        Expr.alias(
            Expr.binary(
                BIN_MUL, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int64(2))
            ),
            "v",
        )
    )
    return pe^


def _pushed_render(p: LogicalPlan) -> String:
    """The predicate that ended up BELOW the root Project (a Filter under it
    or the Scan's pushed filter), rendered; "" when nothing was pushed."""
    var s = String("")
    if p.tag != PLAN_PROJECT:
        return s
    ref c = p._project.value()[].child[]
    if c.tag == PLAN_FILTER:
        c._filter.value()[].predicate.write_to(s)
    elif c.tag == PLAN_SCAN and c._scan.value()[].filter:
        c._scan.value()[].filter.value().write_to(s)
    return s


def _kept_above_or_pushed_with(p: LogicalPlan, needle: String) raises:
    """Either correct outcome: the Filter stays ABOVE the Project, or it is
    pushed with the Project's expression SUBSTITUTED (DuckDB's rule)."""
    if p.tag == PLAN_FILTER:
        return
    var r = _pushed_render(p)
    assert_true(r.find(needle) >= 0, "pushed WITHOUT substitution: " + r)


def test_a_predicate_on_a_REPLACED_column_is_never_pushed_raw() raises:
    # v > 8 reads the Project's v * 2; pushed raw it reads the scan's v.
    var out = push_predicates_down(_filter_over(_replacing(), _gt("v", 8)))
    _kept_above_or_pushed_with(out, "MUL")


def test_a_predicate_on_SWAPPED_names_is_never_pushed_raw() raises:
    # [w AS v, v AS w]: both names exist below, neither means the same there.
    var pe = ExprArray()
    pe.append(Expr.alias(Expr.col_ref("w"), "v"))
    pe.append(Expr.alias(Expr.col_ref("v"), "w"))
    var out = push_predicates_down(_filter_over(pe^, _gt("v", 8)))
    _kept_above_or_pushed_with(out, "ColRef(w)")


def test_a_predicate_on_a_WINDOW_replaced_column_stays_above() raises:
    var pe = ExprArray()
    pe.append(Expr.col_ref("k"))
    pe.append(col("v").sum().over("w").alias("v"))
    var out = push_predicates_down(_filter_over(pe^, _gt("v", 8)))
    assert_equal(Int(out.tag), Int(PLAN_FILTER), "a window is not row-local")


def test_a_predicate_under_a_node_the_substitution_returns_AS_BUILT_stays_above() raises:
    # [k, w AS v]: v is row-local (a rename), but `regexp_like` is returned AS
    # BUILT by `substitute_project_refs`, so a substituted push would leave it
    # reading the scan's OWN v. `expr_substitutes_safely` must keep it above
    # (no other test in this file needs that check to answer False).
    var pe = ExprArray()
    pe.append(Expr.col_ref("k"))
    pe.append(Expr.alias(Expr.col_ref("w"), "v"))
    var out = push_predicates_down(
        _filter_over(pe^, Expr.regexp_like(Expr.col_ref("v"), "^Z"))
    )
    _kept_above_or_pushed_with(out, "ColRef(w)")


def test_a_predicate_on_a_column_a_RAISING_function_computes_stays_above() raises:
    # [k, sqrt(v) AS v]: pushed with sqrt substituted, the predicate would be
    # pushed on past any guard FILTER under the Project and raise on the rows
    # it excluded (`sqrt` of a negative x in
    # `... sqrt(x) AS x ... WHERE x >= 0) q WHERE x > 1`).
    var pe = ExprArray()
    pe.append(Expr.col_ref("k"))
    pe.append(Expr.alias(Expr.sqrt(Expr.col_ref("v")), "v"))
    var out = push_predicates_down(_filter_over(pe^, _gt("v", 1)))
    assert_equal(Int(out.tag), Int(PLAN_FILTER), "sqrt can raise: keep it above")


def test_a_predicate_on_a_PASS_THROUGH_column_is_pushed_the_control() raises:
    var out = push_predicates_down(_filter_over(_replacing(), _gt("k", 1)))
    assert_equal(Int(out.tag), Int(PLAN_PROJECT), "k passes through: push it")


def test_an_aliased_pass_through_is_pushed_the_skins_spelling() raises:
    # A front end may author Alias(ColRef(k), "k") for every kept column (the
    # python skins, which are not in this tree, do).
    var pe = ExprArray()
    pe.append(Expr.alias(Expr.col_ref("k"), "k"))
    pe.append(Expr.col_ref("v"))
    var out = push_predicates_down(_filter_over(pe^, _gt("k", 1)))
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
