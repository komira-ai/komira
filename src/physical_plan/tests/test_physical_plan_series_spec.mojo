# =============================================================================
# test_physical_plan_series_spec: the SOURCE_GENERATE_SERIES arm of SourceSpecPod
# =============================================================================
#
#   * test_the_series_arm_carries_the_whole_spec: `SourceSpecPod.generate_series`
#     keeps every field of the spec (column, type, bounds, both steps,
#     inclusive) and leaves every other arm at its default (no Parquet path,
#     no JSONL path, no dependency, no batch handle), so a consumer keyed on
#     another kind reads nothing from it.
#   * test_an_empty_spec_is_a_series_of_no_rows: the default spec's series has
#     no rows.
#   * test_the_kind_is_new_and_the_version_moved: SOURCE_GENERATE_SERIES is a
#     value no other source kind has, and the IR version is 22, the version
#     that added it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_GENERATE_SERIES,
    SOURCE_ICEBERG,
    SOURCE_JSONL,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
    SOURCE_UDF_STEP,
    SourceSpecPod,
)
from scan_source.series_scan import SeriesSpec, series_values


def test_the_series_arm_carries_the_whole_spec() raises:
    var spec = SourceSpecPod.generate_series(
        SeriesSpec("d", True, 10, 20, 0, -3, True)
    )
    ref s = spec.series_spec
    assert_equal(s.column, "d")
    assert_true(s.timestamp)
    assert_equal(s.start, 10)
    assert_equal(s.stop, 20)
    assert_equal(s.step, 0)
    assert_equal(s.step_months, -3)
    assert_true(s.inclusive)
    assert_true(s.arrow_type() == ArrowType.TIMESTAMP_US)
    assert_equal(spec.parquet_path, "")
    assert_false(spec.parquet_spec_is_total)
    assert_equal(spec.jsonl_path, "")
    assert_equal(len(spec.dep_seg_ids), 0)
    assert_equal(spec.batch_handle_id, -1)


def test_an_empty_spec_is_a_series_of_no_rows() raises:
    var spec = SourceSpecPod()
    assert_equal(len(series_values(spec.series_spec, 0, 10)), 0)
    assert_equal(spec.series_spec.row_count().value(), 0)


def test_the_kind_is_new_and_the_version_moved() raises:
    var others: List[UInt8] = [
        SOURCE_PARQUET, SOURCE_BATCH, SOURCE_SINK_OUTPUT, SOURCE_CONCAT,
        SOURCE_CSV, SOURCE_UDF_STEP, SOURCE_ICEBERG, SOURCE_JSONL,
    ]
    for i in range(len(others)):
        assert_true(others[i] != SOURCE_GENERATE_SERIES)
    assert_equal(Int(SOURCE_GENERATE_SERIES), 8)
    assert_equal(PHYSICAL_PLAN_IR_VERSION, 22)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
