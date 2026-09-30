# =============================================================================
# Tests for P0 Arrow spec fixes:
#   1. Dictionary support in Column (from_dictionary / as_dictionary)
#   2. RecordBatchBuilder for N columns
#   3. Parameterized Timestamp types (s/ms/us/ns)
#   4. Parameterized Decimal128 format string
#   5. Buffer end-padding to 64-byte boundary
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
    StringArray,
    StringDictionaryArray,
    decimal_format_string,
    timestamp_format_string,
)


# =============================================================================
# P0-1: Dictionary support in Column
# =============================================================================


def test_column_from_dictionary_type() raises:
    """Column.from_dictionary sets arrow_type to DICTIONARY."""
    var dict_values: List[String] = ["apple", "banana"]
    var dictionary = StringArray.from_strings(dict_values)
    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(1), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)
    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)

    var col = Column.from_dictionary(arr^)
    assert_equal(col.arrow_type, ArrowType.DICTIONARY)
    assert_equal(col.length(), 3)
    assert_equal(col.null_count(), 0)


def test_column_dictionary_roundtrip() raises:
    """Column.from_dictionary -> as_dictionary preserves all values."""
    var dict_values: List[String] = ["red", "green", "blue"]
    var dictionary = StringArray.from_strings(dict_values)
    var idx_values: List[Scalar[DType.int32]] = [Int32(2), Int32(0), Int32(1), Int32(2)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)
    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)

    var col = Column.from_dictionary(arr^)
    var restored = col.as_dictionary()
    assert_equal(len(restored), 4)
    assert_equal(restored.get(0), "blue")
    assert_equal(restored.get(1), "red")
    assert_equal(restored.get(2), "green")
    assert_equal(restored.get(3), "blue")


def test_column_dictionary_indices_preserved() raises:
    """Column.from_dictionary -> as_dictionary preserves raw index values."""
    var dict_values: List[String] = ["x", "y", "z"]
    var dictionary = StringArray.from_strings(dict_values)
    var idx_values: List[Scalar[DType.int32]] = [Int32(1), Int32(0), Int32(2)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)
    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)

    var col = Column.from_dictionary(arr^)
    var restored = col.as_dictionary()
    assert_equal(restored.get_index(0), 1)
    assert_equal(restored.get_index(1), 0)
    assert_equal(restored.get_index(2), 2)


def test_column_dictionary_single_entry() raises:
    """Dictionary column with a single dictionary entry roundtrips."""
    var dict_values: List[String] = ["singleton"]
    var dictionary = StringArray.from_strings(dict_values)
    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(0), Int32(0)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)
    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)

    var col = Column.from_dictionary(arr^)
    var restored = col.as_dictionary()
    assert_equal(len(restored), 3)
    assert_equal(restored.dict_size(), 1)
    assert_equal(restored.get(0), "singleton")
    assert_equal(restored.get(2), "singleton")


def test_column_as_dictionary_wrong_type_raises() raises:
    """Calling as_dictionary on a non-DICTIONARY column raises an error."""
    var values: List[Scalar[DType.int32]] = [Int32(1), Int32(2)]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    var col = Column.from_primitive[DType.int32](arr^)
    var raised = False
    try:
        _ = col.as_dictionary()
    except:
        raised = True
    assert_true(raised)


def test_column_dictionary_in_recordbatch() raises:
    """Dictionary column works inside a RecordBatch via column_as_dictionary."""
    var dict_values: List[String] = ["cat", "dog"]
    var dictionary = StringArray.from_strings(dict_values)
    var idx_values: List[Scalar[DType.int32]] = [Int32(0), Int32(1)]
    var indices = PrimitiveArray[DType.int32].from_list(idx_values)
    var arr = StringDictionaryArray.from_parts(indices^, dictionary^)

    var builder = SchemaBuilder()
    builder.add_field(Field("id", ArrowType.INT32, nullable=False))
    builder.add_field(Field("label", ArrowType.DICTIONARY, nullable=False))
    var schema = builder.build()

    var int_vals: List[Scalar[DType.int32]] = [Int32(1), Int32(2)]

    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(int_vals)
    ))
    rb.add_column(Column.from_dictionary(arr^))
    var batch = rb.build(schema^)

    assert_equal(batch.num_columns(), 2)
    assert_equal(batch.num_rows(), 2)
    assert_equal(batch.column_arrow_type(1), ArrowType.DICTIONARY)

    # Use column_as_dictionary (accesses data within method scope)
    var restored = batch.column_as_dictionary(1)
    assert_equal(restored.get(0), "cat")
    assert_equal(restored.get(1), "dog")


# =============================================================================
# P0-2: RecordBatchBuilder for N columns
# =============================================================================


def test_recordbatch_builder_basic() raises:
    """RecordBatchBuilder creates a batch from columns added one at a time."""
    var builder = SchemaBuilder()
    builder.add_field(Field("a", ArrowType.INT32, nullable=False))
    builder.add_field(Field("b", ArrowType.FLOAT64, nullable=False))
    var schema = builder.build()

    var int_vals: List[Scalar[DType.int32]] = [Int32(10), Int32(20)]
    var float_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.5),
    ]

    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(int_vals)
    ))
    rb.add_column(Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(float_vals)
    ))
    var batch = rb.build(schema^)

    assert_equal(batch.num_columns(), 2)
    assert_equal(batch.num_rows(), 2)


def test_recordbatch_builder_many_columns() raises:
    """RecordBatchBuilder works with more columns than from_typed_columns_3."""
    var sb = SchemaBuilder()
    for i in range(8):
        sb.add_field(Field("col" + String(i), ArrowType.INT64, nullable=False))
    var schema = sb.build()

    var rb = RecordBatchBuilder()
    for i in range(8):
        var vals: List[Scalar[DType.int64]] = [Int64(i * 10), Int64(i * 10 + 1)]
        rb.add_column(Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(vals)
        ))
    var batch = rb.build(schema^)

    assert_equal(batch.num_columns(), 8)
    assert_equal(batch.num_rows(), 2)

    # Verify first and last column data via column_as_primitive
    var arr0 = batch.column_as_primitive_int64(0)
    assert_equal(arr0.get(0), Int64(0))
    assert_equal(arr0.get(1), Int64(1))

    var arr7 = batch.column_as_primitive_int64(7)
    assert_equal(arr7.get(0), Int64(70))
    assert_equal(arr7.get(1), Int64(71))


def test_recordbatch_builder_schema_mismatch_raises() raises:
    """RecordBatchBuilder.build raises when column count != schema field count."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, nullable=False))
    sb.add_field(Field("b", ArrowType.INT32, nullable=False))
    var schema = sb.build()

    var vals: List[Scalar[DType.int32]] = [Int32(1)]
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(vals)
    ))
    # Only 1 column but schema has 2
    var raised = False
    try:
        _ = rb.build(schema^)
    except:
        raised = True
    assert_true(raised)


def test_recordbatch_builder_length_mismatch_raises() raises:
    """RecordBatchBuilder.build raises when columns have different lengths."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, nullable=False))
    sb.add_field(Field("b", ArrowType.INT32, nullable=False))
    var schema = sb.build()

    var vals2: List[Scalar[DType.int32]] = [Int32(1), Int32(2)]
    var vals3: List[Scalar[DType.int32]] = [Int32(1), Int32(2), Int32(3)]
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(vals2)
    ))
    rb.add_column(Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(vals3)
    ))
    var raised = False
    try:
        _ = rb.build(schema^)
    except:
        raised = True
    assert_true(raised)


def test_recordbatch_builder_empty_schema() raises:
    """RecordBatchBuilder with 0 columns and empty schema works."""
    var schema = Schema()
    var rb = RecordBatchBuilder()
    var batch = rb.build(schema^)
    assert_equal(batch.num_columns(), 0)
    assert_equal(batch.num_rows(), 0)


def test_recordbatch_builder_mixed_types() raises:
    """RecordBatchBuilder handles mixed column types (int, float, string)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT32, nullable=False))
    sb.add_field(Field("score", ArrowType.FLOAT64, nullable=False))
    sb.add_field(Field("name", ArrowType.STRING, nullable=False))
    var schema = sb.build()

    var int_vals: List[Scalar[DType.int32]] = [Int32(1), Int32(2)]
    var float_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](9.5),
        Scalar[DType.float64](8.5),
    ]
    var str_vals: List[String] = ["alice", "bob"]

    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(int_vals)
    ))
    rb.add_column(Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(float_vals)
    ))
    rb.add_column(Column.from_string(StringArray.from_strings(str_vals)))
    var batch = rb.build(schema^)

    assert_equal(batch.num_columns(), 3)
    assert_equal(batch.num_rows(), 2)

    # Use column_as_* methods for safe access
    var str_arr = batch.column_as_string(2)
    assert_equal(str_arr.get(0), "alice")
    assert_equal(str_arr.get(1), "bob")

    var int_arr = batch.column_as_primitive_int32(0)
    assert_equal(int_arr.get(0), Scalar[DType.int32](1))
    assert_equal(int_arr.get(1), Scalar[DType.int32](2))


# =============================================================================
# P0-3: Parameterized Timestamp types
# =============================================================================


def test_timestamp_s_type() raises:
    """TIMESTAMP_S is a distinct type with correct display and format string."""
    assert_equal(String(ArrowType.TIMESTAMP_S), "timestamp[s]")
    assert_equal(ArrowType.TIMESTAMP_S.format_string(), "tss:")
    assert_true(ArrowType.TIMESTAMP_S.is_temporal())
    assert_true(ArrowType.TIMESTAMP_S.is_timestamp())
    assert_false(ArrowType.TIMESTAMP_S.is_numeric())


def test_timestamp_ms_type() raises:
    """TIMESTAMP_MS is a distinct type with correct display and format string."""
    assert_equal(String(ArrowType.TIMESTAMP_MS), "timestamp[ms]")
    assert_equal(ArrowType.TIMESTAMP_MS.format_string(), "tsm:")
    assert_true(ArrowType.TIMESTAMP_MS.is_temporal())
    assert_true(ArrowType.TIMESTAMP_MS.is_timestamp())


def test_timestamp_us_type() raises:
    """TIMESTAMP_US is a distinct type with correct display and format string."""
    assert_equal(String(ArrowType.TIMESTAMP_US), "timestamp[us]")
    assert_equal(ArrowType.TIMESTAMP_US.format_string(), "tsu:")
    assert_true(ArrowType.TIMESTAMP_US.is_temporal())
    assert_true(ArrowType.TIMESTAMP_US.is_timestamp())


def test_timestamp_ns_type() raises:
    """TIMESTAMP_NS is a distinct type with correct display and format string."""
    assert_equal(String(ArrowType.TIMESTAMP_NS), "timestamp[ns]")
    assert_equal(ArrowType.TIMESTAMP_NS.format_string(), "tsn:")
    assert_true(ArrowType.TIMESTAMP_NS.is_temporal())
    assert_true(ArrowType.TIMESTAMP_NS.is_timestamp())


def test_timestamp_legacy_preserved() raises:
    """Legacy TIMESTAMP constant still works (maps to us)."""
    assert_equal(String(ArrowType.TIMESTAMP), "timestamp[us]")
    assert_equal(ArrowType.TIMESTAMP.format_string(), "tsu:")
    assert_true(ArrowType.TIMESTAMP.is_timestamp())


def test_timestamp_types_are_distinct() raises:
    """Each timestamp precision is a distinct type."""
    assert_true(ArrowType.TIMESTAMP_S != ArrowType.TIMESTAMP_MS)
    assert_true(ArrowType.TIMESTAMP_MS != ArrowType.TIMESTAMP_US)
    assert_true(ArrowType.TIMESTAMP_US != ArrowType.TIMESTAMP_NS)
    assert_true(ArrowType.TIMESTAMP_S != ArrowType.TIMESTAMP_NS)


def test_timestamp_field_derives_int64() raises:
    """Field with timestamp type derives DType.int64 for storage."""
    var f_s = Field("ts_s", ArrowType.TIMESTAMP_S, nullable=False)
    assert_equal(f_s.dtype, DType.int64)
    var f_ns = Field("ts_ns", ArrowType.TIMESTAMP_NS, nullable=False)
    assert_equal(f_ns.dtype, DType.int64)


def test_non_timestamp_not_timestamp() raises:
    """Non-timestamp types return False for is_timestamp()."""
    assert_false(ArrowType.INT64.is_timestamp())
    assert_false(ArrowType.DATE32.is_timestamp())
    assert_false(ArrowType.STRING.is_timestamp())


# =============================================================================
# P0-4: Parameterized Decimal128 format string
# =============================================================================


def test_decimal_format_string_default() raises:
    """Decimal format string produces correct format for default precision/scale."""
    assert_equal(decimal_format_string(38, 18), "d:38,18")


def test_decimal_format_string_custom() raises:
    """Decimal format string produces correct format for custom precision/scale."""
    assert_equal(decimal_format_string(18, 6), "d:18,6")
    assert_equal(decimal_format_string(10, 2), "d:10,2")
    assert_equal(decimal_format_string(1, 0), "d:1,0")


def test_timestamp_format_string_no_tz() raises:
    """Timestamp format string produces correct format without timezone."""
    assert_equal(timestamp_format_string("s"), "tss:")
    assert_equal(timestamp_format_string("ms"), "tsms:")
    assert_equal(timestamp_format_string("us"), "tsus:")
    assert_equal(timestamp_format_string("ns"), "tsns:")


def test_timestamp_format_string_with_tz() raises:
    """Timestamp format string produces correct format with timezone."""
    assert_equal(timestamp_format_string("us", "UTC"), "tsus:UTC")
    assert_equal(
        timestamp_format_string("ns", "America/New_York"),
        "tsns:America/New_York",
    )


# =============================================================================
# P0-5: Buffer end-padding to 64-byte boundary
# =============================================================================
# No direct test here: OwnedAlignedBuffer owns the allocator (with 64-byte
# end-padding), and SharedAlignedBuffer's capacity() returns the logical
# length, not the padded allocation. The padding-to-64-byte invariant is
# exercised indirectly by every SharedAlignedBuffer-backed test (Column /
# PrimitiveArray / StringArray round-trips that rely on safe SIMD over the
# padded tail).


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
