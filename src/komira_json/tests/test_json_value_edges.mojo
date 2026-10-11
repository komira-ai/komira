# =============================================================================
# test_json_value_edges.mojo: JsonValue refusals by kind and index, the
# numeric edge cases of its constructors and serializer, and the float
# writer's helpers on values their callers never pass.
# =============================================================================
#
# Every refusal is pinned by its whole message, so an accessor that raised
# for another reason (or returned a value) fails.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_json import (
    JSON_NUMBER,
    JsonValue,
    parse_json_value,
    parse_uint64_text,
    write_f64_dtoa,
)
from komira_json.write import _is_inf_f64, _is_nan_f64, _try_fast_decimal_dtoa


def _nan() -> Float64:
    var z = Float64(0.0)
    return z / z


def _inf() -> Float64:
    var z = Float64(0.0)
    return Float64(1.0) / z


def _as_string_err(v: JsonValue) -> String:
    try:
        _ = v.as_string()
    except e:
        return String(e)
    return String("")


def _as_int64_err(v: JsonValue) -> String:
    try:
        _ = v.as_int64()
    except e:
        return String(e)
    return String("")


def _as_uint64_err(v: JsonValue) -> String:
    try:
        _ = v.as_uint64()
    except e:
        return String(e)
    return String("")


def _as_float64_err(v: JsonValue) -> String:
    try:
        _ = v.as_float64()
    except e:
        return String(e)
    return String("")


def _key_at_err(v: JsonValue, i: Int) -> String:
    try:
        _ = v.key_at(i)
    except e:
        return String(e)
    return String("")


def _value_at_err(v: JsonValue, i: Int) -> String:
    try:
        _ = v.value_at(i)
    except e:
        return String(e)
    return String("")


def _value_kind_err(v: JsonValue, i: Int) -> String:
    try:
        _ = v.value_kind(i)
    except e:
        return String(e)
    return String("")


def _element_at_err(v: JsonValue, i: Int) -> String:
    try:
        _ = v.element_at(i)
    except e:
        return String(e)
    return String("")


def test_from_f64_infinities_are_null() raises:
    # +Inf and -Inf have no JSON number form: a Null, not a Number whose
    # text is `null`.
    var pos = JsonValue.from_f64(_inf())
    assert_true(pos.is_null(), "+Inf is a Null")
    assert_equal(pos.serialize(), String("null"))
    var neg = JsonValue.from_f64(-_inf())
    assert_true(neg.is_null(), "-Inf is a Null")
    # The largest finite double is a Number.
    assert_true(JsonValue.from_f64(Float64(1.7976931348623157e308)).is_number())
    print("  test_from_f64_infinities_are_null: PASS")


def test_is_integral_number_edges() raises:
    # A String of digits is not a Number at all.
    assert_false(JsonValue.from_string(String("123")).is_integral_number())
    assert_false(JsonValue.null().is_integral_number())
    # An upper-case exponent makes a number non-integral, as `e` and `.` do.
    assert_false(parse_json_value("1E5").is_integral_number())
    assert_false(parse_json_value("1e5").is_integral_number())
    assert_false(parse_json_value("1.5").is_integral_number())
    assert_true(parse_json_value("-15").is_integral_number())
    print("  test_is_integral_number_edges: PASS")


def test_scalar_accessors_by_kind() raises:
    assert_equal(
        _as_string_err(parse_json_value("1")),
        String("JsonError: as_string() on a non-string value"),
    )
    assert_equal(
        _as_int64_err(parse_json_value("true")),
        String("JsonError: as_int64() on a non-numeric value"),
    )
    assert_equal(
        _as_uint64_err(parse_json_value("null")),
        String("JsonError: as_uint64() on a non-numeric value"),
    )
    assert_equal(
        _as_float64_err(parse_json_value("[1]")),
        String("JsonError: as_float64() on a non-numeric value"),
    )
    assert_equal(
        _as_float64_err(parse_json_value('{"a":1}')),
        String("JsonError: as_float64() on a non-numeric value"),
    )
    # A String is numeric for these accessors (proto3 JSON carries numbers
    # as strings).
    assert_equal(parse_json_value('"2.5"').as_float64(), Float64(2.5))
    assert_equal(parse_json_value('"-7"').as_int64(), Int64(-7))
    assert_equal(parse_json_value('"7"').as_uint64(), UInt64(7))
    print("  test_scalar_accessors_by_kind: PASS")


def test_positional_access_refusals() raises:
    var obj = parse_json_value('{"a":1,"b":[2]}')
    var arr = parse_json_value("[1,2]")
    var non_object = String(" on a non-object value")
    var oob = String(" index out of range")
    # The wrong kind.
    assert_equal(_key_at_err(arr, 0), String("JsonError: key_at()") + non_object)
    assert_equal(_value_at_err(arr, 0), String("JsonError: value_at()") + non_object)
    assert_equal(_value_kind_err(arr, 0), String("JsonError: value_kind()") + non_object)
    assert_equal(
        _element_at_err(obj, 0),
        String("JsonError: element_at() on a non-array value"),
    )
    # One below the range and one past it.
    assert_equal(_key_at_err(obj, -1), String("JsonError: key_at()") + oob)
    assert_equal(_value_at_err(obj, -1), String("JsonError: value_at()") + oob)
    assert_equal(_value_at_err(obj, 2), String("JsonError: value_at()") + oob)
    assert_equal(_value_kind_err(obj, -1), String("JsonError: value_kind()") + oob)
    assert_equal(_value_kind_err(obj, 2), String("JsonError: value_kind()") + oob)
    assert_equal(_element_at_err(arr, -1), String("JsonError: element_at()") + oob)
    # The range's own ends answer.
    assert_equal(obj.key_at(1), String("b"))
    assert_equal(obj.value_at(1).array_len(), 1)
    assert_equal(obj.value_kind(0), JSON_NUMBER)
    assert_equal(arr.element_at(1).as_int64(), Int64(2))
    print("  test_positional_access_refusals: PASS")


def test_empty_number_text_serializes_as_zero() raises:
    # Only a caller-built value has an empty Number text; it writes `0`.
    var v = JsonValue.from_number(String(""))
    assert_equal(v.serialize(), String("0"))
    var a = JsonValue.empty_array()
    a.push(v^)
    a.push(JsonValue.from_number(String("5")))
    assert_equal(a.serialize(), String("[0,5]"))
    print("  test_empty_number_text_serializes_as_zero: PASS")


def test_uint64_empty_text() raises:
    var m = String("")
    try:
        _ = parse_uint64_text(String(""))
    except e:
        m = String(e)
    assert_equal(m, String("JsonError: empty unsigned-integer text"))
    print("  test_uint64_empty_text: PASS")


@no_inline
def _fast(v: Float64) -> String:
    """What the fast path writes for `v`, or "declined" when it returns
    False (it must then have written nothing). One copy of the inlined fast
    path serves every call, so its lines are measured together."""
    var buf = List[UInt8]()
    if not _try_fast_decimal_dtoa(buf, v):
        return String("declined") if len(buf) == 0 else String("declined, wrote bytes")
    return String(unsafe_from_utf8=Span(buf))


def test_float_helpers_off_their_callers_paths() raises:
    # Both callers test NaN first, so `_is_inf_f64` and the fast path never
    # see one there; on their own, NaN is not an infinity and the fast path
    # declines it, writing nothing.
    assert_false(_is_inf_f64(_nan()), "NaN is not an infinity")
    assert_true(_is_inf_f64(_inf()))
    assert_true(_is_inf_f64(-_inf()))
    assert_false(_is_nan_f64(_inf()), "+Inf is not a NaN")
    assert_equal(_fast(_nan()), String("declined"), "fast path declines NaN")
    # The same copy of the fast path takes a value on its grid.
    assert_equal(_fast(Float64(2.5)), String("2.5"))
    print("  test_float_helpers_off_their_callers_paths: PASS")


def _f64(v: Float64) -> String:
    var buf = List[UInt8]()
    write_f64_dtoa(buf, v)
    return String(unsafe_from_utf8=Span(buf))


def test_fast_path_three_fraction_digits() raises:
    # A fraction on the 10^-4 grid whose last digit is 0 and third is not:
    # three digits, equal to the stdlib's text.
    var vals = List[Float64]()
    vals.append(Float64(0.125))
    vals.append(Float64(-1.375))
    vals.append(Float64(20321.501))
    var want = List[String]()
    want.append("0.125")
    want.append("-1.375")
    want.append("20321.501")
    for i in range(len(vals)):
        assert_equal(_f64(vals[i]), want[i])
        assert_equal(_f64(vals[i]), String(vals[i]))
    print("  test_fast_path_three_fraction_digits: PASS")


def main() raises:
    print("test_json_value_edges")
    test_from_f64_infinities_are_null()
    test_is_integral_number_edges()
    test_scalar_accessors_by_kind()
    test_positional_access_refusals()
    test_empty_number_text_serializes_as_zero()
    test_uint64_empty_text()
    test_float_helpers_off_their_callers_paths()
    test_fast_path_three_fraction_digits()
    print("test_json_value_edges: ALL PASS")
