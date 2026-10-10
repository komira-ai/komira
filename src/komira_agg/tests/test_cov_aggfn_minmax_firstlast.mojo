# =============================================================================
# test_cov_aggfn_minmax_firstlast.mojo — MIN / MAX / FIRST / LAST cells
# =============================================================================
#
# The oracle, worked out by hand over a fixed list of non-null values (the
# caller filters nulls before `update`):
#   MIN(x) / MAX(x) = the least / greatest value, in the input type. The
#     integer lists hold the type's own extremes, so a cell whose sentinel or
#     comparison is off by one end gives a different answer.
#   FIRST(x) / LAST(x) = the first / last value in arrival order (DuckDB's
#     `first` / `last`; `merge(a, b)` means partial `a` arrived before `b`).
#
# Every cell is driven through `update` (row struct), `update_scalar`, and
# `merge` of two partials at EVERY cut of the list, so each `merge` arm runs:
# the unseen partial on the left (cut 0), on the right (cut n), and both seen
# with the answer in either partial.
#
# Float lists are finite and hold no -0.0: the NaN order and the sign of
# zero are not settled for these cells, so they are not pinned here.
# MIN/MAX/FIRST/LAST of a group with no rows (SQL NULL) is not pinned either:
# `finalize` returns the state's value whatever `seen` says.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_udf.agg_fn import AggFn
from komira_agg.builtin_agg_fns_states import (
    RowI8, RowI16, RowI32, RowI64,
    RowU8, RowU16, RowU32, RowU64,
    RowF32, RowF64,
)
from komira_agg.builtin_agg_fns_minmax import (
    MinI8, MinI16, MinI32, MinI64, MinU8, MinU16, MinU32, MinU64, MinF32, MinF64,
    MaxI8, MaxI16, MaxI32, MaxI64, MaxU8, MaxU16, MaxU32, MaxU64, MaxF32, MaxF64,
)
from komira_agg.builtin_agg_fns_firstlast import (
    FirstI8, FirstI16, FirstI32, FirstI64,
    FirstU8, FirstU16, FirstU32, FirstU64, FirstF32, FirstF64,
    LastI8, LastI16, LastI32, LastI64,
    LastU8, LastU16, LastU32, LastU64, LastF32, LastF64,
)


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


# The lists: [5, low, high, 3]. MIN is `low`, MAX `high`, FIRST 5, LAST 3.
# Cut 1 puts MIN/MAX in the right partial, cut 3 in the left one.


def _i8() -> List[Int8]:
    return [Int8(5), Int8(-128), Int8(127), Int8(3)]


def _i16() -> List[Int16]:
    return [Int16(5), Int16(-32768), Int16(32767), Int16(3)]


def _i32() -> List[Int32]:
    return [Int32(5), Int32(-2147483648), Int32(2147483647), Int32(3)]


def _i64() -> List[Int64]:
    return [Int64(5), Int64.MIN, Int64.MAX, Int64(3)]


def _u8() -> List[UInt8]:
    return [UInt8(5), UInt8(0), UInt8(255), UInt8(3)]


def _u16() -> List[UInt16]:
    return [UInt16(5), UInt16(0), UInt16(65535), UInt16(3)]


def _u32() -> List[UInt32]:
    return [UInt32(5), UInt32(0), UInt32(4294967295), UInt32(3)]


def _u64() -> List[UInt64]:
    return [UInt64(5), UInt64(0), UInt64.MAX, UInt64(3)]


def _f32() -> List[Float32]:
    return [Float32(2.5), Float32(-1.5), Float32(3.25), Float32(0.5)]


def _f64() -> List[Float64]:
    return [Float64(2.5), Float64(-1.5), Float64(3.25), Float64(0.5)]


# =============================================================================
# MIN
# =============================================================================


def test_min_signed() raises:
    var s8 = MinI8().init()
    MinI8().update(s8, RowI8(Int8(5)))
    MinI8().update(s8, RowI8(Int8(-7)))
    assert_equal(MinI8().finalize(s8), Int8(-7))
    _check_cuts[DType.int8](MinI8(), "MinI8", _i8(), Int8(-128))

    var s16 = MinI16().init()
    MinI16().update(s16, RowI16(Int16(5)))
    assert_equal(MinI16().finalize(s16), Int16(5))
    _check_cuts[DType.int16](MinI16(), "MinI16", _i16(), Int16(-32768))

    var s32 = MinI32().init()
    MinI32().update(s32, RowI32(Int32(5)))
    assert_equal(MinI32().finalize(s32), Int32(5))
    _check_cuts[DType.int32](MinI32(), "MinI32", _i32(), Int32(-2147483648))

    var s64 = MinI64().init()
    MinI64().update(s64, RowI64(Int64(5)))
    assert_equal(MinI64().finalize(s64), Int64(5))
    _check_cuts[DType.int64](MinI64(), "MinI64", _i64(), Int64.MIN)


def test_min_unsigned() raises:
    var s8 = MinU8().init()
    MinU8().update(s8, RowU8(UInt8(5)))
    assert_equal(MinU8().finalize(s8), UInt8(5))
    _check_cuts[DType.uint8](MinU8(), "MinU8", _u8(), UInt8(0))

    var s16 = MinU16().init()
    MinU16().update(s16, RowU16(UInt16(5)))
    assert_equal(MinU16().finalize(s16), UInt16(5))
    _check_cuts[DType.uint16](MinU16(), "MinU16", _u16(), UInt16(0))

    var s32 = MinU32().init()
    MinU32().update(s32, RowU32(UInt32(5)))
    assert_equal(MinU32().finalize(s32), UInt32(5))
    _check_cuts[DType.uint32](MinU32(), "MinU32", _u32(), UInt32(0))

    var s64 = MinU64().init()
    MinU64().update(s64, RowU64(UInt64(5)))
    assert_equal(MinU64().finalize(s64), UInt64(5))
    _check_cuts[DType.uint64](MinU64(), "MinU64", _u64(), UInt64(0))


def test_min_float_finite() raises:
    var s32 = MinF32().init()
    MinF32().update(s32, RowF32(Float32(2.5)))
    assert_equal(MinF32().finalize(s32), Float32(2.5))
    _check_cuts[DType.float32](MinF32(), "MinF32", _f32(), Float32(-1.5))

    var s64 = MinF64().init()
    MinF64().update(s64, RowF64(Float64(2.5)))
    assert_equal(MinF64().finalize(s64), Float64(2.5))
    _check_cuts[DType.float64](MinF64(), "MinF64", _f64(), Float64(-1.5))


# =============================================================================
# MAX
# =============================================================================


def test_max_signed() raises:
    var s8 = MaxI8().init()
    MaxI8().update(s8, RowI8(Int8(-7)))
    MaxI8().update(s8, RowI8(Int8(5)))
    assert_equal(MaxI8().finalize(s8), Int8(5))
    _check_cuts[DType.int8](MaxI8(), "MaxI8", _i8(), Int8(127))

    var s16 = MaxI16().init()
    MaxI16().update(s16, RowI16(Int16(5)))
    assert_equal(MaxI16().finalize(s16), Int16(5))
    _check_cuts[DType.int16](MaxI16(), "MaxI16", _i16(), Int16(32767))

    var s32 = MaxI32().init()
    MaxI32().update(s32, RowI32(Int32(5)))
    assert_equal(MaxI32().finalize(s32), Int32(5))
    _check_cuts[DType.int32](MaxI32(), "MaxI32", _i32(), Int32(2147483647))

    var s64 = MaxI64().init()
    MaxI64().update(s64, RowI64(Int64(5)))
    assert_equal(MaxI64().finalize(s64), Int64(5))
    _check_cuts[DType.int64](MaxI64(), "MaxI64", _i64(), Int64.MAX)


def test_max_unsigned() raises:
    var s8 = MaxU8().init()
    MaxU8().update(s8, RowU8(UInt8(5)))
    assert_equal(MaxU8().finalize(s8), UInt8(5))
    _check_cuts[DType.uint8](MaxU8(), "MaxU8", _u8(), UInt8(255))

    var s16 = MaxU16().init()
    MaxU16().update(s16, RowU16(UInt16(5)))
    assert_equal(MaxU16().finalize(s16), UInt16(5))
    _check_cuts[DType.uint16](MaxU16(), "MaxU16", _u16(), UInt16(65535))

    var s32 = MaxU32().init()
    MaxU32().update(s32, RowU32(UInt32(5)))
    assert_equal(MaxU32().finalize(s32), UInt32(5))
    _check_cuts[DType.uint32](MaxU32(), "MaxU32", _u32(), UInt32(4294967295))

    var s64 = MaxU64().init()
    MaxU64().update(s64, RowU64(UInt64(5)))
    assert_equal(MaxU64().finalize(s64), UInt64(5))
    _check_cuts[DType.uint64](MaxU64(), "MaxU64", _u64(), UInt64.MAX)


def test_max_float_finite() raises:
    var s32 = MaxF32().init()
    MaxF32().update(s32, RowF32(Float32(-1.5)))
    assert_equal(MaxF32().finalize(s32), Float32(-1.5))
    _check_cuts[DType.float32](MaxF32(), "MaxF32", _f32(), Float32(3.25))

    var s64 = MaxF64().init()
    MaxF64().update(s64, RowF64(Float64(-1.5)))
    assert_equal(MaxF64().finalize(s64), Float64(-1.5))
    _check_cuts[DType.float64](MaxF64(), "MaxF64", _f64(), Float64(3.25))


def test_min_max_one_value_at_the_sentinel() raises:
    """A group whose only value equals the cell's sentinel still answers that
    value, and merging it with an empty partial keeps it."""
    var mn = MinI8().init()
    MinI8().update_scalar(mn, Int8(127))
    assert_equal(MinI8().finalize(MinI8().merge(MinI8().init(), mn)), Int8(127))
    var mx = MaxU64().init()
    MaxU64().update_scalar(mx, UInt64(0))
    assert_equal(MaxU64().finalize(MaxU64().merge(mx, MaxU64().init())), UInt64(0))


# =============================================================================
# FIRST
# =============================================================================


def test_first_every_type() raises:
    """FIRST = the first value in arrival order (5 for every list)."""
    var s8 = FirstI8().init()
    FirstI8().update(s8, RowI8(Int8(-9)))
    FirstI8().update(s8, RowI8(Int8(4)))
    assert_equal(FirstI8().finalize(s8), Int8(-9))
    _check_cuts[DType.int8](FirstI8(), "FirstI8", _i8(), Int8(5))

    var s16 = FirstI16().init()
    FirstI16().update(s16, RowI16(Int16(-9)))
    assert_equal(FirstI16().finalize(s16), Int16(-9))
    _check_cuts[DType.int16](FirstI16(), "FirstI16", _i16(), Int16(5))

    var s32 = FirstI32().init()
    FirstI32().update(s32, RowI32(Int32(-9)))
    assert_equal(FirstI32().finalize(s32), Int32(-9))
    _check_cuts[DType.int32](FirstI32(), "FirstI32", _i32(), Int32(5))

    var s64 = FirstI64().init()
    FirstI64().update(s64, RowI64(Int64(-9)))
    assert_equal(FirstI64().finalize(s64), Int64(-9))
    _check_cuts[DType.int64](FirstI64(), "FirstI64", _i64(), Int64(5))

    var u8 = FirstU8().init()
    FirstU8().update(u8, RowU8(UInt8(9)))
    assert_equal(FirstU8().finalize(u8), UInt8(9))
    _check_cuts[DType.uint8](FirstU8(), "FirstU8", _u8(), UInt8(5))

    var u16 = FirstU16().init()
    FirstU16().update(u16, RowU16(UInt16(9)))
    assert_equal(FirstU16().finalize(u16), UInt16(9))
    _check_cuts[DType.uint16](FirstU16(), "FirstU16", _u16(), UInt16(5))

    var u32 = FirstU32().init()
    FirstU32().update(u32, RowU32(UInt32(9)))
    assert_equal(FirstU32().finalize(u32), UInt32(9))
    _check_cuts[DType.uint32](FirstU32(), "FirstU32", _u32(), UInt32(5))

    var u64 = FirstU64().init()
    FirstU64().update(u64, RowU64(UInt64(9)))
    assert_equal(FirstU64().finalize(u64), UInt64(9))
    _check_cuts[DType.uint64](FirstU64(), "FirstU64", _u64(), UInt64(5))

    var f32 = FirstF32().init()
    FirstF32().update(f32, RowF32(Float32(0.75)))
    assert_equal(FirstF32().finalize(f32), Float32(0.75))
    _check_cuts[DType.float32](FirstF32(), "FirstF32", _f32(), Float32(2.5))

    var f64 = FirstF64().init()
    FirstF64().update(f64, RowF64(Float64(0.75)))
    assert_equal(FirstF64().finalize(f64), Float64(0.75))
    _check_cuts[DType.float64](FirstF64(), "FirstF64", _f64(), Float64(2.5))


# =============================================================================
# LAST
# =============================================================================


def test_last_every_type() raises:
    """LAST = the last value in arrival order (3 / 0.5 for every list)."""
    var s8 = LastI8().init()
    LastI8().update(s8, RowI8(Int8(4)))
    LastI8().update(s8, RowI8(Int8(-9)))
    assert_equal(LastI8().finalize(s8), Int8(-9))
    _check_cuts[DType.int8](LastI8(), "LastI8", _i8(), Int8(3))

    var s16 = LastI16().init()
    LastI16().update(s16, RowI16(Int16(-9)))
    assert_equal(LastI16().finalize(s16), Int16(-9))
    _check_cuts[DType.int16](LastI16(), "LastI16", _i16(), Int16(3))

    var s32 = LastI32().init()
    LastI32().update(s32, RowI32(Int32(-9)))
    assert_equal(LastI32().finalize(s32), Int32(-9))
    _check_cuts[DType.int32](LastI32(), "LastI32", _i32(), Int32(3))

    var s64 = LastI64().init()
    LastI64().update(s64, RowI64(Int64(-9)))
    assert_equal(LastI64().finalize(s64), Int64(-9))
    _check_cuts[DType.int64](LastI64(), "LastI64", _i64(), Int64(3))

    var u8 = LastU8().init()
    LastU8().update(u8, RowU8(UInt8(9)))
    assert_equal(LastU8().finalize(u8), UInt8(9))
    _check_cuts[DType.uint8](LastU8(), "LastU8", _u8(), UInt8(3))

    var u16 = LastU16().init()
    LastU16().update(u16, RowU16(UInt16(9)))
    assert_equal(LastU16().finalize(u16), UInt16(9))
    _check_cuts[DType.uint16](LastU16(), "LastU16", _u16(), UInt16(3))

    var u32 = LastU32().init()
    LastU32().update(u32, RowU32(UInt32(9)))
    assert_equal(LastU32().finalize(u32), UInt32(9))
    _check_cuts[DType.uint32](LastU32(), "LastU32", _u32(), UInt32(3))

    var u64 = LastU64().init()
    LastU64().update(u64, RowU64(UInt64(9)))
    assert_equal(LastU64().finalize(u64), UInt64(9))
    _check_cuts[DType.uint64](LastU64(), "LastU64", _u64(), UInt64(3))

    var f32 = LastF32().init()
    LastF32().update(f32, RowF32(Float32(0.75)))
    assert_equal(LastF32().finalize(f32), Float32(0.75))
    _check_cuts[DType.float32](LastF32(), "LastF32", _f32(), Float32(0.5))

    var f64 = LastF64().init()
    LastF64().update(f64, RowF64(Float64(0.75)))
    assert_equal(LastF64().finalize(f64), Float64(0.75))
    _check_cuts[DType.float64](LastF64(), "LastF64", _f64(), Float64(0.5))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
