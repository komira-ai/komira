# =============================================================================
# parse_date — ISO 8601 date string → Int32 days-since-epoch parser
# =============================================================================
#
# JSON has no native
# date literal; the convention is an ISO 8601 calendar date "YYYY-MM-DD"
# string. The Stage 2 walker hits this for any DATE32 column.
#
# Public surface:
#   - `parse_date32(bytes, start, end) raises -> Int32`
#       Parse `bytes[start..end]` as ISO 8601 "YYYY-MM-DD"; return days
#       since 1970-01-01 (Arrow DATE32 convention).
#
# Grammar:
#   YYYY-MM-DD     where YYYY is 4-digit year (0-9999),
#                  MM is 01..12, DD is 01..end-of-month.
# Exact ISO only; other formats ("YYYY/MM/DD", "DD-MM-YYYY", a custom
# `date_format` per `Field._date_format`) are not accepted.
#
# Encapsulation:
#   - `Span[UInt8, _]` + Int32 return; no UnsafePointer.
#
# Algorithm:
#   1. Validate len == 10.
#   2. Validate positions 4 + 7 are '-'.
#   3. Parse 4-digit year, 2-digit month, 2-digit day.
#   4. Compute days-since-epoch via Howard Hinnant's date algorithm
#      ("Number of Days Between Two Dates" — Anderson, Hinnant 2020).
#      For a Gregorian-calendar (Year, Month, Day) tuple, days from
#      1970-01-01:
#         y = Year - (Month <= 2)
#         era = floor(y / 400)    (the C++ form adjusts y-399 for
#                                  truncating division; Mojo's // floors)
#         yoe = (y - era*400)                              [0, 399]
#         doy = (153*(Month + (Month > 2 ? -3 : 9)) + 2) / 5 + Day - 1
#         doe = yoe*365 + yoe/4 - yoe/100 + doy            [0, 146096]
#         days = era*146097 + doe - 719468
# =============================================================================


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)


def parse_date32(bytes: Span[UInt8, _], start: Int, end: Int) raises -> Int32:
    """Parse `bytes[start..end]` as ISO 8601 "YYYY-MM-DD" and return
    days since the Unix epoch (1970-01-01).

    Raises on:
      * Wrong length (not exactly 10 bytes).
      * Missing '-' at position 4 or 7.
      * Non-digit in YYYY / MM / DD.
      * Out-of-range month or day for the given month.
    """
    if end - start != 10:
        raise Error("parse_date32: expected 10 bytes (YYYY-MM-DD), got " + String(end - start))
    # Positions: 0123-56-89
    if bytes[start + 4] != UInt8(0x2D) or bytes[start + 7] != UInt8(0x2D):
        raise Error("parse_date32: missing '-' separator (expected YYYY-MM-DD)")
    # Parse YYYY.
    var year: Int = 0
    for k in range(4):
        var b = bytes[start + k]
        if not _is_digit(b):
            raise Error("parse_date32: non-digit in year at position " + String(start + k))
        year = year * 10 + (Int(b) - 0x30)
    # Parse MM.
    var month: Int = 0
    for k in range(2):
        var b = bytes[start + 5 + k]
        if not _is_digit(b):
            raise Error("parse_date32: non-digit in month at position " + String(start + 5 + k))
        month = month * 10 + (Int(b) - 0x30)
    # Parse DD.
    var day: Int = 0
    for k in range(2):
        var b = bytes[start + 8 + k]
        if not _is_digit(b):
            raise Error("parse_date32: non-digit in day at position " + String(start + 8 + k))
        day = day * 10 + (Int(b) - 0x30)

    if month < 1 or month > 12:
        raise Error("parse_date32: month out of range [1, 12]: " + String(month))
    var max_day = _max_day_in_month(year, month)
    if day < 1 or day > max_day:
        raise Error("parse_date32: day out of range for year=" + String(year) + " month=" + String(month) + ": " + String(day))

    return Int32(_days_from_civil(year, month, day))


def _max_day_in_month(year: Int, month: Int) -> Int:
    """Return the number of days in `month` for the given Gregorian
    `year`."""
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    if month == 2:
        if _is_leap_year(year):
            return 29
        return 28
    return 31


def _is_leap_year(y: Int) -> Bool:
    """Gregorian leap year rule: divisible by 4, but not by 100 unless
    also by 400."""
    if (y % 400) == 0:
        return True
    if (y % 100) == 0:
        return False
    return (y % 4) == 0


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Howard Hinnant's days_from_civil algorithm. Returns days since
    1970-01-01 (negative for earlier dates)."""
    var y_adj = y if m > 2 else (y - 1)
    # Mojo's `//` floors: no C++ `y - 399` adjustment for negative years.
    var era = y_adj // 400
    var yoe = y_adj - era * 400  # [0, 399]
    var m_off = m + (-3 if m > 2 else 9)
    var doy = (153 * m_off + 2) // 5 + d - 1  # [0, 365]
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy  # [0, 146096]
    return era * 146097 + doe - 719468
