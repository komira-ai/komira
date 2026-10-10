# =============================================================================
# Optimizer projection rules — pushdown, pruning, merge, identity elimination,
# bypass detection, late materialization
# =============================================================================
#
# Rule 3: Projection pushdown — push projection lists to Scan nodes
# Rule 4: Column pruning — remove unreferenced columns from projections
# Rule 12: Map/expression merge — merge consecutive Project nodes
# Rule 16: Eliminate identity projections — remove pass-through Projects
# Rule 15: Bypass detection — detect columns eligible for raw copy
# Rule 20: Late materialization — narrow a Filter's scan to the filter columns
# =============================================================================

from std.collections import Set
from std.memory import OwnedPointer

from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
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
)
from komira_plan_stats.table_stats import TableStats
from komira_plan_ir.plan_helpers import (
    _copy_schema,
    _copy_expr_array,
    _copy_agg_expr_array,
    _copy_plan,
    _copy_set,
    _union_sets,
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

from .optimizer_project_merge_guard import (
    projects_merge_safely, substitute_project_refs,
)


# =============================================================================
# Helper: route a residual-carrying join's residual column references to the
# left / right child column sets.
# =============================================================================
#
# A `predicate=` join (`JoinData.residual`) carries a residual Expr whose
# col-refs name columns of the JOINED-ROW schema (left cols keep their names,
# right cols are `_right`-suffixed on collision with a left name — the
# `LogicalPlan.join` schema-builder convention). Projection pushdown / column
# pruning must keep those columns alive in the appropriate child, or the
# residual names a column the narrowed children no longer produce when it is
# evaluated over the joined rows.


def _strip_right_suffix_nr(name: String) -> String:
    """Strip a trailing `_right` from `name` (byte loop; the same result as
    `komira_column_kernels.compiler_helpers.strip_right_suffix`)."""
    var n = name.byte_length()
    if n <= 6:
        return name
    var ptr = name.unsafe_ptr()
    # SAFETY: `n > 6` was checked above, so `ptr[n - 6]` .. `ptr[n - 1]` and
    # `ptr[0]` .. `ptr[n - 7]` are in-bounds byte reads of `name`'s storage,
    # which outlives `ptr` (no use after this function returns).
    if not (
        ptr[n - 6] == UInt8(ord("_"))
        and ptr[n - 5] == UInt8(ord("r"))
        and ptr[n - 4] == UInt8(ord("i"))
        and ptr[n - 3] == UInt8(ord("g"))
        and ptr[n - 2] == UInt8(ord("h"))
        and ptr[n - 1] == UInt8(ord("t"))
    ):
        return name
    var result = String("")
    for i in range(n - 6):
        result += chr(Int(ptr[i]))
    return result^


def _collect_join_residual_side_columns(
    plan: LogicalPlan, mut left_cols: Set[String], mut right_cols: Set[String],
):
    """If `plan` (a PLAN_JOIN) carries a residual, collect its col-refs and
    route each to `left_cols` / `right_cols` by joined-row name."""
    if not plan._join.value()[].has_residual():
        return
    var residual_cols = Set[String]()
    _collect_expr_columns(plan._join.value()[].residual.value()[], residual_cols)
    # Build a Set of left-input column names for collision-aware routing.
    var left_names = Set[String]()
    ref left_schema = plan._join.value()[].left[].output_schema
    for i in range(left_schema.num_columns()):
        left_names.add(left_schema.field_name(i))
    for name in residual_cols:
        if name in left_names:
            # Either a genuine left column, or (rare) a right column whose
            # un-suffixed name happens to collide — keep it on BOTH sides to
            # be safe (over-keeping a column is harmless; under-keeping crashes).
            left_cols.add(name)
            var stripped = _strip_right_suffix_nr(name)
            if stripped != name:
                right_cols.add(stripped^)
        else:
            var stripped = _strip_right_suffix_nr(name)
            # `stripped != name` means it had a `_right` suffix → it's a
            # right column collision-renamed; keep the original name on the
            # right child. Otherwise it's a plain right column.
            if stripped != name:
                right_cols.add(stripped^)
            else:
                right_cols.add(name)



# =============================================================================
# Rule 3: Projection Pushdown
# =============================================================================

def push_projections_down(var plan: LogicalPlan) raises -> LogicalPlan:
    """Push projection lists down to Scan nodes.

    Initializes the needed set from the root plan's output schema. This
    ensures pass-through operators (Sort, Limit, TopN, Distinct) propagate
    all columns the user expects in the output. Schema-changing operators
    (Aggregate, Project) override the needed set for their children, so the
    root initialization only matters for the outermost pass-through chain.

    Each scan is narrowed to the columns its own consumers need: two
    structurally identical subtrees under different consumers get different
    projections.
    """
    var root_needed = Set[String]()
    # Start with ALL columns from the root plan's output schema.
    # This ensures pass-through operators don't accidentally prune columns.
    for i in range(plan.output_schema.num_columns()):
        root_needed.add(plan.output_schema.field_name(i))
    return _push_projections_impl(plan^, root_needed^)


def _push_projections_impl(
    var plan: LogicalPlan, var needed: Set[String]
) raises -> LogicalPlan:
    """Internal: push projections with a known set of needed columns."""

    if plan.tag == PLAN_SCAN:
        # Set projection to only include needed columns that exist in the schema.
        # Also include columns referenced by the scan's pushed-down filter.
        var filter_cols = Set[String]()
        if plan._scan.value()[].filter:
            _collect_expr_columns(plan._scan.value()[].filter.value(), filter_cols)

        var proj = List[String]()
        for i in range(plan.output_schema.num_columns()):
            var col_name = plan.output_schema.field_name(i)
            if col_name in needed or col_name in filter_cols:
                proj.append(col_name)
        if len(proj) == plan.output_schema.num_columns():
            return plan^
        if len(proj) == 0:
            return plan^
        var filter_copy: Optional[Expr] = None
        if plan._scan.value()[].filter:
            filter_copy = plan._scan.value()[].filter.value().copy()
        var full_schema: Schema
        if plan._scan.value()[].schema:
            full_schema = _copy_schema(plan._scan.value()[].schema.value())
        else:
            full_schema = _copy_schema(plan.output_schema)
        var proj_opt: Optional[List[String]] = proj^
        var rc_opt: Optional[Int] = None
        if plan._scan.value()[].row_count:
            rc_opt = plan._scan.value()[].row_count.value()
        var ts_opt: Optional[TableStats] = None
        if plan._scan.value()[].table_stats:
            ts_opt = Optional[TableStats](plan._scan.value()[].table_stats.value().copy())
        # Rebuild via `scan_from_source` so the SourceVariant (including an
        # in-memory source's inline batch) carries over; the positional
        # `LogicalPlan.scan(source_path, source_type, ...)` would lose the
        # inline batch. `SourceVariant.copy()` is a refcount-bump on the
        # ArcPointer payload (no buffer byte-copy).
        var src_copy = plan._scan.value()[].source.copy()
        # Preserve the scan's `source_kind` across this rebuild: without it,
        # `scan_from_source` would reset the kind to its default.
        var src_kind = plan._scan.value()[].source_kind
        return LogicalPlan.scan_from_source(
            src_copy^,
            full_schema^,
            proj_opt^,
            filter_copy^,
            rc_opt^,
            ts_opt^,
            src_kind,
        )

    # Non-SCAN cases mutate the parent's child OwnedPointer in
    # place instead of rebuilding the parent wrapper Schema. The SCAN
    # case (above) still rebuilds because we narrow its projection.
    # The recursive call still consumes a deep-copied child (partial-
    # move ban), but the parent LogicalPlan node is reused.
    elif plan.tag == PLAN_FILTER:
        var pred_cols = Set[String]()
        _collect_expr_columns(plan._filter.value()[].predicate, pred_cols)
        var combined = _union_sets(needed, pred_cols)
        var child_in = _copy_plan(plan._filter.value()[].child[])
        var new_child = _push_projections_impl(child_in^, combined^)
        plan._filter.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_PROJECT:
        # Intersect with `needed` AND drop dead project exprs.
        #
        # Collecting source columns from ALL of the project's exprs would
        # ignore the parent's `needed` set: with `with_column` (N
        # pass-through col_refs + 1 derived), all N source columns would
        # flow to the SCAN even when the parent selects only the derived
        # column.
        #
        # Correctness requirement: when we narrow the source columns we
        # MUST also drop the project's now-dead pass-through exprs. A
        # consumer that looks up each col_ref by name in the (narrowed)
        # child's output schema would otherwise fail on a dead
        # `col(l_orderkey)` once the scan is narrowed to
        # {l_extendedprice, l_discount}.
        #
        # Strategy: count how many output cols the parent needs. If all
        # cols are needed, take the fast path and keep the in-place mutation
        # idiom. If none are needed (degenerate corner-case from an empty
        # `needed` set), also leave the project untouched. Otherwise, build
        # a narrowed expr list + rebuild the Project node so its
        # output_schema is re-derived to match the new expr list.

        var num_exprs = len(plan._project.value()[].exprs)
        var keep_count = 0
        for i in range(num_exprs):
            if plan.output_schema.field_name(i) in needed:
                keep_count += 1

        if keep_count == num_exprs or keep_count == 0:
            # Fast path / degenerate path: keep all exprs.
            var proj_cols = Set[String]()
            for i in range(num_exprs):
                _collect_expr_columns(plan._project.value()[].exprs[i], proj_cols)
            var child_in = _copy_plan(plan._project.value()[].child[])
            var new_child = _push_projections_impl(child_in^, proj_cols^)
            plan._project.value()[].child = OwnedPointer(new_child^)
        else:
            # Narrowing path: build a new ExprArray with only the surviving
            # exprs (those at indices where output_schema.field_name(i) is
            # in `needed`). Then rebuild the Project node entirely so the
            # output schema is re-derived to match the new expr list.
            var new_exprs = ExprArray()
            var new_proj_cols = Set[String]()
            for i in range(num_exprs):
                if plan.output_schema.field_name(i) in needed:
                    new_exprs.append(plan._project.value()[].exprs[i].copy())
                    _collect_expr_columns(plan._project.value()[].exprs[i], new_proj_cols)
            var child_in = _copy_plan(plan._project.value()[].child[])
            var new_child = _push_projections_impl(child_in^, new_proj_cols^)
            return LogicalPlan.project(new_exprs^, new_child^)

    elif plan.tag == PLAN_AGGREGATE:
        var agg_cols = Set[String]()
        for i in range(len(plan._aggregate.value()[].group_by)):
            _collect_expr_columns(plan._aggregate.value()[].group_by[i], agg_cols)
        for i in range(len(plan._aggregate.value()[].agg_exprs)):
            # AggExpr has up to 4 children (child / child1 / child2 /
            # child3) for multi-arg aggs like AGG_CORR(v1, v2). Every slot
            # is walked: walking only `child` (slot 0) would drop slot-1+
            # columns from the Scan projection.
            if plan._aggregate.value()[].agg_exprs[i].child:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child.value(), agg_cols)
            if plan._aggregate.value()[].agg_exprs[i].child1:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child1.value(), agg_cols)
            if plan._aggregate.value()[].agg_exprs[i].child2:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child2.value(), agg_cols)
            if plan._aggregate.value()[].agg_exprs[i].child3:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child3.value(), agg_cols)
        var child_in = _copy_plan(plan._aggregate.value()[].child[])
        var new_child = _push_projections_impl(child_in^, agg_cols^)
        plan._aggregate.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_JOIN:
        var left_cols = Set[String]()
        var right_cols = Set[String]()
        for key in plan._join.value()[].left_on:
            left_cols.add(key)
        for key in plan._join.value()[].right_on:
            right_cols.add(key)
        # COLLISION-RENAME INVERSION. `needed` holds JOINED-ROW names, and the
        # join output spells a RIGHT column whose name COLLIDES with a left name
        # as `<name>_right` (`LogicalPlan.join`). Routing that joined-row spelling
        # VERBATIM into `right_cols` asks the right child for a column it does not
        # have, so the right scan's pushed projection silently drops the REAL
        # column: a self-join `join(read(P), read(P), on=k)` would narrow its
        # right side to the key alone and emit NO `v_right` at all. Invert the
        # rename: prefer the literal name when the right child really carries it,
        # else the `_right`-stripped name when the right child carries THAT. This
        # mirrors `_collect_join_residual_side_columns`, which inverts the rename
        # for the residual path. A right child with an empty output schema keeps
        # the literal name; and a non-colliding join (every needed name either in
        # the left schema or literally in the right schema) is untouched.
        var right_names = Set[String]()
        for i in range(plan._join.value()[].right[].output_schema.num_columns()):
            right_names.add(
                plan._join.value()[].right[].output_schema.field_name(i)
            )
        for col_name in needed:
            var in_left = False
            for i in range(plan._join.value()[].left[].output_schema.num_columns()):
                if plan._join.value()[].left[].output_schema.field_name(i) == col_name:
                    in_left = True
                    break
            if in_left:
                left_cols.add(col_name)
            elif col_name in right_names:
                right_cols.add(col_name)
            else:
                var stripped = _strip_right_suffix_nr(col_name)
                if stripped != col_name and stripped in right_names:
                    right_cols.add(stripped^)
                else:
                    right_cols.add(col_name)
        # Keep the residual's referenced columns alive in the right child /
        # left child (the residual eval needs them).
        _collect_join_residual_side_columns(plan, left_cols, right_cols)

        # ⚠ COLLISION *PRESERVATION* — the other half of the inversion above,
        # and the half that makes the join's OUTPUT NAMING invariant under this
        # pass.
        #
        # `<name>_right` is not a name the right child carries. It is what
        # `LogicalPlan.join` SPELLS a right column as WHEN IT COLLIDES with a
        # left one — so the spelling is a function of BOTH children's name sets,
        # and narrowing is monotone: pruning can only ever DESTROY a collision,
        # never create one. Prune the colliding LEFT twin and the very same
        # right column leaves the join spelled `<name>` instead of
        # `<name>_right`, while every reference ABOVE the join was bound against
        # the OLD spelling and now names nothing.
        #
        # Example, `SELECT x.id, y.qty FROM door x, door y` over one 2-column
        # table, without this block:
        #
        #   BOUND      JOIN out=[id,qty,id_right,qty_right]  L=[id,qty] R=[id,qty]
        #   OPTIMIZED  JOIN out=[id,qty]                     L=[id]     R=[qty]
        #                             ^ `qty` stopped colliding, so it lost its
        #                               `_right`; the Project above still says
        #                               `ColRef(qty_right)`, which names no
        #                               column of the join.
        #
        # KEEP THE COLLISION RATHER THAN REWRITE THE REFERENCES. A rename map
        # would have to be threaded up through every parent shape this pass can
        # sit under; the collision is local, and re-adding the left twin costs
        # ONE extra column read in exactly the shape where a `_right` name is
        # referenced at all. Idempotent — `prune_columns` re-runs this pass and
        # recomputes the same set.
        #
        # SEMI/ANTI are excluded because their output is left-only: no right
        # column reaches the parent, so none can be renamed. Same guard
        # `LogicalPlan.join`'s own schema-builder uses.
        var jt_preserve = plan._join.value()[].join_type
        if jt_preserve != JOIN_SEMI and jt_preserve != JOIN_ANTI:
            var left_names_now = Set[String]()
            for i in range(
                plan._join.value()[].left[].output_schema.num_columns()
            ):
                left_names_now.add(
                    plan._join.value()[].left[].output_schema.field_name(i)
                )
            # Collect first, mutate after — `left_cols` must not be written
            # while `right_cols` is being iterated.
            var twins = List[String]()
            for r in right_cols:
                # Only a column the right child ACTUALLY carries can reach the
                # join output, and only one the left child also carries is
                # subject to the rename.
                if r in right_names and r in left_names_now:
                    twins.append(String(r))
            for i in range(len(twins)):
                left_cols.add(String(twins[i]))

        var left_in = _copy_plan(plan._join.value()[].left[])
        var right_in = _copy_plan(plan._join.value()[].right[])
        var new_left = _push_projections_impl(left_in^, left_cols^)
        var new_right = _push_projections_impl(right_in^, right_cols^)
        plan._join.value()[].left = OwnedPointer(new_left^)
        plan._join.value()[].right = OwnedPointer(new_right^)

    elif plan.tag == PLAN_SORT:
        var sort_cols = _copy_set(needed)
        for key in plan._sort.value()[].keys:
            sort_cols.add(key)
        var child_in = _copy_plan(plan._sort.value()[].child[])
        var new_child = _push_projections_impl(child_in^, sort_cols^)
        plan._sort.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_LIMIT:
        var child_in = _copy_plan(plan._limit.value()[].child[])
        var new_child = _push_projections_impl(child_in^, needed^)
        plan._limit.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_DISTINCT:
        # Distinct must extend the `needed` set with its OWN key columns
        # before recursing — symmetric to SORT (above) and TOPN
        # (below). When upstream `needed` is a strict subset of
        # Distinct's keys (e.g. Aggregate(group_by=[k1]) above
        # Distinct([k1, k2])), recursing with `needed` unchanged would
        # narrow the scan and prune Distinct's other keys, which a Distinct
        # evaluated as Aggregate(group_by=[k1, k2]) still reads.
        # When `columns is None` (DISTINCT *), Distinct dedups over the
        # child's full output schema, so we must keep every child column.
        var dist_cols = _copy_set(needed)
        if plan._distinct.value()[].columns:
            for c in plan._distinct.value()[].columns.value():
                dist_cols.add(c)
        else:
            ref child_schema = plan._distinct.value()[].child[].output_schema
            for i in range(child_schema.num_columns()):
                dist_cols.add(child_schema.field_name(i))
        var child_in = _copy_plan(plan._distinct.value()[].child[])
        var new_child = _push_projections_impl(child_in^, dist_cols^)
        plan._distinct.value()[].child = OwnedPointer(new_child^)

    elif plan.tag == PLAN_TOPN:
        var topn_cols = _copy_set(needed)
        for key in plan._topn.value()[].keys:
            topn_cols.add(key)
        var child_in = _copy_plan(plan._topn.value()[].child[])
        var new_child = _push_projections_impl(child_in^, topn_cols^)
        plan._topn.value()[].child = OwnedPointer(new_child^)

    return plan^


def _collect_referenced_columns(plan: LogicalPlan, mut cols: Set[String]):
    """Collect all column names referenced by operators in the plan tree.

    The Scan node is a leaf that PROVIDES columns, not uses them. We only
    collect columns from its pushed-down filter (if any), NOT from its
    output schema. This allows projection pushdown to narrow the Scan's
    projection to only the columns actually needed by upstream operators.
    """
    if plan.tag == PLAN_SCAN:
        # Only collect columns referenced by the scan's pushed-down filter.
        # Do NOT add all output schema columns -- that defeats pushdown.
        if plan._scan.value()[].filter:
            _collect_expr_columns(plan._scan.value()[].filter.value(), cols)

    elif plan.tag == PLAN_FILTER:
        _collect_expr_columns(plan._filter.value()[].predicate, cols)
        _collect_referenced_columns(plan._filter.value()[].child[], cols)

    elif plan.tag == PLAN_PROJECT:
        for i in range(len(plan._project.value()[].exprs)):
            _collect_expr_columns(plan._project.value()[].exprs[i], cols)
        _collect_referenced_columns(plan._project.value()[].child[], cols)

    elif plan.tag == PLAN_AGGREGATE:
        for i in range(len(plan._aggregate.value()[].group_by)):
            _collect_expr_columns(plan._aggregate.value()[].group_by[i], cols)
        for i in range(len(plan._aggregate.value()[].agg_exprs)):
            # Walk all 4 children for multi-arg aggs (CORR uses slot 0 +
            # slot 1).
            if plan._aggregate.value()[].agg_exprs[i].child:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child.value(), cols)
            if plan._aggregate.value()[].agg_exprs[i].child1:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child1.value(), cols)
            if plan._aggregate.value()[].agg_exprs[i].child2:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child2.value(), cols)
            if plan._aggregate.value()[].agg_exprs[i].child3:
                _collect_expr_columns(plan._aggregate.value()[].agg_exprs[i].child3.value(), cols)
        _collect_referenced_columns(plan._aggregate.value()[].child[], cols)

    elif plan.tag == PLAN_JOIN:
        for key in plan._join.value()[].left_on:
            cols.add(key)
        for key in plan._join.value()[].right_on:
            cols.add(key)
        # A residual-carrying join references columns by joined-row
        # name; add both the literal names AND their `_right`-stripped forms
        # so a downstream scan-narrowing pass keeps them.
        if plan._join.value()[].has_residual():
            var residual_cols = Set[String]()
            _collect_expr_columns(plan._join.value()[].residual.value()[], residual_cols)
            for name in residual_cols:
                cols.add(name)
                var stripped = _strip_right_suffix_nr(name)
                if stripped != name:
                    cols.add(stripped^)
        _collect_referenced_columns(plan._join.value()[].left[], cols)
        _collect_referenced_columns(plan._join.value()[].right[], cols)

    elif plan.tag == PLAN_SORT:
        for key in plan._sort.value()[].keys:
            cols.add(key)
        _collect_referenced_columns(plan._sort.value()[].child[], cols)

    elif plan.tag == PLAN_LIMIT:
        _collect_referenced_columns(plan._limit.value()[].child[], cols)

    elif plan.tag == PLAN_DISTINCT:
        if plan._distinct.value()[].columns:
            for c in plan._distinct.value()[].columns.value():
                cols.add(c)
        _collect_referenced_columns(plan._distinct.value()[].child[], cols)

    elif plan.tag == PLAN_TOPN:
        for key in plan._topn.value()[].keys:
            cols.add(key)
        _collect_referenced_columns(plan._topn.value()[].child[], cols)


# =============================================================================
# Rule 4: Column Pruning
# =============================================================================

def prune_columns(var plan: LogicalPlan) raises -> LogicalPlan:
    """Remove unreferenced columns from scan projections.

    This is a simplified version that re-applies projection pushdown.
    """
    return push_projections_down(plan^)


# =============================================================================
# Rule 16: Eliminate Identity Projections
# =============================================================================

def eliminate_identity_projects(var plan: LogicalPlan) raises -> LogicalPlan:
    """Remove no-op Project nodes that pass all columns through unchanged.

    Wrapper around `eliminate_identity_projects_inplace` for callers that
    hold the plan by value.
    """
    eliminate_identity_projects_inplace(plan)
    return plan^


def eliminate_identity_projects_inplace(mut plan: LogicalPlan) raises:
    """In-place identity-project elimination.

    Recurses children IN PLACE. When a Project is detected as an identity
    projection, the Project node is replaced by its child. The child must
    be deep-copied because partial-moving an `OwnedPointer[LogicalPlan]`
    field out of the variant Data struct is forbidden (the pointer rules)
    -- so we pay one `_copy_plan` on the elimination path only. All NON-elimination paths skip the rebuild entirely.
    """
    if plan.tag == PLAN_PROJECT:
        # Recurse into the child first (bottom-up).
        eliminate_identity_projects_inplace(plan._project.value()[].child[])

        # Check identity: same arity AND each expression is a ColRef whose
        # name matches the child's output column at the same position.
        ref pd_one = plan._project.value()[]
        ref child_ref = pd_one.child[]
        ref proj_exprs = pd_one.exprs
        var is_identity = True
        if len(proj_exprs) != child_ref.output_schema.num_columns():
            is_identity = False
        else:
            for i in range(len(proj_exprs)):
                if proj_exprs[i].tag != EXPR_COL_REF:
                    is_identity = False
                    break
                if proj_exprs[i].col_ref_name() != child_ref.output_schema.field_name(i):
                    is_identity = False
                    break

        if is_identity:
            # Replace `plan` with a deep copy of the child. _copy_plan is
            # the only safe primitive that survives the partial-move ban
            # on the child's OwnedPointer field. Common case (non-identity)
            # avoids this cost entirely -- only fires when the rule applies.
            var child_copy = _copy_plan(plan._project.value()[].child[])
            plan = child_copy^

    elif plan.tag == PLAN_FILTER:
        eliminate_identity_projects_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        eliminate_identity_projects_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        eliminate_identity_projects_inplace(plan._join.value()[].left[])
        eliminate_identity_projects_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        eliminate_identity_projects_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        eliminate_identity_projects_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        eliminate_identity_projects_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        eliminate_identity_projects_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected by this rule. Leave unchanged.


# =============================================================================
# Rule 12: Map/Expression Merge
# =============================================================================

def merge_projects(var plan: LogicalPlan) raises -> LogicalPlan:
    """Merge consecutive Project nodes into a single Project.

    Wrapper around `merge_projects_inplace` for callers that hold the plan
    by value.
    """
    merge_projects_inplace(plan)
    return plan^


def merge_projects_inplace(mut plan: LogicalPlan) raises:
    """In-place project merging.

    Recurses children IN PLACE. The merge case (Project above Project)
    must rebuild because the outer Project's expressions change AND the
    intermediate Project node is dropped. We deep-copy the grandchild
    on that path to satisfy the partial-move ban on the OwnedPointer
    field. The common non-merge walk skips the rebuild entirely.
    """
    if plan.tag == PLAN_PROJECT:
        # Recurse into the child first.
        merge_projects_inplace(plan._project.value()[].child[])

        if plan._project.value()[].child[].tag == PLAN_PROJECT:
            # Pattern: Project(outer_exprs, Project(inner_exprs, gc))
            # Rebuild as: Project(substituted_exprs, gc)
            # One walk of the outer ProjectData, projected.
            ref opd = plan._project.value()[]
            ref outer_exprs = opd.exprs
            ref inner_pd = opd.child[]._project.value()[]
            ref inner_exprs = inner_pd.exprs

            var inner_names = List[String]()
            ref inner_schema = opd.child[].output_schema
            for i in range(inner_schema.num_columns()):
                inner_names.append(inner_schema.field_name(i))

            # ⛔ The substitution (`optimizer_project_merge_guard`) cannot
            # rewrite every node -- a window's input is a column NAME -- and an
            # outer expression reading an inner COMPUTED column under such a
            # node would dangle over the grandchild ("no field named 'v2'"), or
            # read a REPLACED column's original (a silent wrong answer). Leave
            # both standing.
            if not projects_merge_safely(outer_exprs, inner_names, inner_exprs):
                return

            var merged_exprs = ExprArray()
            for i in range(len(outer_exprs)):
                var outer_expr = outer_exprs[i].copy()
                var substituted = substitute_project_refs(
                    outer_expr^, inner_names, inner_exprs
                )
                merged_exprs.append(substituted^)

            # Deep-copy the grandchild (partial-move ban on OwnedPointer
            # field). Replace plan's exprs in place; replace plan's child
            # OwnedPointer with a fresh one wrapping the gc copy.
            var gc_copy = _copy_plan(plan._project.value()[].child[]._project.value()[].child[])
            plan._project.value()[].exprs = merged_exprs^
            plan._project.value()[].child = OwnedPointer(gc_copy^)

    elif plan.tag == PLAN_FILTER:
        merge_projects_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        merge_projects_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        merge_projects_inplace(plan._join.value()[].left[])
        merge_projects_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        merge_projects_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        merge_projects_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        merge_projects_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        merge_projects_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.


# =============================================================================
# Rule 15: Bypass Detection
# =============================================================================

def detect_bypass_columns(var plan: LogicalPlan) -> LogicalPlan:
    """Detect pass-through columns eligible for bypass optimization.

    Returns the plan unchanged: the collected set is discarded.
    """
    var bypass_cols = Set[String]()
    _collect_bypass_columns(plan, bypass_cols)
    return plan^


def _collect_bypass_columns(plan: LogicalPlan, mut bypass: Set[String]):
    """Collect column names that pass through Project nodes unchanged."""
    if plan.tag == PLAN_PROJECT:
        for i in range(len(plan._project.value()[].exprs)):
            if plan._project.value()[].exprs[i].tag == EXPR_COL_REF:
                bypass.add(plan._project.value()[].exprs[i].col_ref_name())
            elif plan._project.value()[].exprs[i].tag == EXPR_ALIAS:
                if plan._project.value()[].exprs[i].alias_child_ref().tag == EXPR_COL_REF:
                    var inner_name = plan._project.value()[].exprs[i].alias_child_ref().col_ref_name()
                    var alias_nm = plan._project.value()[].exprs[i].alias_name()
                    if inner_name == alias_nm:
                        bypass.add(inner_name)
        _collect_bypass_columns(plan._project.value()[].child[], bypass)

    elif plan.tag == PLAN_FILTER:
        _collect_bypass_columns(plan._filter.value()[].child[], bypass)

    elif plan.tag == PLAN_AGGREGATE:
        _collect_bypass_columns(plan._aggregate.value()[].child[], bypass)

    elif plan.tag == PLAN_JOIN:
        _collect_bypass_columns(plan._join.value()[].left[], bypass)
        _collect_bypass_columns(plan._join.value()[].right[], bypass)

    elif plan.tag == PLAN_SORT:
        _collect_bypass_columns(plan._sort.value()[].child[], bypass)

    elif plan.tag == PLAN_LIMIT:
        _collect_bypass_columns(plan._limit.value()[].child[], bypass)

    elif plan.tag == PLAN_DISTINCT:
        _collect_bypass_columns(plan._distinct.value()[].child[], bypass)

    elif plan.tag == PLAN_TOPN:
        _collect_bypass_columns(plan._topn.value()[].child[], bypass)


# =============================================================================
# Rule 20: Late Materialization
# =============================================================================

def late_materialize(var plan: LogicalPlan) -> LogicalPlan:
    """Defer reading non-filter columns until after the filter reduces row count.

    When a Filter node sits directly on a Scan, this rule ensures the Scan
    only reads the columns needed by the filter predicate. After the filter
    eliminates rows, remaining columns are read in a subsequent step.

    Implementation: when Filter -> Scan, restrict the Scan's projection
    to only the columns referenced by the filter predicate. If the Scan
    already has a projection that is a subset of the filter columns, leave
    it unchanged (Rule 3 projection pushdown may have already handled this).

    This complements Rule 3 (projection pushdown) by focusing specifically
    on the filter-scan boundary. If the scan's existing projection already
    includes only filter columns, this rule is a no-op.

    Wrapper around `late_materialize_inplace` for callers that hold the plan
    by value.
    """
    late_materialize_inplace(plan)
    return plan^


def late_materialize_inplace(mut plan: LogicalPlan):
    """In-place late materialization.

    Recurses children IN PLACE. The Filter+Scan rewrite mutates the
    Scan's projection field directly without rebuilding the Scan node.
    """
    if plan.tag == PLAN_FILTER:
        late_materialize_inplace(plan._filter.value()[].child[])

        # When Filter sits on a Scan, restrict scan to filter columns IN PLACE.
        #
        # Only do this when the scan's Source can actually absorb the
        # predicate into its scan (`supports_filter_pushdown`). After
        # per-conjunct pushdown, a Filter that survives directly over a Scan
        # means the Source REJECTED the push (a Parquet OR-tree, a CSV source,
        # etc.) — the Filter then runs ABOVE the scan, so the scan must surface
        # ALL the columns the Filter (and everything above it) needs;
        # restricting the scan's projection to just the filter columns would
        # drop columns the rest of the plan requires (e.g. the join-key column
        # of a semi-join above). When the Source DOES support the push,
        # `push_predicates_down` has already folded the predicate into
        # `Scan.filter` and there is no Filter node here, so this branch is
        # normally unreached for pushable predicates.
        # One walk of the FilterData: a re-walk inside the `and` below would
        # form separate origins over the same storage.
        ref pfd = plan._filter.value()[]
        if pfd.child[].tag == PLAN_SCAN \
           and pfd.child[]._scan.value()[].source.supports_filter_pushdown(
               pfd.predicate
           ):
            var filter_cols = Set[String]()
            _collect_expr_columns(pfd.predicate, filter_cols)

            # Check if scan already has a restricted projection
            ref scan_data = pfd.child[]._scan.value()[]
            var already_restricted = False
            if scan_data.projection:
                if len(scan_data.projection.value()) <= len(filter_cols):
                    already_restricted = True

            if not already_restricted and len(filter_cols) > 0:
                # Get the full schema (before projection)
                var full_schema: Schema
                if scan_data.schema:
                    full_schema = _copy_schema(scan_data.schema.value())
                else:
                    full_schema = _copy_schema(plan._filter.value()[].child[].output_schema)

                # Build projection with only filter columns, preserving the
                # full_schema column order.
                var filter_proj = List[String]()
                for i in range(full_schema.num_columns()):
                    var col_name = full_schema.field_name(i)
                    if col_name in filter_cols:
                        filter_proj.append(col_name)

                # Only apply if this actually reduces the columns
                if len(filter_proj) < full_schema.num_columns() and len(filter_proj) > 0:
                    # Mutate the scan's projection in place. Schema /
                    # filter / row_count / source_path / source_type
                    # are all unchanged.
                    var proj_opt: Optional[List[String]] = filter_proj^
                    plan._filter.value()[].child[]._scan.value()[].projection = proj_opt^

    elif plan.tag == PLAN_PROJECT:
        late_materialize_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        late_materialize_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        late_materialize_inplace(plan._join.value()[].left[])
        late_materialize_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        late_materialize_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        late_materialize_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        late_materialize_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        late_materialize_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # not affected. Leave unchanged.
