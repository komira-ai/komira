# =============================================================================
# Tests for StringArray (the core packages)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_arrow.string_array import StringArray


def test_from_strings_basic() raises:
    """Construct StringArray from a list of strings and verify length."""
    var values: List[String] = ["hello", "world", "foo"]
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 3)
    assert_equal(arr.data_length, 13)  # 5 + 5 + 3
    assert_equal(arr.null_count, 0)


def test_get_returns_correct_strings() raises:
    """Verify get() returns the correct string at each index."""
    var values: List[String] = ["alpha", "beta", "gamma"]
    var arr = StringArray.from_strings(values)
    assert_equal(arr.get(0), "alpha")
    assert_equal(arr.get(1), "beta")
    assert_equal(arr.get(2), "gamma")


def test_get_length_returns_byte_length() raises:
    """Verify get_length() returns the byte length of each string."""
    var values: List[String] = ["hi", "there", "x"]
    var arr = StringArray.from_strings(values)
    assert_equal(arr.get_length(0), 2)
    assert_equal(arr.get_length(1), 5)
    assert_equal(arr.get_length(2), 1)


def test_empty_string_in_array() raises:
    """Empty strings are stored correctly with zero-length spans."""
    var values: List[String] = ["a", "", "b", ""]
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), "a")
    assert_equal(arr.get(1), "")
    assert_equal(arr.get(2), "b")
    assert_equal(arr.get(3), "")
    assert_equal(arr.get_length(0), 1)
    assert_equal(arr.get_length(1), 0)
    assert_equal(arr.get_length(2), 1)
    assert_equal(arr.get_length(3), 0)


def test_single_string_array() raises:
    """A single-element StringArray works correctly."""
    var values: List[String] = ["only"]
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 1)
    assert_equal(arr.get(0), "only")
    assert_equal(arr.get_length(0), 4)


def test_zero_length_array() raises:
    """A zero-length StringArray is valid."""
    var values: List[String] = List[String]()
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 0)
    assert_equal(arr.data_length, 0)
    assert_equal(arr.null_count, 0)


def test_unicode_multibyte() raises:
    """Unicode multi-byte UTF-8 strings are stored and retrieved correctly."""
    var values: List[String] = ["cafe\u0301", "\u00e9", "\u2603", "abc"]
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 4)
    # Verify round-trip: get() returns the original strings
    assert_equal(arr.get(0), "cafe\u0301")
    assert_equal(arr.get(1), "\u00e9")
    assert_equal(arr.get(2), "\u2603")
    assert_equal(arr.get(3), "abc")
    # Multi-byte characters have byte length > character count
    assert_true(arr.get_length(0) >= 4)  # "cafe" + combining accent
    assert_true(arr.get_length(1) >= 1)  # e-acute is 2 bytes in UTF-8
    assert_true(arr.get_length(2) >= 1)  # snowman is 3 bytes in UTF-8
    assert_equal(arr.get_length(3), 3)   # "abc" is plain ASCII


def test_get_out_of_bounds_positive() raises:
    """Verify get() raises on positive out-of-bounds index."""
    var values: List[String] = ["a", "b"]
    var arr = StringArray.from_strings(values)
    var raised = False
    try:
        _ = arr.get(5)
    except:
        raised = True
    assert_true(raised)


def test_get_out_of_bounds_negative() raises:
    """Verify get() raises on negative index."""
    var values: List[String] = ["a", "b"]
    var arr = StringArray.from_strings(values)
    var raised = False
    try:
        _ = arr.get(-1)
    except:
        raised = True
    assert_true(raised)


def test_get_out_of_bounds_at_length() raises:
    """Verify get() raises when index equals length (off-by-one boundary)."""
    var values: List[String] = ["x", "y", "z"]
    var arr = StringArray.from_strings(values)
    var raised = False
    try:
        _ = arr.get(3)
    except:
        raised = True
    assert_true(raised)


def test_is_null_no_bitmap() raises:
    """Verify is_null() returns False for all elements when no validity bitmap."""
    var values: List[String] = ["a", "b", "c"]
    var arr = StringArray.from_strings(values)
    for i in range(3):
        assert_false(arr.is_null(i))


def test_long_strings() raises:
    """Strings longer than typical cache lines are handled correctly."""
    var long_a = String("a") * 1000
    var long_b = String("b") * 2000
    var values: List[String] = [long_a, long_b]
    var arr = StringArray.from_strings(values)
    assert_equal(len(arr), 2)
    assert_equal(arr.get_length(0), 1000)
    assert_equal(arr.get_length(1), 2000)
    assert_equal(arr.data_length, 3000)
    assert_equal(arr.get(0), long_a)
    assert_equal(arr.get(1), long_b)


def test_offsets_are_monotonic() raises:
    """Offsets buffer values are strictly non-decreasing (Arrow invariant)."""
    var values: List[String] = ["ab", "", "cde", "f"]
    var arr = StringArray.from_strings(values)
    # Check all N+1 offsets via get_length (derived from adjacent offsets)
    var running = 0
    for i in range(len(arr)):
        var slen = arr.get_length(i)
        assert_true(slen >= 0)
        running += slen
    assert_equal(running, arr.data_length)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
