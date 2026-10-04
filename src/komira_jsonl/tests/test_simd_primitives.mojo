# =============================================================================
# Tests for komira_jsonl/simd_primitives.mojo — JSON Stage 1 SIMD helpers.
# =============================================================================
#
# Coverage:
#   T1  tag_for_byte — every char-class byte returns the correct tag.
#   T2  movemask_to_uint_u8x16 — all-zero / all-FF / alternating / sparse.
#   T3  movemask_to_uint_u8x16 — high-half-only / low-half-only patterns.
#   T4  prefix_xor_u16 — empty input / single bit / multiple bits / carry-in.
#   T5  prefix_xor_u16 — carry threading across two calls.
#   T6  scan_escapes_u16 — no backslash / single backslash / paired backslash.
#   T7  scan_escapes_u16 — chains of odd / even length / carry-out / carry-in.
#   T8  scan_chunk — plain ASCII { } [ ] : , with no strings.
#   T9  scan_chunk — string in middle of chunk (transitions True→False).
#   T10 scan_chunk — escaped quote inside string (\" not counted as close).
#   T11 scan_chunk — string spanning chunk boundary (carry).
#   T12 emit_offsets — empty bits / single structural / mixed quote+structural.
#   T13 emit_offsets — ordered emission (bits walked low→high).
#
# Test harness: std.testing.TestSuite.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_jsonl.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_COLON,
    TAG_COMMA,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
    TAG_INVALID,
    tag_for_byte,
    movemask_to_uint_u8x16,
    prefix_xor_u16,
    scan_escapes_u16,
    scan_chunk,
    emit_offsets,
)


# =============================================================================
# Helpers
# =============================================================================


def _chunk_from_str(s: String) -> SIMD[DType.uint8, 16]:
    """Build a SIMD[uint8, 16] from a String, zero-padding to 16 bytes.

    Test fixtures only — never on the hot path.
    """
    var bs = s.as_bytes()
    var result = SIMD[DType.uint8, 16](0)
    var n = len(bs)
    if n > 16:
        n = 16
    # Hand-init each lane.
    if n >= 1:
        result[0] = bs[0]
    if n >= 2:
        result[1] = bs[1]
    if n >= 3:
        result[2] = bs[2]
    if n >= 4:
        result[3] = bs[3]
    if n >= 5:
        result[4] = bs[4]
    if n >= 6:
        result[5] = bs[5]
    if n >= 7:
        result[6] = bs[6]
    if n >= 8:
        result[7] = bs[7]
    if n >= 9:
        result[8] = bs[8]
    if n >= 10:
        result[9] = bs[9]
    if n >= 11:
        result[10] = bs[10]
    if n >= 12:
        result[11] = bs[11]
    if n >= 13:
        result[12] = bs[12]
    if n >= 14:
        result[13] = bs[13]
    if n >= 15:
        result[14] = bs[14]
    if n >= 16:
        result[15] = bs[15]
    return result


def _bytemask_from_bits(bits: UInt32) -> SIMD[DType.uint8, 16]:
    """Build a 0xFF/0x00 byte-mask SIMD[uint8, 16] from a 16-bit pattern.

    Bit k → lane k = 0xFF iff bit k of `bits` is 1.
    """
    var result = SIMD[DType.uint8, 16](0)
    if (bits >> UInt32(0)) & UInt32(1) != 0:
        result[0] = 0xFF
    if (bits >> UInt32(1)) & UInt32(1) != 0:
        result[1] = 0xFF
    if (bits >> UInt32(2)) & UInt32(1) != 0:
        result[2] = 0xFF
    if (bits >> UInt32(3)) & UInt32(1) != 0:
        result[3] = 0xFF
    if (bits >> UInt32(4)) & UInt32(1) != 0:
        result[4] = 0xFF
    if (bits >> UInt32(5)) & UInt32(1) != 0:
        result[5] = 0xFF
    if (bits >> UInt32(6)) & UInt32(1) != 0:
        result[6] = 0xFF
    if (bits >> UInt32(7)) & UInt32(1) != 0:
        result[7] = 0xFF
    if (bits >> UInt32(8)) & UInt32(1) != 0:
        result[8] = 0xFF
    if (bits >> UInt32(9)) & UInt32(1) != 0:
        result[9] = 0xFF
    if (bits >> UInt32(10)) & UInt32(1) != 0:
        result[10] = 0xFF
    if (bits >> UInt32(11)) & UInt32(1) != 0:
        result[11] = 0xFF
    if (bits >> UInt32(12)) & UInt32(1) != 0:
        result[12] = 0xFF
    if (bits >> UInt32(13)) & UInt32(1) != 0:
        result[13] = 0xFF
    if (bits >> UInt32(14)) & UInt32(1) != 0:
        result[14] = 0xFF
    if (bits >> UInt32(15)) & UInt32(1) != 0:
        result[15] = 0xFF
    return result


# =============================================================================
# T1 — tag_for_byte
# =============================================================================


def test_tag_for_byte_brace() raises:
    assert_equal(tag_for_byte(UInt8(0x7B)), TAG_OPEN_BRACE)
    assert_equal(tag_for_byte(UInt8(0x7D)), TAG_CLOSE_BRACE)


def test_tag_for_byte_bracket() raises:
    assert_equal(tag_for_byte(UInt8(0x5B)), TAG_OPEN_BRACKET)
    assert_equal(tag_for_byte(UInt8(0x5D)), TAG_CLOSE_BRACKET)


def test_tag_for_byte_colon_comma() raises:
    assert_equal(tag_for_byte(UInt8(0x3A)), TAG_COLON)
    assert_equal(tag_for_byte(UInt8(0x2C)), TAG_COMMA)


def test_tag_for_byte_quote_returns_open() raises:
    # tag_for_byte returns TAG_QUOTE_OPEN by convention; emit_offsets
    # overrides via in_string_bits.
    assert_equal(tag_for_byte(UInt8(0x22)), TAG_QUOTE_OPEN)


def test_tag_for_byte_non_structural() raises:
    assert_equal(tag_for_byte(UInt8(0x41)), TAG_INVALID)  # 'A'
    assert_equal(tag_for_byte(UInt8(0x30)), TAG_INVALID)  # '0'
    assert_equal(tag_for_byte(UInt8(0x20)), TAG_INVALID)  # space


# =============================================================================
# T2/T3 — movemask_to_uint_u8x16
# =============================================================================


def test_movemask_all_zero() raises:
    var mask = SIMD[DType.uint8, 16](0)
    assert_equal(Int(movemask_to_uint_u8x16(mask)), 0)


def test_movemask_all_ones() raises:
    var mask = SIMD[DType.uint8, 16](0xFF)
    assert_equal(Int(movemask_to_uint_u8x16(mask)), 0xFFFF)


def test_movemask_single_lane() raises:
    # Lane 0 only.
    var m0 = _bytemask_from_bits(UInt32(0x0001))
    assert_equal(Int(movemask_to_uint_u8x16(m0)), 0x0001)
    # Lane 15 only.
    var m15 = _bytemask_from_bits(UInt32(0x8000))
    assert_equal(Int(movemask_to_uint_u8x16(m15)), 0x8000)
    # Lane 8 only (high-half bit 0).
    var m8 = _bytemask_from_bits(UInt32(0x0100))
    assert_equal(Int(movemask_to_uint_u8x16(m8)), 0x0100)


def test_movemask_alternating() raises:
    # 0xAAAA = 1010101010101010
    var m = _bytemask_from_bits(UInt32(0xAAAA))
    assert_equal(Int(movemask_to_uint_u8x16(m)), 0xAAAA)


def test_movemask_high_half_only() raises:
    var m = _bytemask_from_bits(UInt32(0xFF00))
    assert_equal(Int(movemask_to_uint_u8x16(m)), 0xFF00)


def test_movemask_low_half_only() raises:
    var m = _bytemask_from_bits(UInt32(0x00FF))
    assert_equal(Int(movemask_to_uint_u8x16(m)), 0x00FF)


# =============================================================================
# T4/T5 — prefix_xor_u16
# =============================================================================


def test_prefix_xor_empty() raises:
    var carry: Bool = False
    var r = prefix_xor_u16(UInt32(0x0000), carry)
    assert_equal(Int(r), 0x0000)
    assert_false(carry)


def test_prefix_xor_single_bit() raises:
    # Bit 3 set → after position 3, every subsequent bit flips to 1.
    # Cumulative XOR: positions 0..2 = 0; positions 3..15 = 1.
    # Result = 0xFFF8.
    var carry: Bool = False
    var r = prefix_xor_u16(UInt32(0x0008), carry)
    assert_equal(Int(r), 0xFFF8)
    # carry_out = bit 15 of result = 1.
    assert_true(carry)


def test_prefix_xor_two_bits_paired() raises:
    # Bits 3 and 7 set: positions 3..6 = 1, 7..15 = 0.
    # Result: 0b 0000_0000_0111_1000 = 0x0078.
    var carry: Bool = False
    var r = prefix_xor_u16(UInt32(0x0088), carry)
    assert_equal(Int(r), 0x0078)
    assert_false(carry)


def test_prefix_xor_with_carry_in() raises:
    # Bit 3 set, carry_in=True. Bits 0..2 = 1, 3..15 = 0.
    # Result = 0x0007.
    var carry: Bool = True
    var r = prefix_xor_u16(UInt32(0x0008), carry)
    assert_equal(Int(r), 0x0007)
    assert_false(carry)


def test_prefix_xor_carry_threading() raises:
    # Chunk 1: bit 5 set, no carry_in. Chunk 2: bit 3 set.
    # After chunk 1: positions 5..15 = 1; carry_out = True.
    # Chunk 2 with carry_in=True: positions 0..2 = 1 (since carry), 3..15 = 0.
    var carry: Bool = False
    var r1 = prefix_xor_u16(UInt32(0x0020), carry)
    assert_equal(Int(r1), 0xFFE0)
    assert_true(carry)
    var r2 = prefix_xor_u16(UInt32(0x0008), carry)
    assert_equal(Int(r2), 0x0007)
    assert_false(carry)


# =============================================================================
# T6/T7 — scan_escapes_u16
# =============================================================================


def test_scan_escapes_empty() raises:
    var carry: Bool = False
    var r = scan_escapes_u16(UInt32(0x0000), carry)
    assert_equal(Int(r), 0x0000)
    assert_false(carry)


def test_scan_escapes_single_backslash() raises:
    # Bit 3 set (single backslash). Odd-length run (1). Escape at bit 4.
    var carry: Bool = False
    var r = scan_escapes_u16(UInt32(0x0008), carry)
    assert_equal(Int(r), 0x0010)
    assert_false(carry)


def test_scan_escapes_paired_backslash() raises:
    # Bits 3,4 (run length 2, even). No escape emitted.
    var carry: Bool = False
    var r = scan_escapes_u16(UInt32(0x0018), carry)
    assert_equal(Int(r), 0x0000)
    assert_false(carry)


def test_scan_escapes_triple_backslash() raises:
    # Bits 3,4,5 (run length 3, odd). Escape at bit 6.
    var carry: Bool = False
    var r = scan_escapes_u16(UInt32(0x0038), carry)
    assert_equal(Int(r), 0x0040)
    assert_false(carry)


def test_scan_escapes_carry_in() raises:
    # No backslashes in this chunk, but carry_in says "bit 0 is escaped".
    var carry: Bool = True
    var r = scan_escapes_u16(UInt32(0x0000), carry)
    assert_equal(Int(r), 0x0001)


def test_scan_escapes_carry_out() raises:
    # Backslash at bit 15 (final position). Odd run of 1 → escape would
    # be at bit 16, i.e. carry out.
    var carry: Bool = False
    var r = scan_escapes_u16(UInt32(0x8000), carry)
    assert_equal(Int(r), 0x0000)
    assert_true(carry)


# =============================================================================
# T8/T9/T10/T11 — scan_chunk
# =============================================================================


def test_scan_chunk_plain_braces() raises:
    # "{}[]:,xxxxxxxxxx" — first 6 are structurals, no strings.
    var chunk = _chunk_from_str("{}[]:,xxxxxxxxxx")
    var prev_in_string: Bool = False
    var prev_escape: Bool = False
    var result = scan_chunk(chunk, prev_in_string, prev_escape)
    var structural_bits = result[0]
    var in_string_bits = result[1]
    var quote_bits = result[2]
    # Bits 0-5 should be structural.
    assert_equal(Int(structural_bits & UInt32(0x003F)), 0x003F)
    assert_equal(Int(in_string_bits), 0)
    assert_equal(Int(quote_bits), 0)
    assert_false(prev_in_string)
    assert_false(prev_escape)


def test_scan_chunk_string_in_middle() raises:
    # `{"a": "x"}` — 10 bytes + padding.
    # Bytes: { " a " :   " x " }  _  _  _  _  _  _
    # idx:   0 1 2 3 4 5 6 7 8 9
    # Quotes at 1, 3, 6, 8. structurals: { at 0, : at 4, } at 9.
    var chunk = _chunk_from_str('{"a": "x"}      ')
    var prev_in_string: Bool = False
    var prev_escape: Bool = False
    var result = scan_chunk(chunk, prev_in_string, prev_escape)
    var structural_bits = result[0]
    var in_string_bits = result[1]
    var quote_bits = result[2]
    # Quotes at 1, 3, 6, 8 — bits 0x142 = 0x142.
    # Computed: (1<<1) | (1<<3) | (1<<6) | (1<<8) = 2 | 8 | 64 | 256 = 330 = 0x14A.
    assert_equal(Int(quote_bits), 0x14A)
    # Structurals (non-quote, non-string): { at 0, : at 4, } at 9.
    # 1 | 16 | 512 = 529 = 0x211.
    assert_equal(Int(structural_bits & UInt32(0x03FF)), 0x211)
    # End state: not in string (we exited the last close quote).
    assert_false(prev_in_string)
    assert_false(prev_escape)


def test_scan_chunk_escaped_quote() raises:
    # `"a\"b"` — escaped quote inside a string.
    # bytes: " a \ " b "  pad pad...
    # idx:   0 1 2 3 4 5
    # Quote at 0 opens string. Backslash at 2 escapes the quote at 3.
    # Quote at 5 closes string. Quotes at 0, 5 are the boundaries.
    var chunk = _chunk_from_str('"a\\"b"          ')
    var prev_in_string: Bool = False
    var prev_escape: Bool = False
    var result = scan_chunk(chunk, prev_in_string, prev_escape)
    var quote_bits = result[2]
    # Unescaped quotes only — should be bits 0 and 5.
    assert_equal(Int(quote_bits), 0x21)
    assert_false(prev_in_string)
    assert_false(prev_escape)


def test_scan_chunk_string_carry_across_boundary() raises:
    # Chunk 1: `xxxxxxxxxxxxxxx"` — opens string at byte 15.
    # Chunk 2: all-x — should stay in_string the whole way.
    var c1 = _chunk_from_str('xxxxxxxxxxxxxxx"')
    var prev_in_string: Bool = False
    var prev_escape: Bool = False
    var r1 = scan_chunk(c1, prev_in_string, prev_escape)
    var qb1 = r1[2]
    assert_equal(Int(qb1), 0x8000)
    # Now in_string for chunk 2's start.
    assert_true(prev_in_string)
    var c2 = _chunk_from_str("xxxxxxxxxxxxxxxx")
    var r2 = scan_chunk(c2, prev_in_string, prev_escape)
    var insb2 = r2[1]
    # Every byte in chunk 2 should be in_string.
    assert_equal(Int(insb2), 0xFFFF)
    var sb2 = r2[0]
    # No structurals in chunk 2.
    assert_equal(Int(sb2), 0)
    # Still in string at end of chunk 2.
    assert_true(prev_in_string)


# =============================================================================
# T12/T13 — emit_offsets
# =============================================================================


def test_emit_offsets_empty() raises:
    var offsets = List[UInt32]()
    var tags = List[UInt8]()
    var chunk = SIMD[DType.uint8, 16](0)
    emit_offsets(
        UInt32(0), UInt32(0), UInt32(0), UInt32(0), chunk, offsets, tags
    )
    assert_equal(len(offsets), 0)
    assert_equal(len(tags), 0)


def test_emit_offsets_single_structural() raises:
    # Chunk has '{' at byte 0.
    var chunk = _chunk_from_str("{               ")
    var offsets = List[UInt32]()
    var tags = List[UInt8]()
    emit_offsets(
        UInt32(0x0001),  # structural_bits: bit 0
        UInt32(0),        # quote_bits: none
        UInt32(0),        # in_string_bits: none
        UInt32(100),      # chunk_start: 100
        chunk,
        offsets,
        tags,
    )
    assert_equal(len(offsets), 1)
    assert_equal(Int(offsets[0]), 100)
    assert_equal(Int(tags[0]), Int(TAG_OPEN_BRACE))


def test_emit_offsets_mixed_quote_and_structural() raises:
    # `{"a":1}` — { at 0, " at 1 (open), " at 3 (close), : at 4, } at 6.
    # Structural bits: 0x51 (bits 0, 4, 6).
    # Quote bits: 0xA (bits 1, 3).
    # in_string_bits: bits 1..2 = 1 (XOR of bit 1 and bit 3). 0x06.
    var chunk = _chunk_from_str('{"a":1}         ')
    var offsets = List[UInt32]()
    var tags = List[UInt8]()
    emit_offsets(
        UInt32(0x51),
        UInt32(0x0A),
        UInt32(0x06),
        UInt32(50),
        chunk,
        offsets,
        tags,
    )
    # Sorted emission: 0, 1, 3, 4, 6.
    assert_equal(len(offsets), 5)
    assert_equal(Int(offsets[0]), 50)
    assert_equal(Int(tags[0]), Int(TAG_OPEN_BRACE))
    assert_equal(Int(offsets[1]), 51)
    assert_equal(Int(tags[1]), Int(TAG_QUOTE_OPEN))
    assert_equal(Int(offsets[2]), 53)
    assert_equal(Int(tags[2]), Int(TAG_QUOTE_CLOSE))
    assert_equal(Int(offsets[3]), 54)
    assert_equal(Int(tags[3]), Int(TAG_COLON))
    assert_equal(Int(offsets[4]), 56)
    assert_equal(Int(tags[4]), Int(TAG_CLOSE_BRACE))


def test_emit_offsets_ordered_walk() raises:
    # Verify bits walked low → high regardless of input bit order.
    var chunk = _chunk_from_str("                ")
    chunk[2] = UInt8(0x7B)   # {
    chunk[7] = UInt8(0x7D)   # }
    chunk[10] = UInt8(0x2C)  # ,
    var offsets = List[UInt32]()
    var tags = List[UInt8]()
    emit_offsets(
        UInt32(0x484),  # bits 2, 7, 10
        UInt32(0),
        UInt32(0),
        UInt32(0),
        chunk,
        offsets,
        tags,
    )
    assert_equal(len(offsets), 3)
    assert_equal(Int(offsets[0]), 2)
    assert_equal(Int(offsets[1]), 7)
    assert_equal(Int(offsets[2]), 10)


# =============================================================================
# Test registration
# =============================================================================


def main() raises:
    test_tag_for_byte_brace()
    test_tag_for_byte_bracket()
    test_tag_for_byte_colon_comma()
    test_tag_for_byte_quote_returns_open()
    test_tag_for_byte_non_structural()
    test_movemask_all_zero()
    test_movemask_all_ones()
    test_movemask_single_lane()
    test_movemask_alternating()
    test_movemask_high_half_only()
    test_movemask_low_half_only()
    test_prefix_xor_empty()
    test_prefix_xor_single_bit()
    test_prefix_xor_two_bits_paired()
    test_prefix_xor_with_carry_in()
    test_prefix_xor_carry_threading()
    test_scan_escapes_empty()
    test_scan_escapes_single_backslash()
    test_scan_escapes_paired_backslash()
    test_scan_escapes_triple_backslash()
    test_scan_escapes_carry_in()
    test_scan_escapes_carry_out()
    test_scan_chunk_plain_braces()
    test_scan_chunk_string_in_middle()
    test_scan_chunk_escaped_quote()
    test_scan_chunk_string_carry_across_boundary()
    test_emit_offsets_empty()
    test_emit_offsets_single_structural()
    test_emit_offsets_mixed_quote_and_structural()
    test_emit_offsets_ordered_walk()
    print("simd_primitives: ALL TESTS PASS (29/29)")
