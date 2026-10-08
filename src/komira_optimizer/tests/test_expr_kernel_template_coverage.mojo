# =============================================================================
# Tests for `_match_expr_to_kernel_template` — phase 3.a
# coverage trip-wire.
#
# Assert the 36 phase-3.a
# templates match the Expr shapes from the active TPC-H Q1/Q6/Q11/Q18 + a
# small ClickBench-shape sample. For each Expr shape, call
# `_match_expr_to_kernel_template` and either:
#   - assert `Optional.is_some()` AND check the returned template-id matches
#     the expected stable-id for that shape (catches over-coverage / wrong
#     wiring), or
#   - assert `Optional.is_none()` for shapes that MUST fall back (catches
#     under-coverage / accidental matching).
#
# This is the trip-wire that gates against:
#   - Adding a template that doesn't actually fire for the bench query it
#     was authored for (over-coverage).
#   - Bench query Expr shape changes that silently fall back to
#     InterpretedExprKernel without us noticing (regression).
#
# Phase 3.a known scope:
#   - ColLit shapes match (F64+I64 lit dtype).
#   - ColCol shapes return None (schema context for ColRef dtype not
#     available in the matcher today; a later change plumbs it).
#   - Non-binary Exprs return None (3.b template targets).
#   - Date32 ColLit comparisons match via I64 ColLit templates IF the
#     literal is constructed as Int64; if constructed as Date32 the
#     literal dtype is Int32 — both cases handled in 3.a's matcher
#     (lit_dtype check accepts both Int64 and Int32 → routes to I64
#     templates).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_GT,
    BIN_GE,
    BIN_LT,
    BIN_LE,
    BIN_AND,
    BIN_OR,
    UN_IS_NULL,
    UN_NOT,
)
from komira_optimizer.optimizer_expr import _match_expr_to_kernel_template
from komira_kernels.expr_kernel_templates import (
    EXPR_TEMPLATE_INTERPRETED,
    EXPR_TEMPLATE_MUL_F64_COLCOL,
    EXPR_TEMPLATE_ADD_F64_COLLIT,
    EXPR_TEMPLATE_SUB_F64_COLLIT,
    EXPR_TEMPLATE_MUL_F64_COLLIT,
    EXPR_TEMPLATE_DIV_F64_COLLIT,
    EXPR_TEMPLATE_ADD_I64_COLLIT,
    EXPR_TEMPLATE_SUB_I64_COLLIT,
    EXPR_TEMPLATE_MUL_I64_COLLIT,
    EXPR_TEMPLATE_DIV_I64_COLLIT,
    EXPR_TEMPLATE_GT_F64_COLLIT,
    EXPR_TEMPLATE_GE_F64_COLLIT,
    EXPR_TEMPLATE_LT_F64_COLLIT,
    EXPR_TEMPLATE_LE_F64_COLLIT,
    EXPR_TEMPLATE_EQ_F64_COLLIT,
    EXPR_TEMPLATE_NE_F64_COLLIT,
    EXPR_TEMPLATE_GT_I64_COLLIT,
    EXPR_TEMPLATE_GE_I64_COLLIT,
    EXPR_TEMPLATE_LT_I64_COLLIT,
    EXPR_TEMPLATE_LE_I64_COLLIT,
    EXPR_TEMPLATE_EQ_I64_COLLIT,
    EXPR_TEMPLATE_NE_I64_COLLIT,
    EXPR_TEMPLATE_MAX_ID_PHASE_3A,
    # Phase 3.b additions.
    EXPR_TEMPLATE_CAST_F64_TO_F32,
    EXPR_TEMPLATE_CAST_F32_TO_F64,
    EXPR_TEMPLATE_CAST_I64_TO_I32,
    EXPR_TEMPLATE_CAST_I32_TO_I64,
    EXPR_TEMPLATE_CAST_F64_TO_I64,
    EXPR_TEMPLATE_CAST_I64_TO_F64,
    EXPR_TEMPLATE_IS_NULL_F64,
    EXPR_TEMPLATE_IS_NOT_NULL_F64,
    EXPR_TEMPLATE_AND_BOOL,
    EXPR_TEMPLATE_OR_BOOL,
    EXPR_TEMPLATE_NOT_BOOL,
    EXPR_TEMPLATE_NEGATE_F64,
    EXPR_TEMPLATE_MOD_I64_COLCOL,
    EXPR_TEMPLATE_MAX_ID_PHASE_3B,
)
from komira_plan_expr.expr import (
    EXPR_CAST,
    UN_NEGATE,
    UN_IS_NOT_NULL,
)


# -----------------------------------------------------------------------------
# Helpers — construct Expr shapes that mirror the bench fixtures.
# -----------------------------------------------------------------------------


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit_f64(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _lit_i64(v: Int64) -> Expr:
    return Expr.literal(ScalarValue.from_int64(v))


def _lit_i32(v: Int32) -> Expr:
    return Expr.literal(ScalarValue.from_int32(v))


def _lit_str(s: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(s))


# -----------------------------------------------------------------------------
# 1) Q6 — 5-filter pipeline + 1 arithmetic projection
#
# Per the TPC-H Q6 query:
#   1. col("l_shipdate") >= date_1994            (BIN_GE with I32-lit)
#   2. col("l_shipdate") < date_1995             (BIN_LT with I32-lit)
#   3. col("l_discount") >= 0.05                 (BIN_GE F64 ColLit)
#   4. col("l_discount") <= 0.07                 (BIN_LE F64 ColLit)
#   5. col("l_quantity") < 24.0                  (BIN_LT F64 ColLit)
#   6. col("l_extendedprice") * col("l_discount") (BIN_MUL F64 ColCol)
#
# Expected matching:
#   Filters 1-2: I64 ColLit cmp templates (matcher accepts I32 lit dtype
#                via the I32→I64 fallback in the matcher).
#   Filters 3-5: F64 ColLit cmp templates.
#   Projection 6: ColCol — returns None in 3.a (deferred to 3.a-late /
#                 3.b-early after schema-context plumbing).
# -----------------------------------------------------------------------------


def test_q6_filter_1_shipdate_ge_date_matches() raises:
    """Q6 filter #1 — `l_shipdate >= date_1994` — matches I64 ColLit GE."""
    var e = Expr.binary(BIN_GE, _col("l_shipdate"), _lit_i32(8766))  # 1994-01-01 in days
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q6 filter 1 must match a template")
    assert_equal(m.value(), EXPR_TEMPLATE_GE_I64_COLLIT)


def test_q6_filter_2_shipdate_lt_date_matches() raises:
    """Q6 filter #2 — `l_shipdate < date_1995` — matches I64 ColLit LT."""
    var e = Expr.binary(BIN_LT, _col("l_shipdate"), _lit_i32(9131))  # 1995-01-01 in days
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q6 filter 2 must match a template")
    assert_equal(m.value(), EXPR_TEMPLATE_LT_I64_COLLIT)


def test_q6_filter_3_discount_ge_lit_matches() raises:
    """Q6 filter #3 — `l_discount >= 0.05` — matches F64 ColLit GE."""
    var e = Expr.binary(BIN_GE, _col("l_discount"), _lit_f64(0.05))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q6 filter 3 must match a template")
    assert_equal(m.value(), EXPR_TEMPLATE_GE_F64_COLLIT)


def test_q6_filter_4_discount_le_lit_matches() raises:
    """Q6 filter #4 — `l_discount <= 0.07` — matches F64 ColLit LE."""
    var e = Expr.binary(BIN_LE, _col("l_discount"), _lit_f64(0.07))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q6 filter 4 must match a template")
    assert_equal(m.value(), EXPR_TEMPLATE_LE_F64_COLLIT)


def test_q6_filter_5_quantity_lt_lit_matches() raises:
    """Q6 filter #5 — `l_quantity < 24.0` — matches F64 ColLit LT."""
    var e = Expr.binary(BIN_LT, _col("l_quantity"), _lit_f64(24.0))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q6 filter 5 must match a template")
    assert_equal(m.value(), EXPR_TEMPLATE_LT_F64_COLLIT)


def test_q6_projection_revenue_colcol_deferred() raises:
    """Q6 projection — `l_extendedprice * l_discount` (ColCol) returns None
    in 3.a (deferred to 3.b after schema-context threading)."""
    var e = Expr.binary(BIN_MUL, _col("l_extendedprice"), _col("l_discount"))
    var m = _match_expr_to_kernel_template(e)
    assert_false(m.__bool__(), "Q6 projection ColCol must return None in 3.a (deferred)")


# -----------------------------------------------------------------------------
# 2) Q11 — Important Stock filter + arithmetic
#
# Per the TPC-H Q11 query:
#   1. n_name == 'GERMANY'           (BIN_EQ STRING — out of 3.a scope; None)
#   2. ps_supplycost * ps_availqty   (BIN_MUL F64 ColCol — None in 3.a)
#   3. part_value > scalar_subquery  (BIN_GT F64 ColLit at runtime)
# -----------------------------------------------------------------------------


def test_q11_filter_n_name_eq_string_no_template() raises:
    """Q11 filter — `n_name == 'GERMANY'` (String ColLit) returns None in 3.a.
    String compare templates are deferred to 3.b at the earliest, and
    they may stay on the legacy engine path."""
    var e = Expr.binary(BIN_EQ, _col("n_name"), _lit_str("GERMANY"))
    var m = _match_expr_to_kernel_template(e)
    assert_false(m.__bool__(), "String ColLit EQ must return None in 3.a")


def test_q11_arith_supplycost_availqty_colcol_deferred() raises:
    """Q11 arithmetic — `ps_supplycost * ps_availqty` (ColCol) returns None."""
    var e = Expr.binary(BIN_MUL, _col("ps_supplycost"), _col("ps_availqty"))
    var m = _match_expr_to_kernel_template(e)
    assert_false(m.__bool__(), "ColCol MUL must return None in 3.a (deferred)")


def test_q11_having_part_value_gt_threshold_matches() raises:
    """Q11 HAVING — `part_value > threshold (F64 lit)` — matches F64 ColLit GT."""
    var e = Expr.binary(BIN_GT, _col("part_value"), _lit_f64(123456.78))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q11 HAVING must match GT_F64_COLLIT")
    assert_equal(m.value(), EXPR_TEMPLATE_GT_F64_COLLIT)


# -----------------------------------------------------------------------------
# 3) Q18 — Large Volume Customer
#
# Per the TPC-H Q18 query:
#   1. HAVING sum(l_quantity) > 300       (BIN_GT post-agg I64 ColLit)
#
# (The JOINs use BIN_EQ ColCol but those are JOIN ON predicates — they
#  do NOT lower to filter Exprs, the join compiler handles them.)
# -----------------------------------------------------------------------------


def test_q18_having_sum_qty_gt_lit_matches_i64_collit() raises:
    """Q18 HAVING — `sum(l_quantity) > 300` lowers to BIN_GT(ColRef:I64, Lit:I64)."""
    var e = Expr.binary(BIN_GT, _col("sum_qty"), _lit_i64(300))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "Q18 HAVING must match GT_I64_COLLIT")
    assert_equal(m.value(), EXPR_TEMPLATE_GT_I64_COLLIT)


# -----------------------------------------------------------------------------
# 4) Q1 / general arithmetic + comparison cross-coverage
#
# Q1 has compound nested arithmetic that 3.a's matcher does NOT handle
# natively (e.g. `l_extendedprice * (1 - l_discount)` — top-level is
# ColCol×Compound — returns None). The interpreter (3.b) covers this.
#
# Verify that all 6 comparison ops + 4 arithmetic ops × 2 dtypes (F64+I64)
# match for ColLit shapes — the matcher's full ColLit surface area.
# -----------------------------------------------------------------------------


def test_arith_add_f64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_ADD, _col("x"), _lit_f64(1.0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_ADD_F64_COLLIT)


def test_arith_sub_f64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_SUB, _col("x"), _lit_f64(1.0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_SUB_F64_COLLIT)


def test_arith_mul_f64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_MUL, _col("x"), _lit_f64(2.0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_MUL_F64_COLLIT)


def test_arith_div_f64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_DIV, _col("x"), _lit_f64(2.0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_DIV_F64_COLLIT)


def test_arith_add_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_ADD, _col("x"), _lit_i64(1)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_ADD_I64_COLLIT)


def test_arith_sub_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_SUB, _col("x"), _lit_i64(1)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_SUB_I64_COLLIT)


def test_arith_mul_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_MUL, _col("x"), _lit_i64(2)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_MUL_I64_COLLIT)


def test_arith_div_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_DIV, _col("x"), _lit_i64(2)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_DIV_I64_COLLIT)


# Comparison F64 — already covered above (Q6 set); add the missing 2.

def test_cmp_eq_f64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_EQ, _col("x"), _lit_f64(0.0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_EQ_F64_COLLIT)


def test_cmp_ne_f64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_NE, _col("x"), _lit_f64(0.0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_NE_F64_COLLIT)


# Comparison I64 — Q18's GT covered above; verify the others.

def test_cmp_ge_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_GE, _col("x"), _lit_i64(10)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_GE_I64_COLLIT)


def test_cmp_lt_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_LT, _col("x"), _lit_i64(100)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_LT_I64_COLLIT)


def test_cmp_le_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_LE, _col("x"), _lit_i64(50)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_LE_I64_COLLIT)


def test_cmp_eq_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_EQ, _col("x"), _lit_i64(42)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_EQ_I64_COLLIT)


def test_cmp_ne_i64_collit_matches() raises:
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_NE, _col("x"), _lit_i64(0)))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_NE_I64_COLLIT)


# -----------------------------------------------------------------------------
# 5) Lit-on-LHS (commutative ops only)
#
# The matcher accepts Lit-on-LHS for commutative ops (ADD, MUL, EQ, NE)
# only. SUB / DIV / GT / GE / LT / LE on Lit-on-LHS need normalization
# (or a separate template family) — both deferred to 3.b at the earliest.
# -----------------------------------------------------------------------------


def test_lit_lhs_add_f64_matches() raises:
    """`1.0 + col("x")` matches ADD F64 ColLit (commutative)."""
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_ADD, _lit_f64(1.0), _col("x")))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_ADD_F64_COLLIT)


def test_lit_lhs_mul_i64_matches() raises:
    """`2 * col("x")` matches MUL I64 ColLit (commutative)."""
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_MUL, _lit_i64(2), _col("x")))
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_MUL_I64_COLLIT)


def test_lit_lhs_sub_f64_no_match() raises:
    """`1.0 - col("x")` does NOT match in 3.a (SUB is non-commutative; deferred)."""
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_SUB, _lit_f64(1.0), _col("x")))
    assert_false(m.__bool__(), "Lit-LHS SUB must return None in 3.a")


def test_lit_lhs_gt_f64_no_match() raises:
    """`100.0 > col("x")` does NOT match in 3.a (GT non-commutative; deferred)."""
    var m = _match_expr_to_kernel_template(Expr.binary(BIN_GT, _lit_f64(100.0), _col("x")))
    assert_false(m.__bool__(), "Lit-LHS GT must return None in 3.a")


# -----------------------------------------------------------------------------
# 6) Negative / out-of-scope shapes — confirm they return None
# -----------------------------------------------------------------------------


def test_unary_not_matches_in_3b() raises:
    """UN_NOT matches the NOT_BOOL template (3.b)."""
    var inner = Expr.binary(BIN_GT, _col("x"), _lit_f64(0.0))
    var e = Expr.unary(UN_NOT, inner^)
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "UN_NOT must match NOT_BOOL template in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_NOT_BOOL)


def test_is_null_matches_in_3b() raises:
    """UN_IS_NULL matches the IS_NULL_F64 template (3.b default-dtype variant)."""
    var e = Expr.unary(UN_IS_NULL, _col("x"))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "UN_IS_NULL must match a template in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_IS_NULL_F64)


def test_is_not_null_matches_in_3b() raises:
    """UN_IS_NOT_NULL matches the IS_NOT_NULL_F64 template (3.b)."""
    var e = Expr.unary(UN_IS_NOT_NULL, _col("x"))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "UN_IS_NOT_NULL must match a template in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_IS_NOT_NULL_F64)


def test_unary_negate_matches_in_3b() raises:
    """UN_NEGATE matches the NEGATE_F64 template (3.b default-dtype variant)."""
    var e = Expr.unary(UN_NEGATE, _col("x"))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "UN_NEGATE must match a template in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_NEGATE_F64)


def test_col_ref_alone_returns_none() raises:
    """A bare ColRef is an operand-shape, not a kernel."""
    var e = _col("x")
    var m = _match_expr_to_kernel_template(e)
    assert_false(m.__bool__(), "Bare ColRef must return None")


def test_literal_alone_returns_none() raises:
    """A bare Literal is an operand-shape, not a kernel."""
    var e = _lit_f64(3.14)
    var m = _match_expr_to_kernel_template(e)
    assert_false(m.__bool__(), "Bare Literal must return None")


def test_lit_lit_returns_none() raises:
    """Lit-Lit shapes are constant-folded by Rule 5 BEFORE the matcher runs;
    the matcher should not match them (defensive — if folding is skipped,
    the matcher still falls back to None rather than mis-binding)."""
    var e = Expr.binary(BIN_ADD, _lit_f64(1.0), _lit_f64(2.0))
    var m = _match_expr_to_kernel_template(e)
    assert_false(m.__bool__(), "Lit-Lit shape must return None (post-fold should not reach matcher)")


def test_bool_and_chain_matches_in_3b() raises:
    """AND of two predicates matches AND_BOOL template (3.b)."""
    var leaf = Expr.binary(BIN_GT, _col("x"), _lit_f64(0.0))
    var e = Expr.binary(BIN_AND, leaf^, Expr.binary(BIN_LT, _col("y"), _lit_f64(1.0)))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "BIN_AND of two predicates must match AND_BOOL in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_AND_BOOL)


def test_bool_or_two_preds_matches_in_3b() raises:
    """OR of two predicates matches OR_BOOL template (3.b)."""
    var leaf = Expr.binary(BIN_GT, _col("x"), _lit_f64(0.0))
    var e = Expr.binary(BIN_OR, leaf^, Expr.binary(BIN_LT, _col("y"), _lit_f64(1.0)))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "BIN_OR of two predicates must match OR_BOOL in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_OR_BOOL)


def test_cast_f64_to_f32_matches_in_3b() raises:
    """cast(F64 → F32) matches CAST_F64_TO_F32 template (3.b)."""
    var e = Expr.cast(_col("x"), DType.float32)
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__(), "CAST F32 must match a template in 3.b")
    assert_equal(m.value(), EXPR_TEMPLATE_CAST_F64_TO_F32)


def test_cast_to_int32_matches_in_3b() raises:
    """cast(? → I32) matches CAST_I64_TO_I32 template (3.b default-source variant)."""
    var e = Expr.cast(_col("x"), DType.int32)
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_CAST_I64_TO_I32)


def test_mod_i64_colcol_matches_in_3b() raises:
    """BIN_MOD ColCol matches MOD_I64_COLCOL template (3.b)."""
    var e = Expr.binary(BIN_MOD, _col("a"), _col("b"))
    var m = _match_expr_to_kernel_template(e)
    assert_true(m.__bool__())
    assert_equal(m.value(), EXPR_TEMPLATE_MOD_I64_COLCOL)


# -----------------------------------------------------------------------------
# 7) Trip-wire invariants — registry-shape regression guards
# -----------------------------------------------------------------------------


def _assert_in_3a_range(m: Optional[Int], shape_label: String) raises:
    """Helper: assert the matcher result is Some(id) with id in [1, 36].
    Used for the original 3.a Lit-side matcher coverage."""
    assert_true(m.__bool__(), shape_label + " must match")
    var v = m.value()
    assert_true(v > 0, shape_label + " template id must be > 0 (INTERPRETED is 0)")
    assert_true(
        v <= EXPR_TEMPLATE_MAX_ID_PHASE_3A,
        shape_label + " template id #" + String(v) + " exceeds 3.a max " + String(EXPR_TEMPLATE_MAX_ID_PHASE_3A)
    )


def _assert_in_3b_range(m: Optional[Int], shape_label: String) raises:
    """Helper: assert the matcher result is Some(id) with id in [1, 65]."""
    assert_true(m.__bool__(), shape_label + " must match")
    var v = m.value()
    assert_true(v > 0, shape_label + " template id must be > 0")
    assert_true(
        v <= EXPR_TEMPLATE_MAX_ID_PHASE_3B,
        shape_label + " template id #" + String(v) + " exceeds 3.b max " + String(EXPR_TEMPLATE_MAX_ID_PHASE_3B)
    )


def test_no_returned_id_exceeds_3a_max() raises:
    """Every id the matcher can possibly return is ≤ MAX_ID_PHASE_3A.
    Catches accidental leak of 3.b template ids before 3.b lands.

    Walks every shape 3.a's matcher matches; calls the helper above on
    each. Inlined here (not via List[Expr]) because Expr is not Copyable
    so it can't be stored in a List."""
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_ADD, _col("x"), _lit_f64(1.0))), "F64 ADD")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_SUB, _col("x"), _lit_f64(1.0))), "F64 SUB")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_MUL, _col("x"), _lit_f64(1.0))), "F64 MUL")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_DIV, _col("x"), _lit_f64(1.0))), "F64 DIV")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_ADD, _col("x"), _lit_i64(1))), "I64 ADD")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_SUB, _col("x"), _lit_i64(1))), "I64 SUB")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_MUL, _col("x"), _lit_i64(1))), "I64 MUL")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_DIV, _col("x"), _lit_i64(1))), "I64 DIV")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_GT, _col("x"), _lit_f64(0.0))), "F64 GT")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_GE, _col("x"), _lit_f64(0.0))), "F64 GE")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_LT, _col("x"), _lit_f64(0.0))), "F64 LT")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_LE, _col("x"), _lit_f64(0.0))), "F64 LE")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_EQ, _col("x"), _lit_f64(0.0))), "F64 EQ")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_NE, _col("x"), _lit_f64(0.0))), "F64 NE")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_GT, _col("x"), _lit_i64(0))), "I64 GT")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_GE, _col("x"), _lit_i64(0))), "I64 GE")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_LT, _col("x"), _lit_i64(0))), "I64 LT")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_LE, _col("x"), _lit_i64(0))), "I64 LE")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_EQ, _col("x"), _lit_i64(0))), "I64 EQ")
    _assert_in_3a_range(_match_expr_to_kernel_template(Expr.binary(BIN_NE, _col("x"), _lit_i64(0))), "I64 NE")


def test_template_id_is_deterministic_per_shape() raises:
    """Calling the matcher twice on the same shape returns the same id.
    Catches non-determinism (e.g. accidental hash-based dispatch) that
    would break the plan compiler's dispatch table."""
    var shape_1 = Expr.binary(BIN_MUL, _col("a"), _lit_f64(2.0))
    var shape_2 = Expr.binary(BIN_MUL, _col("a"), _lit_f64(2.0))
    var m1 = _match_expr_to_kernel_template(shape_1)
    var m2 = _match_expr_to_kernel_template(shape_2)
    assert_true(m1.__bool__())
    assert_true(m2.__bool__())
    assert_equal(m1.value(), m2.value())


# -----------------------------------------------------------------------------
# Test driver
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
