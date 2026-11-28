# =============================================================================
# date_add: `date32_add_months_days` and `date32_to_timestamp_us`.
#
# THE ORACLE: every day count below was computed from the proleptic Gregorian
# calendar as days since 1970-01-01 (the date is named in each comment).
# Month arithmetic keeps the day of the month and clamps it to the last day of
# the target month; days are added after the months.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.testing import assert_raises

from arrow.primitive_array import PrimitiveArray
from kernels.date_add import date32_add_months_days, date32_to_timestamp_us


def _one(days: Int32) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate(1)
    arr.set(0, Scalar[DType.int32](days))
    return arr^


def _shift_one(days: Int32, months: Int32, shift: Int32) raises -> Int:
    var out = date32_add_months_days(_one(days), months, shift)
    return Int(out.get(0))


def _nullable(
    values: List[Int32], nulls: List[Int]
) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Scalar[DType.int32](values[i]))
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    arr.null_count = len(nulls)
    return arr^


def test_adding_days_moves_the_date_by_that_many_days() raises:
    # 2024-01-31 is 19753; plus 7 days is 2024-02-07.
    assert_equal(_shift_one(19753, 0, 7), 19760)


def test_negative_days_move_the_date_back() raises:
    # 2024-01-31 minus 31 days is 2023-12-31.
    assert_equal(_shift_one(19753, 0, -31), 19722)


def test_zero_months_and_zero_days_leave_the_date_alone() raises:
    assert_equal(_shift_one(19753, 0, 0), 19753)


def test_plus_one_month_clamps_to_the_last_day_of_a_leap_february() raises:
    # 2024-01-31 + 1 month = 2024-02-29.
    assert_equal(_shift_one(19753, 1, 0), 19782)


def test_plus_one_month_clamps_to_the_last_day_of_a_common_february() raises:
    # 2023-01-31 + 1 month = 2023-02-28.
    assert_equal(_shift_one(19388, 1, 0), 19416)


def test_minus_twelve_months_from_a_leap_day_lands_on_february_28() raises:
    # 2024-02-29 - 12 months = 2023-02-28.
    assert_equal(_shift_one(19782, -12, 0), 19416)


def test_a_century_year_divisible_by_400_has_a_february_29() raises:
    # 2000-01-31 + 1 month = 2000-02-29.
    assert_equal(_shift_one(10987, 1, 0), 11016)


def test_a_century_year_not_divisible_by_400_has_no_february_29() raises:
    # 1900-01-31 + 1 month = 1900-02-28.
    assert_equal(_shift_one(-25537, 1, 0), -25509)


def test_plus_one_month_clamps_a_31st_to_the_30th_of_a_30_day_month() raises:
    # 2024-03-31 + 1 month = 2024-04-30.
    assert_equal(_shift_one(19813, 1, 0), 19843)


def test_months_are_applied_before_days() raises:
    # 2024-01-31 + 1 month = 2024-02-29, then + 1 day = 2024-03-01 (19783).
    assert_equal(_shift_one(19753, 1, 1), 19783)


def test_months_carry_across_the_year_boundary_forwards() raises:
    # 2024-12-15 + 2 months = 2025-02-15.
    assert_equal(_shift_one(20072, 2, 0), 20134)


def test_months_carry_across_the_year_boundary_backwards() raises:
    # 2024-01-15 - 2 months = 2023-11-15.
    assert_equal(_shift_one(19737, -2, 0), 19676)


def test_a_date_before_the_epoch_moves_by_months() raises:
    # 1969-12-31 + 1 month = 1970-01-31; 1969-12-31 - 1 month = 1969-11-30.
    assert_equal(_shift_one(-1, 1, 0), 30)
    assert_equal(_shift_one(-1, -1, 0), -32)


def test_a_leap_day_before_the_epoch_clamps_a_year_later() raises:
    # 1960-02-29 + 12 months = 1961-02-28.
    assert_equal(_shift_one(-3594, 12, 0), -3229)


def test_null_rows_stay_null_and_other_rows_are_shifted() raises:
    var values: List[Int32] = [19753, 0, 19388, 5]
    var out = date32_add_months_days(_nullable(values, [1, 3]), 1, 0)
    assert_equal(out.length, 4)
    assert_equal(out.null_count, 2)
    assert_false(out.is_null(0))
    assert_true(out.is_null(1))
    assert_false(out.is_null(2))
    assert_true(out.is_null(3))
    assert_equal(Int(out.get(0)), 19782)
    assert_equal(Int(out.get(2)), 19416)


def test_a_non_nullable_input_gives_an_output_without_nulls() raises:
    var arr = PrimitiveArray[DType.int32].allocate(2)
    arr.set(0, Scalar[DType.int32](19753))
    arr.set(1, Scalar[DType.int32](19388))
    var out = date32_add_months_days(arr, 0, 1)
    assert_equal(out.null_count, 0)
    assert_equal(Int(out.get(0)), 19754)
    assert_equal(Int(out.get(1)), 19389)


def test_a_sliced_input_keeps_the_validity_window() raises:
    # Parent rows: 0 null, 1 = 19753, 2 = 19388, 3 null, 4 = 19782.
    # slice(2, 3) is rows 2..4: value, NULL, value.
    var values: List[Int32] = [0, 19753, 19388, 0, 19782]
    var parent = _nullable(values, [0, 3])
    var out = date32_add_months_days(parent.slice(2, 3), 0, 1)
    assert_equal(out.length, 3)
    assert_equal(out.null_count, 1)
    assert_false(out.is_null(0))
    assert_true(out.is_null(1))
    assert_false(out.is_null(2))
    assert_equal(Int(out.get(0)), 19389)
    assert_equal(Int(out.get(2)), 19783)


def test_a_null_row_holding_an_out_of_range_payload_does_not_raise() raises:
    var values: List[Int32] = [2147483647, 19753]
    var out = date32_add_months_days(_nullable(values, [0]), 0, 1000)
    assert_true(out.is_null(0))
    assert_equal(Int(out.get(1)), 20753)


def test_a_day_shift_past_the_int32_range_raises_by_name() raises:
    with assert_raises(contains="date32_add_months_days: result out of range for DATE32"):
        _ = date32_add_months_days(_one(2147483000), 0, 1000)


def test_a_negative_day_shift_past_the_int32_range_raises_by_name() raises:
    with assert_raises(contains="date32_add_months_days: result out of range for DATE32"):
        _ = date32_add_months_days(_one(-2147483000), 0, -1000)


def test_a_month_shift_past_the_int32_range_raises_by_name() raises:
    with assert_raises(contains="date32_add_months_days: result out of range for DATE32"):
        _ = date32_add_months_days(_one(0), 2000000000, 0)
    with assert_raises(contains="date32_add_months_days: result out of range for DATE32"):
        _ = date32_add_months_days(_one(0), -2000000000, 0)


def test_the_last_representable_day_is_accepted() raises:
    assert_equal(_shift_one(2147483646, 0, 1), 2147483647)
    assert_equal(_shift_one(-2147483647, 0, -1), -2147483648)


def test_a_date_widens_to_microseconds_at_midnight() raises:
    # 2024-01-31 is day 19753.
    var out = date32_to_timestamp_us(_one(19753))
    assert_equal(Int(out.get(0)), 19753 * 86_400_000_000)


def test_a_date_before_the_epoch_widens_to_negative_microseconds() raises:
    var out = date32_to_timestamp_us(_one(-1))
    assert_equal(Int(out.get(0)), -86_400_000_000)


def test_widening_keeps_null_rows_null_over_a_slice() raises:
    var values: List[Int32] = [0, 1, 2, 0, 4]
    var parent = _nullable(values, [0, 3])
    var out = date32_to_timestamp_us(parent.slice(2, 3))
    assert_equal(out.length, 3)
    assert_equal(out.null_count, 1)
    assert_false(out.is_null(0))
    assert_true(out.is_null(1))
    assert_false(out.is_null(2))
    assert_equal(Int(out.get(0)), 2 * 86_400_000_000)
    assert_equal(Int(out.get(2)), 4 * 86_400_000_000)


def test_widening_accepts_the_last_day_count_that_fits_int64() raises:
    assert_equal(Int(date32_to_timestamp_us(_one(106751991)).get(0)), 106751991 * 86_400_000_000)
    assert_equal(Int(date32_to_timestamp_us(_one(-106751991)).get(0)), -106751991 * 86_400_000_000)


def test_widening_a_day_count_past_int64_microseconds_raises_by_name() raises:
    with assert_raises(contains="date32_to_timestamp_us: result out of range for TIMESTAMP_US"):
        _ = date32_to_timestamp_us(_one(106751992))
    with assert_raises(contains="date32_to_timestamp_us: result out of range for TIMESTAMP_US"):
        _ = date32_to_timestamp_us(_one(-106751992))


def test_widening_an_input_without_nulls_gives_an_output_without_nulls() raises:
    var out = date32_to_timestamp_us(_one(3))
    assert_equal(out.null_count, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
