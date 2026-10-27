# page_index: the parsed index values, page row counts, run coalescing and
# the read of chosen pages, on files written by komira_test_parquet_file
# with a page index:
#   - OffsetIndex.page_rows is exact for every page, the last one included
#     (it ends at the row group's row count, not at an estimate from its
#     byte size);
#   - coalesce_pages merges adjacent picks, counts each run's rows exactly,
#     and refuses picks out of range or out of order;
#   - read_selected_pages_via_runs decodes exactly the chosen pages' rows of
#     a PLAIN, a nullable and a dictionary-encoded chunk (whose dictionary
#     page the OffsetIndex does not list), and no run gives no row.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.column import Column
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.heap_region import HeapRegion
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.page_index import (
    ColumnIndex,
    OffsetIndex,
    PageByteRun,
    coalesce_pages,
    read_selected_pages_via_runs,
)
from komira_parquet.page_index_parser import parse_offset_index
from komira_parquet_api.metadata import FileMetaData
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _Reader = ParquetFileReader[LocalFs[NoopSink]]
comptime _ROWS = 45  # pages of 10, 10, 10, 10 and 5 rows


def _v(r: Int) -> Int:
    return r * 100 + 1


def _null(r: Int) -> Bool:
    return r % 3 == 2


def _s(r: Int) -> String:
    return "k" + String(r % 4)


def _file() raises -> String:
    var path = test_tmpdir() + "/page_index.parquet"
    var v = List[Int]()
    var nulls = List[Bool]()
    var s = List[String]()
    for r in range(_ROWS):
        v.append(_v(r))
        nulls.append(_null(r))
        s.append(_s(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("v", v.copy()))
    cols.append(TestColumn.int64("n", v^).with_nulls(nulls^))
    cols.append(TestColumn.string("s", s^).dict_encoded())
    write_parquet_file(path, cols, TestFileLayout(List[Int](), 10, True))
    return path^


def _meta(reader: _Reader) raises -> FileMetaData:
    return parse_full_metadata(
        reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
    )


def _oi(reader: _Reader, md: FileMetaData, col: Int) raises -> OffsetIndex:
    ref cc = md.row_groups[0].columns[col]
    var off = cc.offset_index_offset.value()
    var n = cc.offset_index_length.value()
    var buf = reader.read_bytes(off, n)
    return parse_offset_index(buf.view_range_ro(0, n))


def test_page_rows_are_exact_including_the_last_page() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var oi = _oi(reader, md, 0)
    assert_equal(oi.num_pages, 5)
    var want: List[Int] = [10, 10, 10, 10, 5]
    for p in range(5):
        assert_equal(oi.page_rows(p, _ROWS), want[p], "page " + String(p))
        assert_equal(oi.first_row_indices[p], p * 10)
    assert_equal(oi.page_end_row(4, _ROWS), _ROWS)


def test_coalesce_merges_adjacent_picks_with_exact_rows() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var oi = _oi(reader, md, 0)
    var runs = coalesce_pages(oi, [0, 1, 3, 4], _ROWS)
    assert_equal(len(runs), 2)
    assert_equal(runs[0].start_pick, 0)
    assert_equal(runs[0].end_pick_excl, 2)
    assert_equal(runs[0].num_pages(), 2)
    assert_equal(runs[0].first_row_idx, 0)
    assert_equal(runs[0].num_rows, 20)
    assert_equal(runs[0].byte_offset, oi.offsets[0])
    assert_equal(runs[0].byte_length, oi.compressed_sizes[0] + oi.compressed_sizes[1])
    assert_equal(runs[1].first_row_idx, 30)
    assert_equal(runs[1].num_rows, 15)
    assert_equal(len(coalesce_pages(oi, List[Int](), _ROWS)), 0)
    with assert_raises(contains="out of range"):
        _ = coalesce_pages(oi, [5], _ROWS)
    with assert_raises(contains="not strictly ascending"):
        _ = coalesce_pages(oi, [2, 1], _ROWS)
    with assert_raises(contains="not strictly ascending"):
        _ = coalesce_pages(oi, [1, 1], _ROWS)


def _read(
    reader: _Reader, md: FileMetaData, col: Int, picks: List[Int]
) raises -> Column[HeapRegion]:
    var oi = _oi(reader, md, col)
    var runs = coalesce_pages(oi, picks, _ROWS)
    return read_selected_pages_via_runs(
        reader, md.row_groups[0].columns[col], md.schema[col + 1], runs
    )


def _picked_rows(picks: List[Int]) -> List[Int]:
    var rows = List[Int]()
    for i in range(len(picks)):
        for r in range(picks[i] * 10, min(picks[i] * 10 + 10, _ROWS)):
            rows.append(r)
    return rows^


def test_reading_chosen_pages_of_each_kind_of_chunk() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var pick_sets = List[List[Int]]()
    pick_sets.append([0])
    pick_sets.append([1, 2])
    pick_sets.append([0, 2, 4])
    pick_sets.append([4])
    pick_sets.append([0, 1, 2, 3, 4])
    for k in range(len(pick_sets)):
        ref picks = pick_sets[k]
        var rows = _picked_rows(picks)
        var v = _read(reader, md, 0, picks)
        assert_equal(v.length(), len(rows))
        var n = _read(reader, md, 1, picks)
        assert_equal(n.length(), len(rows))
        var s = _read(reader, md, 2, picks)
        assert_equal(s.length(), len(rows))
        var sa = s.as_string()
        for i in range(len(rows)):
            var r = rows[i]
            assert_equal(Int(v.as_primitive[DType.int64]().get(i)), _v(r))
            assert_equal(n.is_null_at(i), _null(r), "null row " + String(r))
            if not _null(r):
                assert_equal(Int(n.as_primitive[DType.int64]().get(i)), _v(r))
            assert_equal(sa.get(i), _s(r), "dictionary row " + String(r))


def test_no_run_is_no_row() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    for col in range(3):
        var c = read_selected_pages_via_runs(
            reader, md.row_groups[0].columns[col], md.schema[col + 1],
            List[PageByteRun](),
        )
        assert_equal(c.length(), 0)


def _bools(var b: List[Bool]) -> Optional[List[Bool]]:
    return Optional[List[Bool]](b^)


def test_index_values() raises:
    var ci = ColumnIndex(
        null_pages=[False, True],
        min_values_int64=[Int64(1), Int64(0)],
        max_values_int64=[Int64(5), Int64(0)],
        num_pages=2,
    )
    assert_true(ci.page_has_bounds(0) and ci.page_has_bounds(1))
    assert_true(ci.has_int64_stats())
    var none = ColumnIndex(
        null_pages=[False],
        min_values_int64=[Int64(0)],
        max_values_int64=[Int64(0)],
        num_pages=1,
        has_bounds=_bools([False]),
    )
    assert_false(none.has_int64_stats())
    var copy = ci.copy()
    assert_equal(copy.num_pages, 2)
    assert_equal(Int(copy.max_values_int64[0]), 5)


def test_a_dictionary_offset_of_zero_is_no_dictionary() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var oi = _oi(reader, md, 0)
    var runs = coalesce_pages(oi, [1, 2], _ROWS)
    var chunk = md.row_groups[0].columns[0].copy()
    chunk.meta_data.dictionary_page_offset = Optional[Int](0)
    var c = read_selected_pages_via_runs(reader, chunk, md.schema[1], runs)
    assert_equal(c.length(), 20)
    for i in range(20):
        assert_equal(Int(c.as_primitive[DType.int64]().get(i)), _v(10 + i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
