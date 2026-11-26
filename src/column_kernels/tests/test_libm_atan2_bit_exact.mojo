# =============================================================================
# test_libm_atan2_bit_exact — `libm_atan2` returns libm's `atan2` bit for bit
# =============================================================================
#
# DuckDB computes `atan2` with libm, and komira's math columns are compared with
# it value by value (see the header of `column_kernels/scalar_math.mojo`). The
# expected values below are libm's results written with 17 significant digits,
# so each literal is the exact double libm returns; the asserts use exact
# equality, no tolerance. A kernel that is only correct to within an ulp, such
# as `std.math.atan2` from Mojo 1.2.0, fails them.
# =============================================================================

from std.math import isnan, pi
from std.testing import TestSuite, assert_equal, assert_true

from column_kernels.scalar_math import libm_atan2


def test_atan2_matches_libm_to_the_last_bit() raises:
    assert_equal(libm_atan2(1.0, 1.0), 0.7853981633974483)
    assert_equal(libm_atan2(0.5, 3.0), 0.16514867741462683)
    assert_equal(libm_atan2(-2.0, -7.0), -2.8632929945846817)
    assert_equal(libm_atan2(0.001, 0.7), 0.0014285704567553203)
    assert_equal(libm_atan2(3.0, -4.0), 2.498091544796509)
    assert_equal(libm_atan2(123.456, 0.001), 1.5707882267430564)


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
