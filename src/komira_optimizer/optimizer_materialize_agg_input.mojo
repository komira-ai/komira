# =============================================================================
# Optimizer rule: materialize derived agg inputs
# =============================================================================
#
# Shapes this rule rewrites:
#   `agg(sum(col("a") * col("b")))`      — user writes binop directly, OR
#   `with_column(a*b alias x).agg(sum(col("x")))` after the
#   `absorb_expression_into_aggregate` rule folds the with_column away.
#   `agg(corr(col("a") * 2.0, col("b")))` — bivariate agg with derived
#   slot 1 (or any of the higher slots).
#
# Both shapes leave one or more AggExpr child slots as non-col-ref
# expressions. A consumer that resolves each agg child with
# `resolve_col_index(child, schema)` (`komira_column_kernels.compiler_helpers`)
# rejects anything that isn't a col-ref / col-idx / alias-of-col-ref with:
#   "PipelineCompiler: cannot resolve column index from expression tag: <N>"
#
# Fix: at every PLAN_AGGREGATE, scan agg_exprs[].child0..child3. For each
# non-trivial child slot, mint a fresh name `__agg_in_<n>`, replace the
# agg's slot with `col_ref(fresh_name)`, and insert a Project node between
# the aggregate and its existing child to materialize the derived
# expression as a real column.
#
# Slot coverage:
#   - slot 0 (`child`): unary aggs (SUM, COUNT, MIN, MAX, MEAN, STDDEV_SAMP).
#   - slot 1 (`child1`): bivariate aggs (CORR, COVAR).
#   - slot 2 (`child2`) / slot 3 (`child3`): aggs with three or four inputs.
# All 4 slots scanned uniformly; empty (None) slots skipped cleanly.
#
# This rule MUST run AFTER `absorb_expression_into_aggregate` because absorb
# is what creates the failure shape in the with_column case. Running this
# rule afterwards re-introduces the project — but with all derived
# expressions consolidated into a single project (rather than the original
# user-written `with_column(...)` which emits N pass-throughs + 1 derived).
# =============================================================================

from std.memory import OwnedPointer

from komira_arrow.schema import Schema, Field
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_ALIAS,
)
from komira_plan_expr.agg_expr import AggExpr
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
)
from komira_plan_ir.plan_helpers import _copy_plan

# The project-merge rule, reused: a Project this rule splices in over a
# Project is folded into one (see `_maybe_insert_materialize_project`).
from .optimizer_projection import merge_projects_inplace


# =============================================================================
# Helper: classify "trivially resolvable" agg-child expressions
# =============================================================================


def _is_trivially_resolvable(expr: Expr) -> Bool:
    """True if `resolve_col_index(expr, schema)` would accept this expr.

    Mirrors the accept-set of
    `komira_column_kernels.compiler_helpers.resolve_col_index`: EXPR_COL_REF, EXPR_COL_IDX, or EXPR_ALIAS whose
    child is itself trivially resolvable. Anything else (binary-op,
    unary-op, cast, string-op, when-case, literal) MUST be materialized
    into a named column before the aggregate operator runs.
    """
    if expr.tag == EXPR_COL_REF or expr.tag == EXPR_COL_IDX:
        return True
    if expr.tag == EXPR_ALIAS:
        return _is_trivially_resolvable(expr.alias_child_ref())
    return False


# =============================================================================
# Helper: which CHILD columns does the aggregate itself reference?
# =============================================================================
#
# The materialize-Project carries the columns the AGGREGATE reads, not every
# column the child happens to have.
#
# Example, `avg(length(url))` grouped by `counter_id`: without narrowing the
# plan is
#
#     Aggregate [1 keys, 1 agg] <- Project [3 exprs] <- Scan [proj: 2 cols]
#
# whose 3 exprs are `counter_id`, `url`, `length(url) AS __agg_in_0`. NOTHING
# above that Project references the bare `url` — an Aggregate emits only its
# group keys and its aggregands, so a child column named by neither is invisible
# upward — yet every consumer of the Project would carry the whole `url` column.
#
# The Project is created after projection pushdown has run, so nothing else
# narrows it. The narrowing is HERE, at the single site that builds the list,
# rather than a second `push_projections_down`: that pass also rewrites SCAN
# projections and carries a collision-rename arm on PLAN_JOIN, i.e. it is a
# whole-plan rewrite where the narrowing concerns one node's expr list.


def _referenced_column_name(imm e: Expr) -> Optional[String]:
    """The single CHILD-SCHEMA COLUMN NAME this reference resolves to, or None
    if it cannot be resolved to a name.

    ⛔ `EXPR_COL_IDX` DELIBERATELY RETURNS None. `_is_trivially_resolvable`
    ACCEPTS a col-idx, but a col-idx names a POSITION in the child schema and
    narrowing the passthrough list RENUMBERS those positions — so a narrowed
    plan would resolve it against a DIFFERENT column and answer quietly from the
    wrong one. That is the only over-narrowing failure mode that is not loud
    (the ordinary one is `Schema.column_index: no field named '<x>'`), so the
    caller must DECLINE to narrow rather than renumber it.
    """
    if e.tag == EXPR_COL_REF:
        return Optional[String](e.col_ref_name())
    if e.tag == EXPR_ALIAS:
        return _referenced_column_name(e.alias_child_ref())
    return None


def _append_unique(mut names: List[String], var name: String):
    for i in range(len(names)):
        if names[i] == name:
            return
    names.append(name^)


def _note_retained_slot(
    imm slot: Optional[Expr], mut needed: List[String]
) -> Bool:
    """Record the column an agg child slot reads, if that slot is RETAINED.

    Returns False — meaning the caller must DECLINE to narrow — only for a
    retained slot that cannot be resolved to a name. An EMPTY slot is nothing to
    read, and a NON-trivial slot is about to be LIFTED into `__agg_in_<n>` (its
    source columns are reached through the derived expr, which is appended to
    the project whole), so neither contributes a passthrough.
    """
    if not slot:
        return True
    ref e = slot.value()
    if not _is_trivially_resolvable(e):
        return True
    var name_opt = _referenced_column_name(e)
    if not name_opt:
        return False
    _append_unique(needed, name_opt.value())
    return True


def _agg_referenced_child_columns(
    imm group_by: ExprArray, imm agg_arr: AggExprArray
) -> Optional[List[String]]:
    """The CHILD columns the AGGREGATE itself references: every group-by key's
    column, plus the column of every agg child slot that is trivially resolvable
    (i.e. was NOT lifted). `None` means DO NOT NARROW — see
    `_referenced_column_name` for the one shape that forces that.
    """
    var needed = List[String]()

    for i in range(len(group_by)):
        var name_opt = _referenced_column_name(group_by[i])
        if not name_opt:
            return None
        _append_unique(needed, name_opt.value())

    for i in range(len(agg_arr)):
        if not _note_retained_slot(agg_arr[i].child, needed):
            return None
        if not _note_retained_slot(agg_arr[i].child1, needed):
            return None
        if not _note_retained_slot(agg_arr[i].child2, needed):
            return None
        if not _note_retained_slot(agg_arr[i].child3, needed):
            return None

    return Optional[List[String]](needed^)


# =============================================================================
# Rule: materialize_agg_input
# =============================================================================


def materialize_agg_input(var plan: LogicalPlan) raises -> LogicalPlan:
    """Insert a Project to materialize any non-trivial agg-input expressions.

    Wrapper around `materialize_agg_input_inplace`.
    """
    materialize_agg_input_inplace(plan)
    return plan^


def materialize_agg_input_inplace(mut plan: LogicalPlan) raises:
    """In-place rewrite that materializes derived agg inputs.

    Walks the tree in place. At each PLAN_AGGREGATE: if any AggExpr.child
    is non-trivial, build a Project node containing the existing child's
    columns (passthrough col_refs) plus one alias-bound expression per
    non-trivial agg child, and graft it between the aggregate and its
    existing child.

    Schema invariant: the aggregate's output schema is unchanged. Group-by
    expressions are left untouched (they can be col_refs that survive the
    insertion). The AggExpr.alias_name (output column name) is preserved
    exactly.
    """
    # Recurse children FIRST so we operate on a fully-rewritten subtree
    # before deciding what to do at this node.
    if plan.tag == PLAN_AGGREGATE:
        materialize_agg_input_inplace(plan._aggregate.value()[].child[])
        _maybe_insert_materialize_project(plan)

    elif plan.tag == PLAN_FILTER:
        materialize_agg_input_inplace(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        materialize_agg_input_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        materialize_agg_input_inplace(plan._join.value()[].left[])
        materialize_agg_input_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        materialize_agg_input_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        materialize_agg_input_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        materialize_agg_input_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        materialize_agg_input_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN:
    # leave unchanged.


def _maybe_insert_materialize_project(mut plan: LogicalPlan) raises:
    """Inspect plan (must be PLAN_AGGREGATE). If any agg child slot is non-
    trivial, build a Project that materializes the non-trivial children and
    splice it in between the aggregate and its existing child.

    Scans ALL `MAX_AGG_CHILDREN = 4` slots per AggExpr (`child` /
    `child1` / `child2` / `child3`). Empty slots (None) are skipped.
    Trivially-resolvable slots are kept as-is. Each non-trivial slot is
    lifted into the materialize-Project under a synthetic name and
    replaced with a `col_ref(__agg_in_<n>)` reference.

    Preserves the aggregate's output schema by leaving all field names and
    types alone — derived columns get a synthetic `__agg_in_<i>` name that
    is referenced ONLY by the rewritten agg child slot (never user-visible).
    """
    ref agg_arr = plan._aggregate.value()[].agg_exprs
    var num_aggs = len(agg_arr)

    # First pass: count how many slots (across all aggs, all 4 slots) need
    # materialization. If zero, skip.
    var rewrite_count = 0
    for i in range(num_aggs):
        if agg_arr[i].child:
            if not _is_trivially_resolvable(agg_arr[i].child.value()):
                rewrite_count += 1
        if agg_arr[i].child1:
            if not _is_trivially_resolvable(agg_arr[i].child1.value()):
                rewrite_count += 1
        if agg_arr[i].child2:
            if not _is_trivially_resolvable(agg_arr[i].child2.value()):
                rewrite_count += 1
        if agg_arr[i].child3:
            if not _is_trivially_resolvable(agg_arr[i].child3.value()):
                rewrite_count += 1

    if rewrite_count == 0:
        return

    # Build new agg_exprs and the list of (fresh_name, derived_expr) pairs.
    # Use a per-aggregate-node monotonic counter for fresh-name uniqueness
    # spanning all aggs and all slots. The same name can re-appear at a
    # parent agg (different scope) — the naming is local to this
    # materialize-project, which is also local to this aggregate.
    var new_aggs = AggExprArray()
    var derived_exprs = ExprArray()  # the child expressions being lifted
    var fresh_seq = 0

    for i in range(num_aggs):
        # Build the new AggExpr by:
        #   1. Deep-copying the source AggExpr to preserve func / alias /
        #      all 4 slots in their current state.
        #   2. Walking each populated slot and rewriting it in-place if
        #      non-trivial (lift derived expr into project, replace slot
        #      with col_ref).
        # Trivial / None slots are preserved by the initial copy.
        var rewritten = agg_arr[i].copy()

        # Slot 0 (`child`)
        if rewritten.child:
            ref slot0_expr = rewritten.child.value()
            if not _is_trivially_resolvable(slot0_expr):
                var fresh = String("__agg_in_") + String(fresh_seq)
                fresh_seq += 1
                derived_exprs.append(
                    Expr.alias(slot0_expr.copy(), fresh.copy())
                )
                rewritten.child = Optional[Expr](Expr.col_ref(fresh^))

        # Slot 1 (`child1`)
        if rewritten.child1:
            ref slot1_expr = rewritten.child1.value()
            if not _is_trivially_resolvable(slot1_expr):
                var fresh = String("__agg_in_") + String(fresh_seq)
                fresh_seq += 1
                derived_exprs.append(
                    Expr.alias(slot1_expr.copy(), fresh.copy())
                )
                rewritten.child1 = Optional[Expr](Expr.col_ref(fresh^))

        # Slot 2 (`child2`)
        if rewritten.child2:
            ref slot2_expr = rewritten.child2.value()
            if not _is_trivially_resolvable(slot2_expr):
                var fresh = String("__agg_in_") + String(fresh_seq)
                fresh_seq += 1
                derived_exprs.append(
                    Expr.alias(slot2_expr.copy(), fresh.copy())
                )
                rewritten.child2 = Optional[Expr](Expr.col_ref(fresh^))

        # Slot 3 (`child3`)
        if rewritten.child3:
            ref slot3_expr = rewritten.child3.value()
            if not _is_trivially_resolvable(slot3_expr):
                var fresh = String("__agg_in_") + String(fresh_seq)
                fresh_seq += 1
                derived_exprs.append(
                    Expr.alias(slot3_expr.copy(), fresh.copy())
                )
                rewritten.child3 = Optional[Expr](Expr.col_ref(fresh^))

        new_aggs.append(rewritten^)

    # Build the project: the passthrough columns + the derived expressions. We
    # need passthroughs because the aggregate's group-by keys and its other agg
    # children (those that were already col-refs) must still be visible BY NAME
    # in the project's output schema.
    #
    # The passthrough list is the columns the AGGREGATE READS, not every column
    # the child has (see the block comment on `_agg_referenced_child_columns`).
    # ONE interior reference, two field reads. Forming `plan._aggregate.value()[]`
    # TWICE inside a single call invalidates the first — and `needed_opt` is an
    # owned value, so it survives the later `existing_child` binding that
    # invalidates this one. `agg_exprs` here is still the ORIGINAL slot set,
    # which is what tells us which slots were RETAINED rather than lifted.
    ref agg_node = plan._aggregate.value()[]
    var needed_opt = _agg_referenced_child_columns(
        agg_node.group_by, agg_node.agg_exprs
    )

    ref existing_child = plan._aggregate.value()[].child[]
    ref child_schema = existing_child.output_schema
    var num_child_cols = child_schema.num_columns()

    # A needed name that is NOT in the child schema means the plan was already
    # inconsistent. Keep the previous behaviour rather than convert that into a
    # NEW failure introduced by this rule.
    var narrow = False
    if needed_opt:
        narrow = True
        for i in range(len(needed_opt.value())):
            var found = False
            for c in range(num_child_cols):
                if String(child_schema.field_name(c)) == needed_opt.value()[i]:
                    found = True
                    break
            if not found:
                narrow = False
                break

    var project_exprs = ExprArray()
    if narrow:
        # Iterate the CHILD SCHEMA, not the needed list, so the kept columns
        # stay in CANONICAL ORDER and are de-duplicated for free (a column read
        # by both a group key and an agg child must not be emitted twice — that
        # would be a duplicate field name in the project's output schema).
        for c in range(num_child_cols):
            var col_name = String(child_schema.field_name(c))
            for i in range(len(needed_opt.value())):
                if needed_opt.value()[i] == col_name:
                    project_exprs.append(Expr.col_ref(col_name))
                    break
    else:
        for c in range(num_child_cols):
            project_exprs.append(Expr.col_ref(child_schema.field_name(c)))

    for d in range(len(derived_exprs)):
        project_exprs.append(derived_exprs[d].copy())

    # Deep-copy the grandchild — we cannot partial-move it out of the
    # AggregateData OwnedPointer field (the pointer rules). Same pattern as
    # `absorb_expression_into_aggregate_inplace`.
    var grandchild_copy = _copy_plan(existing_child)
    var new_project = LogicalPlan.project(project_exprs^, grandchild_copy^)

    # FOLD THE PROJECT, DO NOT STACK IT.
    #
    # A Project can already sit below the AGGREGATE (for example one that
    # materialises a COMPUTED GROUP KEY such as `GROUP BY
    # REGEXP_REPLACE(referer, ...)`). When the aggregate also has a computed
    # aggregand (`avg(length(referer))`), splicing this rule's Project on top
    # would give `AGGREGATE(PROJECT(PROJECT(...)))`; a consumer that accepts at
    # most one Project between an aggregate and its scan would not match it.
    # This folds the stack at the single site that creates it.
    #
    # `merge_projects_inplace` is the project-merge rule, unmodified: it
    # SUBSTITUTES each outer col_ref with the inner Project's expression, so the
    # merged node evaluates `__agg_in_0 = length(referer)` and `__grp_key_0 =
    # REGEXP_REPLACE(referer, ...)` over the SAME grandchild, with the outer
    # output names (and therefore this aggregate's own schema) untouched. A
    # grandchild that is not a PROJECT is left exactly as it was.
    if new_project._project.value()[].child[].tag == PLAN_PROJECT:
        merge_projects_inplace(new_project)

    # Splice: replace the aggregate's child with the new project, and
    # update its agg_exprs in place. Schema unchanged — output schema is
    # derived from group_by + agg_exprs output names, both of which we
    # preserved (the aggregate's *output* names are governed by
    # AggExpr.alias_name, not by the AggExpr.child name).
    plan._aggregate.value()[].agg_exprs = new_aggs^
    plan._aggregate.value()[].child = OwnedPointer(new_project^)
