"""Every branch of `record_batch_extract`: each supported column type with a
value and with a NULL, the unsupported type, the empty batch per type, and
the shape refusals of `scalar` and `scalar_list`.

Each test names the mutant it catches in its docstring.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.scalar_value import ScalarValue

from komira_dispatch_scan.record_batch_extract import scalar, scalar_list


# =============================================================================
# Fixtures: one-column batches; row 1 is NULL where the type allows it
# =============================================================================


def _one(var col: Column[HeapRegion], at: ArrowType, nullable: Bool = True) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), at, nullable))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


def _i64(n: Int, null_row: Int = -1) raises -> RecordBatch:
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a.set(i, Int64(10 + i))
    if null_row >= 0:
        a._set_null(null_row)
    return _one(Column.from_primitive[DType.int64](a^), ArrowType.INT64)


def _i32(n: Int, at: ArrowType, null_row: Int = -1) raises -> RecordBatch:
    var a = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        a.set(i, Int32(20 + i))
    if null_row >= 0:
        a._set_null(null_row)
    var c = Column.from_primitive[DType.int32](a^)
    c.arrow_type = at
    return _one(c^, at)


def _f64(n: Int, null_row: Int = -1) raises -> RecordBatch:
    var a = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        a.set(i, Float64(i) + 0.5)
    if null_row >= 0:
        a._set_null(null_row)
    return _one(Column.from_primitive[DType.float64](a^), ArrowType.FLOAT64)


def _str(n: Int, null_row: Int = -1) raises -> RecordBatch:
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(n):
        vals.append(String("s") + String(i))
        valid.append(i != null_row)
    return _one(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid)),
        ArrowType.STRING,
    )


def _bool(n: Int, null_row: Int = -1) raises -> RecordBatch:
    var a = BooleanArray.allocate_nullable(n)
    for i in range(n):
        a.set(i, i % 2 == 0)
    if null_row >= 0:
        a._set_null(null_row)
    return _one(Column.from_boolean(a^), ArrowType.BOOL)


def _u8(n: Int) raises -> RecordBatch:
    var a = PrimitiveArray[DType.uint8].allocate(n)
    var c = Column.from_primitive[DType.uint8](a^)
    c.arrow_type = ArrowType.UINT8
    return _one(c^, ArrowType.UINT8, False)


def _raises_scalar(b: RecordBatch) -> String:
    try:
        _ = scalar(b)
    except e:
        return String(e)
    return String("")


def _raises_list(b: RecordBatch) -> String:
    try:
        _ = scalar_list(b)
    except e:
        return String(e)
    return String("")


# =============================================================================
# Values and NULLs, per type, through scalar_list (every row)
# =============================================================================


def test_int64_values_and_null() raises:
    """MUTANT: skip the INT64 `is_null` check and row 1 reads 11."""
    var xs = scalar_list(_i64(3, 1))
    assert_equal(len(xs), 3)
    assert_equal(xs[0].int_val, 10)
    assert_true(xs[1].is_null())
    assert_true(xs[1].null_type() == DType.int64)
    assert_equal(xs[2].int_val, 12)


def test_int32_values_and_null() raises:
    """MUTANT: build the INT32 value with `from_int64` and the dtype is
    int64."""
    var xs = scalar_list(_i32(2, ArrowType.INT32, 1))
    assert_true(xs[0].dtype == DType.int32)
    assert_equal(xs[0].int_val, 20)
    assert_true(xs[1].is_null())
    assert_true(xs[1].null_type() == DType.int32)


def test_float64_values_and_null() raises:
    """MUTANT: read the float column through the int64 accessor and the
    value is not 0.5."""
    var xs = scalar_list(_f64(2, 0))
    assert_true(xs[0].is_null())
    assert_true(xs[0].null_type() == DType.float64)
    assert_equal(xs[1].float_val, 1.5)


def test_string_values_and_null() raises:
    """A NULL string is an untyped NULL; a value owns its text.
    MUTANT: return `from_string("")` for a NULL and it is not `is_null()`."""
    var xs = scalar_list(_str(3, 2))
    assert_equal(xs[0].string_val, String("s0"))
    assert_equal(xs[1].string_val, String("s1"))
    assert_true(xs[2].is_null())


def test_bool_values_and_null() raises:
    """MUTANT: skip the BOOL `is_null` check and row 1 reads False."""
    var xs = scalar_list(_bool(3, 1))
    assert_true(xs[0].bool_val)
    assert_true(xs[1].is_null())
    assert_true(xs[1].null_type() == DType.bool)
    assert_true(xs[2].bool_val)


def test_date32_values_and_null() raises:
    """DATE32 reads its int32 storage and returns an int32 scalar.
    MUTANT: drop the DATE32 arm and this raises "unsupported"."""
    var xs = scalar_list(_i32(2, ArrowType.DATE32, 0))
    assert_true(xs[0].is_null())
    assert_true(xs[0].null_type() == DType.int32)
    assert_equal(xs[1].int_val, 21)


def test_an_unsupported_type_raises_and_names_it() raises:
    """MUTANT: return a NULL for an unknown type and this does not raise."""
    var msg = _raises_list(_u8(1))
    assert_true("scalar: unsupported arrow_type" in msg, msg)
    assert_true("supported: INT64/INT32/FLOAT64/STRING/BOOL/DATE32" in msg, msg)


# =============================================================================
# scalar: the shape rules
# =============================================================================


def test_scalar_reads_the_one_row() raises:
    """MUTANT: read row 0 of a different column and this fails."""
    var s = scalar(_i64(1))
    assert_equal(s.int_val, 10)


def test_scalar_refuses_more_than_one_column_or_row() raises:
    """MUTANT: `n_rows > 2` lets a two-row batch through."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].allocate(1)))
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].allocate(1)))
    var two = bb.build(sb.build())
    var msg = _raises_scalar(two)
    assert_true("scalar: expected 1 column, got 2" in msg, msg)
    msg = _raises_scalar(_i64(2))
    assert_true("scalar: expected 1 row, got 2" in msg, msg)


def test_an_empty_batch_is_a_typed_null_per_type() raises:
    """Zero rows give a NULL of the column's dtype: INT64, INT32 and DATE32
    (int32), FLOAT64, BOOL, and untyped for anything else.
    MUTANT: map DATE32 to the untyped NULL and the second DATE32 assert
    fails."""
    var s = scalar(_i64(0))
    assert_true(s.is_null() and s.null_type() == DType.int64)
    s = scalar(_i32(0, ArrowType.INT32))
    assert_true(s.is_null() and s.null_type() == DType.int32)
    s = scalar(_i32(0, ArrowType.DATE32))
    assert_true(s.is_null() and s.null_type() == DType.int32)
    s = scalar(_f64(0))
    assert_true(s.is_null() and s.null_type() == DType.float64)
    s = scalar(_bool(0))
    assert_true(s.is_null() and s.null_type() == DType.bool)
    s = scalar(_str(0))
    assert_true(s.is_null())
    assert_false(s.null_type() == DType.int64)


# =============================================================================
# scalar_list: the shape rules
# =============================================================================


def test_scalar_list_refuses_a_second_column_and_accepts_zero_rows() raises:
    """MUTANT: reserve and append one entry for an empty batch and the empty
    list has a length of 1."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].allocate(1)))
    bb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].allocate(1)))
    var msg = _raises_list(bb.build(sb.build()))
    assert_true("scalar_list: expected 1 column, got 2" in msg, msg)
    var xs = scalar_list(_i64(0))
    assert_equal(len(xs), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
