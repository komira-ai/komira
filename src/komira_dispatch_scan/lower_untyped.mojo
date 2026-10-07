# =============================================================================
# lower_untyped — the plan-shape predicates the untyped dispatcher routes on
# =============================================================================
#
# Three PREDICATE-ONLY functions (read-only over `LogicalPlan`):
#   - `_is_multi_file_parquet_scan(plan)` — a PLAN_SCAN over a ParquetSource
#     that spans several files or carries eager Hive partition columns.
#   - `route_plan_shape_row_streaming(plan)` — always False: there is no row
#     executor, so every plan takes the column path.
#   - `_has_row_source_signal(plan)` — whether any scan in the tree reads a
#     ROW source (`source_kind == SOURCE_KIND_ROW`).
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_JOIN,
    PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN, PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN, PLAN_UNION,
    PLAN_CAST_TO_VARCHAR,
    SOURCE_KIND_ROW,
)
from komira_scan_source.source_variant import SOURCE_VARIANT_PARQUET


def _is_multi_file_parquet_scan(imm plan: LogicalPlan) -> Bool:
    """True iff `plan` is a PLAN_SCAN over a ParquetSource that spans more than
    one file OR carries Hive partition columns. Single-file plain Parquet scans
    (and the lazy dir-scan Hive shape) return False.

    The lazy dir-scanning Hive shape is NOT union-classified — it carries a
    SINGLE un-enumerated base dir in `paths[0]` + `partition_cols` (so
    `is_partitioned()` would otherwise intercept it); instead it flows through
    as ONE SOURCE_PARQUET to the engine materialize site (which binds the
    pruned Hive discovery and lists only the surviving partitions). Flat
    multi-file (`is_multi_file()`, no partition cols) and EAGER Hive
    (`ParquetSource.partitioned`, hive_dir_scan False) return True.

    PREDICATE ONLY: read-only over `plan`.
    """
    if plan.tag != PLAN_SCAN or not plan._scan:
        return False
    ref scan_data = plan._scan.value()[]
    if scan_data.source.tag != SOURCE_VARIANT_PARQUET:
        return False
    if not scan_data.source._parquet:
        return False
    ref ps = scan_data.source._parquet.value()
    if ps.is_dir_scan_hive():
        return False
    return ps.is_multi_file() or ps.is_partitioned()


def route_plan_shape_row_streaming(imm plan: LogicalPlan) -> Bool:
    """ALWAYS False -- there is no row executor to route a plan at.

    The question it answers: should this plan go to a ROW executor instead of
    the column one? With no row executor, the answer is always no.

    ⚠ A ROW-SOURCE SIGNAL EXISTS AND ANSWERS TRUTHFULLY --
    `_has_row_source_signal` reads `scan.source_kind == SOURCE_KIND_ROW` -- so
    wiring it in here would COMPILE and would route those plans at an executor
    that does not exist. See the body.

    PREDICATE ONLY: does not mutate `plan` or perform any lowering.

    Args:
        plan: The optimized LogicalPlan that would be classified (read-only,
            and not consulted).

    Returns:
        False, unconditionally. Every plan -- row-SOURCE plans included -- goes
        to the column-untyped path, which is the only path there is.
    """
    # THERE IS NO ROW EXECUTOR. This predicate asked "should this plan go to
    # the ROW executor instead of the column one?", so False is the only answer
    # it can honestly give.
    #
    # ⛔ DO NOT ADD THE SIGNAL CHECK. `_has_row_source_signal` answers
    # truthfully, so wiring it in here would compile, and would route
    # those plans at an executor that does not exist. A row-SOURCE plan (CSV /
    # NDJSON) is served by the COLUMN path; carrying a ROW source signal is not
    # a reason to leave it.
    return False


def _has_row_source_signal(imm plan: LogicalPlan) -> Bool:
    """True iff the plan tree carries a ROW source signal anywhere: a
    `PLAN_SCAN` with `source_kind == SOURCE_KIND_ROW`. A pure column-only plan
    returns False."""
    # A row-kind scan source is row-streaming-eligible at the
    # producer end (CSV / NDJSON; auto-promoted to SOURCE_KIND_ROW).
    if plan.tag == PLAN_SCAN and plan._scan:
        if plan.scan_data_ref().source_kind == SOURCE_KIND_ROW:
            return True

    # Recurse into children (read-only — no copy / rebuild). Covers
    # single-child + multi-child (JOIN / ASOF_JOIN / UNION) shapes.
    var tag = plan.tag
    if tag == PLAN_FILTER and plan._filter:
        return _has_row_source_signal(plan.filter_data_ref().child[])
    if tag == PLAN_PROJECT and plan._project:
        return _has_row_source_signal(plan.project_data_ref().child[])
    if tag == PLAN_AGGREGATE and plan._aggregate:
        return _has_row_source_signal(plan.aggregate_data_ref().child[])
    if tag == PLAN_SORT and plan._sort:
        return _has_row_source_signal(plan.sort_data_ref().child[])
    if tag == PLAN_LIMIT and plan._limit:
        return _has_row_source_signal(plan.limit_data_ref().child[])
    if tag == PLAN_DISTINCT and plan._distinct:
        return _has_row_source_signal(plan.distinct_data_ref().child[])
    if tag == PLAN_TOPN and plan._topn:
        return _has_row_source_signal(plan.topn_data_ref().child[])
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        return _has_row_source_signal(plan.partition_by_data_ref().child[])
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return _has_row_source_signal(
            plan.partition_topn_data_ref().child[]
        )
    if tag == PLAN_CAST_TO_VARCHAR and plan._cast_to_varchar:
        return _has_row_source_signal(
            plan.cast_to_varchar_data_ref().child[]
        )
    if tag == PLAN_JOIN and plan._join:
        ref jd = plan.join_data_ref()
        if _has_row_source_signal(jd.left[]):
            return True
        return _has_row_source_signal(jd.right[])
    if tag == PLAN_ASOF_JOIN and plan._asof_join:
        ref ad = plan.asof_join_data_ref()
        if _has_row_source_signal(ad.left[]):
            return True
        return _has_row_source_signal(ad.right[])
    if tag == PLAN_UNION and plan._union:
        ref ud = plan.union_data_ref()
        for i in range(ud.num_children()):
            if _has_row_source_signal(ud.children[i][]):
                return True
        return False

    # PLAN_SCAN / PLAN_VIEW_REF / PLAN_CSE_REF leaves with no row signal,
    # and any node whose variant payload is unexpectedly absent: not eligible.
    return False
