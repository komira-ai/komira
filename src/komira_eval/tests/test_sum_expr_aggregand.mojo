# =============================================================================
# test_sum_expr_aggregand.mojo — generic SUM(<ExprXF64>) aggregator substrate
# =============================================================================
#
# Operator-substrate coverage for the generic computed-aggregand kernel:
#
#   - `ColAtXF64[idx]` comptime-index F64 column leaf (expr_x_conformers).
#   - `Add/Sub/DivXF64` F64 arith binops (expr_x_conformers) — completing the
#     F64 op-matrix that previously had `MulXF64` only.
#   - `SumOfExprF64Agg[E]` generic SUM-over-expression aggregator
#     (builtin_agg_fns_sum_expr) — generalizes `SumProductF64Agg`'s fixed
#     `a*b` to an arbitrary `ExprXF64` aggregand.
#
# NON-WEDGING substrate test: drives the Aggregator's `init` / `update_scalar`
# / `combine` / `finalize` DIRECTLY over a hand-built `BatchView` (mirrors
# `test_expr_leaf_bind.mojo`). NO `ctx.materialize` row path — no
# deep-chain monomorph, no SDK routing. The dtype+op matrix is asserted
# value-identical to a hand-computed scalar oracle.
#
# The expression trees are built from comptime-index leaves (`ColAtXF64`), so
# `E()` is fully resolved at construction with no runtime bind — exactly how
# the column-grouped Stage drives a field-less `SumOfExprF64Agg.make()`.
#
# Op-matrix covered:  a*b  |  a-b  |  a+b  |  a/b  |  a*(1-b)  |  c*x (scalar)
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import batch_view_over

from komira_eval.builtin_agg_fns_sum_expr import SumOfExprF64Agg
from komira_eval.expr_x_conformers import (
    AddXF64,
    ColAtXF64,
    DivXF64,
    LitXF64,
    MulXF64,
    SubXF64,
)


# -----------------------------------------------------------------------------
# Fixture: 2-column F64 batch (col 0 = "a", col 1 = "b").
# -----------------------------------------------------------------------------
def _build_ab_batch(n: Int) raises -> RecordBatch:
    """2-column F64 batch.
      a[i] = 10.0 + i          (a clean positive ramp)
      b[i] = 0.10 + i * 0.05   (a fractional ramp, b<1 so 1-b is positive)
    """
    var av: List[Scalar[DType.float64]] = []
    var bv: List[Scalar[DType.float64]] = []
    for i in range(n):
        av.append(Scalar[DType.float64](10.0 + Float64(i)))
        bv.append(Scalar[DType.float64](0.10 + Float64(i) * 0.05))
    var a_arr = PrimitiveArray[DType.float64].from_list(av^)
    var b_arr = PrimitiveArray[DType.float64].from_list(bv^)
    var schema = Schema.from_fields_2(
        Field("a", DType.float64, True),
        Field("b", DType.float64, True),
    )
    var c0 = Column.from_primitive[DType.float64](a_arr^)
    var c1 = Column.from_primitive[DType.float64](b_arr^)
    return RecordBatch.from_typed_columns_2(schema^, c0^, c1^)


@always_inline
def _a(i: Int) -> Float64:
    return 10.0 + Float64(i)


@always_inline
def _b(i: Int) -> Float64:
    return 0.10 + Float64(i) * 0.05


def _close(got: Float64, want: Float64) -> Bool:
    var d = got - want
    if d < 0.0:
        d = -d
    var tol = 1e-9 * (1.0 + (want if want >= 0.0 else -want))
    return d <= tol


# =============================================================================
# Test 1 — SUM(a * b): the SumProductF64Agg shape, now via the generic kernel.
# =============================================================================
def test_sum_a_times_b() raises:
    comptime N = 8
    comptime E = MulXF64[ColAtXF64[0], ColAtXF64[1]]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()
    var state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(state, bview, i)
    var got = SumOfExprF64Agg[E].finalize(state)

    var want = Float64(0.0)
    for i in range(N):
        want += _a(i) * _b(i)
    assert_true(_close(got, want), "SUM(a*b) mismatch")


# =============================================================================
# Test 2 — SUM(a - b): the new SubXF64 binop.
# =============================================================================
def test_sum_a_minus_b() raises:
    comptime N = 8
    comptime E = SubXF64[ColAtXF64[0], ColAtXF64[1]]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()
    var state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(state, bview, i)
    var got = SumOfExprF64Agg[E].finalize(state)

    var want = Float64(0.0)
    for i in range(N):
        want += _a(i) - _b(i)
    assert_true(_close(got, want), "SUM(a-b) mismatch")


# =============================================================================
# Test 3 — SUM(a + b): the new AddXF64 binop.
# =============================================================================
def test_sum_a_plus_b() raises:
    comptime N = 8
    comptime E = AddXF64[ColAtXF64[0], ColAtXF64[1]]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()
    var state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(state, bview, i)
    var got = SumOfExprF64Agg[E].finalize(state)

    var want = Float64(0.0)
    for i in range(N):
        want += _a(i) + _b(i)
    assert_true(_close(got, want), "SUM(a+b) mismatch")


# =============================================================================
# Test 4 — SUM(a / b): the new DivXF64 binop.
# =============================================================================
def test_sum_a_div_b() raises:
    comptime N = 8
    comptime E = DivXF64[ColAtXF64[0], ColAtXF64[1]]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()
    var state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(state, bview, i)
    var got = SumOfExprF64Agg[E].finalize(state)

    var want = Float64(0.0)
    for i in range(N):
        want += _a(i) / _b(i)
    assert_true(_close(got, want), "SUM(a/b) mismatch")


# =============================================================================
# Test 5 — SUM(a * (1 - b)): the TPC-H disc-price shape (the headline).
#   This is `MulXF64[ColAtXF64[a], SubXF64[LitXF64[1.0], ColAtXF64[b]]]` —
#   nested arith + a scalar literal fold, the exact `price*(1-discount)`
#   customer query. Previously inexpressible (no SubXF64).
# =============================================================================
def test_sum_a_times_one_minus_b() raises:
    comptime N = 8
    comptime E = MulXF64[
        ColAtXF64[0],
        SubXF64[LitXF64[Float64(1.0)], ColAtXF64[1]],
    ]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()
    var state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(state, bview, i)
    var got = SumOfExprF64Agg[E].finalize(state)

    var want = Float64(0.0)
    for i in range(N):
        want += _a(i) * (1.0 - _b(i))
    assert_true(_close(got, want), "SUM(a*(1-b)) mismatch")


# =============================================================================
# Test 6 — SUM(2.5 * a): a scalar-times-column shape (`c * x`).
# =============================================================================
def test_sum_scalar_times_a() raises:
    comptime N = 8
    comptime E = MulXF64[LitXF64[Float64(2.5)], ColAtXF64[0]]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()
    var state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(state, bview, i)
    var got = SumOfExprF64Agg[E].finalize(state)

    var want = Float64(0.0)
    for i in range(N):
        want += 2.5 * _a(i)
    assert_true(_close(got, want), "SUM(2.5*a) mismatch")


# =============================================================================
# Test 7 — parallel-partial `combine` is associative for SUM(a*(1-b)).
#   Split the N rows across 2 partial states then combine; the combined sum
#   must equal the single-pass sum (the parallel-agg merge path).
# =============================================================================
def test_combine_partial_sum_a_times_one_minus_b() raises:
    comptime N = 12
    comptime E = MulXF64[
        ColAtXF64[0],
        SubXF64[LitXF64[Float64(1.0)], ColAtXF64[1]],
    ]
    var batch = _build_ab_batch(N)
    var bview = batch_view_over(batch)

    var agg = SumOfExprF64Agg[E].make()

    # Single-pass reference.
    var ref_state = SumOfExprF64Agg[E].init()
    for i in range(N):
        agg.update_scalar(ref_state, bview, i)
    var ref_out = SumOfExprF64Agg[E].finalize(ref_state)

    # Two partial states over disjoint row ranges, then combine.
    var w0 = SumOfExprF64Agg[E].init()
    var w1 = SumOfExprF64Agg[E].init()
    for i in range(0, N // 2):
        agg.update_scalar(w0, bview, i)
    for i in range(N // 2, N):
        agg.update_scalar(w1, bview, i)
    agg.combine(w0, w1)
    var combined_out = SumOfExprF64Agg[E].finalize(w0)

    assert_true(_close(combined_out, ref_out), "combine != single-pass")


def main() raises:
    test_sum_a_times_b()
    print("test_sum_a_times_b PASSED")
    test_sum_a_minus_b()
    print("test_sum_a_minus_b PASSED")
    test_sum_a_plus_b()
    print("test_sum_a_plus_b PASSED")
    test_sum_a_div_b()
    print("test_sum_a_div_b PASSED")
    test_sum_a_times_one_minus_b()
    print("test_sum_a_times_one_minus_b PASSED")
    test_sum_scalar_times_a()
    print("test_sum_scalar_times_a PASSED")
    test_combine_partial_sum_a_times_one_minus_b()
    print("test_combine_partial_sum_a_times_one_minus_b PASSED")
    print("ALL 7 TESTS PASSED — computed-aggregand substrate")
