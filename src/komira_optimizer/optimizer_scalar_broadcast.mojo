# =============================================================================
# optimizer_scalar_broadcast
# =============================================================================
#
# Detects the user-side `df.filter(col("x") == col("x").max())` shape after
# `.group_by(...).agg(...)` and rewrites it with values bound in the
# `ScalarDepTable`: `Expr.literal(scalar_value)` replaces the `EXPR_AGG_FN`
# node in the outer Filter predicate, and the inner Aggregate becomes a scan
# of its already-materialized batch. This
# module executes nothing, and komira has no caller in this tree that
# executes the requests it records.
#
# Pattern (the only one that triggers):
#   Filter(<predicate referencing EXPR_AGG_FN>)
#     Aggregate(group_by=[...], aggs=[...])
#       <inner subtree>
#
# Rewrite:
#   1. Extract the agg-fn op + child column from the EXPR_AGG_FN node.
#   2. Look the inner Aggregate's structural hash up in the `ScalarDepTable`.
#      On a miss, record a request carrying the inner Aggregate and the
#      `(op, col_name)` pair, and leave the plan unchanged. The caller this
#      is designed for (not in this tree) runs the group-by Aggregate,
#      reduces its batch with the ungrouped
#      Aggregate(max/min/sum/avg/count(child)) that `_build_inner_sub_plan`
#      builds (two cascaded aggregates: per-group values, then one scalar),
#      binds the scalar and the batch, and runs this pass again.
#   3. On a hit, substitute every EXPR_AGG_FN node in the outer Filter
#      predicate with `Expr.literal(scalar_value)` via a recursive
#      Expr-tree walk with rebuild.
#   4. Replace the inner Aggregate subtree with a scan of the bound
#      `InMemorySource`, so the outer plan does not re-run the group-by.
#
# Pass order: `optimizer_driver.optimize` runs this pass AFTER
# `push_predicates_down` (so any non-EXPR_AGG_FN predicates have already moved
# out of the same Filter) and BEFORE the inner-to-semi join conversion
# (`convert_inner_to_semi`), so the SEMI swap sees the rewritten
# literal-comparison filter.
#
# Failure modes (with explicit error messages):
#   * Pattern not matched (no EXPR_AGG_FN in any Filter, or Filter not
#     above Aggregate): the rule no-ops; the plan passes through.
#   * The inner sub-plan is executed outside this module; this pass only
#     reads bound values.
#   * Inner sub-plan returns 0 rows: the binding this pass is designed for
#     is `ScalarValue.null(dtype)`, and substitution puts
#     `Expr.literal(NULL)` in the predicate (matches DuckDB semantics for
#     empty subquery).
# =============================================================================

from komira_arrow.schema import RecordBatch, Schema
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
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    WhenCaseData,
)
from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_FILTER,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
    SOURCE_IN_MEMORY,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.source_variant import SourceVariant
from komira_scan_source.in_memory_source import InMemorySource
from komira_plan_ir.plan_helpers import _copy_plan, _copy_schema
from .optimizer_scalar_deps import ScalarDepTable, DEP_SCALAR_BROADCAST


# =============================================================================
# Predicate walker — does this Expr tree contain any EXPR_AGG_FN node?
# =============================================================================

def _expr_has_agg_fn(expr: Expr) -> Bool:
    """Recursive walk: True iff any sub-node is `EXPR_AGG_FN`.

    Stops at the first hit; otherwise traverses every child variant. The
    walker mirrors `plan_helpers._collect_expr_columns`, so adding a new
    variant is mechanical.
    """
    if expr.tag == EXPR_AGG_FN:
        return True
    if expr.tag == EXPR_BINARY_OP:
        if _expr_has_agg_fn(expr.binary_left_ref()):
            return True
        return _expr_has_agg_fn(expr.binary_right_ref())
    if expr.tag == EXPR_UNARY_OP:
        return _expr_has_agg_fn(expr.unary_child_ref())
    if expr.tag == EXPR_CAST:
        return _expr_has_agg_fn(expr.cast_child_ref())
    if expr.tag == EXPR_ALIAS:
        return _expr_has_agg_fn(expr.alias_child_ref())
    if expr.tag == EXPR_STRING_OP:
        return _expr_has_agg_fn(expr.string_op_child_ref())
    # ★ MathFn / MathFn2 / CASE: `having
    # sqrt(s) > sqrt(s.mean())` and a CASE-wrapped aggregate must be seen,
    # or the aggregate is left in the plan unrewritten. Every
    # arm here needs its twin in `_substitute_agg_fn` and `_walk_for_agg_fn`.
    if expr.tag == EXPR_MATH_FN:
        return _expr_has_agg_fn(expr.math_fn_child_ref())
    if expr.tag == EXPR_MATH_FN2:
        if _expr_has_agg_fn(expr.math_fn2_left_ref()):
            return True
        return _expr_has_agg_fn(expr.math_fn2_right_ref())
    if expr.tag == EXPR_WHEN:
        for i in range(expr.when_num_cases()):
            if _expr_has_agg_fn(expr.when_case_condition_ref(i)):
                return True
            if _expr_has_agg_fn(expr.when_case_result_ref(i)):
                return True
        return _expr_has_agg_fn(expr.when_default_ref())
    # EXPR_LITERAL, EXPR_COL_REF, EXPR_COL_IDX are leaves; any other
    # container is not walked (its aggregate is not broadcast).
    return False


# =============================================================================
# Predicate rewriter — substitute EXPR_AGG_FN nodes with EXPR_LITERAL
# =============================================================================

def _substitute_agg_fn(
    expr: Expr,
    scalar_value: ScalarValue,
) raises -> Expr:
    """Walk the Expr tree and replace every `EXPR_AGG_FN` node with
    `Expr.literal(scalar_value)`.

    Pure tree-rewrite — every container `_expr_has_agg_fn` walks is
    reconstructed via its factory with recursively-rewritten children; any
    other node is deep-copied AS BUILT (it holds no aggregate this rule
    broadcasts, because `_expr_has_agg_fn` did not see one). The shape
    matches `optimizer_project_merge_guard.substitute_project_refs`.
    """
    if expr.tag == EXPR_AGG_FN:
        return Expr.literal(scalar_value.copy())
    if expr.tag == EXPR_BINARY_OP:
        var new_left = _substitute_agg_fn(expr.binary_left_ref(), scalar_value)
        var new_right = _substitute_agg_fn(expr.binary_right_ref(), scalar_value)
        return Expr.binary(expr.binary_op(), new_left^, new_right^)
    if expr.tag == EXPR_UNARY_OP:
        var new_child = _substitute_agg_fn(expr.unary_child_ref(), scalar_value)
        return Expr.unary(expr.unary_op(), new_child^)
    if expr.tag == EXPR_CAST:
        # `cast_preserving_arrow` — rebuilding from `cast_target()` alone RESETS
        # a temporal or decimal target to its bare physical DType (the same
        # rule as `optimizer_expr._fold_expr`'s EXPR_CAST arm).
        var new_child = _substitute_agg_fn(expr.cast_child_ref(), scalar_value)
        return Expr.cast_preserving_arrow(new_child^, expr)
    if expr.tag == EXPR_ALIAS:
        var new_child = _substitute_agg_fn(expr.alias_child_ref(), scalar_value)
        return Expr.alias(new_child^, expr.alias_name())
    if expr.tag == EXPR_STRING_OP:
        var new_child = _substitute_agg_fn(expr.string_op_child_ref(), scalar_value)
        return Expr.string_op(
            expr.string_op_type(), new_child^, expr.string_op_pattern()
        )
    if expr.tag == EXPR_MATH_FN:
        var new_child = _substitute_agg_fn(expr.math_fn_child_ref(), scalar_value)
        return Expr.math_fn(expr.math_fn_op(), new_child^)
    if expr.tag == EXPR_MATH_FN2:
        var new_left = _substitute_agg_fn(expr.math_fn2_left_ref(), scalar_value)
        var new_right = _substitute_agg_fn(expr.math_fn2_right_ref(), scalar_value)
        return Expr.math_fn2(expr.math_fn2_op(), new_left^, new_right^)
    if expr.tag == EXPR_WHEN:
        var cases = List[WhenCaseData]()
        for i in range(expr.when_num_cases()):
            var c = _substitute_agg_fn(expr.when_case_condition_ref(i), scalar_value)
            var r = _substitute_agg_fn(expr.when_case_result_ref(i), scalar_value)
            cases.append(WhenCaseData(c^, r^))
        var d = _substitute_agg_fn(expr.when_default_ref(), scalar_value)
        return Expr.when(cases^, d^)
    # No AGG_FN reachable through this tag — just deep-copy.
    return expr.copy()


# =============================================================================
# Inner sub-plan builder
# =============================================================================

def _resolve_child_col_name(child: Expr) raises -> String:
    """Extract the column name from the EXPR_AGG_FN's child expression.

    The pass supports the simple shape `col("x").max()` where the agg-fn
    child is a bare `EXPR_COL_REF`. More complex children (binary ops,
    casts, etc.) would require recursive evaluation against the inner
    Aggregate's output schema and are out of scope for v0.4. The error
    points the user at the supported shape.
    """
    if child.tag == EXPR_COL_REF:
        return child.col_ref_name()
    raise Error(
        "scalar-broadcast: agg-fn child must be a bare column reference"
        " (e.g. `col(\"total_revenue\").max()`); compound expressions"
        " inside the agg-fn are not supported in v0.4. Got tag "
        + String(Int(child.tag))
    )


def _build_inner_sub_plan(
    var inner_aggregate: LogicalPlan,
    op: UInt8,
    col_name: String,
) raises -> LogicalPlan:
    """Build the inner sub-plan: an ungrouped `op(col_name)` over a
    deep-copy of the original inner Aggregate.

    The original inner Aggregate (with its group-by) produces N rows;
    the new outer Aggregate reduces them to a single row containing the
    aggregate of `col_name`. Output schema: 1 column carrying the agg
    output dtype.
    """
    # Build the outer ungrouped Aggregate.
    var group_by = ExprArray()
    var aggs = AggExprArray()
    var none_alias: Optional[String] = Optional[String](
        String("_scalar_broadcast")
    )
    var child_expr = Expr.col_ref(col_name.copy())
    var child_opt: Optional[Expr] = Optional[Expr](child_expr^)
    var agg = AggExpr(op, child_opt^, none_alias^)
    aggs.append(agg^)
    return LogicalPlan.aggregate(group_by^, aggs^, inner_aggregate^)


# =============================================================================
# Main rule body — 3-phase design
# =============================================================================
#
# The rule runs in three explicitly-staged phases. The split was first made
# to keep execution (and its FileHandle reach) OUT of any recursive,
# parametric `def`: the AOT-monomorphization trap
# (parametric+recursive+FileHandle reach). With execution gone, no phase is
# parametric and none reaches a FileHandle. See the closing note at the end
# of this file.
#
# Phase 1 — pure walker `_collect_scalar_broadcast_sites`:
#   non-parametric, recursive on `LogicalPlan`. Identifies every
#   Filter(Aggregate) shape with an EXPR_AGG_FN predicate and pushes
#   a `ScalarBroadcastSite` (op, col_name, inner_aggregate clone, hash)
#   into the output Slab. Executes nothing.
#   Does NOT carry parametric origins.
#
# Phase 2 — top-level driver `scalar_broadcast_rewrite` body:
#   non-parametric. Iterates the precomputed sites in a FLAT for-loop
#   (NOT recursive) and looks each site's hash up in the `ScalarDepTable`.
#   A hit appends the bound scalar, name, schema and `InMemorySource` to
#   parallel lists; a miss records a request and the plan passes through.
#
# Phase 3 — pure rewriter `_rewrite_scalar_broadcast_sites`:
#   non-parametric, recursive on `LogicalPlan`. Walks the tree again,
#   substituting `EXPR_AGG_FN` with `Expr.literal(scalar)` at each
#   matching Filter(Aggregate) site. The matching is order-preserving
#   on the same site list emitted by Phase 1 (post-order via a shared
#   index counter passed by reference).
#
# Why the split closes the trap: the trap
# requires ALL THREE legs simultaneously — parametric, recursive, and
# FileHandle reach. Phase 1's recursion is non-parametric. Phase 2 is
# neither recursive nor parametric. Phase 3's recursion is
# non-parametric. No phase reaches a FileHandle, so the
# AOT-link monomorphizer never enters the quadratic-blowup regime.

# =============================================================================
# ScalarBroadcastSite — descriptor for a single Filter(Aggregate) match
# =============================================================================

struct ScalarBroadcastSite(Movable):
    """One Filter(Aggregate) site whose predicate contains an EXPR_AGG_FN
    that the rule will fold to a literal.

    Lifetime is bounded by one `scalar_broadcast_rewrite` call; the Slab
    holding these is constructed in Phase 1, consumed in Phases 2-3, and
    dropped at function exit. No long-lived storage of these sites — the
    requests written into the `ScalarDepTable` are the only artefact that
    outlives the call.

    Movable-only because LogicalPlan and String are Movable-only. Stored
    inside `Slab[ScalarBroadcastSite]`.
    """

    var op: UInt8
    var col_name: String
    var inner_aggregate: LogicalPlan
    var inner_hash: UInt64

    def __init__(
        out self,
        op: UInt8,
        var col_name: String,
        var inner_aggregate: LogicalPlan,
        inner_hash: UInt64,
    ):
        self.op = op
        self.col_name = col_name^
        self.inner_aggregate = inner_aggregate^
        self.inner_hash = inner_hash


# =============================================================================
# Phase 1 — non-parametric site collector (recursive, no FileHandle reach)
# =============================================================================

def _collect_scalar_broadcast_sites(
    imm plan: LogicalPlan,
    mut sites: Slab[ScalarBroadcastSite],
) raises:
    """Walk the plan tree post-order and collect every Filter(Aggregate)
    site whose predicate contains an EXPR_AGG_FN node.

    NON-PARAMETRIC by construction (no origin parameters on the
    signature). This breaks one leg of the
    parametric+recursive+FileHandle-reach trap. Executes nothing and
    reads no dependency table.

    Recursion shape mirrors the original `_recurse_into_children` —
    Sort/Limit/Filter pass through to the child; Filter(Aggregate) with
    an EXPR_AGG_FN predicate is the trigger and stops the recursion at
    that subtree (nested Filter(Aggregate) deeper inside the inner
    aggregate is out of scope).
    """
    if plan.tag == PLAN_FILTER and plan.filter_data_ref().child[].tag == PLAN_AGGREGATE:
        var predicate_copy = plan.filter_data_ref().predicate.copy()
        if _expr_has_agg_fn(predicate_copy):
            var op_name_pair = _extract_single_agg_fn(predicate_copy)
            var op = op_name_pair[0]
            var col_name = op_name_pair[1]
            var inner_agg_clone = _copy_plan(plan.filter_data_ref().child[])
            var inner_hash = inner_agg_clone.structural_hash()
            sites.append(
                ScalarBroadcastSite(op, col_name^, inner_agg_clone^, inner_hash)
            )
            # Stop at this site — single-broadcast model.
            return
        # Filter(Aggregate) without EXPR_AGG_FN — recurse into the
        # Filter's child (the Aggregate's subtree may still contain a
        # Filter(Aggregate) deeper down, e.g. inside a derived
        # subquery materialization).
        _collect_scalar_broadcast_sites(plan.filter_data_ref().child[], sites)
        return

    if plan.tag == PLAN_SORT:
        _collect_scalar_broadcast_sites(plan._sort.value()[].child[], sites)
        return
    if plan.tag == PLAN_LIMIT:
        _collect_scalar_broadcast_sites(plan._limit.value()[].child[], sites)
        return
    if plan.tag == PLAN_FILTER:
        # Filter NOT above Aggregate — recurse into the Filter's child.
        _collect_scalar_broadcast_sites(plan._filter.value()[].child[], sites)
        return
    # Other shapes (Aggregate/Scan/Join/Project/etc.): leaf.


# =============================================================================
# Phase 3 — non-parametric rewriter (recursive, no FileHandle reach)
# =============================================================================

def _rewrite_scalar_broadcast_sites(
    var plan: LogicalPlan,
    imm sites: Slab[ScalarBroadcastSite],
    imm scalars: List[ScalarValue],
    imm cache_names: List[String],
    imm cache_schemas: Slab[Schema],
    imm cache_sources: Slab[InMemorySource],
    mut next_idx: Int,
) raises -> LogicalPlan:
    """Walk the plan tree post-order in lockstep with Phase 1's site
    enumeration. At each Filter(Aggregate)-with-EXPR_AGG_FN site:

      1. Substitute the predicate's EXPR_AGG_FN with
         `Expr.literal(scalars[next_idx])`.
      2. **Replace the inner Aggregate child with `Scan(SOURCE_IN_MEMORY,
         cache_names[next_idx])`.** The inner Aggregate's batch is a
         bound value (materialized by whoever executed the request),
         and Phase 2 looked it up under `cache_names[next_idx]`;
         rewriting the outer plan to scan it from memory means the
         plan no longer carries the inner scan + filters + group-by.
      3. Advance `next_idx`.

    NON-PARAMETRIC by construction. The walker depends only on
    pure-data inputs (Slab, List, Int counter); no execution handle or
    origin parameter is in this function's monomorphization
    closure.

    Order discipline: this walker MUST visit nodes in the same order
    as `_collect_scalar_broadcast_sites` so the parallel arrays
    (sites[i] <-> scalars[i] <-> cache_names[i] <-> cache_schemas[i])
    line up. Both walkers process Filter(Aggregate) -> Sort.child ->
    Limit.child -> Filter.child (no Filter(Aggregate)) in identical
    order, so a shared counter `next_idx` advances in sync.
    """
    if plan.tag == PLAN_FILTER and plan.filter_data_ref().child[].tag == PLAN_AGGREGATE:
        var predicate_copy = plan.filter_data_ref().predicate.copy()
        if _expr_has_agg_fn(predicate_copy):
            var scalar_value = scalars[next_idx].copy()
            _ = cache_names[next_idx]  # parallel consume — debug-only
            var cache_schema = _copy_schema(cache_schemas[next_idx])
            # Clone the per-
            # site InMemorySource (ArcPointer refcount-bump; no batch
            # byte-copy) and emit a SourceVariant-carrying scan via
            # `scan_from_source`, so the batch travels in
            # `scan.source._in_memory` rather than by name (the plan
            # still scans a materialized batch instead of re-emitting
            # the inner Aggregate).
            var in_mem_clone = cache_sources[next_idx].copy()
            next_idx += 1
            var new_predicate = _substitute_agg_fn(predicate_copy, scalar_value)
            _ = sites  # parallel consume — sites[next_idx-1] consumed.
            # Instead of re-emitting the inner Aggregate (its scan +
            # filters + group-by were already executed to produce the
            # bound batch), scan the batch inline on the SourceVariant.
            # The schema matches the inner Aggregate's output_schema
            # captured in Phase 2.
            var in_mem_scan = LogicalPlan.scan_from_source(
                SourceVariant(in_mem_clone^),
                cache_schema^,
            )
            return LogicalPlan.filter(new_predicate^, in_mem_scan^)
        # No EXPR_AGG_FN in this predicate — fall through to recurse on
        # the child (inner aggregate's subtree).
        var child = _copy_plan(plan.filter_data_ref().child[])
        var rewritten_child = _rewrite_scalar_broadcast_sites(
            child^, sites, scalars, cache_names, cache_schemas, cache_sources, next_idx
        )
        var pred = plan.filter_data_ref().predicate.copy()
        return LogicalPlan.filter(pred^, rewritten_child^)

    if plan.tag == PLAN_SORT:
        var child = _copy_plan(plan._sort.value()[].child[])
        var rewritten_child = _rewrite_scalar_broadcast_sites(
            child^, sites, scalars, cache_names, cache_schemas, cache_sources, next_idx
        )
        var keys = plan._sort.value()[].keys.copy()
        var desc = plan._sort.value()[].descending.copy()
        # ORDNULL-SURVIVE: carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(keys^, desc^, rewritten_child^, nf_copy^)

    if plan.tag == PLAN_LIMIT:
        var child = _copy_plan(plan._limit.value()[].child[])
        var rewritten_child = _rewrite_scalar_broadcast_sites(
            child^, sites, scalars, cache_names, cache_schemas, cache_sources, next_idx
        )
        var n = plan._limit.value()[].n
        # Forward the RANGE offset, don't drop it on rebuild.
        return LogicalPlan.limit(
            n, rewritten_child^, offset=plan._limit.value()[].offset
        )

    if plan.tag == PLAN_FILTER:
        var child = _copy_plan(plan._filter.value()[].child[])
        var rewritten_child = _rewrite_scalar_broadcast_sites(
            child^, sites, scalars, cache_names, cache_schemas, cache_sources, next_idx
        )
        var pred = plan._filter.value()[].predicate.copy()
        return LogicalPlan.filter(pred^, rewritten_child^)

    # Other shapes: pass through unchanged.
    return plan^


# =============================================================================
# Phase 2 — top-level driver (PURE, non-parametric, NOT recursive)
# =============================================================================


def scalar_broadcast_rewrite(
    var plan: LogicalPlan,
    mut deps: ScalarDepTable,
) raises -> LogicalPlan:
    """Scalar-broadcast rewrite — the 3-phase driver.

    ⛔ THIS PASS EXECUTES NOTHING. Resolving a site takes TWO chained
    executions: (a) the original group-by Aggregate, to get the multi-row
    batch, and (b) an ungrouped reduction of that batch, to get the scalar.
    Both belong to a caller that executes plans (komira has none in this
    tree); it binds the results into the `ScalarDepTable` and runs this pass
    again.

    ★ WHY THIS PASS IS THE HARDER OF THE TWO, AND WHY IT STILL FITS THE RULE.
    `resolve_scalar_subqueries` folds a value into a literal and nothing else.
    This one ALSO splices materialized RESULT DATA into the plan: Phase 3
    replaces the whole inner Aggregate subtree with
    `Scan(SourceVariant(InMemorySource))` over the batch Phase 2 looked up
    (without it the outer plan would still carry the inner scan + filters +
    group-by that produced the batch). Under the dependency model that batch
    is a BOUND VALUE like any other — the executing caller produces it, the
    table carries it, and this pass consumes it as pure data.

    Three-phase implementation:

      Phase 1 (pure, recursive):
        Walk the plan with `_collect_scalar_broadcast_sites` to enumerate
        every Filter(Aggregate) site whose predicate contains an
        EXPR_AGG_FN node. Pushes one `ScalarBroadcastSite` per site
        into a local Slab.

      Phase 2 (this body — PURE, a FLAT for-loop):
        Look each site's `inner_hash` up in the dependency table's bindings.
        A HIT yields all four parallel values Phase 3 needs (scalar, synthetic
        name, schema, `InMemorySource`). A MISS records a request carrying the
        inner Aggregate PLUS the `(op, col_name)` the executing caller needs to
        build the ungrouped reduction, and the plan passes through untouched.

      Phase 3 (pure, recursive):
        Re-walk the plan with `_rewrite_scalar_broadcast_sites`,
        substituting EXPR_AGG_FN -> Expr.literal(scalar) and the Aggregate
        subtree -> the inline-batch scan, in lockstep with Phase 1's order.

    With no execution here, NO phase of this pass is parametric and none
    reaches a FileHandle.

    Multi-broadcast detection: if more than one distinct EXPR_AGG_FN
    appears in any Filter's predicate (e.g. `col(x).max() AND
    col(y).min()`), `_extract_single_agg_fn` raises so the caller can
    decompose. That refusal is a PURE pattern-match decline and stays here.

    Args:
        plan: The (sub-)plan to rewrite. Consumed.
        deps: The dependency channel — bindings in, requests out.

    Returns:
        Rewritten plan (or input plan unchanged if no pattern match, or if a
        site is not yet bound).
    """
    # ---- Phase 1: collect Filter(Aggregate) sites (no execution). ----
    var sites = Slab[ScalarBroadcastSite]()
    _collect_scalar_broadcast_sites(plan, sites)
    if len(sites) == 0:
        # No matching site anywhere in the plan — pass through unchanged.
        return plan^

    # ---- Phase 2: bind (or request) per site. PURE, FLAT. ----
    # Parallel arrays sites[i] <-> scalars[i] <-> cache_names[i] <->
    # cache_schemas[i] <-> cache_sources[i], consumed in lockstep by Phase 3.
    var scalars = List[ScalarValue]()
    var cache_names = List[String]()
    var cache_schemas = Slab[Schema]()
    var cache_sources = Slab[InMemorySource]()
    var all_bound = True
    for i in range(len(sites)):
        var h = sites[i].inner_hash
        var bi = deps.binding_index(DEP_SCALAR_BROADCAST, h)
        if bi < 0:
            # MISS: request this site's materialization. The request
            # carries the inner Aggregate AND the `(op, col_name)` pair,
            # because resolving a broadcast is two CHAINED executions and the
            # second one's plan is DERIVED from the first one's output — it
            # cannot be reconstructed from the inner plan alone.
            all_bound = False
            deps.request(
                DEP_SCALAR_BROADCAST,
                h,
                _copy_plan(sites[i].inner_aggregate),
                sites[i].op,
                sites[i].col_name.copy(),
            )
            continue
        scalars.append(deps.bound_scalar(bi))
        cache_names.append(deps.bound_name(bi))
        cache_schemas.append(deps.bound_schema(bi))
        cache_sources.append(deps.bound_source(bi))

    if not all_bound:
        # Leave EVERY site intact — a partial rewrite would desynchronise
        # Phase 3's shared `next_idx` counter against the parallel arrays.
        return plan^

    # ---- Phase 3: rewrite plan with scalars (no execution). ----
    var next_idx: Int = 0
    var rewritten = _rewrite_scalar_broadcast_sites(
        plan^, sites, scalars, cache_names, cache_schemas, cache_sources, next_idx
    )
    return rewritten^


# =============================================================================
# Single-EXPR_AGG_FN extraction
# =============================================================================

def _extract_single_agg_fn(expr: Expr) raises -> Tuple[UInt8, String]:
    """Find the unique `EXPR_AGG_FN` node in `expr` and return its
    (op, child_col_name).

    Raises if zero or two-or-more `EXPR_AGG_FN` nodes are present.
    Caller is expected to have validated `_expr_has_agg_fn(expr)` first;
    the zero-case here is just a defensive guard.
    """
    var found_op: Optional[UInt8] = None
    var found_col: Optional[String] = None
    var count: Int = 0
    _walk_for_agg_fn(expr, found_op, found_col, count)
    if count == 0:
        raise Error("scalar-broadcast: predicate has no EXPR_AGG_FN node")
    if count > 1:
        raise Error(
            "multiple broadcast aggregates in one predicate not yet"
            " supported (use two `.filter()` calls or wait for v0.5)"
        )
    return (found_op.value(), found_col.value())


def _walk_for_agg_fn(
    expr: Expr,
    mut found_op: Optional[UInt8],
    mut found_col: Optional[String],
    mut count: Int,
) raises:
    """Tree walk that increments `count` on every EXPR_AGG_FN hit and
    captures the FIRST hit's (op, col_name) into the out params."""
    if expr.tag == EXPR_AGG_FN:
        count += 1
        if count == 1:
            found_op = Optional[UInt8](expr.agg_fn_op())
            # agg_fn_child_ref() returns a ref; pass directly into the
            # name resolver without binding to a local (Expr is not
            # ImplicitlyCopyable).
            found_col = Optional[String](
                _resolve_child_col_name(expr.agg_fn_child_ref())
            )
        return
    if expr.tag == EXPR_BINARY_OP:
        _walk_for_agg_fn(expr.binary_left_ref(), found_op, found_col, count)
        _walk_for_agg_fn(expr.binary_right_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_UNARY_OP:
        _walk_for_agg_fn(expr.unary_child_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_CAST:
        _walk_for_agg_fn(expr.cast_child_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_ALIAS:
        _walk_for_agg_fn(expr.alias_child_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_STRING_OP:
        _walk_for_agg_fn(expr.string_op_child_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_MATH_FN:
        _walk_for_agg_fn(expr.math_fn_child_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_MATH_FN2:
        _walk_for_agg_fn(expr.math_fn2_left_ref(), found_op, found_col, count)
        _walk_for_agg_fn(expr.math_fn2_right_ref(), found_op, found_col, count)
        return
    if expr.tag == EXPR_WHEN:
        for i in range(expr.when_num_cases()):
            _walk_for_agg_fn(
                expr.when_case_condition_ref(i), found_op, found_col, count
            )
            _walk_for_agg_fn(
                expr.when_case_result_ref(i), found_op, found_col, count
            )
        _walk_for_agg_fn(expr.when_default_ref(), found_op, found_col, count)
        return
    # Leaf or non-AGG container — stop.


# =============================================================================
# Recursive descent — REMOVED in the 3-phase design
# =============================================================================
#
# The previous `_recurse_into_children[ctx_origin, reg_origin]` parametric
# recursive walker was the monomorphization trap shape: parametric on the
# origins of an `OptimizerContext` (not in this tree) AND mutually recursive
# with `scalar_broadcast_rewrite` AND reaching `FileHandle` via
# `execute_plan_on_session` (not in this tree) from inside the recursion. The
# 3-phase design replaces it with the non-parametric `_collect_scalar_broadcast_sites`
# (Phase 1) + non-parametric `_rewrite_scalar_broadcast_sites`
# (Phase 3); the dependency lookup is the FLAT for-loop in
# `scalar_broadcast_rewrite`'s body (Phase 2), and execution is outside
# komira_optimizer. See the "Main rule body" notes above for the rationale.
