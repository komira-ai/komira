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

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr

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
    # A constant whose DECIMAL result would need more than 38 digits stays
    # float.
    var wide = _bound(
        _w("dc < 0.1234567890123456789 * 0.1234567890123456789012345")
    )
    assert_true(wide.find("float64") >= 0, wide)
    assert_true(wide.find("decimal128") < 0, wide)


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


def main() raises:
    var suite = TestSuite()
    suite.test[test_literal_facing_a_decimal_column_is_decimal]()
    suite.test[test_constant_arithmetic_facing_a_decimal_column_is_decimal]()
    suite.test[test_integer_literals_stay_integers]()
    suite.test[test_everything_else_stays_float]()
    suite.test[test_literals_past_38_digits_stay_float]()
    suite^.run()
