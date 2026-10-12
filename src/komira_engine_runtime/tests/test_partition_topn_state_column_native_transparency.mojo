# =============================================================================
# test_partition_topn_state_column_native_transparency.mojo
#
# P-2.B.2a transparency gate for the PartitionTopNState column-native breaker
# migration (`partition_topn_state.mojo`). The migrated `drain_to_record_batch`
# produces a ColumnNativeBatch internally and bridges to RecordBatch at the
# breaker output via the P-2.A shim. Because the ColumnNativeBatch body IS a
# THSPLC chunk, the lift+lower is byte-identical to a spill/restore round-trip,
# so the migrated drain is byte-identical to the prior direct RecordBatch drain.
#
# This breaker drains a 3-col (part_key Int64, key Int64, payload Int64) batch:
# for every partition, its top-N rows in sorted order. The bridge transparency
# below proves the lift+lower the migration inserts is byte-identical for that
# output shape, including the multi-partition layout.
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


def _ptopn_3col(
    part: List[Int64], keys: List[Int64], pays: List[Int64]
) raises -> RecordBatch:
    """The 3-col (part_key, key, payload) Int64 shape PartitionTopNState drains."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("part_key"), ArrowType.INT64, True))
    sb.add_field(Field(String("key"), ArrowType.INT64, True))
    sb.add_field(Field(String("payload"), ArrowType.INT64, True))
    var schema = sb.build()
    var pkl: List[Scalar[DType.int64]] = []
    var kl: List[Scalar[DType.int64]] = []
    var pl: List[Scalar[DType.int64]] = []
    for i in range(len(part)):
        pkl.append(part[i])
        kl.append(keys[i])
        pl.append(pays[i])
    var part_col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(pkl)
    )
    var kcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(kl)
    )
    var pcol = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(pl)
    )
    return RecordBatch.from_typed_columns_3(schema^, part_col^, kcol^, pcol^)


def test_bridge_byte_identical_ptopn_multi_partition() raises:
    """The 3-col PartitionTopNState drain output across multiple partitions
    round-trips byte-identical through the breaker-output bridge."""
    # Two partitions (1 and 2), top-2 each, in per-partition sorted order.
    var part: List[Int64] = [1, 1, 2, 2]
    var keys: List[Int64] = [30, 20, 50, 40]
    var pays: List[Int64] = [3, 2, 5, 4]
    var golden = _ptopn_3col(part, keys, pays)
    var to_bridge = _ptopn_3col(part, keys, pays)
    var native = column_native_from_record_batch(to_bridge^)
    assert_true(native.num_rows() == 4, "row count preserved")
    assert_true(native.num_columns() == 3, "col count preserved")
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "PartitionTopN drain bridge (3-col i64) must be byte-identical",
    )


def test_bridge_byte_identical_ptopn_single_partition() raises:
    """A single partition with a single retained row round-trips byte-identical."""
    var part: List[Int64] = [7]
    var keys: List[Int64] = [99]
    var pays: List[Int64] = [1]
    var golden = _ptopn_3col(part, keys, pays)
    var to_bridge = _ptopn_3col(part, keys, pays)
    var native = column_native_from_record_batch(to_bridge^)
    var restored = record_batch_from_column_native(native^)
    assert_true(
        record_batch_byte_equal(golden, restored),
        "PartitionTopN drain bridge (single partition row) byte-identical",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
