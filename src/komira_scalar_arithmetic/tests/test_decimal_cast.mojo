# =============================================================================
# DECIMAL128 CASTS: integer -> decimal, float -> decimal, decimal -> float,
# decimal -> integer, decimal -> decimal and decimal -> string.
#
# Oracles, worked by hand:
# - integer -> DECIMAL(p, s) is the integer times 10^s, an error when that
#   needs more than p digits;
# - float and decimal -> narrower scale round half away from zero (DuckDB and
#   PostgreSQL; `decimal_cast.mojo` header). Float inputs are binary
#   fractions (2.5, 0.125, 99.75) so the double holds the tie exactly and no
#   double-rounding question arises;
# - a float that has no DECIMAL value (NaN, an infinity, out of range, too
#   many digits) is asserted only to give no value: the code answers NULL
#   (safe cast), and a raising cast would pass the same assertion;
# - decimal -> string writes exactly `scale` digits after the point.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import (
    int_to_decimal_i128,
    float_to_decimal_i128,
    decimal_to_float64,
    decimal_to_int64,
    decimal_rescale_i128,
    decimal_to_string,
)


# Each product call goes through a @no_inline wrapper: its arguments are then
# runtime values, so the compiler cannot fold an @always_inline body at a
# constant call site and the coverage run sees every arm the test takes.

@no_inline
def _rt_int_to_decimal_i128(v: Int64, p: Int, s: Int) raises -> I128:
    return int_to_decimal_i128(v, p, s)


@no_inline
def _rt_float_to_decimal_i128(f: Float64, p: Int, s: Int) raises -> Optional[I128]:
    return float_to_decimal_i128(f, p, s)


@no_inline
def _rt_decimal_to_float64(v: I128, s: Int) raises -> Float64:
    return decimal_to_float64(v, s)


@no_inline
def _rt_decimal_to_int64(v: I128, s: Int) raises -> Int64:
    return decimal_to_int64(v, s)


@no_inline
def _rt_decimal_rescale_i128(v: I128, fs: Int, tp: Int, ts: Int) raises -> I128:
    return decimal_rescale_i128(v, fs, tp, ts)


comptime MAX38 = I128(99999999999999999999999999999999999999)


def _int_cast_message(v: Int64, p: Int, s: Int) -> String:
    try:
        _ = _rt_int_to_decimal_i128(v, p, s)
    except e:
        return String(e)
    return String("")


def _to_int64_message(v: I128, s: Int) -> String:
    try:
        _ = _rt_decimal_to_int64(v, s)
    except e:
        return String(e)
    return String("")


def _rescale_message(v: I128, fs: Int, tp: Int, ts: Int) -> String:
    try:
        _ = _rt_decimal_rescale_i128(v, fs, tp, ts)
    except e:
        return String(e)
    return String("")


def _float_gives_no_value(f: Float64, p: Int, s: Int) -> Bool:
    """True when the cast yields no DECIMAL: NULL, or an error."""
    try:
        var r = _rt_float_to_decimal_i128(f, p, s)
        return not r
    except:
        return True


def _float_value(f: Float64, p: Int, s: Int) raises -> I128:
    var r = _rt_float_to_decimal_i128(f, p, s)
    assert_true(Bool(r), "expected a value")
    return r.value()


# --- integer -> decimal ------------------------------------------------------------


def test_int_to_decimal_values() raises:
    """123 -> DECIMAL(5,2) is 123.00; -123 likewise; 0 fits DECIMAL(1,0)."""
    assert_equal(_rt_int_to_decimal_i128(Int64(123), 5, 2), I128(12300))
    assert_equal(_rt_int_to_decimal_i128(Int64(-123), 5, 2), I128(-12300))
    assert_equal(_rt_int_to_decimal_i128(Int64(0), 1, 0), I128(0))
    assert_equal(_rt_int_to_decimal_i128(Int64(0), 3, 3), I128(0))
    assert_equal(
        _rt_int_to_decimal_i128(Int64.MIN, 38, 19),
        I128(-92233720368547758080000000000000000000),
    )


def test_int_to_decimal_precision_boundary() raises:
    """99 fits DECIMAL(2,0), 100 does not; -99 / -100 the same (the sign is no digit)."""
    assert_equal(_rt_int_to_decimal_i128(Int64(99), 2, 0), I128(99))
    assert_equal(_rt_int_to_decimal_i128(Int64(-99), 2, 0), I128(-99))
    assert_equal(
        _int_cast_message(Int64(100), 2, 0),
        "Decimal128 cast: integer 100 does not fit DECIMAL(2,0)",
    )
    assert_equal(
        _int_cast_message(Int64(-100), 2, 0),
        "Decimal128 cast: integer -100 does not fit DECIMAL(2,0)",
    )
    # 123 -> DECIMAL(4,2) needs 12300: five digits.
    assert_equal(
        _int_cast_message(Int64(123), 4, 2),
        "Decimal128 cast: integer 123 does not fit DECIMAL(4,2)",
    )


def test_int_to_decimal_invalid_precision_raises() raises:
    """A Decimal128 precision is 1 to 38: 0 and 39 hold nothing."""
    assert_true(_int_cast_message(Int64(1), 0, 0).startswith("Decimal128 cast"))
    assert_true(_int_cast_message(Int64(1), 39, 0).startswith("Decimal128 cast"))


def test_int_to_decimal_range_overflow_raises() raises:
    """INT64 MAX times 10^20 is about 9.2e38: past 10^38 - 1."""
    assert_equal(
        _int_cast_message(Int64.MAX, 38, 20),
        "Decimal128 cast: integer 9223372036854775807 overflows DECIMAL(38,20)",
    )


# --- float -> decimal ----------------------------------------------------------------


def test_float_to_decimal_half_away_from_zero() raises:
    """2.5 -> 3, -2.5 -> -3; 0.125 -> 0.13, -0.125 -> -0.13; 2.4 -> 2, -2.4 -> -2."""
    assert_equal(_float_value(2.5, 5, 0), I128(3))
    assert_equal(_float_value(-2.5, 5, 0), I128(-3))
    assert_equal(_float_value(0.125, 5, 2), I128(13))
    assert_equal(_float_value(-0.125, 5, 2), I128(-13))
    assert_equal(_float_value(2.4, 1, 0), I128(2))
    assert_equal(_float_value(-2.4, 1, 0), I128(-2))
    assert_equal(_float_value(99.75, 4, 2), I128(9975))
    assert_equal(_float_value(0.0, 1, 0), I128(0))
    assert_equal(_float_value(-0.0, 1, 0), I128(0))
    # 10^20 is exact in a double.
    assert_equal(_float_value(1.0e20, 38, 0), I128(100000000000000000000))


def test_float_to_decimal_precision_boundary() raises:
    """999.4 -> 999 fits DECIMAL(3,0); 999.5 rounds to 1000, which does not."""
    assert_equal(_float_value(999.4, 3, 0), I128(999))
    assert_true(_float_gives_no_value(999.5, 3, 0))
    assert_true(_float_gives_no_value(-999.5, 3, 0))
    assert_true(_float_gives_no_value(123.5, 4, 2))


def test_float_without_a_decimal_value() raises:
    """NaN, both infinities, and magnitudes past 10^38 - 1 give no value."""
    var zero = Float64(0.0)
    var nan = zero / zero
    var inf = Float64(1.0) / zero
    assert_true(_float_gives_no_value(nan, 38, 0))
    assert_true(_float_gives_no_value(inf, 38, 0))
    assert_true(_float_gives_no_value(-inf, 38, 0))
    # Past the 1.7e38 guard.
    assert_true(_float_gives_no_value(1.0e300, 38, 0))
    assert_true(_float_gives_no_value(-1.0e300, 38, 0))
    # Inside the guard but above 10^38 - 1.
    assert_true(_float_gives_no_value(1.5e38, 38, 0))
    assert_true(_float_gives_no_value(-1.5e38, 38, 0))
    # A small value whose scaling leaves the range: 2 * 10^37 at scale 2.
    assert_true(_float_gives_no_value(2.0e37, 38, 2))


# --- decimal -> float ------------------------------------------------------------------


def test_decimal_to_float64() raises:
    """Each quotient is the correctly rounded double of the decimal."""
    assert_equal(_rt_decimal_to_float64(I128(12345), 2), 123.45)
    assert_equal(_rt_decimal_to_float64(I128(-5), 3), -0.005)
    assert_equal(_rt_decimal_to_float64(I128(7), 0), 7.0)
    assert_equal(_rt_decimal_to_float64(I128(0), 4), 0.0)
    assert_equal(_rt_decimal_to_float64(I128(-25), 1), -2.5)


# --- decimal -> integer --------------------------------------------------------------


def test_decimal_to_int64_rounds_half_away_from_zero() raises:
    """3.5 -> 4, -2.5 -> -3, 3.99 -> 4, 7.49 -> 7, -3.99 -> -4, -3.01 -> -3."""
    assert_equal(_rt_decimal_to_int64(I128(35000), 4), Int64(4))
    assert_equal(_rt_decimal_to_int64(I128(-25000), 4), Int64(-3))
    assert_equal(_rt_decimal_to_int64(I128(399), 2), Int64(4))
    assert_equal(_rt_decimal_to_int64(I128(749), 2), Int64(7))
    assert_equal(_rt_decimal_to_int64(I128(-399), 2), Int64(-4))
    assert_equal(_rt_decimal_to_int64(I128(-301), 2), Int64(-3))
    assert_equal(_rt_decimal_to_int64(I128(42), 0), Int64(42))
    # 0.99..9 (38 nines) at scale 38 rounds to 1.
    assert_equal(_rt_decimal_to_int64(MAX38, 38), Int64(1))
    assert_equal(_rt_decimal_to_int64(-MAX38, 38), Int64(-1))


def test_decimal_to_int64_range() raises:
    """INT64's range is [-2^63, 2^63 - 1], checked on the rounded value."""
    assert_equal(_rt_decimal_to_int64(I128(9223372036854775807), 0), Int64.MAX)
    assert_equal(_rt_decimal_to_int64(I128(-9223372036854775808), 0), Int64.MIN)
    var msg = "Decimal128 cast to INTEGER: value out of Int64 range"
    assert_equal(_to_int64_message(I128(9223372036854775808), 0), msg)
    assert_equal(_to_int64_message(I128(-9223372036854775809), 0), msg)
    # 9223372036854775807.4 -> MAX; .5 rounds to 2^63, outside.
    assert_equal(_rt_decimal_to_int64(I128(92233720368547758074), 1), Int64.MAX)
    assert_equal(_to_int64_message(I128(92233720368547758075), 1), msg)
    # -9223372036854775808.4 -> MIN; .5 rounds to -2^63 - 1, outside.
    assert_equal(_rt_decimal_to_int64(I128(-92233720368547758084), 1), Int64.MIN)
    assert_equal(_to_int64_message(I128(-92233720368547758085), 1), msg)


# --- decimal -> decimal ----------------------------------------------------------------


def test_rescale_values() raises:
    """123.45 -> DECIMAL(10,4) is 123.4500; -> (10,1) is 123.5 (tie); 123.44 -> 123.4."""
    assert_equal(_rt_decimal_rescale_i128(I128(12345), 2, 10, 4), I128(1234500))
    assert_equal(_rt_decimal_rescale_i128(I128(12345), 2, 10, 1), I128(1235))
    assert_equal(_rt_decimal_rescale_i128(I128(-12345), 2, 10, 1), I128(-1235))
    assert_equal(_rt_decimal_rescale_i128(I128(12344), 2, 10, 1), I128(1234))
    assert_equal(_rt_decimal_rescale_i128(I128(42), 2, 5, 2), I128(42))


def test_rescale_precision_refusals() raises:
    """123.45 has five digits: not DECIMAL(4,2). 999.99 -> scale 1 rounds to
    1000.0, five digits: not DECIMAL(4,1). 10^37 -> scale 2 is 10^39: past the range."""
    var prec = _rescale_message(I128(12345), 2, 4, 2)
    assert_equal(
        prec,
        "Decimal128 rescale: value has more than 4 digits — does not fit DECIMAL(4,2)",
    )
    var rounded = _rescale_message(I128(99999), 2, 4, 1)
    assert_true(rounded.startswith("Decimal128 rescale: value has more than 4 digits"), rounded)
    assert_equal(_rt_decimal_rescale_i128(I128(99999), 2, 5, 1), I128(10000))
    var big = _rescale_message(I128(10000000000000000000000000000000000000), 0, 38, 2)
    assert_equal(big, "Decimal128 rescale: value overflows DECIMAL(38,2)")


# --- decimal -> string -----------------------------------------------------------------


def test_decimal_to_string() raises:
    assert_equal(decimal_to_string(I128(-126), 2), "-1.26")
    assert_equal(decimal_to_string(I128(5), 3), "0.005")
    assert_equal(decimal_to_string(I128(-5), 1), "-0.5")
    assert_equal(decimal_to_string(I128(0), 0), "0")
    assert_equal(decimal_to_string(I128(0), 2), "0.00")
    assert_equal(decimal_to_string(I128(12345), 0), "12345")
    assert_equal(decimal_to_string(I128(100), 2), "1.00")
    assert_equal(decimal_to_string(I128(1230), 1), "123.0")
    assert_equal(decimal_to_string(I128(-21260), 2), "-212.60")
    assert_equal(decimal_to_string(MAX38, 38), "0.99999999999999999999999999999999999999")
    assert_equal(decimal_to_string(-MAX38, 0), "-99999999999999999999999999999999999999")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
