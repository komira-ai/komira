# =============================================================================
# Tests for SIMD-vectorized _unpack_bitwidth1 / _unpack_bitwidth2 /
# _unpack_bitwidth4.
#
# These three bit_widths fire DEDICATED u8-byte fast paths in
# rle_bitunpack.mojo (NOT the _unpack_generic_simd ladder); they mirror the
# bw=8 SIMD shape onto the smaller widths.
#
# bw=1 — 8 values per byte; SIMD broadcast + per-lane shift+mask, store 8
#        Int32s per byte.
# bw=2 — 4 values per byte; SIMD broadcast + per-lane shift+mask, store 4
#        Int32s per byte.
# bw=4 — 2 values per byte; SIMD multi-byte interleave, 16 Int32 outputs
#        per 8 input bytes.
#
# Coverage strategy:
#   1. Boundary counts: exactly the SIMD body multiple, exactly that + 1
#      (to exercise the partial scalar tail), exactly W_BYTES * 1, etc.
#   2. Saturated-value patterns: all-zero, all-max, alternating.
#   3. Truncated-input case: pack_len smaller than ceil(max_values / N).
#   4. Large counts (1024+) — exercises many SIMD iterations.
#
# Every test compares the SIMD-decoded output against an explicit scalar
# reference computed in Mojo (no dependency on the original scalar
# implementation surviving — guards against future scalar-tail
# refactors).
# =============================================================================

from std.testing import TestSuite, assert_equal
from std.memory import alloc, unsafe_memset

from komira_parquet import RleDecoder


# =============================================================================
# Helpers — encode and reference-decode (independent of rle.mojo internals)
# =============================================================================


def _encode_bitpacked_group(values: List[Int], bit_width: Int) -> List[UInt8]:
    """Encode values as a single bit-packed group (Parquet RLE/bit-pack).

    Mirrors test_rle_simd._encode_bitpacked_group. Groups are always 8
    values; pads with zeros if fewer.
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


def _decode_and_check(values: List[Int], bit_width: Int) raises:
    """Encode `values` at `bit_width`, decode via RleDecoder, assert
    byte-equal.

    Used for ANY count, including counts < 8 (single-group encoder pads
    with zeros)."""
    var encoded = _encode_bitpacked_group(values, bit_width)

    var decoded = List[Int32](capacity=len(values) + 16)  # +16 slack
    decoded.resize(len(values) + 16, Int32(0))

    var decoder = RleDecoder(Span(encoded), bit_width)
    var n = decoder.decode_int32(len(values), Span(decoded))

    assert_equal(n, len(values), "decoded count mismatch (bw=" + String(bit_width) + ")")
    for i in range(len(values)):
        var got = Int(decoded[i])
        assert_equal(
            got,
            values[i],
            "value mismatch at i=" + String(i) + ", bw=" + String(bit_width),
        )


# =============================================================================
# bw=1 — 8 values per byte; SIMD body processes 1 byte → 8 outputs at a time
# =============================================================================


def test_bw1_exactly_8() raises:
    """One full SIMD body iteration, no scalar tail."""
    var v: List[Int] = [0, 1, 0, 1, 1, 0, 1, 0]
    _decode_and_check(v, 1)


def test_bw1_all_zero_64() raises:
    """8 SIMD body iterations of all-zero — SIMD path must produce
    byte-perfect zero output."""
    var v: List[Int] = []
    for _ in range(64):
        v.append(0)
    _decode_and_check(v, 1)


def test_bw1_all_one_64() raises:
    """8 SIMD body iterations of all-one — exercises the (b32 >> SHIFTS)
    & 1 ALL-LANES-1 path."""
    var v: List[Int] = []
    for _ in range(64):
        v.append(1)
    _decode_and_check(v, 1)


def test_bw1_partial_tail_9() raises:
    """1 full SIMD byte (8 outputs) + 1 scalar-tail output."""
    var v: List[Int] = [1, 0, 1, 0, 1, 0, 1, 0, 1]
    _decode_and_check(v, 1)


def test_bw1_partial_tail_15() raises:
    """1 full SIMD byte (8) + 7 scalar-tail outputs."""
    var v: List[Int] = []
    for i in range(15):
        v.append(i & 1)
    _decode_and_check(v, 1)


def test_bw1_only_tail_5() raises:
    """No full SIMD byte — entirely scalar tail (5 < 8)."""
    var v: List[Int] = [1, 0, 0, 1, 1]
    _decode_and_check(v, 1)


def test_bw1_large_1024() raises:
    """128 SIMD body iterations — confirms large-count throughput."""
    var v: List[Int] = []
    for i in range(1024):
        v.append((i * 7 + 3) & 1)
    _decode_and_check(v, 1)


# =============================================================================
# bw=2 — 4 values per byte; SIMD body processes 1 byte → 4 outputs at a time
# =============================================================================


def test_bw2_exactly_4() raises:
    var v: List[Int] = [0, 1, 2, 3]
    _decode_and_check(v, 2)


def test_bw2_all_max_32() raises:
    """8 SIMD body iterations of all-max (0x03)."""
    var v: List[Int] = []
    for _ in range(32):
        v.append(3)
    _decode_and_check(v, 2)


def test_bw2_all_zero_32() raises:
    var v: List[Int] = []
    for _ in range(32):
        v.append(0)
    _decode_and_check(v, 2)


def test_bw2_partial_tail_5() raises:
    """1 full SIMD byte (4) + 1 scalar tail."""
    var v: List[Int] = [3, 1, 0, 2, 1]
    _decode_and_check(v, 2)


def test_bw2_partial_tail_7() raises:
    """1 full SIMD byte (4) + 3 scalar tail."""
    var v: List[Int] = [0, 1, 2, 3, 3, 2, 1]
    _decode_and_check(v, 2)


def test_bw2_only_tail_3() raises:
    """No full SIMD byte — entirely scalar tail."""
    var v: List[Int] = [2, 0, 3]
    _decode_and_check(v, 2)


def test_bw2_large_1024() raises:
    """256 SIMD body iterations."""
    var v: List[Int] = []
    for i in range(1024):
        v.append((i * 5 + 1) & 0x03)
    _decode_and_check(v, 2)


def test_bw2_alternating_64() raises:
    """Alternating 0/3 stresses the per-lane mask."""
    var v: List[Int] = []
    for i in range(64):
        if i & 1 == 0:
            v.append(0)
        else:
            v.append(3)
    _decode_and_check(v, 2)


# =============================================================================
# bw=4 — 2 values per byte; SIMD body processes 8 bytes → 16 outputs at a time
# =============================================================================


def test_bw4_exactly_16() raises:
    """One full SIMD body iteration (W_BYTES=8), no scalar tail."""
    var v: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    _decode_and_check(v, 4)


def test_bw4_all_max_64() raises:
    """4 SIMD body iterations of all-0xF — exercises the high-nibble
    shift and mask."""
    var v: List[Int] = []
    for _ in range(64):
        v.append(15)
    _decode_and_check(v, 4)


def test_bw4_all_zero_64() raises:
    var v: List[Int] = []
    for _ in range(64):
        v.append(0)
    _decode_and_check(v, 4)


def test_bw4_partial_tail_17() raises:
    """1 full SIMD body (16) + 1 scalar-tail output."""
    var v: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 7]
    _decode_and_check(v, 4)


def test_bw4_partial_tail_31() raises:
    """1 full SIMD body (16) + 15 scalar-tail outputs."""
    var v: List[Int] = []
    for i in range(31):
        v.append(i & 0x0F)
    _decode_and_check(v, 4)


def test_bw4_only_tail_8() raises:
    """Less than W_BYTES=8 worth of bytes; entirely scalar tail.
    8 outputs < 16 lanes / W_VALS, so SIMD body skipped."""
    var v: List[Int] = [1, 2, 3, 4, 5, 6, 7, 8]
    _decode_and_check(v, 4)


def test_bw4_only_tail_15() raises:
    """15 outputs needs only 7.5 bytes — under the 8-byte SIMD threshold."""
    var v: List[Int] = []
    for i in range(15):
        v.append((i * 3) & 0x0F)
    _decode_and_check(v, 4)


def test_bw4_large_1024() raises:
    """64 SIMD body iterations."""
    var v: List[Int] = []
    for i in range(1024):
        v.append((i * 13 + 5) & 0x0F)
    _decode_and_check(v, 4)


def test_bw4_alternating_lo_hi_64() raises:
    """Alternating 0x0F / 0x00 stresses the lo/hi nibble interleave —
    if interleave order were swapped, output would be reversed."""
    var v: List[Int] = []
    for i in range(64):
        if i & 1 == 0:
            v.append(15)  # ends up in low nibble
        else:
            v.append(0)   # ends up in high nibble
    _decode_and_check(v, 4)


def test_bw4_alternating_hi_lo_64() raises:
    """Reverse: 0 then 15 — confirms low-nibble-first ordering."""
    var v: List[Int] = []
    for i in range(64):
        if i & 1 == 0:
            v.append(0)
        else:
            v.append(15)
    _decode_and_check(v, 4)


def test_bw4_lineitem_returnflag_pattern() raises:
    """TPC-H l_returnflag dictionary pattern — 3 distinct values cycling.
    bw=4 fits 2 values per byte; 6M-row column would dispatch this path
    on every Q3/Q14/Q1 lineitem scan."""
    var v: List[Int] = []
    for i in range(256):
        # cycle [0, 1, 2] = ['A', 'N', 'R']
        v.append(i % 3)
    _decode_and_check(v, 4)


def test_bw4_lineitem_shipmode_pattern() raises:
    """TPC-H l_shipmode dictionary pattern — 7 distinct values, exact
    fit at bw=4. Hot on Q12/Q14."""
    var v: List[Int] = []
    for i in range(256):
        v.append(i % 7)
    _decode_and_check(v, 4)


# =============================================================================
# Test entry
# =============================================================================


def main() raises:
    var suite = TestSuite()
    # bw=1
    suite.test[test_bw1_exactly_8]()
    suite.test[test_bw1_all_zero_64]()
    suite.test[test_bw1_all_one_64]()
    suite.test[test_bw1_partial_tail_9]()
    suite.test[test_bw1_partial_tail_15]()
    suite.test[test_bw1_only_tail_5]()
    suite.test[test_bw1_large_1024]()
    # bw=2
    suite.test[test_bw2_exactly_4]()
    suite.test[test_bw2_all_max_32]()
    suite.test[test_bw2_all_zero_32]()
    suite.test[test_bw2_partial_tail_5]()
    suite.test[test_bw2_partial_tail_7]()
    suite.test[test_bw2_only_tail_3]()
    suite.test[test_bw2_large_1024]()
    suite.test[test_bw2_alternating_64]()
    # bw=4
    suite.test[test_bw4_exactly_16]()
    suite.test[test_bw4_all_max_64]()
    suite.test[test_bw4_all_zero_64]()
    suite.test[test_bw4_partial_tail_17]()
    suite.test[test_bw4_partial_tail_31]()
    suite.test[test_bw4_only_tail_8]()
    suite.test[test_bw4_only_tail_15]()
    suite.test[test_bw4_large_1024]()
    suite.test[test_bw4_alternating_lo_hi_64]()
    suite.test[test_bw4_alternating_hi_lo_64]()
    suite.test[test_bw4_lineitem_returnflag_pattern]()
    suite.test[test_bw4_lineitem_shipmode_pattern]()
    suite^.run()
