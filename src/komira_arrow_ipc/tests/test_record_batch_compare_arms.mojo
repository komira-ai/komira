# =============================================================================
# test_record_batch_compare_arms.mojo: the comparator's arms that
# test_record_batch_compare.mojo leaves out
# =============================================================================
#
# Schema: nullability and DECIMAL128 precision/scale. Cells: a value
# divergence in every integer width other than INT64 (each dtype arm of the
# dispatch must reach the comparison), FLOAT32 and FLOAT16 compared in the
# bit domain (+0.0 and -0.0 differ, equal bits are equal), validity and value
# divergences of BOOL and STRING columns, and the explicit "does not yet
# support" reason for a column type outside the dispatch. Each divergence
# test asserts the reason names its column and row, so an arm that compared
# the wrong cells or the wrong column would fail.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, SchemaBuilder, RecordBatch
from komira_arrow.schema import RecordBatchBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.decimal_array import Decimal128Array
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.record_batch_compare import (
    RecordBatchDiff,
    record_batch_diff,
    record_batch_byte_equal,
)


def _one_column(
    var col: Column[HeapRegion], var field: Field
) raises -> RecordBatch:
    var b = RecordBatchBuilder()
    b.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(field^)
    return b.build(sb.build())


def _prim[
    dtype: DType
](t: ArrowType, v0: Scalar[dtype], v1: Scalar[dtype]) raises -> RecordBatch:
    """A non-nullable two-row column `p` of `dtype` holding (v0, v1)."""
    var vals = List[Scalar[dtype]]()
    vals.append(v0)
    vals.append(v1)
    var arr = PrimitiveArray[dtype].from_list(vals)
    return _one_column(Column.from_primitive[dtype](arr^), Field("p", t, False))


def _check_value_differs[
    dtype: DType
](t: ArrowType, same: Scalar[dtype], x: Scalar[dtype], y: Scalar[dtype]) raises:
    """Row 0 equal in both, row 1 `x` vs `y`: the diff names row 1 of column
    0; the batches with row 1 equal compare equal."""
    var a = _prim[dtype](t, same, x)
    var b = _prim[dtype](t, same, y)
    var d = record_batch_diff(a, b)
    assert_false(d.equal, String(t))
    assert_true("value differs at column 0 ('p') row 1" in d.reason, d.reason)
    assert_true(record_batch_byte_equal(a, _prim[dtype](t, same, x)), String(t))


def test_every_integer_width_compares_its_cells() raises:
    _check_value_differs[DType.int8](ArrowType.INT8, 5, -1, 1)
    _check_value_differs[DType.int16](ArrowType.INT16, 5, 300, 301)
    _check_value_differs[DType.uint8](ArrowType.UINT8, 5, 255, 254)
    _check_value_differs[DType.uint16](ArrowType.UINT16, 5, 65535, 0)
    _check_value_differs[DType.uint32](ArrowType.UINT32, 5, 4000000000, 7)
    _check_value_differs[DType.uint64](ArrowType.UINT64, 5, 1 << 63, 1)


def test_float32_and_float16_compare_bits() raises:
    """+0.0 and -0.0 are equal as numbers and differ as bits: the
    comparator reports them, naming the width."""
    var d32 = record_batch_diff(
        _prim[DType.float32](ArrowType.FLOAT32, 1.5, 0.0),
        _prim[DType.float32](ArrowType.FLOAT32, 1.5, -0.0),
    )
    assert_false(d32.equal)
    assert_true(
        "float32 value differs (bit-exact) at column 0 ('p') row 1"
        in d32.reason,
        d32.reason,
    )
    assert_true(
        record_batch_byte_equal(
            _prim[DType.float32](ArrowType.FLOAT32, 1.5, -0.0),
            _prim[DType.float32](ArrowType.FLOAT32, 1.5, -0.0),
        )
    )
    var d16 = record_batch_diff(
        _prim[DType.float16](ArrowType.FLOAT16, 1.5, 0.0),
        _prim[DType.float16](ArrowType.FLOAT16, 1.5, -0.0),
    )
    assert_false(d16.equal)
    assert_true(
        "float16 value differs (bit-exact) at column 0 ('p') row 1"
        in d16.reason,
        d16.reason,
    )
    assert_true(
        record_batch_byte_equal(
            _prim[DType.float16](ArrowType.FLOAT16, 1.5, 2.0),
            _prim[DType.float16](ArrowType.FLOAT16, 1.5, 2.0),
        )
    )


def test_nullability_differs() raises:
    var vals = List[Int64]()
    vals.append(1)
    var a = _one_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals)),
        Field("n", ArrowType.INT64, False),
    )
    var b = _one_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals)),
        Field("n", ArrowType.INT64, True),
    )
    var d = record_batch_diff(a, b)
    assert_false(d.equal)
    assert_equal(
        d.reason, "nullability differs at column 0 ('n'): A=False B=True"
    )


def _dec(precision: Int, scale: Int) raises -> RecordBatch:
    var vals = List[SIMD[DType.int128, 1]]()
    vals.append(SIMD[DType.int128, 1](12345))
    var arr = Decimal128Array[HeapRegion].from_i128_list(vals, precision, scale)
    return _one_column(
        Column.from_decimal128(arr^),
        Field.decimal128("d", precision, scale, False),
    )


def test_decimal_precision_and_scale_differ() raises:
    var dp = record_batch_diff(_dec(10, 2), _dec(12, 2))
    assert_false(dp.equal)
    assert_equal(
        dp.reason,
        "decimal precision/scale differs at column 0 ('d'): A=(10,2) B=(12,2)",
    )
    var ds = record_batch_diff(_dec(10, 2), _dec(10, 3))
    assert_false(ds.equal)
    assert_equal(
        ds.reason,
        "decimal precision/scale differs at column 0 ('d'): A=(10,2) B=(10,3)",
    )


def test_a_type_outside_the_dispatch_is_reported_not_passed() raises:
    """Two identical DECIMAL128 columns: the schemas agree, and the cell
    compare refuses to call them equal because it cannot compare them."""
    var d = record_batch_diff(_dec(10, 2), _dec(10, 2))
    assert_false(d.equal)
    assert_true(
        "column 0 ('d') has Arrow type" in d.reason, d.reason
    )
    assert_true("does not yet support" in d.reason, d.reason)
    assert_true("_diff_column" in d.reason, d.reason)


def _bools(v0: Bool, v1: Bool, null_at: Int) raises -> RecordBatch:
    """A nullable BOOL column `b` of (v0, v1), row `null_at` null (-1:
    none)."""
    var arr = BooleanArray.allocate_nullable(2)
    arr.set(0, v0)
    arr.set(1, v1)
    if null_at >= 0:
        arr._set_null(null_at)
    return _one_column(Column.from_boolean(arr^), Field("b", ArrowType.BOOL, True))


def test_bool_validity_and_value_differ() raises:
    var dv = record_batch_diff(_bools(True, False, 1), _bools(True, False, -1))
    assert_false(dv.equal)
    assert_equal(
        dv.reason,
        "validity differs at column 0 ('b') row 1: A.is_null=True"
        " B.is_null=False",
    )
    var dval = record_batch_diff(
        _bools(True, False, -1), _bools(True, True, -1)
    )
    assert_false(dval.equal)
    assert_equal(
        dval.reason, "bool value differs at column 0 ('b') row 1: A=False B=True"
    )
    # A null row's value is not compared.
    assert_true(
        record_batch_byte_equal(_bools(True, False, 1), _bools(True, True, 1))
    )


def _strs(null_at: Int) raises -> RecordBatch:
    var vals = List[String]()
    vals.append(String("a"))
    vals.append(String("b"))
    var valid = List[Bool]()
    valid.append(null_at != 0)
    valid.append(null_at != 1)
    var arr = StringArray.from_strings_with_validity(vals, valid)
    return _one_column(
        Column.from_string(arr^), Field("s", ArrowType.STRING, True)
    )


def test_string_validity_differs() raises:
    var d = record_batch_diff(_strs(-1), _strs(1))
    assert_false(d.equal)
    assert_equal(
        d.reason,
        "validity differs at column 0 ('s') row 1: A.is_null=False"
        " B.is_null=True",
    )
    assert_true(record_batch_byte_equal(_strs(0), _strs(0)))


def test_diff_writes_itself() raises:
    assert_equal(
        String(RecordBatchDiff(True, String(""))), "RecordBatchDiff(equal=True)"
    )
    assert_equal(
        String(RecordBatchDiff(False, String("why"))),
        "RecordBatchDiff(equal=False, reason='why')",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_integer_width_compares_its_cells]()
    suite.test[test_float32_and_float16_compare_bits]()
    suite.test[test_nullability_differs]()
    suite.test[test_decimal_precision_and_scale_differ]()
    suite.test[test_a_type_outside_the_dispatch_is_reported_not_passed]()
    suite.test[test_bool_validity_and_value_differ]()
    suite.test[test_string_validity_differs]()
    suite.test[test_diff_writes_itself]()
    suite^.run()
