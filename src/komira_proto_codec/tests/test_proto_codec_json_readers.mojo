# =============================================================================
# test_proto_codec_json_readers.mojo — what `JsonDecoder` reads out of proto3
# JSON text written by hand.
# =============================================================================
#
# Every document is written from the protobuf JSON mapping, not produced by
# `JsonEncoder`. `JsonDecoder` is driven directly, reader by reader.
#
#   K1  every singular reader returns the value its text denotes: 64-bit
#       integers from a string and from a number, 32-bit integers, sint /
#       fixed / sfixed as their plain width, padded base64, "NaN" /
#       "Infinity" / "-Infinity" and decimal text for both float widths,
#       booleans. Catches: a reader wired to the wrong parser, a string form
#       that is not accepted, a lost sign.
#   K2  an enum reads as its name, as a number and as numeric text; an
#       undeclared name is refused with the name, its path and the declared
#       names (and is folded to zero only by the lenient decoder);
#       `google.protobuf.NullValue` reads null. Catches: an undeclared name
#       that decodes to 0 silently, a numeric string looked up as a name.
#   K3  a value of the wrong JSON kind, text that is not the type, a source
#       that is not an object and a read before `next_field` are refused by
#       name. Catches: a reader that coerces (a number read as a string).
#   K4  a repeated field reads from an array for every element type, strings,
#       bytes, enums (all three spellings) and messages included; a field that
#       is not an array is refused. Catches: a reader that stops at the first
#       element, one that appends to the wrong list type.
#   K5  a nested message, a repeated message and a map of messages decode with
#       the path of what they decoded, so a refusal inside one says where, and
#       a well-known type read through any of those paths carries the same
#       locator. Catches: a refusal that names `$` for a field three levels in.
#   K6  the five map readers (string / int32 / int64 values, int64 keys,
#       message values); an int64 key that is not an integer and a field that
#       is not an object are refused. Catches: key and value swapped, a key
#       parsed as the wrong width.
#   K7  `null` is absent, except for the keys named to `keep_null_fields`;
#       `copy` is a deep clone; `skip` refuses an unknown field in strict
#       mode and lets it pass in lenient mode. Catches: a null read as a
#       value, a clone that shares its cursor.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_json import JsonValue
from komira_proto_codec import (
    JsonDecoder,
    UnknownFields,
    ProtoEnum,
    ProtoNullValueEnum,
    Proto3JsonWkt,
    Serializable,
    WireDecoder,
    WireEncoder,
)


@fieldwise_init
struct Level(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    """`enum Level { UNSET = 0; LOW = 1; HIGH = 2; }`."""

    var value: Int

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        if self.value == 1:
            return String("LOW")
        if self.value == 2:
            return String("HIGH")
        return String("UNSET")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        if s == "LOW":
            return Self(1)
        if s == "HIGH":
            return Self(2)
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "UNSET" or s == "LOW" or s == "HIGH"

    @staticmethod
    def known_json_names() -> String:
        return String("UNSET,LOW,HIGH")


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
    """`message Leaf { int64 n = 1; }`, strict about its vocabulary."""

    var n: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("t.Leaf", "n")
        var n = Int64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.json_name == "n":
                n = dec.read_i64()
            else:
                dec.skip()
        return Leaf(n)


@fieldwise_init
struct Span2(Proto3JsonWkt, Copyable, Movable):
    """A well-known type whose JSON form is the string `"<n>s"`."""

    var seconds: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        return Span2(0)

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        pass

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        var text = v.as_string()
        if not text.endswith("s"):
            raise Error("not a span: " + text)
        return Span2(Int64(atol(String(text.removesuffix("s")))))


def _at(text: String) raises -> JsonDecoder:
    """A decoder positioned on the first field of `text`."""
    var d = JsonDecoder.from_text(text)
    var k = d.next_field()
    assert_false(k.end, "a field was expected in " + text)
    return d^


def _is_nan(x: Float64) -> Bool:
    return x != x


# =============================================================================
# K1
# =============================================================================


def test_k1_strings_and_bytes() raises:
    var d = _at('{"v":"abc"}')
    assert_equal(d.read_string(), String("abc"))
    d = _at('{"v":"a\\u00e9\\n\\"\\\\"}')
    assert_equal(d.read_string(), String('aé\n"\\'), "escapes decode")
    d = _at('{"v":""}')
    assert_equal(d.read_string(), String(""))

    d = _at('{"v":"AAH/"}')
    var raw = d.read_bytes()
    assert_equal(len(raw), 3)
    assert_equal(Int(raw[0]), 0)
    assert_equal(Int(raw[1]), 1)
    assert_equal(Int(raw[2]), 255)
    d = _at('{"v":"Zg=="}')
    assert_equal(len(d.read_bytes()), 1, "one byte, two pad characters")
    d = _at('{"v":"Zm8="}')
    assert_equal(len(d.read_bytes()), 2, "two bytes, one pad character")
    d = _at('{"v":""}')
    assert_equal(len(d.read_bytes()), 0)
    print("  test_k1_strings_and_bytes: PASS")


def test_k1_integers() raises:
    var d = _at('{"v":"-1"}')
    assert_equal(d.read_i64(), Int64(-1), "int64 from a string")
    d = _at('{"v":-1}')
    assert_equal(d.read_i64(), Int64(-1), "int64 from a number")
    d = _at('{"v":"-9223372036854775808"}')
    assert_equal(d.read_i64(), Int64.MIN)
    d = _at('{"v":9223372036854775807}')
    assert_equal(d.read_i64(), Int64.MAX)

    d = _at('{"v":-1}')
    assert_equal(d.read_i32(), Int32(-1))
    d = _at('{"v":"-2147483648"}')
    assert_equal(d.read_i32(), Int32.MIN, "int32 from a string")
    d = _at('{"v":2147483647}')
    assert_equal(d.read_i32(), Int32.MAX)

    d = _at('{"v":"18446744073709551615"}')
    assert_equal(d.read_u64(), UInt64.MAX, "uint64 above Int64.MAX")
    d = _at('{"v":5}')
    assert_equal(d.read_u64(), UInt64(5))
    d = _at('{"v":4294967295}')
    assert_equal(d.read_u32(), UInt32.MAX)
    d = _at('{"v":"4294967295"}')
    assert_equal(d.read_u32(), UInt32.MAX, "uint32 from a string")

    d = _at('{"v":"-9223372036854775808"}')
    assert_equal(d.read_sint64(), Int64.MIN)
    d = _at('{"v":"-9223372036854775808"}')
    assert_equal(d.read_sfixed64(), Int64.MIN)
    d = _at('{"v":"18446744073709551615"}')
    assert_equal(d.read_fixed64(), UInt64.MAX)
    d = _at('{"v":-2147483648}')
    assert_equal(d.read_sint32(), Int32.MIN)
    d = _at('{"v":-2147483648}')
    assert_equal(d.read_sfixed32(), Int32.MIN)
    d = _at('{"v":4294967295}')
    assert_equal(d.read_fixed32(), UInt32.MAX)
    print("  test_k1_integers: PASS")


def test_k1_floats_and_bools() raises:
    var d = _at('{"v":1.5}')
    assert_equal(d.read_f64(), Float64(1.5))
    d = _at('{"v":"1.5"}')
    assert_equal(d.read_f64(), Float64(1.5), "double from a string")
    d = _at('{"v":-2e3}')
    assert_equal(d.read_f64(), Float64(-2000.0), "an exponent")
    d = _at('{"v":"NaN"}')
    assert_true(_is_nan(d.read_f64()))
    d = _at('{"v":"Infinity"}')
    assert_equal(d.read_f64(), Float64(1.0) / Float64(0.0))
    d = _at('{"v":"-Infinity"}')
    assert_equal(d.read_f64(), -(Float64(1.0) / Float64(0.0)))

    d = _at('{"v":0.5}')
    assert_equal(d.read_f32(), Float32(0.5))
    d = _at('{"v":"0.25"}')
    assert_equal(d.read_f32(), Float32(0.25), "float from a string")
    d = _at('{"v":"NaN"}')
    assert_true(_is_nan(Float64(d.read_f32())))
    d = _at('{"v":"Infinity"}')
    assert_equal(d.read_f32(), Float32(Float64(1.0) / Float64(0.0)))
    d = _at('{"v":"-Infinity"}')
    assert_equal(d.read_f32(), Float32(-(Float64(1.0) / Float64(0.0))))

    d = _at('{"v":true}')
    assert_true(d.read_bool())
    d = _at('{"v":false}')
    assert_false(d.read_bool())
    print("  test_k1_floats_and_bools: PASS")


# =============================================================================
# K2
# =============================================================================


def _enum_refusal(text: String) -> String:
    try:
        var d = _at(text)
        _ = d.read_enum[Level]()
    except e:
        return String(e)
    return String("")


def test_k2_enums() raises:
    var d = _at('{"level":"HIGH"}')
    assert_equal(d.read_enum[Level]().value, 2, "a name")
    d = _at('{"level":"UNSET"}')
    assert_equal(d.read_enum[Level]().value, 0, "the declared zero name")
    d = _at('{"level":1}')
    assert_equal(d.read_enum[Level]().value, 1, "a number")
    d = _at('{"level":-3}')
    assert_equal(d.read_enum[Level]().value, -3, "a negative number")
    d = _at('{"level":"2"}')
    assert_equal(d.read_enum[Level]().value, 2, "numeric text is a number, not a name")
    d = _at('{"level":"-1"}')
    assert_equal(d.read_enum[Level]().value, -1)

    var msg = _enum_refusal('{"level":"MEDIUM"}')
    assert_true(
        msg.startswith(
            'JsonError: unknown enum value "MEDIUM" at $.level (line 1)'
            " — declared values are: UNSET,LOW,HIGH. "
        ),
        String("an undeclared name is refused with its path: ") + msg,
    )
    # "" and "+" are names, and not declared ones.
    assert_true(_enum_refusal('{"level":""}').startswith('JsonError: unknown enum value "" at $.level'))
    assert_true(_enum_refusal('{"level":"+"}').startswith('JsonError: unknown enum value "+" at $.level'))
    assert_true(_enum_refusal('{"level":"1.5"}').startswith('JsonError: unknown enum value "1.5" at $.level'))
    assert_true(_enum_refusal('{"level":"1x"}').startswith('JsonError: unknown enum value "1x" at $.level'))

    # The lenient decoder folds an undeclared name to zero.
    var lenient = JsonDecoder.from_text_lenient('{"level":"MEDIUM"}')
    _ = lenient.next_field()
    assert_equal(lenient.read_enum[Level]().value, 0, "lenient: undeclared is zero")

    # NullValue: null reads as its one value; other spellings as any enum.
    var keep = JsonDecoder.from_text('{"v":null}')
    keep.keep_null_fields("v")
    _ = keep.next_field()
    assert_equal(keep.read_enum[Nothing]().value, 0, "null is NULL_VALUE")
    d = _at('{"v":"NULL_VALUE"}')
    assert_equal(d.read_enum[Nothing]().value, 0, "the name")
    d = _at('{"v":7}')
    assert_equal(d.read_enum[Nothing]().value, 7, "a number goes through from_number")
    print("  test_k2_enums: PASS")


# =============================================================================
# K3
# =============================================================================


def _read(text: String, op: Int) -> String:
    """The refusal (or "") of reading the first field of `text` with `op`."""
    try:
        var d = _at(text)
        if op == 0:
            _ = d.read_string()
        elif op == 1:
            _ = d.read_i64()
        elif op == 2:
            _ = d.read_u64()
        elif op == 3:
            _ = d.read_bool()
        elif op == 4:
            _ = d.read_f64()
        elif op == 5:
            _ = d.read_f32()
        elif op == 6:
            _ = d.read_bytes()
        elif op == 7:
            _ = d.read_i32()
        elif op == 8:
            _ = d.read_u32()
    except e:
        return String(e)
    return String("")


def test_k3_wrong_kind_and_malformed_text_are_refused() raises:
    assert_equal(_read('{"v":1}', 0), String("JsonError: as_string() on a non-string value"))
    assert_equal(_read('{"v":true}', 1), String("JsonError: as_int64() on a non-numeric value"))
    assert_equal(_read('{"v":"x"}', 1), String("JsonError: non-digit in integer text"))
    assert_equal(_read('{"v":1.5}', 1), String("JsonError: non-digit in integer text"))
    assert_equal(_read('{"v":""}', 1), String("JsonError: empty integer text"))
    assert_equal(
        _read('{"v":"9223372036854775808"}', 1),
        String("JsonError: integer text out of range"),
        "int64 one past the maximum",
    )
    assert_equal(
        _read('{"v":"-9223372036854775809"}', 1),
        String("JsonError: integer text out of range"),
        "int64 one below the minimum",
    )
    assert_equal(
        _read('{"v":"18446744073709551616"}', 2),
        String("JsonError: integer text out of range"),
        "uint64 one past the maximum",
    )
    assert_equal(_read('{"v":-1}', 2), String("JsonError: non-digit in integer text"))
    assert_equal(_read('{"v":"true"}', 3), String("JsonError: as_bool() on a non-bool value"))
    assert_equal(_read('{"v":1}', 3), String("JsonError: as_bool() on a non-bool value"))
    assert_equal(_read('{"v":true}', 4), String("JsonError: as_float64() on a non-numeric value"))
    assert_equal(_read('{"v":"x"}', 4), String("JsonError: not a proto3 double: x"))
    assert_equal(_read('{"v":"x"}', 5), String("JsonError: not a proto3 float: x"))
    assert_equal(
        _read('{"v":1e39}', 5),
        String("JsonError: value out of float32 range: 1e39"),
    )
    assert_true(
        _read('{"v":"!!"}', 6).startswith("komira_encoding.InvalidCharacter"),
        "text outside the base64 alphabet",
    )
    assert_equal(_read('{"v":true}', 7), String("JsonError: as_int64() on a non-numeric value"))
    assert_equal(_read('{"v":"x"}', 8), String("JsonError: non-digit in integer text"))

    var d = JsonDecoder.from_text("[1]")
    var msg = String("")
    try:
        _ = d.next_field()
    except e:
        msg = String(e)
    assert_equal(msg, String("JsonError: decode source is not a JSON object"))

    d = JsonDecoder.from_text('{"v":1}')
    msg = String("")
    try:
        _ = d.read_i64()
    except e:
        msg = String(e)
    assert_equal(msg, String("JsonError: read_* before next_field()"))

    # After the last field the cursor is past the end, and a read says so.
    d = JsonDecoder.from_text('{"v":1}')
    _ = d.next_field()
    assert_true(d.next_field().end)
    msg = String("")
    try:
        _ = d.read_i64()
    except e:
        msg = String(e)
    assert_equal(msg, String("JsonError: read_* before next_field()"))
    print("  test_k3_wrong_kind_and_malformed_text_are_refused: PASS")


# =============================================================================
# K4
# =============================================================================


def test_k4_repeated_scalars() raises:
    var d = _at('{"v":["a","","c"]}')
    var strs = List[String]()
    d.read_into_repeated_string(strs)
    assert_equal(len(strs), 3)
    assert_equal(strs[0], String("a"))
    assert_equal(strs[1], String(""))
    assert_equal(strs[2], String("c"))

    d = _at('{"v":["Zg==","AAH/",""]}')
    var blobs = List[List[UInt8]]()
    d.read_into_repeated_bytes(blobs)
    assert_equal(len(blobs), 3)
    assert_equal(len(blobs[0]), 1)
    assert_equal(len(blobs[1]), 3)
    assert_equal(Int(blobs[1][2]), 255)
    assert_equal(len(blobs[2]), 0)

    d = _at('{"v":["-1",2,"9223372036854775807"]}')
    var i64s = List[Int64]()
    d.read_into_repeated_i64(i64s)
    assert_equal(len(i64s), 3)
    assert_equal(i64s[0], Int64(-1))
    assert_equal(i64s[1], Int64(2))
    assert_equal(i64s[2], Int64.MAX)

    d = _at('{"v":[-1,"2",2147483647]}')
    var i32s = List[Int32]()
    d.read_into_repeated_i32(i32s)
    assert_equal(len(i32s), 3)
    assert_equal(i32s[0], Int32(-1))
    assert_equal(i32s[1], Int32(2))
    assert_equal(i32s[2], Int32.MAX)

    d = _at('{"v":["18446744073709551615",3]}')
    var u64s = List[UInt64]()
    d.read_into_repeated_u64(u64s)
    assert_equal(len(u64s), 2)
    assert_equal(u64s[0], UInt64.MAX)
    assert_equal(u64s[1], UInt64(3))

    d = _at('{"v":[4294967295,"7"]}')
    var u32s = List[UInt32]()
    d.read_into_repeated_u32(u32s)
    assert_equal(len(u32s), 2)
    assert_equal(u32s[0], UInt32.MAX)
    assert_equal(u32s[1], UInt32(7))

    d = _at('{"v":[1.5,"NaN","-Infinity"]}')
    var f64s = List[Float64]()
    d.read_into_repeated_f64(f64s)
    assert_equal(len(f64s), 3)
    assert_equal(f64s[0], Float64(1.5))
    assert_true(_is_nan(f64s[1]))
    assert_equal(f64s[2], -(Float64(1.0) / Float64(0.0)))

    d = _at('{"v":[0.5,"Infinity"]}')
    var f32s = List[Float32]()
    d.read_into_repeated_f32(f32s)
    assert_equal(len(f32s), 2)
    assert_equal(f32s[0], Float32(0.5))
    assert_equal(f32s[1], Float32(Float64(1.0) / Float64(0.0)))

    d = _at('{"v":[true,false,true]}')
    var bools = List[Bool]()
    d.read_into_repeated_bool(bools)
    assert_equal(len(bools), 3)
    assert_true(bools[0])
    assert_false(bools[1])
    assert_true(bools[2])

    d = _at('{"v":["-9223372036854775808"]}')
    var s64s = List[Int64]()
    d.read_into_repeated_sint64(s64s)
    assert_equal(s64s[0], Int64.MIN)
    d = _at('{"v":["-9223372036854775808"]}')
    var sf64s = List[Int64]()
    d.read_into_repeated_sfixed64(sf64s)
    assert_equal(sf64s[0], Int64.MIN)
    d = _at('{"v":["18446744073709551615"]}')
    var fx64s = List[UInt64]()
    d.read_into_repeated_fixed64(fx64s)
    assert_equal(fx64s[0], UInt64.MAX)
    d = _at('{"v":[-2147483648]}')
    var s32s = List[Int32]()
    d.read_into_repeated_sint32(s32s)
    assert_equal(s32s[0], Int32.MIN)
    d = _at('{"v":[-2147483648]}')
    var sf32s = List[Int32]()
    d.read_into_repeated_sfixed32(sf32s)
    assert_equal(sf32s[0], Int32.MIN)
    d = _at('{"v":[4294967295]}')
    var fx32s = List[UInt32]()
    d.read_into_repeated_fixed32(fx32s)
    assert_equal(fx32s[0], UInt32.MAX)

    d = _at('{"v":[]}')
    var none = List[Int64]()
    d.read_into_repeated_i64(none)
    assert_equal(len(none), 0, "an empty array adds nothing")
    print("  test_k4_repeated_scalars: PASS")


def test_k4_repeated_enums() raises:
    var d = _at('{"v":["LOW","HIGH",2,"0","UNSET"]}')
    var xs = List[Level]()
    d.read_into_repeated_enum[Level](xs)
    assert_equal(len(xs), 5)
    assert_equal(xs[0].value, 1)
    assert_equal(xs[1].value, 2)
    assert_equal(xs[2].value, 2, "a number")
    assert_equal(xs[3].value, 0, "numeric text")
    assert_equal(xs[4].value, 0, "the declared zero name")

    var msg = String("")
    try:
        d = _at('{"v":["LOW","MEDIUM"]}')
        d.read_into_repeated_enum[Level](xs)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith('JsonError: unknown enum value "MEDIUM" at $.v (line 1)'),
        String("an undeclared name inside an array: ") + msg,
    )

    var lenient = JsonDecoder.from_text_lenient('{"v":["LOW","MEDIUM"]}')
    _ = lenient.next_field()
    var ys = List[Level]()
    lenient.read_into_repeated_enum[Level](ys)
    assert_equal(len(ys), 2)
    assert_equal(ys[1].value, 0, "lenient: undeclared is zero")

    var named = JsonDecoder.from_text('{"v":["NULL_VALUE",7]}')
    _ = named.next_field()
    var ns = List[Nothing]()
    named.read_into_repeated_enum[Nothing](ns)
    assert_equal(len(ns), 2)
    assert_equal(ns[0].value, 0, "the name")
    assert_equal(ns[1].value, 7, "a number goes through from_number")
    print("  test_k4_repeated_enums: PASS")


def _array_refusal(text: String, op: Int) -> String:
    try:
        var d = _at(text)
        if op == 0:
            var x = List[Int64]()
            d.read_into_repeated_i64(x)
        elif op == 1:
            var x = List[String]()
            d.read_into_repeated_string(x)
        elif op == 2:
            var x = List[Level]()
            d.read_into_repeated_enum[Level](x)
        elif op == 3:
            var x = List[Leaf]()
            d.read_into_repeated_message[Leaf](x)
        elif op == 4:
            var x = Dict[String, String]()
            d.read_into_string_string_map(x)
        elif op == 5:
            var x = Dict[Int64, String]()
            d.read_into_i64_string_map(x)
    except e:
        return String(e)
    return String("")


def test_k4_a_field_that_is_not_an_array_is_refused() raises:
    comptime A = "JsonError: expected a JSON array for repeated field"
    assert_equal(_array_refusal('{"v":1}', 0), String(A))
    assert_equal(_array_refusal('{"v":"a"}', 1), String(A))
    assert_equal(_array_refusal('{"v":{"a":1}}', 2), String(A))
    assert_equal(_array_refusal('{"v":true}', 3), String(A))
    comptime O = "JsonError: expected a JSON object for map field"
    assert_equal(_array_refusal('{"v":[]}', 4), String(O))
    assert_equal(_array_refusal('{"v":"x"}', 5), String(O))
    # An element of the wrong kind is refused by the element reader.
    assert_equal(
        _array_refusal('{"v":["1",true]}', 0),
        String("JsonError: as_int64() on a non-numeric value"),
    )
    assert_equal(
        _array_refusal('{"v":["a",1]}', 1),
        String("JsonError: as_string() on a non-string value"),
    )
    print("  test_k4_a_field_that_is_not_an_array_is_refused: PASS")


# =============================================================================
# K5
# =============================================================================


def _msg_refusal(text: String, op: Int) -> String:
    try:
        var d = _at(text)
        if op == 0:
            _ = d.read_message[Leaf]()
        elif op == 1:
            var x = List[Leaf]()
            d.read_into_repeated_message[Leaf](x)
        elif op == 2:
            var x = Dict[String, Leaf]()
            d.read_into_string_message_map[Leaf](x)
        elif op == 3:
            _ = d.read_message[Span2]()
        elif op == 4:
            var x = List[Span2]()
            d.read_into_repeated_message[Span2](x)
        elif op == 5:
            var x = Dict[String, Span2]()
            d.read_into_string_message_map[Span2](x)
    except e:
        return String(e)
    return String("")


def test_k5_messages_decode_with_their_path() raises:
    var d = _at('{"leaf":{"n":"7"}}')
    assert_equal(d.read_message[Leaf]().n, Int64(7))

    d = _at('{"leaves":[{"n":"1"},{"n":2},{}]}')
    var leaves = List[Leaf]()
    d.read_into_repeated_message[Leaf](leaves)
    assert_equal(len(leaves), 3)
    assert_equal(leaves[0].n, Int64(1))
    assert_equal(leaves[1].n, Int64(2))
    assert_equal(leaves[2].n, Int64(0), "an empty object is a default message")

    d = _at('{"m":{"a":{"n":"5"},"b":{}}}')
    var by_name = Dict[String, Leaf]()
    d.read_into_string_message_map[Leaf](by_name)
    assert_equal(len(by_name), 2)
    assert_equal(by_name["a"].n, Int64(5))
    assert_equal(by_name["b"].n, Int64(0))

    # The refusal inside names where it is.
    assert_true(
        _msg_refusal('{"leaf":{"x":1}}', 0).startswith('JsonError: unknown field "x" at $.leaf (line 1)'),
        "a nested message",
    )
    assert_true(
        _msg_refusal('{"leaves":[{"n":"1"},{"x":1}]}', 1).startswith(
            'JsonError: unknown field "x" at $.leaves[1] (line 1)'
        ),
        "the second element of a repeated field",
    )
    assert_true(
        _msg_refusal('{"m":{"k":{"x":1}}}', 2).startswith(
            'JsonError: unknown field "x" at $.m["k"] (line 1)'
        ),
        "the value of a map entry",
    )
    # The lenient decoder drops the unknown key at each of those places.
    var lenient = JsonDecoder.from_text_lenient(
        '{"leaf":{"x":1,"n":"4"},"leaves":[{"y":1}],"m":{"k":{"z":1}}}'
    )
    _ = lenient.next_field()
    assert_equal(lenient.read_message[Leaf]().n, Int64(4))
    _ = lenient.next_field()
    var ls = List[Leaf]()
    lenient.read_into_repeated_message[Leaf](ls)
    assert_equal(len(ls), 1)
    _ = lenient.next_field()
    var mm = Dict[String, Leaf]()
    lenient.read_into_string_message_map[Leaf](mm)
    assert_equal(mm["k"].n, Int64(0))

    # The element that is not an object.
    assert_equal(
        _msg_refusal('{"leaves":[1]}', 1),
        String("JsonError: decode source is not a JSON object"),
    )
    print("  test_k5_messages_decode_with_their_path: PASS")


def test_k5_well_known_types_read_their_canonical_value() raises:
    var d = _at('{"span":"90s"}')
    assert_equal(d.read_message[Span2]().seconds, Int64(90))
    d = _at('{"spans":["1s","-2s"]}')
    var xs = List[Span2]()
    d.read_into_repeated_message[Span2](xs)
    assert_equal(len(xs), 2)
    assert_equal(xs[0].seconds, Int64(1))
    assert_equal(xs[1].seconds, Int64(-2))
    d = _at('{"m":{"a":"5s","b":"6s"}}')
    var by_name = Dict[String, Span2]()
    d.read_into_string_message_map[Span2](by_name)
    assert_equal(by_name["a"].seconds, Int64(5))
    assert_equal(by_name["b"].seconds, Int64(6))

    # A refusal by the well-known type carries the field's path.
    assert_equal(
        _msg_refusal('{"span":"90"}', 3), String("not a span: 90 at $.span")
    )
    assert_equal(
        _msg_refusal('{"spans":["1s","x"]}', 4),
        String("not a span: x at $.spans[1]"),
    )
    assert_equal(
        _msg_refusal('{"m":{"a":"5s","b":"y"}}', 5),
        String('not a span: y at $.m["b"]'),
    )
    print("  test_k5_well_known_types_read_their_canonical_value: PASS")


# =============================================================================
# K6
# =============================================================================


def test_k6_map_readers() raises:
    var d = _at('{"m":{"a":"x","b":"","a2":"z"}}')
    var ss = Dict[String, String]()
    d.read_into_string_string_map(ss)
    assert_equal(len(ss), 3)
    assert_equal(ss["a"], String("x"))
    assert_equal(ss["b"], String(""))
    assert_equal(ss["a2"], String("z"))

    d = _at('{"m":{"a":-1,"b":"2","c":2147483647}}')
    var si32 = Dict[String, Int32]()
    d.read_into_string_i32_map(si32)
    assert_equal(len(si32), 3)
    assert_equal(si32["a"], Int32(-1))
    assert_equal(si32["b"], Int32(2), "int32 from a string")
    assert_equal(si32["c"], Int32.MAX)

    d = _at('{"m":{"a":"-9223372036854775808","b":5}}')
    var si64 = Dict[String, Int64]()
    d.read_into_string_i64_map(si64)
    assert_equal(len(si64), 2)
    assert_equal(si64["a"], Int64.MIN)
    assert_equal(si64["b"], Int64(5))

    d = _at('{"m":{"-3":"neg","0":"zero","9223372036854775807":"max"}}')
    var is_ = Dict[Int64, String]()
    d.read_into_i64_string_map(is_)
    assert_equal(len(is_), 3)
    assert_equal(is_[Int64(-3)], String("neg"))
    assert_equal(is_[Int64(0)], String("zero"))
    assert_equal(is_[Int64.MAX], String("max"))

    d = _at('{"m":{}}')
    var none = Dict[String, String]()
    d.read_into_string_string_map(none)
    assert_equal(len(none), 0, "an empty object adds nothing")

    assert_equal(
        _array_refusal('{"m":{"x":"a"}}', 5),
        String("JsonError: non-digit in integer text"),
        "an int64 key that is not an integer",
    )
    assert_equal(
        _array_refusal('{"m":{"":"a"}}', 5),
        String("JsonError: empty integer text"),
        "an empty int64 key",
    )
    assert_equal(
        _array_refusal('{"m":{"a":1}}', 4),
        String("JsonError: as_string() on a non-string value"),
        "a map value of the wrong kind",
    )
    print("  test_k6_map_readers: PASS")


# =============================================================================
# K7
# =============================================================================


def test_k7_null_copy_and_skip() raises:
    # null is absent...
    var d = JsonDecoder.from_text('{"a":null,"b":1,"c":null}')
    var k = d.next_field()
    assert_equal(k.json_name, String("b"), "the null before b is skipped")
    assert_equal(k.field_no, 0, "the JSON wire carries no number")
    assert_equal(d.read_i64(), Int64(1))
    assert_true(d.next_field().end, "the null after b is skipped")

    # ...except for the keys named to keep_null_fields.
    d = JsonDecoder.from_text('{"a":null,"b":null,"c":null}')
    d.keep_null_fields("a|x")
    d.keep_null_fields("c")
    k = d.next_field()
    assert_equal(k.json_name, String("a"))
    k = d.next_field()
    assert_equal(k.json_name, String("c"), "b is not kept, c is")
    assert_true(d.next_field().end)

    # copy is a deep clone at the same position.
    d = JsonDecoder.from_text('{"a":1,"b":2,"c":3}')
    _ = d.next_field()
    var c = d.copy()
    assert_equal(d.next_field().json_name, String("b"))
    assert_equal(d.read_i64(), Int64(2))
    assert_equal(c.read_i64(), Int64(1), "the copy still stands on a")
    assert_equal(c.next_field().json_name, String("b"), "and walks on alone")
    assert_equal(c.next_field().json_name, String("c"))
    assert_equal(d.next_field().json_name, String("c"))

    # skip: strict refuses, lenient passes.
    d = JsonDecoder.from_text('{"a":1,"x":2}')
    _ = d.next_field()
    _ = d.next_field()
    var strict_msg = String("")
    try:
        d.skip()
    except e:
        strict_msg = String(e)
    assert_true(
        strict_msg.startswith('JsonError: unknown field "x" at $ (line 1)'),
        String("strict skip of x: ") + strict_msg,
    )
    var lenient = JsonDecoder.from_text_lenient('{"x":2,"a":3}')
    _ = lenient.next_field()
    lenient.skip()
    assert_equal(lenient.next_field().json_name, String("a"))

    # Called with no field under the cursor (before the first, after the
    # last) skip still refuses, naming `?` and giving no line.
    var unmoved = JsonDecoder.from_text('{"a":1}')
    var before = String("")
    try:
        unmoved.skip()
    except e:
        before = String(e)
    assert_true(
        before.startswith('JsonError: unknown field "?" at $ — it matches no field'),
        String("skip before next_field: ") + before,
    )
    _ = unmoved.next_field()
    assert_true(unmoved.next_field().end)
    var after = String("")
    try:
        unmoved.skip()
    except e:
        after = String(e)
    assert_true(
        after.startswith('JsonError: unknown field "?" at $ — it matches no field'),
        String("skip after the last field: ") + after,
    )

    # A well-known type read before any field is under the cursor.
    var early = String("")
    try:
        var fresh = JsonDecoder.from_text('{"span":"1s"}')
        _ = fresh.read_message[Span2]()
    except e:
        early = String(e)
    assert_equal(early, String("JsonError: read_* before next_field() at $.?"))

    # The unknown-token policies compare by value.
    assert_true(UnknownFields.refuse() == UnknownFields.refuse())
    assert_true(UnknownFields.refuse() != UnknownFields.ignore())
    assert_false(UnknownFields.ignore() != UnknownFields.ignore())
    assert_false(UnknownFields.refuse() == UnknownFields.ignore())
    print("  test_k7_null_copy_and_skip: PASS")


def main() raises:
    test_k1_strings_and_bytes()
    test_k1_integers()
    test_k1_floats_and_bools()
    test_k2_enums()
    test_k3_wrong_kind_and_malformed_text_are_refused()
    test_k4_repeated_scalars()
    test_k4_repeated_enums()
    test_k4_a_field_that_is_not_an_array_is_refused()
    test_k5_messages_decode_with_their_path()
    test_k5_well_known_types_read_their_canonical_value()
    test_k6_map_readers()
    test_k7_null_copy_and_skip()
