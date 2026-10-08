# =============================================================================
# optimizer_window_rewrite -- window co-location, fusion, Sort elision
# =============================================================================
#
# Multi-window co-location for window functions. This
# rule has THREE triggers, each closing a different gap:
#
#   Pattern A -- Project containing EXPR_WINDOW_FN exprs.
#     Trigger:   Project(exprs=[..., window_expr_1, ..., window_expr_2, ...])
#     Rewrite:   group window exprs by `(partition_by, order_by, descending)`
#                triple. For each group, build one `PartitionBy` node above
#                the child plan; replace each window expr in the Project
#                with a `col_ref(<output_name>)`.
#     Future-proofing: the current SDK never builds a Project containing
#     EXPR_WINDOW_FN (the SDK's `with_column` fast-path lowers directly
#     to PartitionBy). This pattern catches a future `df.select(<exprs>)`
#     overload OR a chain that lands EXPR_WINDOW_FN inside a Project via
#     `merge_projects`.
#
#   Pattern B -- Adjacent PartitionBy nodes with matching triple.
#     Trigger:   PartitionBy(pkeys=A, okeys=B, desc=C, pexprs=[e1])
#                  PartitionBy(pkeys=A, okeys=B, desc=C, pexprs=[e2])
#                    child
#     Rewrite:   PartitionBy(pkeys=A, okeys=B, desc=C, pexprs=[e2, e1])
#                  child
#     This is the empirically-load-bearing pattern today: chained
#     `.with_column(window).with_column(window)` with the same `.over(...)`
#     produces adjacent PartitionBy nodes that this rule fuses into one.
#     Co-locates the partitioning pass + sort + frame-walk into a single
#     execution.
#
#   Pattern C -- Redundant post-window Sort elision.
#     Trigger:   Sort(keys=K, desc=A)
#                  PartitionBy(pkeys=P, okeys=O, desc=D, ...)
#                    child
#     Rewrite:   PartitionBy(...)   <-- Sort dropped
#                  child
#     when K is a PREFIX of (P ++ O) AND A matches the sort directions
#     implied by the PartitionBy (P keys are always ASC in the sink; O
#     keys use D directly) AND the sink DECLARES that it emits that order
#     (`PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER`). A sort by a prefix of
#     an already-sorted-on-prefix order is a no-op.
#     ⛔ THE DECLARATION IS LOAD-BEARING AND IT IS READ, NOT ASSUMED — see
#     the Pattern C section below. This rule shipped a silent-wrong for
#     three and a half months because it asserted an ordering guarantee
#     about a driver that had not been written yet.
#     A running or rolling window query that ends with a `Sort` on its
#     window keys (`PartitionBy(user_id, ts)` then `Sort(user_id, ts)`)
#     would sort rows that are already in that order a second time; this
#     pattern removes that second sort.
#     Plan-shape conservative gate: only fire on Sort directly above
#     PartitionBy. We never elide a Sort separated by an intermediate
#     Project / Filter / etc., even if the keys would still match — the
#     intermediate node may invalidate the row order (e.g. a Project that
#     drops a sort key is fine, but conservatively we don't claim it).
#
# Pipeline order: run AFTER `late_materialize` and BEFORE
# `fuse_partition_topn`. That order guarantees:
#   * The Project pattern fires after `merge_projects` has had a chance
#     to consolidate adjacent Projects (so we don't redundantly walk
#     intermediate Project layers).
#   * The PartitionBy fusion fires before `fuse_partition_topn`, which
#     consumes a *single* PartitionBy + Filter shape and would otherwise
#     miss a fusion opportunity if the rule ran after.
#
# Why a plain recursive walker: this rule is a pure plan transform with NO
# FileHandle reach (no `execute_plan_on_session`, no `precompute_*`).
# The compiler trap this avoids needs three legs: parametric +
# recursive + FileHandle reach. This rule has neither parametric origins
# (no OptimizerContext) nor FileHandle reach, so a straightforward
# recursive `def` walker is safe -- no 3-phase hoist (non-parametric /
# parametric / non-parametric split) is needed here.
#
# Correctness invariants:
#   * Per-key descending list is part of the equivalence triple. Two
#     window exprs with the same partition_by + order_by but different
#     descending flags are NOT co-locatable (different sort directions).
#   * Output column names are preserved verbatim. The
#     PartitionExpr.alias_name carries the user's `.alias("...")` choice;
#     the Project's replacement col_ref points at that name.
#   * If a Project expr is `Alias(window_fn, "name")`, the alias name
#     becomes the PartitionExpr.alias_name AND the Project's col_ref
#     name. The Alias node itself is dropped (the PartitionBy already
#     names the column).
#   * If a Project expr is a bare `EXPR_WINDOW_FN` (no alias), the
#     PartitionExpr generates `_w<idx>_<func>` per
#     `partition_expr_output_field`; the Project's col_ref uses that
#     same generated name.
#
# Edge case: two windows with the same partition_by but a different
# order_by (or descending) are separate groups; they are not merged.
# =============================================================================

from std.memory import OwnedPointer

from komira_exec_types.partition_by_output_contract import (
    PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER,
)

from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_ALIAS,
    EXPR_WINDOW_FN,
    WindowFnData,
)
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_expr.null_order_policy import derived_nulls_first
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_PROJECT,
    PLAN_PARTITION_BY,
    PLAN_FILTER,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_SCAN,
)
from komira_plan_expr.partition_expr import (
    PartitionExpr,
    partition_expr_output_field,
    PF_RANK, PF_ROW_NUMBER, PF_DENSE_RANK, PF_PERCENT_RANK,
    PF_CUME_DIST, PF_NTILE, PF_LAG, PF_LEAD,
    PF_FIRST_VALUE, PF_LAST_VALUE, PF_NTH_VALUE,
    PF_SUM, PF_AVG, PF_MIN, PF_MAX, PF_COUNT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.plan_helpers import _copy_plan, _copy_schema, _copy_expr_array


# =============================================================================
# Triple-equality helpers -- (partition_by, order_by, descending)
# =============================================================================
#
# Two window expressions are co-locatable iff their (partition_by,
# order_by, descending) triples match exactly (same lists, same per-key
# direction). Mojo lists don't have value-equality out of the box for
# String-element form so we open-code the comparator.

def _str_lists_equal(a: List[String], b: List[String]) -> Bool:
    """Element-wise equality on two lists of String."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _bool_lists_equal(a: List[Bool], b: List[Bool]) -> Bool:
    """Element-wise equality on two lists of Bool."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _triples_equal(
    pa: List[String], oa: List[String], da: List[Bool],
    pb: List[String], ob: List[String], db: List[Bool],
) -> Bool:
    """True iff (pa, oa, da) == (pb, ob, db) as flat lists."""
    if not _str_lists_equal(pa, pb):
        return False
    if not _str_lists_equal(oa, ob):
        return False
    return _bool_lists_equal(da, db)


# =============================================================================
# Window-expr classification + name resolution
# =============================================================================
#
# The optimizer's own window-expression tests. Both helpers are
# non-parametric pure walkers and consume the Expr by ref.

def _is_window_or_alias_window(expr_ref: Expr) -> Bool:
    """True if `expr_ref` is `EXPR_WINDOW_FN` directly OR
    `Alias(EXPR_WINDOW_FN, ...)`."""
    if expr_ref.tag == EXPR_WINDOW_FN:
        return True
    if expr_ref.tag == EXPR_ALIAS:
        return expr_ref.alias_child_ref().tag == EXPR_WINDOW_FN
    return False


def _project_has_window_fn(plan_ref: LogicalPlan) -> Bool:
    """True iff plan is a Project node containing 1+ EXPR_WINDOW_FN exprs."""
    if plan_ref.tag != PLAN_PROJECT:
        return False
    ref pd = plan_ref.project_data_ref()
    for i in range(len(pd.exprs)):
        if _is_window_or_alias_window(pd.exprs[i]):
            return True
    return False


def _partition_by_over_partition_by(plan_ref: LogicalPlan) -> Bool:
    """True iff plan is `PartitionBy(child=PartitionBy(...))`."""
    if plan_ref.tag != PLAN_PARTITION_BY:
        return False
    return plan_ref.partition_by_data_ref().child[].tag == PLAN_PARTITION_BY


# =============================================================================
# WindowFnData -> PartitionExpr
# =============================================================================
#
# Builds the PartitionBy node's expression from a window function.

def _window_fn_to_partition_expr(
    w: WindowFnData,
    var alias_name: String,
) raises -> PartitionExpr:
    """Convert a WindowFnData payload to a PartitionExpr ready for
    `LogicalPlan.partition_by`. `alias_name` is the user's `.alias()`
    output column name (empty string -> PartitionExpr generates
    `_w<idx>_<func>` per `partition_expr_output_field`).

    Mojo 0.26.3 forbids partial-move out of struct fields, so we
    deep-copy the `arg_col` and `frame` fields rather than trying to
    transfer ownership. The cost is one String alloc + one
    PartitionFrame copy per call -- negligible vs the optimization
    benefit of co-locating windows.
    """
    return PartitionExpr(
        w.func,
        w.arg_col.copy(),
        w.arg_offset,
        ScalarValue(),
        False,
        w.frame.copy(),
        alias_name^,
    )


# =============================================================================
# Output-name preview (for the Project replacement col_refs)
# =============================================================================
#
# The replacement col_ref needs the SAME output column name that the
# PartitionBy node will produce for this PartitionExpr. The name is
# determined by `partition_expr_output_field` -- either the user's
# `alias_name` (if non-empty) or `_w<idx>_<func>`. We preview that name
# here so the Project's expr list can reference it.

def _preview_partition_expr_name(
    pexpr_ref: PartitionExpr,
    expr_idx: Int,
) -> String:
    """Compute the output column name that `partition_expr_output_field`
    will assign to this `pexpr_ref` at position `expr_idx` in the
    PartitionBy node's pexprs list."""
    if pexpr_ref.alias_name.byte_length() > 0:
        return pexpr_ref.alias_name.copy()
    var base: String
    if pexpr_ref.func == PF_ROW_NUMBER:
        base = "row_number"
    elif pexpr_ref.func == PF_RANK:
        base = "rank"
    elif pexpr_ref.func == PF_DENSE_RANK:
        base = "dense_rank"
    elif pexpr_ref.func == PF_PERCENT_RANK:
        base = "percent_rank"
    elif pexpr_ref.func == PF_CUME_DIST:
        base = "cume_dist"
    elif pexpr_ref.func == PF_NTILE:
        base = "ntile"
    elif pexpr_ref.func == PF_LAG:
        base = "lag"
    elif pexpr_ref.func == PF_LEAD:
        base = "lead"
    elif pexpr_ref.func == PF_FIRST_VALUE:
        base = "first_value"
    elif pexpr_ref.func == PF_LAST_VALUE:
        base = "last_value"
    elif pexpr_ref.func == PF_NTH_VALUE:
        base = "nth_value"
    elif pexpr_ref.func == PF_SUM:
        base = "sum"
    elif pexpr_ref.func == PF_COUNT:
        base = "count"
    elif pexpr_ref.func == PF_AVG:
        base = "avg"
    elif pexpr_ref.func == PF_MIN:
        base = "min"
    else:  # PF_MAX
        base = "max"
    return "_w" + String(expr_idx) + "_" + base


# =============================================================================
# WindowGroup -- a (triple, [pexprs]) bucket
# =============================================================================
#
# One bucket per unique (partition_by, order_by, descending) triple
# discovered in a Project's expr list (Pattern A) or via PartitionBy
# adjacency (Pattern B). The bucket holds the PartitionExprs that should
# be co-located into a single PartitionBy node, plus the output names
# in pexpr-ordering so the Project's replacement col_refs can target
# them.
#
# Movable-only because List[PartitionExpr] / List[String] are heap-
# owning. Stored inside `Slab[WindowGroup]` (same shape as
# `optimizer_scalar_broadcast.ScalarBroadcastSite`).

struct WindowGroup(Movable):
    var partition_by: List[String]
    var order_by: List[String]
    var descending: List[Bool]
    var pexprs: List[PartitionExpr]
    # output_names[i] is the column name that pexprs[i] will produce
    # (after being placed at position i in the final PartitionBy's
    # pexpr list; `_preview_partition_expr_name` is the source of truth).
    var output_names: List[String]

    def __init__(
        out self,
        var partition_by: List[String],
        var order_by: List[String],
        var descending: List[Bool],
    ):
        self.partition_by = partition_by^
        self.order_by = order_by^
        self.descending = descending^
        self.pexprs = List[PartitionExpr]()
        self.output_names = List[String]()


# =============================================================================
# Pattern A -- Project containing EXPR_WINDOW_FN exprs
# =============================================================================
#
# One pass over the Project's expr list:
#   1. Walk exprs left-to-right.
#   2. For each window-fn expr, peel any Alias wrap to capture the
#      user's chosen name. Look up an existing WindowGroup whose triple
#      matches (partition_by, order_by, descending); if none, append a
#      new group.
#   3. Convert the WindowFnData to a PartitionExpr; append to the
#      group's pexprs. Record the output name (alias OR generated)
#      via `_preview_partition_expr_name` (using the position the
#      pexpr will land at in the FINAL group, NOT the per-call append
#      index -- single-group case has them coincide; multi-group has
#      separate counters per group, which `_preview_partition_expr_name`
#      handles via the `expr_idx` arg).
#   4. Build the rewritten Project: replace each window-fn expr with
#      `Expr.col_ref(output_name)`; non-window exprs pass through.
#   5. Stack the WindowGroups into PartitionBy nodes above the child
#      plan: innermost group is the FIRST one discovered (that order
#      preserves user-visible read-order semantics for adjacent
#      PartitionBy execution).

def _rewrite_project_with_windows(var plan: LogicalPlan) raises -> LogicalPlan:
    """Pattern A driver. Caller has verified `plan.tag == PLAN_PROJECT`
    and the Project contains 1+ EXPR_WINDOW_FN exprs.

    The Project's child is recursively descended FIRST (so nested
    Project-with-windows OR adjacent PartitionBy-PartitionBy in the
    child also get rewritten). After descent, this Project is rewritten
    in-place: window exprs become col_refs into the new PartitionBy
    layer(s) inserted between this Project and its descended child.
    """
    # Recurse into child first (post-order rewrite).
    var rewritten_child = optimize_window_rewrite(
        _copy_plan(plan.project_data_ref().child[])
    )

    # ⛔ A WINDOW ALIASED TO A NAME THE CHILD ALREADY HAS (2026-09-24).
    # The PartitionBy APPENDS its output, so `max(v) OVER (g) AS v` over
    # [k, g, v] made [k, g, v, v] and the col_ref below resolved to the CHILD's
    # `v`: `with_columns(col("v").max().over("g").alias("v"))` answered the
    # ORIGINAL column, silently (polars 1.44.2 and DuckDB 1.5.3 answer the group
    # max). Such a window is computed under an INTERNAL name and the Project
    # aliases it back, so the Project's output is the user's name.
    var child_names = List[String]()
    for ci in range(rewritten_child.output_schema.num_columns()):
        child_names.append(rewritten_child.output_schema.field_name(ci))

    # Walk the expr list and bucketize window-fns by triple.
    # WindowGroup is Movable-only (heap-owning List fields), so use Slab
    # not List (which requires Copyable).
    var groups = Slab[WindowGroup]()
    var new_exprs = ExprArray()
    ref pd = plan.project_data_ref()
    for i in range(len(pd.exprs)):
        ref e = pd.exprs[i]
        if not _is_window_or_alias_window(e):
            new_exprs.append(e.copy())
            continue

        # Peel Alias if present and capture the user's chosen name.
        var alias_name = String("")
        var inner_window_data: WindowFnData
        if e.tag == EXPR_ALIAS:
            alias_name = e.alias_name()
            inner_window_data = e.alias_child_ref().window_fn_data_ref().copy()
        else:
            inner_window_data = e.window_fn_data_ref().copy()

        # Find or create a group with this triple.
        var group_idx: Int = -1
        for gi in range(len(groups)):
            if _triples_equal(
                groups[gi].partition_by,
                groups[gi].order_by,
                groups[gi].descending,
                inner_window_data.partition_by,
                inner_window_data.order_by,
                inner_window_data.descending,
            ):
                group_idx = gi
                break

        if group_idx < 0:
            var new_group = WindowGroup(
                inner_window_data.partition_by.copy(),
                inner_window_data.order_by.copy(),
                inner_window_data.descending.copy(),
            )
            groups.append(new_group^)
            group_idx = len(groups) - 1

        # A user name the child already carries is SHADOWED under an
        # internal one (see `child_names` above) and aliased back below.
        var user_name = alias_name.copy()
        var shadowed = False
        if alias_name.byte_length() > 0:
            for cn in child_names:
                if cn == alias_name:
                    shadowed = True
                    break
        if shadowed:
            alias_name = String("_w_shadow_") + String(i) + String("_") + user_name

        # Append the PartitionExpr to the chosen group; capture output name.
        var pexpr_idx_in_group = len(groups[group_idx].pexprs)
        var pexpr = _window_fn_to_partition_expr(
            inner_window_data, alias_name^,
        )
        var out_name = _preview_partition_expr_name(pexpr, pexpr_idx_in_group)
        groups[group_idx].pexprs.append(pexpr^)
        groups[group_idx].output_names.append(out_name.copy())

        # Replace this Project entry with a col_ref to the output name.
        if shadowed:
            new_exprs.append(Expr.alias(Expr.col_ref(out_name^), user_name^))
        else:
            new_exprs.append(Expr.col_ref(out_name^))

    # Stack PartitionBy nodes above the descended child. Innermost
    # node = group 0 (the first discovered triple). Iterate in append
    # order so groups[0] becomes the innermost PartitionBy and
    # groups[len-1] becomes the outermost; then the Project sits on top.
    var stacked: LogicalPlan = rewritten_child^
    for gi in range(len(groups)):
        var g_pkeys = groups[gi].partition_by.copy()
        var g_okeys = groups[gi].order_by.copy()
        var g_desc = groups[gi].descending.copy()
        var g_pexprs = List[PartitionExpr]()
        for pi in range(len(groups[gi].pexprs)):
            g_pexprs.append(groups[gi].pexprs[pi].copy())
        stacked = LogicalPlan.partition_by(
            g_pkeys^, g_okeys^, g_desc^, g_pexprs^, stacked^,
        )

    return LogicalPlan.project(new_exprs^, stacked^)


# =============================================================================
# Pattern B -- adjacent PartitionBy nodes with matching triple
# =============================================================================
#
# When two PartitionBy nodes are adjacent and share the same
# (partition_keys, order_keys, descending) triple, fuse them: keep the
# OUTER node's structure but extend its pexprs list with the INNER
# node's pexprs, then drop the inner PartitionBy by promoting its
# child.
#
# Pexpr ordering: outer's pexprs come AFTER inner's (innermost
# PartitionBy in the original plan executes first; when both windows
# share a triple, the engine evaluates them in append order, so
# inner -> outer order matches the original plan's execution order).

def _fuse_adjacent_partition_bys(var plan: LogicalPlan) raises -> LogicalPlan:
    """Pattern B driver. Caller has verified
    `_partition_by_over_partition_by(plan)`.

    Returns a fused PartitionBy if the triples match — re-examined by the
    rule, so a deeper stack with the same triple keeps fusing down to ONE
    node — else recurses once into the inner PartitionBy and rebuilds.
    """
    ref outer = plan.partition_by_data_ref()
    ref inner = outer.child[].partition_by_data_ref()

    if _triples_equal(
        outer.partition_keys, outer.order_keys, outer.descending,
        inner.partition_keys, inner.order_keys, inner.descending,
    ):
        # Triples match: fuse into one PartitionBy.
        var fused_pkeys = outer.partition_keys.copy()
        var fused_okeys = outer.order_keys.copy()
        var fused_desc = outer.descending.copy()
        # Inner pexprs first (executed first in original plan), then
        # outer pexprs.
        var fused_pexprs = List[PartitionExpr]()
        for i in range(len(inner.partition_exprs)):
            fused_pexprs.append(inner.partition_exprs[i].copy())
        for i in range(len(outer.partition_exprs)):
            fused_pexprs.append(outer.partition_exprs[i].copy())
        # Promote the inner's child as the fused node's child, then RE-RUN THE
        # RULE ON THE FUSED NODE so a deeper stack keeps fusing.
        #
        # ⛔ IT REWROTE ONLY THE GRANDCHILD UNTIL 2026-09-24.
        # The SQL binder builds ONE PartitionBy per window
        # SELECT item, so three windows over one OVER clause arrive as
        # PB3(PB2(PB1(scan))); fusing the top pair and then rewriting PB1 alone
        # left PB32(PB1(scan)) — a window whose child is a window, which the
        # window executor refuses as an out-of-envelope shape. So
        # every 3+-window SQL SELECT over one OVER clause REFUSED while two
        # windows answered. Each fuse removes one node, so this terminates.
        var grandchild = _copy_plan(inner.child[])
        var fused = LogicalPlan.partition_by(
            fused_pkeys^, fused_okeys^, fused_desc^,
            fused_pexprs^, grandchild^,
        )
        return optimize_window_rewrite(fused^)

    # Triples don't match: recurse into the inner; rebuild the outer.
    var inner_copy = _copy_plan(outer.child[])
    var rewritten_inner = optimize_window_rewrite(inner_copy^)
    var outer_pkeys = outer.partition_keys.copy()
    var outer_okeys = outer.order_keys.copy()
    var outer_desc = outer.descending.copy()
    var outer_pexprs = List[PartitionExpr]()
    for i in range(len(outer.partition_exprs)):
        outer_pexprs.append(outer.partition_exprs[i].copy())
    return LogicalPlan.partition_by(
        outer_pkeys^, outer_okeys^, outer_desc^,
        outer_pexprs^, rewritten_inner^,
    )


# =============================================================================
# Pattern C -- redundant post-window Sort elision
# =============================================================================
#
# Sort(keys=K, desc=A) above PartitionBy(pkeys=P, okeys=O, desc=D, ...).
#
# ⛔ THE PREMISE IS NOT A PROPERTY OF ONE FUNCTION — IT IS A CONTRACT OVER
# EVERY DRIVER THE SINK CAN ROUTE TO, AND WHICH ONE RUNS IS DECIDED AT
# RUNTIME BY ROW COUNT. `_execute_partition_by_sink` sorts by `(P ++ O)`
# and writes output aligned to that layout, but `PartitionBySink` routes
# through `_execute_partition_by_sink_parallel`, which above 65,536 rows
# hands off to a third driver this file has never seen. Previously
# that third driver emitted bucket order and this rule
# deleted the Sort anyway.
#
# So the premise is READ, not assumed:
# `komira_exec_types.partition_by_output_contract` declares
# `PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER`, every driver has to satisfy
# it on BOTH sides of the routing threshold, and False here disables this
# rule rather than corrupting the answer.
#
# When the contract holds, the output is sorted by `(P ++ O)` with
# directions `([False]*|P| ++ D)`.
#
# A subsequent `Sort(K, A)` is a no-op when K is a PREFIX of (P ++ O)
# AND A matches the corresponding prefix of the implied direction list
# AND each key's NULL placement is the sink's derived one
# (`derived_nulls_first` of the key's direction). In that case the Sort can be dropped entirely.
#
# Conservative gate -- when this rule does NOT fire:
#   * Sort node is NOT directly above PartitionBy (intermediate Project
#     or Filter -- conservatively defer; the intermediate node may
#     invalidate the row order even if keys would still match).
#   * K is not a prefix of (P ++ O), e.g. K reorders P or includes a
#     column not in (P ++ O).
#   * Direction mismatch on any key in K.
#   * NULL placement mismatch on any key in K (an explicit NULLS FIRST /
#     NULLS LAST the sink's derived placement does not produce).
#   * P or O is empty (degenerate cases; the partition-by sort path
#     skips the sort when `len(sort_keys) == 0`, so the post-window
#     order isn't guaranteed).
#
# Stability: the engine's `sort_batch_by_keys` is a stable sort on its
# composite key, so when the user's K is a strict prefix the output
# tie-break order beyond K is the original input row order from the
# parquet scan. The PartitionBy's own internal sort uses the FULL
# `(P ++ O)` key, so post-window the rows ARE ordered by the full key
# AND ties beyond K are broken by (the rest of P ++ O) — strictly
# more specific than the user's request. Standard prefix-elision
# semantics: "sort by K" is satisfied by "sort by (K ++ extras)" as
# long as K is a prefix.

def _sort_over_partition_by(plan_ref: LogicalPlan) -> Bool:
    """True iff plan is `Sort(child=PartitionBy(...))`."""
    if plan_ref.tag != PLAN_SORT:
        return False
    return plan_ref.sort_data_ref().child[].tag == PLAN_PARTITION_BY


def _sort_keys_redundant_after_partition_by(
    sort_keys: List[String],
    sort_desc: List[Bool],
    sort_nulls_first: List[Bool],
    partition_keys: List[String],
    order_keys: List[String],
    pb_desc: List[Bool],
) -> Bool:
    """True iff `(sort_keys, sort_desc, sort_nulls_first)` is a prefix of
    the row order implied by `_execute_partition_by_sink`'s internal sort:
    `(partition_keys ++ order_keys)` with directions
    `([False]*|partition_keys| ++ pb_desc)` and, per key, the NULL placement
    `derived_nulls_first(direction)` (a PartitionBy carries no explicit NULL
    placement, so its sink derives it).

    Returns False on:
      * `PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER` being False — the sink
        drivers do not promise that order, so there is no order to be
        redundant WITH. See below.
      * sort_keys/sort_desc/sort_nulls_first length mismatch (defensive).
      * Empty partition_keys AND order_keys (no internal sort run).
      * sort_keys longer than (partition_keys ++ order_keys).
      * Any sort_keys[i] != implied_keys[i].
      * Any sort_desc[i] != implied_desc[i].
      * Any sort_nulls_first[i] != derived_nulls_first(implied_desc[i]).
    """
    # ⛔ THE PREMISE, READ FROM THE OPERATORS PACKAGE RATHER THAN ASSUMED.
    # This rule is only sound because every PartitionBy sink driver emits
    # `(P ++ O)` order. That used to be an invariant this file asserted
    # about code it cannot see, and a new driver broke it 13
    # hours after this rule landed — three and a half months of windowed
    # queries silently ignoring their `ORDER BY`. The declaration now lives
    # in `komira_exec_types.partition_by_output_contract`, and flipping it
    # False turns this elision off instead of turning the answer wrong.
    #
    # Comptime-constant condition: folds away entirely when True.
    if not PARTITION_BY_SINK_EMITS_GLOBAL_KEY_ORDER:
        return False

    var n_sort = len(sort_keys)
    if n_sort != len(sort_desc) or n_sort != len(sort_nulls_first):
        return False
    if n_sort == 0:
        # An empty Sort is a degenerate shape -- defer; the recursive
        # walker handles non-trigger nodes via _recurse_into_children.
        return False
    var n_pk = len(partition_keys)
    var n_ok = len(order_keys)
    if n_pk == 0 and n_ok == 0:
        # Internal sort is skipped (`if len(sort_keys) == 0: sorted_batch
        # = batch^` in partition_scan_sink). Output order is NOT
        # guaranteed; cannot elide.
        return False
    if len(pb_desc) != n_ok:
        # Defensive: the SDK guarantees this invariant, but guard
        # against malformed plans.
        return False
    var n_implied = n_pk + n_ok
    if n_sort > n_implied:
        return False

    # Check prefix equality on (key, direction) pairs.
    for i in range(n_sort):
        var implied_key: String
        var implied_dir: Bool
        if i < n_pk:
            implied_key = partition_keys[i]
            implied_dir = False  # partition keys always ASC
        else:
            implied_key = order_keys[i - n_pk]
            implied_dir = pb_desc[i - n_pk]
        if sort_keys[i] != implied_key:
            return False
        if sort_desc[i] != implied_dir:
            return False
        if sort_nulls_first[i] != derived_nulls_first(implied_dir):
            return False
    return True


def _elide_sort_over_partition_by(var plan: LogicalPlan) raises -> LogicalPlan:
    """Pattern C driver. Caller has verified `_sort_over_partition_by(plan)`.

    Checks the prefix-equality predicate; if it holds, returns the inner
    PartitionBy (with its child recursively window-rewritten). Otherwise
    rebuilds the Sort with a window-rewritten PartitionBy as its child.
    """
    ref sd = plan.sort_data_ref()
    ref pb = sd.child[].partition_by_data_ref()

    if _sort_keys_redundant_after_partition_by(
        sd.keys, sd.descending, sd.nulls_first,
        pb.partition_keys, pb.order_keys, pb.descending,
    ):
        # Drop the Sort. Re-run the rule on the resulting PartitionBy
        # plan so any deeper Pattern A / B / C triggers (e.g. a
        # PartitionBy-over-PartitionBy that Pattern B would now fuse)
        # also fire. We construct the PartitionBy from the inner pb's
        # fields and a deep-copy of its child, then hand it back to
        # `optimize_window_rewrite` for further descent.
        var pb_plan = _copy_plan(sd.child[])
        return optimize_window_rewrite(pb_plan^)

    # Predicate failed: keep the Sort, but recurse into its child
    # (which is a PartitionBy -- may itself have nested patterns).
    var pb_copy = _copy_plan(sd.child[])
    var rewritten_pb = optimize_window_rewrite(pb_copy^)
    var sort_keys = sd.keys.copy()
    var sort_desc = sd.descending.copy()
    # Carry the EXPLICIT NULL
    # placement; omitting it silently re-derives the DEFAULT
    # (`null_order_policy.derived_nulls_first`).
    var sort_nf = Optional(sd.nulls_first.copy())
    return LogicalPlan.sort(sort_keys^, sort_desc^, rewritten_pb^, sort_nf^)


# =============================================================================
# Public entry -- optimize_window_rewrite
# =============================================================================
#
# The rule's public entry. Walks the plan tree top-down; at each node:
#   * Project-with-window-fns           -> Pattern A rewrite, then recurse
#                                          (the rewrite path itself
#                                          handles the recursion).
#   * PartitionBy(PartitionBy)          -> Pattern B rewrite, then recurse
#                                          (the rewrite path itself
#                                          handles the recursion).
#   * Sort(PartitionBy)                 -> Pattern C check; elide if Sort
#                                          keys+desc+nulls are a prefix of
#                                          the PartitionBy's implied order.
#   * Other shapes                       -> recurse into children, rebuild.
#
# Non-parametric, recursive, NO FileHandle reach -- safe to be a single
# `def`. A 3-phase hoist (non-parametric/parametric/
# non-parametric split) is not required here because the rule has no
# OptimizerContext / EngineContext / FileHandle reach.

def optimize_window_rewrite(var plan: LogicalPlan) raises -> LogicalPlan:
    """Window rewrite rule entry: multi-window co-location +
    redundant post-window-sort elision.

    Three patterns trigger:
      A. Project containing 1+ EXPR_WINDOW_FN exprs (incl. via Alias).
      B. Adjacent PartitionBy nodes with matching (partition_keys,
         order_keys, descending) triple.
      C. Sort(PartitionBy(...)) where Sort keys+desc+nulls are a prefix
         of the PartitionBy's implied output order.

    Returns a (possibly) rewritten plan. No-ops when the plan contains
    none of these patterns. Safe to call on any plan; recurses into
    children.
    """
    if _project_has_window_fn(plan):
        return _rewrite_project_with_windows(plan^)

    if _partition_by_over_partition_by(plan):
        return _fuse_adjacent_partition_bys(plan^)

    if _sort_over_partition_by(plan):
        return _elide_sort_over_partition_by(plan^)

    # No trigger at this node -- recurse into children.
    return _recurse_into_children(plan^)


def _recurse_into_children(var plan: LogicalPlan) raises -> LogicalPlan:
    """Walk children, rewriting each, then rebuild the parent. Pure
    non-parametric recursion. Pass-through for leaf shapes (Scan)."""
    if plan.tag == PLAN_SCAN:
        return plan^

    if plan.tag == PLAN_FILTER:
        var child = optimize_window_rewrite(_copy_plan(plan.filter_data_ref().child[]))
        var pred = plan.filter_data_ref().predicate.copy()
        return LogicalPlan.filter(pred^, child^)

    if plan.tag == PLAN_PROJECT:
        # Project WITHOUT EXPR_WINDOW_FN -- just descend into its child.
        var child = optimize_window_rewrite(_copy_plan(plan.project_data_ref().child[]))
        var exprs = _copy_expr_array(plan.project_data_ref().exprs)
        return LogicalPlan.project(exprs^, child^)

    if plan.tag == PLAN_AGGREGATE:
        var child = optimize_window_rewrite(_copy_plan(plan._aggregate.value()[].child[]))
        var gb = _copy_expr_array(plan._aggregate.value()[].group_by)
        var aggs = AggExprArrayCopyHelper.copy(plan._aggregate.value()[].agg_exprs)
        return LogicalPlan.aggregate(gb^, aggs^, child^)

    if plan.tag == PLAN_JOIN:
        var left = optimize_window_rewrite(_copy_plan(plan._join.value()[].left[]))
        var right = optimize_window_rewrite(_copy_plan(plan._join.value()[].right[]))
        # Preserve `residual` across this recurse-rebuild.
        var join_resid: Optional[OwnedPointer[Expr]] = None
        ref jd = plan._join.value()[]
        if jd.has_residual():
            join_resid = OwnedPointer(jd.residual.value()[].copy())
        return LogicalPlan.join(
            left^, right^,
            jd.left_on.copy(),
            jd.right_on.copy(),
            jd.join_type,
            jd.algo_hint,
            join_resid^,
        )

    if plan.tag == PLAN_SORT:
        var child = optimize_window_rewrite(_copy_plan(plan._sort.value()[].child[]))
        # Carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(
            plan._sort.value()[].keys.copy(),
            plan._sort.value()[].descending.copy(),
            child^,
            nf_copy^,
        )

    if plan.tag == PLAN_LIMIT:
        var child = optimize_window_rewrite(_copy_plan(plan._limit.value()[].child[]))
        # Forward the RANGE offset, don't drop it on rebuild.
        ref ld = plan._limit.value()[]
        return LogicalPlan.limit(ld.n, child^, offset=ld.offset)

    if plan.tag == PLAN_DISTINCT:
        var child = optimize_window_rewrite(_copy_plan(plan._distinct.value()[].child[]))
        var cols: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols^, child^)

    if plan.tag == PLAN_TOPN:
        var child = optimize_window_rewrite(_copy_plan(plan._topn.value()[].child[]))
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

    if plan.tag == PLAN_PARTITION_BY:
        # Single PartitionBy (not adjacent) -- recurse into its child.
        var child = optimize_window_rewrite(_copy_plan(plan.partition_by_data_ref().child[]))
        var pk = plan.partition_by_data_ref().partition_keys.copy()
        var ok = plan.partition_by_data_ref().order_keys.copy()
        var desc = plan.partition_by_data_ref().descending.copy()
        var pexprs = List[PartitionExpr]()
        for i in range(len(plan.partition_by_data_ref().partition_exprs)):
            pexprs.append(plan.partition_by_data_ref().partition_exprs[i].copy())
        return LogicalPlan.partition_by(pk^, ok^, desc^, pexprs^, child^)

    if plan.tag == PLAN_PARTITION_TOPN:
        var child = optimize_window_rewrite(_copy_plan(plan._partition_topn.value()[].child[]))
        # Preserve func, over_fetch_k and output_rank_col_name through
        # the window rewrite.
        var rank_col_copy: Optional[String] = None
        ref ptd = plan._partition_topn.value()[]
        if ptd.output_rank_col_name:
            rank_col_copy = String(ptd.output_rank_col_name.value())
        return LogicalPlan.partition_topn(
            ptd.partition_keys.copy(),
            ptd.sort_keys.copy(),
            ptd.descending.copy(),
            ptd.k,
            child^,
            ptd.func,
            ptd.over_fetch_k,
            rank_col_copy^,
        )

    if plan.tag == PLAN_ASOF_JOIN:
        ref aj = plan._asof_join.value()[]
        var left = optimize_window_rewrite(_copy_plan(aj.left[]))
        var right = optimize_window_rewrite(_copy_plan(aj.right[]))
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

    # Unknown tag: pass through.
    return plan^


# =============================================================================
# AggExpr-array deep-copy helper (same as plan_helpers._copy_agg_expr_array)
# =============================================================================
#
# A local copy of `komira_plan_ir.plan_helpers._copy_agg_expr_array`, which
# this module does not import. Inline the deep-copy via a struct
# staticmethod so the call site stays one-line.

struct AggExprArrayCopyHelper:
    @staticmethod
    def copy(arr: AggExprArray) -> AggExprArray:
        """Deep-copy an AggExprArray — ALL child slots (mirrors
        `plan_helpers._copy_agg_expr_array`; uses `AggExpr.copy()` so the
        bivariate/multivariate child1..child3 slots are PRESERVED). The prior
        3-arg-ctor rebuild silently dropped child1..child3."""
        var result = AggExprArray()
        for i in range(len(arr)):
            result.append(arr[i].copy())
        return result^
