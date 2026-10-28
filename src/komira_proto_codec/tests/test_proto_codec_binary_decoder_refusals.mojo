# =============================================================================
# test_proto_codec_binary_decoder_refusals.mojo — what `PbDecoder` refuses and
# what it skips.
# =============================================================================
#
# Every input is a hex string written from the protobuf encoding spec, so the
# decoder is checked against the format and not against `PbEncoder`.
# `PbDecoder` is driven directly, reader by reader.
#
#   D3  a packed record whose last element runs past the record into the next
#       field's bytes is refused, naming the type and how far it ran, for
#       every element type. Catches: a missing bound check (a value assembled
#       from two fields), a refusal naming the wrong type.
#   D4  malformed input is refused with the name of the failure: an
#       unterminated or over-long varint, field number 0, a length past the
#       buffer, a truncated fixed32 / fixed64, an unknown wire type.
#       Catches: a reader that returns garbage or reads out of bounds instead
#       of refusing.
#   D5  `skip` steps over a field of each of the four wire types and the next
#       field reads correctly; a truncated field is refused. Catches: a wrong
#       skip distance for one wire type.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import (
    PbDecoder,
    ProtoEnum,
    Serializable,
    WireDecoder,
    WireEncoder,
)


def _nib(c: UInt8) -> Int:
    if c >= 0x61:
        return Int(c) - 0x61 + 10
    return Int(c) - 0x30


def _b(hex: String) -> List[UInt8]:
    """Bytes from a hex string; spaces are ignored."""
    var out = List[UInt8]()
    var bs = hex.as_bytes()
    var hi = -1
    for i in range(len(bs)):
        var c = bs[i]
        if c == 0x20:
            continue
        if hi < 0:
            hi = _nib(c)
        else:
            out.append(UInt8(hi * 16 + _nib(c)))
            hi = -1
    return out^


def _dec(hex: String) -> PbDecoder:
    return PbDecoder(_b(hex))


def _varint(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var x = n
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))
    return out^


def _len_rec(field: Int, payload: List[UInt8]) -> List[UInt8]:
    """Field `field` as a LEN record holding `payload`."""
    var out = _varint(field * 8 + 2)
    out.extend(_varint(len(payload)))
    out.extend(Span(payload))
    return out^


def _first(mut d: PbDecoder) raises -> Int:
    var k = d.next_field()
    assert_false(k.end, "a field was expected")
    assert_equal(k.json_name, String(""), "the binary wire carries no name")
    return k.field_no


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
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var n = Int64(0)
        var tag = String("")
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1:
                n = dec.read_i64()
            elif key.field_no == 2:
                tag = dec.read_string()
            else:
                dec.skip()
        return Leaf(n, tag^)


# =============================================================================
# D3, D4, D5: refusals
# =============================================================================


def _packed_msg(what: String, n: Int) -> String:
    return (
        String("ProtobufError.TRUNCATED: a packed repeated ")
        + what
        + String(" field's last element runs ")
        + String(n)
        + String(
            " byte(s) past the payload it was declared to occupy. Refused"
            " rather than assembled from the following field's bytes."
        )
    )


def _read_repeated(hex: String, kind: Int) raises -> String:
    """The refusal (or "") of reading the first field of `hex` as repeated
    element type `kind`."""
    var d = _dec(hex)
    try:
        _ = d.next_field()
        if kind == 0:
            var x = List[Int64]()
            d.read_into_repeated_i64(x)
        elif kind == 1:
            var x = List[Int32]()
            d.read_into_repeated_i32(x)
        elif kind == 2:
            var x = List[UInt64]()
            d.read_into_repeated_u64(x)
        elif kind == 3:
            var x = List[UInt32]()
            d.read_into_repeated_u32(x)
        elif kind == 4:
            var x = List[Float64]()
            d.read_into_repeated_f64(x)
        elif kind == 5:
            var x = List[Float32]()
            d.read_into_repeated_f32(x)
        elif kind == 6:
            var x = List[Int64]()
            d.read_into_repeated_sint64(x)
        elif kind == 7:
            var x = List[Int32]()
            d.read_into_repeated_sint32(x)
        elif kind == 8:
            var x = List[UInt64]()
            d.read_into_repeated_fixed64(x)
        elif kind == 9:
            var x = List[UInt32]()
            d.read_into_repeated_fixed32(x)
        elif kind == 10:
            var x = List[Int64]()
            d.read_into_repeated_sfixed64(x)
        elif kind == 11:
            var x = List[Int32]()
            d.read_into_repeated_sfixed32(x)
        elif kind == 12:
            var x = List[Bool]()
            d.read_into_repeated_bool(x)
        elif kind == 13:
            var x = List[Level]()
            d.read_into_repeated_enum[Level](x)
        elif kind == 14:
            var x = List[String]()
            d.read_into_repeated_string(x)
        elif kind == 15:
            var x = List[List[UInt8]]()
            d.read_into_repeated_bytes(x)
        elif kind == 16:
            var x = List[Leaf]()
            d.read_into_repeated_message[Leaf](x)
    except e:
        return String(e)
    return String("")


def test_d3_a_packed_element_running_past_its_record_is_refused() raises:
    # A varint element: the record is one byte (0x80, "more follows") and the
    # next field's byte (0x01) completes it.
    var varint_hex = String("0a 01 80 01")
    assert_equal(_read_repeated(varint_hex, 0), _packed_msg("int64", 1))
    assert_equal(_read_repeated(varint_hex, 1), _packed_msg("int32", 1))
    assert_equal(_read_repeated(varint_hex, 2), _packed_msg("uint64", 1))
    assert_equal(_read_repeated(varint_hex, 3), _packed_msg("uint32", 1))
    assert_equal(_read_repeated(varint_hex, 6), _packed_msg("sint64", 1))
    assert_equal(_read_repeated(varint_hex, 7), _packed_msg("sint32", 1))
    assert_equal(_read_repeated(varint_hex, 12), _packed_msg("bool", 1))
    assert_equal(_read_repeated(varint_hex, 13), _packed_msg("enum", 1))

    # An 8 byte element declared 4 bytes long, with 4 more bytes after it.
    var wide = String("0a 04 01 02 03 04 05 06 07 08")
    assert_equal(_read_repeated(wide, 4), _packed_msg("double", 4))
    assert_equal(_read_repeated(wide, 8), _packed_msg("fixed64", 4))
    assert_equal(_read_repeated(wide, 10), _packed_msg("sfixed64", 4))

    # A 4 byte element declared 2 bytes long, with 2 more bytes after it.
    var narrow = String("0a 02 01 02 03 04")
    assert_equal(_read_repeated(narrow, 5), _packed_msg("float", 2))
    assert_equal(_read_repeated(narrow, 9), _packed_msg("fixed32", 2))
    assert_equal(_read_repeated(narrow, 11), _packed_msg("sfixed32", 2))

    # The inversion: the same bytes with the record declared long enough.
    assert_equal(_read_repeated(String("0a 02 80 01"), 0), String(""))
    assert_equal(_read_repeated(String("0a 08 01 02 03 04 05 06 07 08"), 8), String(""))
    assert_equal(_read_repeated(String("0a 04 01 02 03 04"), 9), String(""))
    print("  test_d3_a_packed_element_running_past_its_record_is_refused: PASS")


def _op(hex: String, op: Int) raises -> String:
    """The refusal (or "") of reading the first field of `hex` with `op`."""
    var d = _dec(hex)
    try:
        _ = d.next_field()
        if op == 0:
            pass
        elif op == 1:
            _ = d.read_string()
        elif op == 2:
            _ = d.read_bytes()
        elif op == 3:
            _ = d.read_i64()
        elif op == 4:
            _ = d.read_f64()
        elif op == 5:
            _ = d.read_f32()
        elif op == 6:
            _ = d.read_fixed64()
        elif op == 7:
            _ = d.read_fixed32()
        elif op == 8:
            _ = d.read_message[Leaf]()
        elif op == 9:
            d.skip()
        elif op == 10:
            var m = Dict[String, String]()
            d.read_into_string_string_map(m)
        elif op == 11:
            _ = d.read_sfixed64()
        elif op == 12:
            _ = d.read_sfixed32()
    except e:
        return String(e)
    return String("")


def test_d4_malformed_input_is_refused_by_name() raises:
    comptime M = "ProtobufError.MALFORMED: "
    # The tag.
    assert_equal(_op("80", 0), String(M) + "varint runs past buffer end", "unterminated tag")
    assert_equal(_op("00 00", 0), String(M) + "field number 0 is illegal", "field 0")
    assert_equal(_op("07 00", 0), String(M) + "field number 0 is illegal", "field 0, wire 7")
    # The value varint.
    assert_equal(_op("08 80", 3), String(M) + "varint runs past buffer end", "unterminated value")
    assert_equal(
        _op("08 ff ff ff ff ff ff ff ff ff ff 01", 3),
        String(M) + "varint exceeds 10 bytes",
        "eleven bytes",
    )
    assert_equal(_op("08", 3), String(M) + "varint runs past buffer end", "no value at all")
    # LEN records.
    var past = String(M) + "length-delimited field runs past buffer end"
    assert_equal(_op("0a 05 61", 1), past, "string longer than the buffer")
    assert_equal(_op("0a 03 61 62", 2), past, "bytes one short")
    assert_equal(_op("0a ff ff ff ff ff ff ff ff ff 01", 1), past, "length 2^64 - 1")
    assert_equal(_op("0a", 1), String(M) + "varint runs past buffer end", "no length")
    assert_equal(_op("0a 02 08 05", 8), String(""), "an exact record is accepted")
    assert_equal(_op("0a 03 08 05", 8), past, "message one byte short")
    assert_equal(_op("0a 05 0a 01 6b 12", 10), past, "map entry past the buffer")
    # Fixed widths.
    assert_equal(_op("09 01 02 03 04 05 06 07", 4), String(M) + "fixed64 past end", "double")
    assert_equal(_op("09 01 02 03 04 05 06 07", 6), String(M) + "fixed64 past end", "fixed64")
    assert_equal(_op("09 01 02 03 04 05 06 07", 11), String(M) + "fixed64 past end", "sfixed64")
    assert_equal(_op("0d 01 02 03", 5), String(M) + "fixed32 past end", "float")
    assert_equal(_op("0d 01 02 03", 7), String(M) + "fixed32 past end", "fixed32")
    assert_equal(_op("0d 01 02 03", 12), String(M) + "fixed32 past end", "sfixed32")
    assert_equal(_op("0d 01 02 03 04", 5), String(""), "four bytes are enough")
    # Wire types 6 and 7 do not exist.
    assert_equal(_op("0e 00", 9), String(M) + "unknown wire type 6", "wire 6")
    assert_equal(_op("0f 00", 9), String(M) + "unknown wire type 7", "wire 7")
    print("  test_d4_malformed_input_is_refused_by_name: PASS")


def test_d5_skip_steps_over_every_wire_type() raises:
    # fields 1..4: varint, fixed64, LEN, fixed32; field 5 is read.
    var d = _dec(
        "08 ff ff 03"
        " 11 01 02 03 04 05 06 07 08"
        " 1a 03 61 62 63"
        " 25 01 02 03 04"
        " 28 2a"
    )
    for want in range(1, 5):
        assert_equal(_first(d), want)
        d.skip()
    assert_equal(_first(d), 5, "the field after four skipped ones")
    assert_equal(d.read_i64(), Int64(42))
    assert_true(d.next_field().end)

    # A multi-byte varint tag (field 16) is skipped as one field.
    d = _dec("80 01 05 08 07")
    assert_equal(_first(d), 16)
    d.skip()
    assert_equal(_first(d), 1)
    assert_equal(d.read_i64(), Int64(7))

    # A truncated field is refused rather than skipped.
    assert_equal(_op("0a 04 61", 9), String("ProtobufError.MALFORMED: length-delimited field runs past buffer end"))
    assert_equal(_op("11 01 02", 9), String("ProtobufError.MALFORMED: fixed64 past end"))
    assert_equal(_op("15 01 02", 9), String("ProtobufError.MALFORMED: fixed32 past end"))
    assert_equal(_op("08 80", 9), String("ProtobufError.MALFORMED: varint runs past buffer end"))
    print("  test_d5_skip_steps_over_every_wire_type: PASS")


# =============================================================================


def main() raises:
    test_d3_a_packed_element_running_past_its_record_is_refused()
    test_d4_malformed_input_is_refused_by_name()
    test_d5_skip_steps_over_every_wire_type()
