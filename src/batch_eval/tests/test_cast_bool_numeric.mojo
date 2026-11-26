# =============================================================================
# CAST between BOOLEAN and every fixed-width integer and float type
# =============================================================================
#
# DuckDB answers every one of these pairs and none of them can fail: a
# BOOLEAN becomes 1 or 0, and a number becomes true when it is not zero (NaN
# is true, -0.0 is false). NULL stays NULL both ways, and TRY_CAST answers
# the same as CAST. Expected values are written out here, never read back
# from the engine. They are the answers of the pinned DuckDB release for the
# same casts.
#
# What each test proves:
#   * test_bool_casts_to_every_integer_and_float: BOOLEAN -> INT8, INT16,
#     INT32, INT64, UINT8, UINT16, UINT32, UINT64, FLOAT, DOUBLE gives 1 for
#     true, 0 for false, keeps a NULL a NULL with 0 in its slot, and carries
#     the target's Arrow type.
#   * test_bool_without_nulls_casts_with_no_nulls: a column with no validity
#     bitmap gives a result with no NULL.
#   * test_every_signed_integer_casts_to_bool: INT8..INT64 -> BOOLEAN is
#     true for the minimum, -1, 1 and the maximum, false for 0, NULL for a
#     NULL, and a NULL row carries a false data bit.
#   * test_every_unsigned_integer_casts_to_bool: UINT8..UINT64 -> BOOLEAN is
#     true for 1 and the maximum (not read as -1), false for 0, NULL for NULL.
#   * test_floats_cast_to_bool_nan_true_negative_zero_false: FLOAT and DOUBLE
#     -> BOOLEAN: 0.0 and -0.0 are false; 0.4, NaN, +inf, -inf and the
#     smallest subnormal are true; NULL stays NULL.
#   * test_a_number_without_nulls_casts_to_bool_with_no_nulls: no validity in,
#     no NULL out.
#   * test_empty_input_casts_both_ways: a zero-row column gives a zero-row
#     result of the target type in both directions.
#   * test_all_null_input_stays_all_null_both_ways: every row NULL in, every
#     row NULL out, both directions.
#   * test_try_cast_answers_the_same_as_cast: TRY_CAST(bool AS BIGINT) and
#     TRY_CAST(double AS BOOLEAN) give the CAST answers, NULL included.
#   * test_a_comparison_result_casts_to_an_integer: CAST((a > 1) AS BIGINT)
#     over a computed BOOLEAN child gives 0, 1 and NULL.
#   * test_a_sliced_number_casts_to_bool_from_its_own_rows: a numeric
#     array viewed at an offset, with and without a null mask, casts the
#     rows of its window and their NULLs, not the rows before it.
#   * test_bool_to_bool_is_unchanged: CAST(bool AS BOOLEAN) keeps values and
#     NULLs.
#   * test_bool_to_and_from_a_date_is_still_refused: BOOLEAN -> DATE and
#     DATE -> BOOLEAN still raise the unsupported-cast error by name.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from batch_eval.cast_bool import _numeric_to_bool
from batch_eval.eval_column import _eval_column_expr
from plan_expr.expr import BIN_GT, Expr
from plan_expr.scalar_value import ScalarValue


# Row values of a BOOLEAN fixture: 1 true, 0 false, -1 NULL.
comptime _T = 1
comptime _F = 0
comptime _N = -1


def _bool_batch(ref rows: List[Int]) raises -> RecordBatch:
    """One BOOLEAN column `a`; nullable only when a row is NULL."""
    var b = ColumnBuilder[DType.bool].with_capacity(len(rows))
    for i in range(len(rows)):
        if rows[i] == _N:
            b.append_null()
        else:
            b.append(rows[i] == _T)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.BOOL, True))
    var rb = RecordBatchBuilder()
    rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _num_batch[
    dt: DType
](at: ArrowType, ref vals: List[Scalar[dt]], ref nulls: List[Int]) raises -> RecordBatch:
    """One column `a` of `vals`; the rows in `nulls` are NULL. No validity
    bitmap at all when `nulls` is empty."""
    var arr = PrimitiveArray[dt].allocate(len(vals))
    if len(nulls) > 0:
        arr = PrimitiveArray[dt].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), at, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive_with_arrow_type[dt](arr^, at))
    return rb.build(sb.build())


def _cast(ref batch: RecordBatch, to: ArrowType) raises -> Column[HeapRegion]:
    return _eval_column_expr(Expr.cast_to_arrow(Expr.col_ref("a"), to), batch)


def _check_from_bool[dst: DType](dst_at: ArrowType) raises:
    var label = String("bool -> ") + String(dst_at)
    var rows: List[Int] = [_T, _F, _N, _T, _F]
    var batch = _bool_batch(rows)
    var col = _cast(batch, dst_at)
    assert_true(col.arrow_type == dst_at, label + ": wrong result type")
    assert_equal(col.length(), 5)
    assert_equal(col.null_count(), 1, label)
    var out = col.as_primitive[dst]()
    var want: List[Scalar[dst]] = [
        Scalar[dst](1), Scalar[dst](0), Scalar[dst](0), Scalar[dst](1), Scalar[dst](0)
    ]
    for i in range(5):
        assert_true(out.get(i) == want[i], label + ": row " + String(i) + " differs")
        assert_equal(out.is_null(i), i == 2, label + ": null mask row " + String(i))


def test_bool_casts_to_every_integer_and_float() raises:
    _check_from_bool[DType.int8](ArrowType.INT8)
    _check_from_bool[DType.int16](ArrowType.INT16)
    _check_from_bool[DType.int32](ArrowType.INT32)
    _check_from_bool[DType.int64](ArrowType.INT64)
    _check_from_bool[DType.uint8](ArrowType.UINT8)
    _check_from_bool[DType.uint16](ArrowType.UINT16)
    _check_from_bool[DType.uint32](ArrowType.UINT32)
    _check_from_bool[DType.uint64](ArrowType.UINT64)
    _check_from_bool[DType.float32](ArrowType.FLOAT32)
    _check_from_bool[DType.float64](ArrowType.FLOAT64)


def test_bool_without_nulls_casts_with_no_nulls() raises:
    var rows: List[Int] = [_T, _F, _T]
    var batch = _bool_batch(rows)
    var col = _cast(batch, ArrowType.INT64)
    assert_equal(col.null_count(), 0)
    var out = col.as_primitive[DType.int64]()
    assert_equal(out.get(0), Int64(1))
    assert_equal(out.get(1), Int64(0))
    assert_equal(out.get(2), Int64(1))
    assert_true(not out.is_null(0) and not out.is_null(1) and not out.is_null(2))


def _check_to_bool[
    src: DType
](
    src_at: ArrowType,
    vals: List[Scalar[src]],
    want: List[Bool],
    nulls: List[Int],
) raises:
    var label = String(src_at) + " -> bool"
    var batch = _num_batch[src](src_at, vals, nulls)
    var col = _cast(batch, ArrowType.BOOL)
    assert_true(col.arrow_type == ArrowType.BOOL, label + ": wrong result type")
    assert_equal(col.length(), len(vals))
    assert_equal(col.null_count(), len(nulls), label)
    var out = col.as_boolean()
    for i in range(len(vals)):
        var is_null = False
        for j in range(len(nulls)):
            if nulls[j] == i:
                is_null = True
        assert_equal(out.is_null(i), is_null, label + ": null mask row " + String(i))
        if is_null:
            assert_true(not out.get(i), label + ": a NULL row carries a true bit")
        else:
            assert_equal(out.get(i), want[i], label + ": row " + String(i) + " differs")


def test_every_signed_integer_casts_to_bool() raises:
    # min, -1, 0, 1, max, and a NULL whose slot holds a non-zero value.
    var want: List[Bool] = [True, True, False, True, True, False]
    var nulls: List[Int] = [5]
    _check_to_bool[DType.int8](
        ArrowType.INT8, [Int8.MIN, Int8(-1), Int8(0), Int8(1), Int8.MAX, Int8(7)], want, nulls
    )
    _check_to_bool[DType.int16](
        ArrowType.INT16, [Int16.MIN, Int16(-1), Int16(0), Int16(1), Int16.MAX, Int16(7)], want, nulls
    )
    _check_to_bool[DType.int32](
        ArrowType.INT32, [Int32.MIN, Int32(-1), Int32(0), Int32(1), Int32.MAX, Int32(7)], want, nulls
    )
    _check_to_bool[DType.int64](
        ArrowType.INT64, [Int64.MIN, Int64(-1), Int64(0), Int64(1), Int64.MAX, Int64(7)], want, nulls
    )


def test_every_unsigned_integer_casts_to_bool() raises:
    # 0, 1, max, and a NULL whose slot holds a non-zero value.
    var want: List[Bool] = [False, True, True, False]
    var nulls: List[Int] = [3]
    _check_to_bool[DType.uint8](
        ArrowType.UINT8, [UInt8(0), UInt8(1), UInt8.MAX, UInt8(9)], want, nulls
    )
    _check_to_bool[DType.uint16](
        ArrowType.UINT16, [UInt16(0), UInt16(1), UInt16.MAX, UInt16(9)], want, nulls
    )
    _check_to_bool[DType.uint32](
        ArrowType.UINT32, [UInt32(0), UInt32(1), UInt32.MAX, UInt32(9)], want, nulls
    )
    _check_to_bool[DType.uint64](
        ArrowType.UINT64, [UInt64(0), UInt64(1), UInt64.MAX, UInt64(9)], want, nulls
    )


def test_floats_cast_to_bool_nan_true_negative_zero_false() raises:
    var zero64 = Float64(0.0)
    var neg_zero64 = zero64 * Float64(-1.0)
    var nan64 = zero64 / zero64
    var inf64 = Float64(1.0) / zero64
    # The smallest subnormal of each width, from its bit pattern.
    var tiny64 = bitcast[DType.float64](UInt64(1))
    # The fixture itself: -0.0 carries the sign, the subnormal is above 0.
    assert_true(Float64(1.0) / neg_zero64 < 0.0)
    assert_true(tiny64 > 0.0)
    # 0.0, -0.0, 0.4, NaN, +inf, -inf, smallest subnormal, NULL over NaN.
    var want: List[Bool] = [False, False, True, True, True, True, True, False]
    var nulls: List[Int] = [7]
    _check_to_bool[DType.float64](
        ArrowType.FLOAT64,
        [zero64, neg_zero64, Float64(0.4), nan64, inf64, -inf64, tiny64, nan64],
        want,
        nulls,
    )
    var zero32 = Float32(0.0)
    var neg_zero32 = zero32 * Float32(-1.0)
    var nan32 = zero32 / zero32
    var inf32 = Float32(1.0) / zero32
    var tiny32 = bitcast[DType.float32](UInt32(1))
    assert_true(Float32(1.0) / neg_zero32 < 0.0)
    assert_true(tiny32 > 0.0)
    _check_to_bool[DType.float32](
        ArrowType.FLOAT32,
        [zero32, neg_zero32, Float32(0.4), nan32, inf32, -inf32, tiny32, nan32],
        want,
        nulls,
    )


def test_a_number_without_nulls_casts_to_bool_with_no_nulls() raises:
    var vals: List[Int64] = [Int64(0), Int64(3)]
    var none: List[Int] = []
    var batch = _num_batch[DType.int64](ArrowType.INT64, vals, none)
    var col = _cast(batch, ArrowType.BOOL)
    assert_equal(col.null_count(), 0)
    var out = col.as_boolean()
    assert_true(not out.get(0))
    assert_true(out.get(1))
    assert_true(not out.is_null(0) and not out.is_null(1))


def test_empty_input_casts_both_ways() raises:
    var no_rows: List[Int] = []
    var bools = _bool_batch(no_rows)
    var as_int = _cast(bools, ArrowType.INT32)
    assert_true(as_int.arrow_type == ArrowType.INT32)
    assert_equal(as_int.length(), 0)
    var as_double = _cast(bools, ArrowType.FLOAT64)
    assert_true(as_double.arrow_type == ArrowType.FLOAT64)
    assert_equal(as_double.length(), 0)
    var no_vals: List[Float64] = []
    var nums = _num_batch[DType.float64](ArrowType.FLOAT64, no_vals, no_rows)
    var as_bool = _cast(nums, ArrowType.BOOL)
    assert_true(as_bool.arrow_type == ArrowType.BOOL)
    assert_equal(as_bool.length(), 0)


def test_all_null_input_stays_all_null_both_ways() raises:
    var rows: List[Int] = [_N, _N, _N]
    var bools = _bool_batch(rows)
    var as_int = _cast(bools, ArrowType.INT64)
    assert_equal(as_int.null_count(), 3)
    var ints = as_int.as_primitive[DType.int64]()
    for i in range(3):
        assert_true(ints.is_null(i))
    var vals: List[Int32] = [Int32(1), Int32(0), Int32(-4)]
    var nulls: List[Int] = [0, 1, 2]
    var nums = _num_batch[DType.int32](ArrowType.INT32, vals, nulls)
    var as_bool = _cast(nums, ArrowType.BOOL)
    assert_equal(as_bool.null_count(), 3)
    var out = as_bool.as_boolean()
    for i in range(3):
        assert_true(out.is_null(i))
        assert_true(not out.get(i))


def test_try_cast_answers_the_same_as_cast() raises:
    var rows: List[Int] = [_T, _N, _F]
    var bools = _bool_batch(rows)
    var ints = _eval_column_expr(
        Expr.try_cast(Expr.col_ref("a"), DType.int64), bools
    ).as_primitive[DType.int64]()
    assert_equal(ints.get(0), Int64(1))
    assert_true(ints.is_null(1))
    assert_equal(ints.get(2), Int64(0))
    var zero = Float64(0.0)
    var vals: List[Float64] = [zero / zero, Float64(2.0), zero]
    var nulls: List[Int] = [1]
    var nums = _num_batch[DType.float64](ArrowType.FLOAT64, vals, nulls)
    var col = _eval_column_expr(Expr.try_cast(Expr.col_ref("a"), DType.bool), nums)
    assert_true(col.arrow_type == ArrowType.BOOL)
    var out = col.as_boolean()
    assert_true(out.get(0))
    assert_true(out.is_null(1))
    assert_true(not out.get(2))


def test_a_comparison_result_casts_to_an_integer() raises:
    var vals: List[Int64] = [Int64(0), Int64(5), Int64(9)]
    var nulls: List[Int] = [2]
    var batch = _num_batch[DType.int64](ArrowType.INT64, vals, nulls)
    var gt = Expr.binary(
        BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1))
    )
    var col = _eval_column_expr(Expr.cast(gt^, DType.int64), batch)
    assert_true(col.arrow_type == ArrowType.INT64)
    var out = col.as_primitive[DType.int64]()
    assert_equal(out.get(0), Int64(0))
    assert_equal(out.get(1), Int64(1))
    assert_true(out.is_null(2))


def test_a_sliced_number_casts_to_bool_from_its_own_rows() raises:
    # Rows 0..5 are 0, 0, 7, 0, 0, 3 with row 1 and row 4 NULL; the window
    # [2, 6) is 7, 0, NULL, 3.
    var vals: List[Int64] = [Int64(0), Int64(0), Int64(7), Int64(0), Int64(0), Int64(3)]
    var nullable = PrimitiveArray[DType.int64].allocate_nullable(6)
    var plain = PrimitiveArray[DType.int64].allocate(6)
    for i in range(6):
        nullable.set(i, vals[i])
        plain.set(i, vals[i])
    nullable._set_null(1)
    nullable._set_null(4)
    var masked = _numeric_to_bool[DType.int64](nullable.slice(2, 4))
    assert_equal(masked.length, 4)
    assert_equal(masked.null_count, 1)
    assert_true(masked.get(0) and not masked.is_null(0))
    assert_true(not masked.get(1) and not masked.is_null(1))
    assert_true(masked.is_null(2) and not masked.get(2))
    assert_true(masked.get(3) and not masked.is_null(3))
    var unmasked = _numeric_to_bool[DType.int64](plain.slice(2, 4))
    assert_equal(unmasked.null_count, 0)
    assert_true(unmasked.get(0))
    assert_true(not unmasked.get(1))
    assert_true(not unmasked.get(2))
    assert_true(unmasked.get(3))


def test_bool_to_bool_is_unchanged() raises:
    var rows: List[Int] = [_T, _N, _F]
    var batch = _bool_batch(rows)
    var col = _cast(batch, ArrowType.BOOL)
    assert_true(col.arrow_type == ArrowType.BOOL)
    var out = col.as_boolean()
    assert_true(out.get(0))
    assert_true(out.is_null(1))
    assert_true(not out.get(2))


def test_bool_to_and_from_a_date_is_still_refused() raises:
    var rows: List[Int] = [_T, _F]
    var bools = _bool_batch(rows)
    with assert_raises(contains="unsupported EXPR_CAST from bool"):
        _ = _cast(bools, ArrowType.DATE32)
    var vals: List[Int32] = [Int32(1), Int32(0)]
    var none: List[Int] = []
    var dates = _num_batch[DType.int32](ArrowType.DATE32, vals, none)
    with assert_raises(contains="unsupported EXPR_CAST"):
        _ = _cast(dates, ArrowType.BOOL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
