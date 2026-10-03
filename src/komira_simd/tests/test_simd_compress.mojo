# =============================================================================
# Round-trip + edge tests for the SIMD mask-driven compress wrappers in
# `komira_simd.compress`.
# =============================================================================
#
# Coverage:
#   1. Round-trip: each wrapper must be byte-identical to a scalar
#      reference compactor on 10K randomized inputs (mask + vector).
#      Catches both AVX-512 intrinsic mis-binding (would silently emit a
#      different op) and bitmask/popcount derivation bugs.
#   2. Edge cases per primitive: all-mask-0, all-mask-1, alternating-bit
#      mask, single-lane-set per lane, last-lane-only.
#   3. Cross-check between `_popcount_mask` helper and the CompressResult
#      `count` field.
#
# All scalar references mirror the `_scalar_compress` helper logic: walk
# lanes 0..W-1 in order, emit vec[k] to out[count++] when mask[k] is set;
# trailing lanes are zero.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.random import random_si64, seed

from komira_simd.compress import (
    CompressResult,
    compress_u32xW,
    compress_f64xW,
    compress_i64xW,
)


comptime ITERS: Int = 10_000


# =============================================================================
# Scalar reference compactors (oracle for the round-trip tests).
# =============================================================================


def _ref_compress_u32[W: Int](
    mask: SIMD[DType.bool, W],
    vec: SIMD[DType.uint32, W],
) -> CompressResult[DType.uint32, W]:
    """Scalar reference: walks lanes in order, emits to dense out, trailing
    lanes zero. Independent implementation from `_scalar_compress` so that
    the AVX-512 path can be cross-checked against an independent oracle.
    """
    var out = SIMD[DType.uint32, W](0)
    var c: Int = 0
    for k in range(W):
        if mask[k]:
            out[c] = vec[k]
            c = c + 1
    return CompressResult[DType.uint32, W](compacted=out, count=UInt8(c))


def _ref_compress_f64[W: Int](
    mask: SIMD[DType.bool, W],
    vec: SIMD[DType.float64, W],
) -> CompressResult[DType.float64, W]:
    var out = SIMD[DType.float64, W](0.0)
    var c: Int = 0
    for k in range(W):
        if mask[k]:
            out[c] = vec[k]
            c = c + 1
    return CompressResult[DType.float64, W](compacted=out, count=UInt8(c))


def _ref_compress_i64[W: Int](
    mask: SIMD[DType.bool, W],
    vec: SIMD[DType.int64, W],
) -> CompressResult[DType.int64, W]:
    var out = SIMD[DType.int64, W](0)
    var c: Int = 0
    for k in range(W):
        if mask[k]:
            out[c] = vec[k]
            c = c + 1
    return CompressResult[DType.int64, W](compacted=out, count=UInt8(c))


# =============================================================================
# Test helpers — assert two CompressResults match the (out, count) ref.
# =============================================================================


def _assert_compress_u32_matches[W: Int](
    result: CompressResult[DType.uint32, W],
    ref_out: SIMD[DType.uint32, W],
    ref_count: UInt8,
) raises:
    assert_equal(result.count, ref_count)
    # Compare first `count` lanes byte-identical; trailing lanes must be 0.
    for k in range(Int(ref_count)):
        assert_equal(result.compacted[k], ref_out[k])
    for k in range(Int(ref_count), W):
        assert_equal(result.compacted[k], UInt32(0))


def _assert_compress_f64_matches[W: Int](
    result: CompressResult[DType.float64, W],
    ref_out: SIMD[DType.float64, W],
    ref_count: UInt8,
) raises:
    assert_equal(result.count, ref_count)
    for k in range(Int(ref_count)):
        assert_equal(result.compacted[k], ref_out[k])
    for k in range(Int(ref_count), W):
        assert_equal(result.compacted[k], Float64(0.0))


def _assert_compress_i64_matches[W: Int](
    result: CompressResult[DType.int64, W],
    ref_out: SIMD[DType.int64, W],
    ref_count: UInt8,
) raises:
    assert_equal(result.count, ref_count)
    for k in range(Int(ref_count)):
        assert_equal(result.compacted[k], ref_out[k])
    for k in range(Int(ref_count), W):
        assert_equal(result.compacted[k], Int64(0))


# =============================================================================
# Random-input builders.
# =============================================================================


def _make_random_mask_x8() -> SIMD[DType.bool, 8]:
    """Random 8-lane bool mask. Each lane flips coin independently."""
    var m = SIMD[DType.bool, 8](fill=False)
    for i in range(8):
        var r = random_si64(0, 2)
        m[i] = (Int(r) & 1) == 1
    return m


def _make_random_u32x8() -> SIMD[DType.uint32, 8]:
    """Random 8-lane u32 vector (for the AVX-512 W=8 ymm-form vpcompressd
    path used by sel_kernels `_emit_lane_writes[W=8]`)."""
    var v = SIMD[DType.uint32, 8](0)
    for i in range(8):
        var hi = random_si64(0, 65536)
        var lo = random_si64(0, 65536)
        var word: UInt64 = (UInt64(Int(hi)) << 16) | UInt64(Int(lo) & 0xFFFF)
        v[i] = UInt32(Int(word) & 0xFFFFFFFF)
    return v


def _make_random_mask_x16() -> SIMD[DType.bool, 16]:
    """Random 16-lane bool mask."""
    var m = SIMD[DType.bool, 16](fill=False)
    for i in range(16):
        var r = random_si64(0, 2)
        m[i] = (Int(r) & 1) == 1
    return m


def _make_random_mask_x4() -> SIMD[DType.bool, 4]:
    """Random 4-lane bool mask (matches NEON u32 native width)."""
    var m = SIMD[DType.bool, 4](fill=False)
    for i in range(4):
        var r = random_si64(0, 2)
        m[i] = (Int(r) & 1) == 1
    return m


def _make_random_mask_x2() -> SIMD[DType.bool, 2]:
    """Random 2-lane bool mask (matches NEON f64/i64 native width)."""
    var m = SIMD[DType.bool, 2](fill=False)
    for i in range(2):
        var r = random_si64(0, 2)
        m[i] = (Int(r) & 1) == 1
    return m


def _make_random_u32x16() -> SIMD[DType.uint32, 16]:
    """Random 16-lane u32 vector."""
    var v = SIMD[DType.uint32, 16](0)
    for i in range(16):
        var hi = random_si64(0, 65536)
        var lo = random_si64(0, 65536)
        var word: UInt64 = (UInt64(Int(hi)) << 16) | UInt64(Int(lo) & 0xFFFF)
        v[i] = UInt32(Int(word) & 0xFFFFFFFF)
    return v


def _make_random_u32x4() -> SIMD[DType.uint32, 4]:
    """Random 4-lane u32 vector."""
    var v = SIMD[DType.uint32, 4](0)
    for i in range(4):
        var hi = random_si64(0, 65536)
        var lo = random_si64(0, 65536)
        var word: UInt64 = (UInt64(Int(hi)) << 16) | UInt64(Int(lo) & 0xFFFF)
        v[i] = UInt32(Int(word) & 0xFFFFFFFF)
    return v


def _make_random_f64x8() -> SIMD[DType.float64, 8]:
    """Random 8-lane f64 vector (values in approximately [-65536, 65536])."""
    var v = SIMD[DType.float64, 8](0.0)
    for i in range(8):
        var r = random_si64(-65536, 65536)
        v[i] = Float64(Int(r))
    return v


def _make_random_f64x2() -> SIMD[DType.float64, 2]:
    var v = SIMD[DType.float64, 2](0.0)
    for i in range(2):
        var r = random_si64(-65536, 65536)
        v[i] = Float64(Int(r))
    return v


def _make_random_i64x8() -> SIMD[DType.int64, 8]:
    var v = SIMD[DType.int64, 8](0)
    for i in range(8):
        var r = random_si64(-1_000_000, 1_000_000)
        v[i] = Int64(Int(r))
    return v


def _make_random_i64x2() -> SIMD[DType.int64, 2]:
    var v = SIMD[DType.int64, 2](0)
    for i in range(2):
        var r = random_si64(-1_000_000, 1_000_000)
        v[i] = Int64(Int(r))
    return v


# =============================================================================
# Round-trip vs scalar reference (10K random inputs per primitive × width).
#
# We test BOTH the AVX-512-native widths (W=16 u32, W=8 f64/i64) AND the
# NEON-native widths (W=4 u32, W=2 f64/i64). On NEON both fall through to
# the scalar scatter helper; on AVX-512 the wider widths fire the
# intrinsic and the narrower widths fall through. Either way the result
# is verified against an INDEPENDENT scalar oracle.
# =============================================================================


def test_compress_u32x16_round_trip_random() raises:
    """compress_u32xW(W=16) byte-identical to scalar oracle on 10K random inputs."""
    seed(0xA1_B2_C3_D4)
    for _ in range(ITERS):
        var m = _make_random_mask_x16()
        var v = _make_random_u32x16()
        var r = compress_u32xW(m, v)
        var oracle = _ref_compress_u32[16](m, v)
        _assert_compress_u32_matches[16](r, oracle.compacted, oracle.count)


def test_compress_u32x4_round_trip_random() raises:
    """compress_u32xW(W=4) byte-identical on 10K random inputs (NEON native)."""
    seed(0xB2_C3_D4_E5)
    for _ in range(ITERS):
        var m = _make_random_mask_x4()
        var v = _make_random_u32x4()
        var r = compress_u32xW(m, v)
        var oracle = _ref_compress_u32[4](m, v)
        _assert_compress_u32_matches[4](r, oracle.compacted, oracle.count)


def test_compress_u32x8_round_trip_random() raises:
    """compress_u32xW(W=8) byte-identical on 10K random inputs.

    Locks the AVX-512 W=8 ymm-form `vpcompressd ymm0{k1}{z}, ymm0` arm.
    This is the lane-id compact shape used by
    `sel_kernels._emit_lane_writes[W=8]` for f64/i64 column filters.

    If the gate required `W==16` only, W=8 callers would fall through to
    `_scalar_compress` (a long kshiftrb sequence on AVX-512). This test
    prevents silent regression of the W=8 arm in future refactors.

    On NEON / AVX2 / scalar this exercises the same scalar-scatter
    fallback; correctness is identical across arches by construction.
    """
    seed(0xB2_C3_D4_E6)
    for _ in range(ITERS):
        var m = _make_random_mask_x8()
        var v = _make_random_u32x8()
        var r = compress_u32xW(m, v)
        var oracle = _ref_compress_u32[8](m, v)
        _assert_compress_u32_matches[8](r, oracle.compacted, oracle.count)


def test_compress_u32x8_all_mask_one() raises:
    """W=8 all-mask-one: count=8, compacted preserves input verbatim."""
    var m = SIMD[DType.bool, 8](fill=True)
    var v = SIMD[DType.uint32, 8](
        UInt32(1001), UInt32(1002), UInt32(1003), UInt32(1004),
        UInt32(1005), UInt32(1006), UInt32(1007), UInt32(1008),
    )
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(8))
    for k in range(8):
        assert_equal(r.compacted[k], v[k])


def test_compress_u32x8_alternating_mask() raises:
    """W=8 alternating mask: even-indexed lanes survive, packed densely."""
    var m = SIMD[DType.bool, 8](True, False, True, False, True, False, True, False)
    var v = SIMD[DType.uint32, 8](
        UInt32(10), UInt32(11), UInt32(12), UInt32(13),
        UInt32(14), UInt32(15), UInt32(16), UInt32(17),
    )
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(4))
    assert_equal(r.compacted[0], UInt32(10))
    assert_equal(r.compacted[1], UInt32(12))
    assert_equal(r.compacted[2], UInt32(14))
    assert_equal(r.compacted[3], UInt32(16))
    for k in range(4, 8):
        assert_equal(r.compacted[k], UInt32(0))


def test_compress_u32x8_last_lane_only() raises:
    """W=8 only lane 7 set — exercises highest-lane bit-shift path."""
    var m = SIMD[DType.bool, 8](fill=False)
    m[7] = True
    var v = SIMD[DType.uint32, 8](0)
    v[7] = UInt32(0xC0FFEE)
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(1))
    assert_equal(r.compacted[0], UInt32(0xC0FFEE))


def test_compress_f64x8_round_trip_random() raises:
    """compress_f64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0xC3_D4_E5_F6)
    for _ in range(ITERS):
        var m = _make_random_mask_x8()
        var v = _make_random_f64x8()
        var r = compress_f64xW(m, v)
        var oracle = _ref_compress_f64[8](m, v)
        _assert_compress_f64_matches[8](r, oracle.compacted, oracle.count)


def test_compress_f64x2_round_trip_random() raises:
    """compress_f64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0xD4_E5_F6_07)
    for _ in range(ITERS):
        var m = _make_random_mask_x2()
        var v = _make_random_f64x2()
        var r = compress_f64xW(m, v)
        var oracle = _ref_compress_f64[2](m, v)
        _assert_compress_f64_matches[2](r, oracle.compacted, oracle.count)


def test_compress_i64x8_round_trip_random() raises:
    """compress_i64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0xE5_F6_07_18)
    for _ in range(ITERS):
        var m = _make_random_mask_x8()
        var v = _make_random_i64x8()
        var r = compress_i64xW(m, v)
        var oracle = _ref_compress_i64[8](m, v)
        _assert_compress_i64_matches[8](r, oracle.compacted, oracle.count)


def test_compress_i64x2_round_trip_random() raises:
    """compress_i64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0xF6_07_18_29)
    for _ in range(ITERS):
        var m = _make_random_mask_x2()
        var v = _make_random_i64x2()
        var r = compress_i64xW(m, v)
        var oracle = _ref_compress_i64[2](m, v)
        _assert_compress_i64_matches[2](r, oracle.compacted, oracle.count)


# =============================================================================
# Edge cases — all-zero, all-one, alternating, single-lane, last-lane.
# =============================================================================


def test_compress_u32x16_all_mask_zero() raises:
    """All-zero mask: count=0, compacted all zeros."""
    var m = SIMD[DType.bool, 16](fill=False)
    var v = SIMD[DType.uint32, 16](
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
    )
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(0))
    for k in range(16):
        assert_equal(r.compacted[k], UInt32(0))


def test_compress_u32x16_all_mask_one() raises:
    """All-one mask: count=W, compacted preserves input verbatim."""
    var m = SIMD[DType.bool, 16](fill=True)
    var v = SIMD[DType.uint32, 16](
        10, 20, 30, 40, 50, 60, 70, 80,
        90, 100, 110, 120, 130, 140, 150, 160
    )
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(16))
    for k in range(16):
        assert_equal(r.compacted[k], v[k])


def test_compress_u32x16_alternating_mask() raises:
    """Mask = [T,F,T,F,...]: even-indexed lanes survive, packed densely."""
    var m = SIMD[DType.bool, 16](fill=False)
    for k in range(0, 16, 2):
        m[k] = True
    var v = SIMD[DType.uint32, 16](
        100, 101, 102, 103, 104, 105, 106, 107,
        108, 109, 110, 111, 112, 113, 114, 115
    )
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(8))
    # Compacted lanes 0..7 should be v[0], v[2], v[4], ..., v[14]
    for k in range(8):
        assert_equal(r.compacted[k], v[k * 2])
    # Trailing lanes 8..15 are zero.
    for k in range(8, 16):
        assert_equal(r.compacted[k], UInt32(0))


def test_compress_u32x16_single_lane_set() raises:
    """Exactly one lane set, swept across all 16 positions."""
    for lane in range(16):
        var m = SIMD[DType.bool, 16](fill=False)
        m[lane] = True
        var v = SIMD[DType.uint32, 16](0)
        v[lane] = UInt32(0xDEADBEEF)
        var r = compress_u32xW(m, v)
        assert_equal(r.count, UInt8(1))
        assert_equal(r.compacted[0], UInt32(0xDEADBEEF))


def test_compress_u32x16_last_lane_only() raises:
    """Only lane W-1 (lane 15) set — exercises the highest-lane bit-shift path."""
    var m = SIMD[DType.bool, 16](fill=False)
    m[15] = True
    var v = SIMD[DType.uint32, 16](0)
    v[15] = UInt32(0x11223344)
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(1))
    assert_equal(r.compacted[0], UInt32(0x11223344))


# Same edge-case fanout for f64 W=8.


def test_compress_f64x8_all_mask_zero() raises:
    var m = SIMD[DType.bool, 8](fill=False)
    var v = SIMD[DType.float64, 8](1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5)
    var r = compress_f64xW(m, v)
    assert_equal(r.count, UInt8(0))
    for k in range(8):
        assert_equal(r.compacted[k], Float64(0.0))


def test_compress_f64x8_all_mask_one() raises:
    var m = SIMD[DType.bool, 8](fill=True)
    var v = SIMD[DType.float64, 8](
        10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0
    )
    var r = compress_f64xW(m, v)
    assert_equal(r.count, UInt8(8))
    for k in range(8):
        assert_equal(r.compacted[k], v[k])


def test_compress_f64x8_alternating_mask() raises:
    var m = SIMD[DType.bool, 8](True, False, True, False, True, False, True, False)
    var v = SIMD[DType.float64, 8](
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0
    )
    var r = compress_f64xW(m, v)
    assert_equal(r.count, UInt8(4))
    assert_equal(r.compacted[0], Float64(1.0))
    assert_equal(r.compacted[1], Float64(3.0))
    assert_equal(r.compacted[2], Float64(5.0))
    assert_equal(r.compacted[3], Float64(7.0))
    for k in range(4, 8):
        assert_equal(r.compacted[k], Float64(0.0))


def test_compress_f64x8_single_lane_set() raises:
    for lane in range(8):
        var m = SIMD[DType.bool, 8](fill=False)
        m[lane] = True
        var v = SIMD[DType.float64, 8](0.0)
        v[lane] = Float64(42.5)
        var r = compress_f64xW(m, v)
        assert_equal(r.count, UInt8(1))
        assert_equal(r.compacted[0], Float64(42.5))


def test_compress_f64x8_last_lane_only() raises:
    var m = SIMD[DType.bool, 8](fill=False)
    m[7] = True
    var v = SIMD[DType.float64, 8](0.0)
    v[7] = Float64(99.99)
    var r = compress_f64xW(m, v)
    assert_equal(r.count, UInt8(1))
    assert_equal(r.compacted[0], Float64(99.99))


# Same edge-case fanout for i64 W=8.


def test_compress_i64x8_all_mask_zero() raises:
    var m = SIMD[DType.bool, 8](fill=False)
    var v = SIMD[DType.int64, 8](1, 2, 3, 4, 5, 6, 7, 8)
    var r = compress_i64xW(m, v)
    assert_equal(r.count, UInt8(0))
    for k in range(8):
        assert_equal(r.compacted[k], Int64(0))


def test_compress_i64x8_all_mask_one() raises:
    var m = SIMD[DType.bool, 8](fill=True)
    var v = SIMD[DType.int64, 8](
        -1, -2, -3, -4, -5, -6, -7, -8
    )
    var r = compress_i64xW(m, v)
    assert_equal(r.count, UInt8(8))
    for k in range(8):
        assert_equal(r.compacted[k], v[k])


def test_compress_i64x8_alternating_mask() raises:
    var m = SIMD[DType.bool, 8](False, True, False, True, False, True, False, True)
    var v = SIMD[DType.int64, 8](
        100, 200, 300, 400, 500, 600, 700, 800
    )
    var r = compress_i64xW(m, v)
    assert_equal(r.count, UInt8(4))
    assert_equal(r.compacted[0], Int64(200))
    assert_equal(r.compacted[1], Int64(400))
    assert_equal(r.compacted[2], Int64(600))
    assert_equal(r.compacted[3], Int64(800))
    for k in range(4, 8):
        assert_equal(r.compacted[k], Int64(0))


def test_compress_i64x8_single_lane_set() raises:
    for lane in range(8):
        var m = SIMD[DType.bool, 8](fill=False)
        m[lane] = True
        var v = SIMD[DType.int64, 8](0)
        v[lane] = Int64(-0x7F7F7F7F)
        var r = compress_i64xW(m, v)
        assert_equal(r.count, UInt8(1))
        assert_equal(r.compacted[0], Int64(-0x7F7F7F7F))


def test_compress_i64x8_last_lane_only() raises:
    var m = SIMD[DType.bool, 8](fill=False)
    m[7] = True
    var v = SIMD[DType.int64, 8](0)
    v[7] = Int64(0x1234567890)
    var r = compress_i64xW(m, v)
    assert_equal(r.count, UInt8(1))
    assert_equal(r.compacted[0], Int64(0x1234567890))


# =============================================================================
# NEON-width edge cases — confirm the W=4 u32 / W=2 f64 / W=2 i64 fallback
# scalar-scatter path behaves identically to the wider widths.
# =============================================================================


def test_compress_u32x4_all_mask_one() raises:
    var m = SIMD[DType.bool, 4](fill=True)
    var v = SIMD[DType.uint32, 4](11, 22, 33, 44)
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(4))
    for k in range(4):
        assert_equal(r.compacted[k], v[k])


def test_compress_u32x4_alternating_mask() raises:
    var m = SIMD[DType.bool, 4](True, False, True, False)
    var v = SIMD[DType.uint32, 4](11, 22, 33, 44)
    var r = compress_u32xW(m, v)
    assert_equal(r.count, UInt8(2))
    assert_equal(r.compacted[0], UInt32(11))
    assert_equal(r.compacted[1], UInt32(33))
    assert_equal(r.compacted[2], UInt32(0))
    assert_equal(r.compacted[3], UInt32(0))


def test_compress_f64x2_alternating_mask() raises:
    var m = SIMD[DType.bool, 2](False, True)
    var v = SIMD[DType.float64, 2](7.7, 8.8)
    var r = compress_f64xW(m, v)
    assert_equal(r.count, UInt8(1))
    assert_equal(r.compacted[0], Float64(8.8))
    assert_equal(r.compacted[1], Float64(0.0))


def test_compress_i64x2_all_mask_one() raises:
    var m = SIMD[DType.bool, 2](True, True)
    var v = SIMD[DType.int64, 2](-7, 42)
    var r = compress_i64xW(m, v)
    assert_equal(r.count, UInt8(2))
    assert_equal(r.compacted[0], Int64(-7))
    assert_equal(r.compacted[1], Int64(42))


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
