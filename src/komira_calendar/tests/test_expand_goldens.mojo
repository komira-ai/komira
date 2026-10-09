# =============================================================================
# test_expand_goldens.mojo: the classic RRULE expansion cases (weekly by
# weekday, several weekdays, COUNT, UNTIL, EXDATE, an ordinal weekday),
# each restated as the equivalent structured rule. The RRULE each row stands
# for is named beside it; every count and instant was derived by hand.
# November 2026 starts on a Sunday, so its Mondays are the 2nd, 9th, 16th,
# 23rd and 30th; its first Wednesday is the 4th and its first Friday the 6th.
# The third Mondays of November 2026, December 2026 and January 2027 are the
# 16th, 21st and 18th.
#
# What a red row means: a weekly rule that misses or adds a Monday, a weekday
# set read as one day, a count or an until that is off by one, an exdate not
# removed, or an ordinal weekday on the wrong week.
# =============================================================================

from std.testing import assert_equal

from komira_calendar import Occurrence, expand, parse_local_datetime
from komira_calendar_proto.calendar import Event
from komira_datetime import format_iso_date
from komira_proto_codec import decode_json


def _at(text: String) raises -> Int:
    return parse_local_datetime(text).seconds()


def _two(v: Int) -> String:
    return (String("0") if v < 10 else String("")) + String(v)


def _text(seconds: Int) raises -> String:
    var sod = seconds % 86400
    return (
        format_iso_date(seconds // 86400)
        + "T"
        + _two(sod // 3600)
        + ":"
        + _two(sod // 60 % 60)
        + ":"
        + _two(sod % 60)
    )


def _starts(occurrences: List[Occurrence]) raises -> String:
    var out = String("")
    for i in range(len(occurrences)):
        if i > 0:
            out += " "
        out += _text(occurrences[i].start)
    return out


def _event(start: String, duration: Int, recurrence: String, exdates: String = "") raises -> Event:
    var text = (
        '{"title":"golden","start":"'
        + start
        + '","timeZone":"Europe/London","durationSeconds":'
        + String(duration)
        + ',"recurrence":'
        + recurrence
    )
    if exdates.byte_length() > 0:
        text += ',"exdates":' + exdates
    return decode_json[Event](text + "}")


def test_weekly_mondays_in_a_month() raises:
    # RRULE FREQ=WEEKLY;BYDAY=MO from a Monday: five Mondays in the month.
    var e = _event("2026-11-02T09:00:00", 3600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"]}')
    var all = expand(e, _at("2026-11-01T00:00:00"), _at("2026-12-01T00:00:00"))
    assert_equal(len(all), 5)
    assert_equal(
        _starts(all),
        "2026-11-02T09:00:00 2026-11-09T09:00:00 2026-11-16T09:00:00 2026-11-23T09:00:00 2026-11-30T09:00:00",
    )
    assert_equal(all[0].end - all[0].start, 3600)
    # A narrower window [9th, 24th) holds three of them.
    var narrow = expand(e, _at("2026-11-09T00:00:00"), _at("2026-11-24T00:00:00"))
    assert_equal(_starts(narrow), "2026-11-09T09:00:00 2026-11-16T09:00:00 2026-11-23T09:00:00")


def test_weekly_three_weekdays() raises:
    # RRULE FREQ=WEEKLY;BYDAY=MO,WE,FR: the first week holds Mon, Wed and Fri.
    var e = _event(
        "2026-11-02T09:00:00", 1800, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY","WEDNESDAY","FRIDAY"]}'
    )
    var week = expand(e, _at("2026-11-02T00:00:00"), _at("2026-11-09T00:00:00"))
    assert_equal(_starts(week), "2026-11-02T09:00:00 2026-11-04T09:00:00 2026-11-06T09:00:00")


def test_daily_count() raises:
    # RRULE FREQ=DAILY;COUNT=3: exactly three, however wide the window.
    var e = _event("2026-11-02T09:00:00", 3600, '{"freq":"DAILY","interval":1,"count":3}')
    var all = expand(e, _at("2026-11-01T00:00:00"), _at("2026-12-01T00:00:00"))
    assert_equal(_starts(all), "2026-11-02T09:00:00 2026-11-03T09:00:00 2026-11-04T09:00:00")


def test_daily_until_is_inclusive() raises:
    # RRULE FREQ=DAILY;UNTIL=<the third day>: the third day is kept.
    var e = _event("2026-11-02T09:00:00", 3600, '{"freq":"DAILY","interval":1,"until":"2026-11-04"}')
    var all = expand(e, _at("2026-11-01T00:00:00"), _at("2026-12-01T00:00:00"))
    assert_equal(_starts(all), "2026-11-02T09:00:00 2026-11-03T09:00:00 2026-11-04T09:00:00")


def test_exdate_removes_one() raises:
    # RRULE FREQ=WEEKLY;BYDAY=MO with EXDATE on the third Monday: four of the five Mondays remain.
    var e = _event(
        "2026-11-02T09:00:00",
        3600,
        '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"]}',
        '["2026-11-16T09:00:00"]',
    )
    var all = expand(e, _at("2026-11-01T00:00:00"), _at("2026-12-01T00:00:00"))
    assert_equal(
        _starts(all), "2026-11-02T09:00:00 2026-11-09T09:00:00 2026-11-23T09:00:00 2026-11-30T09:00:00"
    )


def test_monthly_third_monday() raises:
    # RRULE FREQ=MONTHLY;BYDAY=3MO from a third Monday: three months, three
    # third Mondays, the first at the event's own start.
    var e = _event(
        "2026-11-16T09:00:00", 3600, '{"freq":"MONTHLY","interval":1,"ordinal":3,"ordinalWeekday":"MONDAY"}'
    )
    var all = expand(e, _at("2026-11-01T00:00:00"), _at("2027-02-01T00:00:00"))
    assert_equal(_starts(all), "2026-11-16T09:00:00 2026-12-21T09:00:00 2027-01-18T09:00:00")
    assert_equal(all[0].start, _at("2026-11-16T09:00:00"))


def main() raises:
    print("test_expand_goldens: the classic RRULE cases as structured rules")
    test_weekly_mondays_in_a_month()
    test_weekly_three_weekdays()
    test_daily_count()
    test_daily_until_is_inclusive()
    test_exdate_removes_one()
    test_monthly_third_monday()
    print("ALL EXPANSION GOLDENS PASSED")
