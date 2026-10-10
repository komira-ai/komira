# =============================================================================
# komira_plan_conformance/cases_filter_3vl.mojo -- shard filter_3vl.
# =============================================================================
#
# Three-valued logic, query semantics §1.1 (AND, OR, NOT) and §1.2
# (comparisons with NULL; a filter keeps a row only when its predicate is
# TRUE). The full AND/OR/NOT truth table over two nullable BOOLEAN columns
# (dataset bool_pairs: every pair of TRUE, FALSE, NULL), as projected values
# and as filters, and comparisons against a NULL literal and a NULL column
# value (dataset ints_nullable). Every expectation is HAND, its derivation in
# the .tsv.
#
# The defect each case would catch once it executes:
#   and_or_truth_table      FALSE AND NULL as NULL, TRUE OR NULL as NULL
#   not_truth_table         NOT NULL as TRUE or FALSE
#   filter_and              a NULL predicate kept as TRUE
#   filter_or               TRUE OR NULL dropped
#   filter_not              NOT NULL kept
#   filter_not_and          NOT (FALSE AND NULL) dropped as NULL
#   compare_null_literal    x = NULL as FALSE (or TRUE for NULL x)
#   compare_null_value      a NULL x compared as a value (0, or equal)
#   filter_eq_null_empty    x = NULL keeping the NULL row
#   filter_ne_drops_null    x <> 2 keeping the NULL row
# =============================================================================

from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    UN_NOT,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import bool_pairs, ints_nullable, scan

comptime SHARD = "filter_3vl"


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _as(var e: Expr, name: String) -> Expr:
    return Expr.alias(e^, name)


def _null_i64() -> Expr:
    return Expr.literal(ScalarValue.null(DType.int64))


def _i64(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


# --- bool_pairs ---------------------------------------------------------------


def _and_or_truth_table() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_col("a"))
    e.append(_col("b"))
    e.append(_as(_bin(BIN_AND, _col("a"), _col("b")), "a_and_b"))
    e.append(_as(_bin(BIN_OR, _col("a"), _col("b")), "a_or_b"))
    return LogicalPlan.project(e^, scan(bool_pairs()))


def _not_truth_table() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_col("a"))
    e.append(_as(Expr.unary(UN_NOT, _col("a")), "not_a"))
    return LogicalPlan.project(e^, scan(bool_pairs()))


def _filter_and() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _bin(BIN_AND, _col("a"), _col("b")), scan(bool_pairs())
    )


def _filter_or() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _bin(BIN_OR, _col("a"), _col("b")), scan(bool_pairs())
    )


def _filter_not() raises -> LogicalPlan:
    return LogicalPlan.filter(Expr.unary(UN_NOT, _col("a")), scan(bool_pairs()))


def _filter_not_and() raises -> LogicalPlan:
    return LogicalPlan.filter(
        Expr.unary(UN_NOT, _bin(BIN_AND, _col("a"), _col("b"))),
        scan(bool_pairs()),
    )


# --- ints_nullable ------------------------------------------------------------


def _compare_null_literal() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_EQ, _col("x"), _null_i64()), "eq_null"))
    e.append(_as(_bin(BIN_NE, _col("x"), _null_i64()), "ne_null"))
    e.append(_as(_bin(BIN_LT, _col("x"), _null_i64()), "lt_null"))
    return LogicalPlan.project(e^, scan(ints_nullable()))


def _compare_null_value() raises -> LogicalPlan:
    var e = ExprArray()
    e.append(_col("id"))
    e.append(_as(_bin(BIN_EQ, _col("x"), _i64(2)), "eq_2"))
    e.append(_as(_bin(BIN_NE, _col("x"), _i64(2)), "ne_2"))
    e.append(_as(_bin(BIN_GT, _col("x"), _i64(1)), "gt_1"))
    return LogicalPlan.project(e^, scan(ints_nullable()))


def _filter_eq_null_empty() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _bin(BIN_EQ, _col("x"), _null_i64()), scan(ints_nullable())
    )


def _filter_ne_drops_null() raises -> LogicalPlan:
    return LogicalPlan.filter(
        _bin(BIN_NE, _col("x"), _i64(2)), scan(ints_nullable())
    )


def cases() -> List[Case]:
    """The shard's cases. Without an ORDER BY a result's row order is not
    defined (§4.8), so every case compares its rows as a multiset."""
    return [
        Case.hand("and_or_truth_table", SHARD, _and_or_truth_table, CanonPolicy.unordered()),
        Case.hand("not_truth_table", SHARD, _not_truth_table, CanonPolicy.unordered()),
        Case.hand("filter_and", SHARD, _filter_and, CanonPolicy.unordered()),
        Case.hand("filter_or", SHARD, _filter_or, CanonPolicy.unordered()),
        Case.hand("filter_not", SHARD, _filter_not, CanonPolicy.unordered()),
        Case.hand("filter_not_and", SHARD, _filter_not_and, CanonPolicy.unordered()),
        Case.hand("compare_null_literal", SHARD, _compare_null_literal, CanonPolicy.unordered()),
        Case.hand("compare_null_value", SHARD, _compare_null_value, CanonPolicy.unordered()),
        Case.hand("filter_eq_null_empty", SHARD, _filter_eq_null_empty, CanonPolicy.unordered()),
        Case.hand("filter_ne_drops_null", SHARD, _filter_ne_drops_null, CanonPolicy.unordered()),
    ]
