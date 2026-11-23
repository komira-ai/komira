# =============================================================================
# Optimizer rule helper: flatten_scalar
# Scalar subqueries inside an expression, for flatten_dependent_joins
# =============================================================================
#
# A scalar subquery has a value, so unlike EXISTS / NOT EXISTS / IN it can sit
# anywhere in an expression: an operand of a comparison or of arithmetic, under
# NOT, a CAST, an alias or a CASE. `lower_scalar_subqueries_in` replaces each
# one with the expression that computes its value over the columns of a LEFT
# join it adds to the plan below (`_lower_scalar_correlated`), so the outer
# expression reads the value row by row. A LEFT join keeps every outer row
# once (its right side is grouped by the join keys), so where in the
# expression the subquery sits does not change what the join does.
#
# `expr_contains_predicate_subquery` finds an EXISTS / NOT EXISTS / IN
# subquery anywhere under the same node kinds: such a subquery is lowered
# only as a bare predicate (a SEMI or ANTI join), so the callers refuse one
# that sits inside a larger expression.
# =============================================================================

from plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_ALIAS,
    EXPR_AGG_FN,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_IN_LIST,
    EXPR_STRING_OP,
    EXPR_UNARY_OP,
    EXPR_WHEN,
)
from plan_ir.logical_plan import CORR_KIND_SCALAR, LogicalPlan
from .flatten_dependent_joins import (
    _expr_contains_correlated_subquery,
    _lower_scalar_correlated,
)


def expr_contains_predicate_subquery(expr: Expr) -> Bool:
    """True if `expr` holds an EXISTS / NOT EXISTS / IN subquery (a
    correlated subquery of any kind but SCALAR) under the node kinds
    `_expr_contains_correlated_subquery` descends. A SCALAR subquery's inner
    plan is not looked into: its own lowering flattens it."""
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        return expr._corr_subq.value()[].kind != CORR_KIND_SCALAR
    if expr.tag == EXPR_BINARY_OP:
        return expr_contains_predicate_subquery(
            expr.binary_left_ref()
        ) or expr_contains_predicate_subquery(expr.binary_right_ref())
    if expr.tag == EXPR_UNARY_OP:
        return expr_contains_predicate_subquery(expr.unary_child_ref())
    if expr.tag == EXPR_CAST:
        return expr_contains_predicate_subquery(expr.cast_child_ref())
    if expr.tag == EXPR_ALIAS:
        return expr_contains_predicate_subquery(expr.alias_child_ref())
    if expr.tag == EXPR_STRING_OP:
        return expr_contains_predicate_subquery(expr.string_op_child_ref())
    if expr.tag == EXPR_IN_LIST:
        return expr_contains_predicate_subquery(expr._in_list.value().child[])
    if expr.tag == EXPR_AGG_FN:
        return expr_contains_predicate_subquery(expr.agg_fn_child_ref())
    if expr.tag == EXPR_WHEN:
        for i in range(expr.when_num_cases()):
            if expr_contains_predicate_subquery(expr.when_case_condition_ref(i)):
                return True
            if expr_contains_predicate_subquery(expr.when_case_result_ref(i)):
                return True
        return expr_contains_predicate_subquery(expr.when_default_ref())
    return False


def lower_scalar_subqueries_in(
    mut base: LogicalPlan, expr: Expr, mut n: Int, refusal: String
) raises -> Expr:
    """`expr` with every SCALAR subquery in it replaced by its value, each
    one's LEFT join added over `base` (left to right in the expression; the
    `n`th one's aggregate, for a plan built with an Aggregate at its inner
    root, is named `__corr_scalar_<n>`). Descends binary and unary operators,
    CAST, alias and CASE; raises `refusal` for a subquery under any other
    node kind and for one that is not SCALAR."""
    if not _expr_contains_correlated_subquery(expr):
        return expr.copy()
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        if expr._corr_subq.value()[].kind != CORR_KIND_SCALAR:
            raise Error(refusal)
        var lowered = _lower_scalar_correlated(
            base.copy(), expr, "__corr_scalar_" + String(n)
        )
        n += 1
        base = lowered.plan.copy()
        return lowered.value.copy()
    if expr.tag == EXPR_BINARY_OP:
        var l = lower_scalar_subqueries_in(base, expr.binary_left_ref(), n, refusal)
        var r = lower_scalar_subqueries_in(base, expr.binary_right_ref(), n, refusal)
        return Expr.binary_with_division_intent(
            expr.binary_op(), l^, r^, expr.binary_division_intent()
        )
    if expr.tag == EXPR_UNARY_OP:
        var c = lower_scalar_subqueries_in(base, expr.unary_child_ref(), n, refusal)
        return Expr.unary(expr.unary_op(), c^)
    if expr.tag == EXPR_CAST:
        var c = lower_scalar_subqueries_in(base, expr.cast_child_ref(), n, refusal)
        return Expr.cast_preserving_arrow(c^, expr)
    if expr.tag == EXPR_ALIAS:
        var c = lower_scalar_subqueries_in(base, expr.alias_child_ref(), n, refusal)
        return Expr.alias(c^, expr.alias_name())
    if expr.tag == EXPR_WHEN:
        var cases = List[WhenCaseData]()
        for i in range(expr.when_num_cases()):
            var c = lower_scalar_subqueries_in(
                base, expr.when_case_condition_ref(i), n, refusal
            )
            var r = lower_scalar_subqueries_in(
                base, expr.when_case_result_ref(i), n, refusal
            )
            cases.append(WhenCaseData(c^, r^))
        var d = lower_scalar_subqueries_in(base, expr.when_default_ref(), n, refusal)
        return Expr.when(cases^, d^)
    raise Error(refusal)
