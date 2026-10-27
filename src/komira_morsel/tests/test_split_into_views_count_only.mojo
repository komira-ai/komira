# =============================================================================
# split_into_views on a count-only batch (`RecordBatch.count_only(n)`: zero
# columns, `n` rows). Regression test for komira-ai/komira#1205.
# =============================================================================
#
# What these tests prove (oracle: the docstring of `split_into_views`, "zero-
# copy views covering all rows", with "Maximum number of rows per view"; the
# numbers are worked out by hand):
#
#   * `count_only(n)` split at `M` gives ceil(n / M) views, view `v` starting
#     at row v*M and holding min(M, n - v*M) rows, so the views tile [0, n).
#     The defect returned one view (0, 0) for any zero-column batch, which the
#     view-count and row-sum assertions catch. Tried at n a multiple of M, one
#     past, M = 1 and M > n.
#   * `count_only(0)` still gives one empty view (0, 0).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.record_batch import RecordBatch
from komira_morsel.morsel import split_into_views


def _check(n: Int, m_size: Int, expect: List[Int]) raises:
    var views = split_into_views(RecordBatch.count_only(n), m_size)
    assert_equal(len(views), len(expect), "view count")
    var next_start = 0
    for v in range(len(expect)):
        assert_equal(views[v].start_row, next_start, "views are contiguous")
        assert_equal(views[v].num_rows, expect[v], "rows in view")
        next_start += views[v].num_rows
    assert_equal(next_start, n, "every row is covered")


def test_count_only_rows_are_covered_not_dropped() raises:
    _check(10, 4, [4, 4, 2])
    _check(8, 4, [4, 4])
    _check(9, 4, [4, 4, 1])
    _check(3, 1, [1, 1, 1])
    _check(5, 100, [5])


def test_count_only_zero_rows_gives_one_empty_view() raises:
    var views = split_into_views(RecordBatch.count_only(0), 4)
    assert_equal(len(views), 1)
    assert_equal(views[0].start_row, 0)
    assert_equal(views[0].num_rows, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
