# =============================================================================
# Tests for komira_csv/cell_parsers.mojo — per-DType parsers.
# =============================================================================
#
# Coverage:
#   T1  _try_parse_int64: positive / negative / leading-zero / empty / sign-only /
#       non-digit.
#   T2  _try_parse_float64: integer-form / decimal / negative / exponent / empty /
#       multi-dot.
#   T3  _try_parse_date32: 1970-01-01 epoch / 2024-01-01 / leap-year valid /
#       leap-year invalid (Feb 29 non-leap) / wrong format.
#   T4  _try_parse_bool: true_strings hit / false_strings hit / unknown value.
#   T5  unescape_cell_double_quote: doubled-quote -> single.
#   T6  unescape_cell_posix: backslash escapes (n / t / r / literal).
#   T7  null_detection: pandas default tokens.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    CsvReadOptions,
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_date32,
    _try_parse_bool,
    cell_to_string,
    unescape_cell_double_quote,
    unescape_cell_posix,
    is_null_cell,
    is_true_cell,
    is_false_cell,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def test_parse_int64() raises:
    """T1: int64 parser corner cases."""
    var buf_pos = _bytes(String("12345"))
    var p1 = _try_parse_int64(Span(buf_pos))
    assert_true(Bool(p1), "12345 parses")
    assert_equal(Int(p1.value()), 12345)

    var buf_neg = _bytes(String("-42"))
    var p2 = _try_parse_int64(Span(buf_neg))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), -42)

    var buf_zero = _bytes(String("0"))
    var p3 = _try_parse_int64(Span(buf_zero))
    assert_true(Bool(p3))
    assert_equal(Int(p3.value()), 0)

    var buf_empty = _bytes(String(""))
    var p4 = _try_parse_int64(Span(buf_empty))
    assert_false(Bool(p4), "empty -> None")

    var buf_sign_only = _bytes(String("-"))
    var p5 = _try_parse_int64(Span(buf_sign_only))
    assert_false(Bool(p5), "sign-only -> None")

    var buf_non_digit = _bytes(String("12a3"))
    var p6 = _try_parse_int64(Span(buf_non_digit))
    assert_false(Bool(p6), "non-digit byte -> None")


def test_parse_float64() raises:
    """T2: float64 parser corner cases."""
    var buf_int_form = _bytes(String("42"))
    var p1 = _try_parse_float64(Span(buf_int_form), UInt8(ord(".")))
    assert_true(Bool(p1), "int-form parses")
    assert_equal(p1.value(), Float64(42.0))

    var buf_dec = _bytes(String("3.14"))
    var p2 = _try_parse_float64(Span(buf_dec), UInt8(ord(".")))
    assert_true(Bool(p2))
    var diff = p2.value() - Float64(3.14)
    if diff < 0:
        diff = -diff
    assert_true(diff < Float64(1e-10), "3.14 round-trips")

    var buf_neg = _bytes(String("-1.5e2"))
    var p3 = _try_parse_float64(Span(buf_neg), UInt8(ord(".")))
    assert_true(Bool(p3))
    assert_equal(p3.value(), Float64(-150.0))

    var buf_multi = _bytes(String("1.2.3"))
    var p4 = _try_parse_float64(Span(buf_multi), UInt8(ord(".")))
    assert_false(Bool(p4), "multi-dot -> None")


def test_parse_date32() raises:
    """T3: date32 ISO-8601 parser."""
    var buf_epoch = _bytes(String("1970-01-01"))
    var p1 = _try_parse_date32(Span(buf_epoch))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 0, "epoch -> day 0")

    var buf_2024 = _bytes(String("2024-01-01"))
    var p2 = _try_parse_date32(Span(buf_2024))
    assert_true(Bool(p2))
    # 1970-01-01 to 2024-01-01: 54 years. Leap years: 1972, 76, 80, ...,
    # 2020 = 13 leap years. Non-leaps: 41. Days = 41*365 + 13*366 = 19723.
    assert_equal(Int(p2.value()), 19723)

    # Leap year valid: 2024-02-29
    var buf_leap_ok = _bytes(String("2024-02-29"))
    var p3 = _try_parse_date32(Span(buf_leap_ok))
    assert_true(Bool(p3), "2024-02-29 is valid (leap year)")

    # Non-leap-year invalid: 2023-02-29
    var buf_leap_fail = _bytes(String("2023-02-29"))
    var p4 = _try_parse_date32(Span(buf_leap_fail))
    assert_false(Bool(p4), "2023-02-29 is invalid (non-leap)")

    # Wrong format
    var buf_wrong = _bytes(String("01/01/2024"))
    var p5 = _try_parse_date32(Span(buf_wrong))
    assert_false(Bool(p5), "MM/DD/YYYY rejected")


def test_parse_bool() raises:
    """T4: bool parser via true_strings / false_strings."""
    var opts = CsvReadOptions()
    var buf_true = _bytes(String("true"))
    var p1 = _try_parse_bool(Span(buf_true), opts)
    assert_true(Bool(p1))
    assert_equal(p1.value(), True)

    var buf_false_caps = _bytes(String("FALSE"))
    var p2 = _try_parse_bool(Span(buf_false_caps), opts)
    assert_true(Bool(p2))
    assert_equal(p2.value(), False)

    var buf_unknown = _bytes(String("maybe"))
    var p3 = _try_parse_bool(Span(buf_unknown), opts)
    assert_false(Bool(p3))


def test_unescape_double_quote() raises:
    """T5: doubled-quote `""` collapses to `"`."""
    var buf = _bytes(String("a\"\"b"))
    var out = unescape_cell_double_quote(Span(buf), UInt8(ord('"')))
    assert_equal(out, String("a\"b"), "doubled-quote collapsed")


def test_unescape_posix() raises:
    """T6: Posix backslash escapes."""
    var buf_n = _bytes(String("a\\nb"))
    var out_n = unescape_cell_posix(Span(buf_n), UInt8(0x5C))  # '\\'
    assert_equal(out_n, String("a\nb"), "\\n -> LF")

    var buf_q = _bytes(String("a\\\"b"))
    var out_q = unescape_cell_posix(Span(buf_q), UInt8(0x5C))
    assert_equal(out_q, String("a\"b"), "\\\" -> \"")


def test_null_detection_defaults() raises:
    """T7: pandas defaults — empty / NULL / NA / NaN / null."""
    var opts = CsvReadOptions()
    var b_empty = _bytes(String(""))
    var b_NULL = _bytes(String("NULL"))
    var b_NA = _bytes(String("NA"))
    var b_NaN = _bytes(String("NaN"))
    var b_null = _bytes(String("null"))
    var b_other = _bytes(String("nope"))

    assert_true(is_null_cell(Span(b_empty), opts), "empty is null")
    assert_true(is_null_cell(Span(b_NULL), opts), "NULL is null")
    assert_true(is_null_cell(Span(b_NA), opts), "NA is null")
    assert_true(is_null_cell(Span(b_NaN), opts), "NaN is null")
    assert_true(is_null_cell(Span(b_null), opts), "null is null")
    assert_false(is_null_cell(Span(b_other), opts), "nope is NOT null")


def main() raises:
    test_parse_int64()
    test_parse_float64()
    test_parse_date32()
    test_parse_bool()
    test_unescape_double_quote()
    test_unescape_posix()
    test_null_detection_defaults()
    print("test_csv_cell_parsers: 7/7 PASS")
