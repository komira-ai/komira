# parquet_source_page_picks on a file written by komira_test_parquet_file
# with a page index: 45 rows, pages of 10 rows (the last of 5) for v, w and
# the dictionary-encoded s, and pages of 15 rows for m.
#   - a page's rows end at the next page's first row, the last page's at the
#     row group's row count (exact, whatever the page's byte size);
#   - row-range intersection, the pages of each column that cover a set of
#     rows (pages of 10 and of 15 rows), the rows every filter column keeps;
#   - the per-column page decode against the rows written, a dictionary
#     column included, and the one-pick-list form;
#   - the refusals: columns whose picked pages cover different rows, a
#     column without a page index, pick lists of the wrong count.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.page_index import OffsetIndex
from komira_parquet.page_index_cache import ParquetPageIndexCache
from komira_parquet.page_index_parser import parse_offset_index
from komira_parquet.parquet_source_page_picks import (
    _absolute_row_ranges_for_picks,
    _decode_columns_with_per_col_picks,
    _decode_predicate_cols_with_picks,
    _intersect_pred_row_ranges_via_cache,
    _intersect_row_ranges,
    _picks_overlapping_row_ranges,
    _picks_per_col_from_row_ranges,
)
from komira_arrow.record_batch import RecordBatch
from komira_parquet_api.metadata import FileMetaData
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _Reader = ParquetFileReader[LocalFs[NoopSink]]
comptime _ROWS = 45


def _v(r: Int) -> Int:
    return r + 1000


def _w(r: Int) -> Int:
    return -r


def _s(r: Int) -> String:
    return "t" + String(r % 6)


def _file(name: String, page_index: Bool) raises -> String:
    var path = test_tmpdir() + "/" + name
    var v = List[Int]()
    var w = List[Int]()
    var s = List[String]()
    for r in range(_ROWS):
        v.append(_v(r))
        w.append(_w(r))
        s.append(_s(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("v", v.copy()))
    cols.append(TestColumn.int64("w", w^))
    cols.append(TestColumn.string("s", s^).dict_encoded())
    cols.append(TestColumn.int64("m", v^).with_page_rows(15))
    write_parquet_file(path, cols, TestFileLayout(List[Int](), 10, page_index))
    return path^


def _meta(reader: _Reader) raises -> FileMetaData:
    return parse_full_metadata(reader.metadata_bytes.view_range_ro(0, reader.metadata_length))


def _oi(reader: _Reader, md: FileMetaData, col: Int) raises -> OffsetIndex:
    ref cc = md.row_groups[0].columns[col]
    var n = cc.offset_index_length.value()
    var buf = reader.read_bytes(cc.offset_index_offset.value(), n)
    return parse_offset_index(buf.view_range_ro(0, n))


def _assert_list(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want), "length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "item " + String(i))


def test_row_ranges_and_page_cover() raises:
    var reader = _Reader.open(_file("picks_ranges.parquet", True))
    var md = _meta(reader)
    var v = _oi(reader, md, 0)
    var m = _oi(reader, md, 3)
    _assert_list(_absolute_row_ranges_for_picks(v, [3, 4], _ROWS), [30, 40, 40, 45])
    _assert_list(_absolute_row_ranges_for_picks(m, [2], _ROWS), [30, 45])
    _assert_list(_intersect_row_ranges([0, 10, 20, 30], [5, 25]), [5, 10, 20, 25])
    _assert_list(_intersect_row_ranges([0, 10], [10, 20]), List[Int]())
    _assert_list(_picks_overlapping_row_ranges(v, [12, 14], _ROWS), [1])
    _assert_list(_picks_overlapping_row_ranges(m, [12, 14], _ROWS), [0])
    _assert_list(_picks_overlapping_row_ranges(v, [44, 45], _ROWS), [4])
    _assert_list(_picks_overlapping_row_ranges(m, [14, 16], _ROWS), [0, 1])


def test_rows_every_filter_column_keeps() raises:
    var path = _file("picks_keep.parquet", True)
    var reader = _Reader.open(path)
    var md = _meta(reader)
    var cache = ParquetPageIndexCache()
    var picks = List[List[Int]]()
    picks.append([1, 2])
    picks.append([2, 3])
    var rows = _intersect_pred_row_ranges_via_cache(cache, reader, path, md, 0, [0, 1], picks)
    _assert_list(rows, [20, 30])
    var per_col = _picks_per_col_from_row_ranges(cache, reader, path, md, 0, [0, 2, 3], rows)
    _assert_list(per_col[0], [2])
    _assert_list(per_col[1], [2])
    _assert_list(per_col[2], [1])
    assert_equal(
        len(_intersect_pred_row_ranges_via_cache(cache, reader, path, md, 0, List[Int](), List[List[Int]]())),
        0,
    )


def _check(b: RecordBatch, rows: List[Int]) raises:
    """`b` is columns v, s, w of `rows`."""
    assert_equal(b.num_rows(), len(rows))
    var s = b.column_at(1).as_string()
    for i in range(len(rows)):
        var r = rows[i]
        assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(i)), _v(r))
        assert_equal(s.get(i), _s(r), "s row " + String(r))
        assert_equal(Int(b.column_at(2).as_primitive[DType.int64]().get(i)), _w(r))


def _range(lo: Int, hi: Int, mut out: List[Int]):
    for r in range(lo, hi):
        out.append(r)


def test_decoding_picked_pages() raises:
    var path = _file("picks_decode.parquet", True)
    var reader = _Reader.open(path)
    var md = _meta(reader)
    var cache = ParquetPageIndexCache()
    var picks = List[List[Int]]()
    for _ in range(3):
        picks.append([2, 4])
    var b = _decode_columns_with_per_col_picks(cache, reader, path, md, 0, [0, 2, 1], picks, False)
    var rows = List[Int]()
    _range(20, 30, rows)
    _range(40, 45, rows)
    _check(b, rows)
    var one = _decode_predicate_cols_with_picks(cache, reader, path, md, 0, [0, 2, 1], [0, 1], 0, False)
    var rows2 = List[Int]()
    _range(0, 20, rows2)
    _check(one, rows2)


def test_refusals() raises:
    var path = _file("picks_refuse.parquet", True)
    var reader = _Reader.open(path)
    var md = _meta(reader)
    var cache = ParquetPageIndexCache()
    var mixed = List[List[Int]]()
    mixed.append([1])
    mixed.append([0])
    with assert_raises(contains="cover other rows"):
        _ = _decode_columns_with_per_col_picks(cache, reader, path, md, 0, [0, 3], mixed, False)
    with assert_raises(contains="one pick list per column"):
        _ = _decode_columns_with_per_col_picks(cache, reader, path, md, 0, [0, 3, 1], mixed, False)
    var bare = _file("picks_bare.parquet", False)
    var r2 = _Reader.open(bare)
    var md2 = _meta(r2)
    with assert_raises(contains="has no page index"):
        _ = _decode_predicate_cols_with_picks(cache, r2, bare, md2, 0, [0], [0], 0, False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
