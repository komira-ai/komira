# =============================================================================
# resolve_scalar_subqueries.mojo
# =============================================================================
#
# Compile-time pass that resolves every UNCORRELATED scalar subquery
# (`EXPR_CORRELATED_SUBQUERY` whose `kind == CORR_KIND_SCALAR` AND has NO
# `outer_refs`) to an `EXPR_LITERAL` holding its single-row single-column
# ScalarValue. The inner plan is executed once, outside komira_optimizer, and
# its value bound in a `ScalarDepTable`; the optimizer itself executes nothing.
#
# Algorithm ("execute-once + literal-inline"):
#   1. Walk the LogicalPlan. At every Expr-bearing node (Filter, Project,
#      and the metadata-only passthroughs Sort/Limit/Distinct/TopN), walk
#      the Expr tree and COLLECT each uncorrelated SCALAR subquery as a
#      `ScalarSubquerySite{inner_plan_clone, inner_hash}`.
#   2. (Driver -- see below.) For each collected site:
#        a. inner_hash = inner_plan.structural_hash() -- the dependency key.
#        b. If the `ScalarDepTable` binds that key, use the bound
#           ScalarValue (one binding serves every occurrence).
#        c. Otherwise record a request for the inner plan and leave the
#           plan unchanged. The caller this is designed for (not in this
#           tree) executes the request, checks the result is 1 column and at
#           most 1 row (`ScalarSubqueryMultipleRows` if > 1 row; 0 rows ->
#           typed NULL, as SQL `x = (SELECT ... WHERE false)` -> `x = NULL`),
#           binds the value and runs the passes again.
#   3. Re-walk the plan and SPLICE `Expr.literal(scalars[i])` in place of
#      the i-th collected subquery (lockstep with the Phase-1 enumeration
#      order). Correlated scalar subqueries (`len(outer_refs) > 0`) are
#      LEFT UNCHANGED -- `flatten_dependent_joins`
#      lowers them to JOIN_LEFT + agg-sink.
#
# =============================================================================
# Module layering: execution stays outside the optimizer
# =============================================================================
#
# Executing the inner plan needs an executor, and an executor sits above the
# optimizer, so the optimizer cannot call one (a reverse import is a layering
# inversion). The optimizer therefore executes nothing. It has the same
# 3-phase split as `optimizer_scalar_broadcast`: the two RECURSIVE walkers
# (collect, rewrite) are PURE + NON-PARAMETRIC and live HERE in
# `komira_optimizer`; the DRIVER, a FLAT non-parametric for-loop in
# `komira_optimizer/optimizer_resolve_scalar_subqueries.mojo`, looks each
# site up in a `ScalarDepTable`, folding on a hit and recording a request on
# a miss. No function is parametric or reaches a FileHandle, so the
# AOT-link monomorphizer never enters its quadratic-blowup regime.
#
# DuckDB reference (`src/planner/binder/query_node/plan_subquery.cpp:77-153`,
# `SubqueryType::SCALAR` uncorrelated arm): DuckDB lowers an uncorrelated
# scalar subquery to `Aggregate(first(col), count_star())` + a
# `CASE WHEN count > 1 THEN error('...single row') ELSE first END`
# projection, cross-joined onto the outer plan. We borrow the two
# *semantic* primitives -- (1) >1-row -> error; (2) 0-row -> NULL -- but
# evaluate eagerly at compile time (the subquery is uncorrelated, so it is
# a fixed value) and inline the literal, which is strictly cheaper than a
# CrossProduct + delim-style plumbing.
#
# The v0.3 Rust planner carried correlated-subquery
# flattening (`scalar_subquery_to_join.rs`) but NO uncorrelated-scalar
# eager-fold pass; this is a v0.4 addition.
#
# Dedup: the dependency key is `inner_plan.structural_hash()`, so a
# subquery that appears N times is one request and one binding (see
# `optimizer_scalar_deps.ScalarDepTable`). This module keeps no cache of
# its own, so nothing here outlives one call.
# =============================================================================

from std.collections import Optional, Dict, List

from komira_collections.slab import Slab

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_IN_LIST,
    EXPR_CORRELATED_SUBQUERY,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    CORR_KIND_SCALAR,
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
)
from komira_plan_ir.corr_subquery import corr_data_inner_plan_ref
from komira_plan_expr.scalar_value import ScalarValue


# Public error-name prefix for the >1-row HALT-condition. The caller that
# executes the request is designed to raise
# `Error(SCALAR_SUBQUERY_MULTIPLE_ROWS + ": ...")`; tests assert on the prefix.
comptime SCALAR_SUBQUERY_MULTIPLE_ROWS: String = "ScalarSubqueryMultipleRows"


# =============================================================================
# Helper: is this Expr an UNCORRELATED scalar subquery?
# =============================================================================


@always_inline
def _is_uncorrelated_scalar_subquery(expr: Expr) -> Bool:
    """True iff `expr.tag == EXPR_CORRELATED_SUBQUERY` AND
    `kind == CORR_KIND_SCALAR` AND `len(outer_refs) == 0`."""
    if expr.tag != EXPR_CORRELATED_SUBQUERY:
        return False
    ref cs = expr._corr_subq.value()[]
    return cs.kind == CORR_KIND_SCALAR and len(cs.outer_refs) == 0


# =============================================================================
# Expr walkers -- COUNT (observability, kept for the detection tests)
# =============================================================================


def _count_uncorrelated_scalar_in_expr(expr: Expr) raises -> Int:
    """Recursively count uncorrelated SCALAR `EXPR_CORRELATED_SUBQUERY`
    Exprs. Walk-coverage mirrors `_collect_scalar_subquery_sites_in_expr`
    EXACTLY so the count is a faithful pre-count of what the rewrite path
    will substitute.
    """
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        if _is_uncorrelated_scalar_subquery(expr):
            return 1
        return 0
    if expr.tag == EXPR_BINARY_OP:
        return (
            _count_uncorrelated_scalar_in_expr(expr.binary_left_ref())
            + _count_uncorrelated_scalar_in_expr(expr.binary_right_ref())
        )
    if expr.tag == EXPR_UNARY_OP:
        return _count_uncorrelated_scalar_in_expr(expr.unary_child_ref())
    if expr.tag == EXPR_CAST:
        return _count_uncorrelated_scalar_in_expr(expr.cast_child_ref())
    if expr.tag == EXPR_ALIAS:
        return _count_uncorrelated_scalar_in_expr(expr.alias_child_ref())
    if expr.tag == EXPR_STRING_OP:
        return _count_uncorrelated_scalar_in_expr(expr.string_op_child_ref())
    if expr.tag == EXPR_IN_LIST:
        return _count_uncorrelated_scalar_in_expr(expr.in_list_child_ref())
    if expr.tag == EXPR_AGG_FN:
        return _count_uncorrelated_scalar_in_expr(expr.agg_fn_child_ref())
    return 0


def _count_uncorrelated_scalar_in_plan(plan: LogicalPlan) raises -> Int:
    """Walk the plan counting uncorrelated SCALAR subqueries in every
    Filter predicate / Project expr. Recursion-coverage mirrors
    `_collect_scalar_subquery_sites` EXACTLY.
    """
    var n = 0
    if plan.tag == PLAN_FILTER:
        n += _count_uncorrelated_scalar_in_expr(plan.filter_data_ref().predicate)
        n += _count_uncorrelated_scalar_in_plan(plan.filter_data_ref().child[])
    elif plan.tag == PLAN_PROJECT:
        ref pj = plan.project_data_ref()
        for i in range(len(pj.exprs)):
            n += _count_uncorrelated_scalar_in_expr(pj.exprs[i])
        n += _count_uncorrelated_scalar_in_plan(pj.child[])
    elif plan.tag == PLAN_SORT:
        n += _count_uncorrelated_scalar_in_plan(plan.sort_data_ref().child[])
    elif plan.tag == PLAN_LIMIT:
        n += _count_uncorrelated_scalar_in_plan(plan.limit_data_ref().child[])
    elif plan.tag == PLAN_DISTINCT:
        n += _count_uncorrelated_scalar_in_plan(plan.distinct_data_ref().child[])
    elif plan.tag == PLAN_TOPN:
        n += _count_uncorrelated_scalar_in_plan(plan.topn_data_ref().child[])
    # Aggregate / Join / PartitionBy / PartitionTopN / Scan / Union /
    # ViewRef: leaf for this pass (a subquery deeper inside one of those
    # is neither counted nor resolved here).
    return n


# =============================================================================
# Public API -- observability (consumed by the detection tests)
# =============================================================================


def find_uncorrelated_scalar_subqueries(plan: LogicalPlan) raises -> Int:
    """Count `EXPR_CORRELATED_SUBQUERY` Exprs with kind == CORR_KIND_SCALAR
    AND len(outer_refs) == 0 anywhere this pass's rewrite path would
    reach. Pure observability helper -- the active resolve+inline path is
    the driver `resolve_scalar_subqueries_rewrite`.
    """
    return _count_uncorrelated_scalar_in_plan(plan)


def resolve_scalar_subqueries(var plan: LogicalPlan) raises -> LogicalPlan:
    """No-execution form (kept for the detection tests + any
    caller that has no `ScalarDepTable`). It returns the plan unchanged.

    The ACTIVE pass -- which inlines the literal for each uncorrelated
    inner plan -- is the non-parametric driver
    `komira_optimizer.optimizer_resolve_scalar_subqueries.resolve_scalar_subqueries_rewrite`.
    It takes the `ScalarDepTable` the executing caller fills, folds each site whose
    value is bound and requests the rest. `flatten_dependent_joins` has no
    uncorrelated arm: with no outer_refs its hoist derives no join keys,
    so a still-present uncorrelated SCALAR would become a keyless LEFT
    join over an ungrouped Aggregate -- so a plan is designed to pass
    through that driver, with every site bound, before flatten runs.
    """
    return plan^


# =============================================================================
# Phase 1 -- pure, non-parametric site collector (recursive; no FileHandle)
# =============================================================================


struct ScalarSubquerySite(Movable):
    """One uncorrelated SCALAR subquery occurrence whose inner plan is
    executed once (outside komira_optimizer) and whose Expr node the rewrite walker will
    replace with `Expr.literal(...)`.

    Lifetime bounded by one `resolve_scalar_subqueries_rewrite` call: the
    `Slab[ScalarSubquerySite]` holding these is built in Phase 1, consumed
    in Phases 2-3, dropped at the driver's function exit. Movable-only
    because `LogicalPlan` is Movable-only; stored in `Slab[...]` (same
    shape as `ScalarBroadcastSite` in `optimizer_scalar_broadcast.mojo`).
    """

    var inner_plan: LogicalPlan
    var inner_hash: UInt64

    def __init__(out self, var inner_plan: LogicalPlan, inner_hash: UInt64):
        self.inner_plan = inner_plan^
        self.inner_hash = inner_hash


def _collect_scalar_subquery_sites_in_expr(
    expr: Expr,
    mut sites: Slab[ScalarSubquerySite],
) raises:
    """Walk the Expr tree, appending one `ScalarSubquerySite` (with a
    deep-clone of the inner plan + its structural hash) per uncorrelated
    SCALAR subquery, in left-to-right pre-order. NON-PARAMETRIC; does NOT
    reach FileHandle. Coverage MUST match `_rewrite_scalar_subquery_in_expr`
    (the lockstep invariant).
    """
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        if _is_uncorrelated_scalar_subquery(expr):
            ref cs = expr._corr_subq.value()[]
            var inner_clone = corr_data_inner_plan_ref(cs).copy()
            var h = inner_clone.structural_hash()
            sites.append(ScalarSubquerySite(inner_clone^, h))
        # A correlated SCALAR (or non-SCALAR) corr-subquery: leaf for this
        # pass -- the inner plan is not walked (flatten handles it).
        return
    if expr.tag == EXPR_BINARY_OP:
        _collect_scalar_subquery_sites_in_expr(expr.binary_left_ref(), sites)
        _collect_scalar_subquery_sites_in_expr(expr.binary_right_ref(), sites)
        return
    if expr.tag == EXPR_UNARY_OP:
        _collect_scalar_subquery_sites_in_expr(expr.unary_child_ref(), sites)
        return
    if expr.tag == EXPR_CAST:
        _collect_scalar_subquery_sites_in_expr(expr.cast_child_ref(), sites)
        return
    if expr.tag == EXPR_ALIAS:
        _collect_scalar_subquery_sites_in_expr(expr.alias_child_ref(), sites)
        return
    if expr.tag == EXPR_STRING_OP:
        _collect_scalar_subquery_sites_in_expr(expr.string_op_child_ref(), sites)
        return
    if expr.tag == EXPR_IN_LIST:
        _collect_scalar_subquery_sites_in_expr(expr.in_list_child_ref(), sites)
        return
    if expr.tag == EXPR_AGG_FN:
        _collect_scalar_subquery_sites_in_expr(expr.agg_fn_child_ref(), sites)
        return
    # Leaf (col_ref / col_idx / literal) or a container not on the
    # walk-set (when / window_fn): stop.


def _collect_scalar_subquery_sites(
    imm plan: LogicalPlan,
    mut sites: Slab[ScalarSubquerySite],
) raises:
    """Walk the plan pre-order, collecting uncorrelated SCALAR subquery
    sites from every Filter predicate / Project expr. NON-PARAMETRIC; no
    FileHandle reach (the trap-safe recursive leg). Recursion-coverage
    MUST match `_rewrite_scalar_subquery_sites` EXACTLY.
    """
    if plan.tag == PLAN_FILTER:
        _collect_scalar_subquery_sites_in_expr(
            plan.filter_data_ref().predicate, sites
        )
        _collect_scalar_subquery_sites(plan.filter_data_ref().child[], sites)
        return
    if plan.tag == PLAN_PROJECT:
        ref pj = plan.project_data_ref()
        for i in range(len(pj.exprs)):
            _collect_scalar_subquery_sites_in_expr(pj.exprs[i], sites)
        _collect_scalar_subquery_sites(pj.child[], sites)
        return
    if plan.tag == PLAN_SORT:
        _collect_scalar_subquery_sites(plan.sort_data_ref().child[], sites)
        return
    if plan.tag == PLAN_LIMIT:
        _collect_scalar_subquery_sites(plan.limit_data_ref().child[], sites)
        return
    if plan.tag == PLAN_DISTINCT:
        _collect_scalar_subquery_sites(plan.distinct_data_ref().child[], sites)
        return
    if plan.tag == PLAN_TOPN:
        _collect_scalar_subquery_sites(plan.topn_data_ref().child[], sites)
        return
    # Other shapes (Aggregate / Join / Scan / PartitionBy / PartitionTopN
    # / Union / ViewRef): leaf for this pass.


# =============================================================================
# Phase 3 -- pure, non-parametric rewriter (recursive; no FileHandle)
# =============================================================================


def _rewrite_scalar_subquery_in_expr(
    expr: Expr,
    imm scalars: List[ScalarValue],
    mut next_idx: Int,
) raises -> Expr:
    """Rebuild the Expr tree, replacing each uncorrelated SCALAR subquery
    with `Expr.literal(scalars[next_idx])` and advancing `next_idx` --
    visited in the SAME pre-order as `_collect_scalar_subquery_sites_in_expr`.
    NON-PARAMETRIC. The tree is rebuilt rather than swapped in place, as
    `optimizer_scalar_broadcast._substitute_agg_fn` does.
    """
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        if _is_uncorrelated_scalar_subquery(expr):
            var lit = Expr.literal(scalars[next_idx].copy())
            next_idx += 1
            return lit^
        # Correlated / non-SCALAR: pass through unchanged.
        return expr.copy()
    if expr.tag == EXPR_BINARY_OP:
        var nl = _rewrite_scalar_subquery_in_expr(
            expr.binary_left_ref(), scalars, next_idx
        )
        var nr = _rewrite_scalar_subquery_in_expr(
            expr.binary_right_ref(), scalars, next_idx
        )
        return Expr.binary(expr.binary_op(), nl^, nr^)
    if expr.tag == EXPR_UNARY_OP:
        var nc = _rewrite_scalar_subquery_in_expr(
            expr.unary_child_ref(), scalars, next_idx
        )
        return Expr.unary(expr.unary_op(), nc^)
    if expr.tag == EXPR_CAST:
        var nc = _rewrite_scalar_subquery_in_expr(
            expr.cast_child_ref(), scalars, next_idx
        )
        return Expr.cast(nc^, expr.cast_target())
    if expr.tag == EXPR_ALIAS:
        var nc = _rewrite_scalar_subquery_in_expr(
            expr.alias_child_ref(), scalars, next_idx
        )
        return Expr.alias(nc^, expr.alias_name())
    if expr.tag == EXPR_STRING_OP:
        var nc = _rewrite_scalar_subquery_in_expr(
            expr.string_op_child_ref(), scalars, next_idx
        )
        return Expr.string_op(expr.string_op_type(), nc^, expr.string_op_pattern())
    if expr.tag == EXPR_IN_LIST:
        var nc = _rewrite_scalar_subquery_in_expr(
            expr.in_list_child_ref(), scalars, next_idx
        )
        return Expr.in_list_node(nc^, expr.in_list_values_ref().copy())
    if expr.tag == EXPR_AGG_FN:
        var nc = _rewrite_scalar_subquery_in_expr(
            expr.agg_fn_child_ref(), scalars, next_idx
        )
        return Expr.agg_fn(expr.agg_fn_op(), nc^)
    # Leaf or off-walk-set container: deep-copy unchanged.
    return expr.copy()


def _rewrite_exprs_in_array(
    imm exprs: ExprArray,
    imm scalars: List[ScalarValue],
    mut next_idx: Int,
) raises -> ExprArray:
    """Rebuild an ExprArray, rewriting each element in order."""
    var out = ExprArray()
    for i in range(len(exprs)):
        out.append(_rewrite_scalar_subquery_in_expr(exprs[i], scalars, next_idx))
    return out^


def _rewrite_scalar_subquery_sites(
    var plan: LogicalPlan,
    imm scalars: List[ScalarValue],
    mut next_idx: Int,
) raises -> LogicalPlan:
    """Re-walk the plan in lockstep with `_collect_scalar_subquery_sites`,
    splicing `Expr.literal(scalars[i])` for the i-th collected subquery.
    NON-PARAMETRIC; no FileHandle reach. Order-discipline: this walker
    MUST visit nodes / exprs in the exact pre-order `_collect_*` used so
    the shared `next_idx` counter advances in sync.
    """
    if plan.tag == PLAN_FILTER:
        ref fd = plan.filter_data_ref()
        var new_pred = _rewrite_scalar_subquery_in_expr(
            fd.predicate, scalars, next_idx
        )
        var new_child = _rewrite_scalar_subquery_sites(
            fd.child[].copy(), scalars, next_idx
        )
        return LogicalPlan.filter(new_pred^, new_child^)
    if plan.tag == PLAN_PROJECT:
        ref pj = plan.project_data_ref()
        var new_exprs = _rewrite_exprs_in_array(pj.exprs, scalars, next_idx)
        var new_child = _rewrite_scalar_subquery_sites(
            pj.child[].copy(), scalars, next_idx
        )
        return LogicalPlan.project(new_exprs^, new_child^)
    if plan.tag == PLAN_SORT:
        ref sd = plan.sort_data_ref()
        var new_child = _rewrite_scalar_subquery_sites(
            sd.child[].copy(), scalars, next_idx
        )
        # ORDNULL-SURVIVE: carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        return LogicalPlan.sort(
            sd.keys.copy(),
            sd.descending.copy(),
            new_child^,
            Optional(sd.nulls_first.copy()),
        )
    if plan.tag == PLAN_LIMIT:
        ref ld = plan.limit_data_ref()
        var n = ld.n
        var off = ld.offset
        var new_child = _rewrite_scalar_subquery_sites(
            ld.child[].copy(), scalars, next_idx
        )
        # Forward the RANGE offset, don't drop it on rebuild.
        return LogicalPlan.limit(n, new_child^, offset=off)
    if plan.tag == PLAN_DISTINCT:
        ref dd = plan.distinct_data_ref()
        var cols_copy: Optional[List[String]] = None
        if dd.columns:
            cols_copy = Optional(dd.columns.value().copy())
        var new_child = _rewrite_scalar_subquery_sites(
            dd.child[].copy(), scalars, next_idx
        )
        return LogicalPlan.distinct(cols_copy^, new_child^)
    if plan.tag == PLAN_TOPN:
        ref td = plan.topn_data_ref()
        var n = td.n
        var new_child = _rewrite_scalar_subquery_sites(
            td.child[].copy(), scalars, next_idx
        )
        # ORDNULL-SURVIVE: carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        return LogicalPlan.topn(
            td.keys.copy(),
            td.descending.copy(),
            n,
            new_child^,
            Optional(td.nulls_first.copy()),
        )
    # Other shapes: pass through unchanged (no subquery sites were
    # collected under them, so `next_idx` does not need to advance here).
    return plan^
