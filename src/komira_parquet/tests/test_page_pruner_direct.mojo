# page_pruner. The pure layer on hand-built indexes (pages of [0, 9],
# [10, 19], [20, 29] unless a test says otherwise):
#   - each comparison keeps the pages that can hold a match, a literal on
#     the left is swapped, AND intersects, OR unites (also across columns,
#     where the other column's leaf keeps every page), BETWEEN-as-AND;
#   - != and a column-to-column comparison keep every page (all pass); a
#     literal below every page empties the row group;
#   - an all-null page is never kept; a page whose bounds were not written
#     is always kept while its neighbours are pruned on theirs;
#   - Int64.MIN / Int64.MAX literals do not wrap.
# The cache layer on files written by komira_test_parquet_file: a pruned
# INT64 column, a column the filter does not name, and the columns it must
# leave whole (UINT_64, DECIMAL, no page index, not INT64).

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.page_index import ColumnIndex, OffsetIndex
from komira_parquet.page_index_cache import ParquetPageIndexCache
from komira_parquet.page_pruner import (
    PageIndexBundle,
    PageSelectionSet,
    evaluate_page_filter,
    select_pages_for_unit,
)
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file


def _ci(mins: List[Int], maxs: List[Int]) -> ColumnIndex:
    var nps = List[Bool]()
    var lo = List[Int64]()
    var hi = List[Int64]()
    for i in range(len(mins)):
        nps.append(False)
        lo.append(Int64(mins[i]))
        hi.append(Int64(maxs[i]))
    return ColumnIndex(null_pages=nps^, min_values_int64=lo^, max_values_int64=hi^, num_pages=len(mins))


def _oi(n: Int) -> OffsetIndex:
    var offs = List[Int]()
    var sizes = List[Int]()
    var firsts = List[Int]()
    for i in range(n):
        offs.append(4 + i * 100)
        sizes.append(100)
        firsts.append(i * 10)
    return OffsetIndex(offsets=offs^, compressed_sizes=sizes^, first_row_indices=firsts^, num_pages=n)


def _bundle() -> PageIndexBundle:
    var b = PageIndexBundle()
    b.add("x", 0, _ci([0, 10, 20], [9, 19, 29]), _oi(3))
    b.add("y", 1, _ci([100, 200, 300], [199, 299, 399]), _oi(3))
    return b^


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


def _rcmp(op: UInt8, v: Int, col: String) -> Expr:
    return Expr.binary(op, Expr.literal(ScalarValue.from_int(v)), Expr.col_ref(col))


def _picks(s: PageSelectionSet, col: String) raises -> List[Int]:
    """The kept pages of `col` (every page when it is all pass)."""
    var i = s.find(col)
    assert_true(i >= 0, col + " has an entry")
    if s.entries[i].is_all_pass:
        var all = List[Int]()
        for p in range(s.entries[i].num_pages):
            all.append(p)
        return all^
    return s.entries[i].picks.copy()


def _assert_picks(s: PageSelectionSet, col: String, want: List[Int]) raises:
    var got = _picks(s, col)
    assert_equal(len(got), len(want), col + " pick count")
    for k in range(len(want)):
        assert_equal(got[k], want[k], col + " pick " + String(k))


def test_each_comparison() raises:
    var b = _bundle()
    _assert_picks(evaluate_page_filter(_cmp(BIN_LT, "x", 15), b), "x", [0, 1])
    _assert_picks(evaluate_page_filter(_cmp(BIN_LT, "x", 10), b), "x", [0])
    _assert_picks(evaluate_page_filter(_cmp(BIN_LE, "x", 10), b), "x", [0, 1])
    _assert_picks(evaluate_page_filter(_cmp(BIN_GT, "x", 19), b), "x", [2])
    _assert_picks(evaluate_page_filter(_cmp(BIN_GE, "x", 19), b), "x", [1, 2])
    _assert_picks(evaluate_page_filter(_cmp(BIN_EQ, "x", 25), b), "x", [2])
    # A literal on the left: 15 > x is x < 15.
    _assert_picks(evaluate_page_filter(_rcmp(BIN_GT, 15, "x"), b), "x", [0, 1])
    _assert_picks(evaluate_page_filter(_rcmp(BIN_LE, 20, "x"), b), "x", [2])


def test_and_or_and_between() raises:
    var b = _bundle()
    var between = Expr.binary(BIN_AND, _cmp(BIN_GE, "x", 12), _cmp(BIN_LE, "x", 14))
    _assert_picks(evaluate_page_filter(between, b), "x", [1])
    var either = Expr.binary(BIN_OR, _cmp(BIN_LT, "x", 3), _cmp(BIN_GT, "x", 25))
    _assert_picks(evaluate_page_filter(either, b), "x", [0, 2])
    # Two columns under AND: each column keeps its own pages.
    var both = Expr.binary(BIN_AND, _cmp(BIN_LT, "x", 5), _cmp(BIN_GE, "y", 300))
    var s = evaluate_page_filter(both, b)
    _assert_picks(s, "x", [0])
    _assert_picks(s, "y", [2])
    # Two columns under OR: the other column's leaf keeps every page.
    var any = Expr.binary(BIN_OR, _cmp(BIN_LT, "x", 5), _cmp(BIN_GE, "y", 300))
    var t = evaluate_page_filter(any, b)
    assert_true(t.entries[t.find("x")].is_all_pass)
    assert_true(t.entries[t.find("y")].is_all_pass)
    assert_false(t.is_pruned_empty)


def test_all_pass_and_empty() raises:
    var b = _bundle()
    var ne = evaluate_page_filter(_cmp(BIN_NE, "x", 5), b)
    assert_true(ne.entries[ne.find("x")].is_all_pass)
    var colcol = Expr.binary(BIN_LT, Expr.col_ref("x"), Expr.col_ref("y"))
    var cc = evaluate_page_filter(colcol, b)
    assert_true(cc.entries[cc.find("x")].is_all_pass)
    var below = evaluate_page_filter(_cmp(BIN_LT, "x", -1), b)
    assert_true(below.is_pruned_empty)
    assert_equal(len(_picks(below, "x")), 0)
    var wide = evaluate_page_filter(_cmp(BIN_GE, "x", -1000), b)
    assert_true(wide.entries[wide.find("x")].is_all_pass)
    assert_false(wide.is_pruned_empty)


def _bools(var b: List[Bool]) -> Optional[List[Bool]]:
    return Optional[List[Bool]](b^)


def test_null_pages_and_pages_without_bounds() raises:
    var b = PageIndexBundle()
    b.add(
        "z",
        0,
        ColumnIndex(
            null_pages=[False, True, False, False],
            min_values_int64=[Int64(0), Int64(0), Int64(0), Int64(30)],
            max_values_int64=[Int64(9), Int64(0), Int64(0), Int64(39)],
            num_pages=4,
            has_bounds=_bools([True, True, False, True]),
        ),
        _oi(4),
    )
    # Page 1 is all null; page 2 has no bounds (its 0s are not bounds).
    _assert_picks(evaluate_page_filter(_cmp(BIN_GE, "z", 25), b), "z", [2, 3])
    _assert_picks(evaluate_page_filter(_cmp(BIN_EQ, "z", 0), b), "z", [0, 2])


def test_extreme_literals_do_not_wrap() raises:
    var b = _bundle()
    var lt_min = evaluate_page_filter(_cmp(BIN_LT, "x", Int(Int64.MIN)), b)
    assert_true(lt_min.is_pruned_empty)
    var gt_max = evaluate_page_filter(_cmp(BIN_GT, "x", Int(Int64.MAX)), b)
    assert_true(gt_max.is_pruned_empty)
    var le_max = evaluate_page_filter(_cmp(BIN_LE, "x", Int(Int64.MAX)), b)
    assert_true(le_max.entries[le_max.find("x")].is_all_pass)


def _file() raises -> String:
    var path = test_tmpdir() + "/pruner.parquet"
    var v = List[Int]()
    var u = List[Int]()
    var s = List[String]()
    for r in range(40):
        v.append(r)
        u.append(r)
        s.append(String(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("v", v.copy()))
    var uns = TestColumn.int64("u", u.copy())
    uns.converted_type = 14  # UINT_64
    cols.append(uns^)
    var dec = TestColumn.int64("d", v.copy())
    dec.converted_type = 5  # DECIMAL
    cols.append(dec^)
    cols.append(TestColumn.int32("i", v^))
    cols.append(TestColumn.string("s", s^))
    write_parquet_file(path, cols, TestFileLayout(List[Int](), 10, True))
    return path^


def test_the_cache_layer_on_a_file() raises:
    var path = _file()
    var reader = ParquetFileReader[LocalFs[NoopSink]].open(path)
    var md = parse_full_metadata(reader.metadata_bytes.view_range_ro(0, reader.metadata_length))
    var cache = ParquetPageIndexCache()
    var s = select_pages_for_unit(cache, reader, path, md, 0, _cmp(BIN_GE, "v", 25))
    assert_equal(len(s.entries), 1)
    _assert_picks(s, "v", [2, 3])
    assert_equal(s.entries[0].col_idx, 0)
    # UINT_64, DECIMAL and INT32 columns are left whole: no entry.
    var whole = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_AND, _cmp(BIN_LT, "u", 5), _cmp(BIN_LT, "d", 5)),
        _cmp(BIN_LT, "i", 5),
    )
    var w = select_pages_for_unit(cache, reader, path, md, 0, whole)
    assert_equal(len(w.entries), 0)
    assert_false(w.is_pruned_empty)
    # A name the file lacks, and a filter naming no column.
    assert_equal(len(select_pages_for_unit(cache, reader, path, md, 0, _cmp(BIN_LT, "q", 5)).entries), 0)
    var lit = Expr.literal(ScalarValue.from_int(1))
    assert_equal(len(select_pages_for_unit(cache, reader, path, md, 0, lit).entries), 0)
    assert_equal(cache.miss_count(), 1)
    with assert_raises(contains="out of range"):
        _ = select_pages_for_unit(cache, reader, path, md, 1, lit)


def test_a_file_without_a_page_index() raises:
    var path = test_tmpdir() + "/pruner_noindex.parquet"
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("v", [1, 2, 3]))
    write_parquet_file(path, cols, TestFileLayout.single())
    var reader = ParquetFileReader[LocalFs[NoopSink]].open(path)
    var md = parse_full_metadata(reader.metadata_bytes.view_range_ro(0, reader.metadata_length))
    var cache = ParquetPageIndexCache()
    var s = select_pages_for_unit(cache, reader, path, md, 0, _cmp(BIN_LT, "v", 0))
    assert_equal(len(s.entries), 0)
    assert_false(s.is_pruned_empty)


def test_a_column_with_no_pages_is_read_whole() raises:
    var b = _bundle()
    b.add("z", 2, _ci(List[Int](), List[Int]()), _oi(0))
    var s = evaluate_page_filter(Expr.binary(BIN_AND, _cmp(BIN_GE, "z", 0), _cmp(BIN_GE, "x", 20)), b)
    assert_false(s.is_pruned_empty)
    assert_true(s.find("z") < 0)
    _assert_picks(s, "x", [2])
    var only = PageIndexBundle()
    only.add("z", 0, _ci(List[Int](), List[Int]()), _oi(0))
    var alone = evaluate_page_filter(_cmp(BIN_GE, "z", 0), only)
    assert_false(alone.is_pruned_empty)
    assert_equal(len(alone.entries), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
