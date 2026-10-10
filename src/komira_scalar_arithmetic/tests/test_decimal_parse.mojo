# =============================================================================
# STRING -> DECIMAL128 (`string_to_decimal_i128`): sign, digits, point,
# exponent, surrounding whitespace, HALF_UP to the target scale, refusals.
#
# Oracle: the decimal value the literal spells, rounded half away from zero to
# the target scale (DuckDB's `CAST('...' AS DECIMAL(p, s))`), worked by hand.
# Only refusals every candidate grammar shares are pinned: no digits, a stray
# character, a malformed exponent, embedded whitespace, a value past the
# precision. Grammar extensions some engines accept (`1_000`, `0x1F`) are not
# asserted either way.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import string_to_decimal_i128

comptime MAX38 = I128(99999999999999999999999999999999999999)


def _parse_message(s: String, p: Int, sc: Int) -> String:
    try:
        _ = string_to_decimal_i128(s, p, sc)
    except e:
        return String(e)
    return String("")


def test_plain_literals() raises:
    assert_equal(string_to_decimal_i128("123.45", 10, 2), I128(12345))
    assert_equal(string_to_decimal_i128("+123.45", 10, 2), I128(12345))
    assert_equal(string_to_decimal_i128("-123.45", 10, 2), I128(-12345))
    assert_equal(string_to_decimal_i128("7", 10, 3), I128(7000))
    assert_equal(string_to_decimal_i128("-0", 5, 0), I128(0))
    assert_equal(string_to_decimal_i128("007.50", 5, 2), I128(750))


def test_point_without_digits_on_one_side() raises:
    """`.5` is 0.5 and `5.` is 5, as in SQL numeric literals."""
    assert_equal(string_to_decimal_i128(".5", 5, 2), I128(50))
    assert_equal(string_to_decimal_i128("5.", 5, 2), I128(500))
    assert_equal(string_to_decimal_i128("-.25", 5, 2), I128(-25))


def test_surrounding_whitespace_is_trimmed() raises:
    """Space, tab, LF, CR, VT and FF on either side are ignored."""
    assert_equal(string_to_decimal_i128(" -1.255 ", 10, 2), I128(-126))
    assert_equal(string_to_decimal_i128("\t1.5\n", 5, 1), I128(15))
    assert_equal(string_to_decimal_i128("\r1.5\x0b", 5, 1), I128(15))
    assert_equal(string_to_decimal_i128("\x0c1.5\x0c", 5, 1), I128(15))
    assert_equal(string_to_decimal_i128("\x0b\x0c\r\n\t 2", 5, 0), I128(2))


def test_rounds_half_away_from_zero() raises:
    """1.005 -> 1.01 (tie); 1.004 -> 1.00; -1.005 -> -1.01; -0.004 -> 0.00;
    -3.99 -> -4 and -3.01 -> -3 at scale 0 (negative non-ties)."""
    assert_equal(string_to_decimal_i128("1.005", 10, 2), I128(101))
    assert_equal(string_to_decimal_i128("1.004", 10, 2), I128(100))
    assert_equal(string_to_decimal_i128("-1.005", 10, 2), I128(-101))
    assert_equal(string_to_decimal_i128("-0.004", 10, 2), I128(0))
    assert_equal(string_to_decimal_i128("-3.99", 10, 0), I128(-4))
    assert_equal(string_to_decimal_i128("-3.01", 10, 0), I128(-3))


def test_exponents() raises:
    """1.2e1 = 12; 125e-2 = 1.25 -> 1.3 at scale 1; 1E+2 = 100.00;
    2.5E-1 = 0.25; -4e0 = -4; 1e-2 = 0.01 exactly at scale 2."""
    assert_equal(string_to_decimal_i128("1.2e1", 10, 0), I128(12))
    assert_equal(string_to_decimal_i128("125e-2", 10, 1), I128(13))
    assert_equal(string_to_decimal_i128("1E+2", 10, 2), I128(10000))
    assert_equal(string_to_decimal_i128("2.5E-1", 10, 2), I128(25))
    assert_equal(string_to_decimal_i128("-4e0", 10, 0), I128(-4))
    assert_equal(string_to_decimal_i128("1e-2", 10, 2), I128(1))
    assert_equal(string_to_decimal_i128("12e10", 20, 0), I128(120000000000))


def test_empty_and_whitespace_refused() raises:
    var empty = "Decimal128 parse: empty or whitespace-only string"
    assert_equal(_parse_message("", 10, 2), empty)
    assert_equal(_parse_message("   ", 10, 2), empty)
    assert_equal(_parse_message("\t\n", 10, 2), empty)


def test_no_digits_refused() raises:
    assert_equal(_parse_message(".", 10, 2), "Decimal128 parse: no digits in '.'")
    assert_equal(_parse_message("-", 10, 2), "Decimal128 parse: no digits in '-'")
    assert_equal(_parse_message("abc", 10, 2), "Decimal128 parse: no digits in 'abc'")
    assert_equal(_parse_message("+-5", 10, 2), "Decimal128 parse: no digits in '+-5'")
    assert_equal(_parse_message("e5", 10, 2), "Decimal128 parse: no digits in 'e5'")


def test_malformed_exponent_refused() raises:
    assert_equal(_parse_message("1e", 10, 2), "Decimal128 parse: malformed exponent in '1e'")
    assert_equal(_parse_message("1e+", 10, 2), "Decimal128 parse: malformed exponent in '1e+'")
    assert_equal(_parse_message("1E-", 10, 2), "Decimal128 parse: malformed exponent in '1E-'")
    assert_equal(_parse_message("1ex", 10, 2), "Decimal128 parse: malformed exponent in '1ex'")


def test_trailing_garbage_refused() raises:
    """A second point, an inner space, a letter after the number or exponent."""
    assert_equal(_parse_message("1.2.3", 10, 2), "Decimal128 parse: trailing garbage in '1.2.3'")
    assert_equal(_parse_message("1 2", 10, 2), "Decimal128 parse: trailing garbage in '1 2'")
    assert_equal(_parse_message("12x", 10, 2), "Decimal128 parse: trailing garbage in '12x'")
    assert_equal(_parse_message("1e5x", 10, 2), "Decimal128 parse: trailing garbage in '1e5x'")
    assert_equal(_parse_message("1e+5 5", 10, 2), "Decimal128 parse: trailing garbage in '1e+5 5'")


def test_precision_refused() raises:
    """123.45 needs 5 digits: not DECIMAL(4,2). 99.995 rounds to 100.00, also
    five digits. -123.45 the same: the sign is no digit."""
    assert_equal(
        _parse_message("123.45", 4, 2),
        "Decimal128 parse: '123.45' has more than 4 digits — does not fit DECIMAL(4,2)",
    )
    assert_true(_parse_message("99.995", 4, 2).startswith("Decimal128 parse: '99.995' has more than 4 digits"))
    assert_true(_parse_message("-123.45", 4, 2).startswith("Decimal128 parse: '-123.45' has more than 4 digits"))
    assert_equal(string_to_decimal_i128("99.994", 4, 2), I128(9999))


def test_range_boundary() raises:
    """38 nines fit DECIMAL(38,0); 1e38 is 39 digits and overflows, both signs."""
    assert_equal(
        string_to_decimal_i128("99999999999999999999999999999999999999", 38, 0), MAX38
    )
    assert_equal(
        string_to_decimal_i128("-99999999999999999999999999999999999999", 38, 0), -MAX38
    )
    assert_equal(
        _parse_message("1e38", 38, 0),
        "Decimal128 parse: '1e38' overflows DECIMAL(38,0)",
    )
    assert_true(_parse_message("-1e38", 38, 0).startswith("Decimal128 parse: '-1e38' overflows"))
    # 10^80 has no DECIMAL(38,0) value; any refusal is right.
    assert_true(_parse_message("1e80", 38, 0) != "")
    assert_true(_parse_message("-1e80", 38, 0) != "")
    # 1.5e37 at scale 2 is 1.5e39 unscaled: the rescale leaves the range.
    assert_true(_parse_message("1.5e37", 38, 2).startswith("Decimal128 parse: '1.5e37' overflows"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
