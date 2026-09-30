# =============================================================================
# Tests for ArrowType, updated Schema/Field, SchemaBuilder, and
# PrimitiveArray offset/slicing
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.dtype_sentinel import DTYPE_NONE
from komira_core.arrow import (
    ArrowType,
    Schema,
    SchemaBuilder,
    Field,
    RecordBatch,
    PrimitiveArray,
)

# Mojo 1.0.0 removed `DType.invalid`. `Field.__init__` writes `self.dtype =
# DTYPE_NONE` for every ArrowType with no DType peer (the final `else` in
# `arrow/schema.mojo`), so this assertion names the constant the constructor
# actually stores rather than a second spelling of "absent".
from komira_core.dtype_sentinel import DTYPE_NONE


# =============================================================================
# ArrowType enum tests
# =============================================================================


def test_arrow_type_equality() raises:
    """ArrowType constants compare equal to themselves."""
    assert_true(ArrowType.INT64 == ArrowType.INT64)
    assert_true(ArrowType.STRING == ArrowType.STRING)
    assert_false(ArrowType.INT64 == ArrowType.STRING)
    assert_true(ArrowType.INT64 != ArrowType.FLOAT64)


def test_arrow_type_write() raises:
    """ArrowType writes human-readable names."""
    assert_equal(String(ArrowType.INT32), "int32")
    assert_equal(String(ArrowType.STRING), "string")
    assert_equal(String(ArrowType.BOOL), "bool")
    assert_equal(String(ArrowType.FLOAT64), "float64")
    assert_equal(String(ArrowType.DICTIONARY), "dictionary")
    assert_equal(String(ArrowType.LIST), "list")
    assert_equal(String(ArrowType.STRUCT), "struct")
    assert_equal(String(ArrowType.TIMESTAMP), "timestamp[us]")
    assert_equal(String(ArrowType.NULL), "null")


def test_arrow_type_is_integer() raises:
    """Checks is_integer() returns True for all signed/unsigned integer types."""
    assert_true(ArrowType.INT8.is_integer())
    assert_true(ArrowType.INT16.is_integer())
    assert_true(ArrowType.INT32.is_integer())
    assert_true(ArrowType.INT64.is_integer())
    assert_true(ArrowType.UINT8.is_integer())
    assert_true(ArrowType.UINT64.is_integer())
    assert_false(ArrowType.FLOAT32.is_integer())
    assert_false(ArrowType.STRING.is_integer())
    assert_false(ArrowType.BOOL.is_integer())


def test_arrow_type_is_floating() raises:
    """Checks is_floating() returns True for float types only."""
    assert_true(ArrowType.FLOAT16.is_floating())
    assert_true(ArrowType.FLOAT32.is_floating())
    assert_true(ArrowType.FLOAT64.is_floating())
    assert_false(ArrowType.INT64.is_floating())
    assert_false(ArrowType.STRING.is_floating())


def test_arrow_type_is_numeric() raises:
    """Checks is_numeric() covers both integer and floating types."""
    assert_true(ArrowType.INT32.is_numeric())
    assert_true(ArrowType.FLOAT64.is_numeric())
    assert_false(ArrowType.STRING.is_numeric())
    assert_false(ArrowType.BINARY.is_numeric())
    assert_false(ArrowType.LIST.is_numeric())


def test_arrow_type_is_temporal() raises:
    """Checks is_temporal() returns True for date and timestamp types."""
    assert_true(ArrowType.DATE32.is_temporal())
    assert_true(ArrowType.DATE64.is_temporal())
    assert_true(ArrowType.TIMESTAMP.is_temporal())
    assert_false(ArrowType.INT64.is_temporal())
    assert_false(ArrowType.STRING.is_temporal())


def test_arrow_type_is_nested() raises:
    """Checks is_nested() returns True for list and struct types."""
    assert_true(ArrowType.LIST.is_nested())
    assert_true(ArrowType.STRUCT.is_nested())
    assert_false(ArrowType.INT64.is_nested())
    assert_false(ArrowType.STRING.is_nested())


def test_arrow_type_from_dtype() raises:
    """Converts Mojo DType to corresponding ArrowType via from_dtype()."""
    assert_true(ArrowType.from_dtype(DType.int32) == ArrowType.INT32)
    assert_true(ArrowType.from_dtype(DType.int64) == ArrowType.INT64)
    assert_true(ArrowType.from_dtype(DType.float64) == ArrowType.FLOAT64)
    assert_true(ArrowType.from_dtype(DType.bool) == ArrowType.BOOL)
    assert_true(ArrowType.from_dtype(DType.uint8) == ArrowType.UINT8)


# =============================================================================
# Field with ArrowType tests
# =============================================================================


def test_field_with_arrow_type() raises:
    """Field can be constructed with ArrowType (new API)."""
    var f = Field("name", ArrowType.STRING, nullable=True)
    assert_equal(f.name, "name")
    assert_true(f.arrow_type == ArrowType.STRING)
    assert_true(f.nullable)
    # STRING has no DType equivalent
    assert_equal(f.dtype, DTYPE_NONE)


def test_field_with_dtype_backward_compat() raises:
    """Field constructed with DType still works (backward compat)."""
    var f = Field("age", DType.int32, nullable=False)
    assert_equal(f.name, "age")
    assert_equal(f.dtype, DType.int32)
    assert_true(f.arrow_type == ArrowType.INT32)
    assert_false(f.nullable)


def test_field_arrow_type_numeric_derives_dtype() raises:
    """ArrowType constructor derives correct DType for numeric types."""
    var f = Field("score", ArrowType.FLOAT64, nullable=False)
    assert_equal(f.dtype, DType.float64)
    assert_true(f.arrow_type == ArrowType.FLOAT64)


# =============================================================================
# SchemaBuilder tests
# =============================================================================


def test_schema_builder_basic() raises:
    """SchemaBuilder creates a schema from incrementally added fields."""
    var builder = SchemaBuilder()
    builder.add_field(Field("id", ArrowType.INT64, nullable=False))
    builder.add_field(Field("name", ArrowType.STRING, nullable=True))
    builder.add_field(Field("score", DType.float64, nullable=False))
    var schema = builder.build()

    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_name(1), "name")
    assert_equal(schema.field_name(2), "score")
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(2) == ArrowType.FLOAT64)
    assert_false(schema.field_nullable(0))
    assert_true(schema.field_nullable(1))
    assert_false(schema.field_nullable(2))


def test_schema_builder_many_fields() raises:
    """SchemaBuilder works with more than 3 fields (beyond from_fields_N)."""
    var builder = SchemaBuilder()
    builder.add_field(Field("a", ArrowType.INT32, nullable=False))
    builder.add_field(Field("b", ArrowType.INT64, nullable=False))
    builder.add_field(Field("c", ArrowType.FLOAT32, nullable=True))
    builder.add_field(Field("d", ArrowType.STRING, nullable=True))
    builder.add_field(Field("e", ArrowType.TIMESTAMP, nullable=False))
    var schema = builder.build()

    assert_equal(schema.num_columns(), 5)
    assert_equal(schema.field_name(4), "e")
    assert_true(schema.field_arrow_type(3) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(4) == ArrowType.TIMESTAMP)


def test_schema_builder_empty() raises:
    """SchemaBuilder with no fields produces an empty schema."""
    var builder = SchemaBuilder()
    var schema = builder.build()
    assert_equal(schema.num_columns(), 0)


def test_schema_get_field_arrow_type_by_name() raises:
    """Schema.get_field_arrow_type looks up ArrowType by field name."""
    var builder = SchemaBuilder()
    builder.add_field(Field("x", ArrowType.INT64, nullable=False))
    builder.add_field(Field("y", ArrowType.STRING, nullable=True))
    var schema = builder.build()

    var at = schema.get_field_arrow_type("y")
    assert_true(at == ArrowType.STRING)


# =============================================================================
# PrimitiveArray offset and slicing tests
# =============================================================================


def test_primitive_array_default_offset() raises:
    """Newly created PrimitiveArrays have offset=0."""
    var arr = PrimitiveArray[DType.int64].allocate(5)
    assert_equal(arr.offset, 0)


def test_primitive_array_from_list_offset() raises:
    """Arrays from from_list have offset=0."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)
    assert_equal(arr.offset, 0)
    assert_equal(arr.length, 3)


def test_primitive_array_slice_basic() raises:
    """Slicing creates a view with correct offset and values."""
    var values: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](10),
        Scalar[DType.int64](20),
        Scalar[DType.int64](30),
        Scalar[DType.int64](40),
        Scalar[DType.int64](50),
    ]
    var arr = PrimitiveArray[DType.int64].from_list(values)

    # Slice [1, 4) — elements 20, 30, 40
    var sliced = arr.slice(1, 3)
    assert_equal(sliced.length, 3)
    assert_equal(sliced.offset, 1)
    assert_equal(sliced.get(0), Scalar[DType.int64](20))
    assert_equal(sliced.get(1), Scalar[DType.int64](30))
    assert_equal(sliced.get(2), Scalar[DType.int64](40))


def test_primitive_array_slice_start() raises:
    """Slicing from the start works correctly."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](100),
        Scalar[DType.int32](200),
        Scalar[DType.int32](300),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)

    var sliced = arr.slice(0, 2)
    assert_equal(sliced.length, 2)
    assert_equal(sliced.offset, 0)
    assert_equal(sliced.get(0), Scalar[DType.int32](100))
    assert_equal(sliced.get(1), Scalar[DType.int32](200))


def test_primitive_array_slice_end() raises:
    """Slicing to the end works correctly."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
        Scalar[DType.int32](4),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)

    var sliced = arr.slice(2, 2)
    assert_equal(sliced.length, 2)
    assert_equal(sliced.offset, 2)
    assert_equal(sliced.get(0), Scalar[DType.int32](3))
    assert_equal(sliced.get(1), Scalar[DType.int32](4))


def test_primitive_array_slice_empty() raises:
    """Slicing with length=0 produces an empty view."""
    var values: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](10),
        Scalar[DType.int64](20),
    ]
    var arr = PrimitiveArray[DType.int64].from_list(values)

    var sliced = arr.slice(1, 0)
    assert_equal(sliced.length, 0)


def test_primitive_array_slice_out_of_bounds() raises:
    """Slicing out of bounds raises an error."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
    ]
    var arr = PrimitiveArray[DType.int32].from_list(values)

    var raised = False
    try:
        _ = arr.slice(1, 3)  # start=1, length=3 -> end=4, but only 2 elements
    except:
        raised = True
    assert_true(raised)


def test_primitive_array_slice_simd_load() raises:
    """SIMD load on a sliced array reads correct offset-adjusted values."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.0),
        Scalar[DType.float64](2.0),
        Scalar[DType.float64](3.0),
        Scalar[DType.float64](4.0),
    ]
    var arr = PrimitiveArray[DType.float64].from_list(values)

    # Slice [1, 3) — elements 2.0, 3.0
    var sliced = arr.slice(1, 2)
    # Load 2 elements from position 0 of the slice
    var loaded = sliced.load[2](0)
    assert_equal(loaded[0], Scalar[DType.float64](2.0))
    assert_equal(loaded[1], Scalar[DType.float64](3.0))


# =============================================================================
# Backward compatibility — existing from_fields_N still work
# =============================================================================


def test_from_fields_backward_compat() raises:
    """Legacy from_fields_1/2/3 still work with DType-based Fields."""
    var schema = Schema.from_fields_2(
        Field("id", DType.int64, nullable=False),
        Field("val", DType.float64, nullable=True),
    )
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_dtype(0), DType.int64)
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_nullable(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
