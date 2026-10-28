# =============================================================================
# sort_parallel: the co-rank search midpoints at the Int64 extremes
# =============================================================================
#
# Kept apart from the sort tests on purpose: a regression in a midpoint makes
# the co-rank search stop making progress, and the sort tests then never return.
# These tests call the midpoints directly, so the regression is reported here as
# a named failure.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_sort.sort_parallel import _mid_ceil, _mid_floor


def test_mid_ceil_of_the_full_range_is_inside_and_above_lo() raises:
    var lo = Int64.MIN
    var hi = Int64.MAX
    var m = _mid_ceil(lo, hi)
    assert_true(m > lo, "the ceil midpoint of [MIN, MAX] must exceed lo")
    assert_true(m <= hi)
    assert_equal(m, Int64(0))


def test_mid_ceil_rounds_up_on_adjacent_and_equal_bounds() raises:
    assert_equal(_mid_ceil(Int64.MIN, Int64.MIN + 1), Int64.MIN + 1)
    assert_equal(_mid_ceil(Int64.MAX - 1, Int64.MAX), Int64.MAX)
    assert_equal(_mid_ceil(Int64(7), Int64(7)), Int64(7))
    assert_equal(_mid_ceil(Int64(-3), Int64(-2)), Int64(-2))
    assert_equal(_mid_ceil(Int64.MIN, Int64(0)), Int64.MIN // 2)
    assert_equal(_mid_ceil(Int64(0), Int64.MAX), Int64.MAX // 2 + 1)


def test_mid_floor_of_the_full_range_and_adjacent_bounds() raises:
    assert_equal(_mid_floor(Int64.MIN, Int64.MAX), Int64(-1))
    assert_equal(_mid_floor(Int64.MIN, Int64.MIN + 1), Int64.MIN)
    assert_equal(_mid_floor(Int64.MAX - 1, Int64.MAX), Int64.MAX - 1)
    assert_equal(_mid_floor(Int64(-3), Int64(-2)), Int64(-3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
