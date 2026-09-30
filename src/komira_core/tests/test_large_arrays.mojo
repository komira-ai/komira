# =============================================================================
# Tests for LargeStringArray and LargeBinaryArray (Int64 offset variants)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.sys import size_of

from komira_core.arrow import ArrowType, LargeStringArray, LargeBinaryArray


# =============================================================================
# LargeStringArray tests
# =============================================================================


def test_large_string_basic_construction() raises:
    """LargeStringArray from_strings creates array with correct length and data."""
    var values: List[String] = ["hello", "world", "foo"]
    var arr = LargeStringArray.from_strings(values)
    assert_equal(len(arr), 3)
    assert_equal(arr.data_length, 13)  # 5 + 5 + 3
    assert_equal(arr.null_count, 0)


def test_large_string_get_returns_correct_strings() raises:
    """LargeStringArray.get returns the correct string at each index."""
    var values: List[String] = ["alpha", "beta", "gamma"]
    var arr = LargeStringArray.from_strings(values)
    assert_equal(arr.get(0), "alpha")
    assert_equal(arr.get(1), "beta")
    assert_equal(arr.get(2), "gamma")


def test_large_string_get_length() raises:
    """LargeStringArray.get_length returns byte length of each string."""
    var values: List[String] = ["hi", "there", "x"]
    var arr = LargeStringArray.from_strings(values)
    assert_equal(arr.get_length(0), 2)
    assert_equal(arr.get_length(1), 5)
    assert_equal(arr.get_length(2), 1)


def test_large_string_empty_string_in_array() raises:
    """Empty strings are stored correctly with zero-length spans."""
    var values: List[String] = ["a", "", "b", ""]
    var arr = LargeStringArray.from_strings(values)
    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), "a")
    assert_equal(arr.get(1), "")
    assert_equal(arr.get(2), "b")
    assert_equal(arr.get(3), "")
    assert_equal(arr.get_length(1), 0)
    assert_equal(arr.get_length(3), 0)


def test_large_string_single_element() raises:
    """A single-element LargeStringArray works correctly."""
    var values: List[String] = ["only"]
    var arr = LargeStringArray.from_strings(values)
    assert_equal(len(arr), 1)
    assert_equal(arr.get(0), "only")
    assert_equal(arr.get_length(0), 4)


def test_large_string_unicode_multibyte() raises:
    """Unicode multi-byte UTF-8 strings are stored and retrieved correctly."""
    var values: List[String] = ["cafe\u0301", "\u00e9", "\u2603", "abc"]
    var arr = LargeStringArray.from_strings(values)
    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), "cafe\u0301")
    assert_equal(arr.get(1), "\u00e9")
    assert_equal(arr.get(2), "\u2603")
    assert_equal(arr.get(3), "abc")
    # Multi-byte characters have byte length >= character count
    assert_true(arr.get_length(0) >= 4)
    assert_true(arr.get_length(1) >= 1)
    assert_true(arr.get_length(2) >= 1)
    assert_equal(arr.get_length(3), 3)


def test_large_string_out_of_bounds_positive() raises:
    """LargeStringArray.get raises on positive out-of-bounds index."""
    var values: List[String] = ["a", "b"]
    var arr = LargeStringArray.from_strings(values)
    var raised = False
    try:
        _ = arr.get(5)
    except:
        raised = True
    assert_true(raised)


def test_large_string_out_of_bounds_negative() raises:
    """LargeStringArray.get raises on negative index."""
    var values: List[String] = ["a", "b"]
    var arr = LargeStringArray.from_strings(values)
    var raised = False
    try:
        _ = arr.get(-1)
    except:
        raised = True
    assert_true(raised)


def test_large_string_out_of_bounds_at_length() raises:
    """LargeStringArray.get raises when index equals length."""
    var values: List[String] = ["x", "y", "z"]
    var arr = LargeStringArray.from_strings(values)
    var raised = False
    try:
        _ = arr.get(3)
    except:
        raised = True
    assert_true(raised)


def test_large_string_is_null_no_bitmap() raises:
    """LargeStringArray.is_null returns False when no validity bitmap."""
    var values: List[String] = ["a", "b", "c"]
    var arr = LargeStringArray.from_strings(values)
    for i in range(3):
        assert_false(arr.is_null(i))


def test_large_string_zero_length_array() raises:
    """A zero-length LargeStringArray is valid."""
    var values: List[String] = List[String]()
    var arr = LargeStringArray.from_strings(values)
    assert_equal(len(arr), 0)
    assert_equal(arr.data_length, 0)
    assert_equal(arr.null_count, 0)


def test_large_string_int64_offsets_size() raises:
    """Verify that LargeStringArray offsets buffer uses Int64-sized entries."""
    var values: List[String] = ["ab", "cde"]
    var arr = LargeStringArray.from_strings(values)
    # N+1 offsets, each Int64 = 8 bytes -> 3 * 8 = 24 bytes
    comptime int64_size = size_of[Int64]()
    assert_equal(int64_size, 8)
    # Verify offsets buffer length = (num_elements + 1) * 8
    assert_equal(arr.offsets.len(), (len(arr) + 1) * int64_size)


# =============================================================================
# LargeBinaryArray tests
# =============================================================================


def test_large_binary_basic_construction() raises:
    """LargeBinaryArray from_bytes_list creates array with correct length."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0x01))
    b0.append(UInt8(0x02))
    b0.append(UInt8(0x03))
    var b1 = List[UInt8]()
    b1.append(UInt8(0xFF))
    b1.append(UInt8(0xFE))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    assert_equal(len(arr), 2)
    assert_equal(arr.data_length, 5)
    assert_equal(arr.null_count, 0)


def test_large_binary_get() raises:
    """LargeBinaryArray.get returns correct bytes."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0xAA))
    b0.append(UInt8(0xBB))
    var b1 = List[UInt8]()
    b1.append(UInt8(0xCC))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    var result0 = arr.get(0)
    assert_equal(len(result0), 2)
    assert_equal(result0[0], UInt8(0xAA))
    assert_equal(result0[1], UInt8(0xBB))
    var result1 = arr.get(1)
    assert_equal(len(result1), 1)
    assert_equal(result1[0], UInt8(0xCC))


def test_large_binary_get_length() raises:
    """LargeBinaryArray.get_length returns byte length of each element."""
    var b0 = List[UInt8]()
    b0.append(UInt8(1))
    b0.append(UInt8(2))
    b0.append(UInt8(3))
    b0.append(UInt8(4))
    var b1 = List[UInt8]()
    var b2 = List[UInt8]()
    b2.append(UInt8(5))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    values.append(b2^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    assert_equal(arr.get_length(0), 4)
    assert_equal(arr.get_length(1), 0)  # empty element
    assert_equal(arr.get_length(2), 1)


def test_large_binary_out_of_bounds() raises:
    """LargeBinaryArray.get raises on out-of-bounds index."""
    var b0 = List[UInt8]()
    b0.append(UInt8(1))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    var raised = False
    try:
        _ = arr.get(5)
    except:
        raised = True
    assert_true(raised)


def test_large_binary_is_null_no_bitmap() raises:
    """LargeBinaryArray.is_null returns False when no validity bitmap."""
    var b0 = List[UInt8]()
    b0.append(UInt8(1))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    assert_false(arr.is_null(0))


def test_large_binary_int64_offsets_size() raises:
    """Verify that LargeBinaryArray offsets buffer uses Int64-sized entries."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0x01))
    var b1 = List[UInt8]()
    b1.append(UInt8(0x02))
    b1.append(UInt8(0x03))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    comptime int64_size = size_of[Int64]()
    assert_equal(int64_size, 8)
    # N+1 offsets, each Int64 = 8 bytes -> 3 * 8 = 24 bytes
    assert_equal(arr.offsets.len(), (len(arr) + 1) * int64_size)


def test_large_binary_get_byte() raises:
    """LargeBinaryArray.get_byte returns individual bytes."""
    var b0 = List[UInt8]()
    b0.append(UInt8(10))
    b0.append(UInt8(20))
    b0.append(UInt8(30))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = LargeBinaryArray.from_bytes_list(values)
    assert_equal(arr.get_byte(0, 0), UInt8(10))
    assert_equal(arr.get_byte(0, 1), UInt8(20))
    assert_equal(arr.get_byte(0, 2), UInt8(30))


def test_large_binary_empty() raises:
    """Empty LargeBinaryArray is valid."""
    var values = List[List[UInt8]]()
    var arr = LargeBinaryArray.from_bytes_list(values)
    assert_equal(len(arr), 0)
    assert_equal(arr.data_length, 0)


# =============================================================================
# ArrowType format string tests for LARGE_STRING and LARGE_BINARY
# =============================================================================


def test_arrow_type_large_string_format() raises:
    """ArrowType.LARGE_STRING format_string returns 'U' per Arrow C Data Interface."""
    assert_equal(ArrowType.LARGE_STRING.format_string(), "U")


def test_arrow_type_large_binary_format() raises:
    """ArrowType.LARGE_BINARY format_string returns 'Z' per Arrow C Data Interface."""
    assert_equal(ArrowType.LARGE_BINARY.format_string(), "Z")


def test_arrow_type_large_string_write() raises:
    """ArrowType.LARGE_STRING writes 'large_string'."""
    assert_equal(String(ArrowType.LARGE_STRING), "large_string")


def test_arrow_type_large_binary_write() raises:
    """ArrowType.LARGE_BINARY writes 'large_binary'."""
    assert_equal(String(ArrowType.LARGE_BINARY), "large_binary")


def test_arrow_type_large_string_not_equal_string() raises:
    """LARGE_STRING and STRING are distinct types."""
    assert_true(ArrowType.LARGE_STRING != ArrowType.STRING)
    assert_false(ArrowType.LARGE_STRING == ArrowType.STRING)


def test_arrow_type_large_binary_not_equal_binary() raises:
    """LARGE_BINARY and BINARY are distinct types."""
    assert_true(ArrowType.LARGE_BINARY != ArrowType.BINARY)
    assert_false(ArrowType.LARGE_BINARY == ArrowType.BINARY)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
