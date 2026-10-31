# =============================================================================
# decimal_fold_binary / decimal_negate: DuckDB's type and value of + - * over
# decimal and integer literals
# =============================================================================
#
# The expected precision and scale of the first rows of each test are what
# DuckDB prints for `typeof(<expr>)` (komira_decimal_compare_conformance/
# oracle/types.sql): 0.06 - 0.01 and 0.06 + 0.01 DECIMAL(4,2), 0.06 * 0.01
# DECIMAL(6,4), 0.5 * 0.1 DECIMAL(4,2), 0.1 * 0.1 * 0.1 DECIMAL(6,3),
# 1 - 0.94 DECIMAL(13,2), 2 * 0.025 DECIMAL(14,3), 24 + 0.5 DECIMAL(12,1),
# 3000000000 * 0.5 DECIMAL(21,1), -0.06 + 0.01 DECIMAL(4,2), 0.07 - 0.1
# DECIMAL(4,2), 99999999999999999.99 + 0.01 DECIMAL(20,2). The rows that DuckDB
# caps are in the same file: 2 + 1234567890123456.78 DECIMAL(18,2),
# 123456789.123456789 * 0.5 DECIMAL(18,10), 0.000000001 * 0.000000001
# DECIMAL(20,18), 0.1234567890123456789012345678901234567 + 1 DECIMAL(38,37);
# and the ones it raises on: 12345678.123 * 12345678.123 (overflow of
# DECIMAL(18)), 9999999999.9999999999 * 9999999999.9999999999 (overflow of
# DECIMAL(38)), 0.00000000000000000001 * 0.000000000000000000000000000000000001
# (a scale of 56).
#
# What each test proves, and the defect it catches:
#   * test_add_and_subtract: scale max(s1, s2) and precision
#     max(p1 - s1, p2 - s2) + max(s1, s2) + 1, operands aligned to that scale,
#     either operand order. Catches a result scale of the left operand, an
#     operand not aligned, `-` computed as `+`, and an operand-order slip.
#   * test_multiply: scale s1 + s2, precision p1 + p2 (not p1 + p2 + 1).
#     Catches either rule wrong.
#   * test_integers_take_part_as_decimal_with_duckdbs_widths: an int that fits
#     INT32 is DECIMAL(10, 0), a larger one DECIMAL(19, 0), both signs at both
#     edges. Catches the wrong width and a boundary off by one.
#   * test_limits: a result of 38 digits folds exactly; one of 39 or more is
#     cut to 38 digits and folds when its value fits them (a sum of 10^37 and
#     1 at scale 0; a product of 10^18 and 10^19) and raises when it does not;
#     a value past the precision it is declared with is not folded. Catches a
#     limit off by one, a result that overflows its precision, and a fold that
#     gives up where DuckDB folds.
#   * test_a_result_wider_than_18_digits_from_narrow_operands_is_cut_to_18:
#     when both operands are 18 digits or fewer and the result would be wider
#     than 18 (and, for `*`, its scale below 18), DuckDB gives DECIMAL(18, s)
#     with an overflow check: a 19-digit sum stays DECIMAL(18, s), a product
#     of scale 17 is cut and one of scale 18 is not, and an operand of 19
#     digits switches the cut off. Catches a width of 19 or more where
#     DuckDB's is 18, the scale condition of `*` missing or off by one, and a
#     cut applied to operands of 19 digits.
#   * test_a_result_that_does_not_fit_its_cut_width_is_refused: the same
#     products and sums, with values past 18 and 38 digits, raise with
#     DuckDB's wording ("Overflow in multiplication of DECIMAL(18)"), and a
#     product with a scale past 38 raises ("Needed scale 56"). Catches a value
#     folded into a type too narrow for it, and an error DuckDB raises
#     answered.
#   * test_integer_arithmetic_keeps_the_integer_type /
#     test_integer_arithmetic_raises_where_duckdb_does: `+ - *` over two
#     integer-typed constants is INTEGER (10 digits), BIGINT (19) or HUGEINT
#     (38) by the wider operand, with no promotion: a result outside the type is
#     DuckDB's "Overflow in addition of INT32". Catches an integer sub-expression
#     that falls back to a float, a BIGINT-typed result given INTEGER's width by
#     its value, and an overflow that wraps or promotes.
#   * test_integer_remainder_and_division_truncate: `%` and `//` over integer
#     constants keep the dividend's sign and truncate toward zero; a zero divisor
#     and the minimum over -1 are refused. Catches a floored division and a
#     divisor of zero that crashes.
#   * test_negating_an_integer_minimum_raises: -(-2147483647 - 1) and the BIGINT
#     and HUGEINT minima raise "Overflow in negation of integer!"; the maxima and
#     the BIGINT -2147483648 negate. Catches a negation that wraps.
#   * test_pairs_the_fold_does_not_cover: two integers, a float, a typeless
#     decimal, `/`, a comparison, a non-literal. Catches a pair folded by a
#     rule that does not own it.
#   * test_negate: the type is kept, the sign flips, zero stays zero, and a
#     non-decimal gives None.

from std.testing import TestSuite, assert_equal, assert_true

from komira_decimal_literal.decimal_literal import (
    decimal_fold_binary,
    decimal_negate,
    INTEGER_FOLD_IDIV,
    integer_fold_binary,
    integer_negate,
)
from komira_plan_expr.expr import BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_LT, BIN_MOD
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128, I256, pow10_i256


def _d(unscaled: Int, precision: Int, scale: Int) -> ScalarValue:
    return ScalarValue.decimal128_i128(I128(unscaled), precision, scale)


def _i(v: Int) -> ScalarValue:
    return ScalarValue.from_int(v)


def _expect(
    op: UInt8,
    a: ScalarValue,
    b: ScalarValue,
    unscaled: Int,
    precision: Int,
    scale: Int,
) raises:
    var got = decimal_fold_binary(op, a, b)
    assert_true(Bool(got), "no fold: " + String(a) + " and " + String(b))
    assert_equal(
        String(got.value()), String(_d(unscaled, precision, scale))
    )


def _refusal(op: UInt8, a: ScalarValue, b: ScalarValue) -> String:
    """The message `decimal_fold_binary` raises, or "" when it folds or leaves
    the pair alone."""
    try:
        _ = decimal_fold_binary(op, a, b)
    except e:
        return String(e)
    return String("")


def _digits_value(digits: String, precision: Int, scale: Int) -> ScalarValue:
    """The decimal whose unscaled integer is the 38 digits or fewer in
    `digits`."""
    var n = I128(0)
    for b in digits.as_bytes():
        n = n * I128(10) + I128(Int(b - UInt8(ord("0"))))
    return ScalarValue.decimal128_i128(n, precision, scale)


def _expect_big(
    op: UInt8, a: ScalarValue, b: ScalarValue, digits: String, precision: Int, scale: Int
) raises:
    var got = decimal_fold_binary(op, a, b)
    assert_true(Bool(got), "no fold: " + String(a) + " and " + String(b))
    assert_equal(String(got.value()), String(_digits_value(digits, precision, scale)))


def test_add_and_subtract() raises:
    _expect(BIN_SUB, _d(6, 3, 2), _d(1, 3, 2), 5, 4, 2)
    _expect(BIN_ADD, _d(6, 3, 2), _d(1, 3, 2), 7, 4, 2)
    # Different scales align to the larger: 0.07 - 0.1 = -0.03.
    _expect(BIN_SUB, _d(7, 3, 2), _d(1, 2, 1), -3, 4, 2)
    _expect(BIN_SUB, _d(1, 2, 1), _d(7, 3, 2), 3, 4, 2)
    _expect(BIN_ADD, _d(1, 2, 1), _d(7, 3, 2), 17, 4, 2)
    # Mixed signs.
    _expect(BIN_ADD, _d(-6, 3, 2), _d(1, 3, 2), -5, 4, 2)
    # A wider integer part: 99999999999999999.99 + 0.01.
    var big = ScalarValue.decimal128_i128(pow10_i256(19).cast[DType.int128]() - I128(1), 19, 2)
    var got = decimal_fold_binary(BIN_ADD, big, _d(1, 3, 2))
    assert_true(Bool(got), "wide sum")
    var want = ScalarValue.decimal128_i128(pow10_i256(19).cast[DType.int128](), 20, 2)
    assert_equal(String(got.value()), String(want))


def test_multiply() raises:
    _expect(BIN_MUL, _d(6, 3, 2), _d(1, 3, 2), 6, 6, 4)
    _expect(BIN_MUL, _d(5, 2, 1), _d(1, 2, 1), 5, 4, 2)
    _expect(BIN_MUL, _d(-6, 3, 2), _d(-5, 2, 1), 30, 5, 3)
    _expect(BIN_MUL, _d(-6, 3, 2), _d(5, 2, 1), -30, 5, 3)
    # 0.1 * 0.1 * 0.1 = 0.001 as DECIMAL(6, 3).
    var two = decimal_fold_binary(BIN_MUL, _d(1, 2, 1), _d(1, 2, 1))
    assert_true(Bool(two), "0.1 * 0.1")
    _expect(BIN_MUL, two.value(), _d(1, 2, 1), 1, 6, 3)


def test_integers_take_part_as_decimal_with_duckdbs_widths() raises:
    # 1 - 0.94: DECIMAL(10, 0) - DECIMAL(3, 2).
    _expect(BIN_SUB, _i(1), _d(94, 3, 2), 6, 13, 2)
    # 2 * 0.025: DECIMAL(10, 0) * DECIMAL(4, 3).
    _expect(BIN_MUL, _i(2), _d(25, 4, 3), 50, 14, 3)
    _expect(BIN_ADD, _i(24), _d(5, 2, 1), 245, 12, 1)
    # The integer on the right.
    _expect(BIN_SUB, _d(5, 2, 1), _i(1), -5, 12, 1)
    # INT32 edges: 10 digits; one past: 19 (and -2147483648, below).
    _expect(BIN_ADD, _i(2147483647), _d(5, 2, 1), 21474836475, 12, 1)
    # -2147483648 is a BIGINT in DuckDB (the minus applies to the BIGINT 2147483648).
    _expect(BIN_ADD, _i(-2147483648), _d(5, 2, 1), -21474836475, 21, 1)
    _expect(BIN_ADD, _i(2147483648), _d(5, 2, 1), 21474836485, 21, 1)
    _expect(BIN_ADD, _i(-2147483649), _d(5, 2, 1), -21474836485, 21, 1)
    # 3000000000 * 0.5: DECIMAL(19, 0) * DECIMAL(2, 1).
    _expect(BIN_MUL, _i(3000000000), _d(5, 2, 1), 15000000000, 21, 1)


def _digits(n: Int) raises -> ScalarValue:
    """A DECIMAL(n, 0) holding 10^(n-1): its precision is its declared one."""
    return ScalarValue.decimal128_i128(pow10_i256(n - 1).cast[DType.int128](), n, 0)


def test_limits() raises:
    # 37 + 37 digits at scale 0: max(37, 37) + 0 + 1 = 38 folds.
    var a37 = _digits(37)
    assert_true(Bool(decimal_fold_binary(BIN_ADD, a37, a37)), "38 digits fold")
    assert_true(Bool(decimal_fold_binary(BIN_SUB, a37, a37)), "38 digits fold")
    # 38 digits plus one is 39: DuckDB cuts it to 38 with an overflow check.
    # 10^37 + 1 fits 38 digits: it folds as DECIMAL(38, 0).
    var a38 = _digits(38)
    var sum38 = decimal_fold_binary(BIN_ADD, a38, _d(1, 1, 0))
    assert_true(Bool(sum38), "39 digits cut to 38 fold when the value fits")
    assert_equal(
        String(sum38.value()),
        String(
            ScalarValue.decimal128_i128(
                pow10_i256(37).cast[DType.int128]() + I128(1), 38, 0
            )
        ),
    )
    var diff38 = decimal_fold_binary(BIN_SUB, _d(1, 1, 0), a38)
    assert_true(Bool(diff38), "39 digits cut to 38 fold when the value fits")
    # ... and raises when it does not: 38 nines plus one is 10^38.
    var nines38 = _digits_value("99999999999999999999999999999999999999", 38, 0)
    assert_true(
        _refusal(BIN_ADD, nines38, _d(1, 1, 0)).find("Overflow in addition of DECIMAL(38)") >= 0,
        "38 nines + 1",
    )
    assert_true(
        _refusal(BIN_SUB, _d(-1, 1, 0), nines38).find("Overflow in subtraction of DECIMAL(38)") >= 0,
        "-1 - 38 nines",
    )
    # An operand that does not fit the cut type is a cast error before any sum:
    # 38 nines plus 0.5 is cut to DECIMAL(38, 1), and the 38 nines at scale 1
    # are 39 digits. DuckDB: "Could not cast value ... to DECIMAL(38,1)".
    var cast_message = _refusal(BIN_ADD, nines38, _d(5, 2, 1))
    assert_true(cast_message.find("Could not cast value") >= 0, cast_message)
    assert_true(cast_message.find("DECIMAL(38,1)") >= 0, cast_message)
    # A scale pushes the result past the limit the same way: 19 + 19.
    assert_true(
        Bool(decimal_fold_binary(BIN_ADD, _d(1, 19, 18), _d(1, 19, 18))),
        "p1 - s1 = 1: 1 + 18 + 1 = 20",
    )
    # 0.1234567890123456789012345678901234567 + 1: DuckDB gives DECIMAL(38, 37)
    # and keeps the scale.
    var frac = _digits_value("1234567890123456789012345678901234567", 38, 37)
    var one = decimal_fold_binary(BIN_ADD, frac, _i(1))
    assert_true(Bool(one), "scale kept when the width is cut to 38")
    assert_equal(
        String(one.value()),
        String(_digits_value("11234567890123456789012345678901234567", 38, 37)),
    )
    # Multiplication: 19 + 19 = 38 folds; 19 + 20 = 39 is cut to 38 and folds
    # when the value fits (10^18 * 10^19 = 10^37).
    var m19 = _digits(19)
    assert_true(Bool(decimal_fold_binary(BIN_MUL, m19, m19)), "38 digits fold")
    var cut = decimal_fold_binary(BIN_MUL, m19, _digits(20))
    assert_true(Bool(cut), "39 digits cut to 38 fold when the value fits")
    assert_equal(
        String(cut.value()),
        String(ScalarValue.decimal128_i128(pow10_i256(37).cast[DType.int128](), 38, 0)),
    )
    # A value larger than the precision it is declared with: DECIMAL(1, 0)
    # holding 10^36, times itself, needs 73 digits but would be DECIMAL(2, 0).
    var liar = ScalarValue.decimal128_i128(pow10_i256(36).cast[DType.int128](), 1, 0)
    assert_true(not decimal_fold_binary(BIN_MUL, liar, liar), "overflows its precision")


def test_a_result_wider_than_18_digits_from_narrow_operands_is_cut_to_18() raises:
    # 2 + 1234567890123456.78: DECIMAL(10, 0) + DECIMAL(18, 2) would be
    # DECIMAL(19, 2); both operands have 18 digits or fewer, so DuckDB gives
    # DECIMAL(18, 2).
    _expect(BIN_ADD, _i(2), _d(123456789012345678, 18, 2), 123456789012345878, 18, 2)
    _expect(BIN_ADD, _d(123456789012345678, 18, 2), _i(2), 123456789012345878, 18, 2)
    # 1234567890123456.78 + 1234567890123456.78.
    _expect(
        BIN_ADD, _d(123456789012345678, 18, 2), _d(123456789012345678, 18, 2),
        246913578024691356, 18, 2,
    )
    # 0.1 + 12345678901234567.1 and 0.1 - 99999999999999999.9.
    _expect(BIN_ADD, _d(1, 2, 1), _d(123456789012345671, 18, 1), 123456789012345672, 18, 1)
    _expect(BIN_SUB, _d(1, 2, 1), _d(999999999999999999, 18, 1), -999999999999999998, 18, 1)
    # An operand of 19 digits: no cut. 123456789012345678.9 + 1 is DECIMAL(20, 1).
    _expect(BIN_ADD, _d(1234567890123456789, 19, 1), _i(1), 1234567890123456799, 20, 1)
    # An INTEGER-typed 3000000000 is 19 digits: 3000000000 * 0.5 stays DECIMAL(21, 1).
    # 123456789.123456789 * 0.5: DECIMAL(18, 9) * DECIMAL(2, 1) is DECIMAL(20, 10): cut to 18.
    _expect(BIN_MUL, _d(123456789123456789, 18, 9), _d(5, 2, 1), 617283945617283945, 18, 10)
    # 0.000000000000001 * 1000000: DECIMAL(16, 15) * DECIMAL(10, 0).
    _expect(BIN_MUL, _d(1, 16, 15), _i(1000000), 1000000, 18, 15)
    # The scale condition of `*`: a result of scale 17 is cut, one of scale 18
    # is not. 0.00000001 * 0.000000001 is DECIMAL(9, 8) * DECIMAL(10, 9).
    _expect(BIN_MUL, _d(1, 9, 8), _d(1, 10, 9), 1, 18, 17)
    # 0.000000001 * 0.000000001 is DECIMAL(10, 9) * DECIMAL(10, 9): DECIMAL(20, 18).
    _expect(BIN_MUL, _d(1, 10, 9), _d(1, 10, 9), 1, 20, 18)
    # 1.000000001 * 1.000000001.
    _expect(BIN_MUL, _d(1000000001, 10, 9), _d(1000000001, 10, 9), 1000000002000000001, 20, 18)
    # 0.1 multiplied thirteen times: each step past 18 digits is cut to 18.
    var p = _d(1, 2, 1)
    for k in range(12):
        var next = decimal_fold_binary(BIN_MUL, p, _d(1, 2, 1))
        assert_true(Bool(next), "a power of 0.1")
        p = next.take()
    assert_equal(String(p), String(_d(1, 18, 13)))
    # A product of scale 38: 0.0000000000000000001 squared is DECIMAL(38, 38).
    _expect(BIN_MUL, _d(1, 20, 19), _d(1, 20, 19), 1, 38, 38)
    # A sum of scale 18 from operands of 18 digits is cut to 18: .123456789012345678 + .5
    _expect(BIN_ADD, _d(123456789012345678, 18, 18), _d(5, 1, 1), 623456789012345678, 18, 18)
    # A scale of 32 from two operands of 16 digits is not cut: DECIMAL(34, 32).
    _expect(BIN_MUL, _d(1, 17, 16), _d(1, 17, 16), 1, 34, 32)


def test_a_hugeint_sized_integer_takes_part_as_decimal_38() raises:
    # 9223372036854775808 + 0.5 and * 2.5: DuckDB gives DECIMAL(38, 1) (the
    # integer is a HUGEINT, DECIMAL(38, 0), and the result is cut to 38).
    var int_ = ScalarValue.decimal128_i128(I128(Int(Int64.MAX)) + I128(1), 38, 0)
    _expect_big(BIN_ADD, int_.copy(), _d(5, 2, 1), "92233720368547758085", 38, 1)
    _expect_big(BIN_MUL, int_.copy(), _d(25, 2, 1), "230584300921369395200", 38, 1)


def test_a_result_that_does_not_fit_its_cut_width_is_refused() raises:
    # 12345678.123 * 12345678.123: DECIMAL(11, 3) * DECIMAL(11, 3), cut to
    # DECIMAL(18, 6); the product 12345678123^2 is past 10^18.
    var m = _refusal(BIN_MUL, _d(12345678123, 11, 3), _d(12345678123, 11, 3))
    assert_true(m.find("Overflow in multiplication of DECIMAL(18)") >= 0, m)
    # 123456789.12345 * 1234567: 12345678912345 * 1234567 > 10^18.
    m = _refusal(BIN_MUL, _d(12345678912345, 14, 5), _i(1234567))
    assert_true(m.find("Overflow in multiplication of DECIMAL(18)") >= 0, m)
    # 1000000000 * 1000000000.5: DECIMAL(10, 0) * DECIMAL(11, 1), cut to 18.
    m = _refusal(BIN_MUL, _i(1000000000), _d(10000000005, 11, 1))
    assert_true(m.find("Overflow in multiplication of DECIMAL(18)") >= 0, m)
    # 99999999999999999.9 + 99999999999999999.9 and the subtraction of the
    # negative.
    m = _refusal(BIN_ADD, _d(999999999999999999, 18, 1), _d(999999999999999999, 18, 1))
    assert_true(m.find("Overflow in addition of DECIMAL(18)") >= 0, m)
    m = _refusal(BIN_SUB, _d(-999999999999999999, 18, 1), _d(999999999999999999, 18, 1))
    assert_true(m.find("Overflow in subtraction of DECIMAL(18)") >= 0, m)
    # The sum just under the limit folds: 10^17 - 1 + 10^17 - 1 at 18 digits.
    _expect(
        BIN_ADD, _d(499999999999999999, 18, 1), _d(499999999999999999, 18, 1),
        999999999999999998, 18, 1,
    )
    # 9999999999.9999999999 * 9999999999.9999999999: DECIMAL(20, 10) squared is
    # 40 digits, cut to 38, and the value has 40 digits.
    var big = _digits_value("99999999999999999999", 20, 10)
    m = _refusal(BIN_MUL, big, big)
    assert_true(m.find("Overflow in multiplication of DECIMAL(38)") >= 0, m)
    # A product with a scale past 38: 0.00000000000000000001 (scale 20) times a
    # scale-36 factor.
    m = _refusal(BIN_MUL, _d(1, 21, 20), _d(1, 37, 36))
    assert_true(m.find("Needed scale 56") >= 0, m)
    assert_true(m.find("Max scale is 38") >= 0, m)


def test_pairs_the_fold_does_not_cover() raises:
    assert_true(not decimal_fold_binary(BIN_ADD, _i(1), _i(2)), "two integers")
    assert_true(
        not decimal_fold_binary(BIN_ADD, _d(6, 3, 2), ScalarValue.from_float(0.5)),
        "a float",
    )
    assert_true(
        not decimal_fold_binary(BIN_ADD, ScalarValue.decimal128(0, 6), _d(1, 3, 2)),
        "a typeless decimal",
    )
    assert_true(not decimal_fold_binary(BIN_DIV, _d(6, 3, 2), _d(1, 3, 2)), "/")
    assert_true(not decimal_fold_binary(BIN_LT, _d(6, 3, 2), _d(1, 3, 2)), "<")
    assert_true(
        not decimal_fold_binary(BIN_ADD, _d(6, 3, 2), ScalarValue.from_bool(True)),
        "a bool",
    )


def test_negate() raises:
    var n = decimal_negate(_d(5, 4, 2))
    assert_true(Bool(n), "negate")
    assert_equal(String(n.value()), String(_d(-5, 4, 2)))
    var back = decimal_negate(_d(-65, 4, 3))
    assert_equal(String(back.value()), String(_d(65, 4, 3)))
    var zero = decimal_negate(_d(0, 2, 1))
    assert_equal(String(zero.value()), String(_d(0, 2, 1)))
    assert_true(not decimal_negate(_i(5)), "an integer is not this fold's")
    assert_true(not decimal_negate(ScalarValue.from_float(0.5)), "a float")


def _int(value: Int, precision: Int) -> ScalarValue:
    """An integer-typed constant: INTEGER is (10, 0), BIGINT (19, 0), HUGEINT
    (38, 0)."""
    return ScalarValue.decimal128_i128(I128(value), precision, 0)


def _int_expect(op: UInt8, a: ScalarValue, b: ScalarValue, value: Int, precision: Int) raises:
    var got = integer_fold_binary(op, a, b)
    assert_equal(String(got), String(_int(value, precision)))


def test_integer_arithmetic_keeps_the_integer_type() raises:
    # DuckDB: typeof(1 + 2) is INTEGER, 1 - 2 - 3 is INTEGER -4, 2147483648 + 0
    # BIGINT, - 2147483647 - 1 is INTEGER -2147483648.
    _int_expect(BIN_ADD, _int(1, 10), _int(2, 10), 3, 10)
    _int_expect(BIN_SUB, _int(1, 10), _int(2, 10), -1, 10)
    _int_expect(BIN_MUL, _int(2, 10), _int(3, 10), 6, 10)
    _int_expect(BIN_SUB, _int(-2147483647, 10), _int(1, 10), -2147483648, 10)
    _int_expect(BIN_ADD, _int(2147483647, 10), _int(-2147483647, 10), 0, 10)
    # One BIGINT operand makes a BIGINT, whatever the value.
    _int_expect(BIN_ADD, _int(3000000000, 19), _int(1, 10), 3000000001, 19)
    _int_expect(BIN_SUB, _int(3000000000, 19), _int(2999999999, 19), 1, 19)
    _int_expect(BIN_SUB, _int(-2147483648, 19), _int(1, 10), -2147483649, 19)
    _int_expect(BIN_MUL, _int(3000000000, 19), _int(3000000000, 19), 9000000000000000000, 19)
    # A HUGEINT operand makes a HUGEINT.
    var big = ScalarValue.decimal128_i128(I128(Int(Int64.MAX)) + I128(1), 38, 0)
    var sum = integer_fold_binary(BIN_ADD, _int(1, 10), big)
    assert_equal(
        String(sum),
        String(ScalarValue.decimal128_i128(I128(Int(Int64.MAX)) + I128(2), 38, 0)),
    )


def test_integer_arithmetic_raises_where_duckdb_does() raises:
    # No promotion: INTEGER + INTEGER past int32 is an error, as are BIGINT
    # past int64 and HUGEINT past 2^127 - 1.
    var m = _refusal_int(BIN_ADD, _int(2147483647, 10), _int(1, 10))
    assert_true(m.find("Overflow in addition of INT32") >= 0, m)
    m = _refusal_int(BIN_MUL, _int(2147483647, 10), _int(2, 10))
    assert_true(m.find("Overflow in multiplication of INT32") >= 0, m)
    m = _refusal_int(BIN_SUB, _int(2147483647, 10), _int(-1, 10))
    assert_true(m.find("Overflow in subtraction of INT32") >= 0, m)
    m = _refusal_int(BIN_SUB, _int(-2147483647, 10), _int(2, 10))
    assert_true(m.find("INT32") >= 0, m)
    m = _refusal_int(BIN_ADD, _int(Int(Int64.MAX), 19), _int(1, 10))
    assert_true(m.find("Overflow in addition of INT64") >= 0, m)
    m = _refusal_int(BIN_MUL, _int(Int(Int64.MAX), 19), _int(2, 10))
    assert_true(m.find("INT64") >= 0, m)
    var max128 = ScalarValue.decimal128_i128((I128(1) << I128(127)) - I128(1), 38, 0)
    m = _refusal_int(BIN_ADD, max128, _int(1, 10))
    assert_true(m.find("INT128") >= 0, m)
    # -2^127 is a HUGEINT (DuckDB: -170141183460469231731687303715884105727 - 1
    # is -170141183460469231731687303715884105728); one below it is not.
    m = _refusal_int(BIN_MUL, max128, _int(2, 10))
    assert_true(m.find("INT128") >= 0, m)
    var negmax = ScalarValue.decimal128_i128(-((I128(1) << I128(127)) - I128(1)), 38, 0)
    m = _refusal_int(BIN_SUB, negmax, _int(2, 10))
    assert_true(m.find("INT128") >= 0, m)


def _refusal_int(op: UInt8, a: ScalarValue, b: ScalarValue) -> String:
    try:
        _ = integer_fold_binary(op, a, b)
    except e:
        return String(e)
    return String("")


def test_integer_remainder_and_division_truncate() raises:
    # DuckDB: 7 % 4 is 3, -7 % 4 is -3, 7 % -4 is 3 (the sign of the dividend);
    # 7 // 2 is 3, -7 // 2 is -3, 7 // -2 is -3 (toward zero). Types are the
    # wider operand's.
    _int_expect(BIN_MOD, _int(7, 10), _int(4, 10), 3, 10)
    _int_expect(BIN_MOD, _int(-7, 10), _int(4, 10), -3, 10)
    _int_expect(BIN_MOD, _int(7, 10), _int(-4, 10), 3, 10)
    _int_expect(INTEGER_FOLD_IDIV, _int(7, 10), _int(2, 10), 3, 10)
    _int_expect(INTEGER_FOLD_IDIV, _int(-7, 10), _int(2, 10), -3, 10)
    _int_expect(INTEGER_FOLD_IDIV, _int(7, 10), _int(-2, 10), -3, 10)
    _int_expect(BIN_MOD, _int(3000000000, 19), _int(7, 10), 4, 19)
    _int_expect(INTEGER_FOLD_IDIV, _int(2147483647, 10), _int(1, 10), 2147483647, 10)
    # A zero divisor is NULL in DuckDB; it is refused here, and so is the one
    # quotient outside the type (INTEGER minimum over -1).
    var m = _refusal_int(BIN_MOD, _int(7, 10), _int(0, 10))
    assert_true(m.find("division by zero") >= 0, m)
    m = _refusal_int(INTEGER_FOLD_IDIV, _int(7, 10), _int(0, 10))
    assert_true(m.find("division by zero") >= 0, m)
    m = _refusal_int(INTEGER_FOLD_IDIV, _int(-2147483648, 10), _int(-1, 10))
    assert_true(m.find("INT32") >= 0, m)
    m = _refusal_int(BIN_MOD, _int(-2147483648, 10), _int(-1, 10))
    assert_true(m.find("INT32") >= 0, m)


def test_negating_an_integer_minimum_raises() raises:
    var neg = integer_negate(_int(5, 10))
    assert_equal(String(neg), String(_int(-5, 10)))
    assert_equal(String(integer_negate(_int(-5, 19))), String(_int(5, 19)))
    # -(-2147483647 - 1), the INT32 and INT64 minima, and the HUGEINT minimum.
    var m = _refusal_negate(_int(-2147483648, 10))
    assert_true(m.find("Overflow in negation of integer") >= 0, m)
    m = _refusal_negate(_int(-Int(Int64.MAX) - 1, 19))
    assert_true(m.find("Overflow in negation of integer") >= 0, m)
    var min128 = ScalarValue.decimal128_i128(-(I128(1) << I128(127)), 38, 0)
    m = _refusal_negate(min128)
    assert_true(m.find("Overflow in negation of integer") >= 0, m)
    # The maxima negate; the INT32 minimum as a BIGINT (-2147483648 the literal)
    # negates; the HUGEINT minimum is a value (-(2^127 - 1) - 1).
    assert_equal(
        String(integer_negate(_int(-2147483648, 19))), String(_int(2147483648, 19))
    )
    var max128 = ScalarValue.decimal128_i128((I128(1) << I128(127)) - I128(1), 38, 0)
    var held = integer_fold_binary(BIN_SUB, ScalarValue.decimal128_i128(-max128.decimal_value_i128(), 38, 0), _int(1, 10))
    assert_true(held.decimal_value_i128() == -(I128(1) << I128(127)), "-(2^127 - 1) - 1 is the HUGEINT minimum")


def _refusal_negate(a: ScalarValue) -> String:
    try:
        _ = integer_negate(a)
    except e:
        return String(e)
    return String("")


def main() raises:
    var suite = TestSuite()
    suite.test[test_add_and_subtract]()
    suite.test[test_multiply]()
    suite.test[test_integers_take_part_as_decimal_with_duckdbs_widths]()
    suite.test[test_limits]()
    suite.test[test_integer_arithmetic_keeps_the_integer_type]()
    suite.test[test_integer_arithmetic_raises_where_duckdb_does]()
    suite.test[test_integer_remainder_and_division_truncate]()
    suite.test[test_negating_an_integer_minimum_raises]()
    suite.test[test_a_result_wider_than_18_digits_from_narrow_operands_is_cut_to_18]()
    suite.test[test_a_hugeint_sized_integer_takes_part_as_decimal_38]()
    suite.test[test_a_result_that_does_not_fit_its_cut_width_is_refused]()
    suite.test[test_pairs_the_fold_does_not_cover]()
    suite.test[test_negate]()
    suite^.run()
