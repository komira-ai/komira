# =============================================================================
# Bloom-filter `merge_or_range` SIMD-vs-scalar parity test
# =============================================================================
#
# Regression guard: the SIMD-vectorized OR loop
# in `BloomFilter.merge_or_range` (bloom_filter.mojo) replaces a
# scalar u64 OR loop with a `simd_width_of[DType.uint64]()`-wide SIMD OR
# (~4 lanes on AVX2, ~8 on AVX-512, ~2 on NEON). This test asserts that
# the SIMD path produces byte-identical results vs a scalar oracle for a
# range of buffer sizes and byte-window offsets, including:
#
#   1. Single-block (32-byte) merges — minimum filter size; exactly 4 u64s.
#   2. Multi-block (64 / 256 / 4096 byte) merges — the production hot path.
#   3. Disjoint-window merges — what the parallel pre-pass actually does
#      (each reducer task ORs a [byte_start, byte_start+byte_len) sub-window).
#   4. Edge windows: byte_start=0 and byte_start at last block boundary.
#   5. Randomized (LCG) byte patterns to avoid biased test inputs.
#   6. Idempotence: OR of self into self is a no-op (a | a == a).
#   7. Associativity: (a | b) | c == a | (b | c) — order independence
#      check for the parallel OR-reduce contract.
#
# The "scalar oracle" lives inside this test file (re-implements the
# byte-by-byte OR) so a refactor of `merge_or_range` cannot silently
# break the parity assertion.
#
# Pattern: unit-stride bulk operation, the same shape as `_simd_sum`, with
# `|` in place of `+`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_dynamic_filter.bloom_filter import BloomFilter


# -----------------------------------------------------------------------------
# Scalar oracle: byte-by-byte OR, no SIMD, no u64 stride. Reads each byte
# of `src.data[byte_start:byte_start+byte_len]` and ORs it into the
# corresponding byte of `dst.data`. Returns the OR'd output bytes as a
# `List[UInt8]` of length `dst.num_bytes` for byte-equivalence check.
# -----------------------------------------------------------------------------


def _oracle_or_bytes(
    dst_bytes: List[UInt8],
    src_bytes: List[UInt8],
    byte_start: Int,
    byte_len: Int,
) -> List[UInt8]:
    """Reference: scalar byte-by-byte OR of src[start:start+len] into dst.

    Args:
        dst_bytes: Destination bytes (input copy of dst.data).
        src_bytes: Source bytes (input copy of src.data).
        byte_start: Starting byte offset.
        byte_len: Number of bytes to OR.

    Returns:
        New List[UInt8] with the OR'd output.
    """
    var out = List[UInt8](capacity=len(dst_bytes))
    for i in range(len(dst_bytes)):
        out.append(dst_bytes[i])
    for i in range(byte_start, byte_start + byte_len):
        out[i] = out[i] | src_bytes[i]
    return out^


# -----------------------------------------------------------------------------
# Helper: build a BloomFilter from a List[UInt8] of length `num_bytes`.
# `BloomFilter.from_bytes` rounds up to the next multiple of 32 and pads
# with zeros, so passing a length-`num_bytes` list (where `num_bytes` is
# already a multiple of 32) yields a filter whose underlying data
# matches the list byte-for-byte.
# -----------------------------------------------------------------------------


def _bf_from_pattern(num_bytes: Int, seed: UInt64) -> BloomFilter:
    """Construct a BloomFilter whose data follows a deterministic LCG
    pattern. The output filter has exactly `num_bytes` capacity (rounded
    up to next multiple of 32 by `from_bytes`).
    """
    var raw = List[UInt8](capacity=num_bytes)
    var state = seed
    for _ in range(num_bytes):
        # LCG params from Numerical Recipes (Knuth).
        state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        raw.append(UInt8((state >> 32) & 0xFF))
    var bf = BloomFilter.from_bytes(Span(raw))
    _ = raw^  # keepalive
    return bf^


def _bf_data_to_list(bf: BloomFilter) -> List[UInt8]:
    """Read the underlying bytes of a BloomFilter into a List[UInt8]."""
    var out = List[UInt8](capacity=bf.num_bytes)
    var view = bf.data.view_range_ro(0, bf.num_bytes)
    for i in range(bf.num_bytes):
        out.append(view.get_typed[UInt8](i))
    return out^


def _assert_byte_equal(
    actual: List[UInt8], expected: List[UInt8], context: String
) raises:
    """Byte-by-byte equality check with a context label for failure msg."""
    assert_equal(
        len(actual),
        len(expected),
        context + ": length mismatch",
    )
    for i in range(len(actual)):
        if actual[i] != expected[i]:
            assert_equal(
                Int(actual[i]),
                Int(expected[i]),
                (
                    context
                    + ": byte["
                    + String(i)
                    + "] mismatch (actual="
                    + String(actual[i])
                    + ", expected="
                    + String(expected[i])
                    + ")"
                ),
            )


# -----------------------------------------------------------------------------
# Test 1: single-block (32-byte) merge — exactly 4 u64s.
# On AVX2 (W=4) this is a single SIMD OR, no scalar tail.
# On AVX-512 (W=8) this is a scalar-tail-only path (4 u64s < 8).
# On NEON (W=2) this is two SIMD iterations, no tail.
# -----------------------------------------------------------------------------


def test_single_block_merge() raises:
    var dst = _bf_from_pattern(32, UInt64(0xDEADBEEF))
    var src = _bf_from_pattern(32, UInt64(0xCAFEBABE))
    var dst_in = _bf_data_to_list(dst)
    var src_in = _bf_data_to_list(src)
    dst.merge_or_range(src, 0, 32)
    var actual = _bf_data_to_list(dst)
    var expected = _oracle_or_bytes(dst_in, src_in, 0, 32)
    _assert_byte_equal(actual, expected, "single_block_merge")
    _ = src^  # keepalive


# -----------------------------------------------------------------------------
# Test 2: multi-block 64-byte merge — covers 8 u64s (full SIMD on AVX-512;
# 2 SIMD-iters on AVX2; 4 SIMD-iters on NEON).
# -----------------------------------------------------------------------------


def test_64_byte_merge() raises:
    var dst = _bf_from_pattern(64, UInt64(0x1234567890ABCDEF))
    var src = _bf_from_pattern(64, UInt64(0xFEDCBA9876543210))
    var dst_in = _bf_data_to_list(dst)
    var src_in = _bf_data_to_list(src)
    dst.merge_or_range(src, 0, 64)
    var actual = _bf_data_to_list(dst)
    var expected = _oracle_or_bytes(dst_in, src_in, 0, 64)
    _assert_byte_equal(actual, expected, "64_byte_merge")
    _ = src^


# -----------------------------------------------------------------------------
# Test 3: 256-byte merge — typical small-filter size.
# -----------------------------------------------------------------------------


def test_256_byte_merge() raises:
    var dst = _bf_from_pattern(256, UInt64(0x1111))
    var src = _bf_from_pattern(256, UInt64(0x2222))
    var dst_in = _bf_data_to_list(dst)
    var src_in = _bf_data_to_list(src)
    dst.merge_or_range(src, 0, 256)
    var actual = _bf_data_to_list(dst)
    var expected = _oracle_or_bytes(dst_in, src_in, 0, 256)
    _assert_byte_equal(actual, expected, "256_byte_merge")
    _ = src^


# -----------------------------------------------------------------------------
# Test 4: 4096-byte merge — typical mid-size filter.
# -----------------------------------------------------------------------------


def test_4096_byte_merge() raises:
    var dst = _bf_from_pattern(4096, UInt64(0xA5A5A5A5))
    var src = _bf_from_pattern(4096, UInt64(0x5A5A5A5A))
    var dst_in = _bf_data_to_list(dst)
    var src_in = _bf_data_to_list(src)
    dst.merge_or_range(src, 0, 4096)
    var actual = _bf_data_to_list(dst)
    var expected = _oracle_or_bytes(dst_in, src_in, 0, 4096)
    _assert_byte_equal(actual, expected, "4096_byte_merge")
    _ = src^


# -----------------------------------------------------------------------------
# Test 5: disjoint-window merges — exactly the parallel pre-pass pattern.
# Each reducer task gets a contiguous [byte_start, byte_start+byte_len)
# sub-window. Test that the SIMD path matches scalar oracle on every
# block-aligned sub-window of an 8-block (256-byte) filter.
# -----------------------------------------------------------------------------


def test_disjoint_block_aligned_windows() raises:
    var num_bytes = 256
    var num_blocks = 8  # 256 / 32
    for block_idx in range(num_blocks):
        var dst = _bf_from_pattern(num_bytes, UInt64(0xF00DCAFE) + UInt64(block_idx))
        var src = _bf_from_pattern(num_bytes, UInt64(0xBADBEEF0) + UInt64(block_idx))
        var dst_in = _bf_data_to_list(dst)
        var src_in = _bf_data_to_list(src)
        var byte_start = block_idx * 32
        var byte_len = 32
        dst.merge_or_range(src, byte_start, byte_len)
        var actual = _bf_data_to_list(dst)
        var expected = _oracle_or_bytes(dst_in, src_in, byte_start, byte_len)
        _assert_byte_equal(
            actual, expected,
            "disjoint_block_aligned_windows[block=" + String(block_idx) + "]"
        )
        _ = src^


# -----------------------------------------------------------------------------
# Test 6: multi-block sub-windows — varying byte_len that crosses
# SIMD-width / u64-stride boundaries. Stresses the scalar tail.
# -----------------------------------------------------------------------------


def test_multi_block_sub_windows() raises:
    var num_bytes = 1024
    # Sub-window byte_lens span: pure SIMD (32, 64, 128), SIMD + scalar
    # tail (96 if W=4; 40 / 48 / 56 are <W*8 on AVX-512).
    var byte_lens: List[Int] = [32, 64, 96, 128, 160, 192, 224, 256, 512, 768, 1024]
    var byte_starts: List[Int] = [0, 32, 64, 128, 256, 512]
    for s_idx in range(len(byte_starts)):
        var byte_start = byte_starts[s_idx]
        for l_idx in range(len(byte_lens)):
            var byte_len = byte_lens[l_idx]
            if byte_start + byte_len > num_bytes:
                continue
            var dst = _bf_from_pattern(num_bytes, UInt64(0xABCD0000) + UInt64(s_idx * 100 + l_idx))
            var src = _bf_from_pattern(num_bytes, UInt64(0x12340000) + UInt64(s_idx * 100 + l_idx))
            var dst_in = _bf_data_to_list(dst)
            var src_in = _bf_data_to_list(src)
            dst.merge_or_range(src, byte_start, byte_len)
            var actual = _bf_data_to_list(dst)
            var expected = _oracle_or_bytes(dst_in, src_in, byte_start, byte_len)
            _assert_byte_equal(
                actual, expected,
                (
                    "multi_block_sub_windows[start="
                    + String(byte_start)
                    + ", len="
                    + String(byte_len)
                    + "]"
                ),
            )
            _ = src^


# -----------------------------------------------------------------------------
# Test 7: idempotence — OR of self into self is a no-op.
# -----------------------------------------------------------------------------


def test_idempotence() raises:
    var bf = _bf_from_pattern(256, UInt64(0xDEADC0DE))
    var bf_other = _bf_from_pattern(256, UInt64(0xDEADC0DE))  # same seed, identical bytes
    var before = _bf_data_to_list(bf)
    bf.merge_or_range(bf_other, 0, 256)
    var after = _bf_data_to_list(bf)
    # x | x == x for all bytes.
    _assert_byte_equal(after, before, "idempotence: self-OR is no-op")
    _ = bf_other^


# -----------------------------------------------------------------------------
# Test 8: order independence — (a | b) | c == a | (b | c) byte-for-byte.
# This is the contract for the parallel OR-reduce: tasks may merge in any
# order and the result must be deterministic.
# -----------------------------------------------------------------------------


def test_order_independence() raises:
    var num_bytes = 512
    # Path 1: ((empty | a) | b) | c — start from exactly-zeros.
    var zeros = List[UInt8](capacity=num_bytes)
    for _ in range(num_bytes):
        zeros.append(UInt8(0))
    var p1 = BloomFilter.from_bytes(Span(zeros))
    _ = zeros^

    var a = _bf_from_pattern(num_bytes, UInt64(0xAAAA))
    var b = _bf_from_pattern(num_bytes, UInt64(0xBBBB))
    var c = _bf_from_pattern(num_bytes, UInt64(0xCCCC))
    p1.merge_or_range(a, 0, num_bytes)
    p1.merge_or_range(b, 0, num_bytes)
    p1.merge_or_range(c, 0, num_bytes)
    var p1_out = _bf_data_to_list(p1)

    # Path 2: ((empty | c) | a) | b — different order.
    var zeros2 = List[UInt8](capacity=num_bytes)
    for _ in range(num_bytes):
        zeros2.append(UInt8(0))
    var p2 = BloomFilter.from_bytes(Span(zeros2))
    _ = zeros2^

    p2.merge_or_range(c, 0, num_bytes)
    p2.merge_or_range(a, 0, num_bytes)
    p2.merge_or_range(b, 0, num_bytes)
    var p2_out = _bf_data_to_list(p2)

    _assert_byte_equal(p1_out, p2_out, "order_independence")
    _ = a^
    _ = b^
    _ = c^


# -----------------------------------------------------------------------------
# Test 9: pathological all-zero src — OR of zero is identity.
# -----------------------------------------------------------------------------


def test_zero_src_is_identity() raises:
    var num_bytes = 128
    var dst = _bf_from_pattern(num_bytes, UInt64(0xFEEDFACE))
    var dst_in = _bf_data_to_list(dst)
    var zeros = List[UInt8](capacity=num_bytes)
    for _ in range(num_bytes):
        zeros.append(UInt8(0))
    var zero_src = BloomFilter.from_bytes(Span(zeros))
    _ = zeros^

    dst.merge_or_range(zero_src, 0, num_bytes)
    var actual = _bf_data_to_list(dst)
    _assert_byte_equal(actual, dst_in, "zero_src_is_identity")
    _ = zero_src^


# -----------------------------------------------------------------------------
# Test 10: pathological all-ones src — OR of all-ones produces all-ones.
# -----------------------------------------------------------------------------


def test_ones_src_yields_ones() raises:
    var num_bytes = 128
    var dst = _bf_from_pattern(num_bytes, UInt64(0xC0FFEE))
    var ones = List[UInt8](capacity=num_bytes)
    for _ in range(num_bytes):
        ones.append(UInt8(0xFF))
    var ones_src = BloomFilter.from_bytes(Span(ones))

    dst.merge_or_range(ones_src, 0, num_bytes)
    var actual = _bf_data_to_list(dst)
    # Every byte must be 0xFF.
    for i in range(num_bytes):
        assert_equal(
            Int(actual[i]),
            255,
            "ones_src_yields_ones: byte[" + String(i) + "] not 0xFF",
        )
    _ = ones_src^
    _ = ones^


# =============================================================================
# Test entry point
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_single_block_merge]()
    suite.test[test_64_byte_merge]()
    suite.test[test_256_byte_merge]()
    suite.test[test_4096_byte_merge]()
    suite.test[test_disjoint_block_aligned_windows]()
    suite.test[test_multi_block_sub_windows]()
    suite.test[test_idempotence]()
    suite.test[test_order_independence]()
    suite.test[test_zero_src_is_identity]()
    suite.test[test_ones_src_yields_ones]()
    suite^.run()
