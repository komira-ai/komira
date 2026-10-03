# =============================================================================
# komira_datetime/civil.mojo -- the civil (calendar) arithmetic
# =============================================================================
#
# Days count from 1970-01-01 (day 0), in the PROLEPTIC GREGORIAN calendar: the
# Gregorian rules are applied to every year, including those before 1582, and
# the year numbering is ASTRONOMICAL (ISO 8601): 1 BC is year 0 and 45 BC is
# year -44. There is no year-zero gap and no Julian switchover.
#
# Both directions are Howard Hinnant's closed forms ("chrono-Compatible
# Low-Level Date Algorithms"): constant time, no loops, no tables. They count
# from 0000-03-01 so the leap day is the LAST day of a shifted year.
#
# RANGE. Every function is exact for every input whose intermediate products
# fit a 64-bit `Int`. In practice: `civil_from_days` and `days_from_civil` are
# exact for years in [-10^9, 10^9] and far beyond (the 400-year era count is the
# only term that grows), and the epoch-second functions of timestamp.mojo are
# exact while `days * 86400` fits an `Int`, that is, for |year| below about
# 2.9 * 10^11. The tests sweep every day of years -1000..3000 against an
# independent closed form and pin the 10^9 boundary.
#
# ONE TRAP, NAMED. Mojo's `//` FLOORS (`-7 // 2 == -4`), unlike C's `/`. Hinnant's
# C text writes `(y >= 0 ? y : y - 399) / 400` to recover a floor from a
# truncating divide; copied into Mojo that subtracts a SECOND era and is wrong
# by one day for every year before 0000-03-01. This file uses the plain floor
# and `test_civil` pins a BC date that fails the double-floor spelling.
# =============================================================================


# Days from 0000-03-01 to 1970-01-01.
comptime _EPOCH_SHIFT = 719468
comptime _DAYS_PER_ERA = 146097  # one 400-year cycle


@fieldwise_init
struct CivilDate(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """A calendar date: `month` is 1..12 and `day` 1..31, `year` astronomical."""

    var year: Int
    var month: Int
    var day: Int


def is_leap_year(year: Int) -> Bool:
    """The Gregorian rule: divisible by 4, except centuries not divisible by 400."""
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0


def days_in_month(year: Int, month: Int) -> Int:
    """The length of `month` (1..12) of `year`; 0 for a month outside 1..12."""
    if month == 2:
        return 29 if is_leap_year(year) else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    if month >= 1 and month <= 12:
        return 31
    return 0


@always_inline
def days_from_civil(year: Int, month: Int, day: Int) -> Int:
    """Days since 1970-01-01 of the date (year, month, day).

    UNCHECKED: a month outside 1..12 or a day outside the month is not refused
    (the result is the arithmetic continuation, e.g. day 32 of January is
    February 1). Use `days_from_date` to refuse them."""
    var y = year - 1 if month <= 2 else year
    var era = y // 400
    var yoe = y - era * 400  # [0, 399]
    var mp = month - 3 if month > 2 else month + 9  # March = 0
    var doy = (153 * mp + 2) // 5 + day - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy  # [0, 146096]
    return era * _DAYS_PER_ERA + doe - _EPOCH_SHIFT


def civil_from_days(days: Int) -> CivilDate:
    """The date of a day count since 1970-01-01; the inverse of
    `days_from_civil` for every valid date."""
    var z = days + _EPOCH_SHIFT
    var era = z // _DAYS_PER_ERA
    var doe = z - era * _DAYS_PER_ERA  # [0, 146096]
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    return CivilDate(y + 1 if m <= 2 else y, m, d)


def days_from_date(year: Int, month: Int, day: Int) raises -> Int:
    """Days since 1970-01-01 of a date that must EXIST: a month outside 1..12
    or a day outside its month (30 February, 29 February of a common year)
    raises."""
    if month < 1 or month > 12:
        raise Error("month " + String(month) + " is outside 1..12")
    if day < 1 or day > days_in_month(year, month):
        raise Error(
            "day "
            + String(day)
            + " does not exist in month "
            + String(month)
            + " of year "
            + String(year)
        )
    return days_from_civil(year, month, day)


def weekday_from_days(days: Int) -> Int:
    """The day of the week of a day count: 0 = Sunday .. 6 = Saturday
    (1970-01-01 was a Thursday)."""
    return (days + 4) % 7
