# =============================================================================
# DECIMAL256 BOUNDS: the 76-digit edges `test_decimal256_arith.mojo` leaves
# out. Powers of ten at their limits, the overflow predicate on both sides,
# the exact multiplication guard at 10^76 - 1, the division guards, and the
# result-type rules at their clamps.
#
# Oracle: a Decimal256 holds at most 76 digits, so its largest magnitude is
# 10^76 - 1 = (10^38 - 1)(10^38 + 1); every expected value is worked by hand.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.decimal256_arith import (
    I256,
    pow10_i256_d,
    max_dec256_i256,
    i256_abs,
    i256_sign,
    overflows_dec256_inline,
    rescale_i256_half_up,
    decimal256_add_result_ps,
    decimal256_mul_result_ps,
    decimal256_div_result_ps,
    decimal256_add_i256,
    decimal256_sub_i256,
    decimal256_mul_i256,
    decimal256_div_i256,
)


# Each product call goes through a @no_inline wrapper: its arguments are then
# runtime values, so the compiler cannot fold an @always_inline body at a
# constant call site and the coverage run sees every arm the test takes.

@no_inline
def _rt_pow10_i256_d(n: Int) raises -> I256:
    return pow10_i256_d(n)


@no_inline
def _rt_max_dec256_i256() raises -> I256:
    return max_dec256_i256()


@no_inline
def _rt_i256_abs(v: I256) raises -> I256:
    return i256_abs(v)


@no_inline
def _rt_i256_sign(v: I256) raises -> I256:
    return i256_sign(v)


@no_inline
def _rt_overflows_dec256_inline(v: I256) raises -> Bool:
    return overflows_dec256_inline(v)


@no_inline
def _rt_rescale_i256_half_up(v: I256, f: Int, t: Int) raises -> I256:
    return rescale_i256_half_up(v, f, t)


@no_inline
def _rt_decimal256_add_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    return decimal256_add_result_ps(p1, s1, p2, s2)


@no_inline
def _rt_decimal256_mul_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    return decimal256_mul_result_ps(p1, s1, p2, s2)


@no_inline
def _rt_decimal256_div_result_ps(p1: Int, s1: Int, p2: Int, s2: Int) raises -> Tuple[Int, Int]:
    return decimal256_div_result_ps(p1, s1, p2, s2)


@no_inline
def _rt_decimal256_add_i256(a: I256, s1: Int, b: I256, s2: Int, o: Int) raises -> I256:
    return decimal256_add_i256(a, s1, b, s2, o)


@no_inline
def _rt_decimal256_sub_i256(a: I256, s1: Int, b: I256, s2: Int, o: Int) raises -> I256:
    return decimal256_sub_i256(a, s1, b, s2, o)


@no_inline
def _rt_decimal256_mul_i256(a: I256, b: I256) raises -> I256:
    return decimal256_mul_i256(a, b)


@no_inline
def _rt_decimal256_div_i256(a: I256, s1: Int, b: I256, s2: Int, o: Int) raises -> I256:
    return decimal256_div_i256(a, s1, b, s2, o)


comptime TEN76 = I256(10000000000000000000000000000000000000000000000000000000000000000000000000000)
comptime MAX76 = I256(9999999999999999999999999999999999999999999999999999999999999999999999999999)
comptime TEN38_M1 = I256(99999999999999999999999999999999999999)
comptime TEN38 = I256(100000000000000000000000000000000000000)
comptime TEN38_P1 = I256(100000000000000000000000000000000000001)


def _add_message(a: I256, s1: Int, b: I256, s2: Int, o: Int) -> String:
    try:
        _ = _rt_decimal256_add_i256(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def _sub_message(a: I256, s1: Int, b: I256, s2: Int, o: Int) -> String:
    try:
        _ = _rt_decimal256_sub_i256(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def _mul_message(a: I256, b: I256) -> String:
    try:
        _ = _rt_decimal256_mul_i256(a, b)
    except e:
        return String(e)
    return String("")


def _div_message(a: I256, s1: Int, b: I256, s2: Int, o: Int) -> String:
    try:
        _ = _rt_decimal256_div_i256(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def test_pow10_and_max() raises:
    assert_equal(_rt_pow10_i256_d(0), I256(1))
    assert_equal(_rt_pow10_i256_d(38), TEN38)
    assert_equal(_rt_pow10_i256_d(76), TEN76)
    assert_equal(_rt_max_dec256_i256(), MAX76)
    var low = String("")
    try:
        _ = _rt_pow10_i256_d(-1)
    except e:
        low = String(e)
    assert_equal(low, "pow10_i256_d: exponent -1 out of range [0, 76]")
    var high = String("")
    try:
        _ = _rt_pow10_i256_d(77)
    except e:
        high = String(e)
    assert_equal(high, "pow10_i256_d: exponent 77 out of range [0, 76]")


def test_overflow_predicate_boundary() raises:
    assert_false(_rt_overflows_dec256_inline(I256(0)))
    assert_false(_rt_overflows_dec256_inline(MAX76))
    assert_false(_rt_overflows_dec256_inline(-MAX76))
    assert_true(_rt_overflows_dec256_inline(TEN76))
    assert_true(_rt_overflows_dec256_inline(-TEN76))


def test_abs_sign_and_identity_rescale() raises:
    assert_equal(_rt_i256_abs(I256(-9)), I256(9))
    assert_equal(_rt_i256_abs(I256(9)), I256(9))
    assert_equal(_rt_i256_sign(I256(3)), I256(1))
    assert_equal(_rt_i256_sign(I256(-3)), I256(-1))
    assert_equal(_rt_i256_sign(I256(0)), I256(0))
    assert_equal(_rt_rescale_i256_half_up(I256(-77), 4, 4), I256(-77))
    assert_equal(_rt_rescale_i256_half_up(I256(123), 2, 4), I256(12300))
    assert_equal(_rt_rescale_i256_half_up(I256(-149), 2, 0), I256(-1))
    assert_equal(_rt_rescale_i256_half_up(I256(149), 2, 0), I256(1))
    assert_equal(_rt_rescale_i256_half_up(I256(150), 2, 0), I256(2))


def test_result_types_at_their_edges() raises:
    """add: max(p1-s1, p2-s2) + max(s1, s2) + 1, clamped at 76. mul: scale
    s1 + s2 up to 76 (precision asserted only where it clamps). div: scale
    min(s1 + 4, 76), precision min(s - s1 + s2 + p1, 76)."""
    var add = _rt_decimal256_add_result_ps(5, 2, 4, 3)
    assert_equal(add[0], 7)
    assert_equal(add[1], 3)
    var add_edge = _rt_decimal256_add_result_ps(75, 0, 1, 0)
    assert_equal(add_edge[0], 76)
    var mul = _rt_decimal256_mul_result_ps(76, 38, 76, 38)
    assert_equal(mul[0], 76)
    assert_equal(mul[1], 76)
    var msg = String("")
    try:
        _ = _rt_decimal256_mul_result_ps(76, 39, 76, 38)
    except e:
        msg = String(e)
    assert_true(msg.startswith("Decimal256 mul: result scale 77 exceeds 76"), msg)
    var div = _rt_decimal256_div_result_ps(10, 2, 5, 3)
    assert_equal(div[1], 6)
    assert_equal(div[0], 17)
    var div_edge = _rt_decimal256_div_result_ps(76, 74, 10, 0)
    assert_equal(div_edge[1], 76)
    assert_equal(div_edge[0], 76)
    var div_exact = _rt_decimal256_div_result_ps(72, 72, 1, 0)
    assert_equal(div_exact[1], 76)


def test_add_sub_boundaries() raises:
    """(10^76 - 2) + 1 is the maximum; one more overflows, on either side."""
    assert_equal(_rt_decimal256_add_i256(MAX76 - I256(1), 0, I256(1), 0, 0), MAX76)
    assert_equal(_rt_decimal256_add_i256(-MAX76 + I256(1), 0, I256(-1), 0, 0), -MAX76)
    var neg = _add_message(-MAX76, 0, I256(-1), 0, 0)
    assert_true(neg.startswith("Decimal256 overflow in add"), neg)
    assert_equal(_rt_decimal256_sub_i256(-MAX76 + I256(1), 0, I256(1), 0, 0), -MAX76)
    assert_equal(_rt_decimal256_sub_i256(MAX76 - I256(1), 0, I256(-1), 0, 0), MAX76)
    var down = _sub_message(-MAX76, 0, I256(1), 0, 0)
    assert_true(down.startswith("Decimal256 overflow in sub"), down)
    var up = _sub_message(MAX76, 0, I256(-1), 0, 0)
    assert_true(up.startswith("Decimal256 overflow in sub"), up)


def test_mul_guard_is_exact() raises:
    """(10^38 - 1)(10^38 + 1) = 10^76 - 1 fits; 10^38 * 10^38 = 10^76 does not.
    The guard |a| > MAX / |b| is exact for integers, so the two neighbours fall
    on opposite sides, with every sign."""
    assert_equal(_rt_decimal256_mul_i256(TEN38_M1, TEN38_P1), MAX76)
    assert_equal(_rt_decimal256_mul_i256(-TEN38_M1, TEN38_P1), -MAX76)
    assert_equal(_rt_decimal256_mul_i256(TEN38_P1, -TEN38_M1), -MAX76)
    assert_equal(_rt_decimal256_mul_i256(-MAX76, I256(-1)), MAX76)
    var up = _mul_message(TEN38, TEN38)
    assert_true(up.startswith("Decimal256 overflow in mul"), up)
    var down = _mul_message(-TEN38, TEN38)
    assert_true(down.startswith("Decimal256 overflow in mul"), down)
    # A zero operand on either side short-circuits, whatever the other holds.
    assert_equal(_rt_decimal256_mul_i256(I256(0), I256(1) << 200), I256(0))
    assert_equal(_rt_decimal256_mul_i256(I256(1) << 200, I256(0)), I256(0))


def test_div_rounding_and_zero_numerator() raises:
    """1/8 = 0.125 -> 0.13 and -1/8 -> -0.13 at scale 2; 1/3 -> 0.33; 0/7 = 0."""
    assert_equal(_rt_decimal256_div_i256(I256(1), 0, I256(8), 0, 2), I256(13))
    assert_equal(_rt_decimal256_div_i256(I256(-1), 0, I256(8), 0, 2), I256(-13))
    assert_equal(_rt_decimal256_div_i256(I256(1), 0, I256(-8), 0, 2), I256(-13))
    assert_equal(_rt_decimal256_div_i256(I256(1), 0, I256(3), 0, 2), I256(33))
    assert_equal(_rt_decimal256_div_i256(I256(0), 0, I256(7), 0, 4), I256(0))
    # 12.5 (scale 1) / 0.25 (scale 2) = 50 at scale 5.
    assert_equal(_rt_decimal256_div_i256(I256(125), 1, I256(25), 2, 5), I256(5000000))


def test_div_guards() raises:
    """An out_scale below s1 - s2 is outside the contract. 10^76 - 1 over 1 at
    scale 4 is 10^80 - 10^4 unscaled: past the range under any reading, so
    the refusal is right whichever check makes it."""
    var neg = _div_message(I256(1), 5, I256(1), 0, 0)
    assert_true(neg.startswith("Decimal256 div"), neg)
    var big = _div_message(MAX76, 0, I256(1), 0, 4)
    assert_true(big.startswith("Decimal256 overflow in div"), big)
    var big_neg = _div_message(-MAX76, 0, I256(-1), 0, 4)
    assert_true(big_neg.startswith("Decimal256 overflow in div"), big_neg)
    # The largest numerator the scaled form can hold: (10^72 - 1) * 10^4.
    var edge = (TEN76 / I256(10000)) - I256(1)
    assert_equal(_rt_decimal256_div_i256(edge, 0, I256(1), 0, 4), edge * I256(10000))
    var zero = _div_message(I256(5), 0, I256(0), 0, 4)
    assert_equal(zero, "Decimal256 division by zero")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
