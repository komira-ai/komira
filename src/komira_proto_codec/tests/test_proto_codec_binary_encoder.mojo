# =============================================================================
# test_proto_codec_binary_encoder.mojo — the bytes `PbEncoder` writes.
# =============================================================================
#
# `PbEncoder` is driven directly, one call per writer, and the byte string it
# produced is compared with one worked out by hand from the protobuf encoding
# spec (varint, zigzag, little-endian fixed-width, length-delimited framing).
# The decoder is never involved, so a writer and a reader that drift together
# cannot hide each other.
#
#   E1  every singular writer, with the value that distinguishes it from its
#       neighbours: a negative int32 sign-extends to a ten byte varint, a
#       uint32 stays five bytes, sint32 / sint64 are zigzag (the extremes
#       included), fixed and sfixed are little-endian at their own width.
#       Catches: a writer wired to the wrong primitive (sint written as
#       int64, sfixed32 widened to eight bytes), a wrong zigzag sign, a
#       varint that drops its last group, a wrong wire type in the tag.
#   E2  every repeated element writer writes the same record as its singular
#       writer, once per element, and `begin_list_field` / `end_list_field`
#       add no bytes. Catches: an element writer that packs, or that keys the
#       element under a different tag than the singular field.
#   E3  an enum field is its number as an int32 varint; a negative number
#       sign-extends. Catches: an enum written by name or truncated to
#       fewer bytes.
#   E4  a nested message is tag, length, bytes; the scratch buffers it borrows
#       are recycled, so the second and third child (and a child that itself
#       nests one) come out the same as the first. Catches: a stale scratch
#       buffer (bytes of the previous child leaking into the next), a length
#       prefix that does not match the payload.
#   E5  a map entry is a length-delimited record of key (field 1) and value
#       (field 2) under the map field's tag, one record per entry, and the
#       fields outside the entry are not disturbed. Catches: an entry whose
#       bytes land in the parent buffer unframed, a lost entry, a wrong tag.
#   E6  `into_buf` hands over the bytes and leaves the encoder empty and
#       reusable; binary encoding writes defaults. Catches: a copy that
#       leaves the bytes behind.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import (
    PbEncoder,
    ProtoEnum,
    Serializable,
    WireDecoder,
    WireEncoder,
)


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var hb = digits.as_bytes()
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        out += chr(Int(hb[(Int(b[i]) >> 4) & 0xF]))
        out += chr(Int(hb[Int(b[i]) & 0xF]))
    return out^


def _raw(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


@fieldwise_init
struct Level(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("LEVEL")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "LEVEL"

    @staticmethod
    def known_json_names() -> String:
        return String("LEVEL")


@fieldwise_init
struct Leaf(Serializable, Copyable, Movable):
    """`message Leaf { int64 n = 1; string tag = 2; }`."""

    var n: Int64
    var tag: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "n", self.n)
        if self.tag.byte_length() > 0:
            enc.write_string_field(2, "tag", self.tag)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        return Leaf(0, String(""))


@fieldwise_init
struct Branch(Serializable, Copyable, Movable):
    """`message Branch { Leaf leaf = 1; int64 n = 2; }`: nests one level."""

    var leaf: Leaf
    var n: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_message_field(1, "leaf", self.leaf)
        enc.write_i64_field(2, "n", self.n)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        return Branch(Leaf(0, String("")), 0)


def test_e1_singular_writers() raises:
    comptime TEN_FF = "ff ff ff ff ff ff ff ff ff 01"

    var e = PbEncoder()
    e.write_string_field(1, "s", String("abc"))
    assert_equal(_hex(e.buf), "0a 03 61 62 63", "string: tag 0x0a, len, bytes")

    e = PbEncoder()
    e.write_string_field(1, "s", String("hé"))
    assert_equal(_hex(e.buf), "0a 03 68 c3 a9", "string: UTF-8 bytes, len in bytes")

    e = PbEncoder()
    e.write_string_field(1, "s", String(""))
    assert_equal(_hex(e.buf), "0a 00", "an empty string is still written")

    e = PbEncoder()
    var raw = List[UInt8]()
    raw.append(UInt8(0))
    raw.append(UInt8(255))
    e.write_bytes_field(2, "b", raw)
    assert_equal(_hex(e.buf), "12 02 00 ff", "bytes: tag 0x12, len, verbatim")

    e = PbEncoder()
    e.write_i64_field(1, "v", Int64(150))
    assert_equal(_hex(e.buf), "08 96 01", "int64 150: two-byte varint")

    e = PbEncoder()
    e.write_i64_field(1, "v", Int64(-1))
    assert_equal(_hex(e.buf), String("08 ") + String(TEN_FF), "int64 -1: ten bytes")

    e = PbEncoder()
    e.write_i64_field(1, "v", Int64(127))
    e.write_i64_field(1, "v", Int64(128))
    assert_equal(_hex(e.buf), "08 7f 08 80 01", "varint group boundary 127 / 128")

    e = PbEncoder()
    e.write_i32_field(1, "v", Int32(-1))
    assert_equal(
        _hex(e.buf), String("08 ") + String(TEN_FF), "int32 -1 sign-extends"
    )

    e = PbEncoder()
    e.write_i32_field(1, "v", Int32(300))
    assert_equal(_hex(e.buf), "08 ac 02", "int32 300")

    e = PbEncoder()
    e.write_u64_field(1, "v", UInt64.MAX)
    assert_equal(_hex(e.buf), String("08 ") + String(TEN_FF), "uint64 max")

    e = PbEncoder()
    e.write_u32_field(1, "v", UInt32.MAX)
    assert_equal(_hex(e.buf), "08 ff ff ff ff 0f", "uint32 max: five bytes")

    e = PbEncoder()
    e.write_f64_field(1, "v", Float64(1.5))
    assert_equal(_hex(e.buf), "09 00 00 00 00 00 00 f8 3f", "double 1.5")

    e = PbEncoder()
    e.write_f32_field(1, "v", Float32(1.5))
    assert_equal(_hex(e.buf), "0d 00 00 c0 3f", "float 1.5")

    e = PbEncoder()
    e.write_f64_field(1, "v", Float64(-0.0))
    assert_equal(_hex(e.buf), "09 00 00 00 00 00 00 00 80", "double -0.0 keeps its sign bit")

    e = PbEncoder()
    e.write_sint64_field(1, "v", Int64(-1))
    e.write_sint64_field(1, "v", Int64(1))
    e.write_sint64_field(1, "v", Int64(0))
    assert_equal(_hex(e.buf), "08 01 08 02 08 00", "sint64 zigzag -1, 1, 0")

    e = PbEncoder()
    e.write_sint64_field(1, "v", Int64.MIN)
    e.write_sint64_field(1, "v", Int64.MAX)
    assert_equal(
        _hex(e.buf),
        String("08 ") + String(TEN_FF) + String(" 08 fe ff ff ff ff ff ff ff ff 01"),
        "sint64 extremes",
    )

    e = PbEncoder()
    e.write_sint32_field(1, "v", Int32(-1))
    e.write_sint32_field(1, "v", Int32(1))
    e.write_sint32_field(1, "v", Int32(-2))
    assert_equal(_hex(e.buf), "08 01 08 02 08 03", "sint32 zigzag -1, 1, -2")

    e = PbEncoder()
    e.write_sint32_field(1, "v", Int32.MIN)
    e.write_sint32_field(1, "v", Int32.MAX)
    assert_equal(
        _hex(e.buf),
        "08 ff ff ff ff 0f 08 fe ff ff ff 0f",
        "sint32 extremes stay five bytes",
    )

    e = PbEncoder()
    e.write_fixed64_field(1, "v", UInt64(0x0102030405060708))
    assert_equal(_hex(e.buf), "09 08 07 06 05 04 03 02 01", "fixed64 little-endian")

    e = PbEncoder()
    e.write_fixed32_field(1, "v", UInt32(0x01020304))
    assert_equal(_hex(e.buf), "0d 04 03 02 01", "fixed32 little-endian")

    e = PbEncoder()
    e.write_sfixed64_field(1, "v", Int64(-2))
    assert_equal(_hex(e.buf), "09 fe ff ff ff ff ff ff ff", "sfixed64 -2")

    e = PbEncoder()
    e.write_sfixed32_field(1, "v", Int32(-2))
    assert_equal(_hex(e.buf), "0d fe ff ff ff", "sfixed32 -2 is four bytes")

    e = PbEncoder()
    e.write_sfixed32_field(1, "v", Int32.MIN)
    assert_equal(_hex(e.buf), "0d 00 00 00 80", "sfixed32 min")

    e = PbEncoder()
    e.write_bool_field(1, "v", True)
    e.write_bool_field(1, "v", False)
    assert_equal(_hex(e.buf), "08 01 08 00", "bool true / false")

    e = PbEncoder()
    e.write_i64_field(16, "v", Int64(1))
    assert_equal(_hex(e.buf), "80 01 01", "field 16 needs a two byte tag")
    print("  test_e1_singular_writers: PASS")


def test_e2_repeated_elements() raises:
    var e = PbEncoder()
    e.begin_list_field(3, "xs")
    e.write_i32_element(3, Int32(1))
    e.write_i32_element(3, Int32(-1))
    e.end_list_field()
    assert_equal(
        _hex(e.buf),
        "18 01 18 ff ff ff ff ff ff ff ff ff 01",
        "i32 elements: one tagged record each, no list framing",
    )

    e = PbEncoder()
    e.write_string_element(1, String("a"))
    e.write_string_element(1, String("bc"))
    assert_equal(_hex(e.buf), "0a 01 61 0a 02 62 63", "string elements")

    e = PbEncoder()
    var raw = List[UInt8]()
    raw.append(UInt8(7))
    e.write_bytes_element(1, raw)
    e.write_bytes_element(1, List[UInt8]())
    assert_equal(_hex(e.buf), "0a 01 07 0a 00", "bytes elements, one empty")

    e = PbEncoder()
    e.write_i64_element(1, Int64(-1))
    assert_equal(
        _hex(e.buf), "08 ff ff ff ff ff ff ff ff ff 01", "i64 element -1"
    )

    e = PbEncoder()
    e.write_u64_element(1, UInt64(300))
    e.write_u32_element(1, UInt32(300))
    assert_equal(_hex(e.buf), "08 ac 02 08 ac 02", "u64 / u32 elements")

    e = PbEncoder()
    e.write_f64_element(1, Float64(1.5))
    e.write_f32_element(1, Float32(1.5))
    assert_equal(
        _hex(e.buf),
        "09 00 00 00 00 00 00 f8 3f 0d 00 00 c0 3f",
        "f64 / f32 elements",
    )

    e = PbEncoder()
    e.write_sint64_element(1, Int64(-3))
    e.write_sint32_element(1, Int32(-3))
    assert_equal(_hex(e.buf), "08 05 08 05", "sint64 / sint32 elements zigzag")

    e = PbEncoder()
    e.write_fixed64_element(1, UInt64(1))
    e.write_fixed32_element(1, UInt32(1))
    assert_equal(
        _hex(e.buf),
        "09 01 00 00 00 00 00 00 00 0d 01 00 00 00",
        "fixed64 / fixed32 elements",
    )

    e = PbEncoder()
    e.write_sfixed64_element(1, Int64(-1))
    e.write_sfixed32_element(1, Int32(-1))
    assert_equal(
        _hex(e.buf),
        "09 ff ff ff ff ff ff ff ff 0d ff ff ff ff",
        "sfixed64 / sfixed32 elements",
    )

    e = PbEncoder()
    e.write_bool_element(1, True)
    e.write_bool_element(1, False)
    assert_equal(_hex(e.buf), "08 01 08 00", "bool elements")

    e = PbEncoder()
    e.write_enum_element(1, Level(2))
    e.write_enum_element(1, Level(-1))
    assert_equal(
        _hex(e.buf),
        "08 02 08 ff ff ff ff ff ff ff ff ff 01",
        "enum elements are int32 varints",
    )

    e = PbEncoder()
    e.write_message_element(1, Leaf(5, String("x")))
    e.write_message_element(1, Leaf(6, String("")))
    assert_equal(
        _hex(e.buf),
        "0a 05 08 05 12 01 78 0a 02 08 06",
        "message elements: one framed record each",
    )
    print("  test_e2_repeated_elements: PASS")


def test_e3_enum_field() raises:
    var e = PbEncoder()
    e.write_enum_field(1, "level", Level(3))
    assert_equal(_hex(e.buf), "08 03", "enum 3 is the varint 3")
    e = PbEncoder()
    e.write_enum_field(1, "level", Level(0))
    assert_equal(_hex(e.buf), "08 00", "enum 0 is written, not omitted")
    e = PbEncoder()
    e.write_enum_field(1, "level", Level(-1))
    assert_equal(
        _hex(e.buf),
        "08 ff ff ff ff ff ff ff ff ff 01",
        "a negative enum number sign-extends",
    )
    print("  test_e3_enum_field: PASS")


def test_e4_nested_messages_reuse_scratch() raises:
    var e = PbEncoder()
    e.write_message_field(1, "leaf", Leaf(150, String("long enough")))
    var first = _hex(e.buf)
    assert_equal(
        first,
        "0a 10 08 96 01 12 0b 6c 6f 6e 67 20 65 6e 6f 75 67 68",
        "tag, length 16, child bytes",
    )

    # A shorter child after a longer one: no byte of the first may remain.
    e = PbEncoder()
    e.write_message_field(1, "leaf", Leaf(150, String("long enough")))
    e.write_message_field(2, "leaf", Leaf(1, String("")))
    e.write_message_field(3, "leaf", Leaf(150, String("long enough")))
    assert_equal(
        _hex(e.buf),
        "0a 10 08 96 01 12 0b 6c 6f 6e 67 20 65 6e 6f 75 67 68"
        " 12 02 08 01"
        " 1a 10 08 96 01 12 0b 6c 6f 6e 67 20 65 6e 6f 75 67 68",
        "the second child is not padded with the first one's bytes",
    )

    # An empty child is a zero length record.
    e = PbEncoder()
    e.write_message_field(4, "leaf", Leaf(0, String("")))
    assert_equal(_hex(e.buf), "22 02 08 00", "child with only a zero field")

    # A child that nests a child.
    e = PbEncoder()
    e.write_message_field(1, "b", Branch(Leaf(1, String("")), 2))
    e.write_message_field(1, "b", Branch(Leaf(1, String("")), 2))
    assert_equal(
        _hex(e.buf),
        "0a 06 0a 02 08 01 10 02 0a 06 0a 02 08 01 10 02",
        "two levels of framing, twice over the same pool",
    )

    # A child of 128 bytes needs a two byte length prefix.
    var big = String("")
    for _ in range(126):
        big += "a"
    e = PbEncoder()
    e.write_message_field(1, "leaf", Leaf(0, big))
    # child = 08 00 (2) + 12 7e + 126 bytes (128) + ... = 2 + 2 + 126 = 130
    assert_equal(len(e.buf), 1 + 2 + 130, "tag + two byte length + child")
    assert_equal(Int(e.buf[0]), 0x0A, "tag")
    assert_equal(Int(e.buf[1]), 0x82, "length 130, low group with continuation")
    assert_equal(Int(e.buf[2]), 0x01, "length 130, high group")
    print("  test_e4_nested_messages_reuse_scratch: PASS")


def test_e5_map_entries() raises:
    var e = PbEncoder()
    e.begin_map_field(5, "m")
    e.begin_map_entry()
    e.write_string_field(1, "key", String("k"))
    e.write_i32_field(2, "value", Int32(7))
    e.end_map_entry()
    e.begin_map_entry()
    e.write_string_field(1, "key", String("kk"))
    e.write_i32_field(2, "value", Int32(-1))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(
        _hex(e.buf),
        "2a 05 0a 01 6b 10 07"
        " 2a 0f 0a 02 6b 6b 10 ff ff ff ff ff ff ff ff ff 01",
        "two entries under tag 5, each length-prefixed",
    )

    # Fields before and after a map are untouched by the entry redirection.
    e = PbEncoder()
    e.write_i64_field(1, "a", Int64(1))
    e.begin_map_field(5, "m")
    e.begin_map_entry()
    e.write_i64_field(1, "key", Int64(2))
    e.write_string_field(2, "value", String("v"))
    e.end_map_entry()
    e.end_map_field()
    e.write_i64_field(3, "c", Int64(3))
    assert_equal(
        _hex(e.buf),
        "08 01 2a 05 08 02 12 01 76 18 03",
        "outer fields keep their place around the entry",
    )

    # An entry whose value is a message.
    e = PbEncoder()
    e.begin_map_field(6, "m")
    e.begin_map_entry()
    e.write_string_field(1, "key", String("k"))
    e.write_message_field(2, "value", Leaf(9, String("")))
    e.end_map_entry()
    e.end_map_field()
    assert_equal(
        _hex(e.buf),
        "32 07 0a 01 6b 12 02 08 09",
        "message value nested in an entry",
    )

    # An empty map writes nothing.
    e = PbEncoder()
    e.begin_map_field(5, "m")
    e.end_map_field()
    assert_equal(len(e.buf), 0, "no entries, no bytes")
    print("  test_e5_map_entries: PASS")


def test_e6_into_buf_and_defaults() raises:
    var e = PbEncoder()
    e.write_i64_field(1, "v", Int64(0))
    e.write_string_field(2, "s", String(""))
    e.write_bool_field(3, "b", False)
    var out = e.into_buf()
    assert_equal(
        _hex(out),
        "08 00 12 00 18 00",
        "binary encoding writes fields at their default",
    )
    assert_equal(len(e.buf), 0, "into_buf leaves the encoder empty")
    e.write_i64_field(1, "v", Int64(1))
    assert_equal(_hex(e.buf), "08 01", "the emptied encoder is reusable")
    assert_false(PbEncoder.OMITS_IMPLICIT_DEFAULTS, "binary never omits defaults")
    print("  test_e6_into_buf_and_defaults: PASS")


def main() raises:
    test_e1_singular_writers()
    test_e2_repeated_elements()
    test_e3_enum_field()
    test_e4_nested_messages_reuse_scratch()
    test_e5_map_entries()
    test_e6_into_buf_and_defaults()
