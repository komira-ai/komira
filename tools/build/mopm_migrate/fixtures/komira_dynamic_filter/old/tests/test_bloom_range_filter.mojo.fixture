# =============================================================================
# Unit tests for RangeFilter (bloom pushdown)
# =============================================================================
#
# The range tier of the three-tier dynamic-filter hierarchy. Tests min/max
# membership and the helper that computes min/max from a build-side Int64
# array.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_dynamic_filter.range_filter import RangeFilter


# -----------------------------------------------------------------------------
# Construction from explicit (min, max) pair.
# -----------------------------------------------------------------------------
def test_explicit_range() raises:
    var f = RangeFilter.new_int64(min=10, max=100)
    assert_true(f.contains_int64(10))     # boundary low
    assert_true(f.contains_int64(50))     # mid
    assert_true(f.contains_int64(100))    # boundary high
    assert_false(f.contains_int64(9))     # below
    assert_false(f.contains_int64(101))   # above
    assert_false(f.contains_int64(-5))    # far below


# -----------------------------------------------------------------------------
# Single-element range (min == max).
# -----------------------------------------------------------------------------
def test_single_element_range() raises:
    var f = RangeFilter.new_int64(min=42, max=42)
    assert_true(f.contains_int64(42))
    assert_false(f.contains_int64(41))
    assert_false(f.contains_int64(43))


# -----------------------------------------------------------------------------
# Build min/max from a build-side Int64 array.
# (the key-range computation the dynamic-filter build uses).
# -----------------------------------------------------------------------------
def test_from_int64_values() raises:
    var values = List[Int64]()
    values.append(7)
    values.append(3)
    values.append(11)
    values.append(5)
    values.append(11)
    values.append(2)

    var maybe = RangeFilter.try_from_int64(values)
    assert_true(maybe.__bool__())
    var f = maybe.take()
    assert_equal(Int(f.min_int64()), 2)
    assert_equal(Int(f.max_int64()), 11)
    assert_true(f.contains_int64(2))
    assert_true(f.contains_int64(11))
    assert_true(f.contains_int64(5))
    assert_false(f.contains_int64(1))
    assert_false(f.contains_int64(12))


# -----------------------------------------------------------------------------
# Empty array -> None (no useful range filter from zero rows).
# -----------------------------------------------------------------------------
def test_empty_array() raises:
    var values = List[Int64]()
    var maybe = RangeFilter.try_from_int64(values)
    assert_false(maybe.__bool__())


# -----------------------------------------------------------------------------
# Single-row array -> degenerate single-element range.
# -----------------------------------------------------------------------------
def test_single_row_array() raises:
    var values = List[Int64]()
    values.append(99)
    var maybe = RangeFilter.try_from_int64(values)
    assert_true(maybe.__bool__())
    var f = maybe.take()
    assert_equal(Int(f.min_int64()), 99)
    assert_equal(Int(f.max_int64()), 99)


# -----------------------------------------------------------------------------
# Negative-spanning range (e.g. signed Int64 keys with negatives).
# -----------------------------------------------------------------------------
def test_negative_range() raises:
    var f = RangeFilter.new_int64(min=-100, max=100)
    assert_true(f.contains_int64(-100))
    assert_true(f.contains_int64(0))
    assert_true(f.contains_int64(100))
    assert_false(f.contains_int64(-101))
    assert_false(f.contains_int64(101))


# -----------------------------------------------------------------------------
# is_degenerate: min == max sentinel — the columnar path
# (`probe_side_filter_stages`) skips the range stage when min == max
# because it's redundant against the in-list (size-1) filter.
# -----------------------------------------------------------------------------
def test_is_degenerate() raises:
    var f1 = RangeFilter.new_int64(min=5, max=5)
    assert_true(f1.is_degenerate())
    var f2 = RangeFilter.new_int64(min=5, max=10)
    assert_false(f2.is_degenerate())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
