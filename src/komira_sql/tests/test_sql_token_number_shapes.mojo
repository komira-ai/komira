# =============================================================================
# Number literals: `5.`, `.5`, `00.5` and exponents
# =============================================================================
#
# DuckDB reads `5.` as DECIMAL(1, 0), `.5` as DECIMAL(1, 1), `00.5` as
# DECIMAL(3, 1), and any literal with an exponent (`1e-2`, `2.5E1`, `1.e2`) as
# a DOUBLE. The tokenizer returns each as a FLOAT token whose `text` holds the
# digits as written, which the binder types a DECIMAL from; an exponent literal
# keeps its text too, and the binder leaves it a float.
#
# What each test proves, and the defect it catches:
#   * test_a_trailing_or_leading_point_is_a_float: `5.` before a space, a
#     comma, a parenthesis, an operator and the end; `.5` at the start, after a
#     space, a parenthesis and an operator; `00.5`. Catches `5.` lexed as INT
#     and DOT, a leading point lexed as DOT, and a lost text.
#   * test_a_point_that_belongs_to_a_name_is_still_a_dot: `t.a`, `t1.a`, `x1.5`
#     (a name then a dot then digits), `1.x`, `1..2`. Catches a qualifier's
#     dot swallowed into a number.
#   * test_exponents: values and text of `1e-2`, `2.5e1`, `1E2`, `1.e2`,
#     `5e0`, `1.5e-3`, `0.1e1`, `1e22` and `1e-22`, each exactly the double a
#     plain decimal spelling of the same number reads as. Catches an exponent
#     applied to the wrong side, a sign dropped, a rounding in the digits.
#   * test_an_e_that_is_not_an_exponent: `1e`, `1e+`, `1ex` are an INT and a
#     name. Catches an exponent taken without digits.
#   * test_an_exponent_is_the_nearest_double: `1e100`, `1e-30`, `1.5e300`, the
#     largest double, a mantissa past 2^53 (with the tie that rounds to even), the
#     smallest normal and subnormal; past the double range is refused. Catches a
#     number refused that DuckDB reads, and a value one ulp off the nearest
#     double.
#   * test_a_literal_of_more_than_38_digits_is_the_nearest_double: DuckDB reads
#     it as a DOUBLE. Catches a digit-by-digit Float64 sum.
#   * test_a_decimal_converts_like_duckdbs_decimal_to_double: `123.456`,
#     `2.675` and the like are the nearest double; a mantissa past 2^53
#     (`90071992547409.93`) is converted in two parts, as DuckDB's cast does.
#     Catches a sum of two rounded parts that lands one ulp away.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_sql.sql_token import (
    TK_COMMA,
    TK_DOT,
    TK_EOF,
    TK_FLOAT,
    TK_IDENT,
    TK_INT,
    TK_LPAREN,
    TK_MINUS,
    TK_PLUS,
    TK_RPAREN,
    TK_STAR,
    tokenize,
)


def _assert_kinds(sql: String, expected: List[Int]) raises:
    var toks = tokenize(sql)
    assert_equal(len(toks), len(expected), "token count for: " + sql)
    for i in range(len(expected)):
        assert_equal(Int(toks[i].kind), expected[i], "token " + String(i) + " of: " + sql)


def _float(sql: String, text: String, value: Float64) raises:
    var toks = tokenize(sql)
    assert_equal(len(toks), 2, "token count for: " + sql)
    assert_equal(Int(toks[0].kind), Int(TK_FLOAT), "kind of: " + sql)
    assert_equal(toks[0].text, text, "text of: " + sql)
    assert_equal(toks[0].float_val, value, "value of: " + sql)


def test_a_trailing_or_leading_point_is_a_float() raises:
    _float("5.", "5.", 5.0)
    _float(".5", ".5", 0.5)
    _float("00.5", "00.5", 0.5)
    _float("100.", "100.", 100.0)
    _assert_kinds("5. ", [Int(TK_FLOAT), Int(TK_EOF)])
    _assert_kinds("5.,6.", [Int(TK_FLOAT), Int(TK_COMMA), Int(TK_FLOAT), Int(TK_EOF)])
    _assert_kinds("(5.)", [Int(TK_LPAREN), Int(TK_FLOAT), Int(TK_RPAREN), Int(TK_EOF)])
    _assert_kinds("5.+.5", [Int(TK_FLOAT), Int(TK_PLUS), Int(TK_FLOAT), Int(TK_EOF)])
    _assert_kinds("5.*2", [Int(TK_FLOAT), Int(TK_STAR), Int(TK_INT), Int(TK_EOF)])
    _assert_kinds("(.5)", [Int(TK_LPAREN), Int(TK_FLOAT), Int(TK_RPAREN), Int(TK_EOF)])
    _assert_kinds("-.5", [Int(TK_MINUS), Int(TK_FLOAT), Int(TK_EOF)])
    _assert_kinds("select .5", [Int(TK_IDENT), Int(TK_FLOAT), Int(TK_EOF)])
    var toks = tokenize("select 5. from t")
    assert_equal(Int(toks[1].kind), Int(TK_FLOAT))
    assert_equal(toks[1].text, "5.")
    assert_equal(toks[2].text, "from")


def test_a_point_that_belongs_to_a_name_is_still_a_dot() raises:
    _assert_kinds("t.a", [Int(TK_IDENT), Int(TK_DOT), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("t1.a", [Int(TK_IDENT), Int(TK_DOT), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("x1.5", [Int(TK_IDENT), Int(TK_DOT), Int(TK_INT), Int(TK_EOF)])
    _assert_kinds(")..5", [Int(TK_RPAREN), Int(TK_DOT), Int(TK_FLOAT), Int(TK_EOF)])
    _assert_kinds("1.x", [Int(TK_INT), Int(TK_DOT), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("1..2", [Int(TK_INT), Int(TK_DOT), Int(TK_FLOAT), Int(TK_EOF)])


def test_exponents() raises:
    _float("1e-2", "1e-2", 0.01)
    _float("2.5e1", "2.5e1", 25.0)
    _float("1E2", "1E2", 100.0)
    _float("1.e2", "1.e2", 100.0)
    _float("5e0", "5e0", 5.0)
    _float("1.5e-3", "1.5e-3", 0.0015)
    _float("0.1e1", "0.1e1", 1.0)
    _float("1e+2", "1e+2", 100.0)
    _float("1e22", "1e22", 1e22)
    _float("1e-22", "1e-22", 1e-22)
    _float("123456789012345e-15", "123456789012345e-15", 0.123456789012345)
    _float(".5e1", ".5e1", 5.0)


def test_an_e_that_is_not_an_exponent() raises:
    _assert_kinds("1e", [Int(TK_INT), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("1e+", [Int(TK_INT), Int(TK_IDENT), Int(TK_PLUS), Int(TK_EOF)])
    _assert_kinds("1ex", [Int(TK_INT), Int(TK_IDENT), Int(TK_EOF)])
    _assert_kinds("1e-x", [Int(TK_INT), Int(TK_IDENT), Int(TK_MINUS), Int(TK_IDENT), Int(TK_EOF)])


def _refused(sql: String) -> Bool:
    try:
        _ = tokenize(sql)
    except:
        return True
    return False


def test_an_exponent_is_the_nearest_double() raises:
    # Every number with an exponent is the double nearest to its digits (ties
    # to even), whatever its length or exponent: the shapes a one-multiply rule
    # cannot do, and the largest double.
    _float("1e100", "1e100", 1e100)
    _float("1e-30", "1e-30", 1e-30)
    _float("1.5e300", "1.5e300", 1.5e300)
    _float("1.7976931348623157e308", "1.7976931348623157e308", 1.7976931348623157e308)
    _float("123456789012345678e0", "123456789012345678e0", 123456789012345678.0)
    _float("9007199254740993e0", "9007199254740993e0", 9007199254740992.0)
    _float("9007199254740995e0", "9007199254740995e0", 9007199254740996.0)
    _float("2.2250738585072014e-308", "2.2250738585072014e-308", 2.2250738585072014e-308)
    # 4.9e-324 rounds to the smallest subnormal, 2^-1074.
    _float("4.9e-324", "4.9e-324", bitcast[DType.float64](UInt64(1)))
    _float("1e23", "1e23", 1e23)
    _float("12e35", "12e35", 12e35)
    _float("0.1234567890123456789012345e2", "0.1234567890123456789012345e2", 12.34567890123456789012345)
    # Past the double range there is no number to return.
    assert_true(_refused("1e999"), "1e999")
    assert_true(_refused("1e-999"), "1e-999")
    assert_true(_refused("1.7976931348623159e308"), "just past DBL_MAX")


def test_a_literal_of_more_than_38_digits_is_the_nearest_double() raises:
    # DuckDB reads a literal of more than 38 digits as a DOUBLE.
    _float(
        "0.1234567890123456789012345678901234567890",
        "0.1234567890123456789012345678901234567890",
        0.1234567890123456789012345678901234567890,
    )
    _float(
        "1234567890123456789012345678901234567890.5",
        "1234567890123456789012345678901234567890.5",
        1.2345678901234568e39,
    )
    _float(
        "100000000000000000000000000000000000001.0",
        "100000000000000000000000000000000000001.0",
        1e38,
    )


def test_a_decimal_converts_like_duckdbs_decimal_to_double() raises:
    # A literal with a point and at most 38 digits is a DECIMAL in DuckDB, and a
    # DECIMAL meets a DOUBLE by DuckDB's cast: a mantissa of at most 2^53 (or no
    # fraction) is one correctly rounded division; a larger one is its integer
    # part plus its fraction part divided apart. Both are the nearest double for
    # these.
    _float("0.07", "0.07", 0.07)
    _float("123.456", "123.456", 123.456)
    _float("1234.5678", "1234.5678", 1234.5678)
    _float("2.675", "2.675", 2.675)
    _float("8.41", "8.41", 8.41)
    _float("0.1234567890123456", "0.1234567890123456", 0.1234567890123456)
    _float("0.30000000000000004", "0.30000000000000004", 0.30000000000000004)
    # 2^53 + 1 hundredths: divided as one double the quotient would be
    # 90071992547409.92; apart it is 90071992547409 + 0.93, which rounds to
    # 90071992547409.9375.
    _float("90071992547409.93", "90071992547409.93", 90071992547409.9375)
    _float("90071992547409.9375", "90071992547409.9375", 90071992547409.9375)
    _float("12345678901234567890.5", "12345678901234567890.5", 12345678901234567890.5)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_trailing_or_leading_point_is_a_float]()
    suite.test[test_a_point_that_belongs_to_a_name_is_still_a_dot]()
    suite.test[test_exponents]()
    suite.test[test_an_e_that_is_not_an_exponent]()
    suite.test[test_an_exponent_is_the_nearest_double]()
    suite.test[test_a_literal_of_more_than_38_digits_is_the_nearest_double]()
    suite.test[test_a_decimal_converts_like_duckdbs_decimal_to_double]()
    suite^.run()
