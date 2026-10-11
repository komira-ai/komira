# =============================================================================
# Partial aggregate pushdown below inner join (v0.3 -> v0.4 port)
# =============================================================================
#
# SHIP-DISABLED-BY-DEFAULT — see ENABLE_AGG_PUSHDOWN_BELOW_JOIN below.
#
# v0.3 has the equivalent rule but it is dead code
# in v0.3: nothing in v0.3 that orders its passes calls it (only tests do)
# because v0.3 lacks the uniqueness metadata required to fire safely on
# arbitrary plans. v0.4 mirrors that dormancy: the rule is present and tested
# but gated behind a comptime flag set to False. Flipping the flag to True
# without first wiring up uniqueness inference WILL produce wrong answers
# on PK-FK joins where the "other" side has duplicate join keys.
#
# Soundness gate (3 clauses, ALL must hold before the rewrite is sound):
#
#   (a) Join is INNER, with no residual (non-equi) predicate. The caller
#       checks both (join_type == JOIN_INNER and not has_residual());
#       _classify_push re-checks only the join type. We
#       still keep the explicit join_type==JOIN_INNER guard in place so a
#       future LEFT/RIGHT/SEMI/ANTI/FULL extension does not silently start
#       firing. v0.3 enforces the same condition.
#
#   (b) Every group-by key AND every aggregate-input column reference
#       resolves to ONE side of the join (call it sideB). If references
#       span both sides the rewrite is impossible because the partial
#       aggregate cannot see columns from the opposite side. Enforced by
#       the existing _all_cols_in_schema check below; mirrors the v0.3
#       rule.
#
#   (c) The OTHER side's join key is provably UNIQUE — via PK constraint,
#       distinctness inference, or an explicit DISTINCT/Aggregate sub-plan.
#       Without this proof, the join can still produce a one-to-many
#       fan-out from sideA, and a partial pre-aggregation on sideB then
#       silently double-counts when the merge agg above the join replays
#       the (possibly duplicated) partial groups. v0.3's rule
#       has no such gate which is precisely why v0.3 leaves this rule out
#       of the production pipeline. v0.4 makes the gate explicit so that
#       the day uniqueness infra (table stats, PK metadata, distinctness
#       analysis) lands, this rule can be flipped on by toggling
#       ENABLE_AGG_PUSHDOWN_BELOW_JOIN to True without further surgery.
#
# UDAF rejection (as in v0.3):
#   v0.4's AggExpr enum has no UDAF tag — UDAFs literally cannot exist in
#   the IR today, so this rejection is structurally vacuous. Any future
#   UDAF tag MUST be explicitly excluded from the whitelist; see
#   _is_whitelisted_agg below.
#
# AVG decomposition (as in v0.3):
#   AVG cannot be partially aggregated as a single accumulator (the partial
#   AVG of two halves is not the AVG of the whole). v0.3 splits AVG into
#   partial SUM(input) + partial COUNT(input), then exposes those as two
#   merge SUMs aliased "__partial_avg_sum_{out}" and
#   "__partial_avg_count_{out}". The downstream consumer is responsible
#   for the final division. No rewriter in this tree consumes the exposed
#   sum+count pair, so a fired rewrite over an AVG would leave the plan
#   without the AVG's output column. The whitelist permits AVG to keep parity with
#   v0.3 BUT the rule never fires in practice while the gate is False, so
#   the AVG arm is reachable only from explicit gate-bypassing tests.
#
# Original v0.4 file header preserved below for context.
#
# =============================================================================
# Partial aggregate pushdown below inner join (v0.3 -> v0.4 port)
# =============================================================================
#
# When an Aggregate sits directly above an INNER Join and every column
# referenced by the Aggregate (group-by keys + aggregate input columns)
# comes from a SINGLE side of the join, we rewrite:
#
#     Aggregate(keys, [SUM|COUNT|MIN|MAX ...], Join(L, R))
#
# into:
#
#     MergeAggregate(keys, [SUM|SUM|MIN|MAX ...],
#         Join(
#             PartialAggregate(keys, [SUM|COUNT|MIN|MAX ...], L),
#             R
#         ))
#
# The partial aggregate collapses duplicate (group_key, join_key) rows on
# one side BEFORE the join, shrinking the probe (or build) stream. The
# merge aggregate above the join re-combines partial results that got
# duplicated by the join's one-to-many match. Merge semantics per op:
#
#     SUM   -> partial SUM,   merge SUM   (sum of partial sums)
#     COUNT -> partial COUNT, merge SUM   (sum of partial counts)
#     MIN   -> partial MIN,   merge MIN
#     MAX   -> partial MAX,   merge MAX
#
# This port intentionally stops at the v0.3 whitelist:
# SUM / COUNT / MIN / MAX, plus AVG through the SUM+COUNT decomposition
# described above. COUNT_DISTINCT and statistical accumulators are NOT
# ported -- they require merge-aware sketches (HLL, digest) that this rule
# skips to keep the surface area small. If ANY aggregate in the spec list falls outside
# the whitelist, the rule skips the entire Aggregate (partial-pushing some
# aggs and leaving others above the join would produce wrong results).
#
# Correctness gating
# ==================
#
# Even with the single-side check the rewrite is only sound when the JOIN
# KEYS on the pushed side are a subset of the group-by set. Otherwise the
# partial aggregate would strip the join keys from the pushed side's
# output schema and the join would dangle (or, worse, silently produce
# wrong answers if a synthesised column happens to match). We enforce
# this explicitly -- v0.3 relied on the implicit rule that callers only
# build plans where this holds, which is fragile. See step 4 of
# _classify_push_inner.
#
# We also avoid name collisions between the partial-agg output and the
# opposite join side: if any group-by column name already exists on the
# other side the join would suffix it with "_right" and the merge agg
# above would look for a column that no longer exists under that name.
# In that case we conservatively skip the rewrite. This matches the join
# schema construction in LogicalPlan.join().
#
# Pipeline placement
# ==================
#
# `optimizer_driver.optimize` does not run this rule. It is
# designed to run AFTER predicate pushdown (so pushed filters shrink the
# partial agg input) and BEFORE inner->semi conversion and join
# reordering (so downstream cost models see the reduced cardinality).
#
# Interaction with the existing (naive) push_aggregate_below_join rule:
# the v0.4 optimizer previously contained a simplified version in
# optimizer_join.mojo that pushed the ENTIRE Aggregate below the join
# on the left side. That version was unsound for non-trivial joins
# (it dropped the join key and skipped the merge step), so we delete it
# in favour of this partial/merge rule. The public entry-point name
# `push_aggregate_below_join` is kept.
# =============================================================================

from std.collections import Set
from std.memory import OwnedPointer

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr, EXPR_COL_REF
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
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
)
from komira_plan_ir.plan_helpers import (
    _copy_expr_array,
    _copy_agg_expr_array,
    _collect_expr_columns,
    _take_filter_child,
    _take_project_child,
    _take_aggregate_child,
    _take_join_left,
    _take_join_right,
    _take_sort_child,
    _take_limit_child,
    _take_distinct_child,
    _take_topn_child,
)


# =============================================================================
# Soundness gate
# =============================================================================
#
# Decision: ship the rule DISABLED.
# Flipping this to True without uniqueness inference will produce wrong
# answers on PK-FK joins where the OTHER side has duplicate join keys
# (the partial pre-aggregation gets fan-out-multiplied by the join, and
# the merge agg double-counts).
#
# To enable safely you must FIRST land:
#   1. Table-level PK / UNIQUE metadata on Scan nodes, OR
#   2. A distinctness analysis pass that propagates uniqueness through
#      Filter/Project/Aggregate/Distinct, OR
#   3. An explicit DISTINCT subquery wrapper on the "other" side.
# Then update _other_side_key_unique below to consult that infra.

comptime ENABLE_AGG_PUSHDOWN_BELOW_JOIN: Bool = False


def _other_side_key_unique(join_plan: LogicalPlan, push_to_left: Bool) -> Bool:
    """Soundness clause (c): is the OTHER side's join key provably unique?

    "Other side" = the side we are NOT pushing the partial aggregate to.
    If push_to_left is True we are pushing onto the LEFT child, so the
    OTHER side is the RIGHT child and we must prove RIGHT.right_on is
    unique. Symmetric for push_to_left=False.

    Returns True only when uniqueness is proven. v0.4 has no uniqueness
    infrastructure today (no PK metadata on Scan, no distinctness
    inference, no DISTINCT-subplan recognition) so this function
    UNCONDITIONALLY returns False. Once any of those land, replace the
    body with the corresponding lookup.
    """
    # SAFETY: returning False here forces _classify_push to reject every
    # candidate when the comptime gate is True. This is intentional --
    # without a uniqueness proof the rewrite is unsound on arbitrary
    # plans. See file header for the list of infra that must precede
    # flipping ENABLE_AGG_PUSHDOWN_BELOW_JOIN to True.
    _ = join_plan
    _ = push_to_left
    return False


# =============================================================================
# Top-level rule: push_aggregate_below_join
# =============================================================================

def push_aggregate_below_join(var plan: LogicalPlan) raises -> LogicalPlan:
    """Rewrite Aggregate(keys, aggs, Join(L, R)) into a partial/merge pair
    when all referenced columns come from one side of the join and every
    aggregate is in the SUM/COUNT/MIN/MAX whitelist.

    Recurses into every plan variant so nested patterns (e.g. Filter above
    Aggregate above Join) are rewritten in place. Other nodes are rebuilt
    with their children recursed; the JOIN arm rebuilds with the default
    algo_hint and no residual (push_aggregate_below_join_force keeps both).
    """
    if plan.tag == PLAN_AGGREGATE:
        # Bottom-up: rewrite children first, then try to rewrite this node.
        var child = _take_aggregate_child(plan)
        var new_child = push_aggregate_below_join(child^)

        # We only rewrite if the immediate child (after recursion) is an
        # INNER join AND all the safety checks pass. Run the checks on
        # a BORROWED view of new_child so we can fall through to the
        # rebuild path without having consumed it.
        if new_child.tag == PLAN_JOIN and new_child._join.value()[].join_type == JOIN_INNER and not new_child._join.value()[].has_residual():
            var decision = _classify_push(plan, new_child)
            if decision.kind == _PUSH_LEFT or decision.kind == _PUSH_RIGHT:
                return _perform_rewrite(  # cov: unreachable _classify_push returns _PUSH_NONE while ENABLE_AGG_PUSHDOWN_BELOW_JOIN is False
                    plan, new_child^, decision.kind == _PUSH_LEFT  # cov: unreachable see the line above
                )
            # decision.kind == _PUSH_NONE -- fall through unchanged.

        # Fall-through: rebuild the Aggregate with the (possibly recursed)
        # child unchanged. Covers non-Join child, non-Inner join, and
        # the case where all safety checks rejected the rewrite.
        var new_gb = _copy_expr_array(plan._aggregate.value()[].group_by)
        var new_aggs = _copy_agg_expr_array(plan._aggregate.value()[].agg_exprs)
        return LogicalPlan.aggregate(new_gb^, new_aggs^, new_child^)

    elif plan.tag == PLAN_FILTER:
        var child = _take_filter_child(plan)
        var pred = plan._filter.value()[].predicate.copy()
        var new_child = push_aggregate_below_join(child^)
        return LogicalPlan.filter(pred^, new_child^)

    elif plan.tag == PLAN_PROJECT:
        var child = _take_project_child(plan)
        var new_child = push_aggregate_below_join(child^)
        var new_exprs = _copy_expr_array(plan._project.value()[].exprs)
        return LogicalPlan.project(new_exprs^, new_child^)

    elif plan.tag == PLAN_JOIN:
        # preserve `residual` + `algo_hint` across this recurse-rebuild.
        var algo = plan._join.value()[].algo_hint
        var join_resid: Optional[OwnedPointer[Expr]] = None
        if plan._join.value()[].has_residual():
            join_resid = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        var left = _take_join_left(plan)
        var right = _take_join_right(plan)
        var new_left = push_aggregate_below_join(left^)
        var new_right = push_aggregate_below_join(right^)
        return LogicalPlan.join(
            new_left^,
            new_right^,
            plan._join.value()[].left_on.copy(),
            plan._join.value()[].right_on.copy(),
            plan._join.value()[].join_type,
            algo,
            join_resid^,
        )

    elif plan.tag == PLAN_SORT:
        var child = _take_sort_child(plan)
        var new_child = push_aggregate_below_join(child^)
        # carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(
            plan._sort.value()[].keys.copy(),
            plan._sort.value()[].descending.copy(),
            new_child^,
            nf_copy^,
        )

    elif plan.tag == PLAN_LIMIT:
        var child = _take_limit_child(plan)
        var new_child = push_aggregate_below_join(child^)
        # forward the RANGE offset, don't drop it on rebuild.
        # MOJO 1.0.0: `.n` and `.offset` in one call are two walks of the
        # same chain; the second invalidates the first. Bind once.
        ref ld = plan._limit.value()[]
        return LogicalPlan.limit(ld.n, new_child^, offset=ld.offset)

    elif plan.tag == PLAN_DISTINCT:
        var child = _take_distinct_child(plan)
        var new_child = push_aggregate_below_join(child^)
        var cols_copy: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols_copy = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols_copy^, new_child^)

    elif plan.tag == PLAN_TOPN:
        var child = _take_topn_child(plan)
        var new_child = push_aggregate_below_join(child^)
        # carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._topn.value()[].nulls_first.copy())
        return LogicalPlan.topn(
            plan._topn.value()[].keys.copy(),
            plan._topn.value()[].descending.copy(),
            plan._topn.value()[].n,
            new_child^,
            nf_copy^,
        )

    # Scan and unknown tags: return as-is.
    return plan^


# =============================================================================
# Core rewrite -- split into "classify" (borrows) and "perform" (consumes)
# =============================================================================
#
# Mojo ownership note: once a plan value is consumed by a helper, it is
# gone. Returning "sorry, didn't fire, here's your plan back" out of a
# helper that took `var` ownership is not possible without explicit
# return. We split the rewrite into a BORROW-only classification pass
# that decides whether the rule fires, followed by a CONSUMING rewrite
# that only runs on the success path.

comptime _PUSH_NONE: UInt8 = 0
comptime _PUSH_LEFT: UInt8 = 1
comptime _PUSH_RIGHT: UInt8 = 2


struct _PushDecision(Movable):
    """Result of _classify_push. `kind` is one of _PUSH_NONE / _PUSH_LEFT /
    _PUSH_RIGHT.
    """
    var kind: UInt8

    def __init__(out self, kind: UInt8):
        self.kind = kind

def _classify_push(
    agg_plan: LogicalPlan, join_plan: LogicalPlan
) -> _PushDecision:
    """Production classifier. Honors ENABLE_AGG_PUSHDOWN_BELOW_JOIN.

    Borrows both plans -- does not consume either. Returns _PUSH_NONE if
    the gate is disabled OR any clause-level check fails.
    """
    # --- 0. Soundness gate (ship-disabled by default) ---------------
    # See file header for the 3-clause soundness predicate. In the default
    # build the comptime branch always returns _PUSH_NONE, so the
    # classification call below is dead code at the call site (matching
    # v0.3's dormancy pattern).
    comptime if not ENABLE_AGG_PUSHDOWN_BELOW_JOIN:
        return _PushDecision(_PUSH_NONE)
    return _classify_push_inner(agg_plan, join_plan)


def _classify_push_inner(
    agg_plan: LogicalPlan, join_plan: LogicalPlan
) -> _PushDecision:
    """Gate-bypassed classifier. Runs all 3 soundness clauses but skips
    the comptime ENABLE_AGG_PUSHDOWN_BELOW_JOIN check.

    Tests use this directly to verify each clause independently. Today
    clause (c) -- _other_side_key_unique -- always rejects (no uniqueness
    infra), so for tests that want to validate the REWRITE SHAPE itself
    use _classify_push_unchecked instead.
    """
    # --- Clause (a): join must be INNER with no residual predicate -------
    # The caller already guards on join_type == JOIN_INNER but we re-check
    # here so this function is independently sound if invoked from a test.
    # JoinData can carry a residual; the caller excludes residual-carrying
    # joins, and this function does not re-check for one.
    if join_plan._join.value()[].join_type != JOIN_INNER:
        return _PushDecision(_PUSH_NONE)

    # --- 1. Whitelist check: all aggregates must be SUM/COUNT/MIN/MAX/AVG ---
    # UDAF rejection (as in v0.3): vacuous in v0.4 -- the AggExpr
    # enum has no UDAF tag. If/when one is added, _is_whitelisted_agg MUST
    # exclude it explicitly.
    var n_aggs = len(agg_plan._aggregate.value()[].agg_exprs)
    for i in range(n_aggs):
        var func = agg_plan._aggregate.value()[].agg_exprs[i].func
        if not _is_whitelisted_agg(func):
            return _PushDecision(_PUSH_NONE)

    # --- 2. Collect all column references used by the aggregate ---
    var agg_cols = Set[String]()
    var n_keys = len(agg_plan._aggregate.value()[].group_by)
    for i in range(n_keys):
        _collect_expr_columns(
            agg_plan._aggregate.value()[].group_by[i], agg_cols
        )
    for i in range(n_aggs):
        if agg_plan._aggregate.value()[].agg_exprs[i].child:
            _collect_expr_columns(
                agg_plan._aggregate.value()[].agg_exprs[i].child.value(),
                agg_cols,
            )

    if len(agg_cols) == 0:
        # Edge case: no input columns (e.g. pure COUNT(*) with no
        # group-by). Without a side-check we cannot decide where to push.
        return _PushDecision(_PUSH_NONE)

    # --- 3. Side classification ---
    var all_left = _all_cols_in_schema(
        agg_cols, join_plan._join.value()[].left[].output_schema
    )
    var all_right = _all_cols_in_schema(
        agg_cols, join_plan._join.value()[].right[].output_schema
    )

    if not all_left and not all_right:
        return _PushDecision(_PUSH_NONE)  # Columns span both sides.

    # Prefer left when a column appears in both schemas (join-key columns
    # that share a name). Matches v0.3 semantics and avoids the name
    # collision path entirely.
    var push_to_left = all_left

    # --- 4. Gating: join keys on the pushed side must be in group_by ---
    #
    # Rationale: the partial aggregate outputs only group_by + partial
    # agg outputs. If any join key on the pushed side is not in group_by,
    # it is STRIPPED and the outer join references a missing column.
    # v0.3 tolerated this because plans usually have join_keys ⊆ group_by
    # by construction, but we make the check explicit for safety.
    var gb_names = _group_by_col_names(agg_plan._aggregate.value()[].group_by)
    var side_join_keys: List[String]
    if push_to_left:
        side_join_keys = join_plan._join.value()[].left_on.copy()
    else:
        side_join_keys = join_plan._join.value()[].right_on.copy()

    if not _all_strings_in(side_join_keys, gb_names):
        return _PushDecision(_PUSH_NONE)

    # --- 5. Collision guard: partial output names vs opposite side ---
    #
    # LogicalPlan.join() builds the output schema by scanning right-side
    # names and suffixing collisions with "_right". If we push to the
    # LEFT, left names are never suffixed so we are safe. If we push to
    # the RIGHT, any group-by column that also exists on the left will
    # be renamed in the join output and the merge aggregate's column
    # reference would break. Bail out in that case.
    if not push_to_left:
        # Direct borrow through the ref chain -- no local copy of Schema.
        for i in range(len(gb_names)):
            if _schema_has_field(
                join_plan._join.value()[].left[].output_schema, gb_names[i]
            ):
                return _PushDecision(_PUSH_NONE)
        # Partial agg output names use the "__partial_*" prefix which
        # is assumed not to collide with user column names. If a user
        # ever names a column "__partial_sum_x" explicitly the merge
        # agg would also see a rename; we accept that as out-of-scope.

    # --- Clause (c): OTHER side's join key must be provably unique -------
    # Without this proof the join can fan out one-to-many from the
    # opposite side, and the partial pre-aggregation gets multiplied so
    # the merge agg above the join double-counts. See file header for
    # the list of infra that must land before _other_side_key_unique
    # can return True. Today it always returns False, so this branch
    # ALWAYS rejects -- which is the correct behaviour while uniqueness
    # inference is absent.
    if not _other_side_key_unique(join_plan, push_to_left):
        return _PushDecision(_PUSH_NONE)

    if push_to_left:  # cov: unreachable _other_side_key_unique returns False unconditionally, so the clause (c) check returns first
        return _PushDecision(_PUSH_LEFT)  # cov: unreachable see the line above
    return _PushDecision(_PUSH_RIGHT)  # cov: unreachable see the line above


def _classify_push_unchecked(
    agg_plan: LogicalPlan, join_plan: LogicalPlan
) -> _PushDecision:
    """Test-only: runs clauses (a) and (b) but SKIPS clause (c).

    Used by legacy rewrite-shape tests
    that pre-date the soundness gate. Production code MUST go through
    _classify_push. Calling this in production would silently produce
    wrong answers on PK-FK joins where the OTHER side has duplicate
    join keys.

    The implementation duplicates _classify_push_inner up to (but not
    including) the clause-(c) check. We deliberately copy the body
    instead of parameterising _classify_push_inner so a future
    soundness-clause refactor can't accidentally weaken the production
    path while editing the test path.
    """
    # Clause (a)
    if join_plan._join.value()[].join_type != JOIN_INNER:
        return _PushDecision(_PUSH_NONE)

    # Whitelist
    var n_aggs = len(agg_plan._aggregate.value()[].agg_exprs)
    for i in range(n_aggs):
        var func = agg_plan._aggregate.value()[].agg_exprs[i].func
        if not _is_whitelisted_agg(func):
            return _PushDecision(_PUSH_NONE)

    # Collect referenced columns
    var agg_cols = Set[String]()
    var n_keys = len(agg_plan._aggregate.value()[].group_by)
    for i in range(n_keys):
        _collect_expr_columns(
            agg_plan._aggregate.value()[].group_by[i], agg_cols
        )
    for i in range(n_aggs):
        if agg_plan._aggregate.value()[].agg_exprs[i].child:
            _collect_expr_columns(
                agg_plan._aggregate.value()[].agg_exprs[i].child.value(),
                agg_cols,
            )
    if len(agg_cols) == 0:
        return _PushDecision(_PUSH_NONE)

    # Clause (b)
    var all_left = _all_cols_in_schema(
        agg_cols, join_plan._join.value()[].left[].output_schema
    )
    var all_right = _all_cols_in_schema(
        agg_cols, join_plan._join.value()[].right[].output_schema
    )
    if not all_left and not all_right:
        return _PushDecision(_PUSH_NONE)
    var push_to_left = all_left

    # Side join key in group_by
    var gb_names = _group_by_col_names(agg_plan._aggregate.value()[].group_by)
    var side_join_keys: List[String]
    if push_to_left:
        side_join_keys = join_plan._join.value()[].left_on.copy()
    else:
        side_join_keys = join_plan._join.value()[].right_on.copy()
    if not _all_strings_in(side_join_keys, gb_names):
        return _PushDecision(_PUSH_NONE)

    # Collision guard
    if not push_to_left:
        for i in range(len(gb_names)):
            if _schema_has_field(
                join_plan._join.value()[].left[].output_schema, gb_names[i]
            ):
                return _PushDecision(_PUSH_NONE)

    # NOTE: clause (c) deliberately skipped -- see docstring.
    if push_to_left:
        return _PushDecision(_PUSH_LEFT)
    return _PushDecision(_PUSH_RIGHT)


def push_aggregate_below_join_force(var plan: LogicalPlan) raises -> LogicalPlan:
    """Test-only entry point: same recursion as push_aggregate_below_join
    but uses _classify_push_unchecked (skips clause (c)) so legacy
    rewrite-shape tests that pre-date the soundness gate keep working.

    Production code MUST call push_aggregate_below_join. See its docstring
    and the file header for the soundness contract.
    """
    if plan.tag == PLAN_AGGREGATE:
        var child = _take_aggregate_child(plan)
        var new_child = push_aggregate_below_join_force(child^)

        if new_child.tag == PLAN_JOIN and new_child._join.value()[].join_type == JOIN_INNER and not new_child._join.value()[].has_residual():
            var decision = _classify_push_unchecked(plan, new_child)
            if decision.kind == _PUSH_LEFT or decision.kind == _PUSH_RIGHT:
                return _perform_rewrite(
                    plan, new_child^, decision.kind == _PUSH_LEFT
                )

        var new_gb = _copy_expr_array(plan._aggregate.value()[].group_by)
        var new_aggs = _copy_agg_expr_array(plan._aggregate.value()[].agg_exprs)
        return LogicalPlan.aggregate(new_gb^, new_aggs^, new_child^)

    elif plan.tag == PLAN_FILTER:
        var child = _take_filter_child(plan)
        var pred = plan._filter.value()[].predicate.copy()
        var new_child = push_aggregate_below_join_force(child^)
        return LogicalPlan.filter(pred^, new_child^)

    elif plan.tag == PLAN_PROJECT:
        var child = _take_project_child(plan)
        var new_child = push_aggregate_below_join_force(child^)
        var new_exprs = _copy_expr_array(plan._project.value()[].exprs)
        return LogicalPlan.project(new_exprs^, new_child^)

    elif plan.tag == PLAN_JOIN:
        # preserve `residual` + `algo_hint` across this
        # recurse-rebuild (dropping the residual silently loses the
        # `predicate=` join condition).
        var algo = plan._join.value()[].algo_hint
        var join_resid: Optional[OwnedPointer[Expr]] = None
        if plan._join.value()[].has_residual():
            join_resid = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        var left = _take_join_left(plan)
        var right = _take_join_right(plan)
        var new_left = push_aggregate_below_join_force(left^)
        var new_right = push_aggregate_below_join_force(right^)
        return LogicalPlan.join(
            new_left^,
            new_right^,
            plan._join.value()[].left_on.copy(),
            plan._join.value()[].right_on.copy(),
            plan._join.value()[].join_type,
            algo,
            join_resid^,
        )

    elif plan.tag == PLAN_SORT:
        var child = _take_sort_child(plan)
        var new_child = push_aggregate_below_join_force(child^)
        # carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(
            plan._sort.value()[].keys.copy(),
            plan._sort.value()[].descending.copy(),
            new_child^,
            nf_copy^,
        )

    elif plan.tag == PLAN_LIMIT:
        var child = _take_limit_child(plan)
        var new_child = push_aggregate_below_join_force(child^)
        # forward the RANGE offset, don't drop it on rebuild.
        # MOJO 1.0.0: `.n` and `.offset` in one call are two walks of the
        # same chain; the second invalidates the first. Bind once.
        ref ld = plan._limit.value()[]
        return LogicalPlan.limit(ld.n, new_child^, offset=ld.offset)

    elif plan.tag == PLAN_DISTINCT:
        var child = _take_distinct_child(plan)
        var new_child = push_aggregate_below_join_force(child^)
        var cols_copy: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols_copy = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols_copy^, new_child^)

    elif plan.tag == PLAN_TOPN:
        var child = _take_topn_child(plan)
        var new_child = push_aggregate_below_join_force(child^)
        # carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._topn.value()[].nulls_first.copy())
        return LogicalPlan.topn(
            plan._topn.value()[].keys.copy(),
            plan._topn.value()[].descending.copy(),
            plan._topn.value()[].n,
            new_child^,
            nf_copy^,
        )

    return plan^


def _perform_rewrite(
    agg_plan: LogicalPlan,
    var join_plan: LogicalPlan,
    push_to_left: Bool,
) raises -> LogicalPlan:
    """Consume join_plan and return the rewritten Aggregate/Join tree.

    All safety checks must already have passed via _classify_push.
    Preconditions:
      - agg_plan.tag == PLAN_AGGREGATE  (borrowed -- deep-copied as needed)
      - join_plan.tag == PLAN_JOIN, inner join (consumed)
    """
    # Build partial + merge agg lists. Safe to call because the whitelist
    # check in _classify_push already guarantees support.
    var partial_aggs = AggExprArray()
    var merge_aggs = AggExprArray()
    _build_partial_and_merge(
        agg_plan._aggregate.value()[].agg_exprs, partial_aggs, merge_aggs
    )

    # Partial group-by keys are a deep copy of the original group-by.
    var partial_gb = _copy_expr_array(agg_plan._aggregate.value()[].group_by)

    # Snapshot the join metadata BEFORE we consume join_plan's children.
    var left_on_copy = join_plan._join.value()[].left_on.copy()
    var right_on_copy = join_plan._join.value()[].right_on.copy()
    var jt = join_plan._join.value()[].join_type

    var join_left_plan = _take_join_left(join_plan)
    var join_right_plan = _take_join_right(join_plan)

    var new_left: LogicalPlan
    var new_right: LogicalPlan
    if push_to_left:
        new_left = LogicalPlan.aggregate(
            partial_gb^, partial_aggs^, join_left_plan^
        )
        new_right = join_right_plan^
    else:
        new_left = join_left_plan^
        new_right = LogicalPlan.aggregate(
            partial_gb^, partial_aggs^, join_right_plan^
        )

    # Rebuild the join with the partial aggregate on one side. The
    # original join_plan itself is now unused -- its children have been
    # taken and the join tags/keys were copied above, so Mojo will
    # destroy it at end of scope.
    var new_join = LogicalPlan.join(
        new_left^,
        new_right^,
        left_on_copy^,
        right_on_copy^,
        jt,
    )

    # Merge aggregate above the join.
    var merge_gb = _copy_expr_array(agg_plan._aggregate.value()[].group_by)
    return LogicalPlan.aggregate(merge_gb^, merge_aggs^, new_join^)


# =============================================================================
# Helpers
# =============================================================================

@always_inline
def _is_whitelisted_agg(func: UInt8) -> Bool:
    """SUM / COUNT / MIN / MAX directly; AVG via SUM+COUNT decomposition.

    v0.3 lists the same set. UDAF and
    statistical accumulators (STDDEV/CORR/PERCENTILE/COUNT_DISTINCT) are
    deliberately excluded because their merge semantics either require
    sketch state (HLL, t-digest) or are not associative across the join's
    one-to-many fan-out.
    """
    return (
        func == AGG_SUM
        or func == AGG_COUNT
        or func == AGG_MIN
        or func == AGG_MAX
        or func == AGG_MEAN
    )


def _all_cols_in_schema(cols: Set[String], schema: Schema) -> Bool:
    """Return True if every column name in the set exists in the schema.

    This is equivalent to komira_plan_ir.plan_helpers._all_columns_in_schema
    but we re-implement locally to keep the partial-agg module self-contained.
    """
    for col_name in cols:
        var found = False
        for i in range(schema.num_columns()):
            if schema.field_name(i) == col_name:
                found = True
                break
        if not found:
            return False
    return True


def _schema_has_field(schema: Schema, name: String) -> Bool:
    """Return True if the schema has a field with the given name."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return True
    return False


def _group_by_col_names(group_by: ExprArray) -> List[String]:
    """Extract column names from a list of group-by expressions.

    Only handles the ColRef case -- group-by expressions that are not
    plain column references (e.g. CASE WHEN) return a placeholder empty
    string, and the caller must treat the gating check as failing for
    such exprs. v0.3 uses string-based group_by directly so this is the
    direct equivalent.
    """
    var out = List[String]()
    for i in range(len(group_by)):
        # Bind as a reference (Slab.__getitem__ returns a ref).
        # A plain `var e = group_by[i]` would trigger a copy and Expr
        # is not ImplicitlyCopyable.
        if group_by[i].tag == EXPR_COL_REF:
            out.append(group_by[i].col_ref_name())
        else:
            # Non-column group-by expression -- return a sentinel that
            # the subset check will fail against. We append an empty
            # string so _all_strings_in never matches a real join key.
            out.append("")
    return out^


def _all_strings_in(needles: List[String], haystack: List[String]) -> Bool:
    """Return True if every needle is present in haystack."""
    for i in range(len(needles)):
        var found = False
        for j in range(len(haystack)):
            if needles[i] == haystack[j]:
                found = True
                break
        if not found:
            return False
    return True


# =============================================================================
# Partial + merge aggregate expression construction
# =============================================================================


def _build_partial_and_merge(
    aggs: AggExprArray,
    mut partials_out: AggExprArray,
    mut merges_out: AggExprArray,
):
    """Construct the partial and merge aggregate lists for a whitelisted
    set of aggregates.

    For each input AggExpr we emit:
      - one partial AggExpr whose input expression is a direct copy of
        the original child expression, aliased as `__partial_{op}_{out}`;
      - one merge AggExpr whose input expression is a ColRef to the
        partial alias, aliased as the original output name.

    The merge op differs from the partial op only for COUNT, where the
    merge operator must be SUM (sum of partial counts). For SUM/MIN/MAX
    the merge op matches the partial op.

    Precondition: every input AggExpr MUST be in the whitelist. The
    caller (_classify_push) enforces this before calling. partials_out
    and merges_out must be empty on entry; this helper appends into
    them rather than returning a struct because Mojo does not allow
    destructuring individual Movable-only fields out of a returned
    struct without leaving the struct half-destroyed.
    """
    for i in range(len(aggs)):
        var func = aggs[i].func

        # --- Determine the original output name ---
        #
        # We prefer the explicit alias if present. Otherwise we derive a
        # default from the op name -- this matches _infer_agg_field in
        # logical_plan.mojo so the merge agg's output schema stays
        # identical to what the original aggregate would have produced.
        var orig_name = _agg_output_name(aggs[i])

        # --- AVG decomposition (as in v0.3) ------------------------------
        # AVG cannot be partially aggregated as one accumulator. Split
        # into partial SUM(input) + partial COUNT(input), then expose
        # both as merge SUMs aliased "__partial_avg_sum_{out}" and
        # "__partial_avg_count_{out}". The downstream rewriter is
        # responsible for the final division (not yet written; today
        # the rule never fires while the gate is False).
        if func == AGG_MEAN:
            _emit_avg_decomposition(aggs[i], orig_name^, partials_out, merges_out)
            continue

        # --- Partial output name ---
        var partial_name = _partial_alias(func, orig_name)

        # --- Partial agg expression: deep copy the original child ---
        var partial_child: Optional[Expr] = None
        if aggs[i].child:
            partial_child = aggs[i].child.value().copy()
        var partial_alias_opt: Optional[String] = partial_name.copy()
        var partial_expr = AggExpr(
            func, partial_child^, partial_alias_opt^
        )
        partials_out.append(partial_expr^)

        # --- Merge agg expression: reads the partial alias as a col ---
        var merge_func = _merge_func_for(func)
        var merge_col_expr = Expr.col_ref(partial_name^)
        var merge_child_expr: Optional[Expr] = merge_col_expr^
        var merge_alias_opt: Optional[String] = orig_name^
        var merge_expr = AggExpr(
            merge_func, merge_child_expr^, merge_alias_opt^
        )
        merges_out.append(merge_expr^)


@always_inline
def _merge_func_for(partial_func: UInt8) -> UInt8:
    """Return the merge-phase aggregate function for a partial func.

    COUNT is the only op whose merge semantics differ (sum of counts).
    For SUM/MIN/MAX the merge op matches the partial op.
    """
    if partial_func == AGG_COUNT:
        return AGG_SUM
    return partial_func


def _write_agg_output_name[W: Writer](mut writer: W, agg: AggExpr):
    """WRITE what `_agg_output_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library
    that binds such a pair CROSSED crashes the process that loaded it.
    (The lint for this shape, `scripts/lint_literal_return_ladder.py`,
    is not in this tree.)"""
    if agg.alias_name:
        writer.write(agg.alias_name.value())
        return
    if agg.func == AGG_SUM:
        writer.write("sum")
        return
    if agg.func == AGG_COUNT:
        writer.write("count")
        return
    if agg.func == AGG_MIN:
        writer.write("min")
        return
    if agg.func == AGG_MAX:
        writer.write("max")
        return
    if agg.func == AGG_MEAN:
        writer.write("mean")
        return
    writer.write("agg")
    return


def _agg_output_name(agg: AggExpr) -> String:
    """Return the output column name that an AggExpr produces.

    Mirrors _infer_agg_field in logical_plan.mojo: alias_name wins, else
    fall back to the op's default base name.
    """
    var out = String()
    _write_agg_output_name(out, agg)
    return out^


def _partial_alias(func: UInt8, orig_name: String) -> String:
    """Mint a unique alias for a partial aggregate output.

    Format: `__partial_{op}_{orig_name}`. Matches v0.3's naming so
    debugging output looks the same across engines.
    """
    var op_tag: String
    if func == AGG_SUM:
        op_tag = "sum"
    elif func == AGG_COUNT:
        op_tag = "count"
    elif func == AGG_MIN:
        op_tag = "min"
    elif func == AGG_MAX:
        op_tag = "max"
    elif func == AGG_MEAN:
        # AVG decomposition uses dedicated sum/count aliases assembled
        # in _emit_avg_decomposition, so the rewrite never reaches this
        # branch; it keeps the mapping total (a test calls it with
        # MEAN).
        op_tag = "mean"
    else:
        op_tag = "agg"
    return "__partial_" + op_tag + "_" + orig_name


def _emit_avg_decomposition(
    agg: AggExpr,
    var orig_name: String,
    mut partials_out: AggExprArray,
    mut merges_out: AggExprArray,
):
    """AVG -> partial SUM(input) + partial COUNT(input), merge SUM+SUM.

    As in v0.3. Both partial outputs are exposed by name
    ("__partial_avg_sum_{orig}" and "__partial_avg_count_{orig}") so a
    downstream rewriter can synthesize the final division. The merge
    aggregates above the join SUM both partial columns -- this preserves
    the invariant that SUM(SUM_partial) == SUM(input) and
    SUM(COUNT_partial) == COUNT(input) under one-to-many fan-out from
    the OTHER side, which is precisely what soundness clause (c) buys us.

    Precondition: agg.func == AGG_MEAN. Caller is _build_partial_and_merge.
    """
    var sum_alias: String = String("__partial_avg_sum_") + orig_name.copy()
    var count_alias: String = String("__partial_avg_count_") + orig_name.copy()

    # --- Partial SUM(input) ----------------------------------------------
    var sum_child: Optional[Expr] = None
    if agg.child:
        sum_child = agg.child.value().copy()
    var sum_alias_opt: Optional[String] = sum_alias.copy()
    var partial_sum = AggExpr(AGG_SUM, sum_child^, sum_alias_opt^)
    partials_out.append(partial_sum^)

    # --- Partial COUNT(input) -------------------------------------------
    var count_child: Optional[Expr] = None
    if agg.child:
        count_child = agg.child.value().copy()
    var count_alias_opt: Optional[String] = count_alias.copy()
    var partial_count = AggExpr(AGG_COUNT, count_child^, count_alias_opt^)
    partials_out.append(partial_count^)

    # --- Merge SUM(__partial_avg_sum_*) ---------------------------------
    # Output name keeps the partial alias so the downstream rewriter can
    # locate both halves by name. v0.3 uses the same convention
    # (v0.3 emits the partial-sum alias as the merge alias).
    var merge_sum_col = Expr.col_ref(sum_alias^)
    var merge_sum_child: Optional[Expr] = merge_sum_col^
    var merge_sum_alias_opt: Optional[String] = String("__partial_avg_sum_") + orig_name.copy()
    var merge_sum = AggExpr(AGG_SUM, merge_sum_child^, merge_sum_alias_opt^)
    merges_out.append(merge_sum^)

    # --- Merge SUM(__partial_avg_count_*) -------------------------------
    var merge_count_col = Expr.col_ref(count_alias^)
    var merge_count_child: Optional[Expr] = merge_count_col^
    var merge_count_alias_opt: Optional[String] = String("__partial_avg_count_") + orig_name^
    var merge_count = AggExpr(AGG_SUM, merge_count_child^, merge_count_alias_opt^)
    merges_out.append(merge_count^)
