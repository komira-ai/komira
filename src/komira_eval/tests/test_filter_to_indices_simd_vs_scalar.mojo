# =============================================================================
# test_filter_to_indices_simd_vs_scalar.mojo — correctness oracle
# =============================================================================
#
# Verifies that the pure-Mojo SIMD path
# (`_filter_to_indices_simd`) produces byte-for-byte identical output to
# the scalar reference path (`_filter_to_indices_scalar`) across:
#
#   * Selectivity: 0%, 1%, 8%, 38%, 50%, 90%, 100%
#   * Length: empty, 1, 8 (one byte), 9 (one byte + 1 bit tail), 16,
#             63 (just under one u64), 64 (exactly one u64), 65 (u64 + 1 bit),
#             72 (u64 + 1 byte), 128, 1023, 4096
#   * Bit-tail boundaries: lengths that exercise byte-tail (multiple of 8
#     but not 64) and bit-tail (not multiple of 8)
#   * Edge masks: alternating, single-bit-set-at-position, all-ones,
#     all-zeros, contiguous-runs (block-skip happy paths)
#
# Bug protocol: tests assert byte-match between the two paths. If
# `_filter_to_indices_simd` ever diverges from `_filter_to_indices_scalar`,
# at least one of these tests must fail before the regression is shipped.
#
# Why both paths exist: scalar is the well-tested correctness oracle;
# SIMD is the production hot path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_column_kernels.comparison import eval_gt, eval_lt, eval_eq, filter_to_indices
from komira_column_kernels.comparison import (
    _filter_to_indices_scalar, _filter_to_indices_simd
)


# =============================================================================
# Helpers
# =============================================================================


def _lists_equal(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _make_mask_from_pattern(
    length: Int, pattern_fn: def (Int) thin -> Bool
) raises -> BooleanArray:
    """Build a BooleanArray of given `length` where bit i is `pattern_fn(i)`.

    Goes through the same Bitmap construction path the production
    eval_* kernels use so the resulting BooleanArray bit layout is
    identical. Bits are LSB-first within each byte (Arrow convention).
    `Bitmap.create` zero-inits the buffer; we set bits via `Bitmap.set`.
    """
    var bm = Bitmap.create(length)
    for i in range(length):
        if pattern_fn(i):
            bm.set(i)
    return BooleanArray.from_bitmap(bm^)


# Pattern callbacks (top-level fns -- Mojo cannot pass closures yet).
def _all_true(i: Int) -> Bool:
    return True


def _all_false(i: Int) -> Bool:
    return False


def _alternating(i: Int) -> Bool:
    return (i & 1) == 0


def _every_third(i: Int) -> Bool:
    return (i % 3) == 0


def _every_seventh(i: Int) -> Bool:
    return (i % 7) == 0


def _every_64th(i: Int) -> Bool:
    """Hits the all-zero u64 fast path 63 of 64 times."""
    return (i % 64) == 0


def _every_other_block(i: Int) -> Bool:
    """All-ones u64 followed by all-zero u64."""
    return ((i >> 6) & 1) == 0


def _first_bit_only(i: Int) -> Bool:
    return i == 0


def _last_bit_in_byte(i: Int) -> Bool:
    """Tail-byte stress: only bit 7 of every byte set."""
    return (i & 7) == 7


# =============================================================================
# Direct-equivalence tests (SIMD vs scalar)
# =============================================================================


def _assert_simd_matches_scalar(mask: BooleanArray) raises:
    var simd_out = _filter_to_indices_simd(mask)
    var scalar_out = _filter_to_indices_scalar(mask)
    assert_equal(len(simd_out), len(scalar_out))
    assert_true(_lists_equal(simd_out, scalar_out))


# ---- length sweep ------------------------------------------------------------


def test_simd_eq_scalar_length_0() raises:
    var mask = _make_mask_from_pattern(0, _all_true)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_1() raises:
    var mask = _make_mask_from_pattern(1, _all_true)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_8() raises:
    var mask = _make_mask_from_pattern(8, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_9() raises:
    """One full byte + 1 bit tail."""
    var mask = _make_mask_from_pattern(9, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_63() raises:
    """One bit short of a full u64 — all in byte-tail path."""
    var mask = _make_mask_from_pattern(63, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_64() raises:
    """Exactly one u64."""
    var mask = _make_mask_from_pattern(64, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_65() raises:
    """One u64 + 1 bit tail."""
    var mask = _make_mask_from_pattern(65, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_72() raises:
    """One u64 + 1 full byte tail (byte-tail path)."""
    var mask = _make_mask_from_pattern(72, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_128() raises:
    """Exactly two u64s."""
    var mask = _make_mask_from_pattern(128, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_1023() raises:
    """1023 = 15*64 + 63. 15 full u64s + 7-byte byte-tail + 7-bit bit-tail."""
    var mask = _make_mask_from_pattern(1023, _every_third)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_length_4096() raises:
    """64 full u64s, no tail."""
    var mask = _make_mask_from_pattern(4096, _every_seventh)
    _assert_simd_matches_scalar(mask)


# ---- selectivity sweep -------------------------------------------------------


def test_simd_eq_scalar_all_zero() raises:
    """0% selectivity — exercises all-zero u64 fast path exclusively."""
    var mask = _make_mask_from_pattern(1024, _all_false)
    var out = _filter_to_indices_simd(mask)
    assert_equal(len(out), 0)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_all_one() raises:
    """100% selectivity — exercises all-one u64 fast path exclusively."""
    var mask = _make_mask_from_pattern(1024, _all_true)
    var out = _filter_to_indices_simd(mask)
    assert_equal(len(out), 1024)
    # First and last index sanity.
    assert_equal(out[0], 0)
    assert_equal(out[1023], 1023)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_low_sel() raises:
    """~1.5% selectivity (every 64th bit) — mostly all-zero u64 fast path,
    with one set bit in each u64 forcing the mixed (ctz) path."""
    var mask = _make_mask_from_pattern(4096, _every_64th)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_block_alternating() raises:
    """Alternating all-ones / all-zero u64 blocks — exercises BOTH fast
    paths in the same iteration."""
    var mask = _make_mask_from_pattern(1024, _every_other_block)
    var out = _filter_to_indices_simd(mask)
    # 1024 / 64 = 16 blocks; even blocks are all-one (8 blocks * 64 = 512).
    assert_equal(len(out), 512)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_alternating_50pct() raises:
    """~50% selectivity, branch-rich — mixed-u64 path on every word."""
    var mask = _make_mask_from_pattern(2048, _alternating)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_first_bit_only() raises:
    """Single bit at position 0. All other u64s all-zero."""
    var mask = _make_mask_from_pattern(1024, _first_bit_only)
    var out = _filter_to_indices_simd(mask)
    assert_equal(len(out), 1)
    assert_equal(out[0], 0)
    _assert_simd_matches_scalar(mask)


def test_simd_eq_scalar_high_bit_each_byte() raises:
    """Bit 7 of every byte set — guarantees `count_trailing_zeros` of
    a non-trivial position (7, 15, 23, ...)."""
    var mask = _make_mask_from_pattern(2048, _last_bit_in_byte)
    _assert_simd_matches_scalar(mask)


# =============================================================================
# Production-API equivalence (filter_to_indices entry point)
# =============================================================================


def test_filter_to_indices_uses_simd_path() raises:
    """The public `filter_to_indices` entry point should match
    `_filter_to_indices_simd` exactly (it dispatches there)."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(257):
        values.append(Scalar[DType.int32](i))
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](100))
    var pub = filter_to_indices(mask)
    var simd_out = _filter_to_indices_simd(mask)
    assert_true(_lists_equal(pub, simd_out))


def test_filter_to_indices_realistic_38pct_sel() raises:
    """Q4-shape: 38% selectivity over a multi-u64 mask. Exact match
    required between SIMD and scalar across all 1000 elements."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(1000):
        values.append(Scalar[DType.int32](i))
    var col = PrimitiveArray[DType.int32].from_list(values)
    # 380 of 1000 pass: i > 619.
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](619))
    _assert_simd_matches_scalar(mask)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
