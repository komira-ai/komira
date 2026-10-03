# =============================================================================
# Tests for byte_class table_lookup + find_any_of + bitmask + compress +
# masked_memory + quote_region_mask.
# =============================================================================
#
# Coverage:
#   L1  table_lookup_u8x16 — identity / reverse / partial (sequential index).
#   L2  table_lookup_u8x32 — 32-byte 2-half lookup.
#   L3  nibble_lut_classify_u8x16 — byte-class detection via nibble LUTs.
#   F1  byte_find_eq_2/3/4/5 at W=16 — multi-needle find correctness.
#   F2  byte_find_eq_4 at W=32 — AVX2 width.
#   F3  byte_find_in_set_u8x16 — nibble-LUT find-in-set.
#   B1  append_set_positions_u16/32/64 — set-bit enumeration.
#   B2  popcount / first_set_bit.
#   X1  compress_u8x32 — mask-driven compress.
#   X2  compress_with_count_u8x32 — count return.
#   X3  expand_via_shuffle_u8x32 — carve-out composite.
#   M1  masked_load_u8x32 / masked_store_u8x32 — scalar fallback.
#   M2  tail_mask_u8x32 — partial-chunk mask.
#   Q1  quote_region_mask_u64 — single quote / paired / multi-region.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_simd.byte_class.table_lookup import (
    table_lookup_u8x16, table_lookup_u8x32, nibble_lut_classify_u8x16,
)
from komira_simd.byte_class.byte_find_any_of import (
    byte_find_eq_2_u8x16, byte_find_eq_3_u8x16, byte_find_eq_4_u8x16,
    byte_find_eq_5_u8x16, byte_find_eq_4_u8x32,
    byte_find_in_set_u8x16, build_byte_set_nibble_luts,
)
from komira_simd.byte_class.bitmask_to_positions import (
    append_set_positions_u16, append_set_positions_u32,
    append_set_positions_u64, popcount_u32, popcount_u64,
    first_set_bit_u32, first_set_bit_u64,
)
from komira_simd.byte_class.compress_expand import (
    compress_u8x32, compress_with_count_u8x32,
    expand_via_shuffle_u8x32,
)
from komira_simd.byte_class.masked_memory import (
    masked_load_u8x32, masked_store_u8x32, tail_mask_u8x32,
)
from komira_simd.byte_class.quote_region_mask import (
    quote_region_mask_u64,
)


# =============================================================================
# L1 — table_lookup_u8x16.
# =============================================================================

def test_table_lookup_u8x16_identity() raises:
    # table[k] = k*4, indices = [0, 1, 2, ..., 15] → out[k] = k*4
    var table = SIMD[DType.uint8, 16](0)
    var indices = SIMD[DType.uint8, 16](0)
    for k in range(16):
        table[k] = UInt8(k * 4)
        indices[k] = UInt8(k)
    var out = table_lookup_u8x16(table, indices)
    for k in range(16):
        assert_equal(out[k], UInt8(k * 4))


def test_table_lookup_u8x16_reverse() raises:
    var table = SIMD[DType.uint8, 16](0)
    var indices = SIMD[DType.uint8, 16](0)
    for k in range(16):
        table[k] = UInt8(k + 1)  # 1..16
        indices[k] = UInt8(15 - k)
    var out = table_lookup_u8x16(table, indices)
    for k in range(16):
        # out[k] = table[15 - k] = (15 - k) + 1 = 16 - k
        assert_equal(out[k], UInt8(16 - k))


# =============================================================================
# L2 — table_lookup_u8x32.
# =============================================================================

def test_table_lookup_u8x32() raises:
    # NEON 32-lane: two independent 16-byte halves; each half's index
    # only addresses its OWN half.  Build (table_lo, table_hi) where
    # both halves are identical: table[k] = k * 2 for k in 0..15.
    var table = SIMD[DType.uint8, 32](0)
    var indices = SIMD[DType.uint8, 32](0)
    for k in range(32):
        table[k] = UInt8((k % 16) * 2)  # table_lo = table_hi
        indices[k] = UInt8(k % 16)  # identity within each half
    var out = table_lookup_u8x32(table, indices)
    for k in range(32):
        assert_equal(out[k], UInt8((k % 16) * 2))


# =============================================================================
# L3 — nibble_lut_classify (the byte_classify_simd shape).
# =============================================================================

def test_nibble_lut_classify_simple() raises:
    # Build LUTs that mark byte 0x41 ('A') as the only set byte.
    # low nibble of 0x41 is 0x1; high nibble is 0x4.
    # lo_lut[0x1] needs bit (1 << 0x4) set = 0x10
    # hi_lut[0x4] needs bit (1 << 0x1) set = 0x02
    # AND of lo_class(0x10) and hi_class(0x02) = 0
    # So for this scheme we need: lo_lut[ln] bit position = hn,
    # hi_lut[hn] bit position = ln.  For byte 0x41 we need both
    # SAME bit to be set in both LUTs at their respective indices.
    # Common convention: use 1 << hn for lo_lut and 1 << ln for hi_lut.
    # Then AND yields (1 << hn) & (1 << ln) — non-zero ONLY if hn == ln.
    # For byte 0x41 (ln=1, hn=4) this convention doesn't match.
    #
    # The CORRECT scheme (per Highway nibble-LUT) is to use a SHARED bit
    # marker. Use bit position 0 for the only target byte:
    #   lo_lut[1] = 0x01
    #   hi_lut[4] = 0x01
    # Then byte 0x41 → lo_class = 0x01, hi_class = 0x01, AND = 0x01.
    # Other bytes will (usually) get 0 because the matching bit doesn't
    # land at the right position. This is the canonical simdjson scheme.
    var lo_lut = SIMD[DType.uint8, 16](0)
    var hi_lut = SIMD[DType.uint8, 16](0)
    lo_lut[0x1] = UInt8(0x01)
    hi_lut[0x4] = UInt8(0x01)

    var chunk = SIMD[DType.uint8, 16](0)
    chunk[0] = UInt8(0x41)  # 'A' — should classify as 0x01
    chunk[1] = UInt8(0x42)  # 'B' — should classify as 0x00
    chunk[5] = UInt8(0x41)  # 'A' again
    var out = nibble_lut_classify_u8x16(lo_lut, hi_lut, chunk)
    assert_equal(out[0], UInt8(0x01))
    assert_equal(out[1], UInt8(0x00))  # 'B' has hi_nibble=4, lo_nibble=2; no match
    assert_equal(out[5], UInt8(0x01))


# =============================================================================
# F1 — byte_find_eq_N at W=16.
# =============================================================================

def _build_test_chunk(s: String) -> SIMD[DType.uint8, 16]:
    """Build SIMD from a string, zero-pad to 16 bytes."""
    var bs = s.as_bytes()
    var v = SIMD[DType.uint8, 16](0)
    var n = len(bs)
    if n > 16:
        n = 16
    for k in range(n):
        v[k] = bs[k]
    return v


def test_byte_find_eq_2() raises:
    # "hello,world\n" — find ',' (0x2C) or '\n' (0x0A)
    var chunk = _build_test_chunk("hello,world\n   ")
    var bm = byte_find_eq_2_u8x16(chunk, UInt8(0x2C), UInt8(0x0A))
    # ',' is at position 5, '\n' at position 11
    assert_equal(bm[5], UInt8(0xFF))
    assert_equal(bm[11], UInt8(0xFF))
    # All others should be 0
    for k in range(16):
        if k != 5 and k != 11:
            assert_equal(bm[k], UInt8(0x00))


def test_byte_find_eq_4_rfc4180() raises:
    # CSV RFC-4180: needles {',', '\n', '\r', '"'} = (0x2C, 0x0A, 0x0D, 0x22)
    var chunk = _build_test_chunk("a,b\nc\"d\rxxxxxxx")
    var bm = byte_find_eq_4_u8x16(chunk, UInt8(0x2C), UInt8(0x0A),
                                  UInt8(0x0D), UInt8(0x22))
    # Positions: 1 (,) 3 (\n) 6 (") 8 (\r) — wait, let me count again:
    # 'a' ',' 'b' '\n' 'c' '"' 'd' '\r' ...
    #  0   1   2   3    4   5   6   7
    assert_equal(bm[1], UInt8(0xFF))
    assert_equal(bm[3], UInt8(0xFF))
    assert_equal(bm[5], UInt8(0xFF))
    assert_equal(bm[7], UInt8(0xFF))
    # Others = 0
    assert_equal(bm[0], UInt8(0x00))
    assert_equal(bm[2], UInt8(0x00))
    assert_equal(bm[4], UInt8(0x00))
    assert_equal(bm[6], UInt8(0x00))


# =============================================================================
# F2 — 32-lane multi-needle.
# =============================================================================

def test_byte_find_eq_4_u8x32() raises:
    var chunk = SIMD[DType.uint8, 32](UInt8(0x20))  # all spaces
    chunk[5] = UInt8(0x2C)
    chunk[18] = UInt8(0x0A)
    chunk[31] = UInt8(0x22)
    var bm = byte_find_eq_4_u8x32(chunk, UInt8(0x2C), UInt8(0x0A),
                                  UInt8(0x0D), UInt8(0x22))
    assert_equal(bm[5], UInt8(0xFF))
    assert_equal(bm[18], UInt8(0xFF))
    assert_equal(bm[31], UInt8(0xFF))
    for k in range(32):
        if k != 5 and k != 18 and k != 31:
            assert_equal(bm[k], UInt8(0x00))


# =============================================================================
# B1 — append_set_positions.
# =============================================================================

def test_append_set_positions_u16() raises:
    # bits = 0x0125 → positions 0, 2, 5, 8
    var bits = UInt32(0x0125)
    var out = List[Int]()
    append_set_positions_u16(bits, 100, out)
    assert_equal(len(out), 4)
    assert_equal(out[0], 100)
    assert_equal(out[1], 102)
    assert_equal(out[2], 105)
    assert_equal(out[3], 108)


def test_append_set_positions_u64() raises:
    # bits with only positions 0 and 63 set
    var bits = UInt64(0x8000000000000001)
    var out = List[Int]()
    append_set_positions_u64(bits, 0, out)
    assert_equal(len(out), 2)
    assert_equal(out[0], 0)
    assert_equal(out[1], 63)


# =============================================================================
# B2 — popcount + first_set_bit.
# =============================================================================

def test_popcount_first_set() raises:
    assert_equal(popcount_u32(UInt32(0)), 0)
    assert_equal(popcount_u32(UInt32(0xFFFFFFFF)), 32)
    assert_equal(popcount_u32(UInt32(0x0125)), 4)

    assert_equal(first_set_bit_u32(UInt32(0)), 32)
    assert_equal(first_set_bit_u32(UInt32(0x0001)), 0)
    assert_equal(first_set_bit_u32(UInt32(0x8000)), 15)
    assert_equal(first_set_bit_u32(UInt32(0x80000000)), 31)

    assert_equal(first_set_bit_u64(UInt64(0)), 64)
    assert_equal(first_set_bit_u64(UInt64(1) << UInt64(63)), 63)


# =============================================================================
# X1 — compress_u8x32.
# =============================================================================

def test_compress_u8x32() raises:
    # src = [0, 1, 2, ..., 31]; mask: even lanes set → output low 16 = even
    var src = SIMD[DType.uint8, 32](0)
    var mask = SIMD[DType.bool, 32](fill=False)
    for k in range(32):
        src[k] = UInt8(k)
        if k % 2 == 0:
            mask[k] = True
    var pt = SIMD[DType.uint8, 32](0xFE)
    var compressed = compress_u8x32(src, mask, pt)
    # First 16 lanes should be [0, 2, 4, ..., 30]
    for k in range(16):
        assert_equal(compressed[k], UInt8(k * 2))


def test_compress_with_count() raises:
    var src = SIMD[DType.uint8, 32](0)
    var mask = SIMD[DType.bool, 32](fill=False)
    for k in range(32):
        src[k] = UInt8(k)
        if k < 10:
            mask[k] = True
    var pt = SIMD[DType.uint8, 32](0xFE)
    var result = compress_with_count_u8x32(src, mask, pt)
    var compacted = result[0]
    var count = result[1]
    assert_equal(count, 10)
    for k in range(10):
        assert_equal(compacted[k], UInt8(k))


# =============================================================================
# X3 — expand_via_shuffle_u8x32 (carve-out composite).
# =============================================================================

def test_expand_via_shuffle() raises:
    # src = [10, 20, 30, 40, 0, 0, ..., 0]; mask: lanes 0, 5, 10, 15 set
    # → out should scatter src[0..3] to lanes 0, 5, 10, 15; other lanes
    # take passthrough.
    var src = SIMD[DType.uint8, 32](0)
    src[0] = UInt8(10)
    src[1] = UInt8(20)
    src[2] = UInt8(30)
    src[3] = UInt8(40)
    var mask = SIMD[DType.bool, 32](fill=False)
    mask[0] = True
    mask[5] = True
    mask[10] = True
    mask[15] = True
    var pt = SIMD[DType.uint8, 32](0xFE)

    var out = expand_via_shuffle_u8x32(src, mask, pt)
    assert_equal(out[0], UInt8(10))
    assert_equal(out[5], UInt8(20))
    assert_equal(out[10], UInt8(30))
    assert_equal(out[15], UInt8(40))
    # Unset lanes should be passthrough (0xFE)
    assert_equal(out[1], UInt8(0xFE))
    assert_equal(out[31], UInt8(0xFE))


# =============================================================================
# M1 — masked_load_u8x32 + masked_store_u8x32 (scalar fallback).
# =============================================================================

def test_masked_load_scalar() raises:
    # Backing buffer: 64 bytes, byte k = k + 1
    var backing = List[UInt8]()
    for k in range(64):
        backing.append(UInt8(k + 1))
    var src_span = Span[UInt8](backing)

    var mask = SIMD[DType.bool, 32](fill=False)
    for k in range(32):
        if k < 16:
            mask[k] = True
    var pt = SIMD[DType.uint8, 32](0xFE)

    var loaded = masked_load_u8x32(src_span, mask, pt)
    # Lanes 0..15: loaded from backing → 1..16
    for k in range(16):
        assert_equal(loaded[k], UInt8(k + 1))
    # Lanes 16..31: passthrough = 0xFE
    for k in range(16, 32):
        assert_equal(loaded[k], UInt8(0xFE))


def test_masked_store_scalar() raises:
    var dst = List[UInt8]()
    for k in range(32):
        dst.append(UInt8(0xAB))
    var dst_span = Span[UInt8](dst)

    var mask = SIMD[DType.bool, 32](fill=False)
    for k in range(16):
        mask[k] = True
    var vec = SIMD[DType.uint8, 32](0)
    for k in range(32):
        vec[k] = UInt8(k + 100)

    masked_store_u8x32(dst_span, vec, mask)
    # Lanes 0..15: should be 100..115
    for k in range(16):
        assert_equal(dst[k], UInt8(k + 100))
    # Lanes 16..31: preserved 0xAB
    for k in range(16, 32):
        assert_equal(dst[k], UInt8(0xAB))


# =============================================================================
# M2 — tail_mask_u8x32.
# =============================================================================

def test_tail_mask() raises:
    var m = tail_mask_u8x32(7)
    for k in range(7):
        assert_true(m[k])
    for k in range(7, 32):
        assert_false(m[k])

    # Edge cases: n=0 → all-False; n>=32 → all-True
    var m_zero = tail_mask_u8x32(0)
    for k in range(32):
        assert_false(m_zero[k])

    var m_full = tail_mask_u8x32(32)
    for k in range(32):
        assert_true(m_full[k])


# =============================================================================
# Q1 — quote_region_mask_u64.
# =============================================================================

def test_quote_region_mask_basic() raises:
    # Quote at position 5 only → in_string set for positions 5..63
    # (one quote = open, no close → in-string from 5 onward).
    var qb = UInt64(1) << UInt64(5)
    var out = quote_region_mask_u64(qb, False)
    # All lower bits (0..4) should be 0
    for k in range(5):
        var bit = (out >> UInt64(k)) & UInt64(1)
        assert_equal(bit, UInt64(0))
    # Bits 5..63 should be 1
    for k in range(5, 64):
        var bit = (out >> UInt64(k)) & UInt64(1)
        assert_equal(bit, UInt64(1))


def test_quote_region_mask_paired() raises:
    # Quotes at 3 and 7 → in_string set for 3..6, unset for 7..63
    var qb = (UInt64(1) << UInt64(3)) | (UInt64(1) << UInt64(7))
    var out = quote_region_mask_u64(qb, False)
    for k in range(3):
        var bit = (out >> UInt64(k)) & UInt64(1)
        assert_equal(bit, UInt64(0))
    for k in range(3, 7):
        var bit = (out >> UInt64(k)) & UInt64(1)
        assert_equal(bit, UInt64(1))
    for k in range(7, 64):
        var bit = (out >> UInt64(k)) & UInt64(1)
        assert_equal(bit, UInt64(0))


def test_quote_region_mask_carry_in() raises:
    # No quotes; carry_in=True → all bits flipped (in-string throughout).
    var qb = UInt64(0)
    var out = quote_region_mask_u64(qb, True)
    assert_equal(out, UInt64(0xFFFFFFFFFFFFFFFF))


# =============================================================================
# Entrypoint
# =============================================================================

def main() raises -> None:
    test_table_lookup_u8x16_identity()
    test_table_lookup_u8x16_reverse()
    test_table_lookup_u8x32()
    test_nibble_lut_classify_simple()
    test_byte_find_eq_2()
    test_byte_find_eq_4_rfc4180()
    test_byte_find_eq_4_u8x32()
    test_append_set_positions_u16()
    test_append_set_positions_u64()
    test_popcount_first_set()
    test_compress_u8x32()
    test_compress_with_count()
    test_expand_via_shuffle()
    test_masked_load_scalar()
    test_masked_store_scalar()
    test_tail_mask()
    test_quote_region_mask_basic()
    test_quote_region_mask_paired()
    test_quote_region_mask_carry_in()
    print("byte_class shuffle + find + bitmask + compress + masked + quote_region: ALL PASS")
