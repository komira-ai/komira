# =============================================================================
# Symmetric OR decomposition
# =============================================================================
#
# Literal port of the v0.3 Rust planner's `decompose_symmetric_or`.
#
# Detects cross-column symmetric swap OR patterns and infers single-column
# IN predicates that can be pushed through joins / filters independently.
#
# Pattern (form 1 -- same column order on both sides):
#
#     (A == x AND B == y) OR (A == y AND B == x)
#
# Pattern (form 2 -- transposed column order on the RHS):
#
#     (A == x AND B == y) OR (B == x AND A == y)
#
# In both cases we rewrite to:
#
#     (A IN {x, y}) AND (B IN {x, y}) AND ORIGINAL_OR
#
# where IN {x, y} is expressed as `(col == x) OR (col == y)`.
#
# The new AND conjuncts are single-column, pushable predicates; predicate
# pushdown (Rule 2, `push_predicates_down`) can then push them through joins
# independently. `optimizer_driver.optimize` runs this pass BEFORE
# push_predicates_down. The original OR is kept
# as a conjunct (above the join when it reads both sides) so semantics are
# exactly equivalent -- it rejects any tuple not on the swap diagonal.
#
# Restriction (per v0.3 literal): operands of each `==` MUST be a
# `ColRef`/`Literal` pair. Any UDF, arithmetic, cast, or computed
# expression aborts the match (returns the OR untouched). This avoids
# speculatively lifting non-deterministic or expensive subexpressions.
#
# Mojo port notes:
#   - v0.3 uses `PartialEq` on `Expr` literals via `scalar_values_equal`.
#     Mojo's Expr has no PartialEq; we use `_expr_fingerprint` on literal
#     expressions to get canonical string equality (handles Int/Float/
#     String/Bool uniformly via the existing helper).
#   - v0.3 uses `map_children` to recurse; Mojo has no such helper so we
#     manually traverse each PLAN_* variant (same pattern as
#     fuse_filters / push_predicates_down).
#   - v0.3 recurses into the OR *children* on no-match so nested swap
#     patterns are still detected. We replicate this literally.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    BIN_AND,
    BIN_OR,
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
)
from komira_plan_ir.plan_helpers import (
    _copy_expr_array,
    _copy_agg_expr_array,
    _expr_fingerprint,
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
# Public entry -- plan walker
# =============================================================================


def decompose_symmetric_or(var plan: LogicalPlan) -> LogicalPlan:
    """Rewrite symmetric-swap OR predicates in every Filter node.

    Wrapper around `decompose_symmetric_or_inplace`.
    """
    decompose_symmetric_or_inplace(plan)
    return plan^


def decompose_symmetric_or_inplace(mut plan: LogicalPlan):
    """In-place symmetric-OR decomposition.

    Recurses children IN PLACE. The Filter predicate is mutated in place
    when a swap-OR pattern is found; tree shape never changes.
    """
    if plan.tag == PLAN_FILTER:
        decompose_symmetric_or_inplace(plan._filter.value()[].child[])
        var pred_copy = plan._filter.value()[].predicate.copy()
        var new_pred = decompose_symmetric_or_expr(pred_copy^)
        plan._filter.value()[].predicate = new_pred^

    elif plan.tag == PLAN_PROJECT:
        decompose_symmetric_or_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        decompose_symmetric_or_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        decompose_symmetric_or_inplace(plan._join.value()[].left[])
        decompose_symmetric_or_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        decompose_symmetric_or_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        decompose_symmetric_or_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        decompose_symmetric_or_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        decompose_symmetric_or_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN (leaf) -- nothing to do. PLAN_PARTITION_*, PLAN_ASOF_JOIN
    # also untouched (not a target of this rule).


# =============================================================================
# Expression walker -- detect + rewrite OR
# =============================================================================


def decompose_symmetric_or_expr(var expr: Expr) -> Expr:
    """Apply symmetric-OR decomposition to an expression tree.

    Walks the expression looking for `OR` nodes that match the symmetric
    swap pattern. When a match is found, returns the rewritten
    `(A_IN) AND (B_IN) AND ORIGINAL_OR`. Otherwise recurses into both
    AND/OR children so nested matches are still found.
    """
    if expr.tag != EXPR_BINARY_OP:
        return expr^

    var op = expr.binary_op()

    if op == BIN_OR:
        # Attempt to decompose this OR.
        var maybe_rewrite = _try_decompose_symmetric_swap(
            expr.binary_left_ref(), expr.binary_right_ref()
        )
        if maybe_rewrite:
            return maybe_rewrite.take()
        # Not a swap -- recurse into children so nested ORs still get
        # a chance to match.
        var left = decompose_symmetric_or_expr(expr.binary_left().copy())
        var right = decompose_symmetric_or_expr(expr.binary_right().copy())
        return Expr.binary(BIN_OR, left^, right^)

    if op == BIN_AND:
        var left = decompose_symmetric_or_expr(expr.binary_left().copy())
        var right = decompose_symmetric_or_expr(expr.binary_right().copy())
        return Expr.binary(BIN_AND, left^, right^)

    # Any other binary op (EQ, arithmetic, comparison) -- leaf for this
    # rule. v0.3 only recurses into AND/OR; other ops are returned as-is.
    return expr^


# =============================================================================
# Core pattern matcher
# =============================================================================


def _try_decompose_symmetric_swap(left: Expr, right: Expr) -> Optional[Expr]:
    """Detect the symmetric swap pattern on `(left) OR (right)`.

    Returns `Some(rewritten_expr)` on match. Both forms are checked:

    Form 1: left = (A==x AND B==y), right = (A==y AND B==x)
            -> a_col==c_col, b_col==d_col, a_val==d_val, b_val==c_val

    Form 2: left = (A==x AND B==y), right = (B==x AND A==y)
            -> a_col==d_col, b_col==c_col, a_val==c_val, b_val==d_val
    """
    # Extract `(col1, val1, col2, val2)` from each conjunct-AND.
    var lhs = _extract_eq_pair(left)
    if not lhs:
        return None
    var rhs = _extract_eq_pair(right)
    if not rhs:
        return None

    ref lp = lhs.value()
    ref rp = rhs.value()

    var a_col = lp.col1
    var a_val_fp = lp.val1_fp
    var b_col = lp.col2
    var b_val_fp = lp.val2_fp

    var c_col = rp.col1
    var c_val_fp = rp.val1_fp
    var d_col = rp.col2
    var d_val_fp = rp.val2_fp

    # Reject self-symmetric same-column predicates: the swap only makes
    # sense when the two conjunct columns differ. Without this guard,
    # `(A==x AND A==y) OR (A==y AND A==x)` would match form 1 trivially
    # but the rewrite would emit a redundant conjunct; v0.3 is quietly protected
    # by its downstream pushdown refusing same-col AND, but we bail
    # early for clarity.
    if a_col == b_col:
        return None

    # Form 1: (A==x AND B==y) OR (A==y AND B==x)
    if (
        a_col == c_col
        and b_col == d_col
        and a_val_fp == d_val_fp
        and b_val_fp == c_val_fp
    ):
        return _build_rewrite(
            a_col, b_col,
            lp.val1_expr, lp.val2_expr,
            left, right,
        )

    # Form 2: (A==x AND B==y) OR (B==x AND A==y)
    if (
        a_col == d_col
        and b_col == c_col
        and a_val_fp == c_val_fp
        and b_val_fp == d_val_fp
    ):
        return _build_rewrite(
            a_col, b_col,
            lp.val1_expr, lp.val2_expr,
            left, right,
        )

    return None


# =============================================================================
# Rewrite builder
# =============================================================================


def _build_rewrite(
    a_col: String, b_col: String,
    val1: Expr, val2: Expr,
    orig_left: Expr, orig_right: Expr,
) -> Expr:
    """Emit `(A IN {v1,v2}) AND (B IN {v1,v2}) AND (orig_left OR orig_right)`."""
    var a_in = _make_in_expr(a_col, val1.copy(), val2.copy())
    var b_in = _make_in_expr(b_col, val1.copy(), val2.copy())
    var original_or = Expr.binary(BIN_OR, orig_left.copy(), orig_right.copy())
    var ab_in = Expr.binary(BIN_AND, a_in^, b_in^)
    return Expr.binary(BIN_AND, ab_in^, original_or^)


def _make_in_expr(col_name: String, var val1: Expr, var val2: Expr) -> Expr:
    """Build `col == val1 OR col == val2` (a 2-element IN list as OR)."""
    var eq1 = Expr.binary(BIN_EQ, Expr.col_ref(col_name.copy()), val1^)
    var eq2 = Expr.binary(BIN_EQ, Expr.col_ref(col_name.copy()), val2^)
    return Expr.binary(BIN_OR, eq1^, eq2^)


# =============================================================================
# Pair extraction helpers
# =============================================================================


@fieldwise_init
struct _EqPair(Movable):
    """Extracted shape: `(col1 == val1) AND (col2 == val2)`.

    Carries both the deep-copied literal Exprs (for building the
    rewrite) and their canonical fingerprints (for cross-conjunct
    equality comparison). Fingerprint comparison is the Mojo
    equivalent of v0.3's `scalar_values_equal`: handles Int / Float /
    String / Bool uniformly.
    """
    var col1: String
    var val1_expr: Expr
    var val1_fp: String
    var col2: String
    var val2_expr: Expr
    var val2_fp: String


def _extract_eq_pair(expr: Expr) -> Optional[_EqPair]:
    """Return `(col1, val1, col2, val2)` if expr is `(c1==v1) AND (c2==v2)`.

    Returns None unless the expression is exactly two `ColRef==Literal`
    comparisons joined by a single AND. UDFs, casts, arithmetic, and
    nested ANDs all fail the match (v0.3 behavior).
    """
    if expr.tag != EXPR_BINARY_OP:
        return None
    if expr.binary_op() != BIN_AND:
        return None

    var e1 = _extract_column_eq_literal(expr.binary_left_ref())
    if not e1:
        return None
    var e2 = _extract_column_eq_literal(expr.binary_right_ref())
    if not e2:
        return None

    ref a = e1.value()
    ref b = e2.value()

    return _EqPair(
        a.name.copy(),
        a.val.copy(),
        _expr_fingerprint(a.val),
        b.name.copy(),
        b.val.copy(),
        _expr_fingerprint(b.val),
    )


@fieldwise_init
struct _ColEqLit(Movable):
    var name: String
    var val: Expr


def _extract_column_eq_literal(expr: Expr) -> Optional[_ColEqLit]:
    """Return `(col_name, literal_expr)` from `col == literal` or `literal == col`.

    Restriction: both operands must be exactly ColRef and Literal. Any
    other shape (UDF / arithmetic / cast / nested expr) returns None.
    Literal-on-left form is accepted for commutativity, matching v0.3.
    """
    if expr.tag != EXPR_BINARY_OP:
        return None
    if expr.binary_op() != BIN_EQ:
        return None

    ref l = expr.binary_left_ref()
    ref r = expr.binary_right_ref()

    # Column == Literal
    if l.tag == EXPR_COL_REF and r.tag == EXPR_LITERAL:
        return _ColEqLit(l.col_ref_name(), r.copy())
    # Literal == Column
    if l.tag == EXPR_LITERAL and r.tag == EXPR_COL_REF:
        return _ColEqLit(r.col_ref_name(), l.copy())
    return None
