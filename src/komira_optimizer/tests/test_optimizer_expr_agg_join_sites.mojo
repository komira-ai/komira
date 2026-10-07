# =============================================================================
# The three expression rules of `optimizer_expr` (constant folding, predicate
# simplification, the IN-clause rewrite) at the two sites
# `test_optimizer_expr_rules.mojo` does not reach: the argument slots of an
# Aggregate's aggregate functions and a Join's residual condition.
#
# Each case builds the plan in memory, runs one rule and renders the rewritten
# expression, so a failure prints the expression the rule left behind.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_IN_LIST,
    BIN_ADD,
    BIN_EQ,
    BIN_GT,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX, AGG_CORR
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_optimizer.optimizer_expr import (
    fold_constants,
    simplify_predicates,
    rewrite_in_clauses,
)


def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _b(v: Bool) -> Expr:
    return Expr.literal(ScalarValue.from_bool(v))


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _a_eq_1_or_a_eq_2() -> Expr:
    return _bin(BIN_OR, _bin(BIN_EQ, _c("a"), _i(1)), _bin(BIN_EQ, _c("a"), _i(2)))


# Renders literals as values, binary ops infix and parenthesized, IN lists as
# `x in [v,...]`; anything else as its tag.
def _d(e: Expr) raises -> String:
    if e.tag == EXPR_LITERAL:
        var v = e.literal_value()
        if v.is_bool():
            if v.bool_val:
                return String("true")
            return String("false")
        if v.is_int():
            return String(Int(v.int_val))
        return String("lit?")
    if e.tag == EXPR_COL_REF:
        return e.col_ref_name()
    if e.tag == EXPR_BINARY_OP:
        var op = e.binary_op()
        var o = String("op")
        if op == BIN_ADD:
            o = "+"
        elif op == BIN_EQ:
            o = "="
        elif op == BIN_GT:
            o = ">"
        elif op == BIN_AND:
            o = "and"
        elif op == BIN_OR:
            o = "or"
        return "(" + _d(e.binary_left_ref()) + " " + o + " " + _d(e.binary_right_ref()) + ")"
    if e.tag == EXPR_IN_LIST:
        var s = _d(e.in_list_child_ref()) + " in ["
        ref vals = e.in_list_values_ref()
        for k in range(len(vals)):
            if k > 0:
                s += ","
            s += String(Int(vals[k].int_val))
        return s + "]"
    return "tag" + String(Int(e.tag))


def _left_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))
    return sb.build()


def _right_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, var schema: Schema) -> LogicalPlan:
    var none: Optional[Expr] = None
    return LogicalPlan.scan(path, SOURCE_PARQUET, schema^, None, none^)


# Aggregate(group_by=[b], [sum(arg0) as s, corr(a, arg1) as k]) over a scan:
# `arg1` sits in slot 1 of a bivariate aggregate.
def _agg_over(var arg0: Expr, var arg1: Expr) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(_c("b"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(arg0^), Optional(String("s"))))
    aggs.append(AggExpr(AGG_CORR, Optional(_c("a")), Optional(arg1^), Optional(String("k"))))
    return LogicalPlan.aggregate(gb^, aggs^, _scan("l.parquet", _left_schema()))


def _agg_args(plan: LogicalPlan) raises -> String:
    assert_true(plan.tag == PLAN_AGGREGATE, "the aggregate stays on top")
    ref aggs = plan._aggregate.value()[].agg_exprs
    return _d(aggs[0].child.value()) + " | " + _d(aggs[1].child1.value())


# Join(left, right, a = x) with `residual`.
def _join_with(var residual: Expr) -> LogicalPlan:
    var lon: List[String] = ["a"]
    var ron: List[String] = ["x"]
    var r: Optional[OwnedPointer[Expr]] = OwnedPointer(residual^)
    return LogicalPlan.join(
        _scan("l.parquet", _left_schema()), _scan("r.parquet", _right_schema()),
        lon^, ron^, JOIN_INNER, residual=r^,
    )


def _residual(plan: LogicalPlan) raises -> String:
    assert_true(plan.tag == PLAN_JOIN, "the join stays on top")
    ref j = plan._join.value()[]
    assert_true(Bool(j.residual), "the residual is kept")
    return _d(j.residual.value()[])


def test_in_rewrites_aggregate_arguments() raises:
    """Catches: the IN rewrite skipping an Aggregate's aggregate-function
    arguments, in slot 0 and in a bivariate aggregate's slot 1."""
    var out = rewrite_in_clauses(_agg_over(_a_eq_1_or_a_eq_2(), _a_eq_1_or_a_eq_2()))
    assert_equal(_agg_args(out), "a in [1,2] | a in [1,2]")


def test_in_rewrites_join_residual() raises:
    """Catches: the IN rewrite skipping a Join's residual condition."""
    var out = rewrite_in_clauses(_join_with(_a_eq_1_or_a_eq_2()))
    assert_equal(_residual(out), "a in [1,2]")


def test_fold_rewrites_aggregate_arguments() raises:
    """Catches: constant folding skipping an Aggregate's aggregate-function
    arguments."""
    var out = fold_constants(_agg_over(_bin(BIN_ADD, _i(1), _i(1)),
                                       _bin(BIN_ADD, _c("a"), _bin(BIN_ADD, _i(2), _i(3)))))
    assert_equal(_agg_args(out), "2 | (a + 5)")


def test_fold_rewrites_join_residual() raises:
    """Catches: constant folding skipping a Join's residual condition."""
    var out = fold_constants(_join_with(_bin(BIN_GT, _c("a"), _bin(BIN_ADD, _i(2), _i(3)))))
    assert_equal(_residual(out), "(a > 5)")


def test_simplify_rewrites_aggregate_arguments() raises:
    """Catches: predicate simplification skipping an Aggregate's
    aggregate-function arguments."""
    var out = simplify_predicates(_agg_over(_bin(BIN_AND, _c("b"), _b(True)),
                                            _bin(BIN_OR, _b(False), _c("b"))))
    assert_equal(_agg_args(out), "b | b")


def test_simplify_rewrites_join_residual() raises:
    """Catches: predicate simplification skipping a Join's residual condition."""
    var out = simplify_predicates(_join_with(_bin(BIN_AND, _b(True), _bin(BIN_GT, _c("a"), _c("x")))))
    assert_equal(_residual(out), "(a > x)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
