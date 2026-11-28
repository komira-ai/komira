# =============================================================================
# test_date_add_projection: EXPR_DATE_ADD and the DATE32 -> TIMESTAMP_US cast
# through the projection evaluator
# =============================================================================
#
# `date_add(months, days, child)` moves a DATE32 child by calendar months
# (day of month clamped to the target month) and then by days, and answers a
# DATE32 column. A column a parquet or CSV scan stamped INT32 while its schema
# field says DATE32 is served like a DATE32-stamped one. `CAST(<date> AS
# TIMESTAMP)` answers TIMESTAMP_US at midnight. Day counts are days since
# 1970-01-01: 2024-01-31 is 19753, 2024-02-29 is 19782, 2023-01-31 is 19388,
# 2023-02-28 is 19416.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.testing import assert_raises

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from plan_expr.expr import BIN_GT, BIN_LT, Expr

from batch_eval.eval_column import _eval_column_expr

comptime _US_PER_DAY: Int = 86_400_000_000


def _days_array(values: List[Int32], null_row: Int) raises -> PrimitiveArray[DType.int32]:
    """`values` as a nullable int32 array with row `null_row` NULL (-1: none)."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    if null_row >= 0:
        arr._set_null(null_row)
        arr.null_count = 1
    return arr^


def _date_batch(values: List[Int32], null_row: Int) raises -> RecordBatch:
    """One DATE32-stamped column `d` over a DATE32 field."""
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](_days_array(values, null_row), ArrowType.DATE32)
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    return rbb.build(sb.build())


def _scan_stamped_batch(values: List[Int32], null_row: Int, declared: ArrowType) raises -> RecordBatch:
    """One INT32-stamped column `d` (the physical stamp a scan gives a date)
    over a field of type `declared`."""
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int32](_days_array(values, null_row)))
    var sb = SchemaBuilder()
    sb.add_field(Field("d", declared, True))
    return rbb.build(sb.build())


def _vals() -> List[Int32]:
    return [19753, 19388, 0, 19782]


def test_date_add_days_shifts_a_date32_column_and_keeps_the_date_stamp() raises:
    var out = _eval_column_expr(Expr.date_add(0, 7, Expr.col_ref("d")), _date_batch(_vals(), 2))
    assert_true(out.arrow_type == ArrowType.DATE32)
    var arr = out.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), 19760)
    assert_equal(Int(arr.get(1)), 19395)
    assert_equal(Int(arr.get(3)), 19789)


def test_date_add_keeps_a_null_row_null() raises:
    var out = _eval_column_expr(Expr.date_add(0, 7, Expr.col_ref("d")), _date_batch(_vals(), 2))
    assert_equal(out.length(), 4)
    assert_equal(out.null_count(), 1)
    assert_true(out.is_null_at(2))
    assert_false(out.is_null_at(0))


def test_date_add_months_clamps_to_the_last_day_of_the_month() raises:
    var out = _eval_column_expr(Expr.date_add(1, 0, Expr.col_ref("d")), _date_batch(_vals(), 2))
    var arr = out.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), 19782)  # 2024-01-31 + 1 month = 2024-02-29
    assert_equal(Int(arr.get(1)), 19416)  # 2023-01-31 + 1 month = 2023-02-28


def test_date_add_negative_months_and_days_move_backwards() raises:
    var values: List[Int32] = [19782]
    var out = _eval_column_expr(Expr.date_add(-12, -1, Expr.col_ref("d")), _date_batch(values, -1))
    # 2024-02-29 - 12 months = 2023-02-28, then - 1 day = 2023-02-27.
    assert_equal(Int(out.as_primitive[DType.int32]().get(0)), 19415)


def test_date_add_serves_a_scan_stamped_int32_column_declared_date32() raises:
    var out = _eval_column_expr(
        Expr.date_add(1, 1, Expr.col_ref("d")), _scan_stamped_batch(_vals(), 2, ArrowType.DATE32)
    )
    assert_true(out.arrow_type == ArrowType.DATE32)
    var arr = out.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), 19783)
    assert_equal(Int(arr.get(1)), 19417)
    assert_true(out.is_null_at(2))


def test_a_select_list_comparison_of_a_scan_stamped_date_with_its_shift_reads_dates() raises:
    """`SELECT d < d + INTERVAL '7' DAY` and `SELECT d > d + 7` over a column a
    scan stamped INT32: the comparison reads both sides as dates (true and
    false on every row) and a NULL date answers NULL."""
    var batch = _scan_stamped_batch(_vals(), 2, ArrowType.DATE32)
    var lt = _eval_column_expr(
        Expr.binary(
            BIN_LT, Expr.col_ref("d"),
            Expr.cast_to_arrow(Expr.date_add(0, 7, Expr.col_ref("d")), ArrowType.TIMESTAMP_US),
        ),
        batch,
    )
    var gt = _eval_column_expr(
        Expr.binary(BIN_GT, Expr.col_ref("d"), Expr.date_add(0, 7, Expr.col_ref("d"))),
        batch,
    )
    assert_true(lt.is_null_at(2), "NULL date, NULL answer (<)")
    assert_true(gt.is_null_at(2), "NULL date, NULL answer (>)")
    var lt_b = lt.as_boolean()
    var gt_b = gt.as_boolean()
    for i in [0, 1, 3]:
        assert_true(lt_b.get(i), "d < d + 7 days")
        assert_false(gt_b.get(i), "d > d + 7")


def test_date_add_over_a_computed_date_child_composes() raises:
    var values: List[Int32] = [19753]
    var inner = Expr.date_add(1, 0, Expr.col_ref("d"))
    var out = _eval_column_expr(Expr.date_add(0, 1, inner^), _date_batch(values, -1))
    assert_equal(Int(out.as_primitive[DType.int32]().get(0)), 19783)


def test_date_add_over_a_column_declared_int32_is_refused_by_name() raises:
    with assert_raises(contains="EXPR_DATE_ADD child must be DATE32"):
        _ = _eval_column_expr(
            Expr.date_add(0, 1, Expr.col_ref("d")), _scan_stamped_batch(_vals(), -1, ArrowType.INT32)
        )


def test_date_add_past_the_date32_range_raises_by_name() raises:
    var values: List[Int32] = [2147483000]
    with assert_raises(contains="date32_add_months_days: result out of range for DATE32"):
        _ = _eval_column_expr(Expr.date_add(0, 1000, Expr.col_ref("d")), _date_batch(values, -1))


def test_cast_of_date_add_is_timestamp_us_at_midnight() raises:
    var e = Expr.cast_to_arrow(Expr.date_add(0, 1, Expr.col_ref("d")), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(e, _date_batch(_vals(), 2))
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 19754 * _US_PER_DAY)
    assert_equal(Int(arr.get(1)), 19389 * _US_PER_DAY)
    assert_equal(Int(arr.get(3)), 19783 * _US_PER_DAY)


def test_cast_of_date_add_keeps_a_null_row_null() raises:
    var e = Expr.cast_to_arrow(Expr.date_add(0, 1, Expr.col_ref("d")), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(e, _date_batch(_vals(), 2))
    assert_equal(out.null_count(), 1)
    assert_true(out.is_null_at(2))


def test_cast_of_a_date32_column_to_timestamp_us_is_midnight_of_each_day() raises:
    var e = Expr.cast_to_arrow(Expr.col_ref("d"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(e, _date_batch(_vals(), 2))
    assert_true(out.arrow_type == ArrowType.TIMESTAMP_US)
    assert_equal(Int(out.as_primitive[DType.int64]().get(0)), 19753 * _US_PER_DAY)


def test_cast_of_a_date_before_the_epoch_is_negative_microseconds() raises:
    var values: List[Int32] = [-1]
    var e = Expr.cast_to_arrow(Expr.col_ref("d"), ArrowType.TIMESTAMP_US)
    var out = _eval_column_expr(e, _date_batch(values, -1))
    assert_equal(Int(out.as_primitive[DType.int64]().get(0)), -_US_PER_DAY)


def test_cast_to_timestamp_us_past_int64_microseconds_raises_by_name() raises:
    var values: List[Int32] = [2000000000]
    var e = Expr.cast_to_arrow(Expr.col_ref("d"), ArrowType.TIMESTAMP_US)
    with assert_raises(contains="date32_to_timestamp_us: result out of range for TIMESTAMP_US"):
        _ = _eval_column_expr(e, _date_batch(values, -1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
