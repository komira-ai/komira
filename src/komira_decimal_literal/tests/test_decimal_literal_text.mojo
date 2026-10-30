# =============================================================================
# decimal_from_literal_text: the DECIMAL type and value of a literal's text
# =============================================================================
#
# The expected precision and scale of each row are what DuckDB prints for
# `typeof(<literal>)` (komira_decimal_compare_conformance/oracle/types.sql):
# 0.06 DECIMAL(3,2), 0.060 DECIMAL(4,3), 1.5 DECIMAL(2,1), 0.0 DECIMAL(2,1),
# 100.00 DECIMAL(5,2).
#
# What each test proves, and the defect it catches:
#   * test_text_gives_digits_as_precision_and_fraction_as_scale: precision is
#     the digit count (the leading zero included), scale the digits after the
#     point, value the digits as one integer. Catches a precision that drops
#     the leading zero or a trailing zero, and a scale off by one.
#   * test_a_sign_negates_the_value: a leading minus negates the value and
#     changes no digit count. Catches a sign counted as a digit, or dropped.
#   * test_the_38_digit_limit: 38 digits are a DECIMAL(38, s), 39 are not.
#     Catches an off-by-one at the limit, either side.
#   * test_text_that_is_not_a_decimal_literal_has_no_type: no point, nothing
#     after the point, two points, a letter, empty, a sign alone. Catches a
#     malformed text typed as a number.

from std.testing import TestSuite, assert_equal, assert_true

from komira_decimal_literal.decimal_literal import decimal_from_literal_text
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128


def _expect(text: String, unscaled: Int, precision: Int, scale: Int) raises:
    var got = decimal_from_literal_text(text)
    assert_true(Bool(got), text + " has no type")
    var want = ScalarValue.decimal128_i128(I128(unscaled), precision, scale)
    assert_equal(String(got.value()), String(want))


def test_text_gives_digits_as_precision_and_fraction_as_scale() raises:
    _expect("0.06", 6, 3, 2)
    _expect("0.060", 60, 4, 3)
    _expect("1.5", 15, 2, 1)
    _expect("0.0", 0, 2, 1)
    _expect("100.00", 10000, 5, 2)
    _expect("0.0000001", 1, 8, 7)
    _expect("24.00", 2400, 4, 2)
    _expect("123456789.987654321", 123456789987654321, 18, 9)


def test_a_sign_negates_the_value() raises:
    _expect("-0.06", -6, 3, 2)
    _expect("-0.5", -5, 2, 1)
    _expect("-100.00", -10000, 5, 2)
    # Negative zero is zero.
    _expect("-0.0", 0, 2, 1)


def test_the_38_digit_limit() raises:
    # 1 + 37 digits after the point: precision 38, scale 37.
    var frac37 = String("")
    for _ in range(37):
        frac37 += "9"
    var at_limit = decimal_from_literal_text("0." + frac37)
    assert_true(Bool(at_limit), "38 digits have a type")
    assert_equal(at_limit.value().dec128_precision, 38)
    assert_equal(at_limit.value().dec128_scale, 37)
    var past = decimal_from_literal_text("0." + frac37 + "9")
    assert_true(not past, "39 digits have no type")
    # 38 digits in the integer part, one after the point is 39: no type.
    var int38 = String("")
    for _ in range(38):
        int38 += "9"
    assert_true(not decimal_from_literal_text(int38 + ".5"), "39 digits")
    var int37 = String("")
    for _ in range(37):
        int37 += "9"
    var edge = decimal_from_literal_text(int37 + ".5")
    assert_true(Bool(edge), "38 digits with 37 before the point")
    assert_equal(edge.value().dec128_scale, 1)


def test_text_that_is_not_a_decimal_literal_has_no_type() raises:
    assert_true(not decimal_from_literal_text(""), "empty")
    assert_true(not decimal_from_literal_text("-"), "sign alone")
    assert_true(not decimal_from_literal_text("5"), "no point")
    assert_true(not decimal_from_literal_text("5."), "nothing after the point")
    assert_true(not decimal_from_literal_text("."), "point alone")
    assert_true(not decimal_from_literal_text("1.2.3"), "two points")
    assert_true(not decimal_from_literal_text("1.x"), "a letter")
    assert_true(not decimal_from_literal_text("1e5"), "an exponent")
    assert_true(not decimal_from_literal_text("+1.5"), "a plus sign")


def main() raises:
    var suite = TestSuite()
    suite.test[test_text_gives_digits_as_precision_and_fraction_as_scale]()
    suite.test[test_a_sign_negates_the_value]()
    suite.test[test_the_38_digit_limit]()
    suite.test[test_text_that_is_not_a_decimal_literal_has_no_type]()
    suite^.run()
