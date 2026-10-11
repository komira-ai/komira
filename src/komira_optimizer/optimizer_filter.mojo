# =============================================================================
# Optimizer filter rules — filter fusion, decomposition, predicate pushdown,
# cross-join elimination
# =============================================================================
#
# Rule 1: Filter fusion — merge consecutive Filters into one (A AND B)
# Rule 8: Filter decomposition — split ANDs into separate Filters for pushdown
# Rule 2: Predicate pushdown — push filters toward scan nodes
# Rule 19: Eliminate cross join — cross join + equi-filter -> inner join
# =============================================================================

from komira_arrow.schema import Schema
from komira_arrow.arrow_types import ArrowType
# ⭐ THE ONE TABLE. This fold gate reads the same join-key table every key gate
# is designed to read (the executor's route gates are not in this tree). A key
# this gate misses is not a refusal: the plan keeps `Filter(equi, CROSS)`, an
# N*M Cartesian product. See `join_key_envelope.mojo`'s header.
from komira_kernels.join_key_envelope import JoinKeyType, join_key_admitted
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_IN_LIST,
    EXPR_STRING_OP,
    EXPR_REGEXP,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    BIN_AND,
    BIN_EQ,
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
    JOIN_CROSS,
    JOIN_INNER,
    JOIN_LEFT,
    SOURCE_KIND_ROW,
)
from komira_plan_stats.table_stats import TableStats
from .optimizer_project_merge_guard import predicate_below_project
# The UdfData import was removed — Filter/Project
# rewriter rules no longer thread UDF snapshots.
from std.memory import OwnedPointer
from komira_plan_ir.plan_helpers import (
    _copy_schema,
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
)


# =============================================================================
# Rule 1: Filter Fusion
# =============================================================================

def fuse_filters(var plan: LogicalPlan) raises -> LogicalPlan:
    """Merge consecutive Filter nodes into a single Filter with AND predicate.

    Wrapper around `fuse_filters_inplace` for legacy callers.
    """
    fuse_filters_inplace(plan)
    return plan^


def fuse_filters_inplace(mut plan: LogicalPlan) raises:
    """In-place filter fusion.

    Recurses children IN PLACE. For Filter-of-Filter (the rare case after
    `decompose_filters` + `push_predicates_down` runs), falls back to the
    legacy rebuild path because Mojo 0.26.3 forbids partial-move-out of a
    `FilterData.child` OwnedPointer field. The rebuild only fires on the
    fuse case; the recursive walk avoids it. Common plans pay only the
    walk cost.
    """
    if plan.tag == PLAN_FILTER:
        # Recurse into the child first.
        fuse_filters_inplace(plan._filter.value()[].child[])

        # If the (now-rewritten) child is also a Filter, fuse them. This
        # path takes a deep copy of the grandchild (legacy cost), but
        # only fires when fusion is actually possible.
        #
        # The UDF-aware fusion guard was removed.
        # FilterData no longer carries a `udf` slot — Filter-of-Filter fusion
        # is now always safe (no UDF semantics to drop).
        if plan._filter.value()[].child[].tag == PLAN_FILTER:
            var inner_pred = plan._filter.value()[].child[]._filter.value()[].predicate.copy()
            var outer_pred = plan._filter.value()[].predicate.copy()
            var fused = Expr.binary(BIN_AND, inner_pred^, outer_pred^)
            # Deep-copy the grandchild subtree (cannot partial-move the
            # OwnedPointer out of FilterData under Mojo 0.26.3).
            var grandchild_copy = _copy_plan(plan._filter.value()[].child[]._filter.value()[].child[])
            # Replace this Filter's child OwnedPointer with a fresh one
            # holding the grandchild copy.
            plan._filter.value()[].child = OwnedPointer(grandchild_copy^)
            plan._filter.value()[].predicate = fused^

    elif plan.tag == PLAN_PROJECT:
        fuse_filters_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        fuse_filters_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        fuse_filters_inplace(plan._join.value()[].left[])
        fuse_filters_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        fuse_filters_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        fuse_filters_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        fuse_filters_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        fuse_filters_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN: no children to recurse into


# =============================================================================
# Rule 8: Filter Decomposition
# =============================================================================

def decompose_filters(var plan: LogicalPlan) raises -> LogicalPlan:
    """Split AND predicates in Filter nodes into separate Filter nodes.

    Wrapper around `decompose_filters_inplace` for legacy callers.
    """
    decompose_filters_inplace(plan)
    return plan^


def decompose_filters_inplace(mut plan: LogicalPlan) raises:
    """In-place filter decomposition.

    Recurses children IN PLACE. The decompose path itself (Filter with
    AND-conjunct predicate) takes a deep copy of the child because we
    must restructure the tree (one Filter -> N nested Filters); the
    child OwnedPointer cannot be partial-moved out of FilterData under
    Mojo 0.26.3. This deep-copy only fires when decomposition applies.
    """
    if plan.tag == PLAN_FILTER:
        decompose_filters_inplace(plan._filter.value()[].child[])

        var pred_copy = plan._filter.value()[].predicate.copy()
        var conjuncts = ExprArray()
        _collect_and_conjuncts(pred_copy^, conjuncts)

        if len(conjuncts) <= 1:
            # No decomposition needed -- predicate had a single top-level
            # conjunct. Avoid the rebuild path.
            return

        # Decomposition: rebuild a chain of Filter nodes around the
        # current child. Take a deep copy of the child subtree (rare path).
        var child_copy = _copy_plan(plan._filter.value()[].child[])
        var result = child_copy^
        for i in range(len(conjuncts)):
            var conj = conjuncts[i].copy()
            result = LogicalPlan.filter(conj^, result^)
        # Replace `plan` with the decomposed chain. Since `plan` is `mut`,
        # we must reassign it. Use Optional dance: take the result's
        # FilterData (a chain of nested filters) and graft it onto plan.
        # Simpler: just replace plan via direct assignment-via-take on
        # the inner Filter chain. We set plan._filter = result._filter.take()
        # but we need to also set the schema. Schema is unchanged for
        # nested filter chains, so just update the FilterData.
        plan._filter = result._filter.take()

    elif plan.tag == PLAN_PROJECT:
        decompose_filters_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        decompose_filters_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        decompose_filters_inplace(plan._join.value()[].left[])
        decompose_filters_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        decompose_filters_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        decompose_filters_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        decompose_filters_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        decompose_filters_inplace(plan._topn.value()[].child[])


def _collect_and_conjuncts(var expr: Expr, mut conjuncts: ExprArray):
    """Flatten top-level AND tree into a list of conjuncts.

    E.g., (A AND B) AND C -> [A, B, C]
    Non-AND expressions are added as leaf conjuncts.
    """
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_AND:
        var left = expr.binary_left()
        var right = expr.binary_right()
        _collect_and_conjuncts(left^, conjuncts)
        _collect_and_conjuncts(right^, conjuncts)
    else:
        conjuncts.append(expr^)


# =============================================================================
# Rule 2: Predicate Pushdown
# =============================================================================

def push_predicates_down(var plan: LogicalPlan) raises -> LogicalPlan:
    """Push filter predicates toward scan nodes.

    Note: the FILTER case still rebuilds because pushdown rewrites
    the parent shape (Filter goes through Project, into Join's left or
    right side, into Scan's pushed-filter). The non-FILTER recursion
    paths use in-place walks via push_predicates_down_inplace_walk so
    operators above a Filter no longer rebuild on every pass.
    """
    # ★★ A UDF-CARRYING NODE IS OPAQUE TO THIS PASS. Pinned by
    # `test_optimizer_udf_node_opacity.mojo`, which fails on BOTH halves
    # without it.
    #
    # This node's `predicate` is a PLACEHOLDER — the UDF path stamps `lit(true)`
    # because the customer's predicate IS the UDF — and `lit(true)` is the most
    # absorbable predicate there is. The scan arm below takes it, `len(kept)`
    # reaches 0, and `return new_scan^` returns the BARE SCAN: the UDF node is
    # deleted and the query returns EVERY ROW, with rc=0.
    #
    # ⚠ A FULL STOP, NOT A RECURSE-INTO-THE-CHILD. Recursing would mean taking
    # the child out and rebuilding this node — and rebuilding is exactly how the
    # Project arm below lost its UDF for fifteen months, because every rebuild
    # site reaches for the NON-UDF factory. Costing nothing today
    # (`komira_dispatch_scan.udf_execution_refusal` is designed to refuse a UDF
    # plan before the optimizer runs), a full stop cannot drop a payload. If a
    # UDF ever sits above a subtree worth optimising, add the recursion WITH a
    # `filter_with_udf` rebuild and a test that counts UDFs across the whole tree.
    if plan.has_udf():
        return plan^

    if plan.tag == PLAN_FILTER:
        var child = _take_filter_child(plan)
        var pred = plan._filter.value()[].predicate.copy()

        # Push through Project if predicate only references columns below
        if child.tag == PLAN_PROJECT:
            # Projection guard: a Project
            # whose `udf` is populated is opaque to predicate pushdown.
            # The UDF's output column(s) may be in scope of `pred` (e.g.
            # `df.map[F]().filter(col(F.out) > 0)`), so pushing the filter
            # below the Project would reference a column that does not
            # yet exist in the under-Project schema. Even when `pred`
            # references only pass-through columns, pushing changes the
            # cardinality the UDF sees, which is illegal for non-stateless
            # UDFs (e.g. partition-local with order keys). Mirror DuckDB
            # `src/optimizer/pushdown/pushdown_projection.cpp:51-55` —
            # volatile-projection expressions force the filter to remain
            # ABOVE the Project. Leave `pred` parked above the Project and
            # recurse into the Project's child untouched.
            #
            # CSE barrier: a Project
            # flagged `is_cse_introduced=True` is similarly opaque. It
            # materializes `_cse_*` synthetic columns that exist ONLY
            # above the Project; the predicate may reference these
            # (Axis 2 rewrites Filter predicates to ColRef synthetics),
            # so pushing the Filter below would dangle the ColRef. The
            # barrier mirrors the UDF-Project handling.
            # UDF-Project barrier removed —
            # ProjectData no longer carries `udf`. The CSE-introduced barrier
            # still holds: a `_cse_*` synthetic column materialized above the
            # Project must NOT be referenced from a predicate pushed below it.
            # ★ THE BARRIER THE COMMENT ABOVE DESCRIBES, RESTORED. Its
            # rationale ("pushing changes the cardinality the UDF sees, which
            # is illegal for non-stateless UDFs") outlived the guard by fifteen
            # months: a change removed it on day one because `ProjectData`
            # had lost its `udf` field, and a later change PUT THE FIELD BACK ON
            # day two. Without this, a Filter pushed
            # through a UDF-Project rebuilds it via `LogicalPlan.project(...)`
            # — the NON-UDF factory — and the customer's function is simply
            # GONE, leaving the placeholder col-refs to execute in its place.
            if child.has_udf():
                return LogicalPlan.filter(pred^, child^)
            if child._project.value()[].is_cse_introduced:
                var proj_child_keep = _take_project_child(child)
                var proj_exprs_keep = _copy_expr_array(child._project.value()[].exprs)
                var cse_keep = child._project.value()[].is_cse_introduced
                var new_proj_child = push_predicates_down(proj_child_keep^)
                var new_proj = LogicalPlan.project(proj_exprs_keep^, new_proj_child^, cse_keep)
                return LogicalPlan.filter(pred^, new_proj^)
            var proj_child = _take_project_child(child)
            var proj_exprs_copy = _copy_expr_array(child._project.value()[].exprs)
            # ⛔ BY NAME IS NOT ENOUGH: a Project may REPLACE a name its child
            # also has (`SELECT k, v*2 AS v`), and a predicate pushed raw then
            # reads the ORIGINAL column -- a silent wrong answer (see
            # `optimizer_project_merge_guard`'s header). Push only what means
            # the same below the Project.
            var proj_names = List[String]()
            for c in range(child.output_schema.num_columns()):
                proj_names.append(child.output_schema.field_name(c))
            var below = predicate_below_project(
                pred, proj_names, child._project.value()[].exprs
            )
            if below and _predicate_refs_in_schema(
                below.value(), proj_child.output_schema
            ):
                var new_filter = LogicalPlan.filter(below.take(), proj_child^)
                var pushed = push_predicates_down(new_filter^)
                return LogicalPlan.project(proj_exprs_copy^, pushed^)
            else:
                var new_proj_child = push_predicates_down(proj_child^)
                var new_proj = LogicalPlan.project(proj_exprs_copy^, new_proj_child^)
                return LogicalPlan.filter(pred^, new_proj^)

        # Push into Scan: split `pred` into AND-conjuncts and ask the
        # scan's Source which ones it can usefully absorb (per-conjunct
        # pushdown). Conjuncts
        # the Source accepts are folded into `pushed_filter`; the rest
        # stay as a `Filter` node above the (possibly-rewritten) scan.
        # A Source that rejects everything (e.g. InMemorySource today,
        # or a Parquet predicate that's an OR-tree / LIKE / arithmetic)
        # leaves the scan untouched and the whole predicate above it.
        elif child.tag == PLAN_SCAN:
            # ⚠ THE REASON THIS BRANCH WAS WRITTEN IS GONE; THE BRANCH IS
            # NOT. Read this before "simplifying" it either way.
            #
            # HISTORY: do NOT
            # push a filter into a SOURCE_KIND_ROW scan, because the
            # row-streaming executor (Path 4) lowered the filter from the
            # PLAN_FILTER node ABOVE the scan and never read the scan-node
            # `ScanData.filter` — pushing into the scan silently dropped the
            # predicate. The closing claim was "no column-side regression: a
            # SOURCE_KIND_ROW scan never reached the column predicate-pushdown
            # win anyway, its producer is the row pump".
            #
            # ⛔ BOTH HALVES ARE NOW FALSE. The row execution tower was deleted
            # 2026-09-10 (`route_plan_shape_row_streaming` returns False
            # unconditionally); there is no row pump, and a SOURCE_KIND_ROW
            # scan's producer IS the column path. So this early return no
            # longer prevents a dropped predicate — it declines a pushdown the
            # column path could have taken.
            #
            # ⚠ IT IS KEPT DELIBERATELY, NOT BY OVERSIGHT, because whether
            # removing it is a NO-OP is UNMEASURED. `SOURCE_KIND_ROW` is a
            # SOURCE-DECODE annotation (CSV / NDJSON / Avro), NOT the deleted
            # execution orientation, and all three of those sources answer
            # `supports_filter_pushdown -> False` unconditionally
            # (komira_scan_source: CsvSource, JsonSource, AvroSource)
            # — over them `pushable` would come back empty and the rebuilt node
            # would be identical. What is NOT established is that nothing puts
            # SOURCE_KIND_ROW over a source that ACCEPTS a predicate; the
            # legacy CSV factory once threaded exactly that over a ParquetSource
            # (logical_plan.mojo, "★ CSV BUILDS A `CsvSource`, NOT A
            # `ParquetSource`"). Removing the branch is a PLAN-SHAPE change and needs a
            # differential test against the column oracle, not an edit.
            if child._scan.value()[].source_kind == SOURCE_KIND_ROW:
                return LogicalPlan.filter(pred^, child^)

            var conjuncts = ExprArray()
            _collect_and_conjuncts(pred^, conjuncts)

            var pushable = ExprArray()
            var kept = ExprArray()
            for i in range(len(conjuncts)):
                if child._scan.value()[].source.supports_filter_pushdown(
                    conjuncts[i]
                ):
                    pushable.append(conjuncts[i].copy())
                else:
                    kept.append(conjuncts[i].copy())

            if len(pushable) == 0:
                # Nothing pushable — leave the scan as-is, keep the whole
                # predicate as a Filter node above it. Rebuild `pred`
                # from `kept` (== all conjuncts) so its AND-shape is the
                # canonical right-leaning chain.
                var kept_pred = kept[0].copy()
                for i in range(1, len(kept)):
                    kept_pred = Expr.binary(BIN_AND, kept_pred^, kept[i].copy())
                return LogicalPlan.filter(kept_pred^, child^)

            # Build the new scan filter = (old pushed_filter?) AND (pushable conjuncts).
            var merged_pred: Expr
            var first_idx = 0
            if child._scan.value()[].filter:
                merged_pred = child._scan.value()[].filter.value().copy()
            else:
                merged_pred = pushable[0].copy()
                first_idx = 1
            for i in range(first_idx, len(pushable)):
                merged_pred = Expr.binary(BIN_AND, merged_pred^, pushable[i].copy())

            var proj_copy: Optional[List[String]] = None
            if child._scan.value()[].projection:
                proj_copy = child._scan.value()[].projection.value().copy()
            var new_filter: Optional[Expr] = merged_pred^
            var rc_opt: Optional[Int] = None
            if child._scan.value()[].row_count:
                rc_opt = child._scan.value()[].row_count.value()
            var ts_opt: Optional[TableStats] = None
            if child._scan.value()[].table_stats:
                ts_opt = Optional[TableStats](child._scan.value()[].table_stats.value().copy())
            # Rebuild via
            # `scan_from_source` to preserve the SourceVariant's inline
            # batch payload (for SOURCE_IN_MEMORY scans built from
            # an in-memory record batch or by the scalar-broadcast rewrite).
            # `LogicalPlan.scan(source_path, source_type, ...)` would build
            # an EMPTY InMemorySource Slab, and nothing resolves an
            # in-memory scan by name, so this path must preserve the inline
            # batch. `SourceVariant.copy()` is a refcount-bump on the
            # ArcPointer[Slab[RecordBatch]] payload (no buffer byte-copy).
            var src_copy = child._scan.value()[].source.copy()
            # Preserve the
            # original scan's `source_kind` across this filter-into-scan
            # rebuild. Without threading the kind, `scan_from_source` would
            # reset it to its default, `SOURCE_KIND_UNSET`, and the rewritten
            # scan would lose its source-decode annotation.
            var src_kind = child._scan.value()[].source_kind
            var new_scan = LogicalPlan.scan_from_source(
                src_copy^,
                _copy_schema(child.output_schema),
                proj_copy^,
                new_filter^,
                rc_opt^,
                ts_opt^,
                src_kind,
            )
            if len(kept) == 0:
                return new_scan^
            # Some conjuncts could not be pushed — wrap the rewritten
            # scan in a Filter carrying just those (right-leaning AND).
            var kept_pred2 = kept[0].copy()
            for i in range(1, len(kept)):
                kept_pred2 = Expr.binary(BIN_AND, kept_pred2^, kept[i].copy())
            return LogicalPlan.filter(kept_pred2^, new_scan^)

        # Push through Filter (recurse). First push the inner Filter's
        # subtree; if that collapsed the inner Filter into a non-Filter
        # node (e.g. its predicate merged into a Scan, or it pushed into
        # a Join side), the merged shape may now also admit `pred` — so
        # re-run pushdown on `Filter(pred, new_child)`. But if `new_child`
        # comes back STILL a Filter, that means the inner predicate is
        # parked above a node it can't descend through (a both-sides
        # Join, an Aggregate, etc.); `pred` cannot descend there either,
        # so re-recursing on `Filter(pred, Filter(inner, ...))` would
        # produce an identical (node, predicate-set) pair and loop
        # forever (the OPTIMIZER-PUSHDOWN-RECURSION-BUG: a decomposed
        # both-sides AND like `eq1 AND eq2 AND eq3` over a CROSS/INNER
        # join becomes nested Filters, none of which can push, and the
        # old unconditional re-recursion never terminated). Park `pred`
        # above the inner Filter and stop.
        elif child.tag == PLAN_FILTER:
            var new_child = push_predicates_down(child^)
            if new_child.tag == PLAN_FILTER:
                # `new_child` = Filter(inner_pred, gc): inner_pred is parked
                # above a node it can't descend (a both-sides Join / Aggregate).
                # But `pred` (this OUTER filter) MAY descend PAST the inner
                # filter into `gc` — TPC-H q9: the single-
                # table `p_name LIKE '%green%'` is stacked above the both-sides
                # bridging conjunct `p_partkey = l_partkey` that is (correctly)
                # parked above the `(part × supplier) ⋈ lineitem` join, so the
                # old "park `pred` above the inner filter" left green stranded
                # above the 6M-row join instead of on the part scan.
                #
                # TRIAL-THEN-COMMIT: push `pred` into a COPY of `gc` and swap
                # ONLY IF `pred` genuinely DESCENDED (the pushed root is no
                # longer a Filter — it reached a Join/Scan via a refs-validated
                # push). If it did descend, re-wrap the inner predicate on top;
                # filters COMMUTE (both conjunctive over the SAME `gc` output
                # schema), so the swap is byte-identical AND schema-safe (the
                # descent already passed the Filter-through-Join refs guard, so
                # no dangling column ref). If `pred` did NOT descend (a both-
                # sides / disambiguated `_right`-column predicate that can only
                # live above the join — TPC-H q17's self-join equi-condition),
                # keep the ORIGINAL park order untouched: reordering two filters
                # that both belong above the join is pointless and can dangle a
                # join-output-only column when the self-join disambiguation
                # order flips. TERMINATION: the trial pushes into `gc` (a
                # strictly smaller subtree) and the swapped whole is returned
                # WITHOUT re-recursion, so the `eq1 AND eq2 AND eq3`-over-a-join
                # nest still terminates.
                var inner_pred = new_child._filter.value()[].predicate.copy()
                var gc = _take_filter_child(new_child)
                var trial = push_predicates_down(
                    LogicalPlan.filter(pred.copy(), _copy_plan(gc))
                )
                if trial.tag != PLAN_FILTER:
                    # `pred` descended past the inner filter → swap.
                    _ = gc^
                    return LogicalPlan.filter(inner_pred^, trial^)
                # `pred` could not descend → keep the original park order.
                _ = trial^
                return LogicalPlan.filter(
                    pred^, LogicalPlan.filter(inner_pred^, gc^)
                )
            return push_predicates_down(LogicalPlan.filter(pred^, new_child^))

        # Push through Inner OR Cross Join: if predicate references only one
        # side, push into that side. TPC-H Q3/Q5/Q7 depend on this: their date
        # filters belong on one side of the join, below it.
        #
        # Also descend JOIN_CROSS. The SQL binder
        # lowers a comma-list FROM (`FROM a, b, c WHERE a.k=b.k AND ...`) into a
        # LEFT-DEEP tree of JOIN_CROSS nodes + a single top Filter, and relies
        # on `eliminate_cross_join` to fold the WHERE equi-conjuncts into inner
        # joins. But `eliminate_cross_join` only folds a cross join with a
        # Filter DIRECTLY above it — so the WHERE conjuncts must first be pushed
        # DOWN to sit above the appropriate cross-join level. Before this fix
        # pushdown stopped at the topmost cross join (it matched only
        # JOIN_INNER), leaving every NESTED cross join a cartesian product
        # (customer×orders×… in q3/q5/q7/q9/q10). Pushing a
        # single-side filter into one side of a CROSS join is trivially
        # semantics-preserving: a cross join has no join condition, so a filter
        # on one input's columns commutes with the product. The rebuild
        # preserves the child's join_type (`jt`) and its (empty-for-CROSS)
        # key lists, so a cross join stays CROSS here and is folded to INNER by
        # `eliminate_cross_join` once its bridging equi-conjunct lands directly
        # above it. A both-sides conjunct (the bridging equi-key) is parked
        # above the join by the `else` arm — exactly where the fold expects it.
        #
        # A residual-carrying INNER join is left as a filter
        # barrier — the rebuild branches below don't thread `residual`
        # through, so pushing a filter into a side would silently drop
        # the residual condition. (Pushing IS semantically valid; the
        # rebuild just doesn't carry the residual yet.)
        elif child.tag == PLAN_JOIN \
             and (child._join.value()[].join_type == JOIN_INNER \
                  or child._join.value()[].join_type == JOIN_CROSS) \
             and not child._join.value()[].has_residual():
            var jt = child._join.value()[].join_type
            var left_schema = _copy_schema(child._join.value()[].left[].output_schema)
            var right_schema = _copy_schema(child._join.value()[].right[].output_schema)
            var refs_left = _predicate_refs_in_schema(pred, left_schema)
            var refs_right = _predicate_refs_in_schema(pred, right_schema)

            if refs_left and not refs_right:
                # Push into left side only
                var left = _take_join_left(child)
                var right = _take_join_right(child)
                var new_left = LogicalPlan.filter(pred^, left^)
                var pushed_left = push_predicates_down(new_left^)
                var new_right = push_predicates_down(right^)
                return LogicalPlan.join(
                    pushed_left^,
                    new_right^,
                    child._join.value()[].left_on.copy(),
                    child._join.value()[].right_on.copy(),
                    jt,
                )
            elif refs_right and not refs_left:
                # Push into right side only
                var left = _take_join_left(child)
                var right = _take_join_right(child)
                var new_left = push_predicates_down(left^)
                var new_right = LogicalPlan.filter(pred^, right^)
                var pushed_right = push_predicates_down(new_right^)
                return LogicalPlan.join(
                    new_left^,
                    pushed_right^,
                    child._join.value()[].left_on.copy(),
                    child._join.value()[].right_on.copy(),
                    jt,
                )
            else:
                # Predicate spans both sides (or neither — shouldn't happen);
                # leave it above the join.
                var new_child = push_predicates_down(child^)
                return LogicalPlan.filter(pred^, new_child^)

        # Cannot push through Aggregate, Limit, Distinct, Sort, other join types
        else:
            var new_child = push_predicates_down(child^)
            return LogicalPlan.filter(pred^, new_child^)

    # Non-FILTER cases mutate the existing parent's child
    # OwnedPointer in place instead of rebuilding the parent node. The
    # FILTER case itself still rebuilds because pushdown moves the
    # filter through/into the parent. Children are still deep-copied
    # for the recursive call (partial-move ban on OwnedPointer field),
    # but the parent's wrapper Schema + OwnedPointer is reused.
    elif plan.tag == PLAN_PROJECT:
        var child_in = _copy_plan(plan._project.value()[].child[])
        var new_child = push_predicates_down(child_in^)
        plan._project.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_AGGREGATE:
        var child_in = _copy_plan(plan._aggregate.value()[].child[])
        var new_child = push_predicates_down(child_in^)
        plan._aggregate.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_JOIN:
        var left_in = _copy_plan(plan._join.value()[].left[])
        var right_in = _copy_plan(plan._join.value()[].right[])
        var new_left = push_predicates_down(left_in^)
        var new_right = push_predicates_down(right_in^)
        plan._join.value()[].left = OwnedPointer(new_left^)
        plan._join.value()[].right = OwnedPointer(new_right^)

    elif plan.tag == PLAN_SORT:
        var child_in = _copy_plan(plan._sort.value()[].child[])
        var new_child = push_predicates_down(child_in^)
        plan._sort.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_LIMIT:
        var child_in = _copy_plan(plan._limit.value()[].child[])
        var new_child = push_predicates_down(child_in^)
        plan._limit.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_DISTINCT:
        var child_in = _copy_plan(plan._distinct.value()[].child[])
        var new_child = push_predicates_down(child_in^)
        plan._distinct.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_TOPN:
        var child_in = _copy_plan(plan._topn.value()[].child[])
        var new_child = push_predicates_down(child_in^)
        plan._topn.value()[].child = OwnedPointer(new_child^)

    return plan^


def _predicate_refs_in_schema(expr: Expr, schema: Schema) -> Bool:
    """Check if all column references in an expression exist in the given schema."""
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        for i in range(schema.num_columns()):
            if schema.field_name(i) == name:
                return True
        return False

    elif expr.tag == EXPR_BINARY_OP:
        return _predicate_refs_in_schema(expr.binary_left_ref(), schema) and _predicate_refs_in_schema(expr.binary_right_ref(), schema)

    elif expr.tag == EXPR_UNARY_OP:
        return _predicate_refs_in_schema(expr.unary_child_ref(), schema)

    elif expr.tag == EXPR_CAST:
        return _predicate_refs_in_schema(expr.cast_child_ref(), schema)

    elif expr.tag == EXPR_ALIAS:
        return _predicate_refs_in_schema(expr.alias_child_ref(), schema)

    elif expr.tag == EXPR_IN_LIST:
        # IN list: only the child carries column refs;
        # values are scalar literals.
        return _predicate_refs_in_schema(expr.in_list_child_ref(), schema)

    elif expr.tag == EXPR_STRING_OP:
        # TPC-H q9 stranded residual fix. A string
        # predicate (`col LIKE ...` / `.contains` / `.starts_with` /
        # `.ends_with`) carries its column refs ONLY in the child; the
        # pattern is a plan-literal. Without this arm the fallback below
        # returned `True` for EVERY schema, so a single-table string filter
        # (q9's part-only `p_name LIKE '%green%'`) evaluated as
        # `refs_left == refs_right == True` in the Filter-through-Join arm
        # -> "spans both sides" -> PARKED above the top join instead of
        # descending to sit above its owning (part) scan, so the plan joined
        # all of partsupp and lineitem before filtering to the green parts.
        # The sibling column-need walk (today
        # `expr_walk.walk_expr_column_refs`) grew this exact arm earlier for
        # projection pushdown (q2/q9/q13/q16/q20 string-only predicates);
        # this filter-pushdown walker was the missed twin.
        return _predicate_refs_in_schema(expr.string_op_child_ref(), schema)

    elif expr.tag == EXPR_REGEXP:
        # Stranded regexp filter fix. The EXACT twin of the
        # EXPR_STRING_OP arm above, and it was missed when that one landed on
        # an earlier day — the sibling column-need walk
        # (today `expr_walk.walk_expr_column_refs`) grew BOTH arms together on
        # an earlier day, so the asymmetry is between the two WALKERS, not between
        # the two tags. Like a string op, an `EXPR_REGEXP` carries its column
        # refs ONLY in the child; pattern / replacement / flags / group /
        # group_name are plan-literals.
        #
        # Without this arm the predicate fell through to the `return True`
        # fallback below and read as referencing EVERY schema, so
        # `refs_left == refs_right == True` -> "spans both sides" -> the filter
        # was parked above the join instead of descending to its owning scan,
        # and a right-only ON-conjunct stayed a join RESIDUAL instead of
        # becoming a Filter on the owning side (`_split_join_residual_to_side`).
        # EXPR_REGEXP is not exotic: it is what BOTH Python skins emit for an
        # interior-wildcard LIKE (`%a%b%`), which cannot lower to
        # contains/starts_with/ends_with without losing the ORDER the pattern
        # requires.
        #
        # Guarded by tests/…/test_optimizer_string_filter_descends.mojo's three
        # `test_regexp_*` cases (RED before this arm: child tag PLAN_JOIN not
        # PLAN_SCAN; `has_residual` True not False).
        return _predicate_refs_in_schema(expr.regexp_child_ref(), schema)

    elif expr.tag == EXPR_STRING_FN:
        # Added on 2026-09-02. The third member of the same family as
        # the two arms above, added WITH the tag rather than after a bench
        # regression found it missing — `WHERE upper(name) = 'ACME'` is the
        # single most common shape this builtin exists for, and without this
        # arm it reads as referencing EVERY schema and parks above the join.
        # A `STRFN_*` node carries its column refs ONLY in the child; the op is
        # a plan-literal.
        return _predicate_refs_in_schema(expr.string_fn_child_ref(), schema)

    elif expr.tag == EXPR_STRING_FN_N:
        # Added on 2026-09-03. ⚠ THE FOLD IS `and` OVER EVERY
        # ARGUMENT, and the EMPTY case answers True. A node with zero
        # arguments is malformed (`string_fn_n_arity` gives every member a
        # floor of at least 1) and the plan wire decoder refuses it; answering
        # True here means "this carries no reference that stops the push",
        # which is the same answer a literal gives and never a claim that the
        # node is valid.
        for i in range(expr.string_fn_n_num_args()):
            if not _predicate_refs_in_schema(
                expr.string_fn_n_arg_ref(i), schema
            ):
                return False
        return True

    elif expr.tag == EXPR_UDF_CALL:
        # Added on 2026-09-02. `filter(affine(col("x")) > lit(10))` is one of
        # the three things the retired `.on()/.to()` node form could not do at
        # all, so the arm lands WITH the tag. The UDF's column refs are ONLY in
        # the argument; name / handle / dtype tags are plan-literals.
        return _predicate_refs_in_schema(expr.udf_call_child_ref(), schema)

    # Literals, ColIdx: always valid.
    #
    # ⚠ THIS FALLBACK IS OPEN, AND THAT IS WHY THIS BUG HAS NOW HAPPENED TWICE.
    # It is correctness-SAFE (claiming "refs every schema" only ever PREVENTS a
    # pushdown) and performance-PESSIMAL. This walker has fewer arms than the
    # complete column-reference walk (`komira_plan_expr.expr_walk.
    # walk_expr_column_refs`, which `plan_helpers._collect_expr_columns`
    # wraps). A predicate built from any missing tag never descends.
    #
    # ⚠ EARLIER HAND COUNTS OF THIS GAP WERE WRONG. Every figure below was
    # DERIVED by counting each ladder's `if`/`elif expr.tag ==` tags:
    #
    # walker tags: 11
    # sibling tags: 23
    # missing: EXPR_AGG_FN EXPR_CORRELATED_SUBQUERY EXPR_EXTRACT
    #   EXPR_JSON_EXTRACT EXPR_MAP_GET EXPR_MATH_FN EXPR_MATH_FN2
    #   EXPR_STRUCT_FIELD EXPR_STRUCT_FIELD_IDX EXPR_SUBSTRING EXPR_WHEN
    #   EXPR_WINDOW_FN
    # They are named here rather than fixed blind.
    return True


# =============================================================================
# Rule: push a JOIN's single-side ON-residual conjuncts to the owning child
# =============================================================================


def _and_combine(var conjuncts: ExprArray) -> Expr:
    """Combine a NON-EMPTY conjunct list into a right-leaning `AND` chain (the
    canonical predicate shape the rest of the optimizer produces)."""
    var acc = conjuncts[0].copy()
    for i in range(1, len(conjuncts)):
        acc = Expr.binary(BIN_AND, acc^, conjuncts[i].copy())
    return acc^


def push_join_residual_to_side(var plan: LogicalPlan) raises -> LogicalPlan:
    """Push a JOIN's single-side ON-clause residual conjuncts down as a `FILTER`
    on the owning child, so a residual-carrying equi-join becomes a plain
    equi-join above a child filter (which predicate pushdown, and a projection
    pushdown pass that is not in this tree, then narrow).

    This is the standard outer-join predicate-pushdown rule (DuckDB
    `pushdown_left_join` / `pushdown_inner_join`): for a JOIN whose ON clause
    carries a residual predicate `R` (its non-equi part, already lifted to plain
    joined-schema col-refs by `join_predicate_decompose`), any AND-conjunct of
    `R` that references ONLY the null-supplying (inner) side may instead be
    evaluated as a FILTER on that side BEFORE the join — the per-left-row match
    set (and therefore the outer null-extension) is identical.

      * `JOIN_INNER` — a conjunct over ONLY the left child pushes to the left;
        one over ONLY the right child pushes to the right (both children are
        "inner").
      * `JOIN_LEFT` — only RIGHT-only conjuncts push (the right child is the
        null-supplying inner side). A LEFT-only ON conjunct on a LEFT join is
        NOT a `WHERE` filter (an unmatched left row still null-extends), so it
        stays on the residual.

    Correctness (LEFT, right-only conjunct C):
      `A LEFT JOIN B ON (eq AND C(B))` ≡ `A LEFT JOIN (σ_C B) ON (eq)` — for each
      row `a`, `{b : eq(a,b) AND C(b)}` equals `{b ∈ σ_C B : eq(a,b)}`; both
      null-extend `a` iff that set is empty. Holds even when `R` also carries a
      both-sides conjunct `D` (kept on the residual): `{b : eq ∧ C(b) ∧ D(a,b)}`
      = `{b ∈ σ_C B : eq ∧ D(a,b)}`.

    TPC-H q13: `customer LEFT JOIN orders ON c_custkey = o_custkey AND o_comment
    NOT LIKE '%special%requests%'`. The residual references only `o_comment`
    (orders = right/inner), so it lowers to a FILTER on the orders scan. This
    turns a residual join (the `NOT LIKE` evaluated once per equi-candidate
    pair) into a plain LEFT equi-join over a once-filtered orders side, and lets
    a projection pushdown pass (not in this tree) drop `o_comment` from the join
    output.

    Only the DECOMPOSED equi-join form (`left_on`/`right_on` non-empty) is
    rewritten: a residual that survived decompose with NO equi-key is a pure-NLJ
    shape (no plain-equi form to fall back to) and is left unchanged. RIGHT /
    FULL / SEMI / ANTI residuals are left unchanged (a follow-up — the
    null-supplying side / existence semantics differ). Recurses bottom-up; a
    collision-`_right`-renamed residual col-ref resolves against NEITHER child
    schema by name, so it is conservatively kept on the residual (never
    mis-pushed). No-op when no JOIN carries a single-side residual conjunct."""
    if plan.tag == PLAN_FILTER and plan._filter:
        var c = _take_filter_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._filter.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_PROJECT and plan._project:
        var c = _take_project_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._project.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_AGGREGATE and plan._aggregate:
        var c = _take_aggregate_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._aggregate.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_SORT and plan._sort:
        var c = _take_sort_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._sort.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_LIMIT and plan._limit:
        var c = _take_limit_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._limit.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_DISTINCT and plan._distinct:
        var c = _take_distinct_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._distinct.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_TOPN and plan._topn:
        var c = _take_topn_child(plan)
        var nc = push_join_residual_to_side(c^)
        plan._topn.value()[].child = OwnedPointer(nc^)
    elif plan.tag == PLAN_JOIN and plan._join:
        var l = _take_join_left(plan)
        var nl = push_join_residual_to_side(l^)
        plan._join.value()[].left = OwnedPointer(nl^)
        var r = _take_join_right(plan)
        var nr = push_join_residual_to_side(r^)
        plan._join.value()[].right = OwnedPointer(nr^)
        return _split_join_residual_to_side(plan^)
    return plan^


def _split_join_residual_to_side(var plan: LogicalPlan) raises -> LogicalPlan:
    """Split THIS join's residual (children already recursed) — see
    `push_join_residual_to_side`. Returns the plan unchanged unless it is a
    decomposed INNER/LEFT equi-join whose residual has a single-side conjunct."""
    if plan.tag != PLAN_JOIN or not plan._join:
        return plan^
    if not plan._join.value()[].has_residual():
        return plan^
    var jt = plan._join.value()[].join_type
    if jt != JOIN_INNER and jt != JOIN_LEFT:
        return plan^
    # Decomposed equi-join only: a residual that survived decompose with NO
    # equi-key is a pure-NLJ shape with no plain-equi form — leave it.
    if len(plan._join.value()[].left_on) == 0:
        return plan^

    # Classify each residual AND-conjunct against the (recursed) child schemas.
    var conjuncts = ExprArray()
    _collect_and_conjuncts(
        plan._join.value()[].residual.value()[].copy(), conjuncts
    )
    var kept = ExprArray()
    var to_left = ExprArray()
    var to_right = ExprArray()
    for i in range(len(conjuncts)):
        var refs_left = _predicate_refs_in_schema(
            conjuncts[i], plan._join.value()[].left[].output_schema
        )
        var refs_right = _predicate_refs_in_schema(
            conjuncts[i], plan._join.value()[].right[].output_schema
        )
        if refs_right and not refs_left:
            # Right-only conjunct — pushable to the right for INNER and LEFT
            # (the right child is the null-supplying inner side for LEFT).
            to_right.append(conjuncts[i].copy())
        elif refs_left and not refs_right and jt == JOIN_INNER:
            # Left-only conjunct — pushable to the left for INNER only.
            to_left.append(conjuncts[i].copy())
        else:
            # Both-sides / neither / a LEFT left-only conjunct — stays residual.
            kept.append(conjuncts[i].copy())

    if len(to_left) == 0 and len(to_right) == 0:
        return plan^  # nothing single-sided to push — unchanged

    # Rebuild: wrap the pushed children in FILTER nodes; rebuild the residual
    # from the kept conjuncts (or None). Preserve join_type / algo_hint / keys.
    var jt2 = plan._join.value()[].join_type
    var algo = plan._join.value()[].algo_hint
    var left_on = plan._join.value()[].left_on.copy()
    var right_on = plan._join.value()[].right_on.copy()
    var new_left = _take_join_left(plan)
    var new_right = _take_join_right(plan)
    if len(to_left) > 0:
        new_left = LogicalPlan.filter(_and_combine(to_left^), new_left^)
    if len(to_right) > 0:
        new_right = LogicalPlan.filter(_and_combine(to_right^), new_right^)
    var new_residual: Optional[OwnedPointer[Expr]] = None
    if len(kept) > 0:
        new_residual = Optional[OwnedPointer[Expr]](
            OwnedPointer(_and_combine(kept^))
        )
    return LogicalPlan.join(
        new_left^, new_right^, left_on^, right_on^, jt2, algo, new_residual^
    )


# =============================================================================
# Rule 19: Eliminate Cross Join
# =============================================================================

def eliminate_cross_join(var plan: LogicalPlan) raises -> LogicalPlan:
    """Convert cross join + equi-filter into inner join.

    Wrapper around `eliminate_cross_join_inplace`.
    """
    eliminate_cross_join_inplace(plan)
    return plan^


def eliminate_cross_join_inplace(mut plan: LogicalPlan) raises:
    """In-place cross-join elimination + equi-filter-into-INNER-join folding.

    Recurses children IN PLACE. Two cases fire:

    1. **Filter-above-Cross-Join** (original behavior): convert CROSS to
       INNER by extracting equi-keys from the Filter predicate.
    2. **Filter-above-Inner-Join** (bench-shape feature 1B): fold any
       equi-conjuncts from the Filter predicate that bridge the two
       sides into the existing INNER join's `left_on` / `right_on`,
       producing a multi-key composite hash-join probe instead of a
       single-key probe + post-join filter. This is the planner-side
       analog of "JOIN ON A=B AND C=D" being expressed as separate
       single-key join + downstream filter in a hand-written plan.

    In both cases, when all conjuncts are equi-keys the Filter node is
    eliminated by replacing plan with a deep-copy of the now-rewritten
    Join. Non-firing walks skip rebuilds entirely.
    """
    if plan.tag == PLAN_FILTER:
        eliminate_cross_join_inplace(plan._filter.value()[].child[])

        if plan._filter.value()[].child[].tag == PLAN_JOIN and plan._filter.value()[].child[]._join.value()[].join_type == JOIN_CROSS:
            # MOJO 1.0.0: every ref used together must be projected out of
            # ONE interior-reference walk. Re-walking `plan._filter...`
            # forms a second origin over the same storage and invalidates the
            # first (an earlier Mojo beta accepted the repeated walk).
            ref fd = plan._filter.value()[]
            ref jd = fd.child[]._join.value()[]
            var left_keys = List[String]()
            var right_keys = List[String]()
            # CROSS -> INNER key extraction over the composite-kernel key
            # envelope. ⭐ THE ENVELOPE IS NOT TRANSCRIBED HERE — it is
            # `komira_kernels.join_key_envelope`'s ONE table, read by
            # `_column_is_supported_key` below. This comment used to transcribe
            # it as "{INT64, FLOAT64, STRING, DICTIONARY}" and to name
            # "INT32/DATE/DECIMAL/BOOL" as the keys that still decline; the
            # INT32 half went FALSE when INT32 became a servable key and this
            # file was not moved with it.
            #
            # ⛔ AND THE COST OF THAT MISS WAS NOT A REFUSAL. Without the fold
            # the equi-conjunct stays `Filter(equi, CROSS)`: the plan asks for
            # the full N*M Cartesian product, not the clean refusal the comment
            # described.
            #
            # HISTORICAL: this call once used strict INT64-only defaults
            # because a single non-INT64 key routed through an
            # INT64-hardcoded single-key probe that crashed. That probe is not
            # in this tree.
            var remaining_pred = _extract_equi_keys(
                fd.predicate,
                jd.left[].output_schema,
                jd.right[].output_schema,
                left_keys,
                right_keys,
            )

            if len(left_keys) > 0:
                # Mutate JoinData in place: CROSS -> INNER, set keys.
                # SchemaBuilder result for CROSS and INNER joins is
                # identical (left + right columns), so the Join node's
                # output_schema does NOT need to change.
                plan._filter.value()[].child[]._join.value()[].join_type = JOIN_INNER
                plan._filter.value()[].child[]._join.value()[].left_on = left_keys^
                plan._filter.value()[].child[]._join.value()[].right_on = right_keys^

                if remaining_pred:
                    # Replace Filter's predicate with the residual.
                    var rem = remaining_pred.value().copy()
                    plan._filter.value()[].predicate = rem^
                else:
                    # No residual: the Filter node is now redundant.
                    # Replace plan with deep-copy of (now-INNER) Join.
                    var join_copy = _copy_plan(plan._filter.value()[].child[])
                    plan = join_copy^

        elif plan._filter.value()[].child[].tag == PLAN_JOIN and plan._filter.value()[].child[]._join.value()[].join_type == JOIN_INNER:
            # Equi-filter-into-INNER-join folding (bench-shape feature 1B).
            # If the Filter sits above an INNER join and contributes
            # additional bridging equi-conjuncts (l_col = r_col), append
            # them to the existing left_on/right_on lists so the join carries
            # a multi-key equi-key list (a composite hash-join probe). Conjuncts
            # that don't bridge stay in the Filter; if every conjunct
            # gets folded, the Filter node is eliminated.
            #
            # ⭐ THE KEY-TYPE ENVELOPE IS NOT AN ARGUMENT ANY MORE. This
            # call used to pass `allow_float64=True, allow_string=True,
            # allow_dict=True` — as did every other call site, which is what
            # made the three flags dead configuration. They are deleted;
            # `_column_is_supported_key` reads
            # `komira_kernels.join_key_envelope`'s ONE table, the table every
            # join-key gate is designed to read.
            #
            # THE INVARIANT THIS SITE STILL RELIES ON (unchanged by that): the
            # existing INNER join arrived with N >= 1 keys, so folding any
            # further conjunct yields N >= 2 and the multi-key composite path
            # by construction — never a single-key probe. The shapes it
            # unblocks are the natural compound joins:
            # `(country, currency)`, `(first_name, last_name)`,
            # `(region, currency)` over dict-encoded low-cardinality columns,
            # and q2's `(partkey, ps_supplycost)` with its FLOAT64 leg.
            # MOJO 1.0.0: bind the Filter once; a second `plan._filter` walk
            # in the call below would invalidate `ijd`.
            ref ifd = plan._filter.value()[]
            ref ijd = ifd.child[]._join.value()[]
            var add_left = List[String]()
            var add_right = List[String]()
            var remaining_inner = _extract_equi_keys(
                ifd.predicate,
                ijd.left[].output_schema,
                ijd.right[].output_schema,
                add_left,
                add_right,
            )

            if len(add_left) > 0:
                # Append the newly-extracted bridging keys to the
                # existing INNER join's key lists. The Join's
                # output_schema does NOT change (INNER-join schema is
                # left ∪ right regardless of the number of keys).
                for i in range(len(add_left)):
                    plan._filter.value()[].child[]._join.value()[].left_on.append(add_left[i])
                    plan._filter.value()[].child[]._join.value()[].right_on.append(add_right[i])

                if remaining_inner:
                    var rem2 = remaining_inner.value().copy()
                    plan._filter.value()[].predicate = rem2^
                else:
                    # All conjuncts folded -- drop the Filter node.
                    var join_copy2 = _copy_plan(plan._filter.value()[].child[])
                    plan = join_copy2^

        elif (
            plan._filter.value()[].child[].tag == PLAN_PROJECT
            and plan._filter.value()[].child[]._project.value()[].is_cse_introduced
            and plan._filter.value()[].child[]._project.value()[].child[].tag == PLAN_JOIN
            and plan._filter.value()[].child[]._project.value()[].child[]._join.value()[].join_type == JOIN_CROSS
        ):
            # Filter -> CSE-Project -> CROSS Join (TPC-H q19). A CSE pass designed
            # to run earlier (`eliminate_common_subexpressions`, not in this
            # tree) materializes a common OR-factor
            # (q19: `l_shipmode IN ('AIR','AIR REG')`, shared across the 3-branch
            # OR) into a synthetic `_cse_*` column via a passthrough Project
            # inserted DIRECTLY above the Join. That Project is a predicate-
            # pushdown BARRIER (the CSE synthetic exists ONLY above it), so
            # `push_predicates_down` parks the bridging equi-conjunct
            # (`l_partkey = p_partkey`) above it and it never reaches a
            # `Filter -> Join` adjacency. Without folding THROUGH the Project the
            # join stays CROSS: the plan asks for the full N*M Cartesian product
            # of lineitem and part.
            #
            # A CSE Project is a pure passthrough of EVERY original column plus
            # the synthetic `_cse_*` columns, so the equi-key columns (matched
            # against the JOIN's CHILD schemas below, exactly as the direct
            # `Filter -> Join` case does) flow through it unchanged -> folding
            # through it is semantics-preserving. The residual (if any) stays on
            # the Filter ABOVE the Project so it can still reference the `_cse_*`
            # synthetic. Only the CROSS shape is folded here (the q19 gap); an
            # INNER join under a CSE Project already has its keys.
            ref fd2 = plan._filter.value()[]
            ref jd2 = fd2.child[]._project.value()[].child[]._join.value()[]
            var left_keys2 = List[String]()
            var right_keys2 = List[String]()
            var remaining_cse = _extract_equi_keys(
                fd2.predicate,
                jd2.left[].output_schema,
                jd2.right[].output_schema,
                left_keys2,
                right_keys2,
            )

            if len(left_keys2) > 0:
                plan._filter.value()[].child[]._project.value()[].child[]._join.value()[].join_type = JOIN_INNER
                plan._filter.value()[].child[]._project.value()[].child[]._join.value()[].left_on = left_keys2^
                plan._filter.value()[].child[]._project.value()[].child[]._join.value()[].right_on = right_keys2^

                if remaining_cse:
                    var remc = remaining_cse.value().copy()
                    plan._filter.value()[].predicate = remc^
                else:
                    # No residual: drop the Filter, keep the (passthrough) CSE
                    # Project as the new root above the now-INNER join.
                    var proj_copy = _copy_plan(plan._filter.value()[].child[])
                    plan = proj_copy^

    elif plan.tag == PLAN_PROJECT:
        eliminate_cross_join_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        eliminate_cross_join_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        eliminate_cross_join_inplace(plan._join.value()[].left[])
        eliminate_cross_join_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        eliminate_cross_join_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        eliminate_cross_join_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        eliminate_cross_join_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        eliminate_cross_join_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


def _extract_equi_keys(
    pred: Expr,
    left_schema: Schema,
    right_schema: Schema,
    mut left_keys: List[String],
    mut right_keys: List[String],
) -> Optional[Expr]:
    """Extract equi-join keys from a predicate and return remaining conditions.

    Every `l_col = r_col` conjunct whose two columns are in the join's two
    CHILD schemas and whose key types are both in the composite join-key
    ENVELOPE is moved out of `pred` into `left_keys` / `right_keys`; whatever
    is left is returned as the residual predicate (None if nothing is left).

    ⭐ THE ENVELOPE IS ONE TABLE AND IT IS NOT A PARAMETER OF THIS FUNCTION.
    `_column_is_supported_key` reads `komira_kernels.join_key_envelope`, the
    table every join-key gate is designed to read. ⚠ THIS USED TO TAKE THREE MODE
    FLAGS — `allow_float64` / `allow_string` / `allow_dict`, defaulting to an
    "INT64 only" mode. All three call sites passed `True` for all three and
    the INT64-only mode had no caller: it was written for the era when a
    single non-INT64 key routed through an INT64-hardcoded single-key probe
    and crashed, and that probe is not in this tree. The flags are deleted —
    a per-type flag
    whose every caller passes the same value is a partial restatement of the
    table wearing a different shape, and this file's copy of that restatement
    is the one that went stale on INT32.

    ⛔ FOLDING IS NOT OPTIONAL FOR CORRECTNESS-AT-SCALE. Without the fold a
    STRING / FLOAT64 / DICT equi-join stays `Filter(equi, CROSS)`: the plan
    asks for the full N*M Cartesian product. That is why a key type this gate
    refuses but the join-key table ADMITS is a regression, not a missing
    feature; see `_column_is_supported_key`.

    HISTORICAL, kept because it names the defect that created the gate: q2's
    `ps_supplycost == min_cost` conjunct is FLOAT64, and before the multi-key
    kernel canonicalised floats, folding it crashed at runtime with "column is
    float64 but requested int64".

    Both callers fold into a join that ends with N >= 1 keys, and the
    Filter-above-INNER caller starts from N >= 1, so its result is N >= 2 and
    reaches the multi-key composite path by construction.
    """
    var conjuncts = ExprArray()
    _collect_and_conjuncts(pred.copy(), conjuncts)

    var remaining = ExprArray()
    for i in range(len(conjuncts)):
        var extracted = False

        if conjuncts[i].tag == EXPR_BINARY_OP and conjuncts[i].binary_op() == BIN_EQ:
            if conjuncts[i].binary_left_ref().tag == EXPR_COL_REF and conjuncts[i].binary_right_ref().tag == EXPR_COL_REF:
                var lname = conjuncts[i].binary_left_ref().col_ref_name()
                var rname = conjuncts[i].binary_right_ref().col_ref_name()

                # Classify each side against the join's two CHILD schemas. A
                # right-side reference may be presented as its `_right`-renamed
                # OUTPUT name (the SQL binder resolves a qualified
                # right key over a colliding join to the renamed name), so it is
                # mapped back to the right child's own-schema name via
                # `_right_child_orig` before being emitted as a join key
                # (`left_on`/`right_on` name each child's PRE-rename column).
                var l_is_left = _name_in_schema(lname, left_schema)
                var r_right_orig = _right_key_orig(rname, left_schema, right_schema)
                if l_is_left and r_right_orig:
                    var rkey = r_right_orig.value()
                    if (
                        _column_is_supported_key(lname, left_schema)
                        and _column_is_supported_key(rkey, right_schema)
                    ):
                        left_keys.append(lname)
                        right_keys.append(rkey)
                        extracted = True
                else:
                    # Swapped: the LEFT operand is the right-side key (possibly
                    # `_right`-renamed) and the RIGHT operand is the left key.
                    var r_is_left = _name_in_schema(rname, left_schema)
                    var l_right_orig = _right_key_orig(lname, left_schema, right_schema)
                    if r_is_left and l_right_orig:
                        var rkey2 = l_right_orig.value()
                        if (
                            _column_is_supported_key(rname, left_schema)
                            and _column_is_supported_key(rkey2, right_schema)
                        ):
                            left_keys.append(rname)
                            right_keys.append(rkey2)
                            extracted = True

        if not extracted:
            remaining.append(conjuncts[i].copy())

    if len(remaining) == 0:
        return None

    var result = remaining[0].copy()
    for i in range(1, len(remaining)):
        result = Expr.binary(BIN_AND, result^, remaining[i].copy())
    var opt: Optional[Expr] = result^
    return opt^


def _name_in_schema(name: String, schema: Schema) -> Bool:
    """Check if a column name exists in the given schema."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return True
    return False


def _right_child_orig(
    out_name: String, left_schema: Schema, right_schema: Schema
) -> Optional[String]:
    """Map a combined-join-OUTPUT column name back to the RIGHT child's ORIGINAL
    (pre-rename) column name, or None if `out_name` is not a right-side output.

    `LogicalPlan.join` renames a right column whose name COLLIDES with any LEFT
    output name to `name_right` in the OUTPUT schema, but stores `left_on` /
    `right_on` PRE-rename, naming columns of each child's own schema
    (logical_plan.mojo `join()`). This replays that exact single-suffix
    rename over `right_schema` (colliding against `left_schema`) and returns the
    right child's own-schema name when its output name equals `out_name`.

    WHY: the SQL binder's `BindScope` resolves a qualified
    right-side reference (`r.key` over `l JOIN r` whose keys collide) to the
    `_right`-renamed OUTPUT name. So an INNER/CROSS join whose ON folded into a
    WHERE equi-conjunct presents its right key as `key_right`. Without this
    reverse map the CROSS->INNER fold cannot match `key_right` against the right
    child schema (which holds `key`) and leaves the join a CROSS: the plan asks
    for the full N*M Cartesian product. Every colliding-key INNER join (`id1 =
    id1`, `key = key`) has this shape."""
    for i in range(right_schema.num_columns()):
        var c = String(right_schema.field_name(i))
        var collides = False
        for j in range(left_schema.num_columns()):
            if left_schema.field_name(j) == c:
                collides = True
                break
        var this_out = c + "_right" if collides else c
        if this_out == out_name:
            return Optional(String(c))
    return None


def _right_key_orig(
    name: String, left_schema: Schema, right_schema: Schema
) -> Optional[String]:
    """Resolve `name` (a predicate operand) to the RIGHT child's own column name
    if it references a right-side column, else None. Handles BOTH spellings a
    bridging equi-conjunct can use for the right key:

      1. the `_right`-renamed combined-OUTPUT name (the SQL binder's qualified
         resolution over a colliding join — `r.key` -> `key_right`), mapped back
         via `_right_child_orig`; and
      2. the right column's ORIGINAL name matched directly against the right
         child schema (an older binder dropped qualifiers, and hand-built IR
         plans reference the right key by its own name even when it collides with
         a left column — `id = id`).

    The rename map is tried FIRST so a genuine `_right` output name maps to the
    right child (not shadowed by a same-named left column); the direct match is
    the fallback that preserves the historical `id = id` colliding-name shape."""
    var via_rename = _right_child_orig(name, left_schema, right_schema)
    if via_rename:
        return via_rename^
    if _name_in_schema(name, right_schema):
        return Optional(String(name))
    return None


# ⛔ `_column_is_int64(name, schema)` USED TO LIVE HERE AND IS DELETED.
#
# It was a SIXTH statement of a join-key admission rule — "INT64 only",
# written for the era when every single-key hash-join probe hardcoded
# `as_primitive[DType.int64]` — and it had ZERO callers. The path it guarded went
# away with an earlier deletion. A dead rule that disagrees with the live
# one is the thing this unification exists to remove, so it goes rather than
# being re-pointed at the table.


def _column_is_supported_key(name: String, schema: Schema) -> Bool:
    """True iff the named column may be folded into an equi-join KEY.

    ⭐ READS THE ONE TABLE — `komira_kernels.join_key_envelope` — the table
    every join-key gate, including an executor's, is designed to read (the
    executor is not in this tree). THIS GATE AND THE EXECUTOR MUST AGREE, and
    the direction of a disagreement is not symmetric:

      * this gate REFUSING a key the executor serves is the expensive one. The
        equi-conjunct then stays `Filter(equi, CROSS)` and the plan asks for
        the full N*M Cartesian product. That is strictly worse than the
        refusal it stands in for, and it is exactly what happened when INT32
        became a servable key and this gate was never moved.
      * this gate ADMITTING a key the executor refuses turns a Cartesian into
        a loud decline.

    ⛔ THE PAIRING RULE IS DELIBERATELY NOT ENFORCED HERE. `join_key_envelope`
    also answers "may these two key types be joined to each other", and this
    gate does not ask it — even though both child schemas are in hand. That is
    not an oversight: a MISMATCHED pair (i64 ⋈ i32) declined HERE stays a
    Cartesian product, while the same pair folded and then declined at the
    EXECUTOR fails loud. The repo's standing decision is that a
    mismatched-DType equi-join fails loud, so the enforcement belongs to the
    executing caller (not in this tree), where a decline is audible, not here,
    where it is an allocation.

    ⚠ THE `allow_float64` / `allow_string` / `allow_dict` KWARGS ARE GONE.
    All call sites passed `True` for all three; the INT64-only mode the
    defaults described had no caller and named a single-key probe path the
    earlier deletion removed. A flag whose every caller passes the same
    value is a partial restatement of the table wearing a different shape.

    Returns False if the name is missing."""
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return join_key_admitted(JoinKeyType.of_schema_column(schema, i))
    return False
