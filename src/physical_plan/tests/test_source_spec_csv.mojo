# =============================================================================
# test_source_spec_csv: the SOURCE_CSV arm of SourceSpecPod
# =============================================================================
#
# `SourceSpecPod.csv` records the file, the dialect and the bound columns it is
# given, and touches no field of another arm; an empty spec holds the CSV
# defaults (a comma, a header row, RFC 4180, no line skipped, no column), so a spec that never
# set them reads a comma-separated file with a header. SOURCE_CSV is the next
# free source tag and does not reuse another kind's.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.csv_source_spec import CsvSourceSpec
from physical_plan.physical_plan import (
    SourceSpecPod,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
)


def test_the_csv_arm_records_its_file_dialect_and_columns() raises:
    var names = List[String]()
    names.append("id")
    names.append("name")
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var s = SourceSpecPod.csv(CsvSourceSpec(
        String("t.csv.gz"), UInt8(ord("|")), False, 2, names^, types^
    ))
    assert_equal(s.csv_spec.path, "t.csv.gz")
    assert_equal(Int(s.csv_spec.delimiter), ord("|"))
    assert_false(s.csv_spec.has_header)
    assert_equal(s.csv_spec.quote_style_tag, 2)
    assert_equal(len(s.csv_spec.column_names), 2)
    assert_equal(s.csv_spec.column_names[1], "name")
    assert_true(s.csv_spec.column_types[0] == ArrowType.INT64)
    assert_true(s.csv_spec.column_types[1] == ArrowType.STRING)
    # No other arm's field is set.
    assert_equal(s.parquet_path, "")
    assert_false(s.parquet_spec_is_total)
    assert_equal(len(s.dep_seg_ids), 0)
    assert_equal(s.batch_handle_id, -1)


def test_the_csv_arm_records_the_lines_it_skips() raises:
    var names = List[String]()
    names.append("id")
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    var s = SourceSpecPod.csv(CsvSourceSpec(
        String("t.csv"), UInt8(ord(",")), True, 0, names^, types^, 3
    ))
    assert_equal(s.csv_spec.skip, 3)
    var plain = List[String]()
    plain.append("id")
    var plain_types = List[ArrowType]()
    plain_types.append(ArrowType.INT64)
    var d = SourceSpecPod.csv(CsvSourceSpec(
        String("t.csv"), UInt8(ord(",")), True, 0, plain^, plain_types^
    ))
    assert_equal(d.csv_spec.skip, 0)


def test_an_empty_spec_holds_the_csv_defaults() raises:
    var s = SourceSpecPod()
    assert_equal(s.csv_spec.path, "")
    assert_equal(Int(s.csv_spec.delimiter), ord(","))
    assert_true(s.csv_spec.has_header)
    assert_equal(s.csv_spec.quote_style_tag, 0)
    assert_equal(s.csv_spec.skip, 0)
    assert_equal(len(s.csv_spec.column_names), 0)
    assert_equal(len(s.csv_spec.column_types), 0)
    # Another arm's constructor leaves them at the defaults too.
    var b = SourceSpecPod.batch(3)
    assert_equal(b.csv_spec.path, "")
    assert_equal(len(b.csv_spec.column_names), 0)


def test_source_csv_is_a_tag_of_its_own() raises:
    assert_equal(Int(SOURCE_CSV), 4)
    var others = List[UInt8]()
    others.append(SOURCE_PARQUET)
    others.append(SOURCE_BATCH)
    others.append(SOURCE_SINK_OUTPUT)
    others.append(SOURCE_CONCAT)
    for i in range(len(others)):
        assert_true(others[i] != SOURCE_CSV)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
