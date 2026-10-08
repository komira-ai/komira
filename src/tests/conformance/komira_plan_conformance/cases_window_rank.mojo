# =============================================================================
# komira_plan_conformance/cases_window_rank.mojo -- shard window_rank.
# =============================================================================
#
# Window functions, citing query semantics §9.2 to §9.5, §9.7, §9.9 and
# §4.1 (the window ORDER BY's placement, §9.6), with result types from §8.22
# and §8.24. Two datasets:
#   window_rows  partitions g = 1: ids 1 to 3, v = 10, NULL, 30; g = 2: ids
#                4, 5, v = 40, 50; g = 3: id 6, v = 60. g is non-nullable.
#                LAG and LEAD with and without a default, an explicit NULL
#                default, an offset of 2, a descending order key, and LAG
#                over the non-nullable g with and without a default.
#   rank_rows    g = 1: o = 10, 20, 20, 30, NULL, NULL (ids 1 to 6); g = 2:
#                o = 5 (id 7); g NULL: o = 7, 7, 9 (ids 8 to 10). RANK and
#                DENSE_RANK over a tie and two NULL order keys, ascending and
#                descending; ROW_NUMBER among peers, compared as a set; a
#                NULL partition key forming one partition.
# Every expectation is HAND, its derivation in the .tsv. A PARTITION_BY (or
# PROJECT) root is not a SORT, so every case compares its rows as a
# multiset (§4.8). Where ROW_NUMBER numbers peers, which peer gets which
# number is not promised (§9.3): row_number_peers_as_set projects the ids
# away, so the peers' rows compare as a set; the other ROW_NUMBER case
# orders by the total key id.
#
# Types. §8.22: ROW_NUMBER, RANK and DENSE_RANK are INT64, non-nullable.
# §8.24: LAG and LEAD have the input column's type, non-nullable only when
# the input is non-nullable and a non-NULL default is given.
#
# Not here: a windowed SUM under its RANGE default frame. komira_plan_ir can
# express the frame (PartitionFrame.running_range()), but it declares a
# windowed SUM non-nullable where §8.26 makes it always nullable, so the
# case's schema would disagree with the plan and test_corpus would be red.
# That is item 13 of the document's "Code that does not follow" (tracked as
# komira#771); the case waits for the fix.
#
# The defect each case would catch once a plan executes (nothing executes
# one here yet, so "catch" means the expected rows differ from the rows the
# defect would give):
#   lag_lead_no_default     LAG/LEAD crossing the partition edge (id 4's
#                           LAG reading id 3's 30); a NULL value skipped
#                           (§9.5: id 3's LAG reading id 1's 10)
#   lag_lead_default        the default answering a NULL value at an
#                           existing offset row (id 1's LEAD, id 3's LAG);
#                           the default not applied at the edge
#   lag_lead_null_default   an explicit NULL default read as a value (0)
#   lag_lead_offset_2       the offset ignored (read as 1); an offset
#                           counted across the partition edge (id 4's LAG
#                           reading id 2's NULL, id 3's LEAD id 5's 50)
#   lag_desc                the order key's direction ignored
#   lag_non_nullable_input  a LAG over a non-nullable input with a non-NULL
#                           default answering NULL at the edge
#   rank_dense_rank_ties    RANK without gaps (id 4 as 3) or DENSE_RANK with
#                           them; peers ranked apart; NULL order keys ranked
#                           apart (§9.7) or first; the NULL-g rows split
#   rank_desc               DESC placing NULLs first (PostgreSQL's rule)
#   row_number_peers_as_set ROW_NUMBER giving peers one number (2, 2), or
#                           not restarting per partition
#   null_partition_key_one_partition  NULL partition keys hashed apart
#                           (ids 8 to 10 numbered 1, 1, 1)
# =============================================================================

from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan

from .plan_case import Case
from .datasets import rank_rows, scan, window_rows

comptime SHARD = "window_rank"


def _i64(v: Int) -> ScalarValue:
    return ScalarValue.from_int64(Int64(v))


def _over_g_by_id(desc: Bool, var fns: List[PartitionExpr]) raises -> LogicalPlan:
    """window_rows with `fns` OVER (PARTITION BY g ORDER BY id [DESC])."""
    return LogicalPlan.partition_by(
        [String("g")], [String("id")], [desc], fns^, scan(window_rows())
    )


def _lag_lead_no_default() raises -> LogicalPlan:
    """LAG(v) AS lag_v, LEAD(v) AS lead_v."""
    return _over_g_by_id(
        False,
        [
            PartitionExpr.lag("v").with_alias("lag_v"),
            PartitionExpr.lead("v").with_alias("lead_v"),
        ],
    )


def _lag_lead_default() raises -> LogicalPlan:
    """LAG(v, 1, 0) AS lag_v, LEAD(v, 1, -1) AS lead_v."""
    return _over_g_by_id(
        False,
        [
            PartitionExpr.lag_default("v", 1, _i64(0)).with_alias("lag_v"),
            PartitionExpr.lead_default("v", 1, _i64(-1)).with_alias("lead_v"),
        ],
    )


def _lag_lead_null_default() raises -> LogicalPlan:
    """LAG(v, 1, NULL) AS lag_v, LEAD(v, 1, NULL) AS lead_v."""
    return _over_g_by_id(
        False,
        [
            PartitionExpr.lag_default(
                "v", 1, ScalarValue.null(DType.int64)
            ).with_alias("lag_v"),
            PartitionExpr.lead_default(
                "v", 1, ScalarValue.null(DType.int64)
            ).with_alias("lead_v"),
        ],
    )


def _lag_lead_offset_2() raises -> LogicalPlan:
    """LAG(v, 2, 0) AS lag2_v, LEAD(v, 2) AS lead2_v."""
    return _over_g_by_id(
        False,
        [
            PartitionExpr.lag_default("v", 2, _i64(0)).with_alias("lag2_v"),
            PartitionExpr.lead("v", 2).with_alias("lead2_v"),
        ],
    )


def _lag_desc() raises -> LogicalPlan:
    """LAG(v, 1, 0) AS lag_v OVER (PARTITION BY g ORDER BY id DESC)."""
    return _over_g_by_id(
        True, [PartitionExpr.lag_default("v", 1, _i64(0)).with_alias("lag_v")]
    )


def _lag_non_nullable_input() raises -> LogicalPlan:
    """LAG(g, 1, 0) AS lag_g_d, LAG(g) AS lag_g, over the non-nullable g."""
    return _over_g_by_id(
        False,
        [
            PartitionExpr.lag_default("g", 1, _i64(0)).with_alias("lag_g_d"),
            PartitionExpr.lag("g").with_alias("lag_g"),
        ],
    )


def _over_rank_rows(
    var order_key: String, desc: Bool, var fns: List[PartitionExpr]
) raises -> LogicalPlan:
    """rank_rows with `fns` OVER (PARTITION BY g ORDER BY order_key)."""
    return LogicalPlan.partition_by(
        [String("g")], [order_key^], [desc], fns^, scan(rank_rows())
    )


def _rank_fns() -> List[PartitionExpr]:
    return [
        PartitionExpr.rank().with_alias("rk"),
        PartitionExpr.dense_rank().with_alias("dr"),
    ]


def _rank_dense_rank_ties() raises -> LogicalPlan:
    """RANK AS rk, DENSE_RANK AS dr OVER (PARTITION BY g ORDER BY o)."""
    return _over_rank_rows(String("o"), False, _rank_fns())


def _rank_desc() raises -> LogicalPlan:
    """RANK AS rk, DENSE_RANK AS dr OVER (PARTITION BY g ORDER BY o DESC)."""
    return _over_rank_rows(String("o"), True, _rank_fns())


def _row_number_peers_as_set() raises -> LogicalPlan:
    """g, o, ROW_NUMBER() OVER (PARTITION BY g ORDER BY o) AS rn: id is
    projected away, so peers compare as a set (§9.3)."""
    var w = _over_rank_rows(
        String("o"), False, [PartitionExpr.row_number().with_alias("rn")]
    )
    var e = ExprArray()
    e.append(Expr.col_ref("g"))
    e.append(Expr.col_ref("o"))
    e.append(Expr.col_ref("rn"))
    return LogicalPlan.project(e^, w^)


def _null_partition_key_one_partition() raises -> LogicalPlan:
    """ROW_NUMBER() OVER (PARTITION BY g ORDER BY id) AS rn."""
    return _over_rank_rows(
        String("id"), False, [PartitionExpr.row_number().with_alias("rn")]
    )


def cases() -> List[Case]:
    return [
        Case.hand("lag_lead_no_default", SHARD, _lag_lead_no_default, CanonPolicy.unordered()),
        Case.hand("lag_lead_default", SHARD, _lag_lead_default, CanonPolicy.unordered()),
        Case.hand("lag_lead_null_default", SHARD, _lag_lead_null_default, CanonPolicy.unordered()),
        Case.hand("lag_lead_offset_2", SHARD, _lag_lead_offset_2, CanonPolicy.unordered()),
        Case.hand("lag_desc", SHARD, _lag_desc, CanonPolicy.unordered()),
        Case.hand("lag_non_nullable_input", SHARD, _lag_non_nullable_input, CanonPolicy.unordered()),
        Case.hand("rank_dense_rank_ties", SHARD, _rank_dense_rank_ties, CanonPolicy.unordered()),
        Case.hand("rank_desc", SHARD, _rank_desc, CanonPolicy.unordered()),
        Case.hand("row_number_peers_as_set", SHARD, _row_number_peers_as_set, CanonPolicy.unordered()),
        Case.hand("null_partition_key_one_partition", SHARD, _null_partition_key_one_partition, CanonPolicy.unordered()),
    ]
