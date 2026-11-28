# =============================================================================
# test_round_digits — the `EXPR_ROUND_DIGITS` kernels, cell by cell
# =============================================================================
#
# Every expected value is one measured on DuckDB (`RDG_ROUND`, `RDG_TRUNC`) or
# numpy (`RDG_ROUND_HALF_EVEN`). Signed zero is observed through `1 / x`, since
# `-0.0 == 0.0` hides it from `==`.

from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from byte_buffer.heap_region import HeapRegion
from column_kernels.round_digits import (
    eval_round_digits_decimal,
    eval_round_digits_float,
    eval_round_digits_int,
    numpy_power_of_ten,
)
from plan_expr.expr import RDG_ROUND, RDG_TRUNC, RDG_ROUND_HALF_EVEN
from scalar_arithmetic.decimal_arith import I128

def _nan() -> Float64:
    return nan[DType.float64]()


def _inf() -> Float64:
    return inf[DType.float64]()


def _is_nan(x: Float64) -> Bool:
    return x != x


def _is_neg_zero(x: Float64) -> Bool:
    return x == 0.0 and 1.0 / x < 0.0


def _is_pos_zero(x: Float64) -> Bool:
    return x == 0.0 and 1.0 / x > 0.0


def _f64(vals: List[Float64]) -> PrimitiveArray[DType.float64]:
    return PrimitiveArray[DType.float64].from_list(vals)


def _one_f64(op: UInt8, x: Float64, digits: Int) raises -> Float64:
    var a = eval_round_digits_float[DType.float64](
        op, digits, _f64([x])
    )
    return a.get(0)


def _one_f32(op: UInt8, x: Float32, digits: Int) raises -> Float32:
    var arr = PrimitiveArray[DType.float32].from_list([x])
    return eval_round_digits_float[DType.float32](op, digits, arr).get(0)


def _one_i64(op: UInt8, v: Int64, digits: Int) raises -> Int64:
    var arr = PrimitiveArray[DType.int64].from_list([v])
    return eval_round_digits_int[DType.int64](op, digits, arr).get(0)


def _one_i32(op: UInt8, v: Int32, digits: Int) raises -> Int32:
    var arr = PrimitiveArray[DType.int32].from_list([v])
    return eval_round_digits_int[DType.int32](op, digits, arr).get(0)


def _one_i8(op: UInt8, v: Int8, digits: Int) raises -> Int8:
    var arr = PrimitiveArray[DType.int8].from_list([v])
    return eval_round_digits_int[DType.int8](op, digits, arr).get(0)


def _dec(
    vals: List[I128], w: Int, s: Int
) raises -> Decimal128Array[HeapRegion]:
    return Decimal128Array.from_i128_list(vals, w, s)


# --------------------------------------------------------------------------
# RDG_ROUND over FLOAT64
# --------------------------------------------------------------------------


def test_round_float_halves_go_away_from_zero() raises:
    assert_equal(_one_f64(RDG_ROUND, 0.5, 0), 1.0)
    assert_equal(_one_f64(RDG_ROUND, 1.5, 0), 2.0)
    assert_equal(_one_f64(RDG_ROUND, 2.5, 0), 3.0)
    assert_equal(_one_f64(RDG_ROUND, -2.5, 0), -3.0)


def test_round_float_positive_digits_follow_the_double_product() raises:
    assert_equal(_one_f64(RDG_ROUND, 2.345, 2), 2.35)
    assert_equal(_one_f64(RDG_ROUND, 1.005, 2), 1.0)


def test_round_float_inf_result_with_nonnegative_digits_returns_operand() raises:
    assert_equal(_one_f64(RDG_ROUND, 1e308, 1), 1e308)
    assert_equal(_one_f64(RDG_ROUND, 1.5, 2147483647), 1.5)
    assert_true(_is_nan(_one_f64(RDG_ROUND, _nan(), 1)))


def test_round_float_keeps_the_sign_of_a_zero_result() raises:
    assert_true(_is_neg_zero(_one_f64(RDG_ROUND, -1e-308, 0)))
    assert_equal(_one_f64(RDG_ROUND, -1e-308, 400), -1e-308)
    assert_true(_is_neg_zero(_one_f64(RDG_ROUND, -1.5, -1)))


def test_round_float_negative_digits_with_inf_or_nan_result_is_zero() raises:
    assert_true(_is_pos_zero(_one_f64(RDG_ROUND, _nan(), -1)))
    assert_true(_is_pos_zero(_one_f64(RDG_ROUND, _inf(), -1)))
    assert_true(_is_pos_zero(_one_f64(RDG_ROUND, -0.5, -400)))
    assert_true(_is_pos_zero(_one_f64(RDG_ROUND, _nan(), -400)))
    assert_true(_is_pos_zero(_one_f64(RDG_ROUND, 123.0, -400)))


def test_round_float_negative_digits_round_to_tens() raises:
    assert_equal(_one_f64(RDG_ROUND, 25.0, -1), 30.0)
    assert_equal(_one_f64(RDG_ROUND, -25.0, -1), -30.0)


# --------------------------------------------------------------------------
# RDG_TRUNC over FLOAT64
# --------------------------------------------------------------------------


def test_trunc_float_goes_toward_zero() raises:
    assert_equal(_one_f64(RDG_TRUNC, -2.789, 1), -2.7)
    assert_true(_is_neg_zero(_one_f64(RDG_TRUNC, -1.5, -1)))


def test_trunc_float_inf_or_nan_result_returns_operand_on_both_sides() raises:
    assert_true(_is_nan(_one_f64(RDG_TRUNC, _nan(), -1)))
    assert_equal(_one_f64(RDG_TRUNC, _inf(), -1), _inf())
    assert_equal(_one_f64(RDG_TRUNC, -1.5, -400), -1.5)
    assert_true(_is_pos_zero(_one_f64(RDG_TRUNC, 0.0, -400)))
    assert_equal(_one_f64(RDG_TRUNC, 1e308, 1), 1e308)


# --------------------------------------------------------------------------
# FLOAT32 is computed in FLOAT64 for the SQL rules
# --------------------------------------------------------------------------


def test_float32_sql_rules_compute_in_double_and_narrow() raises:
    assert_equal(_one_f32(RDG_ROUND, Float32(2.5), 0), Float32(3.0))
    assert_equal(_one_f32(RDG_ROUND, Float32(-2.5), 0), Float32(-3.0))
    assert_equal(_one_f32(RDG_TRUNC, Float32(-2.789), 1), Float32(-2.7))
    assert_equal(_one_f32(RDG_ROUND, Float32(1.5), 2147483647), Float32(1.5))


def test_float32_half_even_stays_in_float32() raises:
    assert_equal(_one_f32(RDG_ROUND_HALF_EVEN, Float32(2.5), 0), Float32(2.0))
    assert_equal(_one_f32(RDG_ROUND_HALF_EVEN, Float32(0.25), 1), Float32(0.2))
    assert_equal(_one_f32(RDG_ROUND_HALF_EVEN, Float32(25.0), -1), Float32(20.0))


# --------------------------------------------------------------------------
# RDG_ROUND_HALF_EVEN over FLOAT64
# --------------------------------------------------------------------------


def test_half_even_float_halves_go_to_even() raises:
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 0.5, 0), 0.0)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 1.5, 0), 2.0)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 2.5, 0), 2.0)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, -2.5, 0), -2.0)
    assert_true(_is_neg_zero(_one_f64(RDG_ROUND_HALF_EVEN, -0.4, 0)))


def test_half_even_float_scales_by_numpy_power_of_ten() raises:
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 0.25, 1), 0.2)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 25.0, -1), 20.0)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 35.0, -1), 40.0)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 0.125, 2), 0.12)
    assert_equal(_one_f64(RDG_ROUND_HALF_EVEN, 2.5e12, -12), 2.0e12)


def test_half_even_float_has_no_inf_or_nan_fallback() raises:
    assert_true(_is_nan(_one_f64(RDG_ROUND_HALF_EVEN, 1.5, 400)))
    assert_true(_is_nan(_one_f64(RDG_ROUND_HALF_EVEN, 1.5, -400)))
    assert_true(_is_nan(_one_f64(RDG_ROUND_HALF_EVEN, _nan(), 1)))


def test_numpy_power_of_ten_table_and_repeated_multiplication() raises:
    assert_equal(numpy_power_of_ten(0), 1.0)
    assert_equal(numpy_power_of_ten(8), 1e8)
    assert_equal(numpy_power_of_ten(9), 1e9)
    var f = 1e9
    for _ in range(6):
        f = f * 10.0
    assert_equal(numpy_power_of_ten(15), f)
    assert_equal(numpy_power_of_ten(2147483647), _inf())


# --------------------------------------------------------------------------
# NULL validity and the rule check over floats
# --------------------------------------------------------------------------


def test_float_null_rows_stay_null_and_data_is_not_read() raises:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(3)
    arr.set(0, 2.5)
    arr.set(1, _nan())
    arr.set(2, -2.5)
    arr.validity.value().clear(1)
    arr.null_count = 1
    var out = eval_round_digits_float[DType.float64](RDG_ROUND, 0, arr)
    assert_equal(out.length, 3)
    assert_true(not out.is_null(0))
    assert_true(out.is_null(1))
    assert_true(not out.is_null(2))
    assert_equal(out.get(0), 3.0)
    assert_equal(out.get(2), -3.0)


def test_float_unknown_rule_is_refused() raises:
    with assert_raises(contains="unknown rounding rule 9"):
        _ = eval_round_digits_float[DType.float64](
            UInt8(9), 1, _f64([1.0])
        )


# --------------------------------------------------------------------------
# INT
# --------------------------------------------------------------------------


def test_round_int_negative_digits_half_away_from_zero() raises:
    assert_equal(_one_i64(RDG_ROUND, 1250, -2), 1300)
    assert_equal(_one_i64(RDG_ROUND, -1250, -2), -1300)
    assert_equal(_one_i64(RDG_ROUND, 1249, -2), 1200)
    assert_equal(_one_i64(RDG_ROUND, -255, -2), -300)
    assert_equal(_one_i8(RDG_ROUND, Int8(25), -1), Int8(30))
    assert_equal(_one_i8(RDG_ROUND, Int8(120), -2), Int8(100))


def test_round_int_wraps_at_the_column_width() raises:
    assert_equal(_one_i32(RDG_ROUND, Int32.MAX, -1), Int32(-2147483646))
    assert_equal(
        _one_i64(RDG_ROUND, Int64.MAX, -1), Int64(-9223372036854775800)
    )
    assert_equal(
        _one_i64(RDG_ROUND, Int64.MIN, -1), Int64(9223372036854775800)
    )
    assert_equal(
        _one_i64(RDG_ROUND, Int64.MAX, -18), Int64(-8000000000000000000)
    )


def test_int_nonnegative_digits_return_the_value() raises:
    assert_equal(_one_i64(RDG_ROUND, 1250, 0), 1250)
    assert_equal(_one_i64(RDG_ROUND, 1250, 5), 1250)
    assert_equal(_one_i64(RDG_TRUNC, -1250, 3), -1250)
    assert_equal(_one_i8(RDG_ROUND_HALF_EVEN, Int8(-7), 2), Int8(-7))


def test_int_digits_at_or_below_minus_19_are_zero() raises:
    assert_equal(_one_i64(RDG_ROUND, 5000000000000000000, -19), 0)
    assert_equal(_one_i64(RDG_TRUNC, Int64.MAX, -2147483648), 0)


def test_trunc_int_goes_toward_zero() raises:
    assert_equal(_one_i64(RDG_TRUNC, -255, -2), -200)
    assert_equal(_one_i64(RDG_TRUNC, 255, -2), 200)
    assert_equal(_one_i64(RDG_TRUNC, Int64.MAX, -18), 9000000000000000000)


def test_half_even_int_goes_through_double_and_truncates_back() raises:
    assert_equal(_one_i64(RDG_ROUND_HALF_EVEN, 25, -1), 20)
    assert_equal(_one_i64(RDG_ROUND_HALF_EVEN, 35, -1), 40)
    assert_equal(_one_i64(RDG_ROUND_HALF_EVEN, -25, -1), -20)
    assert_equal(_one_i32(RDG_ROUND_HALF_EVEN, Int32(1250), -2), Int32(1200))


def test_int_null_rows_stay_null() raises:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(2)
    arr.set(0, Int32(1250))
    arr.set(1, Int32(99999))
    arr.validity.value().clear(1)
    arr.null_count = 1
    var out = eval_round_digits_int[DType.int32](RDG_ROUND, -2, arr)
    assert_equal(out.get(0), Int32(1300))
    assert_true(out.is_null(1))
    assert_true(not out.is_null(0))


def test_int_unknown_rule_is_refused() raises:
    with assert_raises(contains="unknown rounding rule 7"):
        _ = eval_round_digits_int[DType.int64](
            UInt8(7), -1, PrimitiveArray[DType.int64].from_list([Int64(1)])
        )


# --------------------------------------------------------------------------
# DECIMAL128
# --------------------------------------------------------------------------


def test_round_decimal_to_fewer_places_rescales_and_rounds_half_away() raises:
    var vals: List[I128] = [I128(12345), I128(-79955)]
    var out = eval_round_digits_decimal(RDG_ROUND, 2, _dec(vals, 12, 4))
    assert_equal(out.precision, 12)
    assert_equal(out.scale, 2)
    assert_equal(out.get_i128(0), I128(123))
    assert_equal(out.get_i128(1), I128(-800))


def test_round_decimal_digits_at_or_above_scale_keep_value_and_type() raises:
    var vals: List[I128] = [I128(12345), I128(-1)]
    var out = eval_round_digits_decimal(RDG_ROUND, 6, _dec(vals, 12, 4))
    assert_equal(out.scale, 4)
    assert_equal(out.get_i128(0), I128(12345))
    assert_equal(out.get_i128(1), I128(-1))
    var same = eval_round_digits_decimal(RDG_TRUNC, 4, _dec(vals, 12, 4))
    assert_equal(same.scale, 4)
    assert_equal(same.get_i128(0), I128(12345))


def test_round_decimal_negative_digits_give_scale_zero() raises:
    var vals: List[I128] = [I128(1055000), I128(-25000)]
    var out = eval_round_digits_decimal(RDG_ROUND, -1, _dec(vals, 12, 4))
    assert_equal(out.precision, 12)
    assert_equal(out.scale, 0)
    assert_equal(out.get_i128(0), I128(110))
    assert_equal(out.get_i128(1), I128(0))


def test_round_decimal_thousand_survives_when_a_digit_is_left() raises:
    var vals: List[I128] = [I128(10000)]
    var out = eval_round_digits_decimal(RDG_ROUND, -3, _dec(vals, 5, 1))
    assert_equal(out.scale, 0)
    assert_equal(out.get_i128(0), I128(1000))


def test_round_decimal_all_zero_case_is_valid_zero_even_for_null() raises:
    var arr = _dec([I128(12345), I128(7)], 12, 4)
    arr.set_null(1)
    var out = eval_round_digits_decimal(RDG_ROUND, -8, arr)
    assert_equal(out.scale, 0)
    assert_true(not out.is_null(0))
    assert_true(not out.is_null(1))
    assert_equal(out.get_i128(0), I128(0))
    assert_equal(out.get_i128(1), I128(0))
    var small = eval_round_digits_decimal(RDG_ROUND, -3, _dec([I128(9999)], 4, 1))
    assert_equal(small.scale, 0)
    assert_equal(small.get_i128(0), I128(0))


def test_round_decimal_null_stays_null_just_inside_the_all_zero_bound() raises:
    var arr = _dec([I128(12345), I128(7)], 12, 4)
    arr.set_null(1)
    var out = eval_round_digits_decimal(RDG_ROUND, -7, arr)
    assert_true(not out.is_null(0))
    assert_true(out.is_null(1))


def test_round_decimal_wide_precision_keeps_precision() raises:
    var v = I128(123456789012345678901234) * I128(10000) + I128(5000)
    var out = eval_round_digits_decimal(RDG_ROUND, 2, _dec([v], 30, 4))
    assert_equal(out.precision, 30)
    assert_equal(out.scale, 2)
    assert_equal(out.get_i128(0), I128(123456789012345678901234) * I128(100) + I128(50))


def test_trunc_decimal_goes_toward_zero() raises:
    var out = eval_round_digits_decimal(RDG_TRUNC, 1, _dec([I128(-3289)], 12, 4))
    assert_equal(out.scale, 1)
    assert_equal(out.get_i128(0), I128(-3))
    var neg = eval_round_digits_decimal(RDG_TRUNC, -1, _dec([I128(-135000)], 12, 4))
    assert_equal(neg.scale, 0)
    assert_equal(neg.get_i128(0), I128(-10))


def test_trunc_decimal_all_zero_case_includes_null_rows() raises:
    var arr = _dec([I128(5)], 12, 4)
    arr.set_null(0)
    var out = eval_round_digits_decimal(RDG_TRUNC, -12, arr)
    assert_true(not out.is_null(0))
    assert_equal(out.get_i128(0), I128(0))


def test_half_even_decimal_is_refused_by_name() raises:
    with assert_raises(contains="no DECIMAL rule"):
        _ = eval_round_digits_decimal(
            RDG_ROUND_HALF_EVEN, 1, _dec([I128(1)], 12, 4)
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
