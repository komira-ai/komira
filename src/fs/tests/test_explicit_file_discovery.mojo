# =============================================================================
# test_explicit_file_discovery.mojo
# =============================================================================
# `ExplicitFileDiscovery`: a fixed file list with constant partition columns.
#
#   * `from_files` keeps the caller's file order and answers the partition
#     hooks from the values it was given: names, Arrow types, and one decoded
#     text per file and column; a list with no partition columns answers none.
#   * `from_files` refuses an empty file list, a value row count that is not
#     the file count, and a row that is not one value per column, each by name.
#   * `open` lists a file, a glob and a directory as `EagerGlobDiscovery` does
#     (sorted, no partition columns) and refuses a glob that matches nothing.
#   * It binds as a `FileDiscovery`.
# Files live under `test_tmpdir()`; no test shares a path with another.

from std.os import makedirs
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.schema import Field
from async_rt.ops.waker_sink import NoopSink
from fs.explicit_file_discovery import ExplicitFileDiscovery
from fs.file_discovery import FileDiscovery
from fs.local_fs import LocalFs
from runtime_paths import test_tmpdir


comptime _Fs = LocalFs[NoopSink]


def _paths3() -> List[String]:
    var p = List[String]()
    p.append(String("/z/last.parquet"))
    p.append(String("/a/first.parquet"))
    p.append(String("/m/mid.parquet"))
    return p^


def _row(a: String, b: String) -> List[String]:
    var r = List[String]()
    r.append(a.copy())
    r.append(b.copy())
    return r^


def _touch(path: String) raises:
    var fh = open(path, "w")
    fh.write(String("x"))
    fh.close()


def _fresh_dir(tag: String) raises -> String:
    var d = test_tmpdir() + "/explicit_disc_" + tag
    makedirs(d + "/sub", exist_ok=True)
    return d^


def _count_paths[D: FileDiscovery](d: D) -> Int:
    return d.num_paths()


def test_from_files_keeps_order_and_partition_values() raises:
    var cols = List[Field]()
    cols.append(Field("day", ArrowType.DATE32, False))
    cols.append(Field("region", ArrowType.STRING, False))
    var rows = List[List[String]]()
    rows.append(_row("2026-11-03", "eu"))
    rows.append(_row("2026-11-01", "us"))
    rows.append(_row("2026-11-02", ""))
    var d = ExplicitFileDiscovery.from_files(_paths3(), cols, rows)
    assert_equal(d.num_paths(), 3)
    assert_equal(d.path_at(0), "/z/last.parquet")
    assert_equal(d.path_at(1), "/a/first.parquet")
    assert_equal(d.path_at(2), "/m/mid.parquet")
    assert_equal(d.num_partition_cols(), 2)
    assert_equal(d.partition_col_name_at(0), "day")
    assert_equal(d.partition_col_name_at(1), "region")
    assert_true(d.partition_col_type_at(0) == ArrowType.DATE32)
    assert_true(d.partition_col_type_at(1) == ArrowType.STRING)
    var schema = d.partition_schema()
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.names[0], "day")
    assert_equal(schema.names[1], "region")
    var pv0 = d.partition_values_at(0)
    assert_equal(pv0.num_pairs(), 2)
    assert_equal(pv0.keys[0], "day")
    assert_equal(pv0.values[0], "2026-11-03")
    assert_equal(pv0.keys[1], "region")
    assert_equal(pv0.values[1], "eu")
    var pv1 = d.partition_values_at(1)
    assert_equal(pv1.values[0], "2026-11-01")
    assert_equal(pv1.values[1], "us")
    var pv2 = d.partition_values_at(2)
    assert_equal(pv2.values[0], "2026-11-02")
    assert_equal(pv2.values[1], "")
    assert_false(ExplicitFileDiscovery.is_lazy())


def test_from_files_without_partition_columns_answers_none() raises:
    var d = ExplicitFileDiscovery.from_files(
        _paths3(), List[Field](), List[List[String]]()
    )
    assert_equal(d.num_paths(), 3)
    assert_equal(d.num_partition_cols(), 0)
    assert_equal(d.partition_schema().num_columns(), 0)
    assert_equal(d.partition_values_at(1).num_pairs(), 0)


def test_from_files_accepts_empty_value_rows_for_no_columns() raises:
    var rows = List[List[String]]()
    for _ in range(3):
        rows.append(List[String]())
    var d = ExplicitFileDiscovery.from_files(
        _paths3(), List[Field](), rows
    )
    assert_equal(d.num_paths(), 3)
    assert_equal(d.num_partition_cols(), 0)
    assert_equal(d.partition_values_at(2).num_pairs(), 0)


def test_from_files_refuses_an_empty_file_list() raises:
    with assert_raises(contains="ExplicitFileDiscovery: the file list is empty"):
        _ = ExplicitFileDiscovery.from_files(
            List[String](), List[Field](), List[List[String]]()
        )


def test_from_files_refuses_a_value_row_count_that_is_not_the_file_count() raises:
    var cols = List[Field]()
    cols.append(Field("n", ArrowType.INT64, False))
    var rows = List[List[String]]()
    var one = List[String]()
    one.append(String("1"))
    rows.append(one^)
    with assert_raises(
        contains="ExplicitFileDiscovery: 1 partition value rows for 3 files"
    ):
        _ = ExplicitFileDiscovery.from_files(_paths3(), cols, rows)


def test_from_files_refuses_a_row_that_is_not_one_value_per_column() raises:
    var cols = List[Field]()
    cols.append(Field("n", ArrowType.INT64, False))
    cols.append(Field("m", ArrowType.INT64, False))
    var rows = List[List[String]]()
    rows.append(_row("1", "2"))
    var short = List[String]()
    short.append(String("3"))
    rows.append(short^)
    rows.append(_row("5", "6"))
    with assert_raises(
        contains=(
            "ExplicitFileDiscovery: file '/a/first.parquet' has 1 partition"
            " values for 2 partition columns"
        )
    ):
        _ = ExplicitFileDiscovery.from_files(_paths3(), cols, rows)


def test_open_lists_a_single_file_as_itself() raises:
    var dir = _fresh_dir("single")
    var file = dir + "/only.parquet"
    _touch(file)
    var fs = _Fs.new()
    var d = ExplicitFileDiscovery.open(fs, file)
    assert_equal(d.num_paths(), 1)
    assert_equal(d.path_at(0), file)
    assert_equal(d.num_partition_cols(), 0)


def test_open_expands_a_glob_sorted() raises:
    var dir = _fresh_dir("glob")
    _touch(dir + "/b.parquet")
    _touch(dir + "/a.parquet")
    _touch(dir + "/sub/c.parquet")
    _touch(dir + "/a.txt")
    var fs = _Fs.new()
    var d = ExplicitFileDiscovery.open(fs, dir + "/*.parquet")
    assert_equal(d.num_paths(), 2)
    assert_equal(d.path_at(0), dir + "/a.parquet")
    assert_equal(d.path_at(1), dir + "/b.parquet")
    var deep = ExplicitFileDiscovery.open(fs, dir + "/**/*.parquet")
    assert_equal(deep.num_paths(), 3)
    assert_equal(deep.path_at(2), dir + "/sub/c.parquet")
    assert_equal(deep.partition_values_at(0).num_pairs(), 0)


def test_open_refuses_a_glob_that_matches_nothing() raises:
    var dir = _fresh_dir("nomatch")
    var fs = _Fs.new()
    with assert_raises(contains="no files matched glob pattern"):
        _ = ExplicitFileDiscovery.open(fs, dir + "/*.parquet")


def test_binds_as_a_file_discovery() raises:
    var d = ExplicitFileDiscovery.from_files(
        _paths3(), List[Field](), List[List[String]]()
    )
    assert_equal(_count_paths(d), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
