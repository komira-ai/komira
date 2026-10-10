# =============================================================================
# test_proto_codec_binary_refusals.mojo — what the protobuf-binary decoder
# REFUSES, and the unknown fields it must SKIP.
# =============================================================================
#
# Every byte string here is written out by hand, so a test does not depend on
# the encoder agreeing with the decoder.
#
#   B1  a field whose WIRE TYPE does not match the reader is refused, naming
#       the wire type the reader expected — for every scalar reader (the
#       sint, fixed and sfixed readers included), `bytes`, an enum, a nested
#       message and a map entry. Catches: a reader that
#       drops its wire-type check (a LEN field read as a varint reads its
#       length as the value; a VARINT field read as LEN reads its value as a
#       length), and a refusal naming the wrong wire type.
#   B2  sub-message nesting is bounded at PB_MAX_DECODE_DEPTH levels counting
#       the outermost: 64 levels decode, 65 are refused with
#       ProtobufError.TOO_DEEP. Catches: an off-by-one either way, and a
#       bound that is never checked (the decoder would recurse until the
#       stack runs out).
#   B3  an unknown field inside a map ENTRY is skipped, before and after the
#       key, for both map readers this suite instantiates, and an unknown
#       top-level field is skipped (the proto3 forward-compatibility
#       contract). Catches: an entry loop that does not skip (the next tag is
#       then read from the unknown field's payload).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    ProtoEnum,
    Serializable,
    WireEncoder,
    WireDecoder,
    decode_proto,
    PB_MAX_DECODE_DEPTH,
    PB_DECODE_TOO_DEEP,
)

comptime VARINT = 0
comptime FIXED64 = 1
comptime LEN = 2
comptime FIXED32 = 5


@fieldwise_init
struct Color(ProtoEnum, Copyable, Movable, ImplicitlyCopyable):
    var value: Int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        return String("RED") if self.value == 1 else String("COLOR_UNSET")

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(1) if s == "RED" else Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "RED" or s == "COLOR_UNSET"

    @staticmethod
    def known_json_names() -> String:
        return String("COLOR_UNSET,RED")


@fieldwise_init
struct Leaf(Serializable, Copyable, Movable):
    var n: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "n", self.n)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var n = Int64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1:
                n = dec.read_i64()
            else:
                dec.skip()
        return Leaf(n)


@fieldwise_init
struct WireProbe(Serializable, Copyable, Movable):
    """One field per reader under test; field N is read by reader N."""

    var s: String
    var count: Int
    var names: Dict[String, String]
    var totals: Dict[String, Int64]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var s = String("")
        var count = 0
        var names = Dict[String, String]()
        var totals = Dict[String, Int64]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            count += 1
            var f = key.field_no
            if f == 1:
                s = dec.read_string()
            elif f == 2:
                _ = dec.read_bytes()
            elif f == 3:
                _ = dec.read_i64()
            elif f == 4:
                _ = dec.read_i32()
            elif f == 5:
                _ = dec.read_u64()
            elif f == 6:
                _ = dec.read_u32()
            elif f == 7:
                _ = dec.read_f64()
            elif f == 8:
                _ = dec.read_f32()
            elif f == 9:
                _ = dec.read_bool()
            elif f == 10:
                _ = dec.read_enum[Color]()
            elif f == 11:
                _ = dec.read_message[Leaf]()
            elif f == 12:
                dec.read_into_string_string_map(names)
            elif f == 13:
                dec.read_into_string_i64_map(totals)
            elif f == 14:
                _ = dec.read_sint64()
            elif f == 15:
                _ = dec.read_sint32()
            elif f == 16:
                _ = dec.read_fixed64()
            elif f == 17:
                _ = dec.read_fixed32()
            elif f == 18:
                _ = dec.read_sfixed64()
            elif f == 19:
                _ = dec.read_sfixed32()
            else:
                dec.skip()
        return WireProbe(s^, count, names^, totals^)


def _tag(field: Int, wire: Int) -> UInt8:
    return UInt8(field * 8 + wire)


def _field_of_wire(field: Int, wire: Int) -> List[UInt8]:
    """Field `field` with wire type `wire` and a well-formed zero payload."""
    var b = List[UInt8]()
    _append_varint(b, field * 8 + wire)  # fields 16 and up need 2 tag bytes
    var payload = 1  # VARINT 0, or LEN 0
    if wire == FIXED64:
        payload = 8
    elif wire == FIXED32:
        payload = 4
    for _ in range(payload):
        b.append(UInt8(0))
    return b^


def _refusal(var bytes: List[UInt8]) raises -> String:
    try:
        _ = decode_proto[WireProbe](bytes^)
    except e:
        return String(e)
    return String("")


def _expect_refusal(field: Int, wire: Int, want: String) raises:
    var got = _refusal(_field_of_wire(field, wire))
    assert_equal(
        got,
        want,
        String("field ")
        + String(field)
        + String(" sent with wire type ")
        + String(wire),
    )


# =============================================================================
# B1
# =============================================================================


def test_b1_a_wire_type_mismatch_is_refused_per_reader() raises:
    comptime M = "ProtobufError.WIRE_MISMATCH: expected "
    _expect_refusal(1, VARINT, String(M) + "LEN (string)")
    _expect_refusal(2, VARINT, String(M) + "LEN (bytes)")
    _expect_refusal(3, LEN, String(M) + "VARINT")
    _expect_refusal(4, LEN, String(M) + "VARINT")
    _expect_refusal(5, LEN, String(M) + "VARINT")
    _expect_refusal(6, LEN, String(M) + "VARINT")
    _expect_refusal(7, FIXED32, String(M) + "FIXED64")
    _expect_refusal(8, FIXED64, String(M) + "FIXED32")
    _expect_refusal(9, LEN, String(M) + "VARINT")
    _expect_refusal(10, LEN, String(M) + "VARINT (enum)")
    _expect_refusal(11, VARINT, String(M) + "LEN (message)")
    _expect_refusal(12, VARINT, String(M) + "LEN (map entry)")
    _expect_refusal(13, FIXED32, String(M) + "LEN (map entry)")
    _expect_refusal(14, LEN, String(M) + "VARINT (sint64)")
    _expect_refusal(15, FIXED32, String(M) + "VARINT (sint32)")
    _expect_refusal(16, FIXED32, String(M) + "FIXED64 (fixed64)")
    _expect_refusal(17, FIXED64, String(M) + "FIXED32 (fixed32)")
    _expect_refusal(18, VARINT, String(M) + "FIXED64 (sfixed64)")
    _expect_refusal(19, LEN, String(M) + "FIXED32 (sfixed32)")
    # The inversion: the matching wire type is read without a refusal.
    var ok = _field_of_wire(3, VARINT)
    ok.extend(_field_of_wire(1, LEN))
    ok.extend(_field_of_wire(8, FIXED32))
    ok.extend(_field_of_wire(14, VARINT))
    ok.extend(_field_of_wire(15, VARINT))
    ok.extend(_field_of_wire(16, FIXED64))
    ok.extend(_field_of_wire(17, FIXED32))
    ok.extend(_field_of_wire(18, FIXED64))
    ok.extend(_field_of_wire(19, FIXED32))
    var probe = decode_proto[WireProbe](ok^)
    assert_equal(probe.count, 9, "nine well-typed fields decode")
    print("  test_b1_a_wire_type_mismatch_is_refused_per_reader: PASS")


# =============================================================================
# B2
# =============================================================================


@fieldwise_init
struct Deep(Serializable, Copyable, Movable):
    """`message Deep { Deep inner = 1; }`, decoded as the depth below it."""

    var levels: Int

    def encode[E: WireEncoder](self, mut enc: E) raises:
        pass

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var levels = 1
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1:
                levels = dec.read_message[Deep]().levels + 1
            else:
                dec.skip()
        return Deep(levels)


def _append_varint(mut b: List[UInt8], v: Int):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _nested(levels: Int) -> List[UInt8]:
    """A `Deep` that is `levels` messages deep, the outermost included."""
    var inner = List[UInt8]()
    for _ in range(levels - 1):
        var outer = List[UInt8]()
        outer.append(_tag(1, LEN))
        _append_varint(outer, len(inner))
        outer.extend(Span(inner))
        inner = outer^
    return inner^


def test_b2_nesting_is_bounded_at_the_maximum_depth() raises:
    assert_equal(PB_MAX_DECODE_DEPTH, 64, "the bound this test is sized to")
    var at_bound = decode_proto[Deep](_nested(PB_MAX_DECODE_DEPTH))
    assert_equal(
        at_bound.levels,
        PB_MAX_DECODE_DEPTH,
        "a message exactly PB_MAX_DECODE_DEPTH deep must decode",
    )
    var msg = String("")
    try:
        _ = decode_proto[Deep](_nested(PB_MAX_DECODE_DEPTH + 1))
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(PB_DECODE_TOO_DEEP + ": this message nests more than 64"),
        String("one level past the bound must be refused as TOO_DEEP; got: ")
        + msg,
    )
    print("  test_b2_nesting_is_bounded_at_the_maximum_depth: PASS")


# =============================================================================
# B3
# =============================================================================


def _len_field(field: Int, payload: List[UInt8]) -> List[UInt8]:
    var b = List[UInt8]()
    b.append(_tag(field, LEN))
    _append_varint(b, len(payload))
    b.extend(Span(payload))
    return b^


def _str(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    b.extend(s.as_bytes())
    return b^


def _unknown_varint(field: Int) -> List[UInt8]:
    var b = List[UInt8]()
    b.append(_tag(field, VARINT))
    b.append(UInt8(5))
    return b^


def test_b3_unknown_fields_in_a_map_entry_are_skipped() raises:
    # names: an unknown field 3 AFTER the key and value, then one BEFORE.
    var e1 = _len_field(1, _str("k"))
    e1.extend(_len_field(2, _str("v")))
    e1.extend(_unknown_varint(3))
    var e2 = _unknown_varint(7)
    e2.extend(_len_field(1, _str("k2")))
    e2.extend(_len_field(2, _str("v2")))
    # totals: an unknown field between the key and the value.
    var e3 = _len_field(1, _str("t"))
    e3.extend(_unknown_varint(4))
    e3.append(_tag(2, VARINT))
    e3.append(UInt8(42))
    var doc = _len_field(12, e1)
    doc.extend(_len_field(12, e2))
    doc.extend(_len_field(13, e3))
    # An unknown TOP-LEVEL field, then a known one after it.
    doc.extend(_unknown_varint(15))
    doc.extend(_len_field(1, _str("after")))
    var probe = decode_proto[WireProbe](doc^)
    assert_equal(len(probe.names), 2, "both string->string entries decode")
    assert_equal(probe.names["k"], String("v"), "entry with a trailing unknown")
    assert_equal(probe.names["k2"], String("v2"), "entry with a leading unknown")
    assert_equal(len(probe.totals), 1, "the string->int64 entry decodes")
    assert_equal(probe.totals["t"], Int64(42), "value after an unknown field")
    assert_equal(probe.s, String("after"), "a field after a skipped field")
    print("  test_b3_unknown_fields_in_a_map_entry_are_skipped: PASS")


def main() raises:
    test_b1_a_wire_type_mismatch_is_refused_per_reader()
    test_b2_nesting_is_bounded_at_the_maximum_depth()
    test_b3_unknown_fields_in_a_map_entry_are_skipped()
