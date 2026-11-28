# =============================================================================
# test_physical_plan_jsonl_spec: the SOURCE_JSONL arm of SourceSpecPod
# =============================================================================
#
#   * test_the_jsonl_arm_carries_its_path_and_schema: `SourceSpecPod.jsonl`
#     keeps the path and every field of the schema, in order, with its type
#     and nullability, and leaves every other arm at its default (no Parquet
#     path, not total, no dependency, no batch handle), so a consumer keyed on
#     another kind reads nothing from it.
#   * test_an_empty_spec_reads_no_file: the default spec names no JSONL path
#     and holds a schema of no column.
#   * test_the_kind_is_new_and_the_version_moved: SOURCE_JSONL is a value no
#     other source kind has, and the IR version has moved on from 20, the
#     version that added it (the current version is 22).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from physical_plan.physical_plan import (
    PHYSICAL_PLAN_IR_VERSION,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_ICEBERG,
    SOURCE_JSONL,
    SOURCE_PARQUET,
    SOURCE_SINK_OUTPUT,
    SOURCE_UDF_STEP,
    SourceSpecPod,
)


def test_the_jsonl_arm_carries_its_path_and_schema() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var spec = SourceSpecPod.jsonl(String("data/rows.jsonl"), sb.build())
    assert_equal(spec.jsonl_path, "data/rows.jsonl")
    assert_equal(spec.jsonl_schema.num_columns(), 2)
    assert_equal(spec.jsonl_schema.field_name(0), "s")
    assert_equal(spec.jsonl_schema.field_name(1), "id")
    assert_true(spec.jsonl_schema.field_arrow_type(0) == ArrowType.STRING)
    assert_true(spec.jsonl_schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(spec.jsonl_schema.field_nullable(0))
    assert_false(spec.jsonl_schema.field_nullable(1))
    assert_equal(spec.parquet_path, "")
    assert_false(spec.parquet_spec_is_total)
    assert_false(Bool(spec.parquet_projection))
    assert_false(Bool(spec.parquet_filter))
    assert_equal(len(spec.dep_seg_ids), 0)
    assert_equal(spec.batch_handle_id, -1)


def test_an_empty_spec_reads_no_file() raises:
    var spec = SourceSpecPod()
    assert_equal(spec.jsonl_path, "")
    assert_equal(spec.jsonl_schema.num_columns(), 0)


def test_the_kind_is_new_and_the_version_moved() raises:
    var others = List[UInt8]()
    others.append(SOURCE_PARQUET)
    others.append(SOURCE_BATCH)
    others.append(SOURCE_SINK_OUTPUT)
    others.append(SOURCE_CONCAT)
    others.append(SOURCE_CSV)
    others.append(SOURCE_UDF_STEP)
    others.append(SOURCE_ICEBERG)
    for i in range(len(others)):
        assert_true(others[i] != SOURCE_JSONL)
    assert_equal(Int(SOURCE_JSONL), 7)
    assert_equal(PHYSICAL_PLAN_IR_VERSION, 22)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
