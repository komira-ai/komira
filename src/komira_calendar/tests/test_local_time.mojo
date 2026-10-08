# =============================================================================
# test_local_time.mojo: the local date and local date-time text forms, and the
# shape of a time zone name.
#
# Each form is exact: a parse that accepted an offset, a `Z`, a fraction, a
# lower-case `t`, a 24:00 or a 60th second, or a date that does not exist,
# would turn a row here red. Day counts are checked against known dates
# (1970-01-01 is day 0, 2000-03-01 day 11017).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_calendar import (
    LocalDateTime,
    is_time_zone_name,
    parse_local_date,
    parse_local_datetime,
)


def _refuses_datetime(text: String, message: String) raises:
    try:
        _ = parse_local_datetime(text)
    except e:
        assert_equal(String(e), message, text)
        return
    raise Error("accepted " + text)


def test_local_date() raises:
    assert_equal(parse_local_date("1970-01-01"), 0)
    assert_equal(parse_local_date("2000-03-01"), 11017)
    assert_equal(parse_local_date("2028-02-29"), 21243)
    try:
        _ = parse_local_date("2027-02-29")
        raise Error("accepted 2027-02-29")
    except e:
        assert_equal(String(e), "day 29 does not exist in month 2 of year 2027")


def test_local_datetime() raises:
    var t = parse_local_datetime("2000-03-01T23:59:59")
    assert_equal(t.days, 11017)
    assert_equal(t.second_of_day, 86399)
    assert_equal(parse_local_datetime("1970-01-01T00:00:00").second_of_day, 0)
    assert_equal(parse_local_datetime("2026-10-12T09:30:15").second_of_day, 9 * 3600 + 30 * 60 + 15)

    _refuses_datetime("2026-10-12T09:30", "a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes")
    _refuses_datetime("2026-10-12T09:30:00Z", "a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes")
    _refuses_datetime("2026-10-12T09:30:00+01:00", "a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes")
    _refuses_datetime("2026-10-12T09:30:00-05:00", "a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes")
    _refuses_datetime("2026-10-12T09:30:00.5", "a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes")
    _refuses_datetime("2026-10-12t09:30:00", "a local date-time has 'T' between the date and the time")
    _refuses_datetime("2026-10-12T09-30:00", "a local time is HH:MM:SS")
    _refuses_datetime("2026-10-12T24:00:00", "the time of day is outside 00:00:00..23:59:59")
    _refuses_datetime("2026-10-12T09:60:00", "the time of day is outside 00:00:00..23:59:59")
    _refuses_datetime("2026-10-12T09:30:60", "the time of day is outside 00:00:00..23:59:59")
    _refuses_datetime("2026-10-12T0a:30:00", "the hour is not two digits")
    _refuses_datetime("2026-10-32T09:30:00", "day 32 does not exist in month 10 of year 2026")
    # A multi-byte character of the same byte length is refused before any slicing.
    _refuses_datetime("2026-10-1éT09:30:0", "a local date-time is ASCII")


def test_ordering() raises:
    var a = LocalDateTime(10, 50)
    var b = LocalDateTime(10, 60)
    var c = LocalDateTime(11, 0)
    assert_true(a < b)
    assert_true(b < c)
    assert_false(c < a)
    assert_false(a < a)
    assert_true(a == LocalDateTime(10, 50))
    assert_true(a != b)


def test_time_zone_shape() raises:
    for good in ["UTC", "Europe/London", "America/Argentina/Buenos_Aires", "Etc/GMT+5", "Etc/GMT-14", "America/Port-au-Prince"]:
        assert_true(is_time_zone_name(good), good)
    var long = String("A")
    for _ in range(63):
        long += "b"
    assert_true(is_time_zone_name(long), "64 bytes")
    long += "c"
    for bad in ["", "Europe/", "/UTC", "Europe//London", "../etc", "Europe/Lon don", "5Zone", "Europe\\London", long]:
        assert_false(is_time_zone_name(bad), bad)


def main() raises:
    print("test_local_time: the local date and date-time forms, zone name shape")
    test_local_date()
    test_local_datetime()
    test_ordering()
    test_time_zone_shape()
    print("ALL LOCAL TIME TESTS PASSED")
