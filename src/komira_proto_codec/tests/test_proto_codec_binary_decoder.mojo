# =============================================================================
# test_proto_codec_binary_decoder.mojo — what `PbDecoder` reads out of bytes
# written by hand.
# =============================================================================
#
# Every input is a hex string written from the protobuf encoding spec, so the
# decoder is checked against the format and not against `PbEncoder`.
# `PbDecoder` is driven directly, reader by reader.
#
#   D1  every singular reader returns the value its bytes denote: varint
#       edges (127 / 128, ten bytes), the int32 / uint32 truncation of a wider
#       varint, zigzag at its extremes, little-endian fixed32 / fixed64 and
#       the signed reinterpretation of sfixed, any non-zero varint as true.
#       Catches: a reader wired to the wrong primitive, a wrong zigzag sign, a
#       missing 32-bit truncation, an off-by-one in the varint groups.
#   D2  a repeated scalar is read in both forms the spec allows, one record
#       per element and one packed LEN record, mixed in one field, for every
#       element type; an empty packed record adds nothing. Catches: a reader
#       that takes only one form, a packed loop that stops early or reads past
#       the record.
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
# D1
# =============================================================================


def test_d1_string_and_bytes() raises:
    var d = _dec("0a 03 61 62 63")
    assert_equal(_first(d), 1)
    assert_equal(d.read_string(), String("abc"))
    assert_true(d.next_field().end, "nothing follows")

    d = _dec("0a 03 68 c3 a9")
    _ = _first(d)
    assert_equal(d.read_string(), String("hé"), "UTF-8 bytes read back as text")

    d = _dec("0a 00")
    _ = _first(d)
    assert_equal(d.read_string(), String(""), "an empty string")

    d = _dec("12 03 00 ff 7f 18 01")
    assert_equal(_first(d), 2)
    var raw = d.read_bytes()
    assert_equal(len(raw), 3)
    assert_equal(Int(raw[0]), 0)
    assert_equal(Int(raw[1]), 255)
    assert_equal(Int(raw[2]), 127)
    assert_equal(_first(d), 3, "the field after the bytes record")
    print("  test_d1_string_and_bytes: PASS")


def test_d1_varint_readers() raises:
    var d = _dec("08 7f 08 80 01 08 96 01")
    _ = _first(d)
    assert_equal(d.read_i64(), Int64(127), "one group")
    _ = _first(d)
    assert_equal(d.read_i64(), Int64(128), "two groups")
    _ = _first(d)
    assert_equal(d.read_i64(), Int64(150))

    d = _dec("08 ff ff ff ff ff ff ff ff ff 01")
    _ = _first(d)
    assert_equal(d.read_i64(), Int64(-1), "ten byte varint is -1")

    d = _dec("08 ff ff ff ff ff ff ff ff ff 01")
    _ = _first(d)
    assert_equal(d.read_i32(), Int32(-1), "a sign-extended int32")
    d = _dec("08 ff ff ff ff 0f 08 80 80 80 80 08 08 80 80 80 80 10")
    _ = _first(d)
    assert_equal(d.read_i32(), Int32(-1), "five byte 2^32 - 1 keeps the low 32 bits")
    _ = _first(d)
    assert_equal(d.read_i32(), Int32.MIN, "2^31 is Int32.MIN")
    _ = _first(d)
    assert_equal(d.read_i32(), Int32(0), "2^32 truncates to 0")

    d = _dec("08 ff ff ff ff ff ff ff ff ff 01")
    _ = _first(d)
    assert_equal(d.read_u64(), UInt64.MAX)

    d = _dec("08 ff ff ff ff 0f 08 ff ff ff ff ff ff ff ff ff 01 08 80 80 80 80 10")
    _ = _first(d)
    assert_equal(d.read_u32(), UInt32.MAX)
    _ = _first(d)
    assert_equal(d.read_u32(), UInt32.MAX, "a ten byte varint keeps the low 32 bits")
    _ = _first(d)
    assert_equal(d.read_u32(), UInt32(0), "2^32 truncates to 0")

    d = _dec("08 01 08 00 08 02 08 80 01 08 80 00")
    _ = _first(d)
    assert_true(d.read_bool())
    _ = _first(d)
    assert_false(d.read_bool())
    _ = _first(d)
    assert_true(d.read_bool(), "any non-zero value is true")
    _ = _first(d)
    assert_true(d.read_bool(), "128 is true")
    _ = _first(d)
    assert_false(d.read_bool(), "an over-long zero is false")

    d = _dec("08 03 08 ff ff ff ff ff ff ff ff ff 01 08 ff ff ff ff 0f")
    _ = _first(d)
    assert_equal(d.read_enum[Level]().value, 3)
    _ = _first(d)
    assert_equal(d.read_enum[Level]().value, -1, "a sign-extended negative number")
    _ = _first(d)
    assert_equal(d.read_enum[Level]().value, -1, "the low 32 bits of 2^32 - 1")
    print("  test_d1_varint_readers: PASS")


def test_d1_zigzag_readers() raises:
    var d = _dec("08 00 08 01 08 02 08 03 08 04")
    var want = List[Int64]()
    want.append(0)
    want.append(-1)
    want.append(1)
    want.append(-2)
    want.append(2)
    for i in range(len(want)):
        _ = _first(d)
        assert_equal(d.read_sint64(), want[i], "sint64 zigzag")

    d = _dec(
        "08 ff ff ff ff ff ff ff ff ff 01 08 fe ff ff ff ff ff ff ff ff 01"
    )
    _ = _first(d)
    assert_equal(d.read_sint64(), Int64.MIN)
    _ = _first(d)
    assert_equal(d.read_sint64(), Int64.MAX)

    d = _dec("08 00 08 01 08 02 08 03 08 04")
    var want32 = List[Int32]()
    want32.append(0)
    want32.append(-1)
    want32.append(1)
    want32.append(-2)
    want32.append(2)
    for i in range(len(want32)):
        _ = _first(d)
        assert_equal(d.read_sint32(), want32[i], "sint32 zigzag")

    d = _dec("08 ff ff ff ff 0f 08 fe ff ff ff 0f")
    _ = _first(d)
    assert_equal(d.read_sint32(), Int32.MIN)
    _ = _first(d)
    assert_equal(d.read_sint32(), Int32.MAX)
    print("  test_d1_zigzag_readers: PASS")


def test_d1_fixed_width_readers() raises:
    var d = _dec("09 08 07 06 05 04 03 02 01")
    assert_equal(_first(d), 1)
    assert_equal(d.read_fixed64(), UInt64(0x0102030405060708))

    d = _dec("0d 04 03 02 01")
    _ = _first(d)
    assert_equal(d.read_fixed32(), UInt32(0x01020304))

    d = _dec("09 fe ff ff ff ff ff ff ff 09 00 00 00 00 00 00 00 80")
    _ = _first(d)
    assert_equal(d.read_sfixed64(), Int64(-2))
    _ = _first(d)
    assert_equal(d.read_sfixed64(), Int64.MIN)

    d = _dec("0d fe ff ff ff 0d 00 00 00 80 0d ff ff ff 7f")
    _ = _first(d)
    assert_equal(d.read_sfixed32(), Int32(-2))
    _ = _first(d)
    assert_equal(d.read_sfixed32(), Int32.MIN)
    _ = _first(d)
    assert_equal(d.read_sfixed32(), Int32.MAX)

    d = _dec("09 00 00 00 00 00 00 f8 3f 09 00 00 00 00 00 00 00 80")
    _ = _first(d)
    assert_equal(d.read_f64(), Float64(1.5))
    _ = _first(d)
    var neg_zero = d.read_f64()
    assert_equal(neg_zero, Float64(0.0))
    assert_true(Float64(1.0) / neg_zero < Float64(0.0), "the sign bit survives")
    assert_true(d.next_field().end, "the cursor moved past both doubles")

    d = _dec("0d 00 00 c0 3f 0d 00 00 80 7f")
    _ = _first(d)
    assert_equal(d.read_f32(), Float32(1.5))
    _ = _first(d)
    var inf = d.read_f32()
    assert_true(inf > Float32(3.4e38), "0x7f800000 is +Infinity")
    assert_true(d.next_field().end, "the cursor moved past both floats")
    print("  test_d1_fixed_width_readers: PASS")


# =============================================================================
# D2
# =============================================================================


def test_d2_repeated_scalars_read_both_forms() raises:
    # int64: unpacked, packed, unpacked.
    var buf = _b("08 01")
    buf.extend(_len_rec(1, _b("02 ff ff ff ff ff ff ff ff ff 01")))
    buf.extend(_b("08 96 01"))
    var d = PbDecoder(buf^)
    var i64s = List[Int64]()
    while True:
        if d.next_field().end:
            break
        d.read_into_repeated_i64(i64s)
    assert_equal(len(i64s), 4)
    assert_equal(i64s[0], Int64(1))
    assert_equal(i64s[1], Int64(2))
    assert_equal(i64s[2], Int64(-1))
    assert_equal(i64s[3], Int64(150))

    # int32
    buf = _b("08 01")
    buf.extend(_len_rec(1, _b("02 ff ff ff ff 0f")))
    d = PbDecoder(buf^)
    var i32s = List[Int32]()
    while True:
        if d.next_field().end:
            break
        d.read_into_repeated_i32(i32s)
    assert_equal(len(i32s), 3)
    assert_equal(i32s[1], Int32(2))
    assert_equal(i32s[2], Int32(-1), "packed int32 keeps the low 32 bits")

    # uint64 / uint32
    d = PbDecoder(_len_rec(1, _b("01 ff ff ff ff ff ff ff ff ff 01")))
    var u64s = List[UInt64]()
    _ = d.next_field()
    d.read_into_repeated_u64(u64s)
    assert_equal(len(u64s), 2)
    assert_equal(u64s[0], UInt64(1))
    assert_equal(u64s[1], UInt64.MAX)
    d = PbDecoder(_b("08 09"))
    _ = d.next_field()
    d.read_into_repeated_u64(u64s)
    assert_equal(len(u64s), 3)
    assert_equal(u64s[2], UInt64(9), "an unpacked element")
    d = PbDecoder(_len_rec(1, _b("01 ff ff ff ff 0f")))
    var u32s = List[UInt32]()
    _ = d.next_field()
    d.read_into_repeated_u32(u32s)
    d = PbDecoder(_b("08 07"))
    _ = d.next_field()
    d.read_into_repeated_u32(u32s)
    assert_equal(len(u32s), 3)
    assert_equal(u32s[1], UInt32.MAX)
    assert_equal(u32s[2], UInt32(7), "an unpacked element")

    # bool: protoc packs these.
    d = PbDecoder(_len_rec(1, _b("01 00 01")))
    var bools = List[Bool]()
    _ = d.next_field()
    d.read_into_repeated_bool(bools)
    d = PbDecoder(_b("08 00"))
    _ = d.next_field()
    d.read_into_repeated_bool(bools)
    assert_equal(len(bools), 4)
    assert_true(bools[0])
    assert_false(bools[1])
    assert_true(bools[2])
    assert_false(bools[3], "an unpacked element")

    # enum
    d = PbDecoder(_len_rec(1, _b("01 02 ff ff ff ff 0f")))
    var enums = List[Level]()
    _ = d.next_field()
    d.read_into_repeated_enum[Level](enums)
    d = PbDecoder(_b("08 05"))
    _ = d.next_field()
    d.read_into_repeated_enum[Level](enums)
    assert_equal(len(enums), 4)
    assert_equal(enums[0].value, 1)
    assert_equal(enums[1].value, 2)
    assert_equal(enums[2].value, -1)
    assert_equal(enums[3].value, 5, "an unpacked element")

    # sint64 / sint32
    d = PbDecoder(_len_rec(1, _b("01 02 03")))
    var s64s = List[Int64]()
    _ = d.next_field()
    d.read_into_repeated_sint64(s64s)
    d = PbDecoder(_b("08 04"))
    _ = d.next_field()
    d.read_into_repeated_sint64(s64s)
    assert_equal(len(s64s), 4)
    assert_equal(s64s[0], Int64(-1))
    assert_equal(s64s[1], Int64(1))
    assert_equal(s64s[2], Int64(-2))
    assert_equal(s64s[3], Int64(2), "an unpacked element")
    d = PbDecoder(_len_rec(1, _b("01 02 ff ff ff ff 0f")))
    var s32s = List[Int32]()
    _ = d.next_field()
    d.read_into_repeated_sint32(s32s)
    d = PbDecoder(_b("08 03"))
    _ = d.next_field()
    d.read_into_repeated_sint32(s32s)
    assert_equal(len(s32s), 4)
    assert_equal(s32s[0], Int32(-1))
    assert_equal(s32s[1], Int32(1))
    assert_equal(s32s[2], Int32.MIN)
    assert_equal(s32s[3], Int32(-2), "an unpacked element")
    print("  test_d2_repeated_scalars_read_both_forms: PASS")


def test_d2_repeated_fixed_width_read_both_forms() raises:
    var d = PbDecoder(
        _len_rec(1, _b("01 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00"))
    )
    var u64s = List[UInt64]()
    _ = d.next_field()
    d.read_into_repeated_fixed64(u64s)
    d = PbDecoder(_b("09 03 00 00 00 00 00 00 00"))
    _ = d.next_field()
    d.read_into_repeated_fixed64(u64s)
    assert_equal(len(u64s), 3)
    assert_equal(u64s[0], UInt64(1))
    assert_equal(u64s[1], UInt64(2))
    assert_equal(u64s[2], UInt64(3), "an unpacked element")

    d = PbDecoder(_len_rec(1, _b("01 00 00 00 02 00 00 00")))
    var u32s = List[UInt32]()
    _ = d.next_field()
    d.read_into_repeated_fixed32(u32s)
    d = PbDecoder(_b("0d 03 00 00 00"))
    _ = d.next_field()
    d.read_into_repeated_fixed32(u32s)
    assert_equal(len(u32s), 3)
    assert_equal(u32s[1], UInt32(2))
    assert_equal(u32s[2], UInt32(3), "an unpacked element")

    d = PbDecoder(_len_rec(1, _b("ff ff ff ff ff ff ff ff fe ff ff ff ff ff ff ff")))
    var i64s = List[Int64]()
    _ = d.next_field()
    d.read_into_repeated_sfixed64(i64s)
    d = PbDecoder(_b("09 fd ff ff ff ff ff ff ff"))
    _ = d.next_field()
    d.read_into_repeated_sfixed64(i64s)
    assert_equal(len(i64s), 3)
    assert_equal(i64s[0], Int64(-1))
    assert_equal(i64s[1], Int64(-2))
    assert_equal(i64s[2], Int64(-3), "an unpacked element")

    d = PbDecoder(_len_rec(1, _b("ff ff ff ff 00 00 00 80")))
    var i32s = List[Int32]()
    _ = d.next_field()
    d.read_into_repeated_sfixed32(i32s)
    d = PbDecoder(_b("0d fe ff ff ff"))
    _ = d.next_field()
    d.read_into_repeated_sfixed32(i32s)
    assert_equal(len(i32s), 3)
    assert_equal(i32s[0], Int32(-1))
    assert_equal(i32s[1], Int32.MIN)
    assert_equal(i32s[2], Int32(-2), "an unpacked element")

    d = PbDecoder(
        _len_rec(1, _b("00 00 00 00 00 00 f8 3f 00 00 00 00 00 00 00 c0"))
    )
    var f64s = List[Float64]()
    _ = d.next_field()
    d.read_into_repeated_f64(f64s)
    d = PbDecoder(_b("09 00 00 00 00 00 00 04 40"))
    _ = d.next_field()
    d.read_into_repeated_f64(f64s)
    assert_equal(len(f64s), 3)
    assert_equal(f64s[0], Float64(1.5))
    assert_equal(f64s[1], Float64(-2.0))
    assert_equal(f64s[2], Float64(2.5), "an unpacked element")

    d = PbDecoder(_len_rec(1, _b("00 00 c0 3f 00 00 00 c0")))
    var f32s = List[Float32]()
    _ = d.next_field()
    d.read_into_repeated_f32(f32s)
    d = PbDecoder(_b("0d 00 00 20 40"))
    _ = d.next_field()
    d.read_into_repeated_f32(f32s)
    assert_equal(len(f32s), 3)
    assert_equal(f32s[0], Float32(1.5))
    assert_equal(f32s[1], Float32(-2.0))
    assert_equal(f32s[2], Float32(2.5), "an unpacked element")
    print("  test_d2_repeated_fixed_width_read_both_forms: PASS")


def test_d2_empty_packed_record_adds_nothing_and_next_field_follows() raises:
    var buf = _len_rec(1, List[UInt8]())
    buf.extend(_b("10 05"))
    var d = PbDecoder(buf^)
    var xs = List[Int32]()
    assert_equal(_first(d), 1)
    d.read_into_repeated_i32(xs)
    assert_equal(len(xs), 0, "an empty packed record has no elements")
    assert_equal(_first(d), 2, "the cursor stands at the next field")
    assert_equal(d.read_i32(), Int32(5))
    print("  test_d2_empty_packed_record_adds_nothing_and_next_field_follows: PASS")


def test_d2_strings_bytes_and_messages_are_never_packed() raises:
    var buf = _b("0a 02 61 62 0a 00 0a 01 63")
    var d = PbDecoder(buf^)
    var strs = List[String]()
    while True:
        if d.next_field().end:
            break
        d.read_into_repeated_string(strs)
    assert_equal(len(strs), 3)
    assert_equal(strs[0], String("ab"))
    assert_equal(strs[1], String(""))
    assert_equal(strs[2], String("c"))

    d = _dec("0a 02 01 02 0a 00")
    var blobs = List[List[UInt8]]()
    while True:
        if d.next_field().end:
            break
        d.read_into_repeated_bytes(blobs)
    assert_equal(len(blobs), 2)
    assert_equal(len(blobs[0]), 2)
    assert_equal(Int(blobs[0][1]), 2)
    assert_equal(len(blobs[1]), 0)

    d = _dec("0a 02 08 05 0a 04 08 06 12 00")
    var leaves = List[Leaf]()
    while True:
        if d.next_field().end:
            break
        d.read_into_repeated_message[Leaf](leaves)
    assert_equal(len(leaves), 2)
    assert_equal(leaves[0].n, Int64(5))
    assert_equal(leaves[1].n, Int64(6))
    assert_equal(leaves[1].tag, String(""))
    print("  test_d2_strings_bytes_and_messages_are_never_packed: PASS")


# =============================================================================


def main() raises:
    test_d1_string_and_bytes()
    test_d1_varint_readers()
    test_d1_zigzag_readers()
    test_d1_fixed_width_readers()
    test_d2_repeated_scalars_read_both_forms()
    test_d2_repeated_fixed_width_read_both_forms()
    test_d2_empty_packed_record_adds_nothing_and_next_field_follows()
    test_d2_strings_bytes_and_messages_are_never_packed()
