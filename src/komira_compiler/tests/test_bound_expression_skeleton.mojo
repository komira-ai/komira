# =============================================================================
# test_bound_expression_skeleton -- BoundExpression skeleton acceptance test
# =============================================================================
#
# Coverage:
#   1. BoundExpr trait conformance (BoundExprI64/I32/F32/F64/Bool) — wrap a
#      BoundLitXX at comptime, unwrap via `evaluate` and assert byte-
#      identity with the comptime parameter.
#   2. BoundCol trait conformance (BoundColI64/I32/F32/F64/Bool) — wrap a
#      BoundColXX[col_idx] at comptime, assert `evaluate` returns the
#      placeholder zero value (Phase 0 stub) and `depth` returns 1.
#   3. `depth` plan-time invariant — every leaf returns 1; the static
#      method exists at the trait level so a future Phase 1 binop walker
#      can rely on it.
#   4. `from_expr_ast_*` factory stubs raise the expected Phase-0 error —
#      ensures the symbol is in place for Phase 1 to swap the body, but is
#      not silently usable.
#
# Out of scope for this skeleton:
#   - Phase 1 binop family (BoundGtI64 etc.).
#   - Phase 1 `from_expr_ast` walker (resolves names → indices) — same.
#   - Per-DType eval[S: Schema, W: Int](batch, i) row-mode signature —
#     replaces the placeholder body in Phase 1 once BatchOf /
#     Column.load_via_sel is consumed.
#
# Package-boundary invariant:
#   `bound_expression.mojo` MUST NOT import from `komira_eval` (parallel
#   hierarchies).

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_compiler.bound_expression import (
    BoundExprI64,
    BoundExprI32,
    BoundExprF32,
    BoundExprF64,
    BoundExprBool,
    BoundLitI64,
    BoundLitI32,
    BoundLitF32,
    BoundLitF64,
    BoundLitBool,
    BoundColI64,
    BoundColI32,
    BoundColF32,
    BoundColF64,
    BoundColBool,
    from_expr_ast_i64,
    from_expr_ast_i32,
    from_expr_ast_f32,
    from_expr_ast_f64,
    from_expr_ast_bool,
)


# =============================================================================
# BoundLit wrap-unwrap roundtrip
# =============================================================================
# Mirrors the comptime-parameter pattern used by `komira_eval.expr_ast`:
# the value lives in the type, so `evaluate` on the instance returns the
# comptime parameter byte-identically.


def test_bound_lit_i64_roundtrip() raises:
    # `evaluate` + `depth` are @staticmethod — calling them via the
    # struct type is equivalent to calling them via an instance. Using the
    # type-qualified form (`BoundLitI64[5].evaluate`) avoids an unused-
    # `inst` warning and emphasizes the comptime-monomorphization shape:
    # the value is in the TYPE, not the instance.
    assert_equal(BoundLitI64[5].evaluate(), Int64(5))
    assert_equal(BoundLitI64[5].depth(), 1)


def test_bound_lit_i64_negative() raises:
    assert_equal(BoundLitI64[-7].evaluate(), Int64(-7))


def test_bound_lit_i32_roundtrip() raises:
    assert_equal(BoundLitI32[42].evaluate(), Int32(42))
    assert_equal(BoundLitI32[42].depth(), 1)


def test_bound_lit_f32_roundtrip() raises:
    assert_equal(BoundLitF32[1.5].evaluate(), Float32(1.5))
    assert_equal(BoundLitF32[1.5].depth(), 1)


def test_bound_lit_f64_roundtrip() raises:
    assert_equal(BoundLitF64[3.25].evaluate(), Float64(3.25))
    assert_equal(BoundLitF64[3.25].depth(), 1)


def test_bound_lit_bool_true() raises:
    assert_true(BoundLitBool[True].evaluate())
    assert_equal(BoundLitBool[True].depth(), 1)


def test_bound_lit_bool_false() raises:
    assert_false(BoundLitBool[False].evaluate())


# =============================================================================
# BoundCol skeleton — col_idx is the resolved index
# =============================================================================
# Phase 0 evaluate is a placeholder; the test asserts the type-level shape
# is in place and depth=1 for leaves. Phase 1 will rewrite the body to
# `batch.column[col_idx].load_via_sel(sel, k)` and add a runtime test.


def test_bound_col_i64_skeleton() raises:
    # Phase 0 placeholder body returns Int64(0); the value is not semantically
    # load-bearing in this slot, but the call must compile and return the
    # right type. Phase 1 rewrites the body to a SIMD load via the resolved
    # `col_idx` against `batch.column[col_idx]`.
    assert_equal(BoundColI64[3].evaluate(), Int64(0))
    assert_equal(BoundColI64[3].depth(), 1)


def test_bound_col_i32_skeleton() raises:
    assert_equal(BoundColI32[0].evaluate(), Int32(0))
    assert_equal(BoundColI32[0].depth(), 1)


def test_bound_col_f32_skeleton() raises:
    assert_equal(BoundColF32[5].evaluate(), Float32(0.0))
    assert_equal(BoundColF32[5].depth(), 1)


def test_bound_col_f64_skeleton() raises:
    assert_equal(BoundColF64[7].evaluate(), Float64(0.0))
    assert_equal(BoundColF64[7].depth(), 1)


def test_bound_col_bool_skeleton() raises:
    assert_false(BoundColBool[1].evaluate())
    assert_equal(BoundColBool[1].depth(), 1)


# =============================================================================
# Trait conformance — generic helpers exercise the trait-typed API
# =============================================================================
# These free fns force the compiler to verify that BoundLitXX / BoundColXX
# conform to BoundExprXX. If a future regression breaks conformance, this
# file fails to compile, which is exactly the gate we want.


def _exercise_bound_expr_i64[E: BoundExprI64](var e: E) -> Int64:
    return e.evaluate()


def _exercise_bound_expr_i32[E: BoundExprI32](var e: E) -> Int32:
    return e.evaluate()


def _exercise_bound_expr_f32[E: BoundExprF32](var e: E) -> Float32:
    return e.evaluate()


def _exercise_bound_expr_f64[E: BoundExprF64](var e: E) -> Float64:
    return e.evaluate()


def _exercise_bound_expr_bool[E: BoundExprBool](var e: E) -> Bool:
    return e.evaluate()


def test_trait_conformance_lit_i64() raises:
    assert_equal(_exercise_bound_expr_i64(BoundLitI64[11]()), Int64(11))


def test_trait_conformance_lit_bool() raises:
    assert_true(_exercise_bound_expr_bool(BoundLitBool[True]()))


def test_trait_conformance_col_f64() raises:
    # Phase 0 placeholder returns 0.0; the assertion exercises trait dispatch.
    assert_equal(_exercise_bound_expr_f64(BoundColF64[2]()), Float64(0.0))


# =============================================================================
# from_expr_ast stubs raise the Phase-0 error
# =============================================================================
# Phase 1 will replace the body; for now we lock in that the symbol exists
# AND that calling it does not silently succeed.


def test_from_expr_ast_i64_raises() raises:
    var raised = False
    try:
        _ = from_expr_ast_i64(BoundLitI64[1]())
    except e:
        raised = True
    assert_true(raised)


def test_from_expr_ast_bool_raises() raises:
    var raised = False
    try:
        _ = from_expr_ast_bool(BoundLitBool[False]())
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# Runner
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
