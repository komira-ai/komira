# ParquetPageIndexCache on files written by komira_test_parquet_file with a
# page index:
#   - a miss reads and parses, a hit returns the same indexes without a
#     parse, ten lookups of one chunk parse it once;
#   - distinct (row group, column) keys are distinct entries, and what a
#     lookup returns is a copy that a later insert cannot disturb;
#   - invalidate drops the entries of one path and keeps the others';
#   - a refused lookup (an empty length, a range outside the file) leaves
#     the cache usable: the lock is released on the raise path.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.page_index_cache import ParquetPageIndexCache, get_or_parse_indexes_copy
from komira_parquet_api.metadata import FileMetaData
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _Reader = ParquetFileReader[LocalFs[NoopSink]]


def _file(name: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    var a = List[Int]()
    var b = List[Int]()
    for r in range(60):
        a.append(r)
        b.append(1000 - r)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int64("b", b^))
    write_parquet_file(path, cols, TestFileLayout([30, 30], 10, True))
    return path^


def _meta(reader: _Reader) raises -> FileMetaData:
    return parse_full_metadata(
        reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
    )


def _lookup(
    mut cache: ParquetPageIndexCache,
    reader: _Reader,
    path: String,
    md: FileMetaData,
    rg: Int,
    col: Int,
) raises -> Tuple[Int, Int]:
    """(pages, min of page 1) of the looked-up indexes."""
    ref cc = md.row_groups[rg].columns[col]
    var parsed = get_or_parse_indexes_copy(
        cache,
        reader,
        path,
        rg,
        col,
        cc.column_index_offset.value(),
        cc.column_index_length.value(),
        cc.offset_index_offset.value(),
        cc.offset_index_length.value(),
    )
    var ci = parsed.take_column_index()
    var oi = parsed.take_offset_index()
    assert_equal(ci.num_pages, oi.num_pages)
    return (ci.num_pages, Int(ci.min_values_int64[1]))


def test_miss_then_hits_parse_once() raises:
    var path = _file("cache_hits.parquet")
    var reader = _Reader.open(path)
    var md = _meta(reader)
    var cache = ParquetPageIndexCache()
    var first = _lookup(cache, reader, path, md, 1, 0)
    assert_equal(first[0], 3)
    assert_equal(first[1], 40)  # row group 1 starts at row 30
    assert_equal(cache.miss_count(), 1)
    for _ in range(10):
        var again = _lookup(cache, reader, path, md, 1, 0)
        assert_equal(again[1], 40)
    assert_equal(cache.miss_count(), 1)
    assert_equal(cache.parse_count_for(path, 1, 0), 1)
    assert_equal(cache.hit_count_for(path, 1, 0), 10)
    assert_equal(cache.size(), 1)


def test_distinct_keys_and_copies() raises:
    var path = _file("cache_keys.parquet")
    var reader = _Reader.open(path)
    var md = _meta(reader)
    var cache = ParquetPageIndexCache()
    var held = get_or_parse_indexes_copy(
        cache,
        reader,
        path,
        0,
        1,
        md.row_groups[0].columns[1].column_index_offset.value(),
        md.row_groups[0].columns[1].column_index_length.value(),
        md.row_groups[0].columns[1].offset_index_offset.value(),
        md.row_groups[0].columns[1].offset_index_length.value(),
    )
    for rg in range(2):
        for col in range(2):
            _ = _lookup(cache, reader, path, md, rg, col)
    assert_equal(cache.size(), 4)
    assert_equal(cache.miss_count(), 4)
    # What the first lookup returned is untouched by the inserts after it.
    assert_equal(Int(held.column_index_ref().min_values_int64[1]), 1000 - 19)
    assert_equal(held.offset_index_ref().first_row_indices[2], 20)


def test_invalidate_drops_one_path() raises:
    var p1 = _file("cache_p1.parquet")
    var p2 = _file("cache_p2.parquet")
    var r1 = _Reader.open(p1)
    var r2 = _Reader.open(p2)
    var md = _meta(r1)
    var cache = ParquetPageIndexCache()
    _ = _lookup(cache, r1, p1, md, 0, 0)
    _ = _lookup(cache, r2, p2, md, 0, 0)
    _ = _lookup(cache, r2, p2, md, 1, 1)
    cache.invalidate(p1)
    assert_equal(cache.size(), 2)
    assert_equal(cache.parse_count_for(p1, 0, 0), 0)
    assert_equal(cache.parse_count_for(p2, 1, 1), 1)
    _ = _lookup(cache, r2, p2, md, 0, 0)
    assert_equal(cache.miss_count(), 3, "p2's entry survived the invalidate")


def test_a_refused_lookup_leaves_the_cache_usable() raises:
    var path = _file("cache_refuse.parquet")
    var reader = _Reader.open(path)
    var md = _meta(reader)
    var cache = ParquetPageIndexCache()
    with assert_raises(contains="empty page index"):
        _ = get_or_parse_indexes_copy(cache, reader, path, 0, 0, 4, 0, 4, 10)
    with assert_raises():
        _ = get_or_parse_indexes_copy(cache, reader, path, 0, 0, 1 << 40, 10, 4, 10)
    # A leaked lock would hang here.
    var ok = _lookup(cache, reader, path, md, 0, 0)
    assert_equal(ok[0], 3)
    assert_equal(cache.size(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
