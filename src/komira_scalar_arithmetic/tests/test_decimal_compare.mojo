# =============================================================================
# DECIMAL128 COMPARISON at different scales: every operator over a less, an
# equal and a greater pair, the widest scale gap, and an unknown operator.
#
# Oracle: the numbers themselves. 1.5 (scale 1) equals 1.50 (scale 2); 2
# (scale 0) is greater than 1.5 (scale 1) though its unscaled 2 is less than
# the unscaled 15, so a comparison that skipped the rescale would answer it
# the wrong way.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_compare import (
    DEC_CMP_LT,
    DEC_CMP_LE,
    DEC_CMP_GT,
    DEC_CMP_GE,
    DEC_CMP_EQ,
    DEC_CMP_NE,
    decimal_cmp_i128,
)


# Each product call goes through a @no_inline wrapper: its arguments are then
# runtime values, so the compiler cannot fold an @always_inline body at a
# constant call site and the coverage run sees every arm the test takes.

@no_inline
def _rt_decimal_cmp_i128(a: I128, s1: Int, b: I128, s2: Int, op: UInt8) raises -> Bool:
    return decimal_cmp_i128(a, s1, b, s2, op)


comptime MAX38 = I128(99999999999999999999999999999999999999)


def _row(a: I128, s1: Int, b: I128, s2: Int, lt: Bool, eq: Bool, gt: Bool) raises:
    """Asserts all six operators for one pair whose order is (lt, eq, gt)."""
    assert_equal(_rt_decimal_cmp_i128(a, s1, b, s2, DEC_CMP_LT), lt)
    assert_equal(_rt_decimal_cmp_i128(a, s1, b, s2, DEC_CMP_LE), lt or eq)
    assert_equal(_rt_decimal_cmp_i128(a, s1, b, s2, DEC_CMP_GT), gt)
    assert_equal(_rt_decimal_cmp_i128(a, s1, b, s2, DEC_CMP_GE), gt or eq)
    assert_equal(_rt_decimal_cmp_i128(a, s1, b, s2, DEC_CMP_EQ), eq)
    assert_equal(_rt_decimal_cmp_i128(a, s1, b, s2, DEC_CMP_NE), not eq)


def test_equal_at_different_scales() raises:
    """1.5 (s=1) vs 1.50 (s=2), both ways round, and -1.5 vs -1.50."""
    _row(I128(15), 1, I128(150), 2, False, True, False)
    _row(I128(150), 2, I128(15), 1, False, True, False)
    _row(I128(-15), 1, I128(-150), 2, False, True, False)


def test_less_at_different_scales() raises:
    """1.5 < 1.51; 1.5 (s=1) < 2 (s=0) though 15 > 2 unscaled; -2 < -1.5."""
    _row(I128(15), 1, I128(151), 2, True, False, False)
    _row(I128(15), 1, I128(2), 0, True, False, False)
    _row(I128(-2), 0, I128(-15), 1, True, False, False)


def test_greater_at_different_scales() raises:
    """2 (s=0) > 1.5 (s=1) though 2 < 15 unscaled; 1.51 > 1.5; 0 > -0.001."""
    _row(I128(2), 0, I128(15), 1, False, False, True)
    _row(I128(151), 2, I128(15), 1, False, False, True)
    _row(I128(0), 0, I128(-1), 3, False, False, True)


def test_widest_scale_gap() raises:
    """(10^38 - 1) at scale 0 against (10^38 - 1) at scale 38: rescaling the
    left side multiplies it by 10^38, which leaves 128 bits; the comparison
    must still see 10^38 - 1 > 0.99..9 and -(10^38 - 1) < 0.99..9."""
    _row(MAX38, 0, MAX38, 38, False, False, True)
    _row(-MAX38, 0, MAX38, 38, True, False, False)
    _row(MAX38, 38, -MAX38, 0, False, False, True)
    # 10^37 at scale 37 is 1.
    _row(I128(1), 0, I128(10000000000000000000000000000000000000), 37, False, True, False)


def test_unknown_operator_raises() raises:
    var msg = String("")
    try:
        _ = _rt_decimal_cmp_i128(I128(1), 0, I128(1), 0, UInt8(6))
    except e:
        msg = String(e)
    assert_equal(msg, "decimal_cmp_i128: unknown op 6")
    var msg255 = String("")
    try:
        _ = _rt_decimal_cmp_i128(I128(1), 0, I128(2), 0, UInt8(255))
    except e:
        msg255 = String(e)
    assert_equal(msg255, "decimal_cmp_i128: unknown op 255")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
