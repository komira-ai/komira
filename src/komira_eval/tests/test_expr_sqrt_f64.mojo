# =============================================================================
# Tests for `ExpressionExecutor.eval_to_list_f64_from_view[bo]` —
# EXPR_SQRT_F64 unary arm coverage.
#
# Validates the
# runtime expr catalog primitive `make_sqrt_f64(child)` end-to-end:
# the column-walker eval arm (`eval_to_list_f64_from_view`), the
# arity-1 entry in `_node_arity`, and the arity-1 wiring in
# `_build_state_tree`.
#
# `EXPR_SQRT_F64` is the FIRST arity-1 opcode in the runtime expr
# catalog (prior tags are all arity 0 / 2). This test covers the
# unary-tag wiring as well as IEEE-754 semantic edge cases.
#
# Semantics:
#   - sqrt(x) for x >= 0      → IEEE-754 sqrt
#   - sqrt(-x) for x > 0      → NaN (NOT a raise)
#   - sqrt(NaN)               → NaN
#   - sqrt(+Inf)              → +Inf
#   - sqrt(-0.0)              → -0.0 (signed zero quirk)
#   - sqrt(0.0)               → 0.0
#
# Test coverage (6 cases):
#   1. SQRT(col(c0)) over [0, 1, 4, 9, 16, 25]
#        ⇒ [0.0, 1.0, 2.0, 3.0, 4.0, 5.0] — perfect-square inputs.
#   2. SQRT(lit(2.0)) over identity sel of length 4 ⇒ [~1.41421356] * 4
#        — tolerance assertion (sqrt(2) is irrational).
#   3. SQRT(lit(-1.0)) ⇒ NaN — IEEE-754 propagation, no raise.
#   4. SQRT(col(c0)) with a 0.0 row ⇒ 0.0 — boundary, also exercises
#        the column-walker recursion through a single-row sel.
#   5. SQRT(MUL(col(c0), col(c0))) over [1.0..8.0]
#        ⇒ [1.0..8.0] — composition test (arity-1 over arity-2 child;
#        validates the recursive _build_state_tree + walker dispatch).
#   6. SQRT(lit(1.0e10)) ⇒ 1.0e5 — large-value sanity.
#
# Cross-refs:
#   - Production code: komira_eval.expression_executor
#     (the EXPR_SQRT_F64 arms, _node_arity arity-1 entry, and
#     _build_state_tree arity-1 wiring) +
#     komira_kernels.runtime_expr (EXPR_SQRT_F64 tag + make_sqrt_f64
#     factory).
#   - Sibling tests:
#     test_runtime_project_walker.mojo (existing F64 arith
#     arm coverage incl. div-by-zero-no-raise).
# =============================================================================

from std.math import isnan, sqrt

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_lit_f64,
    make_mul_f64,
    make_sqrt_f64,
)
from komira_arrow.selection_vector_row import RowSelectionVector


# -----------------------------------------------------------------------------
# Helpers (mirror sibling test_runtime_project_walker.mojo conventions)
# -----------------------------------------------------------------------------


def _names1(s0: String) -> List[String]:
    var out = List[String]()
    out.append(s0)
    return out^


def _build_f64_batch_from_list(
    vals: List[Float64], name: String
) raises -> RecordBatch:
    """Single-column Float64 batch with the given values + column name."""
    var scalars = List[Scalar[DType.float64]]()
    var i = 0
    while i < len(vals):
        scalars.append(Scalar[DType.float64](vals[i]))
        i = i + 1
    var arr = PrimitiveArray[DType.float64].from_list(scalars^)
    var schema = Schema.from_fields_1(Field(name, DType.float64, True))
    var col = Column.from_primitive[DType.float64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _make_identity_sel(n: Int) -> RowSelectionVector:
    """Build an identity RowSelectionVector [0, 1, ..., n-1]."""
    var sel = RowSelectionVector()
    var i = 0
    while i < n:
        sel.append(UInt32(i))
        i = i + 1
    return sel^


def _approx_equal_f64(
    actual: Scalar[DType.float64],
    expected: Float64,
    tol: Float64,
) -> Bool:
    """Tolerance-based equality (for irrational expected values)."""
    var diff = actual - Scalar[DType.float64](expected)
    if diff < Scalar[DType.float64](0.0):
        diff = -diff
    return diff < Scalar[DType.float64](tol)


# =============================================================================
# Test cases
# =============================================================================


def test_sqrt_col_perfect_squares() raises:
    """`sqrt(col(c0))` over [0, 1, 4, 9, 16, 25] ⇒ [0, 1, 2, 3, 4, 5]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0: c0
    pool.append(make_sqrt_f64(0))  # 1: root = sqrt(c0)
    var exec_ = ExpressionExecutor(pool^, 1, _names1("c0"))

    var input_vals = List[Float64]()
    input_vals.append(Float64(0.0))
    input_vals.append(Float64(1.0))
    input_vals.append(Float64(4.0))
    input_vals.append(Float64(9.0))
    input_vals.append(Float64(16.0))
    input_vals.append(Float64(25.0))
    var batch = _build_f64_batch_from_list(input_vals^, "c0")
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(6)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 1, sel, out)

    var expected = List[Float64]()
    expected.append(Float64(0.0))
    expected.append(Float64(1.0))
    expected.append(Float64(2.0))
    expected.append(Float64(3.0))
    expected.append(Float64(4.0))
    expected.append(Float64(5.0))

    assert_equal(len(out), 6, "sqrt-col-perfect-squares: 6 outputs")
    var i = 0
    while i < 6:
        assert_equal(
            out[i],
            Scalar[DType.float64](expected[i]),
            "sqrt-col-perfect-squares: out[" + String(i) + "]",
        )
        i = i + 1


def test_sqrt_lit_two_irrational() raises:
    """`sqrt(lit(2.0))` over identity sel of length 4 ⇒ [~1.41421356]*4.

    Validates the literal-broadcast path through the unary arm. The
    expected value sqrt(2) is irrational; uses tolerance-based assert.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(2.0)))  # 0: lit(2.0)
    pool.append(make_sqrt_f64(0))  # 1: root = sqrt(lit(2.0))
    var exec_ = ExpressionExecutor(pool^, 1, List[String]())

    # _build_f64_batch_from_list requires a non-empty column for the
    # batch shape, but the actual VALUES don't matter — we evaluate
    # sqrt(lit), no column access in the SQRT subtree.
    var input_vals = List[Float64]()
    input_vals.append(Float64(0.0))
    input_vals.append(Float64(0.0))
    input_vals.append(Float64(0.0))
    input_vals.append(Float64(0.0))
    var batch = _build_f64_batch_from_list(input_vals^, "c0")
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 1, sel, out)

    assert_equal(len(out), 4, "sqrt-lit-two: 4 outputs")
    var i = 0
    while i < 4:
        assert_true(
            _approx_equal_f64(out[i], Float64(1.41421356), Float64(1e-7)),
            "sqrt-lit-two: out[" + String(i) + "] ~= 1.41421356",
        )
        i = i + 1


def test_sqrt_negative_returns_nan() raises:
    """`sqrt(lit(-1.0))` ⇒ NaN — IEEE-754, no raise.

    Matches the IEEE-754-default convention used by EXPR_DIV_F64
    (div-by-zero produces ±Inf / NaN, no raise) per the existing
    `test_f64_div_by_zero_no_raise` sibling case.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(-1.0)))  # 0: lit(-1.0)
    pool.append(make_sqrt_f64(0))  # 1: root = sqrt(lit(-1.0))
    var exec_ = ExpressionExecutor(pool^, 1, List[String]())

    var input_vals = List[Float64]()
    input_vals.append(Float64(0.0))
    var batch = _build_f64_batch_from_list(input_vals^, "c0")
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(1)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 1, sel, out)

    assert_equal(len(out), 1, "sqrt-negative: 1 output")
    # NaN != NaN by IEEE-754 — use isnan to detect.
    assert_true(
        isnan(out[0]),
        "sqrt-negative: out[0] is NaN (sqrt(-1.0) per IEEE-754)",
    )


def test_sqrt_zero_boundary() raises:
    """`sqrt(col(c0))` with col=[0.0] ⇒ [0.0] — boundary."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0: c0
    pool.append(make_sqrt_f64(0))  # 1: root = sqrt(c0)
    var exec_ = ExpressionExecutor(pool^, 1, _names1("c0"))

    var input_vals = List[Float64]()
    input_vals.append(Float64(0.0))
    var batch = _build_f64_batch_from_list(input_vals^, "c0")
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(1)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 1, sel, out)

    assert_equal(len(out), 1, "sqrt-zero-boundary: 1 output")
    assert_equal(
        out[0],
        Scalar[DType.float64](Float64(0.0)),
        "sqrt-zero-boundary: sqrt(0.0) = 0.0",
    )


def test_sqrt_of_mul_composition() raises:
    """`sqrt(col(c0) * col(c0))` over [1.0..8.0] ⇒ [1.0..8.0].

    Validates the recursive composition path: an arity-1 SQRT node over
    an arity-2 MUL child. Both `_build_state_tree` (recursive state
    tree construction) and `eval_to_list_f64_from_view` (recursive
    descent into node.left) must wire correctly.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0: c0
    pool.append(make_mul_f64(0, 0))  # 1: c0 * c0
    pool.append(make_sqrt_f64(1))  # 2: root = sqrt(c0*c0)
    var exec_ = ExpressionExecutor(pool^, 2, _names1("c0"))

    var input_vals = List[Float64]()
    var i = 1
    while i <= 8:
        input_vals.append(Float64(i))
        i = i + 1
    var batch = _build_f64_batch_from_list(input_vals^, "c0")
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(8)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)

    assert_equal(len(out), 8, "sqrt-of-mul-composition: 8 outputs")
    var k = 0
    while k < 8:
        assert_equal(
            out[k],
            Scalar[DType.float64](Float64(k + 1)),
            "sqrt-of-mul-composition: out[" + String(k) + "]",
        )
        k = k + 1


def test_sqrt_large_value() raises:
    """`sqrt(lit(1e10))` ⇒ 1e5 — large-value sanity."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(Float64(1.0e10)))  # 0: lit(1e10)
    pool.append(make_sqrt_f64(0))  # 1: root = sqrt(lit(1e10))
    var exec_ = ExpressionExecutor(pool^, 1, List[String]())

    var input_vals = List[Float64]()
    input_vals.append(Float64(0.0))
    var batch = _build_f64_batch_from_list(input_vals^, "c0")
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(1)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 1, sel, out)

    assert_equal(len(out), 1, "sqrt-large: 1 output")
    # sqrt(1e10) = 1e5 — exact (1e10 is exactly representable; 1e5 is
    # exactly representable; the square is exact).
    assert_equal(
        out[0],
        Scalar[DType.float64](Float64(1.0e5)),
        "sqrt-large: sqrt(1e10) = 1e5",
    )


# =============================================================================
# Suite entrypoint
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_sqrt_col_perfect_squares]()
    suite.test[test_sqrt_lit_two_irrational]()
    suite.test[test_sqrt_negative_returns_nan]()
    suite.test[test_sqrt_zero_boundary]()
    suite.test[test_sqrt_of_mul_composition]()
    suite.test[test_sqrt_large_value]()
    suite^.run()
