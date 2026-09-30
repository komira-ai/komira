# =============================================================================
# Tests for ListArray and StructArray — Arrow nested array types
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.list_array import ListArray
from komira_core.arrow.struct_array import StructArray
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.arrow_types import ArrowType


# =============================================================================
# ListArray tests
# =============================================================================


def test_list_from_int_lists_basic() raises:
    """Create a ListArray from [[1,2,3], [4,5], [6]] and verify length."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [1, 2, 3]
    var l1: List[Int] = [4, 5]
    var l2: List[Int] = [6]
    lists.append(l0^)
    lists.append(l1^)
    lists.append(l2^)
    var arr = ListArray.from_int_lists(lists)
    assert_equal(len(arr), 3)
    assert_equal(arr.null_count, 0)
    assert_equal(arr.total_values(), 6)


def test_list_get_offset() raises:
    """Verify get_offset returns correct child start indices."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [1, 2, 3]
    var l1: List[Int] = [4, 5]
    var l2: List[Int] = [6]
    lists.append(l0^)
    lists.append(l1^)
    lists.append(l2^)
    var arr = ListArray.from_int_lists(lists)
    assert_equal(arr.get_offset(0), 0)
    assert_equal(arr.get_offset(1), 3)
    assert_equal(arr.get_offset(2), 5)


def test_list_get_length() raises:
    """Verify get_length returns correct element counts."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [1, 2, 3]
    var l1: List[Int] = [4, 5]
    var l2: List[Int] = [6]
    lists.append(l0^)
    lists.append(l1^)
    lists.append(l2^)
    var arr = ListArray.from_int_lists(lists)
    assert_equal(arr.get_length(0), 3)
    assert_equal(arr.get_length(1), 2)
    assert_equal(arr.get_length(2), 1)


def test_list_empty_element() raises:
    """An empty list element [] has length 0 and correct offsets."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [10, 20]
    var l1: List[Int] = List[Int]()  # empty
    var l2: List[Int] = [30]
    lists.append(l0^)
    lists.append(l1^)
    lists.append(l2^)
    var arr = ListArray.from_int_lists(lists)
    assert_equal(len(arr), 3)
    assert_equal(arr.get_length(0), 2)
    assert_equal(arr.get_length(1), 0)  # empty list
    assert_equal(arr.get_length(2), 1)
    assert_equal(arr.get_offset(1), 2)  # empty list starts where list 0 ends
    assert_equal(arr.get_offset(2), 2)  # same offset since list 1 was empty
    assert_equal(arr.total_values(), 3)


def test_list_single_element_lists() raises:
    """Each list contains exactly one element."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [100]
    var l1: List[Int] = [200]
    var l2: List[Int] = [300]
    lists.append(l0^)
    lists.append(l1^)
    lists.append(l2^)
    var arr = ListArray.from_int_lists(lists)
    assert_equal(len(arr), 3)
    for i in range(3):
        assert_equal(arr.get_length(i), 1)
    assert_equal(arr.total_values(), 3)


def test_list_is_null_no_bitmap() raises:
    """All elements report non-null when no validity bitmap."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [1]
    var l1: List[Int] = [2]
    lists.append(l0^)
    lists.append(l1^)
    var arr = ListArray.from_int_lists(lists)
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))


def test_list_is_null_with_bitmap() raises:
    """Null elements report correctly when validity bitmap is present."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [1, 2]
    var l1: List[Int] = [3]
    var l2: List[Int] = [4, 5]
    lists.append(l0^)
    lists.append(l1^)
    lists.append(l2^)
    var mask: List[Bool] = [True, False, True]
    var arr = ListArray.from_int_lists_nullable(lists, mask)
    assert_false(arr.is_null(0))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_equal(arr.null_count, 1)


def test_list_empty_array() raises:
    """A ListArray with zero lists is valid."""
    var lists = List[List[Int]]()
    var arr = ListArray.from_int_lists(lists)
    assert_equal(len(arr), 0)
    assert_equal(arr.total_values(), 0)
    assert_equal(arr.null_count, 0)


def test_list_single_list() raises:
    """A ListArray with exactly one list element."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [10, 20, 30, 40]
    lists.append(l0^)
    var arr = ListArray.from_int_lists(lists)
    assert_equal(len(arr), 1)
    assert_equal(arr.get_offset(0), 0)
    assert_equal(arr.get_length(0), 4)
    assert_equal(arr.total_values(), 4)


def test_list_child_column_type() raises:
    """The child column has the correct arrow_type (INT64)."""
    var lists = List[List[Int]]()
    var l0: List[Int] = [1, 2]
    lists.append(l0^)
    var arr = ListArray.from_int_lists(lists)
    assert_true(arr.child.arrow_type == ArrowType.INT64)


# =============================================================================
# StructArray tests
# =============================================================================


def test_struct_from_columns_basic() raises:
    """Create a StructArray from int + float columns."""
    var int_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
    ]
    var float_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.5),
        Scalar[DType.float64](3.5),
    ]
    var int_arr = PrimitiveArray[DType.int64].from_list(int_vals)
    var float_arr = PrimitiveArray[DType.float64].from_list(float_vals)
    var col0 = Column.from_primitive[DType.int64](int_arr)
    var col1 = Column.from_primitive[DType.float64](float_arr)
    var names: List[String] = ["age", "score"]
    var arr = StructArray.from_columns_2(names, col0^, col1^)
    assert_equal(len(arr), 3)
    assert_equal(arr.num_fields(), 2)
    assert_equal(arr.null_count, 0)


def test_struct_field_name() raises:
    """Verify field_name returns the correct name at each index."""
    var int_vals: List[Scalar[DType.int64]] = [Scalar[DType.int64](10)]
    var float_vals: List[Scalar[DType.float64]] = [Scalar[DType.float64](1.0)]
    var int_arr = PrimitiveArray[DType.int64].from_list(int_vals)
    var float_arr = PrimitiveArray[DType.float64].from_list(float_vals)
    var col0 = Column.from_primitive[DType.int64](int_arr)
    var col1 = Column.from_primitive[DType.float64](float_arr)
    var names: List[String] = ["id", "value"]
    var arr = StructArray.from_columns_2(names, col0^, col1^)
    assert_equal(arr.field_name(0), "id")
    assert_equal(arr.field_name(1), "value")


def test_struct_num_fields() raises:
    """Verify num_fields returns the correct count."""
    var vals1: List[Scalar[DType.int32]] = [Scalar[DType.int32](1)]
    var vals2: List[Scalar[DType.int32]] = [Scalar[DType.int32](2)]
    var vals3: List[Scalar[DType.int32]] = [Scalar[DType.int32](3)]
    var arr1 = PrimitiveArray[DType.int32].from_list(vals1)
    var arr2 = PrimitiveArray[DType.int32].from_list(vals2)
    var arr3 = PrimitiveArray[DType.int32].from_list(vals3)
    var c1 = Column.from_primitive[DType.int32](arr1)
    var c2 = Column.from_primitive[DType.int32](arr2)
    var c3 = Column.from_primitive[DType.int32](arr3)
    var names: List[String] = ["a", "b", "c"]
    var arr = StructArray.from_columns_3(names, c1^, c2^, c3^)
    assert_equal(arr.num_fields(), 3)


def test_struct_is_null_no_bitmap() raises:
    """All rows report non-null when no validity bitmap."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
    ]
    var int_arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](int_arr)
    var names: List[String] = ["x"]
    var arr = StructArray.from_columns_1(names, col^)
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))


def test_struct_is_null_with_bitmap() raises:
    """Null rows report correctly when validity bitmap is present."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
    ]
    var int_arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](int_arr)
    var names: List[String] = ["x"]
    var mask: List[Bool] = [True, False, True]
    var arr = StructArray.from_columns_1_nullable(names, col^, mask)
    assert_false(arr.is_null(0))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_equal(arr.null_count, 1)


def test_struct_len() raises:
    """Verify __len__ returns the number of rows."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
        Scalar[DType.int64](4),
    ]
    var int_arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](int_arr)
    var names: List[String] = ["data"]
    var arr = StructArray.from_columns_1(names, col^)
    assert_equal(len(arr), 4)


def test_struct_empty_zero_rows() raises:
    """A StructArray with fields but 0 rows is valid."""
    var vals: List[Scalar[DType.int64]] = List[Scalar[DType.int64]]()
    var int_arr = PrimitiveArray[DType.int64].from_list(vals)
    var col = Column.from_primitive[DType.int64](int_arr)
    var names: List[String] = ["empty_field"]
    var arr = StructArray.from_columns_1(names, col^)
    assert_equal(len(arr), 0)
    assert_equal(arr.num_fields(), 1)
    assert_equal(arr.null_count, 0)


def test_struct_no_fields() raises:
    """A StructArray with 0 fields is valid (empty struct)."""
    var arr = StructArray()
    assert_equal(len(arr), 0)
    assert_equal(arr.num_fields(), 0)


def test_struct_mismatched_lengths_raises() raises:
    """Raises when child columns have different lengths."""
    var vals2: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
    ]
    var vals3: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
    ]
    var arr2 = PrimitiveArray[DType.int64].from_list(vals2)
    var arr3 = PrimitiveArray[DType.int64].from_list(vals3)
    var c1 = Column.from_primitive[DType.int64](arr2)
    var c2 = Column.from_primitive[DType.int64](arr3)
    var names: List[String] = ["a", "b"]
    var raised = False
    try:
        var arr = StructArray.from_columns_2(names, c1^, c2^)
    except:
        raised = True
    assert_true(raised)


def test_struct_child_arrow_types() raises:
    """Children preserve their arrow_type through Column wrapping."""
    var int_vals: List[Scalar[DType.int32]] = [Scalar[DType.int32](1)]
    var float_vals: List[Scalar[DType.float64]] = [Scalar[DType.float64](1.0)]
    var int_arr = PrimitiveArray[DType.int32].from_list(int_vals)
    var float_arr = PrimitiveArray[DType.float64].from_list(float_vals)
    var c1 = Column.from_primitive[DType.int32](int_arr)
    var c2 = Column.from_primitive[DType.float64](float_arr)
    var names: List[String] = ["i", "f"]
    var arr = StructArray.from_columns_2(names, c1^, c2^)
    assert_true(arr.child_at(0).arrow_type == ArrowType.INT32)
    assert_true(arr.child_at(1).arrow_type == ArrowType.FLOAT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
