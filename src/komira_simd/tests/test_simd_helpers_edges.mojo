# =============================================================================
# test_simd_helpers_edges — the simd_helpers paths test_simd_helpers misses
# =============================================================================
#
# H1  `_simd_min` / `_simd_max` over several SIMD chunks: the extreme value is
#     planted at EVERY position of an array of 4 native widths plus 3, so the
#     chunk-fold loop (chunks 2..4), the first chunk and the scalar tail each
#     hold it in some row. The other tests use at most 7 elements, which is one
#     chunk or none.
# H2  `_simd_max` with n = 1.
# H3  `simd_min_arrays` / `simd_max_arrays` with n = 0 leave dst alone, and
#     n = 1 still folds.
# =============================================================================

from std.memory import alloc
from std.sys import simd_width_of
from std.testing import TestSuite, assert_equal

from komira_simd.simd_helpers import (
    _simd_min,
    _simd_max,
    simd_min_arrays,
    simd_max_arrays,
)


def _sweep_min_max[dtype: DType]() raises:
    comptime width = simd_width_of[dtype]()
    var n = 4 * width + 3
    var ptr = alloc[Scalar[dtype]](n)
    for pos in range(n):
        for i in range(n):
            # 10..(10 + n), never the planted extremes.
            ptr.store[width=1](i, Scalar[dtype](10 + (i * 7) % n))
        ptr.store[width=1](pos, Scalar[dtype](1))
        assert_equal(
            _simd_min[dtype](ptr, n),
            Scalar[dtype](1),
            String(dtype) + " min planted at " + String(pos),
        )
        ptr.store[width=1](pos, Scalar[dtype](100 + n))
        assert_equal(
            _simd_max[dtype](ptr, n),
            Scalar[dtype](100 + n),
            String(dtype) + " max planted at " + String(pos),
        )
    ptr.free()


def test_min_max_every_position() raises:
    _sweep_min_max[DType.int32]()
    _sweep_min_max[DType.int64]()
    _sweep_min_max[DType.float64]()
    _sweep_min_max[DType.uint8]()


def test_max_single() raises:
    var ptr = alloc[Scalar[DType.int64]](1)
    ptr.store[width=1](0, Scalar[DType.int64](-42))
    assert_equal(_simd_max[DType.int64](ptr, 1), Scalar[DType.int64](-42))
    ptr.free()


def test_min_max_arrays_zero_and_one() raises:
    var dst = alloc[Scalar[DType.int32]](1)
    var src = alloc[Scalar[DType.int32]](1)
    # n = 0: neither fold may touch dst, whichever way src compares.
    dst.store[width=1](0, Scalar[DType.int32](5))
    src.store[width=1](0, Scalar[DType.int32](1))
    simd_min_arrays[DType.int32](dst, src, 0)
    assert_equal(dst.load[width=1](0), Scalar[DType.int32](5), "min n=0")
    src.store[width=1](0, Scalar[DType.int32](9))
    simd_max_arrays[DType.int32](dst, src, 0)
    assert_equal(dst.load[width=1](0), Scalar[DType.int32](5), "max n=0")
    # n = 1: one scalar-tail element.
    src.store[width=1](0, Scalar[DType.int32](1))
    simd_min_arrays[DType.int32](dst, src, 1)
    assert_equal(dst.load[width=1](0), Scalar[DType.int32](1), "min n=1")
    src.store[width=1](0, Scalar[DType.int32](9))
    simd_max_arrays[DType.int32](dst, src, 1)
    assert_equal(dst.load[width=1](0), Scalar[DType.int32](9), "max n=1")
    dst.free()
    src.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
