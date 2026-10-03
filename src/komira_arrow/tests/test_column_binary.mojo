# =============================================================================
# Tests for Column (type-erased container) and BinaryArray
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray


# =============================================================================
# Column wrapping PrimitiveArray
# =============================================================================


def test_column_from_primitive_int32() raises:
    """Column wrapping a PrimitiveArray[int32] preserves type and length."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive[DType.int32](arr^)
    assert_equal(col.arrow_type, ArrowType.INT32)
    assert_equal(col.length(), 3)
    assert_equal(col.null_count(), 0)


def test_column_from_primitive_float64() raises:
    """Column wrapping a PrimitiveArray[float64] preserves type and length."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.5),
    ]
    var arr = PrimitiveArray[DType.float64].from_list(values)
    var col = Column.from_primitive[DType.float64](arr^)
    assert_equal(col.arrow_type, ArrowType.FLOAT64)
    assert_equal(col.length(), 2)


def test_column_as_primitive_int32_roundtrip() raises:
    """Reconstruct PrimitiveArray[int32] values via as_primitive from a Column."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](100),
        Scalar[DType.int32](200),
        Scalar[DType.int32](300),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive[DType.int32](arr^)
    var restored = col.as_primitive[DType.int32]()
    assert_equal(restored.length, 3)
    assert_equal(restored.get(0), Scalar[DType.int32](100))
    assert_equal(restored.get(1), Scalar[DType.int32](200))
    assert_equal(restored.get(2), Scalar[DType.int32](300))


def test_column_as_primitive_float64_roundtrip() raises:
    """Reconstruct PrimitiveArray[float64] values via as_primitive from a Column."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](3.14),
        Scalar[DType.float64](2.72),
    ]
    var arr = PrimitiveArray[DType.float64].from_list(values)
    var col = Column.from_primitive[DType.float64](arr^)
    var restored = col.as_primitive[DType.float64]()
    assert_equal(restored.length, 2)
    assert_equal(restored.get(0), Scalar[DType.float64](3.14))
    assert_equal(restored.get(1), Scalar[DType.float64](2.72))


def test_column_as_primitive_type_mismatch_raises() raises:
    """Type mismatch in as_primitive raises an error."""
    var values: List[Scalar[DType.int32]] = [Scalar[DType.int32](1)]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive[DType.int32](arr^)
    var raised = False
    try:
        _ = col.as_primitive[DType.float64]()
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# Column wrapping StringArray
# =============================================================================


def test_column_from_string() raises:
    """Column wrapping a StringArray preserves type and length."""
    var values: List[String] = ["hello", "world"]
    var arr = StringArray.from_strings(values)
    var col = Column.from_string(arr^)
    assert_equal(col.arrow_type, ArrowType.STRING)
    assert_equal(col.length(), 2)


def test_column_as_string_roundtrip() raises:
    """Reconstruct StringArray values via as_string from a Column."""
    var values: List[String] = ["alpha", "beta", "gamma"]
    var arr = StringArray.from_strings(values)
    var col = Column.from_string(arr^)
    var restored = col.as_string()
    assert_equal(restored.length, 3)
    assert_equal(restored.get(0), "alpha")
    assert_equal(restored.get(1), "beta")
    assert_equal(restored.get(2), "gamma")


# =============================================================================
# Column wrapping BooleanArray
# =============================================================================


def test_column_from_boolean() raises:
    """Column wrapping a BooleanArray preserves type and length."""
    var arr = BooleanArray.allocate(5)
    arr.set(0, True)
    arr.set(2, True)
    arr.set(4, True)
    var col = Column.from_boolean(arr^)
    assert_equal(col.arrow_type, ArrowType.BOOL)
    assert_equal(col.length(), 5)


def test_column_as_boolean_roundtrip() raises:
    """Reconstruct BooleanArray values via as_boolean from a Column."""
    var arr = BooleanArray.allocate(4)
    arr.set(0, True)
    arr.set(1, False)
    arr.set(2, True)
    arr.set(3, False)
    var col = Column.from_boolean(arr^)
    var restored = col.as_boolean()
    assert_equal(restored.length, 4)
    assert_true(restored.get(0))
    assert_false(restored.get(1))
    assert_true(restored.get(2))
    assert_false(restored.get(3))


# =============================================================================
# RecordBatch with mixed column types
# =============================================================================


def test_recordbatch_mixed_types() raises:
    """RecordBatch with int32 + float64 + string columns via from_typed_columns_3."""
    # Build schema
    var builder = SchemaBuilder()
    builder.add_field(Field("id", ArrowType.INT32, nullable=False))
    builder.add_field(Field("score", ArrowType.FLOAT64, nullable=False))
    builder.add_field(Field("name", ArrowType.STRING, nullable=False))
    var schema = builder.build()

    # Build columns
    var int_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
    ]
    var float_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](9.5),
        Scalar[DType.float64](8.5),
    ]
    var str_vals: List[String] = ["alice", "bob"]

    var batch = RecordBatch.from_typed_columns_3(
        schema^,
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(int_vals)
        ),
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(float_vals)
        ),
        Column.from_string(StringArray.from_strings(str_vals)),
    )

    assert_equal(batch.num_columns(), 3)
    assert_equal(batch.num_rows(), 2)

    # Verify types via column_arrow_type
    assert_equal(batch.column_arrow_type(0), ArrowType.INT32)
    assert_equal(batch.column_arrow_type(1), ArrowType.FLOAT64)
    assert_equal(batch.column_arrow_type(2), ArrowType.STRING)

    # Access typed data through Column
    var col0_ptr = batch._column_ref(0)
    var int_arr = col0_ptr[].as_primitive[DType.int32]()
    assert_equal(int_arr.get(0), Scalar[DType.int32](1))
    assert_equal(int_arr.get(1), Scalar[DType.int32](2))

    var col1_ptr = batch._column_ref(1)
    var float_arr = col1_ptr[].as_primitive[DType.float64]()
    assert_equal(float_arr.get(0), Scalar[DType.float64](9.5))

    var col2_ptr = batch._column_ref(2)
    var str_arr = col2_ptr[].as_string()
    assert_equal(str_arr.get(0), "alice")
    assert_equal(str_arr.get(1), "bob")


def test_recordbatch_column_lookup_by_name_mixed() raises:
    """Column lookup by name works with mixed-type RecordBatch."""
    var builder = SchemaBuilder()
    builder.add_field(Field("x", ArrowType.INT64, nullable=False))
    builder.add_field(Field("label", ArrowType.STRING, nullable=False))
    var schema = builder.build()

    var int_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](42),
        Scalar[DType.int64](99),
    ]
    var str_vals: List[String] = ["foo", "bar"]

    var batch = RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(int_vals)
        ),
        Column.from_string(StringArray.from_strings(str_vals)),
    )

    assert_equal(batch.column_by_name("x"), 0)
    assert_equal(batch.column_by_name("label"), 1)

    # Verify the string column data via the looked-up index
    var label_idx = batch.column_by_name("label")
    var label_col = batch._column_ref(label_idx)
    var label_arr = label_col[].as_string()
    assert_equal(label_arr.get(0), "foo")
    assert_equal(label_arr.get(1), "bar")


def test_recordbatch_backward_compat_from_columns_1() raises:
    """Backward-compatible from_columns_1 still works with Column-based RecordBatch."""
    var values: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](100),
        Scalar[DType.int64](200),
    ]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(Field("x", DType.int64, nullable=False)),
        PrimitiveArray[DType.int64].from_list(values),
    )
    assert_equal(batch.num_rows(), 2)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.column_value(0, 0), Scalar[DType.int64](100))
    assert_equal(batch.column_value(0, 1), Scalar[DType.int64](200))


def test_recordbatch_backward_compat_column_by_name() raises:
    """Backward-compatible column_by_name works with Column-based RecordBatch."""
    var vals: List[Scalar[DType.int64]] = [Scalar[DType.int64](1)]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(Field("id", DType.int64, nullable=False)),
        PrimitiveArray[DType.int64].from_list(vals),
    )
    assert_equal(batch.column_by_name("id"), 0)


# =============================================================================
# BinaryArray
# =============================================================================


def test_binary_array_creation() raises:
    """BinaryArray from_bytes_list creates array with correct length."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0x01))
    b0.append(UInt8(0x02))
    b0.append(UInt8(0x03))
    var b1 = List[UInt8]()
    b1.append(UInt8(0xFF))
    b1.append(UInt8(0xFE))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    var arr = BinaryArray.from_bytes_list(values)
    assert_equal(len(arr), 2)
    assert_equal(arr.data_length, 5)
    assert_equal(arr.null_count, 0)


def test_binary_array_get() raises:
    """BinaryArray.get returns correct bytes."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0xAA))
    b0.append(UInt8(0xBB))
    var b1 = List[UInt8]()
    b1.append(UInt8(0xCC))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    var arr = BinaryArray.from_bytes_list(values)
    var result0 = arr.get(0)
    assert_equal(len(result0), 2)
    assert_equal(result0[0], UInt8(0xAA))
    assert_equal(result0[1], UInt8(0xBB))
    var result1 = arr.get(1)
    assert_equal(len(result1), 1)
    assert_equal(result1[0], UInt8(0xCC))


def test_binary_array_get_length() raises:
    """BinaryArray.get_length returns byte length of each element."""
    var b0 = List[UInt8]()
    b0.append(UInt8(1))
    b0.append(UInt8(2))
    b0.append(UInt8(3))
    b0.append(UInt8(4))
    var b1 = List[UInt8]()
    var b2 = List[UInt8]()
    b2.append(UInt8(5))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    values.append(b2^)
    var arr = BinaryArray.from_bytes_list(values)
    assert_equal(arr.get_length(0), 4)
    assert_equal(arr.get_length(1), 0)  # empty element
    assert_equal(arr.get_length(2), 1)


def test_binary_array_get_byte() raises:
    """BinaryArray.get_byte returns individual bytes."""
    var b0 = List[UInt8]()
    b0.append(UInt8(10))
    b0.append(UInt8(20))
    b0.append(UInt8(30))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = BinaryArray.from_bytes_list(values)
    assert_equal(arr.get_byte(0, 0), UInt8(10))
    assert_equal(arr.get_byte(0, 1), UInt8(20))
    assert_equal(arr.get_byte(0, 2), UInt8(30))


def test_binary_array_empty() raises:
    """Empty BinaryArray is valid."""
    var values = List[List[UInt8]]()
    var arr = BinaryArray.from_bytes_list(values)
    assert_equal(len(arr), 0)
    assert_equal(arr.data_length, 0)


def test_binary_array_out_of_bounds() raises:
    """BinaryArray.get raises on out-of-bounds index."""
    var b0 = List[UInt8]()
    b0.append(UInt8(1))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = BinaryArray.from_bytes_list(values)
    var raised = False
    try:
        _ = arr.get(5)
    except:
        raised = True
    assert_true(raised)


def test_binary_array_is_null_no_bitmap() raises:
    """BinaryArray.is_null returns False when no validity bitmap."""
    var b0 = List[UInt8]()
    b0.append(UInt8(1))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = BinaryArray.from_bytes_list(values)
    assert_false(arr.is_null(0))


# =============================================================================
# Column wrapping BinaryArray
# =============================================================================


def test_column_from_binary() raises:
    """Column wrapping a BinaryArray preserves type and length."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0x01))
    b0.append(UInt8(0x02))
    var values = List[List[UInt8]]()
    values.append(b0^)
    var arr = BinaryArray.from_bytes_list(values)
    var col = Column.from_binary(arr^)
    assert_equal(col.arrow_type, ArrowType.BINARY)
    assert_equal(col.length(), 1)


def test_column_as_binary_roundtrip() raises:
    """Reconstruct BinaryArray values via as_binary from a Column."""
    var b0 = List[UInt8]()
    b0.append(UInt8(0xDE))
    b0.append(UInt8(0xAD))
    var b1 = List[UInt8]()
    b1.append(UInt8(0xBE))
    b1.append(UInt8(0xEF))
    var values = List[List[UInt8]]()
    values.append(b0^)
    values.append(b1^)
    var arr = BinaryArray.from_bytes_list(values)
    var col = Column.from_binary(arr^)
    var restored = col.as_binary()
    assert_equal(restored.length, 2)
    var r0 = restored.get(0)
    assert_equal(len(r0), 2)
    assert_equal(r0[0], UInt8(0xDE))
    assert_equal(r0[1], UInt8(0xAD))
    var r1 = restored.get(1)
    assert_equal(r1[0], UInt8(0xBE))
    assert_equal(r1[1], UInt8(0xEF))


# =============================================================================
# Nullable Column roundtrip tests
# =============================================================================


def test_column_nullable_primitive_roundtrip() raises:
    """Nullable PrimitiveArray survives Column round-trip with nulls preserved."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(4)
    arr.set(0, Scalar[DType.int32](10))
    arr.set(1, Scalar[DType.int32](20))
    arr.set(2, Scalar[DType.int32](30))
    arr.set(3, Scalar[DType.int32](40))
    # Mark index 1 as null
    arr._set_null(1)
    arr.null_count = 1
    var col = Column.from_primitive[DType.int32](arr^)
    assert_equal(col.null_count(), 1)
    assert_equal(col.length(), 4)
    # Reconstruct and check the values and null status
    var restored = col.as_primitive[DType.int32]()
    assert_equal(restored.length, 4)
    assert_equal(restored.null_count, 1)
    assert_false(restored.is_null(0))
    assert_true(restored.is_null(1))
    assert_false(restored.is_null(2))
    assert_false(restored.is_null(3))
    assert_equal(restored.get(0), Scalar[DType.int32](10))
    assert_equal(restored.get(2), Scalar[DType.int32](30))
    assert_equal(restored.get(3), Scalar[DType.int32](40))


def test_column_nullable_boolean_roundtrip() raises:
    """Nullable BooleanArray survives Column round-trip with nulls preserved."""
    var arr = BooleanArray.allocate(3)
    arr.set(0, True)
    arr.set(1, False)
    arr.set(2, True)
    var col = Column.from_boolean(arr^)
    var restored = col.as_boolean()
    assert_equal(restored.length, 3)
    assert_true(restored.get(0))
    assert_false(restored.get(1))
    assert_true(restored.get(2))


# =============================================================================
# Error path tests for Column type mismatch
# =============================================================================


def test_column_as_string_on_int32_raises() raises:
    """as_string on an INT32 column raises type mismatch error."""
    var values: List[Scalar[DType.int32]] = [Scalar[DType.int32](1)]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive[DType.int32](arr^)
    var raised = False
    try:
        _ = col.as_string()
    except:
        raised = True
    assert_true(raised)


def test_column_as_boolean_on_string_raises() raises:
    """as_boolean on a STRING column raises type mismatch error."""
    var str_vals: List[String] = ["hello"]
    var arr = StringArray.from_strings(str_vals)
    var col = Column.from_string(arr^)
    var raised = False
    try:
        _ = col.as_boolean()
    except:
        raised = True
    assert_true(raised)


def test_column_as_binary_on_int64_raises() raises:
    """as_binary on an INT64 column raises type mismatch error."""
    var values: List[Scalar[DType.int64]] = [Scalar[DType.int64](99)]
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr^)
    var raised = False
    try:
        _ = col.as_binary()
    except:
        raised = True
    assert_true(raised)


def test_column_as_primitive_on_bool_raises() raises:
    """as_primitive[int32] on a BOOL column raises type mismatch error."""
    var arr = BooleanArray.allocate(2)
    arr.set(0, True)
    var col = Column.from_boolean(arr^)
    var raised = False
    try:
        _ = col.as_primitive[DType.int32]()
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
