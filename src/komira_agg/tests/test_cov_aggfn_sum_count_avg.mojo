# =============================================================================
# test_cov_aggfn_sum_count_avg.mojo — SUM / COUNT / AVG cells, every input type
# =============================================================================
#
# The oracle is SQL aggregate semantics worked out by hand over a fixed list
# of non-null values (null rows never reach an `AggFn`: the caller filters
# them before `update`, see `CountState`):
#   SUM(x)   = the exact sum, in the documented result type: a signed integer
#              input widens to Int64, an unsigned one to UInt64, a float one to
#              Float64. Every list holds a sum that does NOT fit the input type,
#              so a cell that accumulated in its input width would fail.
#   COUNT(x) = the number of values; COUNT over no rows is 0.
#   AVG(x)   = SUM / COUNT as Float64; every list is chosen so the mean is
#              exactly representable, and every sum stays inside 2^53 so a
#              Float64 accumulator is exact.
#
# Each cell is driven three ways: the row-struct `update` (which forwards to
# `update_scalar`), the positional `update_scalar`, and `merge` of two
# partials at EVERY cut of the list (including the empty partial on either
# side), each finalized and compared with the hand-computed answer.
#
# Not pinned here (departures from SQL, reported rather than tested):
#   - SUM and AVG of a group with no rows: SQL answers NULL; the cells answer
#     0 / 0.0 (`finalize(init())`), and the AVG `count > 0` else arm is that
#     0.0. No input makes both agree, so those arms stay unpinned.
#   - SUM(Int64)/SUM(UInt64) past the result range: the cells wrap.
#   - AVG of integers past 2^53: the cells sum in Float64 and round.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_udf.agg_fn import AggFn
from komira_agg.builtin_agg_fns_states import (
    RowI8, RowI16, RowI32, RowI64,
    RowU8, RowU16, RowU32, RowU64,
    RowF32, RowF64,
)
from komira_agg.builtin_agg_fns_sum import (
    SumI8, SumI16, SumI32, SumI64,
    SumU8, SumU16, SumU32, SumU64,
    SumF32, SumF64,
)
from komira_agg.builtin_agg_fns_count import (
    CountI8, CountI16, CountI32, CountI64,
    CountU8, CountU16, CountU32, CountU64,
    CountF32, CountF64,
)
from komira_agg.builtin_agg_fns_avg import (
    AvgI8, AvgI16, AvgI32, AvgI64,
    AvgU8, AvgU16, AvgU32, AvgU64,
    AvgF32, AvgF64,
)


# -----------------------------------------------------------------------------
# Helpers: fold a slice of a value list through `update_scalar`, and check the
# merge of two partials at every cut against the hand-computed answer.
# -----------------------------------------------------------------------------


def _fold[
    dt: DType, F: AggFn
](f: F, vals: List[Scalar[dt]], lo: Int, hi: Int) -> F.State:
    var s = f.init()
    for i in range(lo, hi):
        f.update_scalar(s, vals[i])
    return s^


def _check_cuts[
    dt: DType, F: AggFn
](f: F, name: String, vals: List[Scalar[dt]], want: Scalar[F.OutType]) raises:
    var n = len(vals)
    assert_equal(f.finalize(_fold[dt, F](f, vals, 0, n)), want, name + " serial")
    for k in range(n + 1):
        var m = f.merge(_fold[dt, F](f, vals, 0, k), _fold[dt, F](f, vals, k, n))
        assert_equal(f.finalize(m), want, name + " merge at cut " + String(k))


# -----------------------------------------------------------------------------
# The value lists. Each sum overflows the input type; each mean is exact.
# -----------------------------------------------------------------------------


def _i8() -> List[Int8]:
    return [Int8(-128), Int8(127), Int8(100), Int8(101)]  # sum 200, mean 50


def _i16() -> List[Int16]:
    return [Int16(-32768), Int16(32767), Int16(30000), Int16(30001)]  # 60000


def _i32() -> List[Int32]:
    # sum 4000000000 (> Int32.MAX), mean 1e9
    return [Int32(-2147483648), Int32(2147483647), Int32(2000000000), Int32(2000000001)]


def _i64() -> List[Int64]:
    # sum 4000000000004 (> UInt32.MAX, < 2^53), mean 1000000000001
    return [Int64(-4503599627370496), Int64(4503599627370496), Int64(4000000000000), Int64(4)]


def _u8() -> List[UInt8]:
    return [UInt8(255), UInt8(255), UInt8(0), UInt8(2)]  # sum 512, mean 128


def _u16() -> List[UInt16]:
    return [UInt16(65535), UInt16(65535), UInt16(0), UInt16(2)]  # 131072


def _u32() -> List[UInt32]:
    # sum 8589934592 (2^33), mean 2^31
    return [UInt32(4294967295), UInt32(4294967295), UInt32(0), UInt32(2)]


def _u64() -> List[UInt64]:
    # sum 2^52 + 2^52 + 0 + 4 = 9007199254740996 (< 2^53 + 8: exact in F64,
    # 9007199254740996 is even and below 2^54), mean 2251799813685249
    return [UInt64(4503599627370496), UInt64(4503599627370496), UInt64(0), UInt64(4)]


def _f32() -> List[Float32]:
    # In Float32, 16777216 + 1 == 16777216: a Float32 accumulator would lose
    # both 1.0s. In Float64 the sum is exactly 16777220 and the mean 4194305.
    return [Float32(16777216.0), Float32(1.0), Float32(1.0), Float32(2.0)]


def _f64() -> List[Float64]:
    return [Float64(0.5), Float64(0.25), Float64(2.0), Float64(1.25)]  # 4.0, 1.0


# =============================================================================
# SUM
# =============================================================================


def test_sum_signed_widen_to_int64() raises:
    """SUM over i8/i16/i32/i64: the exact sum as Int64 (each overflows its
    input type, so an input-width accumulator gives a different answer)."""
    var s8 = SumI8().init()
    for v in _i8():
        SumI8().update(s8, RowI8(v))
    assert_equal(SumI8().finalize(s8), Int64(200))
    _check_cuts[DType.int8](SumI8(), "SumI8", _i8(), Int64(200))

    var s16 = SumI16().init()
    for v in _i16():
        SumI16().update(s16, RowI16(v))
    assert_equal(SumI16().finalize(s16), Int64(60000))
    _check_cuts[DType.int16](SumI16(), "SumI16", _i16(), Int64(60000))

    var s32 = SumI32().init()
    for v in _i32():
        SumI32().update(s32, RowI32(v))
    assert_equal(SumI32().finalize(s32), Int64(4000000000))
    _check_cuts[DType.int32](SumI32(), "SumI32", _i32(), Int64(4000000000))

    var s64 = SumI64().init()
    for v in _i64():
        SumI64().update(s64, RowI64(v))
    assert_equal(SumI64().finalize(s64), Int64(4000000000004))
    _check_cuts[DType.int64](SumI64(), "SumI64", _i64(), Int64(4000000000004))
    # Past 2^53 (no Float64 round trip): 2^62 + 1 - 3, exact.
    var big: List[Int64] = [Int64(4611686018427387904), Int64(1), Int64(-3)]
    _check_cuts[DType.int64](SumI64(), "SumI64 2^62", big, Int64(4611686018427387902))


def test_sum_unsigned_widen_to_uint64() raises:
    """SUM over u8/u16/u32/u64: the exact sum as UInt64."""
    var s8 = SumU8().init()
    for v in _u8():
        SumU8().update(s8, RowU8(v))
    assert_equal(SumU8().finalize(s8), UInt64(512))
    _check_cuts[DType.uint8](SumU8(), "SumU8", _u8(), UInt64(512))

    var s16 = SumU16().init()
    for v in _u16():
        SumU16().update(s16, RowU16(v))
    assert_equal(SumU16().finalize(s16), UInt64(131072))
    _check_cuts[DType.uint16](SumU16(), "SumU16", _u16(), UInt64(131072))

    var s32 = SumU32().init()
    for v in _u32():
        SumU32().update(s32, RowU32(v))
    assert_equal(SumU32().finalize(s32), UInt64(8589934592))
    _check_cuts[DType.uint32](SumU32(), "SumU32", _u32(), UInt64(8589934592))

    var s64 = SumU64().init()
    for v in _u64():
        SumU64().update(s64, RowU64(v))
    assert_equal(SumU64().finalize(s64), UInt64(9007199254740996))
    # Above Int64.MAX, still inside UInt64: 2^63 + 2^62 + 5.
    var big: List[UInt64] = [
        UInt64(9223372036854775808), UInt64(4611686018427387904), UInt64(5)
    ]
    _check_cuts[DType.uint64](SumU64(), "SumU64 2^63", big, UInt64(13835058055282163717))


def test_sum_float_widen_to_float64() raises:
    """SUM over f32 accumulates in Float64 (16777216 + 1 + 1 + 2 = 16777220,
    which a Float32 accumulator cannot reach); SUM over f64 is the plain sum."""
    var s32 = SumF32().init()
    for v in _f32():
        SumF32().update(s32, RowF32(v))
    assert_equal(SumF32().finalize(s32), Float64(16777220.0))
    _check_cuts[DType.float32](SumF32(), "SumF32", _f32(), Float64(16777220.0))

    var s64 = SumF64().init()
    for v in _f64():
        SumF64().update(s64, RowF64(v))
    assert_equal(SumF64().finalize(s64), Float64(4.0))
    _check_cuts[DType.float64](SumF64(), "SumF64", _f64(), Float64(4.0))


# =============================================================================
# COUNT
# =============================================================================


def test_count_every_type() raises:
    """COUNT counts the rows it is fed (4 per list) whatever their value, and
    COUNT over no rows is 0 (SQL: COUNT never answers NULL)."""
    var c8 = CountI8().init()
    assert_equal(CountI8().finalize(c8), Int64(0))
    for v in _i8():
        CountI8().update(c8, RowI8(v))
    assert_equal(CountI8().finalize(c8), Int64(4))
    _check_cuts[DType.int8](CountI8(), "CountI8", _i8(), Int64(4))

    var c16 = CountI16().init()
    for v in _i16():
        CountI16().update(c16, RowI16(v))
    assert_equal(CountI16().finalize(c16), Int64(4))
    _check_cuts[DType.int16](CountI16(), "CountI16", _i16(), Int64(4))

    var c32 = CountI32().init()
    for v in _i32():
        CountI32().update(c32, RowI32(v))
    assert_equal(CountI32().finalize(c32), Int64(4))
    _check_cuts[DType.int32](CountI32(), "CountI32", _i32(), Int64(4))

    var c64 = CountI64().init()
    for v in _i64():
        CountI64().update(c64, RowI64(v))
    assert_equal(CountI64().finalize(c64), Int64(4))
    _check_cuts[DType.int64](CountI64(), "CountI64", _i64(), Int64(4))

    var u8 = CountU8().init()
    for v in _u8():
        CountU8().update(u8, RowU8(v))
    assert_equal(CountU8().finalize(u8), Int64(4))
    _check_cuts[DType.uint8](CountU8(), "CountU8", _u8(), Int64(4))

    var u16 = CountU16().init()
    for v in _u16():
        CountU16().update(u16, RowU16(v))
    assert_equal(CountU16().finalize(u16), Int64(4))
    _check_cuts[DType.uint16](CountU16(), "CountU16", _u16(), Int64(4))

    var u32 = CountU32().init()
    for v in _u32():
        CountU32().update(u32, RowU32(v))
    assert_equal(CountU32().finalize(u32), Int64(4))
    _check_cuts[DType.uint32](CountU32(), "CountU32", _u32(), Int64(4))

    var u64 = CountU64().init()
    for v in _u64():
        CountU64().update(u64, RowU64(v))
    assert_equal(CountU64().finalize(u64), Int64(4))
    _check_cuts[DType.uint64](CountU64(), "CountU64", _u64(), Int64(4))

    var f32 = CountF32().init()
    for v in _f32():
        CountF32().update(f32, RowF32(v))
    assert_equal(CountF32().finalize(f32), Int64(4))
    _check_cuts[DType.float32](CountF32(), "CountF32", _f32(), Int64(4))

    var f64 = CountF64().init()
    assert_equal(CountF64().finalize(f64), Int64(0))
    for v in _f64():
        CountF64().update(f64, RowF64(v))
    assert_equal(CountF64().finalize(f64), Int64(4))
    _check_cuts[DType.float64](CountF64(), "CountF64", _f64(), Int64(4))


# =============================================================================
# AVG
# =============================================================================


def test_avg_signed() raises:
    """AVG over i8/i16/i32/i64 = exact SUM / COUNT as Float64."""
    var a8 = AvgI8().init()
    for v in _i8():
        AvgI8().update(a8, RowI8(v))
    assert_equal(AvgI8().finalize(a8), Float64(50.0))
    _check_cuts[DType.int8](AvgI8(), "AvgI8", _i8(), Float64(50.0))

    var a16 = AvgI16().init()
    for v in _i16():
        AvgI16().update(a16, RowI16(v))
    assert_equal(AvgI16().finalize(a16), Float64(15000.0))
    _check_cuts[DType.int16](AvgI16(), "AvgI16", _i16(), Float64(15000.0))

    var a32 = AvgI32().init()
    for v in _i32():
        AvgI32().update(a32, RowI32(v))
    assert_equal(AvgI32().finalize(a32), Float64(1000000000.0))
    _check_cuts[DType.int32](AvgI32(), "AvgI32", _i32(), Float64(1000000000.0))

    var a64 = AvgI64().init()
    for v in _i64():
        AvgI64().update(a64, RowI64(v))
    assert_equal(AvgI64().finalize(a64), Float64(1000000000001.0))
    _check_cuts[DType.int64](AvgI64(), "AvgI64", _i64(), Float64(1000000000001.0))
    # A mean that is not an integer: (1 + 2) / 2.
    var half: List[Int64] = [Int64(1), Int64(2)]
    _check_cuts[DType.int64](AvgI64(), "AvgI64 1.5", half, Float64(1.5))


def test_avg_unsigned() raises:
    """AVG over u8/u16/u32/u64 = exact SUM / COUNT as Float64."""
    var a8 = AvgU8().init()
    for v in _u8():
        AvgU8().update(a8, RowU8(v))
    assert_equal(AvgU8().finalize(a8), Float64(128.0))
    _check_cuts[DType.uint8](AvgU8(), "AvgU8", _u8(), Float64(128.0))

    var a16 = AvgU16().init()
    for v in _u16():
        AvgU16().update(a16, RowU16(v))
    assert_equal(AvgU16().finalize(a16), Float64(32768.0))
    _check_cuts[DType.uint16](AvgU16(), "AvgU16", _u16(), Float64(32768.0))

    var a32 = AvgU32().init()
    for v in _u32():
        AvgU32().update(a32, RowU32(v))
    assert_equal(AvgU32().finalize(a32), Float64(2147483648.0))
    _check_cuts[DType.uint32](AvgU32(), "AvgU32", _u32(), Float64(2147483648.0))

    var a64 = AvgU64().init()
    for v in _u64():
        AvgU64().update(a64, RowU64(v))
    assert_equal(AvgU64().finalize(a64), Float64(2251799813685249.0))
    _check_cuts[DType.uint64](AvgU64(), "AvgU64", _u64(), Float64(2251799813685249.0))


def test_avg_float() raises:
    """AVG over f32 sums in Float64 (mean 4194305, which a Float32 sum of the
    same list cannot give); AVG over f64 is the plain mean."""
    var a32 = AvgF32().init()
    for v in _f32():
        AvgF32().update(a32, RowF32(v))
    assert_equal(AvgF32().finalize(a32), Float64(4194305.0))
    _check_cuts[DType.float32](AvgF32(), "AvgF32", _f32(), Float64(4194305.0))

    var a64 = AvgF64().init()
    for v in _f64():
        AvgF64().update(a64, RowF64(v))
    assert_equal(AvgF64().finalize(a64), Float64(1.0))
    _check_cuts[DType.float64](AvgF64(), "AvgF64", _f64(), Float64(1.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
