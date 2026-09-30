# =============================================================================
# Tests for Schema, Field, RecordBatch (komira_core.arrow)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_core.arrow import Schema, Field, RecordBatch, PrimitiveArray


def test_field_construction() raises:
    """Field stores name, dtype, and nullable flag."""
    var f = Field("age", DType.int32, nullable=False)
    assert_equal(f.name, "age")
    assert_equal(f.dtype, DType.int32)
    assert_false(f.nullable)


def test_field_nullable() raises:
    """Field correctly stores nullable=True."""
    var f = Field("score", DType.float64, nullable=True)
    assert_equal(f.name, "score")
    assert_equal(f.dtype, DType.float64)
    assert_true(f.nullable)


def test_schema_from_1_field() raises:
    """Schema.from_fields_1 creates a 1-column schema."""
    var schema = Schema.from_fields_1(
        Field("id", DType.int64, nullable=False),
    )
    assert_equal(schema.num_columns(), 1)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_dtype(0), DType.int64)
    assert_false(schema.field_nullable(0))


def test_schema_from_2_fields() raises:
    """Schema.from_fields_2 creates a 2-column schema."""
    var schema = Schema.from_fields_2(
        Field("id", DType.int64, nullable=False),
        Field("val", DType.float64, nullable=True),
    )
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_dtype(1), DType.float64)
    assert_true(schema.field_nullable(1))


def test_schema_from_3_fields() raises:
    """Schema.from_fields_3 creates a 3-column schema."""
    var schema = Schema.from_fields_3(
        Field("a", DType.int32, nullable=False),
        Field("b", DType.int64, nullable=True),
        Field("c", DType.float64, nullable=False),
    )
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(2), "c")
    assert_equal(schema.field_dtype(2), DType.float64)


def test_schema_get_field_by_name() raises:
    """Schema.get_field_name looks up a field by name."""
    var schema = Schema.from_fields_2(
        Field("x", DType.int64, nullable=False),
        Field("y", DType.float64, nullable=True),
    )
    var name = schema.get_field_name("y")
    assert_equal(name, "y")


def test_schema_get_field_dtype_by_name() raises:
    """Schema.get_field_dtype looks up dtype by field name."""
    var schema = Schema.from_fields_2(
        Field("x", DType.int64, nullable=False),
        Field("y", DType.float64, nullable=True),
    )
    var dt = schema.get_field_dtype("y")
    assert_equal(dt, DType.float64)


def test_schema_column_index() raises:
    """Schema.column_index returns the correct zero-based index."""
    var schema = Schema.from_fields_3(
        Field("a", DType.int32, nullable=False),
        Field("b", DType.int64, nullable=False),
        Field("c", DType.float64, nullable=False),
    )
    assert_equal(schema.column_index("a"), 0)
    assert_equal(schema.column_index("b"), 1)
    assert_equal(schema.column_index("c"), 2)


def test_schema_missing_field_raises() raises:
    """Looking up a non-existent field raises an error."""
    var schema = Schema.from_fields_1(
        Field("x", DType.int64, nullable=False),
    )
    var raised = False
    try:
        _ = schema.get_field_name("missing")
    except:
        raised = True
    assert_true(raised)


def test_recordbatch_from_1_column() raises:
    """RecordBatch.from_columns_1 constructs a 1-column batch."""
    var values: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](100),
        Scalar[DType.int64](200),
    ]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(
            Field("x", DType.int64, nullable=False),
        ),
        PrimitiveArray[DType.int64].from_list(values),
    )
    assert_equal(batch.num_rows(), 2)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.column_value(0, 0), Scalar[DType.int64](100))
    assert_equal(batch.column_value(0, 1), Scalar[DType.int64](200))


def test_recordbatch_from_2_columns() raises:
    """RecordBatch.from_columns_2 constructs a 2-column batch."""
    var col0_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
    ]
    var col1_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](10),
        Scalar[DType.int64](20),
    ]
    var batch = RecordBatch.from_columns_2(
        Schema.from_fields_2(
            Field("a", DType.int64, nullable=False),
            Field("b", DType.int64, nullable=False),
        ),
        PrimitiveArray[DType.int64].from_list(col0_vals),
        PrimitiveArray[DType.int64].from_list(col1_vals),
    )
    assert_equal(batch.num_rows(), 2)
    assert_equal(batch.num_columns(), 2)
    assert_equal(batch.column_value(0, 0), Scalar[DType.int64](1))
    assert_equal(batch.column_value(1, 1), Scalar[DType.int64](20))


def test_recordbatch_column_by_name() raises:
    """column_by_name returns the correct column index."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
    ]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(
            Field("id", DType.int64, nullable=False),
        ),
        PrimitiveArray[DType.int64].from_list(vals),
    )
    assert_equal(batch.column_by_name("id"), 0)


def test_recordbatch_schema_mismatch_raises() raises:
    """from_columns_1 raises when schema has wrong number of fields."""
    var vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
    ]
    var raised = False
    try:
        _ = RecordBatch.from_columns_1(
            Schema.from_fields_2(
                Field("a", DType.int64, nullable=False),
                Field("b", DType.int64, nullable=False),
            ),
            PrimitiveArray[DType.int64].from_list(vals),
        )
    except:
        raised = True
    assert_true(raised)


def test_recordbatch_empty_schema() raises:
    """RecordBatch.from_columns_0 works with an empty schema."""
    var batch = RecordBatch.from_columns_0(Schema())
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 0)


# =============================================================================
# RecordBatch.column_by_index and column_length tests
# =============================================================================


def test_recordbatch_column_by_index() raises:
    """column_by_index returns the column length for valid indices."""
    var col0_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](2),
        Scalar[DType.int64](3),
    ]
    var col1_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](10),
        Scalar[DType.int64](20),
        Scalar[DType.int64](30),
    ]
    var batch = RecordBatch.from_columns_2(
        Schema.from_fields_2(
            Field("a", DType.int64, nullable=False),
            Field("b", DType.int64, nullable=False),
        ),
        PrimitiveArray[DType.int64].from_list(col0_vals),
        PrimitiveArray[DType.int64].from_list(col1_vals),
    )
    assert_equal(batch.column_by_index(0), 3)
    assert_equal(batch.column_by_index(1), 3)


def test_recordbatch_column_by_index_out_of_bounds() raises:
    """column_by_index raises on out-of-bounds index."""
    var vals: List[Scalar[DType.int64]] = [Scalar[DType.int64](1)]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(Field("x", DType.int64, nullable=False)),
        PrimitiveArray[DType.int64].from_list(vals),
    )
    var raised = False
    try:
        _ = batch.column_by_index(5)
    except:
        raised = True
    assert_true(raised)


def test_recordbatch_column_length() raises:
    """column_length returns the length of a specific column."""
    var col0_vals: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](10),
        Scalar[DType.int64](20),
    ]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(Field("x", DType.int64, nullable=False)),
        PrimitiveArray[DType.int64].from_list(col0_vals),
    )
    assert_equal(batch.column_length(0), 2)


def test_recordbatch_column_length_out_of_bounds() raises:
    """column_length raises on out-of-bounds index."""
    var vals: List[Scalar[DType.int64]] = [Scalar[DType.int64](1)]
    var batch = RecordBatch.from_columns_1(
        Schema.from_fields_1(Field("x", DType.int64, nullable=False)),
        PrimitiveArray[DType.int64].from_list(vals),
    )
    var raised = False
    try:
        _ = batch.column_length(10)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
