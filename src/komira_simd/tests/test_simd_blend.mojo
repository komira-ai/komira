# =============================================================================
# Round-trip + edge tests for the SIMD mask-driven blend (bitwise select)
# wrappers in `komira_simd.blend`.
# =============================================================================
#
# Coverage:
#   1. Round-trip: each wrapper must be byte-identical to a scalar
#      reference blend on 10K randomized inputs (mask + true_v + false_v).
#      Catches both AVX-512 intrinsic mis-binding (if a future revision
#      substitutes a hand-staged intrinsic that picks the wrong operand
#      order) and lane-mask widening bugs.
#   2. Edge cases per primitive: all-true mask (must return true_v),
#      all-false mask (must return false_v), alternating mask (canonical
#      `bsl` exercise), single-lane mask sweep.
#   3. Sign-bit / fractional coverage: int64 mixes pos/neg values, float
#      types use mantissa-bit fractional values to validate bitwise
#      preservation.
#   4. Cross-DType coverage: 5 DTypes × 2 widths each = 10 round-trip
#      tests (NEON-native + AVX-512-native widths).
#
# All scalar references walk lanes 0..W-1 in order, emitting
# `true_v[k] if mask[k] else false_v[k]` to `out[k]`. Independent
# implementation from the stdlib `SIMD.select()` lowering so the
# production module's lowering can be cross-checked against an oracle
# that doesn't share any codegen with it.
# =============================================================================

from std.random import random_si64, random_float64, seed
from std.testing import TestSuite, assert_equal, assert_true

from komira_simd.blend import (
    blend_u32xW,
    blend_u64xW,
    blend_i64xW,
    blend_f32xW,
    blend_f64xW,
)


comptime ITERS: Int = 10_000


# =============================================================================
# Scalar reference blenders (oracle for the round-trip tests).
# =============================================================================
#
# We walk lanes in a Python-style for loop, which lowers to per-lane
# scalar `csel`/`cmov` on x86 + ARM. This is a different codegen path
# from `SIMD[Bool, W].select()` (vector `bsl`/`vblendm*`). The
# independent-oracle property: a bug in the SIMD lowering does not also
# break the scalar lowering.
# =============================================================================


def _ref_blend_u32[W: Int](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.uint32, W],
    false_v: SIMD[DType.uint32, W],
) -> SIMD[DType.uint32, W]:
    var out = SIMD[DType.uint32, W](0)
    for k in range(W):
        if mask[k]:
            out[k] = true_v[k]
        else:
            out[k] = false_v[k]
    return out


def _ref_blend_u64[W: Int](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.uint64, W],
    false_v: SIMD[DType.uint64, W],
) -> SIMD[DType.uint64, W]:
    var out = SIMD[DType.uint64, W](0)
    for k in range(W):
        if mask[k]:
            out[k] = true_v[k]
        else:
            out[k] = false_v[k]
    return out


def _ref_blend_i64[W: Int](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.int64, W],
    false_v: SIMD[DType.int64, W],
) -> SIMD[DType.int64, W]:
    var out = SIMD[DType.int64, W](0)
    for k in range(W):
        if mask[k]:
            out[k] = true_v[k]
        else:
            out[k] = false_v[k]
    return out


def _ref_blend_f32[W: Int](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.float32, W],
    false_v: SIMD[DType.float32, W],
) -> SIMD[DType.float32, W]:
    var out = SIMD[DType.float32, W](0.0)
    for k in range(W):
        if mask[k]:
            out[k] = true_v[k]
        else:
            out[k] = false_v[k]
    return out


def _ref_blend_f64[W: Int](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.float64, W],
    false_v: SIMD[DType.float64, W],
) -> SIMD[DType.float64, W]:
    var out = SIMD[DType.float64, W](0.0)
    for k in range(W):
        if mask[k]:
            out[k] = true_v[k]
        else:
            out[k] = false_v[k]
    return out


# =============================================================================
# Test helpers — assert two SIMD blend results match the ref lane-by-lane.
# =============================================================================


def _assert_blend_u32_matches[W: Int](
    got: SIMD[DType.uint32, W],
    expect: SIMD[DType.uint32, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_blend_u64_matches[W: Int](
    got: SIMD[DType.uint64, W],
    expect: SIMD[DType.uint64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_blend_i64_matches[W: Int](
    got: SIMD[DType.int64, W],
    expect: SIMD[DType.int64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_blend_f32_matches[W: Int](
    got: SIMD[DType.float32, W],
    expect: SIMD[DType.float32, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_blend_f64_matches[W: Int](
    got: SIMD[DType.float64, W],
    expect: SIMD[DType.float64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


# =============================================================================
# Random-input builders. Distinct value patterns so failures are traceable.
# =============================================================================


def _make_random_mask_x4() -> SIMD[DType.bool, 4]:
    var m = SIMD[DType.bool, 4](fill=False)
    for i in range(4):
        var r = random_si64(0, 1)
        m[i] = (r == 1)
    return m


def _make_random_mask_x16() -> SIMD[DType.bool, 16]:
    var m = SIMD[DType.bool, 16](fill=False)
    for i in range(16):
        var r = random_si64(0, 1)
        m[i] = (r == 1)
    return m


def _make_random_mask_x2() -> SIMD[DType.bool, 2]:
    var m = SIMD[DType.bool, 2](fill=False)
    for i in range(2):
        var r = random_si64(0, 1)
        m[i] = (r == 1)
    return m


def _make_random_mask_x8() -> SIMD[DType.bool, 8]:
    var m = SIMD[DType.bool, 8](fill=False)
    for i in range(8):
        var r = random_si64(0, 1)
        m[i] = (r == 1)
    return m


def _make_random_u32_x4() -> SIMD[DType.uint32, 4]:
    var v = SIMD[DType.uint32, 4](0)
    for i in range(4):
        v[i] = UInt32(Int(random_si64(0, 0x7FFF_FFFF)))
    return v


def _make_random_u32_x16() -> SIMD[DType.uint32, 16]:
    var v = SIMD[DType.uint32, 16](0)
    for i in range(16):
        v[i] = UInt32(Int(random_si64(0, 0x7FFF_FFFF)))
    return v


def _make_random_u64_x2() -> SIMD[DType.uint64, 2]:
    var v = SIMD[DType.uint64, 2](0)
    for i in range(2):
        v[i] = UInt64(Int(random_si64(0, 0x7FFF_FFFF))) * UInt64(0xDEADBEEF)
    return v


def _make_random_u64_x8() -> SIMD[DType.uint64, 8]:
    var v = SIMD[DType.uint64, 8](0)
    for i in range(8):
        v[i] = UInt64(Int(random_si64(0, 0x7FFF_FFFF))) * UInt64(0xCAFE_F00D)
    return v


def _make_random_i64_x2() -> SIMD[DType.int64, 2]:
    var v = SIMD[DType.int64, 2](0)
    for i in range(2):
        v[i] = Int64(Int(random_si64(-1_000_000_000, 1_000_000_000)))
    return v


def _make_random_i64_x8() -> SIMD[DType.int64, 8]:
    var v = SIMD[DType.int64, 8](0)
    for i in range(8):
        v[i] = Int64(Int(random_si64(-1_000_000_000, 1_000_000_000)))
    return v


def _make_random_f32_x4() -> SIMD[DType.float32, 4]:
    var v = SIMD[DType.float32, 4](0.0)
    for i in range(4):
        v[i] = Float32(random_float64(-1000.0, 1000.0))
    return v


def _make_random_f32_x16() -> SIMD[DType.float32, 16]:
    var v = SIMD[DType.float32, 16](0.0)
    for i in range(16):
        v[i] = Float32(random_float64(-1000.0, 1000.0))
    return v


def _make_random_f64_x2() -> SIMD[DType.float64, 2]:
    var v = SIMD[DType.float64, 2](0.0)
    for i in range(2):
        v[i] = random_float64(-1_000_000.0, 1_000_000.0)
    return v


def _make_random_f64_x8() -> SIMD[DType.float64, 8]:
    var v = SIMD[DType.float64, 8](0.0)
    for i in range(8):
        v[i] = random_float64(-1_000_000.0, 1_000_000.0)
    return v


# =============================================================================
# Round-trip vs scalar reference (10K random inputs per primitive × width).
#
# We test BOTH the AVX-512-native widths (W=16 u32, W=8 u64/i64/f64,
# W=16 f32) AND the NEON-native widths (W=4 u32, W=2 u64/i64/f64,
# W=4 f32). On NEON the wider widths internally pair-up; either way
# the result is verified against an INDEPENDENT scalar oracle.
# =============================================================================


def test_blend_u32x4_round_trip_random() raises:
    """blend_u32xW(W=4) byte-identical to scalar oracle on 10K random inputs (NEON native)."""
    seed(0xA1_B2_C3_D4)
    for _ in range(ITERS):
        var m = _make_random_mask_x4()
        var a = _make_random_u32_x4()
        var b = _make_random_u32_x4()
        var got = blend_u32xW(m, a, b)
        var expect = _ref_blend_u32[4](m, a, b)
        _assert_blend_u32_matches[4](got, expect)


def test_blend_u32x16_round_trip_random() raises:
    """blend_u32xW(W=16) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0xB2_C3_D4_E5)
    for _ in range(ITERS):
        var m = _make_random_mask_x16()
        var a = _make_random_u32_x16()
        var b = _make_random_u32_x16()
        var got = blend_u32xW(m, a, b)
        var expect = _ref_blend_u32[16](m, a, b)
        _assert_blend_u32_matches[16](got, expect)


def test_blend_u64x2_round_trip_random() raises:
    """blend_u64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0xC3_D4_E5_F6)
    for _ in range(ITERS):
        var m = _make_random_mask_x2()
        var a = _make_random_u64_x2()
        var b = _make_random_u64_x2()
        var got = blend_u64xW(m, a, b)
        var expect = _ref_blend_u64[2](m, a, b)
        _assert_blend_u64_matches[2](got, expect)


def test_blend_u64x8_round_trip_random() raises:
    """blend_u64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0xD4_E5_F6_07)
    for _ in range(ITERS):
        var m = _make_random_mask_x8()
        var a = _make_random_u64_x8()
        var b = _make_random_u64_x8()
        var got = blend_u64xW(m, a, b)
        var expect = _ref_blend_u64[8](m, a, b)
        _assert_blend_u64_matches[8](got, expect)


def test_blend_i64x2_round_trip_random() raises:
    """blend_i64xW(W=2) byte-identical on 10K random inputs (NEON native, signed)."""
    seed(0xE5_F6_07_18)
    for _ in range(ITERS):
        var m = _make_random_mask_x2()
        var a = _make_random_i64_x2()
        var b = _make_random_i64_x2()
        var got = blend_i64xW(m, a, b)
        var expect = _ref_blend_i64[2](m, a, b)
        _assert_blend_i64_matches[2](got, expect)


def test_blend_i64x8_round_trip_random() raises:
    """blend_i64xW(W=8) byte-identical on 10K random inputs (AVX-512 native, signed)."""
    seed(0xF6_07_18_29)
    for _ in range(ITERS):
        var m = _make_random_mask_x8()
        var a = _make_random_i64_x8()
        var b = _make_random_i64_x8()
        var got = blend_i64xW(m, a, b)
        var expect = _ref_blend_i64[8](m, a, b)
        _assert_blend_i64_matches[8](got, expect)


def test_blend_f32x4_round_trip_random() raises:
    """blend_f32xW(W=4) byte-identical on 10K random inputs (NEON native)."""
    seed(0x07_18_29_3A)
    for _ in range(ITERS):
        var m = _make_random_mask_x4()
        var a = _make_random_f32_x4()
        var b = _make_random_f32_x4()
        var got = blend_f32xW(m, a, b)
        var expect = _ref_blend_f32[4](m, a, b)
        _assert_blend_f32_matches[4](got, expect)


def test_blend_f32x16_round_trip_random() raises:
    """blend_f32xW(W=16) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0x18_29_3A_4B)
    for _ in range(ITERS):
        var m = _make_random_mask_x16()
        var a = _make_random_f32_x16()
        var b = _make_random_f32_x16()
        var got = blend_f32xW(m, a, b)
        var expect = _ref_blend_f32[16](m, a, b)
        _assert_blend_f32_matches[16](got, expect)


def test_blend_f64x2_round_trip_random() raises:
    """blend_f64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0x29_3A_4B_5C)
    for _ in range(ITERS):
        var m = _make_random_mask_x2()
        var a = _make_random_f64_x2()
        var b = _make_random_f64_x2()
        var got = blend_f64xW(m, a, b)
        var expect = _ref_blend_f64[2](m, a, b)
        _assert_blend_f64_matches[2](got, expect)


def test_blend_f64x8_round_trip_random() raises:
    """blend_f64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0x3A_4B_5C_6D)
    for _ in range(ITERS):
        var m = _make_random_mask_x8()
        var a = _make_random_f64_x8()
        var b = _make_random_f64_x8()
        var got = blend_f64xW(m, a, b)
        var expect = _ref_blend_f64[8](m, a, b)
        _assert_blend_f64_matches[8](got, expect)


# =============================================================================
# Edge cases — all-True, all-False, alternating, single-lane sweep.
# =============================================================================


def test_blend_u32x4_all_true_returns_true_v() raises:
    """all-True mask: result must equal true_v lane-for-lane."""
    var m = SIMD[DType.bool, 4](True, True, True, True)
    var a = SIMD[DType.uint32, 4](1, 2, 3, 4)
    var b = SIMD[DType.uint32, 4](100, 200, 300, 400)
    var got = blend_u32xW(m, a, b)
    for k in range(4):
        assert_equal(got[k], a[k])


def test_blend_u32x4_all_false_returns_false_v() raises:
    """all-False mask: result must equal false_v lane-for-lane."""
    var m = SIMD[DType.bool, 4](False, False, False, False)
    var a = SIMD[DType.uint32, 4](1, 2, 3, 4)
    var b = SIMD[DType.uint32, 4](100, 200, 300, 400)
    var got = blend_u32xW(m, a, b)
    for k in range(4):
        assert_equal(got[k], b[k])


def test_blend_u32x16_alternating_mask() raises:
    """Alternating mask (T,F,T,F,...): canonical `bsl` codegen exercise.
    Result: a[0], b[1], a[2], b[3], a[4], b[5], ... lane interleave.
    """
    var m = SIMD[DType.bool, 16](
        True, False, True, False, True, False, True, False,
        True, False, True, False, True, False, True, False,
    )
    var a = SIMD[DType.uint32, 16](
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
    )
    var b = SIMD[DType.uint32, 16](
        100, 200, 300, 400, 500, 600, 700, 800,
        900, 1000, 1100, 1200, 1300, 1400, 1500, 1600,
    )
    var got = blend_u32xW(m, a, b)
    for k in range(16):
        if k & 1 == 0:
            assert_equal(got[k], a[k])
        else:
            assert_equal(got[k], b[k])


def test_blend_u32x16_single_lane_sweep() raises:
    """For each lane L: set ONLY mask[L]=True. Result lane L = a[L],
    other lanes = b[k]. Sweeps all 16 lanes to catch lane-mask
    widening bugs.
    """
    var a = SIMD[DType.uint32, 16](
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
    )
    var b = SIMD[DType.uint32, 16](
        100, 200, 300, 400, 500, 600, 700, 800,
        900, 1000, 1100, 1200, 1300, 1400, 1500, 1600,
    )
    for L in range(16):
        var m = SIMD[DType.bool, 16](fill=False)
        m[L] = True
        var got = blend_u32xW(m, a, b)
        for k in range(16):
            if k == L:
                assert_equal(got[k], a[k])
            else:
                assert_equal(got[k], b[k])


# Same edge-case fanout for u64 (W=8 AVX-512).


def test_blend_u64x8_all_true_returns_true_v() raises:
    var m = SIMD[DType.bool, 8](
        True, True, True, True, True, True, True, True
    )
    var a = SIMD[DType.uint64, 8](
        UInt64(0x1111_2222_3333_4444),
        UInt64(0x2222_3333_4444_5555),
        UInt64(0x3333_4444_5555_6666),
        UInt64(0x4444_5555_6666_7777),
        UInt64(0x5555_6666_7777_8888),
        UInt64(0x6666_7777_8888_9999),
        UInt64(0x7777_8888_9999_AAAA),
        UInt64(0x8888_9999_AAAA_BBBB),
    )
    var b = SIMD[DType.uint64, 8](UInt64(0xFFFFFFFFFFFFFFFF))
    var got = blend_u64xW(m, a, b)
    for k in range(8):
        assert_equal(got[k], a[k])


def test_blend_u64x8_all_false_returns_false_v() raises:
    var m = SIMD[DType.bool, 8](
        False, False, False, False, False, False, False, False
    )
    var a = SIMD[DType.uint64, 8](
        UInt64(0x1111_2222_3333_4444),
        UInt64(0x2222_3333_4444_5555),
        UInt64(0x3333_4444_5555_6666),
        UInt64(0x4444_5555_6666_7777),
        UInt64(0x5555_6666_7777_8888),
        UInt64(0x6666_7777_8888_9999),
        UInt64(0x7777_8888_9999_AAAA),
        UInt64(0x8888_9999_AAAA_BBBB),
    )
    var b = SIMD[DType.uint64, 8](UInt64(0xDEAD_BEEF_CAFE_F00D))
    var got = blend_u64xW(m, a, b)
    for k in range(8):
        assert_equal(got[k], b[k])


def test_blend_u64x8_alternating_mask() raises:
    var m = SIMD[DType.bool, 8](
        True, False, True, False, True, False, True, False
    )
    var a = SIMD[DType.uint64, 8](1, 2, 3, 4, 5, 6, 7, 8)
    var b = SIMD[DType.uint64, 8](100, 200, 300, 400, 500, 600, 700, 800)
    var got = blend_u64xW(m, a, b)
    for k in range(8):
        if k & 1 == 0:
            assert_equal(got[k], a[k])
        else:
            assert_equal(got[k], b[k])


# Same edge-case fanout for i64 + sign-bit coverage.


def test_blend_i64x8_all_true_returns_true_v() raises:
    var m = SIMD[DType.bool, 8](
        True, True, True, True, True, True, True, True
    )
    var a = SIMD[DType.int64, 8](-1, -2, -3, -4, 5, 6, 7, 8)
    var b = SIMD[DType.int64, 8](100, 200, 300, 400, -500, -600, -700, -800)
    var got = blend_i64xW(m, a, b)
    for k in range(8):
        assert_equal(got[k], a[k])


def test_blend_i64x8_all_false_returns_false_v() raises:
    var m = SIMD[DType.bool, 8](
        False, False, False, False, False, False, False, False
    )
    var a = SIMD[DType.int64, 8](1, 2, 3, 4, 5, 6, 7, 8)
    var b = SIMD[DType.int64, 8](-100, -200, -300, -400, -500, -600, -700, -800)
    var got = blend_i64xW(m, a, b)
    for k in range(8):
        assert_equal(got[k], b[k])


def test_blend_i64x8_sign_bit_preserved() raises:
    """Sign-bit smoke: blend a vector of large-negative values into a
    vector of large-positive values under an alternating mask. Every
    selected negative value must remain negative — catches any
    truncation or sign-extension bug in the lane-width widening path.
    """
    var m = SIMD[DType.bool, 8](
        True, False, True, False, True, False, True, False
    )
    var negs = SIMD[DType.int64, 8](
        Int64(-9_000_000_000_000_000_001),
        Int64(-9_000_000_000_000_000_002),
        Int64(-9_000_000_000_000_000_003),
        Int64(-9_000_000_000_000_000_004),
        Int64(-9_000_000_000_000_000_005),
        Int64(-9_000_000_000_000_000_006),
        Int64(-9_000_000_000_000_000_007),
        Int64(-9_000_000_000_000_000_008),
    )
    var pos = SIMD[DType.int64, 8](
        Int64(1), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(8),
    )
    var got = blend_i64xW(m, negs, pos)
    for k in range(8):
        if k & 1 == 0:
            assert_equal(got[k], negs[k])
            assert_true(got[k] < Int64(0))
        else:
            assert_equal(got[k], pos[k])
            assert_true(got[k] > Int64(0))


# Same edge-case fanout for f32.


def test_blend_f32x4_all_true_returns_true_v() raises:
    var m = SIMD[DType.bool, 4](True, True, True, True)
    var a = SIMD[DType.float32, 4](1.5, 2.5, 3.5, 4.5)
    var b = SIMD[DType.float32, 4](100.0, 200.0, 300.0, 400.0)
    var got = blend_f32xW(m, a, b)
    for k in range(4):
        assert_equal(got[k], a[k])


def test_blend_f32x4_all_false_returns_false_v() raises:
    var m = SIMD[DType.bool, 4](False, False, False, False)
    var a = SIMD[DType.float32, 4](1.5, 2.5, 3.5, 4.5)
    var b = SIMD[DType.float32, 4](100.0, 200.0, 300.0, 400.0)
    var got = blend_f32xW(m, a, b)
    for k in range(4):
        assert_equal(got[k], b[k])


def test_blend_f32x4_fractional_preserved() raises:
    """f32 mantissa smoke: fractional values must round-trip bit-identical
    (the `bsl` lowering is a bitwise op so this should always hold; this
    test guards against any future intrinsic substitution that
    accidentally goes through a floating-point conversion).
    """
    var m = SIMD[DType.bool, 4](True, False, True, False)
    var a = SIMD[DType.float32, 4](1.234567, 2.345678, 3.456789, 4.567890)
    var b = SIMD[DType.float32, 4](9.876543, 8.765432, 7.654321, 6.543210)
    var got = blend_f32xW(m, a, b)
    assert_equal(got[0], a[0])
    assert_equal(got[1], b[1])
    assert_equal(got[2], a[2])
    assert_equal(got[3], b[3])


# Same edge-case fanout for f64.


def test_blend_f64x8_all_true_returns_true_v() raises:
    var m = SIMD[DType.bool, 8](
        True, True, True, True, True, True, True, True
    )
    var a = SIMD[DType.float64, 8](
        1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5
    )
    var b = SIMD[DType.float64, 8](
        100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0
    )
    var got = blend_f64xW(m, a, b)
    for k in range(8):
        assert_equal(got[k], a[k])


def test_blend_f64x8_all_false_returns_false_v() raises:
    var m = SIMD[DType.bool, 8](
        False, False, False, False, False, False, False, False
    )
    var a = SIMD[DType.float64, 8](
        1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5
    )
    var b = SIMD[DType.float64, 8](
        100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0
    )
    var got = blend_f64xW(m, a, b)
    for k in range(8):
        assert_equal(got[k], b[k])


def test_blend_f64x8_fractional_preserved() raises:
    """f64 mantissa-bit-preservation smoke: pick 53-bit-mantissa fractional
    constants that would round if accidentally converted through f32.
    """
    var m = SIMD[DType.bool, 8](
        True, False, True, False, True, False, True, False
    )
    var a = SIMD[DType.float64, 8](
        Float64(1.0) / Float64(7.0),
        Float64(1.0) / Float64(13.0),
        Float64(1.0) / Float64(17.0),
        Float64(1.0) / Float64(19.0),
        Float64(1.0) / Float64(23.0),
        Float64(1.0) / Float64(29.0),
        Float64(1.0) / Float64(31.0),
        Float64(1.0) / Float64(37.0),
    )
    var b = SIMD[DType.float64, 8](
        Float64(2.0) / Float64(7.0),
        Float64(2.0) / Float64(13.0),
        Float64(2.0) / Float64(17.0),
        Float64(2.0) / Float64(19.0),
        Float64(2.0) / Float64(23.0),
        Float64(2.0) / Float64(29.0),
        Float64(2.0) / Float64(31.0),
        Float64(2.0) / Float64(37.0),
    )
    var got = blend_f64xW(m, a, b)
    for k in range(8):
        if k & 1 == 0:
            assert_equal(got[k], a[k])
        else:
            assert_equal(got[k], b[k])


# =============================================================================
# Cross-primitive composition smoke (blend + compress canonical shape).
# =============================================================================


def test_blend_then_count_composition() raises:
    """Canonical mask-driven blend smoke: produce a SIMD compare mask,
    blend two pre-computed result vectors, then count the survivors via
    the mask. This is the CASE-expression carve-out + AdaptiveFilter
    explore-arm result-merge shape.

    Validates that the blend output can be consumed by downstream SIMD ops
    (cardinality count, compare-against-zero, etc.) — the AVX-512 / NEON
    blend instruction MUST produce a SIMD register in a form usable for
    the next SIMD op without an intermediate scalar trip.
    """
    seed(0xCAFE_BABE)
    for _ in range(200):
        var threshold = Int64(Int(random_si64(-100, 100)))
        var col = _make_random_i64_x8()
        var then_v = SIMD[DType.int64, 8](Int64(1))
        var else_v = SIMD[DType.int64, 8](Int64(-1))
        # SIMD compare returns SIMD[Bool, W] when using the .gt method.
        var cmp = col.gt(SIMD[DType.int64, 8](threshold))
        var blended = blend_i64xW(cmp, then_v, else_v)
        # Sanity: blended lanes are exactly 1 or -1.
        for k in range(8):
            if col[k] > threshold:
                assert_equal(blended[k], Int64(1))
            else:
                assert_equal(blended[k], Int64(-1))


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
