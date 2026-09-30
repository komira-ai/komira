# =============================================================================
# Tests for bitmap_ops::select_into
# =============================================================================
#
# Oracle strategy: naive scalar reference implementation run alongside the
# SIMD implementation; buffers compared element-wise after each case.
#
# select_into() takes OwnedAlignedBuffer refs (not raw UnsafePointers).
# Test allocations use OwnedAlignedBuffer(0).
# =============================================================================

from std.sys.info import size_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow import Bitmap, select_into
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer


# -----------------------------------------------------------------------------
# Helpers -- MmapAlignedBuffer-backed Float64 / Int32 buffers + scalar oracle.
# -----------------------------------------------------------------------------

comptime F64_SZ = size_of[Float64]()
comptime I32_SZ = size_of[Int32]()


def _make_f64_buf(n: Int, v0: Float64, stride: Float64) -> OwnedAlignedBuffer:
    var buf = OwnedAlignedBuffer(n * F64_SZ)
    for i in range(n):
        buf.set_typed[Float64](i, v0 + Float64(i) * stride)
    return buf^


def _make_i32_buf(n: Int, v0: Int32, stride: Int32) -> OwnedAlignedBuffer:
    var buf = OwnedAlignedBuffer(n * I32_SZ)
    for i in range(n):
        buf.set_typed[Int32](i, v0 + Int32(i) * stride)
    return buf^


def _naive_select_into_f64(
    mut dst: OwnedAlignedBuffer,
    src: OwnedAlignedBuffer,
    mask: Bitmap,
    n: Int,
):
    """Scalar reference implementation for oracle comparison."""
    for i in range(n):
        if mask.test(i):
            dst.set_typed[Float64](i, src.get_typed[Float64](i))


def _naive_select_into_i32(
    mut dst: OwnedAlignedBuffer,
    src: OwnedAlignedBuffer,
    mask: Bitmap,
    n: Int,
):
    for i in range(n):
        if mask.test(i):
            dst.set_typed[Int32](i, src.get_typed[Int32](i))


# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------


def test_select_into_all_zero_mask_f64() raises:
    """All-zero mask leaves dst untouched."""
    var n = 64
    var dst = _make_f64_buf(n, 10.0, 1.0)
    var src = _make_f64_buf(n, 100.0, 2.0)
    var mask = Bitmap.create(n)
    select_into[DType.float64](dst, src, mask, n)
    for i in range(n):
        assert_equal(dst.get_typed[Float64](i), Float64(10 + i))


def test_select_into_all_one_mask_f64() raises:
    """All-one mask copies src into dst wholesale."""
    var n = 64
    var dst = _make_f64_buf(n, 10.0, 1.0)
    var src = _make_f64_buf(n, 100.0, 2.0)
    var mask = Bitmap.create_all_valid(n)
    select_into[DType.float64](dst, src, mask, n)
    for i in range(n):
        assert_equal(dst.get_typed[Float64](i), Float64(100 + 2 * i))


def test_select_into_alternating_f64() raises:
    """Alternating mask bits match scalar oracle exactly."""
    var n = 128
    var dst = _make_f64_buf(n, 10.0, 1.0)
    var src = _make_f64_buf(n, 100.0, 2.0)
    var dst_ref = _make_f64_buf(n, 10.0, 1.0)
    var src_ref = _make_f64_buf(n, 100.0, 2.0)
    var mask = Bitmap.create(n)
    for i in range(n):
        if (i & 1) == 0:
            mask.set(i)
    select_into[DType.float64](dst, src, mask, n)
    _naive_select_into_f64(dst_ref, src_ref, mask, n)
    for i in range(n):
        assert_equal(dst.get_typed[Float64](i), dst_ref.get_typed[Float64](i))


def test_select_into_unaligned_length_f64() raises:
    """n_rows not a multiple of SIMD width exercises the scalar tail."""
    var n = 67  # prime, forces tail
    var dst = _make_f64_buf(n, 10.0, 1.0)
    var src = _make_f64_buf(n, 100.0, 2.0)
    var dst_ref = _make_f64_buf(n, 10.0, 1.0)
    var src_ref = _make_f64_buf(n, 100.0, 2.0)
    var mask = Bitmap.create(n)
    # Irregular mask: primes < 67
    var primes: List[Int] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61]
    for p in primes:
        mask.set(p)
    select_into[DType.float64](dst, src, mask, n)
    _naive_select_into_f64(dst_ref, src_ref, mask, n)
    for i in range(n):
        assert_equal(dst.get_typed[Float64](i), dst_ref.get_typed[Float64](i))


def test_select_into_empty() raises:
    """n_rows == 0 is a no-op and doesn't read/write anything."""
    var dst = _make_f64_buf(1, 999.0, 0.0)
    var src = _make_f64_buf(1, 111.0, 0.0)
    var mask = Bitmap.create_all_valid(0)
    select_into[DType.float64](dst, src, mask, 0)
    assert_equal(dst.get_typed[Float64](0), 999.0)


def test_select_into_int32_oracle() raises:
    """Different dtype width (Int32) exercises SIMD-width parametrization."""
    var n = 500
    var dst = _make_i32_buf(n, 0, 1)
    var src = _make_i32_buf(n, -10000, 7)
    var dst_ref = _make_i32_buf(n, 0, 1)
    var src_ref = _make_i32_buf(n, -10000, 7)
    var mask = Bitmap.create(n)
    for i in range(n):
        if (i * 31 + 7) % 5 == 0:
            mask.set(i)
    select_into[DType.int32](dst, src, mask, n)
    _naive_select_into_i32(dst_ref, src_ref, mask, n)
    for i in range(n):
        assert_equal(dst.get_typed[Int32](i), dst_ref.get_typed[Int32](i))


def test_select_into_large_random_like_f64() raises:
    """Larger size (4096 rows) crosses many SIMD blocks."""
    var n = 4096
    var dst = _make_f64_buf(n, 0.5, 0.25)
    var src = _make_f64_buf(n, -3.0, 1.5)
    var dst_ref = _make_f64_buf(n, 0.5, 0.25)
    var src_ref = _make_f64_buf(n, -3.0, 1.5)
    var mask = Bitmap.create(n)
    for i in range(n):
        if ((i * 2654435761) >> 16) & 1 == 0:
            mask.set(i)
    select_into[DType.float64](dst, src, mask, n)
    _naive_select_into_f64(dst_ref, src_ref, mask, n)
    for i in range(n):
        assert_equal(dst.get_typed[Float64](i), dst_ref.get_typed[Float64](i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
