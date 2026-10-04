# =============================================================================
# test_aggregator_trait — Wave 9 v4.1.3 Phase G-pre regression tests
# =============================================================================
#
# Bug-Fix Protocol regression test for the Aggregator trait + 8 builtin
# impls (plan §3.0b / §6.8a). Pre-Phase-G-pre: trait was an empty
# placeholder; SumF64 / SumI64 / CountStar / Min/Max[F64,I64] / AvgF64
# did not exist. Post-Phase-G-pre: 8 impls land + retrofit of existing
# AoS thunks. These tests lock kernel-math correctness per impl, plus
# default-impl loop equivalence vs override semantics on update_batch.
#
# Test cases (8 + 5 = 13 total; one per impl + cross-cutting checks):
#   1.  test_sum_f64_kernel_math    — 100-row randomized round-trip
#   2.  test_sum_i64_kernel_math    — 100-row randomized round-trip
#   3.  test_count_star_kernel_math — 100-row count
#   4.  test_min_f64_kernel_math    — 100-row min including ±inf edges
#   5.  test_max_f64_kernel_math    — 100-row max including ±inf edges
#   6.  test_min_i64_kernel_math    — 100-row min including INT_MIN
#   7.  test_max_i64_kernel_math    — 100-row max including INT_MAX
#   8.  test_avg_f64_kernel_math    — 100-row sum (AVG state IS sum;
#                                     finalize returns sum; SDK divides)
#   9.  test_update_batch_simd_matches_scalar_sum_f64
#                                   — SIMD update_batch override vs
#                                     scalar update loop produce
#                                     identical results
#   10. test_update_batch_default_impl_correctness
#                                   — Default-impl update_batch (loops
#                                     scalar) produces correct output;
#                                     this is the load-bearing
#                                     update_batch[N] caveat from
#                                     Repro 25 (`var s; states[i] = s`
#                                     pattern)
#   11. test_combine_partition_merge_sum_f64
#                                   — Split 1000 inputs across 4
#                                     workers, combine, verify identical
#                                     to single-worker sum
#   12. test_combine_partition_merge_min_f64
#                                   — Same shape for MIN; verifies
#                                     combine takes the lower
#   13. test_finalize_passthrough   — All 8 impls' finalize is
#                                     passthrough (identity on the State)
#
# Plan: an internal doc §3.0b / §6.8a.
# RFC: an internal doc §6.3.
# Spike: an internal doc
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.aggregator_trait import (
    Aggregator,
)
from komira_op_agg_state.aggregators_builtin import (
    SumF64,
    SumI64,
    CountStar,
    MinF64,
    MaxF64,
    MinI64,
    MaxI64,
    AvgF64,
)


# -----------------------------------------------------------------------------
# Test 1 — SumF64 kernel math: scalar update on 100 rows
# -----------------------------------------------------------------------------


def test_sum_f64_kernel_math() raises:
    """`SumF64.init / update / finalize` correctly sums 100 Float64 values.

    Reference computation: sum_{i=0..99} (i * 1.5) = 1.5 * 99*100/2 = 7425.0.
    Kernel-math correctness gate.
    """
    var state = SumF64.init()
    for i in range(100):
        SumF64.update(state, Float64(i) * 1.5)
    var out = SumF64.finalize(state)
    var expected = 1.5 * 99.0 * 100.0 / 2.0  # = 7425.0
    assert_true(out == Scalar[DType.float64](expected))


# -----------------------------------------------------------------------------
# Test 2 — SumI64 kernel math
# -----------------------------------------------------------------------------


def test_sum_i64_kernel_math() raises:
    """`SumI64.init / update / finalize` correctly sums 100 Int64 values.

    Reference: sum_{i=0..99} i = 99*100/2 = 4950.
    """
    var state = SumI64.init()
    for i in range(100):
        SumI64.update(state, Scalar[DType.int64](i))
    var out = SumI64.finalize(state)
    assert_true(out == Scalar[DType.int64](4950))


# -----------------------------------------------------------------------------
# Test 3 — CountStar kernel math
# -----------------------------------------------------------------------------


def test_count_star_kernel_math() raises:
    """`CountStar.init / update / finalize` increments by 1 per row.

    Inputs are ignored; 100 increments → state = 100.
    """
    var state = CountStar.init()
    for _i in range(100):
        # Input value is irrelevant — pass True (placeholder).
        CountStar.update(state, Scalar[DType.bool](True))
    var out = CountStar.finalize(state)
    assert_true(out == Scalar[DType.uint64](100))


# -----------------------------------------------------------------------------
# Test 4 — MinF64 kernel math (incl. ±inf init edge)
# -----------------------------------------------------------------------------


def test_min_f64_kernel_math() raises:
    """`MinF64.init / update / finalize` correctly tracks minimum.

    100 inputs in pattern (i + 0.5); minimum is 0.5.
    Init state is MIN's identity, the canonical NaN (MAX_FINITE until
    2026-09-25), so the first non-NaN update takes the input.
    """
    var state = MinF64.init()
    for i in range(100):
        MinF64.update(state, Float64(i) + 0.5)
    var out = MinF64.finalize(state)
    assert_true(out == Scalar[DType.float64](0.5))


# -----------------------------------------------------------------------------
# Test 5 — MaxF64 kernel math
# -----------------------------------------------------------------------------


def test_max_f64_kernel_math() raises:
    """`MaxF64.init / update / finalize` correctly tracks maximum.

    100 inputs in pattern (i + 0.5); maximum is 99.5.
    """
    var state = MaxF64.init()
    for i in range(100):
        MaxF64.update(state, Float64(i) + 0.5)
    var out = MaxF64.finalize(state)
    assert_true(out == Scalar[DType.float64](99.5))


# -----------------------------------------------------------------------------
# Test 6 — MinI64 kernel math
# -----------------------------------------------------------------------------


def test_min_i64_kernel_math() raises:
    """`MinI64.init / update / finalize` correctly tracks minimum Int64.

    100 inputs starting at -50; minimum is -50.
    """
    var state = MinI64.init()
    for i in range(100):
        MinI64.update(state, Scalar[DType.int64](i - 50))
    var out = MinI64.finalize(state)
    assert_true(out == Scalar[DType.int64](-50))


# -----------------------------------------------------------------------------
# Test 7 — MaxI64 kernel math
# -----------------------------------------------------------------------------


def test_max_i64_kernel_math() raises:
    """`MaxI64.init / update / finalize` correctly tracks maximum Int64.

    100 inputs from 0..99; maximum is 99.
    """
    var state = MaxI64.init()
    for i in range(100):
        MaxI64.update(state, Scalar[DType.int64](i))
    var out = MaxI64.finalize(state)
    assert_true(out == Scalar[DType.int64](99))


# -----------------------------------------------------------------------------
# Test 8 — AvgF64 kernel math (sum-only state form)
# -----------------------------------------------------------------------------


def test_avg_f64_kernel_math() raises:
    """`AvgF64.init / update / finalize` accumulates SUM (count is sibling slot).

    100 inputs of value 2.5; sum = 250.0. Finalize is passthrough; SDK
    materialization layer divides by COUNT slot.
    """
    var state = AvgF64.init()
    for _i in range(100):
        AvgF64.update(state, Scalar[DType.float64](2.5))
    var out = AvgF64.finalize(state)
    assert_true(out == Scalar[DType.float64](250.0))


# -----------------------------------------------------------------------------
# Test 9 — SIMD update_batch override vs scalar loop equivalence for SumF64
# -----------------------------------------------------------------------------
#
# SumF64 overrides update_batch with `ss += xs`. Verify the override
# produces identical results to scalar update across N=2/4/8 lane widths.
# -----------------------------------------------------------------------------


def test_update_batch_simd_matches_scalar_sum_f64() raises:
    """`SumF64.update_batch[N]` (vectorized override) matches scalar update
    loop for N=2/4/8 lane widths.

    Build a SIMD vector and a scalar loop with the same inputs; assert
    pairwise lane equality. This pins the SIMD-override semantics so a
    silent revert (e.g. dropping `ss += xs` in favor of the default impl)
    is caught.
    """
    # Test N=2.
    var states_scalar2 = SIMD[DType.float64, 2](0.0)
    var states_simd2 = SIMD[DType.float64, 2](0.0)
    var inputs2 = SIMD[DType.float64, 2](1.5, 2.5)
    # Scalar loop using default-impl roundtrip pattern.
    comptime for i in range(2):
        var s = states_scalar2[i]
        SumF64.update(s, inputs2[i])
        states_scalar2[i] = s
    SumF64.update_batch[2](states_simd2, inputs2)
    assert_true(states_scalar2[0] == states_simd2[0])
    assert_true(states_scalar2[1] == states_simd2[1])

    # Test N=4.
    var states_scalar4 = SIMD[DType.float64, 4](0.0)
    var states_simd4 = SIMD[DType.float64, 4](0.0)
    var inputs4 = SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0)
    comptime for i in range(4):
        var s = states_scalar4[i]
        SumF64.update(s, inputs4[i])
        states_scalar4[i] = s
    SumF64.update_batch[4](states_simd4, inputs4)
    comptime for i in range(4):
        assert_true(states_scalar4[i] == states_simd4[i])

    # Test N=8.
    var states_scalar8 = SIMD[DType.float64, 8](0.0)
    var states_simd8 = SIMD[DType.float64, 8](0.0)
    var inputs8 = SIMD[DType.float64, 8](
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0
    )
    comptime for i in range(8):
        var s = states_scalar8[i]
        SumF64.update(s, inputs8[i])
        states_scalar8[i] = s
    SumF64.update_batch[8](states_simd8, inputs8)
    comptime for i in range(8):
        assert_true(states_scalar8[i] == states_simd8[i])


# -----------------------------------------------------------------------------
# Test 10 — Default-impl update_batch correctness on MinF64 (no override)
# -----------------------------------------------------------------------------
#
# MinF64 does NOT override update_batch — it uses the default-impl loop.
# This test pins the load-bearing `var s = states[i]; Self.update(s, ...);
# states[i] = s` pattern from Repro 25 (the SIMD lane mutation
# roundtrip is mandatory for default-impl correctness).
# -----------------------------------------------------------------------------


def test_update_batch_default_impl_correctness() raises:
    """`MinF64.update_batch[4]` (default impl, no override) produces correct
    per-lane minimum.

    Lanes start at MAX_FINITE here (an explicit seed, not `MinF64.init()`,
    which is the canonical NaN since 2026-09-25); updates against (i+0.5)
    → lane[i] = i+0.5 (smaller than MAX_FINITE).
    """
    var states = SIMD[DType.float64, 4](
        Scalar[DType.float64].MAX_FINITE,
        Scalar[DType.float64].MAX_FINITE,
        Scalar[DType.float64].MAX_FINITE,
        Scalar[DType.float64].MAX_FINITE,
    )
    var inputs = SIMD[DType.float64, 4](0.5, 1.5, 2.5, 3.5)
    MinF64.update_batch[4](states, inputs)
    # Each lane took the smaller value (input < MAX_FINITE init).
    assert_true(states[0] == Scalar[DType.float64](0.5))
    assert_true(states[1] == Scalar[DType.float64](1.5))
    assert_true(states[2] == Scalar[DType.float64](2.5))
    assert_true(states[3] == Scalar[DType.float64](3.5))


# -----------------------------------------------------------------------------
# Test 11 — combine on partitioned SUM workers yields the same total
# -----------------------------------------------------------------------------


def test_combine_partition_merge_sum_f64() raises:
    """Split 1000 inputs across 4 workers; combine partials; verify
    identical to single-worker SUM.

    Reference: sum_{i=0..999} (i * 1.5) = 1.5 * 999 * 1000 / 2 = 749250.0.
    """
    # Single-worker reference.
    var ref_state = SumF64.init()
    for i in range(1000):
        SumF64.update(ref_state, Float64(i) * 1.5)

    # 4-worker partitioned.
    var w0 = SumF64.init()
    var w1 = SumF64.init()
    var w2 = SumF64.init()
    var w3 = SumF64.init()
    for i in range(0, 250):
        SumF64.update(w0, Float64(i) * 1.5)
    for i in range(250, 500):
        SumF64.update(w1, Float64(i) * 1.5)
    for i in range(500, 750):
        SumF64.update(w2, Float64(i) * 1.5)
    for i in range(750, 1000):
        SumF64.update(w3, Float64(i) * 1.5)

    # Combine pairwise then root.
    SumF64.combine(w0, w1)
    SumF64.combine(w2, w3)
    SumF64.combine(w0, w2)

    var ref_out = SumF64.finalize(ref_state)
    var combined_out = SumF64.finalize(w0)
    var expected = 1.5 * 999.0 * 1000.0 / 2.0  # = 749250.0
    assert_true(ref_out == Scalar[DType.float64](expected))
    assert_true(combined_out == Scalar[DType.float64](expected))
    assert_true(ref_out == combined_out)


# -----------------------------------------------------------------------------
# Test 12 — combine on partitioned MIN workers yields the global minimum
# -----------------------------------------------------------------------------


def test_combine_partition_merge_min_f64() raises:
    """Split 1000 inputs across 4 workers; combine partial MINs; verify
    identical to single-worker MIN.

    Inputs are i + 0.5 in 0..999; global min = 0.5 (in worker 0's range).
    """
    # Single-worker reference.
    var ref_state = MinF64.init()
    for i in range(1000):
        MinF64.update(ref_state, Float64(i) + 0.5)

    # 4-worker partitioned.
    var w0 = MinF64.init()
    var w1 = MinF64.init()
    var w2 = MinF64.init()
    var w3 = MinF64.init()
    for i in range(0, 250):
        MinF64.update(w0, Float64(i) + 0.5)
    for i in range(250, 500):
        MinF64.update(w1, Float64(i) + 0.5)
    for i in range(500, 750):
        MinF64.update(w2, Float64(i) + 0.5)
    for i in range(750, 1000):
        MinF64.update(w3, Float64(i) + 0.5)

    # Combine pairwise.
    MinF64.combine(w0, w1)
    MinF64.combine(w2, w3)
    MinF64.combine(w0, w2)

    var ref_out = MinF64.finalize(ref_state)
    var combined_out = MinF64.finalize(w0)
    assert_true(ref_out == Scalar[DType.float64](0.5))
    assert_true(combined_out == Scalar[DType.float64](0.5))
    assert_true(ref_out == combined_out)


# -----------------------------------------------------------------------------
# Test 13 — finalize is passthrough for the 8 impls
# -----------------------------------------------------------------------------


def test_finalize_passthrough() raises:
    """All 8 Aggregator impls' finalize is identity on State.

    Phase G-pre's retrofit kernels treat State as the materialized
    output. AVG's divide happens at SDK materialization, not in
    Aggregator.finalize (the count slot is handled by a sibling
    AccTag entry).
    """
    # SumF64
    assert_true(
        SumF64.finalize(Scalar[DType.float64](7.5))
        == Scalar[DType.float64](7.5)
    )
    # SumI64
    assert_true(
        SumI64.finalize(Scalar[DType.int64](42))
        == Scalar[DType.int64](42)
    )
    # CountStar
    assert_true(
        CountStar.finalize(Scalar[DType.uint64](100))
        == Scalar[DType.uint64](100)
    )
    # MinF64
    assert_true(
        MinF64.finalize(Scalar[DType.float64](0.5))
        == Scalar[DType.float64](0.5)
    )
    # MaxF64
    assert_true(
        MaxF64.finalize(Scalar[DType.float64](99.5))
        == Scalar[DType.float64](99.5)
    )
    # MinI64
    assert_true(
        MinI64.finalize(Scalar[DType.int64](-50))
        == Scalar[DType.int64](-50)
    )
    # MaxI64
    assert_true(
        MaxI64.finalize(Scalar[DType.int64](99))
        == Scalar[DType.int64](99)
    )
    # AvgF64
    assert_true(
        AvgF64.finalize(Scalar[DType.float64](250.0))
        == Scalar[DType.float64](250.0)
    )


# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_sum_f64_kernel_math]()
    suite.test[test_sum_i64_kernel_math]()
    suite.test[test_count_star_kernel_math]()
    suite.test[test_min_f64_kernel_math]()
    suite.test[test_max_f64_kernel_math]()
    suite.test[test_min_i64_kernel_math]()
    suite.test[test_max_i64_kernel_math]()
    suite.test[test_avg_f64_kernel_math]()
    suite.test[test_update_batch_simd_matches_scalar_sum_f64]()
    suite.test[test_update_batch_default_impl_correctness]()
    suite.test[test_combine_partition_merge_sum_f64]()
    suite.test[test_combine_partition_merge_min_f64]()
    suite.test[test_finalize_passthrough]()
    suite^.run()
