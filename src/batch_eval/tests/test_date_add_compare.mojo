# =============================================================================
# test_date_add_compare: comparisons of dates and timestamps, and the WHERE
# shapes `ship > order + INTERVAL '7' DAY` and `ship > order + 7`
# =============================================================================
#
# `_eval_col_vs_col_promoted` compares DATE32 with DATE32, TIMESTAMP_US with
# TIMESTAMP_US and DATE32 with TIMESTAMP_US in both orders (the date is read
# as midnight of its day), under all six operators, with a NULL on either side
# giving NULL. Through `_eval_predicate`, a column a scan stamped INT32 while
# its schema field says DATE32 takes part in those comparisons as a date.
#
# Rows are days (or the microseconds of those days at midnight):
#   left  = [5, 5, 5, NULL, 7]
#   right = [4, 5, 6, 3,    NULL]
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.testing import assert_raises

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    Expr,
)

from batch_eval.column_compare import _eval_col_vs_col_promoted
from batch_eval.eval_predicate import _eval_predicate

comptime _US_PER_DAY: Int64 = 86_400_000_000
comptime _NULL: Int = -1


def _date_col(values: List[Int32], null_rows: List[Int]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    for j in range(len(null_rows)):
        arr._set_null(null_rows[j])
    arr.null_count = len(null_rows)
    return Column.from_primitive_with_arrow_type[DType.int32](arr^, ArrowType.DATE32)


def _ts_col(days: List[Int64], extra_us: Int64, null_rows: List[Int]) raises -> Column[HeapRegion]:
    """TIMESTAMP_US at midnight of each day, plus `extra_us` microseconds."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(days))
    for i in range(len(days)):
        arr.set(i, days[i] * _US_PER_DAY + extra_us)
    for j in range(len(null_rows)):
        arr._set_null(null_rows[j])
    arr.null_count = len(null_rows)
    return Column.from_primitive_with_arrow_type[DType.int64](arr^, ArrowType.TIMESTAMP_US)


def _left_days() -> List[Int32]:
    return [5, 5, 5, 0, 7]


def _right_days() -> List[Int32]:
    return [4, 5, 6, 3, 0]


def _left_days64() -> List[Int64]:
    return [5, 5, 5, 0, 7]


def _right_days64() -> List[Int64]:
    return [4, 5, 6, 3, 0]


def _operand(is_ts: Bool, is_left: Bool) raises -> Column[HeapRegion]:
    """The left or right operand column as a DATE32 (False) or TIMESTAMP_US."""
    if is_ts:
        if is_left:
            return _ts_col(_left_days64(), 0, [3])
        return _ts_col(_right_days64(), 0, [4])
    if is_left:
        return _date_col(_left_days(), [3])
    return _date_col(_right_days(), [4])


def _assert_answer(got: BooleanArray, want: List[Int], label: String) raises:
    """`want` holds 1 (true), 0 (false) or `_NULL` per row."""
    assert_equal(got.length, len(want), label + ": length")
    for i in range(len(want)):
        if want[i] == _NULL:
            assert_true(got.is_null(i), label + ": row " + String(i) + " is NULL")
        else:
            assert_false(got.is_null(i), label + ": row " + String(i) + " is not NULL")
            assert_equal(got.get(i), want[i] == 1, label + ": row " + String(i))


def _check_op(l_ts: Bool, r_ts: Bool, op: UInt8, want: List[Int], label: String) raises:
    _assert_answer(_eval_col_vs_col_promoted(_operand(l_ts, True), _operand(r_ts, False), op), want, label)


def _check_all_ops(l_ts: Bool, r_ts: Bool, label: String) raises:
    _check_op(l_ts, r_ts, BIN_GT, [1, 0, 0, _NULL, _NULL], label + " >")
    _check_op(l_ts, r_ts, BIN_GE, [1, 1, 0, _NULL, _NULL], label + " >=")
    _check_op(l_ts, r_ts, BIN_LT, [0, 0, 1, _NULL, _NULL], label + " <")
    _check_op(l_ts, r_ts, BIN_LE, [0, 1, 1, _NULL, _NULL], label + " <=")
    _check_op(l_ts, r_ts, BIN_EQ, [0, 1, 0, _NULL, _NULL], label + " =")
    _check_op(l_ts, r_ts, BIN_NE, [1, 0, 1, _NULL, _NULL], label + " <>")


def test_date32_against_date32_compares_by_day_under_all_six_operators() raises:
    _check_all_ops(False, False, "date vs date")


def test_timestamp_us_against_timestamp_us_compares_by_instant_under_all_six_operators() raises:
    _check_all_ops(True, True, "ts vs ts")


def test_date32_against_timestamp_us_compares_at_midnight_under_all_six_operators() raises:
    _check_all_ops(False, True, "date vs ts")


def test_timestamp_us_against_date32_compares_at_midnight_under_all_six_operators() raises:
    _check_all_ops(True, False, "ts vs date")


def _same_day_pair(date_first: Bool, op: UInt8) raises -> BooleanArray:
    """Date 5 against the timestamp one hour into day 5."""
    var one_day: List[Int32] = [5]
    var one_day64: List[Int64] = [5]
    var none: List[Int] = []
    var date = _date_col(one_day, none)
    var later = _ts_col(one_day64, 3_600_000_000, none)
    if date_first:
        return _eval_col_vs_col_promoted(date^, later^, op)
    return _eval_col_vs_col_promoted(later^, date^, op)


def test_a_date_is_before_a_timestamp_later_the_same_day_in_both_orders() raises:
    _assert_answer(_same_day_pair(True, BIN_LT), [1], "date < ts later that day")
    _assert_answer(_same_day_pair(True, BIN_EQ), [0], "date = ts later that day")
    _assert_answer(_same_day_pair(False, BIN_GT), [1], "ts later that day > date")
    _assert_answer(_same_day_pair(False, BIN_EQ), [0], "ts later that day = date")


def test_a_date_beyond_int64_microseconds_against_a_timestamp_raises_by_name() raises:
    var huge: List[Int32] = [2000000000]
    var one64: List[Int64] = [0]
    var none: List[Int] = []
    with assert_raises(contains="date32_to_timestamp_us: result out of range for TIMESTAMP_US"):
        _ = _eval_col_vs_col_promoted(_date_col(huge, none), _ts_col(one64, 0, none), BIN_GT)


# --- the WHERE shapes, over scan-stamped (INT32) date columns ----------------


def _scan_batch() raises -> RecordBatch:
    """`order_date` and `ship_date`, INT32-stamped over DATE32 fields, and `n`,
    an INT32 column declared INT32.

    order_date = [100, 100, 100, NULL, 100]
    ship_date  = [107, 108, 106, 200,  NULL]
    """
    var order_arr = PrimitiveArray[DType.int32].allocate_nullable(5)
    var ship_arr = PrimitiveArray[DType.int32].allocate_nullable(5)
    var n_arr = PrimitiveArray[DType.int32].allocate(5)
    var ship: List[Int32] = [107, 108, 106, 200, 0]
    for i in range(5):
        order_arr.set(i, 100)
        ship_arr.set(i, ship[i])
        n_arr.set(i, 107)
    order_arr._set_null(3)
    order_arr.null_count = 1
    ship_arr._set_null(4)
    ship_arr.null_count = 1
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int32](order_arr^))
    rbb.add_column(Column.from_primitive[DType.int32](ship_arr^))
    rbb.add_column(Column.from_primitive[DType.int32](n_arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("order_date", ArrowType.DATE32, True))
    sb.add_field(Field("ship_date", ArrowType.DATE32, True))
    sb.add_field(Field("n", ArrowType.INT32, False))
    return rbb.build(sb.build())


def _plus_interval_days(days: Int32) -> Expr:
    """`order_date + INTERVAL 'days' DAY`, as the binder lowers it."""
    return Expr.cast_to_arrow(Expr.date_add(0, days, Expr.col_ref("order_date")), ArrowType.TIMESTAMP_US)


def test_ship_date_after_order_date_plus_interval_days_selects_rows_past_the_midnight() raises:
    # ship 107 is exactly order + 7 days at midnight: not strictly after.
    var got = _eval_predicate(Expr.binary(BIN_GT, Expr.col_ref("ship_date"), _plus_interval_days(7)), _scan_batch())
    _assert_answer(got, [0, 1, 0, _NULL, _NULL], "ship_date > order_date + INTERVAL 7 DAY")


def test_ship_date_at_or_after_order_date_plus_interval_days_includes_the_midnight() raises:
    var got = _eval_predicate(Expr.binary(BIN_GE, Expr.col_ref("ship_date"), _plus_interval_days(7)), _scan_batch())
    _assert_answer(got, [1, 1, 0, _NULL, _NULL], "ship_date >= order_date + INTERVAL 7 DAY")


def test_ship_date_after_order_date_plus_an_integer_compares_two_dates() raises:
    var e = Expr.binary(BIN_GT, Expr.col_ref("ship_date"), Expr.date_add(0, 7, Expr.col_ref("order_date")))
    _assert_answer(_eval_predicate(e, _scan_batch()), [0, 1, 0, _NULL, _NULL], "ship_date > order_date + 7")


def test_a_computed_date_on_the_left_compares_against_a_scan_stamped_date_column() raises:
    var e = Expr.binary(BIN_LT, Expr.date_add(0, 7, Expr.col_ref("order_date")), Expr.col_ref("ship_date"))
    _assert_answer(_eval_predicate(e, _scan_batch()), [0, 1, 0, _NULL, _NULL], "order_date + 7 < ship_date")


def test_a_computed_timestamp_on_the_left_compares_against_a_scan_stamped_date_column() raises:
    var e = Expr.binary(BIN_LT, _plus_interval_days(7), Expr.col_ref("ship_date"))
    _assert_answer(_eval_predicate(e, _scan_batch()), [0, 1, 0, _NULL, _NULL], "order_date + INTERVAL 7 DAY < ship_date")


def test_a_scan_stamped_date_column_against_an_integer_column_is_not_read_as_dates() raises:
    # `n` is declared INT32, so only one operand is temporal: the pair stays
    # an unsupported INT32 vs DATE32 comparison.
    var e = Expr.binary(BIN_GT, Expr.col_ref("n"), Expr.date_add(0, 7, Expr.col_ref("order_date")))
    with assert_raises(contains="unsupported column type pair"):
        _ = _eval_predicate(e, _scan_batch())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
