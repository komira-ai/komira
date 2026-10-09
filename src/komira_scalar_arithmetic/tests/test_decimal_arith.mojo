# =============================================================================
# DECIMAL128 ARITHMETIC: powers of ten, the overflow predicate, HALF_UP
# rescale, the result-type rules and add / sub / mul / div.
#
# Every expected value is worked out by hand from the rules in the header of
# `decimal_arith.mojo` (result types after arrow-rs `decimal_op`, division
# rounding half away from zero) and SQL decimal semantics. A Decimal128 holds
# at most 38 digits: its largest magnitude is 10^38 - 1.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.decimal_arith import (
    I128,
    I256,
    pow10_i128,
    pow10_i256,
    max_dec128_i256,
    overflows_dec128,
    i256_abs,
    i256_sign,
    rescale_i256_half_up,
    decimal_add_result_ps,
    decimal_mul_result_ps_checked,
    decimal_mul_result_ps,
    decimal_div_result_ps,
    decimal_add_i128,
    decimal_sub_i128,
    decimal_mul_i128,
    decimal_div_i128,
)


# Each product call goes through a @no_inline wrapper: its arguments are then
# runtime values, so the compiler cannot fold an @always_inline body at a
# constant call site and the coverage run sees every arm the test takes.

@no_inline
def _rt_pow10_i128(n: Int) raises -> I128:
    return pow10_i128(n)


@no_inline
def _rt_pow10_i256(n: Int) raises -> I256:
    return pow10_i256(n)


@no_inline
def _rt_max_dec128_i256() raises -> I256:
    return max_dec128_i256()


@no_inline
def _rt_overflows_dec128(v: I256) raises -> Bool:
    return overflows_dec128(v)


@no_inline
def _rt_i256_abs(v: I256) raises -> I256:
    return i256_abs(v)


@no_inline
def _rt_i256_sign(v: I256) raises -> I256:
    return i256_sign(v)


@no_inline
def _rt_rescale_i256_half_up(v: I256, f: Int, t: Int) raises -> I256:
    return rescale_i256_half_up(v, f, t)


@no_inline
def _rt_decimal_add_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    return decimal_add_result_ps(p1, s1, p2, s2)


@no_inline
def _rt_decimal_mul_result_ps_checked(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int, Bool]:
    return decimal_mul_result_ps_checked(p1, s1, p2, s2)


@no_inline
def _rt_decimal_mul_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    return decimal_mul_result_ps(p1, s1, p2, s2)


@no_inline
def _rt_decimal_div_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    return decimal_div_result_ps(p1, s1, p2, s2)


@no_inline
def _rt_decimal_add_i128(a: I128, s1: Int, b: I128, s2: Int, o: Int) raises -> I128:
    return decimal_add_i128(a, s1, b, s2, o)


@no_inline
def _rt_decimal_sub_i128(a: I128, s1: Int, b: I128, s2: Int, o: Int) raises -> I128:
    return decimal_sub_i128(a, s1, b, s2, o)


@no_inline
def _rt_decimal_mul_i128(a: I128, b: I128) raises -> I128:
    return decimal_mul_i128(a, b)


@no_inline
def _rt_decimal_div_i128(a: I128, s1: Int, b: I128, s2: Int, o: Int) raises -> I128:
    return decimal_div_i128(a, s1, b, s2, o)


# 10^38 - 1 (38 nines), 10^38, and the two factors of 10^38 - 1.
comptime MAX38 = I128(99999999999999999999999999999999999999)
comptime TEN38_256 = I256(100000000000000000000000000000000000000)
comptime TEN19_M1 = I128(9999999999999999999)
comptime TEN19 = I128(10000000000000000000)
comptime TEN19_P1 = I128(10000000000000000001)


def _message_of_add(a: I128, s1: Int, b: I128, s2: Int, out_scale: Int) -> String:
    try:
        _ = _rt_decimal_add_i128(a, s1, b, s2, out_scale)
    except e:
        return String(e)
    return String("")


def _message_of_sub(a: I128, s1: Int, b: I128, s2: Int, out_scale: Int) -> String:
    try:
        _ = _rt_decimal_sub_i128(a, s1, b, s2, out_scale)
    except e:
        return String(e)
    return String("")


def _message_of_mul(a: I128, b: I128) -> String:
    try:
        _ = _rt_decimal_mul_i128(a, b)
    except e:
        return String(e)
    return String("")


def _message_of_div(a: I128, s1: Int, b: I128, s2: Int, out_scale: Int) -> String:
    try:
        _ = _rt_decimal_div_i128(a, s1, b, s2, out_scale)
    except e:
        return String(e)
    return String("")


# --- powers of ten -----------------------------------------------------------


def test_pow10_i128_values_and_bounds() raises:
    """10^n for n in [0, 38]; -1 and 39 are refused, naming the exponent."""
    assert_equal(_rt_pow10_i128(0), I128(1))
    assert_equal(_rt_pow10_i128(1), I128(10))
    assert_equal(_rt_pow10_i128(18), I128(1000000000000000000))
    assert_equal(_rt_pow10_i128(38), MAX38 + I128(1))
    var low = String("")
    try:
        _ = _rt_pow10_i128(-1)
    except e:
        low = String(e)
    assert_equal(low, "pow10_i128: exponent -1 out of range [0, 38]")
    var high = String("")
    try:
        _ = _rt_pow10_i128(39)
    except e:
        high = String(e)
    assert_equal(high, "pow10_i128: exponent 39 out of range [0, 38]")


def test_pow10_i256_values_and_bounds() raises:
    """10^n for n in [0, 76]; -1 and 77 are refused."""
    assert_equal(_rt_pow10_i256(0), I256(1))
    assert_equal(_rt_pow10_i256(38), TEN38_256)
    assert_equal(
        _rt_pow10_i256(76),
        I256(10000000000000000000000000000000000000000000000000000000000000000000000000000),
    )
    var low = String("")
    try:
        _ = _rt_pow10_i256(-1)
    except e:
        low = String(e)
    assert_equal(low, "pow10_i256: exponent -1 out of range [0, 76]")
    var high = String("")
    try:
        _ = _rt_pow10_i256(77)
    except e:
        high = String(e)
    assert_equal(high, "pow10_i256: exponent 77 out of range [0, 76]")


# --- the overflow predicate and helpers --------------------------------------


def test_max_and_overflow_boundary() raises:
    """10^38 - 1 is the largest magnitude; one past it on either side overflows."""
    assert_equal(_rt_max_dec128_i256(), TEN38_256 - I256(1))
    assert_false(_rt_overflows_dec128(I256(0)))
    assert_false(_rt_overflows_dec128(TEN38_256 - I256(1)))
    assert_false(_rt_overflows_dec128(-(TEN38_256 - I256(1))))
    assert_true(_rt_overflows_dec128(TEN38_256))
    assert_true(_rt_overflows_dec128(-TEN38_256))


def test_i256_abs_and_sign() raises:
    assert_equal(_rt_i256_abs(I256(-5)), I256(5))
    assert_equal(_rt_i256_abs(I256(5)), I256(5))
    assert_equal(_rt_i256_abs(I256(0)), I256(0))
    assert_equal(_rt_i256_sign(I256(7)), I256(1))
    assert_equal(_rt_i256_sign(I256(-7)), I256(-1))
    assert_equal(_rt_i256_sign(I256(0)), I256(0))


# --- HALF_UP rescale -----------------------------------------------------------


def test_rescale_same_and_up() raises:
    """Same scale is the identity; scaling up multiplies by a power of ten."""
    assert_equal(_rt_rescale_i256_half_up(I256(-42), 3, 3), I256(-42))
    assert_equal(_rt_rescale_i256_half_up(I256(123), 2, 4), I256(12300))
    assert_equal(_rt_rescale_i256_half_up(I256(-123), 0, 2), I256(-12300))


def test_rescale_down_ties_and_non_ties() raises:
    """Scaling down rounds half away from zero.

    1.49 -> 1 (2 * 49 < 100), 1.50 -> 2 (the tie), 1.25 -> 1.3 at scale 1.
    The negative non-ties -3.99 -> -4 and -3.01 -> -3 are the cells a floored
    remainder gets wrong; -3.50 -> -4 is the negative tie."""
    assert_equal(_rt_rescale_i256_half_up(I256(149), 2, 0), I256(1))
    assert_equal(_rt_rescale_i256_half_up(I256(150), 2, 0), I256(2))
    assert_equal(_rt_rescale_i256_half_up(I256(125), 2, 1), I256(13))
    assert_equal(_rt_rescale_i256_half_up(I256(-125), 2, 1), I256(-13))
    assert_equal(_rt_rescale_i256_half_up(I256(-399), 2, 0), I256(-4))
    assert_equal(_rt_rescale_i256_half_up(I256(-301), 2, 0), I256(-3))
    assert_equal(_rt_rescale_i256_half_up(I256(-350), 2, 0), I256(-4))
    assert_equal(_rt_rescale_i256_half_up(I256(-349), 2, 0), I256(-3))
    assert_equal(_rt_rescale_i256_half_up(I256(0), 5, 0), I256(0))


# --- result types ----------------------------------------------------------------


def test_add_result_ps() raises:
    """(p, s) = (min(max(p1-s1, p2-s2) + max(s1, s2) + 1, 38), max(s1, s2))."""
    var a = _rt_decimal_add_result_ps(5, 2, 4, 3)
    assert_equal(a[0], 7)
    assert_equal(a[1], 3)
    # The integer digits come from the second operand here: max(0, 5) = 5.
    var b = _rt_decimal_add_result_ps(10, 10, 5, 0)
    assert_equal(b[0], 16)
    assert_equal(b[1], 10)
    # 37 integer digits + 1 is exactly 38: not clamped, not over.
    var c = _rt_decimal_add_result_ps(37, 0, 1, 0)
    assert_equal(c[0], 38)
    assert_equal(c[1], 0)
    var d = _rt_decimal_add_result_ps(38, 0, 38, 0)
    assert_equal(d[0], 38)
    assert_equal(d[1], 0)


def test_mul_result_ps_scale_rule() raises:
    """Scale s1 + s2, representable while it is at most 38.

    The precision is asserted only where it clamps to 38 (p1 + p2 >= 38):
    there min(p1 + p2 + 1, 38) and the proposed min(p1 + p2, 38) agree."""
    var a = _rt_decimal_mul_result_ps_checked(20, 2, 20, 3)
    assert_equal(a[0], 38)
    assert_equal(a[1], 5)
    assert_true(a[2])
    var edge = _rt_decimal_mul_result_ps_checked(38, 19, 38, 19)
    assert_equal(edge[0], 38)
    assert_equal(edge[1], 38)
    assert_true(edge[2])
    var over = _rt_decimal_mul_result_ps_checked(38, 20, 38, 19)
    assert_equal(over[1], 39)
    assert_false(over[2])
    var r = _rt_decimal_mul_result_ps(19, 4, 19, 6)
    assert_equal(r[0], 38)
    assert_equal(r[1], 10)


def test_mul_result_ps_raises_past_scale_38() raises:
    """DuckDB refuses a product needing scale > 38 at bind time; so does this."""
    var msg = String("")
    try:
        _ = _rt_decimal_mul_result_ps(38, 20, 38, 19)
    except e:
        msg = String(e)
    assert_true(msg.startswith("Decimal128 mul: result scale 39 exceeds 38"), msg)
    # 38 itself is fine.
    var ok = _rt_decimal_mul_result_ps(38, 19, 38, 19)
    assert_equal(ok[1], 38)


def test_div_result_ps() raises:
    """s = min(s1 + 4, 38); p = min(s - s1 + s2 + p1, 38)."""
    var a = _rt_decimal_div_result_ps(5, 2, 4, 3)
    assert_equal(a[1], 6)
    assert_equal(a[0], 12)
    var b = _rt_decimal_div_result_ps(10, 0, 10, 10)
    assert_equal(b[1], 4)
    assert_equal(b[0], 24)
    # s1 + 4 = 38 exactly, and s1 + 4 = 40 clamps to 38.
    var c = _rt_decimal_div_result_ps(34, 34, 1, 0)
    assert_equal(c[1], 38)
    assert_equal(c[0], 38)
    var d = _rt_decimal_div_result_ps(38, 36, 10, 0)
    assert_equal(d[1], 38)
    assert_equal(d[0], 38)


# --- add / sub -------------------------------------------------------------------


def test_add_aligns_scales() raises:
    """123.45 + 6.789 = 130.239; -1 + 0.5 = -0.5."""
    assert_equal(_rt_decimal_add_i128(I128(12345), 2, I128(6789), 3, 3), I128(130239))
    assert_equal(_rt_decimal_add_i128(I128(-1), 0, I128(5), 1, 1), I128(-5))
    assert_equal(_rt_decimal_add_i128(I128(5), 1, I128(-1), 0, 2), I128(-50))


def test_add_overflow_boundary() raises:
    """(10^38 - 2) + 1 is the maximum; (10^38 - 1) + 1 overflows, both signs."""
    assert_equal(_rt_decimal_add_i128(MAX38 - I128(1), 0, I128(1), 0, 0), MAX38)
    assert_equal(_rt_decimal_add_i128(-MAX38 + I128(1), 0, I128(-1), 0, 0), -MAX38)
    var up = _message_of_add(MAX38, 0, I128(1), 0, 0)
    assert_true(up.startswith("Decimal128 overflow in add"), up)
    var down = _message_of_add(-MAX38, 0, I128(-1), 0, 0)
    assert_true(down.startswith("Decimal128 overflow in add"), down)
    # Overflow by rescaling: 10^36 at scale 0 is 10^38 at scale 2.
    var scaled = _message_of_add(I128(1000000000000000000000000000000000000), 0, I128(0), 2, 2)
    assert_true(scaled.startswith("Decimal128 overflow in add"), scaled)


def test_sub_aligns_scales_and_signs() raises:
    """200.00 - 75.5 = 124.50; 10 - 25 = -15; 0.5 - (-1) = 1.5."""
    assert_equal(_rt_decimal_sub_i128(I128(20000), 2, I128(755), 1, 2), I128(12450))
    assert_equal(_rt_decimal_sub_i128(I128(10), 0, I128(25), 0, 0), I128(-15))
    assert_equal(_rt_decimal_sub_i128(I128(5), 1, I128(-1), 0, 1), I128(15))


def test_sub_overflow_boundary() raises:
    assert_equal(_rt_decimal_sub_i128(-MAX38 + I128(1), 0, I128(1), 0, 0), -MAX38)
    assert_equal(_rt_decimal_sub_i128(MAX38 - I128(1), 0, I128(-1), 0, 0), MAX38)
    var down = _message_of_sub(-MAX38, 0, I128(1), 0, 0)
    assert_true(down.startswith("Decimal128 overflow in sub"), down)
    var up = _message_of_sub(MAX38, 0, I128(-1), 0, 0)
    assert_true(up.startswith("Decimal128 overflow in sub"), up)


# --- mul -------------------------------------------------------------------------


def test_mul_values() raises:
    assert_equal(_rt_decimal_mul_i128(I128(-25), I128(4)), I128(-100))
    assert_equal(_rt_decimal_mul_i128(I128(-3), I128(-7)), I128(21))
    assert_equal(_rt_decimal_mul_i128(I128(0), MAX38), I128(0))


def test_mul_overflow_boundary() raises:
    """(10^19 - 1)(10^19 + 1) = 10^38 - 1 fits; 10^19 * 10^19 = 10^38 does not."""
    assert_equal(_rt_decimal_mul_i128(TEN19_M1, TEN19_P1), MAX38)
    assert_equal(_rt_decimal_mul_i128(-TEN19_M1, TEN19_P1), -MAX38)
    assert_equal(_rt_decimal_mul_i128(-MAX38, I128(-1)), MAX38)
    var up = _message_of_mul(TEN19, TEN19)
    assert_true(up.startswith("Decimal128 overflow in mul"), up)
    var down = _message_of_mul(-TEN19, TEN19)
    assert_true(down.startswith("Decimal128 overflow in mul"), down)


# --- div -------------------------------------------------------------------------


def test_div_rounds_half_away_from_zero() raises:
    """1/3 = 0.333333 and 2/3 = 0.666667 at scale 6; 1/8 = 0.125 -> 0.13 and
    -1/8 -> -0.13 at scale 2 (exact ties); 3/8 = 0.375 -> 0.38."""
    assert_equal(_rt_decimal_div_i128(I128(100), 2, I128(300), 2, 6), I128(333333))
    assert_equal(_rt_decimal_div_i128(I128(200), 2, I128(300), 2, 6), I128(666667))
    assert_equal(_rt_decimal_div_i128(I128(1), 0, I128(8), 0, 2), I128(13))
    assert_equal(_rt_decimal_div_i128(I128(-1), 0, I128(8), 0, 2), I128(-13))
    assert_equal(_rt_decimal_div_i128(I128(1), 0, I128(-8), 0, 2), I128(-13))
    assert_equal(_rt_decimal_div_i128(I128(3), 0, I128(8), 0, 2), I128(38))


def test_div_negative_non_ties() raises:
    """-1/3 = -0.33 (not -0.34) and -2/3 = -0.67 at scale 2, every sign mix."""
    assert_equal(_rt_decimal_div_i128(I128(-1), 0, I128(3), 0, 2), I128(-33))
    assert_equal(_rt_decimal_div_i128(I128(-2), 0, I128(3), 0, 2), I128(-67))
    assert_equal(_rt_decimal_div_i128(I128(1), 0, I128(-3), 0, 2), I128(-33))
    assert_equal(_rt_decimal_div_i128(I128(-1), 0, I128(-3), 0, 2), I128(33))
    assert_equal(_rt_decimal_div_i128(I128(2), 0, I128(-3), 0, 2), I128(-67))


def test_div_scales() raises:
    """12.5 (scale 1) / 0.25 (scale 2) = 50 at scale 5: mul_pow = 5 - 1 + 2."""
    var ps = _rt_decimal_div_result_ps(3, 1, 3, 2)
    assert_equal(ps[1], 5)
    assert_equal(_rt_decimal_div_i128(I128(125), 1, I128(25), 2, ps[1]), I128(5000000))
    assert_equal(_rt_decimal_div_i128(I128(0), 0, I128(7), 0, 4), I128(0))


def test_div_by_zero_raises() raises:
    assert_equal(_message_of_div(I128(1), 0, I128(0), 0, 4), "Decimal128 division by zero")
    assert_equal(_message_of_div(I128(0), 2, I128(0), 2, 6), "Decimal128 division by zero")


def test_div_out_scale_below_the_rule_raises() raises:
    """out_scale below s1 - s2 is outside the contract out_scale = min(s1+4, 38)."""
    var msg = _message_of_div(I128(1), 5, I128(1), 0, 0)
    assert_true(msg.startswith("Decimal128 div"), msg)
    # mul_pow = 0 exactly is allowed: 7 (scale 2) / 2 (scale 0) at scale 2 = 0.035 -> 0.04.
    assert_equal(_rt_decimal_div_i128(I128(7), 2, I128(2), 0, 2), I128(4))


def test_div_result_overflow_raises() raises:
    """10^34 / 1 at scale 4 is 10^38 unscaled: past the range (the numerator
    10^38 fits the 256-bit intermediate, so this is the result check)."""
    var big = I128(10000000000000000000000000000000000)
    var msg = _message_of_div(big, 0, I128(1), 0, 4)
    assert_true(msg.startswith("Decimal128 overflow in div"), msg)
    assert_equal(
        _rt_decimal_div_i128(big - I128(1), 0, I128(1), 0, 4),
        MAX38 - I128(9999),
    )
    var neg = _message_of_div(-big, 0, I128(1), 0, 4)
    assert_true(neg.startswith("Decimal128 overflow in div"), neg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
