# =============================================================================
# ByteBuffer: the owned read cursor, and write_uleb128, its encoder.
# =============================================================================
#
# Every read is checked at the exact end of the buffer (the last read that
# fits must succeed, the first that does not must raise with its own
# message), and every refusal leaves the cursor where it was. The varint
# cases cover one, two and ten bytes, a varint cut short, and zigzag's two
# signs. Mutants each group was seen to kill are in the pull request that
# added this file.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.byte_buffer import ByteBuffer, write_uleb128
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


def _seq(n: Int) -> List[UInt8]:
    """n bytes 0x10, 0x11, ...: never zero, distinct within 240 bytes."""
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(0x10 + i))
    return out^


def _error_of_advance(mut b: ByteBuffer, n: Int) -> String:
    try:
        b.advance(n)
    except e:
        return String(e)
    return String("no error")


def test_constructors_and_state() raises:
    """`ByteBuffer(data)` starts at 0; `ByteBuffer(data, start)` at `start`.
    `remaining`, `position`, `length` and `is_empty` follow the cursor."""
    var a = ByteBuffer(_seq(5))
    assert_equal(a.position(), 0)
    assert_equal(a.length(), 5)
    assert_equal(a.remaining(), 5)
    assert_false(a.is_empty())

    var b = ByteBuffer(_seq(5), 3)
    assert_equal(b.position(), 3)
    assert_equal(b.remaining(), 2)
    assert_equal(b.read_byte(), UInt8(0x13))
    assert_equal(b.remaining(), 1)
    assert_false(b.is_empty())
    _ = b.read_byte()
    assert_equal(b.remaining(), 0)
    assert_true(b.is_empty())

    var empty = ByteBuffer(List[UInt8]())
    assert_true(empty.is_empty())
    assert_equal(empty.length(), 0)


def test_advance_to_exact_end_and_past_it() raises:
    """Advancing to exactly the end succeeds; one byte further raises and
    leaves the position unchanged."""
    var b = ByteBuffer(_seq(4))
    b.advance(2)
    assert_equal(b.position(), 2)
    b.advance(2)
    assert_equal(b.position(), 4)
    assert_true(b.is_empty())

    var c = ByteBuffer(_seq(4))
    c.advance(2)
    assert_equal(
        _error_of_advance(c, 3),
        "ByteBuffer: advance(3) at pos 2 exceeds length 4",
    )
    assert_equal(c.position(), 2)


def test_set_position_bounds() raises:
    """0 and the length are both valid positions; -1 and length + 1 raise."""
    var b = ByteBuffer(_seq(3))
    b.set_position(3)
    assert_equal(b.position(), 3)
    b.set_position(0)
    assert_equal(b.position(), 0)
    b.set_position(1)
    assert_equal(b.read_byte(), UInt8(0x11))

    var msg = String()
    try:
        b.set_position(-1)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: set_position(-1) out of range [0, 3]")
    msg = String()
    try:
        b.set_position(4)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: set_position(4) out of range [0, 3]")
    assert_equal(b.position(), 2)


def test_peek_and_single_byte_reads() raises:
    """`peek` does not move; `read_byte` and `read_byte_int` do. The last
    byte reads, the next read raises with the method's own message."""
    var b = ByteBuffer(_seq(3))
    assert_equal(b.peek(), UInt8(0x10))
    assert_equal(b.peek(), UInt8(0x10))
    assert_equal(b.position(), 0)
    assert_equal(b.read_byte(), UInt8(0x10))
    assert_equal(b.read_byte_int(), 0x11)
    assert_equal(b.peek(), UInt8(0x12))
    assert_equal(b.read_byte(), UInt8(0x12))
    assert_equal(b.position(), 3)

    var msg = String()
    try:
        _ = b.peek()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: peek past end of buffer")
    msg = String()
    try:
        _ = b.read_byte()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_byte past end of buffer")
    msg = String()
    try:
        _ = b.read_byte_int()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_byte_int past end of buffer")
    assert_equal(b.position(), 3)


def test_read_byte_int_high_byte() raises:
    """A byte with its high bit set widens to 0..255, never negative."""
    var data = List[UInt8]()
    data.append(0xFF)
    data.append(0x80)
    var b = ByteBuffer(data^)
    assert_equal(b.read_byte_int(), 255)
    assert_equal(b.read_byte_int(), 128)


def test_fixed_width_little_endian_reads() raises:
    """u32/i32/u64/i64 read little-endian at a non-zero position, with high
    bytes set so a sign or byte-order slip changes the value; each advances
    by its width."""
    var data = List[UInt8]()
    data.append(0xAA)  # skipped
    # u32 0x81020304
    data.append(0x04)
    data.append(0x03)
    data.append(0x02)
    data.append(0x81)
    # i32 -2 (0xFFFFFFFE)
    data.append(0xFE)
    data.append(0xFF)
    data.append(0xFF)
    data.append(0xFF)
    # u64 0x8807060504030201
    for v in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x88]:
        data.append(UInt8(v))
    # i64 -3
    data.append(0xFD)
    for _ in range(7):
        data.append(0xFF)
    var b = ByteBuffer(data^, 1)
    assert_equal(b.read_u32_le(), UInt32(0x81020304))
    assert_equal(b.position(), 5)
    assert_equal(b.read_i32_le(), Int32(-2))
    assert_equal(b.position(), 9)
    assert_equal(b.read_u64_le(), UInt64(0x8807060504030201))
    assert_equal(b.position(), 17)
    assert_equal(b.read_i64_le(), Int64(-3))
    assert_equal(b.position(), 25)
    assert_true(b.is_empty())


def test_fixed_width_reads_one_byte_short() raises:
    """With width - 1 bytes left each fixed read raises its own message and
    the position stays put; with exactly width bytes left it succeeds."""
    var b = ByteBuffer(_seq(7))
    b.set_position(4)
    var msg = String()
    try:
        _ = b.read_u32_le()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_u32_le needs 4 bytes")
    msg = String()
    try:
        _ = b.read_i32_le()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_i32_le needs 4 bytes")
    assert_equal(b.position(), 4)
    b.set_position(3)
    assert_equal(b.read_u32_le(), UInt32(0x16151413))
    b.set_position(3)
    assert_equal(b.read_i32_le(), Int32(0x16151413))

    var c = ByteBuffer(_seq(15))
    c.set_position(8)
    msg = String()
    try:
        _ = c.read_u64_le()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_u64_le needs 8 bytes")
    msg = String()
    try:
        _ = c.read_i64_le()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_i64_le needs 8 bytes")
    assert_equal(c.position(), 8)
    c.set_position(7)
    assert_equal(c.read_u64_le(), UInt64(0x1E1D1C1B1A191817))
    c.set_position(7)
    assert_equal(c.read_i64_le(), Int64(0x1E1D1C1B1A191817))


def test_uleb128_one_two_and_ten_bytes() raises:
    """0x7F is one byte; 300 is 0xAC 0x02; nine 0xFF then 0x01 is all 64
    bits set (-1 as Int): the tenth byte is shifted by 63."""
    var data = List[UInt8]()
    data.append(0x7F)
    data.append(0xAC)
    data.append(0x02)
    for _ in range(9):
        data.append(0xFF)
    data.append(0x01)
    data.append(0x00)
    var b = ByteBuffer(data^)
    assert_equal(b.read_uleb128(), 127)
    assert_equal(b.position(), 1)
    assert_equal(b.read_uleb128(), 300)
    assert_equal(b.position(), 3)
    assert_equal(b.read_uleb128(), -1)
    assert_equal(b.position(), 13)
    assert_equal(b.read_uleb128(), 0)
    assert_true(b.is_empty())


def test_uleb128_cut_short() raises:
    """A continuation byte at the end of the buffer raises (the varint never
    terminates), and an empty buffer raises before reading anything."""
    var data = List[UInt8]()
    data.append(0x80)
    data.append(0x80)
    var b = ByteBuffer(data^)
    var msg = String()
    try:
        _ = b.read_uleb128()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_uleb128 past end of buffer")

    var empty = ByteBuffer(List[UInt8]())
    msg = String()
    try:
        _ = empty.read_zigzag_varint()
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_uleb128 past end of buffer")


def test_zigzag_both_signs() raises:
    """Zigzag: 0 -> 0, 1 -> -1, 2 -> 1, 3 -> -2, 299 -> -150, 300 -> 150."""
    var data = List[UInt8]()
    for v in [0, 1, 2, 3]:
        write_uleb128(v, data)
    write_uleb128(299, data)
    write_uleb128(300, data)
    var b = ByteBuffer(data^)
    assert_equal(b.read_zigzag_varint(), 0)
    assert_equal(b.read_zigzag_varint(), -1)
    assert_equal(b.read_zigzag_varint(), 1)
    assert_equal(b.read_zigzag_varint(), -2)
    assert_equal(b.read_zigzag_varint(), -150)
    assert_equal(b.read_zigzag_varint(), 150)
    assert_true(b.is_empty())


def test_write_uleb128_bytes_and_round_trip() raises:
    """The encoder's exact bytes at the 7-bit boundaries (0, 127, 128,
    16383, 16384), and a round trip through read_uleb128 of values up to
    2^62."""
    var out = List[UInt8]()
    write_uleb128(0, out)
    assert_equal(out, [UInt8(0x00)])
    out = List[UInt8]()
    write_uleb128(127, out)
    assert_equal(out, [UInt8(0x7F)])
    out = List[UInt8]()
    write_uleb128(128, out)
    assert_equal(out, [UInt8(0x80), UInt8(0x01)])
    out = List[UInt8]()
    write_uleb128(16383, out)
    assert_equal(out, [UInt8(0xFF), UInt8(0x7F)])
    out = List[UInt8]()
    write_uleb128(16384, out)
    assert_equal(out, [UInt8(0x80), UInt8(0x80), UInt8(0x01)])

    var values = List[Int]()
    var v = 1
    for _ in range(63):
        values.append(v - 1)
        values.append(v)
        v = v * 2
    var data = List[UInt8]()
    data.append(0x55)  # write_uleb128 appends: this byte stays first
    for x in values:
        write_uleb128(x, data)
    var b = ByteBuffer(data^, 1)
    for x in values:
        assert_equal(b.read_uleb128(), x)
    assert_true(b.is_empty())


def test_read_slice_pos() raises:
    """Returns (start, n) and advances; n up to the end succeeds, past it
    raises and leaves the cursor."""
    var b = ByteBuffer(_seq(6), 1)
    var t = b.read_slice_pos(3)
    assert_equal(t[0], 1)
    assert_equal(t[1], 3)
    assert_equal(b.position(), 4)
    var msg = String()
    try:
        _ = b.read_slice_pos(3)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_slice_pos(3) at pos 4 exceeds length 6")
    assert_equal(b.position(), 4)
    var u = b.read_slice_pos(2)
    assert_equal(u[0], 4)
    assert_equal(u[1], 2)
    assert_true(b.is_empty())


def test_read_into_list_appends() raises:
    """Appends exactly n bytes after what `dest` held, from the cursor."""
    var b = ByteBuffer(_seq(6), 2)
    var dest = List[UInt8]()
    dest.append(0xEE)
    b.read_into_list(dest, 3)
    assert_equal(dest, [UInt8(0xEE), UInt8(0x12), UInt8(0x13), UInt8(0x14)])
    assert_equal(b.position(), 5)
    var msg = String()
    try:
        b.read_into_list(dest, 2)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_into_list(2) at pos 5 exceeds length 6")
    assert_equal(len(dest), 4)
    b.read_into_list(dest, 1)
    assert_equal(dest[4], UInt8(0x15))
    assert_true(b.is_empty())


def test_read_view_consumes() raises:
    """The view covers the n bytes at the cursor and the cursor moves past
    them; past the end raises."""
    var b = ByteBuffer(_seq(6), 1)
    var v = b.read_view(4)
    assert_equal(v.len(), 4)
    assert_equal(v.read_u8_at(0), UInt8(0x11))
    assert_equal(v.read_u8_at(3), UInt8(0x14))
    assert_equal(b.position(), 5)
    var msg = String()
    try:
        _ = b.read_view(2)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: read_view(2) at pos 5 exceeds length 6")
    assert_equal(b.position(), 5)
    var last = b.read_view(1)
    assert_equal(last.read_u8_at(0), UInt8(0x15))


def test_view_at_does_not_advance() raises:
    """view_at reads anywhere without moving the cursor: [start, start+len)
    up to the end is valid, a negative start and one byte past the end
    raise."""
    var b = ByteBuffer(_seq(6), 4)
    var v = b.view_at(2, 4)
    assert_equal(v.len(), 4)
    assert_equal(v.read_u8_at(0), UInt8(0x12))
    assert_equal(v.read_u8_at(3), UInt8(0x15))
    assert_equal(b.position(), 4)
    var msg = String()
    try:
        _ = b.view_at(3, 4)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: view_at(3, 4) out of range [0, 6]")
    msg = String()
    try:
        _ = b.view_at(-1, 1)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: view_at(-1, 1) out of range [0, 6]")


def test_current_view_is_the_unread_tail() raises:
    """current_view spans [position, length) and does not advance."""
    var b = ByteBuffer(_seq(5), 2)
    var v = b.current_view()
    assert_equal(v.len(), 3)
    assert_equal(v.read_u8_at(0), UInt8(0x12))
    assert_equal(v.read_u8_at(2), UInt8(0x14))
    assert_equal(b.position(), 2)
    b.advance(3)
    assert_equal(b.current_view().len(), 0)


def test_copy_into_view() raises:
    """Copies n bytes from the cursor into `dest` (bytes past n untouched)
    and advances; too few source bytes or too small a destination raise
    with their own message and move nothing."""
    var dst = OwnedAlignedBuffer(capacity=4)
    for i in range(4):
        dst.write_u8_at(i, UInt8(0xEE))
    var b = ByteBuffer(_seq(6), 1)
    b.copy_into_view(dst.view_mut(), 3)
    assert_equal(dst.read_u8_at(0), UInt8(0x11))
    assert_equal(dst.read_u8_at(2), UInt8(0x13))
    assert_equal(dst.read_u8_at(3), UInt8(0xEE))
    assert_equal(b.position(), 4)

    var msg = String()
    try:
        b.copy_into_view(dst.view_mut(), 3)
    except e:
        msg = String(e)
    assert_equal(msg, "ByteBuffer: copy_into_view(3) at pos 4 exceeds length 6")

    var small = OwnedAlignedBuffer(capacity=1)
    small.write_u8_at(0, UInt8(0xEE))
    msg = String()
    try:
        b.copy_into_view(small.view_mut(), 2)
    except e:
        msg = String(e)
    assert_equal(
        msg, "ByteBuffer: copy_into_view dest too small for 2 bytes (dest len=1)"
    )
    assert_equal(small.read_u8_at(0), UInt8(0xEE))
    assert_equal(b.position(), 4)

    var exact = OwnedAlignedBuffer(capacity=2)
    b.copy_into_view(exact.view_mut(), 2)
    assert_equal(exact.read_u8_at(1), UInt8(0x15))
    assert_true(b.is_empty())


def main() raises:
    var s = TestSuite()
    s.test[test_constructors_and_state]()
    s.test[test_advance_to_exact_end_and_past_it]()
    s.test[test_set_position_bounds]()
    s.test[test_peek_and_single_byte_reads]()
    s.test[test_read_byte_int_high_byte]()
    s.test[test_fixed_width_little_endian_reads]()
    s.test[test_fixed_width_reads_one_byte_short]()
    s.test[test_uleb128_one_two_and_ten_bytes]()
    s.test[test_uleb128_cut_short]()
    s.test[test_zigzag_both_signs]()
    s.test[test_write_uleb128_bytes_and_round_trip]()
    s.test[test_read_slice_pos]()
    s.test[test_read_into_list_appends]()
    s.test[test_read_view_consumes]()
    s.test[test_view_at_does_not_advance]()
    s.test[test_current_view_is_the_unread_tail]()
    s.test[test_copy_into_view]()
    s^.run()
