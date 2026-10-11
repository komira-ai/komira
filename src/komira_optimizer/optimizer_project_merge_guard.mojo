# =============================================================================
# optimizer_project_merge_guard — folding Project(outer, Project(inner, gc))
# into ONE Project over gc: the substitution AND the question of whether it is
# safe
# =============================================================================
#
# A projection merge (`optimizer_projection.merge_projects_inplace`, not in this
# tree) folds a Project above a Project by SUBSTITUTING each outer column
# reference with the inner expression that produces it. A substitution that
# descends ColRef / BinaryOp / UnaryOp / Cast / Alias ONLY and returns every
# other node AS BUILT merges an outer MathFn / CASE / string op / window reading
# an inner COMPUTED column into a Project over the grandchild that has no such
# column -- or, when the inner Project REPLACED the column under its own name,
# one that reads the grandchild's ORIGINAL column: a silent wrong answer
# (`SELECT k, sqrt(v) FROM (SELECT k, v*2 AS v FROM t)` would compute sqrt(7)
# where the answer is sqrt(14)).
#
# This module owns BOTH halves, so they cannot drift apart:
#   * `substitute_project_refs` -- the substitution, descending MathFn /
#     MathFn2 / CASE / Substring / StringOp / StringFn / IN list as well (each
#     rebuilt with every other field of its payload preserved);
#   * `projects_merge_safely` -- its exact mirror: every column an outer
#     expression names BELOW a node the substitution still returns as built (a
#     WINDOW, whose input is a column NAME; a regexp; a UDF call; ...) must PASS
#     THROUGH the inner Project unchanged (`ColRef(<same name>)`). Otherwise the
#     two Projects are left standing -- never a dangling or re-pointed
#     reference.
#   * `expr_substitutes_safely` -- the same mirror for ONE expression, for a
#     rewrite that folds a Project into a node other than a Project (Rule 13,
#     `optimizer_join.absorb_expression_into_aggregate`).
#   * `predicate_below_project` -- the same question for a FILTER pushed below
#     a Project (`optimizer_filter.push_predicates_down`). A check BY NAME
#     against the Project's CHILD schema alone passes a Project that REPLACES a
#     name its child also has, and the pushed predicate then reads the ORIGINAL
#     column: in `SELECT k, v FROM (SELECT k, g, v*2 AS v FROM t) q WHERE v > 8`
#     the pushed predicate must be `v * 2 > 8`, not the scan's `v > 8`.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_WHEN,
    EXPR_SUBSTRING,
    EXPR_STRING_OP,
    EXPR_STRING_FN,
    EXPR_IN_LIST,
)
from komira_plan_expr.expr_walk import walk_expr_column_refs, ordered_name_sink
from komira_plan_ir.logical_plan import ExprArray


def substitute_project_refs(
    var expr: Expr,
    inner_names: List[String],
    inner_exprs: ExprArray,
) -> Expr:
    """`expr` with every column reference replaced by the inner Project's
    expression of that name, through ColRef / BinaryOp / UnaryOp / Cast /
    Alias / MathFn / MathFn2 / CASE / Substring / StringOp / StringFn / IN
    list. Any other node is returned AS BUILT -- `projects_merge_safely`
    refuses the merge when that would leave a reference to a computed
    column."""
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        for i in range(len(inner_names)):
            if inner_names[i] == name:
                return inner_exprs[i].copy()
        return expr^
    if expr.tag == EXPR_BINARY_OP:
        var l = substitute_project_refs(
            expr.binary_left_ref().copy(), inner_names, inner_exprs
        )
        var r = substitute_project_refs(
            expr.binary_right_ref().copy(), inner_names, inner_exprs
        )
        return Expr.binary_with_division_intent(
            expr.binary_op(), l^, r^, expr.binary_division_intent()
        )
    if expr.tag == EXPR_UNARY_OP:
        var c = substitute_project_refs(
            expr.unary_child_ref().copy(), inner_names, inner_exprs
        )
        return Expr.unary(expr.unary_op(), c^)
    if expr.tag == EXPR_CAST:
        # `cast_preserving_arrow`: a temporal / decimal target survives.
        var c = substitute_project_refs(
            expr.cast_child_ref().copy(), inner_names, inner_exprs
        )
        return Expr.cast_preserving_arrow(c^, expr)
    if expr.tag == EXPR_ALIAS:
        var c = substitute_project_refs(
            expr.alias_child_ref().copy(), inner_names, inner_exprs
        )
        return Expr.alias(c^, expr.alias_name())
    if expr.tag == EXPR_WHEN:
        # Rebuilt, never mutated: a case's condition / result is an ArcPointer
        # SHARED with every copy of this Expr.
        var cases = List[WhenCaseData]()
        for i in range(expr.when_num_cases()):
            var c = substitute_project_refs(
                expr.when_case_condition_ref(i).copy(), inner_names, inner_exprs
            )
            var r = substitute_project_refs(
                expr.when_case_result_ref(i).copy(), inner_names, inner_exprs
            )
            cases.append(WhenCaseData(c^, r^))
        var d = substitute_project_refs(
            expr.when_default_ref().copy(), inner_names, inner_exprs
        )
        return Expr.when(cases^, d^)
    # The single-child payloads below are OWNED (`OwnedPointer`), so the child
    # is replaced IN PLACE and every other field (op, pattern, start / length,
    # the IN list's values) is kept as built.
    if expr.tag == EXPR_MATH_FN:
        var c = substitute_project_refs(
            expr.math_fn_child_ref().copy(), inner_names, inner_exprs
        )
        expr._math_fn.value().child[] = c^
        return expr^
    if expr.tag == EXPR_MATH_FN2:
        var l = substitute_project_refs(
            expr.math_fn2_left_ref().copy(), inner_names, inner_exprs
        )
        var r = substitute_project_refs(
            expr.math_fn2_right_ref().copy(), inner_names, inner_exprs
        )
        expr._math_fn2.value().left[] = l^
        expr._math_fn2.value().right[] = r^
        return expr^
    if expr.tag == EXPR_SUBSTRING:
        var c = substitute_project_refs(
            expr.substring_child_ref().copy(), inner_names, inner_exprs
        )
        expr._substring.value().child[] = c^
        return expr^
    if expr.tag == EXPR_STRING_OP:
        var c = substitute_project_refs(
            expr.string_op_child_ref().copy(), inner_names, inner_exprs
        )
        expr._string_op.value().child[] = c^
        return expr^
    if expr.tag == EXPR_STRING_FN:
        var c = substitute_project_refs(
            expr.string_fn_child_ref().copy(), inner_names, inner_exprs
        )
        expr._string_fn.value().child[] = c^
        return expr^
    if expr.tag == EXPR_IN_LIST:
        var c = substitute_project_refs(
            expr.in_list_child_ref().copy(), inner_names, inner_exprs
        )
        expr._in_list.value().child[] = c^
        return expr^
    return expr^


def _is_col_named(e: Expr, name: String) -> Bool:
    """`ColRef(name)`, under any number of `Alias(.., name)` layers."""
    if e.tag == EXPR_ALIAS:
        return e.alias_name() == name and _is_col_named(e.alias_child_ref(), name)
    return e.tag == EXPR_COL_REF and e.col_ref_name() == name


def _passes_through(
    name: String, inner_names: List[String], inner_exprs: ExprArray
) -> Bool:
    """True when the inner Project outputs `name` as `ColRef(name)` (or an
    `Alias(ColRef(name), name)`, a form a plan builder may author for a kept
    column; refusing it would refuse merges that are safe)."""
    for i in range(len(inner_names)):
        if inner_names[i] == name:
            return _is_col_named(inner_exprs[i], name)
    return False


def _every_ref_reachable(
    e: Expr, inner_names: List[String], inner_exprs: ExprArray
) -> Bool:
    """Mirror of `substitute_project_refs`: True when every column reference
    in `e` is either substituted by it or survives it intact."""
    if e.tag == EXPR_COL_REF or e.tag == EXPR_LITERAL:
        return True
    if e.tag == EXPR_BINARY_OP:
        return _every_ref_reachable(
            e.binary_left_ref(), inner_names, inner_exprs
        ) and _every_ref_reachable(e.binary_right_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_UNARY_OP:
        return _every_ref_reachable(e.unary_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_CAST:
        return _every_ref_reachable(e.cast_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_ALIAS:
        return _every_ref_reachable(e.alias_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_MATH_FN:
        return _every_ref_reachable(e.math_fn_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_MATH_FN2:
        return _every_ref_reachable(
            e.math_fn2_left_ref(), inner_names, inner_exprs
        ) and _every_ref_reachable(e.math_fn2_right_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_WHEN:
        for i in range(e.when_num_cases()):
            if not _every_ref_reachable(
                e.when_case_condition_ref(i), inner_names, inner_exprs
            ):
                return False
            if not _every_ref_reachable(
                e.when_case_result_ref(i), inner_names, inner_exprs
            ):
                return False
        return _every_ref_reachable(e.when_default_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_SUBSTRING:
        return _every_ref_reachable(e.substring_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_STRING_OP:
        return _every_ref_reachable(e.string_op_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_STRING_FN:
        return _every_ref_reachable(e.string_fn_child_ref(), inner_names, inner_exprs)
    if e.tag == EXPR_IN_LIST:
        return _every_ref_reachable(e.in_list_child_ref(), inner_names, inner_exprs)
    # Returned AS BUILT by the substitution: each name it reads must exist,
    # unchanged, below the inner Project.
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(e, sink)
    for i in range(len(names)):
        if not _passes_through(names[i], inner_names, inner_exprs):
            return False
    return True


def expr_substitutes_safely(
    e: Expr, inner_names: List[String], inner_exprs: ExprArray
) -> Bool:
    """True when `substitute_project_refs(e, ..)` leaves NO reference to a
    column the inner Project computes or replaces -- the per-expression form
    of `projects_merge_safely`, for a rewrite that folds a Project into a
    node other than a Project (Rule 13, `absorb_expression_into_aggregate`)."""
    return _every_ref_reachable(e, inner_names, inner_exprs)


def projects_merge_safely(
    outer_exprs: ExprArray, inner_names: List[String], inner_exprs: ExprArray
) -> Bool:
    """May the outer Project be folded through the inner one? See the module
    header."""
    for i in range(len(outer_exprs)):
        if not _every_ref_reachable(outer_exprs[i], inner_names, inner_exprs):
            return False
    return True


def _row_local(e: Expr) -> Bool:
    """A column / literal / arithmetic / unary / alias tree: its value for a
    row depends on that row alone, so a predicate may read it BELOW the
    Project that computes it.

    ⛔ NOT a MathFn, a MathFn2 or a CAST, although each is row-local: each can
    RAISE on a value outside its domain (`sqrt` / `ln` of a negative, a
    narrowing cast), and a predicate pushed below the Project is pushed on
    past any FILTER under it (the filter-over-filter arm swaps them), so it
    meets rows that guard excluded. In `SELECT k FROM (SELECT k, sqrt(x) AS x
    FROM t WHERE x >= 0) q WHERE x > 1`, `sqrt(x) > 1` pushed below the
    `x >= 0` filter would take the square root of a negative x. A predicate
    over one of those stays ABOVE the Project. (Integer `+ - *` can raise on
    OVERFLOW the same way; that residual is accepted -- it needs a guard that
    excludes overflowing rows.)
    A window, a CASE, a string op or a UDF is not taken either."""
    if e.tag == EXPR_COL_REF or e.tag == EXPR_LITERAL:
        return True
    if e.tag == EXPR_BINARY_OP:
        return _row_local(e.binary_left_ref()) and _row_local(
            e.binary_right_ref()
        )
    if e.tag == EXPR_UNARY_OP:
        return _row_local(e.unary_child_ref())
    if e.tag == EXPR_ALIAS:
        return _row_local(e.alias_child_ref())
    return False


def predicate_below_project(
    pred: Expr, proj_names: List[String], proj_exprs: ExprArray
) -> Optional[Expr]:
    """The predicate that means BELOW a Project (output `proj_names`,
    computed by `proj_exprs`) what `pred` means ABOVE it, or None -- keep the
    FILTER above the Project.

    * every column `pred` names PASSES THROUGH (`ColRef(n)` / `Alias(ColRef(n),
      n)`): `pred` itself;
    * else every one is a ROW-LOCAL, NON-RAISING expression (`_row_local`)
      and `pred` is a tree `substitute_project_refs` rewrites completely
      (`expr_substitutes_safely`): `pred` with those expressions SUBSTITUTED,
      each without its output alias -- DuckDB's rule
      (`pushdown_projection.cpp`); `v > 8` over `v * 2 AS v` is `v * 2 > 8`.
      (The alias is stripped because an alias inside a comparison is not a
      column reference; a consumer that resolves comparison operands to
      columns could not resolve it.)
    * else None."""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(pred, sink)
    var all_pass = True
    for i in range(len(names)):
        var found = False
        for c in range(len(proj_names)):
            if proj_names[c] == names[i]:
                found = True
                if c >= len(proj_exprs):
                    return None
                if not _is_col_named(proj_exprs[c], names[i]):
                    all_pass = False
                    if not _row_local(proj_exprs[c]):
                        return None
                break
        if not found:
            return None
    if all_pass:
        return Optional[Expr](pred.copy())
    if not expr_substitutes_safely(pred, proj_names, proj_exprs):
        return None
    var bare = ExprArray()
    for c in range(len(proj_exprs)):
        var e = proj_exprs[c].copy()
        while e.tag == EXPR_ALIAS:
            var inner = e.alias_child_ref().copy()
            e = inner^
        bare.append(e^)
    return Optional[Expr](substitute_project_refs(pred.copy(), proj_names, bare))
