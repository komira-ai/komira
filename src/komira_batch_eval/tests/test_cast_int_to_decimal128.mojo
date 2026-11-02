# =============================================================================
# CAST(<integer column> AS DECIMAL(38, 0)): every integer width, exact
# =============================================================================
#
# The SQL door widens an integer `sum()` by casting its argument to
# DECIMAL(38, 0) (`komira_sql`), so the column evaluator's cast must accept every
# integer column an aggregate can read, keep every value exactly, and keep a
# NULL a NULL. The expected values are integers written out here, never read
# back from the engine.
#
# What each test proves, and the defect it would catch:
#   * test_every_integer_width_casts_to_decimal_38_0: INT8, INT16, INT32, INT64,
#     UINT8, UINT16, UINT32 and UINT64 columns holding their MIN and MAX (and
#     0 and a NULL) cast to DECIMAL(38, 0) with the same values. Catches a
#     width the evaluator refuses ("unsupported source type"), a sign error on
#     an unsigned column (UINT32 above 2^31, UINT64 above 2^63 read as
#     negative), and a NULL that becomes 0.
#   * test_a_boolean_column_casts_to_zero_and_one: TRUE, FALSE and NULL become 1,
#     0 and NULL. Catches a BOOL column the evaluator refuses.
#   * test_uint64_max_stays_exact: 2^64 - 1 is 18446744073709551615, not -1 and
#     not INT64's maximum. Catches a cast routed through an Int64.
#   * test_a_scaled_cast_refuses_a_value_with_too_many_digits: an integer that
#     needs more than the target's precision is refused, not wrapped. Catches a
#     cast that keeps the low digits.

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_batch_eval.eval_column import _eval_column_expr
from komira_plan_expr.expr import Expr
from komira_scalar_arithmetic.decimal_arith import I128


def _batch[
    dt: DType
](at: ArrowType, vals: List[Scalar[dt]], null_at: Int) raises -> RecordBatch:
    """One nullable column `a` of `vals`, the row `null_at` NULL (-1: none)."""
    var arr = PrimitiveArray[dt].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    if null_at >= 0:
        arr._set_null(null_at)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), at, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[dt](arr^))
    return rb.build(sb.build())


def _cast(ref batch: RecordBatch, p: Int, s: Int) raises -> Column[HeapRegion]:
    return _eval_column_expr(
        Expr.cast_to_decimal(Expr.col_ref("a"), p, s), batch
    )


def _check[
    dt: DType
](at: ArrowType, vals: List[Scalar[dt]], null_at: Int) raises:
    var batch = _batch[dt](at, vals, null_at)
    var col = _cast(batch, 38, 0)
    assert_true(col.arrow_type == ArrowType.DECIMAL128, String(at))
    assert_equal(col.decimal_precision(), 38)
    assert_equal(col.decimal_scale(), 0)
    var out = col.as_decimal128()
    for i in range(len(vals)):
        if i == null_at:
            assert_true(out.is_null(i), String(at) + ": a NULL became a value")
        else:
            assert_true(
                out.get_i128(i) == vals[i].cast[DType.int128](),
                String(at) + ": row " + String(i) + " differs",
            )


def test_every_integer_width_casts_to_decimal_38_0() raises:
    _check[DType.int8](
        ArrowType.INT8,
        [Int8(-128), Int8(127), Int8(0), Int8(5)],
        3,
    )
    _check[DType.int16](
        ArrowType.INT16,
        [Int16(-32768), Int16(32767), Int16(0), Int16(5)],
        3,
    )
    _check[DType.int32](
        ArrowType.INT32,
        [Int32(-2147483648), Int32(2147483647), Int32(0), Int32(5)],
        3,
    )
    _check[DType.int64](
        ArrowType.INT64,
        [Int64.MIN, Int64.MAX, Int64(0), Int64(5)],
        3,
    )
    _check[DType.uint8](
        ArrowType.UINT8,
        [UInt8(0), UInt8(255), UInt8(128), UInt8(5)],
        3,
    )
    _check[DType.uint16](
        ArrowType.UINT16,
        [UInt16(0), UInt16(65535), UInt16(32768), UInt16(5)],
        3,
    )
    _check[DType.uint32](
        ArrowType.UINT32,
        [UInt32(0), UInt32(4294967295), UInt32(2147483648), UInt32(5)],
        3,
    )
    _check[DType.uint64](
        ArrowType.UINT64,
        [UInt64(0), UInt64.MAX, UInt64(9223372036854775808), UInt64(5)],
        3,
    )


def test_a_boolean_column_casts_to_zero_and_one() raises:
    # TRUE is 1, FALSE is 0 (DuckDB's sum(BOOLEAN) counts), a NULL stays NULL.
    var n = 4
    var arr = BooleanArray.allocate_nullable(n)
    arr.set(0, True)
    arr.set(1, False)
    arr.set(2, True)
    arr._set_null(3)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.BOOL, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_boolean(arr^))
    var batch = rb.build(sb.build())
    var out = _cast(batch, 38, 0).as_decimal128()
    assert_true(out.get_i128(0) == I128(1))
    assert_true(out.get_i128(1) == I128(0))
    assert_true(out.get_i128(2) == I128(1))
    assert_true(out.is_null(3), "a NULL became a value")


def test_uint64_max_stays_exact() raises:
    var batch = _batch[DType.uint64](
        ArrowType.UINT64, [UInt64.MAX, UInt64.MAX], -1
    )
    var out = _cast(batch, 38, 0).as_decimal128()
    # 2^64 - 1 = 18446744073709551615.
    var want = I128(4294967296) * I128(4294967296) - I128(1)
    assert_true(out.get_i128(0) == want)
    assert_true(out.get_i128(1) == want)


def test_a_scaled_cast_refuses_a_value_with_too_many_digits() raises:
    # DECIMAL(5, 2) holds integers up to 999: 1000 needs six digits at scale 2.
    var batch = _batch[DType.int16](ArrowType.INT16, [Int16(999), Int16(1000)], -1)
    with assert_raises(contains="does not fit"):
        _ = _cast(batch, 5, 2)
    var ok = _batch[DType.int16](ArrowType.INT16, [Int16(999), Int16(-999)], -1)
    var out = _cast(ok, 5, 2).as_decimal128()
    assert_true(out.get_i128(0) == I128(99900))
    assert_true(out.get_i128(1) == I128(-99900))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
