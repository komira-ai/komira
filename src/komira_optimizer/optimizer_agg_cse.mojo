# =============================================================================
# optimizer_agg_cse.mojo -- find a duplicated AGGREGATE subtree and replace
# every occurrence with one shared in-memory source (a tree-preserving CSE).
#
# WHY THIS EXISTS (float-determinism correctness; TPC-H q15, the
# shared-CTE-aggregate pattern)
# ============================================================================
# A query that references the SAME aggregate more than once -- directly, or
# after `scalar_subquery_decorrelate` turns `col = (SELECT max(col) FROM cte)`
# into a CROSS join whose two sides both read `cte` -- holds that aggregate
# subtree TWICE, and executing the plan as a tree computes each copy
# independently. TPC-H q15 is the canonical case:
#
#   WITH revenue_view AS (SELECT l_suppkey, sum(l_disc_price) AS total_revenue
#                         FROM lineitem WHERE ... GROUP BY l_suppkey)
#   SELECT l_suppkey, total_revenue FROM revenue_view
#   WHERE total_revenue = (SELECT max(total_revenue) FROM revenue_view)
#
# decorrelates to `Filter(tr == col, CROSS(RV_outer, max(RV_inner)))`, where
# RV_outer and RV_inner are the SAME `Aggregate(sum(l_disc_price) GROUP BY
# l_suppkey)` subtree. A `PLAN_CSE_REF` leaf could name one shared copy, but
# it is a DAG edge, and a plan walked as a tree cannot follow it. The aggregate
# is then computed once per copy, and two parallel float-sum reductions are
# non-deterministic (work-stealing morsel order), so their per-group sums can
# differ by ~1 ULP and the exact `total_revenue = max(total_revenue)` equality
# can miss (q15 then returns 0 rows; DuckDB, computing the CTE once, always
# returns the top supplier).
#
# THE FIX (DuckDB-faithful "materialize the CTE once")
# ====================================================
# This module finds each duplicated grouped AGGREGATE subtree (the collect and
# find walks). `replace_agg_subtree_with_source` then replaces every occurrence
# with an `InMemorySource` scan leaf built from ONE materialized result passed
# in as `source`; each leaf holds a copy of that source, which is an ArcPointer
# refcount bump, not a buffer copy. The IR stays a TREE (an in-memory scan is a
# leaf), and BOTH consumers read the SAME bytes, so the compared values are
# bit-identical and `x = max(x)` is exact + deterministic.
#
# SCOPE: restricted to GROUPED AGGREGATE subtrees (`len(group_by) >= 1`) for
# two reasons:
#   1. CORRECTNESS TARGET. The float-determinism bug is a PER-GROUP parallel
#      reduction reorder (q15's `sum(...) GROUP BY l_suppkey`, a
#      grouped agg). An UNGROUPED aggregate is a single global reduction; a
#      global max/min is order-independent (deterministic).
#   2. SAFETY. A 1-row UNGROUPED aggregate is the typical CROSS broadcast side a
#      decorrelated `col = (SELECT max(x) FROM ...)` produces; replacing it with
#      an in-memory scan leaf changes which side of the CROSS is the leaf side,
#      which a nested-cross shape (two identical scalar subqueries under one
#      cross) depends on. Grouped aggregates
#      are data-reducing breakers whose materialize-once is cheap and bounded,
#      and (in the q15 shape) sit UNDER the broadcast max, so folding them
#      leaves the cross's breaker side intact.
# On a plan with no duplicated grouped-aggregate subtree no exact hash reaches
# a count of 2, so there is nothing to replace.
#
# The walks below cover Filter / Project / Aggregate / Join / Sort / Limit /
# Distinct / TopN, and the collect and find walks also AsofJoin and Union.
# Node kinds not walked (PartitionBy / PartitionTopN / Cast / leaves, and
# AsofJoin / Union in `replace_agg_subtree_with_source`) simply do not fold --
# a conservative no-op, never a wrong answer.
# =============================================================================

from std.collections import Dict, List, Optional
from std.memory import OwnedPointer

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SourceVariant,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
)
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_UNARY_OP,
)
from komira_plan_expr.agg_expr import AggExpr
from komira_scan_source.in_memory_source import InMemorySource
from komira_counters.planner_scale_counter import (
    planner_scale_note_agg_cse_cheap,
    planner_scale_note_agg_cse_hash,
)

from komira_plan_ir.plan_helpers import _copy_plan, _copy_schema


# -----------------------------------------------------------------------------
# small local expr/agg array copies (ExprArray/AggExprArray == Slab[Expr]/[AggExpr])
# -----------------------------------------------------------------------------
def _copy_exprs(arr: ExprArray) -> ExprArray:
    var out = ExprArray()
    for i in range(len(arr)):
        out.append(arr[i].copy())
    return out^


def _copy_aggs(arr: AggExprArray) -> AggExprArray:
    var out = AggExprArray()
    for i in range(len(arr)):
        out.append(arr[i].copy())
    return out^


# -----------------------------------------------------------------------------
# Step 1 -- collect: count structural_hash occurrences of PLAN_AGGREGATE subtrees.
# -----------------------------------------------------------------------------
@always_inline
def _is_grouped_aggregate(plan: LogicalPlan) -> Bool:
    """True iff `plan` is a PLAN_AGGREGATE with a non-empty GROUP BY (the fold
    target class -- see the module SCOPE note)."""
    return (
        plan.tag == PLAN_AGGREGATE
        and len(plan._aggregate.value()[].group_by) >= 1
    )


# -----------------------------------------------------------------------------
# ONE traversal, three jobs. See `_walk_grouped_aggregates`.
# -----------------------------------------------------------------------------
comptime AGG_WALK_COUNT = 0
"""Count grouped-aggregate nodes. Hashes NOTHING.
(`count_grouped_aggregate_nodes`.)"""
comptime AGG_WALK_CHEAP = 1
"""Histogram the CHEAP key. Folds no resident bytes. The pre-grouping."""
comptime AGG_WALK_EXACT = 2
"""Histogram the EXACT key, but only for nodes whose cheap key is `hot`."""


def _walk_grouped_aggregates(
    plan: LogicalPlan,
    mode: Int,
    hot: Dict[UInt64, Int],
    hot_all: Bool,
    mut counts: Dict[UInt64, Int],
    mut n_nodes: Int,
) raises:
    """The SINGLE traversal over the grouped-aggregate candidate set.

    ⚠ WHY ONE FUNCTION AND NOT THREE. The node count ("how many candidates
    are there?"), the cheap pre-grouping ("which candidates could possibly be
    equal?") and the exact histogram ("which ones ARE equal?") must agree on
    the walked node set EXACTLY. If the count saw fewer nodes than the exact
    walk, a caller that skips plans counting < 2 could skip a plan that has a
    duplicate; if the cheap walk saw fewer than the exact walk, a true
    duplicate could land outside every hot group and be missed. Either is a
    SILENT WRONG ANSWER (the q15 float-determinism class), not a missed
    optimization. Separate walks would have to be kept in agreement by tests,
    and a node kind added to one and not the others is the easiest possible
    mistake. Here the node set is shared by CONSTRUCTION: there is one
    `_walk_children`, and `mode` only changes what is computed AT a node,
    never which nodes are reached.

    Args:
        plan: Subtree to walk.
        mode: One of `AGG_WALK_COUNT` / `AGG_WALK_CHEAP` / `AGG_WALK_EXACT`.
        hot: In EXACT mode, the cheap keys whose group size is >= 2 — the only
             ones worth an exact hash. Ignored in the other modes.
        hot_all: In EXACT mode, hash EVERY candidate regardless of `hot` (the
             un-pre-grouped walk `collect_agg_subtree_hashes` runs).
        counts: Output histogram, keyed by cheap or exact hash per `mode`.
        n_nodes: Output — grouped-aggregate nodes visited, in EVERY mode.
    """
    if _is_grouped_aggregate(plan):
        n_nodes += 1
        if mode == AGG_WALK_CHEAP:
            planner_scale_note_agg_cse_cheap()
            var c = plan.structural_hash_modulo_inmem_id()
            if c in counts:
                counts[c] = counts[c] + 1
            else:
                counts[c] = 1
        elif mode == AGG_WALK_EXACT:
            var wanted = hot_all
            if not wanted:
                planner_scale_note_agg_cse_cheap()
                wanted = plan.structural_hash_modulo_inmem_id() in hot
            if wanted:
                # ⛔ THE O(RESIDENT BYTES) STEP. `structural_hash()` renders
                # every in-mem leaf's `inmem_id=` through
                # `InMemorySource.structural_id` -> `Column.content_hash`.
                planner_scale_note_agg_cse_hash()
                var h = plan.structural_hash()
                if h in counts:
                    counts[h] = counts[h] + 1
                else:
                    counts[h] = 1
    _walk_children(plan, mode, hot, hot_all, counts, n_nodes)


def _walk_children(
    plan: LogicalPlan,
    mode: Int,
    hot: Dict[UInt64, Int],
    hot_all: Bool,
    mut counts: Dict[UInt64, Int],
    mut n_nodes: Int,
) raises:
    """THE one child recursion. A node kind added here is added to the node
    count, the cheap pre-grouping and the exact histogram simultaneously —
    which is the entire point of the shared walk."""
    if plan.tag == PLAN_FILTER:
        _walk_grouped_aggregates(
            plan._filter.value()[].child[], mode, hot, hot_all, counts, n_nodes
        )
    elif plan.tag == PLAN_PROJECT:
        _walk_grouped_aggregates(
            plan._project.value()[].child[], mode, hot, hot_all, counts, n_nodes
        )
    elif plan.tag == PLAN_AGGREGATE:
        _walk_grouped_aggregates(
            plan._aggregate.value()[].child[],
            mode,
            hot,
            hot_all,
            counts,
            n_nodes,
        )
    elif plan.tag == PLAN_JOIN:
        _walk_grouped_aggregates(
            plan._join.value()[].left[], mode, hot, hot_all, counts, n_nodes
        )
        _walk_grouped_aggregates(
            plan._join.value()[].right[], mode, hot, hot_all, counts, n_nodes
        )
    elif plan.tag == PLAN_SORT:
        _walk_grouped_aggregates(
            plan._sort.value()[].child[], mode, hot, hot_all, counts, n_nodes
        )
    elif plan.tag == PLAN_LIMIT:
        _walk_grouped_aggregates(
            plan._limit.value()[].child[], mode, hot, hot_all, counts, n_nodes
        )
    elif plan.tag == PLAN_DISTINCT:
        _walk_grouped_aggregates(
            plan._distinct.value()[].child[],
            mode,
            hot,
            hot_all,
            counts,
            n_nodes,
        )
    elif plan.tag == PLAN_TOPN:
        _walk_grouped_aggregates(
            plan._topn.value()[].child[], mode, hot, hot_all, counts, n_nodes
        )
    elif plan.tag == PLAN_ASOF_JOIN:
        _walk_grouped_aggregates(
            plan._asof_join.value()[].left[],
            mode,
            hot,
            hot_all,
            counts,
            n_nodes,
        )
        _walk_grouped_aggregates(
            plan._asof_join.value()[].right[],
            mode,
            hot,
            hot_all,
            counts,
            n_nodes,
        )
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            _walk_grouped_aggregates(
                ud.children[i][], mode, hot, hot_all, counts, n_nodes
            )
    # PLAN_SCAN / leaves and un-walked kinds: nothing to recurse.


def count_grouped_aggregate_nodes(plan: LogicalPlan) raises -> Int:
    """The number of GROUPED PLAN_AGGREGATE nodes the collect walk would
    consider — the SAME node set, via the SAME recursion, hashing nothing.

    A LOWER BOUND FOR FOLDING. A subtree is a duplicate only when its hash
    has `counts[h] >= 2`, and a `Dict` value cannot reach 2 with fewer than 2
    insertions. So a plan with `< 2` grouped aggregate nodes CANNOT fold, and
    a caller may skip the hash walk on it with an identical outcome; that is
    a proof, not a heuristic. The hash walk is not cheap: `structural_hash()`
    renders every in-mem leaf's `inmem_id=`, which is
    `InMemorySource.structural_id` -> `Column.content_hash` — an
    O(RESIDENT BYTES) fold. This walk is O(nodes) and hashes nothing.

    The equivalence with the collect walk is structural — both are
    `_walk_grouped_aggregates` under a different `mode`.

    The count cannot be read off the SQL: optimizer rules SYNTHESIZE
    aggregates (`eager_agg`'s cross-side pre-agg is one), so a one-`GROUP BY`
    query can yield a plan with two grouped aggregate nodes."""
    var counts = Dict[UInt64, Int]()
    var hot = Dict[UInt64, Int]()
    var n = 0
    _walk_grouped_aggregates(plan, AGG_WALK_COUNT, hot, False, counts, n)
    return n


def collect_agg_subtree_cheap_keys(
    plan: LogicalPlan, mut counts: Dict[UInt64, Int]
) raises -> Int:
    """`counts[structural_hash_modulo_inmem_id(subtree)] += 1` per grouped
    aggregate node. Returns the node count.

    THE CHEAP KEY IS A COARSENING OF THE EXACT ONE — that is the whole
    soundness argument, and it runs in the direction the fold needs:

        structural_hash(a) == structural_hash(b)
          ==> cheap(a) == cheap(b)

    so two aggregate subtrees that the exact histogram would have counted
    together are ALWAYS in the same cheap group. A cheap group of size 1
    therefore cannot contain a foldable duplicate, and if NO cheap group
    reaches size 2 then no exact hash can reach count 2 either — a caller can
    stop without hashing any resident bytes. False cheap collisions cost
    only the exact hashes that then resolve them; they never make a duplicate
    that the exact key would not have made, because the duplicate test is
    still made on the EXACT hash.

    ⚠ It is a KEY, not an IDENTITY, and must never stand in for
    `structural_id`, which hashes "two separately-constructed sources over
    identical content EQUAL *and* two distinct tables APART"; this key
    deliberately gives up the second half."""
    var hot = Dict[UInt64, Int]()
    var n = 0
    _walk_grouped_aggregates(plan, AGG_WALK_CHEAP, hot, False, counts, n)
    return n


def collect_agg_subtree_hashes(
    plan: LogicalPlan, mut counts: Dict[UInt64, Int]
) raises:
    """`counts[structural_hash(subtree)] += 1` for EVERY grouped aggregate node
    — the un-pre-grouped collect walk. O(nodes) in nodes but
    O(RESIDENT BYTES) in data.

    The ungated walk, and the differential ORACLE for the pre-grouped one:
    `collect_agg_subtree_hashes_in_groups` must reach the same `>= 2` verdict
    on every plan."""
    var hot = Dict[UInt64, Int]()
    var n = 0
    _walk_grouped_aggregates(plan, AGG_WALK_EXACT, hot, True, counts, n)


def collect_agg_subtree_hashes_in_groups(
    plan: LogicalPlan, hot: Dict[UInt64, Int], mut counts: Dict[UInt64, Int]
) raises:
    """`counts[structural_hash(subtree)] += 1` for every grouped aggregate node
    whose CHEAP key is in `hot` — i.e. the exact content hash is computed only
    where two candidates could possibly be equal.

    `counts[h] >= 2` here holds for exactly the same `h` as in the ungated
    `collect_agg_subtree_hashes`: by the coarsening, every node contributing to
    an exact count of >= 2 shares one cheap key, that key's group size is
    therefore >= 2, so it is hot and every one of those nodes is hashed."""
    var n = 0
    _walk_grouped_aggregates(plan, AGG_WALK_EXACT, hot, False, counts, n)


# -----------------------------------------------------------------------------
# Step 2 -- find: a copy of the FIRST aggregate subtree whose hash == target.
# -----------------------------------------------------------------------------
def find_agg_subtree_by_hash(
    plan: LogicalPlan, target: UInt64
) raises -> Optional[LogicalPlan]:
    if _is_grouped_aggregate(plan) and plan.structural_hash() == target:
        return Optional[LogicalPlan](_copy_plan(plan))
    if plan.tag == PLAN_FILTER:
        return find_agg_subtree_by_hash(plan._filter.value()[].child[], target)
    elif plan.tag == PLAN_PROJECT:
        return find_agg_subtree_by_hash(plan._project.value()[].child[], target)
    elif plan.tag == PLAN_AGGREGATE:
        return find_agg_subtree_by_hash(
            plan._aggregate.value()[].child[], target
        )
    elif plan.tag == PLAN_JOIN:
        var l = find_agg_subtree_by_hash(plan._join.value()[].left[], target)
        if l:
            return l^
        return find_agg_subtree_by_hash(plan._join.value()[].right[], target)
    elif plan.tag == PLAN_SORT:
        return find_agg_subtree_by_hash(plan._sort.value()[].child[], target)
    elif plan.tag == PLAN_LIMIT:
        return find_agg_subtree_by_hash(plan._limit.value()[].child[], target)
    elif plan.tag == PLAN_DISTINCT:
        return find_agg_subtree_by_hash(
            plan._distinct.value()[].child[], target
        )
    elif plan.tag == PLAN_TOPN:
        return find_agg_subtree_by_hash(plan._topn.value()[].child[], target)
    elif plan.tag == PLAN_ASOF_JOIN:
        var la = find_agg_subtree_by_hash(
            plan._asof_join.value()[].left[], target
        )
        if la:
            return la^
        return find_agg_subtree_by_hash(
            plan._asof_join.value()[].right[], target
        )
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            var uc = find_agg_subtree_by_hash(ud.children[i][], target)
            if uc:
                return uc^
    return None


# -----------------------------------------------------------------------------
# Step 3 -- replace: every grouped aggregate subtree the walk reaches whose
# hash == target becomes an `InMemorySource` scan leaf sharing `source`
# (refcount-bump per occurrence).
# -----------------------------------------------------------------------------
def replace_agg_subtree_with_source(
    var plan: LogicalPlan, target: UInt64, source: InMemorySource
) raises -> LogicalPlan:
    if _is_grouped_aggregate(plan) and plan.structural_hash() == target:
        # The leaf takes the aggregate's own output_schema; `source` is
        # expected to hold that aggregate's materialized result, so every
        # consumer sees the same columns.
        var sch = _copy_schema(plan.output_schema)
        return LogicalPlan.scan_from_source(SourceVariant(source.copy()), sch^)

    if plan.tag == PLAN_FILTER:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._filter.value()[].child[]), target, source
        )
        var pred = plan._filter.value()[].predicate.copy()
        return LogicalPlan.filter(pred^, child^)
    elif plan.tag == PLAN_PROJECT:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._project.value()[].child[]), target, source
        )
        var exprs = _copy_exprs(plan._project.value()[].exprs)
        return LogicalPlan.project(exprs^, child^)
    elif plan.tag == PLAN_AGGREGATE:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._aggregate.value()[].child[]), target, source
        )
        var group_by = _copy_exprs(plan._aggregate.value()[].group_by)
        var agg_exprs = _copy_aggs(plan._aggregate.value()[].agg_exprs)
        return LogicalPlan.aggregate(group_by^, agg_exprs^, child^)
    elif plan.tag == PLAN_JOIN:
        var left = replace_agg_subtree_with_source(
            _copy_plan(plan._join.value()[].left[]), target, source
        )
        var right = replace_agg_subtree_with_source(
            _copy_plan(plan._join.value()[].right[]), target, source
        )
        var left_on = plan._join.value()[].left_on.copy()
        var right_on = plan._join.value()[].right_on.copy()
        var sd_algo = plan._join.value()[].algo_hint
        var sd_resid: Optional[OwnedPointer[Expr]] = None
        if plan._join.value()[].has_residual():
            sd_resid = OwnedPointer(
                plan._join.value()[].residual.value()[].copy()
            )
        return LogicalPlan.join(
            left^,
            right^,
            left_on^,
            right_on^,
            plan._join.value()[].join_type,
            sd_algo,
            sd_resid^,
        )
    elif plan.tag == PLAN_SORT:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._sort.value()[].child[]), target, source
        )
        var keys = plan._sort.value()[].keys.copy()
        var desc = plan._sort.value()[].descending.copy()
        # Carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(keys^, desc^, child^, nf_copy^)
    elif plan.tag == PLAN_LIMIT:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._limit.value()[].child[]), target, source
        )
        # MOJO 1.0.0: `.n` and `.offset` in one call are two walks of the
        # same chain; the second invalidates the first. Bind once.
        ref ld = plan._limit.value()[]
        return LogicalPlan.limit(ld.n, child^, offset=ld.offset)
    elif plan.tag == PLAN_DISTINCT:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._distinct.value()[].child[]), target, source
        )
        var cols_opt: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols_opt = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols_opt^, child^)
    elif plan.tag == PLAN_TOPN:
        var child = replace_agg_subtree_with_source(
            _copy_plan(plan._topn.value()[].child[]), target, source
        )
        var keys = plan._topn.value()[].keys.copy()
        var desc = plan._topn.value()[].descending.copy()
        # Carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._topn.value()[].nulls_first.copy())
        return LogicalPlan.topn(
            keys^, desc^, plan._topn.value()[].n, child^, nf_copy^
        )

    # Un-walked kinds (scan / leaves / asof / union / partition-by / cast):
    # no fold.
    return plan^


# =============================================================================
# ★★ COMMON-AGGREGATE DEDUP -- DuckDB's `CommonAggregateOptimizer`, ported
# =============================================================================
#
# ⛔⛔ THIS IS THE OTHER HALF OF A PAIR. ON ITS OWN IT RARELY FINDS ANYTHING.
# Nothing a human writes says `SELECT sum(a), sum(a)`; what makes this rule
# earn its walk is `optimizer_sum_rewrite.rewrite_sum_of_offset`, which
# DELIBERATELY emits one `SUM(x)` per matched aggregate plus one `COUNT(x)`
# per non-zero offset, leaving duplicates for this rule to collapse. ClickBench
# cbq29 (`sum(rw), sum(rw+1), ... sum(rw+89)`) leaves the rewrite with **179**
# aggregates and leaves this rule with **2**. The rewrite alone multiplies the
# aggregates; this rule alone has nothing to collapse in that query.
#
# ⚠ THIS IS A DIFFERENT SUBJECT FROM THE REST OF THIS FILE. Everything above
# folds a duplicated AGGREGATE *SUBTREE* (one `Aggregate` node appearing twice
# in a plan) into one shared in-memory source. This folds duplicated AGGREGATE
# *EXPRESSIONS* inside ONE `Aggregate` node. Same word, different altitude;
# they do not interact.
#
# SHAPE. `Aggregate[a, a, b]` becomes `Project[alias(k0,n0), alias(k0,n1),
# alias(k1,n2)] <- Aggregate[a as k0, b as k1]`, where `n0..n2` are read off
# the ORIGINAL node's `output_schema`.
#
# ⛔ THE PRIVATE `__acse_<i>` ALIASES ARE NOT COSMETIC -- THEY ARE WHAT MAKES
# THE REWRITE SCHEMA-STABLE. An UNALIASED aggregate's output name is generated
# by `LogicalPlan.aggregate`'s `_disambiguate_field` from its POSITION among
# the surviving names: `sum(a), sum(a), sum(b)` names them `sum, sum_1, sum_2`,
# and deduping to `sum(a), sum(b)` would rename the SURVIVING `sum(b)` from
# `sum_2` to `sum_1`. Every kept aggregate is therefore given an explicit
# private alias, and the Project renames it back to the name the original node
# published. That is also why the projection's names are READ from
# `output_schema` rather than re-derived.
#
# EQUALITY IS STRICT AND CLOSED. `_acse_expr_equal` recognises COL_REF /
# LITERAL / BINARY_OP / UNARY_OP / ALIAS and answers **False for everything
# else**. ⛔ It deliberately does NOT reuse `plan_helpers._expr_fingerprint`:
# that function's fallback arm fingerprints an unhandled tag by its text
# rendering (`"?:<tag>:" + _fp_str(String(expr))`), so equality for those tags would
# rest on how an expression prints. Collapsing one aggregate into another
# needs every equal answer to come from an arm that compares the tag's
# fields; any other tag declines.
# =============================================================================



def _acse_expr_equal(imm a: Expr, imm b: Expr) -> Bool:
    """Strict structural equality over a CLOSED set of expression tags.

    An ALIAS wrapper is transparent (it names an output, it does not change a
    value). Any tag outside the set answers False -- DECLINING to dedup, which
    is always safe.
    """
    if a.tag == EXPR_ALIAS:
        return _acse_expr_equal(a.alias_child_ref(), b)
    if b.tag == EXPR_ALIAS:
        return _acse_expr_equal(a, b.alias_child_ref())
    if a.tag != b.tag:
        return False
    if a.tag == EXPR_COL_REF:
        return (
            a.col_ref_name() == b.col_ref_name()
            and a.col_ref_side() == b.col_ref_side()
        )
    if a.tag == EXPR_LITERAL:
        return a.literal_value() == b.literal_value()
    if a.tag == EXPR_BINARY_OP:
        if a.binary_op() != b.binary_op():
            return False
        if not _acse_expr_equal(a.binary_left_ref(), b.binary_left_ref()):
            return False
        return _acse_expr_equal(a.binary_right_ref(), b.binary_right_ref())
    if a.tag == EXPR_UNARY_OP:
        if a.unary_op() != b.unary_op():
            return False
        return _acse_expr_equal(a.unary_child_ref(), b.unary_child_ref())
    return False


def _acse_slot_equal(imm a: Optional[Expr], imm b: Optional[Expr]) -> Bool:
    """Slot-wise equality: both empty, or both present and structurally equal."""
    if not a:
        return not b
    if not b:
        return False
    return _acse_expr_equal(a.value(), b.value())


def _acse_agg_equal(imm a: AggExpr, imm b: AggExpr) -> Bool:
    """Two aggregates compute the same value.

    ⛔ `alias_name` is NOT compared -- it names the OUTPUT, and collapsing two
    identically-computed aggregates with different output names is the entire
    point. All four child slots are compared, so a bivariate agg whose second
    argument differs is correctly NOT a duplicate.
    """
    if a.func != b.func:
        return False
    if not _acse_slot_equal(a.child, b.child):
        return False
    if not _acse_slot_equal(a.child1, b.child1):
        return False
    if not _acse_slot_equal(a.child2, b.child2):
        return False
    return _acse_slot_equal(a.child3, b.child3)


def dedup_common_aggregates(var plan: LogicalPlan) raises -> LogicalPlan:
    """Wrapper around `dedup_common_aggregates_inplace`."""
    dedup_common_aggregates_inplace(plan)
    return plan^


def dedup_common_aggregates_inplace(mut plan: LogicalPlan) raises:
    """Collapse structurally-identical aggregate expressions within each
    `Aggregate` node reached through Aggregate / Filter / Project / Join /
    Sort / Limit / Distinct / TopN, preserving that node's output schema
    exactly. Other node kinds (Union, AsofJoin, ...) are not walked."""
    if plan.tag == PLAN_AGGREGATE:
        dedup_common_aggregates_inplace(plan._aggregate.value()[].child[])
        _acse_maybe_dedup(plan)
    elif plan.tag == PLAN_FILTER:
        dedup_common_aggregates_inplace(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        dedup_common_aggregates_inplace(plan._project.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        dedup_common_aggregates_inplace(plan._join.value()[].left[])
        dedup_common_aggregates_inplace(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        dedup_common_aggregates_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        dedup_common_aggregates_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        dedup_common_aggregates_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        dedup_common_aggregates_inplace(plan._topn.value()[].child[])


def _acse_analyze(imm plan: LogicalPlan, mut rep_of: List[Int]) -> Int:
    """For each aggregate, the index of its REPRESENTATIVE (the first aggregate
    it is equal to; itself when unique). Returns the number of duplicates --
    0 means DECLINE.

    ⚠ ONE interior reference into `plan._aggregate`, held for the whole scan.
    """
    ref agg_data = plan._aggregate.value()[]
    if agg_data.has_udf():
        return 0
    if agg_data.group_topk:
        # A SORT/TOPN stamp that `LogicalPlan.aggregate` cannot carry. Decline
        # rather than silently drop it.
        return 0
    var n = len(agg_data.agg_exprs)
    if n < 2:
        return 0
    var dups = 0
    for i in range(n):
        var rep = i
        for j in range(i):
            if rep_of[j] == j and _acse_agg_equal(
                agg_data.agg_exprs[i], agg_data.agg_exprs[j]
            ):
                rep = j
                break
        rep_of.append(rep)
        if rep != i:
            dups += 1
    return dups


def _acse_build(
    imm plan: LogicalPlan,
    imm rep_of: List[Int],
    mut new_aggs: AggExprArray,
    mut proj_exprs: ExprArray,
    mut group_copy: ExprArray,
    mut est_groups: Optional[Int],
) raises -> LogicalPlan:
    """Build the deduped aggregate list + the renaming projection; return a deep
    copy of the aggregate's child."""
    var out_names = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out_names.append(plan.output_schema.field_name(i))

    ref agg_data = plan._aggregate.value()[]
    var n_gb = len(agg_data.group_by)
    for g in range(n_gb):
        group_copy.append(agg_data.group_by[g].copy())
        proj_exprs.append(Expr.col_ref(out_names[g]))
    if agg_data.estimated_groups:
        est_groups = Optional[Int](agg_data.estimated_groups.value())

    var n = len(agg_data.agg_exprs)
    for i in range(n):
        var name_i = String("__acse_") + String(rep_of[i])
        if rep_of[i] == i:
            var kept = agg_data.agg_exprs[i].copy()
            kept.alias_name = Optional[String](name_i)
            new_aggs.append(kept^)
        proj_exprs.append(
            Expr.alias(Expr.col_ref(name_i), out_names[n_gb + i])
        )

    return _copy_plan(agg_data.child[])


def _acse_maybe_dedup(mut plan: LogicalPlan) raises:
    """`plan` is a PLAN_AGGREGATE. Dedup it if it carries duplicates."""
    var rep_of = List[Int]()
    if _acse_analyze(plan, rep_of) == 0:
        return

    var new_aggs = AggExprArray()
    var proj_exprs = ExprArray()
    var group_copy = ExprArray()
    var est_groups: Optional[Int] = None
    var child_copy = _acse_build(
        plan, rep_of, new_aggs, proj_exprs, group_copy, est_groups
    )

    var new_agg_plan = LogicalPlan.aggregate(
        group_copy^, new_aggs^, child_copy^
    )
    if est_groups:
        new_agg_plan._aggregate.value()[].estimated_groups = Optional[Int](
            est_groups.value()
        )
    plan = LogicalPlan.project(proj_exprs^, new_agg_plan^)
