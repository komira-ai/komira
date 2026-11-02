# =============================================================================
# A decimal literal facing a DECIMAL column binds as a DECIMAL, with DuckDB's
# type
# =============================================================================
#
# DuckDB reads `0.06` as DECIMAL(3, 2): its digits, with the leading zero, are
# the precision and the digits after the point the scale (`0.060` is
# DECIMAL(4, 3), `100.00` is DECIMAL(5, 2)). This binder read every such
# literal as FLOAT64, so `l_discount >= 0.06 - 0.01` compared a DECIMAL column
# with a float and folded the bounds to 0.049999999999999996 and
# 0.06999999999999999.
#
# Each case binds the WHERE predicate of `select k from t where <predicate>`
# against t(k INT64, v FLOAT64, i32 INT32, dc DECIMAL(12, 2), dw DECIMAL(30, 4))
# and compares the bound expression's text (no optimizer runs). The rule under
# test: a number literal, or a constant built from number literals with + - *
# and unary minus, that is the operand of a comparison whose other operand is
# a DECIMAL column, binds as DECIMAL literals; every other place a number
# literal appears is unchanged (FLOAT64).
#
# What each test proves, and the defect it catches:
#   * test_literal_facing_a_decimal_column_is_decimal: `dc < 0.065`, a
#     literal on the left, a negative one, an integer-valued `24.00`, a long
#     fraction. Catches a literal bound to FLOAT64, a wrong precision or
#     scale, a lost sign, a literal on the left bound differently.
#   * test_constant_arithmetic_facing_a_decimal_column_is_decimal:
#     `dc >= 0.06 - 0.01` (Q6's bound), `*`, `-` with an integer, unary
#     minus. Catches an operand of the arithmetic left FLOAT64.
#   * test_integer_literals_stay_integers: `dc < 24` keeps INT64 (the
#     comparison kernel rescales it exactly). Catches an integer rewritten.
#   * test_everything_else_stays_float: a FLOAT64 column, an integer column, a
#     select-list literal, arithmetic with a column, and a constant that holds
#     a column. Catches a literal made DECIMAL where no DECIMAL column faces
#     it (the evaluator has no DECIMAL arm for those).
#   * test_literals_past_38_digits_stay_float: a literal DuckDB cannot hold
#     as DECIMAL(38, s) stays FLOAT64. Catches an overflowing DECIMAL.
#   * test_a_minus_before_a_minus_keeps_the_value: `dc > - -0.5` is 0.5, as
#     DECIMAL(2, 1), not -0.5; also `-(-0.5)`, `- - 0.5`, `- -5.` and a triple
#     minus. Catches a negation that keeps the sign of the text it negates.
#   * test_literal_shapes: `5.` is DECIMAL(1, 0), `.5` DECIMAL(1, 1) and `00.5`
#     DECIMAL(3, 1), on either side of the comparison. Catches `5.` left
#     FLOAT64 and a leading point or zeros miscounted.
#   * test_exponent_literals_are_floats: `1e-2`, `2.5e1` and `1E2` face a
#     DECIMAL column as FLOAT64, as in DuckDB (DOUBLE). Catches an exponent
#     typed as a DECIMAL or refused.
#   * test_folded_constants_are_capped_like_duckdb: `2 + 1234567890123456.78`
#     is DECIMAL(18, 2), not (19, 2); `123456789.123456789 * 0.5` DECIMAL(18,
#     10); and `0.1234567890123456789012345678901234567 + 1` DECIMAL(38, 37)
#     rather than a FLOAT64. Catches the 18 and 38 digit caps missing.
#   * test_integer_subexpressions_fold_as_integers: `(1+2)*0.1` is the DECIMAL(12,
#     1) 0.3 (INTEGER times DECIMAL(2, 1)), `2*3*0.05` DECIMAL(13, 2), `(5-3)+0.07`
#     DECIMAL(13, 2); the integer width follows the type (a BIGINT difference
#     of 1, `-2147483648`) and an INTEGER overflow is an error. Catches an
#     integer-only sub-expression that sends the whole constant to float.
#   * test_integer_remainder_division_and_negation_in_a_constant: `0.1 + 0.2 +
#     7 % 4` is DECIMAL(12, 1) 3.3, `7 // 2 * 0.5` 1.5, `-7 % 4 + 0.5` -2.5;
#     `%` and `//` over a decimal, a zero divisor and the negation of an integer
#     minimum are refused. Catches `%` sending the constant to float, and a
#     negation that wraps.
#   * test_unary_plus_is_the_literal: `+0.5`, `- +0.5`, `+5.`, `+24`. Catches a
#     plus sign that is a syntax error.
#   * test_constants_duckdb_raises_on_are_refused: the binder raises, with
#     DuckDB's words, for `12345678.123 * 12345678.123` (overflow of
#     DECIMAL(18)), a sum of two 18-digit numbers past 18 digits, and a
#     product with a scale past 38. Catches a fold that keeps a value DuckDB
#     raises on, or turns it into a float.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import I128

from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import CteScope, _build_bind_scope
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _catalog() raises -> SqlCatalog:
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field.decimal128(String("dw"), 30, 4, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    return cat^


def _bound(sql_text: String) raises -> String:
    """The bound text of `sql_text`'s WHERE predicate, or `ERR: ` and the
    binder's message."""
    var cat = _catalog()
    try:
        var st = parse_sql(tokenize(sql_text))
        var scope = _build_bind_scope(
            st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
        )
        var prebound = List[Expr]()
        var p = _bind_scalar(
            st.query.where_pred.value(),
            scope.out_schema,
            scope,
            cat,
            CteScope(ParquetFacts()),
            prebound,
        )
        return String(p)
    except e:
        return "ERR: " + String(e)


def _selected(sql_text: String) raises -> String:
    """The bound text of the first select item."""
    var cat = _catalog()
    try:
        var st = parse_sql(tokenize(sql_text))
        var scope = _build_bind_scope(
            st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
        )
        var prebound = List[Expr]()
        var e = _bind_scalar(
            st.query.select_items[0].expr,
            scope.out_schema,
            scope,
            cat,
            CteScope(ParquetFacts()),
            prebound,
        )
        return String(e)
    except e:
        return "ERR: " + String(e)


def _d(hi: Int, lo: Int, precision: Int, scale: Int) -> String:
    return (
        "Literal(ScalarValue(decimal128("
        + String(precision)
        + ","
        + String(scale)
        + "), hi="
        + String(hi)
        + ", lo="
        + String(lo)
        + "))"
    )


def _w(predicate: String) -> String:
    return "select k from t where " + predicate


def test_literal_facing_a_decimal_column_is_decimal() raises:
    assert_equal(
        _bound(_w("dc < 0.065")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 65, 4, 3) + ")",
    )
    assert_equal(
        _bound(_w("dc = 0.06")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 6, 3, 2) + ")",
    )
    # Trailing zeros are digits: DuckDB reads 0.060 as DECIMAL(4, 3).
    assert_equal(
        _bound(_w("dc <= 0.060")),
        "BinaryOp(LE, ColRef(dc), " + _d(0, 60, 4, 3) + ")",
    )
    assert_equal(
        _bound(_w("dc > 24.00")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 2400, 4, 2) + ")",
    )
    assert_equal(
        _bound(_w("dc <> 100.50")),
        "BinaryOp(NE, ColRef(dc), " + _d(0, 10050, 5, 2) + ")",
    )
    # A negative literal keeps its type; the 128-bit payload is the sign
    # extension.
    assert_equal(
        _bound(_w("dc >= -0.5")),
        "BinaryOp(GE, ColRef(dc), " + _d(-1, -5, 2, 1) + ")",
    )
    # The literal on the left reads the same with the column on the left: the
    # evaluator compares a column with a literal on its right.
    assert_equal(
        _bound(_w("0.065 > dc")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 65, 4, 3) + ")",
    )
    assert_equal(
        _bound(_w("0.06 - 0.01 <= dc")),
        "BinaryOp(GE, ColRef(dc), " + _d(0, 5, 4, 2) + ")",
    )
    assert_equal(
        _bound(_w("0.065 = dc")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 65, 4, 3) + ")",
    )
    assert_equal(
        _bound(_w("0.065 <> dc")),
        "BinaryOp(NE, ColRef(dc), " + _d(0, 65, 4, 3) + ")",
    )
    assert_equal(
        _bound(_w("0.065 < dc")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 65, 4, 3) + ")",
    )
    assert_equal(
        _bound(_w("0.065 >= dc")),
        "BinaryOp(LE, ColRef(dc), " + _d(0, 65, 4, 3) + ")",
    )
    # A wider column.
    assert_equal(
        _bound(_w("dw < 0.00005")),
        "BinaryOp(LT, ColRef(dw), " + _d(0, 5, 6, 5) + ")",
    )


def test_constant_arithmetic_facing_a_decimal_column_is_decimal() raises:
    # The constant is folded where it is bound, as DECIMAL, with DuckDB's
    # result type (types.tsv of komira_decimal_compare_conformance: 0.06 - 0.01
    # and 0.06 + 0.01 are DECIMAL(4, 2)).
    assert_equal(
        _bound(_w("dc >= 0.06 - 0.01")),
        "BinaryOp(GE, ColRef(dc), " + _d(0, 5, 4, 2) + ")",
    )
    assert_equal(
        _bound(_w("dc <= 0.06 + 0.01")),
        "BinaryOp(LE, ColRef(dc), " + _d(0, 7, 4, 2) + ")",
    )
    assert_equal(
        _bound(_w("dc < 0.5 * 0.1")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 5, 4, 2) + ")",
    )
    # An integer literal in the constant takes part as DECIMAL(10, 0): 1 -
    # 0.94 is DECIMAL(13, 2).
    assert_equal(
        _bound(_w("dc > 1 - 0.94")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 6, 13, 2) + ")",
    )
    assert_equal(
        _bound(_w("dc > -0.06 + 0.01")),
        "BinaryOp(GT, ColRef(dc), " + _d(-1, -5, 4, 2) + ")",
    )
    # A parenthesised constant, and a negated one.
    assert_equal(
        _bound(_w("dc > (0.06 - 0.01) * 2")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 10, 14, 2) + ")",
    )
    assert_equal(
        _bound(_w("dc > -(0.06 - 0.01)")),
        "BinaryOp(GT, ColRef(dc), " + _d(-1, -5, 4, 2) + ")",
    )
    # BETWEEN is two comparisons; both bounds are decimal.
    assert_equal(
        _bound(_w("dc between 0.06 - 0.01 and 0.06 + 0.01")),
        "BinaryOp(AND, BinaryOp(GE, ColRef(dc), "
        + _d(0, 5, 4, 2)
        + "), BinaryOp(LE, ColRef(dc), "
        + _d(0, 7, 4, 2)
        + "))",
    )
    # IN is OR of =: every element is decimal.
    assert_equal(
        _bound(_w("dc in (0.06, 0.065)")),
        "BinaryOp(OR, BinaryOp(EQ, ColRef(dc), "
        + _d(0, 6, 3, 2)
        + "), BinaryOp(EQ, ColRef(dc), "
        + _d(0, 65, 4, 3)
        + "))",
    )
    # A constant whose DECIMAL result needs a scale past 38 is an error in
    # DuckDB: the binder refuses it (test_constants_duckdb_raises_on_are_refused).


def test_integer_literals_stay_integers() raises:
    assert_equal(
        _bound(_w("dc < 24")),
        "BinaryOp(LT, ColRef(dc), Literal(ScalarValue(int64, 24)))",
    )
    # On the left of the column the integer is swapped to the right with its
    # comparison flipped, and stays an integer.
    assert_equal(
        _bound(_w("24 > dc")),
        "BinaryOp(LT, ColRef(dc), Literal(ScalarValue(int64, 24)))",
    )
    assert_equal(
        _bound(_w("24 <= dc")),
        "BinaryOp(GE, ColRef(dc), Literal(ScalarValue(int64, 24)))",
    )


def test_everything_else_stays_float() raises:
    # A FLOAT64 column and an INT32 column face a float literal as before.
    assert_equal(
        _bound(_w("v < 0.065")),
        "BinaryOp(LT, ColRef(v), Literal(ScalarValue(float64, 0.065)))",
    )
    assert_equal(
        _bound(_w("0.5 < v")),
        "BinaryOp(LT, Literal(ScalarValue(float64, 0.5)), ColRef(v))",
    )
    assert_equal(
        _bound(_w("i32 < 0.5")),
        "BinaryOp(LT, ColRef(i32), Literal(ScalarValue(float64, 0.5)))",
    )
    # A literal in the select list, and arithmetic with a column.
    assert_equal(
        _selected("select 0.06 from t"),
        "Literal(ScalarValue(float64, 0.06))",
    )
    assert_equal(
        _selected("select dc * 0.5 from t"),
        "BinaryOp(MUL, ColRef(dc), Literal(ScalarValue(float64, 0.5)))",
    )
    # A constant that holds a column is not a constant.
    assert_equal(
        _bound(_w("dc < 0.5 + v")),
        "BinaryOp(LT, ColRef(dc), BinaryOp(ADD, Literal(ScalarValue(float64,"
        " 0.5)), ColRef(v)))",
    )
    # A division is DOUBLE in DuckDB: it stays float.
    assert_equal(
        _bound(_w("dc < 1.0 / 4.0")),
        "BinaryOp(LT, ColRef(dc), BinaryOp(DIV, Literal(ScalarValue(float64,"
        " 1.0)), Literal(ScalarValue(float64, 4.0))))",
    )


def test_literals_past_38_digits_stay_float() raises:
    var bound = _bound(_w("dc < 0.12345678901234567890123456789012345678901"))
    assert_true(bound.find("float64") >= 0, bound)
    assert_true(bound.find("decimal128") < 0, bound)


def test_a_minus_before_a_minus_keeps_the_value() raises:
    # `- -0.5` is 0.5: DECIMAL(2, 1), unscaled 5.
    assert_equal(
        _bound(_w("dc > - -0.5")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 5, 2, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc > -(-0.5)")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 5, 2, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc > - - 0.5")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 5, 2, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc > - -5.")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 5, 1, 0) + ")",
    )
    # Three minus signs: -0.5.
    assert_equal(
        _bound(_w("dc > - - -0.5")),
        "BinaryOp(GT, ColRef(dc), " + _d(-1, -5, 2, 1) + ")",
    )
    # The literal on the left.
    assert_equal(
        _bound(_w("- -0.5 < dc")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 5, 2, 1) + ")",
    )


def test_literal_shapes() raises:
    assert_equal(
        _bound(_w("dc < 5.")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 5, 1, 0) + ")",
    )
    assert_equal(
        _bound(_w("dc < .5")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 5, 1, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc < 00.5")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 5, 3, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc <= -5.")),
        "BinaryOp(LE, ColRef(dc), " + _d(-1, -5, 1, 0) + ")",
    )
    assert_equal(
        _bound(_w("5. > dc")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 5, 1, 0) + ")",
    )
    assert_equal(
        _bound(_w(".5 >= dc")),
        "BinaryOp(LE, ColRef(dc), " + _d(0, 5, 1, 1) + ")",
    )
    # A constant built from them.
    assert_equal(
        _bound(_w("dc < 5. + .5")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 55, 3, 1) + ")",
    )
    # A FLOAT64 column keeps them as floats.
    assert_equal(
        _bound(_w("v < 5.")),
        "BinaryOp(LT, ColRef(v), Literal(ScalarValue(float64, 5.0)))",
    )


def test_exponent_literals_are_floats() raises:
    assert_equal(
        _bound(_w("dc < 1e-2")),
        "BinaryOp(LT, ColRef(dc), Literal(ScalarValue(float64, 0.01)))",
    )
    assert_equal(
        _bound(_w("dc >= 2.5e1")),
        "BinaryOp(GE, ColRef(dc), Literal(ScalarValue(float64, 25.0)))",
    )
    assert_equal(
        _bound(_w("dc = 1E2")),
        "BinaryOp(EQ, ColRef(dc), Literal(ScalarValue(float64, 100.0)))",
    )
    assert_equal(
        _bound(_w("dc < -1e-1")),
        "BinaryOp(LT, ColRef(dc), Literal(ScalarValue(float64, -0.1)))",
    )
    assert_equal(
        _bound(_w("1e-2 < dc")),
        "BinaryOp(GT, ColRef(dc), Literal(ScalarValue(float64, 0.01)))",
    )


def _dec_digits(digits: String, precision: Int, scale: Int) -> String:
    """The bound text of the DECIMAL whose unscaled digits are `digits`."""
    var n = I128(0)
    for b in digits.as_bytes():
        n = n * I128(10) + I128(Int(b - UInt8(ord("0"))))
    return "Literal(" + String(ScalarValue.decimal128_i128(n, precision, scale)) + ")"


def test_folded_constants_are_capped_like_duckdb() raises:
    # DECIMAL(10, 0) + DECIMAL(18, 2) is DECIMAL(19, 2) uncapped; DuckDB cuts
    # it to DECIMAL(18, 2).
    assert_equal(
        _bound(_w("dc > 2 + 1234567890123456.78")),
        "BinaryOp(GT, ColRef(dc), "
        + _d(0, 123456789012345878, 18, 2)
        + ")",
    )
    assert_equal(
        _bound(_w("dc > 123456789.123456789 * 0.5")),
        "BinaryOp(GT, ColRef(dc), "
        + _d(0, 617283945617283945, 18, 10)
        + ")",
    )
    assert_equal(
        _bound(_w("dc > 0.000000001 * 0.000000001")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 1, 20, 18) + ")",
    )
    # A result of more than 38 digits is cut to 38 and kept when the value
    # fits: DECIMAL(38, 37).
    assert_equal(
        _bound(_w("dc > 0.1234567890123456789012345678901234567 + 1")),
        "BinaryOp(GT, ColRef(dc), "
        + _dec_digits("11234567890123456789012345678901234567", 38, 37)
        + ")",
    )


def test_constants_duckdb_raises_on_are_refused() raises:
    var product = _bound(_w("dc < 12345678.123 * 12345678.123"))
    assert_true(product.startswith("ERR: "), product)
    assert_true(product.find("Overflow in multiplication of DECIMAL(18)") >= 0, product)
    var sum = _bound(_w("dc < 99999999999999999.9 + 99999999999999999.9"))
    assert_true(sum.find("Overflow in addition of DECIMAL(18)") >= 0, sum)
    var scale = _bound(
        _w("dc < 0.1234567890123456789 * 0.1234567890123456789012345")
    )
    assert_true(scale.find("Needed scale 44") >= 0, scale)
    # On the left of the column it is the same comparison.
    var left = _bound(_w("12345678.123 * 12345678.123 > dc"))
    assert_true(left.find("Overflow in multiplication of DECIMAL(18)") >= 0, left)
    # A constant that is not facing a DECIMAL column is not this rule's.
    var float_col = _bound(_w("v < 12345678.123 * 12345678.123"))
    assert_true(float_col.startswith("ERR: ") == False, float_col)


def test_integer_subexpressions_fold_as_integers() raises:
    # DuckDB types 1 + 2 as INTEGER, so (1 + 2) * 0.1 is INTEGER * DECIMAL(2, 1)
    # = DECIMAL(12, 1) 0.3 (not the float 0.30000000000000004).
    assert_equal(
        _bound(_w("dc = (1+2)*0.1")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 3, 12, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc = 2*3*0.05")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 30, 13, 2) + ")",
    )
    assert_equal(
        _bound(_w("dc = 0.1*(1+2)")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 3, 12, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc < (5-3)+0.07")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 207, 13, 2) + ")",
    )
    # The width follows the integer type, not the value: a BIGINT 3000000000
    # minus 2999999999 is a BIGINT 1, and -2147483648 is a BIGINT too.
    assert_equal(
        _bound(_w("dc = (3000000000-2999999999)+0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 15, 21, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc = -2147483648 + 0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(-1, -21474836475, 21, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc = - 2147483647 - 1 + 0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(-1, -21474836475, 12, 1) + ")",
    )
    # Integer overflow is an error in DuckDB, not a promotion.
    var over = _bound(_w("dc = (2147483647+1)*0.1"))
    assert_true(over.startswith("ERR: "), over)
    assert_true(over.find("Overflow in addition of INT32") >= 0, over)
    var times = _bound(_w("dc = (2147483647*2)*0.1"))
    assert_true(times.find("Overflow in multiplication of INT32") >= 0, times)
    # A division is DOUBLE: the constant stays a float expression.
    var div = _bound(_w("dc = (1/2)+0.1"))
    assert_true(div.find("float64") >= 0, div)
    assert_true(div.find("decimal128") < 0, div)


def test_unary_plus_is_the_literal() raises:
    assert_equal(
        _bound(_w("dc > +0.5")),
        "BinaryOp(GT, ColRef(dc), " + _d(0, 5, 2, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc < - +0.5")),
        "BinaryOp(LT, ColRef(dc), " + _d(-1, -5, 2, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc < +5.")),
        "BinaryOp(LT, ColRef(dc), " + _d(0, 5, 1, 0) + ")",
    )
    assert_equal(
        _bound(_w("dc < +24")),
        "BinaryOp(LT, ColRef(dc), Literal(ScalarValue(int64, 24)))",
    )


def test_integer_remainder_division_and_negation_in_a_constant() raises:
    # `7 % 4` is the INTEGER 3, so `0.1 + 0.2 + 7 % 4` is DECIMAL(12, 1) 3.3.
    assert_equal(
        _bound(_w("dc = 0.1 + 0.2 + 7 % 4")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 33, 12, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc = 7 // 2 * 0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 15, 12, 1) + ")",
    )
    assert_equal(
        _bound(_w("dc = -7 % 4 + 0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(-1, -25, 12, 1) + ")",
    )
    # Over a decimal operand DuckDB's % is exact decimal arithmetic: refused.
    var dec = _bound(_w("dc = 0.5 % 2"))
    assert_true(dec.startswith("ERR: "), dec)
    assert_true(dec.find("not supported") >= 0, dec)
    var idiv = _bound(_w("dc = 7.5 // 2"))
    assert_true(idiv.find("not supported") >= 0, idiv)
    # A zero divisor is NULL in DuckDB: refused.
    var zero = _bound(_w("dc = (7 % 0) + 0.5"))
    assert_true(zero.find("division by zero") >= 0, zero)
    # Negating an integer minimum raises.
    var neg32 = _bound(_w("dc = -(-2147483647 - 1) + 0.5"))
    assert_true(neg32.find("Overflow in negation of integer") >= 0, neg32)
    var neg64 = _bound(_w("dc = -(-9223372036854775807 - 1) + 0.5"))
    assert_true(neg64.find("Overflow in negation of integer") >= 0, neg64)
    # -2147483648 is a BIGINT: its negation is 2147483648, fine.
    assert_equal(
        _bound(_w("dc = -(-2147483648) + 0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(0, 21474836485, 21, 1) + ")",
    )


def test_integers_past_bigint_are_hugeint_decimals() raises:
    # DuckDB types an integer past BIGINT HUGEINT, DECIMAL(38, 0) against a
    # DECIMAL column (the conformance comparisons of 99999999999999999999 pin
    # the answers): 99999999999999999999 is 5 * 2^64 + 7766279631452241919.
    assert_equal(
        _bound(_w("dc < 99999999999999999999")),
        "BinaryOp(LT, ColRef(dc), " + _d(5, 7766279631452241919, 38, 0) + ")",
    )
    # HUGEINT's maximum 2^127 - 1 is the last one that types; 2^127 is past it
    # and is refused by name, as every integer past BIGINT is outside the one
    # shape served.
    assert_equal(
        _bound(_w("dc <= 170141183460469231731687303715884105727")),
        "BinaryOp(LE, ColRef(dc), " + _d(9223372036854775807, -1, 38, 0) + ")",
    )
    var past = _bound(_w("dc <= 170141183460469231731687303715884105728"))
    assert_true(past.startswith("ERR: SQL not supported: "), past)
    assert_true(
        past.find("the integer literal 170141183460469231731687303715884105728 is past BIGINT")
        >= 0,
        past,
    )
    # Negated, the literal is HUGEINT's negation; on the left of the column
    # the comparison swaps first.
    assert_equal(
        _bound(_w("dc > -99999999999999999999")),
        "BinaryOp(GT, ColRef(dc), " + _d(-6, -7766279631452241919, 38, 0) + ")",
    )
    assert_equal(
        _bound(_w("-170141183460469231731687303715884105727 < dc")),
        "BinaryOp(GT, ColRef(dc), " + _d(-9223372036854775808, 1, 38, 0) + ")",
    )
    var neg_past = _bound(_w("dc > -170141183460469231731687303715884105728"))
    assert_true(neg_past.startswith("ERR: SQL not supported: "), neg_past)
    assert_true(
        neg_past.find("the integer literal 170141183460469231731687303715884105728 is past BIGINT")
        >= 0,
        neg_past,
    )
    # HUGEINT arithmetic overflows like DuckDB's (conformance errors.sql: the
    # sum, product and difference of the maximum raise).
    var sum = _bound(_w("dc = (170141183460469231731687303715884105727 + 1)*0.1"))
    assert_true(sum.find("Overflow in addition of INT128") >= 0, sum)


def test_a_negated_expression_constant() raises:
    # An integer expression negates as an integer: -(1+2) is the INTEGER -3,
    # so -(1+2) + 0.5 is DECIMAL(12, 1) -2.5 (as -7 % 4 + 0.5 is).
    assert_equal(
        _bound(_w("dc = -(1+2) + 0.5")),
        "BinaryOp(EQ, ColRef(dc), " + _d(-1, -25, 12, 1) + ")",
    )
    # A decimal one negates as a decimal, and a number constant on the left
    # of the column swaps: -(1 + 2.5) < dc is dc > -3.5.
    assert_equal(
        _bound(_w("-(1+2.5) < dc")),
        "BinaryOp(GT, ColRef(dc), " + _d(-1, -35, 12, 1) + ")",
    )
    # A division is DOUBLE: the negated constant keeps its float binding.
    var div = _bound(_w("dc < -(1.5/2)"))
    assert_true(div.find("float64") >= 0, div)
    assert_true(div.find("decimal128") < 0, div)


def main() raises:
    var suite = TestSuite()
    suite.test[test_literal_facing_a_decimal_column_is_decimal]()
    suite.test[test_constant_arithmetic_facing_a_decimal_column_is_decimal]()
    suite.test[test_integer_literals_stay_integers]()
    suite.test[test_everything_else_stays_float]()
    suite.test[test_literals_past_38_digits_stay_float]()
    suite.test[test_a_minus_before_a_minus_keeps_the_value]()
    suite.test[test_literal_shapes]()
    suite.test[test_exponent_literals_are_floats]()
    suite.test[test_folded_constants_are_capped_like_duckdb]()
    suite.test[test_constants_duckdb_raises_on_are_refused]()
    suite.test[test_integer_subexpressions_fold_as_integers]()
    suite.test[test_unary_plus_is_the_literal]()
    suite.test[test_integer_remainder_division_and_negation_in_a_constant]()
    suite.test[test_integers_past_bigint_are_hugeint_decimals]()
    suite.test[test_a_negated_expression_constant]()
    suite^.run()
