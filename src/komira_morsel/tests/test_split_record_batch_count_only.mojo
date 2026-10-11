# =============================================================================
# split_record_batch on a count-only batch (`RecordBatch.count_only(n)`: zero
# columns, `n` rows). Regression test for komira-ai/komira#996.
# =============================================================================
#
# What these tests prove (oracle: the docstring of `split_record_batch`, "Each
# morsel contains up to `morsel_size` rows" and "A MorselArray covering all
# rows in the batch"; the numbers are worked out by hand):
#
#   * `count_only(n)` split at `M` gives ceil(n / M) morsels with ids 0, 1,
#     2, ..., partition 0, zero columns each, morsel `m` holding
#     min(M, n - m*M) rows, so `total_rows()` is `n`. The defect returned one
#     empty morsel (total 0), which every row-count assertion here catches.
#     Tried at n a multiple of M, one past, M = 1 and M > n.
#   * A selection mask on a count-only batch is cut into each morsel's window
#     like any other batch's.
#   * `count_only(0)` still gives one empty morsel.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch
from komira_morsel.morsel import split_record_batch


def _check(n: Int, m_size: Int, expect: List[Int]) raises:
    var ma = split_record_batch(RecordBatch.count_only(n), m_size)
    assert_equal(len(ma), len(expect), "morsel count")
    assert_equal(ma.total_rows(), n, "every row is kept")
    for m in range(len(expect)):
        assert_equal(ma[m].num_rows(), expect[m], "rows in morsel")
        assert_equal(ma[m].batch.num_columns(), 0, "still count-only")
        assert_equal(ma[m].morsel_id, m)
        assert_equal(ma[m].partition_id, 0)
        assert_false(ma[m].batch.has_selection_mask())


def test_count_only_rows_are_split_not_dropped() raises:
    _check(10, 4, [4, 4, 2])
    _check(8, 4, [4, 4])
    _check(9, 4, [4, 4, 1])
    _check(3, 1, [1, 1, 1])
    _check(5, 100, [5])


def test_count_only_selection_mask_is_cut_per_morsel() raises:
    var batch = RecordBatch.count_only(5)
    var mask = BooleanArray.allocate(5)
    mask.set(1, True)
    mask.set(2, True)
    mask.set(4, True)
    batch.set_selection_mask(mask^)
    var ma = split_record_batch(batch^, 2)
    assert_equal(len(ma), 3)
    var seen = String("")
    for m in range(len(ma)):
        assert_true(ma[m].batch.has_selection_mask(), "mask carried")
        for i in range(ma[m].num_rows()):
            seen += "1" if ma[m].batch.selection_mask_get(i) else "0"
        seen += "|"
    assert_equal(seen, "01|10|1|")
    assert_equal(ma.total_rows(), 5)


def test_count_only_zero_rows_gives_one_empty_morsel() raises:
    var ma = split_record_batch(RecordBatch.count_only(0), 4)
    assert_equal(len(ma), 1)
    assert_equal(ma.total_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
