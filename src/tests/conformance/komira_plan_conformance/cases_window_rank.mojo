# =============================================================================
# komira_plan_conformance/cases_window_rank.mojo -- shard window_rank.
# =============================================================================
#
# Window functions, citing query semantics §9.4 and §9.5 (LAG and LEAD),
# §4.1 and §9.6 (the window ORDER BY's placement), §4.8 and §8.19. Over
# dataset window_rows (partitions g = 1: ids 1 to 3, v = 10, NULL, 30;
# g = 2: ids 4, 5, v = 40, 50; g = 3: id 6, v = 60), PARTITION BY g ORDER BY
# id: LAG and LEAD with and without a default, an explicit NULL default, an
# offset of 2, and a descending order key. Every order key here is total
# within its partition, so which row is "previous" is fixed (§9.3). Every
# expectation is HAND, its derivation in the .tsv. A PARTITION_BY root is not
# a SORT, so every case compares its rows as a multiset (§4.8).
#
# Types. The result-type table (§8) has no row for LAG or LEAD. Every value
# of LAG(v) / LEAD(v) is a cell of v, the default, or NULL (§9.4); v is
# INT64 and every default here is an INT64 literal (§8.19), so the column is
# INT64 under any rule. It is nullable by §8's default (no row exempts it),
# and v is nullable, so the plan's declaration agrees.
#
# This shard holds no ranking function, no RANGE aggregate and no NULL
# partition or order key yet. The document has no §8 row for ROW_NUMBER,
# RANK, DENSE_RANK or a windowed SUM, and by its default every such result
# is nullable while komira_plan_ir declares them non-nullable; nor does it
# say whether a NULL partition key forms one partition (§2.4 covers grouping
# and DISTINCT). Those cases wait for the document.
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
# =============================================================================

from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import LogicalPlan

from .plan_case import Case
from .datasets import scan, window_rows

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


def cases() -> List[Case]:
    return [
        Case.hand("lag_lead_no_default", SHARD, _lag_lead_no_default, CanonPolicy.unordered()),
        Case.hand("lag_lead_default", SHARD, _lag_lead_default, CanonPolicy.unordered()),
        Case.hand("lag_lead_null_default", SHARD, _lag_lead_null_default, CanonPolicy.unordered()),
        Case.hand("lag_lead_offset_2", SHARD, _lag_lead_offset_2, CanonPolicy.unordered()),
        Case.hand("lag_desc", SHARD, _lag_desc, CanonPolicy.unordered()),
    ]
