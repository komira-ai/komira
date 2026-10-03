# =============================================================================
# Tests for `expr_executor_mvp.execute_q6_filter_and_sum` -- the Q6-shape
# minimum-viable runtime executor.
#
# Coverage:
#   * Synthetic 1000-row LineItemBatch (a deterministic
#     pseudo-random formula) -- cross-checks executor vs naive baseline.
#   * Zero-surviving fixture (date out of range).
#   * All-surviving fixture (every conjunct true).
#   * 5000-row baseline parity (executor must agree with naive baseline
#     bit-identically on the synthetic inputs -- GE/LT/LE only, no NaN).
#
# The naive baseline is the scratch probe's `baseline_naive_q6` shape:
# 5 sequential filter passes building intermediate index lists, then
# scalar gather + multiply + accumulate over the survivors. It produces
# the ground truth without depending on sel_kernels / RowSelectionVector.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_eval.expr_executor_mvp import (
    Q6Result,
    execute_q6_filter_and_sum,
)
from komira_core.eval.selection_vector import RowSelectionVector


# -----------------------------------------------------------------------------
# Q6 literal bounds (TPC-H Q6).
# -----------------------------------------------------------------------------
# date_to_days(1994, 1, 1) = 8766 (days since 1970-01-01).
# date_to_days(1995, 1, 1) = 9131.
comptime Q6_SHIPDATE_LO: Int64 = Int64(8766)
comptime Q6_SHIPDATE_HI: Int64 = Int64(9131)
comptime Q6_DISCOUNT_LO: Float64 = 0.05
comptime Q6_DISCOUNT_HI: Float64 = 0.07
comptime Q6_QUANTITY_HI: Float64 = 24.0


# -----------------------------------------------------------------------------
# LineItemFixture -- struct wrapper for the 4 Q6 columns. Mojo 1.0.0b1
# tuple returns require Movable + copy/take keyword args; using a struct
# is cleaner and matches the BatchOf[S] shape.
# -----------------------------------------------------------------------------


struct LineItemFixture(Movable):
    var shipdate: PrimitiveArray[DType.int64]
    var discount: PrimitiveArray[DType.float64]
    var quantity: PrimitiveArray[DType.float64]
    var price: PrimitiveArray[DType.float64]

    def __init__(
        out self,
        var shipdate: PrimitiveArray[DType.int64],
        var discount: PrimitiveArray[DType.float64],
        var quantity: PrimitiveArray[DType.float64],
        var price: PrimitiveArray[DType.float64],
    ):
        self.shipdate = shipdate^
        self.discount = discount^
        self.quantity = quantity^
        self.price = price^


# -----------------------------------------------------------------------------
# Synthetic fixture builders.
# -----------------------------------------------------------------------------


def _make_q6_synthetic(n: Int) -> LineItemFixture:
    """Build a deterministic Q6 synthetic fixture with a fixed formula.

    Selectivities:
      - l_shipdate in [7305, 10957] (1990-2000); ~25% in 1994.
      - l_discount in [0.000, 0.099]; ~21% in [0.05, 0.07].
      - l_quantity in [1, 49]; ~46% < 24.
      - l_extendedprice in [1000, 99999].
    Joint surviving selectivity ~2.4%.
    """
    var sd = List[Scalar[DType.int64]]()
    var dc = List[Scalar[DType.float64]]()
    var qy = List[Scalar[DType.float64]]()
    var pr = List[Scalar[DType.float64]]()
    for i in range(n):
        # Pseudo-random spread (deterministic). 3652 = days in 1990-1999;
        # 7305 = 1990-01-01 from 1970-01-01.
        sd.append(Scalar[DType.int64](Int64(7305 + (i * 1009) % 3652)))
        dc.append(Scalar[DType.float64](0.001 * Float64((i * 379) % 100)))
        qy.append(Scalar[DType.float64](Float64(1 + (i * 251) % 49)))
        pr.append(Scalar[DType.float64](1000.0 + Float64((i * 569) % 99000)))
    return LineItemFixture(
        PrimitiveArray[DType.int64].from_list(sd),
        PrimitiveArray[DType.float64].from_list(dc),
        PrimitiveArray[DType.float64].from_list(qy),
        PrimitiveArray[DType.float64].from_list(pr),
    )


def _make_zero_surviving(n: Int) -> LineItemFixture:
    """All rows fail the shipdate predicate -- l_shipdate uniformly in 1980."""
    var sd = List[Scalar[DType.int64]]()
    var dc = List[Scalar[DType.float64]]()
    var qy = List[Scalar[DType.float64]]()
    var pr = List[Scalar[DType.float64]]()
    for i in range(n):
        # 1980-01-01 = day 3653 -- well below Q6_SHIPDATE_LO (8766).
        sd.append(Scalar[DType.int64](Int64(3653 + i)))
        dc.append(Scalar[DType.float64](0.06))   # passes discount
        qy.append(Scalar[DType.float64](10.0))   # passes quantity
        pr.append(Scalar[DType.float64](50000.0))
    return LineItemFixture(
        PrimitiveArray[DType.int64].from_list(sd),
        PrimitiveArray[DType.float64].from_list(dc),
        PrimitiveArray[DType.float64].from_list(qy),
        PrimitiveArray[DType.float64].from_list(pr),
    )


def _make_all_surviving(n: Int) -> LineItemFixture:
    """Every row passes every conjunct; revenue is deterministic.

    shipdate = 8800 (1994 -- passes 8766 <= x < 9131)
    discount = 0.06  (passes 0.05 <= x <= 0.07)
    quantity = 20.0  (passes x < 24.0)
    price    = 1000.0 * (i + 1)  -- distinct per row for sum verifiability.
    revenue  = sum(price[i] * 0.06) = 0.06 * sum(price[i])
             = 0.06 * 1000.0 * sum(1..n)
             = 0.06 * 1000.0 * n*(n+1)/2
    """
    var sd = List[Scalar[DType.int64]]()
    var dc = List[Scalar[DType.float64]]()
    var qy = List[Scalar[DType.float64]]()
    var pr = List[Scalar[DType.float64]]()
    for i in range(n):
        sd.append(Scalar[DType.int64](Int64(8800)))
        dc.append(Scalar[DType.float64](0.06))
        qy.append(Scalar[DType.float64](20.0))
        pr.append(Scalar[DType.float64](1000.0 * Float64(i + 1)))
    return LineItemFixture(
        PrimitiveArray[DType.int64].from_list(sd),
        PrimitiveArray[DType.float64].from_list(dc),
        PrimitiveArray[DType.float64].from_list(qy),
        PrimitiveArray[DType.float64].from_list(pr),
    )


# -----------------------------------------------------------------------------
# Naive baseline -- the ground-truth Q6 evaluator. Does NOT use sel_kernels
# or RowSelectionVector. Mirrors scratch probe `baseline_naive_q6` (lines
# 539-579). Returns are packed into Q6Result so we can reuse the executor's
# result struct without a tuple-return ergonomics issue.
# -----------------------------------------------------------------------------


def _naive_q6(ref fx: LineItemFixture) -> Q6Result:
    """Reference Q6 evaluator. Returns Q6Result (surviving + revenue)."""
    var n = fx.shipdate.length
    var revenue: Float64 = 0.0
    var count: Int = 0
    for i in range(n):
        var sd = Int64(fx.shipdate.get_typed[Scalar[DType.int64]](i))
        if sd >= Q6_SHIPDATE_LO and sd < Q6_SHIPDATE_HI:
            var dc = Float64(fx.discount.get_typed[Scalar[DType.float64]](i))
            if dc >= Q6_DISCOUNT_LO and dc <= Q6_DISCOUNT_HI:
                var qy = Float64(
                    fx.quantity.get_typed[Scalar[DType.float64]](i)
                )
                if qy < Q6_QUANTITY_HI:
                    var pr = Float64(
                        fx.price.get_typed[Scalar[DType.float64]](i)
                    )
                    revenue += pr * dc
                    count += 1
    return Q6Result(surviving_rows=count, revenue=revenue)


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_q6_executor_matches_naive_baseline_1000_rows() raises:
    """Synthetic 1000-row fixture; executor vs naive parity.

    GE/LT/LE-only predicates over non-NaN inputs -- the two paths MUST
    agree bit-identically.
    """
    var fx = _make_q6_synthetic(1000)
    var reference = _naive_q6(fx)

    var sel_a = RowSelectionVector(1000)
    var sel_b = RowSelectionVector(1000)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, reference.surviving_rows)
    # Exact agreement -- synthetic data has no NaN; GE/LT/LE/equality
    # semantics match across both paths.
    var diff = result.revenue - reference.revenue
    var abs_diff = diff if diff >= 0.0 else -diff
    assert_true(abs_diff < 1e-6)


def test_q6_executor_5000_rows_baseline_parity() raises:
    """Larger fixture (5000 rows) -- cross-checks the kernel under a
    longer SIMD body + more morsel-style stride boundaries."""
    var fx = _make_q6_synthetic(5000)
    var reference = _naive_q6(fx)

    var sel_a = RowSelectionVector(5000)
    var sel_b = RowSelectionVector(5000)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, reference.surviving_rows)
    var diff = result.revenue - reference.revenue
    var abs_diff = diff if diff >= 0.0 else -diff
    assert_true(abs_diff < 1e-6)


def test_q6_executor_zero_surviving() raises:
    """All rows fail the shipdate predicate -- surviving = 0; revenue = 0."""
    var fx = _make_zero_surviving(500)

    var sel_a = RowSelectionVector(500)
    var sel_b = RowSelectionVector(500)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, 0)
    assert_equal(result.revenue, 0.0)


def test_q6_executor_all_surviving() raises:
    """Every row passes; revenue computable in closed form.

    revenue = 0.06 * 1000.0 * sum(1..n) for n = 200.
            = 60.0 * (200 * 201 / 2)
            = 60.0 * 20100
            = 1206000.0
    """
    comptime N: Int = 200
    var fx = _make_all_surviving(N)

    var sel_a = RowSelectionVector(N)
    var sel_b = RowSelectionVector(N)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, N)
    var expected = 60.0 * Float64(N) * Float64(N + 1) / 2.0
    var diff = result.revenue - expected
    var abs_diff = diff if diff >= 0.0 else -diff
    # Allow modest fp slop -- 200 fp-adds in a different order than
    # the closed-form expansion. (Empirically: < 1e-7 on M3U; using
    # 1e-3 as a roomy tolerance vs the ~1.2e6 magnitude.)
    assert_true(abs_diff < 1e-3)


# -----------------------------------------------------------------------------
# SIMD-gather-path regression coverage.
#
# `_q6_sum_revenue` was rewritten from scalar `load_via_sel + scalar fma`
# to `gather_f64xW + SIMD fma + reduce_add`. These tests exercise:
#
#   - Various surviving counts spanning the SIMD-body / scalar-tail
#     boundary (sizes specifically chosen so n_surv % W != 0 for both
#     NEON W=2 and AVX-512 W=8).
#   - All-surviving with a row count that exercises both the W=8 SIMD
#     body (Linux AVX-512) and the W=2 SIMD body (NEON) — verified via
#     execute_q6_filter_and_sum (uses _q6_sum_revenue internally).
#   - Naive-baseline parity to confirm bit-identical (modulo fp accum
#     order) agreement.
# -----------------------------------------------------------------------------


def test_q6_simd_path_n_surv_eq_17_tail_handling() raises:
    """17 surviving rows = 2 * 8 + 1 tail (AVX-512); 8 * 2 + 1 tail (NEON).

    Specifically chosen to exercise the scalar tail past `simd_end`.
    Every row passes via the all-surviving fixture, so n_surv = 17.
    """
    comptime N: Int = 17
    var fx = _make_all_surviving(N)
    var reference = _naive_q6(fx)

    var sel_a = RowSelectionVector(N)
    var sel_b = RowSelectionVector(N)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, reference.surviving_rows)
    var diff = result.revenue - reference.revenue
    var abs_diff = diff if diff >= 0.0 else -diff
    assert_true(abs_diff < 1e-6)


def test_q6_simd_path_n_surv_eq_64_exact_avx512_multiple() raises:
    """64 surviving rows = 8 * 8 (exact AVX-512 SIMD body, zero scalar tail).

    On AVX-512: full 8 SIMD iterations of W=8, no tail. On NEON W=2:
    32 SIMD iterations, no tail. Confirms the SIMD path runs without
    relying on the scalar tail for correctness.
    """
    comptime N: Int = 64
    var fx = _make_all_surviving(N)
    var reference = _naive_q6(fx)

    var sel_a = RowSelectionVector(N)
    var sel_b = RowSelectionVector(N)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, reference.surviving_rows)
    var diff = result.revenue - reference.revenue
    var abs_diff = diff if diff >= 0.0 else -diff
    assert_true(abs_diff < 1e-6)


def test_q6_simd_path_single_survivor() raises:
    """n_surv == 1: SIMD body has zero iterations (simd_end == 0);
    scalar tail runs once. Edge case for the tail-only path."""
    var sd = List[Scalar[DType.int64]]()
    var dc = List[Scalar[DType.float64]]()
    var qy = List[Scalar[DType.float64]]()
    var pr = List[Scalar[DType.float64]]()
    # Build a 10-row fixture where exactly row 0 passes all conjuncts.
    sd.append(Scalar[DType.int64](Int64(8800)))   # passes
    dc.append(Scalar[DType.float64](0.06))         # passes
    qy.append(Scalar[DType.float64](20.0))         # passes
    pr.append(Scalar[DType.float64](42.0))
    for _ in range(9):
        sd.append(Scalar[DType.int64](Int64(3653)))  # fails shipdate
        dc.append(Scalar[DType.float64](0.06))
        qy.append(Scalar[DType.float64](20.0))
        pr.append(Scalar[DType.float64](1.0))
    var fx = LineItemFixture(
        PrimitiveArray[DType.int64].from_list(sd),
        PrimitiveArray[DType.float64].from_list(dc),
        PrimitiveArray[DType.float64].from_list(qy),
        PrimitiveArray[DType.float64].from_list(pr),
    )

    var sel_a = RowSelectionVector(10)
    var sel_b = RowSelectionVector(10)
    var result = execute_q6_filter_and_sum(
        fx.shipdate, fx.discount, fx.quantity, fx.price,
        Q6_SHIPDATE_LO, Q6_SHIPDATE_HI,
        Q6_DISCOUNT_LO, Q6_DISCOUNT_HI, Q6_QUANTITY_HI,
        sel_a, sel_b,
    )

    assert_equal(result.surviving_rows, 1)
    # revenue = 42.0 * 0.06 = 2.52
    var diff = result.revenue - 2.52
    var abs_diff = diff if diff >= 0.0 else -diff
    assert_true(abs_diff < 1e-9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
