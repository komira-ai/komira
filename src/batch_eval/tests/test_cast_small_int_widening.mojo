# =============================================================================
# CAST of a small integer column to a wider integer or a float: exact, NULL kept
# =============================================================================
#
# UNION ALL widens a branch column by casting it to the common type, so the
# column evaluator's cast must serve every widening of INT8, INT16, UINT8,
# UINT16, UINT32 and UINT64, keep each value exactly (the minimum and maximum
# of the source type included) and keep a NULL a NULL. Expected values are
# written out here, never read back from the engine.
#
# What each test proves:
#   * test_int8_widens: INT8 -> INT16, INT32, INT64, FLOAT32, FLOAT64 keep -128,
#     127, 0 and a NULL, and the result carries the target's Arrow type.
#   * test_int16_widens: the same for INT16 -> INT32, INT64, FLOAT32, FLOAT64.
#   * test_uint8_widens: UINT8 -> INT16, INT32, INT64, UINT16, UINT32, UINT64,
#     FLOAT32, FLOAT64 keep 0, 255 and a NULL (255 is not read as -1).
#   * test_uint16_widens: UINT16 -> INT32, INT64, UINT32, UINT64, FLOAT32,
#     FLOAT64 keep 0, 65535 and a NULL.
#   * test_uint32_widens: UINT32 -> INT64, UINT64, FLOAT32, FLOAT64 keep 0,
#     4294967295 and a NULL (4294967295 is not read as -1).
#   * test_uint64_widens_to_floats: UINT64 -> FLOAT32, FLOAT64 keep 0, a small
#     value and a NULL, and 2^64 - 1 becomes 2^64 (the nearest float).
#   * test_a_narrowing_or_sign_change_is_still_refused: INT16 -> INT8,
#     INT16 -> UINT16 and UINT8 -> INT8 raise the unsupported-cast error.

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from batch_eval.eval_column import _eval_column_expr
from plan_expr.expr import Expr


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


def _cast(ref batch: RecordBatch, to: ArrowType) raises -> Column[HeapRegion]:
    return _eval_column_expr(Expr.cast_to_arrow(Expr.col_ref("a"), to), batch)


def _check[
    src: DType, dst: DType
](
    src_at: ArrowType,
    dst_at: ArrowType,
    vals: List[Scalar[src]],
    want: List[Scalar[dst]],
    null_at: Int,
) raises:
    var label = String(src_at) + " -> " + String(dst_at)
    var batch = _batch[src](src_at, vals, null_at)
    var col = _cast(batch, dst_at)
    assert_true(col.arrow_type == dst_at, label + ": wrong result type")
    assert_equal(col.length, len(vals))
    var out = col.as_primitive[dst]()
    for i in range(len(vals)):
        if i == null_at:
            assert_true(out.is_null(i), label + ": a NULL became a value")
        else:
            assert_true(
                out.get(i) == want[i],
                label + ": row " + String(i) + " differs",
            )


def test_int8_widens() raises:
    var v = List[Scalar[DType.int8]](Int8(-128), Int8(127), Int8(0), Int8(5))
    _check[DType.int8, DType.int16](
        ArrowType.INT8, ArrowType.INT16,
        v, [Int16(-128), Int16(127), Int16(0), Int16(5)], 3,
    )
    _check[DType.int8, DType.int32](
        ArrowType.INT8, ArrowType.INT32,
        v, [Int32(-128), Int32(127), Int32(0), Int32(5)], 3,
    )
    _check[DType.int8, DType.int64](
        ArrowType.INT8, ArrowType.INT64,
        v, [Int64(-128), Int64(127), Int64(0), Int64(5)], 3,
    )
    _check[DType.int8, DType.float32](
        ArrowType.INT8, ArrowType.FLOAT32,
        v, [Float32(-128.0), Float32(127.0), Float32(0.0), Float32(5.0)], 3,
    )
    _check[DType.int8, DType.float64](
        ArrowType.INT8, ArrowType.FLOAT64,
        v, [Float64(-128.0), Float64(127.0), Float64(0.0), Float64(5.0)], 3,
    )


def test_int16_widens() raises:
    var v = List[Scalar[DType.int16]](
        Int16(-32768), Int16(32767), Int16(0), Int16(5)
    )
    _check[DType.int16, DType.int32](
        ArrowType.INT16, ArrowType.INT32,
        v, [Int32(-32768), Int32(32767), Int32(0), Int32(5)], 3,
    )
    _check[DType.int16, DType.int64](
        ArrowType.INT16, ArrowType.INT64,
        v, [Int64(-32768), Int64(32767), Int64(0), Int64(5)], 3,
    )
    _check[DType.int16, DType.float32](
        ArrowType.INT16, ArrowType.FLOAT32,
        v, [Float32(-32768.0), Float32(32767.0), Float32(0.0), Float32(5.0)], 3,
    )
    _check[DType.int16, DType.float64](
        ArrowType.INT16, ArrowType.FLOAT64,
        v, [Float64(-32768.0), Float64(32767.0), Float64(0.0), Float64(5.0)], 3,
    )


def test_uint8_widens() raises:
    var v = List[Scalar[DType.uint8]](UInt8(0), UInt8(255), UInt8(128), UInt8(5))
    _check[DType.uint8, DType.int16](
        ArrowType.UINT8, ArrowType.INT16,
        v, [Int16(0), Int16(255), Int16(128), Int16(5)], 3,
    )
    _check[DType.uint8, DType.int32](
        ArrowType.UINT8, ArrowType.INT32,
        v, [Int32(0), Int32(255), Int32(128), Int32(5)], 3,
    )
    _check[DType.uint8, DType.int64](
        ArrowType.UINT8, ArrowType.INT64,
        v, [Int64(0), Int64(255), Int64(128), Int64(5)], 3,
    )
    _check[DType.uint8, DType.uint16](
        ArrowType.UINT8, ArrowType.UINT16,
        v, [UInt16(0), UInt16(255), UInt16(128), UInt16(5)], 3,
    )
    _check[DType.uint8, DType.uint32](
        ArrowType.UINT8, ArrowType.UINT32,
        v, [UInt32(0), UInt32(255), UInt32(128), UInt32(5)], 3,
    )
    _check[DType.uint8, DType.uint64](
        ArrowType.UINT8, ArrowType.UINT64,
        v, [UInt64(0), UInt64(255), UInt64(128), UInt64(5)], 3,
    )
    _check[DType.uint8, DType.float32](
        ArrowType.UINT8, ArrowType.FLOAT32,
        v, [Float32(0.0), Float32(255.0), Float32(128.0), Float32(5.0)], 3,
    )
    _check[DType.uint8, DType.float64](
        ArrowType.UINT8, ArrowType.FLOAT64,
        v, [Float64(0.0), Float64(255.0), Float64(128.0), Float64(5.0)], 3,
    )


def test_uint16_widens() raises:
    var v = List[Scalar[DType.uint16]](
        UInt16(0), UInt16(65535), UInt16(32768), UInt16(5)
    )
    _check[DType.uint16, DType.int32](
        ArrowType.UINT16, ArrowType.INT32,
        v, [Int32(0), Int32(65535), Int32(32768), Int32(5)], 3,
    )
    _check[DType.uint16, DType.int64](
        ArrowType.UINT16, ArrowType.INT64,
        v, [Int64(0), Int64(65535), Int64(32768), Int64(5)], 3,
    )
    _check[DType.uint16, DType.uint32](
        ArrowType.UINT16, ArrowType.UINT32,
        v, [UInt32(0), UInt32(65535), UInt32(32768), UInt32(5)], 3,
    )
    _check[DType.uint16, DType.uint64](
        ArrowType.UINT16, ArrowType.UINT64,
        v, [UInt64(0), UInt64(65535), UInt64(32768), UInt64(5)], 3,
    )
    _check[DType.uint16, DType.float32](
        ArrowType.UINT16, ArrowType.FLOAT32,
        v, [Float32(0.0), Float32(65535.0), Float32(32768.0), Float32(5.0)], 3,
    )
    _check[DType.uint16, DType.float64](
        ArrowType.UINT16, ArrowType.FLOAT64,
        v, [Float64(0.0), Float64(65535.0), Float64(32768.0), Float64(5.0)], 3,
    )


def test_uint32_widens() raises:
    var v = List[Scalar[DType.uint32]](
        UInt32(0), UInt32(4294967295), UInt32(2147483648), UInt32(5)
    )
    _check[DType.uint32, DType.int64](
        ArrowType.UINT32, ArrowType.INT64,
        v, [Int64(0), Int64(4294967295), Int64(2147483648), Int64(5)], 3,
    )
    _check[DType.uint32, DType.uint64](
        ArrowType.UINT32, ArrowType.UINT64,
        v, [UInt64(0), UInt64(4294967295), UInt64(2147483648), UInt64(5)], 3,
    )
    # 4294967295 is not representable in a float32: it rounds to 2^32.
    _check[DType.uint32, DType.float32](
        ArrowType.UINT32, ArrowType.FLOAT32,
        v, [Float32(0.0), Float32(4294967296.0), Float32(2147483648.0), Float32(5.0)], 3,
    )
    _check[DType.uint32, DType.float64](
        ArrowType.UINT32, ArrowType.FLOAT64,
        v, [Float64(0.0), Float64(4294967295.0), Float64(2147483648.0), Float64(5.0)], 3,
    )


def test_uint64_widens_to_floats() raises:
    var v = List[Scalar[DType.uint64]](
        UInt64(0), UInt64.MAX, UInt64(9223372036854775808), UInt64(5)
    )
    # 2^64 - 1 rounds to 2^64 in both float widths; 2^63 is exact.
    _check[DType.uint64, DType.float32](
        ArrowType.UINT64, ArrowType.FLOAT32,
        v,
        [Float32(0.0), Float32(18446744073709551616.0), Float32(9223372036854775808.0), Float32(5.0)],
        3,
    )
    _check[DType.uint64, DType.float64](
        ArrowType.UINT64, ArrowType.FLOAT64,
        v,
        [Float64(0.0), Float64(18446744073709551616.0), Float64(9223372036854775808.0), Float64(5.0)],
        3,
    )


def test_a_narrowing_or_sign_change_is_still_refused() raises:
    var b16 = _batch[DType.int16](ArrowType.INT16, [Int16(1), Int16(2)], -1)
    with assert_raises(contains="unsupported EXPR_CAST"):
        _ = _cast(b16, ArrowType.INT8)
    with assert_raises(contains="unsupported EXPR_CAST"):
        _ = _cast(b16, ArrowType.UINT16)
    var b8 = _batch[DType.uint8](ArrowType.UINT8, [UInt8(1), UInt8(2)], -1)
    with assert_raises(contains="unsupported EXPR_CAST"):
        _ = _cast(b8, ArrowType.INT8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
