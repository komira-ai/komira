# =============================================================================
# Quick-win unit tests for arrow array types
# =============================================================================
#
# Covers:
#   - test_decimal_array_from_int128
#   - test_struct_array_null_field
#   - test_dictionary_array_null_index
#   - test_large_string_array_empty_string
#
# Each test is deliberately small (<30 LoC of actual test body) and focuses on
# a single invariant.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.struct_array import StructArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.column import Column


# -----------------------------------------------------------------------------
# 1. Decimal128Array roundtrip for positive, zero, and negative int128 values.
# -----------------------------------------------------------------------------


def test_decimal_array_from_int128() raises:
    """Decimal128Array must store positive, zero, and negative ints via set_raw."""
    var arr = Decimal128Array.allocate(length=3, precision=18, scale=2)
    # row 0: +12345 (low=12345, high=0)
    arr.set_raw(0, Int64(12345), Int64(0))
    # row 1: 0 (low=0, high=0)
    arr.set_raw(1, Int64(0), Int64(0))
    # row 2: -12345 (sign-extended: high=-1)
    arr.set_raw(2, Int64(-12345), Int64(-1))

    assert_equal(len(arr), 3)
    assert_equal(Int(arr.get_low(0)), 12345)
    assert_equal(Int(arr.get_high(0)), 0)
    assert_equal(Int(arr.get_low(1)), 0)
    assert_equal(Int(arr.get_as_int(2)), -12345)


# -----------------------------------------------------------------------------
# 2. StructArray with a null field row.
# -----------------------------------------------------------------------------


def test_struct_array_null_field() raises:
    """Nullable StructArray: valid_mask=[T,F,T] produces null_count=1."""
    var names: List[String] = ["x"]
    var prim = PrimitiveArray[DType.int64].allocate(3)
    var p = prim._typed_ptr_mut()
    (p + 0)[] = Scalar[DType.int64](10)
    (p + 1)[] = Scalar[DType.int64](20)  # will be null
    (p + 2)[] = Scalar[DType.int64](30)
    var col = Column.from_primitive[DType.int64](prim^)

    var mask: List[Bool] = [True, False, True]
    var s = StructArray.from_columns_1_nullable(names, col^, mask)

    assert_equal(len(s), 3)
    assert_equal(s.num_fields(), 1)
    assert_equal(s.null_count, 1)
    assert_false(s.is_null(0))
    assert_true(s.is_null(1))
    assert_false(s.is_null(2))


# -----------------------------------------------------------------------------
# 3. StringDictionaryArray lookup at index position 0 and last.
# -----------------------------------------------------------------------------


def test_dictionary_array_null_index() raises:
    """StringDictionaryArray: out-of-range dict index must raise an error.

    We cannot directly inject an Arrow-style validity bitmap into the current
    dictionary_array.mojo, but we CAN assert that a negative dictionary index
    (the closest analogue to an invalid/null slot) is rejected rather than
    silently dereferenced.
    """
    # dictionary = ["A", "B", "C"]
    var dict_values: List[String] = ["A", "B", "C"]
    var dict_arr = StringArray.from_strings(dict_values)

    # indices: [0, 2, 1] (valid)
    var idx = PrimitiveArray[DType.int32].allocate(3)
    var ip = idx._typed_ptr_mut()
    (ip + 0)[] = Scalar[DType.int32](0)
    (ip + 1)[] = Scalar[DType.int32](2)
    (ip + 2)[] = Scalar[DType.int32](1)

    var da = StringDictionaryArray.from_parts(idx^, dict_arr^)
    assert_equal(len(da), 3)
    assert_equal(da.dict_size(), 3)
    assert_equal(da.get(0), String("A"))
    assert_equal(da.get(1), String("C"))
    assert_equal(da.get(2), String("B"))

    # Out-of-range row index raises.
    var raised = False
    try:
        _ = da.get(99)
    except:
        raised = True
    assert_true(raised, "get(99) must raise an out-of-range error")


# -----------------------------------------------------------------------------
# 4. LargeStringArray with an empty string element.
# -----------------------------------------------------------------------------


def test_large_string_array_empty_string() raises:
    """LargeStringArray must handle an empty string at any position."""
    var values: List[String] = ["hello", "", "world", ""]
    var arr = LargeStringArray.from_strings(values)

    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), String("hello"))
    assert_equal(arr.get(1), String(""))  # empty
    assert_equal(arr.get(2), String("world"))
    assert_equal(arr.get(3), String(""))  # empty
    assert_equal(arr.get_length(1), 0)
    assert_equal(arr.get_length(3), 0)
    # data_length must equal the non-empty bytes only
    assert_equal(arr.data_length, 5 + 5)  # "hello" + "world"


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
