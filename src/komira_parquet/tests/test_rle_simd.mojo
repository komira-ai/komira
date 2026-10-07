# =============================================================================
# Tests for SIMD-vectorized _unpack_generic.
#
# Strategy:
#   1. For every comptime-specialized bit_width in
#      {3, 5, 6, 7, 9..16, 20, 24, 32}, encode a known sequence via the
#      `_encode_bitpacked_group` helper below,
#      decode via RleDecoder.decode_int32 (which dispatches into the SIMD
#      path), and verify byte-equal against the expected sequence.
#   2. Edge cases:
#        - max_values not a multiple of W (trailing partial SIMD lane).
#        - max_values < W (skip SIMD, scalar tail only).
#        - max_values == 0 (zero-length).
#        - bit_width = 1, 2, 4, 8 (still served by dedicated u8-byte
#          helpers; not the SIMD path, but include for invariance).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import alloc, unsafe_memset

from komira_parquet import RleDecoder


# =============================================================================
# Helpers
# =============================================================================


def _encode_bitpacked_group(values: List[Int], bit_width: Int) -> List[UInt8]:
    """Encode values as a single bit-packed group (Parquet RLE/bit-pack).

    Groups are always 8 values. Pads with zeros if fewer than 8 are
    provided. Header: (num_groups << 1) | 1.
    """
    var result: List[UInt8] = []
    var num_groups = (len(values) + 7) // 8

    var header = (num_groups << 1) | 1
    while header >= 0x80:
        result.append(UInt8((header & 0x7F) | 0x80))
        header = header >> 7
    result.append(UInt8(header))

    var total_bits = num_groups * 8 * bit_width
    var total_bytes = (total_bits + 7) // 8
    var packed = alloc[UInt8](max(total_bytes, 1))
    unsafe_memset(packed, 0, max(total_bytes, 1))

    var bit_pos = 0
    for i in range(num_groups * 8):
        var val = 0
        if i < len(values):
            val = values[i]

        var byte_idx = bit_pos >> 3
        var bit_offset = bit_pos & 7
        var remaining = bit_width
        var v = val
        var bi = byte_idx
        var bo = bit_offset
        while remaining > 0 and bi < total_bytes:
            var space = 8 - bo
            var write_bits = min(remaining, space)
            var mask = (1 << write_bits) - 1
            (packed + bi)[] = (packed + bi)[] | UInt8((v & mask) << bo)
            v = v >> write_bits
            remaining -= write_bits
            bo = 0
            bi += 1

        bit_pos += bit_width

    for i in range(total_bytes):
        result.append((packed + i)[])
    packed.free()

    return result^


def _make_test_values(count: Int, bit_width: Int) -> List[Int]:
    """Build a test sequence of `count` values, each fitting in
    `bit_width` bits.

    Pattern: deterministic LCG-like recurrence so values exercise lots
    of bit positions; modulo 2^bit_width to stay in range.
    """
    var values: List[Int] = []
    var v = 1
    var max_val = (1 << bit_width) - 1
    if bit_width >= 32:
        max_val = (1 << 31) - 1  # avoid Int overflow for our recurrence
    for i in range(count):
        # LCG: x = (a*x + c) mod m. Pick deterministic but spread.
        v = (v * 1103515245 + 12345) & 0x7FFFFFFF
        values.append(v % (max_val + 1))
    return values^


def _decode_and_check(values: List[Int], bit_width: Int) raises:
    """Encode `values` at `bit_width`, decode via RleDecoder, assert
    byte-equal."""
    var encoded = _encode_bitpacked_group(values, bit_width)

    var decoded = List[Int32](capacity=len(values) + 8)  # +8 slack
    decoded.resize(len(values) + 8, Int32(0))

    var decoder = RleDecoder(Span(encoded), bit_width)
    var n = decoder.decode_int32(len(values), Span(decoded))

    assert_equal(n, len(values), "decoded count mismatch")
    for i in range(len(values)):
        var got = Int(decoded[i])
        assert_equal(got, values[i],
            "value mismatch at i, bw=" + String(bit_width))


# =============================================================================
# Per-bit-width tests
# =============================================================================


def test_simd_bw1_basic() raises:
    var values = _make_test_values(64, 1)
    _decode_and_check(values, 1)


def test_simd_bw2_basic() raises:
    var values = _make_test_values(64, 2)
    _decode_and_check(values, 2)


def test_simd_bw3_basic() raises:
    var values = _make_test_values(64, 3)
    _decode_and_check(values, 3)


def test_simd_bw4_basic() raises:
    var values = _make_test_values(64, 4)
    _decode_and_check(values, 4)


def test_simd_bw5_basic() raises:
    var values = _make_test_values(64, 5)
    _decode_and_check(values, 5)


def test_simd_bw6_basic() raises:
    var values = _make_test_values(64, 6)
    _decode_and_check(values, 6)


def test_simd_bw7_basic() raises:
    var values = _make_test_values(64, 7)
    _decode_and_check(values, 7)


def test_simd_bw8_basic() raises:
    var values = _make_test_values(64, 8)
    _decode_and_check(values, 8)


def test_simd_bw9_basic() raises:
    var values = _make_test_values(64, 9)
    _decode_and_check(values, 9)


def test_simd_bw10_basic() raises:
    var values = _make_test_values(64, 10)
    _decode_and_check(values, 10)


def test_simd_bw11_basic() raises:
    var values = _make_test_values(64, 11)
    _decode_and_check(values, 11)


def test_simd_bw12_basic() raises:
    var values = _make_test_values(64, 12)
    _decode_and_check(values, 12)


def test_simd_bw13_basic() raises:
    var values = _make_test_values(64, 13)
    _decode_and_check(values, 13)


def test_simd_bw14_basic() raises:
    var values = _make_test_values(64, 14)
    _decode_and_check(values, 14)


def test_simd_bw15_basic() raises:
    var values = _make_test_values(64, 15)
    _decode_and_check(values, 15)


def test_simd_bw16_basic() raises:
    var values = _make_test_values(64, 16)
    _decode_and_check(values, 16)


def test_simd_bw20_basic() raises:
    var values = _make_test_values(64, 20)
    _decode_and_check(values, 20)


def test_simd_bw24_basic() raises:
    var values = _make_test_values(64, 24)
    _decode_and_check(values, 24)


def test_simd_bw32_basic() raises:
    # bit_width=32 — full 32-bit values, but our LCG bound caps at 31
    # bits to avoid Int overflow in the encoder.
    var values = _make_test_values(64, 32)
    _decode_and_check(values, 32)


# =============================================================================
# Edge cases — partial SIMD-lane tail / odd counts / zero-length
# =============================================================================


def test_simd_partial_lane_bw3() raises:
    """Count not a multiple of SIMD lanes (W=8). Forces the scalar
    tail after the SIMD batch."""
    # 8 + 5 = 13 values: one SIMD batch + scalar tail of 5.
    var values = _make_test_values(13, 3)
    _decode_and_check(values, 3)


def test_simd_partial_lane_bw5() raises:
    var values = _make_test_values(11, 5)
    _decode_and_check(values, 5)


def test_simd_partial_lane_bw6() raises:
    var values = _make_test_values(9, 6)
    _decode_and_check(values, 6)


def test_simd_partial_lane_bw7() raises:
    var values = _make_test_values(7, 7)
    _decode_and_check(values, 7)


def test_simd_partial_lane_bw12() raises:
    var values = _make_test_values(7, 12)
    _decode_and_check(values, 12)


def test_simd_partial_lane_bw16() raises:
    var values = _make_test_values(5, 16)
    _decode_and_check(values, 16)


def test_simd_partial_lane_bw24() raises:
    # bit_width=24, W typically reduces to 2 for tight widths.
    var values = _make_test_values(5, 24)
    _decode_and_check(values, 24)


def test_simd_zero_length() raises:
    """Zero values requested — should write nothing."""
    var encoded = _encode_bitpacked_group(List[Int](), 7)
    var decoded = List[Int32](capacity=8)
    decoded.resize(8, Int32(0))
    var decoder = RleDecoder(Span(encoded), 7)
    var n = decoder.decode_int32(0, Span(decoded))
    assert_equal(n, 0, "expected 0 decoded")


def test_simd_small_count_bw3() raises:
    """Count smaller than one SIMD batch. Skips SIMD path entirely."""
    var values = _make_test_values(3, 3)
    _decode_and_check(values, 3)


def test_simd_small_count_bw7() raises:
    var values = _make_test_values(2, 7)
    _decode_and_check(values, 7)


# =============================================================================
# Larger sequences — exercise multiple SIMD batches + multi-group decode
# =============================================================================


def test_simd_large_bw3() raises:
    var values = _make_test_values(256, 3)
    _decode_and_check(values, 3)


def test_simd_large_bw7() raises:
    var values = _make_test_values(256, 7)
    _decode_and_check(values, 7)


def test_simd_large_bw10() raises:
    var values = _make_test_values(256, 10)
    _decode_and_check(values, 10)


def test_simd_large_bw16() raises:
    var values = _make_test_values(256, 16)
    _decode_and_check(values, 16)


def test_simd_large_bw20() raises:
    var values = _make_test_values(256, 20)
    _decode_and_check(values, 20)


def test_simd_large_bw24() raises:
    var values = _make_test_values(256, 24)
    _decode_and_check(values, 24)


# =============================================================================
# Boundary value patterns — all-max, all-zero, alternating
# =============================================================================


def _check_pattern(values: List[Int], bit_width: Int) raises:
    _decode_and_check(values, bit_width)


def test_simd_all_max_bw5() raises:
    var max_val = (1 << 5) - 1
    var values: List[Int] = []
    for _ in range(64):
        values.append(max_val)
    _check_pattern(values, 5)


def test_simd_all_zero_bw7() raises:
    var values: List[Int] = []
    for _ in range(64):
        values.append(0)
    _check_pattern(values, 7)


def test_simd_alternating_bw3() raises:
    var values: List[Int] = []
    for i in range(64):
        if i & 1 == 0:
            values.append(0)
        else:
            values.append(7)  # max for bw=3
    _check_pattern(values, 3)


def test_simd_alternating_bw11() raises:
    var values: List[Int] = []
    var hi = (1 << 11) - 1
    for i in range(64):
        if i & 1 == 0:
            values.append(0)
        else:
            values.append(hi)
    _check_pattern(values, 11)


# =============================================================================
# Test entry
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_simd_bw1_basic]()
    suite.test[test_simd_bw2_basic]()
    suite.test[test_simd_bw3_basic]()
    suite.test[test_simd_bw4_basic]()
    suite.test[test_simd_bw5_basic]()
    suite.test[test_simd_bw6_basic]()
    suite.test[test_simd_bw7_basic]()
    suite.test[test_simd_bw8_basic]()
    suite.test[test_simd_bw9_basic]()
    suite.test[test_simd_bw10_basic]()
    suite.test[test_simd_bw11_basic]()
    suite.test[test_simd_bw12_basic]()
    suite.test[test_simd_bw13_basic]()
    suite.test[test_simd_bw14_basic]()
    suite.test[test_simd_bw15_basic]()
    suite.test[test_simd_bw16_basic]()
    suite.test[test_simd_bw20_basic]()
    suite.test[test_simd_bw24_basic]()
    suite.test[test_simd_bw32_basic]()
    suite.test[test_simd_partial_lane_bw3]()
    suite.test[test_simd_partial_lane_bw5]()
    suite.test[test_simd_partial_lane_bw6]()
    suite.test[test_simd_partial_lane_bw7]()
    suite.test[test_simd_partial_lane_bw12]()
    suite.test[test_simd_partial_lane_bw16]()
    suite.test[test_simd_partial_lane_bw24]()
    suite.test[test_simd_zero_length]()
    suite.test[test_simd_small_count_bw3]()
    suite.test[test_simd_small_count_bw7]()
    suite.test[test_simd_large_bw3]()
    suite.test[test_simd_large_bw7]()
    suite.test[test_simd_large_bw10]()
    suite.test[test_simd_large_bw16]()
    suite.test[test_simd_large_bw20]()
    suite.test[test_simd_large_bw24]()
    suite.test[test_simd_all_max_bw5]()
    suite.test[test_simd_all_zero_bw7]()
    suite.test[test_simd_alternating_bw3]()
    suite.test[test_simd_alternating_bw11]()
    suite^.run()
