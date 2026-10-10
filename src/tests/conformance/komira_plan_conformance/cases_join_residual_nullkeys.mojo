# =============================================================================
# komira_plan_conformance/cases_join_residual_nullkeys.mojo -- shard
# join_residual_nullkeys.
# =============================================================================
#
# NULLs in joins, citing query semantics §1.2, §3.1, §3.2, §3.4, §3.5, §3.9,
# §3.10 to §3.13 and §11.6. Over datasets join_left (lk = 1, 2, 2, NULL, 3)
# and join_right (rk = 2, 2, NULL, 4, 1), joined on lk = rk: a NULL key
# matches nothing in INNER, LEFT, RIGHT, FULL and SEMI joins (and so is
# returned by ANTI); the two k = 2 rows on each side give 2 x 2 = 4 pairs;
# an outer join pads the other side with NULL; a residual `lv < rw` that is
# NULL drops the pair like FALSE; a join with an empty side follows §11.6.
# Every expectation is HAND, its derivation in the .tsv. No case's root is a
# SORT, so every case compares its rows as a multiset (§4.8).
#
# The defect each case would catch once a plan executes (nothing executes
# one here yet, so "catch" means the expected rows differ from the rows the
# defect would give):
#   inner_null_keys               NULL = NULL matching (a lid 4 / rid 3 row);
#                                 a duplicate key matched once, not 2 x 2
#   inner_null_keys_sort_merge    the same, on the SORT_MERGE kernel (§3.1:
#                                 HASH and SORT_MERGE agree)
#   left_null_keys                an unmatched left row dropped, or padded
#                                 with 0 instead of NULL
#   right_null_keys               the same for the right side
#   full_null_keys                one side's unmatched rows missing
#   full_null_keys_sort_merge     the same, on the SORT_MERGE kernel
#   semi_null_keys                SEMI emitting a row per match (lid 2 and 3
#                                 twice); a NULL key matching
#   anti_null_keys                ANTI as NOT IN: the right NULL key
#                                 removing every row, or the left NULL key
#                                 row dropped
#   inner_residual_null           a NULL residual kept as a match
#   left_residual_null            the residual applied after the join as a
#                                 filter (dropping padded rows), or a NULL
#                                 residual counted as a match
#   anti_residual_null            ANTI treating a NULL residual as a match
#   semi_float_zero_keys          float keys compared by bits: -0.0 not
#                                 matching 0.0
#   cross_empty_right             a CROSS join with an empty side returning
#                                 the other side
#   left_empty_right              a LEFT join with an empty right dropping
#                                 the left rows
#   anti_empty_right              an ANTI join with an empty right dropping
#                                 the left rows
# =============================================================================

from std.memory import OwnedPointer

from komira_plan_expr.expr import BIN_EQ, BIN_LT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import (
    JOIN_ALGO_SORT_MERGE,
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_FULL,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
    LogicalPlan,
)

from .plan_case import Case
from .datasets import join_left, join_right, scan, sort_rows

comptime SHARD = "join_residual_nullkeys"


def _on_k(join_type: UInt8) raises -> LogicalPlan:
    """join_left JOIN join_right ON lk = rk, no residual, AUTO kernel."""
    return LogicalPlan.join(
        scan(join_left()), scan(join_right()), [String("lk")], [String("rk")],
        join_type,
    )


def _on_k_sort_merge(join_type: UInt8) raises -> LogicalPlan:
    return LogicalPlan.join(
        scan(join_left()), scan(join_right()), [String("lk")], [String("rk")],
        join_type, JOIN_ALGO_SORT_MERGE,
    )


def _on_k_lv_lt_rw(join_type: UInt8) raises -> LogicalPlan:
    """ON lk = rk AND lv < rw: the residual's refs are side-qualified."""
    return LogicalPlan.join(
        scan(join_left()), scan(join_right()), [String("lk")], [String("rk")],
        join_type,
        residual=Optional(
            OwnedPointer(Expr.binary(BIN_LT, Expr.left("lv"), Expr.right("rw")))
        ),
    )


def _empty_right() raises -> LogicalPlan:
    """join_right filtered by rid < 0: rids are 1 to 5, so no row is TRUE
    (§1.2)."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_LT,
            Expr.col_ref("rid"),
            Expr.literal(ScalarValue.from_int64(Int64(0))),
        ),
        scan(join_right()),
    )


def _inner_null_keys() raises -> LogicalPlan:
    return _on_k(JOIN_INNER)


def _inner_null_keys_sort_merge() raises -> LogicalPlan:
    return _on_k_sort_merge(JOIN_INNER)


def _left_null_keys() raises -> LogicalPlan:
    return _on_k(JOIN_LEFT)


def _right_null_keys() raises -> LogicalPlan:
    return _on_k(JOIN_RIGHT)


def _full_null_keys() raises -> LogicalPlan:
    return _on_k(JOIN_FULL)


def _full_null_keys_sort_merge() raises -> LogicalPlan:
    return _on_k_sort_merge(JOIN_FULL)


def _semi_null_keys() raises -> LogicalPlan:
    return _on_k(JOIN_SEMI)


def _anti_null_keys() raises -> LogicalPlan:
    return _on_k(JOIN_ANTI)


def _inner_residual_null() raises -> LogicalPlan:
    return _on_k_lv_lt_rw(JOIN_INNER)


def _left_residual_null() raises -> LogicalPlan:
    return _on_k_lv_lt_rw(JOIN_LEFT)


def _anti_residual_null() raises -> LogicalPlan:
    return _on_k_lv_lt_rw(JOIN_ANTI)


def _semi_float_zero_keys() raises -> LogicalPlan:
    """sort_rows SEMI JOIN (sort_rows WHERE id = 3) ON f = f. Row id 3 holds
    f = -0.0."""
    var right = LogicalPlan.filter(
        Expr.binary(
            BIN_EQ,
            Expr.col_ref("id"),
            Expr.literal(ScalarValue.from_int64(Int64(3))),
        ),
        scan(sort_rows()),
    )
    return LogicalPlan.join(
        scan(sort_rows()), right^, [String("f")], [String("f")], JOIN_SEMI
    )


def _cross_empty_right() raises -> LogicalPlan:
    return LogicalPlan.join(
        scan(join_left()), _empty_right(), List[String](), List[String](),
        JOIN_CROSS,
    )


def _left_empty_right() raises -> LogicalPlan:
    return LogicalPlan.join(
        scan(join_left()), _empty_right(), [String("lk")], [String("rk")],
        JOIN_LEFT,
    )


def _anti_empty_right() raises -> LogicalPlan:
    return LogicalPlan.join(
        scan(join_left()), _empty_right(), [String("lk")], [String("rk")],
        JOIN_ANTI,
    )


def cases() -> List[Case]:
    """The shard's cases. A join promises no row order (§4.8), so every case
    compares its rows as a multiset."""
    return [
        Case.hand("inner_null_keys", SHARD, _inner_null_keys, CanonPolicy.unordered()),
        Case.hand("inner_null_keys_sort_merge", SHARD, _inner_null_keys_sort_merge, CanonPolicy.unordered()),
        Case.hand("left_null_keys", SHARD, _left_null_keys, CanonPolicy.unordered()),
        Case.hand("right_null_keys", SHARD, _right_null_keys, CanonPolicy.unordered()),
        Case.hand("full_null_keys", SHARD, _full_null_keys, CanonPolicy.unordered()),
        Case.hand("full_null_keys_sort_merge", SHARD, _full_null_keys_sort_merge, CanonPolicy.unordered()),
        Case.hand("semi_null_keys", SHARD, _semi_null_keys, CanonPolicy.unordered()),
        Case.hand("anti_null_keys", SHARD, _anti_null_keys, CanonPolicy.unordered()),
        Case.hand("inner_residual_null", SHARD, _inner_residual_null, CanonPolicy.unordered()),
        Case.hand("left_residual_null", SHARD, _left_residual_null, CanonPolicy.unordered()),
        Case.hand("anti_residual_null", SHARD, _anti_residual_null, CanonPolicy.unordered()),
        Case.hand("semi_float_zero_keys", SHARD, _semi_float_zero_keys, CanonPolicy.unordered()),
        Case.hand("cross_empty_right", SHARD, _cross_empty_right, CanonPolicy.unordered()),
        Case.hand("left_empty_right", SHARD, _left_empty_right, CanonPolicy.unordered()),
        Case.hand("anti_empty_right", SHARD, _anti_empty_right, CanonPolicy.unordered()),
    ]
