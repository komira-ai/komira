# =============================================================================
# Tests for komira_simd/simd_helpers.mojo — SIMD helper abstractions
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import alloc

from komira_simd.simd_helpers import (
    _simd_sum,
    _simd_min,
    _simd_max,
    _simd_min_max,
    _simd_count_if,
    _simd_fill,
    _simd_iota,
    simd_add_arrays,
    simd_min_arrays,
    simd_max_arrays,
)


# =============================================================================
# Sum tests
# =============================================================================


def test_sum_int32() raises:
    """Correctly sums Int32 array."""
    var ptr = alloc[Scalar[DType.int32]](5)
    ptr.store[width=1](0, Scalar[DType.int32](1))
    ptr.store[width=1](1, Scalar[DType.int32](2))
    ptr.store[width=1](2, Scalar[DType.int32](3))
    ptr.store[width=1](3, Scalar[DType.int32](4))
    ptr.store[width=1](4, Scalar[DType.int32](5))
    var result = _simd_sum[DType.int32](ptr, 5)
    assert_equal(result, Scalar[DType.int32](15))
    ptr.free()


def test_sum_int64() raises:
    """Correctly sums Int64 array."""
    var ptr = alloc[Scalar[DType.int64]](4)
    ptr.store[width=1](0, Scalar[DType.int64](10))
    ptr.store[width=1](1, Scalar[DType.int64](20))
    ptr.store[width=1](2, Scalar[DType.int64](30))
    ptr.store[width=1](3, Scalar[DType.int64](40))
    var result = _simd_sum[DType.int64](ptr, 4)
    assert_equal(result, Scalar[DType.int64](100))
    ptr.free()


def test_sum_float64() raises:
    """Correctly sums Float64 array."""
    var ptr = alloc[Scalar[DType.float64]](3)
    ptr.store[width=1](0, Scalar[DType.float64](1.5))
    ptr.store[width=1](1, Scalar[DType.float64](2.5))
    ptr.store[width=1](2, Scalar[DType.float64](3.0))
    var result = _simd_sum[DType.float64](ptr, 3)
    assert_true(abs(Float64(result) - 7.0) < 1e-10)
    ptr.free()


def test_sum_empty() raises:
    """Returns 0 for n=0."""
    var ptr = alloc[Scalar[DType.int64]](1)
    var result = _simd_sum[DType.int64](ptr, 0)
    assert_equal(result, Scalar[DType.int64](0))
    ptr.free()


def test_sum_single() raises:
    """Handles n=1 correctly."""
    var ptr = alloc[Scalar[DType.int64]](1)
    ptr.store[width=1](0, Scalar[DType.int64](42))
    var result = _simd_sum[DType.int64](ptr, 1)
    assert_equal(result, Scalar[DType.int64](42))
    ptr.free()


def test_sum_non_aligned() raises:
    """Handles n not aligned to SIMD width (7 elements)."""
    var ptr = alloc[Scalar[DType.int64]](7)
    for i in range(7):
        ptr.store[width=1](i, Scalar[DType.int64](i + 1))
    var result = _simd_sum[DType.int64](ptr, 7)
    assert_equal(result, Scalar[DType.int64](28))
    ptr.free()


# =============================================================================
# Min tests
# =============================================================================


def test_min_int64() raises:
    """Finds minimum in Int64 array."""
    var ptr = alloc[Scalar[DType.int64]](5)
    ptr.store[width=1](0, Scalar[DType.int64](5))
    ptr.store[width=1](1, Scalar[DType.int64](2))
    ptr.store[width=1](2, Scalar[DType.int64](8))
    ptr.store[width=1](3, Scalar[DType.int64](1))
    ptr.store[width=1](4, Scalar[DType.int64](9))
    var result = _simd_min[DType.int64](ptr, 5)
    assert_equal(result, Scalar[DType.int64](1))
    ptr.free()


def test_min_single() raises:
    """Handles n=1 for min."""
    var ptr = alloc[Scalar[DType.int64]](1)
    ptr.store[width=1](0, Scalar[DType.int64](42))
    var result = _simd_min[DType.int64](ptr, 1)
    assert_equal(result, Scalar[DType.int64](42))
    ptr.free()


def test_min_float64() raises:
    """Finds minimum in Float64 array."""
    var ptr = alloc[Scalar[DType.float64]](4)
    ptr.store[width=1](0, Scalar[DType.float64](3.14))
    ptr.store[width=1](1, Scalar[DType.float64](2.71))
    ptr.store[width=1](2, Scalar[DType.float64](1.41))
    ptr.store[width=1](3, Scalar[DType.float64](1.73))
    var result = _simd_min[DType.float64](ptr, 4)
    assert_true(abs(Float64(result) - 1.41) < 1e-10)
    ptr.free()


def test_min_all_same() raises:
    """Min with all identical values."""
    var ptr = alloc[Scalar[DType.int32]](6)
    for i in range(6):
        ptr.store[width=1](i, Scalar[DType.int32](7))
    var result = _simd_min[DType.int32](ptr, 6)
    assert_equal(result, Scalar[DType.int32](7))
    ptr.free()


# =============================================================================
# Max tests
# =============================================================================


def test_max_int64() raises:
    """Finds maximum in Int64 array."""
    var ptr = alloc[Scalar[DType.int64]](5)
    ptr.store[width=1](0, Scalar[DType.int64](5))
    ptr.store[width=1](1, Scalar[DType.int64](2))
    ptr.store[width=1](2, Scalar[DType.int64](8))
    ptr.store[width=1](3, Scalar[DType.int64](1))
    ptr.store[width=1](4, Scalar[DType.int64](9))
    var result = _simd_max[DType.int64](ptr, 5)
    assert_equal(result, Scalar[DType.int64](9))
    ptr.free()


def test_max_float64() raises:
    """Finds maximum in Float64 array."""
    var ptr = alloc[Scalar[DType.float64]](3)
    ptr.store[width=1](0, Scalar[DType.float64](1.0))
    ptr.store[width=1](1, Scalar[DType.float64](99.9))
    ptr.store[width=1](2, Scalar[DType.float64](50.0))
    var result = _simd_max[DType.float64](ptr, 3)
    assert_true(abs(Float64(result) - 99.9) < 1e-10)
    ptr.free()


def test_max_non_aligned() raises:
    """Max handles non-aligned count."""
    var ptr = alloc[Scalar[DType.int32]](7)
    ptr.store[width=1](0, Scalar[DType.int32](3))
    ptr.store[width=1](1, Scalar[DType.int32](1))
    ptr.store[width=1](2, Scalar[DType.int32](4))
    ptr.store[width=1](3, Scalar[DType.int32](1))
    ptr.store[width=1](4, Scalar[DType.int32](5))
    ptr.store[width=1](5, Scalar[DType.int32](9))
    ptr.store[width=1](6, Scalar[DType.int32](2))
    var result = _simd_max[DType.int32](ptr, 7)
    assert_equal(result, Scalar[DType.int32](9))
    ptr.free()


# =============================================================================
# MinMax tests (single-pass combined min+max)
# =============================================================================


def test_min_max_int32() raises:
    """Returns both min and max in a single pass."""
    var ptr = alloc[Scalar[DType.int32]](8)
    ptr.store[width=1](0, Scalar[DType.int32](5))
    ptr.store[width=1](1, Scalar[DType.int32](-3))
    ptr.store[width=1](2, Scalar[DType.int32](10))
    ptr.store[width=1](3, Scalar[DType.int32](2))
    ptr.store[width=1](4, Scalar[DType.int32](7))
    ptr.store[width=1](5, Scalar[DType.int32](-1))
    ptr.store[width=1](6, Scalar[DType.int32](0))
    ptr.store[width=1](7, Scalar[DType.int32](100))
    var res = _simd_min_max[DType.int32](ptr, 8)
    assert_equal(res[0], Scalar[DType.int32](-3))
    assert_equal(res[1], Scalar[DType.int32](100))
    ptr.free()


def test_min_max_int64_non_aligned() raises:
    """Non-aligned tail path correctness."""
    var ptr = alloc[Scalar[DType.int64]](11)
    ptr.store[width=1](0, Scalar[DType.int64](17))
    ptr.store[width=1](1, Scalar[DType.int64](-5))
    ptr.store[width=1](2, Scalar[DType.int64](0))
    ptr.store[width=1](3, Scalar[DType.int64](42))
    ptr.store[width=1](4, Scalar[DType.int64](100))
    ptr.store[width=1](5, Scalar[DType.int64](-200))
    ptr.store[width=1](6, Scalar[DType.int64](300))
    ptr.store[width=1](7, Scalar[DType.int64](5))
    ptr.store[width=1](8, Scalar[DType.int64](-1))
    ptr.store[width=1](9, Scalar[DType.int64](9))
    ptr.store[width=1](10, Scalar[DType.int64](7))
    var res = _simd_min_max[DType.int64](ptr, 11)
    assert_equal(res[0], Scalar[DType.int64](-200))
    assert_equal(res[1], Scalar[DType.int64](300))
    ptr.free()


def test_min_max_single() raises:
    """n=1 returns (v, v)."""
    var ptr = alloc[Scalar[DType.int32]](1)
    ptr.store[width=1](0, Scalar[DType.int32](42))
    var res = _simd_min_max[DType.int32](ptr, 1)
    assert_equal(res[0], Scalar[DType.int32](42))
    assert_equal(res[1], Scalar[DType.int32](42))
    ptr.free()


def test_min_max_all_same() raises:
    """All identical values."""
    var ptr = alloc[Scalar[DType.int64]](16)
    for i in range(16):
        ptr.store[width=1](i, Scalar[DType.int64](7))
    var res = _simd_min_max[DType.int64](ptr, 16)
    assert_equal(res[0], Scalar[DType.int64](7))
    assert_equal(res[1], Scalar[DType.int64](7))
    ptr.free()


def test_min_max_scalar_vs_simd_parity() raises:
    """SIMD min/max matches a scalar reference across width boundaries."""
    comptime N: Int = 1024 + 13  # forces both SIMD and tail paths
    var ptr = alloc[Scalar[DType.int32]](N)
    # Pseudo-random-ish pattern with both large and small values
    for i in range(N):
        var v = Int32((i * 2654435761) % 1009) - 500
        ptr.store[width=1](i, Scalar[DType.int32](v))
    # Scalar reference
    var ref_min = ptr.load[width=1](0)
    var ref_max = ptr.load[width=1](0)
    for i in range(1, N):
        var v = ptr.load[width=1](i)
        if v < ref_min:
            ref_min = v
        if v > ref_max:
            ref_max = v
    var res = _simd_min_max[DType.int32](ptr, N)
    assert_equal(res[0], ref_min)
    assert_equal(res[1], ref_max)
    ptr.free()


# =============================================================================
# Count-if tests
# =============================================================================


def test_count_if_int64() raises:
    """Counts elements > threshold."""
    var ptr = alloc[Scalar[DType.int64]](5)
    ptr.store[width=1](0, Scalar[DType.int64](1))
    ptr.store[width=1](1, Scalar[DType.int64](5))
    ptr.store[width=1](2, Scalar[DType.int64](3))
    ptr.store[width=1](3, Scalar[DType.int64](7))
    ptr.store[width=1](4, Scalar[DType.int64](2))
    var result = _simd_count_if[DType.int64](ptr, 5, Scalar[DType.int64](3))
    assert_equal(result, 2)  # 5 and 7 are > 3
    ptr.free()


def test_count_if_empty() raises:
    """Returns 0 for n=0."""
    var ptr = alloc[Scalar[DType.int64]](1)
    var result = _simd_count_if[DType.int64](ptr, 0, Scalar[DType.int64](0))
    assert_equal(result, 0)
    ptr.free()


def test_count_if_none_match() raises:
    """Returns 0 when no elements match."""
    var ptr = alloc[Scalar[DType.int32]](3)
    ptr.store[width=1](0, Scalar[DType.int32](1))
    ptr.store[width=1](1, Scalar[DType.int32](2))
    ptr.store[width=1](2, Scalar[DType.int32](3))
    var result = _simd_count_if[DType.int32](ptr, 3, Scalar[DType.int32](100))
    assert_equal(result, 0)
    ptr.free()


def test_count_if_all_match() raises:
    """Counts all when all > threshold."""
    var ptr = alloc[Scalar[DType.int32]](5)
    for i in range(5):
        ptr.store[width=1](i, Scalar[DType.int32]((i + 1) * 10))
    var result = _simd_count_if[DType.int32](ptr, 5, Scalar[DType.int32](0))
    assert_equal(result, 5)
    ptr.free()


# =============================================================================
# Fill tests
# =============================================================================


def test_fill_int64() raises:
    """Broadcasts value to all elements."""
    var ptr = alloc[Scalar[DType.int64]](8)
    for i in range(8):
        ptr.store[width=1](i, Scalar[DType.int64](0))
    _simd_fill[DType.int64](ptr, 8, Scalar[DType.int64](42))
    for i in range(8):
        assert_equal(ptr.load[width=1](i), Scalar[DType.int64](42))
    ptr.free()


def test_fill_non_aligned() raises:
    """Fill handles non-aligned count."""
    var ptr = alloc[Scalar[DType.int32]](5)
    for i in range(5):
        ptr.store[width=1](i, Scalar[DType.int32](0))
    _simd_fill[DType.int32](ptr, 5, Scalar[DType.int32](99))
    for i in range(5):
        assert_equal(ptr.load[width=1](i), Scalar[DType.int32](99))
    ptr.free()


def test_fill_empty() raises:
    """Fill handles n=0 without writing."""
    var ptr = alloc[Scalar[DType.int64]](1)
    ptr.store[width=1](0, Scalar[DType.int64](0))
    _simd_fill[DType.int64](ptr, 0, Scalar[DType.int64](42))
    assert_equal(ptr.load[width=1](0), Scalar[DType.int64](0))
    ptr.free()


def test_fill_single() raises:
    """Fill handles n=1."""
    var ptr = alloc[Scalar[DType.int64]](1)
    ptr.store[width=1](0, Scalar[DType.int64](0))
    _simd_fill[DType.int64](ptr, 1, Scalar[DType.int64](77))
    assert_equal(ptr.load[width=1](0), Scalar[DType.int64](77))
    ptr.free()


# =============================================================================
# Iota tests
# =============================================================================


def test_iota_int32() raises:
    """Iota fills 0,1,2,...,n-1."""
    var ptr = alloc[Scalar[DType.int32]](8)
    _simd_iota[DType.int32](ptr, 8)
    for i in range(8):
        assert_equal(ptr.load[width=1](i), Scalar[DType.int32](i))
    ptr.free()


def test_iota_with_start() raises:
    """Iota fills start, start+1, ..."""
    var ptr = alloc[Scalar[DType.int64]](5)
    _simd_iota[DType.int64](ptr, 5, Scalar[DType.int64](10))
    for i in range(5):
        assert_equal(ptr.load[width=1](i), Scalar[DType.int64](10 + i))
    ptr.free()


def test_iota_non_aligned() raises:
    """Iota handles non-aligned count (7 elements)."""
    var ptr = alloc[Scalar[DType.int32]](7)
    _simd_iota[DType.int32](ptr, 7)
    for i in range(7):
        assert_equal(ptr.load[width=1](i), Scalar[DType.int32](i))
    ptr.free()


def test_iota_empty() raises:
    """Iota handles n=0."""
    var ptr = alloc[Scalar[DType.int32]](1)
    ptr.store[width=1](0, Scalar[DType.int32](0))
    _simd_iota[DType.int32](ptr, 0)
    assert_equal(ptr.load[width=1](0), Scalar[DType.int32](0))
    ptr.free()


def test_iota_single() raises:
    """Iota handles n=1."""
    var ptr = alloc[Scalar[DType.int64]](1)
    _simd_iota[DType.int64](ptr, 1, Scalar[DType.int64](5))
    assert_equal(ptr.load[width=1](0), Scalar[DType.int64](5))
    ptr.free()


# =============================================================================
# Add-arrays tests
# =============================================================================


def test_add_arrays_int64() raises:
    """Element-wise dst += src for Int64."""
    var dst = alloc[Scalar[DType.int64]](4)
    var src = alloc[Scalar[DType.int64]](4)
    dst.store[width=1](0, Scalar[DType.int64](1))
    dst.store[width=1](1, Scalar[DType.int64](2))
    dst.store[width=1](2, Scalar[DType.int64](3))
    dst.store[width=1](3, Scalar[DType.int64](4))
    src.store[width=1](0, Scalar[DType.int64](10))
    src.store[width=1](1, Scalar[DType.int64](20))
    src.store[width=1](2, Scalar[DType.int64](30))
    src.store[width=1](3, Scalar[DType.int64](40))
    simd_add_arrays[DType.int64](dst, src, 4)
    assert_equal(dst.load[width=1](0), Scalar[DType.int64](11))
    assert_equal(dst.load[width=1](1), Scalar[DType.int64](22))
    assert_equal(dst.load[width=1](2), Scalar[DType.int64](33))
    assert_equal(dst.load[width=1](3), Scalar[DType.int64](44))
    dst.free()
    src.free()


def test_add_arrays_non_aligned() raises:
    """Add-arrays handles non-aligned count."""
    var dst = alloc[Scalar[DType.int32]](3)
    var src = alloc[Scalar[DType.int32]](3)
    dst.store[width=1](0, Scalar[DType.int32](1))
    dst.store[width=1](1, Scalar[DType.int32](2))
    dst.store[width=1](2, Scalar[DType.int32](3))
    src.store[width=1](0, Scalar[DType.int32](10))
    src.store[width=1](1, Scalar[DType.int32](20))
    src.store[width=1](2, Scalar[DType.int32](30))
    simd_add_arrays[DType.int32](dst, src, 3)
    assert_equal(dst.load[width=1](0), Scalar[DType.int32](11))
    assert_equal(dst.load[width=1](1), Scalar[DType.int32](22))
    assert_equal(dst.load[width=1](2), Scalar[DType.int32](33))
    dst.free()
    src.free()


def test_add_arrays_empty() raises:
    """Add-arrays handles n=0."""
    var dst = alloc[Scalar[DType.int64]](1)
    var src = alloc[Scalar[DType.int64]](1)
    dst.store[width=1](0, Scalar[DType.int64](0))
    simd_add_arrays[DType.int64](dst, src, 0)
    assert_equal(dst.load[width=1](0), Scalar[DType.int64](0))
    dst.free()
    src.free()


# =============================================================================
# Min-arrays tests
# =============================================================================


def test_min_arrays_int64() raises:
    """Element-wise min for Int64."""
    var dst = alloc[Scalar[DType.int64]](4)
    var src = alloc[Scalar[DType.int64]](4)
    dst.store[width=1](0, Scalar[DType.int64](5))
    dst.store[width=1](1, Scalar[DType.int64](1))
    dst.store[width=1](2, Scalar[DType.int64](8))
    dst.store[width=1](3, Scalar[DType.int64](3))
    src.store[width=1](0, Scalar[DType.int64](3))
    src.store[width=1](1, Scalar[DType.int64](7))
    src.store[width=1](2, Scalar[DType.int64](2))
    src.store[width=1](3, Scalar[DType.int64](9))
    simd_min_arrays[DType.int64](dst, src, 4)
    assert_equal(dst.load[width=1](0), Scalar[DType.int64](3))
    assert_equal(dst.load[width=1](1), Scalar[DType.int64](1))
    assert_equal(dst.load[width=1](2), Scalar[DType.int64](2))
    assert_equal(dst.load[width=1](3), Scalar[DType.int64](3))
    dst.free()
    src.free()


def test_min_arrays_float64() raises:
    """Element-wise min for Float64."""
    var dst = alloc[Scalar[DType.float64]](2)
    var src = alloc[Scalar[DType.float64]](2)
    dst.store[width=1](0, Scalar[DType.float64](3.14))
    dst.store[width=1](1, Scalar[DType.float64](1.0))
    src.store[width=1](0, Scalar[DType.float64](2.71))
    src.store[width=1](1, Scalar[DType.float64](9.9))
    simd_min_arrays[DType.float64](dst, src, 2)
    assert_true(abs(Float64(dst.load[width=1](0)) - 2.71) < 1e-10)
    assert_true(abs(Float64(dst.load[width=1](1)) - 1.0) < 1e-10)
    dst.free()
    src.free()


# =============================================================================
# Max-arrays tests
# =============================================================================


def test_max_arrays_int64() raises:
    """Element-wise max for Int64."""
    var dst = alloc[Scalar[DType.int64]](4)
    var src = alloc[Scalar[DType.int64]](4)
    dst.store[width=1](0, Scalar[DType.int64](5))
    dst.store[width=1](1, Scalar[DType.int64](1))
    dst.store[width=1](2, Scalar[DType.int64](8))
    dst.store[width=1](3, Scalar[DType.int64](3))
    src.store[width=1](0, Scalar[DType.int64](3))
    src.store[width=1](1, Scalar[DType.int64](7))
    src.store[width=1](2, Scalar[DType.int64](2))
    src.store[width=1](3, Scalar[DType.int64](9))
    simd_max_arrays[DType.int64](dst, src, 4)
    assert_equal(dst.load[width=1](0), Scalar[DType.int64](5))
    assert_equal(dst.load[width=1](1), Scalar[DType.int64](7))
    assert_equal(dst.load[width=1](2), Scalar[DType.int64](8))
    assert_equal(dst.load[width=1](3), Scalar[DType.int64](9))
    dst.free()
    src.free()


def test_max_arrays_non_aligned() raises:
    """Max-arrays handles non-aligned count."""
    var dst = alloc[Scalar[DType.int32]](3)
    var src = alloc[Scalar[DType.int32]](3)
    dst.store[width=1](0, Scalar[DType.int32](1))
    dst.store[width=1](1, Scalar[DType.int32](9))
    dst.store[width=1](2, Scalar[DType.int32](5))
    src.store[width=1](0, Scalar[DType.int32](8))
    src.store[width=1](1, Scalar[DType.int32](2))
    src.store[width=1](2, Scalar[DType.int32](5))
    simd_max_arrays[DType.int32](dst, src, 3)
    assert_equal(dst.load[width=1](0), Scalar[DType.int32](8))
    assert_equal(dst.load[width=1](1), Scalar[DType.int32](9))
    assert_equal(dst.load[width=1](2), Scalar[DType.int32](5))
    dst.free()
    src.free()


# =============================================================================
# Main
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
