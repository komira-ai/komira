# =============================================================================
# test_protobuf_packed_bounds.mojo — every packed-repeated value lies inside
# its block `[start, end)`.
# =============================================================================
#
#   P1  a varint that starts inside a packed varint (sint64) block and
#       continues past `end` is refused, although the bytes after `end` are
#       inside the buffer and would complete it. A multi-byte varint that ends
#       exactly at `end` is accepted. Catches a reader whose per-value read is
#       bounded by the buffer instead of the block.
#   P2  the same refusal through `PbFieldCursor.read_packed_varints` /
#       `read_packed_sint64`: the payload of a LEN field ends mid-varint and the
#       next field's tag would complete it. Catches a cursor accessor that
#       hands the reader a bound wider than the payload.
#   P3  a packed fixed32 (fixed64) block whose length is not a multiple of 4
#       (8) is refused, for every remainder 1..3 (1..7); whole blocks of 0, 1
#       and 2 values are accepted with the right values. Catches a reader that
#       stops at the last whole value and drops the trailing bytes.
#
#   Reference: prost refuses both shapes when it merges a packed field (a
#   value overrunning the delimited length; a fixed-width read with too few
#   bytes left).
# =============================================================================

from std.testing import assert_equal, assert_raises

from komira_protobuf import (
    PbFieldCursor,
    pb_read_packed_varints,
    pb_read_packed_sint64,
    pb_read_packed_fixed32,
    pb_read_packed_fixed64,
)


comptime _PAST_BLOCK = "varint runs past the end of its packed block"


# P1 ===========================================================================


def test_varint_crossing_block_end_refused() raises:
    # 0x80 0x01 is the varint 128; the block is only its first byte.
    var b = List[UInt8]([UInt8(0x80), UInt8(0x01)])
    with assert_raises(contains=_PAST_BLOCK):
        _ = pb_read_packed_varints(Span(b), 0, 1)
    with assert_raises(contains=_PAST_BLOCK):
        _ = pb_read_packed_sint64(Span(b), 0, 1)
    # The same varint as the whole block decodes.
    var v = pb_read_packed_varints(Span(b), 0, 2)
    assert_equal(len(v), 1, "one varint")
    assert_equal(v[0], UInt64(128), "varint 128")
    var s = pb_read_packed_sint64(Span(b), 0, 2)
    assert_equal(len(s), 1, "one sint64")
    assert_equal(s[0], Int64(64), "zigzag 128 -> 64")


def test_second_varint_crossing_block_end_refused() raises:
    # Values 5 then 0x80 0x80 0x01 (16384); the block cuts the second after
    # two of its three bytes.
    var b = List[UInt8](
        [UInt8(0x05), UInt8(0x80), UInt8(0x80), UInt8(0x01)]
    )
    with assert_raises(contains=_PAST_BLOCK):
        _ = pb_read_packed_varints(Span(b), 0, 3)
    with assert_raises(contains=_PAST_BLOCK):
        _ = pb_read_packed_sint64(Span(b), 0, 3)
    var v = pb_read_packed_varints(Span(b), 0, 4)
    assert_equal(len(v), 2, "two varints")
    assert_equal(v[0], UInt64(5), "first")
    assert_equal(v[1], UInt64(16384), "second ends exactly at end")


# P2 ===========================================================================


def _len_then_varint_field() -> List[UInt8]:
    # field 1 LEN, length 1, payload 0x80 (a varint cut after one byte);
    # then field 2 VARINT = 1. The tag byte 0x10 would complete the varint.
    return List[UInt8](
        [UInt8(0x0A), UInt8(0x01), UInt8(0x80), UInt8(0x10), UInt8(0x01)]
    )


def test_cursor_packed_varints_stay_in_payload() raises:
    var b = _len_then_varint_field()
    var c = PbFieldCursor.over(Span(b))
    _ = c.next_tag()
    with assert_raises(contains=_PAST_BLOCK):
        _ = c.read_packed_varints()
    var d = PbFieldCursor.over(Span(b))
    _ = d.next_tag()
    with assert_raises(contains=_PAST_BLOCK):
        _ = d.read_packed_sint64()


# P3 ===========================================================================


def _bytes(n: Int) -> List[UInt8]:
    # n bytes 1, 2, 3, ... so every value read is distinguishable.
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(i + 1))
    return out^


def test_fixed32_partial_tail_refused() raises:
    var b = _bytes(12)
    for n in [1, 2, 3, 5, 6, 7, 9, 10, 11]:
        with assert_raises(
            contains="packed fixed32 block length "
            + String(n)
            + " is not a multiple of 4"
        ):
            _ = pb_read_packed_fixed32(Span(b), 0, n)
    # A partial tail at a non-zero start is measured from start.
    with assert_raises(contains="packed fixed32 block length 5"):
        _ = pb_read_packed_fixed32(Span(b), 3, 8)
    assert_equal(len(pb_read_packed_fixed32(Span(b), 4, 4)), 0, "empty")
    var two = pb_read_packed_fixed32(Span(b), 0, 8)
    assert_equal(len(two), 2, "two fixed32")
    assert_equal(two[0], UInt32(0x04030201), "first fixed32")
    assert_equal(two[1], UInt32(0x08070605), "second fixed32")


def test_fixed64_partial_tail_refused() raises:
    var b = _bytes(20)
    for n in [1, 2, 3, 4, 5, 6, 7, 9, 12, 15]:
        with assert_raises(
            contains="packed fixed64 block length "
            + String(n)
            + " is not a multiple of 8"
        ):
            _ = pb_read_packed_fixed64(Span(b), 0, n)
    with assert_raises(contains="packed fixed64 block length 9"):
        _ = pb_read_packed_fixed64(Span(b), 3, 12)
    assert_equal(len(pb_read_packed_fixed64(Span(b), 4, 4)), 0, "empty")
    var two = pb_read_packed_fixed64(Span(b), 0, 16)
    assert_equal(len(two), 2, "two fixed64")
    assert_equal(two[0], UInt64(0x0807060504030201), "first fixed64")
    assert_equal(two[1], UInt64(0x100F0E0D0C0B0A09), "second fixed64")


def main() raises:
    test_varint_crossing_block_end_refused()
    test_second_varint_crossing_block_end_refused()
    test_cursor_packed_varints_stay_in_payload()
    test_fixed32_partial_tail_refused()
    test_fixed64_partial_tail_refused()
    print("test_protobuf_packed_bounds: ALL PASS")
