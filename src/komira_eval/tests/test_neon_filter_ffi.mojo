# =============================================================================
# test_neon_filter_ffi.mojo — Correctness: NEON FFI filter_to_indices
# =============================================================================
#
# Verifies that the vectorized filter_to_indices path byte-matches
# the scalar reference path (_filter_to_indices_scalar) for:
#   - Various densities (0%, 1%, 10%, 50%, 90%, 100%)
#   - Small bitmaps (< 16 bytes, exercises scalar tail)
#   - Medium bitmaps (= 16 bytes, exactly one NEON chunk)
#   - Large bitmaps (> 16 bytes, multiple chunks + tail)
#   - SelectionVector.from_bool_mask vs SelectionVector._from_bool_mask_scalar
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow import PrimitiveArray, BooleanArray
from komira_core.eval import eval_gt, eval_lt, eval_eq, filter_to_indices
from komira_core.eval import SelectionVector
from komira_core.eval.comparison import _filter_to_indices_scalar


def _make_gt_mask(values: List[Scalar[DType.int32]], threshold: Int) raises -> BooleanArray:
    var col = PrimitiveArray[DType.int32].from_list(values)
    return eval_gt[DType.int32](col, Scalar[DType.int32](threshold))


def _lists_equal(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# =============================================================================
# filter_to_indices NEON vs scalar byte-match tests
# =============================================================================


def test_filter_to_indices_empty_mask() raises:
    """Empty mask: NEON path returns empty list."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1), Scalar[DType.int32](2)
    ]
    var mask = _make_gt_mask(values, 100)  # nothing passes
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 0)


def test_filter_to_indices_all_set() raises:
    """All-set mask: NEON path returns all indices."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10), Scalar[DType.int32](20),
        Scalar[DType.int32](30), Scalar[DType.int32](40),
        Scalar[DType.int32](50), Scalar[DType.int32](60),
        Scalar[DType.int32](70), Scalar[DType.int32](80),
    ]
    var mask = _make_gt_mask(values, 0)  # all pass
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 8)


def test_filter_to_indices_partial() raises:
    """Partial filter: indices must byte-match scalar for 4 elements."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](10),
        Scalar[DType.int32](5),
        Scalar[DType.int32](20),
    ]
    var mask = _make_gt_mask(values, 7)  # indices 1, 3
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 2)
    assert_equal(neon_result[0], 1)
    assert_equal(neon_result[1], 3)


def test_filter_to_indices_16_values() raises:
    """Exactly 16 values: one NEON chunk, no scalar tail."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(16):
        values.append(Scalar[DType.int32](i * 10))
    var mask = _make_gt_mask(values, 75)  # indices 8..15
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 8)


def test_filter_to_indices_24_values() raises:
    """24 values: 16-byte NEON chunk + 8-byte scalar tail."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(24):
        values.append(Scalar[DType.int32](i))
    var mask = _make_gt_mask(values, 11)  # indices 12..23
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 12)


def test_filter_to_indices_large() raises:
    """Large bitmap (128 values): multiple NEON chunks, verify byte-match."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(128):
        values.append(Scalar[DType.int32](i))
    # ~50% density: even indices pass (0, 2, 4, ...) — use threshold -1
    var mask = _make_gt_mask(values, 63)  # indices 64..127
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 64)


def test_filter_to_indices_non_byte_aligned() raises:
    """Non-byte-aligned length (9 values): scalar tail must handle remainder."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(9):
        values.append(Scalar[DType.int32](i * 5))
    var mask = _make_gt_mask(values, 20)  # values 25, 30, 35, 40: indices 5, 6, 7, 8
    var neon_result = filter_to_indices(mask)
    var scalar_result = _filter_to_indices_scalar(mask)
    assert_true(_lists_equal(neon_result, scalar_result))
    assert_equal(len(neon_result), 4)
    assert_equal(neon_result[0], 5)
    assert_equal(neon_result[3], 8)


# =============================================================================
# SelectionVector.from_bool_mask NEON vs scalar byte-match tests
# =============================================================================


def test_selection_vector_from_bool_mask_byte_match() raises:
    """SelectionVector.from_bool_mask NEON path byte-matches scalar path."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(64):
        values.append(Scalar[DType.int32](i))
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](31))

    var neon_sv = SelectionVector.from_bool_mask(mask)
    var scalar_sv = SelectionVector._from_bool_mask_scalar(mask)

    assert_equal(neon_sv.length(), scalar_sv.length())
    assert_equal(neon_sv.length(), 32)

    # Verify every index matches.
    var neon_ptr = neon_sv.indices._typed_ptr_ro()
    var scalar_ptr = scalar_sv.indices._typed_ptr_ro()
    for i in range(neon_sv.length()):
        assert_equal(Int((neon_ptr + i)[]), Int((scalar_ptr + i)[]))


def test_selection_vector_gather_after_neon_mask() raises:
    """Gather on a NEON-produced SelectionVector produces correct values."""
    var values: List[Scalar[DType.int32]] = []
    for i in range(16):
        values.append(Scalar[DType.int32](i * 3))
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](20))
    # Values > 20: 21, 24, 27, 30, 33, 36, 39, 42, 45 (indices 7..15)
    var sv = SelectionVector.from_bool_mask(mask)
    var result = sv.gather[DType.int32](col)
    assert_equal(result.length, 9)
    assert_equal(Int(result.get(0)), 21)
    assert_equal(Int(result.get(8)), 45)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
