# =============================================================================
# test_values.mojo -- the DATE, DATE-TIME, DURATION and UTC offset forms
# (RFC 5545 §3.3.4, §3.3.5, §3.3.6, §3.3.14).
#
# Each form is read from text and each refusal asserted by its exact
# message, so a check that is dropped (an hour 24 accepted, a UTC time with
# a TZID accepted, a duration's designators read in any order) turns its
# row red. The writers are pinned to the texts the RFC grammar allows (M
# between H and S; +0000, never -0000).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_datetime import days_from_civil
from komira_calendar_ics.values import (
    format_ics_date,
    format_ics_datetime,
    format_ics_seconds,
    format_utc_offset,
    parse_ics_duration,
    parse_ics_time,
)


def _time_err(text: String, value_type: String, tzid: String) raises -> String:
    try:
        _ = parse_ics_time(text, value_type, tzid)
    except e:
        return String(e)
    raise Error("accepted: " + text)


def _dur_err(text: String) raises -> String:
    try:
        _ = parse_ics_duration(text)
    except e:
        return String(e)
    raise Error("accepted: " + text)


def test_dates_and_times() raises:
    var day = days_from_civil(2030, 11, 2)
    var d = parse_ics_time("20301102", "", "")
    assert_true(d.is_date)
    assert_equal(d.local, day * 86400)
    var d2 = parse_ics_time("20301102", "DATE", "Europe/London")
    assert_true(d2.is_date)
    var lt = parse_ics_time("20301102T093015", "", "America/New_York")
    assert_false(lt.is_date)
    assert_false(lt.is_utc)
    assert_equal(lt.tzid, "America/New_York")
    assert_equal(lt.local, day * 86400 + 9 * 3600 + 30 * 60 + 15)
    assert_equal(lt.day(), day)
    assert_equal(lt.second_of_day(), 9 * 3600 + 1815)
    assert_false(lt.is_floating())
    var u = parse_ics_time("20301102T093015Z", "DATE-TIME", "")
    assert_true(u.is_utc)
    assert_false(u.is_floating())
    var f = parse_ics_time("20301102T000000", "", "")
    assert_true(f.is_floating())
    var neg = parse_ics_time("19691231T235959", "", "")
    assert_equal(neg.day(), -1)
    assert_equal(neg.second_of_day(), 86399)
    print("  test_dates_and_times PASS")


def test_time_refusals() raises:
    assert_equal(
        _time_err("2030110", "", ""),
        '"2030110" is not a DATE-TIME (YYYYMMDDTHHMMSS, optionally ending in Z)',
    )
    assert_equal(_time_err("20301102T0900", "DATE", ""), '"20301102T0900" is not a DATE (YYYYMMDD)')
    assert_equal(_time_err("2030110A", "", ""), '"2030110A" is not a DATE (YYYYMMDD)')
    assert_equal(
        _time_err("20300230", "", ""),
        '"20300230" names no day: day 30 does not exist in month 2 of year 2030',
    )
    assert_equal(
        _time_err("20301102 090000", "", ""),
        '"20301102 090000" is not a DATE-TIME (YYYYMMDDTHHMMSS, optionally ending in Z)',
    )
    assert_equal(
        _time_err("20301102T090000X", "", ""),
        '"20301102T090000X" is not a DATE-TIME (YYYYMMDDTHHMMSS, optionally ending in Z)',
    )
    assert_equal(
        _time_err("20301102T240000", "", ""),
        '"20301102T240000" has no time of day 00:00:00..23:59:59',
    )
    assert_equal(
        _time_err("20301102T235960", "", ""),
        '"20301102T235960" has no time of day 00:00:00..23:59:59',
    )
    assert_equal(
        _time_err("20301102T090000Z", "", "Europe/London"),
        '"20301102T090000Z" is UTC and also names TZID Europe/London',
    )
    assert_equal(_time_err("20301102", "PERIOD", ""), "VALUE=PERIOD is not DATE or DATE-TIME")
    print("  test_time_refusals PASS")


def test_writers() raises:
    var day = days_from_civil(2030, 3, 9)
    assert_equal(format_ics_date(day), "20300309")
    assert_equal(format_ics_datetime(day * 86400 + 3600 + 2 * 60 + 3, False), "20300309T010203")
    assert_equal(format_ics_datetime(day * 86400, True), "20300309T000000Z")
    assert_equal(format_ics_datetime(-1, False), "19691231T235959")
    assert_equal(format_ics_seconds(0), "PT0S")
    assert_equal(format_ics_seconds(59), "PT59S")
    assert_equal(format_ics_seconds(5400), "PT1H30M")
    assert_equal(format_ics_seconds(3605), "PT1H0M5S")
    assert_equal(format_ics_seconds(90000), "PT25H")
    assert_equal(format_ics_seconds(61), "PT1M1S")
    assert_equal(format_utc_offset(-18000), "-0500")
    assert_equal(format_utc_offset(20700), "+0545")
    assert_equal(format_utc_offset(0), "+0000")
    assert_equal(format_utc_offset(3723), "+010203")
    assert_equal(format_utc_offset(-37800), "-1030")
    var msg = String()
    try:
        _ = format_ics_date(days_from_civil(10000, 1, 1))
    except e:
        msg = String(e)
    assert_equal(msg, "year 10000 cannot be written in four digits")
    print("  test_writers PASS")


def test_durations() raises:
    var a = parse_ics_duration("PT1H30M")
    assert_false(a.negative)
    assert_equal(a.days, 0)
    assert_equal(a.seconds, 5400)
    var b = parse_ics_duration("-P1D")
    assert_true(b.negative)
    assert_equal(b.days, 1)
    assert_equal(b.seconds, 0)
    var c = parse_ics_duration("P2W")
    assert_equal(c.days, 14)
    var d = parse_ics_duration("+P1DT2H3M4S")
    assert_false(d.negative)
    assert_equal(d.days, 1)
    assert_equal(d.seconds, 7384)
    assert_equal(parse_ics_duration("PT0S").seconds, 0)
    assert_equal(parse_ics_duration("-PT15M").seconds, 900)
    assert_equal(parse_ics_duration("PT90M").seconds, 5400)
    assert_equal(parse_ics_duration("PT1M5S").seconds, 65)
    print("  test_durations PASS")


def test_duration_refusals() raises:
    assert_equal(_dur_err("1D"), '"1D" is not a DURATION (it starts with P, after an optional sign)')
    assert_equal(_dur_err("P"), '"P" is not a DURATION (no amount)')
    assert_equal(_dur_err("PT"), '"PT" is not a DURATION (no amount)')
    assert_equal(_dur_err("P1DT"), '"P1DT" is not a DURATION (no amount)')
    assert_equal(_dur_err("P1H"), '"P1H" is not a DURATION (designators out of order)')
    assert_equal(_dur_err("PT1S1M"), '"PT1S1M" is not a DURATION (designators out of order)')
    assert_equal(_dur_err("PT1H5S"), '"PT1H5S" is not a DURATION (designators out of order)')
    assert_equal(_dur_err("P1D2D"), '"P1D2D" is not a DURATION (designators out of order)')
    assert_equal(_dur_err("P1W2D"), '"P1W2D" is not a DURATION (weeks stand alone)')
    assert_equal(_dur_err("P1WT"), '"P1WT" is not a DURATION (weeks stand alone)')
    assert_equal(_dur_err("PTT1H"), '"PTT1H" is not a DURATION (a misplaced T)')
    assert_equal(
        _dur_err("P1"),
        '"P1" is not a DURATION (a number and a designator: W, D, H, M or S)',
    )
    assert_equal(
        _dur_err("PT1234567890S"),
        '"PT1234567890S" is not a DURATION (a number and a designator: W, D, H, M or S)',
    )
    print("  test_duration_refusals PASS")


def main() raises:
    print("test_values")
    test_dates_and_times()
    test_time_refusals()
    test_writers()
    test_durations()
    test_duration_refusals()
    print("ALL TESTS PASS")
