# =============================================================================
# temporal_epoch — the whole instant as a count since 1970-01-01 00:00:00
# =============================================================================
#
# The kernels of `epoch(x)` (DOUBLE seconds), `epoch_ms(x)` and `epoch_us(x)`
# (BIGINT) over DATE32 (Int32 days) and TIMESTAMP_* (Int64 ticks in seconds,
# milliseconds, microseconds or nanoseconds). They are the inverse of the
# `make_timestamp` relabel.
#
# DuckDB v1.5.5 is the reference (measured):
#
#     epoch(TIMESTAMP '2026-09-01 00:00:00.123456')       = 1788220800.123456
#     epoch(TIMESTAMP '1969-12-31 23:59:59.9995')         = -0.0005
#     epoch_ms(TIMESTAMP '1969-12-31 23:59:59.9995')      = 0
#     epoch_us(TIMESTAMP '1969-12-31 23:59:59.9995')      = -500
#     epoch_ms(TIMESTAMP_NS '1969-12-31 23:59:59.998999999') = -1
#     epoch(DATE '2026-09-01')                            = 1788220800.0
#     epoch_ms(DATE '1969-12-31')                         = -86400000
#     epoch_us(DATE '5000000-01-01')  -> Conversion Error
#
# So a TIMESTAMP is first brought to MICROSECONDS — TIMESTAMP_NS divides by
# 1000 TRUNCATING TOWARD ZERO, TIMESTAMP_S and TIMESTAMP_MS multiply and raise
# when the product leaves BIGINT — and then:
#
#   epoch_us = that microsecond count;
#   epoch_ms = it divided by 1000, TRUNCATING TOWARD ZERO (not floor: the
#              half-millisecond before 1970 is 0, not -1);
#   epoch    = Float64(it) / 1e6.
#
# A DATE is a whole number of days, so it needs no division: seconds are
# `days * 86400` (as DOUBLE), milliseconds `days * 86_400_000` (cannot leave
# BIGINT for an Int32 day count) and microseconds `days * 86_400_000_000`,
# which can, and raises.
#
# NULL in -> NULL out: a null row's data lane is 0 and is never computed on,
# so a garbage value under a null cannot raise an overflow.
#
# Public surface (PrimitiveArray in and out, no pointers):
#
#   epoch_us_ts(arr, src_unit)       -> PrimitiveArray[int64]
#   epoch_ms_ts(arr, src_unit)       -> PrimitiveArray[int64]
#   epoch_seconds_ts(arr, src_unit)  -> PrimitiveArray[float64]
#   epoch_us_date32(arr)             -> PrimitiveArray[int64]
#   epoch_ms_date32(arr)             -> PrimitiveArray[int64]
#   epoch_seconds_date32(arr)        -> PrimitiveArray[float64]
#
# Serial by design, like `temporal_extract`: these run per morsel.
# =============================================================================

from arrow.primitive_array import PrimitiveArray
from arrow.bitmap import Bitmap
from arrow.arrow_types import ArrowType


comptime _US_PER_SECOND: Int64 = 1_000_000
comptime _US_PER_MS: Int64 = 1_000
comptime _NS_PER_US: Int64 = 1_000
comptime _SECONDS_PER_DAY: Int64 = 86_400
comptime _MS_PER_DAY: Int64 = 86_400_000
comptime _US_PER_DAY: Int64 = 86_400_000_000
comptime _INT64_MAX: Int64 = 9_223_372_036_854_775_807


def _clone_validity[
    src_dt: DType, dt: DType
](src: PrimitiveArray[src_dt], mut out: PrimitiveArray[dt]) raises:
    """Copy `src`'s visible validity window onto `out` and its null count. A
    sliced array indexes its bitmap absolutely, so the window is
    `[src.offset, src.offset + src.length)`, rebased to bit 0."""
    if not src.validity:
        return
    ref src_bm = src.validity.value()
    var cloned = Bitmap.copy_slice_from(src_bm, src.offset, src.length)
    out.null_count = cloned.null_count()
    out.validity = cloned^


@always_inline
def div_trunc(a: Int64, b: Int64) -> Int64:
    """`a / b` rounded toward zero, for `b > 0` (C's integer division, which
    DuckDB's epoch kernels use). Mojo's `//` floors, so a negative dividend
    that is not a multiple of `b` is moved one step up."""
    var q = a // b
    if q * b != a and a < 0:
        q += 1
    return q


@always_inline
def _scale_up(v: Int64, factor: Int64, what: String) raises -> Int64:
    """`v * factor` for `factor > 0`, raising DuckDB's conversion error when
    the product leaves BIGINT. The bounds are `floor(MAX / factor)` and
    `ceil(MIN / factor)`, so the multiplication itself never wraps. The
    lower one is `-floor(MAX / factor)`: that equals `ceil(-2^63 / factor)`
    whenever 2^63 is not a multiple of `factor`, true of every factor here
    (each is a multiple of 5)."""
    var bound = _INT64_MAX // factor
    if v > bound or v < -bound:
        raise Error(
            "Conversion Error: Could not convert " + what + " "
            + String(v) + " to microseconds since 1970-01-01: the count does"
            " not fit in BIGINT"
        )
    return v * factor


@always_inline
def ts_to_micros(v: Int64, src_unit: ArrowType) raises -> Int64:
    """A TIMESTAMP_* tick count in microseconds: the step DuckDB takes before
    every epoch count. `TIMESTAMP` is the legacy alias of TIMESTAMP_US."""
    if src_unit == ArrowType.TIMESTAMP_US or src_unit == ArrowType.TIMESTAMP:
        return v
    if src_unit == ArrowType.TIMESTAMP_NS:
        return div_trunc(v, _NS_PER_US)
    if src_unit == ArrowType.TIMESTAMP_MS:
        return _scale_up(v, _US_PER_MS, "Timestamp(MS)")
    if src_unit == ArrowType.TIMESTAMP_S:
        return _scale_up(v, _US_PER_SECOND, "Timestamp(S)")
    raise Error(
        "temporal_epoch: unsupported timestamp unit type_id="
        + String(Int(src_unit.type_id))
    )


def epoch_us_ts(
    arr: PrimitiveArray[DType.int64], src_unit: ArrowType
) raises -> PrimitiveArray[DType.int64]:
    """`epoch_us` over a TIMESTAMP_* column: microseconds since 1970."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            out.set(i, Scalar[DType.int64](ts_to_micros(Int64(arr.get(i)), src_unit)))
    _clone_validity(arr, out)
    return out^


def epoch_ms_ts(
    arr: PrimitiveArray[DType.int64], src_unit: ArrowType
) raises -> PrimitiveArray[DType.int64]:
    """`epoch_ms` over a TIMESTAMP_* column: milliseconds since 1970,
    truncated toward zero."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var us = ts_to_micros(Int64(arr.get(i)), src_unit)
            out.set(i, Scalar[DType.int64](div_trunc(us, _US_PER_MS)))
    _clone_validity(arr, out)
    return out^


def epoch_seconds_ts(
    arr: PrimitiveArray[DType.int64], src_unit: ArrowType
) raises -> PrimitiveArray[DType.float64]:
    """`epoch` over a TIMESTAMP_* column: seconds since 1970 as DOUBLE, the
    microsecond count divided by 1e6."""
    var n = arr.length
    var out = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.float64](0.0))
        else:
            var us = ts_to_micros(Int64(arr.get(i)), src_unit)
            out.set(i, Scalar[DType.float64](Float64(us) / 1_000_000.0))
    _clone_validity(arr, out)
    return out^


def epoch_us_date32(
    arr: PrimitiveArray[DType.int32],
) raises -> PrimitiveArray[DType.int64]:
    """`epoch_us` over a DATE32 column: `days * 86_400_000_000`, raising when
    the date is too far from 1970 for a BIGINT microsecond count."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            out.set(i, Scalar[DType.int64](_scale_up(Int64(arr.get(i)), _US_PER_DAY, "DATE day")))
    _clone_validity(arr, out)
    return out^


def epoch_ms_date32(
    arr: PrimitiveArray[DType.int32],
) raises -> PrimitiveArray[DType.int64]:
    """`epoch_ms` over a DATE32 column: `days * 86_400_000` (an Int32 day
    count times that stays inside BIGINT)."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            out.set(i, Scalar[DType.int64](Int64(arr.get(i)) * _MS_PER_DAY))
    _clone_validity(arr, out)
    return out^


def epoch_seconds_date32(
    arr: PrimitiveArray[DType.int32],
) raises -> PrimitiveArray[DType.float64]:
    """`epoch` over a DATE32 column: `days * 86400` seconds as DOUBLE."""
    var n = arr.length
    var out = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.float64](0.0))
        else:
            out.set(i, Scalar[DType.float64](Float64(Int64(arr.get(i)) * _SECONDS_PER_DAY)))
    _clone_validity(arr, out)
    return out^
