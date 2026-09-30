# =============================================================================
# Tests for Schema metadata and Arrow C Data Interface
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Schema,
    SchemaBuilder,
    Field,
    CArrowSchema,
    CArrowArray,
    ARROW_FLAG_NULLABLE,
    ARROW_FLAG_DICTIONARY_ORDERED,
    ARROW_FLAG_MAP_KEYS_SORTED,
)


# =============================================================================
# Schema metadata tests
# =============================================================================


def test_schema_metadata_set_and_get() raises:
    """set_metadata stores a key-value pair retrievable by get_metadata."""
    var builder = SchemaBuilder()
    builder.add_field(Field("id", ArrowType.INT64, nullable=False))
    var schema = builder.build()

    schema.set_metadata("creator", "komira")
    var val = schema.get_metadata("creator")
    assert_true(val is not None)
    assert_equal(val.value(), "creator: komira".split(": ")[1])


def test_schema_metadata_has_key() raises:
    """has_metadata returns True for existing keys, False for missing."""
    var builder = SchemaBuilder()
    builder.add_field(Field("x", ArrowType.FLOAT64, nullable=True))
    var schema = builder.build()

    schema.set_metadata("version", "1.0")
    assert_true(schema.has_metadata("version"))
    assert_false(schema.has_metadata("nonexistent"))


def test_schema_metadata_missing_key_returns_none() raises:
    """get_metadata returns None for a key that was never set."""
    var builder = SchemaBuilder()
    builder.add_field(Field("col", ArrowType.INT32, nullable=False))
    var schema = builder.build()

    var result = schema.get_metadata("missing_key")
    assert_true(result is None)


def test_schema_metadata_multiple_pairs() raises:
    """Multiple metadata key-value pairs can be stored and retrieved."""
    var builder = SchemaBuilder()
    builder.add_field(Field("a", ArrowType.STRING, nullable=True))
    var schema = builder.build()

    schema.set_metadata("encoding", "PLAIN")
    schema.set_metadata("compression", "ZSTD")
    schema.set_metadata("row_count", "1000000")

    assert_equal(schema.metadata_count(), 3)
    assert_equal(schema.get_metadata("encoding").value(), "PLAIN")
    assert_equal(schema.get_metadata("compression").value(), "ZSTD")
    assert_equal(schema.get_metadata("row_count").value(), "1000000")


def test_schema_metadata_overwrite_existing_key() raises:
    """Setting an existing key overwrites its value."""
    var builder = SchemaBuilder()
    builder.add_field(Field("col", ArrowType.INT64, nullable=False))
    var schema = builder.build()

    schema.set_metadata("version", "1.0")
    assert_equal(schema.get_metadata("version").value(), "1.0")

    schema.set_metadata("version", "2.0")
    assert_equal(schema.get_metadata("version").value(), "2.0")
    # Count should stay at 1 (overwrite, not append)
    assert_equal(schema.metadata_count(), 1)


def test_schema_metadata_empty_by_default() raises:
    """A freshly built schema has zero metadata entries."""
    var builder = SchemaBuilder()
    builder.add_field(Field("id", ArrowType.INT64, nullable=False))
    var schema = builder.build()

    assert_equal(schema.metadata_count(), 0)
    assert_false(schema.has_metadata("anything"))


# =============================================================================
# ArrowType.format_string() tests — Arrow C Data Interface format strings
# =============================================================================


def test_format_string_int32() raises:
    """INT32 maps to format string 'i'."""
    assert_equal(ArrowType.INT32.format_string(), "i")


def test_format_string_int64() raises:
    """INT64 maps to format string 'l'."""
    assert_equal(ArrowType.INT64.format_string(), "l")


def test_format_string_float32() raises:
    """FLOAT32 maps to format string 'f'."""
    assert_equal(ArrowType.FLOAT32.format_string(), "f")


def test_format_string_float64() raises:
    """FLOAT64 maps to format string 'g'."""
    assert_equal(ArrowType.FLOAT64.format_string(), "g")


def test_format_string_string_utf8() raises:
    """STRING (utf8) maps to format string 'u'."""
    assert_equal(ArrowType.STRING.format_string(), "u")


def test_format_string_binary() raises:
    """BINARY maps to format string 'z'."""
    assert_equal(ArrowType.BINARY.format_string(), "z")


def test_format_string_bool() raises:
    """BOOL maps to format string 'b'."""
    assert_equal(ArrowType.BOOL.format_string(), "b")


def test_format_string_date32() raises:
    """DATE32 (days since epoch) maps to format string 'tdD'."""
    assert_equal(ArrowType.DATE32.format_string(), "tdD")


def test_format_string_timestamp_microsecond() raises:
    """TIMESTAMP (microsecond, no timezone) maps to format string 'tsu:'."""
    assert_equal(ArrowType.TIMESTAMP.format_string(), "tsu:")


def test_format_string_all_integer_types() raises:
    """All signed and unsigned integer types have correct format strings."""
    assert_equal(ArrowType.INT8.format_string(), "c")
    assert_equal(ArrowType.INT16.format_string(), "s")
    assert_equal(ArrowType.INT32.format_string(), "i")
    assert_equal(ArrowType.INT64.format_string(), "l")
    assert_equal(ArrowType.UINT8.format_string(), "C")
    assert_equal(ArrowType.UINT16.format_string(), "S")
    assert_equal(ArrowType.UINT32.format_string(), "I")
    assert_equal(ArrowType.UINT64.format_string(), "L")


def test_format_string_float16() raises:
    """FLOAT16 maps to format string 'e' (half-precision)."""
    assert_equal(ArrowType.FLOAT16.format_string(), "e")


def test_format_string_nested_types() raises:
    """LIST and STRUCT have multi-character format strings starting with +."""
    assert_equal(ArrowType.LIST.format_string(), "+l")
    assert_equal(ArrowType.STRUCT.format_string(), "+s")


def test_format_string_roundtrip_consistency() raises:
    """Every ArrowType's format_string is non-empty and consistent across calls."""
    # Collect all types to test
    var types: List[UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]
    for type_id in types:
        var at = ArrowType(type_id)
        var fmt1 = at.format_string()
        var fmt2 = at.format_string()
        # Format string must not be empty
        assert_true(fmt1.byte_length() > 0)
        # Must be deterministic
        assert_equal(fmt1, fmt2)


# =============================================================================
# CArrowSchema struct tests
# =============================================================================


def test_carrow_schema_default_is_released() raises:
    """Default CArrowSchema has null release (is released)."""
    var schema = CArrowSchema()
    assert_true(schema.is_released())
    assert_equal(schema.flags, 0)
    assert_equal(schema.n_children, 0)


def test_carrow_array_default_is_released() raises:
    """Default CArrowArray has null release (is released)."""
    var arr = CArrowArray()
    assert_true(arr.is_released())
    assert_equal(arr.length, 0)
    assert_equal(arr.null_count, 0)
    assert_equal(arr.offset, 0)
    assert_equal(arr.n_buffers, 0)
    assert_equal(arr.n_children, 0)


# =============================================================================
# Arrow flag constants tests
# =============================================================================


def test_arrow_flag_constants() raises:
    """Arrow flag constants have correct values per the spec."""
    assert_equal(ARROW_FLAG_DICTIONARY_ORDERED, 1)
    assert_equal(ARROW_FLAG_NULLABLE, 2)
    assert_equal(ARROW_FLAG_MAP_KEYS_SORTED, 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
