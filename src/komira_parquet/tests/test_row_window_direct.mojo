# =============================================================================
# resolve_row_group_window.
#
# What each test proves:
#   * hand cases: a window inside one row group, across row groups (and so
#     across files, whose row groups are concatenated), exactly one row
#     group, a length past the end (clamped), an offset at or past the end,
#     a zero or negative length and a negative offset, no row groups, and
#     zero-row row groups before, between and after the window;
#   * a sweep against a brute-force answer: for every window over several
#     row-group layouts, `[first_rg, last_rg]` is the smallest run holding
#     the window's rows, and `local_skip` / `keep` cut exactly those rows
#     out of the run.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_parquet.row_window import ParquetRowWindowResolution, resolve_row_group_window


def _check(
    counts: List[Int],
    offset: Int,
    length: Int,
    first_rg: Int,
    last_rg: Int,
    local_skip: Int,
    keep: Int,
    is_empty: Bool,
) raises:
    var res = resolve_row_group_window(counts, offset, length)
    var what = "(" + String(offset) + ", " + String(length) + ")"
    assert_equal(res.first_rg, first_rg, what + " first_rg")
    assert_equal(res.last_rg, last_rg, what + " last_rg")
    assert_equal(res.local_skip, local_skip, what + " local_skip")
    assert_equal(res.keep, keep, what + " keep")
    assert_equal(res.is_empty, is_empty, what + " is_empty")


def test_hand_cases() raises:
    _check([10], 3, 4, 0, 0, 3, 4, False)
    _check([10], 0, 10, 0, 0, 0, 10, False)
    _check([4, 4, 4], 5, 4, 1, 2, 1, 4, False)
    _check([4, 4, 4], 0, 4, 0, 0, 0, 4, False)
    _check([4, 4, 4], 4, 4, 1, 1, 0, 4, False)
    _check([4, 4, 4], 2, 8, 0, 2, 2, 8, False)
    _check([3, 5, 2], 4, 3, 1, 1, 1, 3, False)
    _check([4, 4, 4, 4], 6, 4, 1, 2, 2, 4, False)


def test_clamps_and_empty_windows() raises:
    _check([4, 4, 4], 10, 5, 2, 2, 2, 2, False)
    _check([4, 4, 4], 12, 3, 0, 0, 0, 0, True)
    _check([4, 4, 4], 100, 3, 0, 0, 0, 0, True)
    _check([4, 4, 4], 5, 0, 0, 0, 0, 0, True)
    _check([4, 4, 4], 5, -3, 0, 0, 0, 0, True)
    _check([4, 4, 4], -2, 3, 0, 0, 0, 3, False)
    _check(List[Int](), 0, 3, -1, -1, 0, 0, True)


def test_zero_row_row_groups() raises:
    _check([4, 0, 4], 2, 4, 0, 2, 2, 4, False)
    _check([4, 0, 4], 0, 4, 0, 0, 0, 4, False)
    _check([0, 4, 4], 0, 4, 1, 1, 0, 4, False)
    _check([4, 4, 0], 4, 4, 1, 1, 0, 4, False)


def test_sweep_against_brute_force() raises:
    var layouts: List[List[Int]] = [[1], [3, 1, 4], [2, 0, 2, 0, 5], [7, 7], [1, 1, 1, 1, 1, 1]]
    for li in range(len(layouts)):
        ref counts = layouts[li]
        var total = 0
        var starts = List[Int]()
        for i in range(len(counts)):
            starts.append(total)
            total += counts[i]
        for offset in range(total):
            for length in range(1, total - offset + 1):
                var res = resolve_row_group_window(counts, offset, length)
                var last_row = offset + length - 1
                # The row groups holding the first and the last row (a
                # zero-row row group holds none).
                var want_first = -1
                var want_last = -1
                for i in range(len(counts)):
                    if counts[i] > 0 and starts[i] <= offset and offset < starts[i] + counts[i]:
                        want_first = i
                    if counts[i] > 0 and starts[i] <= last_row and last_row < starts[i] + counts[i]:
                        want_last = i
                var what = String(li) + ": (" + String(offset) + ", " + String(length) + ")"
                assert_equal(res.first_rg, want_first, what)
                assert_equal(res.last_rg, want_last, what)
                assert_equal(starts[res.first_rg] + res.local_skip, offset, what)
                assert_equal(res.keep, length, what)
                assert_equal(res.is_empty, False, what)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
