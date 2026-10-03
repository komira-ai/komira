# =============================================================================
# Round-trip + edge tests for the SIMD horizontal-add wrappers in
# `komira_simd.horizontal_add`.
# =============================================================================
#
# Coverage:
#   1. Round-trip: each wrapper must be byte-identical to stdlib
#      `reduce_add` on 10K randomized inputs. Catches both intrinsic
#      mis-binding (wrong LLVM name silently selecting a different op)
#      and the truncation contract (mod 256 for non-widening, exact for
#      `hadd_widening_u8x16`).
#   2. Edge cases: all-zero, all-max, single-set-bit per lane, alternating
#      bits. The bitmap mask-popcount pattern runs on
#      arbitrary bit patterns, so these are the realistic shapes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.random import random_si64, seed

from komira_simd.horizontal_add import (
    hadd_u8x16,
    hadd_widening_u8x16,
    hadd_u16x8,
    hadd_u32x4,
)


comptime ITERS: Int = 10_000


# =============================================================================
# Helpers
# =============================================================================


def _make_random_u8x16(rng_state: Int) -> SIMD[DType.uint8, 16]:
    """Build a SIMD[uint8, 16] from a sequence of pseudo-random ints.

    Caller seeds via `seed(...)` before this; we just consume `random_si64`
    16 times. Returns the assembled vector.
    """
    var v = SIMD[DType.uint8, 16](0)
    for i in range(16):
        var r = random_si64(0, 256)
        v[i] = UInt8(Int(r) & 0xFF)
    return v


def _make_random_u16x8(rng_state: Int) -> SIMD[DType.uint16, 8]:
    """Build a SIMD[uint16, 8] from pseudo-random ints."""
    var v = SIMD[DType.uint16, 8](0)
    for i in range(8):
        var r = random_si64(0, 65536)
        v[i] = UInt16(Int(r) & 0xFFFF)
    return v


def _make_random_u32x4(rng_state: Int) -> SIMD[DType.uint32, 4]:
    """Build a SIMD[uint32, 4] from pseudo-random ints. Use two halves
    to fill u32 because `random_si64` returns Int (signed)."""
    var v = SIMD[DType.uint32, 4](0)
    for i in range(4):
        # Build u32 from two random u16s — random_si64 in [0, 65536) for each.
        var hi = random_si64(0, 65536)
        var lo = random_si64(0, 65536)
        var word: UInt64 = (UInt64(Int(hi)) << 16) | UInt64(Int(lo) & 0xFFFF)
        v[i] = UInt32(Int(word) & 0xFFFFFFFF)
    return v


# =============================================================================
# Round-trip vs stdlib (10K random inputs per wrapper)
# =============================================================================


def test_hadd_u8x16_round_trip_random() raises:
    """Hadd_u8x16 byte-identical to stdlib reduce_add on 10K random inputs."""
    seed(0xA1_B2_C3_D4)
    for _ in range(ITERS):
        var v = _make_random_u8x16(0)
        var expected = v.reduce_add()  # stdlib oracle
        var actual = hadd_u8x16(v)
        assert_equal(actual, expected)


def test_hadd_widening_u8x16_round_trip_random() raises:
    """Hadd_widening_u8x16 matches widened stdlib reduce on 10K random inputs."""
    seed(0xB2_C3_D4_E5)
    for _ in range(ITERS):
        var v = _make_random_u8x16(0)
        # Widening oracle: cast to u16 first, then reduce — no truncation.
        var wide = v.cast[DType.uint16]()
        var expected = wide.reduce_add()
        var actual = hadd_widening_u8x16(v)
        assert_equal(actual, expected)


def test_hadd_u16x8_round_trip_random() raises:
    """Hadd_u16x8 byte-identical to stdlib reduce_add on 10K random inputs."""
    seed(0xC3_D4_E5_F6)
    for _ in range(ITERS):
        var v = _make_random_u16x8(0)
        var expected = v.reduce_add()
        var actual = hadd_u16x8(v)
        assert_equal(actual, expected)


def test_hadd_u32x4_round_trip_random() raises:
    """Hadd_u32x4 byte-identical to stdlib reduce_add on 10K random inputs."""
    seed(0xD4_E5_F6_07)
    for _ in range(ITERS):
        var v = _make_random_u32x4(0)
        var expected = v.reduce_add()
        var actual = hadd_u32x4(v)
        assert_equal(actual, expected)


# =============================================================================
# Edge cases — all-zero, all-max, single-lane-set, alternating
# =============================================================================


def test_hadd_u8x16_all_zero() raises:
    var v = SIMD[DType.uint8, 16](0)
    assert_equal(hadd_u8x16(v), UInt8(0))
    assert_equal(hadd_widening_u8x16(v), UInt16(0))


def test_hadd_u8x16_all_max() raises:
    """All 16 lanes = 0xFF. Truncated sum = 0xF0 (0xFF * 16 mod 256). Widening sum = 0x0FF0."""
    var v = SIMD[DType.uint8, 16](0xFF)
    # 16 * 0xFF = 0x0FF0; truncated to u8 = 0xF0.
    assert_equal(hadd_u8x16(v), UInt8(0xF0))
    # Widening preserves full sum.
    assert_equal(hadd_widening_u8x16(v), UInt16(0x0FF0))


def test_hadd_u8x16_single_lane_set() raises:
    """Exactly one lane non-zero; per-lane verify hadd reads every lane."""
    for lane in range(16):
        var v = SIMD[DType.uint8, 16](0)
        v[lane] = UInt8(0x42)
        assert_equal(hadd_u8x16(v), UInt8(0x42))
        assert_equal(hadd_widening_u8x16(v), UInt16(0x42))


def test_hadd_u8x16_alternating() raises:
    """Lanes 0,2,4,...,14 = 1; lanes 1,3,...,15 = 0. Sum = 8."""
    var v = SIMD[DType.uint8, 16](0)
    for i in range(8):
        v[i * 2] = UInt8(1)
    assert_equal(hadd_u8x16(v), UInt8(8))
    assert_equal(hadd_widening_u8x16(v), UInt16(8))


def test_hadd_u8x16_iota() raises:
    """Lanes 0..15. Sum = 0+1+...+15 = 120 = 0x78. No truncation."""
    var v = SIMD[DType.uint8, 16](0)
    for i in range(16):
        v[i] = UInt8(i)
    assert_equal(hadd_u8x16(v), UInt8(120))
    assert_equal(hadd_widening_u8x16(v), UInt16(120))


def test_hadd_u16x8_all_zero() raises:
    var v = SIMD[DType.uint16, 8](0)
    assert_equal(hadd_u16x8(v), UInt16(0))


def test_hadd_u16x8_all_max() raises:
    """All 8 lanes = 0xFFFF. Truncated sum: 8 * 0xFFFF = 0x7FFF8 mod 0x10000 = 0xFFF8."""
    var v = SIMD[DType.uint16, 8](0xFFFF)
    assert_equal(hadd_u16x8(v), UInt16(0xFFF8))


def test_hadd_u16x8_single_lane_set() raises:
    for lane in range(8):
        var v = SIMD[DType.uint16, 8](0)
        v[lane] = UInt16(0x1234)
        assert_equal(hadd_u16x8(v), UInt16(0x1234))


def test_hadd_u16x8_alternating() raises:
    """Lanes 0,2,4,6 = 0x100; others = 0. Sum = 0x400."""
    var v = SIMD[DType.uint16, 8](0)
    for i in range(4):
        v[i * 2] = UInt16(0x100)
    assert_equal(hadd_u16x8(v), UInt16(0x400))


def test_hadd_u32x4_all_zero() raises:
    var v = SIMD[DType.uint32, 4](0)
    assert_equal(hadd_u32x4(v), UInt32(0))


def test_hadd_u32x4_all_max() raises:
    """All 4 lanes = 0xFFFFFFFF. Truncated sum: 4 * 0xFFFFFFFF mod 2^32 = 0xFFFFFFFC."""
    var v = SIMD[DType.uint32, 4](0xFFFFFFFF)
    assert_equal(hadd_u32x4(v), UInt32(0xFFFFFFFC))


def test_hadd_u32x4_single_lane_set() raises:
    for lane in range(4):
        var v = SIMD[DType.uint32, 4](0)
        v[lane] = UInt32(0xDEADBEEF)
        assert_equal(hadd_u32x4(v), UInt32(0xDEADBEEF))


def test_hadd_u32x4_iota() raises:
    """Lanes 0, 1, 2, 3. Sum = 6."""
    var v = SIMD[DType.uint32, 4](0)
    for i in range(4):
        v[i] = UInt32(i)
    assert_equal(hadd_u32x4(v), UInt32(6))


# =============================================================================
# Cross-wrapper consistency: hadd_widening_u8x16 (no trunc) vs hadd_u8x16
# (mod 256). Verify the mathematical relationship `wide mod 256 == narrow`.
# =============================================================================


def test_hadd_widening_matches_narrow_mod_256() raises:
    """For any u8x16 input, hadd_widening_u8x16(v) mod 256 == hadd_u8x16(v)."""
    seed(0xE5_F6_07_18)
    for _ in range(1000):
        var v = _make_random_u8x16(0)
        var wide = hadd_widening_u8x16(v)
        var narrow = hadd_u8x16(v)
        # Widening result is u16; truncate to u8 by masking.
        var wide_trunc = UInt8(Int(wide) & 0xFF)
        assert_equal(wide_trunc, narrow)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
