# =============================================================================
# FooterCache and ParquetFooters over Parquet files written by this repo's writer
# =============================================================================
#
# The files are written in the test (komira_parquet_writer) into the test's
# scratch directory, and read back through the cache, which parses footers with
# komira_parquet's reader: a different implementation from the writer.
#
# What each test proves, and the defect it catches:
#   * test_footer_gives_schema_row_count_and_row_groups: a 1000-row file cut
#     into row groups of 300 reads back its three columns (name, Arrow type,
#     nullability), 1000 rows and row groups of 300, 300, 300 and 100. Catches
#     a schema read in the wrong order or with the wrong nullability, and a
#     row count that is a row group's rather than the file's.
#   * test_two_lookups_read_the_file_once: footer, summary, the same lookup
#     through a copied handle and through ParquetFooters make one read from
#     storage (read_count 1) and the rest cache hits. Catches a cache that
#     reads per lookup, and a copied handle that gets its own cache.
#   * test_two_files_are_cached_apart: two paths give their own row counts and
#     are two reads. Catches a cache keyed by something coarser than the path.
#   * test_a_missing_file_is_a_named_error: the error names the path and says
#     it is not there. test_a_text_file_is_a_named_error and
#     test_a_short_file_is_a_named_error: the same for a file that is not
#     Parquet (bad magic) and for one shorter than 12 bytes.
#   * test_a_failed_read_is_not_cached: a path whose read failed reads fine
#     once the file is replaced by a valid one. Catches a cached failure.
#   * test_changed_since_read: false while the file is untouched, true after it
#     is replaced by a longer one; an unread path is refused by name.
#   * test_a_new_mtime_alone_is_a_change, test_a_removed_file_is_a_change: a
#     file with the same bytes and size but another modification time, and a
#     removed file, read as changed. (The inode field of the identity is not
#     varied here: no rename is available to a test.)
#   * test_invalidate_rereads: a rewritten file is served as first read (the
#     old row count) until invalidate; then the next lookup reads again and
#     sees the new file's row count. Catches a cache that re-reads on a hit.
#   * test_null_count_sums_every_row_group: column y has 100 nulls over four
#     row groups (30, 30, 30, 10): the answer is 100, not one row group's.
#     A column the file lacks is unknown (None).
#   * test_null_count_is_unknown_when_a_row_group_records_none: a column whose
#     statistics carry no null_count gives None, not 0.
#   * test_a_glob_path_is_refused_by_name.
# =============================================================================

from std.os import remove
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_parquet_api.metadata import SchemaElement, Statistics
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_footers.footer_cache import FooterCache
from komira_parquet_footers.parquet_footers import ParquetFooters
from komira_parquet_writer import (
    ParquetFileWriter,
    make_schema_elements_nullable,
    write_record_batch_to_parquet_bytes,
)
from komira_buffer.file_identity import set_file_mtime_ns
from komira_runtime_paths import test_tmpdir


def _batch(n: Int) raises -> RecordBatch:
    """x INT64 not null (2i+1), y INT64 nullable (i % 10, null when i % 10 is
    3), s STRING not null."""
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var x = PrimitiveArray[DType.int64].allocate(n)
    var y = PrimitiveArray[DType.int64].allocate_nullable(n)
    var s = List[String]()
    for i in range(n):
        x.set(i, Int64(2 * i + 1))
        y.set(i, Int64(i % 10))
        if i % 10 == 3:
            y._set_null(i)
        s.append(String("k") + String(i % 4))
    sb.add_field(Field("x", ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](x))
    sb.add_field(Field("y", ArrowType.INT64, True))
    b.add_column(Column.from_primitive[DType.int64](y))
    sb.add_field(Field("s", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(s)))
    return b.build(sb.build())


def _put(file_name: String, data: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + file_name
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()
    return path^


def _write_table(file_name: String, rows: Int, rg_rows: Int) raises -> String:
    var bytes = write_record_batch_to_parquet_bytes(
        _batch(rows), CompressionCodec.UNCOMPRESSED, max_rows_per_rg=rg_rows
    )
    return _put(file_name, bytes)


def _text(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(65 + i % 26))
    return out^


def test_footer_gives_schema_row_count_and_row_groups() raises:
    var path = _write_table("ff_shape.parquet", 1000, 300)
    var cache = FooterCache()
    var summary = cache.summary(path)
    assert_equal(summary.row_count, 1000)
    var schema = summary.take_schema()
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(0), "x")
    assert_equal(schema.field_name(1), "y")
    assert_equal(schema.field_name(2), "s")
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(2) == ArrowType.STRING)
    assert_false(schema.field_nullable(0))
    assert_true(schema.field_nullable(1))
    assert_false(schema.field_nullable(2))
    var meta = cache.footer(path)
    ref md = meta[]
    assert_equal(len(md.row_groups), 4)
    assert_equal(md.row_groups[0].num_rows, 300)
    assert_equal(md.row_groups[1].num_rows, 300)
    assert_equal(md.row_groups[2].num_rows, 300)
    assert_equal(md.row_groups[3].num_rows, 100)


def test_two_lookups_read_the_file_once() raises:
    var path = _write_table("ff_once.parquet", 1000, 300)
    var cache = FooterCache()
    var other_handle = cache.copy()
    var footers = ParquetFooters(cache.copy())
    _ = cache.footer(path)
    _ = cache.summary(path)
    _ = other_handle.footer(path)
    _ = footers.footer_schema(path)
    _ = footers.column_null_count(path, "y")
    assert_equal(cache.read_count(), 1)
    assert_equal(other_handle.read_count(), 1)
    assert_equal(footers.cache().read_count(), 1)
    assert_true(cache.lookup_count(path) >= 4)


def test_two_files_are_cached_apart() raises:
    var a = _write_table("ff_a.parquet", 1000, 300)
    var b = _write_table("ff_b.parquet", 50, 50)
    var cache = FooterCache()
    var sa = cache.summary(a)
    var sb = cache.summary(b)
    assert_equal(sa.row_count, 1000)
    assert_equal(sb.row_count, 50)
    assert_equal(cache.read_count(), 2)
    assert_equal(cache.summary(a).row_count, 1000)
    assert_equal(cache.read_count(), 2)


def test_a_missing_file_is_a_named_error() raises:
    var path = test_tmpdir() + "/ff_absent.parquet"
    var cache = FooterCache()
    with assert_raises(contains="ff_absent.parquet"):
        _ = cache.footer(path)
    with assert_raises(contains="ff_absent.parquet"):
        _ = cache.summary(path)
    with assert_raises(contains="ff_absent.parquet"):
        _ = ParquetFooters().footer_schema(path)
    assert_equal(cache.read_count(), 0)


def test_a_text_file_is_a_named_error() raises:
    var path = _put("ff_text.parquet", _text(200))
    var cache = FooterCache()
    with assert_raises(contains="ff_text.parquet"):
        _ = cache.footer(path)
    with assert_raises(contains="ff_text.parquet"):
        _ = cache.summary(path)


def test_a_short_file_is_a_named_error() raises:
    var path = _put("ff_short.parquet", _text(5))
    var cache = FooterCache()
    with assert_raises(contains="5 bytes"):
        _ = cache.footer(path)
    with assert_raises(contains="ff_short.parquet"):
        _ = ParquetFooters().footer_schema(path)


def test_a_failed_read_is_not_cached() raises:
    var path = _put("ff_heal.parquet", _text(200))
    var cache = FooterCache()
    with assert_raises(contains="ff_heal.parquet"):
        _ = cache.footer(path)
    _ = _write_table("ff_heal.parquet", 70, 70)
    assert_equal(cache.summary(path).row_count, 70)


def test_changed_since_read() raises:
    var path = _write_table("ff_change.parquet", 100, 100)
    var cache = FooterCache()
    with assert_raises(contains="no footer was read"):
        _ = cache.changed_since_read(path)
    _ = cache.footer(path)
    assert_false(cache.changed_since_read(path))
    _ = _write_table("ff_change.parquet", 5000, 1000)
    assert_true(cache.changed_since_read(path))


def test_a_new_mtime_alone_is_a_change() raises:
    # Same bytes, same size: only the modification time differs.
    var path = _write_table("ff_mtime.parquet", 100, 100)
    assert_true(set_file_mtime_ns(path, 1_000_000_000_000_000_000))
    var cache = FooterCache()
    _ = cache.footer(path)
    assert_false(cache.changed_since_read(path))
    assert_true(set_file_mtime_ns(path, 1_100_000_000_000_000_000))
    assert_true(cache.changed_since_read(path))


def test_a_removed_file_is_a_change() raises:
    var path = _write_table("ff_removed.parquet", 100, 100)
    var cache = FooterCache()
    _ = cache.footer(path)
    remove(path)
    assert_true(cache.changed_since_read(path))
    # The held footer is still served: a lookup never re-reads.
    assert_equal(cache.summary(path).row_count, 100)


def test_invalidate_rereads() raises:
    var path = _write_table("ff_inval.parquet", 100, 100)
    var cache = FooterCache()
    assert_equal(cache.summary(path).row_count, 100)
    _ = _write_table("ff_inval.parquet", 400, 100)
    assert_equal(cache.summary(path).row_count, 100)
    cache.invalidate(path)
    assert_equal(cache.summary(path).row_count, 400)
    assert_equal(cache.read_count(), 2)
    assert_false(cache.changed_since_read(path))


def test_null_count_sums_every_row_group() raises:
    var path = _write_table("ff_nulls.parquet", 1000, 300)
    var footers = ParquetFooters()
    var n = footers.column_null_count(path, "y")
    assert_true(Bool(n))
    assert_equal(n.value(), 100)
    assert_false(Bool(footers.column_null_count(path, "no_such_column")))
    with assert_raises(contains="ff_absent_nulls.parquet"):
        _ = footers.column_null_count(
            test_tmpdir() + "/ff_absent_nulls.parquet", "y"
        )


def test_null_count_is_unknown_when_a_row_group_records_none() raises:
    var names: List[String] = ["v"]
    var types: List[ParquetType] = [ParquetType.INT64]
    var nullable: List[Bool] = [True]
    var w = ParquetFileWriter.create(
        make_schema_elements_nullable(names^, types^, nullable^)
    )
    var v = PrimitiveArray[DType.int64].allocate_nullable(10)
    for i in range(10):
        v.set(i, Int64(i))
    v._set_null(2)
    w.write_batch_with_stats[DType.int64](0, v, Statistics())
    var path = _put("ff_nostats.parquet", w.close_to_bytes())
    var footers = ParquetFooters()
    assert_false(Bool(footers.column_null_count(path, "v")))


def test_a_glob_path_is_refused_by_name() raises:
    var footers = ParquetFooters()
    with assert_raises(contains="data/*.parquet"):
        _ = footers.footer_schema("data/*.parquet")
    with assert_raises(contains="glob"):
        _ = footers.footer_schema("data/part-[0-9].parquet")
    with assert_raises(contains="part-?.parquet"):
        _ = footers.footer_schema("data/part-?.parquet")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
