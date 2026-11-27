# =============================================================================
# test_libm_atan2_bit_exact — `libm_atan2` returns libm's `atan2` bit for bit
# =============================================================================
#
# DuckDB computes `atan2` with libm, and komira's math columns are compared with
# it value by value (see the header of `column_kernels/scalar_math.mojo`). The
# expected values below are libm's results written with 17 significant digits,
# so each literal is the exact double glibc's libm returns. On Linux, where the
# oracle runs and its libm is glibc, the asserts use exact equality, no
# tolerance: a kernel that is only correct to within an ulp, such as
# `std.math.atan2` from Mojo 1.2.0, fails them. Elsewhere the platform's libm is
# not glibc's and may round differently, so the comparison accepts the same
# 4-ulp distance the conformance suites allow off the oracle's host
# (src/tests/helpers/komira_plan_harness/libm_rule.mojo).
# =============================================================================

from std.math import isnan, pi
from std.memory import bitcast
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from column_kernels.scalar_math import libm_atan2


# The distance, in units in the last place, that a value off the oracle's host may be
# from glibc's (OFF_ORACLE_HOST_ULPS of komira_plan_harness's libm rule).
comptime _OFF_ORACLE_HOST_ULPS = 4


def _ulps_apart(a: Float64, b: Float64) -> Int:
    """The number of doubles between `a` and `b` (both finite, same sign)."""
    var x = Int(bitcast[DType.int64](a))
    var y = Int(bitcast[DType.int64](b))
    return x - y if x >= y else y - x


def _assert_libm(got: Float64, want: Float64) raises:
    """`got` is glibc's `want` bit for bit on Linux, and within the off-host ulps elsewhere."""
    comptime if CompilationTarget.is_linux():
        assert_equal(got, want)
    else:
        assert_true(
            _ulps_apart(got, want) <= _OFF_ORACLE_HOST_ULPS,
            String("off the oracle's host, ") + String(got) + " is more than 4 ulp from " + String(want),
        )


def test_atan2_matches_libm_to_the_last_bit() raises:
    _assert_libm(libm_atan2(1.0, 1.0), 0.7853981633974483)
    _assert_libm(libm_atan2(0.5, 3.0), 0.16514867741462683)
    _assert_libm(libm_atan2(-2.0, -7.0), -2.8632929945846817)
    _assert_libm(libm_atan2(0.001, 0.7), 0.0014285704567553203)
    _assert_libm(libm_atan2(3.0, -4.0), 2.498091544796509)
    _assert_libm(libm_atan2(123.456, 0.001), 1.5707882267430564)


def test_atan2_axis_and_signed_zero_cases_follow_libm() raises:
    assert_equal(libm_atan2(0.0, -1.0), pi)
    assert_equal(libm_atan2(-0.0, -1.0), -pi)
    assert_equal(libm_atan2(0.0, 0.0), 0.0)
    assert_equal(libm_atan2(1.0, 0.0), pi / 2.0)


def test_atan2_nan_operand_gives_nan() raises:
    var zero = Float64(0.0)
    var nan = zero / zero
    assert_true(isnan(libm_atan2(nan, 1.0)), "NaN y gives NaN")
    assert_true(isnan(libm_atan2(1.0, nan)), "NaN x gives NaN")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
