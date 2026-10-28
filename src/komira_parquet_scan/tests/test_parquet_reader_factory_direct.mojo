# ParquetReaderFactory over a session footer cache:
#   - `open` parses a file's footer once; a second `open` of the same path
#     is a cache hit;
#   - with the cache pinning the mapping, a reader adopts the pin; with no
#     pin, a reader maps the file itself and its worker clones share that
#     mapping (the share count moves by one per clone, and back on drop);
#   - a clone decodes what its original decodes;
#   - the footer-only reader knows the row groups and the schema;
#   - the switches reach every reader (a numeric dictionary column under
#     preserve_dict).

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_scan.parquet_reader_factory import ParquetReaderFactory
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]


def _file() raises -> String:
    var path = test_tmpdir() + "/factory.parquet"
    var a = List[Int]()
    var d = List[Int]()
    for r in range(20):
        a.append(r * 3)
        d.append(r % 4)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int64("d", d^).dict_encoded())
    write_parquet_file(path, cols, TestFileLayout([10, 10], 0, False))
    return path^


def test_open_hits_the_cache_and_pinned_readers_share_the_mapping() raises:
    var path = _file()
    # Revalidation on every hit, so a just-written file is not re-parsed as
    # possibly still being written.
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var fs = _FS.new()
    var f = ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache))
    var r0 = f.open(fs, path)
    # The reader adopted the cache's pinned mapping: the pin and the reader.
    assert_equal(cache.mmap_pin_count(), 1)
    assert_equal(r0.mmap_share_count(), 2)
    var r1 = f.open(fs, path)
    assert_equal(cache.miss_count(), 1)
    assert_equal(cache.hit_count_for(path), 1)
    assert_equal(r1.unit_count_for_file(), 2)


def test_clones_share_the_readers_own_mapping() raises:
    var path = _file()
    var cache = ParquetMetadataCache(mmap_pin_byte_cap=0)
    var fs = _FS.new()
    var f = ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache))
    var r0 = f.open(fs, path)
    assert_equal(r0.mmap_share_count(), 1)
    var other = f.open(fs, path)
    assert_equal(other.mmap_share_count(), 1)
    var c1 = f.clone_reader_for_worker(r0)
    assert_equal(r0.mmap_share_count(), 2)
    var c2 = f.clone_reader_for_worker(c1)
    assert_equal(r0.mmap_share_count(), 3)
    _ = c2^
    assert_equal(r0.mmap_share_count(), 2)
    var b = c1.decode_columns_subset(1, [0], False)
    assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(4)), 42)


def test_the_footer_only_reader() raises:
    var path = _file()
    var cache = ParquetMetadataCache()
    var fs = _FS.new()
    var f = ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache))
    var r = f.open_footer_only(fs, path)
    assert_equal(r.unit_count_for_file(), 2)
    assert_equal(r.unit_num_rows(1), 10)
    assert_equal(r.column_name_to_idx_for_file("d"), 1)
    assert_equal(r.mmap_share_count(), 0)


def test_the_switches_reach_every_reader() raises:
    var path = _file()
    var cache = ParquetMetadataCache()
    var fs = _FS.new()
    var f = ParquetReaderFactory[origin_of(cache), _FS](Pointer(to=cache), numeric_dict_vec=True)
    var r0 = f.open(fs, path)
    var c = f.clone_reader_for_worker(r0)
    assert_true(r0.decode_columns_subset(0, [1], True).column_at(0).is_numeric_dict())
    assert_true(c.decode_columns_subset(0, [1], True).column_at(0).is_numeric_dict())
    var pf = ParquetReaderFactory[origin_of(cache), _FS].new(Pointer(to=cache))
    var plain = pf.open(fs, path)
    assert_false(plain.decode_columns_subset(0, [1], True).column_at(0).is_numeric_dict())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
