# =============================================================================
# Optimizer rule: flatten_dependent_joins
# Decorrelation of correlated subqueries
# =============================================================================
#
# A statistics-independent rule. Lowers every `EXPR_CORRELATED_SUBQUERY` Expr node
# into existing `LogicalJoin` shapes. After this
# rule runs, the resulting plan has ZERO `EXPR_CORRELATED_SUBQUERY` nodes
# remaining (assertable invariant).
#
# References — implementations studied before coding:
#   - DuckDB `src/planner/subquery/flatten_dependent_join.cpp`:
#     `FlattenDependentJoins::RewriteCorrelatedExpressions` walks the
#     correlated expression's inner plan, classifies operators into
#     depth-0 (uncorrelated, pushable below the join) and depth>0
#     (correlated, hoisted to the join's `on=` clause). DuckDB's depth-0/>0
#     classifier uses `HasCTEAccessor` + `DependsOnCorrelatedWalk`.
#     Our pass is a narrower version: only a Filter at the root of
#     `inner_plan` is inspected; a conjunct that references an outer column
#     is HOISTED into the join's keys (an equality) or its residual (any
#     other comparison), and the inner Filter keeps the rest (or is dropped).
#     That hoist, and the shapes it refuses, live in `flatten_hoist`.
#   - DataFusion `optimizer/src/decorrelate_predicate_subquery.rs` and
#     `optimizer/src/scalar_subquery_to_join.rs`. The first lowers
#     EXISTS/NOT_EXISTS to SEMI/ANTI joins; the second lowers scalar-
#     correlated subqueries to a LEFT join with an aggregating sink
#     (the TPC-H Q17 shape).
#
# Lowering shape per `kind`:
#   CORR_KIND_EXISTS    → LogicalJoin(JOIN_SEMI, outer_refs ↔ inner_keys)
#   CORR_KIND_NOT_EXISTS→ LogicalJoin(JOIN_ANTI, outer_refs ↔ inner_keys)
#   CORR_KIND_SCALAR    → LogicalJoin(JOIN_LEFT, outer_refs ↔ inner_keys) +
#                         agg sink (Q17 shape: aggregating the
#                         scalar value over the matched right side).
#                         The scalar Expr in the parent Filter/Project is
#                         replaced with a `col_ref` to the aggregated output.
#   CORR_KIND_IN_CORRELATED → LogicalJoin(JOIN_SEMI,
#                         (outer_refs..., in_lhs_col) ↔ (inner_keys..., in_rhs_col))
#                         (Q20). `col IN (correlated subquery)`
#                         flattens to a semi-join whose keys are the
#                         hoisted correlation predicates PLUS the original
#                         `IN` comparison (`outer.in_lhs_col = inner.in_rhs_col`).
#                         Mirrors DuckDB's "correlated MARK join with one
#                         extra join condition" (plan_subquery.cpp:333-362)
#                         — Komira has no MARK join so positive `IN`
#                         maps directly to JOIN_SEMI. `outer_refs` may be
#                         empty (uncorrelated `IN` whose RHS is a subquery).
#
# Pass order: `optimizer_driver.optimize` runs this pass after the
# uncorrelated scalar-subquery passes and BEFORE join structural rewrites.
#
# Design constraint:
#   - SCALAR + parent=Filter (Q17): the agg sink shape implies the parent
#     plan tree must absorb the aggregate into a new Aggregate node BELOW
#     the Filter, then replace the inner-scalar Expr in the Filter
#     predicate with `col_ref(<agg-output-name>)`. To keep the pass simple
#     and avoid an explicit "lateral" operator, we lower SCALAR to
#     `Filter(rewritten, LEFT JOIN(outer, Aggregate(inner)))`: the
#     Aggregate is the join's right child, groups by the inner join keys
#     and emits a single aggregated column whose name the rewritten Expr
#     references. This composes existing plan nodes (Join + Aggregate +
#     Filter); no new node kind is needed.
# =============================================================================

from std.memory import OwnedPointer
from std.collections import Optional

from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_AGG_FN,
    EXPR_IN_LIST,
    EXPR_CORRELATED_SUBQUERY,
    BIN_AND,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_MEAN
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    CorrelatedSubqueryData,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    CORR_KIND_IN_CORRELATED,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_LEFT,
    JOIN_ALGO_AUTO,
)
from komira_plan_ir.corr_subquery import corr_data_inner_plan_ref
from .flatten_hoist import (
    _schema_has_field,
    _split_conjuncts,
    _join_conjuncts,
    _hoist_outer_eq_predicates,
)


# =============================================================================
# Public API
# =============================================================================


def flatten_dependent_joins(var plan: LogicalPlan) raises -> LogicalPlan:
    """Top-level entry: lower every `EXPR_CORRELATED_SUBQUERY` in `plan`.

    Walks the plan recursively. At any `Filter` node whose predicate
    contains a correlated subquery, replaces that Filter with the lowered
    join+predicate shape per kind; a `Project` carrying one raises (not
    supported). After return, `plan` is guaranteed to contain zero
    `EXPR_CORRELATED_SUBQUERY` nodes (invariant; assertable via
    `_plan_contains_correlated_subquery`).

    Idempotent: a plan with no correlated subqueries is returned
    structurally unchanged.
    """
    flatten_dependent_joins_inplace(plan)
    return plan^


def flatten_dependent_joins_inplace(mut plan: LogicalPlan) raises:
    """In-place rewrite mirror of `flatten_dependent_joins`.

    Recurses children first, then rewrites at this node.
    """
    # Recurse children FIRST.
    if plan.tag == PLAN_FILTER:
        flatten_dependent_joins_inplace(plan._filter.value()[].child[])
        _maybe_lower_filter(plan)
    elif plan.tag == PLAN_PROJECT:
        flatten_dependent_joins_inplace(plan._project.value()[].child[])
        _maybe_lower_project(plan)
    elif plan.tag == PLAN_AGGREGATE:
        flatten_dependent_joins_inplace(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        flatten_dependent_joins_inplace(plan._join.value()[].left[])
        flatten_dependent_joins_inplace(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        flatten_dependent_joins_inplace(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        flatten_dependent_joins_inplace(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        flatten_dependent_joins_inplace(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        flatten_dependent_joins_inplace(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        flatten_dependent_joins_inplace(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        flatten_dependent_joins_inplace(plan._partition_topn.value()[].child[])
    # PLAN_SCAN has no children; PLAN_ASOF_JOIN, PLAN_UNION and the other
    # tags are not descended.


# =============================================================================
# Expr walkers — find / count / classify correlated-subquery nodes
# =============================================================================


def _expr_contains_correlated_subquery(expr: Expr) -> Bool:
    """True if `expr` (or any subtree) is an EXPR_CORRELATED_SUBQUERY."""
    if expr.tag == EXPR_CORRELATED_SUBQUERY:
        return True
    if expr.tag == EXPR_BINARY_OP:
        ref b = expr._binary.value()
        if _expr_contains_correlated_subquery(b.left[]):
            return True
        if _expr_contains_correlated_subquery(b.right[]):
            return True
        return False
    if expr.tag == EXPR_UNARY_OP:
        return _expr_contains_correlated_subquery(expr._unary.value().child[])
    if expr.tag == EXPR_CAST:
        return _expr_contains_correlated_subquery(expr._cast.value().child[])
    if expr.tag == EXPR_ALIAS:
        return _expr_contains_correlated_subquery(expr._alias.value().child[])
    if expr.tag == EXPR_STRING_OP:
        return _expr_contains_correlated_subquery(expr._string_op.value().child[])
    if expr.tag == EXPR_IN_LIST:
        return _expr_contains_correlated_subquery(expr._in_list.value().child[])
    if expr.tag == EXPR_AGG_FN:
        return _expr_contains_correlated_subquery(expr._agg_fn.value().child[])
    if expr.tag == EXPR_WHEN:
        # No lowering handles a subquery under a CASE; seeing it makes the
        # pass refuse the shape instead of leaving the node in the plan.
        ref wd = expr._when.value()
        for i in range(len(wd.cases)):
            if _expr_contains_correlated_subquery(wd.cases[i].condition[]):
                return True
            if _expr_contains_correlated_subquery(wd.cases[i].result[]):
                return True
        return _expr_contains_correlated_subquery(wd.default[])
    # EXPR_COL_REF / EXPR_COL_IDX / EXPR_LITERAL / EXPR_WINDOW_FN (its
    # arguments are column names, not expressions) and the remaining tags
    # are not descended. The supported parent-Expr shapes are: bare
    # CorrelatedSubquery (Filter root) and CorrelatedSubquery within a
    # binary-op (e.g. `>` for SCALAR/Q17).
    return False


def _expr_collect_column_names(
    expr: Expr,
    mut acc: List[String],
) -> None:
    """Collect every `EXPR_COL_REF` name reachable from `expr` into `acc`.

    Nothing in this module calls it (the hoist below matches col-ref names
    directly); only its tests do.
    """
    if expr.tag == EXPR_COL_REF:
        acc.append(expr._col_ref.value().name)
        return
    if expr.tag == EXPR_BINARY_OP:
        ref b = expr._binary.value()
        _expr_collect_column_names(b.left[], acc)
        _expr_collect_column_names(b.right[], acc)
        return
    if expr.tag == EXPR_UNARY_OP:
        _expr_collect_column_names(expr._unary.value().child[], acc)
        return
    if expr.tag == EXPR_CAST:
        _expr_collect_column_names(expr._cast.value().child[], acc)
        return
    if expr.tag == EXPR_ALIAS:
        _expr_collect_column_names(expr._alias.value().child[], acc)
        return
    if expr.tag == EXPR_STRING_OP:
        _expr_collect_column_names(expr._string_op.value().child[], acc)
        return
    if expr.tag == EXPR_IN_LIST:
        _expr_collect_column_names(expr._in_list.value().child[], acc)
        return
    if expr.tag == EXPR_AGG_FN:
        _expr_collect_column_names(expr._agg_fn.value().child[], acc)
        return


def _plan_contains_correlated_subquery(plan: LogicalPlan) -> Bool:
    """Invariant-check helper: True if a Filter predicate or Project expr
    still carries an `EXPR_CORRELATED_SUBQUERY`. It descends Filter,
    Project, Join, Aggregate, Sort, Limit, Distinct and TopN only; other
    tags answer False. After `flatten_dependent_joins_inplace` returns,
    this MUST be False for any successfully lowered plan.
    """
    if plan.tag == PLAN_FILTER:
        if _expr_contains_correlated_subquery(plan._filter.value()[].predicate):
            return True
        return _plan_contains_correlated_subquery(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        ref pj = plan._project.value()[]
        for i in range(len(pj.exprs)):
            if _expr_contains_correlated_subquery(pj.exprs[i]):
                return True
        return _plan_contains_correlated_subquery(pj.child[])
    if plan.tag == PLAN_JOIN:
        if _plan_contains_correlated_subquery(plan._join.value()[].left[]):
            return True
        return _plan_contains_correlated_subquery(plan._join.value()[].right[])
    if plan.tag == PLAN_AGGREGATE:
        return _plan_contains_correlated_subquery(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_SORT:
        return _plan_contains_correlated_subquery(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return _plan_contains_correlated_subquery(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _plan_contains_correlated_subquery(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return _plan_contains_correlated_subquery(plan._topn.value()[].child[])
    return False


# =============================================================================
# Outer-ref validation
# =============================================================================


def _validate_outer_refs(
    outer_refs: List[String],
    parent_schema: Schema,
) raises:
    """Raise `UnresolvedOuterRef` if any outer_ref is missing from
    `parent_schema`. The error message format
    is stable so the negative test can assert against `find("UnresolvedOuterRef:")`.
    """
    for i in range(len(outer_refs)):
        if not _schema_has_field(parent_schema, outer_refs[i]):
            raise Error("UnresolvedOuterRef: " + outer_refs[i])


# =============================================================================
# Filter lowering
# =============================================================================


def _maybe_lower_filter(mut plan: LogicalPlan) raises:
    """Inspect plan (must be PLAN_FILTER). If its predicate is — or
    contains — an EXPR_CORRELATED_SUBQUERY, replace the Filter with the
    appropriate lowered join shape.

    Supported parent-shapes:
      - `Filter(child, EXPR_CORRELATED_SUBQUERY)` — bare subquery as the
        WHERE predicate (Q4 EXISTS / Q21 NOT EXISTS).
      - `Filter(child, BIN_OP(other_lhs, EXPR_CORRELATED_SUBQUERY))` —
        a comparison whose RHS is a scalar correlated subquery (Q17).
      - `Filter(child, BIN_AND(p1, EXPR_CORRELATED_SUBQUERY))` — flat AND
        of non-correlated predicates and bare correlated subqueries.
        Lowering (`_lower_and_chain_with_corr`): the non-correlated
        conjuncts become a Filter directly above `child`, below the joins;
        each correlated piece adds a join.

    Anything else with a nested correlated subquery raises "unsupported
    parent-shape for correlated subquery" so the missed-shape
    bug surfaces (rather than silently leaving the EXPR in the tree).
    """
    if not _expr_contains_correlated_subquery(plan._filter.value()[].predicate):
        return

    # Extract everything we need from the Filter BEFORE we mutate `plan`.
    # We deep-copy the predicate and the child plan so subsequent assignment
    # to `plan` does not invalidate any references we hold.
    var pred_copy = plan._filter.value()[].predicate.copy()
    var child_plan_copy = plan._filter.value()[].child[].copy()

    # Case A: predicate IS the bare CorrelatedSubquery.
    if pred_copy.tag == EXPR_CORRELATED_SUBQUERY:
        var lowered = _lower_correlated_into_join(
            child_plan_copy^, pred_copy, None,
        )
        plan = lowered^
        return

    if pred_copy.tag == EXPR_BINARY_OP:
        var b_op = pred_copy._binary.value().op

        # AND-chain: a WHERE that ANDs one or more correlated subqueries with
        # other predicates (the canonical multi-table shape — TPC-H Q21 ANDs
        # `EXISTS` + `NOT EXISTS` with six join / selection predicates). The
        # generalized handler partitions the conjuncts and chains each bare
        # correlated subquery into its own SEMI / ANTI join. This runs BEFORE
        # the scalar-comparison branches below so a bare `EXISTS` conjunct in
        # the chain is chained (not mis-routed into the "scalar RHS" branch,
        # which would reject its non-SCALAR kind).
        if b_op == BIN_AND:
            _lower_and_chain_with_corr(plan, pred_copy^, child_plan_copy^)
            return

    # Case B: predicate is BIN_OP(lhs, CorrelatedSubquery) — a comparison
    # whose RHS is a scalar-subquery. We only lower when the OUTER
    # comparison is the immediate parent of the CorrelatedSubquery.
    if pred_copy.tag == EXPR_BINARY_OP:
        var b_op = pred_copy._binary.value().op
        var rhs_tag = pred_copy._binary.value().right[].tag
        var lhs_tag = pred_copy._binary.value().left[].tag
        var rhs_has_corr = _expr_contains_correlated_subquery(pred_copy._binary.value().right[])
        var lhs_has_corr = _expr_contains_correlated_subquery(pred_copy._binary.value().left[])

        if rhs_tag == EXPR_CORRELATED_SUBQUERY and not lhs_has_corr:
            # SCALAR pattern (Q17): col > 0.2 * subquery; or
            # col_lhs op subquery for any op.
            var rhs_kind = pred_copy._binary.value().right[]._corr_subq.value()[].kind
            if rhs_kind != CORR_KIND_SCALAR:
                raise Error("bare BIN_OP with non-SCALAR correlated RHS is unsupported")
            var agg_out_name = String("__corr_scalar_0")
            var rhs_copy = pred_copy._binary.value().right[].copy()
            var lhs_copy = pred_copy._binary.value().left[].copy()
            var lowered = _lower_scalar_correlated(
                child_plan_copy^, rhs_copy, agg_out_name.copy(),
            )
            var new_rhs = Expr.col_ref(agg_out_name^)
            var new_pred = Expr.binary(b_op, lhs_copy^, new_rhs^)
            plan = LogicalPlan.filter(new_pred^, lowered^)
            return
        if lhs_tag == EXPR_CORRELATED_SUBQUERY and not rhs_has_corr:
            var lhs_kind = pred_copy._binary.value().left[]._corr_subq.value()[].kind
            if lhs_kind != CORR_KIND_SCALAR:
                raise Error("bare BIN_OP with non-SCALAR correlated LHS is unsupported")
            var agg_out_name = String("__corr_scalar_0")
            var lhs_copy = pred_copy._binary.value().left[].copy()
            var rhs_copy = pred_copy._binary.value().right[].copy()
            var lowered = _lower_scalar_correlated(
                child_plan_copy^, lhs_copy, agg_out_name.copy(),
            )
            var new_lhs = Expr.col_ref(agg_out_name^)
            var new_pred = Expr.binary(b_op, new_lhs^, rhs_copy^)
            plan = LogicalPlan.filter(new_pred^, lowered^)
            return

    raise Error("unsupported parent-shape for correlated subquery in Filter predicate")


def _lower_and_chain_with_corr(
    mut plan: LogicalPlan,
    var pred: Expr,
    var child: LogicalPlan,
) raises:
    """Lower a Filter whose predicate is an AND chain containing one or more
    correlated subqueries (the canonical multi-table WHERE — TPC-H Q21).

    Partition the flattened conjuncts:
      - bare `EXPR_CORRELATED_SUBQUERY` conjuncts (EXISTS / NOT EXISTS / IN) →
        each chained into its own SEMI / ANTI join, stacked on top of `child`
        (a bare SCALAR conjunct becomes a LEFT join).
      - every non-correlated conjunct → a residual Filter placed DIRECTLY above
        `child` (below the correlated joins), so the optimizer's cross-join
        elimination still folds the FROM's join predicates into inner joins.
        (SEMI/ANTI joins are left-only, so filtering `child` before or after
        them is equivalent — same rows, better plan.)

    A correlated subquery nested inside a larger conjunct (e.g. a scalar
    comparison `col < (subquery)`) inside an AND chain is not yet supported —
    raised rather than silently mishandled.
    """
    var conjuncts = ExprArray()
    _split_conjuncts(pred, conjuncts)

    var corr_conjuncts = ExprArray()
    var residual = ExprArray()
    for i in range(len(conjuncts)):
        ref c = conjuncts[i]
        if c.tag == EXPR_CORRELATED_SUBQUERY:
            corr_conjuncts.append(c.copy())
        elif _expr_contains_correlated_subquery(c):
            raise Error(
                "flatten: a correlated subquery nested inside an AND-chain"
                " conjunct (e.g. a scalar comparison `col < (subquery)`) is not"
                " yet supported; only bare EXISTS / NOT EXISTS / IN conjuncts"
                " are lowered from an AND chain"
            )
        else:
            residual.append(c.copy())

    # Non-correlated predicates → a Filter directly above `child`.
    var base: LogicalPlan
    var residual_opt = _join_conjuncts(residual^)
    if residual_opt:
        var rp = residual_opt.value().copy()
        base = LogicalPlan.filter(rp^, child^)
    else:
        base = child^

    # Chain each bare correlated subquery into its SEMI / ANTI join.
    for i in range(len(corr_conjuncts)):
        base = _lower_correlated_into_join(base^, corr_conjuncts[i], None)

    plan = base^


def _maybe_lower_project(mut plan: LogicalPlan) raises:
    """Inspect plan (must be PLAN_PROJECT). If any project Expr contains an
    EXPR_CORRELATED_SUBQUERY, lower it.

    No project-shape is supported: any correlated subquery in a Project
    expr raises. The shape is unusual in TPC-H (Q17 puts the SCALAR under
    a Filter), so the scope is kept tight. A future extension can lower
    projected scalar-subqueries.
    """
    ref pj = plan._project.value()[]
    for i in range(len(pj.exprs)):
        if _expr_contains_correlated_subquery(pj.exprs[i]):
            raise Error("correlated subquery in Project not yet supported")


# =============================================================================
# Lowering primitives (per kind)
# =============================================================================


def _lower_correlated_into_join(
    var outer_child: LogicalPlan,
    corr_expr: Expr,
    var residual_predicate: Optional[Expr],
) raises -> LogicalPlan:
    """Lower a CorrelatedSubquery Expr (with the outer Filter's child)
    into a `LogicalJoin` of the appropriate `join_type`.

    EXISTS         → JOIN_SEMI
    NOT_EXISTS     → JOIN_ANTI
    IN_CORRELATED  → JOIN_SEMI with the `IN`-list equi-key appended:
                     `(hoisted_corr..., in_lhs_col) = (..., in_rhs_col)`.
                     `outer_refs` may be empty (uncorrelated `IN` over a
                     subquery RHS — then the only key is the `IN` key).
    SCALAR         → JOIN_LEFT with no agg sink. Reached only for a bare
                     SCALAR predicate or AND-chain conjunct; a SCALAR
                     under a comparison is routed to
                     `_lower_scalar_correlated` instead.

    Validates outer_refs (and, for IN, `in_lhs_col`) against the
    outer_child's output_schema.
    """
    ref corr_data = corr_expr._corr_subq.value()[]
    _validate_outer_refs(corr_data.outer_refs, outer_child.output_schema)
    if corr_data.kind == CORR_KIND_IN_CORRELATED:
        # The `IN`-list LHS column must resolve in the outer scope too.
        if not _schema_has_field(outer_child.output_schema, corr_data.in_lhs_col):
            raise Error("UnresolvedOuterRef: " + corr_data.in_lhs_col)

    # Nested correlation: recursively lower any EXPR_CORRELATED_SUBQUERY
    # within the inner plan tree BEFORE building the join. This makes the
    # pass deterministic regardless of which correlation level we visit
    # first (CorrelatedSubquery.inner_plan is NOT a regular plan-tree
    # child, so the outer walk doesn't reach it).
    var inner_pre_flat = corr_data_inner_plan_ref(corr_data).copy()
    flatten_dependent_joins_inplace(inner_pre_flat)

    var join_type: UInt8
    if corr_data.kind == CORR_KIND_EXISTS:
        join_type = JOIN_SEMI
    elif corr_data.kind == CORR_KIND_NOT_EXISTS:
        join_type = JOIN_ANTI
    elif corr_data.kind == CORR_KIND_IN_CORRELATED:
        # `col IN (subquery)` — positive membership test. Maps to a
        # semi-join: keep the outer row iff the inner subquery yields
        # >=1 row whose projected column equals `outer.in_lhs_col`. The
        # `IN` equi-predicate is appended to the hoisted-correlation keys.
        join_type = JOIN_SEMI
    elif corr_data.kind == CORR_KIND_SCALAR:
        # SCALAR via this entry point is the "bare correlated as Filter
        # predicate" case. We treat it as JOIN_LEFT (preserves outer rows;
        # matches DuckDB's scalar subquery shape) and trust the caller to
        # have validated the post-join Filter semantics. A SCALAR under a
        # comparison never reaches here (`_maybe_lower_filter` routes it to
        # `_lower_scalar_correlated`).
        join_type = JOIN_LEFT
    else:
        raise Error("unknown correlated-subquery kind: " + String(Int(corr_data.kind)))

    # Outer-ref hoist + equi-key derivation (+ non-equi residual for the
    # side-qualified Q21 self-correlation shape).
    var left_on = List[String]()
    var right_on = List[String]()
    var residual_conjuncts = ExprArray()
    var inner_after_hoist = _hoist_outer_eq_predicates(
        inner_pre_flat^, corr_data.outer_refs, left_on, right_on,
        residual_conjuncts,
    )

    # IN-correlated: append the original `IN` comparison as an extra
    # equi-key (`outer.in_lhs_col = inner.in_rhs_col`). This is the
    # "one extra join condition" DuckDB pushes on its correlated MARK
    # join (plan_subquery.cpp:333-362); since we lower positive `IN`
    # directly to JOIN_SEMI, the extra key goes onto `left_on`/`right_on`.
    if corr_data.kind == CORR_KIND_IN_CORRELATED:
        left_on.append(corr_data.in_lhs_col)
        right_on.append(corr_data.in_rhs_col)

    # Non-equi outer-referencing conjuncts (Q21 `l_suppkey <> l1.l_suppkey`)
    # become a side-qualified join `residual`. `join_predicate_decompose`
    # (designed to run after this pass) rewrites the residual to the
    # joined-row schema; it is evaluated per matched pair outside
    # komira_optimizer (SEMI/ANTI single-equi-key + residual is exactly the
    # Q21 shape). `None` when no non-equi correlation exists.
    var residual: Optional[OwnedPointer[Expr]] = None
    if len(residual_conjuncts) > 0:
        var acc = residual_conjuncts[0].copy()
        for i in range(1, len(residual_conjuncts)):
            acc = Expr.binary(BIN_AND, acc^, residual_conjuncts[i].copy())
        residual = OwnedPointer(acc^)

    var join_plan = LogicalPlan.join(
        outer_child^, inner_after_hoist^,
        left_on^, right_on^,
        join_type,
        JOIN_ALGO_AUTO,
        residual^,
    )

    # If a residual non-correlated predicate was passed, wrap the join in a
    # Filter carrying it. Every caller in this module passes None; the
    # branch tests call this function directly with one.
    if residual_predicate:
        var resid_pred = residual_predicate.value().copy()
        return LogicalPlan.filter(resid_pred^, join_plan^)
    return join_plan^


def _lower_scalar_correlated(
    var outer_child: LogicalPlan,
    corr_expr: Expr,
    var agg_out_name: String,
) raises -> LogicalPlan:
    """Lower a SCALAR correlated subquery to LEFT join + aggregate sink.

    Q17 shape: the inner subquery `SELECT 0.2 * AVG(l_quantity) FROM
    lineitem WHERE l_partkey = outer.p_partkey` becomes:

        LEFT JOIN(outer_child,
                  Aggregate(group_by=[<right side of join_keys>],
                            agg_exprs=[<agg> AS <agg_out_name>],
                            <inner plan>),
                  ON outer_refs = inner_keys)

    The aggregate runs over the join's right side (the inner plan), one
    group per inner join key; the LEFT join preserves every outer row, and
    the per-key aggregate is emitted in `agg_out_name`. The caller (Filter
    rewrite) then references `agg_out_name` in the rewritten predicate.

    NOTE: this lowering assumes the inner plan's "scalar" is the output
    of an existing Aggregate node at its root (its one agg is re-aliased
    and re-grouped by the join keys). If the inner plan does NOT have an
    Aggregate at its root, the lowering preserves the inner plan structure
    but adds a synthetic Aggregate wrapper that emits a MEAN over the
    first output column (default heuristic; the canonical case is the
    TPC-H Q17 shape).
    The inner plan's pre-aggregation expression is the slot-0 input.
    """
    ref corr_data = corr_expr._corr_subq.value()[]
    _validate_outer_refs(corr_data.outer_refs, outer_child.output_schema)

    # Nested correlation: recursively lower any EXPR_CORRELATED_SUBQUERY
    # within the inner plan tree BEFORE building the join (same rationale
    # as the EXISTS path above).
    var inner_pre_flat = corr_data_inner_plan_ref(corr_data).copy()
    flatten_dependent_joins_inplace(inner_pre_flat)

    # Outer-ref hoist + equi-key derivation (same as EXISTS path).
    var left_on = List[String]()
    var right_on = List[String]()
    var scalar_residual = ExprArray()
    var inner_after_hoist = _hoist_outer_eq_predicates(
        inner_pre_flat^, corr_data.outer_refs, left_on, right_on,
        scalar_residual,
    )
    if len(scalar_residual) > 0:
        # A non-equi correlation in a SCALAR subquery would need the residual
        # to gate the aggregate sink's grouping — not yet supported (only
        # `_lower_correlated_into_join`, the EXISTS / NOT EXISTS / IN path,
        # lowers a residual). Surface rather than silently drop the
        # correlation.
        raise Error(
            "flatten: non-equi correlation in a scalar (aggregate) subquery is"
            " not yet supported -- only EXISTS / NOT EXISTS carry a residual"
        )

    # Build the inner aggregate that emits `agg_out_name`. If the inner
    # plan is already a PLAN_AGGREGATE, we trust the caller built the
    # right shape; otherwise we wrap with a default MEAN over the first
    # output column.
    var inner_with_agg: LogicalPlan
    if inner_after_hoist.tag == PLAN_AGGREGATE:
        # Re-alias the existing single agg's output to `agg_out_name`.
        # We rebuild the Aggregate node with the new alias rather than
        # mutating in place (preserves the Mojo move-only contract).
        ref existing_agg = inner_after_hoist._aggregate.value()[]
        if len(existing_agg.agg_exprs) != 1:
            raise Error("scalar correlated inner Aggregate must have exactly 1 agg expr")
        var new_aggs = AggExprArray()
        var renamed = existing_agg.agg_exprs[0].alias(agg_out_name.copy())
        new_aggs.append(renamed^)
        var new_group_by = ExprArray()
        # Preserve outer-ref-derived group keys (right-side join keys) so
        # the LEFT join can match per-outer-row.
        for i in range(len(right_on)):
            new_group_by.append(Expr.col_ref(right_on[i]))
        var grandchild = existing_agg.child[].copy()
        inner_with_agg = LogicalPlan.aggregate(new_group_by^, new_aggs^, grandchild^)
    else:
        # Wrap with default MEAN over the first output column.
        if inner_after_hoist.output_schema.num_columns() == 0:
            raise Error("scalar correlated inner plan has no output columns")
        var first_col_name = inner_after_hoist.output_schema.field_name(0)
        var new_aggs = AggExprArray()
        var mean_arg: Optional[Expr] = Optional(Expr.col_ref(first_col_name))
        var alias_opt: Optional[String] = Optional(agg_out_name.copy())
        var mean_expr = AggExpr(AGG_MEAN, mean_arg^, alias_opt^)
        new_aggs.append(mean_expr^)
        var new_group_by = ExprArray()
        for i in range(len(right_on)):
            new_group_by.append(Expr.col_ref(right_on[i]))
        inner_with_agg = LogicalPlan.aggregate(new_group_by^, new_aggs^, inner_after_hoist^)

    # Build the LEFT join.
    var join_plan = LogicalPlan.join(
        outer_child^, inner_with_agg^,
        left_on^, right_on^,
        JOIN_LEFT,
        JOIN_ALGO_AUTO,
    )
    return join_plan^
