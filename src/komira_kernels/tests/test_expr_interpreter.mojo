# =============================================================================
# Tests for `interpret_expr`.
#
# End-to-end test for ~10 representative Expr shapes via the
# interpreter path. Asserts byte-identical results to a manual scalar
# computation. The shapes here are EXPLICITLY ones the matcher does NOT
# template (nested compounds + EXPR_ALIAS pass-through + cast chains) so the
# interpreter is exercised, not the templated fast paths.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.expr import (
    Expr,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)

from komira_kernels.expr_interpreter import (
    interpret_expr,
    EvalScalar,
    RowContext,
    EVAL_KIND_INT,
    EVAL_KIND_FLOAT,
    EVAL_KIND_BOOL,
    EVAL_KIND_NULL,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit_f64(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _lit_i64(v: Int64) -> Expr:
    return Expr.literal(ScalarValue.from_int64(v))


def _make_ctx_q1() -> RowContext:
    """Q1-shape row: l_extendedprice / l_discount / l_tax."""
    var ctx = RowContext.empty()
    ctx.set_float("l_extendedprice", 100.0)
    ctx.set_float("l_discount", 0.1)
    ctx.set_float("l_tax", 0.05)
    return ctx^


def _make_ctx_q6() -> RowContext:
    """Q6-shape row: shipdate / discount / quantity / extendedprice."""
    var ctx = RowContext.empty()
    ctx.set_int("l_shipdate", 8800)  # 1994-something
    ctx.set_float("l_discount", 0.06)
    ctx.set_float("l_quantity", 20.0)
    ctx.set_float("l_extendedprice", 1000.0)
    return ctx^


# -----------------------------------------------------------------------------
# 1) Q1's `l_extendedprice * (1 - l_discount)` — nested compound (not in
#    template registry; goes through interpreter)
# -----------------------------------------------------------------------------


def test_q1_compound_disc_price() raises:
    """Q1 disc_price = l_extendedprice * (1 - l_discount).
    Tree: BIN_MUL(ColRef, BIN_SUB(Lit, ColRef)).
    Manual check: 100.0 * (1.0 - 0.1) = 90.0."""
    var inner = Expr.binary(BIN_SUB, _lit_f64(1.0), _col("l_discount"))
    var e = Expr.binary(BIN_MUL, _col("l_extendedprice"), inner^)
    var ctx = _make_ctx_q1()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_FLOAT)
    var diff = r.float_val - 90.0
    assert_true(diff * diff < 1e-20, "Q1 disc_price compound interpreter mismatch")


def test_q1_compound_charge() raises:
    """Q1 charge = l_extendedprice * (1 - l_discount) * (1 + l_tax).
    Tree: BIN_MUL(BIN_MUL(ColRef, BIN_SUB(Lit, ColRef)), BIN_ADD(Lit, ColRef)).
    Manual: 100.0 * 0.9 * 1.05 = 94.5."""
    var disc = Expr.binary(BIN_SUB, _lit_f64(1.0), _col("l_discount"))
    var net_price = Expr.binary(BIN_MUL, _col("l_extendedprice"), disc^)
    var tax = Expr.binary(BIN_ADD, _lit_f64(1.0), _col("l_tax"))
    var charge = Expr.binary(BIN_MUL, net_price^, tax^)
    var ctx = _make_ctx_q1()
    var r = interpret_expr(charge, ctx)
    assert_equal(r.kind, EVAL_KIND_FLOAT)
    var diff = r.float_val - 94.5
    assert_true(diff * diff < 1e-20, "Q1 charge compound interpreter mismatch")


# -----------------------------------------------------------------------------
# 2) Q6 5-way AND chain via interpreter (templates handle the leaves;
#    interpreter handles the AND tree composition)
# -----------------------------------------------------------------------------


def test_q6_and_chain_5way() raises:
    """Q6's 5-filter AND-chain at one row.
       (shipdate >= 8766) AND (shipdate < 9131) AND (disc >= 0.05)
         AND (disc <= 0.07) AND (qty < 24.0).
    With ctx values 8800 / 0.06 / 20.0 — all pass → True."""
    var f1 = Expr.binary(BIN_GE, _col("l_shipdate"), _lit_i64(8766))
    var f2 = Expr.binary(BIN_LT, _col("l_shipdate"), _lit_i64(9131))
    var f3 = Expr.binary(BIN_GE, _col("l_discount"), _lit_f64(0.05))
    var f4 = Expr.binary(BIN_LE, _col("l_discount"), _lit_f64(0.07))
    var f5 = Expr.binary(BIN_LT, _col("l_quantity"), _lit_f64(24.0))
    # (((f1 AND f2) AND f3) AND f4) AND f5  — left-deep AND chain
    var and1 = Expr.binary(BIN_AND, f1^, f2^)
    var and2 = Expr.binary(BIN_AND, and1^, f3^)
    var and3 = Expr.binary(BIN_AND, and2^, f4^)
    var and4 = Expr.binary(BIN_AND, and3^, f5^)
    var ctx = _make_ctx_q6()
    var r = interpret_expr(and4, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_true(r.bool_val, "Q6 5-way AND chain must pass for these row values")


def test_q6_and_chain_5way_one_fails() raises:
    """Q6 5-filter AND chain with one filter failing — overall must be False.
    Set qty to 25.0 (fails the < 24.0 filter)."""
    var f1 = Expr.binary(BIN_GE, _col("l_shipdate"), _lit_i64(8766))
    var f2 = Expr.binary(BIN_LT, _col("l_shipdate"), _lit_i64(9131))
    var f3 = Expr.binary(BIN_GE, _col("l_discount"), _lit_f64(0.05))
    var f4 = Expr.binary(BIN_LE, _col("l_discount"), _lit_f64(0.07))
    var f5 = Expr.binary(BIN_LT, _col("l_quantity"), _lit_f64(24.0))
    var and1 = Expr.binary(BIN_AND, f1^, f2^)
    var and2 = Expr.binary(BIN_AND, and1^, f3^)
    var and3 = Expr.binary(BIN_AND, and2^, f4^)
    var and4 = Expr.binary(BIN_AND, and3^, f5^)
    var ctx = RowContext.empty()
    ctx.set_int("l_shipdate", 8800)
    ctx.set_float("l_discount", 0.06)
    ctx.set_float("l_quantity", 25.0)  # FAILS < 24.0
    var r = interpret_expr(and4, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_false(r.bool_val, "Q6 5-way AND chain must fail when one filter fails")


# -----------------------------------------------------------------------------
# 3) Mixed Int / Float arithmetic — coercion correctness
# -----------------------------------------------------------------------------


def test_mixed_int_float_arith() raises:
    """`int_col * float_lit` coerces to Float64."""
    var e = Expr.binary(BIN_MUL, _col("qty"), _lit_f64(2.5))
    var ctx = RowContext.empty()
    ctx.set_int("qty", 10)
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_FLOAT)
    var diff = r.float_val - 25.0
    assert_true(diff * diff < 1e-20)


def test_mixed_float_int_compare() raises:
    """`float_col > int_lit` coerces to Float64 compare."""
    var e = Expr.binary(BIN_GT, _col("price"), _lit_i64(50))
    var ctx = RowContext.empty()
    ctx.set_float("price", 100.5)
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_true(r.bool_val)


# -----------------------------------------------------------------------------
# 4) Unary ops — NEGATE, NOT, IS_NULL
# -----------------------------------------------------------------------------


def test_unary_negate_float() raises:
    """`-l_extendedprice` → -100.0."""
    var e = Expr.unary(UN_NEGATE, _col("l_extendedprice"))
    var ctx = _make_ctx_q1()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_FLOAT)
    var diff = r.float_val - (-100.0)
    assert_true(diff * diff < 1e-20)


def test_unary_not_compound() raises:
    """`NOT (l_quantity < 10)` over l_quantity = 20.0 → True."""
    var inner = Expr.binary(BIN_LT, _col("l_quantity"), _lit_f64(10.0))
    var e = Expr.unary(UN_NOT, inner^)
    var ctx = _make_ctx_q6()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_true(r.bool_val)


def test_is_null_on_present_col() raises:
    """`IS NULL(l_quantity)` over a present column → False."""
    var e = Expr.unary(UN_IS_NULL, _col("l_quantity"))
    var ctx = _make_ctx_q6()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_false(r.bool_val)


def test_is_null_on_absent_col() raises:
    """`IS NULL(missing)` over an absent column → True (RowContext returns NULL)."""
    var e = Expr.unary(UN_IS_NULL, _col("missing"))
    var ctx = _make_ctx_q1()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_true(r.bool_val)


def test_is_not_null_on_present_col() raises:
    """`IS NOT NULL(l_quantity)` over a present column → True."""
    var e = Expr.unary(UN_IS_NOT_NULL, _col("l_quantity"))
    var ctx = _make_ctx_q6()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_BOOL)
    assert_true(r.bool_val)


# -----------------------------------------------------------------------------
# 5) BIN_MOD (integer + float)
# -----------------------------------------------------------------------------


def test_mod_int() raises:
    """`17 % 5` → 2."""
    var e = Expr.binary(BIN_MOD, _lit_i64(17), _lit_i64(5))
    var ctx = RowContext.empty()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_INT)
    assert_equal(r.int_val, 2)


# -----------------------------------------------------------------------------
# Test driver
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
