# =============================================================================
# Correctness gate for the SIMD cyclic byte-pattern extend primitive in
# `komira_core.simd.pattern_copy`.
# =============================================================================
#
# Coverage:
#   1. Length-zero is a no-op (the buffer must not be modified).
#   2. Run-length-encoded byte fill (offset=1, length=10).
#   3. Full sweep `offset in 1..15 x length in 1..64` = 960 cases — every
#      cyclic-overlap shape that the NEON `tbl.16b` path handles.
#   4. Plain non-overlap copies (offset in {16, 32, 64, 1024} x length
#      in 1..64) = 256 cases — exercise the NEON `ld1`/`st1` 16-byte
#      unrolled loop.
#   5. 1000 randomized cases with arbitrary offset / length / prefix.
#
# Each case is verified byte-identical against a scalar oracle in the
# COMMITTED range `[out_pos, out_pos + length)`. The NEON small-offset
# path may legally over-write past the committed end up to the next
# 16-byte block boundary (snappy slop-buffer semantics) — bytes past
# `length` are intentionally not validated. Bytes BEFORE `out_pos` must
# be unchanged.

# =============================================================================

from std.random import random_si64, seed
from std.testing import assert_equal, assert_true

from komira_core.simd.pattern_copy import pattern_copy_extend


# =============================================================================
# Scalar oracle (independent re-implementation of the byte-by-byte loop).
# =============================================================================


def scalar_pattern_copy(
    mut buf: List[UInt8],
    out_pos: Int,
    length: Int,
    offset: Int,
) -> None:
    """Byte-by-byte reference; correct for any (offset >= 1, length >= 0)."""
    for k in range(length):
        buf[out_pos + k] = buf[out_pos - offset + k]


# =============================================================================
# Buffer helpers.
# =============================================================================


def _fresh_buf(prefix_len: Int, suffix_pad: Int) -> List[UInt8]:
    """Build a List[UInt8] with `prefix_len` deterministic-pattern bytes
    followed by `suffix_pad` zero bytes (the slop). The pattern uses the
    high bit set so a 0 in the suffix is distinguishable from a prefix
    byte being incorrectly preserved as zero.
    """
    var b = List[UInt8]()
    for k in range(prefix_len):
        b.append(UInt8(0x80 + (k & 0x7F)))
    for _ in range(suffix_pad):
        b.append(UInt8(0))
    return b^


def _bufs_equal(imm a: List[UInt8], imm b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


def _bytes_equal_in_range(
    imm a: List[UInt8],
    imm b: List[UInt8],
    start: Int,
    end: Int,
) -> Bool:
    """Compare `a[start..end]` vs `b[start..end]`. Used to validate the
    SIMD primitive matches the scalar oracle in the COMMITTED region; the
    SIMD primitive may legally over-write bytes past the committed end up
    to the next 16-byte block boundary (slop-buffer semantics).
    """
    if start < 0 or end > len(a) or end > len(b):
        return False
    for k in range(start, end):
        if a[k] != b[k]:
            return False
    return True


# =============================================================================
# Tests.
# =============================================================================


def test_length_zero_is_noop() raises:
    """length=0 must NOT touch the output buffer."""
    var buf = _fresh_buf(32, 64)
    var golden = List[UInt8]()
    for k in range(len(buf)):
        golden.append(buf[k])
    pattern_copy_extend(Span(buf), 32, 0, 5)
    assert_true(_bufs_equal(buf, golden), "length=0 must be a no-op")


def test_offset_1_run_length_encoding() raises:
    """offset=1, length=N: run-length-encoded byte fill. The byte at
    `out_pos - 1` is repeated N times into `[out_pos, out_pos + N)`."""
    var buf = _fresh_buf(31, 0)
    buf.append(UInt8(0xAA))  # sentinel byte at index 31 (=out_pos - 1)
    for _ in range(64):
        buf.append(UInt8(0))

    var oracle = List[UInt8]()
    for k in range(len(buf)):
        oracle.append(buf[k])

    pattern_copy_extend(Span(buf), 32, 10, 1)
    scalar_pattern_copy(oracle, 32, 10, 1)

    # COMMITTED region (out_pos .. out_pos + length) must match oracle.
    assert_true(
        _bytes_equal_in_range(buf, oracle, 32, 32 + 10),
        "offset=1 length=10 RLE: committed range must match oracle",
    )
    # Sentinel byte 0xAA must be the value repeated into all 10 slots.
    for k in range(32, 42):
        assert_equal(Int(buf[k]), 0xAA)
    # Bytes BEFORE out_pos must be unchanged.
    assert_true(
        _bytes_equal_in_range(buf, oracle, 0, 32),
        "offset=1 length=10 RLE: prefix must be unchanged",
    )


def test_offset_le_15_lengths() raises:
    """Full sweep: offset in [1, 15] x length in [1, 64] = 960 cases.
    Exercises the NEON `tbl.16b` cyclic-shuffle path for every
    overlap shape that the small-offset arm can produce.
    """
    for offset in range(1, 16):
        for length in range(1, 65):
            var prefix_len = 64
            var buf = _fresh_buf(prefix_len, 128)

            var oracle = List[UInt8]()
            for k in range(len(buf)):
                oracle.append(buf[k])

            pattern_copy_extend(Span(buf), prefix_len, length, offset)
            scalar_pattern_copy(oracle, prefix_len, length, offset)

            assert_true(
                _bytes_equal_in_range(
                    buf, oracle, prefix_len, prefix_len + length
                ),
                String("offset=") + String(offset) + String(" length=")
                + String(length) + String(": committed-range mismatch"),
            )
            assert_true(
                _bytes_equal_in_range(buf, oracle, 0, prefix_len),
                String("offset=") + String(offset) + String(" length=")
                + String(length) + String(": prefix changed"),
            )


def test_offset_ge_16_plain_copy() raises:
    """offset >= 16: plain non-overlap copies. Exercises the NEON
    `ld1`/`st1` 16-byte unrolled loop. Offsets {16, 32, 64, 1024} × 64
    lengths = 256 cases.
    """
    var offsets = List[Int]()
    offsets.append(16)
    offsets.append(32)
    offsets.append(64)
    offsets.append(1024)
    for oi in range(len(offsets)):
        var offset = offsets[oi]
        for length in range(1, 65):
            var prefix_len = offset + 64
            var buf = _fresh_buf(prefix_len, 128)

            var oracle = List[UInt8]()
            for k in range(len(buf)):
                oracle.append(buf[k])

            pattern_copy_extend(Span(buf), prefix_len, length, offset)
            scalar_pattern_copy(oracle, prefix_len, length, offset)

            assert_true(
                _bytes_equal_in_range(
                    buf, oracle, prefix_len, prefix_len + length
                ),
                String("plain offset=") + String(offset)
                + String(" length=") + String(length)
                + String(": committed range"),
            )
            assert_true(
                _bytes_equal_in_range(buf, oracle, 0, prefix_len),
                String("plain offset=") + String(offset)
                + String(" length=") + String(length)
                + String(": prefix changed"),
            )


def test_randomized_correctness() raises:
    """1000 random cases with arbitrary offset in [1, 63], length in
    [1, 64], and prefix length [offset+1, offset+100]. Catches anything
    the deterministic sweeps miss (e.g. unusual buffer alignments).
    """
    seed(0xC0FFEE)
    for _ in range(1000):
        var offset = Int(random_si64(1, 63))
        var length = Int(random_si64(1, 64))
        var prefix_len = Int(
            random_si64(Int64(offset + 1), Int64(offset + 100))
        )

        var buf = List[UInt8]()
        for _ in range(prefix_len):
            buf.append(UInt8(random_si64(0, 255)))
        for _ in range(128):
            buf.append(UInt8(0))

        var oracle = List[UInt8]()
        for k in range(len(buf)):
            oracle.append(buf[k])

        pattern_copy_extend(Span(buf), prefix_len, length, offset)
        scalar_pattern_copy(oracle, prefix_len, length, offset)

        assert_true(
            _bytes_equal_in_range(
                buf, oracle, prefix_len, prefix_len + length
            ),
            String("randomized offset=") + String(offset)
            + String(" length=") + String(length)
            + String(": committed range"),
        )
        assert_true(
            _bytes_equal_in_range(buf, oracle, 0, prefix_len),
            String("randomized offset=") + String(offset)
            + String(" length=") + String(length)
            + String(": prefix changed"),
        )


def test_back_to_back_calls() raises:
    """Two consecutive pattern_copy_extend calls into the same buffer.
    Validates that the primitive correctly composes when each call's
    write window is the NEXT call's read window (the LZ77 streaming
    decompressor shape).
    """
    var buf = _fresh_buf(16, 256)  # 16 bytes of prefix-pattern, 256 of slop.
    var oracle = List[UInt8]()
    for k in range(len(buf)):
        oracle.append(buf[k])

    # First call: copy 32 bytes from offset 16 (the entire prefix
    # repeats once, plus 16 more from the copy itself).
    pattern_copy_extend(Span(buf), 16, 32, 16)
    scalar_pattern_copy(oracle, 16, 32, 16)
    assert_true(
        _bytes_equal_in_range(buf, oracle, 16, 48),
        "back-to-back: first call mismatch",
    )

    # Second call: from out_pos=48, copy 24 bytes with offset 8.
    pattern_copy_extend(Span(buf), 48, 24, 8)
    scalar_pattern_copy(oracle, 48, 24, 8)
    assert_true(
        _bytes_equal_in_range(buf, oracle, 48, 72),
        "back-to-back: second call mismatch",
    )


def test_max_length_64_exact() raises:
    """length=64 with offset 1..15 exercises ALL 4 NEON output blocks
    (b0/b1/b2/b3). The sweep above covers lengths 1..64; this is a
    quick targeted regression test for the W=64 boundary, in case any
    future refactor changes the unrolled-block count.
    """
    for offset in range(1, 16):
        var buf = _fresh_buf(64, 128)
        var oracle = List[UInt8]()
        for k in range(len(buf)):
            oracle.append(buf[k])

        pattern_copy_extend(Span(buf), 64, 64, offset)
        scalar_pattern_copy(oracle, 64, 64, offset)
        assert_true(
            _bytes_equal_in_range(buf, oracle, 64, 128),
            String("max-length-64 offset=") + String(offset),
        )
        assert_true(
            _bytes_equal_in_range(buf, oracle, 0, 64),
            String("max-length-64 offset=") + String(offset)
            + String(": prefix changed"),
        )


def main() raises:
    test_length_zero_is_noop()
    print("test_length_zero_is_noop: PASS")
    test_offset_1_run_length_encoding()
    print("test_offset_1_run_length_encoding: PASS")
    test_offset_le_15_lengths()
    print("test_offset_le_15_lengths: PASS")
    test_offset_ge_16_plain_copy()
    print("test_offset_ge_16_plain_copy: PASS")
    test_randomized_correctness()
    print("test_randomized_correctness: PASS")
    test_back_to_back_calls()
    print("test_back_to_back_calls: PASS")
    test_max_length_64_exact()
    print("test_max_length_64_exact: PASS")
    print("ALL TESTS PASS")
