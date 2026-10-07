# =============================================================================
# Tests for the value parsers: parse_float, parse_date, parse_decimal.
# =============================================================================
#
# Coverage (inline fixtures):
#   parse_float:
#     - Simple integer-valued: "0", "1", "42".
#     - Decimal: "3.14", "0.5".
#     - Negative: "-1.5".
#     - Scientific: "1e3", "1.5e-2".
#     - Empty / lone sign / non-digit / lone dot / lone exp → raises.
#
#   parse_date:
#     - 1970-01-01 → 0.
#     - 1970-01-02 → 1.
#     - 2024-01-01 → days since epoch (golden values).
#     - 0000-01-01 (far past) → negative.
#     - Bad format / wrong length → raises.
#     - Leap year handling: 2020-02-29 valid, 2021-02-29 raises.
#
#   parse_decimal:
#     - "0" at scale 2 → unscaled 0.
#     - "1.23" at p=5 s=2 → unscaled 123.
#     - "-1.23" at p=5 s=2 → unscaled -123.
#     - "1.234" at p=5 s=2 → truncates → unscaled 123.
#     - "12345" at p=10 s=0 → unscaled 12345.
#     - Lone sign / exponent / empty → raises.
#
#   End-to-end materializer:
#     - FLOAT64 column with 3 rows.
#     - DATE32 column reading "YYYY-MM-DD" strings.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.value_parsers.parse_date import parse_date32
from komira_jsonl.value_parsers.parse_decimal import parse_decimal128_unscaled
from komira_jsonl.value_parsers.parse_float import parse_float_f64


# =============================================================================
# parse_float
# =============================================================================


def test_float_int_value() raises:
    var s = String("42")
    var b = s.as_bytes()
    var v = parse_float_f64(b, 0, len(b))
    assert_true(v == 42.0)


def test_float_zero() raises:
    var s = String("0")
    var b = s.as_bytes()
    var v = parse_float_f64(b, 0, len(b))
    assert_true(v == 0.0)


def test_float_decimal() raises:
    var s = String("3.14")
    var b = s.as_bytes()
    var v = parse_float_f64(b, 0, len(b))
    # Compare with tight tolerance — 3.14 is exact for the algorithm here.
    var diff = v - 3.14
    if diff < 0:
        diff = -diff
    assert_true(diff < 1e-12)


def test_float_negative_decimal() raises:
    var s = String("-1.5")
    var b = s.as_bytes()
    var v = parse_float_f64(b, 0, len(b))
    assert_true(v == -1.5)


def test_float_exp_pos() raises:
    var s = String("1e3")
    var b = s.as_bytes()
    var v = parse_float_f64(b, 0, len(b))
    assert_true(v == 1000.0)


def test_float_exp_neg() raises:
    var s = String("1.5e-2")
    var b = s.as_bytes()
    var v = parse_float_f64(b, 0, len(b))
    # 0.015 = 1.5 * 10^-2.
    var diff = v - 0.015
    if diff < 0:
        diff = -diff
    assert_true(diff < 1e-12)


def test_float_empty_raises() raises:
    var s = String("")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_float_f64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_float_lone_sign_raises() raises:
    var s = String("-")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_float_f64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_float_lone_dot_raises() raises:
    var s = String("1.")  # decimal with no fractional digits
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_float_f64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_float_lone_exp_raises() raises:
    var s = String("1e")  # 'e' with no digits
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_float_f64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


# =============================================================================
# parse_date
# =============================================================================


def test_date_epoch() raises:
    var s = String("1970-01-01")
    var b = s.as_bytes()
    assert_equal(Int(parse_date32(b, 0, len(b))), 0)


def test_date_one_day_after_epoch() raises:
    var s = String("1970-01-02")
    var b = s.as_bytes()
    assert_equal(Int(parse_date32(b, 0, len(b))), 1)


def test_date_2024_jan_1() raises:
    var s = String("2024-01-01")
    var b = s.as_bytes()
    # Days from 1970-01-01 to 2024-01-01 = 19723.
    # (54 years * 365 + 13 leap days = 19710 + 13 = 19723)
    assert_equal(Int(parse_date32(b, 0, len(b))), 19723)


def test_date_pre_epoch() raises:
    var s = String("1969-12-31")
    var b = s.as_bytes()
    assert_equal(Int(parse_date32(b, 0, len(b))), -1)


def test_date_wrong_length_raises() raises:
    var s = String("2024-1-1")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_date32(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_date_missing_separator_raises() raises:
    var s = String("20240101AB")  # 10 bytes but no '-'
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_date32(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_date_leap_year_valid() raises:
    var s = String("2020-02-29")
    var b = s.as_bytes()
    # Shouldn't raise.
    var _v = parse_date32(b, 0, len(b))


def test_date_non_leap_feb_29_raises() raises:
    var s = String("2021-02-29")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_date32(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


# =============================================================================
# parse_decimal
# =============================================================================


def test_decimal_zero() raises:
    var s = String("0")
    var b = s.as_bytes()
    var v = parse_decimal128_unscaled(b, 0, len(b), 5, 2)
    assert_true(v == SIMD[DType.int128, 1](0))


def test_decimal_simple() raises:
    var s = String("1.23")
    var b = s.as_bytes()
    var v = parse_decimal128_unscaled(b, 0, len(b), 5, 2)
    # Unscaled: 1.23 * 10^2 = 123.
    assert_true(v == SIMD[DType.int128, 1](123))


def test_decimal_negative() raises:
    var s = String("-1.23")
    var b = s.as_bytes()
    var v = parse_decimal128_unscaled(b, 0, len(b), 5, 2)
    assert_true(v == SIMD[DType.int128, 1](-123))


def test_decimal_truncation() raises:
    var s = String("1.234")
    var b = s.as_bytes()
    var v = parse_decimal128_unscaled(b, 0, len(b), 5, 2)
    # Truncates trailing '4'; unscaled = 123 (NOT 124 — truncates, doesn't round).
    assert_true(v == SIMD[DType.int128, 1](123))


def test_decimal_integer_only_scale_0() raises:
    var s = String("12345")
    var b = s.as_bytes()
    var v = parse_decimal128_unscaled(b, 0, len(b), 10, 0)
    assert_true(v == SIMD[DType.int128, 1](12345))


def test_decimal_pad_fractional() raises:
    var s = String("1.5")
    var b = s.as_bytes()
    # scale=4 → need 1.5000 → unscaled 15000.
    var v = parse_decimal128_unscaled(b, 0, len(b), 10, 4)
    assert_true(v == SIMD[DType.int128, 1](15000))


def test_decimal_empty_raises() raises:
    var s = String("")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_decimal128_unscaled(b, 0, len(b), 5, 2)
    except _:
        raised = True
    assert_true(raised)


def test_decimal_lone_sign_raises() raises:
    var s = String("-")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_decimal128_unscaled(b, 0, len(b), 5, 2)
    except _:
        raised = True
    assert_true(raised)


# =============================================================================
# End-to-end materializer with FLOAT64 and DATE32 columns
# =============================================================================


def test_materialize_float64_column() raises:
    var input = String('{"x":1.5}\n{"x":3.14}\n{"x":-2.0}\n')
    var bytes = input.as_bytes()
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, True))
    var schema = sb.build()
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 3)
    assert_equal(batch.num_columns(), 1)


def test_materialize_date32_column() raises:
    var input = String('{"d":"1970-01-01"}\n{"d":"2024-01-01"}\n')
    var bytes = input.as_bytes()
    var sb = SchemaBuilder()
    sb.add_field(Field(String("d"), ArrowType.DATE32, True))
    var schema = sb.build()
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 2)


def test_materialize_mixed_int_float() raises:
    var input = String('{"id":1,"score":85.5}\n{"id":2,"score":92.3}\n')
    var bytes = input.as_bytes()
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"), ArrowType.INT64, True))
    sb.add_field(Field(String("score"), ArrowType.FLOAT64, True))
    var schema = sb.build()
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 2)
    assert_equal(batch.num_columns(), 2)


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("test_value_parsers — value parsers suite")

    # parse_float
    test_float_int_value()
    test_float_zero()
    test_float_decimal()
    test_float_negative_decimal()
    test_float_exp_pos()
    test_float_exp_neg()
    test_float_empty_raises()
    test_float_lone_sign_raises()
    test_float_lone_dot_raises()
    test_float_lone_exp_raises()

    # parse_date
    test_date_epoch()
    test_date_one_day_after_epoch()
    test_date_2024_jan_1()
    test_date_pre_epoch()
    test_date_wrong_length_raises()
    test_date_missing_separator_raises()
    test_date_leap_year_valid()
    test_date_non_leap_feb_29_raises()

    # parse_decimal
    test_decimal_zero()
    test_decimal_simple()
    test_decimal_negative()
    test_decimal_truncation()
    test_decimal_integer_only_scale_0()
    test_decimal_pad_fractional()
    test_decimal_empty_raises()
    test_decimal_lone_sign_raises()

    # End-to-end materializer
    test_materialize_float64_column()
    test_materialize_date32_column()
    test_materialize_mixed_int_float()

    print("test_value_parsers — all tests PASSED")
