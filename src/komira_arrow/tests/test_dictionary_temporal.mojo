# =============================================================================
# Tests for StringDictionaryArray and temporal types (Date32 as PrimitiveArray)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray


# =============================================================================
# StringDictionaryArray Tests
# =============================================================================


def test_dict_create_from_parts() raises:
    """Create a StringDictionaryArray from indices + dictionary and verify structure."""
    var dict_values: List[String] = ["apple", "banana", "cherry"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(1), Int32(2), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(len(arr), 4)
    assert_equal(arr.dict_size(), 3)


def test_dict_get_resolves_correctly() raises:
    """Verify get() resolves through the dictionary to return the correct string."""
    var dict_values: List[String] = ["red", "green", "blue"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(2), Int32(0), Int32(1)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(arr.get(0), "blue")
    assert_equal(arr.get(1), "red")
    assert_equal(arr.get(2), "green")


def test_dict_get_index_returns_raw() raises:
    """Verify get_index() returns the raw integer index, not the resolved string."""
    var dict_values: List[String] = ["x", "y", "z"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(2), Int32(0), Int32(1), Int32(2)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(arr.get_index(0), 2)
    assert_equal(arr.get_index(1), 0)
    assert_equal(arr.get_index(2), 1)
    assert_equal(arr.get_index(3), 2)


def test_dict_multiple_rows_same_entry() raises:
    """Multiple rows pointing to the same dictionary entry all resolve correctly."""
    var dict_values: List[String] = ["only_value"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(0), Int32(0), Int32(0), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(len(arr), 5)
    for i in range(5):
        assert_equal(arr.get(i), "only_value")
        assert_equal(arr.get_index(i), 0)


def test_dict_len() raises:
    """__len__ returns the number of rows, not the dictionary size."""
    var dict_values: List[String] = ["a", "b", "c", "d", "e"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(4)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(len(arr), 2)
    assert_equal(arr.dict_size(), 5)


def test_dict_single_entry() raises:
    """A dictionary with exactly one entry works correctly."""
    var dict_values: List[String] = ["singleton"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(len(arr), 1)
    assert_equal(arr.dict_size(), 1)
    assert_equal(arr.get(0), "singleton")
    assert_equal(arr.get_index(0), 0)


def test_dict_get_out_of_bounds() raises:
    """Verify get() raises on out-of-bounds row index."""
    var dict_values: List[String] = ["a", "b"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(1)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    var raised = False
    try:
        _ = arr.get(5)
    except:
        raised = True
    assert_true(raised)


def test_dict_get_index_out_of_bounds() raises:
    """Verify get_index() raises on out-of-bounds row index."""
    var dict_values: List[String] = ["a"]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    var raised = False
    try:
        _ = arr.get_index(-1)
    except:
        raised = True
    assert_true(raised)


def test_dict_empty_string_values() raises:
    """Dictionary entries can be empty strings."""
    var dict_values: List[String] = ["", "non-empty", ""]
    var dictionary = StringArray.from_strings(dict_values)

    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(1), Int32(2)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)
    assert_equal(arr.get(0), "")
    assert_equal(arr.get(1), "non-empty")
    assert_equal(arr.get(2), "")


# =============================================================================
# Temporal Type Tests — Date32 as PrimitiveArray[DType.int32]
# =============================================================================
#
# Arrow Date32: days since Unix epoch (1970-01-01). No new array type needed;
# PrimitiveArray[DType.int32] carries the values. Semantic type information
# lives in the Schema/Field metadata layer.
# =============================================================================


def test_date32_store_days_since_epoch() raises:
    """Store a date as days-since-epoch and read it back.

    2027-04-02 = 20910 days since 1970-01-01
    (calculated: 57 years * 365 + 14 leap days + 31 Jan + 28 Feb + 31 Mar + 1 = 20910)
    """
    # 2027-04-02 = 20910 days since epoch
    comptime DATE_2027_04_02 = 20910
    var values: List[Scalar[DType.int32]] = [Int32(DATE_2027_04_02)]
    var dates = PrimitiveArray[DType.int32].from_list(values)
    assert_equal(Int(dates.get(0)), DATE_2027_04_02)


def test_date32_arithmetic_add_week() raises:
    """Date arithmetic: adding 7 days yields one week later."""
    comptime DATE_2027_04_02 = 20910
    comptime DATE_2027_04_09 = 20917  # 20910 + 7
    var values: List[Scalar[DType.int32]] = [Int32(DATE_2027_04_02)]
    var dates = PrimitiveArray[DType.int32].from_list(values)
    var result = Int(dates.get(0)) + 7
    assert_equal(result, DATE_2027_04_09)


def test_date32_comparison() raises:
    """Date comparison: earlier dates have smaller integer values."""
    comptime DATE_2027_01_01 = 20819  # Jan 1 2027
    comptime DATE_2027_04_02 = 20910  # Apr 2 2027
    comptime DATE_2027_12_31 = 21183  # Dec 31 2027
    var values: List[Scalar[DType.int32]] = [
        Int32(DATE_2027_01_01),
        Int32(DATE_2027_04_02),
        Int32(DATE_2027_12_31),
    ]
    var dates = PrimitiveArray[DType.int32].from_list(values)
    assert_true(dates.get(0) < dates.get(1))  # Jan < Apr
    assert_true(dates.get(1) < dates.get(2))  # Apr < Dec
    assert_true(dates.get(0) < dates.get(2))  # Jan < Dec


def test_date32_epoch_is_zero() raises:
    """Unix epoch (1970-01-01) is represented as 0."""
    var values: List[Scalar[DType.int32]] = [Int32(0)]
    var dates = PrimitiveArray[DType.int32].from_list(values)
    assert_equal(Int(dates.get(0)), 0)


def test_date32_negative_for_pre_epoch() raises:
    """Dates before Unix epoch are negative integers."""
    # 1969-12-31 = -1 day from epoch
    var values: List[Scalar[DType.int32]] = [Int32(-1)]
    var dates = PrimitiveArray[DType.int32].from_list(values)
    assert_true(dates.get(0) < Int32(0))
    assert_equal(Int(dates.get(0)), -1)


def test_timestamp_micros_as_int64() raises:
    """Timestamp (microseconds since epoch) uses PrimitiveArray[DType.int64].

    Arrow Timestamp with microsecond resolution stores values as Int64.
    2027-04-02T00:00:00Z = 20910 days * 86400 sec/day * 1_000_000 us/sec
    """
    comptime MICROS_2027_04_02 = 1806624000000000  # 20910 * 86400 * 1_000_000
    var values: List[Scalar[DType.int64]] = [Int64(MICROS_2027_04_02)]
    var timestamps = PrimitiveArray[DType.int64].from_list(values)
    assert_equal(Int(timestamps.get(0)), MICROS_2027_04_02)


def test_timestamp_ordering() raises:
    """Timestamps maintain chronological order as integer comparison."""
    comptime TS_JAN = 1798761600000000  # 2027-01-01T00:00:00Z
    comptime TS_APR = 1806537600000000  # 2027-04-01T00:00:00Z
    var values: List[Scalar[DType.int64]] = [Int64(TS_JAN), Int64(TS_APR)]
    var timestamps = PrimitiveArray[DType.int64].from_list(values)
    assert_true(timestamps.get(0) < timestamps.get(1))


def test_date32_multiple_dates_array() raises:
    """Store multiple date values and verify SIMD-friendly access patterns."""
    var values: List[Scalar[DType.int32]] = [
        Int32(0),      # 1970-01-01
        Int32(365),    # 1971-01-01
        Int32(730),    # 1971-12-31 (approx)
        Int32(20910),  # 2027-04-02
    ]
    var dates = PrimitiveArray[DType.int32].from_list(values)
    assert_equal(dates.length, 4)
    assert_equal(Int(dates.get(0)), 0)
    assert_equal(Int(dates.get(1)), 365)
    assert_equal(Int(dates.get(2)), 730)
    assert_equal(Int(dates.get(3)), 20910)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
