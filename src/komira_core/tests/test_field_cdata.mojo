# =============================================================================
# Tests for per-field metadata, nested Field children, and C Data Interface
# export stubs
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Field,
    PrimitiveArray,
    CArrowSchema,
    CArrowArray,
    ARROW_FLAG_NULLABLE,
    export_schema,
    export_primitive,
)


# =============================================================================
# Per-field metadata tests
# =============================================================================


def test_field_metadata_set_and_get() raises:
    """set_metadata stores a key-value pair retrievable by get_metadata."""
    var field = Field("id", ArrowType.INT64, nullable=False)
    field.set_metadata("PARQUET:field_id", "42")

    var val = field.get_metadata("PARQUET:field_id")
    assert_true(val is not None)
    assert_equal(val.value(), "42")


def test_field_metadata_has_key() raises:
    """has_metadata returns True for existing keys, False for missing."""
    var field = Field("name", ArrowType.STRING, nullable=True)
    field.set_metadata("ARROW:extension:name", "uuid")

    assert_true(field.has_metadata("ARROW:extension:name"))
    assert_false(field.has_metadata("nonexistent"))


def test_field_metadata_missing_key_returns_none() raises:
    """get_metadata returns None for a key that was never set."""
    var field = Field("col", ArrowType.INT32, nullable=False)

    var result = field.get_metadata("missing_key")
    assert_true(result is None)


def test_field_metadata_multiple_pairs() raises:
    """Multiple metadata key-value pairs can be stored and retrieved."""
    var field = Field("price", ArrowType.FLOAT64, nullable=True)
    field.set_metadata("PARQUET:field_id", "7")
    field.set_metadata("ARROW:extension:name", "currency")
    field.set_metadata("encoding", "PLAIN_DICTIONARY")

    assert_equal(field.metadata_count(), 3)
    assert_equal(field.get_metadata("PARQUET:field_id").value(), "7")
    assert_equal(field.get_metadata("ARROW:extension:name").value(), "currency")
    assert_equal(field.get_metadata("encoding").value(), "PLAIN_DICTIONARY")


def test_field_metadata_overwrite_existing_key() raises:
    """Setting an existing key overwrites its value (no duplicate keys)."""
    var field = Field("ts", ArrowType.TIMESTAMP_US, nullable=False)
    field.set_metadata("timezone", "UTC")
    assert_equal(field.get_metadata("timezone").value(), "UTC")

    field.set_metadata("timezone", "America/New_York")
    assert_equal(field.get_metadata("timezone").value(), "America/New_York")
    assert_equal(field.metadata_count(), 1)


# =============================================================================
# Nested Field children tests
# =============================================================================


def test_field_no_children_primitive() raises:
    """A primitive field has zero children by default."""
    var field = Field("value", ArrowType.INT32, nullable=False)
    assert_equal(field.num_children(), 0)


def test_field_one_child_list() raises:
    """A List field has one child named 'item'."""
    var field = Field("scores", ArrowType.LIST, nullable=True)
    field.add_child("item", ArrowType.INT32, nullable=False)

    assert_equal(field.num_children(), 1)
    assert_equal(field.child_name(0), "item")
    assert_true(field.child_arrow_type(0) == ArrowType.INT32)
    assert_false(field.child_nullable(0))


def test_field_multiple_children_struct() raises:
    """A Struct field has multiple named children."""
    var field = Field("address", ArrowType.STRUCT, nullable=True)
    field.add_child("street", ArrowType.STRING, nullable=False)
    field.add_child("city", ArrowType.STRING, nullable=False)
    field.add_child("zip", ArrowType.INT32, nullable=True)

    assert_equal(field.num_children(), 3)
    assert_equal(field.child_name(0), "street")
    assert_equal(field.child_name(1), "city")
    assert_equal(field.child_name(2), "zip")
    assert_true(field.child_arrow_type(0) == ArrowType.STRING)
    assert_true(field.child_arrow_type(1) == ArrowType.STRING)
    assert_true(field.child_arrow_type(2) == ArrowType.INT32)
    assert_false(field.child_nullable(0))
    assert_false(field.child_nullable(1))
    assert_true(field.child_nullable(2))


def test_field_child_access_by_index() raises:
    """Child fields are accessible by zero-based index."""
    var field = Field("pair", ArrowType.STRUCT, nullable=False)
    field.add_child("key", ArrowType.STRING, nullable=False)
    field.add_child("value", ArrowType.FLOAT64, nullable=True)

    # Access second child
    assert_equal(field.child_name(1), "value")
    assert_true(field.child_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(field.child_nullable(1))


def test_field_num_children_count() raises:
    """num_children returns the correct count after multiple adds."""
    var field = Field("nested", ArrowType.STRUCT, nullable=False)
    assert_equal(field.num_children(), 0)

    field.add_child("a", ArrowType.INT8, nullable=False)
    assert_equal(field.num_children(), 1)

    field.add_child("b", ArrowType.INT16, nullable=True)
    assert_equal(field.num_children(), 2)

    field.add_child("c", ArrowType.INT32, nullable=False)
    assert_equal(field.num_children(), 3)


# =============================================================================
# C Data Interface export tests
# =============================================================================


def test_export_schema_format_string_int32() raises:
    """export_schema returns correct format string for INT32."""
    var field = Field("x", ArrowType.INT32, nullable=False)
    var schema = export_schema(field)

    # Read the format string from the C pointer
    var fmt = String(unsafe_from_utf8_ptr=schema.format)
    assert_equal(fmt, "i")


def test_export_schema_format_string_float64() raises:
    """export_schema returns correct format string for FLOAT64."""
    var field = Field("y", ArrowType.FLOAT64, nullable=True)
    var schema = export_schema(field)

    var fmt = String(unsafe_from_utf8_ptr=schema.format)
    assert_equal(fmt, "g")


def test_export_schema_name() raises:
    """export_schema returns the correct field name."""
    var field = Field("my_column", ArrowType.INT64, nullable=False)
    var schema = export_schema(field)

    var name = String(unsafe_from_utf8_ptr=schema.name)
    assert_equal(name, "my_column")


def test_export_schema_nullable_flag_set() raises:
    """export_schema sets ARROW_FLAG_NULLABLE for nullable fields."""
    var field = Field("col", ArrowType.INT32, nullable=True)
    var schema = export_schema(field)

    assert_equal(schema.flags, ARROW_FLAG_NULLABLE)


def test_export_schema_nullable_flag_unset() raises:
    """export_schema clears flags for non-nullable fields."""
    var field = Field("col", ArrowType.INT32, nullable=False)
    var schema = export_schema(field)

    assert_equal(schema.flags, 0)


def test_export_primitive_length() raises:
    """export_primitive sets correct length from the array."""
    var arr = PrimitiveArray[DType.int32].allocate(100)
    var exported = export_primitive[DType.int32](arr)

    assert_equal(exported.length, 100)


def test_export_primitive_null_count_nonnullable() raises:
    """export_primitive sets null_count=0 for non-nullable arrays."""
    var arr = PrimitiveArray[DType.int64].allocate(50)
    var exported = export_primitive[DType.int64](arr)

    assert_equal(exported.null_count, 0)


def test_export_primitive_null_count_nullable() raises:
    """export_primitive sets correct null_count for nullable arrays."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(10)
    # Mark 3 elements as null by directly manipulating validity
    arr._set_null(2)
    arr._set_null(5)
    arr._set_null(7)
    arr.null_count = 3

    var exported = export_primitive[DType.int32](arr)
    assert_equal(exported.null_count, 3)


def test_export_primitive_buffer_count() raises:
    """export_primitive always sets n_buffers=2 (validity + data)."""
    # Non-nullable: 2 buffers (validity ptr is null, data ptr is valid)
    var arr1 = PrimitiveArray[DType.int32].allocate(10)
    var exported1 = export_primitive[DType.int32](arr1)
    assert_equal(exported1.n_buffers, 2)

    # Nullable: 2 buffers (both pointers non-null)
    var arr2 = PrimitiveArray[DType.int32].allocate_nullable(10)
    var exported2 = export_primitive[DType.int32](arr2)
    assert_equal(exported2.n_buffers, 2)


def test_export_primitive_nonnullable_validity_ptr_null() raises:
    """For non-nullable arrays, buffers[0] (validity) is a null pointer."""
    var arr = PrimitiveArray[DType.float64].allocate(5)
    var exported = export_primitive[DType.float64](arr)

    # buffers[0] should be null for non-nullable.
    # UnsafePointer does not conform to Boolable;
    # null-check via Int address comparison.
    var validity_ptr = (exported.buffers + 0)[]
    assert_equal(Int(validity_ptr), 0)


def test_export_primitive_data_ptr_nonnull() raises:
    """For any array, buffers[1] (data) is a non-null pointer."""
    var arr = PrimitiveArray[DType.int32].allocate(5)
    var exported = export_primitive[DType.int32](arr)

    # buffers[1] should be non-null (points to data).
    # UnsafePointer does not conform to Boolable;
    # null-check via Int address comparison.
    var data_ptr = (exported.buffers + 1)[]
    assert_true(Int(data_ptr) != 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
