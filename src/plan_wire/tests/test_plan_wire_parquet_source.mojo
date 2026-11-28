# =============================================================================
# test_plan_wire_parquet_source.mojo -- `parquet_source_to_bytes` writes the
# whole source a frontend splices into its scan.
# =============================================================================
#
#   test_a_partitioned_source_keeps_its_files_columns_and_values
#       Two files with two partition columns: the bytes decode as a
#       `WireParquetSource` with both paths in order, the data schema alone,
#       both partition columns in order and one value row per file, on the
#       local file system.
#       Catches: a source written with its first file only, partition columns
#       dropped or merged into the data schema, or value rows out of order.
#
#   test_a_single_file_is_one_path_and_no_partition_columns
#       One file: one path, its schema, no partition column or value row.
#
#   test_an_object_store_path_is_refused_by_name
#       An `s3://` path is refused with `PLAN_WIRE_UNSUPPORTED_REMOTE_FS`, as
#       a plan holding it is, and not written as a local file.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_proto.plan import WireParquetSource
from plan_wire import PLAN_WIRE_UNSUPPORTED_REMOTE_FS, parquet_source_to_bytes
from proto_codec import decode_proto
from scan_source.parquet_source import ParquetSource


def _schema() raises -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("id", ArrowType.INT64, False))
    b.add_field(Field("name", ArrowType.STRING, True))
    return b.build()


def _decoded(p: ParquetSource) raises -> WireParquetSource:
    return decode_proto[WireParquetSource](parquet_source_to_bytes(p))


def test_a_partitioned_source_keeps_its_files_columns_and_values() raises:
    var pcols = List[Field]()
    pcols.append(Field("month", ArrowType.STRING, False))
    pcols.append(Field("year", ArrowType.INT64, False))
    var pvals = List[List[String]]()
    pvals.append([String("feb"), String("2026")])
    pvals.append([String("jan"), String("2027")])
    var source = ParquetSource.partitioned(
        [String("/d/year=2026/month=feb/a.parquet"), String("/d/year=2027/month=jan/b.parquet")],
        _schema(),
        pcols^,
        pvals^,
    )
    var w = _decoded(source)
    assert_equal(len(w.paths), 2)
    assert_equal(w.paths[0], "/d/year=2026/month=feb/a.parquet")
    assert_equal(w.paths[1], "/d/year=2027/month=jan/b.parquet")
    assert_true(Bool(w.schema), "the data schema is written")
    var fields = w.schema.value().fields.copy()
    assert_equal(len(fields), 2, "the data schema holds the files' columns only")
    assert_equal(fields[0].name, "id")
    assert_equal(fields[1].name, "name")
    assert_equal(len(w.partition_cols), 2)
    assert_equal(w.partition_cols[0].name, "month")
    assert_equal(w.partition_cols[1].name, "year")
    assert_equal(len(w.partition_values), 2)
    assert_equal(w.partition_values[0].values[0], "feb")
    assert_equal(w.partition_values[0].values[1], "2026")
    assert_equal(w.partition_values[1].values[0], "jan")
    assert_equal(w.partition_values[1].values[1], "2027")
    assert_true(w.fs_is_local)
    assert_false(w.hive_dir_scan)
    assert_false(w.has_hive_predicate)


def test_a_single_file_is_one_path_and_no_partition_columns() raises:
    var w = _decoded(ParquetSource(String("/d/solo.parquet"), _schema()))
    assert_equal(len(w.paths), 1)
    assert_equal(w.paths[0], "/d/solo.parquet")
    assert_equal(len(w.schema.value().fields), 2)
    assert_equal(len(w.partition_cols), 0)
    assert_equal(len(w.partition_values), 0)
    assert_true(w.fs_is_local)


def test_an_object_store_path_is_refused_by_name() raises:
    var message = String()
    try:
        _ = parquet_source_to_bytes(ParquetSource(String("s3://bucket/x.parquet"), _schema()))
    except e:
        message = String(e)
    assert_true(
        message.startswith(PLAN_WIRE_UNSUPPORTED_REMOTE_FS + ": 's3://bucket/x.parquet'"),
        message,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_partitioned_source_keeps_its_files_columns_and_values]()
    suite.test[test_a_single_file_is_one_path_and_no_partition_columns]()
    suite.test[test_an_object_store_path_is_refused_by_name]()
    suite^.run()
