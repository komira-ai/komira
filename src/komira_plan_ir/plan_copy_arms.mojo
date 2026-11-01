# =============================================================================
# plan_copy_arms — the per-tag arms of `plan_helpers._copy_plan_body`
# =============================================================================
#
# `_copy_plan` and `_copy_plan_body` recurse into each other once per plan
# level. With every arm inline, `_copy_plan_body` carried the stack slots of
# all twelve arms in one frame: 120,688 bytes at -O0, the build a coverage run
# uses. A 64-relation join chain (`test_optimizer_reorder_paths`, the reorder
# relation-limit boundary) then needed more than the 8 MiB stack and the test
# died with SIGSEGV under kcov. Each arm is a function of its own, so a level
# of the recursion holds `_copy_plan_body`'s dispatch plus the one arm it
# runs. The code of each arm is unchanged.
#
# This module and `plan_helpers.mojo` import each other: the arms recurse
# through `_copy_plan`, and `_copy_plan_body` calls the arms.
# =============================================================================

from std.memory import OwnedPointer
from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_expr.udf_data import UdfData
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_stats.table_stats import TableStats
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_ir.plan_helpers import (
    _copy_plan,
    _copy_schema,
    _copy_expr_array,
    _copy_agg_expr_array,
)


def _copy_scan_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_SCAN` arm of `_copy_plan_body`."""
    # Route the source identity through
    # `SourceVariant.copy()` (refcount-bumps an InMemorySource's
    # ArcPointer[Slab[RecordBatch]] without buffer byte-copy); the
    # InMemorySource arm of the SourceVariant carries the batch payload.
    var proj_copy: Optional[List[String]] = None
    if plan._scan.value()[].projection:
        proj_copy = plan._scan.value()[].projection.value().copy()
    var filter_copy: Optional[Expr] = None
    if plan._scan.value()[].filter:
        filter_copy = plan._scan.value()[].filter.value().copy()
    var full_schema: Schema
    if plan._scan.value()[].schema:
        full_schema = _copy_schema(plan._scan.value()[].schema.value())
    else:
        full_schema = _copy_schema(plan.output_schema)
    var rc_copy: Optional[Int] = None
    if plan._scan.value()[].row_count:
        rc_copy = plan._scan.value()[].row_count.value()
    var ts_copy: Optional[TableStats] = None
    if plan._scan.value()[].table_stats:
        ts_copy = Optional[TableStats](plan._scan.value()[].table_stats.value().copy())
    # Preserve the scan's
    # `source_kind` across the deep-copy rebuild (the plan-compile cache
    # `.copy()` and every optimizer copy route here). Without threading
    # the kind the copy would reset it to COLUMNAR and a routing predicate
    # would misread the copied scan.
    return LogicalPlan.scan_from_source(
        plan._scan.value()[].source.copy(),
        full_schema^,
        proj_copy^,
        filter_copy^,
        rc_copy^,
        ts_copy^,
        plan._scan.value()[].source_kind,
        plan._scan.value()[].boundedness,
    )


def _copy_filter_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_FILTER` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._filter.value()[].child[])
    var pred = plan._filter.value()[].predicate.copy()
    # ★★ THE UDF SNAPSHOT IS PRESERVED.
    #
    # A copy of a UDF-carrying Filter that drops `udf` comes back WITHOUT
    # the customer's function — and `FilterData.predicate` on that path is
    # the `lit(true)` PLACEHOLDER the UDF path stamps, so the copy would be
    # a node that returns EVERY ROW and says nothing.
    #
    # ⚠ THE BLAST RADIUS IS NOT PUSHDOWN. `_copy_plan` is called from many
    # sites across the optimizer rule modules plus
    # `EngineContext.explain_analyze`, and every `_take_*_child` helper in
    # plan_helpers.mojo routes through it, so ANY pass that copies a subtree
    # would drop the UDF. Pinned by the optimizer UDF-opacity tests.
    if plan._filter.value()[].has_udf():
        return LogicalPlan.filter_with_udf(
            pred^,
            child^,
            OwnedPointer[UdfData](
                plan._filter.value()[].udf.value()[].copy()
            ),
        )
    return LogicalPlan.filter(pred^, child^)


def _copy_project_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_PROJECT` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._project.value()[].child[])
    var exprs = _copy_expr_array(plan._project.value()[].exprs)
    # Preserve the
    # `is_cse_introduced` barrier flag across plan copies.
    # `push_predicates_down` reads it to skip pushing past a
    # CSE-materializer Project; dropping it silently would let
    # predicates leak below a synthetic Project and dangle the
    # `_cse_*` ColRef target.
    var cse_flag = plan._project.value()[].is_cse_introduced
    # ★★ THE UDF SNAPSHOT IS PRESERVED. See `_copy_filter_node`. On a
    # Project a dropped payload is worse to diagnose: `ProjectData.exprs`
    # on the UDF path are PLACEHOLDER col-refs, so the copy would be a
    # valid-looking projection of the wrong columns rather than an
    # obviously empty node.
    if plan._project.value()[].has_udf():
        return LogicalPlan.project_with_udf(
            exprs^,
            child^,
            OwnedPointer[UdfData](
                plan._project.value()[].udf.value()[].copy()
            ),
            cse_flag,
        )
    return LogicalPlan.project(exprs^, child^, cse_flag)


def _copy_aggregate_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_AGGREGATE` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._aggregate.value()[].child[])
    var gb = _copy_expr_array(plan._aggregate.value()[].group_by)
    var aggs = _copy_agg_expr_array(plan._aggregate.value()[].agg_exprs)
    # The recorded mode is a decision, not a derivable fact: a copy that
    # dropped it would turn a PARTIAL into an UNSET (SINGLE) aggregate.
    var agg_mode = plan._aggregate.value()[].mode
    # ★★ THE UDF SNAPSHOT IS PRESERVED. See `_copy_filter_node`.
    if plan._aggregate.value()[].has_udf():
        return LogicalPlan.aggregate_with_udf(
            gb^,
            aggs^,
            child^,
            OwnedPointer[UdfData](
                plan._aggregate.value()[].udf.value()[].copy()
            ),
            agg_mode,
        )
    return LogicalPlan.aggregate(gb^, aggs^, child^, agg_mode)


def _copy_join_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_JOIN` arm of `_copy_plan_body`."""
    var left = _copy_plan(plan._join.value()[].left[])
    var right = _copy_plan(plan._join.value()[].right[])
    # Preserve algo_hint across plan copies. Without this,
    # `_copy_plan` defaults algo_hint to JOIN_ALGO_AUTO and loses explicit
    # HASH/SORT_MERGE choices set by the caller (DataFrame.join algo=,
    # the auto-select rule in _compile_join, etc).
    # Also preserve `residual` (non-equi / range `predicate=`
    # condition) across plan copies — dropping it silently loses the
    # join condition.
    # And preserve the recorded `build_side` and `adaptive_allowed`: a
    # copy that dropped them would silently hand the build back to the
    # right input.
    var join_resid: Optional[OwnedPointer[Expr]] = None
    if plan._join.value()[].has_residual():
        join_resid = OwnedPointer(plan._join.value()[].residual.value()[].copy())
    var build_side = plan._join.value()[].build_side
    var adaptive = plan._join.value()[].adaptive_allowed
    return LogicalPlan.join(
        left^,
        right^,
        plan._join.value()[].left_on.copy(),
        plan._join.value()[].right_on.copy(),
        plan._join.value()[].join_type,
        plan._join.value()[].algo_hint,
        join_resid^,
        build_side,
        adaptive,
    )


def _copy_sort_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_SORT` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._sort.value()[].child[])
    # ⛔ CARRY THE
    # EXPLICIT NULL PLACEMENT. `nulls_first` is the LAST, OPTIONAL argument
    # of `LogicalPlan.sort`/`.topn`, so omitting it COMPILES, RUNS, and
    # silently re-derives the DEFAULT placement
    # (`null_order_policy.derived_nulls_first`) — the SAME
    # PLAN SHAPE carrying a DIFFERENT ORDER BY. `_copy_plan` is the generic
    # deep copy the optimizer rule modules reach, so it is the highest-fanout
    # dropper in the tree; it is stated in full here and named by tag at the
    # other rebuild sites.
    #
    # ⚠ BOUND TO A LOCAL RATHER THAN SPELLED INSIDE THE CALL, matching the
    # `ref ld` binds on the LIMIT arms: a third walk of the same
    # `plan._sort.value()[]` chain inside one call expression is the shape
    # that bit `.n`/`.offset` on Mojo 1.0.0.
    var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
    return LogicalPlan.sort(
        plan._sort.value()[].keys.copy(),
        plan._sort.value()[].descending.copy(),
        child^,
        nf_copy^,
    )


def _copy_limit_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_LIMIT` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._limit.value()[].child[])
    # Forward the RANGE offset, don't drop it on rebuild.
    return LogicalPlan.limit(
        plan._limit.value()[].n, child^, offset=plan._limit.value()[].offset
    )


def _copy_distinct_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_DISTINCT` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._distinct.value()[].child[])
    var cols: Optional[List[String]] = None
    if plan._distinct.value()[].columns:
        cols = plan._distinct.value()[].columns.value().copy()
    return LogicalPlan.distinct(cols^, child^)


def _copy_topn_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_TOPN` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._topn.value()[].child[])
    # Carry the EXPLICIT NULL
    # placement; omitting it silently re-derives the DEFAULT
    # (`null_order_policy.derived_nulls_first`).
    var nf_copy = Optional(plan._topn.value()[].nulls_first.copy())
    return LogicalPlan.topn(
        plan._topn.value()[].keys.copy(),
        plan._topn.value()[].descending.copy(),
        plan._topn.value()[].n,
        child^,
        nf_copy^,
    )


def _copy_partition_by_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_PARTITION_BY` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._partition_by.value()[].child[])
    var pk = plan._partition_by.value()[].partition_keys.copy()
    var ok = plan._partition_by.value()[].order_keys.copy()
    var desc = plan._partition_by.value()[].descending.copy()
    var exprs = List[PartitionExpr]()
    for i in range(len(plan._partition_by.value()[].partition_exprs)):
        exprs.append(plan._partition_by.value()[].partition_exprs[i].copy())
    # `partition_by()` raises for unknown PartitionExpr func tags. On a copy
    # path the input is already valid, so the raise is unreachable -- but
    # a handler that returned `LogicalPlan(plan.tag, ...)` would answer an
    # "unreachable" case by producing the exact SHELL this function exists
    # never to produce (and `_copy_plan`'s post-condition would then report
    # a dropped payload instead of the PartitionExpr the factory rejected).
    # `_copy_plan` is a `def`, so it simply propagates.
    return LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, child^)


def _copy_partition_topn_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_PARTITION_TOPN` arm of `_copy_plan_body`."""
    var child = _copy_plan(plan._partition_topn.value()[].child[])
    # Preserve func + over_fetch_k across deep copy.
    # Preserve output_rank_col_name across
    # deep copy. Optional[String] requires explicit Some/None branch
    # construction (no auto-derive sentinel).
    var rank_col_copy: Optional[String] = None
    if plan._partition_topn.value()[].output_rank_col_name:
        rank_col_copy = String(
            plan._partition_topn.value()[].output_rank_col_name.value()
        )
    return LogicalPlan.partition_topn(
        plan._partition_topn.value()[].partition_keys.copy(),
        plan._partition_topn.value()[].sort_keys.copy(),
        plan._partition_topn.value()[].descending.copy(),
        plan._partition_topn.value()[].k,
        child^,
        plan._partition_topn.value()[].func,
        plan._partition_topn.value()[].over_fetch_k,
        rank_col_copy^,
    )


def _copy_asof_join_node(plan: LogicalPlan) raises -> LogicalPlan:
    """The `PLAN_ASOF_JOIN` arm of `_copy_plan_body`."""
    # AsofJoin deep copy.
    ref aj = plan._asof_join.value()[]
    var left = _copy_plan(aj.left[])
    var right = _copy_plan(aj.right[])
    return LogicalPlan.asof_join(
        left^, right^,
        aj.left_keys.copy(),
        aj.right_keys.copy(),
        aj.left_asof,
        aj.right_asof,
        aj.strategy,
        aj.tolerance,
        aj.left_sort_keys.copy(),
        aj.left_sort_desc.copy(),
        aj.right_sort_keys.copy(),
        aj.right_sort_desc.copy(),
    )
