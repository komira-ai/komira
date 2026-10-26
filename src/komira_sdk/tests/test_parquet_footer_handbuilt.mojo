# =============================================================================
# parquet_footer on a Parquet file built byte by byte.
# =============================================================================
#
# The file is `PAR1`, a few data bytes, a Thrift Compact FileMetaData written
# here (version 2, three schema elements: the root group, `a` INT64 REQUIRED
# and `s` BYTE_ARRAY UTF8 OPTIONAL, `num_rows` 42, no row groups), the
# footer's length and `PAR1`. It lives under the test's scratch directory; no
# writer is involved.
#
# What each test proves, and the defect it catches:
#   * `read_parquet_row_count` reads 42 from the footer (a wrong footer field
#     or a row-group count returned in its place);
#   * `read_parquet_footer` agrees with it on the count and returns the schema
#     `a int64 not-null, s string nullable`, the root group left out (the
#     repetition type ignored, the root kept, the schema left empty, the count
#     changed);
#   * `take_schema` moves the schema out of the summary;
#   * a file whose trailing magic is wrong raises on both entry points (the
#     magic check skipped);
#   * a footer length larger than the file raises on both (the length not
#     checked against the file);
#   * a file shorter than the minimum size (`PAR1` plus four bytes) raises on
#     both (the size check skipped);
#   * a valid trailer over a truncated or garbage Thrift body raises on both
#     (a short or malformed footer accepted as an empty one);
#   * a path that is not a file raises;
#   * the cached read returns the same count and schema as the uncached read,
#     keeps two files apart (a count or schema of one served for the other),
#     reads each file once and serves a repeat from the cache, through both the
#     local-file entry and the file-system entry;
#   * a cached read of a bad file raises and caches nothing.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_runtime_paths import test_tmpdir
from komira_sdk.parquet_footer import (
    ParquetFooterSummary,
    read_parquet_footer,
    read_parquet_footer_with_cache,
    read_parquet_footer_with_cache_via_fs,
    read_parquet_row_count,
)

comptime _Fs = LocalFs[NoopSink]


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _name(mut out: List[UInt8], header: UInt8, name: String):
    out.append(header)
    _uleb(out, name.byte_length())
    for b in name.as_bytes():
        out.append(b)


def _footer(num_rows: Int, second_name: String) -> List[UInt8]:
    """FileMetaData with the three schema elements described in the header
    (the last column named `second_name`) and `num_rows`."""
    var f: List[UInt8] = [0x15]  # 1: i32 version
    _zz(f, 2)
    f.append(0x19)  # 2: list schema
    f.append(0x3C)  # 3 structs
    # root: 4 name, 5 num_children
    _name(f, 0x48, "schema")
    f.append(0x15)
    _zz(f, 2)
    f.append(0x00)
    # a: 1 type INT64 (2), 3 repetition REQUIRED (0), 4 name
    f.append(0x15)
    _zz(f, 2)
    f.append(0x25)
    _zz(f, 0)
    _name(f, 0x18, "a")
    f.append(0x00)
    # s: 1 type BYTE_ARRAY (6), 3 repetition OPTIONAL (1), 4 name,
    # 6 converted_type UTF8 (0)
    f.append(0x15)
    _zz(f, 6)
    f.append(0x25)
    _zz(f, 1)
    _name(f, 0x18, second_name)
    f.append(0x25)
    _zz(f, 0)
    f.append(0x00)
    f.append(0x16)  # 3: i64 num_rows
    _zz(f, num_rows)
    f.append(0x19)  # 4: list row_groups, empty
    f.append(0x0C)
    f.append(0x00)
    return f^


def _file_bytes(
    num_rows: Int,
    second_name: String,
    footer_length_delta: Int = 0,
    trailing_magic: String = "PAR1",
) -> List[UInt8]:
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(24):
        out.append(UInt8(i * 7 % 251))
    var f = _footer(num_rows, second_name)
    for i in range(len(f)):
        out.append(f[i])
    var n = len(f) + footer_length_delta
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    for b in trailing_magic.as_bytes():
        out.append(b)
    return out^


def _framed(body: List[UInt8]) -> List[UInt8]:
    """`PAR1`, padding, `body` as the footer, its length and `PAR1`."""
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(24):
        out.append(UInt8(i * 7 % 251))
    for i in range(len(body)):
        out.append(body[i])
    var n = len(body)
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    for b in "PAR1".as_bytes():
        out.append(b)
    return out^


def _write(file_name: String, data: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + file_name
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()
    return path^


def _assert_a_s(mut summary: ParquetFooterSummary, second_name: String) raises:
    var schema = summary.take_schema()
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "a")
    assert_equal(schema.field_arrow_type(0), ArrowType.INT64)
    assert_false(schema.field_nullable(0))
    assert_equal(schema.field_name(1), second_name)
    assert_equal(schema.field_arrow_type(1), ArrowType.STRING)
    assert_true(schema.field_nullable(1))


def test_row_count_and_footer_agree() raises:
    var path = _write("pf_ok.parquet", _file_bytes(42, "s"))
    assert_equal(read_parquet_row_count(path), 42)
    var summary = read_parquet_footer(path)
    assert_equal(summary.row_count, 42)
    _assert_a_s(summary, "s")


def test_bad_trailing_magic_raises() raises:
    var path = _write("pf_magic.parquet", _file_bytes(42, "s", 0, "PARX"))
    with assert_raises(contains="PAR1"):
        _ = read_parquet_row_count(path)
    with assert_raises(contains="PAR1"):
        _ = read_parquet_footer(path)


def test_oversized_footer_length_raises() raises:
    var path = _write("pf_len.parquet", _file_bytes(42, "s", 1000))
    with assert_raises(contains="invalid metadata length"):
        _ = read_parquet_row_count(path)
    with assert_raises(contains="invalid metadata length"):
        _ = read_parquet_footer(path)


def test_file_shorter_than_minimum_raises() raises:
    var tiny: List[UInt8] = [0x50, 0x41, 0x52, 0x31, 1, 2, 3, 4]
    var path = _write("pf_tiny.parquet", tiny)
    with assert_raises():
        _ = read_parquet_row_count(path)
    with assert_raises():
        _ = read_parquet_footer(path)


def test_truncated_thrift_body_raises() raises:
    var whole = _footer(42, "s")
    var cut = List[UInt8]()
    for i in range(20):  # ends inside the schema list
        cut.append(whole[i])
    var path = _write("pf_cut.parquet", _framed(cut))
    with assert_raises():
        _ = read_parquet_row_count(path)
    with assert_raises():
        _ = read_parquet_footer(path)


def test_garbage_thrift_body_raises() raises:
    var junk = List[UInt8]()
    for _ in range(16):
        junk.append(0xFF)
    var path = _write("pf_junk.parquet", _framed(junk))
    with assert_raises():
        _ = read_parquet_row_count(path)
    with assert_raises():
        _ = read_parquet_footer(path)


def test_missing_file_raises() raises:
    var path = test_tmpdir() + "/pf_absent.parquet"
    with assert_raises():
        _ = read_parquet_row_count(path)
    with assert_raises():
        _ = read_parquet_footer(path)


def test_cached_read_matches_and_keeps_files_apart() raises:
    var one = _write("pf_one.parquet", _file_bytes(42, "s"))
    var two = _write("pf_two.parquet", _file_bytes(7, "t"))
    var cache = ParquetMetadataCache()

    var first = read_parquet_footer_with_cache(one, cache)
    assert_equal(first.row_count, 42)
    _assert_a_s(first, "s")
    var other = read_parquet_footer_with_cache(two, cache)
    assert_equal(other.row_count, 7)
    _assert_a_s(other, "t")
    assert_equal(cache.size(), 2)
    assert_equal(cache.miss_count(), 2)

    var again = read_parquet_footer_with_cache(one, cache)
    assert_equal(again.row_count, 42)
    _assert_a_s(again, "s")
    assert_equal(cache.miss_count(), 2)
    assert_equal(cache.hit_count_for(one), 1)
    assert_equal(cache.hit_count_for(two), 0)

    var uncached = read_parquet_footer(two)
    assert_equal(uncached.row_count, other.row_count)


def test_cached_read_via_fs_matches() raises:
    var one = _write("pf_fs_one.parquet", _file_bytes(42, "s"))
    var two = _write("pf_fs_two.parquet", _file_bytes(7, "t"))
    var cache = ParquetMetadataCache()
    var fs = _Fs.new()

    var first = read_parquet_footer_with_cache_via_fs(one, fs, cache)
    assert_equal(first.row_count, 42)
    _assert_a_s(first, "s")
    var other = read_parquet_footer_with_cache_via_fs(two, fs, cache)
    assert_equal(other.row_count, 7)
    _assert_a_s(other, "t")
    assert_equal(cache.size(), 2)
    var again = read_parquet_footer_with_cache_via_fs(two, fs, cache)
    assert_equal(again.row_count, 7)
    assert_equal(cache.miss_count(), 2)
    assert_equal(cache.hit_count_for(two), 1)
    assert_equal(cache.hit_count_for(one), 0)


def test_cached_read_of_a_bad_file_raises_and_caches_nothing() raises:
    var cache = ParquetMetadataCache()
    var bad = _write("pf_cache_bad.parquet", _file_bytes(42, "s", 0, "PARX"))
    with assert_raises(contains="PAR1"):
        _ = read_parquet_footer_with_cache(bad, cache)
    var fs = _Fs.new()
    with assert_raises(contains="PAR1"):
        _ = read_parquet_footer_with_cache_via_fs(bad, fs, cache)
    assert_equal(cache.size(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
