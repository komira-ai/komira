# =============================================================================
# Tests for `optimizer_or_factoring` -- OR-conjunct factoring rule
# =============================================================================
#
# Walks every Filter predicate's OR-rooted subtrees and hoists the
# conjuncts present in EVERY branch above the OR.
#
# Positive cases:
#   - Q19 shape: 3-branch OR with 3 common conjuncts.
#   - 2-branch OR with 1 common conjunct.
#   - Edge: nested mix `(A AND B) OR (A AND (C OR D))` — A hoists.
#
# Negative cases:
#   - 2-branch OR with no common conjuncts -- preserved.
#   - Partial overlap (X in branches 1+2 but not 3) -- not hoisted.
#   - Single-branch (degenerate OR == leaf) -- preserved.
#
# Idempotence: rule run twice yields the same plan.
#
# Run: welded into the komira_optimizer build (BUCK test_srcs).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_LITERAL,
    EXPR_COL_REF,
    BIN_EQ,
    BIN_AND,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_FILTER

from komira_plan_ir.plan_helpers import _expr_fingerprint
from komira_optimizer.optimizer_or_factoring import (
    factor_or_conjuncts,
    factor_or_conjuncts_expr,
)


# =============================================================================
# Schema + leaf helpers
# =============================================================================


def _schema() -> Schema:
    """Five-column schema: a, b, c, d, e (all INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("d", ArrowType.INT64, False))
    sb.add_field(Field("e", ArrowType.INT64, False))
    return sb.build()


def _eq(col_name: String, v: Int) -> Expr:
    """col == int_literal."""
    return Expr.binary(
        BIN_EQ,
        Expr.col_ref(col_name),
        Expr.literal(ScalarValue.from_int(v)),
    )


def _and2(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _and3(var x: Expr, var y: Expr, var z: Expr) -> Expr:
    return _and2(_and2(x^, y^), z^)


def _and4(var x: Expr, var y: Expr, var z: Expr, var w: Expr) -> Expr:
    return _and2(_and3(x^, y^, z^), w^)


def _or2(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_OR, l^, r^)


def _or3(var x: Expr, var y: Expr, var z: Expr) -> Expr:
    return _or2(_or2(x^, y^), z^)


# =============================================================================
# Plan-level helpers
# =============================================================================


def _filter_over_scan(var pred: Expr) raises -> LogicalPlan:
    """Build a Filter(pred, Scan(in_memory, schema))."""
    var sch = _schema()
    var scan = LogicalPlan.scan(String("__test"), UInt8(3), sch^)
    return LogicalPlan.filter(pred^, scan^)


# =============================================================================
# Fingerprint-based assertions
# =============================================================================


def _fp(expr: Expr) -> String:
    return _expr_fingerprint(expr)


def _filter_predicate_fp(plan: LogicalPlan) raises -> String:
    """Return the fingerprint of a Filter's predicate."""
    if plan.tag != PLAN_FILTER:
        raise Error("expected PLAN_FILTER root")
    return _fp(plan._filter.value()[].predicate)


def _expr_contains_fp(expr: Expr, target_fp: String) -> Bool:
    """True if any subtree of `expr` has fingerprint == `target_fp`."""
    if _fp(expr) == target_fp:
        return True
    if expr.tag == EXPR_BINARY_OP:
        if _expr_contains_fp(expr.binary_left_ref(), target_fp):
            return True
        if _expr_contains_fp(expr.binary_right_ref(), target_fp):
            return True
    return False


# =============================================================================
# Section 1 — Positive cases
# =============================================================================


def test_q19_shape_three_branch_three_common_conjuncts() raises:
    """Q19's exact shape: 3-branch OR with 3 common conjuncts.

      WHERE (a==1 AND b==2 AND c==3 AND d==10)
         OR (a==1 AND b==2 AND c==3 AND d==20)
         OR (a==1 AND b==2 AND c==3 AND d==30)

    Should rewrite to:
      (a==1) AND (b==2) AND (c==3) AND ( d==10 OR d==20 OR d==30 )
    """
    var br1 = _and4(_eq("a", 1), _eq("b", 2), _eq("c", 3), _eq("d", 10))
    var br2 = _and4(_eq("a", 1), _eq("b", 2), _eq("c", 3), _eq("d", 20))
    var br3 = _and4(_eq("a", 1), _eq("b", 2), _eq("c", 3), _eq("d", 30))
    var pred = _or3(br1^, br2^, br3^)

    var rewritten = factor_or_conjuncts_expr(pred^)

    # Top of rewritten tree must be AND (NOT the original OR).
    assert_true(rewritten.tag == EXPR_BINARY_OP, "expected BinaryOp root")
    assert_true(rewritten.binary_op() == BIN_AND, "expected AND at root")

    # Each common conjunct should appear as a subtree of the rewritten
    # expression.
    var a_eq = _eq("a", 1)
    var b_eq = _eq("b", 2)
    var c_eq = _eq("c", 3)
    assert_true(_expr_contains_fp(rewritten, _fp(a_eq)), "missing a==1")
    assert_true(_expr_contains_fp(rewritten, _fp(b_eq)), "missing b==2")
    assert_true(_expr_contains_fp(rewritten, _fp(c_eq)), "missing c==3")

    # Residuals d==10, d==20, d==30 each present somewhere in the tree.
    var d10 = _eq("d", 10)
    var d20 = _eq("d", 20)
    var d30 = _eq("d", 30)
    assert_true(_expr_contains_fp(rewritten, _fp(d10)), "missing d==10")
    assert_true(_expr_contains_fp(rewritten, _fp(d20)), "missing d==20")
    assert_true(_expr_contains_fp(rewritten, _fp(d30)), "missing d==30")

    # The FULL OR-of-d-residuals subtree should appear (i.e., the OR
    # tree of d==10 OR d==20 OR d==30 is intact, not collapsed to True).
    var d_or = _or3(_eq("d", 10), _eq("d", 20), _eq("d", 30))
    var d_or_fp = _fp(d_or)
    assert_true(_expr_contains_fp(rewritten, d_or_fp), "missing d-OR subtree")


def test_two_branch_one_common_conjunct() raises:
    """2-branch OR with 1 common conjunct.

      (a==1 AND b==2) OR (a==1 AND c==3)
        -> a==1 AND ( b==2 OR c==3 )
    """
    var br1 = _and2(_eq("a", 1), _eq("b", 2))
    var br2 = _and2(_eq("a", 1), _eq("c", 3))
    var pred = _or2(br1^, br2^)

    var rewritten = factor_or_conjuncts_expr(pred^)

    assert_true(rewritten.tag == EXPR_BINARY_OP, "expected BinaryOp root")
    assert_true(rewritten.binary_op() == BIN_AND, "expected AND at root")

    var a_eq = _eq("a", 1)
    var residual_or = _or2(_eq("b", 2), _eq("c", 3))
    assert_true(_expr_contains_fp(rewritten, _fp(a_eq)), "missing a==1")
    assert_true(_expr_contains_fp(rewritten, _fp(residual_or)),
                "missing residual b OR c")


def test_nested_mix_outer_or_finds_common_conjunct() raises:
    """Nested mix: `(A AND B) OR (A AND (C OR D))`.

    Outer is a 2-branch OR. Branch 1 conjuncts: [A, B]. Branch 2
    conjuncts: [A, (C OR D)] (the parenthesized OR is a single
    leaf-conjunct from the AND-flattening's perspective).

    Common: A. Hoist: A AND ( B OR (C OR D) ).
    """
    var br1 = _and2(_eq("a", 1), _eq("b", 2))
    var c_or_d = _or2(_eq("c", 3), _eq("d", 4))
    var br2 = _and2(_eq("a", 1), c_or_d^)
    var pred = _or2(br1^, br2^)

    var rewritten = factor_or_conjuncts_expr(pred^)

    assert_true(rewritten.tag == EXPR_BINARY_OP, "expected BinaryOp root")
    assert_true(rewritten.binary_op() == BIN_AND, "expected AND at root")

    var a_eq = _eq("a", 1)
    assert_true(_expr_contains_fp(rewritten, _fp(a_eq)), "missing a==1")

    # Residual: B OR (C OR D)
    var b_eq = _eq("b", 2)
    assert_true(_expr_contains_fp(rewritten, _fp(b_eq)), "missing b==2")
    var c_eq = _eq("c", 3)
    assert_true(_expr_contains_fp(rewritten, _fp(c_eq)), "missing c==3")


def test_filter_node_predicate_rewritten_via_inplace_walker() raises:
    """End-to-end: in-place walker mutates Filter.predicate.

    Builds a Filter(<2-branch OR with 1 common>) over a Scan, runs the
    plan-level rule, asserts the predicate now has AND at the top.
    """
    var br1 = _and2(_eq("a", 1), _eq("b", 2))
    var br2 = _and2(_eq("a", 1), _eq("c", 3))
    var pred = _or2(br1^, br2^)
    var plan = _filter_over_scan(pred^)

    var rewritten = factor_or_conjuncts(plan^)

    assert_equal(Int(rewritten.tag), Int(PLAN_FILTER))
    ref new_pred_ref = rewritten._filter.value()[].predicate
    assert_true(new_pred_ref.tag == EXPR_BINARY_OP, "expected BinaryOp pred")
    assert_true(new_pred_ref.binary_op() == BIN_AND, "expected AND at pred root")


# =============================================================================
# Section 2 — Negative cases
# =============================================================================


def test_no_common_conjuncts_preserved() raises:
    """2-branch OR where branches share zero conjuncts -- predicate
    unchanged.

      (a==1 AND b==2) OR (c==3 AND d==4)
    """
    var br1 = _and2(_eq("a", 1), _eq("b", 2))
    var br2 = _and2(_eq("c", 3), _eq("d", 4))
    var pred = _or2(br1^, br2^)
    var orig_fp = _fp(pred)

    var rewritten = factor_or_conjuncts_expr(pred^)

    # No factoring -- top should remain OR (or a logically-equivalent
    # tree with the same fingerprint).
    assert_true(rewritten.tag == EXPR_BINARY_OP, "expected BinaryOp root")
    assert_true(rewritten.binary_op() == BIN_OR, "expected OR at root")
    assert_equal(_fp(rewritten), orig_fp)


def test_partial_overlap_not_hoisted_at_outer_or() raises:
    """3-branch OR; X appears in branches 1+2 but NOT 3 -- X NOT hoisted
    above the OUTER OR.

      (b==2 AND e==5) OR (b==2 AND a==1) OR (d==4 AND c==3)
        (use distinct columns per branch to avoid ANY common conjunct
         from also being a sub-OR-2 candidate)

    `b==2` is in branches 1+2 but not 3, so it MUST NOT appear ABOVE
    the top-level OR. (A nested sub-OR rewrite that lifts `b==2` above
    `(br1 OR br2)` is a CORRECT side-effect of recursing into OR
    children, but the top-level OR-shape's outer hoist must not have
    fired. We verify by asserting the top of the rewritten tree is
    still a binary OR -- not the AND that a top-level hoist would
    produce.)
    """
    var br1 = _and2(_eq("b", 2), _eq("e", 5))
    var br2 = _and2(_eq("b", 2), _eq("a", 1))
    var br3 = _and2(_eq("d", 4), _eq("c", 3))
    var pred = _or3(br1^, br2^, br3^)

    var rewritten = factor_or_conjuncts_expr(pred^)

    # Outer OR-of-3 had NO conjunct in ALL THREE branches, so the
    # top-level rewrite must NOT have produced an AND root. (The
    # recursion may have factored `b==2` out of the inner sub-OR
    # `br1 OR br2` -- that's correct, expected, and beneficial.)
    assert_true(rewritten.tag == EXPR_BINARY_OP, "expected BinaryOp root")
    assert_true(rewritten.binary_op() == BIN_OR,
                "expected OR at outer root (no full-3-branch hoist)")


def test_single_branch_or_degenerate_preserved() raises:
    """A standalone non-OR expression (no top-level OR) is untouched.

    NOTE: Mojo / Komira can't *construct* a literal "single-branch OR"
    BinaryOp(OR) with one operand — every BinaryOp(OR) has two children
    by construction. The closest analog: a leaf (no OR at all) which
    must round-trip unchanged.
    """
    var pred = _eq("a", 1)
    var orig_fp = _fp(pred)

    var rewritten = factor_or_conjuncts_expr(pred^)
    assert_equal(_fp(rewritten), orig_fp)


def test_or_with_non_pure_branch_bails_out() raises:
    """If any branch contains a non-pure expression (here EXPR_WHEN
    via cases), the OR factoring bails out -- predicate logically
    unchanged.

    NOTE: We construct a non-pure case via `Expr.when`. `EXPR_WHEN` is
    one of the bail-out tags in `_expr_has_non_pure`.
    """
    from komira_plan_expr.expr import WhenCaseData

    var when_cond = _eq("a", 1)
    var when_result = _eq("b", 2)
    var when_default = _eq("c", 3)
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(when_cond^, when_result^))
    var when_expr = Expr.when(cases^, when_default^)

    # br1 = (a==1 AND b==2 AND when_expr); br2 = (a==1 AND b==2 AND e==5)
    var br1 = _and3(_eq("a", 1), _eq("b", 2), when_expr^)
    var br2 = _and3(_eq("a", 1), _eq("b", 2), _eq("e", 5))
    var pred = _or2(br1^, br2^)
    var orig_fp = _fp(pred)

    var rewritten = factor_or_conjuncts_expr(pred^)

    # Bailed out -- no top-level AND; should still have OR structure
    # (the recursion may have rebuilt the OR with rewritten children
    # but factoring did NOT fire on this OR).
    assert_equal(_fp(rewritten), orig_fp)


# =============================================================================
# Section 3 — Idempotence
# =============================================================================


def test_idempotence_double_apply_yields_same_tree() raises:
    """Running the rule twice on a Q19-shape predicate yields the same
    tree the second time. Ensures the rewrite reaches a fixpoint."""
    var br1 = _and3(_eq("a", 1), _eq("b", 2), _eq("d", 10))
    var br2 = _and3(_eq("a", 1), _eq("b", 2), _eq("d", 20))
    var br3 = _and3(_eq("a", 1), _eq("b", 2), _eq("d", 30))
    var pred = _or3(br1^, br2^, br3^)

    var first = factor_or_conjuncts_expr(pred^)
    var first_fp = _fp(first)

    var second = factor_or_conjuncts_expr(first^)
    var second_fp = _fp(second)

    assert_equal(first_fp, second_fp)


# =============================================================================
# Section 4 — Sanity checks on the helper expressions
# =============================================================================


def test_helper_eq_constructs_binary_eq() raises:
    """Sanity: `_eq` produces a BinaryOp(EQ) with col_ref / literal."""
    var e = _eq("a", 1)
    assert_true(e.tag == EXPR_BINARY_OP, "expected BinaryOp")
    assert_true(e.binary_op() == BIN_EQ, "expected EQ op")
    assert_true(e.binary_left_ref().tag == EXPR_COL_REF, "expected col_ref")
    assert_true(e.binary_right_ref().tag == EXPR_LITERAL, "expected literal")


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
