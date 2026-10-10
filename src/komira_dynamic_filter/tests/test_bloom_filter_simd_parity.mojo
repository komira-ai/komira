# =============================================================================
# Bloom-filter SIMD probe vs scalar probe — bit-identical parity test
# =============================================================================
#
# Regression guard: the SIMD bulk 8-hash probe in
# `_block_check` (bloom_filter.mojo) replaces an 8-step scalar bit-test
# cascade with a SIMD AND + reduce_min check. This test asserts that the
# SIMD probe returns the SAME Bool as a scalar oracle for a sweep of
# block patterns and hash inputs, including the edge cases:
#
#   1. all-zero block — scalar/SIMD must both return False for any hash.
#   2. all-one block (every bit set) — scalar/SIMD must both return True
#      for any hash.
#   3. single-bit-set per word — fingers all 8 lanes individually.
#   4. alternating word patterns — exercises the SIMD lane behavior.
#   5. blocks containing the exact insert pattern for known keys —
#      every inserted key must round-trip True (no false negatives,
#      sanity).
#
# If the SIMD probe ever drifts from the scalar probe, this test fails
# at compile-or-run time, well before the FPR regression test catches it
# at the statistical level.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_dynamic_filter.bloom_filter import (
    BloomFilter,
    _block_check,
    _block_mask_word,
)


# -----------------------------------------------------------------------------
# Scalar oracle: re-implement the 8-step cascade in the test (so a refactor
# of `_block_check` cannot silently break the parity check).
# -----------------------------------------------------------------------------


# SBBF salts (must match bloom_filter.mojo).
comptime _ORACLE_SALT_0: UInt32 = 0x47B6137B
comptime _ORACLE_SALT_1: UInt32 = 0x44974D91
comptime _ORACLE_SALT_2: UInt32 = 0x8824AD5B
comptime _ORACLE_SALT_3: UInt32 = 0xA2B7289D
comptime _ORACLE_SALT_4: UInt32 = 0x705495C7
comptime _ORACLE_SALT_5: UInt32 = 0x2DF1424B
comptime _ORACLE_SALT_6: UInt32 = 0x9EFC4947
comptime _ORACLE_SALT_7: UInt32 = 0x5C6BFB31


def _scalar_mask_word(x: UInt32, salt: UInt32) -> UInt32:
    var y = x * salt
    return UInt32(1) << (y >> 27)


def _scalar_block_check(words: List[UInt32], x: UInt32) -> Bool:
    """Reference scalar implementation of the SBBF probe.

    Args:
        words: 8 UInt32 words of the block.
        x: Lower 32 bits of the hash.

    Returns:
        True iff every probe bit is set in `words`.
    """
    if (words[0] & _scalar_mask_word(x, _ORACLE_SALT_0)) == 0:
        return False
    if (words[1] & _scalar_mask_word(x, _ORACLE_SALT_1)) == 0:
        return False
    if (words[2] & _scalar_mask_word(x, _ORACLE_SALT_2)) == 0:
        return False
    if (words[3] & _scalar_mask_word(x, _ORACLE_SALT_3)) == 0:
        return False
    if (words[4] & _scalar_mask_word(x, _ORACLE_SALT_4)) == 0:
        return False
    if (words[5] & _scalar_mask_word(x, _ORACLE_SALT_5)) == 0:
        return False
    if (words[6] & _scalar_mask_word(x, _ORACLE_SALT_6)) == 0:
        return False
    if (words[7] & _scalar_mask_word(x, _ORACLE_SALT_7)) == 0:
        return False
    return True


# -----------------------------------------------------------------------------
# Helper: build a BloomFilter whose first block contains `words`, then
# probe it with `hash` and compare scalar vs SIMD outputs.
# -----------------------------------------------------------------------------


def _probe_oracle_vs_simd(words: List[UInt32], hash_lo: UInt32) raises:
    """Materialize a 1-block bloom filter from `words`, probe via the SIMD
    impl + the scalar oracle, assert equality."""
    # 1-block filter (32 bytes). num_blocks=1 means _hash_to_block_index
    # always returns 0, so any hash probes block 0 — which is exactly
    # `words`. Constructed directly via `from_bytes` so we control the
    # bit pattern.
    var raw = List[UInt8](capacity=32)
    for i in range(8):
        var w = words[i]
        raw.append(UInt8(w & 0xFF))
        raw.append(UInt8((w >> 8) & 0xFF))
        raw.append(UInt8((w >> 16) & 0xFF))
        raw.append(UInt8((w >> 24) & 0xFF))
    var bf2 = BloomFilter.from_bytes(Span(raw))
    # Probe: SIMD path is `check_hash` (which calls `_block_check`).
    # Synthesize a 64-bit hash where the upper 32 bits are 0 (block 0)
    # and the lower 32 bits are `hash_lo`.
    var full_hash = UInt64(hash_lo)
    var simd_result = bf2.check_hash(full_hash)
    var scalar_result = _scalar_block_check(words, hash_lo)
    assert_equal(
        Int(simd_result),
        Int(scalar_result),
        (
            "SIMD/scalar probe mismatch: hash_lo="
            + String(hash_lo)
            + " expected="
            + String(scalar_result)
            + " got="
            + String(simd_result)
        ),
    )
    _ = raw  # keepalive


# -----------------------------------------------------------------------------
# Test 1: all-zero block — every probe MUST return False.
# -----------------------------------------------------------------------------


def test_all_zero_block_always_false() raises:
    var words: List[UInt32] = [0, 0, 0, 0, 0, 0, 0, 0]
    # Sweep a representative set of hashes (hand-picked + powers-of-2 +
    # the salts themselves to hit interesting shift boundaries).
    var hashes: List[UInt32] = [
        0,
        1,
        2,
        7,
        31,
        32,
        100,
        12345,
        0xCAFEBABE,
        0xDEADBEEF,
        0xFFFFFFFF,
        0x80000000,
        0x47B6137B,  # SALT_0
        0x5C6BFB31,  # SALT_7
    ]
    for i in range(len(hashes)):
        _probe_oracle_vs_simd(words, hashes[i])


# -----------------------------------------------------------------------------
# Test 2: all-one block — every probe MUST return True.
# -----------------------------------------------------------------------------


def test_all_one_block_always_true() raises:
    var ones: UInt32 = 0xFFFFFFFF
    var words: List[UInt32] = [ones, ones, ones, ones, ones, ones, ones, ones]
    var hashes: List[UInt32] = [
        0,
        1,
        2,
        7,
        31,
        32,
        100,
        12345,
        0xCAFEBABE,
        0xDEADBEEF,
        0xFFFFFFFF,
        0x80000000,
    ]
    for i in range(len(hashes)):
        _probe_oracle_vs_simd(words, hashes[i])


# -----------------------------------------------------------------------------
# Test 3: single-bit-set per word, sweep across all 32 bit positions and
# all 8 lanes — verifies SIMD AND/reduce_min over real bit patterns.
# -----------------------------------------------------------------------------


def test_single_bit_per_word_sweep() raises:
    # For each lane in {0..7}, set lane to (1 << bit) for bit in {0..31};
    # leave the other 7 lanes at 0xFFFFFFFF. Probe with a hash that exercises
    # the SBBF mask. The probe FAILS unless the chosen bit happens to match
    # the salt-derived bit position.
    for lane in range(8):
        for bit in range(32):
            var words: List[UInt32] = [
                0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
                0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
            ]
            words[lane] = UInt32(1) << UInt32(bit)
            # Pick a few diverse hashes per (lane, bit) combo.
            var hashes: List[UInt32] = [
                UInt32(bit),
                UInt32(bit) * UInt32(0x9E3779B1),
                0xCAFEBABE ^ UInt32(bit),
            ]
            for h_idx in range(len(hashes)):
                _probe_oracle_vs_simd(words, hashes[h_idx])


# -----------------------------------------------------------------------------
# Test 4: alternating word pattern — checks SIMD lane independence.
# -----------------------------------------------------------------------------


def test_alternating_word_pattern() raises:
    var hi: UInt32 = 0xAAAAAAAA  # alternating bits
    var lo: UInt32 = 0x55555555  # opposite alternating
    var words_a: List[UInt32] = [hi, lo, hi, lo, hi, lo, hi, lo]
    var words_b: List[UInt32] = [lo, hi, lo, hi, lo, hi, lo, hi]
    var hashes: List[UInt32] = [
        0, 1, 7, 31, 0xCAFEBABE, 0xDEADBEEF, 0xFFFFFFFF
    ]
    for i in range(len(hashes)):
        _probe_oracle_vs_simd(words_a, hashes[i])
        _probe_oracle_vs_simd(words_b, hashes[i])


# -----------------------------------------------------------------------------
# Test 5: insert-then-probe round-trip — every inserted key MUST be
# reported as present (no false negatives). End-to-end correctness check
# atop the underlying primitive helpers.
# -----------------------------------------------------------------------------


def test_insert_probe_round_trip() raises:
    # Use a multi-block filter so we exercise `_hash_to_block_index` too.
    var bf = BloomFilter.with_ndv_fpp(4096, 0.01)
    # Sweep diverse Int64 keys including negatives and edges.
    var keys: List[Int64] = [
        Int64(0),
        Int64(1),
        Int64(-1),
        Int64(42),
        Int64(1 << 16),
        Int64(1 << 32),
        Int64(1 << 50),
        Int64(0x7FFFFFFFFFFFFFFF),
        Int64(-0x8000000000000000),
        Int64(0xCAFEBABE),
        Int64(0xDEADBEEF),
    ]
    for i in range(len(keys)):
        bf.insert_int64(keys[i])
    for i in range(len(keys)):
        assert_true(
            bf.might_contain_int64(keys[i]),
            "key " + String(keys[i]) + " inserted but probe returned False",
        )


# -----------------------------------------------------------------------------
# Test 6: monotonicity — ANDing more bits into a block can only make the
# probe transition False -> True, never True -> False (mask is fixed for
# a given hash; setting more block bits can only set more AND-result lanes
# non-zero).
# -----------------------------------------------------------------------------


def test_setting_more_bits_is_monotonic() raises:
    var bf = BloomFilter.with_ndv_fpp(1024, 0.01)
    # Probe-then-insert-then-probe. The post-insert probe must be True.
    # The pre-insert probe is allowed to be anything (False or True FP).
    var keys: List[Int64] = [
        Int64(7), Int64(13), Int64(101), Int64(1009), Int64(99991)
    ]
    for i in range(len(keys)):
        # Pre-insert: compute pre value (allowed to be either).
        var pre = bf.might_contain_int64(keys[i])
        bf.insert_int64(keys[i])
        var post = bf.might_contain_int64(keys[i])
        # Post-insert MUST be True.
        assert_true(
            post,
            "post-insert probe must be True for key " + String(keys[i]),
        )
        # Monotonicity: pre=True implies post=True (we just confirmed
        # post=True, so the only invariant left to assert is "post=True
        # whenever pre=True"). This is automatic, but assert anyway as
        # a paranoid double-check.
        if pre:
            assert_true(
                post,
                "monotonicity violation: pre=True but post=False for "
                + String(keys[i]),
            )


def main() raises:
    var suite = TestSuite()
    suite.test[test_all_zero_block_always_false]()
    suite.test[test_all_one_block_always_true]()
    suite.test[test_single_bit_per_word_sweep]()
    suite.test[test_alternating_word_pattern]()
    suite.test[test_insert_probe_round_trip]()
    suite.test[test_setting_more_bits_is_monotonic]()
    suite^.run()
