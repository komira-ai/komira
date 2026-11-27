# parquet_source_bytes: the Parquet files a path names, resolved as
# register_parquet resolves them, as WireParquetSource bytes.
#
# Rows: a glob gives every file it matches in sorted order (written out of
# order) and no partition column with KOMIRA_HIVE_OFF; one file is its own
# path and schema; a directory of `part=` folders gives its files in sorted
# order and, with KOMIRA_HIVE_AUTO and KOMIRA_HIVE_ON, the partition column
# `part` after the files' columns with each file's value, and none with
# KOMIRA_HIVE_OFF; folders whose keys differ give no partition column with
# KOMIRA_HIVE_AUTO and are refused with KOMIRA_HIVE_ON
# (HIVE_PARTITION_LAYOUT_MISMATCH); a glob that matches nothing is refused
# word for word, naming the pattern; files of two schemas are refused
# (PARQUET_FILES_SCHEMA_MISMATCH); a mode that is no KOMIRA_HIVE_* value is
# refused word for word before anything is read.
from std.os import makedirs
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from parquet_footers.parquet_files import (
    HIVE_PARTITION_LAYOUT_MISMATCH,
    PARQUET_FILES_SCHEMA_MISMATCH,
    PARQUET_GLOB_NO_MATCH,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_proto.plan import WireParquetSource
from proto_codec import decode_proto

from runtime_paths import test_tmpdir

from so import (
    HIVE_PARTITIONING_UNKNOWN,
    KOMIRA_HIVE_AUTO,
    KOMIRA_HIVE_OFF,
    KOMIRA_HIVE_ON,
    Session,
    parquet_source_bytes,
)


def _int_file(path: String, column: String) raises -> String:
    """A Parquet file at `path` of one INT64 column `column` holding 1, 2, 3."""
    var arr = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        arr.set(i, Scalar[DType.int64](i + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field(column, ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var bytes = write_record_batch_to_parquet_bytes(rbb.build(sb.build()))
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/" + name
    makedirs(d, exist_ok=True)
    return d^


def _source(path: String, mode: Int32) raises -> WireParquetSource:
    var s = Session()
    return decode_proto[WireParquetSource](parquet_source_bytes(s, path, mode))


def _refusal(path: String, mode: Int32) raises -> String:
    var s = Session()
    try:
        _ = parquet_source_bytes(s, path, mode)
    except e:
        return String(e)
    return String("")


def test_a_glob_gives_its_files_sorted() raises:
    var d = _dir("glob_sorted")
    _ = _int_file(d + "/b.parquet", String("k"))
    _ = _int_file(d + "/a.parquet", String("k"))
    _ = _int_file(d + "/c.txt", String("k"))
    var w = _source(d + "/*.parquet", KOMIRA_HIVE_OFF)
    assert_equal(len(w.paths), 2)
    assert_equal(w.paths[0], d + "/a.parquet")
    assert_equal(w.paths[1], d + "/b.parquet")
    assert_equal(len(w.schema.value().fields), 1)
    assert_equal(w.schema.value().fields[0].name, "k")
    assert_equal(len(w.partition_cols), 0)
    assert_equal(len(w.partition_values), 0)
    assert_true(w.fs_is_local)


def test_one_file_is_its_own_path() raises:
    var d = _dir("one_file")
    var f = _int_file(d + "/only.parquet", String("k"))
    var w = _source(f, KOMIRA_HIVE_OFF)
    assert_equal(len(w.paths), 1)
    assert_equal(w.paths[0], f)
    assert_equal(w.schema.value().fields[0].name, "k")
    assert_equal(len(w.partition_cols), 0)


def _partitioned(name: String) raises -> String:
    var d = _dir(name)
    makedirs(d + "/part=2", exist_ok=True)
    makedirs(d + "/part=1", exist_ok=True)
    _ = _int_file(d + "/part=2/x.parquet", String("k"))
    _ = _int_file(d + "/part=1/y.parquet", String("k"))
    return d^


def _assert_keyed(w: WireParquetSource, d: String) raises:
    assert_equal(len(w.paths), 2)
    assert_equal(w.paths[0], d + "/part=1/y.parquet")
    assert_equal(w.paths[1], d + "/part=2/x.parquet")
    assert_equal(len(w.schema.value().fields), 1, "the data schema holds the files' columns")
    assert_equal(len(w.partition_cols), 1)
    assert_equal(w.partition_cols[0].name, "part")
    assert_equal(len(w.partition_values), 2)
    assert_equal(w.partition_values[0].values[0], "1")
    assert_equal(w.partition_values[1].values[0], "2")


def test_a_directory_gives_its_keys_as_columns() raises:
    var d = _partitioned("hive_keys")
    _assert_keyed(_source(d, KOMIRA_HIVE_AUTO), d)
    _assert_keyed(_source(d, KOMIRA_HIVE_ON), d)
    var off = _source(d, KOMIRA_HIVE_OFF)
    assert_equal(len(off.paths), 2)
    assert_equal(len(off.partition_cols), 0)
    assert_equal(len(off.partition_values), 0)


def test_keys_that_differ_between_files() raises:
    var d = _dir("hive_mixed")
    makedirs(d + "/part=1", exist_ok=True)
    makedirs(d + "/other=1", exist_ok=True)
    _ = _int_file(d + "/part=1/x.parquet", String("k"))
    _ = _int_file(d + "/other=1/y.parquet", String("k"))
    var auto = _source(d, KOMIRA_HIVE_AUTO)
    assert_equal(len(auto.paths), 2)
    assert_equal(len(auto.partition_cols), 0)
    var refused = _refusal(d, KOMIRA_HIVE_ON)
    assert_true(refused.startswith(String(HIVE_PARTITION_LAYOUT_MISMATCH) + ": "), refused)


def test_a_glob_matching_nothing_is_refused_by_name() raises:
    var d = _dir("glob_nothing")
    var pattern = d + "/*.parquet"
    assert_equal(
        _refusal(pattern, KOMIRA_HIVE_AUTO),
        String(PARQUET_GLOB_NO_MATCH) + ": no file matches '" + pattern + "'",
    )


def test_files_of_two_schemas_are_refused() raises:
    var d = _dir("two_schemas")
    _ = _int_file(d + "/a.parquet", String("k"))
    _ = _int_file(d + "/b.parquet", String("j"))
    var refused = _refusal(d + "/*.parquet", KOMIRA_HIVE_OFF)
    assert_true(refused.startswith(String(PARQUET_FILES_SCHEMA_MISMATCH) + ": '" + d + "/b.parquet'"), refused)


def test_an_unknown_mode_is_refused_before_reading() raises:
    assert_equal(
        _refusal(String("/no/such/dir/*.parquet"), Int32(3)),
        String(HIVE_PARTITIONING_UNKNOWN)
        + ": hive_partitioning 3 is none of KOMIRA_HIVE_AUTO (0), KOMIRA_HIVE_ON (1) and"
        + " KOMIRA_HIVE_OFF (2)",
    )
    assert_equal(
        _refusal(String("/no/such/dir/*.parquet"), Int32(-1)),
        String(HIVE_PARTITIONING_UNKNOWN)
        + ": hive_partitioning -1 is none of KOMIRA_HIVE_AUTO (0), KOMIRA_HIVE_ON (1) and"
        + " KOMIRA_HIVE_OFF (2)",
    )


def main() raises:
    test_a_glob_gives_its_files_sorted()
    test_one_file_is_its_own_path()
    test_a_directory_gives_its_keys_as_columns()
    test_keys_that_differ_between_files()
    test_a_glob_matching_nothing_is_refused_by_name()
    test_files_of_two_schemas_are_refused()
    test_an_unknown_mode_is_refused_before_reading()
    print("OK")
