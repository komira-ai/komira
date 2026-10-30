# =============================================================================
# Constant folding of DECIMAL literals: + - * between decimal literals, and
# between a decimal and an integer literal, fold as DECIMAL with DuckDB's
# result type
# =============================================================================
#
# `_fold_expr` is the rule `fold_constants` applies at every expression site.
# Each expected literal below is the type and value DuckDB gives the same
# constant: the rows of types.tsv, written by the pinned DuckDB from
# `SELECT typeof(<expr>), <expr>` (komira_decimal_compare_conformance/oracle/
# types.sql), copied here so this package's test needs no oracle. The rules
# they show:
#   * `+` and `-`: scale max(s1, s2), precision max(p1 - s1, p2 - s2) +
#     max(s1, s2) + 1;
#   * `*`: scale s1 + s2, precision p1 + p2;
#   * an integer literal is DECIMAL(10, 0) when it fits INT32, else
#     DECIMAL(19, 0), and takes part like any decimal;
#   * a result that would need more than 38 digits is not folded (DuckDB
#     leaves DECIMAL there); the node stays for the runtime;
#   * `/`, a comparison, and a decimal with a float literal are not folded.
#
# What each test proves, and the defect it catches:
#   * test_decimal_bounds_fold_as_decimal: `0.06 - 0.01` is the DECIMAL(4, 2)
#     0.05 and `0.06 + 0.01` the DECIMAL(4, 2) 0.07 (Q6's discount bounds).
#     Catches a decimal pair folded through float64 (0.049999999999999996),
#     or left as an expression the scan filter then carries.
#   * test_decimal_multiplication_folds_with_summed_scale: `0.06 * 0.01`
#     (6, 4), `0.5 * 0.1` (4, 2), `0.1 * 0.1 * 0.1` (6, 3). Catches a product
#     with the wrong scale or precision.
#   * test_integer_literals_fold_with_decimal: `1 - 0.94`, `2 * 0.025`,
#     `24 + 0.5`, `3000000000 * 0.5`, a decimal minus an integer. Catches an
#     integer literal given the wrong width (INT32 against INT64), and an
#     operand-order slip in `-`.
#   * test_negative_and_mixed_sign_decimals_fold: `-0.06 + 0.01`,
#     `0.07 - 0.1`. Catches a sign lost in the 128-bit split of the literal.
#   * test_negating_a_decimal_literal_folds: described at the test.
#   * test_decimal_fold_leaves_what_duckdb_leaves: a result past 38 digits,
#     `/`, a comparison, and a decimal with a float literal stay expressions.
#     Catches a fold that overflows the 38-digit limit, or folds a pair the
#     rule does not cover.
#   * test_decimal_fold_walks_into_a_comparison: `a >= 0.06 - 0.01` folds the
#     bound inside the comparison. Catches a fold that stops at a comparison.

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_LITERAL,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_GE,
    BIN_LT,
    UN_NEGATE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_optimizer.optimizer_expr import _fold_expr
from komira_scalar_arithmetic.decimal_arith import I128, pow10_i256


def _dec(unscaled: Int, precision: Int, scale: Int) -> Expr:
    return Expr.literal(
        ScalarValue.decimal128_i128(I128(unscaled), precision, scale)
    )


def _int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _bin(op: UInt8, var a: Expr, var b: Expr) -> Expr:
    return Expr.binary(op, a^, b^)


def _expect(var folded: Expr, unscaled: Int, precision: Int, scale: Int) raises:
    """`folded` is the DECIMAL literal `unscaled` of type (precision, scale)."""
    assert_true(
        folded.tag == EXPR_LITERAL,
        "not folded to a literal: " + String(folded),
    )
    var want = ScalarValue.decimal128_i128(I128(unscaled), precision, scale)
    assert_equal(String(folded.literal_value()), String(want))


def test_decimal_bounds_fold_as_decimal() raises:
    # 0.06 is DECIMAL(3, 2) unscaled 6; 0.01 is DECIMAL(3, 2) unscaled 1.
    _expect(_fold_expr(_bin(BIN_SUB, _dec(6, 3, 2), _dec(1, 3, 2))), 5, 4, 2)
    _expect(_fold_expr(_bin(BIN_ADD, _dec(6, 3, 2), _dec(1, 3, 2))), 7, 4, 2)
    # DuckDB: 99999999999999999.99 + 0.01 is DECIMAL(20, 2) 100000000000000000.00.
    var big = ScalarValue.decimal128_i128(
        pow10_i256(19).cast[DType.int128]() - I128(1), 19, 2
    )
    var sum = _fold_expr(_bin(BIN_ADD, Expr.literal(big^), _dec(1, 3, 2)))
    assert_true(sum.tag == EXPR_LITERAL, "the wide sum folds")
    var want = ScalarValue.decimal128_i128(pow10_i256(19).cast[DType.int128](), 20, 2)
    assert_equal(String(sum.literal_value()), String(want))


def test_decimal_multiplication_folds_with_summed_scale() raises:
    _expect(_fold_expr(_bin(BIN_MUL, _dec(6, 3, 2), _dec(1, 3, 2))), 6, 6, 4)
    _expect(_fold_expr(_bin(BIN_MUL, _dec(5, 2, 1), _dec(1, 2, 1))), 5, 4, 2)
    var three = _bin(
        BIN_MUL,
        _bin(BIN_MUL, _dec(1, 2, 1), _dec(1, 2, 1)),
        _dec(1, 2, 1),
    )
    _expect(_fold_expr(three^), 1, 6, 3)


def test_integer_literals_fold_with_decimal() raises:
    # 1 - 0.94: INTEGER is DECIMAL(10, 0); max(10, 1) + 2 + 1 = 13.
    _expect(_fold_expr(_bin(BIN_SUB, _int(1), _dec(94, 3, 2))), 6, 13, 2)
    # 2 * 0.025: 0.025 is DECIMAL(4, 3) (its digits, with the leading zero);
    # precision 10 + 4, scale 3.
    _expect(_fold_expr(_bin(BIN_MUL, _int(2), _dec(25, 4, 3))), 50, 14, 3)
    # 24 + 0.5: max(10, 1) + 1 + 1 = 12.
    _expect(_fold_expr(_bin(BIN_ADD, _int(24), _dec(5, 2, 1))), 245, 12, 1)
    # An integer past INT32 is a BIGINT, DECIMAL(19, 0): 3000000000 * 0.5.
    _expect(
        _fold_expr(_bin(BIN_MUL, _int(3000000000), _dec(5, 2, 1))),
        15000000000,
        21,
        1,
    )
    # The integer on the right, and the order of a subtraction.
    _expect(_fold_expr(_bin(BIN_SUB, _dec(5, 2, 1), _int(1))), -5, 12, 1)
    _expect(_fold_expr(_bin(BIN_SUB, _int(1), _dec(5, 2, 1))), 5, 12, 1)


def test_negative_and_mixed_sign_decimals_fold() raises:
    _expect(_fold_expr(_bin(BIN_ADD, _dec(-6, 3, 2), _dec(1, 3, 2))), -5, 4, 2)
    _expect(_fold_expr(_bin(BIN_SUB, _dec(7, 3, 2), _dec(1, 2, 1))), -3, 4, 2)
    _expect(_fold_expr(_bin(BIN_MUL, _dec(-6, 3, 2), _dec(-5, 2, 1))), 30, 5, 3)


def test_negating_a_decimal_literal_folds() raises:
    """`-(0.06 - 0.01)`: the negation of a decimal literal keeps its type.
    Catches a unary minus left in the plan over a decimal literal, which no
    kernel evaluates as a constant."""
    _expect(
        _fold_expr(
            Expr.unary(UN_NEGATE, _bin(BIN_SUB, _dec(6, 3, 2), _dec(1, 3, 2)))
        ),
        -5,
        4,
        2,
    )
    _expect(_fold_expr(Expr.unary(UN_NEGATE, _dec(-65, 4, 3))), 65, 4, 3)


def test_decimal_fold_leaves_what_duckdb_leaves() raises:
    # Past 38 digits: 10^37 (38 digits, scale 0) + 1 needs 39.
    var wide = ScalarValue.decimal128_i128(pow10_i256(37).cast[DType.int128](), 38, 0)
    var e = _fold_expr(_bin(BIN_ADD, Expr.literal(wide^), _dec(1, 38, 0)))
    assert_true(e.tag == EXPR_BINARY_OP, "a 39-digit sum is not folded")
    # A product past 38 digits: precision 20 + 20.
    var m = _fold_expr(_bin(BIN_MUL, _dec(1, 20, 2), _dec(1, 20, 2)))
    assert_true(m.tag == EXPR_BINARY_OP, "a 40-digit product is not folded")
    # Division, and a comparison of two decimal literals.
    var d = _fold_expr(_bin(BIN_DIV, _dec(6, 3, 2), _dec(1, 3, 2)))
    assert_true(d.tag == EXPR_BINARY_OP, "decimal division is not folded")
    var c = _fold_expr(_bin(BIN_LT, _dec(6, 3, 2), _dec(7, 3, 2)))
    assert_true(c.tag == EXPR_BINARY_OP, "a decimal comparison is not folded")
    # A decimal with a float literal: not this rule's pair.
    var f = _fold_expr(
        _bin(BIN_ADD, _dec(6, 3, 2), Expr.literal(ScalarValue.from_float(0.5)))
    )
    assert_true(f.tag == EXPR_BINARY_OP, "decimal + float is not folded")


def test_decimal_fold_walks_into_a_comparison() raises:
    var e = _bin(
        BIN_GE,
        Expr.col_ref("d"),
        _bin(BIN_SUB, _dec(6, 3, 2), _dec(1, 3, 2)),
    )
    var folded = _fold_expr(e^)
    assert_true(folded.tag == EXPR_BINARY_OP, "the comparison stays")
    var want = ScalarValue.decimal128_i128(I128(5), 4, 2)
    assert_equal(
        String(folded),
        "BinaryOp(GE, ColRef(d), Literal(" + String(want) + "))",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_decimal_bounds_fold_as_decimal]()
    suite.test[test_decimal_multiplication_folds_with_summed_scale]()
    suite.test[test_integer_literals_fold_with_decimal]()
    suite.test[test_negative_and_mixed_sign_decimals_fold]()
    suite.test[test_negating_a_decimal_literal_folds]()
    suite.test[test_decimal_fold_leaves_what_duckdb_leaves]()
    suite.test[test_decimal_fold_walks_into_a_comparison]()
    suite^.run()
