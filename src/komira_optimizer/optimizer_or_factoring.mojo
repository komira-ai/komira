# =============================================================================
# OR-conjunct factoring
# =============================================================================
#
# Walks every Filter predicate's expression tree, finds OR-rooted subtrees,
# and hoists conjuncts present in EVERY OR branch above the OR. The
# canonical Q19 shape is:
#
#     WHERE
#       (   p_brand IN (...) AND l_shipinstruct = 'DELIVER...' AND l_shipmode IN (...) AND <branch1>)
#     OR (   p_brand IN (...) AND l_shipinstruct = 'DELIVER...' AND l_shipmode IN (...) AND <branch2>)
#     OR (   p_brand IN (...) AND l_shipinstruct = 'DELIVER...' AND l_shipmode IN (...) AND <branch3>)
#
# Rewritten into:
#
#     WHERE
#       p_brand IN (...) AND l_shipinstruct = 'DELIVER...' AND l_shipmode IN (...)
#       AND ( <branch1> OR <branch2> OR <branch3> )
#
# Common conjuncts evaluate ONCE rather than 3 times. Subsequent
# `push_predicates_down` then routes the hoisted conjuncts into scans /
# under joins.
#
# Correctness via boolean distributivity:
#
#   (P AND Q1) OR (P AND Q2) OR (P AND Q3)  is logically equivalent to
#   P AND (Q1 OR Q2 OR Q3)
#
# Conservative on non-pure expressions: a branch with EXPR_AGG_FN /
# EXPR_WINDOW_FN / EXPR_WHEN at its root or under binary operators halts the
# rewrite for that OR (sub-branches still get a chance via the recursive
# descent).
#
# Pass order: komira_optimizer has no driver that orders its passes. This
# pass is designed to run BEFORE `push_predicates_down` so the newly
# hoisted conjuncts become predicate-pushdown candidates. Same shape as
# `decompose_symmetric_or` -- see `optimizer_symmetric_or.mojo`.
#
# Plan-IR purity: pure plan transform, no FileHandle reach, no
# optimizer context required. Single recursive `def` walker is safe
# (the monomorphization trap requires parametric + recursive + FileHandle, all three
# missing here).
# =============================================================================

from std.collections import Dict
from std.memory import OwnedPointer

from komira_collections.slab import Slab

from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_LITERAL,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_WHEN,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
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
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
)

from komira_plan_ir.plan_helpers import _expr_fingerprint


# =============================================================================
# Per-branch conjunct bundle
# =============================================================================
#
# Holds the conjuncts of one OR branch + their fingerprints. Movable-only
# because the inner `Slab[Expr]` owns Expr nodes (which themselves own
# OwnedPointer children). Stored inside a `Slab[BranchConjuncts]` so we
# can have a per-branch list without requiring Copyable.

struct BranchConjuncts(Movable):
    var conjuncts: ExprArray
    var fingerprints: List[String]

    def __init__(out self):
        self.conjuncts = ExprArray()
        self.fingerprints = List[String]()


# =============================================================================
# Public entry — plan walker (in-place; mirrors decompose_symmetric_or shape)
# =============================================================================


def factor_or_conjuncts(var plan: LogicalPlan) -> LogicalPlan:
    """Wrapper around `factor_or_conjuncts_inplace` for legacy callers."""
    factor_or_conjuncts_inplace(plan)
    return plan^


def factor_or_conjuncts_inplace(mut plan: LogicalPlan):
    """In-place OR-conjunct factoring rule.

    Recurses children IN PLACE. The Filter predicate is mutated in
    place when an OR-rewrite fires; tree shape never changes at the
    Filter node (we always end up with a (possibly new) Expr in
    `predicate`).
    """
    if plan.tag == PLAN_FILTER:
        factor_or_conjuncts_inplace(plan._filter.value()[].child[])
        var pred_copy = plan._filter.value()[].predicate.copy()
        var new_pred = factor_or_conjuncts_expr(pred_copy^)
        plan._filter.value()[].predicate = new_pred^

    elif plan.tag == PLAN_PROJECT:
        factor_or_conjuncts_inplace(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        factor_or_conjuncts_inplace(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        factor_or_conjuncts_inplace(plan._join.value()[].left[])
        factor_or_conjuncts_inplace(plan._join.value()[].right[])

    elif plan.tag == PLAN_SORT:
        factor_or_conjuncts_inplace(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        factor_or_conjuncts_inplace(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        factor_or_conjuncts_inplace(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        factor_or_conjuncts_inplace(plan._topn.value()[].child[])
    # PLAN_SCAN, PLAN_PARTITION_*, PLAN_ASOF_JOIN: nothing to do.


# =============================================================================
# Expression walker — find OR subtrees, attempt rewrite, recurse
# =============================================================================


def factor_or_conjuncts_expr(var expr: Expr) -> Expr:
    """Apply OR-conjunct factoring to an expression tree.

    Walks AND/OR nodes:
      * AND: recurse into both children, rebuild.
      * OR: collect ALL the OR-branches (flatten left-leaning OR
            chain), attempt to rewrite. If common conjuncts found,
            hoist them via AND. Then recurse into branch residuals.
      * Other binary / leaf: return as-is. (We don't recurse into
        e.g. comparisons because conjunct factoring only matters at
        the AND/OR level.)
    """
    if expr.tag != EXPR_BINARY_OP:
        return expr^

    var op = expr.binary_op()

    if op == BIN_AND:
        # Recurse into both sides so any nested OR chain inside an AND
        # tree gets factored.
        var left = factor_or_conjuncts_expr(expr.binary_left().copy())
        var right = factor_or_conjuncts_expr(expr.binary_right().copy())
        return Expr.binary(BIN_AND, left^, right^)

    if op == BIN_OR:
        return _try_factor_or(expr^)

    # Non-AND, non-OR binary op (EQ, comparison, arithmetic): leaf.
    return expr^


# =============================================================================
# Core OR-rewrite logic
# =============================================================================


def _try_factor_or(var or_expr: Expr) -> Expr:
    """Attempt to factor common AND-conjuncts out of an OR tree.

    Steps:
      1. Flatten the top-level OR chain into N branches.
      2. For each branch, flatten its top-level AND chain into a
         conjunct list. Compute fingerprints.
      3. If the OR has fewer than 2 branches (degenerate), bail out.
      4. If ANY branch contains a non-pure expression (AGG_FN /
         WINDOW_FN / WHEN), bail out for safety. (Recurse into branches
         so nested ORs still get a shot.)
      5. Compute the intersection of conjunct fingerprints across all
         branches.
      6. If the intersection is empty, recurse into branch residuals
         and rebuild.
      7. Otherwise, rebuild as:
            common AND ( residual_branch1 OR residual_branch2 OR ... )
         Empty residuals become `Expr.literal(True)`; if any residual
         is True, the whole OR collapses to the hoisted AND.
    """
    # 1. Flatten OR chain.
    var branches = ExprArray()
    _collect_or_branches(or_expr.copy(), branches)
    var n_branches = len(branches)

    # 3. Degenerate cases — fewer than 2 branches.
    if n_branches < 2:
        return or_expr^

    # 2 + 4. Flatten each branch into AND-conjuncts; check purity.
    var bundles = Slab[BranchConjuncts]()
    for i in range(n_branches):
        if _expr_has_non_pure(branches[i]):
            # Non-pure branch — bail out on this OR. Recurse into each
            # OR-child so nested ORs still get a chance.
            return _rebuild_or_recurse(or_expr^)

        var bundle = BranchConjuncts()
        _collect_and_conjuncts_into(branches[i].copy(), bundle.conjuncts)
        for j in range(len(bundle.conjuncts)):
            bundle.fingerprints.append(_expr_fingerprint(bundle.conjuncts[j]))
        bundles.append(bundle^)

    # 5. Compute intersection of fingerprints across all branches.
    # Start with branch 0's fingerprints (deduplicated within the
    # branch), then intersect with each subsequent branch.
    var common_fps = List[String]()
    var seen0 = Dict[String, Bool]()
    for j in range(len(bundles[0].fingerprints)):
        var fp = bundles[0].fingerprints[j]
        if not (fp in seen0):
            seen0[fp] = True
            common_fps.append(fp)

    for bi in range(1, n_branches):
        var branch_set = Dict[String, Bool]()
        for j in range(len(bundles[bi].fingerprints)):
            branch_set[bundles[bi].fingerprints[j]] = True
        var next_common = List[String]()
        for j in range(len(common_fps)):
            if common_fps[j] in branch_set:
                next_common.append(common_fps[j])
        common_fps = next_common^
        if len(common_fps) == 0:
            break

    # 6. No common conjuncts — recurse into branch children + rebuild.
    if len(common_fps) == 0:
        return _rebuild_or_recurse(or_expr^)

    # 7. Hoist common conjuncts; rebuild residual OR.
    var common_set = Dict[String, Bool]()
    for j in range(len(common_fps)):
        common_set[common_fps[j]] = True

    # Build the hoisted AND chain from branch 0's conjuncts (taking
    # the first occurrence of each common fingerprint to preserve
    # source-order for stable test output).
    var hoisted = ExprArray()
    var hoisted_seen = Dict[String, Bool]()
    for j in range(len(bundles[0].conjuncts)):
        var fp = bundles[0].fingerprints[j]
        if (fp in common_set) and not (fp in hoisted_seen):
            hoisted_seen[fp] = True
            hoisted.append(bundles[0].conjuncts[j].copy())

    # Build per-branch residuals: each branch keeps only its non-common
    # conjuncts. Empty residual → `True`.
    var residual_branches = ExprArray()
    for bi in range(n_branches):
        var residual_conjs = ExprArray()
        for j in range(len(bundles[bi].conjuncts)):
            var fp = bundles[bi].fingerprints[j]
            if not (fp in common_set):
                residual_conjs.append(bundles[bi].conjuncts[j].copy())
        if len(residual_conjs) == 0:
            # Branch consisted entirely of common conjuncts — residual
            # is True.
            residual_branches.append(_make_true())
        else:
            var residual = _and_chain_from_slab(residual_conjs^)
            # Recurse into the residual so any nested OR inside this
            # branch still gets factored.
            var rewritten_residual = factor_or_conjuncts_expr(residual^)
            residual_branches.append(rewritten_residual^)

    # If ANY residual is `True`, the OR-chain is `... OR True OR ...`
    # = True. The whole OR collapses to `hoisted_AND_chain` (because
    # `H AND True = H`).
    var any_true_residual = False
    for j in range(len(residual_branches)):
        if _is_true_literal(residual_branches[j]):
            any_true_residual = True
            break

    var hoisted_expr = _and_chain_from_slab(hoisted^)

    if any_true_residual:
        return hoisted_expr^

    # Re-OR the residuals into a left-leaning OR chain.
    var or_chain = _or_chain_from_slab(residual_branches^)

    # Final: hoisted AND ( residual OR chain ).
    return Expr.binary(BIN_AND, hoisted_expr^, or_chain^)


# =============================================================================
# Helpers — flattening / rebuilding / purity check
# =============================================================================


def _collect_or_branches(var expr: Expr, mut out: ExprArray):
    """Flatten OR tree into a list of leaf expressions.

    Mirrors `_collect_and_conjuncts` from optimizer_filter.mojo but for
    OR. Non-OR expressions become single-element entries.
    """
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_OR:
        var left = expr.binary_left()
        var right = expr.binary_right()
        _collect_or_branches(left^, out)
        _collect_or_branches(right^, out)
    else:
        out.append(expr^)


def _collect_and_conjuncts_into(var expr: Expr, mut out: ExprArray):
    """Flatten AND tree into a list of conjuncts.

    Same shape as `optimizer_filter._collect_and_conjuncts` but takes
    a `Slab[Expr]` so it composes with the per-branch structures here.
    """
    if expr.tag == EXPR_BINARY_OP and expr.binary_op() == BIN_AND:
        var left = expr.binary_left()
        var right = expr.binary_right()
        _collect_and_conjuncts_into(left^, out)
        _collect_and_conjuncts_into(right^, out)
    else:
        out.append(expr^)


def _expr_has_non_pure(expr: Expr) -> Bool:
    """True if the tree contains an aggregate-fn / window-fn / when expr.

    The walk descends through binary operators only: one of the three
    under any other node (unary, cast, alias, string op, ...) is not
    seen. The tags checked are EXPR_AGG_FN (scalar broadcast),
    EXPR_WINDOW_FN (window functions) and EXPR_WHEN (CASE/WHEN). Other
    shapes that may not be pure (EXPR_UDF_CALL, EXPR_CORRELATED_SUBQUERY)
    are not checked: a branch holding one is factored like any other.
    """
    if expr.tag == EXPR_AGG_FN:
        return True
    if expr.tag == EXPR_WINDOW_FN:
        return True
    if expr.tag == EXPR_WHEN:
        return True
    if expr.tag == EXPR_BINARY_OP:
        return _expr_has_non_pure(expr.binary_left_ref()) or _expr_has_non_pure(expr.binary_right_ref())
    # Any other tag answers False without descending into it.
    return False


def _rebuild_or_recurse(var or_expr: Expr) -> Expr:
    """For OR trees that we DON'T factor at the top level, recurse into
    each child of the top-level OR so nested ORs still get a chance to
    factor. Rebuild the OR with the recursion results."""
    var left = factor_or_conjuncts_expr(or_expr.binary_left().copy())
    var right = factor_or_conjuncts_expr(or_expr.binary_right().copy())
    return Expr.binary(BIN_OR, left^, right^)


def _and_chain_from_slab(var conjs: ExprArray) -> Expr:
    """Build a left-leaning AND chain from a non-empty Slab of conjuncts.

    Single-element → that element. Two+ → left-leaning AND tree.
    Consumes the input slab; each element is copied out into the
    chain.
    """
    var n = len(conjs)
    var acc = conjs[0].copy()
    for i in range(1, n):
        var rhs = conjs[i].copy()
        acc = Expr.binary(BIN_AND, acc^, rhs^)
    return acc^


def _or_chain_from_slab(var branches: ExprArray) -> Expr:
    """Build a left-leaning OR chain from a non-empty Slab of branches.

    Single-element → that element. Two+ → left-leaning OR tree.
    Consumes the input slab; each element is copied out.
    """
    var n = len(branches)
    var acc = branches[0].copy()
    for i in range(1, n):
        var rhs = branches[i].copy()
        acc = Expr.binary(BIN_OR, acc^, rhs^)
    return acc^


def _make_true() -> Expr:
    """Return the literal `True` expression."""
    return Expr.literal(ScalarValue.from_bool(True))


def _is_true_literal(expr: Expr) -> Bool:
    """True if `expr` is the literal `True`."""
    if expr.tag != EXPR_LITERAL:
        return False
    var sv = expr.literal_value()
    if not sv.is_bool():
        return False
    return sv.bool_val
