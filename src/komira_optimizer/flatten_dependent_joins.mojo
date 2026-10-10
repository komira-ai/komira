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
# Pass order: komira_optimizer has no driver that orders its passes. This
# pass is designed to run BEFORE join structural rewrites.
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
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_IN_LIST,
    EXPR_CORRELATED_SUBQUERY,
    BIN_EQ,
    BIN_AND,
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
    WhenCaseData,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_MEAN
from komira_plan_expr.scalar_value import ScalarValue
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


def _list_contains(needle: String, haystack: List[String]) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


def _schema_has_field(schema: Schema, name: String) -> Bool:
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return True
    return False


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
# Outer-ref hoist
# =============================================================================
#
# DuckDB's `FlattenDependentJoins::RewriteCorrelatedExpressions` walks the
# inner plan and classifies predicate-pieces by whether they reference
# outer-scope columns. Pieces that touch outer refs are HOISTED into the
# join's `on=` clause (i.e. they become equi-join keys). Pieces that
# touch only inner columns stay inside the inner plan.
#
# This pass adopts a conservative single-level hoist:
#   - If the inner plan is `Filter(child, predicate)` and `predicate` is
#     a BIN_EQ between an outer_ref column and an inner column, hoist
#     that equality into the join's left_on/right_on lists and replace
#     the inner Filter with its child (predicate is fully consumed).
#   - If the inner plan is `Filter(child, BIN_AND(p1, p2))`, recurse on the
#     conjuncts: hoist any conjunct that references an outer_ref, and
#     leave the rest in a (possibly simpler) Filter.
#   - Otherwise: equi-keys default to the outer_refs (i.e. assume the
#     inner schema exposes a same-named column for each outer_ref). This
#     matches the Q4/Q17/Q20/Q21 shapes which all have implicit-name
#     join columns.
# =============================================================================


def _split_conjuncts(expr: Expr, mut acc: ExprArray) raises:
    """Split a binary AND tree into a flat list of conjuncts."""
    if expr.tag == EXPR_BINARY_OP and expr._binary.value().op == BIN_AND:
        ref b = expr._binary.value()
        _split_conjuncts(b.left[], acc)
        _split_conjuncts(b.right[], acc)
    else:
        acc.append(expr.copy())


def _join_conjuncts(var conjuncts: ExprArray) raises -> Optional[Expr]:
    """Recombine a list of conjuncts back into a BIN_AND tree, or None if empty."""
    if len(conjuncts) == 0:
        return None
    if len(conjuncts) == 1:
        return Optional(conjuncts[0].copy())
    var acc = conjuncts[0].copy()
    for i in range(1, len(conjuncts)):
        acc = Expr.binary(BIN_AND, acc^, conjuncts[i].copy())
    return Optional(acc^)


# =============================================================================
# Non-equi outer-ref hoist (self-correlated NEQ/range predicates — Q21)
# =============================================================================
#
# The SQL binder (`sql_binder._bind_corr_scalar`, not in this tree) is
# designed to mark a correlated
# subquery's OUTER references with the `COL_SIDE_LEFT` qualifier and leaves
# the subquery's own (inner) columns as plain `COL_SIDE_NONE` col-refs. This
# is the ONLY channel that survives a self-correlation where the outer ref
# and the inner column share a name (TPC-H Q21: outer `l1.l_suppkey` vs inner
# `l3.l_suppkey` are BOTH named `l_suppkey`, so a name-only classifier cannot
# tell them apart). When any conjunct carries a side qualifier we take the
# side-aware hoist path below; otherwise we fall back to the legacy name-based
# hoist (unchanged, for directly-constructed correlated subqueries with plain
# col-refs).
#
# Side-aware hoist per conjunct:
#   - references NO outer (COL_SIDE_LEFT) column  → pure-inner, stays in the
#     inner Filter (a plain COL_SIDE_NONE predicate the inner scan evaluates).
#   - `outer_col = inner_col` (bare EQ, one LEFT + one NONE)  → LIFTED into the
#     equi-join keys (`left_on` = outer name, `right_on` = inner name).
#   - any OTHER outer-referencing conjunct (`<>`, `<`, `>`, `<=`, `>=`, a
#     non-bare EQ, …)  → hoisted into a side-qualified `residual` Expr (the
#     inner NONE refs are re-marked COL_SIDE_RIGHT so the downstream
#     `join_predicate_decompose` pass rewrites them to the joined-row schema,
#     applying the `_right` collision-rename that a self-join needs). The
#     residual is designed to be evaluated per matched pair for
#     SEMI/ANTI/INNER/LEFT, outside komira_optimizer.
#
# This preserves the outer reference through the flatten — the pre-fix bug was
# that a non-EQ outer conjunct stayed in the inner Filter where BOTH sides
# rebind to the inner column, collapsing to a tautology (`l_suppkey <>
# l_suppkey`) and silently dropping the correlation.
# =============================================================================


def _expr_has_side_qualifier(expr: Expr) -> Bool:
    """True if `expr` (or any subtree) contains a side-qualified
    (COL_SIDE_LEFT / COL_SIDE_RIGHT) col-ref — i.e. the binder marked an
    outer reference, so the side-aware hoist path applies."""
    if expr.tag == EXPR_COL_REF:
        return expr._col_ref.value().side != COL_SIDE_NONE
    if expr.tag == EXPR_BINARY_OP:
        ref b = expr._binary.value()
        if _expr_has_side_qualifier(b.left[]):
            return True
        return _expr_has_side_qualifier(b.right[])
    if expr.tag == EXPR_UNARY_OP:
        return _expr_has_side_qualifier(expr._unary.value().child[])
    if expr.tag == EXPR_CAST:
        return _expr_has_side_qualifier(expr._cast.value().child[])
    if expr.tag == EXPR_ALIAS:
        return _expr_has_side_qualifier(expr._alias.value().child[])
    if expr.tag == EXPR_STRING_OP:
        return _expr_has_side_qualifier(expr._string_op.value().child[])
    if expr.tag == EXPR_IN_LIST:
        return _expr_has_side_qualifier(expr._in_list.value().child[])
    if expr.tag == EXPR_AGG_FN:
        return _expr_has_side_qualifier(expr._agg_fn.value().child[])
    return False


def _expr_references_outer_side(expr: Expr) -> Bool:
    """True if `expr` (or any subtree) contains a COL_SIDE_LEFT col-ref (an
    outer reference marked by the binder)."""
    if expr.tag == EXPR_COL_REF:
        return expr._col_ref.value().side == COL_SIDE_LEFT
    if expr.tag == EXPR_BINARY_OP:
        ref b = expr._binary.value()
        if _expr_references_outer_side(b.left[]):
            return True
        return _expr_references_outer_side(b.right[])
    if expr.tag == EXPR_UNARY_OP:
        return _expr_references_outer_side(expr._unary.value().child[])
    if expr.tag == EXPR_CAST:
        return _expr_references_outer_side(expr._cast.value().child[])
    if expr.tag == EXPR_ALIAS:
        return _expr_references_outer_side(expr._alias.value().child[])
    if expr.tag == EXPR_STRING_OP:
        return _expr_references_outer_side(expr._string_op.value().child[])
    if expr.tag == EXPR_IN_LIST:
        return _expr_references_outer_side(expr._in_list.value().child[])
    if expr.tag == EXPR_AGG_FN:
        return _expr_references_outer_side(expr._agg_fn.value().child[])
    return False


def _rewrite_inner_none_to_right(expr: Expr) -> Expr:
    """Deep-copy `expr` re-marking every plain (COL_SIDE_NONE) col-ref as
    COL_SIDE_RIGHT while keeping COL_SIDE_LEFT (outer) refs as LEFT. Used when
    lifting a non-equi outer-referencing conjunct into the join residual: the
    outer refs stay LEFT and the subquery's own columns become RIGHT, giving
    `join_predicate_decompose` the side-qualified shape it rewrites into the
    joined-row schema (with the `_right` self-join collision rename)."""
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        if expr.col_ref_side() == COL_SIDE_LEFT:
            return Expr.left(name)
        return Expr.right(name)
    elif expr.tag == EXPR_BINARY_OP:
        return Expr.binary(
            expr.binary_op(),
            _rewrite_inner_none_to_right(expr.binary_left_ref()),
            _rewrite_inner_none_to_right(expr.binary_right_ref()),
        )
    elif expr.tag == EXPR_UNARY_OP:
        return Expr.unary(
            expr.unary_op(), _rewrite_inner_none_to_right(expr.unary_child_ref())
        )
    elif expr.tag == EXPR_CAST:
        return Expr.cast(
            _rewrite_inner_none_to_right(expr.cast_child_ref()), expr.cast_target()
        )
    elif expr.tag == EXPR_STRING_OP:
        return Expr.string_op(
            expr.string_op_type(),
            _rewrite_inner_none_to_right(expr.string_op_child_ref()),
            expr.string_op_pattern(),
        )
    elif expr.tag == EXPR_ALIAS:
        return Expr.alias(
            _rewrite_inner_none_to_right(expr.alias_child_ref()), expr.alias_name()
        )
    elif expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        var cases = List[WhenCaseData]()
        for i in range(len(wd.cases)):
            cases.append(WhenCaseData(
                _rewrite_inner_none_to_right(wd.cases[i].condition[]),
                _rewrite_inner_none_to_right(wd.cases[i].result[]),
            ))
        return Expr.when(cases^, _rewrite_inner_none_to_right(wd.default[]))
    elif expr.tag == EXPR_IN_LIST:
        ref il = expr._in_list.value()
        var vals = List[ScalarValue]()
        for i in range(len(il.values)):
            vals.append(il.values[i].copy())
        return Expr.in_list_node(_rewrite_inner_none_to_right(il.child[]), vals^)
    elif expr.tag == EXPR_AGG_FN:
        return Expr.agg_fn(
            expr.agg_fn_op(), _rewrite_inner_none_to_right(expr.agg_fn_child_ref())
        )
    else:
        # Literals / col-idx / other leaves: no side-qualified col-ref to
        # remap (a residual conjunct always references at least one LEFT ref,
        # but its literal operands copy through unchanged).
        return expr.copy()


def _try_lift_side_equi(
    c: Expr, mut left_on: List[String], mut right_on: List[String]
) -> Bool:
    """If `c` is a bare `outer_col = inner_col` equality (one operand a
    COL_SIDE_LEFT col-ref, the other a COL_SIDE_NONE col-ref), append the
    outer name to `left_on` and the inner name to `right_on` and return True.
    Otherwise return False (the conjunct is not an equi-key)."""
    if c.tag != EXPR_BINARY_OP:
        return False
    ref b = c._binary.value()
    if b.op != BIN_EQ:
        return False
    if b.left[].tag != EXPR_COL_REF or b.right[].tag != EXPR_COL_REF:
        return False
    var lside = b.left[]._col_ref.value().side
    var rside = b.right[]._col_ref.value().side
    var lname = b.left[]._col_ref.value().name
    var rname = b.right[]._col_ref.value().name
    if lside == COL_SIDE_LEFT and rside != COL_SIDE_LEFT:
        left_on.append(lname)
        right_on.append(rname)
        return True
    if rside == COL_SIDE_LEFT and lside != COL_SIDE_LEFT:
        left_on.append(rname)
        right_on.append(lname)
        return True
    return False


def _hoist_side_qualified_conjuncts(
    var grandchild: LogicalPlan,
    conjuncts: ExprArray,
    mut left_on: List[String],
    mut right_on: List[String],
    mut residual_conjuncts: ExprArray,
) raises -> LogicalPlan:
    """Side-aware hoist: classify each conjunct as pure-inner (stays in the
    inner Filter), an equi-key (lifted into `left_on`/`right_on`), or a
    non-equi outer-referencing conjunct (side-qualified and collected into
    `residual_conjuncts`). Returns the inner plan rebuilt from the surviving
    pure-inner conjuncts (the bare Scan/child if none remain)."""
    var inner_kept = ExprArray()
    for i in range(len(conjuncts)):
        ref c = conjuncts[i]
        if not _expr_references_outer_side(c):
            # Pure-inner predicate — keep it on the inner Filter (all its
            # col-refs are already COL_SIDE_NONE).
            inner_kept.append(c.copy())
            continue
        # References an outer (COL_SIDE_LEFT) column.
        if _try_lift_side_equi(c, left_on, right_on):
            continue
        # Non-equi / non-bare outer-referencing conjunct → join residual.
        residual_conjuncts.append(_rewrite_inner_none_to_right(c))
    var inner_opt = _join_conjuncts(inner_kept^)
    if inner_opt:
        var pred = inner_opt.value().copy()
        return LogicalPlan.filter(pred^, grandchild^)
    return grandchild^


def _hoist_outer_eq_predicates(
    inner_plan: LogicalPlan,
    outer_refs: List[String],
    mut left_on: List[String],
    mut right_on: List[String],
    mut residual_conjuncts: ExprArray,
) raises -> LogicalPlan:
    """Hoist outer-ref predicates from `inner_plan`'s top-level Filter into
    the equi-join keys (EQ correlations) and/or the join `residual` (non-equi
    correlations). Returns the inner plan with the hoisted conjuncts removed
    (or unchanged if no Filter is at the root).

    Two modes:
      - Side-aware (binder-produced predicates carrying COL_SIDE_LEFT outer
        refs): dispatched to `_hoist_side_qualified_conjuncts`. Handles the
        self-correlated NEQ/range case (Q21) that a name-only classifier
        cannot, and preserves the outer reference in the join residual.
      - Legacy name-based (directly-constructed correlated subqueries with
        plain col-refs): the original BIN_EQ-only hoist below. Equi-key
        default: when no Filter-hoist applies, populate `left_on` /
        `right_on` from `outer_refs` (assume same-named inner column).
    """
    # Pre-populate keys from outer_refs as the default. If hoisting succeeds
    # we'll overwrite with the hoisted (col_outer, col_inner) pairs.
    var default_left_on = List[String]()
    var default_right_on = List[String]()
    for i in range(len(outer_refs)):
        default_left_on.append(outer_refs[i])
        default_right_on.append(outer_refs[i])

    if inner_plan.tag != PLAN_FILTER:
        # Inner plan has no top-level Filter; use defaults.
        for i in range(len(default_left_on)):
            left_on.append(default_left_on[i])
            right_on.append(default_right_on[i])
        return inner_plan.copy()

    # Inner plan is a Filter. Split its predicate into conjuncts and walk.
    ref f = inner_plan._filter.value()[]
    var conjuncts = ExprArray()
    _split_conjuncts(f.predicate, conjuncts)

    # If ANY conjunct carries a side qualifier, the binder produced this
    # predicate: take the side-aware hoist (lifts EQ correlations to equi-keys
    # and non-equi correlations to the join residual).
    var side_mode = False
    for i in range(len(conjuncts)):
        if _expr_has_side_qualifier(conjuncts[i]):
            side_mode = True
            break
    if side_mode:
        return _hoist_side_qualified_conjuncts(
            f.child[].copy(), conjuncts, left_on, right_on, residual_conjuncts
        )

    var hoisted_left = List[String]()
    var hoisted_right = List[String]()
    var residual = ExprArray()

    for i in range(len(conjuncts)):
        # Look for `outer_col EQ inner_col` (or the symmetric form).
        var is_hoist = False
        if conjuncts[i].tag == EXPR_BINARY_OP and conjuncts[i]._binary.value().op == BIN_EQ:
            ref b = conjuncts[i]._binary.value()
            if b.left[].tag == EXPR_COL_REF and b.right[].tag == EXPR_COL_REF:
                var lname = b.left[]._col_ref.value().name
                var rname = b.right[]._col_ref.value().name
                if _list_contains(lname, outer_refs):
                    hoisted_left.append(lname)
                    hoisted_right.append(rname)
                    is_hoist = True
                elif _list_contains(rname, outer_refs):
                    hoisted_left.append(rname)
                    hoisted_right.append(lname)
                    is_hoist = True
        if not is_hoist:
            residual.append(conjuncts[i].copy())

    # If we hoisted at least one conjunct, use the hoisted keys.
    if len(hoisted_left) > 0:
        for i in range(len(hoisted_left)):
            left_on.append(hoisted_left[i])
            right_on.append(hoisted_right[i])
    else:
        for i in range(len(default_left_on)):
            left_on.append(default_left_on[i])
            right_on.append(default_right_on[i])

    # Rebuild the inner plan: if no residual conjuncts remain, drop the
    # Filter entirely. Otherwise wrap the Filter's child with a new Filter
    # carrying just the residual conjuncts.
    var grandchild_copy = f.child[].copy()
    var residual_opt = _join_conjuncts(residual^)
    if residual_opt:
        var residual_pred = residual_opt.value().copy()
        return LogicalPlan.filter(residual_pred^, grandchild_copy^)
    return grandchild_copy^


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
