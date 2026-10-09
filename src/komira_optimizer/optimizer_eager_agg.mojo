# =============================================================================
# Eager aggregation — cross-side aggregate pushdown below a join
# =============================================================================
#
# The general DuckDB "aggregate pushdown" lever, done as a CROSS-SIDE
# transform (distinct from the same-side `optimizer_partial_agg.push_aggregate_
# below_join`, which requires ALL agg-referenced columns on one side and
# therefore fires on ZERO TPC-H queries).
#
# Pattern (INNER shown; a LEFT join is handled only when S is its right side):
#
#     Aggregate(GB, AGGS, Join(L, R, L.lk = R.rk, INNER))
#
# where every aggregate INPUT column resolves to ONE side S (the "many"
# side), and every group-by key partitions cleanly onto one side. We push
# a PARTIAL aggregate onto S grouped by (GB∩S) ∪ (S join keys), then a
# MERGE aggregate above the join re-combines:
#
#     MergeAgg(GB, merge(AGGS),
#         Join(
#             PartialAgg((GB∩S) ∪ S.keys, partial(AGGS), S),   # S pre-reduced
#             other,
#             L.lk = R.rk, INNER))
#
# Merge semantics per op (identical to optimizer_partial_agg):
#     SUM   -> partial SUM,   merge SUM
#     COUNT -> partial COUNT, merge SUM     (sum of partial counts)
#     MIN   -> partial MIN,   merge MIN
#     MAX   -> partial MAX,   merge MAX
# AVG / COUNT_DISTINCT are NOT whitelisted (two-phase / sketch merge).
#
# SOUNDNESS (INNER): the partial pre-aggregation collapses S rows sharing
# (GB∩S, S.key); the join replicates each partial group by its match count
# on `other`; the merge re-combines. Because the fan-out replication factor
# is identical to the un-pushed join (every S row in a group shares the
# same key, hence the same match set), SUM/COUNT/MIN/MAX are preserved
# WITHOUT any uniqueness proof on `other`. Verified by construction; comparing
# query results with the pass on and off is the empirical check.
#
# COST GATE (`_eager_pushdown_beneficial`): the pre-agg pays for itself
# only when S is large AND the join keeps most of S's rows (i.e. `other`
# is NOT selectively filtered). If `other` carries a selective filter the
# join discards most S rows cheaply and the full agg pass over S is pure
# overhead — this is the Q10 shape. We gate on the DOWNSTREAM join
# selectivity using real footer row_count (this pass reads no per-column
# NDV, so `estimate_cardinality` row-count + the raw scan `row_count` are
# the signals it has).
#
# ⛔ AND THE HALF THAT SENTENCE LEAVES OUT, WHICH HAS BEEN MISQUOTED TWICE AS
# "eager agg is gated on real footer row counts". WHEN THERE
# IS NO FOOTER ROW COUNT, THIS COST GATE CANNOT DECLINE AT ALL:
#
#   * `LogicalPlan.scan_from_source` defaults `row_count = None`. A scan has a
#     row count only when the code that built it stamped one (a parquet footer
#     row count is the designed source); an in-memory, CSV, NDJSON or Avro
#     scan, or a parquet scan whose footer row count was not stamped, has none.
#   * `estimate_cardinality` then returns `DEFAULT_ROW_COUNT` = 1,000,000, which
#     clears `EAGER_MIN_S_ROWS` (50,000) 20x over — on a FOUR-ROW fixture.
#   * `_leaf_base_rows` returns `EAGER_BASE_NO_STATS` for such a scan, and
#     gate 3's ratio arm is guarded by `if other_base > 0:`, so the
#     selectivity decline — the Q10 guard, the whole point of the paragraph
#     above — is SKIPPED ENTIRELY.
#
# ⇒ For a row-count-less source the size test is met by a CONSTANT and the
# selectivity test never runs, leaving `_classify_eager_push`'s SHAPE check as
# the only gate. Every such source gets the pre-aggregation whenever the shape
# qualifies, REGARDLESS OF ACTUAL SIZE. That is not a bug report — it is the
# documented behaviour of a stats-free plan — but do not cite this pass as
# "runtime-data-gated" without saying "when a footer exists".
#
# ⭐ THE CARVE-OUT ABOVE COVERS ONLY A SCAN WITHOUT A ROW COUNT. When the other
# side of the join bottoms out on a JOIN, `_leaf_base_rows` reaches no scan
# base at all. That is not a missing statistic, it is a MISSING DENOMINATOR:
# there is nothing for a cover ratio to be a ratio OF. That case returns
# `EAGER_BASE_MULTI_WAY` and gate 3 DECLINES on it (clause 3a). Both cases once
# shared one `-1` and this one skipped the test, so the pass fired unguarded on
# every 3-or-more-table query. `tpch/q3_shipping_priority` is that shape: its
# cover ratio, had it been computed, is 147,126/1,500,000 = 9.81% against the
# 1/2 threshold.
# ⛔ Do NOT "finish" this by declining `EAGER_BASE_NO_STATS` too — that is the
# documented behaviour immediately above. Both halves, decline and
# carve-out, are pinned by `tests/test_optimizer_eager_agg_paths.mojo`.
#
# NO KILL SWITCH: the pass is UNCONDITIONAL (no environment variable turns
# it off). Whether it runs is the caller's decision: komira_optimizer has no
# driver that orders its passes.
# =============================================================================

from std.collections import Set
from std.memory import OwnedPointer

from komira_plan_expr.expr import Expr, EXPR_COL_REF
from komira_plan_expr.col_expr import UN_IS_NULL, when_then_else
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
    JOIN_LEFT,
)
from komira_plan_ir.plan_helpers import (
    _copy_expr_array,
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
from .optimizer_partial_agg import (
    _all_cols_in_schema,
    _schema_has_field,
    _agg_output_name,
)
from .optimizer_stats import estimate_cardinality


# =============================================================================
# Cost-gate tunables
# =============================================================================

# Minimum estimated rows on the pushed (S) side before a full agg pass is
# worth paying. Below this, the pre-agg overhead dominates any join saving.
comptime EAGER_MIN_S_ROWS: Int = 50_000

# Downstream-join-selectivity gate: fire only when the OTHER side keeps at
# least COVER_NUM/COVER_DEN of its base (pre-filter) rows. A selectively-
# filtered other side (e.g. Q10's orders, filtered to a three-month range)
# means the join discards most S rows cheaply, so pre-aggregating all of S
# is pure overhead. q13's customer side is unfiltered (100% cover) -> fire.
comptime EAGER_OTHER_COVER_NUM: Int = 1
comptime EAGER_OTHER_COVER_DEN: Int = 2

# `_leaf_base_rows` sentinels. There are TWO reasons it cannot return a base
# row count, they are structurally different facts, and THEY DEMAND OPPOSITE
# DECISIONS FROM THE COVER GATE. Both stay negative so every `> 0` reader
# keeps its meaning.
#
#   EAGER_BASE_NO_STATS    A single scan base IS reachable; it simply carries
#                          no `row_count` (a non-parquet scan, or a parquet
#                          leaf whose footer row count was not stamped).
#                          This is the SHAPE the pass was designed
#                          for and only the STATISTIC is absent, so the cover
#                          test is skipped and the pass may still fire — the
#                          documented stats-free behaviour described in this
#                          file's header.
#   EAGER_BASE_MULTI_WAY   NO single scan base is reachable AT ALL: the other
#                          side bottoms out on a join / aggregate / distinct /
#                          limit, i.e. an intermediate that something has
#                          ALREADY reduced. There is no "base row count" for a
#                          cover ratio to be a ratio OF, so the gate cannot
#                          measure and MUST DECLINE. See clause 3.
comptime EAGER_BASE_NO_STATS: Int = -1
comptime EAGER_BASE_MULTI_WAY: Int = -2


# =============================================================================
# Decision struct
# =============================================================================

comptime _EAGER_NONE: UInt8 = 0
comptime _EAGER_LEFT: UInt8 = 1
comptime _EAGER_RIGHT: UInt8 = 2


struct _EagerDecision(Movable):
    var kind: UInt8

    def __init__(out self, kind: UInt8):
        self.kind = kind


# =============================================================================
# Whitelist
# =============================================================================


@always_inline
def _is_eager_whitelisted(func: UInt8) -> Bool:
    """SUM / COUNT / MIN / MAX only. AVG (two-phase) and COUNT_DISTINCT
    (sketch merge) are excluded — their merge is not a single associative
    accumulator over the join fan-out."""
    return (
        func == AGG_SUM
        or func == AGG_COUNT
        or func == AGG_MIN
        or func == AGG_MAX
    )


@always_inline
def _write_eager_op_tag[W: Writer](mut writer: W, func: UInt8):
    """WRITE what `_eager_op_tag` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a pair bound
    CROSSED pairs one string's pointer with another's length. The lint
    that checks for this (`scripts/lint_literal_return_ladder.py`) is
    not in this tree."""
    if func == AGG_SUM:
        writer.write("sum")
        return
    if func == AGG_COUNT:
        writer.write("count")
        return
    if func == AGG_MIN:
        writer.write("min")
        return
    if func == AGG_MAX:
        writer.write("max")
        return
    writer.write("agg")
    return


@always_inline
def _eager_op_tag(func: UInt8) -> String:
    var out = String()
    _write_eager_op_tag(out, func)
    return out^


# =============================================================================
# Cost gate
# =============================================================================


def _is_reducible_leaf(plan: LogicalPlan) -> Bool:
    """True iff `plan` is a Scan, or a Filter/Project chain over a single
    Scan — i.e. a base relation that pre-aggregation genuinely reduces.
    A join / aggregate / distinct underneath makes this False (pushing a
    partial agg over a multi-way intermediate is the Q10 overhead case)."""
    var tag = plan.tag
    if tag == PLAN_SCAN:
        return True
    elif tag == PLAN_FILTER:
        return _is_reducible_leaf(plan._filter.value()[].child[])
    elif tag == PLAN_PROJECT:
        return _is_reducible_leaf(plan._project.value()[].child[])
    return False


def _leaf_base_rows(plan: LogicalPlan) -> Int:
    """Raw (pre-filter) footer row count of the scan under `plan`, walking
    through Filter/Project/Sort.

    On failure it returns ONE OF TWO NEGATIVE SENTINELS, never a bare -1:
    `EAGER_BASE_NO_STATS` when a single scan base IS reachable but carries no
    `row_count`, and `EAGER_BASE_MULTI_WAY` when no single scan base is
    reachable at all (a join / aggregate / distinct / limit underneath).

    ⛔ THE DISTINCTION IS LOAD-BEARING AND WAS THE DEFECT. Both cases used to
    return -1, and clause 3 of `_eager_pushdown_beneficial` was guarded by
    `if other_base > 0:` alone — so on every 3+-table query the cover test
    was SKIPPED rather than FAILED. Do not collapse these back into one."""
    var tag = plan.tag
    if tag == PLAN_SCAN:
        ref sd = plan._scan.value()[]
        if sd.row_count:
            return sd.row_count.value()
        return EAGER_BASE_NO_STATS
    elif tag == PLAN_FILTER:
        return _leaf_base_rows(plan._filter.value()[].child[])
    elif tag == PLAN_PROJECT:
        return _leaf_base_rows(plan._project.value()[].child[])
    elif tag == PLAN_SORT:
        return _leaf_base_rows(plan._sort.value()[].child[])
    return EAGER_BASE_MULTI_WAY


def _eager_pushdown_beneficial(
    join_plan: LogicalPlan, push_to_left: Bool
) -> Bool:
    """Row-count cost gate. Fire only when the pushed side S is large, is
    the many side, and the join is NON-selective on S (the other side is
    not selectively filtered). This pass reads no per-column NDV, so this
    is a row-count / footer-row-count model."""
    ref jd = join_plan._join.value()[]
    var s_est: Int
    var other_est: Int
    var other_base: Int
    if push_to_left:
        s_est = estimate_cardinality(jd.left[])
        other_est = estimate_cardinality(jd.right[])
        other_base = _leaf_base_rows(jd.right[])
    else:
        s_est = estimate_cardinality(jd.right[])
        other_est = estimate_cardinality(jd.left[])
        other_base = _leaf_base_rows(jd.left[])

    # 1. S must be large enough that reducing it is worth an agg pass.
    if s_est < EAGER_MIN_S_ROWS:
        return False
    # 2. S must be the many/fact side (>= other). If S is the smaller
    #    (likely unique / dimension) side, pre-aggregating by its join
    #    key does not reduce it and is pure overhead.
    if s_est < other_est:
        return False
    # 3. Downstream selectivity: decline when `other` is selectively
    #    filtered (join would discard most S rows cheaply = Q10).
    #
    # ⛔ 3a. AN UNMEASURABLE COST GATE FAILS **CLOSED**. When `other` bottoms
    # out on a join/aggregate/distinct/limit there is no base row count for
    # the cover ratio to be a ratio OF, and the pre-aggregate is being pushed
    # under a join whose other side something has ALREADY reduced — the exact
    # shape that throws the pre-aggregate away. This clause used to be guarded
    # by `if other_base > 0:` alone, so this case SKIPPED the test instead of
    # FAILING it and the pass fired unguarded on every 3+-table query.
    # `tpch/q3_shipping_priority` is that shape: its cover ratio is
    # 147,126/1,500,000 = 9.81% against the 1/2 threshold, a clear decline.
    # ⚠ NOTE WHAT IS *NOT* DECLINED HERE — `EAGER_BASE_NO_STATS`, a reachable
    # scan base that simply carries no `row_count`, still skips the ratio and
    # may fire. That is the documented stats-free behaviour in this file's
    # header; declining it too would turn the pass off for every in-memory /
    # CSV / NDJSON / Avro source in one edit. Both halves are pinned by
    # `tests/test_optimizer_eager_agg_paths.mojo`.
    if other_base == EAGER_BASE_MULTI_WAY:
        return False
    # 3b. The cover ratio, when there IS a base to compute it against.
    if other_base > 0:
        # other_est / other_base >= COVER_NUM / COVER_DEN  (avoid float)
        if (
            other_est * EAGER_OTHER_COVER_DEN
            < other_base * EAGER_OTHER_COVER_NUM
        ):
            return False
    return True


# =============================================================================
# Partial + merge aggregate construction
# =============================================================================


def _build_eager_partial_and_merge(
    aggs: AggExprArray,
    is_left_join: Bool,
    mut partials_out: AggExprArray,
    mut merges_out: AggExprArray,
):
    """Build the partial (on-S) and merge (above-join) aggregate lists.

    Precondition: every agg is in `_is_eager_whitelisted`. Partial output
    is aliased `__eager_<op>_<orig>`; the merge reads it back by name.

    SLICE 2 (is_left_join + COUNT): the merge over a LEFT join must map an
    unmatched (NULL) partial count to 0 — done via a coalesce synthesized
    as `WHEN partial IS NULL THEN 0 ELSE partial`. SUM/MIN/MAX over LEFT
    need no coalesce (unmatched -> NULL is correct for both un-pushed and
    pushed forms)."""
    for i in range(len(aggs)):
        var func = aggs[i].func
        var orig_name = _agg_output_name(aggs[i])
        var partial_name = String("__eager_") + _eager_op_tag(func) + "_" + orig_name

        var partial_child: Optional[Expr] = None
        if aggs[i].child:
            partial_child = aggs[i].child.value().copy()
        var pa: Optional[String] = partial_name.copy()
        partials_out.append(AggExpr(func, partial_child^, pa^))

        var merge_func = AGG_SUM if func == AGG_COUNT else func
        var merge_child_expr: Expr
        if is_left_join and func == AGG_COUNT:
            merge_child_expr = _coalesce_zero(partial_name^)
        else:
            merge_child_expr = Expr.col_ref(partial_name^)
        var mc: Optional[Expr] = merge_child_expr^
        var ma: Optional[String] = orig_name^
        merges_out.append(AggExpr(merge_func, mc^, ma^))


def _coalesce_zero(var col_name: String) -> Expr:
    """Synthesize `coalesce(col, 0)` as `WHEN col IS NULL THEN 0 ELSE col`.

    SLICE 2 (LEFT-count null bin): a LEFT join's unmatched rows null-extend
    the pushed side, so the partial COUNT reads NULL. The un-pushed
    `count(col)` counts non-NULLs -> 0 for an unmatched row, so the merge
    must map NULL partial-count -> 0. `materialize_agg_input` (not in this
    tree) is designed to run after this pass and materialize this WHEN expr
    into a Project column that the merge SUM reads. This is q13's c_count=0
    group."""
    var isnull = Expr.unary(UN_IS_NULL, Expr.col_ref(col_name.copy()))
    var zero = Expr.literal(ScalarValue.from_int(0))
    var passthrough = Expr.col_ref(col_name^)
    return when_then_else(isnull^, zero^, passthrough^)


# =============================================================================
# Classifier
# =============================================================================


def _classify_eager_push(
    agg_plan: LogicalPlan, join_plan: LogicalPlan
) -> _EagerDecision:
    """Borrow-only classification. Returns _EAGER_LEFT / _EAGER_RIGHT when
    the cross-side pushdown is sound + beneficial, else _EAGER_NONE."""
    ref jd = join_plan._join.value()[]

    # --- INNER (both directions) or LEFT (push-to-right only), no residual,
    #     decomposed equi-keys ------------------------------------------
    if jd.join_type != JOIN_INNER and jd.join_type != JOIN_LEFT:
        return _EagerDecision(_EAGER_NONE)
    if jd.has_residual():
        return _EagerDecision(_EAGER_NONE)
    if len(jd.left_on) == 0 or len(jd.right_on) == 0:
        return _EagerDecision(_EAGER_NONE)

    # --- Whitelist: all aggs SUM/COUNT/MIN/MAX --------------------------
    ref aggs = agg_plan._aggregate.value()[].agg_exprs
    var n_aggs = len(aggs)
    if n_aggs == 0:
        return _EagerDecision(_EAGER_NONE)
    for i in range(n_aggs):
        if not _is_eager_whitelisted(aggs[i].func):
            return _EagerDecision(_EAGER_NONE)

    # --- Collect aggregate INPUT columns (not group-by) -----------------
    var agg_input_cols = Set[String]()
    for i in range(n_aggs):
        if aggs[i].child:
            _collect_expr_columns(aggs[i].child.value(), agg_input_cols)
    if len(agg_input_cols) == 0:
        # count(*) — no input columns to anchor a side. Skip in SLICE 1.
        return _EagerDecision(_EAGER_NONE)

    # --- Determine S: the side containing ALL agg input columns ---------
    ref left_schema = jd.left[].output_schema
    ref right_schema = jd.right[].output_schema
    var all_left = _all_cols_in_schema(agg_input_cols, left_schema)
    var all_right = _all_cols_in_schema(agg_input_cols, right_schema)
    if all_left and all_right:
        # Ambiguous (a name present in both schemas) — skip.
        return _EagerDecision(_EAGER_NONE)
    if not all_left and not all_right:
        # Agg inputs span both sides — cannot push.
        return _EagerDecision(_EAGER_NONE)
    var push_to_left = all_left

    # --- LEFT join: only push onto the RIGHT (null-producing) side. ------
    # Pushing onto the preserved (left) side of a LEFT join has subtler
    # merge semantics (preserved-side fan-out) and is out of scope; the
    # q13 case pushes the aggregated many-side (orders) which is the right.
    if jd.join_type == JOIN_LEFT and push_to_left:
        return _EagerDecision(_EAGER_NONE)

    # --- S must be a REDUCIBLE LEAF (Scan / Filter* / Project* over ONE
    #     scan — no join/aggregate underneath). Pushing a partial agg over
    #     a multi-way sub-join intermediate is the Q10 shape (the pre-agg
    #     pass costs more than the buried-selective join saves). Restricting
    #     S to a leaf keeps Q10 (whose fact side is a sub-join) declined
    #     while admitting q13 (orders = Filter(Scan)).
    if push_to_left:
        if not _is_reducible_leaf(jd.left[]):
            return _EagerDecision(_EAGER_NONE)
    else:
        if not _is_reducible_leaf(jd.right[]):
            return _EagerDecision(_EAGER_NONE)

    # --- Group-by must partition cleanly onto one side ------------------
    ref gb = agg_plan._aggregate.value()[].group_by
    for i in range(len(gb)):
        var gcols = Set[String]()
        _collect_expr_columns(gb[i], gcols)
        if len(gcols) == 0:
            continue  # constant group key — side-agnostic.
        var g_left = _all_cols_in_schema(gcols, left_schema)
        var g_right = _all_cols_in_schema(gcols, right_schema)
        if not g_left and not g_right:
            # Group-by expr spans both sides — cannot cleanly split.
            return _EagerDecision(_EAGER_NONE)

    # --- Collision guard (push-to-right): a group-by column on S that
    #     also exists on the LEFT gets a `_right` suffix in the join
    #     output, breaking the merge's group-by reference. Skip. --------
    if not push_to_left:
        for i in range(len(gb)):
            var gcols = Set[String]()
            _collect_expr_columns(gb[i], gcols)
            if len(gcols) == 0:
                continue
            var on_right = _all_cols_in_schema(gcols, right_schema)
            var on_left = _all_cols_in_schema(gcols, left_schema)
            if on_right and not on_left:
                for c in gcols:
                    if _schema_has_field(left_schema, c):
                        return _EagerDecision(_EAGER_NONE)

    # --- Cost gate ------------------------------------------------------
    if not _eager_pushdown_beneficial(join_plan, push_to_left):
        return _EagerDecision(_EAGER_NONE)

    if push_to_left:
        return _EagerDecision(_EAGER_LEFT)
    return _EagerDecision(_EAGER_RIGHT)


# =============================================================================
# Rewrite
# =============================================================================


def _perform_eager_rewrite(
    agg_plan: LogicalPlan,
    var join_plan: LogicalPlan,
    push_to_left: Bool,
) raises -> LogicalPlan:
    """Consume join_plan; return MergeAgg(Join(PartialAgg(S), other)).

    All safety checks must already have passed via _classify_eager_push.
    """
    ref jd = join_plan._join.value()[]
    var left_on = jd.left_on.copy()
    var right_on = jd.right_on.copy()
    var jt = jd.join_type
    var algo = jd.algo_hint

    # S join keys (the keys on the side we push to).
    var s_keys: List[String]
    if push_to_left:
        s_keys = left_on.copy()
    else:
        s_keys = right_on.copy()

    # Build the partial group-by = (GB exprs on S) ∪ (S join keys).
    var partial_gb = ExprArray()
    var partial_gb_names = List[String]()
    ref gb = agg_plan._aggregate.value()[].group_by
    for i in range(len(gb)):
        var gcols = Set[String]()
        _collect_expr_columns(gb[i], gcols)
        if len(gcols) == 0:
            continue
        var on_s: Bool
        if push_to_left:
            on_s = _all_cols_in_schema(gcols, jd.left[].output_schema)
        else:
            on_s = _all_cols_in_schema(gcols, jd.right[].output_schema)
        if on_s:
            partial_gb.append(gb[i].copy())
            if gb[i].tag == EXPR_COL_REF:
                partial_gb_names.append(gb[i].col_ref_name())
    # Append S join keys not already present as group keys.
    for k in range(len(s_keys)):
        var already = False
        for n in range(len(partial_gb_names)):
            if partial_gb_names[n] == s_keys[k]:
                already = True
                break
        if not already:
            partial_gb.append(Expr.col_ref(s_keys[k]))
            partial_gb_names.append(s_keys[k])

    # Partial + merge agg lists.
    var partial_aggs = AggExprArray()
    var merge_aggs = AggExprArray()
    _build_eager_partial_and_merge(
        agg_plan._aggregate.value()[].agg_exprs,
        jt == JOIN_LEFT,
        partial_aggs,
        merge_aggs,
    )

    # Merge group-by = full original group-by (deep copy).
    var merge_gb = _copy_expr_array(agg_plan._aggregate.value()[].group_by)

    # Take the join children and reassemble.
    var left_child = _take_join_left(join_plan)
    var right_child = _take_join_right(join_plan)
    var new_left: LogicalPlan
    var new_right: LogicalPlan
    if push_to_left:
        new_left = LogicalPlan.aggregate(
            partial_gb^, partial_aggs^, left_child^
        )
        new_right = right_child^
    else:
        new_left = left_child^
        new_right = LogicalPlan.aggregate(
            partial_gb^, partial_aggs^, right_child^
        )

    var new_join = LogicalPlan.join(
        new_left^, new_right^, left_on^, right_on^, jt, algo
    )
    return LogicalPlan.aggregate(merge_gb^, merge_aggs^, new_join^)


# =============================================================================
# Top-level recursion
# =============================================================================


def eager_aggregate_pushdown(var plan: LogicalPlan) raises -> LogicalPlan:
    """Cross-side eager aggregation pushdown. UNCONDITIONAL — whether to run
    the pass is the caller's decision (komira_optimizer has no driver that
    orders its passes), so this entry always rewrites."""
    return _eager_rec(plan^)


def _is_fireable_join(plan: LogicalPlan) -> Bool:
    """A join node the pass may push under: INNER or LEFT, no residual."""
    if plan.tag != PLAN_JOIN:
        return False
    var jt = plan._join.value()[].join_type
    if jt != JOIN_INNER and jt != JOIN_LEFT:
        return False
    return not plan._join.value()[].has_residual()


def _is_pure_narrowing_project(plan: LogicalPlan) -> Bool:
    """True iff every projection expr is a PLAIN column reference (no
    rename, no computed expr). Such a Project only drops columns, so it can
    be peeled away from between an Aggregate and its Join child without
    losing any name the merge aggregate resolves against the join output.
    """
    if plan.tag != PLAN_PROJECT:
        return False
    ref exprs = plan._project.value()[].exprs
    if len(exprs) == 0:
        return False
    for i in range(len(exprs)):
        if exprs[i].tag != EXPR_COL_REF:
            return False
    return True


def _eager_rec(var plan: LogicalPlan) raises -> LogicalPlan:
    if plan.tag == PLAN_AGGREGATE:
        var child = _take_aggregate_child(plan)
        var new_child = _eager_rec(child^)

        # Case A: Aggregate directly over a fireable (INNER/LEFT) join.
        if _is_fireable_join(new_child):
            var decision = _classify_eager_push(plan, new_child)
            if decision.kind == _EAGER_LEFT or decision.kind == _EAGER_RIGHT:
                return _perform_eager_rewrite(
                    plan, new_child^, decision.kind == _EAGER_LEFT
                )

        # Case B: Aggregate over a pure-narrowing Project over a fireable
        # join (column pruning, not in this tree, inserts such a Project).
        # Peel the Project: the merge aggregate resolves GB + partial-agg
        # outputs against the join output directly, so dropping a plain
        # column-narrowing Project is answer-preserving.
        elif (
            new_child.tag == PLAN_PROJECT
            and _is_pure_narrowing_project(new_child)
            and _is_fireable_join(new_child._project.value()[].child[])
        ):
            var decision = _classify_eager_push(
                plan, new_child._project.value()[].child[]
            )
            if decision.kind == _EAGER_LEFT or decision.kind == _EAGER_RIGHT:
                var join_node = _take_project_child(new_child)
                return _perform_eager_rewrite(
                    plan, join_node^, decision.kind == _EAGER_LEFT
                )

        var new_gb = _copy_expr_array(plan._aggregate.value()[].group_by)
        var new_aggs = _copy_agg_expr_array_local(
            plan._aggregate.value()[].agg_exprs
        )
        return LogicalPlan.aggregate(new_gb^, new_aggs^, new_child^)

    elif plan.tag == PLAN_FILTER:
        var child = _take_filter_child(plan)
        var pred = plan._filter.value()[].predicate.copy()
        var new_child = _eager_rec(child^)
        return LogicalPlan.filter(pred^, new_child^)

    elif plan.tag == PLAN_PROJECT:
        var child = _take_project_child(plan)
        var new_child = _eager_rec(child^)
        var new_exprs = _copy_expr_array(plan._project.value()[].exprs)
        return LogicalPlan.project(new_exprs^, new_child^)

    elif plan.tag == PLAN_JOIN:
        var algo = plan._join.value()[].algo_hint
        var join_resid: Optional[OwnedPointer[Expr]] = None
        if plan._join.value()[].has_residual():
            join_resid = OwnedPointer(
                plan._join.value()[].residual.value()[].copy()
            )
        var lon = plan._join.value()[].left_on.copy()
        var ron = plan._join.value()[].right_on.copy()
        var jt = plan._join.value()[].join_type
        var left = _take_join_left(plan)
        var right = _take_join_right(plan)
        var new_left = _eager_rec(left^)
        var new_right = _eager_rec(right^)
        return LogicalPlan.join(
            new_left^, new_right^, lon^, ron^, jt, algo, join_resid^
        )

    elif plan.tag == PLAN_SORT:
        var child = _take_sort_child(plan)
        var new_child = _eager_rec(child^)
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
        var new_child = _eager_rec(child^)
        ref ld = plan._limit.value()[]
        return LogicalPlan.limit(ld.n, new_child^, offset=ld.offset)

    elif plan.tag == PLAN_DISTINCT:
        var child = _take_distinct_child(plan)
        var new_child = _eager_rec(child^)
        var cols_copy: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols_copy = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols_copy^, new_child^)

    elif plan.tag == PLAN_TOPN:
        var child = _take_topn_child(plan)
        var new_child = _eager_rec(child^)
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


def _copy_agg_expr_array_local(arr: AggExprArray) -> AggExprArray:
    """Deep copy an AggExprArray (child slot 0 + alias only — sufficient
    for the whitelist-restricted aggregates this pass rebuilds)."""
    var result = AggExprArray()
    for i in range(len(arr)):
        var child_copy: Optional[Expr] = None
        if arr[i].child:
            child_copy = arr[i].child.value().copy()
        var alias_copy: Optional[String] = None
        if arr[i].alias_name:
            alias_copy = arr[i].alias_name.value().copy()
        result.append(AggExpr(arr[i].func, child_copy^, alias_copy^))
    return result^
