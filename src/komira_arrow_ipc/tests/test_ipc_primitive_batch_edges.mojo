# =============================================================================
# test_ipc_primitive_batch_edges.mojo: serialize_primitive_batch's refusal of
# a non-primitive column, and deserialize_primitive_batch's header-size check
# and zero-column batch
# =============================================================================
#
# test_map_ipc.mojo round-trips primitive batches. Here: a STRING column
# after an INT64 one is refused naming column 1; a header declaring one
# column needs 22 bytes (12 + 10 per column), so 21 bytes are refused and 22
# (a one-column, zero-row batch with an empty body) are accepted; a header
# declaring zero columns is an empty batch.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import Field, SchemaBuilder, RecordBatchBuilder
from komira_arrow_ipc.ipc import (
    serialize_primitive_batch,
    deserialize_primitive_batch,
)


def test_serialize_refuses_a_string_column() raises:
    var ints = List[Int64]()
    ints.append(1)
    var strs = List[String]()
    strs.append(String("a"))
    var b = RecordBatchBuilder()
    b.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ints)
        )
    )
    b.add_column(Column.from_string(StringArray.from_strings(strs)))
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    var batch = b.build(sb.build())
    var msg = String("")
    try:
        _ = serialize_primitive_batch(batch)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "serialize_primitive_batch: column 1 has non-primitive type"
        ),
        msg,
    )


def _header(size: Int, num_cols: Int) raises -> SharedAlignedBuffer[HeapRegion]:
    """`size` bytes: the magic, `num_cols`, zero rows, and (when there is
    room) a first column descriptor of INT64 with no data and no
    validity."""
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(size)
    buf.zero()
    buf.write_u8_at(0, UInt8(0x54))
    buf.write_u8_at(1, UInt8(0x48))
    buf.write_u8_at(2, UInt8(0x52))
    buf.write_u8_at(3, UInt8(0x4D))
    buf.write_i32_le_at(4, Int32(num_cols))
    buf.write_i32_le_at(8, Int32(0))
    if size >= 13:
        buf.write_u8_at(12, ArrowType.INT64.type_id)
    buf.set_length(size)
    return buf^


def test_deserialize_needs_ten_bytes_per_column_descriptor() raises:
    var msg = String("")
    try:
        _ = deserialize_primitive_batch(_header(21, 1))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "deserialize_primitive_batch: buffer too short for header (21 bytes,"
        " need 22)",
    )
    var batch = deserialize_primitive_batch(_header(22, 1))
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.column_arrow_type(0), ArrowType.INT64)


def test_deserialize_zero_columns_is_an_empty_batch() raises:
    var batch = deserialize_primitive_batch(_header(12, 0))
    assert_equal(batch.num_columns(), 0)
    assert_equal(batch.num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
