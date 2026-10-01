# =============================================================================
# test_json_write.mojo: the direct-byte writers.
# =============================================================================
#
# String escaping (every C0 control byte, quote, backslash, non-ASCII
# verbatim) round-trips through the strict parser; integers at their bounds;
# Float64 formatting: -0.0 keeps its sign, NaN / +Inf / -Inf write `null`,
# the fast path is byte-identical to `String(v)`, and every output is a
# valid JSON number that parses back to the same double.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json import (
    parse_json_bytes,
    parse_json_value,
    write_f64_dtoa,
    write_i64_dec,
    write_json_bool,
    write_json_null,
    write_json_string,
    write_u64_dec,
)


def _str(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _i64(v: Int64) -> String:
    var b = List[UInt8]()
    write_i64_dec(b, v)
    return _str(b)


def _u64(v: UInt64) -> String:
    var b = List[UInt8]()
    write_u64_dec(b, v)
    return _str(b)


def _f64(v: Float64) -> String:
    var b = List[UInt8]()
    write_f64_dtoa(b, v)
    return _str(b)


def _jstr(s: String) -> String:
    var b = List[UInt8]()
    write_json_string(b, s)
    return _str(b)


def test_literals() raises:
    var b = List[UInt8]()
    write_json_null(b)
    b.append(0x2C)
    write_json_bool(b, True)
    b.append(0x2C)
    write_json_bool(b, False)
    assert_equal(_str(b), String("null,true,false"))
    print("  test_literals: PASS")


def test_integers() raises:
    assert_equal(_i64(Int64(0)), String("0"))
    assert_equal(_i64(Int64(-1)), String("-1"))
    assert_equal(_i64(Int64(10)), String("10"))
    assert_equal(_i64(Int64(-9223372036854775808)), String("-9223372036854775808"))
    assert_equal(_i64(Int64(9223372036854775807)), String("9223372036854775807"))
    assert_equal(_u64(UInt64(0)), String("0"))
    assert_equal(_u64(UInt64(18446744073709551615)), String("18446744073709551615"))
    # Each parses back exactly.
    assert_equal(
        parse_json_value(_i64(Int64(-9223372036854775808))).as_int64(),
        Int64(-9223372036854775808),
    )
    assert_equal(
        parse_json_value(_u64(UInt64(18446744073709551615))).as_uint64(),
        UInt64(18446744073709551615),
    )
    print("  test_integers: PASS")


def test_escaping_every_control_byte_round_trips() raises:
    """Every byte 0x00..0x1F plus `"` and `\\` must be escaped, and the
    escaped text must parse back to the original bytes."""
    var raw = List[UInt8]()
    for c in range(0x20):
        raw.append(UInt8(c))
    raw.append(0x22)  # "
    raw.append(0x5C)  # \
    raw.append(0x2F)  # / (not escaped)
    raw.append(0x7F)  # DEL (not escaped)
    var text = _jstr(_str(raw))
    # The named escapes and a \u00XX form appear; no raw control byte does.
    assert_true(text.find(String("\\b\\t\\n")) >= 0, "named escapes")
    assert_true(text.find(String("\\f\\r")) >= 0, "named escapes 2")
    assert_true(text.find(String("\\u0000\\u0001")) >= 0, "\\u00XX for NUL")
    assert_true(text.find(String("\\u001f")) >= 0, "lowercase hex")
    assert_true(text.find(String('\\"\\\\/')) >= 0, "quote, backslash, slash")
    var tb = text.as_bytes()
    for i in range(len(tb)):
        assert_true(tb[i] >= 0x20, "no raw control byte in the output")
    var back = parse_json_value(text).as_string().as_bytes()
    assert_equal(len(back), len(raw))
    for i in range(len(raw)):
        assert_equal(Int(back[i]), Int(raw[i]), "control byte round trip")
    print("  test_escaping_every_control_byte_round_trips: PASS")


def test_non_ascii_verbatim_and_round_trips() raises:
    # é, em dash, U+FFFF, G clef: copied verbatim (never \u-escaped).
    var raw: List[UInt8] = [
        0xC3, 0xA9,
        0xE2, 0x80, 0x94,
        0xEF, 0xBF, 0xBF,
        0xF0, 0x9D, 0x84, 0x9E,
    ]
    var out = List[UInt8]()
    write_json_string(out, _str(raw))
    assert_equal(len(out), len(raw) + 2)
    assert_equal(Int(out[0]), 0x22)
    for i in range(len(raw)):
        assert_equal(Int(out[i + 1]), Int(raw[i]), "verbatim")
    var back = parse_json_bytes(out).as_string().as_bytes()
    assert_equal(len(back), len(raw))
    for i in range(len(raw)):
        assert_equal(Int(back[i]), Int(raw[i]), "round trip")
    # The escaped \uXXXX surrogate-pair form decodes to the same bytes.
    var pair = parse_json_value('"\\u00e9\\u2014\\uffff\\ud834\\udd1e"')
    var pb = pair.as_string().as_bytes()
    assert_equal(len(pb), len(raw))
    for i in range(len(raw)):
        assert_equal(Int(pb[i]), Int(raw[i]), "escaped form")
    print("  test_non_ascii_verbatim_and_round_trips: PASS")


def test_f64_special_values() raises:
    var zero = Float64(0.0)
    assert_equal(_f64(zero / zero), String("null"))  # NaN
    assert_equal(_f64(Float64(1.0) / zero), String("null"))  # +Inf
    assert_equal(_f64(Float64(-1.0) / zero), String("null"))  # -Inf
    assert_equal(_f64(Float64(0.0)), String("0.0"))
    var neg_zero = _f64(-zero)
    assert_equal(neg_zero, String(-zero))
    assert_true(neg_zero.find(String("-")) == 0, "-0.0 keeps its sign")
    print("  test_f64_special_values: PASS")


def test_f64_matches_stdlib_and_round_trips() raises:
    var zero = Float64(0.0)
    var vals = List[Float64]()
    # Fast-path domain: on the 10^-4 grid, |v| in [1e-4, 1e9).
    vals.append(Float64(17.0))
    vals.append(Float64(0.04))
    vals.append(Float64(21168.23))
    vals.append(Float64(-13309.6))
    vals.append(Float64(20321.5008))
    vals.append(Float64(0.0001))
    vals.append(Float64(999999999.9999))
    # Slow path.
    vals.append(Float64(3.141592653589793))
    vals.append(Float64(0.00001))
    vals.append(Float64(1.0e9))
    vals.append(Float64(1.0e21))
    vals.append(Float64(1.0e300))
    vals.append(Float64(-2.5e-300))
    vals.append(Float64(5e-324))  # smallest denormal
    vals.append(Float64(1.7976931348623157e308))  # Float64.MAX
    vals.append(Float64(9007199254740993.0))
    vals.append(-zero)
    for i in range(len(vals)):
        var v = vals[i]
        var s = _f64(v)
        # Byte-identical to the stdlib formatter (fast path or not).
        assert_equal(s, String(v), "matches String(v)")
        # A valid JSON number that parses back to the same double.
        var parsed = parse_json_value(s)
        assert_true(parsed.is_number(), String("is a JSON number: ") + s)
        assert_equal(parsed.as_float64(), v, String("round trip: ") + s)
    print("  test_f64_matches_stdlib_and_round_trips: PASS")


def main() raises:
    print("test_json_write")
    test_literals()
    test_integers()
    test_escaping_every_control_byte_round_trips()
    test_non_ascii_verbatim_and_round_trips()
    test_f64_special_values()
    test_f64_matches_stdlib_and_round_trips()
    print("test_json_write: ALL PASS")
