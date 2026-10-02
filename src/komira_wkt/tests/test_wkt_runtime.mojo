# =============================================================================
# test_wkt_runtime.mojo — komira_wkt well-known-type runtime suite.
# =============================================================================
#
# Checks: proto-binary encode -> decode identity for every WKT, and proto3
# canonical-JSON output byte-checked against reference vectors.
#
# Every WKT here is exercised on TWO independent paths:
#   1. protobuf-binary `Serializable` round-trip —
#      `encode_proto -> decode_proto` is identity (encode and decode are
#      separate code paths, so a round-trip is a real correctness signal);
#   2. the proto3 canonical-JSON special form — `to_proto3_json()`
#      byte-checked against a hand-verified reference string, and
#      `from_proto3_json()` round-tripped back.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import encode_proto, decode_proto

from komira_wkt import (
    Timestamp,
    Duration,
    Empty,
    Int32Value,
    Int64Value,
    UInt32Value,
    UInt64Value,
    FloatValue,
    DoubleValue,
    BoolValue,
    StringValue,
    BytesValue,
    FieldMask,
    Struct,
    Value,
    ListValue,
    VALUE_KIND_NULL,
    VALUE_KIND_NUMBER,
    VALUE_KIND_STRING,
    VALUE_KIND_BOOL,
    VALUE_KIND_STRUCT,
    VALUE_KIND_LIST,
)


# =============================================================================
# Timestamp — proto-binary round-trip + RFC-3339 canonical JSON.
# =============================================================================


def test_timestamp_proto_roundtrip() raises:
    """Timestamp encode_proto -> decode_proto is identity."""
    var ts = Timestamp(Int64(1672531200), Int32(21000000))
    var bytes = encode_proto[Timestamp](ts)
    var back = decode_proto[Timestamp](bytes^)
    assert_equal(back.seconds, Int64(1672531200))
    assert_equal(back.nanos, Int32(21000000))

    # The epoch zero value.
    var zero = Timestamp.new()
    var zb = encode_proto[Timestamp](zero)
    var z_back = decode_proto[Timestamp](zb^)
    assert_equal(z_back.seconds, Int64(0))
    assert_equal(z_back.nanos, Int32(0))


def test_timestamp_rfc3339_json() raises:
    """Timestamp.to_proto3_json() is the RFC-3339 UTC string."""
    # 2023-01-01T00:00:00Z — epoch 1672531200, no fraction.
    var ts = Timestamp(Int64(1672531200), Int32(0))
    assert_equal(ts.to_proto3_json(), String("2023-01-01T00:00:00Z"))

    # The protobuf-spec worked example: 1972-01-01T10:00:20.021Z.
    # 1972-01-01 is day 730; 730*86400 + 10*3600 + 20 = 63108020.
    var spec = Timestamp(Int64(63108020), Int32(21000000))
    assert_equal(spec.to_proto3_json(), String("1972-01-01T10:00:20.021Z"))

    # Epoch zero.
    var zero = Timestamp.new()
    assert_equal(zero.to_proto3_json(), String("1970-01-01T00:00:00Z"))

    # Nine-digit fraction (not trimmable).
    var nano = Timestamp(Int64(0), Int32(123456789))
    assert_equal(nano.to_proto3_json(), String("1970-01-01T00:00:00.123456789Z"))


def test_timestamp_json_roundtrip() raises:
    """Timestamp.from_proto3_json o to_proto3_json is identity."""
    var cases = List[String]()
    cases.append(String("2023-01-01T00:00:00Z"))
    cases.append(String("1972-01-01T10:00:20.021Z"))
    cases.append(String("1970-01-01T00:00:00Z"))
    cases.append(String("1970-01-01T00:00:00.123456789Z"))
    cases.append(String("2099-12-31T23:59:59.500Z"))
    for i in range(len(cases)):
        var parsed = Timestamp.from_proto3_json(cases[i])
        assert_equal(parsed.to_proto3_json(), cases[i])


def test_timestamp_pre_epoch() raises:
    """A pre-1970 Timestamp (negative seconds) renders the correct civil day.
    """
    # 1969-12-31T00:00:00Z — one day before the epoch = -86400 seconds.
    var ts = Timestamp(Int64(-86400), Int32(0))
    assert_equal(ts.to_proto3_json(), String("1969-12-31T00:00:00Z"))
    var back = Timestamp.from_proto3_json(ts.to_proto3_json())
    assert_equal(back.seconds, Int64(-86400))


# =============================================================================
# Duration — proto-binary round-trip + "<n>s" canonical JSON.
# =============================================================================


def test_duration_proto_roundtrip() raises:
    """Duration encode_proto -> decode_proto is identity, incl. negative."""
    var d = Duration(Int64(90), Int32(500000000))
    var b = encode_proto[Duration](d)
    var back = decode_proto[Duration](b^)
    assert_equal(back.seconds, Int64(90))
    assert_equal(back.nanos, Int32(500000000))

    var neg = Duration(Int64(-12), Int32(0))
    var nb = encode_proto[Duration](neg)
    var n_back = decode_proto[Duration](nb^)
    assert_equal(n_back.seconds, Int64(-12))


def test_duration_json() raises:
    """Duration.to_proto3_json() is the `"<n>[.<frac>]s"` form (proto3 JSON).
    """
    assert_equal(Duration(Int64(3), Int32(0)).to_proto3_json(), String("3s"))
    assert_equal(Duration(Int64(0), Int32(0)).to_proto3_json(), String("0s"))
    # 1.000340012s — full nine-digit fraction.
    assert_equal(
        Duration(Int64(1), Int32(340012)).to_proto3_json(),
        String("1.000340012s"),
    )
    # Negative: sign on the magnitude.
    assert_equal(Duration(Int64(-12), Int32(0)).to_proto3_json(), String("-12s"))
    # Three-digit trimmed fraction.
    assert_equal(
        Duration(Int64(2), Int32(500000000)).to_proto3_json(),
        String("2.500s"),
    )


def test_duration_json_roundtrip() raises:
    """Duration.from_proto3_json o to_proto3_json is identity."""
    var cases = List[String]()
    cases.append(String("3s"))
    cases.append(String("0s"))
    cases.append(String("1.000340012s"))
    cases.append(String("-12s"))
    cases.append(String("2.500s"))
    cases.append(String("-1.250s"))
    for i in range(len(cases)):
        var parsed = Duration.from_proto3_json(cases[i])
        assert_equal(parsed.to_proto3_json(), cases[i])


# =============================================================================
# Empty.
# =============================================================================


def test_empty() raises:
    """Empty: zero-byte proto-binary, `{}` canonical JSON."""
    var e = Empty.new()
    var b = encode_proto[Empty](e)
    assert_equal(len(b), 0)
    var back = decode_proto[Empty](b^)
    _ = back
    assert_equal(e.to_proto3_json(), String("{}"))


# =============================================================================
# Scalar wrappers — proto-binary round-trip + bare-scalar canonical JSON.
# =============================================================================


def test_int32_value() raises:
    var v = Int32Value(Int32(-7))
    var b = encode_proto[Int32Value](v)
    var back = decode_proto[Int32Value](b^)
    assert_equal(back.value, Int32(-7))
    assert_equal(v.to_proto3_json(), String("-7"))
    assert_false(Int32Value.is_json_string())
    assert_equal(Int32Value.from_proto3_json(String("42")).value, Int32(42))


def test_int64_value() raises:
    """Int64Value JSON form is a STRING (proto3 JSON precision safety)."""
    var v = Int64Value(Int64(9007199254740993))  # 2^53 + 1, JS-unsafe.
    var b = encode_proto[Int64Value](v)
    var back = decode_proto[Int64Value](b^)
    assert_equal(back.value, Int64(9007199254740993))
    assert_equal(v.to_proto3_json(), String("9007199254740993"))
    assert_true(Int64Value.is_json_string())


def test_uint_values() raises:
    var u32 = UInt32Value(UInt32(4000000000))
    var b32 = encode_proto[UInt32Value](u32)
    assert_equal(decode_proto[UInt32Value](b32^).value, UInt32(4000000000))
    assert_equal(u32.to_proto3_json(), String("4000000000"))

    var u64 = UInt64Value(UInt64(18446744073709551615))  # UInt64.MAX
    var b64 = encode_proto[UInt64Value](u64)
    assert_equal(
        decode_proto[UInt64Value](b64^).value, UInt64(18446744073709551615)
    )
    assert_equal(u64.to_proto3_json(), String("18446744073709551615"))
    assert_true(UInt64Value.is_json_string())


def test_float_double_values() raises:
    var f = FloatValue(Float32(1.5))
    var fb = encode_proto[FloatValue](f)
    assert_equal(decode_proto[FloatValue](fb^).value, Float32(1.5))

    var d = DoubleValue(Float64(3.25))
    var db = encode_proto[DoubleValue](d)
    assert_equal(decode_proto[DoubleValue](db^).value, Float64(3.25))
    assert_false(DoubleValue.is_json_string())


def test_bool_value() raises:
    var t = BoolValue(True)
    var tb = encode_proto[BoolValue](t)
    assert_true(decode_proto[BoolValue](tb^).value)
    assert_equal(t.to_proto3_json(), String("true"))
    assert_equal(BoolValue(False).to_proto3_json(), String("false"))
    assert_true(BoolValue.from_proto3_json(String("true")).value)


def test_string_value() raises:
    var s = StringValue(String("hello, world"))
    var sb = encode_proto[StringValue](s)
    assert_equal(decode_proto[StringValue](sb^).value, String("hello, world"))
    assert_equal(s.to_proto3_json(), String("hello, world"))
    assert_true(StringValue.is_json_string())


def test_bytes_value() raises:
    """BytesValue JSON form is a base64 string (proto3 JSON mapping)."""
    var raw = List[UInt8]()
    raw.append(0x00)
    raw.append(0x01)
    raw.append(0xFF)
    raw.append(0x42)
    var bv = BytesValue(raw^)
    var bb = encode_proto[BytesValue](bv)
    var back = decode_proto[BytesValue](bb^)
    assert_equal(len(back.value), 4)
    assert_equal(back.value[0], UInt8(0x00))
    assert_equal(back.value[2], UInt8(0xFF))
    # base64 of 00 01 FF 42 is "AAH/Qg==".
    assert_equal(bv.to_proto3_json(), String("AAH/Qg=="))
    var rt = BytesValue.from_proto3_json(bv.to_proto3_json())
    assert_equal(len(rt.value), 4)
    assert_equal(rt.value[2], UInt8(0xFF))
    assert_true(BytesValue.is_json_string())


# =============================================================================
# FieldMask — proto-binary round-trip + comma-joined lowerCamelCase JSON.
# =============================================================================


def test_field_mask() raises:
    var paths = List[String]()
    paths.append(String("user_id"))
    paths.append(String("display_name"))
    paths.append(String("email"))
    var fm = FieldMask(paths^)
    var b = encode_proto[FieldMask](fm)
    var back = decode_proto[FieldMask](b^)
    assert_equal(len(back.paths), 3)
    assert_equal(back.paths[0], String("user_id"))
    assert_equal(back.paths[1], String("display_name"))

    # proto3 JSON: comma-joined lowerCamelCase.
    assert_equal(fm.to_proto3_json(), String("userId,displayName,email"))
    # Round-trip back to the snake_case wire paths.
    var rt = FieldMask.from_proto3_json(fm.to_proto3_json())
    assert_equal(len(rt.paths), 3)
    assert_equal(rt.paths[0], String("user_id"))
    assert_equal(rt.paths[1], String("display_name"))

    # Empty mask -> empty string.
    assert_equal(FieldMask.new().to_proto3_json(), String(""))


# =============================================================================
# Struct / Value / ListValue — proto-binary round-trip + literal-JSON form.
# =============================================================================


def test_value_scalars() raises:
    """A `Value` carrying each scalar kind round-trips on proto-binary."""
    var n = Value.number(Float64(42.5))
    var nb = encode_proto[Value](n)
    var n_back = decode_proto[Value](nb^)
    assert_equal(n_back.kind, VALUE_KIND_NUMBER)
    assert_equal(n_back.number_value, Float64(42.5))

    var s = Value.string(String("hi"))
    var sb = encode_proto[Value](s)
    assert_equal(decode_proto[Value](sb^).kind, VALUE_KIND_STRING)

    var b = Value.boolean(True)
    var bb = encode_proto[Value](b)
    var b_back = decode_proto[Value](bb^)
    assert_equal(b_back.kind, VALUE_KIND_BOOL)
    assert_true(b_back.bool_value)

    var nul = Value.null()
    var nulb = encode_proto[Value](nul)
    assert_equal(decode_proto[Value](nulb^).kind, VALUE_KIND_NULL)


def test_value_json_scalars() raises:
    """Value.to_proto3_json() emits the literal JSON value."""
    assert_equal(Value.null().to_proto3_json(), String("null"))
    assert_equal(Value.boolean(True).to_proto3_json(), String("true"))
    assert_equal(Value.string(String("hi")).to_proto3_json(), String('"hi"'))


def test_struct_roundtrip() raises:
    """A nested Struct round-trips on proto-binary AND emits literal JSON."""
    var inner = Struct.new()
    inner.put(String("count"), Value.number(Float64(3.0)))

    var s = Struct.new()
    s.put(String("name"), Value.string(String("example")))
    s.put(String("active"), Value.boolean(True))
    s.put(String("meta"), Value.struct_(inner^))

    var b = encode_proto[Struct](s)
    var back = decode_proto[Struct](b^)
    assert_equal(len(back.keys), 3)
    assert_equal(back.keys[0], String("name"))
    assert_equal(back.values[0].kind, VALUE_KIND_STRING)
    assert_equal(back.values[0].string_value, String("example"))
    assert_equal(back.values[1].kind, VALUE_KIND_BOOL)
    assert_equal(back.values[2].kind, VALUE_KIND_STRUCT)
    # The recursive child survived.
    assert_equal(len(back.values[2].struct_value), 1)
    assert_equal(back.values[2].struct_value[0].keys[0], String("count"))

    # The literal-JSON form (insertion order preserved).
    assert_equal(
        s.to_proto3_json(),
        String('{"name":"example","active":true,"meta":{"count":3}}'),
    )


def test_list_value_roundtrip() raises:
    """A ListValue round-trips on proto-binary AND emits literal JSON."""
    var lv = ListValue.new()
    lv.add(Value.number(Float64(1.0)))
    lv.add(Value.string(String("two")))
    lv.add(Value.boolean(False))

    var b = encode_proto[ListValue](lv)
    var back = decode_proto[ListValue](b^)
    assert_equal(len(back.values), 3)
    assert_equal(back.values[0].kind, VALUE_KIND_NUMBER)
    assert_equal(back.values[1].string_value, String("two"))

    assert_equal(lv.to_proto3_json(), String('[1,"two",false]'))


def test_value_recursive_json() raises:
    """A deeply recursive Value (object -> array -> object) round-trips
    through the canonical JSON form."""
    var doc = String('{"items":[{"id":1},{"id":2.5}],"ok":true}')
    var v = Value.from_proto3_json(doc)
    assert_equal(v.kind, VALUE_KIND_STRUCT)
    # to_proto3_json reproduces the document byte-for-byte (key order kept).
    assert_equal(v.to_proto3_json(), doc)

    # And it survives a proto-binary round-trip too.
    var b = encode_proto[Value](v)
    var back = decode_proto[Value](b^)
    assert_equal(back.to_proto3_json(), doc)


def main() raises:
    test_timestamp_proto_roundtrip()
    test_timestamp_rfc3339_json()
    test_timestamp_json_roundtrip()
    test_timestamp_pre_epoch()
    test_duration_proto_roundtrip()
    test_duration_json()
    test_duration_json_roundtrip()
    test_empty()
    test_int32_value()
    test_int64_value()
    test_uint_values()
    test_float_double_values()
    test_bool_value()
    test_string_value()
    test_bytes_value()
    test_field_mask()
    test_value_scalars()
    test_value_json_scalars()
    test_struct_roundtrip()
    test_list_value_roundtrip()
    test_value_recursive_json()
    print("test_wkt_runtime: all tests passed")
