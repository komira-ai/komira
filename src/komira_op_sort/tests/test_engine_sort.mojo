# =============================================================================
# Tests for the sort engine
# =============================================================================
#
# Tests cover:
#   - Ascending sort (Int64 and Float64)
#   - Descending sort (Int64 and Float64)
#   - Stability: equal elements maintain relative order
#   - Single element array
#   - Empty array
#   - Already-sorted input
#   - Reverse-sorted input
#   - Duplicate keys
#   - Large array (1000+ elements)
#   - Gather by indices (reorder data using permutation)
#   - Negative values
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort import (
    sort_indices_int64,
    sort_indices_float64,
    gather_by_indices_int64,
    gather_by_indices_float64,
)
from komira_op_sort.sort_topn import topn_indices_int64, topn_indices_float64


# =============================================================================
# Int64 sort tests
# =============================================================================


def test_sort_int64_ascending() raises:
    """Sort Int64 in ascending order returns correct permutation."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50), Int64(20), Int64(40),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    # Expected order: 10, 20, 30, 40, 50
    # Original indices: 1, 3, 0, 4, 2
    assert_equal(indices.length, 5)

    # Verify sorted order by gathering
    var sorted_arr = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted_arr.get(0)), 10)
    assert_equal(Int(sorted_arr.get(1)), 20)
    assert_equal(Int(sorted_arr.get(2)), 30)
    assert_equal(Int(sorted_arr.get(3)), 40)
    assert_equal(Int(sorted_arr.get(4)), 50)


def test_sort_int64_descending() raises:
    """Sort Int64 in descending order returns correct permutation."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50), Int64(20), Int64(40),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys, descending=True)

    # Expected order: 50, 40, 30, 20, 10
    var sorted_arr = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted_arr.get(0)), 50)
    assert_equal(Int(sorted_arr.get(1)), 40)
    assert_equal(Int(sorted_arr.get(2)), 30)
    assert_equal(Int(sorted_arr.get(3)), 20)
    assert_equal(Int(sorted_arr.get(4)), 10)


def test_sort_int64_stability() raises:
    """Equal Int64 elements maintain their relative order (stable sort).

    Keys: [5, 3, 5, 1, 3]
    Group 5 at positions 0, 2 -- should remain in order 0, 2
    Group 3 at positions 1, 4 -- should remain in order 1, 4
    """
    var vals: List[Scalar[DType.int64]] = [
        Int64(5), Int64(3), Int64(5), Int64(1), Int64(3),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    # Expected sorted order: 1, 3, 3, 5, 5
    # Expected indices: [3, 1, 4, 0, 2]
    # Key: position 3 (val=1), then 1 (val=3), then 4 (val=3), then 0 (val=5), then 2 (val=5)
    assert_equal(Int(indices.get(0)), 3)  # val=1
    assert_equal(Int(indices.get(1)), 1)  # val=3 (first 3)
    assert_equal(Int(indices.get(2)), 4)  # val=3 (second 3)
    assert_equal(Int(indices.get(3)), 0)  # val=5 (first 5)
    assert_equal(Int(indices.get(4)), 2)  # val=5 (second 5)


def test_sort_int64_single_element() raises:
    """Single element array returns index [0]."""
    var vals: List[Scalar[DType.int64]] = [Int64(42)]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    assert_equal(indices.length, 1)
    assert_equal(Int(indices.get(0)), 0)


def test_sort_int64_empty() raises:
    """Empty array returns empty indices."""
    var vals: List[Scalar[DType.int64]] = []
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    assert_equal(indices.length, 0)


def test_sort_int64_already_sorted() raises:
    """Already-sorted input returns identity permutation."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(1), Int64(2), Int64(3), Int64(4), Int64(5),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    for i in range(5):
        assert_equal(Int(indices.get(i)), i)


def test_sort_int64_reverse_sorted() raises:
    """Reverse-sorted input is correctly reversed."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(5), Int64(4), Int64(3), Int64(2), Int64(1),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    var sorted_arr = gather_by_indices_int64(keys, indices)
    for i in range(5):
        assert_equal(Int(sorted_arr.get(i)), i + 1)


def test_sort_int64_all_duplicates() raises:
    """All equal elements -- indices should be identity (stable)."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(7), Int64(7), Int64(7), Int64(7),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    # Stability means original order is preserved.
    for i in range(4):
        assert_equal(Int(indices.get(i)), i)


def test_sort_int64_negative_values() raises:
    """Negative Int64 values are handled correctly."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(5), Int64(-10), Int64(0), Int64(-3), Int64(100),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    var sorted_arr = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted_arr.get(0)), -10)
    assert_equal(Int(sorted_arr.get(1)), -3)
    assert_equal(Int(sorted_arr.get(2)), 0)
    assert_equal(Int(sorted_arr.get(3)), 5)
    assert_equal(Int(sorted_arr.get(4)), 100)


def test_sort_int64_large() raises:
    """Sort 1000 elements (exercises merge sort, not just insertion sort)."""
    # Generate values: 999, 998, ..., 0 (reverse order)
    var vals: List[Scalar[DType.int64]] = []
    for i in range(1000):
        vals.append(Scalar[DType.int64](999 - i))
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys)

    var sorted_arr = gather_by_indices_int64(keys, indices)
    for i in range(1000):
        assert_equal(Int(sorted_arr.get(i)), i)


# =============================================================================
# Float64 sort tests
# =============================================================================


def test_sort_float64_ascending() raises:
    """Sort Float64 in ascending order."""
    var vals: List[Scalar[DType.float64]] = [
        Float64(3.3), Float64(1.1), Float64(5.5), Float64(2.2), Float64(4.4),
    ]
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys)

    var sorted_arr = gather_by_indices_float64(keys, indices)
    assert_equal(Float64(sorted_arr.get(0)), 1.1)
    assert_equal(Float64(sorted_arr.get(1)), 2.2)
    assert_equal(Float64(sorted_arr.get(2)), 3.3)
    assert_equal(Float64(sorted_arr.get(3)), 4.4)
    assert_equal(Float64(sorted_arr.get(4)), 5.5)


def test_sort_float64_descending() raises:
    """Sort Float64 in descending order."""
    var vals: List[Scalar[DType.float64]] = [
        Float64(3.3), Float64(1.1), Float64(5.5), Float64(2.2), Float64(4.4),
    ]
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys, descending=True)

    var sorted_arr = gather_by_indices_float64(keys, indices)
    assert_equal(Float64(sorted_arr.get(0)), 5.5)
    assert_equal(Float64(sorted_arr.get(1)), 4.4)
    assert_equal(Float64(sorted_arr.get(2)), 3.3)
    assert_equal(Float64(sorted_arr.get(3)), 2.2)
    assert_equal(Float64(sorted_arr.get(4)), 1.1)


def test_sort_float64_stability() raises:
    """Equal Float64 elements maintain relative order (stable sort).

    Keys: [2.0, 1.0, 2.0, 3.0, 1.0]
    Group 1.0 at positions 1, 4 -- should remain in order 1, 4
    Group 2.0 at positions 0, 2 -- should remain in order 0, 2
    """
    var vals: List[Scalar[DType.float64]] = [
        Float64(2.0), Float64(1.0), Float64(2.0), Float64(3.0), Float64(1.0),
    ]
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys)

    # Expected: [1, 4, 0, 2, 3]
    assert_equal(Int(indices.get(0)), 1)  # val=1.0 (first)
    assert_equal(Int(indices.get(1)), 4)  # val=1.0 (second)
    assert_equal(Int(indices.get(2)), 0)  # val=2.0 (first)
    assert_equal(Int(indices.get(3)), 2)  # val=2.0 (second)
    assert_equal(Int(indices.get(4)), 3)  # val=3.0


def test_sort_float64_empty() raises:
    """Empty Float64 array returns empty indices."""
    var vals: List[Scalar[DType.float64]] = []
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys)

    assert_equal(indices.length, 0)


def test_sort_float64_single() raises:
    """Single Float64 element returns index [0]."""
    var vals: List[Scalar[DType.float64]] = [Float64(42.0)]
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys)

    assert_equal(indices.length, 1)
    assert_equal(Int(indices.get(0)), 0)


def test_sort_float64_negative() raises:
    """Negative Float64 values are sorted correctly."""
    var vals: List[Scalar[DType.float64]] = [
        Float64(0.0), Float64(-1.5), Float64(2.5), Float64(-3.0), Float64(1.0),
    ]
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys)

    var sorted_arr = gather_by_indices_float64(keys, indices)
    assert_equal(Float64(sorted_arr.get(0)), -3.0)
    assert_equal(Float64(sorted_arr.get(1)), -1.5)
    assert_equal(Float64(sorted_arr.get(2)), 0.0)
    assert_equal(Float64(sorted_arr.get(3)), 1.0)
    assert_equal(Float64(sorted_arr.get(4)), 2.5)


def test_sort_float64_large() raises:
    """Sort 1000 Float64 elements."""
    var vals: List[Scalar[DType.float64]] = []
    for i in range(1000):
        vals.append(Scalar[DType.float64](Float64(999 - i)))
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = sort_indices_float64(keys)

    var sorted_arr = gather_by_indices_float64(keys, indices)
    for i in range(1000):
        assert_equal(Float64(sorted_arr.get(i)), Float64(i))


# =============================================================================
# Gather tests
# =============================================================================


def test_gather_int64_identity() raises:
    """Gathering with identity permutation returns original array."""
    var vals: List[Scalar[DType.int64]] = [Int64(10), Int64(20), Int64(30)]
    var data = PrimitiveArray[DType.int64].from_list(vals)

    var idx_vals: List[Scalar[DType.int32]] = [Int32(0), Int32(1), Int32(2)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_vals)

    var result = gather_by_indices_int64(data, indices)
    assert_equal(Int(result.get(0)), 10)
    assert_equal(Int(result.get(1)), 20)
    assert_equal(Int(result.get(2)), 30)


def test_gather_int64_reverse() raises:
    """Gathering with reverse permutation reverses the array."""
    var vals: List[Scalar[DType.int64]] = [Int64(10), Int64(20), Int64(30)]
    var data = PrimitiveArray[DType.int64].from_list(vals)

    var idx_vals: List[Scalar[DType.int32]] = [Int32(2), Int32(1), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_vals)

    var result = gather_by_indices_int64(data, indices)
    assert_equal(Int(result.get(0)), 30)
    assert_equal(Int(result.get(1)), 20)
    assert_equal(Int(result.get(2)), 10)


def test_gather_float64_reorder() raises:
    """Gathering reorders Float64 data correctly."""
    var vals: List[Scalar[DType.float64]] = [Float64(1.0), Float64(2.0), Float64(3.0)]
    var data = PrimitiveArray[DType.float64].from_list(vals)

    var idx_vals: List[Scalar[DType.int32]] = [Int32(1), Int32(2), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_vals)

    var result = gather_by_indices_float64(data, indices)
    assert_equal(Float64(result.get(0)), 2.0)
    assert_equal(Float64(result.get(1)), 3.0)
    assert_equal(Float64(result.get(2)), 1.0)


# =============================================================================
# Descending stability test
# =============================================================================


def test_sort_int64_descending_stability() raises:
    """Descending sort is stable: equal elements keep relative order.

    Keys: [3, 1, 3, 2, 1]
    For descending: 3 (pos 0, 2), 2 (pos 3), 1 (pos 1, 4)
    Expected indices: [0, 2, 3, 1, 4]
    """
    var vals: List[Scalar[DType.int64]] = [
        Int64(3), Int64(1), Int64(3), Int64(2), Int64(1),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = sort_indices_int64(keys, descending=True)

    assert_equal(Int(indices.get(0)), 0)  # val=3 (first)
    assert_equal(Int(indices.get(1)), 2)  # val=3 (second)
    assert_equal(Int(indices.get(2)), 3)  # val=2
    assert_equal(Int(indices.get(3)), 1)  # val=1 (first)
    assert_equal(Int(indices.get(4)), 4)  # val=1 (second)


# =============================================================================
# TopN heap-select tests
# =============================================================================


def test_topn_int64_descending_basic() raises:
    """TopN descending K=3 from 5 elements returns 3 largest in desc order."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50), Int64(20), Int64(40),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = topn_indices_int64(keys, 3, descending=True)

    assert_equal(indices.length, 3)
    # Top 3 descending: 50 (idx=2), 40 (idx=4), 30 (idx=0)
    var sorted = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted.get(0)), 50)
    assert_equal(Int(sorted.get(1)), 40)
    assert_equal(Int(sorted.get(2)), 30)


def test_topn_int64_ascending_basic() raises:
    """TopN ascending K=3 from 5 elements returns 3 smallest in asc order."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50), Int64(20), Int64(40),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = topn_indices_int64(keys, 3, descending=False)

    assert_equal(indices.length, 3)
    # Top 3 ascending: 10 (idx=1), 20 (idx=3), 30 (idx=0)
    var sorted = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted.get(0)), 10)
    assert_equal(Int(sorted.get(1)), 20)
    assert_equal(Int(sorted.get(2)), 30)


def test_topn_int64_k_equals_n() raises:
    """TopN with K >= N returns all elements sorted."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = topn_indices_int64(keys, 5, descending=True)

    assert_equal(indices.length, 3)
    var sorted = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted.get(0)), 50)
    assert_equal(Int(sorted.get(1)), 30)
    assert_equal(Int(sorted.get(2)), 10)


def test_topn_int64_k_equals_1() raises:
    """TopN with K=1 returns the single best element."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50), Int64(20), Int64(40),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var desc = topn_indices_int64(keys, 1, descending=True)
    assert_equal(desc.length, 1)
    assert_equal(Int(keys.get(Int(desc.get(0)))), 50)

    var asc = topn_indices_int64(keys, 1, descending=False)
    assert_equal(asc.length, 1)
    assert_equal(Int(keys.get(Int(asc.get(0)))), 10)


def test_topn_int64_empty() raises:
    """TopN on empty array returns empty."""
    var keys = PrimitiveArray[DType.int64].allocate(0)
    var indices = topn_indices_int64(keys, 5, descending=True)
    assert_equal(indices.length, 0)


def test_topn_int64_duplicates() raises:
    """TopN with duplicate values returns correct top K."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(50), Int64(50), Int64(30), Int64(10),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var indices = topn_indices_int64(keys, 3, descending=True)

    assert_equal(indices.length, 3)
    var sorted = gather_by_indices_int64(keys, indices)
    assert_equal(Int(sorted.get(0)), 50)
    assert_equal(Int(sorted.get(1)), 50)
    assert_equal(Int(sorted.get(2)), 30)


def test_topn_int64_large() raises:
    """TopN K=10 from 1000 elements."""
    var arr = PrimitiveArray[DType.int64].allocate(1000)
    var ptr = arr._typed_ptr_mut()
    for i in range(1000):
        (ptr + i)[] = Scalar[DType.int64](i)  # 0, 1, 2, ..., 999

    var indices = topn_indices_int64(arr, 10, descending=True)
    assert_equal(indices.length, 10)

    # Top 10 descending should be 999, 998, ..., 990
    var sorted = gather_by_indices_int64(arr, indices)
    for i in range(10):
        assert_equal(Int(sorted.get(i)), 999 - i)


def test_topn_int64_negative_values() raises:
    """TopN handles negative values correctly."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(-10), Int64(-30), Int64(20), Int64(-5), Int64(10),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)

    var desc = topn_indices_int64(keys, 2, descending=True)
    var sorted_desc = gather_by_indices_int64(keys, desc)
    assert_equal(Int(sorted_desc.get(0)), 20)
    assert_equal(Int(sorted_desc.get(1)), 10)

    var asc = topn_indices_int64(keys, 2, descending=False)
    var sorted_asc = gather_by_indices_int64(keys, asc)
    assert_equal(Int(sorted_asc.get(0)), -30)
    assert_equal(Int(sorted_asc.get(1)), -10)


def test_topn_float64_descending() raises:
    """TopN descending for Float64 keys."""
    var vals: List[Scalar[DType.float64]] = [
        Float64(3.14), Float64(1.0), Float64(2.718), Float64(0.5), Float64(1.414),
    ]
    var keys = PrimitiveArray[DType.float64].from_list(vals)
    var indices = topn_indices_float64(keys, 3, descending=True)

    assert_equal(indices.length, 3)
    var sorted = gather_by_indices_float64(keys, indices)
    # Top 3 desc: 3.14, 2.718, 1.414
    assert_true(Float64(sorted.get(0)) > 3.13 and Float64(sorted.get(0)) < 3.15, "expected ~3.14")
    assert_true(Float64(sorted.get(1)) > 2.71 and Float64(sorted.get(1)) < 2.72, "expected ~2.718")
    assert_true(Float64(sorted.get(2)) > 1.41 and Float64(sorted.get(2)) < 1.42, "expected ~1.414")


# =============================================================================
# main -- test runner
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
