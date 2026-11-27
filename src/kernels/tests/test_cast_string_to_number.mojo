# =============================================================================
# Tests of kernels.cast_string_to_number: text read as BIGINT, INTEGER,
# DOUBLE and REAL as DuckDB reads it
# =============================================================================
#
# Every expected value is DuckDB's answer to `SELECT TRY_CAST('<text>' AS
# BIGINT), TRY_CAST('<text>' AS INTEGER)` or `SELECT TRY_CAST('<text>' AS
# DOUBLE)::VARCHAR, TRY_CAST('<text>' AS FLOAT)::VARCHAR` for the text named,
# a NULL written as `_no_*`. The SQL end-to-end cases `cast_text_*`
# (src/tests/e2e/sql_e2e) run texts like these through komira and hold the
# answers to the pinned DuckDB's.
#
#   * the integer grammar: digits, sign, whitespace, the fraction's
#     first-digit rounding, the exponent applied DuckDB's way, underscores,
#     hexadecimal and binary, each type's range, and text that is no number;
#   * the float grammar: correct rounding for each width, past the range,
#     NaN and the infinities;
#   * the column kernels: NULL stays NULL, a bad cell raises DuckDB's
#     Conversion Error under CAST and is NULL under TRY_CAST;
#   * C's truncating division, which the exponent arithmetic needs, and the
#     defect raise when the exact float parser refuses text built here.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.string_array import StringArray

from kernels.cast_string_to_number import (
    _FloatText,
    _f32_of,
    _f64_of,
    _tdiv,
    _trem,
    cast_string_to_float32,
    cast_string_to_float64,
    cast_string_to_int32,
    cast_string_to_int64,
    f32_from_str,
    f64_from_str,
    i32_from_str,
    i64_from_str,
    parse_text_float32,
    parse_text_float64,
    parse_text_int32,
    parse_text_int64,
)


def _inf64() -> Float64:
    return Float64(1.0) / Float64(0.0)


def _inf32() -> Float32:
    return Float32(_inf64())


def _i64(text: String, want: Int64) raises:
    var got = parse_text_int64(text)
    assert_true(Bool(got), "'" + text + "' reads as a BIGINT")
    assert_equal(got.value(), want, "'" + text + "' as BIGINT")


def _no_i64(text: String) raises:
    assert_false(Bool(parse_text_int64(text)), "'" + text + "' is no BIGINT")


def _i32(text: String, want: Int32) raises:
    var got = parse_text_int32(text)
    assert_true(Bool(got), "'" + text + "' reads as an INTEGER")
    assert_equal(got.value(), want, "'" + text + "' as INTEGER")


def _no_i32(text: String) raises:
    assert_false(Bool(parse_text_int32(text)), "'" + text + "' is no INTEGER")


def _f64(text: String, want: Float64) raises:
    """Bit for bit, so -0.0 is not 0.0."""
    var got = parse_text_float64(text)
    assert_true(Bool(got), "'" + text + "' reads as a DOUBLE")
    assert_equal(
        bitcast[DType.uint64](got.value()),
        bitcast[DType.uint64](want),
        "'" + text + "' as DOUBLE: got " + String(got.value()),
    )


def _no_f64(text: String) raises:
    assert_false(Bool(parse_text_float64(text)), "'" + text + "' is no DOUBLE")


def _nan_f64(text: String, negative: Bool) raises:
    var got = parse_text_float64(text)
    assert_true(Bool(got), "'" + text + "' reads as a DOUBLE")
    var v = got.value()
    assert_true(v != v, "'" + text + "' is NaN")
    assert_equal((bitcast[DType.uint64](v) >> 63) == 1, negative, "'" + text + "' sign")


def _f32(text: String, want: Float32) raises:
    """Bit for bit."""
    var got = parse_text_float32(text)
    assert_true(Bool(got), "'" + text + "' reads as a REAL")
    assert_equal(
        bitcast[DType.uint32](got.value()),
        bitcast[DType.uint32](want),
        "'" + text + "' as REAL: got " + String(got.value()),
    )


def _no_f32(text: String) raises:
    assert_false(Bool(parse_text_float32(text)), "'" + text + "' is no REAL")


def _nan_f32(text: String, negative: Bool) raises:
    var got = parse_text_float32(text)
    assert_true(Bool(got), "'" + text + "' reads as a REAL")
    var v = got.value()
    assert_true(v != v, "'" + text + "' is NaN")
    assert_equal((bitcast[DType.uint32](v) >> 31) == 1, negative, "'" + text + "' sign")


def test_digits_sign_and_whitespace() raises:
    """Decimal digits with an optional sign, leading zeros and surrounding
    whitespace; a sign followed only by whitespace reads as 0 in DuckDB."""
    _i64("12", 12)
    _i32("12", 12)
    _i64("-7", -7)
    _i32("-7", -7)
    _i64(" 12 ", 12)
    _i32(" 12 ", 12)
    _i64("0", 0)
    _i32("0", 0)
    _i64("05", 5)
    _i32("05", 5)
    _i64("007", 7)
    _i32("007", 7)
    _i64("+99", 99)
    _i32("+99", 99)
    _i64("2147483647", 2147483647)
    _i32("2147483647", 2147483647)
    _i64("-2147483648", -2147483648)
    _i32("-2147483648", -2147483648)
    _i64("- ", 0)
    _i32("- ", 0)


def test_fraction_rounds_half_away_from_zero_on_its_first_digit() raises:
    """`'3.5'` is 4, `'2.5'` 3 and `'-2.5'` -3: the first fraction digit decides,
    so `'1.49999'` is 1; a `.` needs a digit on one side."""
    _i64("3.5", 4)
    _i32("3.5", 4)
    _i64("2.5", 3)
    _i32("2.5", 3)
    _i64("-2.5", -3)
    _i32("-2.5", -3)
    _i64("-3.5", -4)
    _i32("-3.5", -4)
    _i64("0.5", 1)
    _i32("0.5", 1)
    _i64("-0.5", -1)
    _i32("-0.5", -1)
    _i64("1.49999", 1)
    _i32("1.49999", 1)
    _i64("0.99999999999999999999999", 1)
    _i32("0.99999999999999999999999", 1)
    _i64(".5", 1)
    _i32(".5", 1)
    _i64("-.5", -1)
    _i32("-.5", -1)
    _i64("+.5", 1)
    _i32("+.5", 1)
    _i64("5.", 5)
    _i32("5.", 5)
    _i64("1. ", 1)
    _i32("1. ", 1)


def test_exponent_shifts_digits_as_duckdb_does() raises:
    """An exponent moves digits between the integer and its fraction and the
    first-digit rounding follows, with DuckDB's answers where they differ
    from exact arithmetic: `'5e-2'` and `'0.5e-1'` are 1, `'0.55e-1'` is 0, and
    a 19-digit fraction wraps the 10^19 divisor (`'1.9000000000000000000e0'`
    is 0)."""
    _i64("1e2", 100)
    _i32("1e2", 100)
    _i64("1E2", 100)
    _i32("1E2", 100)
    _i64("25e-1", 3)
    _i32("25e-1", 3)
    _i64("1e3", 1000)
    _i32("1e3", 1000)
    _i64("1.5e1", 15)
    _i32("1.5e1", 15)
    _i64("1.45e1", 15)
    _i32("1.45e1", 15)
    _i64("125e-2", 1)
    _i32("125e-2", 1)
    _i64("-125e-2", -1)
    _i32("-125e-2", -1)
    _i64("0.5e-1", 1)
    _i32("0.5e-1", 1)
    _i64("0.9e-1", 1)
    _i32("0.9e-1", 1)
    _i64("0.55e-1", 0)
    _i32("0.55e-1", 0)
    _i64("5e-2", 1)
    _i32("5e-2", 1)
    _i64("-5e-2", -1)
    _i32("-5e-2", -1)
    _i64("1.0500e2", 105)
    _i32("1.0500e2", 105)
    _i64("0.5e3", 500)
    _i32("0.5e3", 500)
    _i64("0.9e19", 9000000000000000000)
    _no_i32("0.9e19")
    _i64("1.00000000000000000000001e0", 1)
    _i32("1.00000000000000000000001e0", 1)
    _i64("1.9000000000000000000e0", 0)
    _i32("1.9000000000000000000e0", 0)
    _i64("-1.9000000000000000000e0", 0)
    _i32("-1.9000000000000000000e0", 0)
    _i64("1.900000000000000000e0", 2)
    _i32("1.900000000000000000e0", 2)
    _i64("30000000000e-2", 300000000)
    _i32("30000000000e-2", 300000000)
    _i64("1e18", 1000000000000000000)
    _no_i32("1e18")
    _i64("1e2.", 100)
    _i32("1e2.", 100)
    _i64("1e2. ", 100)
    _i32("1e2. ", 100)
    _i64("1e1 ", 10)
    _i32("1e1 ", 10)
    _i64("5e-32768", 1)
    _i32("5e-32768", 1)
    _i64("1e1_0", 10000000000)
    _no_i32("1e1_0")
    _i64("1e+2", 100)
    _i32("1e+2", 100)
    _i64("1e ", 1)
    _i32("1e ", 1)


def test_exponent_that_is_no_number_or_past_the_range() raises:
    """An exponent must be an INT16 of digits (a `.` only with nothing after it)
    and must leave the value in range."""
    _no_i64("1e2.5")
    _no_i32("1e2.5")
    _no_i64("1e.")
    _no_i32("1e.")
    _no_i64("1e2.x")
    _no_i32("1e2.x")
    _no_i64("1e1 x")
    _no_i32("1e1 x")
    _no_i64("1e1x")
    _no_i32("1e1x")
    _no_i64("1e-99999")
    _no_i32("1e-99999")
    _no_i64("1e99999")
    _no_i32("1e99999")
    _no_i64("1e32767")
    _no_i32("1e32767")
    _no_i64("1e1_")
    _no_i32("1e1_")
    _no_i64("1e1__0")
    _no_i32("1e1__0")
    _no_i64("1e+")
    _no_i32("1e+")
    _no_i64("1e-")
    _no_i32("1e-")
    _no_i64("e1")
    _no_i32("e1")
    _no_i64("1e")
    _no_i32("1e")
    _no_i64("1ex")
    _no_i32("1ex")
    _no_i64("0.9e20")
    _no_i32("0.9e20")
    _no_i64("1e19")
    _no_i32("1e19")
    _no_i64("-1e19")
    _no_i32("-1e19")


def test_int64_range_edges() raises:
    """BIGINT's range, checked on every digit and after rounding."""
    _i64("9223372036854775807", 9223372036854775807)
    _no_i32("9223372036854775807")
    _no_i64("9223372036854775808")
    _no_i32("9223372036854775808")
    _i64("-9223372036854775808", -9223372036854775808)
    _no_i32("-9223372036854775808")
    _no_i64("-9223372036854775809")
    _no_i32("-9223372036854775809")
    _i64("9223372036854775807.4", 9223372036854775807)
    _no_i32("9223372036854775807.4")
    _no_i64("9223372036854775807.5")
    _no_i32("9223372036854775807.5")
    _i64("-9223372036854775808.4", -9223372036854775808)
    _no_i32("-9223372036854775808.4")
    _no_i64("-9223372036854775808.5")
    _no_i32("-9223372036854775808.5")
    _i64("922337203685477580.7e1", 9223372036854775807)
    _no_i32("922337203685477580.7e1")
    _no_i64("922337203685477580.8e1")
    _no_i32("922337203685477580.8e1")
    _i64("-922337203685477580.8e1", -9223372036854775808)
    _no_i32("-922337203685477580.8e1")
    _no_i64("-922337203685477580.9e1")
    _no_i32("-922337203685477580.9e1")


def test_int32_range_is_checked_on_the_rounded_int64() raises:
    """INTEGER reads the INT64 value and range-checks it after rounding."""
    _i64("2147483648", 2147483648)
    _no_i32("2147483648")
    _i64("-2147483649", -2147483649)
    _no_i32("-2147483649")
    _i64("2147483647.5", 2147483648)
    _no_i32("2147483647.5")
    _i64("-2147483648.5", -2147483649)
    _no_i32("-2147483648.5")


def test_underscore_between_two_digits() raises:
    """One `_` between two digits, in the integer, the fraction or the exponent."""
    _i64("1_000", 1000)
    _i32("1_000", 1000)
    _i64("1_0.5", 11)
    _i32("1_0.5", 11)
    _i64("1.5_5", 2)
    _i32("1.5_5", 2)
    _no_i64("1_")
    _no_i32("1_")
    _no_i64("1__0")
    _no_i32("1__0")
    _no_i64("_1")
    _no_i32("_1")
    _no_i64("1_.5")
    _no_i32("1_.5")
    _no_i64("1._5")
    _no_i32("1._5")
    _no_i64("1.5_")
    _no_i32("1.5_")
    _no_i64("1.5__5")
    _no_i32("1.5__5")


def test_hexadecimal_and_binary() raises:
    """`0x` / `0b` after the leading whitespace and with no sign: at most the
    target's maximum, `_` between digits, no trailing whitespace."""
    _i64("0x1F", 31)
    _i32("0x1F", 31)
    _i64("0X1f", 31)
    _i32("0X1f", 31)
    _i64("0x1e1", 481)
    _i32("0x1e1", 481)
    _i64("0b101", 5)
    _i32("0b101", 5)
    _i64("0B11", 3)
    _i32("0B11", 3)
    _i64("0x1_F", 31)
    _i32("0x1_F", 31)
    _i64("0b1_1", 3)
    _i32("0b1_1", 3)
    _i64(" 0x1F", 31)
    _i32(" 0x1F", 31)
    _i64("0x7FFFFFFFFFFFFFFF", 9223372036854775807)
    _no_i32("0x7FFFFFFFFFFFFFFF")
    _i64("0xFFFFFFFF", 4294967295)
    _no_i32("0xFFFFFFFF")
    _i64("0x80000000", 2147483648)
    _no_i32("0x80000000")
    _no_i64("0xg")
    _no_i32("0xg")
    _no_i64("0b2")
    _no_i32("0b2")
    _no_i64("0x1_")
    _no_i32("0x1_")
    _no_i64("0x1_g")
    _no_i32("0x1_g")
    _no_i64("0b1_2")
    _no_i32("0b1_2")
    _no_i64("0x_1F")
    _no_i32("0x_1F")
    _no_i64("0x")
    _no_i32("0x")
    _no_i64("0b")
    _no_i32("0b")
    _no_i64("0x8000000000000000")
    _no_i32("0x8000000000000000")
    _no_i64("0x1F ")
    _no_i32("0x1F ")
    _no_i64("-0x1F")
    _no_i32("-0x1F")
    _no_i64("+0x1F")
    _no_i32("+0x1F")


def test_text_that_is_no_integer() raises:
    """Empty and blank text, other characters, two signs, a lone `.` or sign."""
    _no_i64("")
    _no_i32("")
    _no_i64("   ")
    _no_i32("   ")
    _no_i64("abc")
    _no_i32("abc")
    _no_i64("1.2.3")
    _no_i32("1.2.3")
    _no_i64("--1")
    _no_i32("--1")
    _no_i64("+-5")
    _no_i32("+-5")
    _no_i64("-+5")
    _no_i32("-+5")
    _no_i64("1,000")
    _no_i32("1,000")
    _no_i64(".")
    _no_i32(".")
    _no_i64("-.")
    _no_i32("-.")
    _no_i64("+")
    _no_i32("+")
    _no_i64("-")
    _no_i32("-")
    _no_i64("1 2")
    _no_i32("1 2")
    _no_i64("12a3")
    _no_i32("12a3")


def test_whitespace_is_the_six_ascii_spaces() raises:
    """Tab, newline, vertical tab, form feed and carriage return are
    whitespace around a number; a control character below them is not."""
    _i64("\t7\n", 7)
    _i64(chr(11) + "7" + chr(12) + chr(13), 7)
    _no_i64(chr(1) + "7")
    _f64("\t7\n", Float64(7.0))


def test_float_values_are_correctly_rounded_for_each_width() raises:
    """The nearest DOUBLE, and the nearest REAL straight from the text (not a
    DOUBLE rounded again): ties to even, subnormals, the largest finite values."""
    _f64("1.5", Float64(1.5))
    _f32("1.5", Float32(1.5))
    _f64("-3.14", Float64(-3.14))
    _f32("-3.14", Float32(-3.14))
    _f64("0.0", Float64(0.0))
    _f32("0.0", Float32(0.0))
    _f64("42", Float64(42.0))
    _f32("42", Float32(42.0))
    _f64("1e3", Float64(1000.0))
    _f32("1e3", Float32(1000.0))
    _f64("1.5e3", Float64(1500.0))
    _f32("1.5e3", Float32(1500.0))
    _f64("1E-2", Float64(0.01))
    _f32("1E-2", Float32(0.01))
    _f64("-2.5e2", Float64(-250.0))
    _f32("-2.5e2", Float32(-250.0))
    _f64("0.1", Float64(0.1))
    _f32("0.1", Float32(0.1))
    _f64("123.456", Float64(123.456))
    _f32("123.456", Float32(123.456))
    _f64("7.58", Float64(7.58))
    _f32("7.58", Float32(7.58))
    _f64("9007199254740993", Float64(9007199254740992.0))
    _f32("9007199254740993", Float32(9007199000000000.0))
    _f64("1.7976931348623157e308", Float64(1.7976931348623157e+308))
    _f32("1.7976931348623157e308", _inf32())
    _f64("4.9e-324", Float64(5e-324))
    _f32("4.9e-324", Float32(0.0))
    _f64("3e-324", Float64(5e-324))
    _f32("3e-324", Float32(0.0))
    _f64("2.2250738585072011e-308", Float64(2.225073858507201e-308))
    _f32("2.2250738585072011e-308", Float32(0.0))
    _f64("1.5E+0010", Float64(15000000000.0))
    _f32("1.5E+0010", Float32(15000000512.0))
    _f64("00001.5", Float64(1.5))
    _f32("00001.5", Float32(1.5))
    _f64("123456789012345678901234567890", Float64(1.2345678901234568e+29))
    _f32("123456789012345678901234567890", Float32(1.2345679e+29))
    _f64("0.000000000000000000000000000000000000000000000000001e51", Float64(1.0))
    _f32("0.000000000000000000000000000000000000000000000000001e51", Float32(1.0))
    _f64("3.4028235e38", Float64(3.4028235e+38))
    _f32("3.4028235e38", Float32(3.4028235e+38))
    _f64("3.402823567e38", Float64(3.402823567e+38))
    _f32("3.402823567e38", Float32(3.4028235e+38))
    _f64("1.4e-45", Float64(1.4e-45))
    _f32("1.4e-45", bitcast[DType.float32](UInt32(1)))
    _f64(" 1.5 ", Float64(1.5))
    _f32(" 1.5 ", Float32(1.5))
    _f64("1e+5", Float64(100000.0))
    _f32("1e+5", Float32(100000.0))
    _f64("1e-5", Float64(1e-05))
    _f32("1e-5", Float32(1e-05))


def test_float_past_the_range_is_an_infinity_and_below_it_a_zero() raises:
    """`'1e400'` is inf and `'-1e-400'` is -0.0 in DuckDB, for DOUBLE and REAL."""
    _f64("1.7976931348623159e308", _inf64())
    _f32("1.7976931348623159e308", _inf32())
    _f64("1e400", _inf64())
    _f32("1e400", _inf32())
    _f64("-1e400", -_inf64())
    _f32("-1e400", -_inf32())
    _f64("1e-400", Float64(0.0))
    _f32("1e-400", Float32(0.0))
    _f64("-1e-400", -Float64(0.0))
    _f32("-1e-400", -Float32(0.0))
    _f64("2e-324", Float64(0.0))
    _f32("2e-324", Float32(0.0))
    _f64("3.4028236e38", Float64(3.4028236e+38))
    _f32("3.4028236e38", _inf32())
    _f64("1e-46", Float64(1e-46))
    _f32("1e-46", Float32(0.0))
    _f64("-0", -Float64(0.0))
    _f32("-0", -Float32(0.0))


def test_float_grammar() raises:
    """Digits on either side of a `.`, one `+` (after which a `-` is read),
    `_` between digits, an exponent with an optional sign."""
    _f64(".5", Float64(0.5))
    _f32(".5", Float32(0.5))
    _f64("5.", Float64(5.0))
    _f32("5.", Float32(5.0))
    _f64("5.e1", Float64(50.0))
    _f32("5.e1", Float32(50.0))
    _f64("-.5", Float64(-0.5))
    _f32("-.5", Float32(-0.5))
    _f64("+.5", Float64(0.5))
    _f32("+.5", Float32(0.5))
    _f64("+-5", Float64(-5.0))
    _f32("+-5", Float32(-5.0))
    _no_f64("-+5")
    _no_f32("-+5")
    _no_f64("++5")
    _no_f32("++5")
    _f64("1_000.5", Float64(1000.5))
    _f32("1_000.5", Float32(1000.5))
    _f64("1_000.5_5", Float64(1000.55))
    _f32("1_000.5_5", Float32(1000.55))
    _f64("1e1_0", Float64(10000000000.0))
    _f32("1e1_0", Float32(10000000000.0))
    _f64(".5_5", Float64(0.55))
    _f32(".5_5", Float32(0.55))
    _no_f64("1_")
    _no_f32("1_")
    _no_f64("1._5")
    _no_f32("1._5")
    _no_f64("1.5_")
    _no_f32("1.5_")
    _no_f64("1_.5")
    _no_f32("1_.5")
    _no_f64("1e_1")
    _no_f32("1e_1")
    _no_f64("1.5_e1")
    _no_f32("1.5_e1")
    _no_f64("1e1_")
    _no_f32("1e1_")
    _no_f64("1e")
    _no_f32("1e")
    _no_f64("1e+")
    _no_f32("1e+")
    _no_f64("1e-")
    _no_f32("1e-")
    _no_f64("1.5x")
    _no_f32("1.5x")
    _no_f64("1.5 x")
    _no_f32("1.5 x")
    _no_f64(".")
    _no_f32(".")
    _no_f64("-.")
    _no_f32("-.")
    _no_f64("abc")
    _no_f32("abc")
    _no_f64("-")
    _no_f32("-")
    _no_f64("+")
    _no_f32("+")
    _no_f64("1.2.3")
    _no_f32("1.2.3")
    _no_f64("1,5")
    _no_f32("1,5")
    _no_f64("0x10")
    _no_f32("0x10")


def test_float_nan_and_infinities() raises:
    """`nan` (with an optional `(<letters, digits, _>)`), `inf` and `infinity` in
    any case with an optional sign; `-nan` keeps its sign."""
    _nan_f64("nan", False)
    _nan_f32("nan", False)
    _nan_f64("NaN", False)
    _nan_f32("NaN", False)
    _nan_f64("NAN", False)
    _nan_f32("NAN", False)
    _nan_f64("-nan", True)
    _nan_f32("-nan", True)
    _nan_f64("+nan", False)
    _nan_f32("+nan", False)
    _nan_f64("nan(1)", False)
    _nan_f32("nan(1)", False)
    _nan_f64("nan()", False)
    _nan_f32("nan()", False)
    _nan_f64("nan(a_Z9)", False)
    _nan_f32("nan(a_Z9)", False)
    _no_f64("nan(1")
    _no_f32("nan(1")
    _no_f64("nan(1-2)")
    _no_f32("nan(1-2)")
    _f64("inf", _inf64())
    _f32("inf", _inf32())
    _f64("iNf", _inf64())
    _f32("iNf", _inf32())
    _f64("-inf", -_inf64())
    _f32("-inf", -_inf32())
    _f64("+inf", _inf64())
    _f32("+inf", _inf32())
    _f64("infinity", _inf64())
    _f32("infinity", _inf32())
    _f64("-Infinity", -_inf64())
    _f32("-Infinity", -_inf32())
    _no_f64("infinit")
    _no_f32("infinit")
    _no_f64("infinityx")
    _no_f32("infinityx")
    _no_f64("infx")
    _no_f32("infx")
    _f64("inf ", _inf64())
    _f32("inf ", _inf32())
    _f64(" inf", _inf64())
    _f32(" inf", _inf32())


def test_nan_spelling_stops_at_a_character_outside_its_sequence() raises:
    """`nan(` takes letters, digits and `_` up to `)`; any other character
    leaves the `(` unread, which is not a number."""
    _no_f64("nan(~)")
    _no_f64("nan(-)")
    _no_f32("nan(~)")


def test_exact_parser_refusing_built_text_is_a_defect_not_a_null() raises:
    """The number text `_float_text` builds always parses; if it did not,
    the cast raises naming the parser instead of answering NULL."""
    var t = _FloatText(False, UInt8(0), String("x"))
    var raised = String("")
    try:
        _ = _f64_of(t)
    except e:
        raised = String(e)
    assert_equal(raised, "parse_text_float64: JsonError: not a proto3 double: x")
    raised = String("")
    try:
        _ = _f32_of(t)
    except e:
        raised = String(e)
    assert_equal(raised, "parse_text_float32: JsonError: not a proto3 float: x")


def test_truncating_division_is_cs() raises:
    """C's `/` truncates toward zero and `%` takes the dividend's sign."""
    assert_equal(_tdiv(Int64(-7), Int64(2)), Int64(-3))
    assert_equal(_trem(Int64(-7), Int64(2)), Int64(-1))
    assert_equal(_tdiv(Int64(7), Int64(-2)), Int64(-3))
    assert_equal(_trem(Int64(7), Int64(-2)), Int64(1))
    assert_equal(_tdiv(Int64(-7), Int64(-2)), Int64(3))
    assert_equal(_tdiv(Int64(7), Int64(2)), Int64(3))


def _column(bad: Bool) raises -> StringArray[HeapRegion]:
    """`'12'`, NULL, `'3.5'`, and `'abc'` when `bad`."""
    var vals = List[String]()
    vals.append(String("12"))
    vals.append(String(""))
    vals.append(String("3.5"))
    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    valid.append(True)
    if bad:
        vals.append(String("abc"))
        valid.append(True)
    return StringArray.from_strings_with_validity(vals, valid)


def test_int64_column_cast_and_try_cast() raises:
    """CAST raises DuckDB's Conversion Error on `'abc'`; TRY_CAST makes it
    NULL; a NULL cell is NULL under both."""
    var raised = String("")
    try:
        _ = cast_string_to_int64(_column(True))
    except e:
        raised = String(e)
    assert_equal(raised, "Conversion Error: Could not convert string 'abc' to INT64")
    var t = cast_string_to_int64(_column(True), True)
    assert_equal(t.get(0), Int64(12))
    assert_true(t.is_null(1))
    assert_equal(t.get(2), Int64(4))
    assert_true(t.is_null(3))
    assert_equal(t.null_count, 2)
    var c = cast_string_to_int64(_column(False))
    assert_equal(c.get(0), Int64(12))
    assert_true(c.is_null(1))
    assert_equal(c.get(2), Int64(4))
    assert_equal(c.null_count, 1)


def test_int32_column_cast_and_try_cast() raises:
    var raised = String("")
    try:
        _ = cast_string_to_int32(_column(True))
    except e:
        raised = String(e)
    assert_equal(raised, "Conversion Error: Could not convert string 'abc' to INT32")
    var t = cast_string_to_int32(_column(True), True)
    assert_equal(t.get(0), Int32(12))
    assert_true(t.is_null(1))
    assert_equal(t.get(2), Int32(4))
    assert_true(t.is_null(3))
    assert_equal(t.null_count, 2)
    var c = cast_string_to_int32(_column(False))
    assert_equal(c.get(2), Int32(4))
    assert_equal(c.null_count, 1)


def test_float64_column_cast_and_try_cast() raises:
    var raised = String("")
    try:
        _ = cast_string_to_float64(_column(True))
    except e:
        raised = String(e)
    assert_equal(raised, "Conversion Error: Could not convert string 'abc' to DOUBLE")
    var t = cast_string_to_float64(_column(True), True)
    assert_equal(t.get(0), Float64(12.0))
    assert_true(t.is_null(1))
    assert_equal(t.get(2), Float64(3.5))
    assert_true(t.is_null(3))
    assert_equal(t.null_count, 2)
    var c = cast_string_to_float64(_column(False))
    assert_equal(c.get(2), Float64(3.5))
    assert_equal(c.null_count, 1)


def test_float32_column_cast_and_try_cast() raises:
    var raised = String("")
    try:
        _ = cast_string_to_float32(_column(True))
    except e:
        raised = String(e)
    assert_equal(raised, "Conversion Error: Could not convert string 'abc' to FLOAT")
    var t = cast_string_to_float32(_column(True), True)
    assert_equal(t.get(0), Float32(12.0))
    assert_true(t.is_null(1))
    assert_equal(t.get(2), Float32(3.5))
    assert_true(t.is_null(3))
    assert_equal(t.null_count, 2)
    var c = cast_string_to_float32(_column(False))
    assert_equal(c.get(2), Float32(3.5))
    assert_equal(c.null_count, 1)


def test_scalar_parsers_raise_the_conversion_error() raises:
    """`i64_from_str` and its three twins answer the value or raise DuckDB's
    Conversion Error naming the text and the type."""
    assert_equal(i64_from_str(String("-2.5")), Int64(-3))
    assert_equal(i32_from_str(String("0x1F")), Int32(31))
    assert_equal(f64_from_str(String("1e3")), Float64(1000.0))
    assert_equal(f32_from_str(String("0.1")), Float32(0.1))
    var got = List[String]()
    try:
        _ = i64_from_str(String("x"))
    except e:
        got.append(String(e))
    try:
        _ = i32_from_str(String("2147483648"))
    except e:
        got.append(String(e))
    try:
        _ = f64_from_str(String("x"))
    except e:
        got.append(String(e))
    try:
        _ = f32_from_str(String("x"))
    except e:
        got.append(String(e))
    assert_equal(len(got), 4)
    assert_equal(got[0], "Conversion Error: Could not convert string 'x' to INT64")
    assert_equal(got[1], "Conversion Error: Could not convert string '2147483648' to INT32")
    assert_equal(got[2], "Conversion Error: Could not convert string 'x' to DOUBLE")
    assert_equal(got[3], "Conversion Error: Could not convert string 'x' to FLOAT")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
