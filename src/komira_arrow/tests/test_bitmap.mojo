# =============================================================================
# Tests for Bitmap — imports from komira_arrow package
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_arrow.bitmap import Bitmap


def test_create_zeros() raises:
    """Bitmap.create() initializes all bits to 0 (null)."""
    var bm = Bitmap.create(16)
    assert_equal(bm.length, 16)
    assert_equal(bm.popcount(), 0)
    for i in range(16):
        assert_false(bm.test(i))


def test_set_and_test() raises:
    """Setting individual bits makes them testable."""
    var bm = Bitmap.create(8)
    bm.set(0)
    bm.set(3)
    bm.set(7)
    assert_true(bm.test(0))
    assert_false(bm.test(1))
    assert_false(bm.test(2))
    assert_true(bm.test(3))
    assert_false(bm.test(4))
    assert_false(bm.test(5))
    assert_false(bm.test(6))
    assert_true(bm.test(7))


def test_clear_bit() raises:
    """Clearing a set bit returns it to 0."""
    var bm = Bitmap.create(8)
    bm.set(3)
    assert_true(bm.test(3))
    bm.clear(3)
    assert_false(bm.test(3))


def test_popcount() raises:
    """Popcount accurately counts set bits."""
    var bm = Bitmap.create(16)
    assert_equal(bm.popcount(), 0)
    bm.set(0)
    assert_equal(bm.popcount(), 1)
    bm.set(5)
    assert_equal(bm.popcount(), 2)
    bm.set(15)
    assert_equal(bm.popcount(), 3)


def test_all_valid() raises:
    """all_valid() returns True only when all bits are set."""
    var bm = Bitmap.create(4)
    assert_false(bm.all_valid())
    bm.set(0)
    bm.set(1)
    bm.set(2)
    bm.set(3)
    assert_true(bm.all_valid())


def test_null_count() raises:
    """null_count() returns the number of unset bits."""
    var bm = Bitmap.create(8)
    assert_equal(bm.null_count(), 8)
    bm.set(0)
    bm.set(1)
    assert_equal(bm.null_count(), 6)


def test_create_all_valid() raises:
    """Bitmap.create_all_valid() initializes all bits to 1 (valid)."""
    var bm = Bitmap.create_all_valid(16)
    assert_equal(bm.length, 16)
    assert_equal(bm.popcount(), 16)
    assert_true(bm.all_valid())
    for i in range(16):
        assert_true(bm.test(i))


def test_create_all_valid_non_multiple_of_8() raises:
    """create_all_valid works for lengths that are not multiples of 8."""
    var bm = Bitmap.create_all_valid(5)
    assert_equal(bm.length, 5)
    assert_equal(bm.popcount(), 5)
    for i in range(5):
        assert_true(bm.test(i))


def test_set_clear_round_trip() raises:
    """Set then clear returns to original state."""
    var bm = Bitmap.create(8)
    for i in range(8):
        bm.set(i)
    assert_equal(bm.popcount(), 8)
    for i in range(8):
        bm.clear(i)
    assert_equal(bm.popcount(), 0)


def test_large_bitmap() raises:
    """Bitmap works correctly at 256 bits (multiple bytes)."""
    var bm = Bitmap.create(256)
    assert_equal(bm.length, 256)
    assert_equal(bm.popcount(), 0)
    bm.set(0)
    bm.set(63)
    bm.set(128)
    bm.set(255)
    assert_equal(bm.popcount(), 4)
    assert_true(bm.test(0))
    assert_true(bm.test(63))
    assert_true(bm.test(128))
    assert_true(bm.test(255))
    assert_false(bm.test(1))
    assert_false(bm.test(127))


# =============================================================================
# Bitwise combiner tests (Bitmap.and_, Bitmap.and_not)
# =============================================================================


def _assert_bits_equal(bm: Bitmap, bits: List[Bool]) raises:
    """Oracle: check every bit of `bm` against the reference pattern `bits`."""
    assert_equal(bm.length, len(bits))
    for i in range(len(bits)):
        if bits[i]:
            assert_true(bm.test(i), "expected bit " + String(i) + " to be set")
        else:
            assert_false(bm.test(i), "expected bit " + String(i) + " to be clear")


def test_and_empty() raises:
    """AND of two empty bitmaps produces an empty bitmap."""
    var a = Bitmap.create(0)
    var b = Bitmap.create(0)
    var c = a.and_(b)
    assert_equal(c.length, 0)
    assert_equal(c.popcount(), 0)


def test_and_all_zero() raises:
    """AND with all-zero bitmap produces all-zero."""
    var a = Bitmap.create_all_valid(37)
    var b = Bitmap.create(37)
    var c = a.and_(b)
    assert_equal(c.length, 37)
    assert_equal(c.popcount(), 0)


def test_and_all_one() raises:
    """x AND all_ones == x."""
    var a = Bitmap.create(37)
    a.set(0)
    a.set(7)
    a.set(20)
    a.set(36)
    var b = Bitmap.create_all_valid(37)
    var c = a.and_(b)
    assert_equal(c.popcount(), 4)
    assert_true(c.test(0))
    assert_true(c.test(7))
    assert_true(c.test(20))
    assert_true(c.test(36))


def test_and_alternating() raises:
    """AND of two alternating-bit patterns matches a scalar oracle."""
    var n = 200
    var a = Bitmap.create(n)
    var b = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var av = (i & 1) == 0       # even indices
        var bv = (i % 3) != 0       # not multiples of 3
        if av:
            a.set(i)
        if bv:
            b.set(i)
        expected.append(av and bv)
    var c = a.and_(b)
    _assert_bits_equal(c, expected)


def test_and_across_64bit_boundary() raises:
    """AND works across u64 word boundaries (size = 65 exercises tail + one chunk)."""
    var a = Bitmap.create_all_valid(65)
    var b = Bitmap.create_all_valid(65)
    # Poke a hole at index 64 (in the tail byte).
    b.clear(64)
    var c = a.and_(b)
    assert_equal(c.length, 65)
    assert_equal(c.popcount(), 64)
    for i in range(64):
        assert_true(c.test(i))
    assert_false(c.test(64))


def test_and_unaligned_length_bits_past_length_zeroed() raises:
    """Bits past `length` in the final partial byte must be zero in the output
    even if one of the inputs has stale bits there."""
    var a = Bitmap.create(5)
    var b = Bitmap.create(5)
    for i in range(5):
        a.set(i)
        b.set(i)
    var c = a.and_(b)
    assert_equal(c.length, 5)
    assert_equal(c.popcount(), 5)
    # The underlying byte must have bits 5..7 cleared.
    var byte0 = (c.buffer.view_typed_ro[DType.uint8]() + 0)[]
    assert_equal(Int(byte0), 0x1F)  # 0b00011111


def test_and_large_random_like() raises:
    """Large bitmap (1024 bits) exercises the SIMD stride multiple times."""
    var n = 1024
    var a = Bitmap.create(n)
    var b = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var av = (i * 17 + 3) % 5 != 0
        var bv = (i * 11 + 1) % 7 != 0
        if av:
            a.set(i)
        if bv:
            b.set(i)
        expected.append(av and bv)
    var c = a.and_(b)
    _assert_bits_equal(c, expected)


def test_and_not_empty() raises:
    """AND_NOT of empty bitmaps is empty."""
    var a = Bitmap.create(0)
    var b = Bitmap.create(0)
    var c = a.and_not(b)
    assert_equal(c.length, 0)


def test_and_not_with_all_zero_rhs() raises:
    """x AND NOT 0 == x (other is all-zero: keep all of self)."""
    var a = Bitmap.create(37)
    a.set(0)
    a.set(15)
    a.set(30)
    var b = Bitmap.create(37)
    var c = a.and_not(b)
    assert_equal(c.popcount(), 3)
    assert_true(c.test(0))
    assert_true(c.test(15))
    assert_true(c.test(30))


def test_and_not_with_all_one_rhs() raises:
    """x AND NOT all_ones == 0."""
    var a = Bitmap.create_all_valid(64)
    var b = Bitmap.create_all_valid(64)
    var c = a.and_not(b)
    assert_equal(c.length, 64)
    assert_equal(c.popcount(), 0)


def test_and_not_alternating() raises:
    """AND_NOT against scalar oracle across u64 boundary."""
    var n = 300
    var a = Bitmap.create(n)
    var b = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var av = (i & 1) == 0
        var bv = (i % 4) == 0
        if av:
            a.set(i)
        if bv:
            b.set(i)
        expected.append(av and (not bv))
    var c = a.and_not(b)
    _assert_bits_equal(c, expected)


def test_and_not_unaligned_length() raises:
    """AND_NOT at length=13 has tail bits zeroed."""
    var a = Bitmap.create_all_valid(13)
    var b = Bitmap.create(13)
    b.set(0)
    b.set(12)
    var c = a.and_not(b)
    assert_equal(c.popcount(), 11)
    assert_false(c.test(0))
    assert_false(c.test(12))
    for i in range(1, 12):
        assert_true(c.test(i))


def test_and_length_mismatch_raises() raises:
    """Bitmaps of different lengths cannot be AND'd."""
    var a = Bitmap.create(8)
    var b = Bitmap.create(16)
    var raised = False
    try:
        var _c = a.and_(b)
    except e:
        raised = True
    assert_true(raised)


# =============================================================================
# Bitmap.copy_slice_from tests (the bulk-copy primitive used by copy_column)
# =============================================================================


def test_copy_slice_zero_rows() raises:
    """Zero-bit slice yields a length-0 bitmap regardless of source state."""
    var src = Bitmap.create_all_valid(64)
    var dst = Bitmap.copy_slice_from(src, 0, 0)
    assert_equal(dst.length, 0)
    assert_equal(dst.popcount(), 0)


def test_copy_slice_single_row_aligned() raises:
    """Single-bit copy from byte-aligned offset returns the right bit."""
    var src = Bitmap.create(16)
    src.set(0)
    var dst1 = Bitmap.copy_slice_from(src, 0, 1)
    assert_equal(dst1.length, 1)
    assert_true(dst1.test(0))
    # Also from a clear bit
    var dst2 = Bitmap.copy_slice_from(src, 8, 1)
    assert_equal(dst2.length, 1)
    assert_false(dst2.test(0))


def test_copy_slice_single_row_misaligned() raises:
    """Single-bit copy from a non-byte-aligned offset still yields right bit."""
    var src = Bitmap.create(16)
    src.set(3)
    src.set(11)
    var dst1 = Bitmap.copy_slice_from(src, 3, 1)
    assert_equal(dst1.length, 1)
    assert_true(dst1.test(0))
    var dst2 = Bitmap.copy_slice_from(src, 4, 1)
    assert_false(dst2.test(0))
    var dst3 = Bitmap.copy_slice_from(src, 11, 1)
    assert_true(dst3.test(0))


def test_copy_slice_byte_aligned_full_bytes() raises:
    """Byte-aligned offset, multiple-of-8 length: pure memcpy fast path."""
    var n = 64
    var src = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var bit = (i * 7 + 1) % 3 != 0
        if bit:
            src.set(i)
        expected.append(bit)
    # Copy bits [16, 16+32) -- offset is byte-aligned (16/8=2),
    # length is byte-multiple (32/8=4).
    var dst = Bitmap.copy_slice_from(src, 16, 32)
    assert_equal(dst.length, 32)
    for i in range(32):
        if expected[16 + i]:
            assert_true(dst.test(i), "bit " + String(i) + " should be set")
        else:
            assert_false(dst.test(i), "bit " + String(i) + " should be clear")


def test_copy_slice_byte_aligned_unaligned_length() raises:
    """Byte-aligned offset, length not a multiple of 8: trailing bits zeroed."""
    var src = Bitmap.create_all_valid(64)
    # Copy bits [8, 8+13) = 13 bits starting at byte 1.
    var dst = Bitmap.copy_slice_from(src, 8, 13)
    assert_equal(dst.length, 13)
    assert_equal(dst.popcount(), 13)
    for i in range(13):
        assert_true(dst.test(i))


def test_copy_slice_misaligned_offset_full_pattern() raises:
    """Bit-shifted offset across a u64 boundary: scalar fallback path."""
    var n = 100
    var src = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var bit = (i * 13 + 5) % 7 != 0
        if bit:
            src.set(i)
        expected.append(bit)
    # Copy bits [3, 3+50) -- shift=3, spans u64 boundary at bit 64.
    var dst = Bitmap.copy_slice_from(src, 3, 50)
    assert_equal(dst.length, 50)
    for i in range(50):
        if expected[3 + i]:
            assert_true(dst.test(i),
                "bit " + String(i) + " should be set (shift=3)")
        else:
            assert_false(dst.test(i),
                "bit " + String(i) + " should be clear (shift=3)")


def test_copy_slice_misaligned_each_shift() raises:
    """Sweep all 7 misaligned shifts to catch off-by-one in the bit-shift path."""
    var n = 32
    var src = Bitmap.create_all_valid(n)
    for shift in range(1, 8):
        var dst = Bitmap.copy_slice_from(src, shift, n - shift)
        assert_equal(dst.length, n - shift)
        assert_equal(dst.popcount(), n - shift,
            "all-1s source should yield all-1s dst at shift=" + String(shift))
        for i in range(n - shift):
            assert_true(dst.test(i),
                "bit " + String(i) + " at shift=" + String(shift)
                + " should be set")


def test_copy_slice_tail_bits_masked() raises:
    """Trailing bits past num_bits in the final byte must NOT see source 1s."""
    # Source: all 1s in bits [0, 16). Copy bits [0, 5). Destination's
    # trailing bits 5..7 in byte 0 must be 0, even though source byte 0
    # is 0xFF.
    var src = Bitmap.create_all_valid(16)
    var dst = Bitmap.copy_slice_from(src, 0, 5)
    assert_equal(dst.length, 5)
    assert_equal(dst.popcount(), 5)
    # Trailing-bit check: read the underlying byte directly.
    var byte0 = dst.buffer.read_u8_at(0)
    assert_equal(Int(byte0), 0x1F)  # 0b00011111


def test_copy_slice_misaligned_tail_bits_masked() raises:
    """Tail-bit mask applies in the bit-unaligned path too."""
    var src = Bitmap.create_all_valid(32)
    # shift=3, num_bits=10 -> dst occupies bits 0..9, bits 10..15 must be 0.
    var dst = Bitmap.copy_slice_from(src, 3, 10)
    assert_equal(dst.length, 10)
    assert_equal(dst.popcount(), 10)
    var byte1 = dst.buffer.read_u8_at(1)
    # bits 8..9 set, bits 10..15 must be clear -> 0b00000011
    assert_equal(Int(byte1), 0x03)


def test_copy_slice_alignment_misalignment_consistency() raises:
    """Aligned and bit-shifted paths must produce identical bit patterns."""
    # Build a source where bits [16, 16+24) match bits [3, 3+24) shifted.
    # Easier: construct one source, copy via aligned offset 16 and via
    # misaligned offset 17, then check each yields the right slice.
    var n = 64
    var src = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var bit = (i % 3) == 1 or (i % 5) == 0
        if bit:
            src.set(i)
        expected.append(bit)
    # Aligned slice [16, 16+24)
    var dst_a = Bitmap.copy_slice_from(src, 16, 24)
    for i in range(24):
        if expected[16 + i]:
            assert_true(dst_a.test(i))
        else:
            assert_false(dst_a.test(i))
    # Misaligned slice [17, 17+24)
    var dst_m = Bitmap.copy_slice_from(src, 17, 24)
    for i in range(24):
        if expected[17 + i]:
            assert_true(dst_m.test(i),
                "misaligned bit " + String(i) + " should be set")
        else:
            assert_false(dst_m.test(i),
                "misaligned bit " + String(i) + " should be clear")


def test_copy_slice_oob_raises() raises:
    """Out-of-bounds slice must raise."""
    var src = Bitmap.create(16)
    var raised = False
    try:
        var _d = Bitmap.copy_slice_from(src, 8, 16)  # 8 + 16 > 16
    except e:
        raised = True
    assert_true(raised)


def test_copy_slice_negative_args_raise() raises:
    """Negative offset/length must raise."""
    var src = Bitmap.create(16)
    var r1 = False
    try:
        var _d = Bitmap.copy_slice_from(src, -1, 4)
    except e:
        r1 = True
    assert_true(r1)
    var r2 = False
    try:
        var _d = Bitmap.copy_slice_from(src, 0, -1)
    except e:
        r2 = True
    assert_true(r2)


def test_copy_slice_large_aligned_random_like() raises:
    """Large 1024-bit aligned slice exercises the SIMD/memcpy fast path."""
    var n = 2048
    var src = Bitmap.create(n)
    var expected: List[Bool] = []
    for i in range(n):
        var bit = (i * 31 + 7) % 11 != 0
        if bit:
            src.set(i)
        expected.append(bit)
    var dst = Bitmap.copy_slice_from(src, 64, 1024)
    assert_equal(dst.length, 1024)
    for i in range(1024):
        if expected[64 + i]:
            assert_true(dst.test(i))
        else:
            assert_false(dst.test(i))


# =============================================================================
# Bitmap.copy_bits_into tests.
# Cover byte-aligned fast path and bit-unaligned fallback.
# Validates the streaming-concat hot path.
# =============================================================================


def test_copy_bits_into_aligned_aligned_full_byte() raises:
    """src_offset=0, dst_offset=0, num_bits=64 — pure byte-aligned memcpy."""
    var src = Bitmap.create(128)
    # Pattern: every 3rd bit set in src[0..64].
    for i in range(64):
        if i % 3 == 0:
            src.set(i)
    var dst = Bitmap.create_all_valid(128)
    Bitmap.copy_bits_into(dst, 0, src, 0, 64)
    for i in range(64):
        var expect = (i % 3 == 0)
        assert_equal(dst.test(i), expect)
    # dst bits past 64 should be unchanged (still 1 from create_all_valid).
    for i in range(64, 128):
        assert_true(dst.test(i))


def test_copy_bits_into_aligned_aligned_with_tail_bits() raises:
    """src_offset=0, dst_offset=0, num_bits=70 (8 full bytes + 6 tail bits).

    Tail bits force the partial-byte read-modify-write path.
    """
    var src = Bitmap.create(128)
    for i in range(70):
        if i & 1 == 0:
            src.set(i)
    var dst = Bitmap.create_all_valid(128)
    Bitmap.copy_bits_into(dst, 0, src, 0, 70)
    for i in range(70):
        var expect = (i & 1 == 0)
        assert_equal(dst.test(i), expect)
    # bit 70 must still be 1 (not overwritten by the tail-bit path).
    assert_true(dst.test(70))
    # bit 71 ditto.
    assert_true(dst.test(71))


def test_copy_bits_into_aligned_aligned_offset_8() raises:
    """src_offset=16, dst_offset=8 — both byte-aligned, non-zero offsets."""
    var src = Bitmap.create(128)
    src.set(16)
    src.set(20)
    src.set(31)
    var dst = Bitmap.create(128)
    dst.set(0)  # sentinel before
    dst.set(72)  # sentinel after
    Bitmap.copy_bits_into(dst, 8, src, 16, 16)
    # dst[8..24] should mirror src[16..32].
    assert_true(dst.test(8))    # src bit 16
    assert_false(dst.test(9))
    assert_false(dst.test(10))
    assert_false(dst.test(11))
    assert_true(dst.test(12))   # src bit 20
    assert_false(dst.test(13))
    assert_false(dst.test(22))
    assert_true(dst.test(23))   # src bit 31
    # Sentinels preserved:
    assert_true(dst.test(0))
    assert_true(dst.test(72))


def test_copy_bits_into_misaligned_misaligned() raises:
    """src_offset=3, dst_offset=5 — both bit-misaligned. Slow path."""
    var src = Bitmap.create(64)
    src.set(3)
    src.set(7)
    src.set(15)
    src.set(31)
    var dst = Bitmap.create(64)
    dst.set(0)  # before-range sentinel
    dst.set(50)  # after-range sentinel
    Bitmap.copy_bits_into(dst, 5, src, 3, 32)
    # dst[5..37] should mirror src[3..35].
    assert_true(dst.test(5))     # src bit 3
    assert_false(dst.test(6))
    assert_false(dst.test(7))
    assert_false(dst.test(8))
    assert_true(dst.test(9))     # src bit 7
    assert_true(dst.test(17))    # src bit 15
    assert_true(dst.test(33))    # src bit 31
    # Sentinels preserved:
    assert_true(dst.test(0))
    assert_true(dst.test(50))


def test_copy_bits_into_aligned_misaligned() raises:
    """src_offset=0 (aligned), dst_offset=3 (misaligned). Slow path."""
    var src = Bitmap.create(32)
    src.set(0)
    src.set(5)
    src.set(15)
    var dst = Bitmap.create(64)
    Bitmap.copy_bits_into(dst, 3, src, 0, 16)
    assert_true(dst.test(3))     # src bit 0
    assert_false(dst.test(4))
    assert_true(dst.test(8))     # src bit 5
    assert_true(dst.test(18))    # src bit 15


def test_copy_bits_into_misaligned_aligned() raises:
    """src_offset=2 (misaligned), dst_offset=0 (aligned). Slow path."""
    var src = Bitmap.create(32)
    src.set(2)
    src.set(7)
    src.set(15)
    var dst = Bitmap.create(32)
    Bitmap.copy_bits_into(dst, 0, src, 2, 16)
    assert_true(dst.test(0))     # src bit 2
    assert_false(dst.test(1))
    assert_true(dst.test(5))     # src bit 7
    assert_true(dst.test(13))    # src bit 15


def test_copy_bits_into_empty_input() raises:
    """num_bits=0 — no-op, no error."""
    var src = Bitmap.create(8)
    var dst = Bitmap.create(8)
    dst.set(3)
    Bitmap.copy_bits_into(dst, 0, src, 0, 0)
    # dst unchanged.
    assert_true(dst.test(3))


def test_copy_bits_into_single_bit_aligned() raises:
    """num_bits=1 at byte-aligned offset: tail-bit path with 1 bit."""
    var src = Bitmap.create(8)
    src.set(0)
    var dst = Bitmap.create_all_valid(8)
    Bitmap.copy_bits_into(dst, 0, src, 0, 1)
    assert_true(dst.test(0))   # copied
    # bits 1..7 must remain 1.
    for i in range(1, 8):
        assert_true(dst.test(i))


def test_copy_bits_into_single_bit_zero_aligned() raises:
    """num_bits=1, src bit is 0; dst bit was 1 → must become 0."""
    var src = Bitmap.create(8)  # all zeros
    var dst = Bitmap.create_all_valid(8)
    Bitmap.copy_bits_into(dst, 0, src, 0, 1)
    assert_false(dst.test(0))  # cleared
    for i in range(1, 8):
        assert_true(dst.test(i))


def test_copy_bits_into_streaming_concat_pattern() raises:
    """Mimics _concat_fixed_columns_multi: fold 3 batches of 100 rows
    each into one 300-row dst, where each batch has different validity.

    Batch 1 (rows 0..99): all valid.
    Batch 2 (rows 100..199): every 5th row null.
    Batch 3 (rows 200..299): rows 200..209 null.

    All offsets are 0 in src, dst offsets are 0, 100, 200 — so
    row_cursor=100 hits a misaligned boundary, row_cursor=200 hits
    a byte-aligned boundary.
    """
    var dst = Bitmap.create_all_valid(300)

    # Batch 1: all valid (skip — copy of all-1 is a no-op)
    var src1 = Bitmap.create_all_valid(100)
    Bitmap.copy_bits_into(dst, 0, src1, 0, 100)
    # Batch 2: every 5th null.
    var src2 = Bitmap.create_all_valid(100)
    for i in range(100):
        if i % 5 == 0:
            src2.clear(i)
    Bitmap.copy_bits_into(dst, 100, src2, 0, 100)
    # Batch 3: rows 0..9 null, rest valid.
    var src3 = Bitmap.create_all_valid(100)
    for i in range(10):
        src3.clear(i)
    Bitmap.copy_bits_into(dst, 200, src3, 0, 100)

    # Verify dst[0..99] all valid.
    for i in range(100):
        assert_true(dst.test(i))
    # Verify dst[100..199] every 5th null.
    for i in range(100):
        if i % 5 == 0:
            assert_false(dst.test(100 + i))
        else:
            assert_true(dst.test(100 + i))
    # Verify dst[200..299] first 10 null, rest valid.
    for i in range(10):
        assert_false(dst.test(200 + i))
    for i in range(10, 100):
        assert_true(dst.test(200 + i))


def test_copy_bits_into_large_aligned_run() raises:
    """1024 bits at aligned boundaries — exercises the SIMD/memcpy bulk path."""
    var src = Bitmap.create(2048)
    var expected: List[Bool] = []
    for i in range(2048):
        var bit = (i * 17 + 5) % 11 != 0
        if bit:
            src.set(i)
        expected.append(bit)
    var dst = Bitmap.create(2048)
    Bitmap.copy_bits_into(dst, 64, src, 128, 1024)
    for i in range(1024):
        if expected[128 + i]:
            assert_true(dst.test(64 + i))
        else:
            assert_false(dst.test(64 + i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
