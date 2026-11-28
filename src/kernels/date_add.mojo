# =============================================================================
# date_add — move a DATE32 column by a constant number of months and days
# =============================================================================
#
# `date32_add_months_days(arr, months, days)` shifts every date of a DATE32
# column (Int32 days since 1970-01-01) by `months` calendar months and then by
# `days` days, as DuckDB does for `date + INTERVAL`:
#
#   * the month shift keeps the day of the month and clamps it to the last day
#     of the target month (2024-01-31 + 1 month = 2024-02-29,
#     2023-01-31 + 1 month = 2023-02-28, 2024-02-29 - 12 months = 2023-02-28);
#   * the day shift is then plain integer addition;
#   * a NULL row stays NULL, and a sliced input keeps its validity window.
#
# A result that does not fit Int32 days (the DATE32 range) raises
# `date32_add_months_days: result out of range for DATE32`.
#
# `date32_to_timestamp_us(arr)` widens a DATE32 column to TIMESTAMP_US at
# midnight (days * 86_400_000_000 microseconds). A day count whose microsecond
# value does not fit Int64 raises
# `date32_to_timestamp_us: result out of range for TIMESTAMP_US`.
#
# Both kernels are serial and validity-preserving, like the extract kernels in
# `temporal_extract`.
# =============================================================================

from arrow.primitive_array import PrimitiveArray

from .temporal_extract import (
    _civil_from_days,
    _clone_validity_to_out_i32,
    _clone_validity_to_out_i64,
    _days_from_civil,
    _div_floor,
)

comptime _MICROS_PER_DAY: Int = 86_400_000_000
comptime _MAX_DAYS_FOR_MICROS: Int = 106_751_991  # floor(Int64.MAX / _MICROS_PER_DAY)


@always_inline
def _is_leap_year(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


@always_inline
def _days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _is_leap_year(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def date32_add_months_days(
    arr: PrimitiveArray[DType.int32], months: Int32, days: Int32
) raises -> PrimitiveArray[DType.int32]:
    """Shift each DATE32 row by `months` calendar months (day of month clamped
    to the target month's last day) and then by `days` days. NULL rows stay
    NULL; raises when a result does not fit Int32 days."""
    var n = arr.length
    var out = PrimitiveArray[DType.int32].allocate(n)
    var m_shift = Int(months)
    var d_shift = Int(days)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int32](0))
            continue
        var v = Int(arr.get(i))
        if m_shift != 0:
            var ymd = _civil_from_days(v)
            var total = ymd[0] * 12 + (ymd[1] - 1) + m_shift
            var ny = _div_floor(total, 12)
            var nm = total - ny * 12 + 1
            var dim = _days_in_month(ny, nm)
            var nd = ymd[2] if ymd[2] < dim else dim
            v = _days_from_civil(ny, nm, nd)
        v += d_shift
        if v < -2147483648 or v > 2147483647:
            raise Error("date32_add_months_days: result out of range for DATE32")
        out.set(i, Scalar[DType.int32](Int32(v)))
    _clone_validity_to_out_i32(n, arr.offset, arr.validity, out)
    return out^


def date32_to_timestamp_us(arr: PrimitiveArray[DType.int32]) raises -> PrimitiveArray[DType.int64]:
    """Widen each DATE32 row to TIMESTAMP_US at midnight. NULL rows stay NULL;
    raises when a result does not fit Int64 microseconds."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
            continue
        var v = Int(arr.get(i))
        if v > _MAX_DAYS_FOR_MICROS or v < -_MAX_DAYS_FOR_MICROS:
            raise Error("date32_to_timestamp_us: result out of range for TIMESTAMP_US")
        out.set(i, Scalar[DType.int64](Int64(v * _MICROS_PER_DAY)))
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^
