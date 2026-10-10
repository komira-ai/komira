# =============================================================================
# Optimizer join + aggregate rules
# =============================================================================
#
# Rule 10: Aggregate pushdown below join (in optimizer_partial_agg.mojo)
# Rule 11: Inner -> Semi join conversion; Rule 11b: SEMI/ANTI reducer pushdown
# Rule 13: Absorb expression into aggregate
# Rule 17: Join build-side selection
# =============================================================================

from std.collections import Set
from std.memory import OwnedPointer

from komira_arrow.schema import Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr, EXPR_COL_REF, EXPR_ALIAS, EXPR_BINARY_OP, EXPR_UNARY_OP, EXPR_CAST,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR,
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
    PLAN_SCAN,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
    JOIN_ANTI,
)
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_ir.plan_helpers import (
    _copy_schema,
    _copy_expr_array,
    _copy_agg_expr_array,
    _copy_plan,
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
from .optimizer_stats import estimate_cardinality, estimate_row_width
# Rule 13 substitutes by NAME, so it takes the shared substitution walk and its
# safety mirror from `optimizer_project_merge_guard`: the walk descends a
# MathFn, and the mirror refuses an aggregand that reads a REPLACED column under
# a node the walk returns AS BUILT, so no aggregand reads the ORIGINAL column.
from .optimizer_project_merge_guard import (
    substitute_project_refs, expr_substitutes_safely,
)

from .optimizer_config import OptimizerConfig

# =============================================================================
# Rule 11: Inner -> Semi Join Conversion
# =============================================================================

def convert_inner_to_semi(var plan: LogicalPlan) -> LogicalPlan:
    """Convert inner joins to semi joins when right-side columns are unused
    AND either the right side is provably KEY-UNIQUE on the join keys, or a
    `DISTINCT` sitting directly above the projection makes the join's row
    MULTIPLICITY unobservable.

    Wrapper around `convert_inner_to_semi_inplace`.
    """
    convert_inner_to_semi_inplace(plan)
    return plan^


def convert_inner_to_semi_inplace(
    mut plan: LogicalPlan, dup_insensitive: Bool = False
):
    """In-place inner-to-semi conversion.

    Recurses children IN PLACE. The Project-above-Inner-Join case mutates
    the JoinData's join_type field directly from JOIN_INNER to JOIN_SEMI;
    no node restructuring needed.

    `dup_insensitive` says that the rows THIS node emits are consumed by an
    operator that discards duplicates, so the join fan-out this rule deletes
    cannot be observed downstream. ⛔ IT IS SET ON EXACTLY ONE EDGE — a
    `PLAN_DISTINCT` handing down to a `PLAN_PROJECT` child whose whole output
    row it dedups — and it is NEVER propagated any further. The adjacency IS
    the soundness argument; see `_distinct_absorbs_child_multiplicity`.
    """
    if plan.tag == PLAN_PROJECT:
        # ⛔ `False`, NOT `dup_insensitive`. A DISTINCT above THIS projection
        # says nothing about a Project-over-INNER nested BELOW it: whatever
        # sits in between (an aggregate, a join, a LIMIT) consumes those rows
        # itself and reads their multiplicity. Deleting fan-out under one of
        # those is precisely the silent wrong answer the uniqueness check prevents, so the
        # licence stops at the node it was granted for.
        convert_inner_to_semi_inplace(plan._project.value()[].child[], False)

        if plan._project.value()[].child[].tag == PLAN_JOIN and plan._project.value()[].child[]._join.value()[].join_type == JOIN_INNER:
            var proj_cols = Set[String]()
            ref proj_exprs = plan._project.value()[].exprs
            for i in range(len(proj_exprs)):
                _collect_expr_columns(proj_exprs[i], proj_cols)

            var uses_right = False
            ref left_schema = plan._project.value()[].child[]._join.value()[].left[].output_schema
            for col_name in proj_cols:
                var in_left = False
                for i in range(left_schema.num_columns()):
                    if left_schema.field_name(i) == col_name:
                        in_left = True
                        break
                if not in_left:
                    uses_right = True
                    break

            # ⛔ "NO RIGHT COLUMN IS READ" IS NOT THE PRECONDITION. KEY
            #    UNIQUENESS IS.
            #
            # An INNER join emits one row per MATCHING PAIR; a SEMI emits each
            # LEFT row AT MOST ONCE. So the rewrite is answer-preserving only
            # when no left row can match more than one right row — i.e. when
            # the right side's `right_on` is a SUPERKEY of that side. Dropping
            # unread right COLUMNS is orthogonal to dropping right ROWS, and
            # checking only the first does not license the second.
            #
            # Example: a dim
            # built as `Project([dk, d1v], d1 INNER JOIN d2 ON dk = dk2)` over
            # a d2 carrying THREE rows per key, rewritten to a SEMI, loses the
            # 3x fan-out, so a `SUM(fval)` over its join with a fact comes back
            # at one third of the true sum — a SILENT WRONG ANSWER, with the
            # right group count and the right column names.
            #
            # ⚠ PERF NOTE, STATED AND NOT HIDDEN: `_right_side_is_key_unique_on`
            # can only prove uniqueness STRUCTURALLY (an Aggregate/Distinct
            # whose keys the join keys cover, through the transparent
            # operators). There is no key catalog, so a right side that is a
            # bare SCAN of a table with a real primary key DECLINES. That
            # narrows Rule 11's fire set on TPC-H q2. Its ROW COUNTS are
            # unaffected (its right keys are genuine primary keys, so INNER
            # and SEMI agree there); the join stays INNER where a SEMI would do.
            #
            # TPC-H q20 is not narrowed: the licence below lets it fire.
            # q2 carries no DISTINCT and so is
            # still narrowed; q20's partsupp subquery,
            # written as `SELECT DISTINCT ps_suppkey`,
            # licenses the rewrite with no uniqueness proof at all.
            # ⭐ THE DISTINCT LICENCE — WHY ONE SHAPE NEEDS NO UNIQUENESS
            #    PROOF (TPC-H q20).
            #
            # The precondition below exists because an INNER emits one row per
            # matching PAIR while a SEMI emits each matching LEFT row ONCE: the
            # two relations differ ONLY in row MULTIPLICITY. So when the
            # consumer of this projection cannot OBSERVE multiplicity, the
            # rewrite is answer-preserving with no uniqueness proof at all:
            #
            #   DISTINCT( pi_L( L |><| R ) ) === DISTINCT( pi_L( L |>< R ) )
            #
            # Both sides are "the distinct pi_L images of the left rows having
            # at least one match in R". The join PREDICATE is identical (a SEMI
            # matches on the same keys with the same NULL semantics), and
            # `uses_right` above has already established that R contributes no
            # VALUE to the output — only existence.
            #
            # `dup_insensitive` is that consumer, granted on exactly one edge
            # by `_distinct_absorbs_child_multiplicity` and propagated nowhere.
            #
            # ⛔ THIS IS A SECOND SUFFICIENT CONDITION, NOT A RELAXATION OF THE
            # FIRST. With no DISTINCT above it the uniqueness precondition is
            # untouched and still decides. Making this branch unconditional
            # reinstates the silent wrong answer above (the `SUM(fval)` at
            # one third of the true sum). BOTH halves have
            # falsifiers in `tests/test_optimizer_join_semi_conversion_arms.mojo`.
            #
            # ⚠ ON q20 THIS IS THE WHOLE FIRE. The right side (the `forest%`
            # parts) is a bare `part` scan under a Filter+Project. `p_partkey`
            # IS part's primary key, but this IR has no key catalog, so the
            # structural prover cannot say so and correctly declines. The
            # `SELECT DISTINCT ps_suppkey` is the evidence it cannot read.
            if not uses_right and not dup_insensitive:
                # MOJO 1.0.0: the key list and the right subplan are two
                # projections of ONE walk of the JoinData; forming both inside
                # a single call expression invalidates the first. Copy the
                # (short) key list out first, then walk once more for the ref.
                var right_keys = (
                    plan._project.value()[].child[]._join.value()[]
                    .right_on.copy()
                )
                var right_unique = _right_side_is_key_unique_on(
                    plan._project.value()[].child[]._join.value()[].right[],
                    right_keys,
                )
                uses_right = not right_unique

            if not uses_right:
                # Mutate join_type in place. left/right children + keys
                # are unchanged; no rebuild needed.
                #
                # SEMI joins emit only left-side columns, so the Join's
                # output_schema must also narrow to left-only. We rebuild
                # just the Schema field (cheap: ~1 SchemaBuilder pass over
                # left columns) instead of the entire Join LogicalPlan.
                plan._project.value()[].child[]._join.value()[].join_type = JOIN_SEMI
                var new_join_schema = _copy_schema(plan._project.value()[].child[]._join.value()[].left[].output_schema)
                plan._project.value()[].child[].output_schema = new_join_schema^

    elif plan.tag == PLAN_FILTER:
        convert_inner_to_semi_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        convert_inner_to_semi_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        convert_inner_to_semi_inplace(plan._join.value()[].left[])
        convert_inner_to_semi_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        convert_inner_to_semi_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        convert_inner_to_semi_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        # THE ONE EDGE THAT GRANTS THE LICENCE. Every other recursion in this
        # function takes the `False` default.
        convert_inner_to_semi_inplace(
            plan._distinct.value()[].child[],
            _distinct_absorbs_child_multiplicity(plan),
        )

    elif plan.tag == PLAN_TOPN:
        convert_inner_to_semi_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


def _name_in(imm names: List[String], imm want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


def _distinct_absorbs_child_multiplicity(imm node: LogicalPlan) -> Bool:
    """True when `node` is a `PLAN_DISTINCT` that makes the ROW MULTIPLICITY of
    its `PLAN_PROJECT` child entirely unobservable — Rule 11's `dup_insensitive`
    licence.

    Every clause is load-bearing. A wrong answer here is a wrong query
    answer.

      * `node` must BE a Distinct and its child must BE the projection.
        ⛔ ADJACENCY IS THE ARGUMENT, not a convenience. Any operator in
        between consumes the projection's rows itself: an AGGREGATE reads
        multiplicity (that is how the fan-out example's `SUM` comes back at one
        third), a JOIN multiplies by it, a LIMIT counts it.
      * The dedup key must cover EVERY output column of that projection —
        either `columns == None` (plain `SELECT DISTINCT`, dedup over the whole
        row) or an explicit list naming all of them. A `DISTINCT ON` a SUBSET
        keeps one arbitrary row per key, so WHICH duplicates existed is still
        observable through the columns it does not dedup.
        ⚠ NOTE THE DIRECTION — IT IS THE OPPOSITE OF THE ONE IN
        `_right_side_is_key_unique_on`'s Distinct arm. There the question is
        "do the JOIN KEYS cover the dedup columns" (is the dedup at least as
        fine as the keys). Here it is "do the DEDUP COLUMNS cover the output"
        (is the dedup over the whole row). Reading either for the other admits
        a subset DISTINCT and is unsound.
      * A typed-UDF projection is REFUSED. This rewrite changes how many rows
        reach the projection, so a projection that is not a pure function of
        its input row is not invariant under it. Every SQL-reachable scalar
        expression is pure — `random()` and `txid_current()` are
        deliberately not bound by the SQL frontend — so `udf` is the only
        impurity channel, and it is CLOSED rather than reasoned about.

    Declines by default, like the prover below it.
    """
    if node.tag != PLAN_DISTINCT:
        return False
    if node._distinct.value()[].child[].tag != PLAN_PROJECT:
        return False
    if node._distinct.value()[].child[]._project.value()[].udf:
        return False
    var n_out = node._distinct.value()[].child[].output_schema.num_columns()
    if n_out == 0:
        return False
    if not node._distinct.value()[].columns:
        # `SELECT DISTINCT` — dedup over the projection's whole output row.
        return True
    ref dcols = node._distinct.value()[].columns.value()
    if len(dcols) == 0:
        return False
    for i in range(n_out):
        if not _name_in(
            dcols,
            node._distinct.value()[].child[].output_schema.field_name(i),
        ):
            return False
    return True


def _right_side_is_key_unique_on(
    imm side: LogicalPlan, imm keys: List[String]
) -> Bool:
    """True only when `side` PROVABLY emits at most one row per distinct value
    of `keys` — i.e. `keys` is a superkey of `side`'s output.

    This is Rule 11's key-uniqueness precondition (see the call site). It is
    deliberately a STRUCTURAL prover and it DECLINES BY DEFAULT: there is no
    key catalog in this IR, so "the user says this column is a primary key" is
    not knowable here, and a prover that guessed would reintroduce the exact
    silent wrong answer it exists to stop.

    What it can prove, and why each is sound:

      * AGGREGATE — one output row per distinct group-key tuple
        (`LogicalPlan.aggregate` lays the output out as
        `[group keys...] + [aggs...]`, so the first `len(group_by)` output
        names ARE the group keys). If `keys` covers every group key, distinct
        group tuples imply distinct `keys` tuples. An UNGROUPED aggregate
        emits exactly one row, so any key set is a superkey.
      * DISTINCT — dedups on its declared `columns`, or on the full output row
        when it is `DISTINCT *`. Covered by `keys` ⇒ unique on `keys`.
      * FILTER / SORT / LIMIT / TOPN — each is a subsequence of its child's
        rows in some order. Uniqueness is inherited, and none of them RENAMES
        a column, so the same `keys` resolve to the same values.
      * PROJECT — transparent ONLY when every expr is a bare col-ref emitted
        under its own name. A rename or a computed column makes `keys` denote
        something the child never had; an arity-narrowing projection is fine
        (it drops columns, never rows).
      * SEMI / ANTI JOIN — the output is a SUBSET of the LEFT input's rows,
        each emitted at most once, so multiplicity is the left side's.

    Everything else — a SCAN, an INNER/LEFT/RIGHT/FULL join, a window, a
    set operation — returns False.
    """
    if len(keys) == 0:
        # A keyless join is a CROSS; a SEMI over one is not the same relation.
        return False

    var t = side.tag

    if t == PLAN_AGGREGATE:
        var n_group = len(side._aggregate.value()[].group_by)
        if n_group == 0:
            # Ungrouped aggregate: exactly one output row.
            return True
        if n_group > side.output_schema.num_columns():
            return False
        for i in range(n_group):
            if not _name_in(keys, side.output_schema.field_name(i)):
                return False
        return True

    if t == PLAN_DISTINCT:
        ref dd = side._distinct.value()[]
        if dd.columns:
            ref dcols = dd.columns.value()
            if len(dcols) == 0:
                return False
            for i in range(len(dcols)):
                if not _name_in(keys, dcols[i]):
                    return False
            return True
        # DISTINCT * — dedup over the whole output row.
        var n_out = side.output_schema.num_columns()
        if n_out == 0:
            return False
        for i in range(n_out):
            if not _name_in(keys, side.output_schema.field_name(i)):
                return False
        return True

    if t == PLAN_FILTER:
        return _right_side_is_key_unique_on(
            side._filter.value()[].child[], keys
        )
    if t == PLAN_SORT:
        return _right_side_is_key_unique_on(side._sort.value()[].child[], keys)
    if t == PLAN_LIMIT:
        return _right_side_is_key_unique_on(side._limit.value()[].child[], keys)
    if t == PLAN_TOPN:
        return _right_side_is_key_unique_on(side._topn.value()[].child[], keys)

    if t == PLAN_PROJECT:
        ref pd = side._project.value()[]
        if pd.udf:
            return False
        var n = len(pd.exprs)
        if n == 0 or n != side.output_schema.num_columns():
            return False
        for i in range(n):
            ref e = pd.exprs[i]
            if not e.is_col_ref():
                return False
            if e.col_ref_name() != side.output_schema.field_name(i):
                return False
        return _right_side_is_key_unique_on(pd.child[], keys)

    if t == PLAN_JOIN:
        var jt = side._join.value()[].join_type
        if jt == JOIN_SEMI or jt == JOIN_ANTI:
            return _right_side_is_key_unique_on(
                side._join.value()[].left[], keys
            )
        return False

    return False


# =============================================================================
# Rule 17: Join Build-Side Selection
# =============================================================================


def _side_has_wide_string_build_payload(
    plan: LogicalPlan, keys: List[String]
) -> Bool:
    """True if `plan` (as a single-key JOIN build side) carries a wide
    STRING build payload.

    `select_join_build_side` uses this on single-key (`n_keys == 1`)
    INNER joins to keep such a side off the build (right) side, overriding
    its cost heuristic, so the STRING-carrying wide side stays on the
    PROBE (left) side.

    This predicate counts the plan's output-schema columns that are NOT a
    join key (a "build payload"), and reports True when:
      - there are MORE THAN 3 such payload columns, AND
      - at least one payload column is STRING.

    Key columns are matched by name against `keys` (the side's `*_on` list).
    The override fires only on this exact condition, so every other join
    keeps the cost decision.
    """
    ref schema = plan.output_schema
    var n = schema.num_columns()
    var n_payload = 0
    var has_string_payload = False
    for i in range(n):
        var col_name = schema.field_name(i)
        var is_key = False
        for k in range(len(keys)):
            if keys[k] == col_name:
                is_key = True
                break
        if is_key:
            continue
        n_payload += 1
        if schema.field_arrow_type(i).type_id == ArrowType.STRING.type_id:
            has_string_payload = True
    return n_payload > 3 and has_string_payload


def select_join_build_side(var plan: LogicalPlan) raises -> LogicalPlan:
    """Swap join sides so the smaller table is on the build (right) side.

    =========================================================================
    PERF-CRITICAL: Join build/probe side selection (INNER, SEMI, RIGHT)
    =========================================================================
    Regression if removed: Any INNER join where the larger table is on
                           the right regresses by a factor proportional
                           to the size ratio (bigger HT, more probes).
    Non-obvious part:      The SEMI swap is not by base cardinality: it
                           puts a side whose HAVING filter (Filter over
                           Aggregate) is estimated below 10% selectivity
                           on the build side. ANTI is never swapped
                           (ANTI(A,B) != ANTI(B,A)).
                           A RIGHT join becomes a LEFT join when its
                           probe side is the cheaper one.
    DuckDB equivalent:     DuckDB's build_probe_side_optimizer does the
                           INNER swap by cardinality*row_width; the
                           HAVING-driven SEMI swap is our own
                           extension.
    Do NOT delete without: 1) re-measuring the inner and semi joins
                           2) any TPC-H query with Filter(Agg(...)) on
                              one side of a SEMI join
    =========================================================================

    For semi-joins, also considers post-aggregate cardinality: if one side
    has a HAVING clause (Filter above Aggregate) with estimated low
    selectivity (< 10%), that side should be the build side because the
    aggressive filter produces a small hash table.
    """
    select_join_build_side_inplace(plan)
    return plan^


def select_join_build_side_inplace(mut plan: LogicalPlan) raises:
    """In-place build-side selection.

    Recurses children IN PLACE. The swap path on a JOIN_INNER (or
    aggressive-HAVING JOIN_SEMI) still rebuilds because swapping the
    `left` and `right` OwnedPointer fields of JoinData would require
    partial-moving Movable fields out of the variant Data struct, which
    the pointer rules forbid. The non-swap walk skips the
    rebuild entirely.
    """
    if plan.tag == PLAN_JOIN:
        # Recurse into both children IN PLACE first.
        select_join_build_side_inplace(plan._join.value()[].left[])
        select_join_build_side_inplace(plan._join.value()[].right[])
        var jt = plan._join.value()[].join_type

        # Decide whether to swap. Both branches need the schemas of the
        # post-recursion children.
        var should_swap = False

        # Never swap a residual-carrying join — the residual's
        # col-refs are named against the joined-row layout (left cols, then
        # right cols with `_right` collision rename), so flipping sides
        # would require rewriting every residual col-ref. Leave it as is.
        # MOJO 1.0.0: `left_p` / `right_p` are projections of ONE walk of the
        # JoinData. Every later `plan._join` walk in this block would form a
        # second origin and invalidate them, so the block goes through `jd`.
        ref jd = plan._join.value()[]
        if jd.has_residual():
            return

        if jt == JOIN_INNER:
            ref left_p = jd.left[]
            ref right_p = jd.right[]
            var left_card = estimate_cardinality(left_p)
            var right_card = estimate_cardinality(right_p)
            var left_width = estimate_row_width(left_p.output_schema)
            var right_width = estimate_row_width(right_p.output_schema)
            var left_cost = left_card * left_width
            var right_cost = right_card * right_width
            if left_cost < right_cost:
                should_swap = True

            # =================================================================
            # STRING-aware side selection: override the cost heuristic when
            # the chosen build
            # side carries a wide STRING build payload.
            #
            # The build side is the RIGHT child (the plan's
            # build=right invariant). If we DON'T swap, build == right; if we
            # DO swap, build == left (the old left becomes the new right).
            #
            # A wide STRING build payload is more than 3 non-key columns,
            # at least one of them STRING
            # (`_side_has_wide_string_build_payload`).
            # So when exactly one side has one, force the OTHER side onto
            # build (keep the STRING-carrying wide side on PROBE), overriding
            # the smaller-table cost heuristic. When BOTH sides have one,
            # swapping cannot help
            # — leave the cost decision unchanged.
            #
            # Single-key-only: the override is gated on `len(left_on) == 1`;
            # a multi-key join keeps the cost decision.
            # =================================================================
            if len(jd.left_on) == 1:
                var right_wide_str = _side_has_wide_string_build_payload(
                    right_p, jd.right_on
                )
                var left_wide_str = _side_has_wide_string_build_payload(
                    left_p, jd.left_on
                )
                if right_wide_str and not left_wide_str:
                    # Only the right (build) side is wide-STRING -> swap so
                    # the STRING-carrying right side becomes the PROBE side.
                    should_swap = True
                elif left_wide_str and not right_wide_str:
                    # Swapping would put the STRING-carrying left side on
                    # build. Keep left on PROBE (do not swap), overriding
                    # any cost-driven swap.
                    should_swap = False

        if jt == JOIN_SEMI:
            ref left_p = jd.left[]
            ref right_p = jd.right[]
            var left_having = _estimate_having_selectivity(left_p)
            var right_having = _estimate_having_selectivity(right_p)
            if left_having < 0.10 and right_having >= 0.10:
                should_swap = True

        # =====================================================================
        # LEFT/RIGHT
        # canonical-form swap.
        #
        # Design principle:
        #     A LEFT JOIN B  ≡  B RIGHT JOIN A
        # Outer joins are canonical-form-equivalent under operand swap + type
        # flip. Pick whichever form puts the SMALLER side on build, regardless
        # of which user-written form came in.
        #
        # Reference: DuckDB src/optimizer/build_probe_side_optimizer.cpp
        # (FlipChildren, TryFlipJoinChildren). DuckDB swaps
        # operand pointers + applies `InverseJoinType` (LEFT↔RIGHT, SEMI↔
        # RIGHT_SEMI) + swaps `left_projection_map` / `right_projection_map`.
        # Our Mojo IR has no projection-map equivalent, so we emit an explicit
        # `Project` wrapper above the swapped join to restore the user-visible
        # output column order.
        #
        # Cost rule: same `left_cost < right_cost` heuristic as INNER — fire
        # when the PROBE-side is the smaller side (anti-pattern; we want
        # build to be smaller). FULL OUTER has no inverse (DuckDB's
        # `HasInverseJoinType` returns False) — not handled here. ANTI is
        # asymmetric (ANTI(A,B) != ANTI(B,A)) — out of scope.
        #
        # Only the RIGHT→LEFT direction fires: the LEFT→RIGHT direction is
        # gated off below, so this rule never produces a JOIN_RIGHT plan.
        # =====================================================================
        var outer_swap_needed = False
        var flipped_jt: UInt8 = jt
        if jt == JOIN_LEFT or jt == JOIN_RIGHT:
            ref left_p = jd.left[]
            ref right_p = jd.right[]
            var left_card = estimate_cardinality(left_p)
            var right_card = estimate_cardinality(right_p)
            var left_width = estimate_row_width(left_p.output_schema)
            var right_width = estimate_row_width(right_p.output_schema)
            var left_cost = left_card * left_width
            var right_cost = right_card * right_width
            # `left` is the probe side (per the plan's
            # build=right invariant). Swap fires when probe is smaller than
            # build (the anti-pattern — we want build to be the small side).
            #
            # This rule emits only the join types {INNER, LEFT, SEMI, ANTI}
            # (it never turns a LEFT input into a JOIN_RIGHT plan). So the
            # LEFT→RIGHT direction is gated off here, and the
            # RIGHT→LEFT direction (which produces a LEFT join) is kept. The
            # cost benefit of the LEFT→RIGHT case is given up.
            if left_cost < right_cost:
                if jt == JOIN_RIGHT:
                    outer_swap_needed = True
                    flipped_jt = JOIN_LEFT

        if outer_swap_needed:
            _swap_outer_join_with_reprojection(plan, flipped_jt)
            return

        if should_swap:
            # ⛔ AN OPERAND EXCHANGE REASSIGNS NAMES. RESTORE FROM PROVENANCE.
            # An INNER join's output is `left cols ++ right cols` with `_right`
            # appended on a name collision, so exchanging the operands both
            # PERMUTES the output and MIGRATES the suffix — after the exchange
            # the name `val` denotes the OTHER relation's column. A by-name
            # projection therefore cannot undo it; only the positional
            # derivation in `_swap_outer_join_with_reprojection` can, which is
            # why the INNER arm uses the OUTER arm's helper.
            #
            # Example: for `SELECT l.skey, l.val, r.skey AS skey_right,
            # r.val AS val_right`, a by-name projection over the exchanged
            # join would emit the RIGHT relation's `val` in the column named
            # `val`, under a schema whose names are exactly the ones the query
            # asked for (test_inner_swap_with_colliding_names_restores_by_position).
            # A silent wrong ANSWER, not merely a wrong column order.
            #
            # ⚠ INNER ONLY. `should_swap` is also set for JOIN_SEMI above,
            # whose output is the PROBE side alone and not `left ++ right`, so
            # the helper's output model does not describe it; SEMI keeps the
            # bare rebuild.
            if jt == JOIN_INNER:
                _swap_outer_join_with_reprojection(plan, jt)
                return
            var new_left = _copy_plan(plan._join.value()[].left[])
            var new_right = _copy_plan(plan._join.value()[].right[])
            var lk = plan._join.value()[].left_on.copy()
            var rk = plan._join.value()[].right_on.copy()
            plan = LogicalPlan.join(new_right^, new_left^, rk^, lk^, jt)

    elif plan.tag == PLAN_FILTER:
        select_join_build_side_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        select_join_build_side_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        select_join_build_side_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_SORT:
        select_join_build_side_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        select_join_build_side_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        select_join_build_side_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        select_join_build_side_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


def _swap_outer_join_with_reprojection(mut plan: LogicalPlan, flipped_jt: UInt8) raises:
    """Operand swap that restores the user-visible output columns.

    In-place LEFT↔RIGHT canonical-form swap:
      JOIN_LEFT(A, B, on l_keys, r_keys)
        →  PROJECT(<restore-user-cols>, JOIN_RIGHT(B, A, on r_keys, l_keys))
      JOIN_RIGHT(A, B, on l_keys, r_keys)
        →  PROJECT(<restore-user-cols>, JOIN_LEFT(B, A, on r_keys, l_keys))

    Mojo IR has no `left_projection_map` / `right_projection_map`
    equivalent to DuckDB's projection-map swap. Instead we emit an
    explicit `Project` wrapper above the swapped join to restore the
    user-visible output column order + names. The Project's exprs are
    `Expr.alias(Expr.col_ref(<post-swap-name>), <original-name>)` per
    original output column.

    Assumes caller has already validated:
      - plan.tag == PLAN_JOIN
      - flipped_jt is JOIN_LEFT or JOIN_RIGHT (the inverse of plan's jt),
        or JOIN_INNER for the INNER operand exchange
      - has_residual() is False (residual flip out of scope; mirrors
        the existing INNER swap-blocker)
      - the caller decided to swap (the cost rule, or for INNER the
        STRING-payload override, which swaps against the cost)

    NOTE: this helper alone does not raise, and it can build a JOIN_RIGHT
    plan; `select_join_build_side` never asks for one (the LEFT→RIGHT
    direction is gated off).
    """
    # Snapshot orig output column metadata BEFORE any mutation.
    var orig_left_n = plan._join.value()[].left[].output_schema.num_columns()
    var orig_right_n = plan._join.value()[].right[].output_schema.num_columns()

    var orig_out_names = List[String]()
    var orig_out_n = plan.output_schema.num_columns()
    for i in range(orig_out_n):
        orig_out_names.append(plan.output_schema.field_name(i))

    # Snapshot un-renamed source names per side. The original join's
    # left child gives the un-renamed first `orig_left_n` output cols;
    # the right child gives the un-renamed next `orig_right_n` output
    # cols (which may have been suffixed `_right` by the original join's
    # collision-rename logic in `LogicalPlan.join`).
    var orig_left_names = List[String]()
    for i in range(orig_left_n):
        orig_left_names.append(
            plan._join.value()[].left[].output_schema.field_name(i)
        )
    var orig_right_names = List[String]()
    for i in range(orig_right_n):
        orig_right_names.append(
            plan._join.value()[].right[].output_schema.field_name(i)
        )

    # Deep-copy each child (same partial-move-ban-driven copy as the
    # bare SEMI swap in `select_join_build_side_inplace`).
    var new_left = _copy_plan(plan._join.value()[].right[])
    var new_right = _copy_plan(plan._join.value()[].left[])
    var new_lk = plan._join.value()[].right_on.copy()
    var new_rk = plan._join.value()[].left_on.copy()

    # Build the post-swap join. LogicalPlan.join() computes the new
    # output schema with collision-rename on the new right side (= orig
    # left). The new left side (= orig right) keeps its un-renamed names.
    var swapped_join = LogicalPlan.join(
        new_left^, new_right^, new_lk^, new_rk^, flipped_jt
    )

    # Build the re-projection ExprArray. For each ORIGINAL output column
    # at position i:
    #   - If i < orig_left_n: this column came from orig-left = new-right.
    #     In the swapped join's output schema, it sits at index
    #     `orig_right_n + i`. Its post-swap name = orig_left_names[i] +
    #     ("_right" if that name collides with any orig-right name, else
    #     no suffix).
    #   - Else: this column came from orig-right = new-left. In the
    #     swapped join's output, it sits at index `i - orig_left_n` with
    #     its un-renamed orig_right_names[i - orig_left_n] (no collision
    #     possible since it's the new left side).
    var reprojection_exprs = ExprArray()
    for i in range(orig_out_n):
        var orig_name = orig_out_names[i]
        var post_swap_name: String
        if i < orig_left_n:
            var src = orig_left_names[i]
            # Detect collision against new-left's names.
            var has_collision = False
            for j in range(orig_right_n):
                if orig_right_names[j] == src:
                    has_collision = True
                    break
            if has_collision:
                post_swap_name = src + "_right"
            else:
                post_swap_name = src
        else:
            post_swap_name = orig_right_names[i - orig_left_n]

        if post_swap_name == orig_name:
            # Identity passthrough — emit a bare col_ref. The Project's
            # `_infer_expr_field` derives the field from the source col,
            # preserving name + ArrowType + nullability.
            reprojection_exprs.append(Expr.col_ref(post_swap_name))
        else:
            # Renaming required (collision flip handling). Alias from
            # post-swap-name to original-name.
            reprojection_exprs.append(
                Expr.alias(Expr.col_ref(post_swap_name), orig_name)
            )

    # Replace plan with Project(reprojection, swapped_join).
    plan = LogicalPlan.project(reprojection_exprs^, swapped_join^)


# =============================================================================
# JOIN-REORDER OUTPUT-ORDER GUARD
# =============================================================================
#
# ⛔ JOIN REORDERING MOVES THE OUTPUT COLUMNS: the join reorder
#    (`optimizer_reorder.reorder_joins`) EXCHANGES JOIN OPERANDS (a PERMUTATION)
#    and does not put them back, and `extract_join_chain`'s PROJECT PIERCE drops
#    a column-narrowing projection it flattens through (a WIDENING — see
#    `narrow_reordered_join_to_declared_columns`). `select_join_build_side`
#    also exchanges operands, but re-projects to ITS INPUT's order.
#
# An INNER join's output schema is `left cols ++ right cols` (with `_right`
# appended on a name collision), so exchanging the operands PERMUTES the
# user-visible output — and on a collision the `_right` suffix MIGRATES to the
# other relation's key, reassigning the names `k` and `k_right` to opposite
# sides. A projection that merely RESTATES the join's declared order is an
# identity projection, which a rewrite may delete; and a `SELECT *` has
# no projection at all.
#
# ⇒ THE GUARD BELONGS AROUND THE REORDERING RULES, NOT INSIDE ANY ONE OF THEM:
#   capture with `join_reorder_output_names` before them and restore with
#   `restore_join_reorder_output_columns` after them. A rule that restores in
#   isolation faithfully preserves the order its already-reordered input
#   handed it, so a permutation made by an earlier rule passes through it
#   (`select_join_build_side`'s re-projection does exactly that).
#
# ⚠ SCOPE. The guard restores the plan ROOT's column order against the names
# captured before the rules, and nothing else.


def join_reorder_output_names(plan: LogicalPlan) raises -> List[String]:
    """The plan's output column names, in order — the value to capture BEFORE
    the join-reordering rules and hand back to
    `restore_join_reorder_output_columns` after them."""
    var out = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out.append(plan.output_schema.field_name(i))
    return out^


def restore_join_reorder_output_columns(
    var plan: LogicalPlan, var want: List[String]
) raises -> LogicalPlan:
    """Re-establish `want` as the plan's output column order, if a join
    reorder permuted it. Returns the plan UNTOUCHED in every other case.

    ⚠ ADDS A NODE ONLY WHEN THE ORDER ACTUALLY CHANGED. The common case (no
    swap, or two swaps that cancelled) compares equal and returns the plan as
    it stands — the
    only plans that gain a `Project` are the ones whose order moved.

    ⛔ RESTORES A PERMUTATION AND NOTHING ELSE. If the arity changed, or the
    name multiset changed, or any name is DUPLICATED (which would make a
    by-name `Project` ambiguous), this declines and returns the plan
    unchanged: a rule that legitimately altered the output is not this
    function's to overrule, and fabricating a projection over names that no
    longer mean what they did would convert an ordering defect into a wrong
    answer.

    ⚠ AN ARITY CHANGE IS NOT THIS FUNCTION'S TO REPAIR, AND ONE IS REACHABLE:
    `extract_join_chain`'s PROJECT PIERCE can WIDEN a join node's output. Its
    repair belongs at that node instead —
    `narrow_reordered_join_to_declared_columns` — because a parent's cached
    schema is not recomputed when the reorder replaces its child, so by the
    time the plan reaches here the widening is invisible from the root."""
    var n = plan.output_schema.num_columns()
    if n != len(want):
        return plan^
    var got = List[String]()
    for i in range(n):
        got.append(plan.output_schema.field_name(i))
    var same = True
    for i in range(n):
        if got[i] != want[i]:
            same = False
            break
    if same:
        return plan^
    # Permutation check, both ways, and distinctness — `want[i]` must name
    # EXACTLY ONE column of the current output.
    for i in range(n):
        var hits = 0
        for j in range(n):
            if got[j] == want[i]:
                hits += 1
        if hits != 1:
            return plan^
    var exprs = ExprArray()
    for i in range(n):
        exprs.append(Expr.col_ref(want[i]))
    return LogicalPlan.project(exprs^, plan^)


def narrow_reordered_join_to_declared_columns(
    var reordered: LogicalPlan, var declared: List[String]
) raises -> LogicalPlan:
    """Undo ONLY the WIDENING that `extract_join_chain`'s PROJECT PIERCE
    performs, at the join node that performed it.

    `_extract_join_chain_inner` (`optimizer_reorder`) flattens THROUGH
    a rename-free col-ref projection and then DROPS it, stating the assumption
    in place: "the greedy rebuild produces a SUPERSET schema (all leaf columns
    concatenated at every join level), which preserves all referenced names."
    True for a consumer above the Project; FALSE at the plan root, where the
    superset IS the answer, and false under `SELECT *`.

    ⚠ THE ROOT-LEVEL GUARD CANNOT SEE THIS ONE. `restore_join_reorder_output_
    columns` reads `plan.output_schema` at the ROOT, and a reorder's pass-through
    rebuild (its SORT/FILTER/PROJECT arms) reassigns a
    parent's `child` WITHOUT recomputing that parent's cached schema. So a
    `Sort` above a widened join still reports the old, narrow schema and the
    root-level comparison comes back equal while the join emits the wide row.
    That is why this repair is made HERE, on the node whose own declared
    schema is the ground truth.

    ⛔ STRICTLY WIDENING — `n <= len(declared)` returns the plan UNTOUCHED.
    The permutation question is deliberately NOT answered here: it belongs to
    `restore_join_reorder_output_columns` around the reordering rules, because
    a per-rule answer preserves whatever order that rule's input already had
    (see the JOIN-REORDER OUTPUT-ORDER GUARD header above).
    This arm cannot fire in the equal-arity case that argument is about.

    Example, a sorted query with no narrowing select:
    `Project([dk, d1v], d1 ⋈ d2)` joined
    to a fact and sorted, once the pierce drops that Project, emits SIX columns
    `[dk, d1v, dk2, d2v, fk, fval]` against a declared four — `d2`'s columns
    re-materialized into the result of a query that had projected them away.
    """
    var n = reordered.output_schema.num_columns()
    if n <= len(declared):
        return reordered^
    var got = List[String]()
    for i in range(n):
        got.append(reordered.output_schema.field_name(i))
    # Every declared name must resolve to EXACTLY ONE column of the wider
    # output. A missing or ambiguous name means the rebuild did something this
    # function has no license to reinterpret; decline rather than fabricate.
    for i in range(len(declared)):
        var hits = 0
        for j in range(n):
            if got[j] == declared[i]:
                hits += 1
        if hits != 1:
            return reordered^
    var exprs = ExprArray()
    for i in range(len(declared)):
        exprs.append(Expr.col_ref(declared[i]))
    return LogicalPlan.project(exprs^, reordered^)


def join_operands_share_column_name(plan: LogicalPlan) raises -> Bool:
    """True if the JOIN node's two operands share any output column name.

    Such a join's output schema depends on operand ORDER for more than order:
    `LogicalPlan.join` appends `_right` to the colliding RIGHT name, so an
    exchange makes the bare name denote the OTHER relation. A reorder that
    cannot restore from provenance must treat such a join as a BARRIER."""
    if plan.tag != PLAN_JOIN:
        return False
    ref jd = plan._join.value()[]
    var left_names = Set[String]()
    for i in range(jd.left[].output_schema.num_columns()):
        left_names.add(jd.left[].output_schema.field_name(i))
    for j in range(jd.right[].output_schema.num_columns()):
        if jd.right[].output_schema.field_name(j) in left_names:
            return True
    return False


def _estimate_having_selectivity(plan: LogicalPlan) -> Float64:
    """Estimate the selectivity of a HAVING clause (Filter above Aggregate).

    Returns a value in [0.0, 1.0]. Lower means more aggressive filtering.
    Returns 1.0 (no filtering) if the plan is not a HAVING pattern.

    A HAVING clause is a Filter whose child is an Aggregate. The heuristic:
      - Comparison operators (>, <, >=, <=, ==, !=): 0.05 (5% selectivity)
      - AND of comparisons: product of child selectivities
      - OR of comparisons: sum of child selectivities (capped at 1.0)
      - Anything else: 0.5 (no strong signal)

    These are rough heuristics — the point is to detect patterns like
    "HAVING count(*) > 100" which typically filter out 90%+ of groups.
    """
    if plan.tag != PLAN_FILTER:
        return 1.0

    # Check if child is an Aggregate (HAVING pattern).
    if plan._filter.value()[].child[].tag != PLAN_AGGREGATE:
        return 1.0

    # It is a HAVING pattern. Estimate selectivity from the predicate tag+op.
    return _estimate_predicate_selectivity_from_plan(plan)


def _estimate_predicate_selectivity_from_plan(plan: LogicalPlan) -> Float64:
    """Estimate selectivity of a HAVING clause from a Filter plan node.

    Inspects the predicate's tag and binary operator to estimate selectivity.
    Uses the plan reference directly to avoid Expr copy issues.

    Returns a value in [0.0, 1.0]:
      - Comparison operators (>, <, >=, <=, ==, !=): 0.05
      - AND: product of child selectivities (approximated at 0.05 * 0.05)
      - OR: 0.10 (two comparisons ORed)
      - Anything else: 0.5
    """
    if plan.tag != PLAN_FILTER:
        return 1.0

    var pred_tag = plan._filter.value()[].predicate.tag
    if pred_tag != EXPR_BINARY_OP:
        return 0.5

    var op = plan._filter.value()[].predicate._binary.value().op

    # Comparison operators: highly selective HAVING predicates
    if (op == BIN_EQ or op == BIN_NE or op == BIN_LT
            or op == BIN_LE or op == BIN_GT or op == BIN_GE):
        return 0.05

    # AND: product of child selectivities (heuristic: each child is a comparison)
    if op == BIN_AND:
        return 0.05 * 0.05

    # OR: sum of two comparison selectivities
    if op == BIN_OR:
        return 0.10

    return 0.5


# =============================================================================
# Rule 10: Aggregate Pushdown Below Join
# =============================================================================
#
# Defined in optimizer_partial_agg.mojo (`push_aggregate_below_join`) as a
# partial/merge rewrite: pushing the entire Aggregate below the join is
# unsound for non-trivial cases -- see that module's header for the
# rationale.


# =============================================================================
# Rule 13: Absorb Expression into Aggregate
# =============================================================================

def absorb_expression_into_aggregate(var plan: LogicalPlan) raises -> LogicalPlan:
    """Inline computed expressions from Project into downstream Aggregate.

    Wrapper around `absorb_expression_into_aggregate_inplace`.
    """
    absorb_expression_into_aggregate_inplace(plan)
    return plan^


def absorb_expression_into_aggregate_inplace(mut plan: LogicalPlan) raises:
    """In-place absorb-expr-into-aggregate.

    Recurses children IN PLACE. The Aggregate-above-Project absorption
    case still rebuilds because (a) the intermediate Project node is
    being deleted, and (b) the AggExpr / ExprArray fields of AggregateData
    are mutated wholesale. We deep-copy the grandchild on that path
    (partial-move ban). The non-absorption walk skips rebuilds entirely.
    """
    if plan.tag == PLAN_AGGREGATE:
        absorb_expression_into_aggregate_inplace(plan._aggregate.value()[].child[])

        if plan._aggregate.value()[].child[].tag == PLAN_PROJECT:
            # MOJO 1.0.0: one walk of the AggregateData, projected three ways.
            ref agd = plan._aggregate.value()[]
            ref proj_data = agd.child[]._project.value()[]
            ref proj_schema = agd.child[].output_schema

            # Build the column-name -> expr replacement map.
            var proj_names = List[String]()
            for i in range(proj_schema.num_columns()):
                proj_names.append(proj_schema.field_name(i))

            # ⛔ Leave Aggregate(Project) standing when a group key or an
            # aggregand reads a computed / replaced column under a node the
            # substitution cannot rewrite; that shape is left as
            # it was built.
            for i in range(len(agd.group_by)):
                if not expr_substitutes_safely(
                    agd.group_by[i], proj_names, proj_data.exprs
                ):
                    return
            for i in range(len(agd.agg_exprs)):
                ref ae = agd.agg_exprs[i]
                if ae.child and not expr_substitutes_safely(
                    ae.child.value(), proj_names, proj_data.exprs
                ):
                    return
                if ae.child1 and not expr_substitutes_safely(
                    ae.child1.value(), proj_names, proj_data.exprs
                ):
                    return
                if ae.child2 and not expr_substitutes_safely(
                    ae.child2.value(), proj_names, proj_data.exprs
                ):
                    return
                if ae.child3 and not expr_substitutes_safely(
                    ae.child3.value(), proj_names, proj_data.exprs
                ):
                    return

            # Substitute group-by expressions.
            var new_gb = ExprArray()
            ref gb_arr = agd.group_by
            for i in range(len(gb_arr)):
                var gb_expr = gb_arr[i].copy()
                var substituted = substitute_project_refs(
                    gb_expr^, proj_names, proj_data.exprs
                )
                new_gb.append(substituted^)

            # Substitute aggregate value expressions. ALL child slots
            # (child / child1 / child2 / child3) are substituted AND preserved,
            # so a bivariate/multivariate agg (corr(x, y) / covar / future UDAF)
            # does not lose its higher-arity inputs when a Project is absorbed
            # into the aggregate. (Same slot-preservation invariant as the
            # plan copy in `plan_helpers._copy_agg_expr_array`; a body that
            # kept ONLY slot 0 fails test_all_four_slots_are_substituted_and_preserved.)
            var new_aggs = AggExprArray()
            ref agg_arr = agd.agg_exprs
            for i in range(len(agg_arr)):
                var new_child_expr: Optional[Expr] = None
                if agg_arr[i].child:
                    var child_expr = agg_arr[i].child.value().copy()
                    var substituted = substitute_project_refs(
                        child_expr^, proj_names, proj_data.exprs
                    )
                    new_child_expr = substituted^
                var new_child1: Optional[Expr] = None
                if agg_arr[i].child1:
                    var c1 = agg_arr[i].child1.value().copy()
                    var sub1 = substitute_project_refs(
                        c1^, proj_names, proj_data.exprs
                    )
                    new_child1 = sub1^
                var new_child2: Optional[Expr] = None
                if agg_arr[i].child2:
                    var c2 = agg_arr[i].child2.value().copy()
                    var sub2 = substitute_project_refs(
                        c2^, proj_names, proj_data.exprs
                    )
                    new_child2 = sub2^
                var new_child3: Optional[Expr] = None
                if agg_arr[i].child3:
                    var c3 = agg_arr[i].child3.value().copy()
                    var sub3 = substitute_project_refs(
                        c3^, proj_names, proj_data.exprs
                    )
                    new_child3 = sub3^
                var alias_copy: Optional[String] = None
                if agg_arr[i].alias_name:
                    alias_copy = agg_arr[i].alias_name.value().copy()
                var new_agg = AggExpr(
                    agg_arr[i].func,
                    new_child_expr^,
                    new_child1^,
                    alias_copy^,
                )
                new_agg.child2 = new_child2^
                new_agg.child3 = new_child3^
                new_aggs.append(new_agg^)

            # Deep-copy the grandchild (Project's child); replace
            # AggregateData fields in place. Schema is unchanged because
            # the aggregate's output is determined by group_by + agg_exprs
            # output names which we preserved exactly.
            var grandchild_copy = _copy_plan(proj_data.child[])
            plan._aggregate.value()[].group_by = new_gb^
            plan._aggregate.value()[].agg_exprs = new_aggs^
            plan._aggregate.value()[].child = OwnedPointer(grandchild_copy^)

    elif plan.tag == PLAN_FILTER:
        absorb_expression_into_aggregate_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        absorb_expression_into_aggregate_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        absorb_expression_into_aggregate_inplace(plan._join.value()[].left[])
        absorb_expression_into_aggregate_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        absorb_expression_into_aggregate_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        absorb_expression_into_aggregate_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        absorb_expression_into_aggregate_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        absorb_expression_into_aggregate_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


# =============================================================================
# Rule 11b: SEMI/ANTI REDUCER PUSHDOWN — `OptimizerConfig.semi_pushdown`
# =============================================================================
#
# Tests: `tests/test_optimizer_join_semi_pushdown_arms.mojo`.
#
# ★ WHY THIS RULE EXISTS, IN ONE SENTENCE
#
#   Rule 11 above (`convert_inner_to_semi`) rewrites a `Project`-over-INNER-join
#   whose projected columns are all left-side into a `JOIN_SEMI`. Every non-INNER
#   join is then a REORDER BARRIER — the join reorder (`optimizer_reorder`) flattens a join
#   into a `JoinChain` ONLY for `jt == JOIN_INNER and not has_resid` — so the
#   relation the semi reduces against is frozen ABOVE whatever join it was
#   sitting on and can never be placed first.
#
#       > The rewrite that makes the filter cheap is what makes it immovable.
#
#   TPC-H q20 has this shape: a SEMI frozen above the INNER join it
#   should reduce first. DuckDB's optimizer places that reducer first.
#
# ★ THE REWRITE — two algebraic rules, applied to fixpoint down the semi's
#   LEFT spine:
#
#     R-A   SemiOrAnti( Filter(X, p), C )       ->  Filter( SemiOrAnti(X, C), p )
#     R-B   SemiOrAnti( Join(A, B, INNER), C )  ->  Join( SemiOrAnti(A, C), B, INNER )
#             [ and the mirror into B ]
#
#   VALIDITY: a SEMI (resp. ANTI) emits each LEFT row at most once, on a
#   predicate that depends only on that row, so it IS a per-row filter on its
#   left input. Commuting a per-row filter with a non-null-extending join it
#   does not reference is the same theorem `push_predicates_down` already runs.
#   Filter-then-join and join-then-filter differ only if the join can
#   null-extend the filtered side (LEFT/RIGHT/FULL — refused by G1) or if the
#   filter's truth depends on the join (refused by G2).
#
# ★ ORDER: it is useful AFTER `convert_inner_to_semi` — it
#   moves the SEMI that rule creates, not the rewrite itself — and BEFORE
#   a join reorder, which can then flatten the INNER joins the SEMI left.
#
# ⛔ IT CHANGES ZERO LINES OF THE REORDER. Admitting a SEMI edge into
#   `JoinChain` / `greedy_join_order` is the more general answer; this
#   rule instead adds a rewrite and leaves the set of
#   join SHAPES the reorder can emit unchanged. Do not "simplify" it into the
#   reorder.
#
# ⚠ THE RULE IS NARROW. Among the TPC-H queries, q20 is the shape it
#   targets; q16 is the only other query whose barrier points the right way.
#   Where the rule declines is decided by
#   the STRUCTURAL guards below, and a plan none of them admits is a REFUSAL,
#   not a pass.
#
# =============================================================================

@fieldwise_init
struct SemiPushdownGate(Copyable, Movable):
    """The rule's on/off arm, taken once from `OptimizerConfig.semi_pushdown`
    and passed by value through the whole recursion, so the rule cannot change
    arms partway through a plan.

    `enabled=False` is the OFF arm: it keeps the incoming plan byte-for-byte
    (test_semi_pushdown_off_returns_the_input_plan_unchanged).

    Fields:
        enabled: `OptimizerConfig.semi_pushdown`.
    """

    var enabled: Bool


def push_semi_reducers_down(
    var plan: LogicalPlan, config: OptimizerConfig
) raises -> LogicalPlan:
    """Rule 11b entry point — see the section header above.

    No-op (returns the plan untouched) when `config.semi_pushdown` is False,
    when there is no
    SEMI/ANTI join, or when any of the five guards G1-G5 declines. Every guard
    is a DECLINE, never a widening.
    """
    var gate = SemiPushdownGate(config.semi_pushdown)
    if not gate.enabled:
        return plan^
    return _push_semi_reducers_down_gated(plan^, gate)


def _push_semi_reducers_down_gated(
    var plan: LogicalPlan, gate: SemiPushdownGate
) raises -> LogicalPlan:
    """Bottom-up recursion; the rewrite is attempted at each JOIN node after its
    children have settled. Same traversal idiom as `push_join_residual_to_side`
    (in `optimizer_filter`)."""
    if plan.tag == PLAN_FILTER and plan._filter:
        var c = _take_filter_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._filter.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_PROJECT and plan._project:
        var c = _take_project_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._project.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_AGGREGATE and plan._aggregate:
        var c = _take_aggregate_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._aggregate.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_SORT and plan._sort:
        var c = _take_sort_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._sort.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_LIMIT and plan._limit:
        var c = _take_limit_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._limit.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_DISTINCT and plan._distinct:
        var c = _take_distinct_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._distinct.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_TOPN and plan._topn:
        var c = _take_topn_child(plan)
        var nc = _push_semi_reducers_down_gated(c^, gate)
        plan._topn.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_JOIN and plan._join:
        var l = _take_join_left(plan)
        var nl = _push_semi_reducers_down_gated(l^, gate)
        plan._join.value()[].left = OwnedPointer(nl^)
        var r = _take_join_right(plan)
        var nr = _push_semi_reducers_down_gated(r^, gate)
        plan._join.value()[].right = OwnedPointer(nr^)
        return _try_push_one_semi_reducer(plan^)
    return plan^


def _try_push_one_semi_reducer(var plan: LogicalPlan) raises -> LogicalPlan:
    """Attempt the rewrite at ONE node (children already recursed).

    Returns `plan` untouched on any decline. The whole push for one semi is
    computed SPECULATIVELY and adopted only if it survives G3 at the top and G5
    at the landing site — the intermediate states of an R-A/R-B fixpoint are
    not "the rewritten plan" and must not be guarded as if they were (during
    R-A on q20 the semi's left child is transiently a JOIN, which G5 refuses).
    """
    if plan.tag != PLAN_JOIN or not plan._join:
        return plan^
    var jt = plan._join.value()[].join_type
    # The rule is about SEMI/ANTI ONLY: those are the join types that are a
    # per-row filter on their left input. Every other type either emits right
    # columns (so it is not a filter) or null-extends (so it is not commutable).
    if jt != JOIN_SEMI and jt != JOIN_ANTI:
        return plan^
    # A zero-equi-key semi is a pure-NLJ shape whose "keys" cannot be resolved
    # against a child schema at all, so G2 has nothing to decide on. Decline.
    if len(plan._join.value()[].left_on) == 0:
        return plan^
    # Cheap pre-check so the ordinary case pays no plan copy: is there anything
    # under the semi to descend THROUGH?
    var admits = plan._join.value()[].left[].tag == PLAN_FILTER
    if plan._join.value()[].left[].tag == PLAN_JOIN:
        if plan._join.value()[].left[]._join:
            admits = (
                plan._join.value()[].left[]._join.value()[].join_type
                == JOIN_INNER
            )
    if not admits:
        return plan^

    var orig_schema = _copy_schema(plan.output_schema)
    var residual_copy: Optional[OwnedPointer[Expr]] = None
    if plan._join.value()[].residual:
        residual_copy = OwnedPointer(
            plan._join.value()[].residual.value()[].copy()
        )
    var rebuilt = _push_semi_into(
        _take_join_left(plan),
        _take_join_right(plan),
        plan._join.value()[].left_on.copy(),
        plan._join.value()[].right_on.copy(),
        jt,
        plan._join.value()[].algo_hint,
        residual_copy^,
        0,
    )
    if not rebuilt:
        return plan^
    var out = rebuilt.take()
    # --- G3 (top) ---------------------------------------------------------
    # The rewritten subtree's output schema must be FIELD-FOR-FIELD equal to
    # the one it replaces. It is structurally so (a SEMI's schema is its left
    # child's, so `INNER(SEMI(A,C), B)` and `SEMI(INNER(A,B), C)` both build
    # `A ++ B`, collision-renames included) — this asserts it rather than
    # trusting it, because a schema ORDINAL change reaching a downstream
    # `Distinct`/`Project`/`Sort` is silently wrong output, not a crash.
    if not _schema_fields_identical(orig_schema, out.output_schema):
        return plan^
    return out^


def _push_semi_into(
    var child: LogicalPlan,
    var right: LogicalPlan,
    var left_on: List[String],
    var right_on: List[String],
    jt: UInt8,
    algo: UInt8,
    var residual: Optional[OwnedPointer[Expr]],
    depth: Int,
) raises -> Optional[LogicalPlan]:
    """Push the semi (`right`/`right_on`/`jt`/`residual`) as deep into `child`'s
    left spine as the guards allow, and return the rebuilt subtree.

    `None` is the DECLINE, and it propagates all the way up: a partial push that
    cannot reach a landing site G5 admits is not adopted.

    `depth` is the number of levels already descended. At `depth == 0` the base
    case would rebuild the node it was handed, so it returns `None` instead —
    "no move" and "declined" are the same outcome for the caller and neither may
    pay for a rebuild.
    """
    # ---------------------------------------------------------------- R-A ---
    # SemiOrAnti( Filter(X, p), C ) -> Filter( SemiOrAnti(X, C), p )
    #
    # A Filter preserves its child's schema, so the semi's keys and its
    # left-resolving residual columns resolve identically above and below it;
    # there is no side to straddle and no ordinal to move. The one refusal is
    # a typed-UDF filter: `LogicalPlan.filter` cannot carry the `UdfData`, so
    # rebuilding one would silently DROP the UDF.
    if child.tag == PLAN_FILTER and child._filter:
        if child._filter.value()[].udf:
            return None
        var pred = child._filter.value()[].predicate.copy()
        var under = _take_filter_child(child)
        var inner = _push_semi_into(
            under^, right^, left_on^, right_on^, jt, algo, residual^, depth + 1
        )
        if not inner:
            return None
        return Optional[LogicalPlan](LogicalPlan.filter(pred^, inner.take()))

    # ---------------------------------------------------------------- R-B ---
    # SemiOrAnti( Join(A, B, INNER), C ) -> Join( SemiOrAnti(A, C), B, INNER )
    if child.tag == PLAN_JOIN and child._join:
        # --- G1 --------------------------------------------------------
        # The carrier must be JOIN_INNER. LEFT/RIGHT/FULL NULL-EXTEND: a row
        # that survives the reducer and a row that is null-extended are not
        # interchangeable, so pushing a reducer into the null-producing side
        # changes the answer. CROSS/ASOF/SEMI/ANTI carriers are refused for
        # want of a proof, not for want of a use case.
        # ⛔ Do NOT relax G1 "to reach q13": a right-only ON-clause conjunct
        # of a LEFT join, as in TPC-H q13, is `push_join_residual_to_side`'s
        # rewrite, not this rule's.
        # A residual ON THE CARRIER is allowed: the push leaves both children's
        # schemas unchanged (a SEMI's schema is its left child's), so the
        # carrier residual's name resolution is untouched, and filtering fewer
        # rows through it cannot change which of the surviving rows match.
        if child._join.value()[].join_type != JOIN_INNER:
            return None
        var side = _semi_target_side(child, left_on, right, residual)
        if side < 0:
            return None
        # --- G4 : THE COST GATE ----------------------------------------
        # Move the reducer past the sibling only if the reducer is SMALLER than
        # the sibling it jumps over. Without this the rule is a query-wide
        # gamble: on TPC-H q21 the semi's right side is a 6M-row `lineitem` and
        # the sibling is a 25-row `nation`, and moving that reducer first is
        # strictly worse. q21 is this rule's DECLINE case.
        # ⚠ Every decorrelated semi's right side prices
        # at DEFAULT_ROW_COUNT = 1,000,000, so this gate declines the whole
        # TPC-H q4/q16/q21/q22 family for a reason that is 100x wrong but
        # points the SAFE way. A better estimate for that side (or a SEMI
        # selectivity) silently WIDENS this rule's firing set.
        var sibling_card: Int
        if side == 0:
            sibling_card = estimate_cardinality(child._join.value()[].right[])
        else:
            sibling_card = estimate_cardinality(child._join.value()[].left[])
        if estimate_cardinality(right) >= sibling_card:
            return None

        var carrier_schema = _copy_schema(child.output_schema)
        var c_jt = child._join.value()[].join_type
        var c_algo = child._join.value()[].algo_hint
        var c_left_on = child._join.value()[].left_on.copy()
        var c_right_on = child._join.value()[].right_on.copy()
        var c_residual: Optional[OwnedPointer[Expr]] = None
        if child._join.value()[].residual:
            c_residual = OwnedPointer(
                child._join.value()[].residual.value()[].copy()
            )
        var target: LogicalPlan
        var sibling: LogicalPlan
        if side == 0:
            target = _take_join_left(child)
            sibling = _take_join_right(child)
        else:
            target = _take_join_right(child)
            sibling = _take_join_left(child)
        var pushed = _push_semi_into(
            target^, right^, left_on^, right_on^, jt, algo, residual^, depth + 1
        )
        if not pushed:
            return None
        var new_left: LogicalPlan
        var new_right: LogicalPlan
        if side == 0:
            new_left = pushed.take()
            new_right = sibling^
        else:
            new_left = sibling^
            new_right = pushed.take()
        var rebuilt = LogicalPlan.join(
            new_left^, new_right^, c_left_on^, c_right_on^, c_jt, c_algo,
            c_residual^,
        )
        # --- G3 (per level) --------------------------------------------
        # The carrier's own output schema must survive the substitution. It
        # does structurally, for the same reason as the top-level check; a
        # collision-`_right` rename computed against a DIFFERENT left schema
        # would be the way it could not, and this is what catches that.
        if not _schema_fields_identical(carrier_schema, rebuilt.output_schema):
            return None
        return Optional[LogicalPlan](rebuilt^)

    # --------------------------------------------------------------- BASE ---
    if depth == 0:
        # Nothing was descended through: the rebuild would reproduce the input.
        return None
    # --- G5 : THE LEAF-SHAPE GUARD -------------------------------------
    # Both of the rewritten semi's children must be a SIDE that resolves
    # without recursion: `PROJECT? -> FILTER* -> SCAN(parquet)`. The shape
    # has TWO forms:
    #   * a PURE-COL-REF `PROJECT` over `FILTER? -> SCAN(parquet)` that
    #     keeps the join key, which a leaf can decode directly;
    #   * a FILTER node the scan cannot absorb, over the scan
    #     (`FILTER* -> SCAN(parquet)`). q20 is THIS form
    #     and not the first: `p_name LIKE 'forest%'` is not parquet-pushable (PushdownGate's
    #     vocabulary is {EQ,NE,LT,LE,GT,GE,AND}, `komira_scan_source.pushdown_gate`,
    #     with no LIKE bit), so the LIKE stays a FILTER NODE above the scan.
    #
    # ⚠ THIS IS DELIBERATELY NARROW: it refuses BREAKER sides, which a join
    # can also resolve by recursion. A
    # guard written as "whatever a join happens to resolve" is satisfied by
    # everything, i.e. it is VACUOUS, and a vacuous guard
    # can never decline. A narrow POSITIVE guard is the only kind that can
    # decline, and declining is this rule's whole safety argument.
    if not _side_is_parquet_leaf_shape(child):
        return None
    if not _side_is_parquet_leaf_shape(right):
        return None
    return Optional[LogicalPlan](
        LogicalPlan.join(child^, right^, left_on^, right_on^, jt, algo, residual^)
    )


def _schema_has_column(schema: Schema, name: String) -> Bool:
    """True iff `schema` has a field named `name`."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return True
    return False


def _schema_fields_identical(a: Schema, b: Schema) -> Bool:
    """G3's comparison: field-for-field equality by ORDINAL — same count, same
    names in the same order, same Arrow type, same nullability.

    Ordinal, not set, equality: a consumer of the join output that reads by
    position is silently wrong if the ORDER moves, and right if it does not.
    A set comparison would pass exactly the case that breaks."""
    if a.num_columns() != b.num_columns():
        return False
    for i in range(a.num_columns()):
        if a.field_name(i) != b.field_name(i):
            return False
        if a.field_arrow_type(i) != b.field_arrow_type(i):
            return False
        if a.field_nullable(i) != b.field_nullable(i):
            return False
    return True


def _semi_target_side(
    imm carrier: LogicalPlan,
    left_on: List[String],
    imm semi_right: LogicalPlan,
    imm residual: Optional[OwnedPointer[Expr]],
) -> Int:
    """G2 — which child of the INNER carrier owns EVERYTHING the semi reads on
    its left. Returns 0 (left), 1 (right), or -1 = DECLINE.

    What it prevents: a semi whose predicate STRADDLES A and B being moved into
    one of them, which is silently wrong output rather than a crash. Every
    ambiguity is a decline, because a name that resolves in two places gives the
    rewritten semi a different predicate than the one it had.

    Three refusals worth naming:
      * a key present in BOTH children (ambiguous), or in NEITHER — the second
        is the `_right` COLLISION RENAME: `LogicalPlan.join` renames a
        right-side field that collides with a left-side name to `<name>_right`,
        so the semi's `left_on` can legitimately name a column that exists in
        no child schema under that spelling. Moving that semi would rebind the
        key to a different column;
      * keys that disagree on which side they live in (a straddling semi);
      * a residual column that resolves in the SIBLING (it would be lost), or in
        both the target and the semi's right side (ambiguous), or in neither.
    """
    if carrier.tag != PLAN_JOIN or not carrier._join:
        return -1
    ref lschema = carrier._join.value()[].left[].output_schema
    ref rschema = carrier._join.value()[].right[].output_schema
    if len(left_on) == 0:
        return -1

    var side = -1
    for k in range(len(left_on)):
        var in_l = _schema_has_column(lschema, left_on[k])
        var in_r = _schema_has_column(rschema, left_on[k])
        if in_l and in_r:
            return -1
        if (not in_l) and (not in_r):
            return -1
        var this_side = 0 if in_l else 1
        if side < 0:
            side = this_side
        elif side != this_side:
            return -1
    if side < 0:
        return -1  # cov: unreachable left_on is non-empty and every pass of the loop above returns -1 or sets side to 0 or 1

    if residual:
        var cols = Set[String]()
        _collect_expr_columns(residual.value()[], cols)
        ref cschema = semi_right.output_schema
        for name in cols:
            var in_l2 = _schema_has_column(lschema, name)
            var in_r2 = _schema_has_column(rschema, name)
            var in_target = in_l2
            var in_sibling = in_r2
            if side == 1:
                in_target = in_r2
                in_sibling = in_l2
            var in_c = _schema_has_column(cschema, name)
            if in_sibling:
                return -1
            if in_target and in_c:
                return -1
            if (not in_target) and (not in_c):
                return -1
    return side


def _pure_colref_project(imm p: LogicalPlan) -> Bool:
    """True iff `p` is a PROJECT whose every output expr is a bare col-ref or an
    alias wrapping one, and which carries no typed UDF.

    This is the leaf
    precondition. A computed project (binary op, literal, cast, CASE,
    window, UDF) declines: a leaf decodes columns, it cannot evaluate
    expressions."""
    if p.tag != PLAN_PROJECT or not p._project:
        return False
    ref pd = p._project.value()[]
    if pd.udf:
        return False
    var n = len(pd.exprs)
    if n == 0:
        return False
    for i in range(n):
        ref e = pd.exprs[i]
        var is_pure = e.is_col_ref()
        if (not is_pure) and e.is_alias():
            is_pure = e.alias_child_ref().is_col_ref()
        if not is_pure:
            return False
    return True


def _filter_chain_bottoms_in_parquet_scan(imm p: LogicalPlan) -> Bool:
    """True iff `p` is `FILTER* -> SCAN(SOURCE_PARQUET)`.

    A typed-UDF filter declines (the leaf cannot run the UDF), same reason the
    R-A arm refuses to rebuild one."""
    if p.tag == PLAN_FILTER:
        if not p._filter:
            return False
        if p._filter.value()[].udf:
            return False
        return _filter_chain_bottoms_in_parquet_scan(p._filter.value()[].child[])
    if p.tag == PLAN_SCAN:
        if not p._scan:
            return False
        return p._scan.value()[].source_type == SOURCE_PARQUET
    return False


def _side_is_parquet_leaf_shape(imm side: LogicalPlan) -> Bool:
    """G5's shape predicate: `PROJECT? -> FILTER* -> SCAN(SOURCE_PARQUET)`.

    See the G5 comment in `_push_semi_into` for why this guard is narrow
    and why that is the point."""
    if side.tag == PLAN_PROJECT:
        if not _pure_colref_project(side):
            return False
        return _filter_chain_bottoms_in_parquet_scan(
            side._project.value()[].child[]
        )
    return _filter_chain_bottoms_in_parquet_scan(side)
