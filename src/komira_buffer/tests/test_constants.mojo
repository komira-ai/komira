# =============================================================================
# The compile-time constants: each SIMD width is the width of its own
# element type, and the cache-line and morsel fallbacks have their
# documented values. (NUM_CORES is not checked here: it is evaluated on the
# machine that compiles the package.)
# =============================================================================

from std.sys import simd_width_of
from std.testing import TestSuite, assert_equal

from komira_buffer.constants import (
    CACHE_LINE_BYTES,
    DEFAULT_MORSEL_ROWS,
    SIMD_WIDTH_F32,
    SIMD_WIDTH_F64,
    SIMD_WIDTH_I16,
    SIMD_WIDTH_I32,
    SIMD_WIDTH_I64,
    SIMD_WIDTH_I8,
    SIMD_WIDTH_U64,
    SIMD_WIDTH_U8,
)


def test_simd_widths_match_their_types() raises:
    """Each width is simd_width_of its own type, and the widths scale with
    the element size (a width named for the wrong type breaks one of the
    two)."""
    assert_equal(SIMD_WIDTH_F64, simd_width_of[DType.float64]())
    assert_equal(SIMD_WIDTH_F32, simd_width_of[DType.float32]())
    assert_equal(SIMD_WIDTH_I64, simd_width_of[DType.int64]())
    assert_equal(SIMD_WIDTH_I32, simd_width_of[DType.int32]())
    assert_equal(SIMD_WIDTH_I16, simd_width_of[DType.int16]())
    assert_equal(SIMD_WIDTH_I8, simd_width_of[DType.int8]())
    assert_equal(SIMD_WIDTH_U8, simd_width_of[DType.uint8]())
    assert_equal(SIMD_WIDTH_U64, simd_width_of[DType.uint64]())
    assert_equal(SIMD_WIDTH_F32, 2 * SIMD_WIDTH_F64)
    assert_equal(SIMD_WIDTH_I32, 2 * SIMD_WIDTH_I64)
    assert_equal(SIMD_WIDTH_I16, 2 * SIMD_WIDTH_I32)
    assert_equal(SIMD_WIDTH_I8, 2 * SIMD_WIDTH_I16)
    assert_equal(SIMD_WIDTH_U8, SIMD_WIDTH_I8)
    assert_equal(SIMD_WIDTH_U64, SIMD_WIDTH_I64)


def test_fixed_constants() raises:
    """The cache line is 64 bytes; the morsel fallback is 64 Ki rows."""
    assert_equal(CACHE_LINE_BYTES, 64)
    assert_equal(DEFAULT_MORSEL_ROWS, 65536)


def main() raises:
    var s = TestSuite()
    s.test[test_simd_widths_match_their_types]()
    s.test[test_fixed_constants]()
    s^.run()
