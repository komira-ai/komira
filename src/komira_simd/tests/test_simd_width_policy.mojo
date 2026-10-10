# =============================================================================
# test_simd_width_policy — komira_simd.width_policy
# =============================================================================
#
# W1  The documented policy as a byte-width fact, per dtype: on x86 without
#     the KOMIRA_SIMD_ALLOW_AVX512 define a loop is at most 256 bits wide and
#     otherwise as wide as the native vector; elsewhere it is the native width.
#     The expectation is stated in bytes (min(native bytes, 32)), not by
#     repeating the policy's own lane arithmetic.
# W2  The per-lever widths (bitpack, delta) equal the shared policy while the
#     sweep constants ship at 0.
# W3  `_target_is_avx512` is true exactly when the native vector is 64 bytes
#     on x86. The pinned build target (x86-64-v3) has 32-byte vectors, so on
#     the gate's target it is false.
# =============================================================================

from std.sys import size_of
from std.sys.info import CompilationTarget, simd_width_of
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_simd.width_policy import (
    KOMIRA_SIMD_ALLOW_AVX512,
    _target_is_avx512,
    komira_simd_width,
    komira_simd_width_bitpack,
    komira_simd_width_delta,
)


def _check_dtype[dtype: DType]() raises:
    var native_bytes = simd_width_of[dtype]() * size_of[dtype]()
    var want_bytes = native_bytes
    if CompilationTarget.is_x86() and not KOMIRA_SIMD_ALLOW_AVX512:
        want_bytes = min(native_bytes, 32)
    var w = komira_simd_width[dtype]()
    assert_true(w >= 1, String(dtype) + " width must be at least one lane")
    assert_equal(w * size_of[dtype](), want_bytes, String(dtype) + " bytes")
    assert_equal(komira_simd_width_bitpack[dtype](), w, String(dtype) + " bitpack")
    assert_equal(komira_simd_width_delta[dtype](), w, String(dtype) + " delta")


def test_policy_widths() raises:
    _check_dtype[DType.uint8]()
    _check_dtype[DType.uint16]()
    _check_dtype[DType.uint32]()
    _check_dtype[DType.uint64]()
    _check_dtype[DType.float32]()
    _check_dtype[DType.float64]()


def test_avx512_detection() raises:
    var native_bytes = simd_width_of[DType.uint32]() * 4
    assert_equal(
        _target_is_avx512(),
        CompilationTarget.is_x86() and native_bytes == 64,
        "AVX-512 iff 64-byte native vectors on x86",
    )
    # The gate's pinned target is x86-64-v3 (AVX2): 32-byte vectors.
    comptime if CompilationTarget.is_x86():
        if native_bytes == 32:
            assert_false(_target_is_avx512(), "AVX2 target read as AVX-512")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
