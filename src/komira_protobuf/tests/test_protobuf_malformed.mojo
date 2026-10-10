# =============================================================================
# test_protobuf_malformed.mojo — the free reader functions' refusals, the
# sint readers, the empty packed writers, and the wire-type names.
# =============================================================================
#
# The round-trip suite feeds the decoder well-formed bytes. This suite feeds
# the free reader functions bytes a hostile or corrupt peer could send, and
# asserts each guard refuses them with its own message — and that the input
# one step inside each guard is still accepted, so a guard that refuses too
# much fails here too.
#
#   M1  pb_read_varint: an 11-byte varint is refused ("exceeds 10 bytes");
#       a 10-byte one is accepted.
#   M2  pb_read_tag: field number 0 is refused, for wire types 0 and 7;
#       field number 1 is accepted.
#   M3  pb_read_len_field: a length whose Int value is negative (>= 2^63)
#       is refused, not turned into a payload that ends before it starts.
#   M4  pb_skip_field: FIXED64 / FIXED32 one byte short are refused, exact
#       length accepted; wire types 6 and 7 are refused and named.
#   M5  pb_read_fixed32 / pb_read_fixed64: one byte short is refused.
#   M6  pb_read_sint64 / pb_read_sint32: zigzag decode of the varint at
#       `pos`, and sint32 keeps only the low 32 bits (as prost does).
#   M7  _pb_check_span through every span reader: start < 0, end < start
#       and end > len each refused; the empty and the whole-buffer span
#       accepted.
#   M8  the packed writers write nothing for an empty list.
#   M9  pb_wire_type_name for each wire type and an unknown one.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_protobuf import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    pb_wire_type_name,
    zigzag_encode,
    zigzag_encode32,
    pb_read_varint,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    pb_read_string,
    pb_read_bytes,
    pb_read_sint64,
    pb_read_sint32,
    pb_read_fixed32,
    pb_read_fixed64,
    pb_read_packed_varints,
    pb_read_packed_sint64,
    pb_read_packed_fixed32,
    pb_read_packed_fixed64,
    pb_write_varint,
    pb_write_packed_varints,
    pb_write_packed_sint64,
    pb_write_packed_fixed64,
    pb_write_packed_fixed32,
)


def _repeat(byte: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(byte)
    return out^


# M1 ===========================================================================


def test_varint_longer_than_ten_bytes_refused() raises:
    # Ten continuation bytes then a terminator: an 11-byte varint. The buffer
    # holds the terminator, so the only refusal that applies is the length cap.
    var eleven = _repeat(0x80, 10)
    eleven.append(0x01)
    with assert_raises(contains="varint exceeds 10 bytes"):
        _ = pb_read_varint(Span(eleven), 0)
    # The same cap, reached at an offset: the count is per varint, not per buffer.
    var at_two = List[UInt8]([UInt8(0x05), UInt8(0x06)])
    at_two.extend(eleven.copy())
    with assert_raises(contains="varint exceeds 10 bytes"):
        _ = pb_read_varint(Span(at_two), 2)
    # Nine continuation bytes then a terminator: 10 bytes, the maximum, accepted.
    var ten = _repeat(0xFF, 9)
    ten.append(0x01)
    var v = pb_read_varint(Span(ten), 0)
    assert_equal(v.value, UInt64.MAX, "10-byte varint value")
    assert_equal(v.new_pos, 10, "10-byte varint end")


# M2 ===========================================================================


def test_tag_field_number_zero_refused() raises:
    # key 0x00: field 0, wire VARINT.
    var zero = List[UInt8]([UInt8(0x00)])
    with assert_raises(contains="field number 0 is illegal"):
        _ = pb_read_tag(Span(zero), 0)
    # key 0x07: field 0, wire 7 — the wire bits must not hide the field number.
    var zero_w7 = List[UInt8]([UInt8(0x07)])
    with assert_raises(contains="field number 0 is illegal"):
        _ = pb_read_tag(Span(zero_w7), 0)
    # key 0x08: field 1, wire VARINT — the smallest legal field number.
    var one = List[UInt8]([UInt8(0x08)])
    var t = pb_read_tag(Span(one), 0)
    assert_equal(t.field_number, 1, "field 1 accepted")
    assert_equal(t.wire_type, PB_WIRE_VARINT, "field 1 wire")


# M3 ===========================================================================


def test_len_field_negative_length_refused() raises:
    # Length UInt64.MAX: Int(UInt64.MAX) is -1, so payload_end = start - 1,
    # which is inside the buffer but BEFORE payload_start.
    var huge = List[UInt8]()
    pb_write_varint(huge, UInt64.MAX)
    huge.extend(_repeat(0xAA, 4))
    with assert_raises(contains="length-delimited field runs past"):
        _ = pb_read_len_field(Span(huge), 0)
    # Length 2^63 + 3: Int value Int.MIN + 3, payload_end far negative.
    var min_len = List[UInt8]()
    pb_write_varint(min_len, (UInt64(1) << 63) + 3)
    min_len.extend(_repeat(0xAA, 4))
    with assert_raises(contains="length-delimited field runs past"):
        _ = pb_read_len_field(Span(min_len), 0)
    # Length exactly the rest of the buffer is accepted.
    var exact = List[UInt8]()
    pb_write_varint(exact, 4)
    exact.extend(_repeat(0xAA, 4))
    var f = pb_read_len_field(Span(exact), 0)
    assert_equal(f.payload_start, 1, "exact len start")
    assert_equal(f.payload_end, 5, "exact len end")


# M4 ===========================================================================


def test_skip_field_short_and_unknown_wire_refused() raises:
    var seven = _repeat(0x11, 7)
    with assert_raises(contains="fixed64 past end"):
        _ = pb_skip_field(Span(seven), 0, PB_WIRE_FIXED64)
    var nine = _repeat(0x11, 9)
    with assert_raises(contains="fixed64 past end"):
        _ = pb_skip_field(Span(nine), 2, PB_WIRE_FIXED64)
    assert_equal(pb_skip_field(Span(nine), 1, PB_WIRE_FIXED64), 9, "fixed64 exact")

    var three = _repeat(0x22, 3)
    with assert_raises(contains="fixed32 past end"):
        _ = pb_skip_field(Span(three), 0, PB_WIRE_FIXED32)
    var five = _repeat(0x22, 5)
    with assert_raises(contains="fixed32 past end"):
        _ = pb_skip_field(Span(five), 2, PB_WIRE_FIXED32)
    assert_equal(pb_skip_field(Span(five), 1, PB_WIRE_FIXED32), 5, "fixed32 exact")

    # Wire types 6 and 7 are not protobuf wire types: refused, and named.
    with assert_raises(contains="unknown wire type 6"):
        _ = pb_skip_field(Span(nine), 0, 6)
    with assert_raises(contains="unknown wire type 7"):
        _ = pb_skip_field(Span(nine), 0, 7)


# M5 ===========================================================================


def test_fixed_readers_short_refused() raises:
    var four = List[UInt8]([UInt8(1), UInt8(2), UInt8(3), UInt8(4)])
    with assert_raises(contains="fixed32 past end"):
        _ = pb_read_fixed32(Span(four), 1)
    assert_equal(pb_read_fixed32(Span(four), 0).value, UInt32(0x04030201), "fixed32 at 0")
    var eight = _repeat(0x01, 8)
    with assert_raises(contains="fixed64 past end"):
        _ = pb_read_fixed64(Span(eight), 1)
    assert_equal(
        pb_read_fixed64(Span(eight), 0).value,
        UInt64(0x0101010101010101),
        "fixed64 at 0",
    )


# M6 ===========================================================================


def test_sint_readers() raises:
    # A buffer with a leading unrelated byte, so `pos` is honoured.
    var vals = List[Int64](
        [
            Int64(0),
            Int64(-1),
            Int64(1),
            Int64(-2),
            Int64(63),
            Int64(-64),
            Int64.MAX,
            Int64.MIN,
        ]
    )
    for i in range(len(vals)):
        var buf = List[UInt8]([UInt8(0xEE)])
        pb_write_varint(buf, zigzag_encode(vals[i]))
        assert_equal(pb_read_sint64(Span(buf), 1), vals[i], "sint64 value")

    var vals32 = List[Int32](
        [
            Int32(0),
            Int32(-1),
            Int32(1),
            Int32(-2),
            Int32.MAX,
            Int32.MIN,
        ]
    )
    for i in range(len(vals32)):
        var buf = List[UInt8]([UInt8(0xEE)])
        pb_write_varint(buf, UInt64(zigzag_encode32(vals32[i])))
        assert_equal(pb_read_sint32(Span(buf), 1), vals32[i], "sint32 value")

    # Spec vectors: 0x03 -> -2, 0x04 -> 2 for both widths.
    var three = List[UInt8]([UInt8(0x03)])
    assert_equal(pb_read_sint64(Span(three), 0), Int64(-2), "sint64 0x03")
    assert_equal(pb_read_sint32(Span(three), 0), Int32(-2), "sint32 0x03")
    var four = List[UInt8]([UInt8(0x04)])
    assert_equal(pb_read_sint64(Span(four), 0), Int64(2), "sint64 0x04")
    assert_equal(pb_read_sint32(Span(four), 0), Int32(2), "sint32 0x04")

    # sint32 keeps the low 32 bits of a wider varint (prost: `as u32`):
    # 0x1_0000_0003 -> low 3 -> -2. sint64 reads the whole value.
    var wide = List[UInt8]()
    pb_write_varint(wide, (UInt64(1) << 32) | 3)
    assert_equal(pb_read_sint32(Span(wide), 0), Int32(-2), "sint32 truncates")
    assert_equal(
        pb_read_sint64(Span(wide), 0), Int64(-2147483650), "sint64 full width"
    )

    var bad = List[UInt8]([UInt8(0x80)])
    with assert_raises(contains="varint runs past buffer end"):
        _ = pb_read_sint64(Span(bad), 0)
    with assert_raises(contains="varint runs past buffer end"):
        _ = pb_read_sint32(Span(bad), 0)


# M7 ===========================================================================


def _six() -> List[UInt8]:
    # Six bytes that decode under every span reader: 01 02 03 04 05 06.
    return List[UInt8](
        [UInt8(1), UInt8(2), UInt8(3), UInt8(4), UInt8(5), UInt8(6)]
    )


def test_span_check_string_bytes() raises:
    var b = _six()
    with assert_raises(contains="string span [-1, 2) is not inside the 6-byte"):
        _ = pb_read_string(Span(b), -1, 2)
    with assert_raises(contains="string span [3, 2)"):
        _ = pb_read_string(Span(b), 3, 2)
    with assert_raises(contains="string span [0, 7)"):
        _ = pb_read_string(Span(b), 0, 7)
    assert_equal(pb_read_string(Span(b), 6, 6).byte_length(), 0, "empty string at end")
    assert_equal(pb_read_string(Span(b), 0, 6).byte_length(), 6, "whole string")

    with assert_raises(contains="bytes span [-1, 2)"):
        _ = pb_read_bytes(Span(b), -1, 2)
    with assert_raises(contains="bytes span [3, 2)"):
        _ = pb_read_bytes(Span(b), 3, 2)
    with assert_raises(contains="bytes span [0, 7)"):
        _ = pb_read_bytes(Span(b), 0, 7)
    assert_equal(len(pb_read_bytes(Span(b), 0, 0)), 0, "empty bytes")
    var whole = pb_read_bytes(Span(b), 0, 6)
    assert_equal(len(whole), 6, "whole bytes")
    assert_equal(whole[5], UInt8(6), "whole bytes last")


def test_span_check_packed() raises:
    var b = _six()
    with assert_raises(contains="packed varint block span [-1, 2)"):
        _ = pb_read_packed_varints(Span(b), -1, 2)
    with assert_raises(contains="packed varint block span [3, 2)"):
        _ = pb_read_packed_varints(Span(b), 3, 2)
    with assert_raises(contains="packed varint block span [0, 7)"):
        _ = pb_read_packed_varints(Span(b), 0, 7)
    assert_equal(len(pb_read_packed_varints(Span(b), 0, 6)), 6, "varints whole")

    with assert_raises(contains="packed sint64 block span [-1, 2)"):
        _ = pb_read_packed_sint64(Span(b), -1, 2)
    with assert_raises(contains="packed sint64 block span [3, 2)"):
        _ = pb_read_packed_sint64(Span(b), 3, 2)
    with assert_raises(contains="packed sint64 block span [0, 7)"):
        _ = pb_read_packed_sint64(Span(b), 0, 7)
    assert_equal(len(pb_read_packed_sint64(Span(b), 0, 6)), 6, "sint64 whole")

    with assert_raises(contains="packed fixed32 block span [-1, 2)"):
        _ = pb_read_packed_fixed32(Span(b), -1, 2)
    with assert_raises(contains="packed fixed32 block span [3, 2)"):
        _ = pb_read_packed_fixed32(Span(b), 3, 2)
    with assert_raises(contains="packed fixed32 block span [0, 7)"):
        _ = pb_read_packed_fixed32(Span(b), 0, 7)
    assert_equal(len(pb_read_packed_fixed32(Span(b), 2, 6)), 1, "fixed32 tail")

    with assert_raises(contains="packed fixed64 block span [-1, 2)"):
        _ = pb_read_packed_fixed64(Span(b), -1, 2)
    with assert_raises(contains="packed fixed64 block span [3, 2)"):
        _ = pb_read_packed_fixed64(Span(b), 3, 2)
    with assert_raises(contains="packed fixed64 block span [0, 7)"):
        _ = pb_read_packed_fixed64(Span(b), 0, 7)
    assert_equal(len(pb_read_packed_fixed64(Span(b), 6, 6)), 0, "fixed64 empty")


# M8 ===========================================================================


def test_empty_packed_writers_write_nothing() raises:
    # A one-byte prefix stands for whatever the caller already wrote.
    var out = List[UInt8]([UInt8(0x5A)])
    pb_write_packed_varints(out, 1, List[UInt64]())
    pb_write_packed_sint64(out, 2, List[Int64]())
    pb_write_packed_fixed64(out, 3, List[UInt64]())
    pb_write_packed_fixed32(out, 4, List[UInt32]())
    assert_equal(len(out), 1, "empty packed lists append no bytes")
    assert_equal(out[0], UInt8(0x5A), "prefix untouched")
    # One element each still writes a field: the guard is on emptiness only.
    pb_write_packed_sint64(out, 2, List[Int64]([Int64(-1)]))
    pb_write_packed_fixed64(out, 3, List[UInt64]([UInt64(7)]))
    pb_write_packed_fixed32(out, 4, List[UInt32]([UInt32(7)]))
    # tag+len+1 (sint64 -1 -> 0x01), tag+len+8, tag+len+4.
    assert_equal(len(out), 1 + 3 + 10 + 6, "one-element packed fields")


# M9 ===========================================================================


def test_wire_type_names() raises:
    assert_equal(pb_wire_type_name(PB_WIRE_VARINT), String("VARINT"), "0")
    assert_equal(pb_wire_type_name(PB_WIRE_FIXED64), String("FIXED64"), "1")
    assert_equal(pb_wire_type_name(PB_WIRE_LEN), String("LEN"), "2")
    assert_equal(pb_wire_type_name(PB_WIRE_FIXED32), String("FIXED32"), "5")
    assert_equal(pb_wire_type_name(6), String("UNKNOWN"), "6")
    assert_equal(pb_wire_type_name(-1), String("UNKNOWN"), "-1")


def main() raises:
    test_varint_longer_than_ten_bytes_refused()
    test_tag_field_number_zero_refused()
    test_len_field_negative_length_refused()
    test_skip_field_short_and_unknown_wire_refused()
    test_fixed_readers_short_refused()
    test_sint_readers()
    test_span_check_string_bytes()
    test_span_check_packed()
    test_empty_packed_writers_write_nothing()
    test_wire_type_names()
    print("test_protobuf_malformed: ALL PASS")
