# =============================================================================
# test_proto_codec_json_encoder.mojo — the text `JsonEncoder` writes.
# =============================================================================
#
# `JsonEncoder` is driven directly, one writer at a time, and its output is
# compared with the proto3 JSON text worked out by hand from the protobuf JSON
# mapping. The decoder is never involved.
#
#   J1  every singular writer in its mapped form: 64-bit integers as JSON
#       strings, 32-bit integers as numbers (sint / fixed / sfixed the same as
#       their plain width), bytes as padded base64, NaN and the infinities as
#       the strings "NaN" / "Infinity" / "-Infinity", bool as a literal, an
#       enum as its name, `google.protobuf.NullValue` as null, strings with
#       their escapes. Catches: a 64-bit integer written as a number, a
#       sint / fixed / sfixed writer that signs or widths differently from
#       its plain neighbour, a missing escape, a missing comma.
#   J2  a nested message is a nested object and a well-known type is its own
#       canonical value, as a field and as a list element. Catches: a
#       well-known type written as `{field: value}`.
#   J3  a repeated field is `"name":[a,b]`, every element type; an empty one
#       leaves no bytes and does not disturb the comma state of the fields
#       around it. Catches: `"xs":[]` on the wire (it would clear a list
#       under a merge-patch), a stray comma after a dropped field.
#   J4  a map field is an object: the key of every key type is a quoted
#       string, values of every kind render as their singular form, entries
#       are comma-separated, an empty map leaves no bytes, and a well-known
#       type as a key is refused. Catches: an unquoted numeric key (invalid
#       JSON), a lost comma between entries, a map written as an array.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_json import JsonValue
from komira_proto_codec import (
    JsonEncoder,
    ProtoEnum,
    ProtoNullValueEnum,
    Proto3JsonWkt,
    Serializable,
    WireDecoder,
    WireEncoder,
)


@fieldwise_init
struct Level(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("LEVEL_") + String(self.value)

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return True

    @staticmethod
    def known_json_names() -> String:
        return String("")


@fieldwise_init
struct Nothing(ProtoNullValueEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("NULL_VALUE")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "NULL_VALUE"

    @staticmethod
    def known_json_names() -> String:
        return String("NULL_VALUE")


@fieldwise_init
struct Leaf(Serializable, Copyable, Movable):
    """`message Leaf { int64 n = 1; }`."""

    var n: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "n", self.n)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        return Leaf(0)


@fieldwise_init
struct Span2(Proto3JsonWkt, Copyable, Movable):
    """A stand-in for a well-known type whose JSON form is a string, like
    `google.protobuf.Duration`: seconds written as `"<n>s"`."""

    var seconds: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "seconds", self.seconds)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        return Span2(0)

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        var text = String('"') + String(self.seconds) + String('s"')
        buf.extend(text.as_bytes())

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Span2(0)


def _text(var e: JsonEncoder) -> String:
    e.finish()
    return e^.into_string()


# =============================================================================
# J1
# =============================================================================


def test_j1_empty_message_and_comma_placement() raises:
    assert_equal(_text(JsonEncoder()), String("{}"), "no field: an empty object")
    var e = JsonEncoder()
    e.write_bool_field(1, "a", True)
    e.write_bool_field(2, "b", False)
    e.write_bool_field(3, "c", True)
    assert_equal(
        _text(e^),
        String('{"a":true,"b":false,"c":true}'),
        "a comma between fields and none after the last",
    )
    assert_true(JsonEncoder.OMITS_IMPLICIT_DEFAULTS, "JSON omits defaults")
    print("  test_j1_empty_message_and_comma_placement: PASS")


def test_j1_scalar_writers() raises:
    var e = JsonEncoder()
    e.write_string_field(1, "s", String("abc"))
    assert_equal(_text(e^), String('{"s":"abc"}'))

    e = JsonEncoder()
    var esc = String('a"b\\c\n\t/') + chr(1) + chr(31) + String("é")
    e.write_string_field(1, "s", esc)
    assert_equal(
        _text(e^),
        String('{"s":"a\\"b\\\\c\\n\\t/\\u0001\\u001fé"}'),
        "quote, backslash, control characters escaped; non-ASCII verbatim",
    )

    e = JsonEncoder()
    e.write_string_field(1, "weird\"name", String(""))
    assert_equal(
        _text(e^),
        String('{"weird\\"name":""}'),
        "the field name is escaped too; an explicit empty string is written",
    )

    e = JsonEncoder()
    var raw = List[UInt8]()
    raw.append(UInt8(0))
    raw.append(UInt8(1))
    raw.append(UInt8(255))
    e.write_bytes_field(1, "b", raw)
    assert_equal(_text(e^), String('{"b":"AAH/"}'), "standard base64 alphabet")

    e = JsonEncoder()
    var one = List[UInt8]()
    one.append(UInt8(0x66))
    var two = List[UInt8]()
    two.append(UInt8(0x66))
    two.append(UInt8(0x6F))
    e.write_bytes_field(1, "one", one)
    e.write_bytes_field(2, "two", two)
    e.write_bytes_field(3, "none", List[UInt8]())
    assert_equal(
        _text(e^),
        String('{"one":"Zg==","two":"Zm8=","none":""}'),
        "base64 padding for 1 and 2 trailing bytes; empty bytes",
    )

    e = JsonEncoder()
    e.write_i64_field(1, "a", Int64(-1))
    e.write_i64_field(2, "b", Int64.MIN)
    e.write_i64_field(3, "c", Int64.MAX)
    assert_equal(
        _text(e^),
        String(
            '{"a":"-1","b":"-9223372036854775808","c":"9223372036854775807"}'
        ),
        "int64 is a JSON string",
    )

    e = JsonEncoder()
    e.write_u64_field(1, "a", UInt64.MAX)
    e.write_u64_field(2, "b", UInt64(0))
    assert_equal(
        _text(e^),
        String('{"a":"18446744073709551615","b":"0"}'),
        "uint64 is a JSON string, unsigned",
    )

    e = JsonEncoder()
    e.write_i32_field(1, "a", Int32(-1))
    e.write_i32_field(2, "b", Int32.MIN)
    e.write_u32_field(3, "c", UInt32.MAX)
    assert_equal(
        _text(e^),
        String('{"a":-1,"b":-2147483648,"c":4294967295}'),
        "32-bit integers are JSON numbers",
    )

    e = JsonEncoder()
    e.write_sint64_field(1, "a", Int64.MIN)
    e.write_sfixed64_field(2, "b", Int64(-5))
    e.write_fixed64_field(3, "c", UInt64.MAX)
    e.write_sint32_field(4, "d", Int32.MIN)
    e.write_sfixed32_field(5, "e", Int32(-5))
    e.write_fixed32_field(6, "f", UInt32.MAX)
    assert_equal(
        _text(e^),
        String(
            '{"a":"-9223372036854775808","b":"-5","c":"18446744073709551615",'
            '"d":-2147483648,"e":-5,"f":4294967295}'
        ),
        "sint / sfixed / fixed render as their plain width",
    )

    e = JsonEncoder()
    e.write_f64_field(1, "a", Float64(1.5))
    e.write_f64_field(2, "b", Float64(-2.0))
    e.write_f32_field(3, "c", Float32(0.5))
    assert_equal(_text(e^), String('{"a":1.5,"b":-2.0,"c":0.5}'))

    e = JsonEncoder()
    var nan = Float64(0.0) / Float64(0.0)
    var inf = Float64(1.0) / Float64(0.0)
    e.write_f64_field(1, "a", nan)
    e.write_f64_field(2, "b", inf)
    e.write_f64_field(3, "c", -inf)
    e.write_f32_field(4, "d", Float32(nan))
    e.write_f32_field(5, "e", Float32(inf))
    e.write_f32_field(6, "f", Float32(-inf))
    assert_equal(
        _text(e^),
        String(
            '{"a":"NaN","b":"Infinity","c":"-Infinity",'
            '"d":"NaN","e":"Infinity","f":"-Infinity"}'
        ),
        "non-finite values are strings, for both float widths",
    )

    e = JsonEncoder()
    e.write_enum_field(1, "level", Level(2))
    e.write_enum_field(2, "gone", Nothing(0))
    assert_equal(
        _text(e^),
        String('{"level":"LEVEL_2","gone":null}'),
        "an enum is its name; NullValue is null",
    )
    print("  test_j1_scalar_writers: PASS")


# =============================================================================
# J2
# =============================================================================


def test_j2_messages_and_well_known_types() raises:
    var e = JsonEncoder()
    e.write_i32_field(1, "a", Int32(1))
    e.write_message_field(2, "leaf", Leaf(7))
    e.write_message_field(3, "span", Span2(90))
    e.write_message_field(4, "other", Leaf(0))
    assert_equal(
        _text(e^),
        String(
            '{"a":1,"leaf":{"n":"7"},"span":"90s","other":{"n":"0"}}'
        ),
        "an object for a message, the canonical value for a WKT",
    )

    # A message that is the first field, and one that is the only field.
    e = JsonEncoder()
    e.write_message_field(1, "span", Span2(1))
    assert_equal(_text(e^), String('{"span":"1s"}'))
    print("  test_j2_messages_and_well_known_types: PASS")


# =============================================================================
# J3
# =============================================================================


def test_j3_repeated_elements_of_every_type() raises:
    var e = JsonEncoder()
    e.begin_list_field(1, "s")
    e.write_string_element(1, String("a"))
    e.write_string_element(1, String("b\n"))
    e.end_list_field()
    e.begin_list_field(2, "b")
    var raw = List[UInt8]()
    raw.append(UInt8(255))
    e.write_bytes_element(2, raw)
    e.write_bytes_element(2, List[UInt8]())
    e.end_list_field()
    e.begin_list_field(3, "i64")
    e.write_i64_element(3, Int64(-1))
    e.write_i64_element(3, Int64.MAX)
    e.end_list_field()
    e.begin_list_field(4, "i32")
    e.write_i32_element(4, Int32(-1))
    e.write_i32_element(4, Int32.MAX)
    e.end_list_field()
    e.begin_list_field(5, "u64")
    e.write_u64_element(5, UInt64.MAX)
    e.end_list_field()
    e.begin_list_field(6, "u32")
    e.write_u32_element(6, UInt32.MAX)
    e.write_u32_element(6, UInt32(0))
    e.end_list_field()
    assert_equal(
        _text(e^),
        String(
            '{"s":["a","b\\n"],"b":["/w==",""],"i64":["-1","9223372036854775807"],'
            '"i32":[-1,2147483647],"u64":["18446744073709551615"],'
            '"u32":[4294967295,0]}'
        ),
    )

    e = JsonEncoder()
    var nan = Float64(0.0) / Float64(0.0)
    e.begin_list_field(1, "f64")
    e.write_f64_element(1, Float64(1.5))
    e.write_f64_element(1, nan)
    e.end_list_field()
    e.begin_list_field(2, "f32")
    e.write_f32_element(2, Float32(0.25))
    e.write_f32_element(2, Float32(-(Float64(1.0) / Float64(0.0))))
    e.end_list_field()
    e.begin_list_field(3, "bool")
    e.write_bool_element(3, True)
    e.write_bool_element(3, False)
    e.end_list_field()
    assert_equal(
        _text(e^),
        String(
            '{"f64":[1.5,"NaN"],"f32":[0.25,"-Infinity"],"bool":[true,false]}'
        ),
    )

    e = JsonEncoder()
    e.begin_list_field(1, "sint64")
    e.write_sint64_element(1, Int64.MIN)
    e.end_list_field()
    e.begin_list_field(2, "sfixed64")
    e.write_sfixed64_element(2, Int64(-2))
    e.end_list_field()
    e.begin_list_field(3, "fixed64")
    e.write_fixed64_element(3, UInt64.MAX)
    e.end_list_field()
    e.begin_list_field(4, "sint32")
    e.write_sint32_element(4, Int32.MIN)
    e.end_list_field()
    e.begin_list_field(5, "sfixed32")
    e.write_sfixed32_element(5, Int32(-2))
    e.end_list_field()
    e.begin_list_field(6, "fixed32")
    e.write_fixed32_element(6, UInt32.MAX)
    e.end_list_field()
    assert_equal(
        _text(e^),
        String(
            '{"sint64":["-9223372036854775808"],"sfixed64":["-2"],'
            '"fixed64":["18446744073709551615"],"sint32":[-2147483648],'
            '"sfixed32":[-2],"fixed32":[4294967295]}'
        ),
        "repeated sint / sfixed / fixed render as their plain width",
    )

    e = JsonEncoder()
    e.begin_list_field(1, "enums")
    e.write_enum_element(1, Level(1))
    e.write_enum_element(1, Level(2))
    e.end_list_field()
    e.begin_list_field(2, "nulls")
    e.write_enum_element(2, Nothing(0))
    e.write_enum_element(2, Nothing(0))
    e.end_list_field()
    e.begin_list_field(3, "leaves")
    e.write_message_element(3, Leaf(1))
    e.write_message_element(3, Leaf(2))
    e.end_list_field()
    e.begin_list_field(4, "spans")
    e.write_message_element(4, Span2(3))
    e.write_message_element(4, Span2(4))
    e.end_list_field()
    assert_equal(
        _text(e^),
        String(
            '{"enums":["LEVEL_1","LEVEL_2"],"nulls":[null,null],'
            '"leaves":[{"n":"1"},{"n":"2"}],"spans":["3s","4s"]}'
        ),
    )
    print("  test_j3_repeated_elements_of_every_type: PASS")


def test_j3_an_empty_list_leaves_no_bytes() raises:
    # Empty list first, in the middle, last, and alone.
    var e = JsonEncoder()
    e.begin_list_field(1, "empty")
    e.end_list_field()
    e.write_i32_field(2, "a", Int32(1))
    assert_equal(_text(e^), String('{"a":1}'), "empty list before the first field")

    e = JsonEncoder()
    e.write_i32_field(1, "a", Int32(1))
    e.begin_list_field(2, "empty")
    e.end_list_field()
    e.write_i32_field(3, "b", Int32(2))
    assert_equal(_text(e^), String('{"a":1,"b":2}'), "empty list between fields")

    e = JsonEncoder()
    e.write_i32_field(1, "a", Int32(1))
    e.begin_list_field(2, "empty")
    e.end_list_field()
    assert_equal(_text(e^), String('{"a":1}'), "empty list after the last field")

    e = JsonEncoder()
    e.begin_list_field(1, "empty")
    e.end_list_field()
    assert_equal(_text(e^), String("{}"), "empty list alone")

    e = JsonEncoder()
    e.begin_list_field(1, "x")
    e.end_list_field()
    e.begin_list_field(2, "y")
    e.write_i32_element(2, Int32(5))
    e.end_list_field()
    e.begin_list_field(3, "z")
    e.end_list_field()
    assert_equal(
        _text(e^),
        String('{"y":[5]}'),
        "a non-empty list among empty ones keeps its own commas",
    )
    print("  test_j3_an_empty_list_leaves_no_bytes: PASS")


# =============================================================================
# J4
# =============================================================================


def test_j4_map_keys_are_quoted_for_every_key_type() raises:
    var e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_string_field(1, "key", String('k"'))
    e.write_i32_field(2, "value", Int32(1))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(_text(e^), String('{"m":{"k\\"":1}}'), "string key, escaped")

    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_i32_field(1, "key", Int32(-7))
    e.write_string_field(2, "value", String("a"))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_i32_field(1, "key", Int32(8))
    e.write_string_field(2, "value", String("b"))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(
        _text(e^), String('{"m":{"-7":"a","8":"b"}}'), "int32 keys quoted, comma between entries"
    )

    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_u32_field(1, "key", UInt32.MAX)
    e.write_bool_field(2, "value", True)
    e.end_map_entry()
    e.end_map_field()
    assert_equal(_text(e^), String('{"m":{"4294967295":true}}'), "uint32 key")

    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_bool_field(1, "key", True)
    e.write_i64_field(2, "value", Int64(-3))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_bool_field(1, "key", False)
    e.write_u64_field(2, "value", UInt64(3))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(
        _text(e^),
        String('{"m":{"true":"-3","false":"3"}}'),
        "bool keys quoted; 64-bit values are strings",
    )

    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_i64_field(1, "key", Int64(-3))
    e.write_f64_field(2, "value", Float64(1.5))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_u64_field(1, "key", UInt64.MAX)
    e.write_f32_field(2, "value", Float32(0.5))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(
        _text(e^),
        String('{"m":{"-3":1.5,"18446744073709551615":0.5}}'),
        "64-bit keys are quoted by their own writers",
    )

    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_sint32_field(1, "key", Int32(-1))
    e.write_sint64_field(2, "value", Int64(-1))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_fixed32_field(1, "key", UInt32(2))
    e.write_fixed64_field(2, "value", UInt64(2))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_sfixed32_field(1, "key", Int32(-3))
    e.write_sfixed64_field(2, "value", Int64(-3))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(
        _text(e^),
        String('{"m":{"-1":"-1","2":"2","-3":"-3"}}'),
        "sint / fixed / sfixed keys are quoted too",
    )
    print("  test_j4_map_keys_are_quoted_for_every_key_type: PASS")


def test_j4_map_values_and_surroundings() raises:
    var e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    e.write_enum_field(1, "key", Level(1))
    e.write_enum_field(2, "value", Level(2))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(_text(e^), String('{"m":{"LEVEL_1":"LEVEL_2"}}'), "enum key and value")

    e = JsonEncoder()
    e.write_i32_field(1, "before", Int32(1))
    e.begin_map_field(2, "m")
    e.begin_map_entry()
    e.write_string_field(1, "key", String("a"))
    e.write_message_field(2, "value", Leaf(5))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_string_field(1, "key", String("b"))
    e.write_message_field(2, "value", Span2(6))
    e.end_map_entry()
    e.end_map_field()
    e.write_i32_field(3, "after", Int32(2))
    assert_equal(
        _text(e^),
        String(
            '{"before":1,"m":{"a":{"n":"5"},"b":"6s"},"after":2}'
        ),
        "message and WKT values; fields around the map keep their commas",
    )

    # An empty map leaves no bytes, wherever it sits.
    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.end_map_field()
    e.write_i32_field(2, "a", Int32(1))
    e.begin_map_field(3, "n")
    e.end_map_field()
    assert_equal(_text(e^), String('{"a":1}'), "empty maps are dropped")

    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.end_map_field()
    assert_equal(_text(e^), String("{}"), "an empty map alone")

    # A well-known type cannot be a map key.
    e = JsonEncoder()
    e.begin_map_field(1, "m")
    e.begin_map_entry()
    var refused = String("")
    try:
        e.write_message_field(1, "key", Span2(1))
    except err:
        refused = String(err)
    assert_equal(refused, String("JsonError: a well-known type cannot be a map key"))
    print("  test_j4_map_values_and_surroundings: PASS")


def main() raises:
    test_j1_empty_message_and_comma_placement()
    test_j1_scalar_writers()
    test_j2_messages_and_well_known_types()
    test_j3_repeated_elements_of_every_type()
    test_j3_an_empty_list_leaves_no_bytes()
    test_j4_map_keys_are_quoted_for_every_key_type()
    test_j4_map_values_and_surroundings()
