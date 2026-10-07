# =============================================================================
# test_optimizer_or_factoring_shapes -- the walk, the bail-outs, the collapse
# =============================================================================
#
# Companion to `test_optimizer_or_factoring.mojo`, which pins the Q19 shape.
# These tests pin what that file does not reach: the plan walk under every
# node kind, the aggregate and window bail-outs, the collapse when a branch
# is entirely common, duplicate conjuncts inside a branch, and the residual
# literal checks.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.partition_expr import PF_RANK
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_plan_ir.plan_helpers import _expr_fingerprint

from komira_optimizer.optimizer_or_factoring import (
    factor_or_conjuncts_expr,
    factor_or_conjuncts_inplace,
    _try_factor_or,
)


def _eq(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(c), Expr.literal(ScalarValue.from_int(v)))


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _or(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_OR, l^, r^)


def _fp(e: Expr) -> String:
    return _expr_fingerprint(e)


def _factorable() -> Expr:
    """(a == 1 AND b == 2) OR (a == 1 AND c == 3) -> a == 1 AND (b == 2 OR c == 3)."""
    return _or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("a", 1), _eq("c", 3)))


def _factored() -> Expr:
    return _and(_eq("a", 1), _or(_eq("b", 2), _eq("c", 3)))


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    return sb.build()


def _filter() -> LogicalPlan:
    return LogicalPlan.filter(
        _factorable(), LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())
    )


# =============================================================================
# Expression rules
# =============================================================================


def test_a_branch_that_is_entirely_common_collapses_the_or() raises:
    # (a == 1 AND b == 2) OR (a == 1) is a == 1. Catches: the collapse
    # dropped (the result would keep `... OR true`) or the hoisted conjunct
    # lost.
    var out = factor_or_conjuncts_expr(_or(_and(_eq("a", 1), _eq("b", 2)), _eq("a", 1)))
    assert_equal(_fp(out), _fp(_eq("a", 1)))


def test_a_true_literal_residual_also_collapses() raises:
    # (a == 1 AND true) OR (a == 1 AND b == 2): the residual `true` makes the
    # OR true. Catches: `_is_true_literal` answering False for true.
    var t = Expr.literal(ScalarValue.from_bool(True))
    var out = factor_or_conjuncts_expr(
        _or(_and(_eq("a", 1), t^), _and(_eq("a", 1), _eq("b", 2)))
    )
    assert_equal(_fp(out), _fp(_eq("a", 1)))


def test_false_and_integer_literal_residuals_do_not_collapse() raises:
    # Catches: `_is_true_literal` answering True for a false literal or for a
    # non-boolean literal (the OR would be dropped and rows lost).
    var f = Expr.literal(ScalarValue.from_bool(False))
    var out = factor_or_conjuncts_expr(
        _or(_and(_eq("a", 1), f.copy()), _and(_eq("a", 1), _eq("b", 2)))
    )
    assert_equal(_fp(out), _fp(_and(_eq("a", 1), _or(f^, _eq("b", 2)))))
    var five = Expr.literal(ScalarValue.from_int(5))
    var out2 = factor_or_conjuncts_expr(
        _or(_and(_eq("a", 1), five.copy()), _and(_eq("a", 1), _eq("b", 2)))
    )
    assert_equal(_fp(out2), _fp(_and(_eq("a", 1), _or(five^, _eq("b", 2)))))


def test_a_conjunct_repeated_in_the_first_branch_is_hoisted_once() raises:
    # (a == 1 AND a == 1 AND b == 2) OR (a == 1 AND c == 3). Catches: the
    # first-branch de-dup or the hoist de-dup removed (a == 1 AND a == 1).
    var out = factor_or_conjuncts_expr(
        _or(
            _and(_and(_eq("a", 1), _eq("a", 1)), _eq("b", 2)),
            _and(_eq("a", 1), _eq("c", 3)),
        )
    )
    assert_equal(_fp(out), _fp(_factored()))


def test_two_common_conjuncts_hoist_as_an_and_chain() raises:
    # Catches: the hoisted chain keeping only its first conjunct.
    var out = factor_or_conjuncts_expr(
        _or(
            _and(_and(_eq("a", 1), _eq("b", 2)), _eq("c", 3)),
            _and(_and(_eq("a", 1), _eq("b", 2)), _eq("c", 4)),
        )
    )
    assert_equal(
        _fp(out), _fp(_and(_and(_eq("a", 1), _eq("b", 2)), _or(_eq("c", 3), _eq("c", 4))))
    )


def test_aggregate_and_window_branches_bail_out() raises:
    # Catches: the AGG_FN or WINDOW_FN arm of the purity check dropped (a
    # conjunct holding an aggregate or a window value would be hoisted).
    var agg_branch = _and(
        _eq("a", 1),
        Expr.binary(BIN_EQ, Expr.agg_fn(AGG_MAX, Expr.col_ref("b")), Expr.col_ref("c")),
    )
    var p1 = _or(agg_branch^, _and(_eq("a", 1), _eq("c", 3)))
    var fp1 = _fp(p1)
    assert_equal(_fp(factor_or_conjuncts_expr(p1^)), fp1)

    var win = Expr.window_fn(PF_RANK, String(""), 0, PartitionFrame.default_ordered())
    var win_branch = _and(_eq("a", 1), Expr.binary(BIN_EQ, win^, Expr.col_ref("c")))
    var p2 = _or(win_branch^, _and(_eq("a", 1), _eq("c", 3)))
    var fp2 = _fp(p2)
    assert_equal(_fp(factor_or_conjuncts_expr(p2^)), fp2)


def test_a_non_or_input_to_the_core_is_returned_as_is() raises:
    # The core is only reached with an OR; called with a leaf it sees one
    # branch and must not rebuild. Catches: the single-branch guard removed.
    assert_equal(_fp(_try_factor_or(_eq("a", 1))), _fp(_eq("a", 1)))
    # A non-binary root is returned by the walker untouched.
    assert_equal(_fp(factor_or_conjuncts_expr(Expr.col_ref("a"))), _fp(Expr.col_ref("a")))


# =============================================================================
# The plan walk
# =============================================================================


def _wrap(kind: Int) -> LogicalPlan:
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        var pe = ExprArray()
        pe.append(Expr.col_ref("a"))
        return LogicalPlan.project(pe^, _filter())
    if kind == 1:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref("a")), Optional[String]("s")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, _filter())
    if kind == 2:
        return LogicalPlan.sort(keys^, desc^, _filter())
    if kind == 3:
        return LogicalPlan.limit(2, _filter())
    if kind == 4:
        return LogicalPlan.distinct(None, _filter())
    if kind == 5:
        return LogicalPlan.topn(keys^, desc^, 2, _filter())
    var lk = List[String]()
    lk.append(String("a"))
    var rk = List[String]()
    rk.append(String("a"))
    return LogicalPlan.join(_filter(), _filter(), lk^, rk^, JOIN_INNER)


def _pred_fp(imm plan: LogicalPlan, kind: Int) -> String:
    if kind == 0:
        return _fp(plan.project_data_ref().child[].filter_data_ref().predicate)
    if kind == 1:
        return _fp(plan.aggregate_data_ref().child[].filter_data_ref().predicate)
    if kind == 2:
        return _fp(plan.sort_data_ref().child[].filter_data_ref().predicate)
    if kind == 3:
        return _fp(plan.limit_data_ref().child[].filter_data_ref().predicate)
    if kind == 4:
        return _fp(plan.distinct_data_ref().child[].filter_data_ref().predicate)
    if kind == 5:
        return _fp(plan.topn_data_ref().child[].filter_data_ref().predicate)
    return (
        _fp(plan.join_data_ref().left[].filter_data_ref().predicate)
        + _fp(plan.join_data_ref().right[].filter_data_ref().predicate)
    )


def test_the_walk_factors_a_filter_under_every_node_kind() raises:
    # Project, Aggregate, Sort, Limit, Distinct, TopN and both sides of a
    # Join. Catches: a recursion arm dropped (the Filter below that kind
    # keeps the unfactored OR).
    var want = _fp(_factored())
    var want_twice = want.copy()
    want_twice += want
    for kind in range(7):
        var plan = _wrap(kind)
        factor_or_conjuncts_inplace(plan)
        if kind == 6:
            assert_equal(_pred_fp(plan, kind), want_twice)
        else:
            assert_equal(_pred_fp(plan, kind), want)
    # A scan is a leaf.
    var scan = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())
    var h = scan.structural_hash()
    factor_or_conjuncts_inplace(scan)
    assert_equal(scan.structural_hash(), h)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
