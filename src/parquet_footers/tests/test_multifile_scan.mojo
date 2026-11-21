# =============================================================================
# A Parquet table of several files: globs, directories, Hive partitions, facts
# =============================================================================
#
# Real Parquet files written under `test_tmpdir()`, resolved with
# `resolve_parquet_source` (and `ParquetFooters.parquet_relation`) and
# registered with `register_parquet_table`.
#
# What each test proves:
#   * test_a_glob_expands_to_the_sorted_files: `*.parquet` and a brace glob
#     list their matches sorted byte-wise, with the first file's schema and no
#     partition columns; a plain file stays a one-path source.
#   * test_a_directory_is_every_parquet_file_below_it: with directories allowed,
#     a directory (with or without a trailing slash) is the `.parquet` files at
#     any depth; a hidden file, a file in a hidden directory and a file that is
#     not `.parquet` are skipped.
#   * test_a_directory_named_in_sql_is_refused_by_name: `parquet_relation` of a
#     directory is `PARQUET_PATH_IS_DIRECTORY`.
#   * test_no_match_is_refused_by_name: a glob matching nothing and a directory
#     without `.parquet` files are `PARQUET_GLOB_NO_MATCH`.
#   * test_files_with_different_schemas_are_refused_by_name: a renamed, retyped,
#     nullable, narrower or differently scaled decimal column in the second file
#     is `PARQUET_FILES_SCHEMA_MISMATCH` naming both files and the column.
#   * test_hive_columns_follow_the_data_columns_ordered_by_key: keys `year` and
#     `m` become columns `m`, `year` after the data columns, not nullable, with
#     the decoded values of each sorted file.
#   * test_hive_column_types_follow_the_first_value_and_fall_back_to_varchar:
#     DATE, TIMESTAMP and BIGINT columns, text kept as written (`007`), and a
#     later value that does not parse (or an overflowing or odd one) makes the
#     column VARCHAR; percent escapes are decoded.
#   * test_hive_values_that_may_be_cast_differently_are_refused: an empty value,
#     NULL in any case, the Hive default partition, a bad percent escape, a
#     repeated key, and values DuckDB may read as dates, timestamps or integers
#     are `HIVE_PARTITION_VALUE_UNSUPPORTED`.
#   * test_a_column_of_dates_and_timestamps_is_refused: a partition column with
#     a DATE value and a TIMESTAMP value, in either order, is
#     `HIVE_PARTITION_VALUE_UNSUPPORTED`.
#   * test_hive_modes: OFF has no partition columns; AUTO with differing key sets
#     has none; ON refuses the differing file with `HIVE_PARTITION_LAYOUT_MISMATCH`;
#     ON with no key in the first file has none.
#   * test_a_partition_key_that_is_a_data_column_is_refused: `X=1` against column
#     `x` is `HIVE_PARTITION_COLUMN_IN_FILE`.
#   * test_only_directories_make_partitions: a file name holding `=` is ignored,
#     and a single named file under a `key=value` directory is partitioned.
#   * test_register_a_directory_and_a_hive_tree: a directory registers its files
#     and the table checks file by file; a Hive tree adds its partition columns
#     to the table's schema.
#   * test_a_disagreeing_second_file_is_refused_by_name: a table whose second
#     file was rewritten with another schema is refused naming that file, and a
#     fresh reader names the schema difference.
#   * test_facts_fold_over_every_file: row count 18, x min -50 and max 104, y
#     null count 4, f min -50 and max 102, and no bounds for a string column over three
#     files; one file gives the facts of `add_parquet_scan`; a replaced second
#     file is refused naming it.
#   * test_a_scan_of_some_files_of_a_table_checks_and_folds_only_those: a scan
#     of one file of a table gets that file's facts even when another file of
#     the table was replaced; a scan of the replaced file is refused naming it.
#   * test_folding_unknown_nulls_distinct_counts_and_missing_bounds: folding
#     hand-built statistics makes the null count unknown when either side's is,
#     keeps the largest distinct count, and drops a bound that either side lacks.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from lowering.lowered_plan import LoweringInputs
from parquet_api.types import CompressionCodec
from parquet_footers.lowering_facts import (
    add_catalog_scan,
    add_catalog_table_scan,
    add_parquet_files_scan,
    _fold_into,
    add_parquet_scan,
)
from parquet_footers.parquet_files import (
    HIVE_PARTITION_COLUMN_IN_FILE,
    HIVE_PARTITION_LAYOUT_MISMATCH,
    HIVE_PARTITION_VALUE_UNSUPPORTED,
    PARQUET_FILES_SCHEMA_MISMATCH,
    PARQUET_GLOB_NO_MATCH,
    PARQUET_PATH_IS_DIRECTORY,
    resolve_parquet_source,
)
from parquet_footers.parquet_footers import (
    ParquetFooters,
    check_catalog_table,
    register_parquet_table,
)
from parquet_writer import write_record_batch_to_parquet_bytes
from plan_expr.scalar_value import ScalarValue
from plan_stats.table_stats import ColumnStats, TableStats
from runtime_paths import test_tmpdir
from scan_source.parquet_source import ParquetSource
from sql.sql_ast import (
    HIVE_PARTITIONING_AUTO,
    HIVE_PARTITIONING_OFF,
    HIVE_PARTITIONING_ON,
)
from sql.sql_catalog import SqlCatalog

# The shape of a test file's columns.
comptime _NORMAL = 0
comptime _RENAMED = 1
comptime _RETYPED = 2
comptime _NULLABLE_X = 3
comptime _NARROW = 4


def _batch(rows: Int, base: Int, shape: Int = _NORMAL) raises -> RecordBatch:
    """x INT64 (base + i, not null), y INT64 (null where i % 5 == 0), f FLOAT64
    (base + i / 2), s STRING; `shape` changes one column."""
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var x = PrimitiveArray[DType.int64].allocate(rows)
    if shape == _NULLABLE_X:
        x = PrimitiveArray[DType.int64].allocate_nullable(rows)
    for i in range(rows):
        x.set(i, Int64(base + i))
    sb.add_field(Field("x", ArrowType.INT64, shape == _NULLABLE_X))
    b.add_column(Column.from_primitive[DType.int64](x))
    if shape == _NARROW:
        return b.build(sb.build())
    var y_name = String("z") if shape == _RENAMED else String("y")
    if shape == _RETYPED:
        var yf = PrimitiveArray[DType.float64].allocate_nullable(rows)
        for i in range(rows):
            yf.set(i, Float64(i))
            if i % 5 == 0:
                yf._set_null(i)
        sb.add_field(Field(y_name, ArrowType.FLOAT64, True))
        b.add_column(Column.from_primitive[DType.float64](yf))
    else:
        var y = PrimitiveArray[DType.int64].allocate_nullable(rows)
        for i in range(rows):
            y.set(i, Int64(i))
            if i % 5 == 0:
                y._set_null(i)
        sb.add_field(Field(y_name, ArrowType.INT64, True))
        b.add_column(Column.from_primitive[DType.int64](y))
    var f = PrimitiveArray[DType.float64].allocate(rows)
    var s = List[String]()
    for i in range(rows):
        f.set(i, Float64(base) + Float64(i) / 2.0)
        s.append(String("k") + String(i % 3))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    b.add_column(Column.from_primitive[DType.float64](f))
    sb.add_field(Field("s", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(s)))
    return b.build(sb.build())


def _put(path: String, data: List[UInt8]) raises:
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()


def _root(name: String) raises -> String:
    var dir = test_tmpdir() + "/mf_" + name
    makedirs(dir, exist_ok=True)
    return dir^


def _write(
    dir: String, file_name: String, rows: Int, base: Int, shape: Int = _NORMAL
) raises -> String:
    """Write a test file at `dir/file_name` (creating `dir`); its path."""
    makedirs(dir, exist_ok=True)
    var path = dir + "/" + file_name
    _put(
        path,
        write_record_batch_to_parquet_bytes(
            _batch(rows, base, shape), CompressionCodec.UNCOMPRESSED
        ),
    )
    return path^


def _decimal_file(dir: String, file_name: String, scale: Int) raises -> String:
    makedirs(dir, exist_ok=True)
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var d = Decimal128Array.allocate_nullable(3, 20, scale)
    for i in range(3):
        d.set_i128(i, SIMD[DType.int128, 1](i * 100 + 7))
    sb.add_field(Field.decimal128("d", 20, scale, False))
    b.add_column(Column.from_decimal128(d))
    var path = dir + "/" + file_name
    _put(
        path,
        write_record_batch_to_parquet_bytes(
            b.build(sb.build()), CompressionCodec.UNCOMPRESSED
        ),
    )
    return path^


def _refusal(path: String, mode: UInt8 = HIVE_PARTITIONING_AUTO) -> String:
    """The error text of resolving `path` (directories allowed), or ""."""
    try:
        _ = resolve_parquet_source(ParquetFooters(), path, mode, True)
    except e:
        return String(e)
    return String("")


def _one_dir_each(
    root: String, dirs: List[String], mode: UInt8 = HIVE_PARTITIONING_AUTO
) raises -> ParquetSource:
    """A source over `root/<dir>/f.parquet` for every `dir`."""
    for i in range(len(dirs)):
        _ = _write(root + "/" + dirs[i], "f.parquet", 2, i)
    return resolve_parquet_source(
        ParquetFooters(), root + "/**/*.parquet", mode, False
    )


def _dirs(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a.copy())
    if b.byte_length() > 0:
        out.append(b.copy())
    if c.byte_length() > 0:
        out.append(c.copy())
    return out^


def test_a_glob_expands_to_the_sorted_files() raises:
    var dir = _root("glob")
    var b = _write(dir, "b.parquet", 5, 100)
    var a = _write(dir, "a.parquet", 4, 0)
    var c = _write(dir, "c.parquet", 3, 50)
    _ = _write(dir, "d.other", 3, 50)
    var footers = ParquetFooters()
    var src = footers.parquet_relation(dir + "/*.parquet", HIVE_PARTITIONING_AUTO)
    assert_equal(len(src.paths), 3)
    assert_equal(src.paths[0], a)
    assert_equal(src.paths[1], b)
    assert_equal(src.paths[2], c)
    assert_equal(src.schema().num_columns(), 4)
    assert_equal(len(src.partition_cols), 0)
    var braces = footers.parquet_relation(
        dir + "/{c,a}*.parquet", HIVE_PARTITIONING_AUTO
    )
    assert_equal(len(braces.paths), 2)
    assert_equal(braces.paths[0], a)
    assert_equal(braces.paths[1], c)
    var one = footers.parquet_relation(a, HIVE_PARTITIONING_AUTO)
    assert_equal(len(one.paths), 1)
    assert_equal(one.path, a)
    assert_equal(len(one.partition_cols), 0)
    var single = footers.parquet_relation(dir + "/a.*", HIVE_PARTITIONING_AUTO)
    assert_equal(len(single.paths), 1)
    assert_equal(single.path, a)


def test_a_directory_is_every_parquet_file_below_it() raises:
    var dir = _root("dir")
    var a = _write(dir, "a.parquet", 2, 0)
    var b = _write(dir + "/sub/deep", "b.parquet", 2, 10)
    _ = _write(dir, ".hidden.parquet", 2, 20)
    _ = _write(dir + "/.cache", "c.parquet", 2, 30)
    _put(dir + "/notes.txt", List[UInt8](length=10, fill=65))
    _ = _write(dir, "e.parquet.bak", 2, 40)
    var footers = ParquetFooters()
    for spelling in range(2):
        var path = dir if spelling == 0 else dir + "/"
        var src = resolve_parquet_source(
            footers, path, HIVE_PARTITIONING_AUTO, True
        )
        assert_equal(len(src.paths), 2)
        assert_equal(src.paths[0], a)
        assert_equal(src.paths[1], b)
        assert_equal(len(src.partition_cols), 0)


def test_a_directory_named_in_sql_is_refused_by_name() raises:
    var dir = _root("sqldir")
    _ = _write(dir, "a.parquet", 2, 0)
    with assert_raises(contains=PARQUET_PATH_IS_DIRECTORY + ": '" + dir + "'"):
        _ = ParquetFooters().parquet_relation(dir, HIVE_PARTITIONING_AUTO)


def test_no_match_is_refused_by_name() raises:
    var dir = _root("nomatch")
    var empty = _root("nomatch_empty")
    _ = _write(dir, "a.parquet", 2, 0)
    var footers = ParquetFooters()
    with assert_raises(contains=PARQUET_GLOB_NO_MATCH + ": no file matches"):
        _ = footers.parquet_relation(dir + "/*.csv", HIVE_PARTITIONING_AUTO)
    with assert_raises(contains=PARQUET_GLOB_NO_MATCH + ": the directory"):
        _ = resolve_parquet_source(footers, empty, HIVE_PARTITIONING_AUTO, True)
    var hidden_only = _root("nomatch_hidden")
    _ = _write(hidden_only, ".a.parquet", 2, 0)
    assert_true(_refusal(hidden_only).startswith(PARQUET_GLOB_NO_MATCH))


def test_files_with_different_schemas_are_refused_by_name() raises:
    var shapes = List[Int]()
    shapes.append(_RENAMED)
    shapes.append(_RETYPED)
    shapes.append(_NULLABLE_X)
    shapes.append(_NARROW)
    var needles = List[String]()
    needles.append("column 1 is 'z', the first file has 'y'")
    needles.append("column 'y' is")
    needles.append("column 'x' is nullable, the first file has it not null")
    needles.append("it has 1 columns, the first file has 4")
    for i in range(len(shapes)):
        var dir = _root("schema_" + String(i))
        var first = _write(dir, "a.parquet", 3, 0)
        var second = _write(dir, "b.parquet", 3, 0, shapes[i])
        var text = _refusal(dir + "/*.parquet")
        assert_true(text.startswith(PARQUET_FILES_SCHEMA_MISMATCH + ": '" + second))
        assert_true(text.find("differs from '" + first + "': " + needles[i]) >= 0)
    var ddir = _root("schema_decimal")
    var d1 = _decimal_file(ddir, "a.parquet", 2)
    var d2 = _decimal_file(ddir, "b.parquet", 3)
    var dtext = _refusal(ddir + "/*.parquet")
    assert_equal(
        dtext,
        PARQUET_FILES_SCHEMA_MISMATCH + ": '" + d2 + "' differs from '" + d1
        + "': column 'd' is decimal(20, 3), the first file has decimal(20, 2)",
    )


def test_hive_columns_follow_the_data_columns_ordered_by_key() raises:
    var root = _root("hive_order")
    var dirs = _dirs("year=2028/m=1", "year=2028/m=2", "year=2027/m=1")
    var src = _one_dir_each(root, dirs)
    assert_equal(len(src.paths), 3)
    assert_equal(src.paths[0], root + "/year=2027/m=1/f.parquet")
    assert_equal(src.paths[1], root + "/year=2028/m=1/f.parquet")
    assert_equal(src.paths[2], root + "/year=2028/m=2/f.parquet")
    assert_equal(src.schema().num_columns(), 4)
    assert_equal(len(src.partition_cols), 2)
    assert_equal(src.partition_cols[0].name, "m")
    assert_equal(src.partition_cols[1].name, "year")
    for c in range(2):
        assert_true(src.partition_cols[c].arrow_type == ArrowType.INT64)
        assert_false(src.partition_cols[c].nullable)
    assert_equal(len(src.partition_values), 3)
    assert_equal(src.partition_values[0][0], "1")
    assert_equal(src.partition_values[0][1], "2027")
    assert_equal(src.partition_values[1][0], "1")
    assert_equal(src.partition_values[1][1], "2028")
    assert_equal(src.partition_values[2][0], "2")
    assert_equal(src.partition_values[2][1], "2028")


def _single_type(label: String, dirs: List[String]) raises -> ArrowType:
    """The type of the one partition column `k` of a tree whose directories
    are `dirs`."""
    var src = _one_dir_each(_root("types_" + label), dirs)
    assert_equal(len(src.partition_cols), 1)
    assert_equal(src.partition_cols[0].name, "k")
    return src.partition_cols[0].arrow_type


def test_hive_column_types_follow_the_first_value_and_fall_back_to_varchar() raises:
    assert_true(
        _single_type("date", _dirs("k=2028-01-02", "k=2028-02-29"))
        == ArrowType.DATE32
    )
    assert_true(
        _single_type("ts", _dirs("k=2028-01-02 03:04:05", "k=2027-12-31 23:59:59"))
        == ArrowType.TIMESTAMP_US
    )
    assert_true(
        _single_type("int", _dirs("k=007", "k=-8", "k=9223372036854775807"))
        == ArrowType.INT64
    )
    assert_true(
        _single_type("minint", _dirs("k=-9223372036854775808"))
        == ArrowType.INT64
    )
    assert_true(_single_type("str", _dirs("k=abc", "k=1")) == ArrowType.STRING)
    # A letter where a date or a time holds a digit: neither a date, a
    # timestamp nor a number, and nothing DuckDB's cast reads otherwise.
    assert_true(
        _single_type("letter_in_date", _dirs("k=2028-0a-01"))
        == ArrowType.STRING
    )
    assert_true(
        _single_type("letter_in_time", _dirs("k=2028-01-01 aa:00:00"))
        == ArrowType.STRING
    )
    assert_true(_single_type("int_then_text", _dirs("k=1", "k=x")) == ArrowType.STRING)
    assert_true(
        _single_type("date_then_int", _dirs("k=2028-01-02", "k=5"))
        == ArrowType.STRING
    )
    assert_true(
        _single_type("date_then_bad", _dirs("k=2028-01-02", "k=abc"))
        == ArrowType.STRING
    )
    assert_true(_single_type("big", _dirs("k=9223372036854775808")) == ArrowType.STRING)
    assert_true(_single_type("negbig", _dirs("k=-9223372036854775809")) == ArrowType.STRING)
    assert_true(_single_type("longint", _dirs("k=12345678901234567890123")) == ArrowType.STRING)
    assert_true(_single_type("dash", _dirs("k=-")) == ArrowType.STRING)
    assert_true(
        _single_type("below_limit", _dirs("k=1000000000000000000"))
        == ArrowType.INT64
    )
    assert_true(_single_type("digit_odd", _dirs("k=1x-2")) == ArrowType.STRING)
    assert_true(_single_type("float", _dirs("k=1.5")) == ArrowType.STRING)
    assert_true(_single_type("mixed", _dirs("k=v1-2")) == ArrowType.STRING)
    assert_true(_single_type("blank", _dirs("k= ")) == ArrowType.STRING)
    var src = _one_dir_each(_root("types_values"), _dirs("k=007", "k=a%20b"))
    assert_true(src.partition_cols[0].arrow_type == ArrowType.STRING)
    assert_equal(src.partition_values[0][0], "007")
    assert_equal(src.partition_values[1][0], "a b")
    var kept = _one_dir_each(_root("types_kept"), _dirs("k=007", "k=8"))
    assert_true(kept.partition_cols[0].arrow_type == ArrowType.INT64)
    assert_equal(kept.partition_values[0][0], "007")
    assert_equal(kept.partition_values[1][0], "8")
    var escaped = _one_dir_each(_root("types_slash"), _dirs("k=a%2Fb"))
    assert_equal(escaped.partition_values[0][0], "a/b")


def test_hive_values_that_may_be_cast_differently_are_refused() raises:
    var bad = List[String]()
    bad.append("k=")
    bad.append("k=NULL")
    bad.append("k=null")
    bad.append("k=__HIVE_DEFAULT_PARTITION__")
    bad.append("k=%zz")
    bad.append("k=%4")
    bad.append("k=%4EULL")
    bad.append("k=%205")
    bad.append("k=5%20")
    bad.append("k=+5")
    bad.append("k=2028-1-1")
    bad.append("k=2028-02-30")
    bad.append("k=2028-01-01T00:00:00")
    bad.append("k=2028-01-01 24:00:00")
    bad.append("k=2028-01-01 00:00:00.5")
    bad.append("k=2028%2F01%2F01")
    bad.append("k=1:2")
    bad.append("a=1/a=2")
    bad.append("k=2028-13-01")
    bad.append("k=2028-01-01 00-00-00")
    for i in range(len(bad)):
        var root = _root("bad_" + String(i))
        _ = _write(root + "/" + bad[i], "f.parquet", 2, 0)
        var text = _refusal(root + "/**/*.parquet")
        assert_true(text.startswith(HIVE_PARTITION_VALUE_UNSUPPORTED + ": "))
        assert_true(text.find("/f.parquet") >= 0 or text.find(root) >= 0)
    var repeated = _refusal(_root("bad_17") + "/**/*.parquet")
    assert_true(repeated.find("the key 'a' appears twice") >= 0)
    # With partitioning off, the same values are never read.
    var off_root = _root("bad_off")
    _ = _write(off_root + "/k=NULL", "f.parquet", 2, 0)
    assert_equal(
        _refusal(off_root + "/**/*.parquet", HIVE_PARTITIONING_OFF), ""
    )


def test_a_column_of_dates_and_timestamps_is_refused() raises:
    var first = _root("date_ts_a")
    _ = _write(first + "/dt=2028-01-01 10:00:00", "f.parquet", 2, 0)
    _ = _write(first + "/dt=2028-01-02", "f.parquet", 2, 0)
    var text = _refusal(first + "/**/*.parquet")
    assert_true(text.startswith(HIVE_PARTITION_VALUE_UNSUPPORTED + ": "))
    assert_true(text.find("holds both dates and timestamps") >= 0)
    var second = _root("date_ts_b")
    _ = _write(second + "/dt=2028-01-01", "f.parquet", 2, 0)
    _ = _write(second + "/dt=2028-01-02 10:00:00", "f.parquet", 2, 0)
    assert_true(
        _refusal(second + "/**/*.parquet").find("holds both dates and timestamps")
        >= 0
    )


def test_hive_modes() raises:
    var root = _root("modes")
    var dirs = _dirs("a=1", "a=2")
    var on = _one_dir_each(root, dirs, HIVE_PARTITIONING_ON)
    assert_equal(len(on.partition_cols), 1)
    var off = _one_dir_each(_root("modes_off"), dirs, HIVE_PARTITIONING_OFF)
    assert_equal(len(off.paths), 2)
    assert_equal(len(off.partition_cols), 0)
    assert_equal(len(off.partition_values), 0)

    var mixed = _root("modes_mixed")
    _ = _write(mixed + "/a=1", "f.parquet", 2, 0)
    _ = _write(mixed + "/b=2", "f.parquet", 2, 0)
    var auto_mixed = resolve_parquet_source(
        ParquetFooters(), mixed + "/**/*.parquet", HIVE_PARTITIONING_AUTO, False
    )
    assert_equal(len(auto_mixed.paths), 2)
    assert_equal(len(auto_mixed.partition_cols), 0)
    var text = _refusal(mixed + "/**/*.parquet", HIVE_PARTITIONING_ON)
    assert_equal(
        text,
        HIVE_PARTITION_LAYOUT_MISMATCH + ": '" + mixed
        + "/b=2/f.parquet' has partition keys that differ from those of '"
        + mixed + "/a=1/f.parquet'",
    )

    var plain_first = _root("modes_plain_first")
    _ = _write(plain_first + "/g", "f.parquet", 2, 0)
    _ = _write(plain_first + "/z=1", "f.parquet", 2, 0)
    var none = resolve_parquet_source(
        ParquetFooters(),
        plain_first + "/**/*.parquet",
        HIVE_PARTITIONING_ON,
        False,
    )
    assert_equal(len(none.paths), 2)
    assert_equal(len(none.partition_cols), 0)


def test_a_partition_key_that_is_a_data_column_is_refused() raises:
    var root = _root("in_file")
    _ = _write(root + "/X=1", "f.parquet", 2, 0)
    var text = _refusal(root + "/**/*.parquet")
    assert_equal(
        text,
        HIVE_PARTITION_COLUMN_IN_FILE + ": the partition key 'X' of '" + root
        + "/X=1/f.parquet' is also the column 'x' of the files",
    )


def test_only_directories_make_partitions() raises:
    var root = _root("only_dirs")
    var path = _write(root + "/a=1", "f=2.parquet", 2, 0)
    var src = resolve_parquet_source(
        ParquetFooters(), path, HIVE_PARTITIONING_AUTO, False
    )
    assert_equal(len(src.paths), 1)
    assert_equal(len(src.partition_cols), 1)
    assert_equal(src.partition_cols[0].name, "a")
    assert_equal(src.partition_values[0][0], "1")
    var two_equals = _root("only_dirs_two")
    var plain = _write(two_equals + "/a=1=2/b==", "f.parquet", 2, 0)
    var plain_src = resolve_parquet_source(
        ParquetFooters(), plain, HIVE_PARTITIONING_AUTO, False
    )
    assert_equal(len(plain_src.partition_cols), 0)
    assert_equal(len(plain_src.partition_values), 0)
    var odd = _root("only_dirs_first")
    var first = _write(odd + "/=1", "f.parquet", 2, 0)
    var first_src = resolve_parquet_source(
        ParquetFooters(), first, HIVE_PARTITIONING_AUTO, False
    )
    assert_equal(len(first_src.partition_cols), 0)


def test_register_a_directory_and_a_hive_tree() raises:
    var dir = _root("register")
    _ = _write(dir, "a.parquet", 4, 0)
    _ = _write(dir + "/sub", "b.parquet", 5, 100)
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", dir, footers)
    var table = catalog.table_of("t")
    assert_equal(len(table.source._parquet.value().paths), 2)
    assert_equal(catalog.schema_of("t").num_columns(), 4)
    check_catalog_table(catalog, "t", footers)
    var inputs = LoweringInputs()
    add_catalog_scan(inputs, catalog, "t", footers)
    assert_equal(inputs.scans[0].stats.value().row_count, 9)

    var tree = _root("register_hive")
    _ = _write(tree + "/p=a", "f.parquet", 2, 0)
    _ = _write(tree + "/p=b", "f.parquet", 3, 10)
    register_parquet_table(catalog, "h", tree, footers)
    var schema = catalog.schema_of("h")
    assert_equal(schema.num_columns(), 5)
    assert_equal(schema.field_name(4), "p")
    assert_true(schema.field_arrow_type(4) == ArrowType.STRING)
    check_catalog_table(catalog, "h", footers)
    var hive_inputs = LoweringInputs()
    add_catalog_scan(hive_inputs, catalog, "h", footers)
    ref hive_stats = hive_inputs.scans[0].stats.value()
    assert_equal(hive_stats.row_count, 5)
    assert_equal(hive_stats.find_column("p"), -1)

    var missing = SqlCatalog()
    with assert_raises(contains=PARQUET_GLOB_NO_MATCH):
        register_parquet_table(missing, "n", dir + "/*.nothing", footers)
    assert_false(missing.has("n"))


def test_a_disagreeing_second_file_is_refused_by_name() raises:
    var dir = _root("second_file")
    _ = _write(dir, "a.parquet", 4, 0)
    var second = _write(dir, "b.parquet", 4, 10)
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", dir + "/*.parquet", footers)
    check_catalog_table(catalog, "t", footers)
    # Rewritten after registration with another schema (and size).
    _ = _write(dir, "b.parquet", 7, 10, _RENAMED)
    var inputs = LoweringInputs()
    with assert_raises(contains="replaced after its footer was read"):
        add_catalog_scan(inputs, catalog, "t", footers)
    assert_equal(len(inputs.scans), 0)
    with assert_raises(contains=second):
        check_catalog_table(catalog, "t", footers)
    # A reader that has not seen the old file names the schema difference.
    var fresh = ParquetFooters()
    with assert_raises(
        contains="the registered schema does not match '" + second
        + "': column 1 is registered as 'y', the file has 'z'"
    ):
        check_catalog_table(catalog, "t", fresh)
    with assert_raises(contains=second):
        add_catalog_scan(inputs, catalog, "t", fresh)
    assert_equal(len(inputs.scans), 0)


def test_a_scan_of_some_files_of_a_table_checks_and_folds_only_those() raises:
    var dir = _root("subset_scan")
    var a = _write(dir, "a.parquet", 4, 0)
    var b = _write(dir, "b.parquet", 6, 10)
    var footers = ParquetFooters()
    var catalog = SqlCatalog()
    register_parquet_table(catalog, "t", dir + "/*.parquet", footers)
    var only_a = footers.parquet_relation(a, HIVE_PARTITIONING_AUTO)
    var only_b = footers.parquet_relation(b, HIVE_PARTITIONING_AUTO)
    _ = _write(dir, "b.parquet", 7, 10, _RENAMED)
    var inputs = LoweringInputs()
    add_catalog_table_scan(inputs, catalog, "t", footers, only_a)
    assert_equal(len(inputs.scans), 1)
    assert_equal(inputs.scans[0].stats.value().row_count, 4)
    with assert_raises(contains="replaced after its footer was read"):
        add_catalog_table_scan(inputs, catalog, "t", footers, only_b)
    assert_equal(len(inputs.scans), 1)
    with assert_raises(contains="unknown table 'missing'"):
        add_catalog_table_scan(inputs, SqlCatalog(), "missing", footers, only_a)


def test_facts_fold_over_every_file() raises:
    var dir = _root("facts")
    _ = _write(dir, "a.parquet", 10, 0)
    _ = _write(dir, "b.parquet", 5, 100)
    var c = _write(dir, "c.parquet", 3, -50)
    var footers = ParquetFooters()
    var src = footers.parquet_relation(dir + "/*.parquet", HIVE_PARTITIONING_AUTO)
    var inputs = LoweringInputs()
    add_parquet_files_scan(inputs, footers, src)
    assert_equal(len(inputs.scans), 1)
    ref stats = inputs.scans[0].stats.value()
    assert_equal(stats.row_count, 18)
    var x = stats.find_column("x")
    assert_true(stats.column_stats[x].min_value.value() == ScalarValue.from_int64(-50))
    assert_true(stats.column_stats[x].max_value.value() == ScalarValue.from_int64(104))
    assert_equal(stats.column_stats[x].null_count.value(), 0)
    var y = stats.find_column("y")
    assert_equal(stats.column_stats[y].null_count.value(), 4)
    var f = stats.find_column("f")
    assert_true(stats.column_stats[f].min_value.value() == ScalarValue.from_float(-50.0))
    assert_true(stats.column_stats[f].max_value.value() == ScalarValue.from_float(102.0))
    var s = stats.find_column("s")
    assert_false(Bool(stats.column_stats[s].min_value))
    assert_false(Bool(stats.column_stats[s].max_value))

    # One file gives the facts add_parquet_scan gives.
    var one = footers.parquet_relation(c, HIVE_PARTITIONING_AUTO)
    var from_source = LoweringInputs()
    add_parquet_files_scan(from_source, footers, one)
    var from_path = LoweringInputs()
    add_parquet_scan(from_path, footers, c, footers.footer_schema(c))
    ref a = from_source.scans[0].stats.value()
    ref b = from_path.scans[0].stats.value()
    assert_equal(a.row_count, b.row_count)
    assert_equal(a.row_count, 3)
    var xa = a.find_column("x")
    assert_true(a.column_stats[xa].min_value.value() == b.column_stats[xa].min_value.value())
    assert_true(a.column_stats[xa].max_value.value() == ScalarValue.from_int64(-48))
    assert_equal(a.column_stats[a.find_column("y")].null_count.value(), 1)

    # A file replaced after its footer was read is refused, naming it.
    _ = _write(dir, "c.parquet", 9, -50)
    var refused = LoweringInputs()
    with assert_raises(contains=c):
        add_parquet_files_scan(refused, footers, src)
    assert_equal(len(refused.scans), 0)


def _one_column(
    rows: Int,
    var nulls: Optional[Int],
    var distinct: Optional[Int],
    var lo: Optional[ScalarValue],
    var hi: Optional[ScalarValue],
) -> TableStats:
    var names = List[String]()
    names.append("c")
    var cols = List[ColumnStats]()
    cols.append(ColumnStats(distinct^, lo^, hi^, nulls^))
    return TableStats(rows, names^, cols^)


def test_folding_unknown_nulls_distinct_counts_and_missing_bounds() raises:
    var total = _one_column(
        4, Optional[Int](1), None, ScalarValue.from_int64(5), ScalarValue.from_int64(9)
    )
    _fold_into(
        total,
        _one_column(
            6, None, Optional[Int](3), ScalarValue.from_int64(2), ScalarValue.from_int64(7)
        ),
    )
    assert_equal(total.row_count, 10)
    assert_false(Bool(total.column_stats[0].null_count))
    assert_equal(total.column_stats[0].distinct_count.value(), 3)
    assert_true(total.column_stats[0].min_value.value() == ScalarValue.from_int64(2))
    assert_true(total.column_stats[0].max_value.value() == ScalarValue.from_int64(9))
    _fold_into(
        total,
        _one_column(
            1, Optional[Int](0), Optional[Int](7), ScalarValue.from_int64(0), ScalarValue.from_int64(1)
        ),
    )
    assert_equal(total.column_stats[0].distinct_count.value(), 7)
    _fold_into(
        total,
        _one_column(
            1, Optional[Int](0), Optional[Int](2), ScalarValue.from_int64(0), ScalarValue.from_int64(1)
        ),
    )
    assert_equal(total.column_stats[0].distinct_count.value(), 7)
    _fold_into(total, _one_column(1, Optional[Int](0), None, None, None))
    assert_false(Bool(total.column_stats[0].min_value))
    assert_false(Bool(total.column_stats[0].max_value))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
