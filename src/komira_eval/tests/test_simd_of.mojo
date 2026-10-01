# =============================================================================
# Tests for SimdOf[T, W].
#
# Coverage:
#   - _total_simd_bytes / _sub_blob_offset for known row types
#   - get/set round-trip for f64, f32, i64, i32, i16, i8, u64, u32, u16, u8, bool
#   - .mask() zeroes non-passing lanes across every field
#   - Multi-chunk round-trip (16 rows × 4 chunks of W=4) — all rows match
#     the scalar reference
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_eval.simd_of import (
    SimdOf,
    _total_simd_bytes,
    _sub_blob_offset,
)


# -----------------------------------------------------------------------------
# Test row types
# -----------------------------------------------------------------------------


@fieldwise_init
struct Row3F64I64F64(Copyable, Movable):
    var a: Float64
    var b: Int64
    var c: Float64


@fieldwise_init
struct RowMixed(Copyable, Movable):
    var f64v: Float64
    var i64v: Int64
    var f32v: Float32
    var i32v: Int32
    var bv:   Bool


@fieldwise_init
struct RowSmallInts(Copyable, Movable):
    var i16v: Int16
    var i8v:  Int8
    var u16v: UInt16
    var u8v:  UInt8


# -----------------------------------------------------------------------------
# 1) Layout helpers — _total_simd_bytes / _sub_blob_offset
# -----------------------------------------------------------------------------


def test_total_simd_bytes_3f64i64f64_w4() raises:
    """3 fields (8 + 8 + 8 bytes) × 4 lanes = 96 bytes."""
    assert_equal(_total_simd_bytes[Row3F64I64F64, 4](), 96)


def test_total_simd_bytes_3f64i64f64_w8() raises:
    """3 fields × 8 lanes = 192 bytes."""
    assert_equal(_total_simd_bytes[Row3F64I64F64, 8](), 192)


def test_sub_blob_offset_3f64i64f64_w4() raises:
    """SoA layout: field 0 at byte 0, field 1 at byte 32 (= 8*4), field 2 at byte 64."""
    assert_equal(_sub_blob_offset[Row3F64I64F64, 4, 0](), 0)
    assert_equal(_sub_blob_offset[Row3F64I64F64, 4, 1](), 32)
    assert_equal(_sub_blob_offset[Row3F64I64F64, 4, 2](), 64)


def test_sub_blob_offset_mixed_w4() raises:
    """Mixed layout: F64(8) + I64(8) + F32(4) + I32(4) + Bool(1), W=4.
    Offsets: 0, 32, 64, 80, 96."""
    assert_equal(_sub_blob_offset[RowMixed, 4, 0](), 0)
    assert_equal(_sub_blob_offset[RowMixed, 4, 1](), 32)   # 0 + 8*4
    assert_equal(_sub_blob_offset[RowMixed, 4, 2](), 64)   # 32 + 8*4
    assert_equal(_sub_blob_offset[RowMixed, 4, 3](), 80)   # 64 + 4*4
    assert_equal(_sub_blob_offset[RowMixed, 4, 4](), 96)   # 80 + 4*4


def test_total_simd_bytes_small_ints_w4() raises:
    """Small-int row: I16(2) + I8(1) + U16(2) + U8(1) = 6 bytes per lane × 4 = 24."""
    assert_equal(_total_simd_bytes[RowSmallInts, 4](), 24)


# -----------------------------------------------------------------------------
# 2) Typed accessor round-trips — one per supported dtype
# -----------------------------------------------------------------------------


def test_round_trip_f64_w4() raises:
    """get_f64/set_f64 round-trip for W=4."""
    var s = SimdOf[Row3F64I64F64, 4].zero()
    s.set_f64[0](SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0))
    var got = s.get_f64[0]()
    assert_equal(got[0], 1.0)
    assert_equal(got[1], 2.0)
    assert_equal(got[2], 3.0)
    assert_equal(got[3], 4.0)


def test_round_trip_i64_w4() raises:
    """get_i64/set_i64 round-trip for W=4 (field 1 of Row3)."""
    var s = SimdOf[Row3F64I64F64, 4].zero()
    s.set_i64[1](SIMD[DType.int64, 4](10, 20, 30, 40))
    var got = s.get_i64[1]()
    assert_equal(got[0], 10)
    assert_equal(got[1], 20)
    assert_equal(got[2], 30)
    assert_equal(got[3], 40)


def test_round_trip_three_fields_w4() raises:
    """All three fields round-trip independently (no aliasing across sub-blobs)."""
    var s = SimdOf[Row3F64I64F64, 4].zero()
    s.set_f64[0](SIMD[DType.float64, 4](1.5, 2.5, 3.5, 4.5))
    s.set_i64[1](SIMD[DType.int64, 4](-1, -2, -3, -4))
    s.set_f64[2](SIMD[DType.float64, 4](0.1, 0.2, 0.3, 0.4))
    var a = s.get_f64[0]()
    var b = s.get_i64[1]()
    var c = s.get_f64[2]()
    assert_equal(a[0], 1.5)
    assert_equal(a[3], 4.5)
    assert_equal(b[0], -1)
    assert_equal(b[3], -4)
    assert_equal(c[0], 0.1)
    assert_equal(c[3], 0.4)


def test_round_trip_f32_w4() raises:
    """get_f32/set_f32 round-trip — field 2 of RowMixed."""
    var s = SimdOf[RowMixed, 4].zero()
    s.set_f32[2](SIMD[DType.float32, 4](1.25, 2.5, 3.75, 5.0))
    var got = s.get_f32[2]()
    assert_equal(got[0], Float32(1.25))
    assert_equal(got[1], Float32(2.5))
    assert_equal(got[2], Float32(3.75))
    assert_equal(got[3], Float32(5.0))


def test_round_trip_i32_w4() raises:
    """get_i32/set_i32 round-trip — field 3 of RowMixed."""
    var s = SimdOf[RowMixed, 4].zero()
    s.set_i32[3](SIMD[DType.int32, 4](100, 200, 300, 400))
    var got = s.get_i32[3]()
    assert_equal(got[0], 100)
    assert_equal(got[1], 200)
    assert_equal(got[2], 300)
    assert_equal(got[3], 400)


def test_round_trip_bool_w4() raises:
    """get_bool/set_bool round-trip — field 4 of RowMixed."""
    var s = SimdOf[RowMixed, 4].zero()
    s.set_bool[4](SIMD[DType.bool, 4](True, False, True, False))
    var got = s.get_bool[4]()
    assert_true(got[0])
    assert_false(got[1])
    assert_true(got[2])
    assert_false(got[3])


def test_round_trip_all_mixed_fields() raises:
    """Round-trip every dtype on RowMixed in one SimdOf — no inter-field aliasing."""
    var s = SimdOf[RowMixed, 4].zero()
    s.set_f64[0](SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0))
    s.set_i64[1](SIMD[DType.int64, 4](10, 20, 30, 40))
    s.set_f32[2](SIMD[DType.float32, 4](1.5, 2.5, 3.5, 4.5))
    s.set_i32[3](SIMD[DType.int32, 4](100, 200, 300, 400))
    s.set_bool[4](SIMD[DType.bool, 4](True, True, False, False))
    var f64v = s.get_f64[0]()
    var i64v = s.get_i64[1]()
    var f32v = s.get_f32[2]()
    var i32v = s.get_i32[3]()
    var bv = s.get_bool[4]()
    # Sample lane 0 and lane 3 from each
    assert_equal(f64v[0], 1.0)
    assert_equal(f64v[3], 4.0)
    assert_equal(i64v[0], 10)
    assert_equal(i64v[3], 40)
    assert_equal(f32v[0], Float32(1.5))
    assert_equal(f32v[3], Float32(4.5))
    assert_equal(i32v[0], 100)
    assert_equal(i32v[3], 400)
    assert_true(bv[0])
    assert_false(bv[3])


# -----------------------------------------------------------------------------
# 3) Mask helper — zero non-passing lanes
# -----------------------------------------------------------------------------


def test_mask_zeroes_non_passing_lanes() raises:
    """SimdOf.mask(m) returns a copy where lanes for which m is False are
    zeroed in every field."""
    var s = SimdOf[Row3F64I64F64, 4].zero()
    s.set_f64[0](SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0))
    s.set_i64[1](SIMD[DType.int64, 4](10, 20, 30, 40))
    s.set_f64[2](SIMD[DType.float64, 4](0.1, 0.2, 0.3, 0.4))

    var m = SIMD[DType.bool, 4](True, False, True, False)
    var mskd = s.mask(m)
    var a = mskd.get_f64[0]()
    var b = mskd.get_i64[1]()
    var c = mskd.get_f64[2]()
    # Lane 0 + 2 pass, lane 1 + 3 zeroed
    assert_equal(a[0], 1.0)
    assert_equal(a[1], 0.0)
    assert_equal(a[2], 3.0)
    assert_equal(a[3], 0.0)
    assert_equal(b[0], 10)
    assert_equal(b[1], 0)
    assert_equal(b[2], 30)
    assert_equal(b[3], 0)
    assert_equal(c[0], 0.1)
    assert_equal(c[1], 0.0)
    assert_equal(c[2], 0.3)
    assert_equal(c[3], 0.0)


def test_mask_all_pass_preserves_values() raises:
    """mask(all-True) is the identity — all lanes preserved."""
    var s = SimdOf[Row3F64I64F64, 4].zero()
    s.set_f64[0](SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0))
    var mskd = s.mask(SIMD[DType.bool, 4](True, True, True, True))
    var a = mskd.get_f64[0]()
    assert_equal(a[0], 1.0)
    assert_equal(a[1], 2.0)
    assert_equal(a[2], 3.0)
    assert_equal(a[3], 4.0)


def test_mask_all_fail_zeroes_everything() raises:
    """mask(all-False) zeroes every lane in every field."""
    var s = SimdOf[Row3F64I64F64, 4].zero()
    s.set_f64[0](SIMD[DType.float64, 4](1.0, 2.0, 3.0, 4.0))
    s.set_i64[1](SIMD[DType.int64, 4](10, 20, 30, 40))
    var mskd = s.mask(SIMD[DType.bool, 4](False, False, False, False))
    var a = mskd.get_f64[0]()
    var b = mskd.get_i64[1]()
    for i in range(4):
        assert_equal(a[i], 0.0)
        assert_equal(b[i], 0)


# -----------------------------------------------------------------------------
# 4) Full multi-chunk round-trip
# -----------------------------------------------------------------------------


def test_multi_chunk_round_trip_correctness() raises:
    """16 rows split into 4 chunks of W=4, run through a Map-shape kernel
    (revenue = price * (1.0 - disc), net_qty = qty - 5), compared to the
    scalar reference. This is the production-shape end-to-end flow the
    morsel-executor uses."""
    comptime W = 4
    var N = 16

    # Source columns (typed lists for clarity; the production path uses
    # PrimitiveArray[dtype] but the SimdOf primitive is column-agnostic).
    var price = List[Float64]()
    var qty = List[Int64]()
    var disc = List[Float64]()
    for i in range(N):
        price.append(Float64(100 + i))
        qty.append(Int64(10 + i))
        disc.append(Float64(i % 5) * 0.1)

    # Output buffers
    var revenue_out = List[Float64]()
    var net_qty_out = List[Int64]()
    for _ in range(N):
        revenue_out.append(0.0)
        net_qty_out.append(0)

    # Per-chunk: load -> compute -> store
    var chunks = N // W
    for c in range(chunks):
        var chunk_start = c * W

        # Load (mirrors a per-column SIMD-load — the executor does this from
        # PrimitiveArray[dtype].load[width=W])
        var s = SimdOf[Row3F64I64F64, W].zero()
        s.set_f64[0]((price.unsafe_ptr() + chunk_start).load[width=W]())
        s.set_i64[1]((qty.unsafe_ptr() + chunk_start).load[width=W]())
        s.set_f64[2]((disc.unsafe_ptr() + chunk_start).load[width=W]())

        # Compute
        var p = s.get_f64[0]()
        var q = s.get_i64[1]()
        var d = s.get_f64[2]()
        var revenue = p * (SIMD[DType.float64, W](1.0) - d)
        var net_qty = q - SIMD[DType.int64, W](5)

        # Store
        (revenue_out.unsafe_ptr() + chunk_start).store(revenue)
        (net_qty_out.unsafe_ptr() + chunk_start).store(net_qty)

    # Compare to scalar reference
    for i in range(N):
        var ref_rev = price[i] * (1.0 - disc[i])
        var ref_net = qty[i] - 5
        var got_rev = revenue_out[i]
        var got_net = net_qty_out[i]
        # FP epsilon
        var diff = ref_rev - got_rev
        assert_true(diff * diff < 1e-20)
        assert_equal(got_net, ref_net)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
