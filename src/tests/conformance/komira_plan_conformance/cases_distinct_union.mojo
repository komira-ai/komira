# =============================================================================
# komira_plan_conformance/cases_distinct_union.mojo -- shard distinct_union.
# =============================================================================
#
# DISTINCT and UNION, built from the plan's PLAN_DISTINCT and PLAN_UNION
# nodes (UNION ALL is PLAN_UNION; UNION is PLAN_DISTINCT over it, §11.2),
# citing query semantics §2.1, §2.3, §2.4, §2.6, §4.6, §4.8, §5.0, §5.6,
# §7.14, §8.6 and §11.1, §11.2, §11.4, §11.6. Datasets:
#   set_left   (k, s): (1, "a") x2, (NULL, "a") x2, (NULL, NULL) x2,
#              (2, NULL), (2, "b"), (4, decomposed e-acute 65 CC 81).
#   set_right  (k, s): (1, "a"), (NULL, NULL), (3, U+65E5), (2, "B"),
#              (4, precomposed e-acute C3 A9), (5, U+1F600).
#   sort_rows  f = 1.5, 0.0, -0.0, -2.5, NULL, 0.0, 0.5.
#   float_pairs p / q = inf, -inf, NaN, NULL, -inf, 0.25, NaN, NULL (§5.6).
# Every set operation projects (k, s) first, so the ids do not make every
# row distinct. Both inputs of every UNION have identical column names,
# types and nullability (§11.1, §11.4); a mixed-type union is the
# frontend's to cast and is not a plan case. No root here sorts, so every
# case compares its rows as a multiset (§4.8).
#
# Not here, and why:
#   - INTERSECT and EXCEPT: UNDECIDED (§11.3), and the plan has no node.
#   - A DISTINCT result holding a float zero: §2.6 leaves which zero
#     represents the group open, and the harness compares zeros by bits, so
#     the -0.0/0.0 case counts the distinct values instead of listing them.
#   - A UNION whose inputs differ only in nullability: komira_plan_wire
#     refuses it (every branch must carry the union's schema, nullability
#     included), and §11.1 and §11.4 speak of names and types only.
#     Reported as a disagreement, not written as a case.
#
# The defect each case would catch once it executes:
#   distinct_nulls_equal        NULL keys compared with `=` (each NULL row
#                               kept, 9 rows); NULLs dropped; DISTINCT over
#                               a normalized string (65 CC 81 kept apart)
#   distinct_float_zero_count   -0.0 and 0.0 kept apart (n = 6); NULL not
#                               one value (n = 5 with nf still 4 is right)
#   distinct_float_nan_inf      NaN never equal to itself (two NaN rows);
#                               the NULLs dropped or kept twice
#   union_all_keeps_duplicates  UNION ALL deduplicating (fewer than 15)
#   union_distinct_nulls_equal  UNION keeping duplicate or all-NULL rows;
#                               "b" and "B", or the two e-acutes, folded
#   union_all_empty_side        an empty branch dropping the union's rows,
#                               or deduplicating them
#   union_distinct_empty_side   an empty first branch ending the union
#   union_all_both_empty        a row invented from nothing
# =============================================================================

from std.memory import OwnedPointer

from komira_plan_expr.agg_expr import AGG_COUNT, AggExpr
from komira_plan_expr.expr import BIN_DIV, BIN_LT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import float_pairs, scan, set_left, set_right, sort_rows

comptime SHARD = "distinct_union"


def _k_s(var input: LogicalPlan) -> LogicalPlan:
    """`SELECT k, s FROM input`: the scanned fields, ids dropped."""
    var e = ExprArray()
    e.append(Expr.col_ref("k"))
    e.append(Expr.col_ref("s"))
    return LogicalPlan.project(e^, input^)


def _empty(var input: LogicalPlan) raises -> LogicalPlan:
    """`input WHERE id < 0`: no row (every id is positive), same schema."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_LT,
            Expr.col_ref("id"),
            Expr.literal(ScalarValue.from_int64(Int64(0))),
        ),
        input^,
    )


def _union_all(var first: LogicalPlan, var second: LogicalPlan) -> LogicalPlan:
    """UNION ALL of two inputs that already share one schema (§11.4); the
    output schema is the first input's."""
    var schema = first.output_schema.copy()
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(first^))
    children.append(OwnedPointer(second^))
    return LogicalPlan.union(children^, schema^)


def _distinct(var input: LogicalPlan) -> LogicalPlan:
    """DISTINCT over every column."""
    return LogicalPlan.distinct(None, input^)


def _distinct_nulls_equal() raises -> LogicalPlan:
    return _distinct(_k_s(scan(set_left())))


def _distinct_float_zero_count() raises -> LogicalPlan:
    """COUNT(*) and COUNT(f) over DISTINCT f of sort_rows."""
    var e = ExprArray()
    e.append(Expr.col_ref("f"))
    var d = _distinct(LogicalPlan.project(e^, scan(sort_rows())))
    var a = AggExprArray()
    a.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    a.append(AggExpr(AGG_COUNT, Optional(Expr.col_ref("f")), Optional(String("nf"))))
    return LogicalPlan.aggregate(ExprArray(), a^, d^)


def _distinct_float_nan_inf() raises -> LogicalPlan:
    """DISTINCT (p / q AS d) over float_pairs."""
    var e = ExprArray()
    e.append(
        Expr.alias(Expr.binary(BIN_DIV, Expr.col_ref("p"), Expr.col_ref("q")), "d")
    )
    return _distinct(LogicalPlan.project(e^, scan(float_pairs())))


def _union_all_keeps_duplicates() raises -> LogicalPlan:
    return _union_all(_k_s(scan(set_left())), _k_s(scan(set_right())))


def _union_distinct_nulls_equal() raises -> LogicalPlan:
    return _distinct(_union_all(_k_s(scan(set_left())), _k_s(scan(set_right()))))


def _union_all_empty_side() raises -> LogicalPlan:
    return _union_all(_k_s(scan(set_left())), _k_s(_empty(scan(set_right()))))


def _union_distinct_empty_side() raises -> LogicalPlan:
    return _distinct(_union_all(_k_s(_empty(scan(set_right()))), _k_s(scan(set_left()))))


def _union_all_both_empty() raises -> LogicalPlan:
    return _union_all(_k_s(_empty(scan(set_left()))), _k_s(_empty(scan(set_right()))))


def cases() -> List[Case]:
    return [
        Case.hand("distinct_nulls_equal", SHARD, _distinct_nulls_equal, CanonPolicy.unordered()),
        Case.hand("distinct_float_zero_count", SHARD, _distinct_float_zero_count, CanonPolicy.unordered()),
        Case.hand("distinct_float_nan_inf", SHARD, _distinct_float_nan_inf, CanonPolicy.unordered()),
        Case.hand("union_all_keeps_duplicates", SHARD, _union_all_keeps_duplicates, CanonPolicy.unordered()),
        Case.hand("union_distinct_nulls_equal", SHARD, _union_distinct_nulls_equal, CanonPolicy.unordered()),
        Case.hand("union_all_empty_side", SHARD, _union_all_empty_side, CanonPolicy.unordered()),
        Case.hand("union_distinct_empty_side", SHARD, _union_distinct_empty_side, CanonPolicy.unordered()),
        Case.hand("union_all_both_empty", SHARD, _union_all_both_empty, CanonPolicy.unordered()),
    ]
