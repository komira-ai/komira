# =============================================================================
# test_topn_state_column_native_transparency.mojo
#
# P-2.B.2a transparency gate for the TopNState column-native breaker migration.
# The migrated `TopNState.drain_to_record_batch` produces a ColumnNativeBatch
# internally and bridges to RecordBatch at the breaker output via the P-2.A shim
# (column_native_from_record_batch -> record_batch_from_column_native). Because
# the ColumnNativeBatch body IS a THSPLC chunk, the lift+lower is byte-identical
# to a spill/restore round-trip, so the migrated drain is byte-identical to the
# prior direct RecordBatch drain.
#
# TopNState drains a fixed 2-col (key Int64, payload Int64) batch in sorted
# order. The bridge transparency below proves the lift+lower the migration
# inserts is byte-identical for that output shape.
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


def _topn_key_payload(keys: List[Int64], pays: List[Int64]) raises -> RecordBatch:
    """The 2-col (key Int64 @0, payload Int64 @1) shape TopNState drains."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("key"), ArrowType.INT64, True))
    sb.add_field(Field(String("payload"), ArrowType.INT64, True))
    var schema = sb.build()
    var kl: List[Scalar[DType.int64]] = []
    var pl: List[Scalar[DType.int64]] = []
    for i in range(len(keys)):
        kl.append(keys[i])
        pl.append(pays[i])
    var kcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(kl)
    )
    var pcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(pl)
    )
    return RecordBatch.from_typed_columns_2(schema^, kcol^, pcol^)


def test_bridge_byte_identical_topn_key_payload() raises:
    """The TopNState (key Int64, payload Int64) drain output round-trips
    byte-identical through the breaker-output bridge."""
    var keys: List[Int64] = [30, 25, 20, 10, 5]
    var pays: List[Int64] = [1, 5, 3, 2, 4]
    var golden = _topn_key_payload(keys, pays)
    var to_bridge = _topn_key_payload(keys, pays)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_rows() == 5, "row count preserved")
    assert_true(native.num_columns() == 2, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "TopNState drain bridge (key + payload i64) must be byte-identical",
    )


def test_bridge_byte_identical_topn_single_row() raises:
    """A single retained row (LIMIT 1) round-trips byte-identical — exercises the
    smallest non-empty drain shape."""
    var keys: List[Int64] = [42]
    var pays: List[Int64] = [7]
    var golden = _topn_key_payload(keys, pays)
    var to_bridge = _topn_key_payload(keys, pays)
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "TopNState drain bridge (single retained row) byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
