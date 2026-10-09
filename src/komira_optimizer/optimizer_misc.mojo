# =============================================================================
# Optimizer miscellaneous rules — limit pushdown, sort+limit fusion,
# statistics propagation
# =============================================================================
#
# Rule 6: Limit pushdown — push Limit through Project
# Rule 14: Sort+Limit -> TopN fusion — replace Sort + Limit with TopN
# Rule 14b: TopN below Project — TopN(Project(Agg)) -> Project(TopN'(Agg))
# Rule 22: Statistics propagation — estimate row counts through plan tree
# =============================================================================

from std.collections import Optional, Set

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
)
from .topn_tiebreak_policy import (
    append_deterministic_tiebreak_schema,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
)
from komira_plan_ir.plan_helpers import (
    _copy_expr_array,
    _copy_agg_expr_array,
    _copy_plan,
    _take_filter_child,
    _take_project_child,
    _take_aggregate_child,
    _take_join_left,
    _take_join_right,
    _take_sort_child,
    _take_limit_child,
    _take_distinct_child,
    _take_topn_child,
    _collect_expr_columns,
)


# =============================================================================
# Rule 6: Limit Pushdown
# =============================================================================

def push_limit_down(var plan: LogicalPlan) raises -> LogicalPlan:
    """Push Limit nodes below Project nodes.

    Wrapper around `push_limit_down_inplace`.
    """
    push_limit_down_inplace(plan)
    return plan^


def push_limit_down_inplace(mut plan: LogicalPlan) raises:
    """In-place limit pushdown.

    Recurses children IN PLACE. The Limit-above-Project case still
    rebuilds because we are reordering two nodes (Limit becomes child of
    Project); we deep-copy the grandchild to satisfy the partial-move
    ban. The non-Project-child walk skips rebuilds entirely.
    """
    if plan.tag == PLAN_LIMIT:
        push_limit_down_inplace(plan._limit.value()[].child[])

        # Pattern: Limit(N, Project(exprs, gc)) -> Project(exprs, Limit(N, gc))
        # OFFSET: only push a plain LIMIT (offset == 0) below Project. A
        # RANGE (offset > 0) is a terminal viewport verb whose offset the
        # materialize sink absorbs at the plan ROOT (skip-count); pushing it
        # under Project would move it off the root and the sink would miss it.
        # offset == 0 keeps the exact pre-range pushdown behavior.
        if (
            plan._limit.value()[].child[].tag == PLAN_PROJECT
            and plan._limit.value()[].offset == 0
        ):
            var n = plan._limit.value()[].n
            var proj_exprs = _copy_expr_array(plan._limit.value()[].child[]._project.value()[].exprs)
            var gc_copy = _copy_plan(plan._limit.value()[].child[]._project.value()[].child[])
            # Schema is unchanged (the Project's output is still the
            # plan output; Limit doesn't change schema). Build the new
            # Project around a fresh Limit node and replace plan.
            var inner_limit = LogicalPlan.limit(n, gc_copy^)
            plan = LogicalPlan.project(proj_exprs^, inner_limit^)

    elif plan.tag == PLAN_FILTER:
        push_limit_down_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        push_limit_down_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        push_limit_down_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        push_limit_down_inplace(plan._join.value()[].left[])
        push_limit_down_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        push_limit_down_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        push_limit_down_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        push_limit_down_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


# =============================================================================
# Rule 14: Sort+Limit -> TopN Fusion
# =============================================================================

def fuse_sort_limit(var plan: LogicalPlan) raises -> LogicalPlan:
    """Replace Sort + Limit patterns with TopN nodes.

    Wrapper around `fuse_sort_limit_inplace`.
    """
    fuse_sort_limit_inplace(plan)
    return plan^


def fuse_sort_limit_inplace(mut plan: LogicalPlan) raises:
    """In-place sort+limit fusion.

    Recurses children IN PLACE. The Limit-above-Sort fusion case rebuilds
    because two nodes collapse into one TopN. The non-fusion walk skips
    the rebuild entirely.
    """
    if plan.tag == PLAN_LIMIT:
        fuse_sort_limit_inplace(plan._limit.value()[].child[])

        # Pattern: Limit(K, Sort(keys, desc, sc)) -> TopN(keys, desc, K, sc)
        # OFFSET: fuse ONLY when offset == 0. TopNData carries no offset,
        # so a RANGE (offset > 0) over a Sort must stay a Limit(offset, K, Sort)
        # — collapsing it into TopN(K) would silently drop the offset and return
        # the wrong window. offset == 0 is the plain Top-N and still fuses
        # (Q-style sort().limit(K) plans are unchanged).
        if (
            plan._limit.value()[].child[].tag == PLAN_SORT
            and plan._limit.value()[].offset == 0
        ):
            var n = plan._limit.value()[].n
            var keys_copy = plan._limit.value()[].child[]._sort.value()[].keys.copy()
            var desc_copy = plan._limit.value()[].child[]._sort.value()[].descending.copy()
            # ⛔ NULL PLACEMENT MUST SURVIVE: a dropped placement
            # here does not merely order differently — the fused TOP-N RETURNS A
            # DIFFERENT SET OF ROWS from the unfused `LIMIT(SORT(...))`, because
            # the placement decides which `n` rows survive the slice. An
            # optimisation that changes the answer is the one thing a rewrite
            # may never do.
            var nf_copy = Optional(
                plan._limit.value()[].child[]._sort.value()[].nulls_first.copy()
            )
            var sort_grandchild = _copy_plan(plan._limit.value()[].child[]._sort.value()[].child[])
            plan = LogicalPlan.topn(
                keys_copy^, desc_copy^, n, sort_grandchild^, nf_copy^
            )

    elif plan.tag == PLAN_FILTER:
        fuse_sort_limit_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        fuse_sort_limit_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        fuse_sort_limit_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        fuse_sort_limit_inplace(plan._join.value()[].left[])
        fuse_sort_limit_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        fuse_sort_limit_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        fuse_sort_limit_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        fuse_sort_limit_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


# =============================================================================
# Rule 14b: TopN below Project
# =============================================================================
#
# ── THE REWRITE ─────────────────────────────────────────────────────────────
#
#     TopN(keys, n, Project(P, Aggregate))  ==>  Project(P, TopN(keys', n, Aggregate))
#
# when every ORDER BY key is a PASS-THROUGH or RENAMED column of the aggregate.
# `keys'` are the keys translated through the Project; `nulls_first` rides
# along (same reason as Rule 14).
#
# ── WHY IT IS WORTH A RULE ──────────────────────────────────────────────────
#
# The Project above an Aggregate is evaluated over EVERY group when the TopN
# sits above it, and over only `n` rows when it sits below; and below it the
# TopN's child IS the aggregate, so the AGG-TOPK stamp (which refuses a
# Project that does more than pass names through) no longer refuses a Project
# that renames or computes a comparator column.
#
#   * ClickBench Q35. The agg-group FD rule re-emits
#     `client_ip - 1/-2/-3` in the post-aggregate Project; the walker evaluated
#     them serially on the driver over all 9,762,046 groups before the TopN —
#     449 ms of a 1,557 ms query. The pushed plan, written by hand as
#     SQL: -450 ms alone there. This rule emits that plan
#     (`Project[5] > TopN > Aggregate[1 key]`, runner `--explain`).
#
# REACH, MEASURED 2026-09-23 by materializing the 42 benchmark queries
# with GROUP BY + ORDER BY + LIMIT: a pre-rule binary vs this one, comparing the
# AGG-TOPK trace and `--dump`. The TopN's input
# changes on EXACTLY FOUR queries, and on each the stamp flips from refused to
# STAMPED: cbq35 (the computed restore above), and three pure renames, cbq18
# (`__grp_key_0 AS m`), cbq39 (`__grp_key_0 AS src`, `url AS dst`, under
# `OFFSET 1000`) and cbq42 (`__grp_key_0 AS m`, `OFFSET 1000`). All 42 dumps
# are row-for-row identical between the two binaries; cbq35, cbq18 and cbq39
# also match DuckDB row for row, and cbq42 matches it up to timestamp rendering.
# Only cbq35 has a measured cost effect. On the three renames the bounded drain
# still declines (the drain refuses a var-width ORDER BY key, and cbq42
# has only 1,440 groups), so their route is otherwise unchanged.
# ⚠ Measure reach by materializing the plan, never with `--explain`: explain
# optimizes BEFORE an OFFSET is absorbed into the plan.
#
# ── THE ONE HAZARD: THE TIE ORDER ───────────────────────────────────────────
#
# The engine does not sort by `keys` alone. Before the cut it WIDENS them with
# a deterministic tie-break over the TopN's INPUT schema
# (`topn_tiebreak_policy.append_deterministic_tiebreak_schema`
# — every INT64/INT32/FLOAT64 column not already a key, in schema order, ASC).
# Moving the TopN below the Project CHANGES ITS INPUT SCHEMA, so the widened
# list changes: a Project that reorders `a, b` to `b, a` turns the tie-break
# `(b, a)` into `(a, b)`, and on a tie at the cut a DIFFERENT ROW SURVIVES.
# No result check can see that — a value check folds a multiset and an
# order check checks only monotonicity of the explicit key — so the rule has to
# prove it cannot happen, and declines whenever it cannot.
#
# THE PROOF, per candidate:
#   1. Widen `keys` over the PROJECT's schema exactly as the engine does today:
#      that is the comparator the un-rewritten plan executes.
#   2. Translate every entry through the Project. A col-ref (renamed or not)
#      maps to its aggregate column. An entry that orders NOTHING is dropped:
#      a column already in the list (two names for one column), or a
#      deterministic function of columns already in the list (Q35's
#      `client_ip - 1` after `client_ip`; a literal). The drop needs VALUE
#      IDENTITY on those inputs — two rows the comparator calls equal must agree
#      on the function — which FLOAT breaks (`-0.0 == 0.0`, `1/x` does not), so
#      a float input declines, as in the agg-group FD rule. Any other computed entry
#      DECLINES: it orders rows and cannot be named below the Project.
#   3. Widen the translated EXPLICIT keys over the AGGREGATE's schema — what
#      the rewritten plan will execute — and fire only if either
#        (i)  nothing was dropped and the two lists are IDENTICAL, entry for
#             entry: the same kernel sees the same key columns in the same row
#             order, so it makes the same choices, residual ties included; or
#        (ii) the translated list is a TOTAL order over the aggregate's rows
#             (it contains every group key -- the group key set is unique per
#             row -- and no FLOAT entry: a float can hold two values the
#             comparator calls equal, or a NaN, which can stop the comparator
#             being a strict weak order) AND the rewritten plan's list STARTS
#             WITH it. A total order leaves no tie for any kernel to break, so
#             the answer is the same whatever the rewritten plan appends.
#
# ⛔ WHAT IT DELIBERATELY DOES NOT DO: make the translated tie-break keys
# EXPLICIT on the new TopN so that a reordering Project could be served too.
# The engine pads each appended tie-break key's NULL placement
# (in the engine's TopN operator); an explicit key would have to restate
# that padding here — a second copy of an engine rule — and the resulting
# non-default placement list would make the AGG-TOPK stamp decline
# (`is_explicit_nulls_first_request`) -- the stamp this rule exists to reach. Declined, not
# approximated.
#
# ⛔ ONLY OVER AN AGGREGATE, AND ONLY WHEN THE PROJECT DOES WORK. A pure
# same-name col-ref Project is already peeled by the AGG-TOPK stamp and costs a
# column narrow; moving the TopN buys nothing there, so the plan is left as it
# is. Over a join, a scan or a distinct the totality argument is unavailable
# and nothing has been measured.
#
# ⛔ THE PROJECT IS NOW EVALUATED OVER `n` ROWS INSTEAD OF EVERY GROUP. For a
# deterministic, row-local expression that is the same value on every row it
# still sees. Anything else changes the answer: a window function (a later pass
# would turn it into a PartitionBy over the TopN's `n` rows), an aggregate, a
# UDF, a correlated subquery. So every COMPUTED Project entry must pass
# `_row_local_shape` -- a FAIL-CLOSED allow-list walked over the WHOLE
# expression (col-ref, literal, alias, cast, unary, binary), not a check of the
# top tag. ⚠ A top-tag check is what the first draft of this rule used
# (the agg-group FD rule's `_derived_key_is_deterministic`, which is right for a GROUP
# BY key, where the binder has already refused windows): it admitted
# `rank() OVER (...) + 1`, whose top tag is a BINARY_OP, and
# `test_nested_window_function_in_the_project_declines` is the RED that caught
# it. An expression that would RAISE on a group the TopN discards no longer
# raises; that is the one observable difference and it runs in the direction
# of answering.
# =============================================================================


def _colref_source(e: Expr) -> String:
    """The aggregate column an output entry passes through, or "" when it is
    computed: `col_ref(X)` -> X, `alias(col_ref(X), _)` -> X."""
    if e.tag == EXPR_COL_REF:
        return e.col_ref_name()
    if e.tag == EXPR_ALIAS and e.alias_child_ref().tag == EXPR_COL_REF:
        return e.alias_child_ref().col_ref_name()
    return String("")


def _schema_index(sch: Schema, name: String) raises -> Int:
    """First column of `sch` named `name`, else -1. SCANNED — `column_index`
    raises on an unknown name, and an unknown name here is a decline."""
    for i in range(sch.num_columns()):
        if sch.field_name(i) == name:
            return i
    return -1


def _name_in(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


def _is_float_type(at: ArrowType) -> Bool:
    return (
        at == ArrowType.FLOAT16
        or at == ArrowType.FLOAT32
        or at == ArrowType.FLOAT64
    )


def _row_local_shape(e: Expr) -> Bool:
    """Is `e` built ONLY from column references, literals, aliases, casts and
    the scalar unary/binary operators -- at EVERY level, not just the top?

    ⛔ A FAIL-CLOSED ALLOW-LIST, ON PURPOSE, AND IT ANSWERS TWO QUESTIONS.
      * "May this Project entry be evaluated over the `n` survivors instead of
        every group?" Every admitted node is deterministic and row-local (the
        `UN_*` / `BIN_*` op sets hold no volatile function). A window function,
        an aggregate, a UDF call or a correlated subquery ANYWHERE in the tree
        is some other tag, so it returns False -- including one nested under a
        BINARY_OP, which a top-tag check misses.
      * "Does `_collect_expr_columns` report this entry's inputs in full?" The
        FD drop in step (2) claims "this entry is a function of columns already
        in the comparator", and learns which columns an expression reads from
        the ONE column walk (`expr_walk.walk_expr_column_refs`). That walk
        leaves EXPR_COL_IDX unwalked (a positional reference has no name), so an
        expression hiding one would under-report its inputs and a comparator
        entry that DOES order rows would be dropped -- a wrong answer.
    Any other tag returns False and the rule DECLINES. That covers both
    measured shapes (Q35's `client_ip - k`, cbq18's rename) and costs, at worst,
    a missed rewrite -- never a wrong one. Widening it is a per-tag decision
    with a test, not a default."""
    var tag = e.tag
    if tag == EXPR_COL_REF or tag == EXPR_LITERAL:
        return True
    if tag == EXPR_ALIAS:
        return _row_local_shape(e.alias_child_ref())
    if tag == EXPR_CAST:
        return _row_local_shape(e.cast_child_ref())
    if tag == EXPR_UNARY_OP:
        return _row_local_shape(e.unary_child_ref())
    if tag == EXPR_BINARY_OP:
        return _row_local_shape(e.binary_left_ref()) and _row_local_shape(
            e.binary_right_ref()
        )
    return False


def push_topn_below_project(var plan: LogicalPlan) raises -> LogicalPlan:
    """TopN below Project. Wrapper around `push_topn_below_project_inplace`."""
    push_topn_below_project_inplace(plan)
    return plan^


def push_topn_below_project_inplace(mut plan: LogicalPlan) raises:
    """Walk the plan bottom-up and rewrite every `TopN(Project(Aggregate))` the
    tie-order proof admits (see the section header).

    IDEMPOTENT: after a rewrite the TopN's child is the Aggregate, so a second
    run matches nothing. A plan with no admitted site is returned structurally
    untouched — no copy, no rebuild."""
    if plan.tag == PLAN_TOPN:
        push_topn_below_project_inplace(plan._topn.value()[].child[])
        var rebuilt = _build_topn_below_project(plan)
        if rebuilt:
            plan = rebuilt.take()

    elif plan.tag == PLAN_LIMIT:
        push_topn_below_project_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_FILTER:
        push_topn_below_project_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        push_topn_below_project_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        push_topn_below_project_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        push_topn_below_project_inplace(plan._join.value()[].left[])
        push_topn_below_project_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        push_topn_below_project_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        push_topn_below_project_inplace(plan._distinct.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN,
    # PLAN_UNION: not affected. Leave unchanged (the same walk Rule 14 does).


def _build_topn_below_project(imm plan: LogicalPlan) raises -> Optional[LogicalPlan]:
    """`plan` is a PLAN_TOPN. Return `Project(TopN'(Aggregate))`, or None when
    the shape does not match or the tie-order proof does not go through.

    Every gate returns None. A decline costs one walk and no copy; the
    aggregate subtree is copied only after every gate has passed."""
    ref td = plan._topn.value()[]
    ref proj_plan = td.child[]
    if proj_plan.tag != PLAN_PROJECT or not proj_plan._project:
        return None
    ref pd = proj_plan._project.value()[]
    if pd.udf:
        return None
    ref agg_plan = pd.child[]
    if agg_plan.tag != PLAN_AGGREGATE or not agg_plan._aggregate:
        return None
    var n_group_keys = len(agg_plan._aggregate.value()[].group_by)
    if n_group_keys < 1:
        return None
    ref s_p = proj_plan.output_schema
    ref s_x = agg_plan.output_schema
    var n_out = len(pd.exprs)
    if n_out != s_p.num_columns() or s_x.num_columns() < n_group_keys:
        return None
    var n_explicit = len(td.keys)
    if (
        n_explicit == 0
        or len(td.descending) != n_explicit
        or len(td.nulls_first) != n_explicit
    ):
        return None
    # Two output columns under one name: the engine resolves a key to the
    # FIRST, and so would this rule, but nothing here needs to reason about it.
    for i in range(n_out):
        for j in range(i):
            if s_p.field_name(i) == s_p.field_name(j):
                return None

    # ── (0) every Project entry must be evaluable over the survivors only ────
    var moves_work = False
    for i in range(n_out):
        ref e = pd.exprs[i]
        var src = _colref_source(e)
        if src != "":
            if _schema_index(s_x, src) < 0:
                return None
            if e.tag != EXPR_COL_REF or src != s_p.field_name(i):
                moves_work = True  # a rename: the AGG-TOPK stamp refuses it
            continue
        moves_work = True
        if not _row_local_shape(e):
            return None
    if not moves_work:
        return None

    # ── (1) the comparator the UN-rewritten plan executes ───────────────────
    var pre_keys = td.keys.copy()
    var pre_desc = td.descending.copy()
    append_deterministic_tiebreak_schema(s_p, pre_keys, pre_desc)

    # ── (2) translate it through the Project ────────────────────────────────
    var l_cols = List[String]()
    var l_desc = List[Bool]()
    var l_nf = List[Bool]()  # explicit entries only; a prefix of `l_cols`
    var dropped = False
    for j in range(len(pre_keys)):
        var pidx = _schema_index(s_p, pre_keys[j])
        if pidx < 0:
            return None
        ref e = pd.exprs[pidx]
        var src = _colref_source(e)
        if src != "":
            if _name_in(l_cols, src):
                dropped = True  # a second name for a column already compared
                continue
            l_cols.append(src)
            l_desc.append(pre_desc[j])
            if j < n_explicit:
                l_nf.append(td.nulls_first[j])
            continue
        # Computed. Droppable only if it orders nothing given what precedes it.
        # (Step (0) already required `_row_local_shape` of every computed entry;
        # restated here because the column walk below is only complete for it.)
        if not _row_local_shape(e):
            return None  # cov: unreachable step (0) already returned None for every computed entry that is not _row_local_shape
        var cols = Set[String]()
        _collect_expr_columns(e, cols)
        for c in cols:
            if not _name_in(l_cols, c):
                return None
            var xi = _schema_index(s_x, c)
            if xi < 0 or _is_float_type(s_x.field_arrow_type(xi)):
                return None
        dropped = True
    var n_l_explicit = len(l_nf)
    if n_l_explicit == 0:
        return None

    # ── (3) the comparator the REWRITTEN plan will execute ──────────────────
    var post_keys = List[String]()
    var post_desc = List[Bool]()
    var post_nf = List[Bool]()
    for i in range(n_l_explicit):
        post_keys.append(l_cols[i])
        post_desc.append(l_desc[i])
        post_nf.append(l_nf[i])
    var eng_keys = post_keys.copy()
    var eng_desc = post_desc.copy()
    append_deterministic_tiebreak_schema(s_x, eng_keys, eng_desc)

    var starts_with = len(eng_keys) >= len(l_cols)
    if starts_with:
        for i in range(len(l_cols)):
            if eng_keys[i] != l_cols[i] or eng_desc[i] != l_desc[i]:
                starts_with = False
                break
    var identical = (not dropped) and starts_with and len(eng_keys) == len(l_cols)

    # TOTAL: every group key is in the list (the group-key set is unique per
    # aggregate row) and NO entry is a float. A float group key can hold two
    # values the comparator calls equal (-0.0 / 0.0); a float anywhere in the
    # list can hold a NaN, and a comparator with a NaN in it need not be a
    # strict weak order -- "no two rows tie" then no longer implies "every
    # kernel orders them the same way". Fail-closed; arm (i) still serves the
    # float shapes, because there the kernel's comparator is unchanged.
    var total = True
    for g in range(n_group_keys):
        if not _name_in(l_cols, s_x.field_name(g)):
            total = False
            break
    if total:
        for i in range(len(l_cols)):
            var xi = _schema_index(s_x, l_cols[i])
            if xi < 0 or _is_float_type(s_x.field_arrow_type(xi)):
                total = False
                break

    if not (identical or (total and starts_with)):
        return None

    # ── (4) rebuild, bottom-up ──────────────────────────────────────────────
    var agg_copy = _copy_plan(agg_plan)
    # The copy re-derives the aggregate's schema; if that disagrees with the
    # schema every decision above was made against, abandon.
    if agg_copy.output_schema.num_columns() != s_x.num_columns():
        return None
    for i in range(s_x.num_columns()):
        if agg_copy.output_schema.field_name(i) != s_x.field_name(i):
            return None
    var new_topn = LogicalPlan.topn(
        post_keys^, post_desc^, td.n, agg_copy^, Optional(post_nf^)
    )
    var new_project = LogicalPlan.project(
        _copy_expr_array(pd.exprs), new_topn^, pd.is_cse_introduced
    )

    # ── (5) POST-CONDITION: the subtree's output schema is the contract ─────
    ref old_schema = plan.output_schema
    ref out_schema = new_project.output_schema
    if out_schema.num_columns() != old_schema.num_columns():
        return None
    for i in range(old_schema.num_columns()):
        if out_schema.field_name(i) != old_schema.field_name(i):
            return None
        if out_schema.field_arrow_type(i) != old_schema.field_arrow_type(i):
            return None
    return Optional(new_project^)


# =============================================================================
# Rule 22: Statistics Propagation
# =============================================================================

def propagate_statistics(var plan: LogicalPlan) -> LogicalPlan:
    """Propagate estimated row counts through the plan tree.

    This is an annotation pass -- the plan structure does not change.
    """
    _ = estimate_row_count(plan)
    return plan^


def estimate_row_count(plan: LogicalPlan) -> Int:
    """Estimate the number of output rows for a plan node.

    Uses simple heuristics:
      Scan: 1_000_000 (default, would use Parquet stats in production)
      Filter: child * 0.5
      Aggregate: child * 0.1
      Join (inner/cross): left * right * 0.3
      Join (semi/anti): left * 0.5
      Project: child (unchanged)
      Limit(N): min(N, child)
      Sort/Distinct/TopN: child
    """
    if plan.tag == PLAN_SCAN:
        return 1_000_000

    elif plan.tag == PLAN_FILTER:
        var child_rows = estimate_row_count(plan._filter.value()[].child[])
        return max(child_rows // 2, 1)

    elif plan.tag == PLAN_PROJECT:
        return estimate_row_count(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        var child_rows = estimate_row_count(plan._aggregate.value()[].child[])
        return max(child_rows // 10, 1)

    elif plan.tag == PLAN_JOIN:
        var left_rows = estimate_row_count(plan._join.value()[].left[])
        var right_rows = estimate_row_count(plan._join.value()[].right[])
        var jt = plan._join.value()[].join_type
        if jt == JOIN_SEMI or jt == JOIN_ANTI:
            return max(left_rows // 2, 1)
        elif jt == JOIN_CROSS:
            return left_rows * right_rows
        else:
            var product = left_rows * right_rows
            if product > 1_000_000_000:
                product = 1_000_000_000
            return max((product * 3) // 10, 1)

    elif plan.tag == PLAN_SORT:
        return estimate_row_count(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        # OFFSET: rows [offset, offset + n) -> after skipping `offset`,
        # at most `child - offset` rows remain, capped at `n`.
        var child_rows = estimate_row_count(plan._limit.value()[].child[])
        var n = plan._limit.value()[].n
        var offset = plan._limit.value()[].offset
        var available = child_rows - offset
        if available < 0:
            available = 0
        if n < available:
            return n
        return available

    elif plan.tag == PLAN_DISTINCT:
        var child_rows = estimate_row_count(plan._distinct.value()[].child[])
        return max(child_rows // 2, 1)

    elif plan.tag == PLAN_TOPN:
        var child_rows = estimate_row_count(plan._topn.value()[].child[])
        var n = plan._topn.value()[].n
        if n < child_rows:
            return n
        return child_rows

    return 1_000_000
