# =============================================================================
# komira_plan_conformance/cases_agg_grouping.mojo -- shard agg_grouping.
# =============================================================================
#
# NULLs in aggregates, query semantics §2.1 to §2.4, with result types from
# §8.1, §8.6 and §8.7. Over dataset groups (k = 1, NULL, 2; v with NULLs, the
# k = 2 group holding only NULL values): NULL grouping keys form one group;
# COUNT(*) counts rows and COUNT(v) non-NULL values; SUM, MIN and MAX of a
# group with no non-NULL input are NULL while COUNT is 0; an aggregate over
# zero rows answers one row without grouping keys and none with them. Every
# expectation is HAND, its derivation in the .tsv.
#
# The defect each case would catch once it executes:
#   null_keys_one_group          NULL keys hashed apart: two or three NULL groups
#   count_star_vs_count_col      COUNT(v) counting NULLs, or COUNT(*) skipping them
#   sum_all_null_group_is_null   SUM of an all-NULL group as 0
#   min_max_all_null_group       MIN/MAX of an all-NULL group as 0 or a sentinel
#   empty_input_no_keys          zero rows instead of one; COUNT NULL; SUM 0
#   empty_input_with_keys        one all-NULL row instead of none
# =============================================================================

from komira_plan_expr.agg_expr import AGG_COUNT, AGG_MAX, AGG_MIN, AGG_SUM, AggExpr
from komira_plan_expr.expr import BIN_LT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import groups, scan

comptime SHARD = "agg_grouping"


def _agg(func: UInt8, column: String, name: String) -> AggExpr:
    """`func(column) AS name`; an empty `column` is COUNT(*)."""
    var child: Optional[Expr] = None
    if column.byte_length() > 0:
        child = Expr.col_ref(column)
    return AggExpr(func, child^, Optional(name))


def _by_k() -> ExprArray:
    var g = ExprArray()
    g.append(Expr.col_ref("k"))
    return g^


def _no_rows() raises -> LogicalPlan:
    """groups filtered by `id < 0`: ids are 1 to 7, so no row is TRUE (§1.2)."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_LT,
            Expr.col_ref("id"),
            Expr.literal(ScalarValue.from_int64(Int64(0))),
        ),
        scan(groups()),
    )


def _null_keys_one_group() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "", "n"))
    return LogicalPlan.aggregate(_by_k(), a^, scan(groups()))


def _count_star_vs_count_col() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "", "n"))
    a.append(_agg(AGG_COUNT, "v", "nv"))
    return LogicalPlan.aggregate(_by_k(), a^, scan(groups()))


def _sum_all_null_group_is_null() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_SUM, "v", "s"))
    return LogicalPlan.aggregate(_by_k(), a^, scan(groups()))


def _min_max_all_null_group() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_MIN, "v", "lo"))
    a.append(_agg(AGG_MAX, "v", "hi"))
    return LogicalPlan.aggregate(_by_k(), a^, scan(groups()))


def _empty_input_no_keys() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "", "n"))
    a.append(_agg(AGG_COUNT, "v", "nv"))
    a.append(_agg(AGG_SUM, "v", "s"))
    a.append(_agg(AGG_MAX, "v", "hi"))
    return LogicalPlan.aggregate(ExprArray(), a^, _no_rows())


def _empty_input_with_keys() raises -> LogicalPlan:
    var a = AggExprArray()
    a.append(_agg(AGG_COUNT, "", "n"))
    return LogicalPlan.aggregate(_by_k(), a^, _no_rows())


def cases() -> List[Case]:
    """The shard's cases. An aggregate promises no row order (§4.8), so every
    case compares its rows as a multiset."""
    return [
        Case.hand("null_keys_one_group", SHARD, _null_keys_one_group, CanonPolicy.unordered()),
        Case.hand("count_star_vs_count_col", SHARD, _count_star_vs_count_col, CanonPolicy.unordered()),
        Case.hand("sum_all_null_group_is_null", SHARD, _sum_all_null_group_is_null, CanonPolicy.unordered()),
        Case.hand("min_max_all_null_group", SHARD, _min_max_all_null_group, CanonPolicy.unordered()),
        Case.hand("empty_input_no_keys", SHARD, _empty_input_no_keys, CanonPolicy.unordered()),
        Case.hand("empty_input_with_keys", SHARD, _empty_input_with_keys, CanonPolicy.unordered()),
    ]
