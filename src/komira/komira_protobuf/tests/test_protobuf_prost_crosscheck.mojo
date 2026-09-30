# =============================================================================
# test_protobuf_prost_crosscheck.mojo — komira_protobuf vs `prost` wire check.
# =============================================================================
#
# The golden vectors below hold the EXACT protobuf wire
# bytes emitted by `prost` 0.13's encoder (a real, widely-used, independent
# protobuf implementation) for a fixed corpus. This test decodes every golden
# vector with the komira_protobuf reader and asserts the field values match
# what `prost` was given. A pass proves this package's decoder is byte-compatible
# with prost's encoder — a true cross-implementation wire-format proof.
#
# The golden byte vectors below were GENERATED ONCE by a small Rust program
# that encodes the fixed corpus with prost 0.13. They are checked in as the
# `PROST_*` aliases, so the test needs neither `cargo` nor `prost`.
# Regenerate them and paste the emitted aliases here only if the corpus
# changes.
#
# Vectors:
#   PROST_SINGLE_VARINT_150  — the canonical "150 at field 1" wire example.
#   PROST_SCALARS            — varint / sint / fixed / float / double / bool /
#                              string / bytes — every scalar wire type.
#   PROST_PACKED_REPEATED    — prost packs repeated scalars (uint64 / sint64 /
#                              fixed32); the reader must decode the packed form.
#   PROST_OUTER              — an embedded message (Inner inside Outer).
#   PROST_EMPTY              — a zero-field message (prost emits zero bytes).
# =============================================================================

from std.testing import assert_equal, assert_true
from std.memory import bitcast

from komira_protobuf import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    PbFieldCursor,
    pb_read_varint,
    pb_read_tag,
    pb_read_packed_fixed32,
    zigzag_decode,
)


# === GENERATED prost 0.13 golden vectors =====================================


def _prost_scalars() -> List[UInt8]:
    return List[UInt8](
        [UInt8(8), UInt8(235), UInt8(229), UInt8(144), UInt8(197), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(1), UInt8(16), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(1), UInt8(24), UInt8(83), UInt8(32), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(15), UInt8(41), UInt8(239), UInt8(190), UInt8(173), UInt8(222), UInt8(190), UInt8(186), UInt8(254), UInt8(202), UInt8(53), UInt8(239), UInt8(190), UInt8(173), UInt8(222), UInt8(57), UInt8(105), UInt8(87), UInt8(20), UInt8(139), UInt8(10), UInt8(191), UInt8(5), UInt8(64), UInt8(69), UInt8(208), UInt8(15), UInt8(73), UInt8(64), UInt8(72), UInt8(1), UInt8(82), UInt8(18), UInt8(99), UInt8(97), UInt8(102), UInt8(195), UInt8(169), UInt8(32), UInt8(226), UInt8(152), UInt8(131), UInt8(32), UInt8(112), UInt8(114), UInt8(111), UInt8(116), UInt8(111), UInt8(98), UInt8(117), UInt8(102), UInt8(90), UInt8(7), UInt8(0), UInt8(1), UInt8(2), UInt8(0), UInt8(255), UInt8(128), UInt8(0)]
    )


def _prost_packed_repeated() -> List[UInt8]:
    return List[UInt8](
        [UInt8(10), UInt8(18), UInt8(1), UInt8(2), UInt8(172), UInt8(2), UInt8(128), UInt8(128), UInt8(1), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(1), UInt8(0), UInt8(18), UInt8(29), UInt8(0), UInt8(1), UInt8(2), UInt8(255), UInt8(136), UInt8(122), UInt8(128), UInt8(137), UInt8(122), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(1), UInt8(254), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(1), UInt8(26), UInt8(16), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(1), UInt8(0), UInt8(0), UInt8(0), UInt8(239), UInt8(190), UInt8(173), UInt8(222), UInt8(255), UInt8(255), UInt8(255), UInt8(255)]
    )


def _prost_outer() -> List[UInt8]:
    return List[UInt8](
        [UInt8(8), UInt8(137), UInt8(6), UInt8(18), UInt8(24), UInt8(8), UInt8(207), UInt8(174), UInt8(134), UInt8(169), UInt8(252), UInt8(255), UInt8(255), UInt8(255), UInt8(255), UInt8(1), UInt8(18), UInt8(11), UInt8(110), UInt8(101), UInt8(115), UInt8(116), UInt8(101), UInt8(100), UInt8(45), UInt8(108), UInt8(101), UInt8(97), UInt8(102)]
    )


def _prost_empty() -> List[UInt8]:
    return List[UInt8]()


def _prost_single_varint_150() -> List[UInt8]:
    return List[UInt8](
        [UInt8(8), UInt8(150), UInt8(1)]
    )


def test_prost_single_varint() raises:
    """The canonical protobuf wire example: `150` at field 1 — bytes 08 96 01.
    A pass proves the most basic tag + varint decode is prost-compatible."""
    var b = _prost_single_varint_150()
    assert_equal(len(b), 3, "single-varint golden is 3 bytes")
    assert_equal(Int(b[0]), 0x08, "tag byte = field 1, wire VARINT")
    assert_equal(Int(b[1]), 0x96, "varint(150) byte 0")
    assert_equal(Int(b[2]), 0x01, "varint(150) byte 1")

    var cur = PbFieldCursor.over(Span(b))
    assert_true(cur.has_next(), "single-varint has a field")
    var tag = cur.next_tag()
    assert_equal(tag.field_number, 1, "field number from prost")
    assert_equal(tag.wire_type, PB_WIRE_VARINT, "wire type from prost")
    assert_equal(cur.read_varint(), UInt64(150), "varint value from prost")
    assert_true(not cur.has_next(), "single-varint has exactly one field")


def test_prost_scalars() raises:
    """Decode the prost-encoded Scalars message; assert every scalar field."""
    var golden = _prost_scalars()
    var cur = PbFieldCursor.over(Span(golden))
    var got_int64: Int64 = 0
    var got_uint64: UInt64 = 0
    var got_sint64: Int64 = 0
    var got_sint32: Int32 = 0
    var got_fixed64: UInt64 = 0
    var got_fixed32: UInt32 = 0
    var got_double: Float64 = 0.0
    var got_float: Float32 = 0.0
    var got_bool = False
    var got_string = String("")
    var got_bytes = List[UInt8]()
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            got_int64 = bitcast[DType.int64, 1](cur.read_varint())
        elif tag.field_number == 2:
            got_uint64 = cur.read_varint()
        elif tag.field_number == 3:
            got_sint64 = cur.read_sint64()
        elif tag.field_number == 4:
            got_sint32 = cur.read_sint32()
        elif tag.field_number == 5:
            got_fixed64 = cur.read_fixed64()
        elif tag.field_number == 6:
            got_fixed32 = cur.read_fixed32()
        elif tag.field_number == 7:
            got_double = cur.read_double()
        elif tag.field_number == 8:
            got_float = cur.read_float()
        elif tag.field_number == 9:
            got_bool = cur.read_bool()
        elif tag.field_number == 10:
            got_string = cur.read_string()
        elif tag.field_number == 11:
            got_bytes = cur.read_bytes()
        else:
            cur.skip()

    # The values prost was handed by the generator.
    assert_equal(got_int64, Int64(-123456789), "prost int64")
    assert_equal(got_uint64, UInt64(18446744073709551615), "prost uint64 MAX")
    assert_equal(got_sint64, Int64(-42), "prost sint64")
    assert_equal(got_sint32, Int32(-2147483648), "prost sint32 MIN")
    assert_equal(got_fixed64, UInt64(0xCAFEBABEDEADBEEF), "prost fixed64")
    assert_equal(got_fixed32, UInt32(0xDEADBEEF), "prost fixed32")
    assert_equal(
        bitcast[DType.uint64, 1](got_double),
        bitcast[DType.uint64, 1](Float64(2.718281828459045)),
        "prost double (bit-identical)",
    )
    assert_equal(
        bitcast[DType.uint32, 1](got_float),
        bitcast[DType.uint32, 1](Float32(3.14159)),
        "prost float (bit-identical)",
    )
    assert_true(got_bool, "prost bool")
    assert_equal(got_string, String("café ☃ protobuf"), "prost string")
    var want_bytes = List[UInt8](
        [
            UInt8(0),
            UInt8(1),
            UInt8(2),
            UInt8(0),
            UInt8(255),
            UInt8(128),
            UInt8(0),
        ]
    )
    assert_equal(len(got_bytes), len(want_bytes), "prost bytes length")
    for i in range(len(want_bytes)):
        assert_equal(got_bytes[i], want_bytes[i], "prost bytes content")


def test_prost_packed_repeated() raises:
    """Decode prost's PACKED repeated scalars — prost packs repeated fields by
    default; the packed-repeated reader must decode the LEN-wrapped form.
    """
    var golden = _prost_packed_repeated()
    var cur = PbFieldCursor.over(Span(golden))
    var got_nums = List[UInt64]()
    var got_signed = List[Int64]()
    var got_fixed = List[UInt32]()
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            # prost packs uint64 repeated -> a single LEN field.
            assert_equal(tag.wire_type, PB_WIRE_LEN, "packed uint64 is LEN")
            got_nums = cur.read_packed_varints()
        elif tag.field_number == 2:
            assert_equal(tag.wire_type, PB_WIRE_LEN, "packed sint64 is LEN")
            got_signed = cur.read_packed_sint64()
        elif tag.field_number == 3:
            # prost packs fixed32 repeated -> a single LEN field.
            assert_equal(tag.wire_type, PB_WIRE_LEN, "packed fixed32 is LEN")
            var lf = cur.read_len()
            got_fixed = pb_read_packed_fixed32(
                Span(golden),
                lf.payload_start,
                lf.payload_end,
            )
        else:
            cur.skip()

    var want_nums = List[UInt64](
        [
            UInt64(1),
            UInt64(2),
            UInt64(300),
            UInt64(16384),
            UInt64(18446744073709551615),
            UInt64(0),
        ]
    )
    assert_equal(len(got_nums), len(want_nums), "packed uint64 count")
    for i in range(len(want_nums)):
        assert_equal(got_nums[i], want_nums[i], "packed uint64 value")

    var want_signed = List[Int64](
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
    assert_equal(len(got_signed), len(want_signed), "packed sint64 count")
    for i in range(len(want_signed)):
        assert_equal(got_signed[i], want_signed[i], "packed sint64 value")

    var want_fixed = List[UInt32](
        [UInt32(0), UInt32(1), UInt32(0xDEADBEEF), UInt32(4294967295)]
    )
    assert_equal(len(got_fixed), len(want_fixed), "packed fixed32 count")
    for i in range(len(want_fixed)):
        assert_equal(got_fixed[i], want_fixed[i], "packed fixed32 value")


def test_prost_outer_nested() raises:
    """Decode prost's Outer message — an embedded Inner sub-message."""
    var golden = _prost_outer()
    var cur = PbFieldCursor.over(Span(golden))
    var got_marker: Int64 = 0
    var got_inner_value: Int64 = 0
    var got_inner_label = String("")
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == 1:
            got_marker = bitcast[DType.int64, 1](cur.read_varint())
        elif tag.field_number == 2:
            var inner = cur.read_message()
            while inner.has_next():
                var it = inner.next_tag()
                if it.field_number == 1:
                    got_inner_value = bitcast[DType.int64, 1](
                        inner.read_varint()
                    )
                elif it.field_number == 2:
                    got_inner_label = inner.read_string()
                else:
                    inner.skip()
        else:
            cur.skip()
    assert_equal(got_marker, Int64(777), "prost Outer.marker")
    assert_equal(got_inner_value, Int64(-987654321), "prost Inner.value")
    assert_equal(got_inner_label, String("nested-leaf"), "prost Inner.label")


def test_prost_empty_message() raises:
    """prost encodes a zero-field message as zero bytes — decode cleanly."""
    var golden = _prost_empty()
    assert_equal(len(golden), 0, "prost empty message is zero bytes")
    var cur = PbFieldCursor.over(Span(golden))
    assert_true(not cur.has_next(), "prost empty message has no fields")


def main() raises:
    test_prost_single_varint()
    test_prost_scalars()
    test_prost_packed_repeated()
    test_prost_outer_nested()
    test_prost_empty_message()
    print("test_protobuf_prost_crosscheck: ALL PASS")
