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
# DECIMAL(4,2), 99999999999999999.99 + 0.01 DECIMAL(20,2).
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
#   * test_limits: exactly 38 digits folds, 39 does not, for `+`, `-` and `*`;
#     a value past the precision it is declared with does not. Catches a limit
#     off by one and a result that overflows its precision.
#   * test_pairs_the_fold_does_not_cover: two integers, a float, a typeless
#     decimal, `/`, a comparison, a non-literal. Catches a pair folded by a
#     rule that does not own it.
#   * test_negate: the type is kept, the sign flips, zero stays zero, and a
#     non-decimal gives None.

from std.testing import TestSuite, assert_equal, assert_true

from komira_decimal_literal.decimal_literal import (
    decimal_fold_binary,
    decimal_negate,
)
from komira_plan_expr.expr import BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_LT
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
    # INT32 edges: 10 digits; one past: 19.
    _expect(BIN_ADD, _i(2147483647), _d(5, 2, 1), 21474836475, 12, 1)
    _expect(BIN_ADD, _i(-2147483648), _d(5, 2, 1), -21474836475, 12, 1)
    _expect(BIN_ADD, _i(2147483648), _d(5, 2, 1), 21474836485, 21, 1)
    _expect(BIN_ADD, _i(-2147483649), _d(5, 2, 1), -21474836485, 21, 1)
    # 3000000000 * 0.5: DECIMAL(19, 0) * DECIMAL(2, 1).
    _expect(BIN_MUL, _i(3000000000), _d(5, 2, 1), 15000000000, 21, 1)


def _digits(n: Int) raises -> ScalarValue:
    """A DECIMAL(n, 0) holding 10^(n-1): its precision is its declared one."""
    return ScalarValue.decimal128_i128(pow10_i256(n - 1).cast[DType.int128](), n, 0)


def test_limits() raises:
    # 37 + 37 digits at scale 0: max(37, 37) + 0 + 1 = 38 folds; 38 + 1 digit: 39 does not.
    var a37 = _digits(37)
    assert_true(Bool(decimal_fold_binary(BIN_ADD, a37, a37)), "38 digits fold")
    assert_true(Bool(decimal_fold_binary(BIN_SUB, a37, a37)), "38 digits fold")
    var a38 = _digits(38)
    assert_true(not decimal_fold_binary(BIN_ADD, a38, _d(1, 1, 0)), "39 digits")
    assert_true(not decimal_fold_binary(BIN_SUB, _d(1, 1, 0), a38), "39 digits")
    # A scale pushes the result past the limit the same way: 19 + 19.
    assert_true(
        Bool(decimal_fold_binary(BIN_ADD, _d(1, 19, 18), _d(1, 19, 18))),
        "p1 - s1 = 1: 1 + 18 + 1 = 20",
    )
    # Multiplication: 19 + 19 = 38 folds; 19 + 20 = 39 does not.
    var m19 = _digits(19)
    assert_true(Bool(decimal_fold_binary(BIN_MUL, m19, m19)), "38 digits fold")
    assert_true(not decimal_fold_binary(BIN_MUL, m19, _digits(20)), "39")
    # A value larger than the precision it is declared with: DECIMAL(1, 0)
    # holding 10^36, times itself, needs 73 digits but would be DECIMAL(2, 0).
    var liar = ScalarValue.decimal128_i128(pow10_i256(36).cast[DType.int128](), 1, 0)
    assert_true(not decimal_fold_binary(BIN_MUL, liar, liar), "overflows its precision")


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


def main() raises:
    var suite = TestSuite()
    suite.test[test_add_and_subtract]()
    suite.test[test_multiply]()
    suite.test[test_integers_take_part_as_decimal_with_duckdbs_widths]()
    suite.test[test_limits]()
    suite.test[test_pairs_the_fold_does_not_cover]()
    suite.test[test_negate]()
    suite^.run()
