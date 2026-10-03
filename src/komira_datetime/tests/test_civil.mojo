# =============================================================================
# test_civil.mojo -- the civil calendar against an independent oracle
# =============================================================================
#
# The oracle is a WALKER: it starts at 1970-01-01 (day 0, a Thursday) and steps
# one day at a time, rolling the day into the month and the month into the year
# with `is_leap` written out here, forward to 3000 and backward to -1000. It
# shares no formula with `days_from_civil` / `civil_from_days`, so agreement on
# every one of ~1.5 million days is two independent derivations meeting.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_datetime import (
    CivilDate,
    is_leap_year,
    days_in_month,
    days_from_civil,
    civil_from_days,
    days_from_date,
    weekday_from_days,
)


def _leap(y: Int) -> Bool:
    if y % 400 == 0:
        return True
    if y % 100 == 0:
        return False
    return y % 4 == 0


def _mdays(y: Int, m: Int) -> Int:
    if m == 2:
        return 29 if _leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _check(day: Int, y: Int, m: Int, d: Int, wd: Int) raises:
    var c = civil_from_days(day)
    if c.year != y or c.month != m or c.day != d:
        raise Error(
            "civil_from_days("
            + String(day)
            + ") = "
            + String(c.year)
            + "-"
            + String(c.month)
            + "-"
            + String(c.day)
            + ", walker says "
            + String(y)
            + "-"
            + String(m)
            + "-"
            + String(d)
        )
    if days_from_civil(y, m, d) != day:
        raise Error(
            "days_from_civil("
            + String(y)
            + ","
            + String(m)
            + ","
            + String(d)
            + ") != "
            + String(day)
        )
    if weekday_from_days(day) != wd:
        raise Error("weekday of day " + String(day) + " is not " + String(wd))


def test_every_day_against_the_walker() raises:
    # Forward from 1970-01-01 to 2999-12-31.
    var y = 1970
    var m = 1
    var d = 1
    var wd = 4  # Thursday
    var day = 0
    var count = 0
    while y < 3000:
        _check(day, y, m, d, wd)
        count += 1
        day += 1
        wd = (wd + 1) % 7
        d += 1
        if d > _mdays(y, m):
            d = 1
            m += 1
            if m > 12:
                m = 1
                y += 1
    # Backward from 1969-12-31 to -1000-01-01.
    y = 1969
    m = 12
    d = 31
    wd = 3  # Wednesday
    day = -1
    while y >= -1000:
        _check(day, y, m, d, wd)
        count += 1
        day -= 1
        wd = (wd + 6) % 7
        d -= 1
        if d < 1:
            m -= 1
            if m < 1:
                m = 12
                y -= 1
            d = _mdays(y, m)
    assert_true(count > 1_400_000)


def test_known_days() raises:
    assert_equal(days_from_civil(1970, 1, 1), 0)
    assert_equal(days_from_civil(1969, 12, 31), -1)
    assert_equal(days_from_civil(2000, 3, 1), 11017)
    assert_equal(days_from_civil(1998, 9, 2), 10471)
    assert_equal(days_from_civil(2038, 1, 19), 24855)
    assert_equal(days_from_civil(1, 1, 1), -719162)
    assert_equal(days_from_civil(0, 3, 1), -719468)
    assert_equal(days_from_civil(9999, 12, 31), 2932896)
    # A BC date, from the DuckDB reference value the engine's own test pins.
    # The C spelling of the era (`(y if y >= 0 else y - 399) // 400`) subtracts
    # a second era under Mojo's flooring `//` and answers -735600.
    assert_equal(days_from_civil(-44, 1, 1), -735599)
    var c = civil_from_days(-735599)
    assert_equal(c.year, -44)
    assert_equal(c.month, 1)
    assert_equal(c.day, 1)
    # Day -719469 is 0000-02-29 (year 0 is a leap year): the last day before
    # the algorithm's own epoch.
    var leap_day = civil_from_days(-719469)
    assert_equal(leap_day.year, 0)
    assert_equal(leap_day.month, 2)
    assert_equal(leap_day.day, 29)


def test_leap_years() raises:
    assert_true(is_leap_year(2000))
    assert_true(is_leap_year(1600))
    assert_true(is_leap_year(2400))
    assert_true(is_leap_year(2024))
    assert_true(is_leap_year(0))
    assert_true(is_leap_year(-4))
    assert_true(is_leap_year(-400))
    assert_true(not is_leap_year(1900))
    assert_true(not is_leap_year(2100))
    assert_true(not is_leap_year(2200))
    assert_true(not is_leap_year(2023))
    assert_true(not is_leap_year(-100))
    assert_true(not is_leap_year(1))
    assert_equal(days_in_month(1900, 2), 28)
    assert_equal(days_in_month(2000, 2), 29)
    assert_equal(days_in_month(2100, 2), 28)
    assert_equal(days_in_month(2024, 2), 29)
    # 1900-03-01 follows 1900-02-28; 2000-03-01 follows 2000-02-29.
    assert_equal(days_from_civil(1900, 3, 1) - days_from_civil(1900, 2, 28), 1)
    assert_equal(days_from_civil(2000, 3, 1) - days_from_civil(2000, 2, 28), 2)
    assert_equal(days_from_civil(2100, 3, 1) - days_from_civil(2100, 2, 28), 1)


def test_month_lengths_and_range() raises:
    var lens = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for m in range(1, 13):
        assert_equal(days_in_month(2023, m), lens[m - 1])
    assert_equal(days_in_month(2023, 0), 0)
    assert_equal(days_in_month(2023, 13), 0)


def test_far_range_round_trips() raises:
    # The era arithmetic is the only term that grows: 400 years is exactly
    # 146097 days at any distance, and the round trip holds at +-10^9 years.
    var years = [
        -1_000_000_000, -999_999_999, -123_456_789, 123_456_789, 999_999_999, 1_000_000_000
    ]
    for i in range(len(years)):
        var y = years[i]
        for m in range(1, 13):
            var d = days_in_month(y, m)
            for dd in range(1, d + 1, 9):
                var days = days_from_civil(y, m, dd)
                var c = civil_from_days(days)
                assert_equal(c.year, y)
                assert_equal(c.month, m)
                assert_equal(c.day, dd)
                assert_equal(days_from_civil(y + 400, m, dd), days + 146097)
    # The last day of a year is followed by the first of the next, far out.
    assert_equal(
        days_from_civil(1_000_000_001, 1, 1) - days_from_civil(1_000_000_000, 12, 31),
        1,
    )


def test_days_from_date_refuses_what_does_not_exist() raises:
    assert_equal(days_from_date(2000, 2, 29), 11016)
    assert_equal(days_from_date(1970, 1, 1), 0)
    with assert_raises(contains="does not exist"):
        _ = days_from_date(1900, 2, 29)
    with assert_raises(contains="does not exist"):
        _ = days_from_date(2100, 2, 29)
    with assert_raises(contains="does not exist"):
        _ = days_from_date(2023, 2, 29)
    with assert_raises(contains="does not exist"):
        _ = days_from_date(2024, 2, 30)
    with assert_raises(contains="does not exist"):
        _ = days_from_date(2024, 4, 31)
    with assert_raises(contains="does not exist"):
        _ = days_from_date(2024, 1, 0)
    with assert_raises(contains="outside 1..12"):
        _ = days_from_date(2024, 0, 1)
    with assert_raises(contains="outside 1..12"):
        _ = days_from_date(2024, 13, 1)


def test_unchecked_form_continues_the_arithmetic() raises:
    # Documented: day 32 of January is 1 February.
    assert_equal(days_from_civil(2024, 1, 32), days_from_civil(2024, 2, 1))


def test_weekday() raises:
    assert_equal(weekday_from_days(0), 4)  # Thursday
    assert_equal(weekday_from_days(-1), 3)
    assert_equal(weekday_from_days(-4), 0)  # 1969-12-28, a Sunday
    assert_equal(weekday_from_days(days_from_civil(1994, 11, 6)), 0)
    assert_equal(weekday_from_days(days_from_civil(2000, 1, 1)), 6)


def main() raises:
    test_every_day_against_the_walker()
    test_known_days()
    test_leap_years()
    test_month_lengths_and_range()
    test_far_range_round_trips()
    test_days_from_date_refuses_what_does_not_exist()
    test_unchecked_form_continues_the_arithmetic()
    test_weekday()
    print("all civil tests passed")
