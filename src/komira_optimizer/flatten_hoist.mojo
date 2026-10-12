# =============================================================================
# flatten_hoist: the outer-reference hoist of `flatten_dependent_joins`
# =============================================================================
#
# When `flatten_dependent_joins` lowers a correlated subquery into a join, the
# subquery's inner plan may start with a Filter whose conjuncts read outer
# columns. This module splits that Filter: a conjunct that reads only inner
# columns stays on the inner side; an `outer = inner` equality becomes an
# equi-join key; any other conjunct that reads an outer column becomes the
# join `residual` (outer refs marked COL_SIDE_LEFT, inner refs COL_SIDE_RIGHT).
# No conjunct that reads an outer column stays on the inner side, where that
# column does not exist; a conjunct the hoist cannot classify is refused.
#
# Refusals (the error message starts with the code):
#   FLATTEN_AMBIGUOUS_OUTER_REF  a plain-name conjunct that is not a hoistable
#                                equality names an outer reference the inner
#                                side also produces, so a name cannot say
#                                which side it reads.
#   FLATTEN_OPAQUE_CORRELATION   a conjunct names an outer reference under an
#                                expression kind the side classification and
#                                the residual rewrite do not descend.
# =============================================================================

from std.collections import Optional

from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_AGG_FN,
    EXPR_IN_LIST,
    BIN_EQ,
    BIN_AND,
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    WhenCaseData,
)
from komira_plan_expr.expr_walk import walk_expr_column_refs, ordered_name_sink
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray, PLAN_FILTER


comptime FLATTEN_AMBIGUOUS_OUTER_REF: String = "FlattenAmbiguousOuterRef"
"""Refusal code: a plain-name correlation names a column both sides produce."""

comptime FLATTEN_OPAQUE_CORRELATION: String = "FlattenOpaqueCorrelation"
"""Refusal code: an outer reference under an expression kind the hoist does
not descend."""


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


def _column_names(expr: Expr) -> List[String]:
    """Every column name `expr` reads, through the one complete column walk
    (`walk_expr_column_refs`), whatever its expression kinds."""
    var out = List[String]()
    var sink = ordered_name_sink(out)
    walk_expr_column_refs(expr, sink)
    return out^


def _names_any_of(expr: Expr, names: List[String]) -> Bool:
    """True if `expr` reads a column whose name is in `names`."""
    var read = _column_names(expr)
    for i in range(len(read)):
        if _list_contains(read[i], names):
            return True
    return False


def _expr_hoist_visible(expr: Expr) -> Bool:
    """True if every node of `expr` is a kind that `_expr_has_side_qualifier`,
    `_expr_references_outer_side` and `_rewrite_sides` all descend (col-ref,
    literal, binary, unary, cast, alias, string op, CASE, IN list, aggregate
    call). A conjunct with any other kind may hide an outer reference from
    the side walkers and keep a plain inner ref through the residual
    rewrite, so the hoist refuses it when it names an outer reference."""
    if expr.tag == EXPR_COL_REF or expr.tag == EXPR_LITERAL:
        return True
    if expr.tag == EXPR_BINARY_OP:
        return _expr_hoist_visible(expr.binary_left_ref()) and _expr_hoist_visible(
            expr.binary_right_ref()
        )
    if expr.tag == EXPR_UNARY_OP:
        return _expr_hoist_visible(expr.unary_child_ref())
    if expr.tag == EXPR_CAST:
        return _expr_hoist_visible(expr.cast_child_ref())
    if expr.tag == EXPR_ALIAS:
        return _expr_hoist_visible(expr.alias_child_ref())
    if expr.tag == EXPR_STRING_OP:
        return _expr_hoist_visible(expr.string_op_child_ref())
    if expr.tag == EXPR_IN_LIST:
        return _expr_hoist_visible(expr._in_list.value().child[])
    if expr.tag == EXPR_AGG_FN:
        return _expr_hoist_visible(expr.agg_fn_child_ref())
    if expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        for i in range(len(wd.cases)):
            if not _expr_hoist_visible(wd.cases[i].condition[]):
                return False
            if not _expr_hoist_visible(wd.cases[i].result[]):
                return False
        return _expr_hoist_visible(wd.default[])
    return False


def _refuse_opaque(c: Expr, outer_refs: List[String]) raises:
    """Raise FLATTEN_OPAQUE_CORRELATION if `c` names an outer reference and
    holds an expression kind the hoist does not descend."""
    if _names_any_of(c, outer_refs) and not _expr_hoist_visible(c):
        raise Error(
            FLATTEN_OPAQUE_CORRELATION
            + ": a correlated conjunct names an outer reference under an"
            " expression kind the outer-reference hoist does not descend"
        )


# =============================================================================
# Outer-ref hoist
# =============================================================================
#
# DuckDB's `FlattenDependentJoins::RewriteCorrelatedExpressions` walks the
# inner plan and classifies predicate-pieces by whether they reference
# outer-scope columns. Pieces that touch outer refs are HOISTED into the
# join's `on=` clause. Pieces that touch only inner columns stay inside the
# inner plan.
#
# This pass adopts a conservative single-level hoist:
#   - If the inner plan is `Filter(child, predicate)`, split `predicate` into
#     its AND conjuncts and classify each: an `outer = inner` equality lifts
#     into the join's left_on/right_on lists, any other conjunct reading an
#     outer column lifts into the join residual, and the rest stay in a
#     (possibly simpler) Filter over `child` (dropped when none remain).
#   - Otherwise (no Filter at the root, or a Filter none of whose conjuncts
#     reads an outer column on the plain-name path): equi-keys default to
#     the outer_refs (i.e. assume the inner schema exposes a same-named
#     column for each outer_ref). This matches the Q4/Q17/Q20/Q21 shapes
#     which all have implicit-name join columns.
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
# side-aware hoist path below; otherwise we take the name-based hoist
# (`_hoist_name_conjuncts`, for directly-constructed correlated subqueries
# with plain col-refs).
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
# Name-based hoist per conjunct (no side qualifiers anywhere): an outer
# reference is a name in the subquery's `outer_refs`. One the inner side
# does not produce ("outer-only") can only be the outer column; one the
# inner side also produces is ambiguous by name.
#   - `a = b` with `a` in outer_refs and `b` not outer-only (or the mirror)
#     → LIFTED into the equi-join keys (`a` outer, `b` inner); this keeps the
#     same-name self-correlation `l_partkey = l_partkey` (Q17) a key.
#   - reads no outer_refs name  → pure-inner, stays in the inner Filter.
#   - reads an ambiguous name  → refused (FLATTEN_AMBIGUOUS_OUTER_REF).
#   - reads an outer-only name  → join residual, outer-only names marked
#     LEFT and every other ref RIGHT.
#
# This preserves the outer reference through the flatten — the pre-fix bug was
# that a non-EQ outer conjunct stayed in the inner Filter where BOTH sides
# rebind to the inner column, collapsing to a tautology (`l_suppkey <>
# l_suppkey`) and silently dropping the correlation; on the name-based path
# the conjunct stayed in the inner Filter naming a column the inner side
# does not produce.
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
    if expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        for i in range(len(wd.cases)):
            if _expr_has_side_qualifier(wd.cases[i].condition[]):
                return True
            if _expr_has_side_qualifier(wd.cases[i].result[]):
                return True
        return _expr_has_side_qualifier(wd.default[])
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
    if expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        for i in range(len(wd.cases)):
            if _expr_references_outer_side(wd.cases[i].condition[]):
                return True
            if _expr_references_outer_side(wd.cases[i].result[]):
                return True
        return _expr_references_outer_side(wd.default[])
    return False


def _rewrite_inner_none_to_right(expr: Expr) -> Expr:
    """Deep-copy `expr` re-marking every plain (COL_SIDE_NONE) col-ref as
    COL_SIDE_RIGHT while keeping COL_SIDE_LEFT (outer) refs as LEFT. Used when
    lifting a non-equi outer-referencing conjunct into the join residual: the
    outer refs stay LEFT and the subquery's own columns become RIGHT, giving
    `join_predicate_decompose` the side-qualified shape it rewrites into the
    joined-row schema (with the `_right` self-join collision rename)."""
    return _rewrite_sides(expr, List[String]())


def _rewrite_sides(expr: Expr, outer_names: List[String]) -> Expr:
    """Deep-copy `expr` marking each col-ref COL_SIDE_LEFT when it is already
    LEFT or is a plain ref whose name is in `outer_names`, and COL_SIDE_RIGHT
    otherwise. The side-aware hoist passes no names (only LEFT refs stay
    LEFT); the name-based hoist passes its outer-only names."""
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        if expr.col_ref_side() == COL_SIDE_LEFT:
            return Expr.left(name)
        if expr.col_ref_side() == COL_SIDE_NONE and _list_contains(name, outer_names):
            return Expr.left(name)
        return Expr.right(name)
    elif expr.tag == EXPR_BINARY_OP:
        return Expr.binary(
            expr.binary_op(),
            _rewrite_sides(expr.binary_left_ref(), outer_names),
            _rewrite_sides(expr.binary_right_ref(), outer_names),
        )
    elif expr.tag == EXPR_UNARY_OP:
        return Expr.unary(
            expr.unary_op(), _rewrite_sides(expr.unary_child_ref(), outer_names)
        )
    elif expr.tag == EXPR_CAST:
        return Expr.cast(
            _rewrite_sides(expr.cast_child_ref(), outer_names), expr.cast_target()
        )
    elif expr.tag == EXPR_STRING_OP:
        return Expr.string_op(
            expr.string_op_type(),
            _rewrite_sides(expr.string_op_child_ref(), outer_names),
            expr.string_op_pattern(),
        )
    elif expr.tag == EXPR_ALIAS:
        return Expr.alias(
            _rewrite_sides(expr.alias_child_ref(), outer_names), expr.alias_name()
        )
    elif expr.tag == EXPR_WHEN:
        ref wd = expr._when.value()
        var cases = List[WhenCaseData]()
        for i in range(len(wd.cases)):
            cases.append(WhenCaseData(
                _rewrite_sides(wd.cases[i].condition[], outer_names),
                _rewrite_sides(wd.cases[i].result[], outer_names),
            ))
        return Expr.when(cases^, _rewrite_sides(wd.default[], outer_names))
    elif expr.tag == EXPR_IN_LIST:
        ref il = expr._in_list.value()
        var vals = List[ScalarValue]()
        for i in range(len(il.values)):
            vals.append(il.values[i].copy())
        return Expr.in_list_node(_rewrite_sides(il.child[], outer_names), vals^)
    elif expr.tag == EXPR_AGG_FN:
        return Expr.agg_fn(
            expr.agg_fn_op(), _rewrite_sides(expr.agg_fn_child_ref(), outer_names)
        )
    else:
        # Literals and the kinds `_expr_hoist_visible` refuses: no col-ref
        # this rewrite descends into. A conjunct that names an outer
        # reference under a refused kind never reaches here
        # (`_refuse_opaque`).
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
    outer_refs: List[String],
    mut left_on: List[String],
    mut right_on: List[String],
    mut residual_conjuncts: ExprArray,
) raises -> LogicalPlan:
    """Side-aware hoist: classify each conjunct as pure-inner (stays in the
    inner Filter), an equi-key (lifted into `left_on`/`right_on`), or a
    non-equi outer-referencing conjunct (side-qualified and collected into
    `residual_conjuncts`). Returns the inner plan rebuilt from the surviving
    pure-inner conjuncts (the bare Scan/child if none remain). Refuses a
    conjunct naming an outer reference under a kind the side walkers do not
    descend (`_refuse_opaque`)."""
    var inner_kept = ExprArray()
    for i in range(len(conjuncts)):
        ref c = conjuncts[i]
        _refuse_opaque(c, outer_refs)
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


def _try_lift_name_equi(
    c: Expr,
    outer_refs: List[String],
    outer_only: List[String],
    mut left_on: List[String],
    mut right_on: List[String],
) -> Bool:
    """If `c` is a bare `a = b` of plain col-refs with `a` in `outer_refs` and
    `b` not in `outer_only` (or the mirror), append the outer name to
    `left_on` and the inner name to `right_on` and return True. An equality
    of two outer-only names reads no inner column and is not a key."""
    if c.tag != EXPR_BINARY_OP:
        return False
    ref b = c._binary.value()
    if b.op != BIN_EQ:
        return False
    if b.left[].tag != EXPR_COL_REF or b.right[].tag != EXPR_COL_REF:
        return False
    var lname = b.left[]._col_ref.value().name
    var rname = b.right[]._col_ref.value().name
    if _list_contains(lname, outer_refs) and not _list_contains(rname, outer_only):
        left_on.append(lname)
        right_on.append(rname)
        return True
    if _list_contains(rname, outer_refs) and not _list_contains(lname, outer_only):
        left_on.append(rname)
        right_on.append(lname)
        return True
    return False


def _hoist_name_conjuncts(
    var grandchild: LogicalPlan,
    conjuncts: ExprArray,
    outer_refs: List[String],
    mut left_on: List[String],
    mut right_on: List[String],
    mut residual_conjuncts: ExprArray,
) raises -> LogicalPlan:
    """Name-based hoist (plain col-refs only): classify each conjunct as an
    equi-key, pure-inner, or a residual conjunct reading an outer-only name
    (see the section comment above), refusing an ambiguous name. When no
    conjunct reads an outer reference, the keys default to the outer_refs.
    Returns the inner plan rebuilt from the pure-inner conjuncts."""
    var outer_only = List[String]()
    for i in range(len(outer_refs)):
        if not _schema_has_field(grandchild.output_schema, outer_refs[i]):
            outer_only.append(outer_refs[i])

    var inner_kept = ExprArray()
    var correlated = False
    for i in range(len(conjuncts)):
        ref c = conjuncts[i]
        if _try_lift_name_equi(c, outer_refs, outer_only, left_on, right_on):
            correlated = True
            continue
        var names = _column_names(c)
        var reads_outer = False
        for j in range(len(names)):
            if _list_contains(names[j], outer_only):
                reads_outer = True
            elif _list_contains(names[j], outer_refs):
                raise Error(
                    FLATTEN_AMBIGUOUS_OUTER_REF + ": " + names[j]
                    + " is an outer reference and an inner column; a plain"
                    " name cannot say which one the conjunct reads"
                )
        if not reads_outer:
            inner_kept.append(c.copy())
            continue
        _refuse_opaque(c, outer_refs)
        residual_conjuncts.append(_rewrite_sides(c, outer_only))
        correlated = True

    if not correlated:
        for i in range(len(outer_refs)):
            left_on.append(outer_refs[i])
            right_on.append(outer_refs[i])

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
      - Name-based (directly-constructed correlated subqueries with plain
        col-refs): dispatched to `_hoist_name_conjuncts`.
    With no Filter at the root, `left_on` / `right_on` default to
    `outer_refs` (assume a same-named inner column).
    """
    if inner_plan.tag != PLAN_FILTER:
        # Inner plan has no top-level Filter; use defaults.
        for i in range(len(outer_refs)):
            left_on.append(outer_refs[i])
            right_on.append(outer_refs[i])
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
            f.child[].copy(), conjuncts, outer_refs, left_on, right_on,
            residual_conjuncts,
        )
    return _hoist_name_conjuncts(
        f.child[].copy(), conjuncts, outer_refs, left_on, right_on,
        residual_conjuncts,
    )
