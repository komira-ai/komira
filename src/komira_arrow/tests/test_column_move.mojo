# =============================================================================
# Tests for Column move semantics — verifies data survives move through
# RecordBatchBuilder
# =============================================================================
#
# This test reproduces a critical bug where Column data was being zeroed when
# moved through RecordBatchBuilder.add_column() -> build() -> RecordBatch.
# The root cause is Mojo's auto-synthesized __moveinit__ not correctly
# handling structs with Optional[MmapAlignedBuffer] fields.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder, RecordBatch, RecordBatchBuilder
from komira_arrow.arrow_types import ArrowType


def test_column_move_primitive_int32() raises:
    """Column[HeapRegion] data survives move through RecordBatchBuilder (int32)."""
    # Create a PrimitiveArray with known values.
    var values: List[Scalar[DType.int32]] = [Int32(10), Int32(20), Int32(30), Int32(40), Int32(50)]
    var arr = PrimitiveArray[DType.int32].from_list(values)

    # Wrap in a Column.
    var col = Column.from_primitive[DType.int32](arr)

    # Verify data BEFORE move.
    var pre = col.as_primitive[DType.int32]()
    assert_equal(pre.get(0), Int32(10))
    assert_equal(pre.get(1), Int32(20))
    assert_equal(pre.get(4), Int32(50))

    # Move through RecordBatchBuilder.
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT32, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    # Verify data AFTER move.
    assert_equal(batch.num_rows(), 5)
    assert_equal(batch.num_columns(), 1)
    var recovered = batch.column_as_primitive_int32(0)
    assert_equal(recovered.get(0), Int32(10))
    assert_equal(recovered.get(1), Int32(20))
    assert_equal(recovered.get(2), Int32(30))
    assert_equal(recovered.get(3), Int32(40))
    assert_equal(recovered.get(4), Int32(50))


def test_column_move_primitive_int64() raises:
    """Column[HeapRegion] data survives move through RecordBatchBuilder (int64)."""
    var values: List[Scalar[DType.int64]] = [Int64(100), Int64(200), Int64(300)]
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr)

    var sb = SchemaBuilder()
    sb.add_field(Field("y", ArrowType.INT64, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    var recovered = batch.column_as_primitive_int64(0)
    assert_equal(recovered.get(0), Int64(100))
    assert_equal(recovered.get(1), Int64(200))
    assert_equal(recovered.get(2), Int64(300))


def test_column_move_primitive_float64() raises:
    """Column[HeapRegion] data survives move through RecordBatchBuilder (float64)."""
    var values: List[Scalar[DType.float64]] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    var arr = PrimitiveArray[DType.float64].from_list(values)
    var col = Column.from_primitive[DType.float64](arr)

    var sb = SchemaBuilder()
    sb.add_field(Field("z", ArrowType.FLOAT64, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    var recovered = batch.column_as_primitive_float64(0)
    assert_equal(recovered.get(0), Float64(1.5))
    assert_equal(recovered.get(1), Float64(2.5))
    assert_equal(recovered.get(2), Float64(3.5))


def test_column_move_multiple_columns() raises:
    """Multiple columns survive move through RecordBatchBuilder."""
    var v1: List[Scalar[DType.int32]] = [Int32(1), Int32(2), Int32(3)]
    var v2: List[Scalar[DType.int64]] = [Int64(10), Int64(20), Int64(30)]

    var col1 = Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(v1))
    var col2 = Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(v2))

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col1^)
    builder.add_column(col2^)
    var batch = builder.build(schema^)

    assert_equal(batch.num_columns(), 2)
    assert_equal(batch.num_rows(), 3)

    var r1 = batch.column_as_primitive_int32(0)
    assert_equal(r1.get(0), Int32(1))
    assert_equal(r1.get(1), Int32(2))
    assert_equal(r1.get(2), Int32(3))

    var r2 = batch.column_as_primitive_int64(1)
    assert_equal(r2.get(0), Int64(10))
    assert_equal(r2.get(1), Int64(20))
    assert_equal(r2.get(2), Int64(30))


def test_column_move_string() raises:
    """String column data survives move through RecordBatchBuilder."""
    var offsets: List[Int32] = [Int32(0), Int32(5), Int32(10)]
    var data_str = "HelloWorld"
    var data_buf = data_str.as_bytes()

    # Build a StringArray manually
    var offset_buf = OwnedAlignedBuffer(3 * 4)  # 3 offsets x 4 bytes
    var off_ptr = offset_buf.view_typed_mut[DType.int32]()
    for i in range(3):
        (off_ptr + i)[] = offsets[i]
    offset_buf.set_length(3 * 4)


    var str_data_buf = OwnedAlignedBuffer(10)
    for i in range(10):
        (str_data_buf.view_typed_mut[DType.uint8]() + i)[] = data_buf[i]
    str_data_buf.set_length(10)


    var str_arr = StringArray(
        offsets=offset_buf^,
        data=str_data_buf^,
        validity=None,
        length=2,
        data_length=10,
        null_count=0,
    )

    var col = Column.from_string(str_arr)

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    var recovered = batch.column_as_string(0)
    assert_equal(len(recovered), 2)
    assert_equal(recovered.get(0), "Hello")
    assert_equal(recovered.get(1), "World")


from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


def test_column_direct_move() raises:
    """Test Column[HeapRegion] move without RecordBatchBuilder (isolate the move)."""
    var values: List[Scalar[DType.int32]] = [Int32(42), Int32(99)]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive[DType.int32](arr)

    # Verify before move.
    var pre = col.as_primitive[DType.int32]()
    assert_equal(pre.get(0), Int32(42))
    assert_equal(pre.get(1), Int32(99))

    # Move into heap slot (simulates what RecordBatchBuilder does).
    from std.memory import alloc
    var ptr = alloc[Column[HeapRegion]](1)
    (ptr + 0).unsafe_write(col^)

    # Read back from heap.
    var recovered = (ptr + 0)[].as_primitive[DType.int32]()
    assert_equal(recovered.get(0), Int32(42))
    assert_equal(recovered.get(1), Int32(99))

    # Clean up.
    (ptr + 0).unsafe_deinit_pointee()
    ptr.free()


def test_column_move_with_optional_offsets() raises:
    """Column[HeapRegion] with Optional offsets (string type) survives builder move chain.

    This specifically exercises the Optional[MmapAlignedBuffer] path that was
    suspected of corruption in the auto-synthesized __moveinit__.
    """
    # Build a string column which has _offsets (Optional[MmapAlignedBuffer]).
    var offsets: List[Int32] = [Int32(0), Int32(3), Int32(7), Int32(12)]
    var data_str = "foobarbazqux"
    var data_bytes = data_str.as_bytes()

    var offset_buf = OwnedAlignedBuffer(4 * 4)
    var off_ptr = offset_buf.view_typed_mut[DType.int32]()
    for i in range(4):
        (off_ptr + i)[] = offsets[i]
    offset_buf.set_length(4 * 4)


    var str_data_buf = OwnedAlignedBuffer(12)
    for i in range(12):
        (str_data_buf.view_typed_mut[DType.uint8]() + i)[] = data_bytes[i]
    str_data_buf.set_length(12)


    var str_arr = StringArray(
        offsets=offset_buf^,
        data=str_data_buf^,
        validity=None,
        length=3,
        data_length=12,
        null_count=0,
    )

    var col = Column.from_string(str_arr)

    # Force a double-move: builder internally moves Column into heap slot,
    # then build() transfers the heap slot to RecordBatch.
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    var recovered = batch.column_as_string(0)
    assert_equal(recovered.get(0), "foo")
    assert_equal(recovered.get(1), "barb")
    assert_equal(recovered.get(2), "azqux")


def test_column_move_with_dict_data() raises:
    """Dictionary column (with _dict_data Optional) survives builder move."""
    from komira_arrow.dictionary_array import StringDictionaryArray

    # Build a dictionary array: 3 values with 2 unique strings.
    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(1), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)

    # Dictionary with 2 entries: "cat", "dog"
    var dict_offsets = OwnedAlignedBuffer(3 * 4)
    var dict_off_ptr = dict_offsets.view_typed_mut[DType.int32]()
    (dict_off_ptr + 0)[] = Int32(0)
    (dict_off_ptr + 1)[] = Int32(3)
    (dict_off_ptr + 2)[] = Int32(6)
    dict_offsets.set_length(3 * 4)


    var dict_data = OwnedAlignedBuffer(6)
    # "catdog"
    var catdog = "catdog".as_bytes()
    for i in range(6):
        (dict_data.view_typed_mut[DType.uint8]() + i)[] = catdog[i]
    dict_data.set_length(6)


    var dictionary = StringArray(
        offsets=dict_offsets^,
        data=dict_data^,
        validity=None,
        length=2,
        data_length=6,
        null_count=0,
    )

    var dict_arr = StringDictionaryArray(indices^, dictionary^, 3)
    var col = Column.from_dictionary(dict_arr)

    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DICTIONARY, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    var batch = builder.build(schema^)

    var recovered = batch.column_as_dictionary(0)
    assert_equal(len(recovered), 3)
    assert_equal(recovered.get(0), "cat")
    assert_equal(recovered.get(1), "dog")
    assert_equal(recovered.get(2), "cat")


def test_column_move_grow_capacity() raises:
    """RecordBatchBuilder grows its internal buffer (triggers uninit_move_n).

    When adding more than 8 columns (initial capacity), the builder must
    reallocate and move all existing columns. This tests the move chain
    under reallocation.
    """
    var sb = SchemaBuilder()
    for i in range(12):
        sb.add_field(Field("c" + String(i), ArrowType.INT32, nullable=False))
    var schema = sb.build()

    var builder = RecordBatchBuilder()
    for i in range(12):
        var vals: List[Scalar[DType.int32]] = [Int32(i * 10 + 1), Int32(i * 10 + 2)]
        var arr = PrimitiveArray[DType.int32].from_list(vals)
        var col = Column.from_primitive[DType.int32](arr)
        builder.add_column(col^)

    var batch = builder.build(schema^)
    assert_equal(batch.num_columns(), 12)
    assert_equal(batch.num_rows(), 2)

    # Verify a sample of columns.
    var r0 = batch.column_as_primitive_int32(0)
    assert_equal(r0.get(0), Int32(1))
    assert_equal(r0.get(1), Int32(2))

    var r5 = batch.column_as_primitive_int32(5)
    assert_equal(r5.get(0), Int32(51))
    assert_equal(r5.get(1), Int32(52))

    var r11 = batch.column_as_primitive_int32(11)
    assert_equal(r11.get(0), Int32(111))
    assert_equal(r11.get(1), Int32(112))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
