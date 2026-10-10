# =============================================================================
# scalar_subquery_decorrelate.mojo
# =============================================================================
#
# Compile-time pre-pass that DECORRELATES an UNCORRELATED scalar subquery
# (`EXPR_CORRELATED_SUBQUERY` with `kind == CORR_KIND_SCALAR` AND no
# `outer_refs`) whose inner plan is PROVABLY <= 1 row into a broadcast
# `JOIN_CROSS` against the node that uses it.
#
# Motivation (design goal — "multiple reads/writes go through the same
# compiler so we can optimize and just read once"):
#   The `resolve_scalar_subqueries` pass does MATERIALIZE-AND-SUBSTITUTE:
#   the inner plan is executed on its own by the executing caller (a
#   `ScalarDepTable` request; the caller is not in this tree) and its value
#   inlined as a literal. So `df.filter(col("c_acctbal") >
#   scalar_subquery(<agg over customer>))` scans `customer` TWICE — once for
#   the agg, once for the outer query — two physical plans, and a plan-CSE
#   cannot span them.
#
#   When the inner plan is provably single-row, we can instead lower it to a
#   broadcast CROSS join: the plan node that USES the subquery gets its child
#   replaced by `Join(CROSS, left=old_child, right=inner_aliased)`, and the
#   subquery Expr becomes `col_ref("__scalar_subq_N")`. Then a plan-CSE
#   (not in this tree) can dedup the base scan shared between the inner-agg
#   branch and the outer branch → ONE physical plan, in which `customer`
#   (Q22) / the germany-join (Q11) is read ONCE.
#
# "PROVABLY <= 1 row" predicate (conservative — fall through to
# materialize-and-substitute otherwise):
#   - `PLAN_AGGREGATE` with `len(group_by) == 0` (a global aggregate emits
#     exactly one row — q22's `avg(c_acctbal)`, q11's `sum(value)*0.0001`).
#   - `PLAN_LIMIT` with `n <= 1`.
#   - peer THROUGH a top-level `PLAN_PROJECT` / `PLAN_SORT` / `PLAN_DISTINCT`
#     (none change row count beyond what their child guarantees) — q11's
#     inner is `Project(Project(Aggregate(no-gb)))` (the `.agg(...).with_column
#     (threshold).select("threshold")` chain).
#   - anything else → NOT provably <= 1 row → leave the EXPR in the tree for
#     the existing materialize-and-substitute path (with its runtime
#     `ScalarSubqueryMultipleRows` guard).
#
# Dedup: if the SAME inner subquery (by `inner_plan.structural_hash()`)
# appears in multiple Expr sites under one node, build ONE CROSS join with
# multiple `col_ref("__scalar_subq_N")` refs — mirrors the by-hash dedup in
# `resolve_scalar_subqueries`.
#
# Schema bookkeeping: the CROSS join's output schema = `left.schema ++
# [the aliased 1-col field]` (the `LogicalPlan.join` factory does this for
# non-SEMI/ANTI joins). To keep the OWNING node's output schema STABLE
# (optimizer rules, the typed-schema mirror and a plan compiler that is not in
# this tree all key on the post-decorrelate schema), the rewritten node is
# wrapped in a
# trailing identity `Project` restoring the original output columns — the
# `__scalar_subq_N` columns never escape past the node that introduced them.
#
# Pass order: komira_optimizer has no driver that orders its passes. This
# pass is designed to run BEFORE `resolve_scalar_subqueries_rewrite` (so it
# claims the decorrelatable sites first; whatever's left goes to
# materialize-and-substitute), BEFORE `flatten_dependent_joins` (which only
# handles CORRELATED subqueries — outer_refs >= 1) and BEFORE plan-CSE (which
# is designed to run after every optimizer pass).
#
# DuckDB reference (`src/planner/subquery/flatten_dependent_join.cpp` +
# `plan_subquery.cpp:77-153`): an uncorrelated scalar subquery is
# decorrelated into a cross-product with the 1-row aggregate side
# (`DELIM_JOIN` is for the CORRELATED case only — here there is nothing to
# delimit). DataFusion `optimizer/src/scalar_subquery_to_join.rs` does the
# analogous LEFT-join lowering for the correlated form; our uncorrelated
# form is the simpler CROSS variant. v0.3 Rust carried correlated-subquery
# flattening only; the uncorrelated CROSS-decorrelate is a v0.4 addition.
#
# This module is PURE + NON-PARAMETRIC (no FileHandle reach, no
# execution context) — it lives entirely in `komira_optimizer`. No 3-phase
# split needed (the monomorphizer trap requires a parametric +
# recursive + FileHandle-reaching function; this has none).
# =============================================================================

from std.collections import Optional, List

from komira_collections.slab import Slab
from komira_arrow.schema import Schema, Field, SchemaBuilder

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
    JOIN_CROSS,
    JOIN_ALGO_AUTO,
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


# Public alias for the synthesized column-name prefix. The N-th distinct
# decorrelated subquery at a node gets `__scalar_subq_<N>`. Tests assert on
# `find(SCALAR_SUBQ_COL_PREFIX)`.
comptime SCALAR_SUBQ_COL_PREFIX: String = "__scalar_subq_"


# =============================================================================
# Helper: is this Expr an UNCORRELATED scalar subquery that is DECORRELATABLE?
# =============================================================================


@always_inline
def _is_uncorrelated_scalar_subquery(expr: Expr) -> Bool:
    """True iff `expr.tag == EXPR_CORRELATED_SUBQUERY` AND
    `kind == CORR_KIND_SCALAR` AND `len(outer_refs) == 0`."""
    if expr.tag != EXPR_CORRELATED_SUBQUERY:
        return False
    ref cs = expr._corr_subq.value()[]
    return cs.kind == CORR_KIND_SCALAR and len(cs.outer_refs) == 0


def _provably_at_most_one_row(plan: LogicalPlan) -> Bool:
    """Conservative cardinality bound: does `plan` provably emit <= 1 row?

    True for:
      - a GLOBAL aggregate (`PLAN_AGGREGATE`, `len(group_by) == 0`),
      - `PLAN_LIMIT` with `n <= 1`,
      - any of `PLAN_PROJECT` / `PLAN_SORT` / `PLAN_DISTINCT` whose child is
        provably <= 1 row (none of those can ADD rows).
    False otherwise (the caller then leaves the subquery for the
    materialize-and-substitute fallback).
    """
    if plan.tag == PLAN_AGGREGATE:
        return len(plan._aggregate.value()[].group_by) == 0
    if plan.tag == PLAN_LIMIT:
        return plan._limit.value()[].n <= 1
    if plan.tag == PLAN_PROJECT:
        return _provably_at_most_one_row(plan._project.value()[].child[])
    if plan.tag == PLAN_SORT:
        return _provably_at_most_one_row(plan._sort.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _provably_at_most_one_row(plan._distinct.value()[].child[])
    return False


@always_inline
def _is_decorrelatable_scalar_subquery(expr: Expr) raises -> Bool:
    """True iff `expr` is an uncorrelated SCALAR subquery whose inner plan
    is provably <= 1 row AND has exactly one output column (a scalar
    subquery used as an expression must return a single column).

    ⚠ `raises` SINCE 2026-09-03 — NOT because this predicate got a new failure
    mode, but because reaching the inner plan now goes through
    `corr_data_inner_plan_ref`, which REFUSES an `ErasedBox` that does not hold
    a `LogicalPlan` rather than dereferencing it blind. All three callers were
    already `raises`, so the cascade stopped here. ⛔ Do not close this by
    adding an unchecked accessor — an unchecked door defeats the one guard
    standing between an erased box and a type confusion."""
    if not _is_uncorrelated_scalar_subquery(expr):
        return False
    ref cs = expr._corr_subq.value()[]
    if corr_data_inner_plan_ref(cs).output_schema.num_columns() != 1:
        return False
    return _provably_at_most_one_row(corr_data_inner_plan_ref(cs))


# =============================================================================
# Expr walkers — count / collect / rewrite
# =============================================================================


def _expr_contains_decorrelatable_scalar(expr: Expr) raises -> Bool:
    """True if `expr` (or any subtree) carries a DECORRELATABLE uncorrelated
    SCALAR subquery. Walk-coverage mirrors `_collect_decorrelatable_in_expr`
    / `_rewrite_decorrelated_in_expr` EXACTLY."""
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        return _is_decorrelatable_scalar_subquery(expr)
    if expr.tag == EXPR_BINARY_OP:
        return (
            _expr_contains_decorrelatable_scalar(expr.binary_left_ref())
            or _expr_contains_decorrelatable_scalar(expr.binary_right_ref())
        )
    if expr.tag == EXPR_UNARY_OP:
        return _expr_contains_decorrelatable_scalar(expr.unary_child_ref())
    if expr.tag == EXPR_CAST:
        return _expr_contains_decorrelatable_scalar(expr.cast_child_ref())
    if expr.tag == EXPR_ALIAS:
        return _expr_contains_decorrelatable_scalar(expr.alias_child_ref())
    if expr.tag == EXPR_STRING_OP:
        return _expr_contains_decorrelatable_scalar(expr.string_op_child_ref())
    if expr.tag == EXPR_IN_LIST:
        return _expr_contains_decorrelatable_scalar(expr.in_list_child_ref())
    if expr.tag == EXPR_AGG_FN:
        return _expr_contains_decorrelatable_scalar(expr.agg_fn_child_ref())
    return False


struct _DecorrSite(Movable):
    """One decorrelated subquery, ALREADY deduped by `inner_hash`. Holds the
    inner plan (deep clone, in an Optional so the cross-chain builder can
    `.take()` it out of the List slot) plus the synthesized output-column
    name the rewritten Exprs reference. Lifetime: one
    `_decorrelate_filter` / `_decorrelate_project` call."""

    var inner_plan: Optional[LogicalPlan]
    var inner_hash: UInt64
    var col_name: String

    def __init__(out self, var inner_plan: LogicalPlan, inner_hash: UInt64, var col_name: String):
        self.inner_plan = Optional[LogicalPlan](inner_plan^)
        self.inner_hash = inner_hash
        self.col_name = col_name^


def _collect_decorrelatable_in_expr(
    expr: Expr,
    mut sites: Slab[_DecorrSite],
) raises:
    """Walk the Expr tree; for each DECORRELATABLE uncorrelated SCALAR
    subquery, if its `inner_hash` is not already in `sites`, append a new
    `_DecorrSite` (deep clone of the inner plan + a fresh `__scalar_subq_<N>`
    name). Order: left-to-right pre-order. Coverage MUST match
    `_rewrite_decorrelated_in_expr`."""
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        if _is_decorrelatable_scalar_subquery(expr):
            ref cs = expr._corr_subq.value()[]
            var inner_clone = corr_data_inner_plan_ref(cs).copy()
            var h = inner_clone.structural_hash()
            # Dedup against already-collected sites.
            var found = False
            for i in range(len(sites)):
                if sites[i].inner_hash == h:
                    found = True
                    break
            if not found:
                var nm = SCALAR_SUBQ_COL_PREFIX + String(len(sites))
                sites.append(_DecorrSite(inner_clone^, h, nm^))
        return
    if expr.tag == EXPR_BINARY_OP:
        _collect_decorrelatable_in_expr(expr.binary_left_ref(), sites)
        _collect_decorrelatable_in_expr(expr.binary_right_ref(), sites)
        return
    if expr.tag == EXPR_UNARY_OP:
        _collect_decorrelatable_in_expr(expr.unary_child_ref(), sites)
        return
    if expr.tag == EXPR_CAST:
        _collect_decorrelatable_in_expr(expr.cast_child_ref(), sites)
        return
    if expr.tag == EXPR_ALIAS:
        _collect_decorrelatable_in_expr(expr.alias_child_ref(), sites)
        return
    if expr.tag == EXPR_STRING_OP:
        _collect_decorrelatable_in_expr(expr.string_op_child_ref(), sites)
        return
    if expr.tag == EXPR_IN_LIST:
        _collect_decorrelatable_in_expr(expr.in_list_child_ref(), sites)
        return
    if expr.tag == EXPR_AGG_FN:
        _collect_decorrelatable_in_expr(expr.agg_fn_child_ref(), sites)
        return


def _find_site_col_for_hash(sites: Slab[_DecorrSite], h: UInt64) raises -> String:
    for i in range(len(sites)):
        if sites[i].inner_hash == h:
            return sites[i].col_name
    raise Error("scalar_subquery_decorrelate: rewrite saw a subquery hash not in the collected site list — collect/rewrite walk drifted")


def _rewrite_decorrelated_in_expr(
    expr: Expr,
    sites: Slab[_DecorrSite],
) raises -> Expr:
    """Rebuild the Expr tree, replacing each DECORRELATABLE uncorrelated
    SCALAR subquery with `Expr.col_ref(<site.col_name>)`. Mojo 0.26.3 has no
    in-place single-node swap; the rebuild form is standard (matches
    `_rewrite_scalar_subquery_in_expr` in `resolve_scalar_subqueries`)."""
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        if _is_decorrelatable_scalar_subquery(expr):
            ref cs = expr._corr_subq.value()[]
            var h = corr_data_inner_plan_ref(cs).structural_hash()
            var nm = _find_site_col_for_hash(sites, h)
            return Expr.col_ref(nm^)
        return expr.copy()
    if expr.tag == EXPR_BINARY_OP:
        var nl = _rewrite_decorrelated_in_expr(expr.binary_left_ref(), sites)
        var nr = _rewrite_decorrelated_in_expr(expr.binary_right_ref(), sites)
        return Expr.binary(expr.binary_op(), nl^, nr^)
    if expr.tag == EXPR_UNARY_OP:
        var nc = _rewrite_decorrelated_in_expr(expr.unary_child_ref(), sites)
        return Expr.unary(expr.unary_op(), nc^)
    if expr.tag == EXPR_CAST:
        var nc = _rewrite_decorrelated_in_expr(expr.cast_child_ref(), sites)
        return Expr.cast(nc^, expr.cast_target())
    if expr.tag == EXPR_ALIAS:
        var nc = _rewrite_decorrelated_in_expr(expr.alias_child_ref(), sites)
        return Expr.alias(nc^, expr.alias_name())
    if expr.tag == EXPR_STRING_OP:
        var nc = _rewrite_decorrelated_in_expr(expr.string_op_child_ref(), sites)
        return Expr.string_op(expr.string_op_type(), nc^, expr.string_op_pattern())
    if expr.tag == EXPR_IN_LIST:
        var nc = _rewrite_decorrelated_in_expr(expr.in_list_child_ref(), sites)
        return Expr.in_list_node(nc^, expr.in_list_values_ref().copy())
    if expr.tag == EXPR_AGG_FN:
        var nc = _rewrite_decorrelated_in_expr(expr.agg_fn_child_ref(), sites)
        return Expr.agg_fn(expr.agg_fn_op(), nc^)
    return expr.copy()


def _rewrite_exprs_in_array(exprs: ExprArray, sites: Slab[_DecorrSite]) raises -> ExprArray:
    var out = ExprArray()
    for i in range(len(exprs)):
        out.append(_rewrite_decorrelated_in_expr(exprs[i], sites))
    return out^


# =============================================================================
# CROSS-join construction + schema-stable wrapping
# =============================================================================


def _alias_inner_single_column(var inner_plan: LogicalPlan, col_name: String) raises -> LogicalPlan:
    """Wrap `inner_plan` (which has exactly one output column) in a
    renaming Project that emits that column under `col_name`. Yields a
    single-column plan whose output field is canonically named — avoids any
    name collision with the left side of the CROSS join."""
    var src_name = inner_plan.output_schema.field_name(0)
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.col_ref(src_name), col_name))
    return LogicalPlan.project(exprs^, inner_plan^)


def _build_cross_chain(var left: LogicalPlan, mut sites: Slab[_DecorrSite]) raises -> LogicalPlan:
    """Left-deep chain of `JOIN_CROSS` nodes:
        left' = CROSS( ... CROSS( CROSS(left, inner_0), inner_1) ..., inner_{N-1})
    Each `inner_i` is `inner_plan_i` aliased to `__scalar_subq_<i>`. Empty
    `left_on` / `right_on` (the CROSS contract — a CROSS join has no join
    keys). Consumes each site's `inner_plan`
    Optional via `.take()` (leaves the List slot destructor-safe)."""
    var acc = left^
    for i in range(len(sites)):
        var inner = sites[i].inner_plan.take()
        var col_name = sites[i].col_name
        var inner_aliased = _alias_inner_single_column(inner^, col_name)
        var lk = List[String]()
        var rk = List[String]()
        acc = LogicalPlan.join(acc^, inner_aliased^, lk^, rk^, JOIN_CROSS, JOIN_ALGO_AUTO)
    return acc^


def _identity_project_for_schema(schema: Schema) raises -> ExprArray:
    """An ExprArray of `col_ref(name)` for every field in `schema` — used to
    re-project the CROSS-joined node back to its pre-decorrelate output
    columns (drops the synthesized `__scalar_subq_N` columns)."""
    var exprs = ExprArray()
    for i in range(schema.num_columns()):
        exprs.append(Expr.col_ref(schema.field_name(i)))
    return exprs^


def _restore_schema(var node: LogicalPlan, original_schema: Schema) raises -> LogicalPlan:
    """If `node.output_schema` differs from `original_schema` (i.e. it grew
    `__scalar_subq_N` columns), wrap in an identity Project restoring the
    original columns. If the schemas already match (e.g. a Project node
    whose rebuilt exprs never referenced an extra column), return `node`
    unchanged — an identity-Project elimination pass (not in this tree)
    would only have to remove a redundant Project otherwise."""
    if node.output_schema.num_columns() == original_schema.num_columns():
        # Same width — assume same columns (the Project / Filter rebuild
        # preserved them). No wrapper needed.
        var same = True
        for i in range(original_schema.num_columns()):
            if node.output_schema.field_name(i) != original_schema.field_name(i):
                same = False
                break
        if same:
            return node^
    var proj_exprs = _identity_project_for_schema(original_schema)
    return LogicalPlan.project(proj_exprs^, node^)


# =============================================================================
# Per-node decorrelation (Filter / Project)
# =============================================================================


def _decorrelate_filter(mut plan: LogicalPlan) raises:
    """`plan` is PLAN_FILTER. If its predicate carries a decorrelatable
    uncorrelated SCALAR subquery, rewrite to:
        Project(<original schema>, Filter(CROSS(child, inners...), pred'))
    where `pred'` has each subquery replaced by `col_ref("__scalar_subq_N")`.
    """
    ref fd0 = plan._filter.value()[]
    if not _expr_contains_decorrelatable_scalar(fd0.predicate):
        return
    var original_schema = plan.output_schema.copy()
    var pred_copy = fd0.predicate.copy()
    var child_copy = fd0.child[].copy()

    var sites = Slab[_DecorrSite]()
    _collect_decorrelatable_in_expr(pred_copy, sites)
    if len(sites) == 0:
        return  # cov: unreachable _expr_contains_decorrelatable_scalar said yes and the collect walk mirrors it

    var new_pred = _rewrite_decorrelated_in_expr(pred_copy, sites)
    var new_child = _build_cross_chain(child_copy^, sites)
    var new_filter = LogicalPlan.filter(new_pred^, new_child^)
    plan = _restore_schema(new_filter^, original_schema)


def _decorrelate_project(mut plan: LogicalPlan) raises:
    """`plan` is PLAN_PROJECT. If any of its exprs carries a decorrelatable
    uncorrelated SCALAR subquery, rewrite to:
        Project(exprs', CROSS(child, inners...))
    The rebuilt Project's output schema is recomputed from `exprs'` against
    the CROSS-joined child — `exprs'` only reference declared output columns
    (the original ones) plus the synthesized `__scalar_subq_N` cols which a
    Project expr would only emit if it explicitly aliased them (it does
    not). So the Project's output schema is unchanged; no `_restore_schema`
    wrapper needed."""
    var any_corr = False
    ref pj0 = plan._project.value()[]
    for i in range(len(pj0.exprs)):
        if _expr_contains_decorrelatable_scalar(pj0.exprs[i]):
            any_corr = True
            break
    if not any_corr:
        return
    var original_schema = plan.output_schema.copy()
    # Extract everything we need from `pj0` BEFORE mutating `plan` (which
    # invalidates the `pj0` ref). `Slab[Expr]` has no `.copy()` — collect
    # sites and build `new_exprs` directly off `pj0.exprs` here.
    var child_copy = pj0.child[].copy()
    var sites = Slab[_DecorrSite]()
    for i in range(len(pj0.exprs)):
        _collect_decorrelatable_in_expr(pj0.exprs[i], sites)
    if len(sites) == 0:
        return  # cov: unreachable a decorrelatable expr was found above and the collect walk mirrors that check
    var new_exprs = _rewrite_exprs_in_array(pj0.exprs, sites)

    var new_child = _build_cross_chain(child_copy^, sites)
    var new_project = LogicalPlan.project(new_exprs^, new_child^)
    # Schema-stable: the rebuilt Project's exprs only reference original
    # columns. But if the column-set drifted (shouldn't), restore.
    plan = _restore_schema(new_project^, original_schema)


# =============================================================================
# Public API — top-down recursive driver
# =============================================================================


def scalar_subquery_decorrelate(var plan: LogicalPlan) raises -> LogicalPlan:
    """Decorrelate every DECORRELATABLE uncorrelated SCALAR subquery in
    `plan` into a broadcast `JOIN_CROSS`.

    Non-decorrelatable uncorrelated scalar subqueries (inner not provably
    <= 1 row, or not exactly 1 output column) are LEFT UNCHANGED for the
    `resolve_scalar_subqueries` materialize-and-substitute path. Correlated
    subqueries (`len(outer_refs) > 0`) are also left untouched
    (`flatten_dependent_joins` lowers those).

    Idempotent: a plan with no decorrelatable scalar subqueries is returned
    structurally unchanged (after the recursive walk, which is O(plan-size)
    and allocates nothing for the common no-op case).
    """
    scalar_subquery_decorrelate_inplace(plan)
    return plan^


def scalar_subquery_decorrelate_inplace(mut plan: LogicalPlan) raises:
    """In-place mirror of `scalar_subquery_decorrelate`. Recurses children
    FIRST, then rewrites at this node. (A subquery's own inner plan is NOT a
    regular plan-tree child — it is only reachable via the
    `EXPR_CORRELATED_SUBQUERY` Expr — so the outer walk does not descend
    into it. A nested decorrelatable subquery inside an inner plan is a
    v0.5 concern; this pass does the top-level form which covers Q22/Q11).
    """
    if plan.tag == PLAN_FILTER:
        scalar_subquery_decorrelate_inplace(plan._filter.value()[].child[])
        _decorrelate_filter(plan)
    elif plan.tag == PLAN_PROJECT:
        scalar_subquery_decorrelate_inplace(plan._project.value()[].child[])
        _decorrelate_project(plan)
    elif plan.tag == PLAN_AGGREGATE:
        scalar_subquery_decorrelate_inplace(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        scalar_subquery_decorrelate_inplace(plan._join.value()[].left[])
        scalar_subquery_decorrelate_inplace(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        scalar_subquery_decorrelate_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        scalar_subquery_decorrelate_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        scalar_subquery_decorrelate_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        scalar_subquery_decorrelate_inplace(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        scalar_subquery_decorrelate_inplace(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        scalar_subquery_decorrelate_inplace(plan._partition_topn.value()[].child[])
    # PLAN_SCAN / PLAN_ASOF_JOIN / PLAN_UNION / PLAN_VIEW_REF / PLAN_CSE_REF:
    # no Expr-bearing children that a SCALAR subquery could ride on.
    # UNION children are themselves plans but a
    # SCALAR subquery at a UNION leaf would be inside a Filter/Project which
    # this walk reaches only through PLAN_UNION recursion — out of scope
    # here; the materialize-and-substitute fallback still covers it.
