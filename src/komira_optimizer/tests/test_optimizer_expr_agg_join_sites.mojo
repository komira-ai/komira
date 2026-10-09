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
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_MAX, AGG_CORR
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


# Aggregate(group_by=[b], [corr(a, a) as k]) with `slot2` / `slot3` placed in
# the aggregate's argument slots 2 and 3 (no constructor takes four inputs;
# the fields are set after construction, as `test_optimizer_expr_cse_branches`
# does).
def _agg_slots_2_3(var slot2: Optional[Expr], var slot3: Optional[Expr]) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(_c("b"))
    var a0 = AggExpr(AGG_CORR, Optional(_c("a")), Optional(_c("a")), Optional(String("k")))
    a0.child2 = slot2^
    a0.child3 = slot3^
    var aggs = AggExprArray()
    aggs.append(a0^)
    return LogicalPlan.aggregate(gb^, aggs^, _scan("l.parquet", _left_schema()))


def _slot(plan: LogicalPlan, k: Int) raises -> String:
    assert_true(plan.tag == PLAN_AGGREGATE, "the aggregate stays on top")
    ref agg = plan._aggregate.value()[].agg_exprs[0]
    if k == 2:
        if not agg.child2:
            return String("none")
        return _d(agg.child2.value())
    if not agg.child3:
        return String("none")
    return _d(agg.child3.value())


def test_rules_rewrite_aggregate_slot_2() raises:
    """Catches: any of the three rules skipping an aggregate function's
    argument slot 2 (`_rewrite_optional_site[rule](agg.child2)`); slot 3 is
    empty and stays empty."""
    var f = fold_constants(_agg_slots_2_3(Optional(_bin(BIN_ADD, _i(2), _i(3))), Optional[Expr]()))
    assert_equal(_slot(f, 2), "5")
    assert_equal(_slot(f, 3), "none")
    var s = simplify_predicates(_agg_slots_2_3(Optional(_bin(BIN_AND, _b(True), _c("b"))), Optional[Expr]()))
    assert_equal(_slot(s, 2), "b")
    assert_equal(_slot(s, 3), "none")
    var r = rewrite_in_clauses(_agg_slots_2_3(Optional(_a_eq_1_or_a_eq_2()), Optional[Expr]()))
    assert_equal(_slot(r, 2), "a in [1,2]")
    assert_equal(_slot(r, 3), "none")


def test_rules_rewrite_aggregate_slot_3() raises:
    """Catches: any of the three rules skipping an aggregate function's
    argument slot 3 (`_rewrite_optional_site[rule](agg.child3)`), including
    when slot 2 before it is empty."""
    var f = fold_constants(_agg_slots_2_3(Optional[Expr](), Optional(_bin(BIN_ADD, _i(2), _i(3)))))
    assert_equal(_slot(f, 2), "none")
    assert_equal(_slot(f, 3), "5")
    var s = simplify_predicates(_agg_slots_2_3(Optional[Expr](), Optional(_bin(BIN_OR, _b(False), _c("b")))))
    assert_equal(_slot(s, 2), "none")
    assert_equal(_slot(s, 3), "b")
    var r = rewrite_in_clauses(_agg_slots_2_3(Optional[Expr](), Optional(_a_eq_1_or_a_eq_2())))
    assert_equal(_slot(r, 2), "none")
    assert_equal(_slot(r, 3), "a in [1,2]")


# Aggregate(group_by=[a = 1 OR a = 2, a + (0 + 1), b AND TRUE],
#           [count(*) as n, max(a + (2 + 3)) as m]): each key is a target of
# one rule (IN rewrite, folding, simplification).
def _agg_count_star_and_or_key() -> LogicalPlan:
    var gb = ExprArray()
    gb.append(_a_eq_1_or_a_eq_2())
    gb.append(_bin(BIN_ADD, _c("a"), _bin(BIN_ADD, _i(0), _i(1))))
    gb.append(_bin(BIN_AND, _c("b"), _b(True)))
    var none: Optional[Expr] = None
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, none^, Optional(String("n"))))
    aggs.append(AggExpr(AGG_MAX, Optional(_bin(BIN_ADD, _c("a"), _bin(BIN_ADD, _i(2), _i(3)))),
                        Optional(String("m"))))
    return LogicalPlan.aggregate(gb^, aggs^, _scan("l.parquet", _left_schema()))


def _count_star_view(plan: LogicalPlan) raises -> String:
    assert_true(plan.tag == PLAN_AGGREGATE, "the aggregate stays on top")
    ref ad = plan._aggregate.value()[]
    assert_equal(len(ad.agg_exprs), 2)
    ref n = ad.agg_exprs[0]
    assert_true(not n.child and not n.child1 and not n.child2 and not n.child3,
                "count(*) keeps every argument slot empty")
    assert_equal(len(ad.group_by), 3)
    return (_d(ad.group_by[0]) + " ; " + _d(ad.group_by[1]) + " ; " + _d(ad.group_by[2])
            + " | " + _d(ad.agg_exprs[1].child.value()))


def test_rules_keep_group_by_keys_and_empty_slots() raises:
    """Catches: a rule rewriting an Aggregate's group-by key (the key's
    inferred output name would no longer match the schema), and a rule
    filling or tripping over an empty argument slot (count(*)) while it still
    rewrites the next aggregate's argument."""
    var f = fold_constants(_agg_count_star_and_or_key())
    assert_equal(_count_star_view(f), "((a = 1) or (a = 2)) ; (a + (0 + 1)) ; (b and true) | (a + 5)")
    var r = rewrite_in_clauses(_agg_count_star_and_or_key())
    assert_equal(_count_star_view(r), "((a = 1) or (a = 2)) ; (a + (0 + 1)) ; (b and true) | (a + (2 + 3))")
    var s = simplify_predicates(_agg_count_star_and_or_key())
    assert_equal(_count_star_view(s), "((a = 1) or (a = 2)) ; (a + (0 + 1)) ; (b and true) | (a + (2 + 3))")


def _join_without_residual() -> LogicalPlan:
    var lon: List[String] = ["a"]
    var ron: List[String] = ["x"]
    return LogicalPlan.join(
        _scan("l.parquet", _left_schema()), _scan("r.parquet", _right_schema()),
        lon^, ron^, JOIN_INNER,
    )


def _no_residual(plan: LogicalPlan) raises -> Bool:
    assert_true(plan.tag == PLAN_JOIN, "the join stays on top")
    return not plan._join.value()[].residual


def test_rules_leave_absent_join_residual_absent() raises:
    """Catches: a rule reading or inventing a residual on a Join that has
    none (`if j.residual:` in `_rewrite_agg_and_residual_sites`)."""
    assert_true(_no_residual(fold_constants(_join_without_residual())), "fold: no residual")
    assert_true(_no_residual(simplify_predicates(_join_without_residual())), "simplify: no residual")
    assert_true(_no_residual(rewrite_in_clauses(_join_without_residual())), "in: no residual")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
