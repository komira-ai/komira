# =============================================================================
# komira_plan_conformance/cases_conditional.mojo -- shard conditional.
# =============================================================================
#
# Conditional expressions and NULL, citing query semantics §1.1, §1.2,
# §1.4, §1.5, §1.7, §1.8, §8.8 and §8.19. A CASE whose condition is NULL
# does not take that branch (§1.7); a CASE with no ELSE answers NULL;
# COALESCE is a CASE over IS NOT NULL (§8.14: "COALESCE, which is a CASE");
# NULLIF(x, y) is CASE WHEN x = y THEN NULL ELSE x (§1.8); IN and NOT IN
# over a list holding a NULL member (§1.4, §1.5), as values and as filters.
# Datasets bool_pairs (every pair of TRUE, FALSE, NULL) and int_pairs (x, y
# = (1, 10), (NULL, 20), (3, NULL), (NULL, NULL), (5, 5)). Every
# expectation is HAND, its derivation in the .tsv. No case's root is a SORT,
# so every case compares its rows as a multiset (§4.8).
#
# Types. The result type of a CASE over mixed branch types is UNDECIDED
# (§8.14), so every branch of every CASE here is INT64: a column of
# int_pairs or an INT64 literal (§8.19), the NULL literal included. Under
# each of §8.14's options a CASE whose branches share one type has that
# type. A CASE is nullable by §8's default (no row of the table says
# otherwise).
#
# The plan has no CASE without an ELSE and no COALESCE or NULLIF node:
#   - a missing ELSE is spelled ELSE NULL (an INT64 NULL literal); §1.7 says
#     a missing ELSE answers NULL, so the two are the same CASE;
#   - COALESCE is built with komira_plan_expr's `coalesce_of`, the CASE over
#     IS NOT NULL that §1.7's "current behaviour" names;
#   - NULLIF is built here as the CASE §1.8 defines it to be, with BIN_EQ.
# IN is the plan's IN_LIST node (`Expr.in_list_node`), the tuple form §1.4
# defines; NOT IN is NOT over it (§1.5).
#
# The defect each case would catch once a plan executes (nothing executes
# one here yet, so "catch" means the expected rows differ from the rows the
# defect would give):
#   case_null_condition       a NULL WHEN taken as TRUE (ids 7 to 9 answer
#                             1); a NULL WHEN read as FALSE under NOT, so
#                             NOT a takes the branch for a NULL a
#   case_no_else              a missing ELSE answering 0 or the last THEN
#   coalesce_nulls            COALESCE stopping at the first argument, or
#                             answering 0 when every argument is NULL
#   nullif_null_operands      x = y with a NULL operand read as TRUE (id 2,
#                             3 answer NULL) or NULLIF answering y
#   in_list_null_member       a NULL member skipped (2 IN (1, NULL) as
#                             FALSE), or NULL IN (...) as FALSE
#   not_in_list_null_member   NOT IN with a NULL member as TRUE for a row
#                             that matches nothing
#   filter_in_null_member     a NULL predicate kept as TRUE
#   filter_not_in_null_member NOT IN (1, NULL) keeping rows (it is never
#                             TRUE)
#   filter_not_in_no_null     the NULL x row kept, or the 3 row kept
# =============================================================================

from komira_plan_expr.expr import (
    BIN_EQ,
    UN_NOT,
    Expr,
    WhenCaseData,
)
from komira_plan_expr.scalar_desugar import coalesce_of
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import bool_pairs, int_pairs, scan

comptime SHARD = "conditional"


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _as(var e: Expr, name: String) -> Expr:
    return Expr.alias(e^, name)


def _i64(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _null_i64() -> Expr:
    return Expr.literal(ScalarValue.null(DType.int64))


def _when(var cond: Expr, var result: Expr) -> WhenCaseData:
    return WhenCaseData(cond^, result^)


def _in(var x: Expr, *members: Optional[Int]) -> Expr:
    """`x IN (members)`; a None member is an INT64 NULL."""
    var vs = List[ScalarValue]()
    for m in members:
        if m:
            vs.append(ScalarValue.from_int64(Int64(m.value())))
        else:
            vs.append(ScalarValue.null(DType.int64))
    return Expr.in_list_node(x^, vs^)


def _not(var e: Expr) -> Expr:
    return Expr.unary(UN_NOT, e^)


# --- bool_pairs ---------------------------------------------------------------


def _case_null_condition() raises -> LogicalPlan:
    """r = CASE WHEN a THEN 1 WHEN b THEN 2 ELSE 3 END,
    r_not = CASE WHEN NOT a THEN 10 ELSE 20 END."""
    var arms = List[WhenCaseData]()
    arms.append(_when(_col("a"), _i64(1)))
    arms.append(_when(_col("b"), _i64(2)))
    var arms_not = List[WhenCaseData]()
    arms_not.append(_when(_not(_col("a")), _i64(10)))
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(Expr.when(arms^, _i64(3)), "r"))
    e.append(_as(Expr.when(arms_not^, _i64(20)), "r_not"))
    return LogicalPlan.project(e^, scan(bool_pairs()))


def _case_no_else() raises -> LogicalPlan:
    """r = CASE WHEN a THEN 1 WHEN b THEN 2 END, its missing ELSE spelled
    ELSE NULL."""
    var arms = List[WhenCaseData]()
    arms.append(_when(_col("a"), _i64(1)))
    arms.append(_when(_col("b"), _i64(2)))
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(Expr.when(arms^, _null_i64()), "r"))
    return LogicalPlan.project(e^, scan(bool_pairs()))


# --- int_pairs ----------------------------------------------------------------


def _coalesce_nulls() raises -> LogicalPlan:
    """COALESCE(x, y), COALESCE(y, x), COALESCE(x, y, 0)."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(coalesce_of([_col("x"), _col("y")]), "c_xy"))
    e.append(_as(coalesce_of([_col("y"), _col("x")]), "c_yx"))
    e.append(_as(coalesce_of([_col("x"), _col("y"), _i64(0)]), "c_xy0"))
    return LogicalPlan.project(e^, scan(int_pairs()))


def _nullif(var x: Expr, var y: Expr) -> Expr:
    """NULLIF(x, y) = CASE WHEN x = y THEN NULL ELSE x END."""
    var arms = List[WhenCaseData]()
    arms.append(_when(Expr.binary(BIN_EQ, x.copy(), y^), _null_i64()))
    return Expr.when(arms^, x^)


def _nullif_null_operands() raises -> LogicalPlan:
    """NULLIF(x, y), NULLIF(x, 3)."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_nullif(_col("x"), _col("y")), "nullif_xy"))
    e.append(_as(_nullif(_col("x"), _i64(3)), "nullif_x3"))
    return LogicalPlan.project(e^, scan(int_pairs()))


def _in_list_null_member() raises -> LogicalPlan:
    """x IN (1, NULL), x IN (1, 3)."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_in(_col("x"), Optional(1), None), "in_1_null"))
    e.append(_as(_in(_col("x"), Optional(1), Optional(3)), "in_1_3"))
    return LogicalPlan.project(e^, scan(int_pairs()))


def _not_in_list_null_member() raises -> LogicalPlan:
    """x NOT IN (1, NULL), x NOT IN (1, 3)."""
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_not(_in(_col("x"), Optional(1), None)), "nin_1_null"))
    e.append(_as(_not(_in(_col("x"), Optional(1), Optional(3))), "nin_1_3"))
    return LogicalPlan.project(e^, scan(int_pairs()))


def _filter_in_null_member() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _in(_col("x"), Optional(1), None), scan(int_pairs())
    )


def _filter_not_in_null_member() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _not(_in(_col("x"), Optional(1), None)), scan(int_pairs())
    )


def _filter_not_in_no_null() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _not(_in(_col("x"), Optional(1), Optional(3))), scan(int_pairs())
    )


def cases() -> List[Case]:
    return [
        Case.hand("case_null_condition", SHARD, _case_null_condition, CanonPolicy.unordered()),
        Case.hand("case_no_else", SHARD, _case_no_else, CanonPolicy.unordered()),
        Case.hand("coalesce_nulls", SHARD, _coalesce_nulls, CanonPolicy.unordered()),
        Case.hand("nullif_null_operands", SHARD, _nullif_null_operands, CanonPolicy.unordered()),
        Case.hand("in_list_null_member", SHARD, _in_list_null_member, CanonPolicy.unordered()),
        Case.hand("not_in_list_null_member", SHARD, _not_in_list_null_member, CanonPolicy.unordered()),
        Case.hand("filter_in_null_member", SHARD, _filter_in_null_member, CanonPolicy.unordered()),
        Case.hand("filter_not_in_null_member", SHARD, _filter_not_in_null_member, CanonPolicy.unordered()),
        Case.hand("filter_not_in_no_null", SHARD, _filter_not_in_no_null, CanonPolicy.unordered()),
    ]
