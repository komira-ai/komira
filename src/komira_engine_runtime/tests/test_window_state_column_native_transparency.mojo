# =============================================================================
# test_window_state_column_native_transparency.mojo
#
# P-2.B.2b transparency gate for the WindowState column-native breaker
# migration. The migrated `WindowState.drain_to_record_batch` produces a
# ColumnNativeBatch internally and bridges to RecordBatch at the breaker output
# via the P-2.A shim (column_native_from_record_batch ->
# record_batch_from_column_native). Because the ColumnNativeBatch body IS a
# THSPLC chunk, the lift+lower is byte-identical to a spill/restore round-trip,
# so the migrated drain is byte-identical to the prior direct RecordBatch drain.
#
# WindowState drains a fixed 2-col (part_key Int64 @0, row_number Int64 @1)
# RecordBatch over all accumulated rows in input order. The schema fields are
# declared NULLABLE (nullable=True) even though the values are non-null, so the
# bridge must preserve that nullable schema flag through the THSPLC round-trip.
# The bridge transparency below proves the lift+lower the migration inserts is
# byte-identical for that output shape.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field

from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


def _i64_prim(
    var vals: List[Scalar[DType.int64]]
) raises -> PrimitiveArray[DType.int64]:
    return PrimitiveArray[DType.int64].from_list(vals^)


def _window_2col(
    var keys: List[Scalar[DType.int64]], var rns: List[Scalar[DType.int64]]
) raises -> RecordBatch:
    """The 2-col (part_key Int64 @0 NULLABLE, row_number Int64 @1 NULLABLE)
    shape WindowState drains — matches the migrated drain's schema exactly."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("part_key"), ArrowType.INT64, True))
    sb.add_field(Field(String("row_number"), ArrowType.INT64, True))
    var schema = sb.build()
    var kcol = Column.from_primitive[DType.int64](_i64_prim(keys^))
    var rcol = Column.from_primitive[DType.int64](_i64_prim(rns^))
    return RecordBatch.from_typed_columns_2(schema^, kcol^, rcol^)


def test_bridge_byte_identical_window_rownumber() raises:
    """The WindowState (part_key, row_number) RowNumber drain output round-trips
    byte-identical through the breaker-output bridge. Two partitions (key 1 with
    3 rows, key 2 with 2 rows), row_number restarting at 1 per partition (the
    partition-sorted RowNumber output)."""
    var keys: List[Scalar[DType.int64]] = [1, 1, 1, 2, 2]
    var rns: List[Scalar[DType.int64]] = [1, 2, 3, 1, 2]
    var keys2: List[Scalar[DType.int64]] = [1, 1, 1, 2, 2]
    var rns2: List[Scalar[DType.int64]] = [1, 2, 3, 1, 2]
    var golden = _window_2col(keys^, rns^)
    var to_bridge = _window_2col(keys2^, rns2^)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_rows() == 5, "row count preserved")
    assert_true(native.num_columns() == 2, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "WindowState RowNumber drain bridge must be byte-identical",
    )


def test_bridge_byte_identical_window_single_row() raises:
    """A single accumulated row (one partition, one row) round-trips
    byte-identical — the smallest non-empty window drain shape."""
    var keys: List[Scalar[DType.int64]] = [7]
    var rns: List[Scalar[DType.int64]] = [1]
    var keys2: List[Scalar[DType.int64]] = [7]
    var rns2: List[Scalar[DType.int64]] = [1]
    var golden = _window_2col(keys^, rns^)
    var to_bridge = _window_2col(keys2^, rns2^)
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "WindowState drain bridge (single accumulated row) byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
