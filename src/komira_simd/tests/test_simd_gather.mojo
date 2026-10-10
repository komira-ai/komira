# =============================================================================
# Round-trip + edge tests for the SIMD index-driven gather wrappers in
# `komira_simd.gather`.
# =============================================================================
#
# Coverage:
#   1. Round-trip: each wrapper must be byte-identical to a scalar
#      reference gather on 10K randomized inputs (base buffer + indices).
#      Catches both AVX-512 intrinsic mis-binding (would silently emit a
#      different op) and index-cast bugs (UInt32 -> Int64/Int32 widening).
#   2. Edge cases per primitive: all-zero indices, monotone-identity
#      indices, reversed, sparse-random, single-set lane sweep.
#   3. Cross-DType coverage: gather_u32xW (W=16 AVX-512, W=4 NEON-native),
#      gather_u64xW / gather_i64xW / gather_f64xW (W=8 AVX-512, W=2 NEON-native).
#
# All scalar references walk lanes 0..W-1 in order, emitting
# `base[indices[k]]` to `out[k]`. Independent implementation from any
# fallback path inside the production module so the AVX-512 intrinsic
# can be cross-checked against an oracle.
# =============================================================================

from std.random import random_si64, seed
from std.testing import TestSuite, assert_equal, assert_true

from komira_simd.gather import (
    gather_u32xW,
    gather_u64xW,
    gather_i64xW,
    gather_f64xW,
)


comptime ITERS: Int = 10_000
comptime BASE_LEN: Int = 256  # Fits any index value 0..255 we generate.


# =============================================================================
# Scalar reference gatherers (oracle for the round-trip tests).
# =============================================================================


def _ref_gather_u32[W: Int](
    imm base: List[UInt32],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.uint32, W]:
    """Scalar reference: walks lanes in order, emits `base[indices[k]]`.
    Independent implementation from `_scalar_gather` (a List subscript, not
    a raw-pointer load in a comptime-unrolled loop) so the AVX-512
    path can be cross-checked against an independent oracle.
    """
    var out = SIMD[DType.uint32, W](0)
    for k in range(W):
        out[k] = base[Int(indices[k])]
    return out


def _ref_gather_u64[W: Int](
    imm base: List[UInt64],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.uint64, W]:
    var out = SIMD[DType.uint64, W](0)
    for k in range(W):
        out[k] = base[Int(indices[k])]
    return out


def _ref_gather_i64[W: Int](
    imm base: List[Int64],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.int64, W]:
    var out = SIMD[DType.int64, W](0)
    for k in range(W):
        out[k] = base[Int(indices[k])]
    return out


def _ref_gather_f64[W: Int](
    imm base: List[Float64],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.float64, W]:
    var out = SIMD[DType.float64, W](0.0)
    for k in range(W):
        out[k] = base[Int(indices[k])]
    return out


# =============================================================================
# Test helpers — assert two SIMD results match the ref.
# =============================================================================


def _assert_gather_u32_matches[W: Int](
    got: SIMD[DType.uint32, W],
    expect: SIMD[DType.uint32, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_gather_u64_matches[W: Int](
    got: SIMD[DType.uint64, W],
    expect: SIMD[DType.uint64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_gather_i64_matches[W: Int](
    got: SIMD[DType.int64, W],
    expect: SIMD[DType.int64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


def _assert_gather_f64_matches[W: Int](
    got: SIMD[DType.float64, W],
    expect: SIMD[DType.float64, W],
) raises:
    for k in range(W):
        assert_equal(got[k], expect[k])


# =============================================================================
# Base-buffer + random-index builders.
# =============================================================================


def _make_base_u32() -> List[UInt32]:
    """Distinct-value u32 base buffer of length BASE_LEN. Each slot
    holds `0xDEAD_0000 + i` so a gather is byte-traceable on failure.
    """
    var b = List[UInt32](capacity=BASE_LEN)
    for i in range(BASE_LEN):
        b.append(UInt32(0xDEAD_0000 + i))
    return b^


def _make_base_u64() -> List[UInt64]:
    var b = List[UInt64](capacity=BASE_LEN)
    for i in range(BASE_LEN):
        b.append(UInt64(0xCAFE_F00D_0000_0000) + UInt64(i))
    return b^


def _make_base_i64() -> List[Int64]:
    var b = List[Int64](capacity=BASE_LEN)
    for i in range(BASE_LEN):
        # Mix positive and negative for sign-bit coverage.
        if i & 1 == 0:
            b.append(Int64(i * 1_000_003))
        else:
            b.append(-Int64(i * 1_000_003))
    return b^


def _make_base_f64() -> List[Float64]:
    var b = List[Float64](capacity=BASE_LEN)
    for i in range(BASE_LEN):
        # Mix integer-valued and fractional for f64 mantissa coverage.
        b.append(Float64(i) * 1.0001 - 512.0)
    return b^


def _make_random_indices_x16() -> SIMD[DType.uint32, 16]:
    """Random 16-lane u32 index vector with values in [0, BASE_LEN)."""
    var idx = SIMD[DType.uint32, 16](0)
    for i in range(16):
        var r = random_si64(0, Int64(BASE_LEN - 1))
        idx[i] = UInt32(Int(r))
    return idx


def _make_random_indices_x8() -> SIMD[DType.uint32, 8]:
    var idx = SIMD[DType.uint32, 8](0)
    for i in range(8):
        var r = random_si64(0, Int64(BASE_LEN - 1))
        idx[i] = UInt32(Int(r))
    return idx


def _make_random_indices_x4() -> SIMD[DType.uint32, 4]:
    var idx = SIMD[DType.uint32, 4](0)
    for i in range(4):
        var r = random_si64(0, Int64(BASE_LEN - 1))
        idx[i] = UInt32(Int(r))
    return idx


def _make_random_indices_x2() -> SIMD[DType.uint32, 2]:
    var idx = SIMD[DType.uint32, 2](0)
    for i in range(2):
        var r = random_si64(0, Int64(BASE_LEN - 1))
        idx[i] = UInt32(Int(r))
    return idx


# =============================================================================
# Round-trip vs scalar reference (10K random inputs per primitive × width).
#
# We test BOTH the AVX-512-native widths (W=16 u32, W=8 u64/i64/f64) AND the
# NEON-native widths (W=4 u32, W=2 u64/i64/f64). On NEON and AVX2 both fall through to
# `_scalar_gather`; on AVX-512 the wider widths fire the explicit intrinsic
# and the narrower widths fall through. Either way the result is verified
# against an INDEPENDENT scalar oracle (`_ref_gather_*`).
# =============================================================================


def test_gather_u32x16_round_trip_random() raises:
    """gather_u32xW(W=16) byte-identical to scalar oracle on 10K random inputs (AVX-512 native)."""
    seed(0xA1_B2_C3_D4)
    var base = _make_base_u32()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x16()
        var got = gather_u32xW(span, idx)
        var expect = _ref_gather_u32[16](base, idx)
        _assert_gather_u32_matches[16](got, expect)


def test_gather_u32x4_round_trip_random() raises:
    """gather_u32xW(W=4) byte-identical on 10K random inputs (NEON native)."""
    seed(0xB2_C3_D4_E5)
    var base = _make_base_u32()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x4()
        var got = gather_u32xW(span, idx)
        var expect = _ref_gather_u32[4](base, idx)
        _assert_gather_u32_matches[4](got, expect)


def test_gather_u64x8_round_trip_random() raises:
    """gather_u64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0xC3_D4_E5_F6)
    var base = _make_base_u64()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x8()
        var got = gather_u64xW(span, idx)
        var expect = _ref_gather_u64[8](base, idx)
        _assert_gather_u64_matches[8](got, expect)


def test_gather_u64x2_round_trip_random() raises:
    """gather_u64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0xD4_E5_F6_07)
    var base = _make_base_u64()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x2()
        var got = gather_u64xW(span, idx)
        var expect = _ref_gather_u64[2](base, idx)
        _assert_gather_u64_matches[2](got, expect)


def test_gather_i64x8_round_trip_random() raises:
    """gather_i64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0xE5_F6_07_18)
    var base = _make_base_i64()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x8()
        var got = gather_i64xW(span, idx)
        var expect = _ref_gather_i64[8](base, idx)
        _assert_gather_i64_matches[8](got, expect)


def test_gather_i64x2_round_trip_random() raises:
    """gather_i64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0xF6_07_18_29)
    var base = _make_base_i64()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x2()
        var got = gather_i64xW(span, idx)
        var expect = _ref_gather_i64[2](base, idx)
        _assert_gather_i64_matches[2](got, expect)


def test_gather_f64x8_round_trip_random() raises:
    """gather_f64xW(W=8) byte-identical on 10K random inputs (AVX-512 native)."""
    seed(0x07_18_29_3A)
    var base = _make_base_f64()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x8()
        var got = gather_f64xW(span, idx)
        var expect = _ref_gather_f64[8](base, idx)
        _assert_gather_f64_matches[8](got, expect)


def test_gather_f64x2_round_trip_random() raises:
    """gather_f64xW(W=2) byte-identical on 10K random inputs (NEON native)."""
    seed(0x18_29_3A_4B)
    var base = _make_base_f64()
    var span = Span(base)
    for _ in range(ITERS):
        var idx = _make_random_indices_x2()
        var got = gather_f64xW(span, idx)
        var expect = _ref_gather_f64[2](base, idx)
        _assert_gather_f64_matches[2](got, expect)


# =============================================================================
# Edge cases — all-zero, monotone-identity, reversed, sparse, single-lane.
# =============================================================================


def test_gather_u32x16_all_zero_indices() raises:
    """All-zero indices: every lane gets base[0]."""
    var base = _make_base_u32()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 16](0)
    var got = gather_u32xW(span, idx)
    for k in range(16):
        assert_equal(got[k], base[0])


def test_gather_u32x16_monotone_identity() raises:
    """Indices = [0,1,2,...,15]: result equals first 16 base elements."""
    var base = _make_base_u32()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 16](
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    )
    var got = gather_u32xW(span, idx)
    for k in range(16):
        assert_equal(got[k], base[k])


def test_gather_u32x16_reversed() raises:
    """Indices = [15,14,...,0]: result equals first 16 base elements reversed."""
    var base = _make_base_u32()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 16](
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
    )
    var got = gather_u32xW(span, idx)
    for k in range(16):
        assert_equal(got[k], base[15 - k])


def test_gather_u32x16_sparse_strided() raises:
    """Indices = [0, 8, 16, 24, ..., 120]: stride-8 sparse gather."""
    var base = _make_base_u32()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 16](
        0, 8, 16, 24, 32, 40, 48, 56,
        64, 72, 80, 88, 96, 104, 112, 120
    )
    var got = gather_u32xW(span, idx)
    for k in range(16):
        assert_equal(got[k], base[k * 8])


def test_gather_u32x16_single_lane_sweep() raises:
    """For each lane L set indices to all point at base[L]; result is all base[L]."""
    var base = _make_base_u32()
    var span = Span(base)
    for L in range(BASE_LEN):
        var idx = SIMD[DType.uint32, 16](UInt32(L))
        var got = gather_u32xW(span, idx)
        for k in range(16):
            assert_equal(got[k], base[L])


# Same edge-case fanout for u64 W=8.


def test_gather_u64x8_all_zero_indices() raises:
    var base = _make_base_u64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0)
    var got = gather_u64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[0])


def test_gather_u64x8_monotone_identity() raises:
    var base = _make_base_u64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0, 1, 2, 3, 4, 5, 6, 7)
    var got = gather_u64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[k])


def test_gather_u64x8_reversed() raises:
    var base = _make_base_u64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](7, 6, 5, 4, 3, 2, 1, 0)
    var got = gather_u64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[7 - k])


def test_gather_u64x8_sparse_strided() raises:
    var base = _make_base_u64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0, 17, 31, 63, 96, 127, 200, 255)
    var got = gather_u64xW(span, idx)
    assert_equal(got[0], base[0])
    assert_equal(got[1], base[17])
    assert_equal(got[2], base[31])
    assert_equal(got[3], base[63])
    assert_equal(got[4], base[96])
    assert_equal(got[5], base[127])
    assert_equal(got[6], base[200])
    assert_equal(got[7], base[255])


# Same edge-case fanout for i64 W=8.


def test_gather_i64x8_all_zero_indices() raises:
    var base = _make_base_i64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0)
    var got = gather_i64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[0])


def test_gather_i64x8_monotone_identity() raises:
    var base = _make_base_i64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0, 1, 2, 3, 4, 5, 6, 7)
    var got = gather_i64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[k])


def test_gather_i64x8_reversed() raises:
    var base = _make_base_i64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](7, 6, 5, 4, 3, 2, 1, 0)
    var got = gather_i64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[7 - k])


def test_gather_i64x8_negative_values_preserved() raises:
    """Sign-bit smoke: i64 base mixes pos/neg; gather must preserve sign."""
    var base = _make_base_i64()
    var span = Span(base)
    # Odd indices are negative in _make_base_i64.
    var idx = SIMD[DType.uint32, 8](1, 3, 5, 7, 9, 11, 13, 15)
    var got = gather_i64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[Int(idx[k])])
        # All odd indices map to negative values.
        assert_true(got[k] < 0)


# Same edge-case fanout for f64 W=8.


def test_gather_f64x8_all_zero_indices() raises:
    var base = _make_base_f64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0)
    var got = gather_f64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[0])


def test_gather_f64x8_monotone_identity() raises:
    var base = _make_base_f64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](0, 1, 2, 3, 4, 5, 6, 7)
    var got = gather_f64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[k])


def test_gather_f64x8_reversed() raises:
    var base = _make_base_f64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](7, 6, 5, 4, 3, 2, 1, 0)
    var got = gather_f64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[7 - k])


def test_gather_f64x8_fractional_preserved() raises:
    """f64 mantissa smoke: fractional values must round-trip bit-identical."""
    var base = _make_base_f64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 8](100, 50, 200, 75, 125, 175, 225, 250)
    var got = gather_f64xW(span, idx)
    for k in range(8):
        assert_equal(got[k], base[Int(idx[k])])


# =============================================================================
# NEON-width edge cases — confirm W=4 u32 / W=2 u64/i64/f64 scalar-fallback
# path behaves identically to the wider widths.
# =============================================================================


def test_gather_u32x4_monotone_identity() raises:
    var base = _make_base_u32()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 4](0, 1, 2, 3)
    var got = gather_u32xW(span, idx)
    for k in range(4):
        assert_equal(got[k], base[k])


def test_gather_u32x4_sparse_strided() raises:
    var base = _make_base_u32()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 4](10, 50, 100, 200)
    var got = gather_u32xW(span, idx)
    assert_equal(got[0], base[10])
    assert_equal(got[1], base[50])
    assert_equal(got[2], base[100])
    assert_equal(got[3], base[200])


def test_gather_u64x2_monotone_identity() raises:
    var base = _make_base_u64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 2](0, 1)
    var got = gather_u64xW(span, idx)
    assert_equal(got[0], base[0])
    assert_equal(got[1], base[1])


def test_gather_i64x2_negative_values_preserved() raises:
    var base = _make_base_i64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 2](1, 3)
    var got = gather_i64xW(span, idx)
    assert_equal(got[0], base[1])
    assert_equal(got[1], base[3])
    assert_true(got[0] < 0)
    assert_true(got[1] < 0)


def test_gather_f64x2_fractional_preserved() raises:
    var base = _make_base_f64()
    var span = Span(base)
    var idx = SIMD[DType.uint32, 2](100, 150)
    var got = gather_f64xW(span, idx)
    assert_equal(got[0], base[100])
    assert_equal(got[1], base[150])


# =============================================================================
# Cross-primitive composition smoke (gather + ad-hoc filter).
# =============================================================================


def test_gather_then_filter_composition() raises:
    """Smoke test the canonical `gather + ad-hoc filter` pattern that
    the `*_with_sel` kernel family uses.

    Build i64 base, gather 8 random lanes, apply `> 0` predicate, count
    survivors. Validates the gather output can be consumed by a SIMD
    comparison op (which the AVX-512 intrinsic path must produce in a
    form usable for downstream `compress_i64xW`).
    """
    seed(0xCAFE_BABE)
    var base = _make_base_i64()
    var span = Span(base)
    for _ in range(100):
        var idx = _make_random_indices_x8()
        var got = gather_i64xW(span, idx)
        # .gt() returns SIMD[Bool, W] per-lane mask (the > operator
        # returns a reduced scalar Bool, which is not subscriptable).
        var zero = SIMD[DType.int64, 8](0)
        var keep = got.gt(zero)
        var got_count: Int = 0
        for k in range(8):
            if keep[k]:
                got_count = got_count + 1
        var expect_count: Int = 0
        for k in range(8):
            if base[Int(idx[k])] > Int64(0):
                expect_count = expect_count + 1
        assert_equal(got_count, expect_count)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
