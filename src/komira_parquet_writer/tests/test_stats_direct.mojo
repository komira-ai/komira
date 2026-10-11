# The column-chunk statistics of `stats`: INT32 / INT64 / DOUBLE / string.
#
# What each group proves, and the defect it catches:
#   * known values, negatives, single element, all-same, empty: the SIMD
#     min/max pass and its scalar tail agree with the obvious answer (a
#     swapped select or a dropped tail fails them; the 9- and 33-element
#     columns put the extreme in the tail).
#   * nulls: a null slot's bytes never enter min/max. The fixtures write
#     -999 / +999 into the null slots first, so a scan that reads the raw
#     buffer (the predecessor's behavior) reports them and fails.
#   * sliced arrays: the validity bitmap is read at `offset + i`; a scan
#     that reads it at `i` takes the validity of the wrong row and fails.
#   * all-null: null_count and no min/max.
#   * DOUBLE: NaN never enters min/max, nan_count is exact, a zero min is
#     -0.0 and a zero max is +0.0 (bits, not values, are asserted).
#   * strings: unsigned byte order (0xC3 sorts after 'z'), the prefix rule,
#     truncation of min and max, nulls skipped, HLL registers present.
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_parquet_writer.stats import (
    STRING_STATS_TRUNCATION_LEN,
    compute_statistics_float64,
    compute_statistics_int32,
    compute_statistics_int64,
    compute_statistics_string,
)


def _i32(values: List[Int32]) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    return arr^


def _i64(values: List[Int64]) raises -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    return arr^


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


def _dec_i32(b: List[UInt8]) raises -> Int:
    assert_equal(len(b), 4)
    return Int(bitcast[DType.int32, 1](UInt32(_le_u64(b))))


def _dec_i64(b: List[UInt8]) raises -> Int:
    assert_equal(len(b), 8)
    return Int(bitcast[DType.int64, 1](_le_u64(b)))


def _f64_bits(b: List[UInt8]) raises -> UInt64:
    assert_equal(len(b), 8)
    return _le_u64(b)


def _repeat(c: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += c
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": byte " + String(i))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


# --- INT32 / INT64 ----------------------------------------------------------


def test_int32_known_values() raises:
    var stats = compute_statistics_int32(_i32([10, -5, 42, 0, 7]))
    assert_equal(stats.null_count.value(), 0)
    assert_equal(_dec_i32(stats.min_value.value()), -5)
    assert_equal(_dec_i32(stats.max_value.value()), 42)
    assert_equal(stats.distinct_count.value(), 5)
    assert_equal(len(stats.hll_registers.value()), 4096)


def test_int32_extremes_in_the_scalar_tail() raises:
    # 9 and 33 elements: the last element is past every SIMD width's body.
    var v = List[Int32]()
    for i in range(8):
        v.append(Int32(i))
    v.append(Int32(-7))
    var s = compute_statistics_int32(_i32(v))
    assert_equal(_dec_i32(s.min_value.value()), -7)
    var w = List[Int32]()
    for i in range(32):
        w.append(Int32(i))
    w.append(Int32(1000))
    var t = compute_statistics_int32(_i32(w))
    assert_equal(_dec_i32(t.max_value.value()), 1000)
    assert_equal(_dec_i32(t.min_value.value()), 0)


def test_int32_negative_single_and_same() raises:
    var neg = compute_statistics_int32(_i32([-10, -20, -1, -100]))
    assert_equal(_dec_i32(neg.min_value.value()), -100)
    assert_equal(_dec_i32(neg.max_value.value()), -1)
    var one = compute_statistics_int32(_i32([99]))
    assert_equal(_dec_i32(one.min_value.value()), 99)
    assert_equal(_dec_i32(one.max_value.value()), 99)
    var same = compute_statistics_int32(_i32([7, 7, 7, 7]))
    assert_equal(_dec_i32(same.min_value.value()), 7)
    assert_equal(_dec_i32(same.max_value.value()), 7)
    assert_equal(same.distinct_count.value(), 1)


def test_int64_large_range() raises:
    var stats = compute_statistics_int64(
        _i64([1000000000000, -999999999999, 0, 42])
    )
    assert_equal(_dec_i64(stats.min_value.value()), -999999999999)
    assert_equal(_dec_i64(stats.max_value.value()), 1000000000000)


def test_empty_column_has_no_range() raises:
    var stats = compute_statistics_int32(PrimitiveArray[DType.int32].allocate(0))
    assert_equal(stats.null_count.value(), 0)
    assert_false(stats.min_value.__bool__())
    assert_false(stats.max_value.__bool__())


def test_int32_null_slots_never_enter_min_max() raises:
    # Rows 1 and 3 are null and hold -999 / +999: values no row has.
    var arr = PrimitiveArray[DType.int32].allocate_nullable(5)
    arr.set(0, 5)
    arr.set(1, -999)
    arr.set(2, 6)
    arr.set(3, 999)
    arr.set(4, 7)
    arr._set_null(1)
    arr._set_null(3)
    var stats = compute_statistics_int32(arr)
    assert_equal(stats.null_count.value(), 2)
    assert_equal(_dec_i32(stats.min_value.value()), 5, "a null slot's -999 is not the min")
    assert_equal(_dec_i32(stats.max_value.value()), 7, "a null slot's 999 is not the max")
    assert_equal(stats.distinct_count.value(), 3)


def test_int64_null_slots_never_enter_min_max() raises:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(40)
    for i in range(40):
        arr.set(i, Int64(100 + i))
    arr.set(17, Int64(-1))
    arr._set_null(17)
    arr.set(39, Int64(1) << 40)
    arr._set_null(39)
    var stats = compute_statistics_int64(arr)
    assert_equal(_dec_i64(stats.min_value.value()), 100)
    assert_equal(_dec_i64(stats.max_value.value()), 138)


def test_sliced_array_reads_its_own_validity() raises:
    # Base: [1, 2, 3(null), 4, 5]; the slice [2, 5) is [3(null), 4, 5].
    # Reading validity at `i` instead of `offset + i` would take row 0 and
    # 1 of the base (valid) for row 0 of the slice and report min 3.
    var arr = PrimitiveArray[DType.int32].allocate_nullable(5)
    for i in range(5):
        arr.set(i, Int32(i + 1))
    arr._set_null(2)
    var sl = arr.slice(2, 3)
    assert_equal(sl.null_count, 1)
    var stats = compute_statistics_int32(sl)
    assert_equal(_dec_i32(stats.min_value.value()), 4)
    assert_equal(_dec_i32(stats.max_value.value()), 5)


def test_all_null_has_null_count_and_no_range() raises:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(3)
    for i in range(3):
        arr._set_null(i)
    var stats = compute_statistics_int64(arr)
    assert_equal(stats.null_count.value(), 3)
    assert_false(stats.min_value.__bool__())
    assert_equal(stats.distinct_count.value(), 0)


# --- DOUBLE -----------------------------------------------------------------


def test_float64_min_max() raises:
    var stats = compute_statistics_float64(_f64([1.5, -3.25, 2.75, 0.5]))
    assert_equal(stats.null_count.value(), 0)
    assert_equal(_f64_bits(stats.min_value.value()), UInt64(Float64(-3.25).to_bits()))
    assert_equal(_f64_bits(stats.max_value.value()), UInt64(Float64(2.75).to_bits()))
    assert_equal(stats.nan_count.value(), 0)


def test_float64_nan_excluded_and_counted() raises:
    var nan = bitcast[DType.float64, 1](UInt64(0x7FF8000000000000))
    var v = List[Float64]()
    for i in range(20):
        v.append(Float64(i))
    v[3] = nan
    v[19] = nan
    var stats = compute_statistics_float64(_f64(v))
    assert_equal(stats.nan_count.value(), 2)
    assert_equal(_f64_bits(stats.min_value.value()), UInt64(1) << 63)
    assert_equal(_f64_bits(stats.max_value.value()), UInt64(Float64(18).to_bits()))


def test_float64_signed_zero_normalised() raises:
    # Only +0.0 present: the min is written as -0.0, the max as +0.0.
    var stats = compute_statistics_float64(_f64([0.0, 0.0]))
    assert_equal(_f64_bits(stats.min_value.value()), UInt64(1) << 63)
    assert_equal(_f64_bits(stats.max_value.value()), UInt64(0))


def test_float64_null_slots_never_enter_min_max() raises:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(4)
    arr.set(0, 1.0)
    arr.set(1, -1.0e300)
    arr.set(2, 2.0)
    arr.set(3, 3.0)
    arr._set_null(1)
    var stats = compute_statistics_float64(arr)
    assert_equal(stats.null_count.value(), 1)
    assert_equal(_f64_bits(stats.min_value.value()), UInt64(Float64(1.0).to_bits()))
    assert_equal(stats.distinct_count.value(), 3)


# --- strings ----------------------------------------------------------------


def test_string_min_max_unsigned_byte_order() raises:
    # "\xc3\xa9" (e-acute) sorts after "z" as unsigned bytes; a signed
    # compare would put it first.
    var strs: List[String] = ["m", "z", "é", "a", "ab"]
    var stats = compute_statistics_string(StringArray.from_strings(strs))
    _assert_bytes(stats.min_value.value(), _bytes("a"), "min_value")
    _assert_bytes(stats.max_value.value(), _bytes("é"), "max_value")
    assert_true(stats.is_min_value_exact)
    assert_true(stats.is_max_value_exact)
    assert_equal(stats.distinct_count.value(), 5)
    assert_equal(len(stats.hll_registers.value()), 4096)


def test_string_prefix_sorts_first() raises:
    var strs: List[String] = ["abc", "ab", "abcd"]
    var stats = compute_statistics_string(StringArray.from_strings(strs))
    _assert_bytes(stats.min_value.value(), _bytes("ab"), "min_value")
    _assert_bytes(stats.max_value.value(), _bytes("abcd"), "max_value")


def test_string_truncation() raises:
    var long_a = _repeat("a", STRING_STATS_TRUNCATION_LEN + 10)
    var long_b = _repeat("b", STRING_STATS_TRUNCATION_LEN + 10)
    var strs: List[String] = [long_a, long_b]
    var stats = compute_statistics_string(StringArray.from_strings(strs))
    # min: the first N bytes; max: the first N bytes with the last one
    # incremented, then cut after it ("b"*63 + "c").
    assert_equal(len(stats.min_value.value()), STRING_STATS_TRUNCATION_LEN)
    assert_false(stats.is_min_value_exact)
    var want_max = _repeat("b", STRING_STATS_TRUNCATION_LEN - 1) + "c"
    _assert_bytes(stats.max_value.value(), _bytes(want_max), "max_value")
    assert_false(stats.is_max_value_exact)


def test_string_nulls_skipped_and_all_null() raises:
    var strs: List[String] = ["zz", "b", "c"]
    var valid: List[Bool] = [False, True, True]
    var stats = compute_statistics_string(
        StringArray.from_strings_with_validity(strs, valid)
    )
    assert_equal(stats.null_count.value(), 1)
    _assert_bytes(stats.min_value.value(), _bytes("b"), "min_value")
    _assert_bytes(stats.max_value.value(), _bytes("c"), "max_value")
    var none: List[Bool] = [False, False, False]
    var all_null = compute_statistics_string(
        StringArray.from_strings_with_validity(strs, none)
    )
    assert_equal(all_null.null_count.value(), 3)
    assert_false(all_null.min_value.__bool__())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
