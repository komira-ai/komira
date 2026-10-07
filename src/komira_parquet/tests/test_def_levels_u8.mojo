# =============================================================================
# Tests for decode_def_levels_u8 — the per-page u8 helper
# =============================================================================
#
# Validates the flat u8 row-order validity vector emitted per page for
# nullable rank-mapping.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.memory import unsafe_memset

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.rle import decode_def_levels_u8


# =============================================================================
# RLE encoders
# =============================================================================


def _encode_all_value_rle(num_values: Int, value: Int) -> OwnedAlignedBuffer:
    """Build an RLE def-level stream where every value is `value` (0 or 1).

    Format: 4-byte LE length prefix + RLE run header (varint) + value byte.
    """
    var header_val = num_values << 1  # low bit=0 -> RLE run
    var header_bytes = List[UInt8]()
    var v = header_val
    while v >= 0x80:
        header_bytes.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    header_bytes.append(UInt8(v))

    var encoded_len = len(header_bytes) + 1
    var total = 4 + encoded_len

    var buf = OwnedAlignedBuffer(total)
    var ptr = buf.view_typed_mut[DType.uint8]()

    ptr[] = UInt8(encoded_len & 0xFF)
    (ptr + 1)[] = UInt8((encoded_len >> 8) & 0xFF)
    (ptr + 2)[] = UInt8((encoded_len >> 16) & 0xFF)
    (ptr + 3)[] = UInt8((encoded_len >> 24) & 0xFF)

    for i in range(len(header_bytes)):
        (ptr + 4 + i)[] = header_bytes[i]
    (ptr + 4 + len(header_bytes))[] = UInt8(value)

    buf.set_length(Int64(total))

    return buf^


def _encode_mixed_rle(num_values: Int) -> OwnedAlignedBuffer:
    """Two RLE runs: first half all 1, second half all 0."""
    var half = num_values >> 1
    var rest = num_values - half

    var parts = List[UInt8]()

    var h1 = half << 1
    while h1 >= 0x80:
        parts.append(UInt8((h1 & 0x7F) | 0x80))
        h1 >>= 7
    parts.append(UInt8(h1))
    parts.append(UInt8(1))

    var h2 = rest << 1
    while h2 >= 0x80:
        parts.append(UInt8((h2 & 0x7F) | 0x80))
        h2 >>= 7
    parts.append(UInt8(h2))
    parts.append(UInt8(0))

    var encoded_len = len(parts)
    var total = 4 + encoded_len

    var buf = OwnedAlignedBuffer(total)
    var ptr = buf.view_typed_mut[DType.uint8]()
    ptr[] = UInt8(encoded_len & 0xFF)
    (ptr + 1)[] = UInt8((encoded_len >> 8) & 0xFF)
    (ptr + 2)[] = UInt8((encoded_len >> 16) & 0xFF)
    (ptr + 3)[] = UInt8((encoded_len >> 24) & 0xFF)
    for i in range(len(parts)):
        (ptr + 4 + i)[] = parts[i]
    buf.set_length(Int64(total))

    return buf^


# =============================================================================
# Tests
# =============================================================================


def test_all_non_null() raises:
    """All-value=1 RLE stream -> all 1s."""
    var buf = _encode_all_value_rle(1000, 1)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), 1000)
    # SAFETY: keep buf alive across the call.
    _ = buf^
    assert_equal(len(out), 1000, "length mismatch")
    for i in range(1000):
        assert_equal(Int(out[i]), 1, "expected 1 at position")


def test_all_null() raises:
    """All-value=0 RLE stream -> all 0s."""
    var buf = _encode_all_value_rle(1000, 0)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), 1000)
    _ = buf^
    assert_equal(len(out), 1000, "length mismatch")
    for i in range(1000):
        assert_equal(Int(out[i]), 0, "expected 0 at position")


def test_mixed_matches_scalar_reference() raises:
    """Mixed RLE (first half 1, second half 0) matches scalar reference."""
    var n = 1000
    var buf = _encode_mixed_rle(n)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), n)
    _ = buf^
    assert_equal(len(out), n, "length mismatch")
    var half = n >> 1
    for i in range(half):
        assert_equal(Int(out[i]), 1, "expected 1 in first half")
    for i in range(half, n):
        assert_equal(Int(out[i]), 0, "expected 0 in second half")


def test_zero_values() raises:
    """num_values=0 returns empty list."""
    var buf = OwnedAlignedBuffer(4)
    unsafe_memset(buf.view_typed_mut[DType.uint8](), 0, 4)
    buf.set_length(4)

    var out = decode_def_levels_u8(buf.view_ro().into_span(), 0)
    _ = buf^
    assert_equal(len(out), 0, "expected empty list for num_values=0")


def test_one_value_non_null() raises:
    """Single value=1 RLE stream."""
    var buf = _encode_all_value_rle(1, 1)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), 1)
    _ = buf^
    assert_equal(len(out), 1, "expected length 1")
    assert_equal(Int(out[0]), 1, "expected 1")


def test_one_value_null() raises:
    """Single value=0 RLE stream."""
    var buf = _encode_all_value_rle(1, 0)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), 1)
    _ = buf^
    assert_equal(len(out), 1, "expected length 1")
    assert_equal(Int(out[0]), 0, "expected 0")


def test_non_power_of_two_count() raises:
    """num_values=777 (non-power-of-2) mixed stream decodes correctly."""
    var n = 777
    var buf = _encode_mixed_rle(n)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), n)
    _ = buf^
    assert_equal(len(out), n, "length mismatch")
    var half = n >> 1
    for i in range(half):
        assert_equal(Int(out[i]), 1, "expected 1 in first half")
    for i in range(half, n):
        assert_equal(Int(out[i]), 0, "expected 0 in second half")


def test_non_power_of_two_all_non_null() raises:
    """num_values=333 all non-null."""
    var n = 333
    var buf = _encode_all_value_rle(n, 1)
    var out = decode_def_levels_u8(buf.view_ro().into_span(), n)
    _ = buf^
    assert_equal(len(out), n, "length mismatch")
    for i in range(n):
        assert_equal(Int(out[i]), 1, "expected 1")


def main() raises:
    print("=== test_def_levels_u8 ===")

    test_all_non_null()
    print("  PASS: test_all_non_null")

    test_all_null()
    print("  PASS: test_all_null")

    test_mixed_matches_scalar_reference()
    print("  PASS: test_mixed_matches_scalar_reference")

    test_zero_values()
    print("  PASS: test_zero_values")

    test_one_value_non_null()
    print("  PASS: test_one_value_non_null")

    test_one_value_null()
    print("  PASS: test_one_value_null")

    test_non_power_of_two_count()
    print("  PASS: test_non_power_of_two_count")

    test_non_power_of_two_all_non_null()
    print("  PASS: test_non_power_of_two_all_non_null")

    print("=== ALL 8 TESTS PASSED ===")
