# =============================================================================
# WRAPS AND WRONG REFUSALS (komira-ai/komira#964): every case here is a value
# the 128- or 256-bit intermediate used to wrap into a plausible wrong answer,
# or a valid input the old guards refused.
#
# Oracle: exact decimal arithmetic worked by hand. A Decimal128 holds at most
# 38 digits (10^38 - 1), a Decimal256 at most 76 (10^76 - 1); a result past
# that range raises, a result inside it is returned, rounded half away from
# zero at the target scale.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.decimal_arith import (
    I128,
    decimal_div_i128,
    overflows_dec128,
)
from komira_scalar_arithmetic.decimal256_arith import (
    I256,
    overflows_dec256_inline,
    decimal256_add_i256,
    decimal256_sub_i256,
    decimal256_mul_i256,
    decimal256_div_i256,
)
from komira_scalar_arithmetic.decimal_cast import (
    decimal_to_string,
    string_to_decimal_i128,
)
from komira_scalar_arithmetic.int_overflow import mul_overflows, checked_mul


# @no_inline wrappers: runtime arguments, so no call folds at compile time.

@no_inline
def _rt_div128(a: I128, s1: Int, b: I128, s2: Int, o: Int) raises -> I128:
    return decimal_div_i128(a, s1, b, s2, o)


@no_inline
def _rt_add256(a: I256, s1: Int, b: I256, s2: Int, o: Int) raises -> I256:
    return decimal256_add_i256(a, s1, b, s2, o)


@no_inline
def _rt_sub256(a: I256, s1: Int, b: I256, s2: Int, o: Int) raises -> I256:
    return decimal256_sub_i256(a, s1, b, s2, o)


@no_inline
def _rt_mul256(a: I256, b: I256) raises -> I256:
    return decimal256_mul_i256(a, b)


@no_inline
def _rt_div256(a: I256, s1: Int, b: I256, s2: Int, o: Int) raises -> I256:
    return decimal256_div_i256(a, s1, b, s2, o)


@no_inline
def _rt_parse(s: String, p: Int, sc: Int) raises -> I128:
    return string_to_decimal_i128(s, p, sc)


@no_inline
def _rt_mul_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Bool:
    # Consumed by a raise, as `checked_mul` consumes it (see test_int_overflow).
    try:
        if mul_overflows[dtype](a, b):
            raise Error("overflow")
    except:
        return True
    return False


def _div128_message(a: I128, s1: Int, b: I128, s2: Int, o: Int) -> String:
    try:
        _ = _rt_div128(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def _add256_message(a: I256, s1: Int, b: I256, s2: Int, o: Int) -> String:
    try:
        _ = _rt_add256(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def _sub256_message(a: I256, s1: Int, b: I256, s2: Int, o: Int) -> String:
    try:
        _ = _rt_sub256(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def _mul256_message(a: I256, b: I256) -> String:
    try:
        _ = _rt_mul256(a, b)
    except e:
        return String(e)
    return String("")


def _div256_message(a: I256, s1: Int, b: I256, s2: Int, o: Int) -> String:
    try:
        _ = _rt_div256(a, s1, b, s2, o)
    except e:
        return String(e)
    return String("")


def _parse_message(s: String, p: Int, sc: Int) -> String:
    try:
        _ = _rt_parse(s, p, sc)
    except e:
        return String(e)
    return String("")


def _zeros(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += "0"
    return out^


def _pow10_256(n: Int) -> I256:
    var r = I256(1)
    for _ in range(n):
        r = r * I256(10)
    return r


def _nines(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += "9"
    return out^


comptime MAX38 = I128(99999999999999999999999999999999999999)
comptime MAX76 = I256(9999999999999999999999999999999999999999999999999999999999999999999999999999)
comptime TEN75 = I256(1000000000000000000000000000000000000000000000000000000000000000000000000000)
comptime TEN72 = I256(1000000000000000000000000000000000000000000000000000000000000000000000000)
comptime MIN256 = Scalar[DType.int256].MIN


# --- 1. Decimal128 division: the 10^mul_pow numerator must not wrap ----------


def test_dec128_div_scaled_numerator_overflow_raises() raises:
    """DECIMAL(38,0) / DECIMAL(38,38) at scale 4: mul_pow = 42, so the
    numerator 99*10^36 * 10^42 is past 2^255. The quotient, about 9.9*10^41
    unscaled, is past 10^38 - 1: the call raises. It used to wrap negative."""
    var big = I128(99000000000000000000000000000000000000)
    var up = _div128_message(big, 0, MAX38, 38, 4)
    assert_true(up.startswith("Decimal128 overflow in div"), up)
    var down = _div128_message(-big, 0, MAX38, 38, 4)
    assert_true(down.startswith("Decimal128 overflow in div"), down)
    var min_num = _div128_message(I128.MIN, 0, I128(1), 38, 4)
    assert_true(min_num.startswith("Decimal128 overflow in div"), min_num)
    # The same mul_pow on a small numerator fits: 1 / 0.99..9 (38 nines) at
    # scale 4 is 1.0000.
    assert_equal(_rt_div128(I128(1), 0, MAX38, 38, 4), I128(10000))
    assert_equal(_rt_div128(I128(-1), 0, MAX38, 38, 4), I128(-10000))


# --- 2. Decimal256 add / sub: the rescaled operand must not wrap ------------


def test_dec256_add_sub_rescale_overflow_raises() raises:
    """1.2*10^74 rescaled to scale 3 is 1.2*10^77, past 2^255; it used to wrap
    to about 4.2*10^75 and pass the range check."""
    var a = I256(12) * _pow10_256(73)
    var add = _add256_message(a, 0, I256(0), 3, 3)
    assert_true(add.startswith("Decimal256 overflow in add"), add)
    var add_neg = _add256_message(-a, 0, I256(0), 3, 3)
    assert_true(add_neg.startswith("Decimal256 overflow in add"), add_neg)
    var sub = _sub256_message(a, 0, I256(0), 3, 3)
    assert_true(sub.startswith("Decimal256 overflow in sub"), sub)
    var sub_b = _sub256_message(I256(0), 3, a, 0, 3)
    assert_true(sub_b.startswith("Decimal256 overflow in sub"), sub_b)
    var add_b = _add256_message(I256(0), 3, a, 0, 3)
    assert_true(add_b.startswith("Decimal256 overflow in add"), add_b)


def test_dec256_add_sub_valid_edges_still_answer() raises:
    """A rescaled operand one past the range, pulled back by the other one:
    10^72 at scale 4 is 10^76, minus 0.0001 is 10^76 - 1, the maximum."""
    assert_equal(_rt_add256(TEN72, 0, I256(-1), 4, 4), MAX76)
    assert_equal(_rt_add256(I256(-1), 4, TEN72, 0, 4), MAX76)
    assert_equal(_rt_sub256(TEN72, 0, I256(1), 4, 4), MAX76)
    assert_equal(_rt_sub256(I256(1), 4, TEN72, 0, 4), -MAX76)
    assert_equal(_rt_sub256(-TEN72, 0, I256(-1), 4, 4), -MAX76)
    # One more unit is past it.
    var over = _add256_message(TEN72, 0, I256(0), 4, 4)
    assert_true(over.startswith("Decimal256 overflow in add"), over)
    # Both operands rescaled to an out_scale above both: 10^75 - (10^75 - 1)
    # at scale 2 is 1.00, though each rescaled operand is past 2^255.
    assert_equal(_rt_add256(TEN75, 0, -(TEN75 - I256(1)), 0, 2), I256(100))
    assert_equal(_rt_sub256(TEN75, 0, TEN75 - I256(1), 0, 2), I256(100))
    # Mixed scales below the range: 12.5 + 0.25 = 12.75; 12.5 - 0.25 = 12.25.
    assert_equal(_rt_add256(I256(125), 1, I256(25), 2, 2), I256(1275))
    assert_equal(_rt_sub256(I256(125), 1, I256(25), 2, 2), I256(1225))
    assert_equal(_rt_sub256(I256(-125), 1, I256(-25), 2, 3), I256(-12250))


# --- 3. The parser's mantissa past 38 digits -------------------------------


def test_parse_long_mantissa_does_not_wrap() raises:
    """2^128 + 5 used to parse as 5. It has 39 digits: past DECIMAL(38,0)."""
    var msg = _parse_message("340282366920938463463374607431768211461", 38, 0)
    assert_true(msg.startswith("Decimal128 parse:"), msg)
    assert_true("overflows" in msg, msg)
    var neg = _parse_message("-340282366920938463463374607431768211461", 38, 0)
    assert_true("overflows" in neg, neg)
    # Valid values spelled with more than 38 significant digits.
    assert_equal(_rt_parse("1." + _zeros(50) + "1", 10, 2), I128(100))
    assert_equal(_rt_parse("-1." + _zeros(100) + "1", 10, 2), I128(-100))
    assert_equal(_rt_parse("1" + _zeros(79) + "e-78", 10, 2), I128(1000))
    assert_equal(_rt_parse(_zeros(100) + "123", 10, 0), I128(123))
    assert_equal(_rt_parse("2." + _zeros(60) + "5e1", 10, 0), I128(20))
    # Rounding is decided by the first dropped digit, however long the tail.
    assert_equal(_rt_parse("0.004" + _nines(90), 10, 2), I128(0))
    assert_equal(_rt_parse("0.005" + _zeros(90) + "1", 10, 2), I128(1))
    assert_equal(_rt_parse("-2.5" + _zeros(80) + "1", 10, 0), I128(-3))
    assert_equal(_rt_parse("2.4" + _nines(80), 10, 0), I128(2))
    # 38 nines followed by a long fraction still fits and rounds up past it.
    var over = _parse_message(_nines(38) + "." + _nines(60), 38, 0)
    assert_true("overflows" in over, over)
    assert_equal(_rt_parse(_nines(38) + ".4" + _nines(60), 38, 0), MAX38)


# --- 4. mul_overflows at 128 and 256 bits ----------------------------------


def test_mul_overflows_wide_types() raises:
    """128-bit operands need a 256-bit product; 256-bit ones have no wider
    type, so the test is exact by division."""
    comptime I = Scalar[DType.int128]
    comptime U = Scalar[DType.uint128]
    assert_true(_rt_mul_overflows[DType.int128](I(1) << 100, I(1) << 100))
    assert_true(_rt_mul_overflows[DType.uint128](U(1) << 100, U(1) << 100))
    assert_false(_rt_mul_overflows[DType.int128](I(1) << 63, I(1) << 63))
    assert_false(_rt_mul_overflows[DType.int128](-(I(1) << 63), I(1) << 64))
    assert_true(_rt_mul_overflows[DType.int128](I(1) << 63, I(1) << 64))
    assert_true(_rt_mul_overflows[DType.int128](I.MIN, I(-1)))
    # Below MIN, not above MAX: -2^63 * (2^64 + 1) = -2^127 - 2^63.
    assert_true(_rt_mul_overflows[DType.int128](-(I(1) << 63), (I(1) << 64) + I(1)))
    assert_false(_rt_mul_overflows[DType.uint128](U(1) << 64, (U(1) << 64) - U(1)))
    assert_true(_rt_mul_overflows[DType.uint128](U(1) << 64, U(1) << 64))
    comptime J = Scalar[DType.int256]
    comptime V = Scalar[DType.uint256]
    assert_true(_rt_mul_overflows[DType.int256](J(1) << 200, J(1) << 200))
    assert_false(_rt_mul_overflows[DType.int256](J(1) << 127, J(1) << 127))
    assert_false(_rt_mul_overflows[DType.int256](-(J(1) << 127), J(1) << 128))
    assert_true(_rt_mul_overflows[DType.int256](J(1) << 127, J(1) << 128))
    assert_true(_rt_mul_overflows[DType.int256](J.MIN, J(-1)))
    assert_true(_rt_mul_overflows[DType.int256](J(-1), J.MIN))
    assert_false(_rt_mul_overflows[DType.int256](J.MAX, J(-1)))
    assert_false(_rt_mul_overflows[DType.int256](J(0), J.MIN))
    assert_true(_rt_mul_overflows[DType.uint256](V(1) << 128, V(1) << 128))
    assert_false(_rt_mul_overflows[DType.uint256](V(1) << 128, (V(1) << 128) - V(1)))
    var msg = String("")
    try:
        _ = checked_mul[DType.int128](I(1) << 100, I(1) << 100)
    except e:
        msg = String(e)
    assert_true(msg.startswith("Out of Range Error: Overflow in multiplication"), msg)


# --- 5. Valid inputs the guards refused ------------------------------------


def test_dec256_div_quotients_that_fit_are_answered() raises:
    """MAX / MAX at scale 4 is 1.0000: the scaled numerator is past 2^255 but
    the quotient is 1. 10^70 / 10^37 (10^75 at scale 38) is 10^33."""
    assert_equal(_rt_div256(MAX76, 0, MAX76, 0, 4), I256(10000))
    assert_equal(_rt_div256(-MAX76, 0, MAX76, 0, 4), I256(-10000))
    assert_equal(_rt_div256(MAX76, 0, MAX76 - I256(1), 0, 4), I256(10000))
    var ten70 = TEN72 / I256(100)
    var ten37 = I256(10000000000000000000000000000000000000)
    assert_equal(_rt_div256(ten70, 0, TEN75, 38, 4), ten37)
    # 1/3 and 2/3 of numbers near the top: every fractional digit by division.
    var three75 = TEN75 * I256(3)
    assert_equal(_rt_div256(TEN75, 0, three75, 0, 4), I256(3333))
    assert_equal(_rt_div256(TEN75 * I256(2), 0, three75, 0, 4), I256(6667))
    assert_equal(_rt_div256(-(TEN75 * I256(2)), 0, three75, 0, 4), I256(-6667))
    assert_equal(_rt_div256(TEN75 * I256(2), 0, -three75, 0, 4), I256(-6667))
    # Half of the last digit rounds away from zero: 1/16 = 0.0625 -> 0.063.
    assert_equal(_rt_div256(I256(1), 0, I256(16), 0, 3), I256(63))
    assert_equal(_rt_div256(I256(-1), 0, I256(16), 0, 3), I256(-63))
    assert_equal(_rt_div256(I256(1), 0, I256(-15), 0, 3), I256(-67))
    assert_equal(_rt_div256(I256(1), 0, I256(-17), 0, 3), I256(-59))
    # A quotient whose rounding carries it past the range.
    # (2*MAX + 1) / 2 = MAX + 0.5 -> MAX + 1; (2*MAX - 1) / 2 = MAX - 0.5 -> MAX.
    var carry = _div256_message(MAX76 * I256(2) + I256(1), 0, I256(2), 0, 0)
    assert_true(carry.startswith("Decimal256 overflow in div"), carry)
    assert_equal(_rt_div256(MAX76 * I256(2) - I256(1), 0, I256(2), 0, 0), MAX76)


def test_parse_tiny_and_zero_exponents_are_answered() raises:
    """1e-100 at scale 2 is 0.00; 0e100 is 0. Both used to raise a pow10
    error."""
    assert_equal(_rt_parse("1e-100", 10, 2), I128(0))
    assert_equal(_rt_parse("-1e-100", 10, 2), I128(0))
    assert_equal(_rt_parse("0e100", 10, 2), I128(0))
    assert_equal(_rt_parse("0.000e-500", 10, 2), I128(0))
    # 0.5 * 10^0 with the point 76 places in: the largest drop that still
    # rounds up; 77 places in, it is below one half.
    assert_equal(_rt_parse("5" + _zeros(75) + "e-76", 10, 0), I128(1))
    assert_equal(_rt_parse("9" + _zeros(75) + "e-77", 10, 0), I128(0))
    assert_equal(_rt_parse("9e-77", 10, 0), I128(0))
    # A large positive exponent is an overflow, named as one.
    var big = _parse_message("1e100", 10, 2)
    assert_true("overflows" in big, big)
    var just = _parse_message("1e38", 38, 0)
    assert_true("overflows" in just, just)
    assert_equal(_rt_parse("1e37", 38, 0), _pow10_256(37).cast[DType.int128]())
    var huge_exp = _parse_message("1e99999999999999999999999", 38, 0)
    assert_true("overflows" in huge_exp, huge_exp)
    assert_equal(_rt_parse("1e-99999999999999999999999", 38, 0), I128(0))


# --- 6. I128.MIN to string --------------------------------------------------


def test_decimal_to_string_i128_min() raises:
    assert_equal(decimal_to_string(I128.MIN, 0), "-170141183460469231731687303715884105728")
    assert_equal(decimal_to_string(I128.MIN, 2), "-1701411834604692317316873037158841057.28")
    assert_equal(decimal_to_string(I128.MAX, 0), "170141183460469231731687303715884105727")


# --- 9. -2^255 must not slip past the Decimal256 guards ----------------------


def test_dec256_min_value_is_refused() raises:
    """|-2^255| is not an int256, so an abs() of it wraps back negative and a
    `|a| > bound` guard reads it as small."""
    assert_true(overflows_dec256_inline(MIN256))
    assert_true(overflows_dec128(MIN256))
    var m1 = _mul256_message(MIN256, I256(1))
    assert_true(m1.startswith("Decimal256 overflow in mul"), m1)
    var m2 = _mul256_message(I256(1), MIN256)
    assert_true(m2.startswith("Decimal256 overflow in mul"), m2)
    var m3 = _mul256_message(MIN256, I256(-1))
    assert_true(m3.startswith("Decimal256 overflow in mul"), m3)
    var d1 = _div256_message(MIN256, 0, I256(1), 0, 0)
    assert_true(d1.startswith("Decimal256 overflow in div"), d1)
    var d2 = _div256_message(MIN256, 0, I256(2), 0, 0)
    assert_true(d2.startswith("Decimal256 overflow in div"), d2)
    var a1 = _add256_message(MIN256, 0, I256(0), 0, 0)
    assert_true(a1.startswith("Decimal256 overflow in add"), a1)
    var s1 = _sub256_message(I256(0), 0, MIN256, 0, 0)
    assert_true(s1.startswith("Decimal256 overflow in sub"), s1)
    # The step-1 sum itself wraps, at equal and at mixed scales.
    var w1 = _add256_message(MIN256, 0, I256(-1), 0, 0)
    assert_true(w1.startswith("Decimal256 overflow in add"), w1)
    var w2 = _sub256_message(MIN256, 0, I256(1), 0, 0)
    assert_true(w2.startswith("Decimal256 overflow in sub"), w2)
    var w3 = _add256_message(MIN256, 0, I256(-10), 1, 1)
    assert_true(w3.startswith("Decimal256 overflow in add"), w3)
    var w4 = _sub256_message(MIN256, 0, I256(10), 1, 1)
    assert_true(w4.startswith("Decimal256 overflow in sub"), w4)
    # Rescaled past the range only by an out_scale above both scales.
    var u1 = _add256_message(TEN75, 0, I256(0), 0, 2)
    assert_true(u1.startswith("Decimal256 overflow in add"), u1)
    var u2 = _sub256_message(I256(0), 0, TEN75, 0, 2)
    assert_true(u2.startswith("Decimal256 overflow in sub"), u2)
    # A denominator of -2^255 leaves a quotient that is just small.
    assert_equal(_rt_div256(I256(1), 0, MIN256, 0, 4), I256(0))
    assert_equal(_rt_div256(MAX76, 0, MIN256, 0, 0), I256(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
