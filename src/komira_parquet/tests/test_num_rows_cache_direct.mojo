# =============================================================================
# ParquetNumRowsCache.
#
# Files are written into TEST_TMPDIR with a footer holding only
# FileMetaData.num_rows (Thrift field 3, i64). What each test proves:
#   * the first call parses, the next ones hit (no parse) while the file's
#     size is unchanged;
#   * a file rewritten at a different size is parsed again and its entry
#     refreshed in place. The refresh used to append a second entry behind
#     the stale one, which every later lookup found first: each call then
#     re-parsed, and the cache grew by one entry per call;
#   * the test hooks report 0 for a path never seen, and a cached path whose
#     file is gone raises from the size probe.
# =============================================================================

from std.os import remove
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_parquet.num_rows_cache import ParquetNumRowsCache


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _write(path: String, num_rows: Int, data_bytes: Int) raises:
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(data_bytes):
        out.append(UInt8(i % 7))
    var footer: List[UInt8] = [0x36]  # field 3, i64
    _uleb(footer, num_rows << 1)
    footer.append(0x00)
    for i in range(len(footer)):
        out.append(footer[i])
    out.append(UInt8(len(footer)))
    out.append(0)
    out.append(0)
    out.append(0)
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()


def test_miss_then_hits() raises:
    var path = test_tmpdir() + "/rows_a.parquet"
    _write(path, 1234, 10)
    var cache = ParquetNumRowsCache()
    assert_equal(cache.get_or_compute(path), 1234)
    assert_equal(cache.get_or_compute(path), 1234)
    assert_equal(cache.get_or_compute(path), 1234)
    assert_equal(cache.miss_count(), 1)
    assert_equal(cache.size(), 1)
    assert_equal(cache.hit_count_for(path), 2)
    assert_equal(cache.parse_count_for(path), 1)


def test_a_rewritten_file_is_refreshed_in_place() raises:
    var path = test_tmpdir() + "/rows_b.parquet"
    _write(path, 10, 10)
    var cache = ParquetNumRowsCache()
    assert_equal(cache.get_or_compute(path), 10)
    _write(path, 20, 50)  # a different size
    assert_equal(cache.get_or_compute(path), 20)
    assert_equal(cache.size(), 1)
    assert_equal(cache.parse_count_for(path), 2)
    # The refreshed entry hits: no third parse.
    assert_equal(cache.get_or_compute(path), 20)
    assert_equal(cache.get_or_compute(path), 20)
    assert_equal(cache.miss_count(), 2)
    assert_equal(cache.hit_count_for(path), 2)
    var other = test_tmpdir() + "/rows_c.parquet"
    _write(other, 5, 3)
    assert_equal(cache.get_or_compute(other), 5)
    assert_equal(cache.size(), 2)


def test_unknown_paths_and_a_removed_file() raises:
    var cache = ParquetNumRowsCache()
    assert_equal(cache.hit_count_for("nowhere"), 0)
    assert_equal(cache.parse_count_for("nowhere"), 0)
    var path = test_tmpdir() + "/rows_d.parquet"
    _write(path, 3, 1)
    assert_equal(cache.get_or_compute(path), 3)
    remove(path)
    var raised = False
    try:
        _ = cache.get_or_compute(path)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
