# =============================================================================
# Per-lane + mask popcount round-trip tests for the SIMD popcount primitives
# in `komira_core.simd.popcount`.
# =============================================================================
#
# Coverage:
#   1. Round-trip: each wrapper must be byte-identical to a scalar
#      reference popcount on 10K randomized inputs. Catches both stdlib
#      `pop_count(SIMD)` lowering bugs (would silently emit wrong opcode)
#      and per-DType width mismatches.
#   2. Edge cases per primitive: all-zero, all-ones, sign-bit-only,
#      single-bit-set per lane.
#   3. Cross-DType coverage: popcount_u8xW (W=16 NEON / W=64 AVX-512),
#      popcount_u16xW (W=8 NEON), popcount_u32xW (W=4 NEON), popcount_u64xW
#      (W=2 NEON).
#   4. Bool-mask popcount: round-trip vs scalar oracle + edge cases.
#
# All scalar references walk lanes 0..W-1 in order, emitting
# `_scalar_popcount(v[k])` to `out[k]`. Independent implementation from
# the stdlib lowering so the SIMD path can be cross-checked against an
# oracle that doesn't share any codegen with the production module.
# =============================================================================

from std.bit import pop_count
from std.random import random_si64, seed
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.simd.popcount import (
    popcount_u8xW,
    popcount_u16xW,
    popcount_u32xW,
    popcount_u64xW,
    popcount_mask,
)


comptime ITERS: Int = 10_000


# =============================================================================
# Scalar reference popcounts (oracle for the round-trip tests).
# =============================================================================
#
# We use the SCALAR `pop_count` from std.bit on each lane individually,
# which is a different codegen path from `pop_count(SIMD[T, W])` (scalar
# `popcnt` instruction vs vector `cnt`/`vpopcntb` family). This is the
# independent-oracle property — a bug in the SIMD lowering does not also
# break the scalar lowering.
# =============================================================================


def _ref_popcount_u8[W: Int](v: SIMD[DType.uint8, W]) -> SIMD[DType.uint8, W]:
    var out = SIMD[DType.uint8, W](0)
    for k in range(W):
        out[k] = pop_count(v[k])
    return out


def _ref_popcount_u16[W: Int](
    v: SIMD[DType.uint16, W]
) -> SIMD[DType.uint16, W]:
    var out = SIMD[DType.uint16, W](0)
    for k in range(W):
        out[k] = pop_count(v[k])
    return out


def _ref_popcount_u32[W: Int](
    v: SIMD[DType.uint32, W]
) -> SIMD[DType.uint32, W]:
    var out = SIMD[DType.uint32, W](0)
    for k in range(W):
        out[k] = pop_count(v[k])
    return out


def _ref_popcount_u64[W: Int](
    v: SIMD[DType.uint64, W]
) -> SIMD[DType.uint64, W]:
    var out = SIMD[DType.uint64, W](0)
    for k in range(W):
        out[k] = pop_count(v[k])
    return out


def _ref_popcount_mask[W: Int](mask: SIMD[DType.bool, W]) -> Int:
    """Scalar reference: walks lanes in order, counts `True`s with a Python
    loop. Independent of `cast[uint8]().reduce_add()` codegen.
    """
    var c: Int = 0
    for k in range(W):
        if mask[k]:
            c = c + 1
    return c


# =============================================================================
# Test helpers — assert two SIMD popcount results match the ref lane-by-lane.
# =============================================================================


def _assert_popcount_u8_matches[W: Int](
    got: SIMD[DType.uint8, W],
    expect: SIMD[DType.uint8, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_popcount_u16_matches[W: Int](
    got: SIMD[DType.uint16, W],
    expect: SIMD[DType.uint16, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_popcount_u32_matches[W: Int](
    got: SIMD[DType.uint32, W],
    expect: SIMD[DType.uint32, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_popcount_u64_matches[W: Int](
    got: SIMD[DType.uint64, W],
    expect: SIMD[DType.uint64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


# =============================================================================
# Random input builders.
# =============================================================================


def _make_random_u8_x16() -> SIMD[DType.uint8, 16]:
    var v = SIMD[DType.uint8, 16](0)
    for k in range(16):
        # Range 0..255 inclusive; random_si64 endpoints are inclusive.
        var r = random_si64(0, 255)
        v[k] = UInt8(Int(r))
    return v


def _make_random_u16_x8() -> SIMD[DType.uint16, 8]:
    var v = SIMD[DType.uint16, 8](0)
    for k in range(8):
        var r = random_si64(0, 65_535)
        v[k] = UInt16(Int(r))
    return v


def _make_random_u32_x4() -> SIMD[DType.uint32, 4]:
    var v = SIMD[DType.uint32, 4](0)
    for k in range(4):
        # 0..4G-1; sample as two halves to avoid overflow on Int.
        var hi = random_si64(0, 65_535)
        var lo = random_si64(0, 65_535)
        v[k] = (UInt32(Int(hi)) << UInt32(16)) | UInt32(Int(lo))
    return v


def _make_random_u64_x2() -> SIMD[DType.uint64, 2]:
    var v = SIMD[DType.uint64, 2](0)
    for k in range(2):
        # Four 16-bit chunks to build a uniform random u64.
        var c0 = random_si64(0, 65_535)
        var c1 = random_si64(0, 65_535)
        var c2 = random_si64(0, 65_535)
        var c3 = random_si64(0, 65_535)
        v[k] = (
            (UInt64(Int(c3)) << UInt64(48))
            | (UInt64(Int(c2)) << UInt64(32))
            | (UInt64(Int(c1)) << UInt64(16))
            | UInt64(Int(c0))
        )
    return v


def _make_random_bool_x16() -> SIMD[DType.bool, 16]:
    var v = SIMD[DType.bool, 16](fill=False)
    for k in range(16):
        var r = random_si64(0, 1)
        v[k] = r == 1
    return v


def _make_random_bool_x8() -> SIMD[DType.bool, 8]:
    var v = SIMD[DType.bool, 8](fill=False)
    for k in range(8):
        var r = random_si64(0, 1)
        v[k] = r == 1
    return v


# =============================================================================
# Round-trip vs scalar reference (10K random inputs per primitive).
#
# Every wrapper is cross-checked against a scalar oracle that walks
# lanes independently. The SIMD path lowers to NEON `cnt.16b` (or
# `vpopcntb` family on AVX-512 BITALG); the scalar oracle lowers to the
# scalar `popcnt` family. A bug in either path is caught by the byte-
# identical assertion.
# =============================================================================


def test_popcount_u8x16_round_trip_random() raises:
    """popcount_u8xW(W=16) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xA1_B2_C3_D4)
    for _ in range(ITERS):
        var v = _make_random_u8_x16()
        var got = popcount_u8xW(v)
        var expect = _ref_popcount_u8[16](v)
        _assert_popcount_u8_matches[16](got, expect)


def test_popcount_u16x8_round_trip_random() raises:
    """popcount_u16xW(W=8) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xB2_C3_D4_E5)
    for _ in range(ITERS):
        var v = _make_random_u16_x8()
        var got = popcount_u16xW(v)
        var expect = _ref_popcount_u16[8](v)
        _assert_popcount_u16_matches[8](got, expect)


def test_popcount_u32x4_round_trip_random() raises:
    """popcount_u32xW(W=4) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xC3_D4_E5_F6)
    for _ in range(ITERS):
        var v = _make_random_u32_x4()
        var got = popcount_u32xW(v)
        var expect = _ref_popcount_u32[4](v)
        _assert_popcount_u32_matches[4](got, expect)


def test_popcount_u64x2_round_trip_random() raises:
    """popcount_u64xW(W=2) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xD4_E5_F6_07)
    for _ in range(ITERS):
        var v = _make_random_u64_x2()
        var got = popcount_u64xW(v)
        var expect = _ref_popcount_u64[2](v)
        _assert_popcount_u64_matches[2](got, expect)


def test_popcount_mask_x16_round_trip_random() raises:
    """popcount_mask(W=16) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xE5_F6_07_18)
    for _ in range(ITERS):
        var v = _make_random_bool_x16()
        var got = popcount_mask(v)
        var expect = _ref_popcount_mask[16](v)
        assert_equal(got, expect)


def test_popcount_mask_x8_round_trip_random() raises:
    """popcount_mask(W=8) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xF6_07_18_29)
    for _ in range(ITERS):
        var v = _make_random_bool_x8()
        var got = popcount_mask(v)
        var expect = _ref_popcount_mask[8](v)
        assert_equal(got, expect)


# =============================================================================
# Edge cases — all-zero, all-ones, sign-bit, single-bit-set sweep.
# =============================================================================


# u8 W=16


def test_popcount_u8x16_all_zero() raises:
    """All-zero lanes: every output lane is 0."""
    var v = SIMD[DType.uint8, 16](0)
    var got = popcount_u8xW(v)
    for k in range(16):
        assert_equal(got[k], UInt8(0))


def test_popcount_u8x16_all_ones() raises:
    """All-0xFF lanes: every output lane is 8."""
    var v = SIMD[DType.uint8, 16](255)
    var got = popcount_u8xW(v)
    for k in range(16):
        assert_equal(got[k], UInt8(8))


def test_popcount_u8x16_sign_bit_only() raises:
    """0x80 lanes (sign bit only): every output lane is 1."""
    var v = SIMD[DType.uint8, 16](0x80)
    var got = popcount_u8xW(v)
    for k in range(16):
        assert_equal(got[k], UInt8(1))


def test_popcount_u8x16_single_bit_sweep() raises:
    """For each bit position B (0..7), set only bit B in lane 0; lane 0 = 1."""
    for B in range(8):
        var v = SIMD[DType.uint8, 16](0)
        v[0] = UInt8(1) << UInt8(B)
        var got = popcount_u8xW(v)
        assert_equal(got[0], UInt8(1))
        for k in range(1, 16):
            assert_equal(got[k], UInt8(0))


# u16 W=8


def test_popcount_u16x8_all_zero() raises:
    var v = SIMD[DType.uint16, 8](0)
    var got = popcount_u16xW(v)
    for k in range(8):
        assert_equal(got[k], UInt16(0))


def test_popcount_u16x8_all_ones() raises:
    var v = SIMD[DType.uint16, 8](0xFFFF)
    var got = popcount_u16xW(v)
    for k in range(8):
        assert_equal(got[k], UInt16(16))


def test_popcount_u16x8_high_byte_only() raises:
    """0xFF00 lanes (high byte all-ones): every output lane is 8."""
    var v = SIMD[DType.uint16, 8](0xFF00)
    var got = popcount_u16xW(v)
    for k in range(8):
        assert_equal(got[k], UInt16(8))


# u32 W=4


def test_popcount_u32x4_all_zero() raises:
    var v = SIMD[DType.uint32, 4](0)
    var got = popcount_u32xW(v)
    for k in range(4):
        assert_equal(got[k], UInt32(0))


def test_popcount_u32x4_all_ones() raises:
    var v = SIMD[DType.uint32, 4](0xFFFFFFFF)
    var got = popcount_u32xW(v)
    for k in range(4):
        assert_equal(got[k], UInt32(32))


def test_popcount_u32x4_alternating_bits() raises:
    """0xAAAA_AAAA lane (every other bit set): output is 16."""
    var v = SIMD[DType.uint32, 4](0xAAAAAAAA)
    var got = popcount_u32xW(v)
    for k in range(4):
        assert_equal(got[k], UInt32(16))


def test_popcount_u32x4_distinct_per_lane() raises:
    """Each lane holds a different value; output must match per-lane oracle."""
    var v = SIMD[DType.uint32, 4](0, 1, 0xFFFFFFFF, 0xCAFEBABE)
    var got = popcount_u32xW(v)
    assert_equal(got[0], UInt32(0))
    assert_equal(got[1], UInt32(1))
    assert_equal(got[2], UInt32(32))
    # popcount(0xCAFEBABE) = 22 (binary: 1100 1010 1111 1110 1011 1010 1011 1110)
    assert_equal(got[3], UInt32(22))


# u64 W=2


def test_popcount_u64x2_all_zero() raises:
    var v = SIMD[DType.uint64, 2](0)
    var got = popcount_u64xW(v)
    for k in range(2):
        assert_equal(got[k], UInt64(0))


def test_popcount_u64x2_all_ones() raises:
    var v = SIMD[DType.uint64, 2](0xFFFFFFFF_FFFFFFFF)
    var got = popcount_u64xW(v)
    for k in range(2):
        assert_equal(got[k], UInt64(64))


def test_popcount_u64x2_high_low_split() raises:
    """Lane 0: high 32 bits all-ones; lane 1: low 32 bits all-ones."""
    var v = SIMD[DType.uint64, 2](0xFFFFFFFF_00000000, 0x00000000_FFFFFFFF)
    var got = popcount_u64xW(v)
    assert_equal(got[0], UInt64(32))
    assert_equal(got[1], UInt64(32))


def test_popcount_u64x2_sign_bit_only() raises:
    """0x8000_0000_0000_0000 lanes (only sign bit): every output lane is 1."""
    var v = SIMD[DType.uint64, 2](0x80000000_00000000)
    var got = popcount_u64xW(v)
    for k in range(2):
        assert_equal(got[k], UInt64(1))


# Mask popcount edge cases.


def test_popcount_mask_x16_all_false() raises:
    var v = SIMD[DType.bool, 16](fill=False)
    assert_equal(popcount_mask(v), 0)


def test_popcount_mask_x16_all_true() raises:
    var v = SIMD[DType.bool, 16](fill=True)
    assert_equal(popcount_mask(v), 16)


def test_popcount_mask_x16_single_lane_sweep() raises:
    """For each lane L set only that lane True; total count = 1."""
    for L in range(16):
        var v = SIMD[DType.bool, 16](fill=False)
        v[L] = True
        assert_equal(popcount_mask(v), 1)


def test_popcount_mask_x8_alternating() raises:
    """Alternating True/False lanes (W=8): total count = 4."""
    var v = SIMD[DType.bool, 8](
        True, False, True, False, True, False, True, False
    )
    assert_equal(popcount_mask(v), 4)


def test_popcount_mask_x4_all_true() raises:
    var v = SIMD[DType.bool, 4](fill=True)
    assert_equal(popcount_mask(v), 4)


def test_popcount_mask_x2_one_true() raises:
    var v = SIMD[DType.bool, 2](True, False)
    assert_equal(popcount_mask(v), 1)


# =============================================================================
# Cross-primitive composition smoke (popcount + reduce_add).
# =============================================================================


def test_popcount_u8x16_then_reduce_add() raises:
    """The canonical bitmap-walk pattern: popcount per chunk, sum across.

    Validates the SIMD popcount output is usable as input to the next
    SIMD op (reduce_add), which is how `_simd_popcount_bytes` works in
    bitmap.mojo.
    """
    # 16 lanes each with 4 set bits = 64 total set bits.
    var v = SIMD[DType.uint8, 16](0x0F)
    var cnts = popcount_u8xW(v)
    var total = cnts.reduce_add()
    assert_equal(Int(total), 64)


def test_popcount_mask_drives_selection_advance() raises:
    """The canonical filter-emission pattern: build mask, popcount, advance.

    Validates popcount_mask returns the right cardinality for advancing
    a selection-vector cursor, the way AdaptiveFilter / ExpressionExecutor
    use it.
    """
    # Build a mask with 5 True lanes out of 16.
    var mask = SIMD[DType.bool, 16](
        True, True, True, False, False, False, True, False,
        True, False, False, False, False, False, False, False
    )
    var n_keep = popcount_mask(mask)
    assert_equal(n_keep, 5)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
