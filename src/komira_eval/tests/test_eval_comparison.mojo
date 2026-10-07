# =============================================================================
# Tests for comparison eval — imports from komira_arrow and the core packages
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_column_kernels.comparison import eval_gt, eval_lt, eval_eq, filter_to_indices


def test_eval_gt_basic() raises:
    """eval_gt returns correct boolean mask for > threshold."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](3))
    assert_equal(len(result), 3)
    assert_false(result.get(0))  # 1 > 3 = false
    assert_true(result.get(1))   # 5 > 3 = true
    assert_true(result.get(2))   # 10 > 3 = true


def test_eval_gt_all_pass() raises:
    """eval_gt returns all true when all values exceed threshold."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](5))
    for i in range(3):
        assert_true(result.get(i))


def test_eval_gt_none_pass() raises:
    """eval_gt returns all false when no values exceed threshold."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](100))
    for i in range(3):
        assert_false(result.get(i))


def test_eval_lt_basic() raises:
    """eval_lt returns correct boolean mask for < threshold."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_lt[DType.int32](col, Scalar[DType.int32](5))
    assert_true(result.get(0))   # 1 < 5 = true
    assert_false(result.get(1))  # 5 < 5 = false
    assert_false(result.get(2))  # 10 < 5 = false


def test_eval_eq_basic() raises:
    """eval_eq returns correct boolean mask for == value."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_eq[DType.int32](col, Scalar[DType.int32](5))
    assert_false(result.get(0))  # 1 == 5 = false
    assert_true(result.get(1))   # 5 == 5 = true
    assert_true(result.get(2))   # 5 == 5 = true
    assert_false(result.get(3))  # 10 == 5 = false


def test_filter_to_indices() raises:
    """filter_to_indices converts BooleanArray mask to index list."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
        Scalar[DType.int32](15),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](4))
    var indices = filter_to_indices(mask)
    assert_equal(len(indices), 3)
    assert_equal(indices[0], 1)
    assert_equal(indices[1], 2)
    assert_equal(indices[2], 3)


def test_filter_to_indices_empty() raises:
    """filter_to_indices returns empty list when no matches."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = eval_gt[DType.int32](col, Scalar[DType.int32](100))
    var indices = filter_to_indices(mask)
    assert_equal(len(indices), 0)


def test_eval_gt_float64() raises:
    """eval_gt works with float64 data."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](3.7),
        Scalar[DType.float64](0.1),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var result = eval_gt[DType.float64](col, Scalar[DType.float64](1.0))
    assert_true(result.get(0))   # 1.5 > 1.0
    assert_true(result.get(1))   # 3.7 > 1.0
    assert_false(result.get(2))  # 0.1 > 1.0


# =============================================================================
# SIMD boundary size tests for bit-packing correctness
# Tests at lengths 7, 8, 9, 15, 16, 17, 63, 64, 65
# =============================================================================


def _make_sequential_int32(n: Int) raises -> PrimitiveArray[DType.int32]:
    """Helper: creates PrimitiveArray with values [0, 1, 2, ..., n-1]."""
    var arr = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int32](i))
    return arr^


def _count_true(mask: BooleanArray) raises -> Int:
    """Helper: count the number of True bits in a BooleanArray."""
    var count = 0
    for i in range(mask.length):
        if mask.get(i):
            count += 1
    return count


def test_eval_gt_boundary_7() raises:
    """eval_gt with 7 elements (< 8, all in remainder path)."""
    var col = _make_sequential_int32(7)  # [0,1,2,3,4,5,6]
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](3))
    assert_equal(len(result), 7)
    assert_false(result.get(0))  # 0 > 3 = false
    assert_false(result.get(3))  # 3 > 3 = false
    assert_true(result.get(4))   # 4 > 3 = true
    assert_true(result.get(6))   # 6 > 3 = true
    assert_equal(_count_true(result), 3)  # 4, 5, 6


def test_eval_gt_boundary_8() raises:
    """eval_gt with exactly 8 elements (one full byte, no remainder)."""
    var col = _make_sequential_int32(8)  # [0..7]
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](4))
    assert_equal(len(result), 8)
    assert_false(result.get(4))  # 4 > 4 = false
    assert_true(result.get(5))   # 5 > 4 = true
    assert_equal(_count_true(result), 3)  # 5, 6, 7


def test_eval_gt_boundary_9() raises:
    """eval_gt with 9 elements (one full byte + 1 remainder)."""
    var col = _make_sequential_int32(9)  # [0..8]
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](4))
    assert_equal(len(result), 9)
    assert_true(result.get(5))   # 5 > 4 = true
    assert_true(result.get(8))   # 8 > 4 = true
    assert_equal(_count_true(result), 4)  # 5, 6, 7, 8


def test_eval_gt_boundary_15() raises:
    """eval_gt with 15 elements (one full byte + 7 remainder)."""
    var col = _make_sequential_int32(15)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](7))
    assert_equal(len(result), 15)
    assert_false(result.get(7))  # 7 > 7 = false
    assert_true(result.get(8))   # 8 > 7 = true
    assert_true(result.get(14))  # 14 > 7 = true
    assert_equal(_count_true(result), 7)  # 8..14


def test_eval_gt_boundary_16() raises:
    """eval_gt with 16 elements (two full bytes, no remainder)."""
    var col = _make_sequential_int32(16)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](10))
    assert_equal(len(result), 16)
    assert_false(result.get(10))  # 10 > 10 = false
    assert_true(result.get(11))   # 11 > 10 = true
    assert_true(result.get(15))   # 15 > 10 = true
    assert_equal(_count_true(result), 5)  # 11..15


def test_eval_gt_boundary_17() raises:
    """eval_gt with 17 elements (two full bytes + 1 remainder)."""
    var col = _make_sequential_int32(17)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](10))
    assert_equal(len(result), 17)
    assert_true(result.get(16))  # 16 > 10 = true
    assert_equal(_count_true(result), 6)  # 11..16


def test_eval_gt_boundary_63() raises:
    """eval_gt with 63 elements (7 full bytes + 7 remainder)."""
    var col = _make_sequential_int32(63)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](30))
    assert_equal(len(result), 63)
    assert_false(result.get(30))  # 30 > 30 = false
    assert_true(result.get(31))   # 31 > 30 = true
    assert_true(result.get(62))   # 62 > 30 = true
    assert_equal(_count_true(result), 32)  # 31..62


def test_eval_gt_boundary_64() raises:
    """eval_gt with 64 elements (8 full bytes, no remainder)."""
    var col = _make_sequential_int32(64)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](30))
    assert_equal(len(result), 64)
    assert_true(result.get(63))   # 63 > 30 = true
    assert_equal(_count_true(result), 33)  # 31..63


def test_eval_gt_boundary_65() raises:
    """eval_gt with 65 elements (8 full bytes + 1 remainder)."""
    var col = _make_sequential_int32(65)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](30))
    assert_equal(len(result), 65)
    assert_true(result.get(64))   # 64 > 30 = true
    assert_equal(_count_true(result), 34)  # 31..64


def test_eval_lt_boundary_9() raises:
    """eval_lt with 9 elements to test remainder path."""
    var col = _make_sequential_int32(9)  # [0..8]
    var result = eval_lt[DType.int32](col, Scalar[DType.int32](4))
    assert_equal(len(result), 9)
    assert_true(result.get(0))   # 0 < 4 = true
    assert_true(result.get(3))   # 3 < 4 = true
    assert_false(result.get(4))  # 4 < 4 = false
    assert_equal(_count_true(result), 4)  # 0, 1, 2, 3


def test_eval_lt_boundary_17() raises:
    """eval_lt with 17 elements to test multi-byte + remainder."""
    var col = _make_sequential_int32(17)
    var result = eval_lt[DType.int32](col, Scalar[DType.int32](10))
    assert_equal(len(result), 17)
    assert_true(result.get(0))    # 0 < 10 = true
    assert_true(result.get(9))    # 9 < 10 = true
    assert_false(result.get(10))  # 10 < 10 = false
    assert_equal(_count_true(result), 10)  # 0..9


def test_eval_eq_boundary_9() raises:
    """eval_eq with 9 elements to test remainder path."""
    var col = _make_sequential_int32(9)  # [0..8]
    var result = eval_eq[DType.int32](col, Scalar[DType.int32](8))
    assert_equal(len(result), 9)
    assert_false(result.get(0))  # 0 == 8 = false
    assert_true(result.get(8))   # 8 == 8 = true
    assert_equal(_count_true(result), 1)


def test_eval_eq_boundary_17() raises:
    """eval_eq with 17 elements to test multi-byte + remainder."""
    var col = _make_sequential_int32(17)
    var result = eval_eq[DType.int32](col, Scalar[DType.int32](16))
    assert_equal(len(result), 17)
    assert_true(result.get(16))   # 16 == 16 = true
    assert_false(result.get(15))  # 15 == 16 = false
    assert_equal(_count_true(result), 1)


# =============================================================================
# Empty array test for eval_gt
# =============================================================================


def test_eval_gt_empty() raises:
    """Empty array: eval_gt returns empty BooleanArray."""
    var col = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_gt[DType.int32](col, Scalar[DType.int32](0))
    assert_equal(len(result), 0)


def test_eval_lt_empty() raises:
    """Empty array: eval_lt returns empty BooleanArray."""
    var col = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_lt[DType.int32](col, Scalar[DType.int32](0))
    assert_equal(len(result), 0)


def test_eval_eq_empty() raises:
    """Empty array: eval_eq returns empty BooleanArray."""
    var col = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_eq[DType.int32](col, Scalar[DType.int32](0))
    assert_equal(len(result), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
