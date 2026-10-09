# =============================================================================
# Optimizer rule: attach_hive_predicate
# Lazy Hive discovery: predicate attach at plan time.
# =============================================================================
#
# The COMPANION of `partition_prune_scans` for the lazy dir-scan Hive shape
# (`ParquetSource.dir_scan_hive`). Where `partition_prune_scans` prunes an
# EAGERLY-enumerated path list at plan time, this pass ATTACHES the Tier-1
# partition-prune POD to an UN-enumerated dir-scan source, so a reader that
# lists the base directory can list ONLY the surviving partitions.
#
# The pass expects the partition filter to be structurally available as
# `Filter(Scan)`, i.e. to run before filter pushdown. Two shapes are handled:
#
#   1. Filter(dir-scan-Hive Scan):
#        - split the filter via `split_partition_predicate(filter,
#          partition_cols, partition_types)` into the Tier-1 partition
#          predicate + the Tier-2 DATA residual.
#        - `pod_from_predicate(split.partition_predicate)` -> attach to the
#          scan's `hive_predicate` field.
#        - the Tier-2 residual stays on the Filter (it remains the
#          row-group / page pushdown). If EVERY conjunct was a partition
#          constraint, the residual is None and the Filter is collapsed to its
#          (now predicate-carrying) child Scan.
#
#   2. A bare dir-scan-Hive Scan with NO Filter above it (the un-filtered
#      read): attach `Some(PartitionPredicatePod.empty())`, which prunes
#      nothing.
#
# Idempotent: a scan that already carries `hive_predicate is Some` is left
# untouched; a plan with no dir-scan-Hive scans is returned structurally
# unchanged. EAGER Hive scans (`ParquetSource.partitioned`, hive_dir_scan
# False) are NOT touched here — they keep `partition_prune_scans`.
#
# Mutual exclusion with `partition_prune_scans`: that rule BAILS on the
# dir-scan-Hive shape (`is_dir_scan_hive()`), so the two passes never both
# fire on one scan.
#
# Mojo discipline: no UnsafePointer crosses a module boundary; the in-place
# rewrite mutates through `Optional[OwnedPointer[...]]` ref-mutation (same
# shape as `partition_prune_scans_inplace`).
# =============================================================================

from std.memory import OwnedPointer
from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema
from komira_plan_expr.expr import Expr
from komira_plan_stats.table_stats import TableStats
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ScanData,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
)
from komira_plan_expr.partition_pred_pod import PartitionPredicatePod
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
)
from komira_scan_planning.partition_predicate_split import split_partition_predicate
from komira_scan_planning.partition_pred_bridge import pod_from_predicate


# =============================================================================
# Public API
# =============================================================================


def attach_hive_predicate(var plan: LogicalPlan) raises -> LogicalPlan:
    """Top-level entry: attach the Tier-1 partition-prune POD to every lazy
    dir-scanning Hive Scan in `plan` (from the Filter above it, or `empty()`
    for an un-filtered read), carving the Tier-2 residual back onto the Filter.

    Idempotent: a plan with no dir-scan-Hive scans (the overwhelming common
    case — single file / flat multi-file / eager Hive) is returned structurally
    unchanged.
    """
    attach_hive_predicate_inplace(plan)
    return plan^


def attach_hive_predicate_inplace(mut plan: LogicalPlan) raises:
    """In-place mirror of `attach_hive_predicate`.

    At a Filter, attaches first and then recurses into the (possibly
    collapsed) child; at every other node, recurses into the children; at a
    Scan, attaches `empty()`. Recursion shape follows
    `partition_prune_scans_inplace`.
    """
    if plan.tag == PLAN_FILTER:
        # Attach the split predicate to a dir-scan-Hive Scan child FIRST — BEFORE
        # recursing — so the child Scan's predicate comes from THIS Filter's
        # split, not from the bare-scan `empty()` attach (which the PLAN_SCAN arm
        # would otherwise apply when the recursion reaches the Scan child first).
        _maybe_attach_over_filter(plan)
        # Recurse into the (possibly-collapsed) child for any DEEPER dir-scan
        # scans (Filter-over-Filter-over-Scan, etc.). A dir-scan Scan already
        # handled above is a no-op here (the idempotency guard).
        if plan.tag == PLAN_FILTER:
            attach_hive_predicate_inplace(plan._filter.value()[].child[])
        else:
            # The Filter collapsed to its child Scan (no residual) — recurse on
            # the now-Scan `plan` so any further structure is visited.
            attach_hive_predicate_inplace(plan)
    elif plan.tag == PLAN_PROJECT:
        attach_hive_predicate_inplace(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        attach_hive_predicate_inplace(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        attach_hive_predicate_inplace(plan._join.value()[].left[])
        attach_hive_predicate_inplace(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        attach_hive_predicate_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        attach_hive_predicate_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        attach_hive_predicate_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        attach_hive_predicate_inplace(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        attach_hive_predicate_inplace(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        attach_hive_predicate_inplace(plan._partition_topn.value()[].child[])
    elif plan.tag == PLAN_SCAN:
        # A bare dir-scan-Hive Scan reached WITHOUT a Filter parent (the
        # un-filtered read): attach Some(empty()). When the Scan
        # IS under a Filter, `_maybe_attach_over_filter` handles it BEFORE the
        # recursion reaches the Scan here (the Filter branch attaches first,
        # then recurses — so the predicate is already set and this is a
        # no-op via the idempotency guard).
        _maybe_attach_empty_to_bare_scan(plan)
    # PLAN_ASOF_JOIN: its children are not visited.


# =============================================================================
# The Filter -> dir-scan-Hive Scan attach
# =============================================================================


def _maybe_attach_over_filter(mut plan: LogicalPlan) raises:
    """If `plan` is a Filter directly over a lazy dir-scan-Hive Parquet Scan,
    split the filter, attach the Tier-1 POD to the scan, and carve the Tier-2
    residual back onto the Filter (collapsing the Filter if the residual is
    empty)."""
    # plan.tag == PLAN_FILTER (caller guarantees).
    # Bind the FilterData once. `child`, `scan` and `psrc` below
    # are projections of THIS origin; re-walking `plan._filter` to reach
    # `.predicate` would invalidate all three.
    ref fd = plan._filter.value()[]
    ref child = fd.child[]
    if child.tag != PLAN_SCAN or not child._scan:
        return
    ref scan = child._scan.value()[]
    if scan.source.tag != SOURCE_VARIANT_PARQUET:
        return
    if not scan.source._parquet:
        return
    ref psrc = scan.source._parquet.value()
    if not psrc.is_dir_scan_hive():
        return
    if psrc.hive_predicate:
        return  # already attached (idempotent).

    # Partition schema (parallel name / type lists for the split).
    var part_names = List[String]()
    var part_types = List[ArrowType]()
    for i in range(len(psrc.partition_cols)):
        part_names.append(String(psrc.partition_cols[i].name))
        part_types.append(psrc.partition_cols[i].arrow_type)

    # Split: Tier-1 partition predicate + Tier-2 residual.
    var split = split_partition_predicate(
        fd.predicate, part_names, part_types
    )
    var pod = pod_from_predicate(split.partition_predicate)

    # Reseat the scan's source with the POD attached.
    _reseat_scan_with_pod(child, pod^)

    # Carve the Tier-2 residual back onto the Filter (or collapse the Filter).
    if split.residual:
        plan._filter.value()[].predicate = split.residual.value().copy()
    else:
        # Every conjunct was a partition constraint -> the Filter is fully
        # consumed by the Tier-1 prune. Collapse `plan` to its (now
        # POD-carrying) child Scan.
        var child_plan = plan._filter.value()[].child[].copy()
        plan = child_plan^


def _maybe_attach_empty_to_bare_scan(mut plan: LogicalPlan) raises:
    """If `plan` is a bare dir-scan-Hive Scan with no predicate attached yet
    (the un-filtered read), attach
    `Some(PartitionPredicatePod.empty())`."""
    if not plan._scan:
        return
    ref scan = plan._scan.value()[]
    if scan.source.tag != SOURCE_VARIANT_PARQUET:
        return
    if not scan.source._parquet:
        return
    ref psrc = scan.source._parquet.value()
    if not psrc.is_dir_scan_hive():
        return
    if psrc.hive_predicate:
        return  # already attached.
    _reseat_scan_with_pod(plan, PartitionPredicatePod.empty())


# =============================================================================
# Scan reseating (preserve all other ScanData fields; swap the source)
# =============================================================================


def _stamp_fs_descriptor_on_scan(
    var plan: LogicalPlan, var fs_descriptor: FsDescriptorPod
) raises -> LogicalPlan:
    """Stamp `fs_descriptor` (scheme, bucket and `node_id`) onto the PARQUET
    scan reached by descending through Filter and Project nodes from the root
    of `plan`. Returns the plan with that scan's
    `ParquetSource.fs_descriptor` set.

    Only Filter and Project are descended (one child each); any other node,
    a scan node without scan data, and a non-parquet scan are left unchanged.
    Reseats the ParquetSource via the `with_fs_descriptor` copy, as
    `_reseat_scan_with_pod` does with `with_hive_predicate`."""
    _stamp_fs_descriptor_inplace(plan, fs_descriptor^)
    return plan^


def _stamp_fs_descriptor_inplace(
    mut plan: LogicalPlan, var fs_descriptor: FsDescriptorPod
) raises:
    if plan.tag == PLAN_SCAN:
        if not plan._scan:
            return
        ref scan = plan._scan.value()[]
        if scan.source.tag != SOURCE_VARIANT_PARQUET:
            return
        if not scan.source._parquet:
            return
        ref psrc = scan.source._parquet.value()
        var new_psrc = psrc.with_fs_descriptor(fs_descriptor)
        var proj_copy: Optional[List[String]] = None
        if scan.projection:
            proj_copy = Optional(scan.projection.value().copy())
        var filter_copy: Optional[Expr] = None
        if scan.filter:
            filter_copy = Optional(scan.filter.value().copy())
        var rc_copy: Optional[Int] = None
        if scan.row_count:
            rc_copy = Optional(scan.row_count.value())
        var ts_copy: Optional[TableStats] = None
        if scan.table_stats:
            ts_copy = Optional(scan.table_stats.value().copy())
        var schema_copy: Optional[Schema] = None
        if scan.schema:
            schema_copy = Optional(scan.schema.value().copy())
        var new_scan_data = ScanData(
            SourceVariant(new_psrc^),
            schema_copy^,
            proj_copy^,
            filter_copy^,
            rc_copy^,
            ts_copy^,
        )
        plan._scan = OwnedPointer(new_scan_data^)
    elif plan.tag == PLAN_FILTER and plan._filter:
        _stamp_fs_descriptor_inplace(
            plan._filter.value()[].child[], fs_descriptor^
        )
    elif plan.tag == PLAN_PROJECT and plan._project:
        _stamp_fs_descriptor_inplace(
            plan._project.value()[].child[], fs_descriptor^
        )


def _reseat_scan_with_pod(
    mut scan_plan: LogicalPlan, var pod: PartitionPredicatePod
) raises:
    """Replace `scan_plan`'s (PLAN_SCAN) ParquetSource with a copy carrying
    `hive_predicate = Some(pod)`, preserving every other ScanData field
    (schema / projection / filter / row_count / table_stats). Mirrors the
    reseat in `partition_prune_scans._maybe_prune_filter_over_scan`."""
    ref scan = scan_plan._scan.value()[]
    ref psrc = scan.source._parquet.value()
    var new_psrc = psrc.with_hive_predicate(pod^)

    var proj_copy: Optional[List[String]] = None
    if scan.projection:
        proj_copy = Optional(scan.projection.value().copy())
    var filter_copy: Optional[Expr] = None
    if scan.filter:
        filter_copy = Optional(scan.filter.value().copy())
    var rc_copy: Optional[Int] = None
    if scan.row_count:
        rc_copy = Optional(scan.row_count.value())
    var ts_copy: Optional[TableStats] = None
    if scan.table_stats:
        ts_copy = Optional(scan.table_stats.value().copy())
    var schema_copy: Optional[Schema] = None
    if scan.schema:
        schema_copy = Optional(scan.schema.value().copy())
    var new_scan_data = ScanData(
        SourceVariant(new_psrc^),
        schema_copy^,
        proj_copy^,
        filter_copy^,
        rc_copy^,
        ts_copy^,
    )
    scan_plan._scan = OwnedPointer(new_scan_data^)
