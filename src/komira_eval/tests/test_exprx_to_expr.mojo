# =============================================================================
# test_exprx_to_expr.mojo — `to_expr()` lowering on ExprX conformers
# =============================================================================
#
# Validates the `to_expr()` lowering on engine ExprX conformers
# (`komira_eval.expr_x_conformers`), following the typed expression
# AST's `ExprBool.to_expr()` lowering pattern.
#
# Each engine ExprX conformer lowers to a runtime LogicalPlan walker `Expr`
# (`komira_plan_expr.expr.Expr`):
#   - ColX*  -> Expr.col_ref(name)                    (tag = EXPR_COL_REF)
#   - LitX*  -> Expr.literal(ScalarValue.from_*(v))   (tag = EXPR_LITERAL)
#   - Binop  -> Expr.binary(BIN_*, L.to_expr(), R.to_expr())  (EXPR_BINARY_OP)
#
# Acceptance gates:
#   (a) The package builds.
#   (b) Every test PASSES (lowered tags / column names / literal values /
#       binop kinds / recursive children match expectation).
#   (c) Composite expression `(col_i64 > lit) & col_bool` lowers to
#       BIN_AND[BIN_GT[COL_REF, LITERAL], COL_REF] (tree shape correct).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_plan_expr.expr import (
    Expr,
    BIN_GT,
    BIN_LT,
    BIN_GE,
    BIN_LE,
    BIN_EQ,
    BIN_NE,
    BIN_AND,
    BIN_OR,
    BIN_MUL,
    BIN_ADD,
    BIN_SUB,
    BIN_DIV,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
)

from komira_eval.expr_x_conformers import (
    # Leaves
    ColXI64,
    ColXF64,
    ColXBool,
    ColXF32,
    ColXI32,
    ColXString,
    LitXI64,
    LitXF64,
    LitXBool,
    LitXF32,
    LitXI32,
    LitXString,
    # I64 binops
    GeXI64,
    GtXI64,
    LtXI64,
    LeXI64,
    EqXI64,
    NeXI64,
    # F64 binops
    GeXF64,
    GtXF64,
    LtXF64,
    LeXF64,
    EqXF64,
    NeXF64,
    # F32 binops
    GeXF32,
    GtXF32,
    LtXF32,
    LeXF32,
    EqXF32,
    NeXF32,
    # I32 binops
    GeXI32,
    GtXI32,
    LtXI32,
    LeXI32,
    EqXI32,
    NeXI32,
    # Arithmetic
    MulXF64,
    AddXF32,
    SubXF32,
    MulXF32,
    DivXF32,
    AddXI32,
    SubXI32,
    MulXI32,
    DivXI32,
    # Logical
    AndX,
    OrX,
    # String
    EqXString,
)


# =============================================================================
# Test 1 — Leaf lowering: ColX* -> EXPR_COL_REF + name preserved
# =============================================================================
def test_col_leaves_lower_to_col_ref() raises:
    """Each ColX* leaf produces an Expr.col_ref keyed by its comptime name."""
    var e_i64 = ColXI64["a"].to_expr()
    assert_equal(e_i64.tag, EXPR_COL_REF)
    assert_equal(e_i64.col_ref_name(), String("a"))

    var e_f64 = ColXF64["b"].to_expr()
    assert_equal(e_f64.tag, EXPR_COL_REF)
    assert_equal(e_f64.col_ref_name(), String("b"))

    var e_bool = ColXBool["c"].to_expr()
    assert_equal(e_bool.tag, EXPR_COL_REF)
    assert_equal(e_bool.col_ref_name(), String("c"))

    var e_f32 = ColXF32["d"].to_expr()
    assert_equal(e_f32.tag, EXPR_COL_REF)
    assert_equal(e_f32.col_ref_name(), String("d"))

    var e_i32 = ColXI32["e"].to_expr()
    assert_equal(e_i32.tag, EXPR_COL_REF)
    assert_equal(e_i32.col_ref_name(), String("e"))

    var e_str = ColXString["f"].to_expr()
    assert_equal(e_str.tag, EXPR_COL_REF)
    assert_equal(e_str.col_ref_name(), String("f"))


# =============================================================================
# Test 2 — Literal lowering: LitX* -> EXPR_LITERAL + value preserved
# =============================================================================
def test_lit_leaves_lower_to_literal() raises:
    """Each LitX* leaf produces an Expr.literal with the comptime value."""
    var e_i64 = LitXI64[Int64(42)].to_expr()
    assert_equal(e_i64.tag, EXPR_LITERAL)
    var sv_i64 = e_i64.literal_value()
    assert_true(sv_i64.is_int())
    assert_equal(sv_i64.int_val, Int64(42))

    var e_f64 = LitXF64[Float64(3.14)].to_expr()
    assert_equal(e_f64.tag, EXPR_LITERAL)
    var sv_f64 = e_f64.literal_value()
    assert_true(sv_f64.is_float())
    assert_equal(sv_f64.float_val, Float64(3.14))

    var e_bool_t = LitXBool[True].to_expr()
    assert_equal(e_bool_t.tag, EXPR_LITERAL)
    var sv_bool_t = e_bool_t.literal_value()
    assert_true(sv_bool_t.is_bool())
    assert_equal(sv_bool_t.bool_val, True)

    var e_bool_f = LitXBool[False].to_expr()
    var sv_bool_f = e_bool_f.literal_value()
    assert_equal(sv_bool_f.bool_val, False)

    var e_f32 = LitXF32[Float32(2.5)].to_expr()
    assert_equal(e_f32.tag, EXPR_LITERAL)
    var sv_f32 = e_f32.literal_value()
    assert_true(sv_f32.is_float())
    assert_equal(sv_f32.float_val, Float64(2.5))

    var e_i32 = LitXI32[Int32(7)].to_expr()
    assert_equal(e_i32.tag, EXPR_LITERAL)
    var sv_i32 = e_i32.literal_value()
    assert_true(sv_i32.is_int())
    assert_equal(sv_i32.int_val, Int64(7))

    var e_str = LitXString["hello"].to_expr()
    assert_equal(e_str.tag, EXPR_LITERAL)
    var sv_str = e_str.literal_value()
    assert_true(sv_str.is_string())
    assert_equal(sv_str.string_val, String("hello"))


# =============================================================================
# Test 3 — I64 comparison binops lower to Expr.binary(BIN_*, L, R)
# =============================================================================
def test_i64_cmp_binops_lower_to_binary() raises:
    """Each I64 cmp binop produces Expr.binary(BIN_*, COL_REF("a"), LITERAL(5))."""
    var e_ge = GeXI64[ColXI64["a"], LitXI64[Int64(5)]].to_expr()
    assert_equal(e_ge.tag, EXPR_BINARY_OP)
    assert_equal(e_ge.binary_op(), BIN_GE)
    assert_equal(e_ge.binary_left_ref().tag, EXPR_COL_REF)
    assert_equal(e_ge.binary_left_ref().col_ref_name(), String("a"))
    assert_equal(e_ge.binary_right_ref().tag, EXPR_LITERAL)
    assert_equal(e_ge.binary_right_ref().literal_value().int_val, Int64(5))

    var e_gt = GtXI64[ColXI64["a"], LitXI64[Int64(5)]].to_expr()
    assert_equal(e_gt.binary_op(), BIN_GT)

    var e_lt = LtXI64[ColXI64["a"], LitXI64[Int64(5)]].to_expr()
    assert_equal(e_lt.binary_op(), BIN_LT)

    var e_le = LeXI64[ColXI64["a"], LitXI64[Int64(5)]].to_expr()
    assert_equal(e_le.binary_op(), BIN_LE)

    var e_eq = EqXI64[ColXI64["a"], LitXI64[Int64(5)]].to_expr()
    assert_equal(e_eq.binary_op(), BIN_EQ)

    var e_ne = NeXI64[ColXI64["a"], LitXI64[Int64(5)]].to_expr()
    assert_equal(e_ne.binary_op(), BIN_NE)


# =============================================================================
# Test 4 — F64 comparison binops lower to Expr.binary(BIN_*, L, R)
# =============================================================================
def test_f64_cmp_binops_lower_to_binary() raises:
    """Each F64 cmp binop maps to the right BIN_* tag."""
    var e_ge = GeXF64[ColXF64["b"], LitXF64[Float64(1.0)]].to_expr()
    assert_equal(e_ge.binary_op(), BIN_GE)

    var e_gt = GtXF64[ColXF64["b"], LitXF64[Float64(1.0)]].to_expr()
    assert_equal(e_gt.binary_op(), BIN_GT)

    var e_lt = LtXF64[ColXF64["b"], LitXF64[Float64(1.0)]].to_expr()
    assert_equal(e_lt.binary_op(), BIN_LT)

    var e_le = LeXF64[ColXF64["b"], LitXF64[Float64(1.0)]].to_expr()
    assert_equal(e_le.binary_op(), BIN_LE)

    var e_eq = EqXF64[ColXF64["b"], LitXF64[Float64(1.0)]].to_expr()
    assert_equal(e_eq.binary_op(), BIN_EQ)

    var e_ne = NeXF64[ColXF64["b"], LitXF64[Float64(1.0)]].to_expr()
    assert_equal(e_ne.binary_op(), BIN_NE)


# =============================================================================
# Test 5 — F32 / I32 cmp binops lower to right BIN_* tag
# =============================================================================
def test_f32_i32_cmp_binops_lower_to_binary() raises:
    var e_f32_ge = GeXF32[ColXF32["d"], LitXF32[Float32(0.5)]].to_expr()
    assert_equal(e_f32_ge.binary_op(), BIN_GE)
    var e_f32_eq = EqXF32[ColXF32["d"], LitXF32[Float32(0.5)]].to_expr()
    assert_equal(e_f32_eq.binary_op(), BIN_EQ)
    var e_f32_ne = NeXF32[ColXF32["d"], LitXF32[Float32(0.5)]].to_expr()
    assert_equal(e_f32_ne.binary_op(), BIN_NE)

    var e_i32_ge = GeXI32[ColXI32["e"], LitXI32[Int32(3)]].to_expr()
    assert_equal(e_i32_ge.binary_op(), BIN_GE)
    var e_i32_eq = EqXI32[ColXI32["e"], LitXI32[Int32(3)]].to_expr()
    assert_equal(e_i32_eq.binary_op(), BIN_EQ)
    var e_i32_ne = NeXI32[ColXI32["e"], LitXI32[Int32(3)]].to_expr()
    assert_equal(e_i32_ne.binary_op(), BIN_NE)


# =============================================================================
# Test 6 — Arithmetic binops lower to BIN_ADD / BIN_SUB / BIN_MUL / BIN_DIV
# =============================================================================
def test_arithmetic_binops_lower_to_binary() raises:
    var e_mul_f64 = MulXF64[ColXF64["b"], LitXF64[Float64(2.0)]].to_expr()
    assert_equal(e_mul_f64.binary_op(), BIN_MUL)

    var e_add_f32 = AddXF32[ColXF32["d"], LitXF32[Float32(1.0)]].to_expr()
    assert_equal(e_add_f32.binary_op(), BIN_ADD)
    var e_sub_f32 = SubXF32[ColXF32["d"], LitXF32[Float32(1.0)]].to_expr()
    assert_equal(e_sub_f32.binary_op(), BIN_SUB)
    var e_mul_f32 = MulXF32[ColXF32["d"], LitXF32[Float32(1.0)]].to_expr()
    assert_equal(e_mul_f32.binary_op(), BIN_MUL)
    var e_div_f32 = DivXF32[ColXF32["d"], LitXF32[Float32(1.0)]].to_expr()
    assert_equal(e_div_f32.binary_op(), BIN_DIV)

    var e_add_i32 = AddXI32[ColXI32["e"], LitXI32[Int32(1)]].to_expr()
    assert_equal(e_add_i32.binary_op(), BIN_ADD)
    var e_sub_i32 = SubXI32[ColXI32["e"], LitXI32[Int32(1)]].to_expr()
    assert_equal(e_sub_i32.binary_op(), BIN_SUB)
    var e_mul_i32 = MulXI32[ColXI32["e"], LitXI32[Int32(1)]].to_expr()
    assert_equal(e_mul_i32.binary_op(), BIN_MUL)
    var e_div_i32 = DivXI32[ColXI32["e"], LitXI32[Int32(1)]].to_expr()
    assert_equal(e_div_i32.binary_op(), BIN_DIV)


# =============================================================================
# Test 7 — Logical binops AndX/OrX lower to BIN_AND / BIN_OR
# =============================================================================
def test_logical_binops_lower_to_binary() raises:
    var e_and = AndX[
        GtXI64[ColXI64["a"], LitXI64[Int64(5)]],
        LtXF64[ColXF64["b"], LitXF64[Float64(2.0)]],
    ].to_expr()
    assert_equal(e_and.tag, EXPR_BINARY_OP)
    assert_equal(e_and.binary_op(), BIN_AND)
    # AND's left child is the GT binop; right is the LT binop.
    assert_equal(e_and.binary_left_ref().binary_op(), BIN_GT)
    assert_equal(e_and.binary_right_ref().binary_op(), BIN_LT)

    var e_or = OrX[ColXBool["c"], ColXBool["c"]].to_expr()
    assert_equal(e_or.binary_op(), BIN_OR)
    assert_equal(e_or.binary_left_ref().tag, EXPR_COL_REF)
    assert_equal(e_or.binary_left_ref().col_ref_name(), String("c"))


# =============================================================================
# Test 8 — String EqXString lowers to BIN_EQ
# =============================================================================
def test_string_eq_lowers_to_binary() raises:
    var e = EqXString[ColXString["f"], LitXString["hello"]].to_expr()
    assert_equal(e.tag, EXPR_BINARY_OP)
    assert_equal(e.binary_op(), BIN_EQ)
    assert_equal(e.binary_left_ref().tag, EXPR_COL_REF)
    assert_equal(e.binary_left_ref().col_ref_name(), String("f"))
    assert_equal(e.binary_right_ref().tag, EXPR_LITERAL)
    assert_equal(e.binary_right_ref().literal_value().string_val, String("hello"))


# =============================================================================
# Test 9 — Composite tree shape: `(col_i64 > 5) & col_bool` lowers to the
# right BIN_AND[BIN_GT[COL_REF, LITERAL], COL_REF] shape.
# =============================================================================
def test_composite_tree_shape() raises:
    """Recursive lowering: composite Expr tree shape matches expectation."""
    # Built as if from the SDK chain: ColXI64["a"]() > LitXI64[5]() & ColXBool["c"]()
    # Operator overloads return the right struct types; we instantiate the
    # composite directly to keep the test independent of overload behavior.
    var e = AndX[
        GtXI64[ColXI64["a"], LitXI64[Int64(5)]],
        ColXBool["c"],
    ].to_expr()
    # Top-level is BIN_AND.
    assert_equal(e.tag, EXPR_BINARY_OP)
    assert_equal(e.binary_op(), BIN_AND)
    # Expr is not ImplicitlyCopyable — use `ref` aliases (or repeated
    # `binary_left_ref()` calls) instead of `var =` assignment.
    # Left child is BIN_GT(COL_REF("a"), LITERAL(5)).
    ref left = e.binary_left_ref()
    assert_equal(left.tag, EXPR_BINARY_OP)
    assert_equal(left.binary_op(), BIN_GT)
    assert_equal(left.binary_left_ref().tag, EXPR_COL_REF)
    assert_equal(left.binary_left_ref().col_ref_name(), String("a"))
    assert_equal(left.binary_right_ref().tag, EXPR_LITERAL)
    assert_equal(left.binary_right_ref().literal_value().int_val, Int64(5))
    # Right child is COL_REF("c").
    ref right = e.binary_right_ref()
    assert_equal(right.tag, EXPR_COL_REF)
    assert_equal(right.col_ref_name(), String("c"))


def main() raises:
    test_col_leaves_lower_to_col_ref()
    print("test_col_leaves_lower_to_col_ref PASSED")

    test_lit_leaves_lower_to_literal()
    print("test_lit_leaves_lower_to_literal PASSED")

    test_i64_cmp_binops_lower_to_binary()
    print("test_i64_cmp_binops_lower_to_binary PASSED")

    test_f64_cmp_binops_lower_to_binary()
    print("test_f64_cmp_binops_lower_to_binary PASSED")

    test_f32_i32_cmp_binops_lower_to_binary()
    print("test_f32_i32_cmp_binops_lower_to_binary PASSED")

    test_arithmetic_binops_lower_to_binary()
    print("test_arithmetic_binops_lower_to_binary PASSED")

    test_logical_binops_lower_to_binary()
    print("test_logical_binops_lower_to_binary PASSED")

    test_string_eq_lowers_to_binary()
    print("test_string_eq_lowers_to_binary PASSED")

    test_composite_tree_shape()
    print("test_composite_tree_shape PASSED")

    print(
        "ALL 9 TESTS PASSED — ExprX to_expr lowering"
    )
