# FLOAT / DOUBLE statistics (`writer_float_stats`) against parquet.thrift's
# floating-point rules.
#
# What each test proves, and the defect it catches:
#   * NaN never enters min/max, at the head, inside the SIMD body and in the
#     scalar tail (lengths 5, 17 and 67 put the NaNs in each region); a
#     select written with the accumulator as the left operand takes the NaN
#     lane and fails.
#   * nan_count is exact in every region, including NaNs before the first
#     non-NaN seed (a count that starts at the seed, or that counts the seed
#     region twice, fails test_nan_count_with_leading_nans).
#   * all-NaN: nan_count == n and no min/max; all-null and empty: no min/max.
#   * signed zero: a zero min is written as -0.0 and a zero max as +0.0,
#     asserted on the bits.
#   * nulls: a null slot's bytes are not a value when skip_nulls is True,
#     and every slot is a value when it is False (a REQUIRED column).
#   * the dictionary arm cannot count NaN rows, so it writes no nan_count.
#   * merge sums the counts and keeps the bound across accumulators.
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_writer.writer_float_stats import (
    FloatMinMax,
    float_column_statistics,
    float_minmax_from_array,
    float_minmax_from_values,
    make_float_statistics,
)


def _nan64() -> Float64:
    return bitcast[DType.float64, 1](UInt64(0x7FF8000000000000))


def _neg_zero64() -> Float64:
    return bitcast[DType.float64, 1](UInt64(1) << 63)


def _f64(values: List[Float64]) raises -> PrimitiveArray[DType.float64]:
    var arr = PrimitiveArray[DType.float64].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    return arr^


def _le_u64(b: List[UInt8]) -> UInt64:
    var v = UInt64(0)
    for i in range(len(b)):
        v = v | (UInt64(b[i]) << UInt64(8 * i))
    return v


def _ramp_with_nans(n: Int, nan_at: List[Int]) -> List[Float64]:
    """Values 1..n (as Float64), with NaN at each index of `nan_at`."""
    var v = List[Float64]()
    for i in range(n):
        v.append(Float64(i + 1))
    for k in range(len(nan_at)):
        v[nan_at[k]] = _nan64()
    return v^


def test_nan_excluded_in_every_region() raises:
    var cases: List[Int] = [5, 17, 67]
    for c in range(len(cases)):
        var n = cases[c]
        # NaN at the head, the middle and the last element.
        var v = _ramp_with_nans(n, [0, n // 2, n - 1])
        var stats = float_column_statistics[DType.float64](_f64(v), True, 0)
        var lo = Float64(2)
        var hi = Float64(n - 1)
        assert_equal(_le_u64(stats.min_value.value()), UInt64(lo.to_bits()), "min, n=" + String(n))
        assert_equal(_le_u64(stats.max_value.value()), UInt64(hi.to_bits()), "max, n=" + String(n))
        assert_equal(stats.nan_count.value(), 3, "nan_count, n=" + String(n))


def test_nan_count_with_leading_nans() raises:
    # 40 values, the first 10 NaN (before the seed), 5 more in the body.
    var v = _ramp_with_nans(40, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 20, 21, 22, 30, 39])
    var mm = float_minmax_from_array[DType.float64](_f64(v), True)
    assert_true(mm.seeded)
    assert_equal(mm.nan_count, 15)
    assert_equal(mm.min_value, Float64(11))
    assert_equal(mm.max_value, Float64(39))


def test_all_nan_has_count_and_no_range() raises:
    var v = List[Float64]()
    for _ in range(19):
        v.append(_nan64())
    var stats = float_column_statistics[DType.float64](_f64(v), True, 0)
    assert_false(stats.min_value.__bool__())
    assert_false(stats.max_value.__bool__())
    assert_equal(stats.nan_count.value(), 19)
    assert_equal(stats.null_count.value(), 0)


def test_empty_and_all_null() raises:
    var empty = float_column_statistics[DType.float64](
        PrimitiveArray[DType.float64].allocate(0), True, 0
    )
    assert_false(empty.min_value.__bool__())
    assert_equal(empty.nan_count.value(), 0)
    var arr = PrimitiveArray[DType.float64].allocate_nullable(4)
    for i in range(4):
        arr.set(i, Float64(i))
        arr._set_null(i)
    var all_null = float_column_statistics[DType.float64](arr, True, 4)
    assert_false(all_null.min_value.__bool__())
    assert_equal(all_null.null_count.value(), 4)


def test_signed_zero_normalised_on_the_bits() raises:
    # Only -0.0: min is -0.0, max is +0.0.
    var s1 = float_column_statistics[DType.float64](
        _f64([_neg_zero64(), _neg_zero64()]), True, 0
    )
    assert_equal(_le_u64(s1.min_value.value()), UInt64(1) << 63)
    assert_equal(_le_u64(s1.max_value.value()), UInt64(0))
    # Only +0.0: the same pair.
    var s2 = float_column_statistics[DType.float64](_f64([0.0, 0.0, 0.0]), True, 0)
    assert_equal(_le_u64(s2.min_value.value()), UInt64(1) << 63)
    assert_equal(_le_u64(s2.max_value.value()), UInt64(0))
    # A non-zero min stays as it is.
    var s3 = float_column_statistics[DType.float64](_f64([-1.0, 0.0]), True, 0)
    assert_equal(_le_u64(s3.min_value.value()), UInt64(Float64(-1).to_bits()))
    assert_equal(_le_u64(s3.max_value.value()), UInt64(0))


def test_float32_is_four_bytes() raises:
    var arr = PrimitiveArray[DType.float32].allocate(3)
    arr.set(0, 2.5)
    arr.set(1, -4.0)
    arr.set(2, 1.0)
    var stats = float_column_statistics[DType.float32](arr, True, 0)
    assert_equal(len(stats.min_value.value()), 4)
    assert_equal(UInt32(_le_u64(stats.min_value.value())), UInt32(Float32(-4).to_bits()))
    assert_equal(UInt32(_le_u64(stats.max_value.value())), UInt32(Float32(2.5).to_bits()))


def test_null_slots_and_required_columns() raises:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(3)
    arr.set(0, 5.0)
    arr.set(1, -1.0e300)
    arr.set(2, 6.0)
    arr._set_null(1)
    var skip = float_minmax_from_array[DType.float64](arr, True)
    assert_equal(skip.min_value, Float64(5))
    # skip_nulls False: every slot is a value the page encodes.
    var keep = float_minmax_from_array[DType.float64](arr, False)
    assert_equal(keep.min_value, Float64(-1.0e300))


def test_dictionary_arm_writes_no_nan_count() raises:
    var values: List[Float64] = [3.0, _nan64(), 1.0]
    var mm = float_minmax_from_values[DType.float64](values)
    assert_false(mm.nan_count_exact)
    var stats = make_float_statistics[DType.float64](mm, 0)
    assert_false(stats.nan_count.__bool__(), "a NaN row count is unknown here")
    assert_equal(_le_u64(stats.min_value.value()), UInt64(Float64(1).to_bits()))


def test_merge_sums_counts_and_bounds() raises:
    var a = float_minmax_from_array[DType.float64](_f64([1.0, _nan64()]), True)
    var b = float_minmax_from_array[DType.float64](_f64([_nan64(), -3.0, _nan64()]), True)
    a.merge(b)
    assert_equal(a.nan_count, 3)
    assert_true(a.nan_count_exact)
    assert_equal(a.min_value, Float64(-3))
    assert_equal(a.max_value, Float64(1))
    var d = float_minmax_from_values[DType.float64]([2.0])
    a.merge(d)
    assert_false(a.nan_count_exact, "an inexact part makes the total inexact")
    var empty = FloatMinMax[DType.float64]()
    empty.merge(b)
    assert_equal(empty.min_value, Float64(-3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
