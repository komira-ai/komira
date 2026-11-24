# =============================================================================
# test_source_spec_iceberg: the SOURCE_ICEBERG arm of SourceSpecPod
# =============================================================================
#
# `SourceSpecPod.iceberg` records the planned files, delete files and bound
# columns it is given, and touches no field of another arm; an empty spec holds
# no file and no column, so a spec that never set them reads nothing.
# SOURCE_ICEBERG is the next free source tag and does not reuse another
# kind's. `ParquetSourceData` and `ParquetRowWindow`, which moved to
# `parquet_source_data`, still import from `physical_plan.physical_plan`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.iceberg_scan_spec import (
    IcebergDataFileSpec,
    IcebergDeleteSpec,
    IcebergScanSpec,
)
from physical_plan.physical_plan import (
    ParquetRowWindow,
    ParquetSourceData,
    SourceSpecPod,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_ICEBERG,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
    SOURCE_UDF_STEP,
)


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _spec() -> IcebergScanSpec:
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var names = List[String]()
    names.append("id")
    names.append("name")
    var ids = List[Int]()
    ids.append(1)
    ids.append(4)
    var pos = List[Int]()
    pos.append(0)
    var eq = List[Int]()
    eq.append(1)
    var files = List[IcebergDataFileSpec]()
    files.append(
        IcebergDataFileSpec(
            String("/w/t/data/a.parquet"),
            String("file:///w/t/data/a.parquet"),
            pos^,
            eq^,
        )
    )
    var deletes = List[IcebergDeleteSpec]()
    deletes.append(
        IcebergDeleteSpec(
            String("/w/t/data/p.parquet"), 1, String("PARQUET"), List[String]()
        )
    )
    deletes.append(
        IcebergDeleteSpec(
            String("/w/t/data/e.avro"), 2, String("AVRO"), _one("id")
        )
    )
    return IcebergScanSpec(names^, types^, ids^, files^, deletes^)


def test_the_iceberg_arm_records_its_files_deletes_and_columns() raises:
    var s = SourceSpecPod.iceberg(_spec())
    ref spec = s.iceberg_spec
    assert_equal(len(spec.column_names), 2)
    assert_equal(spec.column_names[1], "name")
    assert_true(spec.column_types[0] == ArrowType.INT64)
    assert_true(spec.column_types[1] == ArrowType.STRING)
    assert_equal(spec.column_field_ids[1], 4)
    assert_equal(len(spec.data_files), 1)
    assert_equal(spec.data_files[0].path, "/w/t/data/a.parquet")
    assert_equal(spec.data_files[0].stored_path, "file:///w/t/data/a.parquet")
    assert_equal(spec.data_files[0].position_deletes[0], 0)
    assert_equal(spec.data_files[0].equality_deletes[0], 1)
    assert_equal(len(spec.deletes), 2)
    assert_equal(spec.deletes[0].path, "/w/t/data/p.parquet")
    assert_equal(spec.deletes[0].content, 1)
    assert_equal(spec.deletes[0].file_format, "PARQUET")
    assert_equal(len(spec.deletes[0].equality_columns), 0)
    assert_equal(spec.deletes[1].content, 2)
    assert_equal(spec.deletes[1].file_format, "AVRO")
    assert_equal(spec.deletes[1].equality_columns[0], "id")
    # No other arm's field is set.
    assert_equal(s.parquet_path, "")
    assert_false(s.parquet_spec_is_total)
    assert_equal(len(s.dep_seg_ids), 0)
    assert_equal(s.batch_handle_id, -1)
    assert_equal(s.csv_spec.path, "")
    assert_false(Bool(s.udf_step))


def test_an_empty_spec_reads_no_file_and_binds_no_column() raises:
    var s = SourceSpecPod()
    assert_equal(len(s.iceberg_spec.column_names), 0)
    assert_equal(len(s.iceberg_spec.column_types), 0)
    assert_equal(len(s.iceberg_spec.column_field_ids), 0)
    assert_equal(len(s.iceberg_spec.data_files), 0)
    assert_equal(len(s.iceberg_spec.deletes), 0)
    # Another arm's constructor leaves them empty too.
    var b = SourceSpecPod.batch(3)
    assert_equal(len(b.iceberg_spec.data_files), 0)
    var d = IcebergDeleteSpec()
    assert_equal(d.path, "")
    assert_equal(d.content, 0)
    assert_equal(d.file_format, "")
    assert_equal(len(d.equality_columns), 0)
    var f = IcebergDataFileSpec()
    assert_equal(f.path, "")
    assert_equal(f.stored_path, "")
    assert_equal(len(f.position_deletes), 0)
    assert_equal(len(f.equality_deletes), 0)


def test_a_copy_of_a_spec_is_independent_of_the_original() raises:
    var spec = _spec()
    var copied = spec.copy()
    spec.data_files[0].path = String("/w/t/data/changed.parquet")
    spec.deletes.clear()
    assert_equal(copied.data_files[0].path, "/w/t/data/a.parquet")
    assert_equal(len(copied.deletes), 2)


def test_source_iceberg_is_a_tag_of_its_own() raises:
    assert_equal(Int(SOURCE_ICEBERG), 6)
    var others = List[UInt8]()
    others.append(SOURCE_PARQUET)
    others.append(SOURCE_BATCH)
    others.append(SOURCE_SINK_OUTPUT)
    others.append(SOURCE_CONCAT)
    others.append(SOURCE_CSV)
    others.append(SOURCE_UDF_STEP)
    for i in range(len(others)):
        assert_true(others[i] != SOURCE_ICEBERG)


def test_the_parquet_source_data_still_imports_from_physical_plan() raises:
    var data = ParquetSourceData(String("t.parquet"), None, None)
    assert_equal(data.file_path, "t.parquet")
    assert_equal(len(data.explicit_paths), 0)
    assert_true(data.preserve_string_dict)
    assert_false(Bool(data.row_window))
    data.row_window = Optional[ParquetRowWindow](ParquetRowWindow(5, 10))
    assert_equal(data.row_window.value().offset, 5)
    assert_equal(data.row_window.value().length, 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
