# =============================================================================
# Optimizer rule: view_resolution_pass
# View resolution: inline registered views
# =============================================================================
#
# A statistics-independent pass. Walks a LogicalPlan and replaces every
# `PLAN_VIEW_REF` leaf with the registered view's *expanded* plan
# (recursively — a view may reference another view; depth-first; depth
# limit 16; cycle detection via a name-stack). komira_optimizer has no
# driver that orders its passes; the order this pass is designed for is:
#
#   * BEFORE `flatten_dependent_joins` — so a view whose body
#     contains a correlated subquery gets inlined first, then flattened.
#   * BEFORE `partition_prune_scans` — so a view that wraps a
#     partitioned Parquet scan gets resolved first, then the partition
#     prune sees the real scan.
#   * BEFORE the `structural_hash` is taken for a plan cache key (the
#     cache and the session API that registers views are not in this tree)
#     — so two consumers of the same view (`ctx.view(h).filter(p)`
#     and `ctx.view(h).select(c)`) produce *resolved* plans, and a query
#     against `ctx.view(h).filter(p)` produces the SAME structural_hash as
#     a manually-written `base_df.filter(p)` (where `base_df` is the plan
#     the view wraps). That structural-hash equivalence is the load-bearing
#     invariant that makes views cache-effective.
#
# After this pass returns, the plan is guaranteed to contain ZERO
# `PLAN_VIEW_REF` nodes (an assertable invariant — a surviving
# `PLAN_VIEW_REF` is a bug).
#
# May raise `ViewRecursionLimitExceeded` (depth or cycle) at compile time.
# This is strictly stronger than a create-time depth guard at view
# registration (the registering API is not in this tree):
# with the lazy `ctx.view(handle)` shape (a `PLAN_VIEW_REF` leaf), a chain
# `create_view("a", df_over_view_b)` / `create_view("b", df_over_view_a)`
# only forms a cycle once BOTH views exist — the create-time per-plan depth
# guard can't see across views; this pass definitively catches it.
#
# References — implementations studied before coding:
#   * DuckDB `Connection::CreateView` (`src/main/connection.cpp`) +
#     `Binder::Bind` on a `LogicalGet` over a view: the view's stored
#     `SELECT` is re-bound (inlined) at planning time; recursive views
#     (DuckDB has explicit `WITH RECURSIVE`, not view-of-view recursion)
#     are bounded by `max_expression_depth`. Our pass is the same
#     "inline at planning time" shape; the depth/cycle guard is ours.
#   * DataFusion `SessionContext::register_table(name, ViewTable)` +
#     `ViewTable::scan` returns the view's `LogicalPlan` which the
#     `Analyzer`'s `InlineTableScan` rule splices in (DataFusion calls it
#     "inline table scan"). Same shape; DataFusion's recursion guard is
#     `recursion_limit` on the rewriter.
#
# Pass order: designed to run FIRST (before
# `partition_prune_scans` / `propagate_statistics` /
# `flatten_dependent_joins`). The pass takes the view registry by `ref`
# (the `Slab[Optional[LogicalPlan]]` plan store + the `Dict[String, Int]`
# name→idx map) — both `komira_collections` container types, so
# `komira_optimizer` does NOT import the SDK and builds without it. The caller
# that owns the view registry (not in this tree) threads both at the call
# site.
# =============================================================================

from std.collections import Optional, Dict

from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import (
    LogicalPlan,
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
    PLAN_UNION,
    PLAN_VIEW_REF,
)


# =============================================================================
# Constants
# =============================================================================

# Maximum chain length of view-of-view-of-view resolution. A chain of 16
# views resolves successfully (16 nested resolutions, depths 0..15); a
# chain of 17 raises `ViewRecursionLimitExceeded` (the 17th resolution
# would be at depth 16).
comptime VIEW_RESOLUTION_DEPTH_LIMIT: Int = 16


# =============================================================================
# Public API
# =============================================================================


def view_resolution_pass(
    var plan: LogicalPlan,
    ref view_slab: Slab[Optional[LogicalPlan]],
    ref view_name_to_idx: Dict[String, Int],
    ref cte_names: List[String],
    ref cte_plans: Slab[LogicalPlan],
) raises -> LogicalPlan:
    """Top-level entry: inline every `PLAN_VIEW_REF` in `plan`.

    Walks the plan recursively. At any `PLAN_VIEW_REF` node, looks up the
    referenced name in TWO scopes — first the statement-scoped CTE bindings
    (`cte_names` / `cte_plans` — the `with_cte["name"](inner^)` registry,
    threaded in by the caller for one statement only), then the
    persistent view registry (`view_name_to_idx` /
    `view_slab`, owned by the caller). **CTE scope wins**: a name bound by
    `with_cte` shadows a same-name registered view (matching DuckDB,
    which resolves CTEs before catalog tables). It deep-copies the matched
    plan, recursively resolves *that* plan's refs (depth-first; depth limit
    16; cycle detection via a name-stack), and splices the fully-resolved
    subtree in place of the `PLAN_VIEW_REF` node. After return, `plan`
    contains zero `PLAN_VIEW_REF` nodes.

    `cte_names` + `cte_plans` are the `CteScope`'s internal
    storage (a parallel `List[String]` + `Slab[LogicalPlan]`), passed by
    `ref` so `komira_optimizer` stays SDK-free (both are
    `komira_collections` / stdlib container types — same discipline as the view
    registry threading). A caller holding a `CteScope` is designed to pass its
    `names_ref()` / `plans_ref()`. Pass empty containers (`List[String]()` /
    `Slab[LogicalPlan]()`) for the no-CTE case.

    Idempotent: a plan with no view refs is returned structurally
    unchanged (the walk is O(nodes) and never reallocates a non-view node).

    Raises:
        * `ViewRecursionLimitExceeded`: the resolution chain exceeds 16,
          OR a cycle was detected (a name appears on its own resolution
          stack — e.g. a `cte_ref["x"]` whose bound plan transitively
          references `cte_ref["x"]`).
        * `ViewNotFound`: a `PLAN_VIEW_REF` names something present in
          NEITHER scope (a `cte_ref["typo"]`, or a view ref whose view
          was dropped from the registry). For a mistyped CTE name this is
          the error surface.
    """
    view_resolution_pass_inplace(
        plan, view_slab, view_name_to_idx, cte_names, cte_plans
    )
    return plan^


def view_resolution_pass(
    var plan: LogicalPlan,
    ref view_slab: Slab[Optional[LogicalPlan]],
    ref view_name_to_idx: Dict[String, Int],
) raises -> LogicalPlan:
    """Convenience overload — resolve only against the view registry
    (no CTE scope). Equivalent to the 5-arg form with empty `cte_names` /
    `cte_plans`. A caller with a per-statement CTE scope calls the 5-arg
    form; this overload exists for
    callers (e.g. focused unit tests) that exercise the view-registry path
    in isolation. (`ref` params can't carry defaults, hence the overload
    rather than a default arg).
    """
    var empty_names = List[String]()
    var empty_plans = Slab[LogicalPlan]()
    view_resolution_pass_inplace(
        plan, view_slab, view_name_to_idx, empty_names, empty_plans
    )
    return plan^


def view_resolution_pass_inplace(
    mut plan: LogicalPlan,
    ref view_slab: Slab[Optional[LogicalPlan]],
    ref view_name_to_idx: Dict[String, Int],
    ref cte_names: List[String],
    ref cte_plans: Slab[LogicalPlan],
) raises:
    """In-place rewrite mirror of `view_resolution_pass`.

    Mirrors `flatten_dependent_joins_inplace` / `partition_prune_scans_inplace`
    — the in-tree precedent for an in-place LogicalPlan-rewriting rule.
    """
    var name_stack = List[String]()
    _resolve_view_refs_inplace(
        plan, view_slab, view_name_to_idx, cte_names, cte_plans, name_stack, 0
    )


# =============================================================================
# Recursive walker
# =============================================================================


def _resolve_view_refs_inplace(
    mut plan: LogicalPlan,
    ref view_slab: Slab[Optional[LogicalPlan]],
    ref view_name_to_idx: Dict[String, Int],
    ref cte_names: List[String],
    ref cte_plans: Slab[LogicalPlan],
    mut name_stack: List[String],
    depth: Int,
) raises:
    """Resolve every `PLAN_VIEW_REF` reachable from `plan`, in place.

    `depth` is the number of resolutions already on the stack (== the
    length of `name_stack` for the resolution chain we're inside; passed
    explicitly for clarity). `name_stack` is the chain of names currently
    being resolved — used for cycle detection. A `PLAN_VIEW_REF` is
    resolved against the CTE scope (`cte_names` / `cte_plans`) FIRST, then
    the persistent view registry (`view_name_to_idx` / `view_slab`).
    """
    if plan.tag == PLAN_VIEW_REF:
        # --- depth guard ---
        # `depth` resolutions already done; this would be #(depth+1). If
        # `depth >= 16`, this would be the 17th nested resolution → raise.
        if depth >= VIEW_RESOLUTION_DEPTH_LIMIT:
            raise Error(
                "ViewRecursionLimitExceeded: view/CTE resolution chain"
                + " exceeded depth limit " + String(VIEW_RESOLUTION_DEPTH_LIMIT)
                + " (chain: " + _join_names(name_stack) + ")"
            )
        var vname = plan._view_ref.value()[].view_name
        # --- cycle guard ---
        for i in range(len(name_stack)):
            if name_stack[i] == vname:
                raise Error(
                    "ViewRecursionLimitExceeded: cycle detected resolving"
                    + " '" + vname + "' (resolution chain already contains it: "
                    + _join_names(name_stack) + ")"
                )
        # --- resolve: CTE scope wins over the view registry ---
        # (matches DuckDB — CTEs are bound before catalog tables/views).
        var expanded = _expand_ref(
            vname, view_slab, view_name_to_idx, cte_names, cte_plans
        )
        # --- recursively resolve refs inside the expanded plan ---
        name_stack.append(vname)
        _resolve_view_refs_inplace(
            expanded, view_slab, view_name_to_idx, cte_names, cte_plans,
            name_stack, depth + 1,
        )
        _ = name_stack.pop()
        # --- splice the fully-resolved subtree in place of this node ---
        plan = expanded^
        return

    # --- not a view ref: recurse into children ---
    if plan.tag == PLAN_FILTER:
        _resolve_view_refs_inplace(
            plan._filter.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_PROJECT:
        _resolve_view_refs_inplace(
            plan._project.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_AGGREGATE:
        _resolve_view_refs_inplace(
            plan._aggregate.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_JOIN:
        _resolve_view_refs_inplace(
            plan._join.value()[].left[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
        _resolve_view_refs_inplace(
            plan._join.value()[].right[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_SORT:
        _resolve_view_refs_inplace(
            plan._sort.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_LIMIT:
        _resolve_view_refs_inplace(
            plan._limit.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_DISTINCT:
        _resolve_view_refs_inplace(
            plan._distinct.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_TOPN:
        _resolve_view_refs_inplace(
            plan._topn.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_PARTITION_BY:
        _resolve_view_refs_inplace(
            plan._partition_by.value()[].child[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_PARTITION_TOPN:
        _resolve_view_refs_inplace(
            plan._partition_topn.value()[].child[], view_slab,
            view_name_to_idx, cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_ASOF_JOIN:
        _resolve_view_refs_inplace(
            plan._asof_join.value()[].left[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
        _resolve_view_refs_inplace(
            plan._asof_join.value()[].right[], view_slab, view_name_to_idx,
            cte_names, cte_plans, name_stack, depth,
        )
    elif plan.tag == PLAN_UNION:
        var n = len(plan._union.value()[].children)
        for i in range(n):
            _resolve_view_refs_inplace(
                plan._union.value()[].children[i][], view_slab,
                view_name_to_idx, cte_names, cte_plans, name_stack, depth,
            )
    # PLAN_SCAN: leaf, no children.


def _expand_ref(
    vname: String,
    ref view_slab: Slab[Optional[LogicalPlan]],
    ref view_name_to_idx: Dict[String, Int],
    ref cte_names: List[String],
    ref cte_plans: Slab[LogicalPlan],
) raises -> LogicalPlan:
    """Look up `vname` and return a deep clone of the matched (still
    UNRESOLVED) plan. CTE scope is consulted first, then the view
    registry. Raises `ViewNotFound` if `vname` is in neither scope or its
    registry slot is empty."""
    # --- CTE scope (statement-scoped `with_cte` bindings) ---
    for i in range(len(cte_names)):
        if cte_names[i] == vname:
            return cte_plans[i].copy()
    # --- persistent view registry (owned by the caller) ---
    if vname in view_name_to_idx:
        var idx = view_name_to_idx[vname]
        # `view_slab[idx]` is `Optional[LogicalPlan]`; a live registry
        # entry is always `Some` (the registry's owner is designed to set a
        # dropped view's slot to `None` AND remove the name→idx mapping, so a
        # name present in `view_name_to_idx` always maps to a `Some` slot). A
        # violated invariant raises `ViewNotFound` rather than aborting in
        # `.value()`.
        if not view_slab[idx]:
            raise Error(
                "ViewNotFound: '" + vname + "' maps to an empty view-registry"
                + " slot (the name was not removed when its plan was)"
            )
        return view_slab[idx].value().copy()
    raise Error(
        "ViewNotFound: '" + vname + "' referenced by a PLAN_VIEW_REF is"
        + " neither a `with_cte` binding nor a registered view (typo? a"
        + " `cte_ref[\"" + vname + "\"]` with no matching `with_cte`?"
        + " a dropped view?)"
    )


# =============================================================================
# Invariant-check helper
# =============================================================================


def plan_contains_view_ref(plan: LogicalPlan) -> Bool:
    """True if any node in `plan` is a `PLAN_VIEW_REF`.

    After `view_resolution_pass` returns, this MUST be False for any
    successfully resolved plan. Used by tests + as a defensive assertion.
    """
    if plan.tag == PLAN_VIEW_REF:
        return True
    if plan.tag == PLAN_FILTER:
        return plan_contains_view_ref(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        return plan_contains_view_ref(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        return plan_contains_view_ref(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        if plan_contains_view_ref(plan._join.value()[].left[]):
            return True
        return plan_contains_view_ref(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return plan_contains_view_ref(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return plan_contains_view_ref(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return plan_contains_view_ref(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return plan_contains_view_ref(plan._topn.value()[].child[])
    if plan.tag == PLAN_PARTITION_BY:
        return plan_contains_view_ref(plan._partition_by.value()[].child[])
    if plan.tag == PLAN_PARTITION_TOPN:
        return plan_contains_view_ref(plan._partition_topn.value()[].child[])
    if plan.tag == PLAN_ASOF_JOIN:
        if plan_contains_view_ref(plan._asof_join.value()[].left[]):
            return True
        return plan_contains_view_ref(plan._asof_join.value()[].right[])
    if plan.tag == PLAN_UNION:
        var n = len(plan._union.value()[].children)
        for i in range(n):
            if plan_contains_view_ref(plan._union.value()[].children[i][]):
                return True
        return False
    # PLAN_SCAN: leaf.
    return False


# =============================================================================
# Internal helpers
# =============================================================================


def _join_names(names: List[String]) -> String:
    """Render a list of view names as `a -> b -> c` for error messages."""
    var s = String("")
    for i in range(len(names)):
        if i > 0:
            s += " -> "
        s += names[i]
    return s
