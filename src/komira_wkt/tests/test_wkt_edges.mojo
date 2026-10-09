# =============================================================================
# test_wkt_edges.mojo — the refusals, range ends and small helpers of the
# well-known types that the round-trip suites do not reach.
# =============================================================================
#
#   - Duration: both ends of the seconds and nanos ranges (the last value
#     accepted and the first refused), both orders of mismatched signs, a
#     zero-second negative, every fraction width of the text form, and each
#     refusal of the text reader with the refusal it must name;
#   - Any / Empty / FieldMask / Struct / ListValue: each reader's refusal
#     of the wrong JSON kind, and the empty forms;
#   - Value: an arm whose box is empty, an unset value on the binary wire,
#     a JSON kind the converter does not know, and the number writer at
#     2^53 and at both zeros;
#   - NullValue's enum surface, the wrappers' small static helpers, and the
#     digit check of the Duration parser.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_proto_codec import encode_proto, encode_json
from komira_json import JsonValue, parse_json_value

from komira_wkt import (
    Any,
    Duration,
    Empty,
    Int32Value,
    UInt32Value,
    FloatValue,
    BoolValue,
    StringValue,
    FieldMask,
    Struct,
    Value,
    ListValue,
    NullValue,
    NULL_VALUE,
    VALUE_KIND_UNSET,
    VALUE_KIND_STRUCT,
    VALUE_KIND_LIST,
    VALUE_KIND_NUMBER,
)
from komira_wkt.structpb import _StructEntry
from komira_wkt.timestamp import _parse_uint


def _dur(seconds: Int, nanos: Int) raises -> String:
    return Duration(Int64(seconds), Int32(nanos)).to_proto3_json()


def _empty_box_value(kind: Int) -> Value:
    return Value(
        kind, Float64(0.0), String(""), False, List[Struct](), List[ListValue]()
    )


# =============================================================================
# Duration.
# =============================================================================


def test_duration_output_range_ends() raises:
    assert_equal(_dur(315576000000, 0), String("315576000000s"))
    assert_equal(_dur(-315576000000, 0), String("-315576000000s"))
    with assert_raises(contains="seconds outside +-315576000000: 315576000001"):
        _ = _dur(315576000001, 0)
    with assert_raises(
        contains="seconds outside +-315576000000: -315576000001"
    ):
        _ = _dur(-315576000001, 0)
    assert_equal(_dur(0, 999999999), String("0.999999999s"))
    assert_equal(_dur(0, -999999999), String("-0.999999999s"))
    with assert_raises(contains="nanos outside +-999999999: 1000000000"):
        _ = _dur(0, 1000000000)
    with assert_raises(contains="nanos outside +-999999999: -1000000000"):
        _ = _dur(0, -1000000000)


def test_duration_output_signs() raises:
    with assert_raises(contains="opposite signs: 1, -1"):
        _ = _dur(1, -1)
    with assert_raises(contains="opposite signs: -1, 1"):
        _ = _dur(-1, 1)
    # Zero seconds: the sign comes from the nanos alone.
    assert_equal(_dur(0, -5), String("-0.000000005s"))
    assert_equal(_dur(0, 5), String("0.000000005s"))


def test_duration_fraction_widths() raises:
    """Each of the last six digits decides between 9, 6 and 3 digits."""
    assert_equal(_dur(1, 1), String("1.000000001s"))
    assert_equal(_dur(1, 10), String("1.000000010s"))
    assert_equal(_dur(1, 100), String("1.000000100s"))
    assert_equal(_dur(1, 1000), String("1.000001s"))
    assert_equal(_dur(1, 10000), String("1.000010s"))
    assert_equal(_dur(1, 100000), String("1.000100s"))
    assert_equal(_dur(1, 1000000), String("1.001s"))


def test_duration_text_refusals() raises:
    with assert_raises(contains="must end in 's'"):
        _ = Duration.from_proto3_json(String("s"))
    with assert_raises(contains="must end in 's'"):
        _ = Duration.from_proto3_json(String(""))
    with assert_raises(contains="must end in 's'"):
        _ = Duration.from_proto3_json(String("5x"))
    with assert_raises(contains="no integer part"):
        _ = Duration.from_proto3_json(String("-s"))
    with assert_raises(contains="trailing chars in Duration: 5as"):
        _ = Duration.from_proto3_json(String("5as"))
    with assert_raises(contains="trailing chars in Duration: 5:s"):
        _ = Duration.from_proto3_json(String("5:s"))
    with assert_raises(contains="Duration out of range: 1234567890123s"):
        _ = Duration.from_proto3_json(String("1234567890123s"))
    with assert_raises(contains="Duration out of range: 999999999999s"):
        _ = Duration.from_proto3_json(String("999999999999s"))
    with assert_raises(contains="bad Duration fraction: 1.s"):
        _ = Duration.from_proto3_json(String("1.s"))
    with assert_raises(contains="bad Duration fraction: 1./s"):
        _ = Duration.from_proto3_json(String("1./s"))
    with assert_raises(contains="bad Duration fraction: 1.1234567890s"):
        _ = Duration.from_proto3_json(String("1.1234567890s"))
    with assert_raises(contains="trailing chars in Duration: 1.5as"):
        _ = Duration.from_proto3_json(String("1.5as"))
    with assert_raises(contains="trailing chars in Duration: 1.5:s"):
        _ = Duration.from_proto3_json(String("1.5:s"))
    with assert_raises(contains="Duration JSON must be a string"):
        _ = Duration.read_proto3_json(parse_json_value(String("5")))


def test_duration_text_accepts() raises:
    var top = Duration.from_proto3_json(String("315576000000s"))
    assert_equal(top.seconds, Int64(315576000000))
    var plus = Duration.from_proto3_json(String("+5s"))
    assert_equal(plus.seconds, Int64(5))
    assert_equal(plus.nanos, Int32(0))
    var nine = Duration.from_proto3_json(String("1.123456789s"))
    assert_equal(nine.nanos, Int32(123456789))
    var edge = Duration.from_proto3_json(String("90.09s"))
    assert_equal(edge.seconds, Int64(90))
    assert_equal(edge.nanos, Int32(90000000))


def test_parse_uint_refuses_a_non_digit() raises:
    var ok = List[UInt8]()
    ok.append(0x30)
    ok.append(0x39)
    assert_equal(_parse_uint(ok, 0, 2), 9)
    var below = List[UInt8]()
    below.append(0x31)
    below.append(0x2F)  # '/', one below '0'
    with assert_raises(contains="expected a decimal digit"):
        _ = _parse_uint(below, 0, 2)
    var above = List[UInt8]()
    above.append(0x3A)  # ':', one above '9'
    with assert_raises(contains="expected a decimal digit"):
        _ = _parse_uint(above, 0, 1)


# =============================================================================
# Any.
# =============================================================================


def test_any_empty_forms() raises:
    var a = Any.new()
    assert_equal(a.type_url, String(""))
    assert_equal(len(encode_proto[Any](a)), 0)
    assert_equal(encode_json[Any](a), String("{}"))
    var back = Any.read_proto3_json(parse_json_value(String("{}")))
    assert_equal(back.type_url, String(""))
    assert_false(back.has_json_payload())


def test_any_non_wkt_google_type_writes_bare_type() raises:
    """A `google.protobuf.` name that is no well-known type is an ordinary
    message: with no payload its JSON is `{"@type": ...}` alone."""
    var url = String("type.googleapis.com/google.protobuf.FileDescriptorProto")
    var a = Any(url, List[UInt8]())
    assert_equal(encode_json[Any](a), String('{"@type":"') + url + '"}')
    var near = String("type.googleapis.com/google.protobuf.Durations")
    assert_equal(
        encode_json[Any](Any(near, List[UInt8]())),
        String('{"@type":"') + near + '"}',
    )


def test_any_json_refusals() raises:
    with assert_raises(contains="Any JSON must be an object"):
        _ = Any.read_proto3_json(parse_json_value(String('"t/x"')))
    with assert_raises(contains="'@type' twice"):
        _ = Any.read_proto3_json(
            parse_json_value(String('{"@type":"t/a","@type":"t/b"}'))
        )
    with assert_raises(contains="'@type' must be a string"):
        _ = Any.read_proto3_json(parse_json_value(String('{"@type":5}')))


# =============================================================================
# Empty, FieldMask.
# =============================================================================


def test_empty_json_forms() raises:
    _ = Empty.from_proto3_json(String("{}"))
    with assert_raises(contains="Empty JSON must be the empty object"):
        _ = Empty.read_proto3_json(parse_json_value(String("[]")))
    with assert_raises(contains="Empty JSON must be the empty object"):
        _ = Empty.read_proto3_json(parse_json_value(String('{"a":1}')))
    _ = Empty.read_proto3_json(parse_json_value(String("{}")))


def test_field_mask_edges() raises:
    assert_equal(len(FieldMask.from_proto3_json(String("")).paths), 0)
    with assert_raises(contains="FieldMask JSON must be a string"):
        _ = FieldMask.read_proto3_json(parse_json_value(String('["a"]')))
    var ends = List[String]()
    ends.append(String("a_a"))
    ends.append(String("a_z"))
    assert_equal(FieldMask(ends^).to_proto3_json(), String("aA,aZ"))
    # `_` before a non-letter (below 'a', above 'z') cannot round-trip.
    var digit = List[String]()
    digit.append(String("a_1"))
    with assert_raises(contains="does not round-trip"):
        _ = FieldMask(digit^).to_proto3_json()
    var brace = List[String]()
    brace.append(String("a_{"))
    with assert_raises(contains="does not round-trip"):
        _ = FieldMask(brace^).to_proto3_json()


# =============================================================================
# Value / Struct / ListValue / NullValue.
# =============================================================================


def test_value_empty_boxes_and_unset() raises:
    assert_equal(
        _empty_box_value(VALUE_KIND_STRUCT).to_proto3_json(), String("{}")
    )
    assert_equal(_empty_box_value(VALUE_KIND_LIST).to_proto3_json(), String("[]"))
    # An unset oneof writes no field on the binary wire.
    assert_equal(len(encode_proto[Value](_empty_box_value(VALUE_KIND_UNSET))), 0)


def test_value_unknown_json_kind_refused() raises:
    var jv = JsonValue()
    jv.kind = 99
    with assert_raises(contains="unknown JSON kind in Value conversion"):
        _ = Value.read_proto3_json(jv)


def test_value_number_writer_edges() raises:
    # 2^53 is the first value the integer form does not take.
    assert_equal(
        Value.number(Float64(9007199254740991.0)).to_proto3_json(),
        String("9007199254740991"),
    )
    assert_equal(
        Value.number(Float64(-9007199254740991.0)).to_proto3_json(),
        String("-9007199254740991"),
    )
    assert_equal(
        Value.number(Float64(9007199254740992.0)).to_proto3_json(),
        String("9007199254740992.0"),
    )
    assert_equal(
        Value.number(Float64(-9007199254740992.0)).to_proto3_json(),
        String("-9007199254740992.0"),
    )
    assert_equal(Value.number(Float64(0.0)).to_proto3_json(), String("0"))
    var neg = Value.number(-Float64(0.0)).to_proto3_json()
    assert_equal(neg, String("-0.0"))
    var back = Value.from_proto3_json(neg)
    assert_equal(back.kind, VALUE_KIND_NUMBER)
    assert_equal(bitcast[DType.uint64](back.number_value), UInt64(1) << 63)


def test_struct_and_list_readers_refuse_the_wrong_kind() raises:
    with assert_raises(contains="Struct JSON must be an object"):
        _ = Struct.read_proto3_json(parse_json_value(String("[]")))
    with assert_raises(contains="ListValue JSON must be an array"):
        _ = ListValue.read_proto3_json(parse_json_value(String("{}")))
    with assert_raises(contains="Struct JSON is not an object: [1]"):
        _ = Struct.from_proto3_json(String("[1]"))
    with assert_raises(contains="ListValue JSON is not an array: {}"):
        _ = ListValue.from_proto3_json(String("{}"))
    var s = Struct.from_proto3_json(String('{"a":[true]}'))
    assert_equal(len(s.keys), 1)
    assert_equal(s.keys[0], String("a"))
    assert_equal(s.values[0].kind, VALUE_KIND_LIST)
    var l = ListValue.from_proto3_json(String('[1,"x"]'))
    assert_equal(len(l.values), 2)
    assert_equal(l.values[1].string_value, String("x"))


def test_struct_entry_copy_is_deep() raises:
    var e = _StructEntry(String("k"), Value.string(String("v")))
    var c = _StructEntry(copy=e)
    e.key = String("changed")
    e.value.string_value = String("changed")
    assert_equal(c.key, String("k"))
    assert_equal(c.value.string_value, String("v"))


def test_null_value_enum_surface() raises:
    var n = NULL_VALUE
    assert_equal(n.number(), 0)
    assert_equal(n.json_name(), String("NULL_VALUE"))
    assert_equal(NullValue.from_number(3).number(), 3)
    assert_equal(NullValue.from_json_name(String("NULL_VALUE")).number(), 0)
    assert_true(NullValue.is_known_json_name(String("NULL_VALUE")))
    assert_false(NullValue.is_known_json_name(String("null")))
    assert_equal(NullValue.known_json_names(), String("NULL_VALUE"))
    assert_true(n == NullValue(0))
    assert_false(n == NullValue(1))
    assert_true(n != NullValue(1))
    assert_false(n != NullValue(0))


# =============================================================================
# The scalar wrappers' small helpers.
# =============================================================================


def test_wrapper_helpers() raises:
    assert_false(FloatValue.is_json_string())
    assert_false(UInt32Value.is_json_string())
    assert_false(BoolValue.is_json_string())
    assert_true(StringValue.is_json_string())
    assert_equal(StringValue.from_proto3_json(String('a"b')).value, String('a"b'))
    assert_true(BoolValue.from_proto3_json(String("true")).value)
    assert_false(BoolValue.from_proto3_json(String("false")).value)
    with assert_raises(contains="BoolValue JSON must be true/false: False"):
        _ = BoolValue.from_proto3_json(String("False"))


def test_int32_value_range_ends() raises:
    assert_equal(
        Int32Value.read_proto3_json(parse_json_value(String("2147483647"))).value,
        Int32(2147483647),
    )
    assert_equal(
        Int32Value.read_proto3_json(
            parse_json_value(String("-2147483648"))
        ).value,
        Int32(-2147483648),
    )
    with assert_raises(contains="Int32Value out of range: 2147483648"):
        _ = Int32Value.read_proto3_json(parse_json_value(String("2147483648")))
    with assert_raises(contains="Int32Value out of range: -2147483649"):
        _ = Int32Value.read_proto3_json(
            parse_json_value(String("-2147483649"))
        )


def main() raises:
    test_duration_output_range_ends()
    test_duration_output_signs()
    test_duration_fraction_widths()
    test_duration_text_refusals()
    test_duration_text_accepts()
    test_parse_uint_refuses_a_non_digit()
    test_any_empty_forms()
    test_any_non_wkt_google_type_writes_bare_type()
    test_any_json_refusals()
    test_empty_json_forms()
    test_field_mask_edges()
    test_value_empty_boxes_and_unset()
    test_value_unknown_json_kind_refused()
    test_value_number_writer_edges()
    test_struct_and_list_readers_refuse_the_wrong_kind()
    test_struct_entry_copy_is_deep()
    test_null_value_enum_surface()
    test_wrapper_helpers()
    test_int32_value_range_ends()
    print("test_wkt_edges: all tests passed")
