# =============================================================================
# test_protobuf_roundtrip.mojo — komira_protobuf wire-codec round-trip suite.
# =============================================================================
#
# Encode -> decode is identity for every wire type, plus the named edge-case
# corpus.
#
# Every test encodes a value via the komira_protobuf writer, then decodes it
# back via the reader, and asserts byte / value identity. The encoders and
# decoders are independent code paths, so a round-trip is a real correctness
# signal (not a no-op). Several vectors also assert the EXACT wire bytes
# against the protobuf spec — varint LEB128, zigzag, tag layout — so a
# cross-impl reader (prost / protobuf-c) reads this package's output.
#
# Coverage (the wire-type + edge-case matrix):
#   T1   varint round-trip + exact LEB128 bytes (0, small, 7-bit boundary,
#        300, UInt64 max — the 10-byte varint).
#   T2   tag encode/decode — field_number + wire_type pack.
#   T3   sint32 / sint64 zigzag round-trip incl. negative + boundary values.
#   T4   fixed32 / fixed64 little-endian round-trip.
#   T5   float / double IEEE-754 round-trip.
#   T6   string field round-trip incl. empty + UTF-8 multibyte.
#   T7   bytes field round-trip incl. embedded NUL bytes.
#   T8   embedded message field round-trip (length-delimited sub-message).
#   T9   packed-repeated varint / sint64 / fixed32 / fixed64 round-trip.
#   T10  PbFieldCursor — the general tag-driven field-dispatch decode loop
#        over a hand-built multi-field message.
#   T11  edge case: int64 boundary values (Int64.MIN / Int64.MAX).
#   T12  edge case: empty message (zero fields) decodes cleanly.
#   T13  edge case: unknown-field skip-and-keep — the proto3 forward-compat
#        contract (pb_skip_field over every wire type).
#   T14  edge case: nested / deeply-nested messages (a 3-level message tree).
#   T15  wire guard: a malformed varint (runs past buffer end) raises.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.memory import bitcast

from komira_protobuf import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    PbVarint,
    PbTag,
    PbLenField,
    PbFieldCursor,
    zigzag_encode,
    zigzag_decode,
    zigzag_encode32,
    zigzag_decode32,
    pb_read_varint,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    pb_read_string,
    pb_read_bytes,
    pb_read_fixed32,
    pb_read_fixed64,
    pb_read_float,
    pb_read_double,
    pb_read_packed_varints,
    pb_read_packed_sint64,
    pb_read_packed_fixed32,
    pb_read_packed_fixed64,
    pb_write_varint,
    pb_write_tag,
    pb_write_varint_field,
    pb_write_bool_field,
    pb_write_len_field,
    pb_write_sint64_field,
    pb_write_sint32_field,
    pb_write_fixed64_field,
    pb_write_fixed32_field,
    pb_write_double_field,
    pb_write_float_field,
    pb_write_string_field,
    pb_write_bytes_field,
    pb_write_message_field,
    pb_write_packed_varints,
    pb_write_packed_sint64,
    pb_write_packed_fixed64,
    pb_write_packed_fixed32,
)


# =============================================================================
# T1 — varint round-trip + exact LEB128 byte vectors.
# =============================================================================


def test_varint_roundtrip() raises:
    """T1: varint encode -> decode is identity; exact LEB128 bytes asserted."""
    var vectors = List[UInt64](
        [
            UInt64(0),
            UInt64(1),
            UInt64(127),
            UInt64(128),
            UInt64(300),
            UInt64(16383),
            UInt64(16384),
            UInt64(0xFFFFFFFF),
            UInt64(0xFFFFFFFFFFFFFFFF),
        ]
    )
    for i in range(len(vectors)):
        var v = vectors[i]
        var buf = List[UInt8]()
        pb_write_varint(buf, v)
        var got = pb_read_varint(Span(buf), 0)
        assert_equal(got.value, v, "varint round-trip value")
        assert_equal(got.new_pos, len(buf), "varint round-trip consumes all")

    # Exact wire bytes — the protobuf-spec LEB128 reference vectors.
    var b0 = List[UInt8]()
    pb_write_varint(b0, 0)
    assert_equal(len(b0), 1, "varint(0) is 1 byte")
    assert_equal(Int(b0[0]), 0, "varint(0) byte")

    var b127 = List[UInt8]()
    pb_write_varint(b127, 127)
    assert_equal(len(b127), 1, "varint(127) is 1 byte")
    assert_equal(Int(b127[0]), 0x7F, "varint(127) byte")

    var b128 = List[UInt8]()
    pb_write_varint(b128, 128)
    assert_equal(len(b128), 2, "varint(128) is 2 bytes")
    assert_equal(Int(b128[0]), 0x80, "varint(128) byte 0")
    assert_equal(Int(b128[1]), 0x01, "varint(128) byte 1")

    var b300 = List[UInt8]()
    pb_write_varint(b300, 300)
    assert_equal(len(b300), 2, "varint(300) is 2 bytes")
    assert_equal(Int(b300[0]), 0xAC, "varint(300) byte 0")
    assert_equal(Int(b300[1]), 0x02, "varint(300) byte 1")

    var bmax = List[UInt8]()
    pb_write_varint(bmax, 0xFFFFFFFFFFFFFFFF)
    assert_equal(len(bmax), 10, "varint(UInt64.MAX) is the 10-byte form")


# =============================================================================
# T2 — tag encode/decode.
# =============================================================================


def test_tag_roundtrip() raises:
    """T2: a field tag packs field_number << 3 | wire_type and round-trips."""
    var cases = List[Int]([1, 2, 3, 15, 16, 2047, 8000, 536870911])
    var wires = List[Int](
        [PB_WIRE_VARINT, PB_WIRE_FIXED64, PB_WIRE_LEN, PB_WIRE_FIXED32]
    )
    for ci in range(len(cases)):
        for wi in range(len(wires)):
            var fn_no = cases[ci]
            var wt = wires[wi]
            var buf = List[UInt8]()
            pb_write_tag(buf, fn_no, wt)
            var got = pb_read_tag(Span(buf), 0)
            assert_equal(got.field_number, fn_no, "tag field number")
            assert_equal(got.wire_type, wt, "tag wire type")


# =============================================================================
# T3 — sint32 / sint64 zigzag round-trip.
# =============================================================================


def test_zigzag_roundtrip() raises:
    """T3: zigzag encode/decode is identity for negative + boundary values."""
    var v64 = List[Int64](
        [
            Int64(0),
            Int64(1),
            Int64(-1),
            Int64(2),
            Int64(-2),
            Int64(63),
            Int64(-64),
            Int64(1000000),
            Int64(-1000000),
            Int64.MAX,
            Int64.MIN,
        ]
    )
    for i in range(len(v64)):
        var v = v64[i]
        assert_equal(zigzag_decode(zigzag_encode(v)), v, "zigzag64 identity")

    # Exact zigzag mapping: 0->0, -1->1, 1->2, -2->3, 2->4.
    assert_equal(zigzag_encode(Int64(0)), UInt64(0), "zigzag(0)")
    assert_equal(zigzag_encode(Int64(-1)), UInt64(1), "zigzag(-1)")
    assert_equal(zigzag_encode(Int64(1)), UInt64(2), "zigzag(1)")
    assert_equal(zigzag_encode(Int64(-2)), UInt64(3), "zigzag(-2)")
    assert_equal(zigzag_encode(Int64(2)), UInt64(4), "zigzag(2)")

    var v32 = List[Int32](
        [
            Int32(0),
            Int32(1),
            Int32(-1),
            Int32(2147483647),
            Int32(-2147483648),
            Int32(65536),
            Int32(-65536),
        ]
    )
    for i in range(len(v32)):
        var v = v32[i]
        assert_equal(zigzag_decode32(zigzag_encode32(v)), v, "zigzag32 ident")

    # sint64 field round-trip via the wire writer/reader.
    for i in range(len(v64)):
        var v = v64[i]
        var buf = List[UInt8]()
        pb_write_sint64_field(buf, 3, v)
        var tag = pb_read_tag(Span(buf), 0)
        assert_equal(tag.field_number, 3, "sint64 field number")
        assert_equal(tag.wire_type, PB_WIRE_VARINT, "sint64 wire is varint")
        var raw = pb_read_varint(Span(buf), tag.new_pos)
        assert_equal(zigzag_decode(raw.value), v, "sint64 field round-trip")

    # sint32 field round-trip.
    for i in range(len(v32)):
        var v = v32[i]
        var buf = List[UInt8]()
        pb_write_sint32_field(buf, 4, v)
        var tag = pb_read_tag(Span(buf), 0)
        var raw = pb_read_varint(Span(buf), tag.new_pos)
        assert_equal(
            zigzag_decode32(UInt32(raw.value & 0xFFFFFFFF)),
            v,
            "sint32 field round-trip",
        )


# =============================================================================
# T4 / T5 — fixed32 / fixed64 + float / double.
# =============================================================================


def test_fixed_roundtrip() raises:
    """T4: fixed32 / fixed64 little-endian fields round-trip."""
    var u32 = List[UInt32](
        [
            UInt32(0),
            UInt32(1),
            UInt32(0xDEADBEEF),
            UInt32(0xFFFFFFFF),
            UInt32(256),
        ]
    )
    for i in range(len(u32)):
        var v = u32[i]
        var buf = List[UInt8]()
        pb_write_fixed32_field(buf, 5, v)
        var tag = pb_read_tag(Span(buf), 0)
        assert_equal(tag.wire_type, PB_WIRE_FIXED32, "fixed32 wire type")
        var s = pb_read_fixed32(Span(buf), tag.new_pos)
        assert_equal(s.value, v, "fixed32 round-trip")
        assert_equal(s.new_pos, len(buf), "fixed32 consumes 4 bytes")

    var u64 = List[UInt64](
        [
            UInt64(0),
            UInt64(1),
            UInt64(0xCAFEBABEDEADBEEF),
            UInt64(0xFFFFFFFFFFFFFFFF),
            UInt64(1) << 40,
        ]
    )
    for i in range(len(u64)):
        var v = u64[i]
        var buf = List[UInt8]()
        pb_write_fixed64_field(buf, 6, v)
        var tag = pb_read_tag(Span(buf), 0)
        assert_equal(tag.wire_type, PB_WIRE_FIXED64, "fixed64 wire type")
        var s = pb_read_fixed64(Span(buf), tag.new_pos)
        assert_equal(s.value, v, "fixed64 round-trip")


def test_float_double_roundtrip() raises:
    """T5: float / double IEEE-754 fields round-trip exactly."""
    var f32 = List[Float32](
        [
            Float32(0.0),
            Float32(1.0),
            Float32(-1.0),
            Float32(3.14159),
            Float32(1e30),
            Float32(-1e-30),
        ]
    )
    for i in range(len(f32)):
        var v = f32[i]
        var buf = List[UInt8]()
        pb_write_float_field(buf, 7, v)
        var tag = pb_read_tag(Span(buf), 0)
        var got = pb_read_float(Span(buf), tag.new_pos)
        assert_equal(
            bitcast[DType.uint32, 1](got),
            bitcast[DType.uint32, 1](v),
            "float round-trip (bit-identical)",
        )

    var f64 = List[Float64](
        [
            Float64(0.0),
            Float64(1.0),
            Float64(-1.0),
            Float64(2.718281828459045),
            Float64(1e300),
            Float64(-1e-300),
        ]
    )
    for i in range(len(f64)):
        var v = f64[i]
        var buf = List[UInt8]()
        pb_write_double_field(buf, 8, v)
        var tag = pb_read_tag(Span(buf), 0)
        var got = pb_read_double(Span(buf), tag.new_pos)
        assert_equal(
            bitcast[DType.uint64, 1](got),
            bitcast[DType.uint64, 1](v),
            "double round-trip (bit-identical)",
        )


# =============================================================================
# T6 / T7 — string + bytes length-delimited fields.
# =============================================================================


def test_string_roundtrip() raises:
    """T6: string fields round-trip incl. empty + multibyte UTF-8."""
    var strs = List[String](
        [
            String(""),
            String("a"),
            String("hello protobuf"),
            String("café ☃ \U0001F680"),  # accented + snowman + rocket
        ]
    )
    for i in range(len(strs)):
        var s = strs[i]
        var buf = List[UInt8]()
        pb_write_string_field(buf, 1, s)
        var tag = pb_read_tag(Span(buf), 0)
        assert_equal(tag.wire_type, PB_WIRE_LEN, "string wire type")
        var lf = pb_read_len_field(Span(buf), tag.new_pos)
        var got = pb_read_string(Span(buf), lf.payload_start, lf.payload_end)
        assert_equal(got, s, "string round-trip")


def test_bytes_roundtrip() raises:
    """T7: bytes fields round-trip incl. embedded NUL bytes."""
    var payload = List[UInt8](
        [
            UInt8(0),
            UInt8(1),
            UInt8(2),
            UInt8(0),
            UInt8(255),
            UInt8(128),
            UInt8(0),
            UInt8(0),
            UInt8(64),
        ]
    )
    var buf = List[UInt8]()
    pb_write_bytes_field(buf, 2, Span(payload))
    var tag = pb_read_tag(Span(buf), 0)
    var lf = pb_read_len_field(Span(buf), tag.new_pos)
    var got = pb_read_bytes(Span(buf), lf.payload_start, lf.payload_end)
    assert_equal(len(got), len(payload), "bytes length round-trip")
    for i in range(len(payload)):
        assert_equal(got[i], payload[i], "bytes content round-trip")

    # Empty bytes.
    var empty = List[UInt8]()
    var buf2 = List[UInt8]()
    pb_write_bytes_field(buf2, 2, Span(empty))
    var tag2 = pb_read_tag(Span(buf2), 0)
    var lf2 = pb_read_len_field(Span(buf2), tag2.new_pos)
    assert_equal(lf2.payload_end - lf2.payload_start, 0, "empty bytes field")


# =============================================================================
# T8 — embedded message field.
# =============================================================================


def test_message_field_roundtrip() raises:
    """T8: an embedded message (length-delimited sub-message) round-trips."""
    # Build a child message: field 1 = varint 42, field 2 = string "child".
    var child = List[UInt8]()
    pb_write_varint_field(child, 1, 42)
    pb_write_string_field(child, 2, String("child"))

    # Embed the child as field 5 of a parent.
    var parent = List[UInt8]()
    pb_write_message_field(parent, 5, child)

    # Decode: parent field 5 -> the child payload span.
    var tag = pb_read_tag(Span(parent), 0)
    assert_equal(tag.field_number, 5, "embedded message field number")
    assert_equal(tag.wire_type, PB_WIRE_LEN, "embedded message wire type")
    var lf = pb_read_len_field(Span(parent), tag.new_pos)
    assert_equal(
        lf.payload_end - lf.payload_start, len(child),
        "embedded message payload length",
    )
    # Re-decode the child fields off the parent buffer.
    var ctag = pb_read_tag(Span(parent), lf.payload_start)
    assert_equal(ctag.field_number, 1, "child field 1 number")
    var cv = pb_read_varint(Span(parent), ctag.new_pos)
    assert_equal(cv.value, UInt64(42), "child field 1 value")


# =============================================================================
# T9 — packed-repeated scalars.
# =============================================================================


def test_packed_repeated_roundtrip() raises:
    """T9: packed-repeated varint / sint64 / fixed32 / fixed64 round-trip."""
    var uvals = List[UInt64](
        [
            UInt64(1),
            UInt64(2),
            UInt64(300),
            UInt64(16384),
            UInt64(0xFFFFFFFFFFFFFFFF),
            UInt64(0),
        ]
    )
    var buf = List[UInt8]()
    pb_write_packed_varints(buf, 4, uvals)
    var tag = pb_read_tag(Span(buf), 0)
    assert_equal(tag.wire_type, PB_WIRE_LEN, "packed varint wire is LEN")
    var lf = pb_read_len_field(Span(buf), tag.new_pos)
    var ugot = pb_read_packed_varints(
        Span(buf), lf.payload_start, lf.payload_end
    )
    assert_equal(len(ugot), len(uvals), "packed varint count")
    for i in range(len(uvals)):
        assert_equal(ugot[i], uvals[i], "packed varint value")

    var svals = List[Int64](
        [
            Int64(0),
            Int64(-1),
            Int64(1),
            Int64(-1000000),
            Int64(1000000),
            Int64.MIN,
            Int64.MAX,
        ]
    )
    var sbuf = List[UInt8]()
    pb_write_packed_sint64(sbuf, 5, svals)
    var stag = pb_read_tag(Span(sbuf), 0)
    var slf = pb_read_len_field(Span(sbuf), stag.new_pos)
    var sgot = pb_read_packed_sint64(
        Span(sbuf), slf.payload_start, slf.payload_end
    )
    assert_equal(len(sgot), len(svals), "packed sint64 count")
    for i in range(len(svals)):
        assert_equal(sgot[i], svals[i], "packed sint64 value")

    var f32 = List[UInt32](
        [UInt32(0), UInt32(1), UInt32(0xDEADBEEF), UInt32(0xFFFFFFFF)]
    )
    var f32buf = List[UInt8]()
    pb_write_packed_fixed32(f32buf, 6, f32)
    var f32tag = pb_read_tag(Span(f32buf), 0)
    var f32lf = pb_read_len_field(Span(f32buf), f32tag.new_pos)
    var f32got = pb_read_packed_fixed32(
        Span(f32buf), f32lf.payload_start, f32lf.payload_end
    )
    assert_equal(len(f32got), len(f32), "packed fixed32 count")
    for i in range(len(f32)):
        assert_equal(f32got[i], f32[i], "packed fixed32 value")

    var f64 = List[UInt64](
        [UInt64(0), UInt64(1), UInt64(0xCAFEBABEDEADBEEF)]
    )
    var f64buf = List[UInt8]()
    pb_write_packed_fixed64(f64buf, 7, f64)
    var f64tag = pb_read_tag(Span(f64buf), 0)
    var f64lf = pb_read_len_field(Span(f64buf), f64tag.new_pos)
    var f64got = pb_read_packed_fixed64(
        Span(f64buf), f64lf.payload_start, f64lf.payload_end
    )
    assert_equal(len(f64got), len(f64), "packed fixed64 count")
    for i in range(len(f64)):
        assert_equal(f64got[i], f64[i], "packed fixed64 value")

    # An empty packed-repeated field writes nothing (proto3 omits empty).
    var empty = List[UInt64]()
    var ebuf = List[UInt8]()
    pb_write_packed_varints(ebuf, 4, empty)
    assert_equal(len(ebuf), 0, "empty packed-repeated writes nothing")


# =============================================================================
# T10 — PbFieldCursor: the general tag-driven field-dispatch decode loop.
# =============================================================================


def test_field_cursor_dispatch() raises:
    """T10: PbFieldCursor walks a hand-built multi-field message and the
    per-wire-type accessors decode each field correctly."""
    # Build a message with fields:
    #   1 varint   = 7
    #   2 string   = "name"
    #   3 sint64   = -42
    #   4 fixed64  = 0xABCD
    #   5 fixed32  = 0x1234
    #   6 bool     = true
    var msg = List[UInt8]()
    pb_write_varint_field(msg, 1, 7)
    pb_write_string_field(msg, 2, String("name"))
    pb_write_sint64_field(msg, 3, -42)
    pb_write_fixed64_field(msg, 4, 0xABCD)
    pb_write_fixed32_field(msg, 5, 0x1234)
    pb_write_bool_field(msg, 6, True)

    var cur = PbFieldCursor.over(Span(msg))
    var seen_1 = False
    var seen_2 = False
    var seen_3 = False
    var seen_4 = False
    var seen_5 = False
    var seen_6 = False
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            assert_equal(cur.read_varint(), UInt64(7), "cursor field 1")
            seen_1 = True
        elif tag.field_number == 2:
            assert_equal(cur.read_string(), String("name"), "cursor field 2")
            seen_2 = True
        elif tag.field_number == 3:
            assert_equal(cur.read_sint64(), Int64(-42), "cursor field 3")
            seen_3 = True
        elif tag.field_number == 4:
            assert_equal(cur.read_fixed64(), UInt64(0xABCD), "cursor field 4")
            seen_4 = True
        elif tag.field_number == 5:
            assert_equal(cur.read_fixed32(), UInt32(0x1234), "cursor field 5")
            seen_5 = True
        elif tag.field_number == 6:
            assert_true(cur.read_bool(), "cursor field 6")
            seen_6 = True
        else:
            cur.skip()
    assert_true(seen_1, "cursor saw field 1")
    assert_true(seen_2, "cursor saw field 2")
    assert_true(seen_3, "cursor saw field 3")
    assert_true(seen_4, "cursor saw field 4")
    assert_true(seen_5, "cursor saw field 5")
    assert_true(seen_6, "cursor saw field 6")


# =============================================================================
# T11 — edge case: int64 boundary values.
# =============================================================================


def test_int64_boundary_values() raises:
    """T11: Int64.MIN / Int64.MAX survive a varint + a zigzag round-trip."""
    # Plain varint of the unsigned bit-pattern.
    var as_u = bitcast[DType.uint64, 1](Int64.MIN)
    var buf = List[UInt8]()
    pb_write_varint(buf, as_u)
    var got = pb_read_varint(Span(buf), 0)
    assert_equal(
        bitcast[DType.int64, 1](got.value), Int64.MIN, "Int64.MIN varint"
    )

    # Zigzag — the sint encoding small negatives keep small, but MIN/MAX must
    # still survive exactly.
    assert_equal(
        zigzag_decode(zigzag_encode(Int64.MIN)), Int64.MIN, "Int64.MIN zigzag"
    )
    assert_equal(
        zigzag_decode(zigzag_encode(Int64.MAX)), Int64.MAX, "Int64.MAX zigzag"
    )


# =============================================================================
# T12 — edge case: empty message.
# =============================================================================


def test_empty_message() raises:
    """T12: a zero-field message decodes cleanly (the cursor sees no fields).
    """
    var empty = List[UInt8]()
    var cur = PbFieldCursor.over(Span(empty))
    assert_true(not cur.has_next(), "empty message has no fields")
    var count = 0
    while cur.has_next():
        _ = cur.next_tag()
        cur.skip()
        count += 1
    assert_equal(count, 0, "empty message field count")


# =============================================================================
# T13 — edge case: unknown-field skip-and-keep (proto3 forward-compat).
# =============================================================================


def test_unknown_field_skip() raises:
    """T13: pb_skip_field skips an unknown field of EVERY wire type, so a
    decoder that does not model a field stays forward-compatible."""
    # A message: field 1 (known, varint), field 99 (unknown, every wire type
    # in turn), field 2 (known, varint). The decoder reads 1 + 2, skips 99.
    def build_with_unknown(unknown: List[UInt8]) -> List[UInt8]:
        var m = List[UInt8]()
        pb_write_varint_field(m, 1, 111)
        for i in range(len(unknown)):
            m.append(unknown[i])
        pb_write_varint_field(m, 2, 222)
        return m^

    # Unknown field 99 as a VARINT.
    var u_varint = List[UInt8]()
    pb_write_varint_field(u_varint, 99, 9999)
    # Unknown field 99 as LEN (a string).
    var u_len = List[UInt8]()
    pb_write_string_field(u_len, 99, String("unknown payload"))
    # Unknown field 99 as FIXED64.
    var u_f64 = List[UInt8]()
    pb_write_fixed64_field(u_f64, 99, 0xDEADBEEF)
    # Unknown field 99 as FIXED32.
    var u_f32 = List[UInt8]()
    pb_write_fixed32_field(u_f32, 99, 0xBEEF)

    var variants = List[List[UInt8]]()
    variants.append(u_varint^)
    variants.append(u_len^)
    variants.append(u_f64^)
    variants.append(u_f32^)

    for vi in range(len(variants)):
        var msg = build_with_unknown(variants[vi])
        var cur = PbFieldCursor.over(Span(msg))
        var got_1: UInt64 = 0
        var got_2: UInt64 = 0
        while cur.has_next():
            var tag = cur.next_tag()
            if tag.field_number == 1:
                got_1 = cur.read_varint()
            elif tag.field_number == 2:
                got_2 = cur.read_varint()
            else:
                # The unknown field — skip-and-keep, never an error.
                cur.skip()
        assert_equal(got_1, UInt64(111), "known field 1 survives skip")
        assert_equal(got_2, UInt64(222), "known field 2 survives skip")


# =============================================================================
# T14 — edge case: deeply-nested messages.
# =============================================================================


def test_deeply_nested_messages() raises:
    """T14: a 3-level nested message tree round-trips via embedded fields."""
    # Level 3 (innermost): field 1 = string "leaf".
    var l3 = List[UInt8]()
    pb_write_string_field(l3, 1, String("leaf"))
    # Level 2: field 1 = varint 2, field 2 = embedded l3.
    var l2 = List[UInt8]()
    pb_write_varint_field(l2, 1, 2)
    pb_write_message_field(l2, 2, l3)
    # Level 1 (outermost): field 1 = varint 1, field 2 = embedded l2.
    var l1 = List[UInt8]()
    pb_write_varint_field(l1, 1, 1)
    pb_write_message_field(l1, 2, l2)

    # Walk down the tree with nested PbFieldCursors.
    var c1 = PbFieldCursor.over(Span(l1))
    var depth1_marker: UInt64 = 0
    var leaf = String("")
    while c1.has_next():
        var t1 = c1.next_tag()
        if t1.field_number == 1:
            depth1_marker = c1.read_varint()
        elif t1.field_number == 2:
            var c2 = c1.read_message()
            while c2.has_next():
                var t2 = c2.next_tag()
                if t2.field_number == 1:
                    assert_equal(c2.read_varint(), UInt64(2), "L2 marker")
                elif t2.field_number == 2:
                    var c3 = c2.read_message()
                    while c3.has_next():
                        var t3 = c3.next_tag()
                        if t3.field_number == 1:
                            leaf = c3.read_string()
                        else:
                            c3.skip()
                else:
                    c2.skip()
        else:
            c1.skip()
    assert_equal(depth1_marker, UInt64(1), "L1 marker")
    assert_equal(leaf, String("leaf"), "deeply-nested leaf string")


# =============================================================================
# T15 — wire guard: a malformed varint raises.
# =============================================================================


def test_malformed_varint_raises() raises:
    """T15: a varint whose continuation bit runs past the buffer end raises —
    the decoder fails fast, never reads out of bounds."""
    # A buffer of all-continuation bytes (high bit set) with no terminator.
    var bad = List[UInt8]([UInt8(0x80), UInt8(0x80), UInt8(0x80)])
    var raised = False
    try:
        var _v = pb_read_varint(Span(bad), 0)
    except:
        raised = True
    assert_true(raised, "varint past buffer end raises")

    # A length-delimited field claiming more bytes than exist.
    var bad_len = List[UInt8]()
    pb_write_tag(bad_len, 1, PB_WIRE_LEN)
    pb_write_varint(bad_len, 9999)  # claims 9999 payload bytes; none follow.
    var raised2 = False
    try:
        var tag = pb_read_tag(Span(bad_len), 0)
        var _lf = pb_read_len_field(Span(bad_len), tag.new_pos)
    except:
        raised2 = True
    assert_true(raised2, "length-delimited field past buffer end raises")


def main() raises:
    test_varint_roundtrip()
    test_tag_roundtrip()
    test_zigzag_roundtrip()
    test_fixed_roundtrip()
    test_float_double_roundtrip()
    test_string_roundtrip()
    test_bytes_roundtrip()
    test_message_field_roundtrip()
    test_packed_repeated_roundtrip()
    test_field_cursor_dispatch()
    test_int64_boundary_values()
    test_empty_message()
    test_unknown_field_skip()
    test_deeply_nested_messages()
    test_malformed_varint_raises()
    print("test_protobuf_roundtrip: ALL PASS")
