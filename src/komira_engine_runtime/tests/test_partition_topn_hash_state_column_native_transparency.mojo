# =============================================================================
# test_partition_topn_hash_state_column_native_transparency.mojo
#
# P-2.B.2a transparency gate for the PartitionTopNHashState column-native breaker
# migration (`partition_topn_hash_state.mojo`, the full-row variadic
# partition-topn breaker). The migrated `drain_to_record_batch` produces a
# ColumnNativeBatch internally and bridges to RecordBatch at the breaker output
# via the P-2.A shim. Because the ColumnNativeBatch body IS a THSPLC chunk, the
# lift+lower is byte-identical to a spill/restore round-trip, so the migrated
# drain is byte-identical to the prior direct RecordBatch drain.
#
# This breaker drains FULL ROWS [pk0..pkK-1, order_key, payload0..payloadM-1]:
# for every partition, its top-N rows in sorted order. The bridge transparency
# below covers its representative output shape (part keys + order key + payloads)
# plus a STRING payload (var-width region).
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field

from komira_arrow_ipc.record_batch_compare import record_batch_byte_equal

from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


def test_bridge_byte_identical_pthash_fullrow() raises:
    """Full-row partition-topn output [pk Int64, order_key Int64, payload Int64]
    across multiple partitions round-trips byte-identical through the bridge."""

    def build() raises -> RecordBatch:
        var s = SchemaBuilder()
        s.add_field(Field(String("pk0"), ArrowType.INT64, True))
        s.add_field(Field(String("order_key"), ArrowType.INT64, True))
        s.add_field(Field(String("p0"), ArrowType.INT64, True))
        var schema = s.build()
        var pk: List[Scalar[DType.int64]] = [1, 1, 2, 2]
        var ok: List[Scalar[DType.int64]] = [30, 20, 50, 40]
        var p0: List[Scalar[DType.int64]] = [3, 2, 5, 4]
        var cpk = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(pk)
        )
        var cok = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ok)
        )
        var cp0 = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(p0)
        )
        return RecordBatch.from_typed_columns_3(schema^, cpk^, cok^, cp0^)

    var golden = build()
    var to_bridge = build()
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_columns() == 3, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "PartitionTopNHash full-row bridge (pk + order + payload) byte-identical",
    )


def test_bridge_byte_identical_pthash_string_payload() raises:
    """Full-row partition-topn output with a STRING payload (var-width) round-trips
    byte-identical — exercises the THSPLC var-width region path the full-row
    breaker carries as a payload column."""

    def build() raises -> RecordBatch:
        var s = SchemaBuilder()
        s.add_field(Field(String("pk0"), ArrowType.INT64, True))
        s.add_field(Field(String("order_key"), ArrowType.INT64, True))
        s.add_field(Field(String("name"), ArrowType.STRING, True))
        var schema = s.build()
        var pk: List[Scalar[DType.int64]] = [1, 1, 2]
        var ok: List[Scalar[DType.int64]] = [30, 20, 50]
        var cpk = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(pk)
        )
        var cok = Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ok)
        )
        var names: List[String] = [
            String("gamma"),
            String(""),
            String("epsilon"),
        ]
        var scol = Column.from_string(StringArray.from_strings(names))
        return RecordBatch.from_typed_columns_3(schema^, cpk^, cok^, scol^)

    var golden = build()
    var to_bridge = build()
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "PartitionTopNHash full-row bridge (string payload) byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
