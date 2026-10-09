# =============================================================================
# test_expand_rules.mojo: each part of the structured rule, the window, and
# series_span, against dates derived by hand.
#
# Calendar facts the rows rely on: 2026-10-30 is a Friday and the last one of
# October; the last Fridays of the next five months are 2026-11-27,
# 2026-12-25, 2027-01-29, 2027-02-26 and 2027-03-26. November 2026 starts on a
# Sunday. November, February, April, June, September have no 31st. 2028,
# 2032 and 2036 are leap years; 2029 to 2031 and 2033 to 2035 are not.
#
# Each test names the defect it catches.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_calendar import (
    MAX_WINDOW_OCCURRENCES,
    OPEN_END,
    Occurrence,
    SeriesSpan,
    expand,
    parse_local_date,
    parse_local_datetime,
    series_span,
)
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


def _timed(start: String, duration: Int, recurrence: String, exdates: String = "") raises -> Event:
    var text = '{"title":"t","start":"' + start + '","timeZone":"America/New_York","durationSeconds":' + String(
        duration
    )
    if recurrence.byte_length() > 0:
        text += ',"recurrence":' + recurrence
    if exdates.byte_length() > 0:
        text += ',"exdates":' + exdates
    return decode_json[Event](text + "}")


def _all_day(start_date: String, days: Int, recurrence: String, exdates: String = "") raises -> Event:
    var text = (
        '{"title":"d","showWithoutTime":true,"startDate":"'
        + start_date
        + '","days":'
        + String(days)
        + ',"recurrence":'
        + recurrence
    )
    if exdates.byte_length() > 0:
        text += ',"exdates":' + exdates
    return decode_json[Event](text + "}")


# Wide enough for every finite series below.
def _everything(e: Event) raises -> List[Occurrence]:
    return expand(e, _at("2026-10-01T00:00:00"), _at("2040-01-01T00:00:00"))


def test_last_friday() raises:
    # Catches the last weekday (-1) read as the first.
    var e = _timed(
        "2026-10-30T15:00:00",
        3600,
        '{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY","count":6}',
    )
    assert_equal(
        _starts(_everything(e)),
        "2026-10-30T15:00:00 2026-11-27T15:00:00 2026-12-25T15:00:00 2027-01-29T15:00:00"
        + " 2027-02-26T15:00:00 2027-03-26T15:00:00",
    )


def test_interval() raises:
    # Catches an ignored interval, on a day period and on a week period.
    var daily = _timed("2026-11-02T08:00:00", 600, '{"freq":"DAILY","interval":3,"count":4}')
    assert_equal(
        _starts(_everything(daily)), "2026-11-02T08:00:00 2026-11-05T08:00:00 2026-11-08T08:00:00 2026-11-11T08:00:00"
    )
    var fortnightly = _timed(
        "2026-11-02T08:00:00", 600, '{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY","THURSDAY"],"count":5}'
    )
    assert_equal(
        _starts(_everything(fortnightly)),
        "2026-11-02T08:00:00 2026-11-05T08:00:00 2026-11-16T08:00:00 2026-11-19T08:00:00 2026-11-30T08:00:00",
    )


def test_until_on_a_picked_day_is_kept() raises:
    # Catches an exclusive until: the last Thursday is the until day itself.
    var e = _timed(
        "2026-11-05T18:30:00", 3600, '{"freq":"WEEKLY","interval":1,"weekdays":["THURSDAY"],"until":"2026-11-26"}'
    )
    assert_equal(
        _starts(_everything(e)), "2026-11-05T18:30:00 2026-11-12T18:30:00 2026-11-19T18:30:00 2026-11-26T18:30:00"
    )


def test_month_day_skips_short_months() raises:
    # Catches the 31st clamped to a shorter month's last day.
    var e = _timed("2026-10-31T12:00:00", 600, '{"freq":"MONTHLY","interval":1,"monthDay":31,"count":4}')
    assert_equal(
        _starts(_everything(e)), "2026-10-31T12:00:00 2026-12-31T12:00:00 2027-01-31T12:00:00 2027-03-31T12:00:00"
    )


def test_yearly_on_the_leap_day() raises:
    # Catches 29 February moved to 28 February (or 1 March) in a common year.
    var e = _all_day("2028-02-29", 1, '{"freq":"YEARLY","interval":1,"count":3}')
    assert_equal(
        _starts(_everything(e)), "2028-02-29T00:00:00 2032-02-29T00:00:00 2036-02-29T00:00:00"
    )


def test_weekly_from_an_unpicked_day() raises:
    # Catches the first day counted as an occurrence when the rule does not
    # pick it, and a picked weekday before the first day kept.
    var e = _timed(
        "2026-11-04T10:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY","FRIDAY"],"count":3}'
    )
    assert_equal(_starts(_everything(e)), "2026-11-06T10:00:00 2026-11-09T10:00:00 2026-11-13T10:00:00")


def test_count_includes_removed_occurrences() raises:
    # Catches a count that skips excluded occurrences: three are counted, the
    # second is removed, two remain.
    var e = _timed("2026-11-02T09:00:00", 600, '{"freq":"DAILY","interval":1,"count":3}', '["2026-11-03T09:00:00"]')
    assert_equal(_starts(_everything(e)), "2026-11-02T09:00:00 2026-11-04T09:00:00")


def test_all_day_occurrences() raises:
    # Two-day all-day occurrences; a window on the second day still finds one.
    var e = _all_day("2026-12-24", 2, '{"freq":"YEARLY","interval":1,"count":2}')
    var all = _everything(e)
    assert_equal(len(all), 2)
    assert_true(all[0] == Occurrence(_at("2026-12-24T00:00:00"), _at("2026-12-26T00:00:00")))
    assert_true(all[1] == Occurrence(_at("2027-12-24T00:00:00"), _at("2027-12-26T00:00:00")))
    var second_day = expand(e, _at("2026-12-25T12:00:00"), _at("2026-12-25T13:00:00"))
    assert_equal(_starts(second_day), "2026-12-24T00:00:00")


def test_window_on_an_open_series() raises:
    # A series without an end, cut by the window, far from its first day.
    var e = _timed("2026-11-02T09:00:00", 1800, '{"freq":"DAILY","interval":1}')
    assert_equal(
        _starts(expand(e, _at("2030-06-01T00:00:00"), _at("2030-06-04T00:00:00"))),
        "2030-06-01T09:00:00 2030-06-02T09:00:00 2030-06-03T09:00:00",
    )
    # Overlap, not containment: an occurrence that started before the window
    # and ends inside it is in; one starting at the window's end is out.
    assert_equal(
        _starts(expand(e, _at("2030-06-01T09:15:00"), _at("2030-06-02T09:00:00"))), "2030-06-01T09:00:00"
    )
    # One ending exactly at the window's start is out. Catches the end edge
    # of a recurring occurrence's overlap test taken as `>=`.
    var hour = _timed("2026-11-02T09:00:00", 3600, '{"freq":"DAILY","interval":1}')
    assert_equal(len(expand(hour, _at("2026-11-20T10:00:00"), _at("2026-11-20T11:00:00"))), 0)
    # One ending a second after the window's start is in. Catches that end
    # edge moved one second later.
    assert_equal(
        _starts(expand(hour, _at("2026-11-20T09:59:59"), _at("2026-11-20T11:00:00"))), "2026-11-20T09:00:00"
    )
    # One starting a second before the window's end is in, on a period's
    # first day. Catches the period exit or the per-pick start edge moved one
    # second earlier.
    assert_equal(
        _starts(expand(e, _at("2030-06-02T00:00:00"), _at("2030-06-02T09:00:01"))), "2030-06-02T09:00:00"
    )
    # A weekly pick later in its week than the Monday reaches the per-pick
    # start edge rather than the period exit. Starting exactly at the
    # window's end it is out (catches that edge taken as `<=`); a second
    # before the end it is in.
    var friday = _timed("2026-11-06T09:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["FRIDAY"]}')
    assert_equal(len(expand(friday, _at("2026-11-19T00:00:00"), _at("2026-11-20T09:00:00"))), 0)
    assert_equal(
        _starts(expand(friday, _at("2026-11-19T00:00:00"), _at("2026-11-20T09:00:01"))), "2026-11-20T09:00:00"
    )
    assert_equal(len(expand(e, _at("9000-01-01T00:00:00"), _at("9000-01-02T00:00:00"))), 1)
    # Nothing after 9999-12-31.
    var last_day = parse_local_date("9999-12-31")
    assert_equal(
        _starts(expand(e, last_day * 86400, (last_day + 3) * 86400)), "9999-12-31T09:00:00"
    )


def test_window_reaches_back_by_the_length() raises:
    # Catches a window search that starts at the window's own day: five-day
    # occurrences from the 16th to the 20th all overlap the 20th at noon.
    var e = _timed("2026-11-02T09:00:00", 5 * 86400, '{"freq":"DAILY","interval":1}')
    assert_equal(
        _starts(expand(e, _at("2026-11-20T12:00:00"), _at("2026-11-20T13:00:00"))),
        "2026-11-16T09:00:00 2026-11-17T09:00:00 2026-11-18T09:00:00 2026-11-19T09:00:00 2026-11-20T09:00:00",
    )


def test_window_reaches_back_overnight() raises:
    # Catches the window search's margin dropped: a 23:00 occurrence lasting
    # two hours runs into the next day, so the day before the window's own
    # day must be searched even though the length is under one day.
    var e = _timed("2026-11-02T23:00:00", 7200, '{"freq":"DAILY","interval":1}')
    assert_equal(_starts(expand(e, _at("2026-11-20T00:00:00"), _at("2026-11-20T00:30:00"))), "2026-11-19T23:00:00")
    assert_equal(_starts(expand(e, _at("2026-11-20T00:30:00"), _at("2026-11-20T01:00:00"))), "2026-11-19T23:00:00")


def test_far_window_keeps_the_interval() raises:
    # Catches the window search ignoring the interval, for each frequency:
    # an open series with interval above 1, queried several periods out.
    # Every third day from Monday 2026-11-02: day 27 is 11-29, day 30 is 12-02.
    var daily = _timed("2026-11-02T09:00:00", 600, '{"freq":"DAILY","interval":3}')
    assert_equal(_starts(expand(daily, _at("2026-12-01T00:00:00"), _at("2026-12-03T00:00:00"))), "2026-12-02T09:00:00")
    # 2027-03-01 is 119 days (17 weeks) after 2026-11-02, an odd week: off.
    var fortnightly = _timed("2026-11-02T09:00:00", 600, '{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY"]}')
    assert_equal(
        _starts(expand(fortnightly, _at("2027-03-01T00:00:00"), _at("2027-03-15T00:00:00"))), "2027-03-08T09:00:00"
    )
    # Every third month from November: February, May, August.
    var quarterly = _timed("2026-11-15T09:00:00", 600, '{"freq":"MONTHLY","interval":3,"monthDay":15}')
    assert_equal(
        _starts(expand(quarterly, _at("2027-08-01T00:00:00"), _at("2027-09-01T00:00:00"))), "2027-08-15T09:00:00"
    )
    # Every second year from 2026: 2028, 2030, 2032.
    var biennial = _all_day("2026-12-24", 1, '{"freq":"YEARLY","interval":2}')
    assert_equal(
        _starts(expand(biennial, _at("2032-12-01T00:00:00"), _at("2033-01-01T00:00:00"))), "2032-12-24T00:00:00"
    )
    assert_equal(len(expand(biennial, _at("2031-12-01T00:00:00"), _at("2032-01-01T00:00:00"))), 0)


def test_counted_series_is_counted_from_its_start() raises:
    # Catches the window search skipping periods on a counted series: the
    # count runs from the first day, so a window after the last occurrence
    # holds nothing. A search that jumped to the window would count its
    # first occurrences from the jumped-to period instead.
    # Daily, three: 11-02, 11-03, 11-04. A jump would count 11-18 to 11-20.
    var daily = _timed("2026-11-02T09:00:00", 600, '{"freq":"DAILY","interval":1,"count":3}')
    assert_equal(len(expand(daily, _at("2026-11-20T00:00:00"), _at("2026-11-21T00:00:00"))), 0)
    # Mondays, three: 11-02, 11-09, 11-16. A jump would count 11-30, 12-07
    # and 12-14, and 12-07 is in the window.
    var weekly = _timed("2026-11-02T09:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"],"count":3}')
    assert_equal(len(expand(weekly, _at("2026-12-02T00:00:00"), _at("2026-12-10T00:00:00"))), 0)
    # The 15th, twice: 2026-11-15 and 2026-12-15. A jump would count
    # 2027-03-15 first.
    var monthly = _timed("2026-11-15T09:00:00", 600, '{"freq":"MONTHLY","interval":1,"monthDay":15,"count":2}')
    assert_equal(len(expand(monthly, _at("2027-03-10T00:00:00"), _at("2027-03-20T00:00:00"))), 0)
    # The 15th, once: only 2026-11-15. A jump would count 2027-03-15. This
    # row catches the jump running for a count of exactly 1. A daily or
    # Monday-weekly count-1 row cannot: the search day is 2 days before the
    # window, so the jumped-to period's first pick falls before the window
    # and uses up the single count there.
    var monthly_once = _timed("2026-11-15T09:00:00", 600, '{"freq":"MONTHLY","interval":1,"monthDay":15,"count":1}')
    assert_equal(len(expand(monthly_once, _at("2027-03-10T00:00:00"), _at("2027-03-20T00:00:00"))), 0)
    # The last occurrence itself, with the window past the first day.
    assert_equal(
        _starts(expand(daily, _at("2026-11-04T00:00:00"), _at("2026-11-21T00:00:00"))), "2026-11-04T09:00:00"
    )


def test_window_inside_a_period() raises:
    # Catches the window search landing one period late: the window starts
    # mid-period and that period's pick is inside the window. The search day
    # is the window's day minus the length's days minus 2.
    # Search day Tuesday 2026-11-17 is in the week of 2026-11-16; one week
    # late is the week of 2026-11-23 and drops Friday 2026-11-20.
    var weekly = _timed("2026-11-06T09:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["FRIDAY"]}')
    assert_equal(
        _starts(expand(weekly, _at("2026-11-19T00:00:00"), _at("2026-11-21T00:00:00"))), "2026-11-20T09:00:00"
    )
    # Search day 2027-03-08 is in March; one month late is April.
    var monthly = _timed("2026-11-15T09:00:00", 600, '{"freq":"MONTHLY","interval":1,"monthDay":15}')
    assert_equal(
        _starts(expand(monthly, _at("2027-03-10T00:00:00"), _at("2027-03-20T00:00:00"))), "2027-03-15T09:00:00"
    )
    # One day long, so the search day is 2030-12-20, in 2030; one year late
    # is 2031.
    var yearly = _all_day("2026-12-24", 1, '{"freq":"YEARLY","interval":1}')
    assert_equal(
        _starts(expand(yearly, _at("2030-12-23T00:00:00"), _at("2030-12-26T00:00:00"))), "2030-12-24T00:00:00"
    )


def test_all_day_exdates() raises:
    # Catches an all-day exdate read as anything but the date's midnight.
    var e = _all_day("2026-12-24", 1, '{"freq":"DAILY","interval":1,"count":3}', '["2026-12-25"]')
    assert_equal(_starts(_everything(e)), "2026-12-24T00:00:00 2026-12-26T00:00:00")


def test_single_event() raises:
    var e = _timed("2026-11-02T09:00:00", 3600, "")
    assert_equal(_starts(expand(e, _at("2026-11-02T09:59:59"), _at("2026-11-03T00:00:00"))), "2026-11-02T09:00:00")
    assert_equal(len(expand(e, _at("2026-11-02T10:00:00"), _at("2026-11-03T00:00:00"))), 0)
    assert_equal(len(expand(e, _at("2026-11-01T00:00:00"), _at("2026-11-02T09:00:00"))), 0)


def _span(e: Event) raises -> SeriesSpan:
    var s = series_span(e)
    if not s:
        raise Error("no span")
    return s.value()


def test_series_span() raises:
    # Catches an open series given 0 (or any finite end) instead of OPEN_END,
    # and a counted series ending anywhere but its last occurrence's end.
    var open = _timed("2026-11-02T09:00:00", 1800, '{"freq":"WEEKLY","interval":1}')
    assert_true(_span(open) == SeriesSpan(_at("2026-11-02T09:00:00"), OPEN_END))
    assert_equal(OPEN_END, Int(Int64.MAX))
    var counted = _timed("2026-11-02T09:00:00", 3600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"],"count":3}')
    assert_true(_span(counted) == SeriesSpan(_at("2026-11-02T09:00:00"), _at("2026-11-16T10:00:00")))
    var occurrences = _everything(counted)
    assert_equal(_span(counted).last_end, occurrences[len(occurrences) - 1].end)
    # An until that is not a picked day: the last Friday before it.
    var last_friday = _timed(
        "2026-10-30T15:00:00",
        3600,
        '{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY","until":"2027-01-31"}',
    )
    assert_true(_span(last_friday) == SeriesSpan(_at("2026-10-30T15:00:00"), _at("2027-01-29T16:00:00")))
    # Backwards over a month the rule skips.
    var month_end = _timed(
        "2026-10-31T12:00:00", 600, '{"freq":"MONTHLY","interval":1,"monthDay":31,"until":"2027-02-28"}'
    )
    assert_true(_span(month_end) == SeriesSpan(_at("2026-10-31T12:00:00"), _at("2027-01-31T12:10:00")))
    # An until inside a period, before that period's pick: the pick of the
    # period before. Catches the last day read without the until.
    var thursdays = _timed(
        "2026-11-05T18:30:00", 3600, '{"freq":"WEEKLY","interval":1,"weekdays":["THURSDAY"],"until":"2026-11-24"}'
    )
    assert_true(_span(thursdays) == SeriesSpan(_at("2026-11-05T18:30:00"), _at("2026-11-19T19:30:00")))
    # A count the calendar cannot hold: 9999-12-31 is a Friday, so after the
    # weekend of the 25th the next picks would be in the year 10000.
    var weekend = _timed(
        "9999-12-25T10:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["SATURDAY","SUNDAY"],"count":5}'
    )
    assert_true(_span(weekend) == SeriesSpan(_at("9999-12-25T10:00:00"), _at("9999-12-26T10:10:00")))
    var end_of_time = parse_local_date("9999-12-31") * 86400
    assert_equal(
        _starts(expand(weekend, _at("9999-12-01T00:00:00"), end_of_time + 3 * 86400)),
        "9999-12-25T10:00:00 9999-12-26T10:00:00",
    )
    # A counted series whose last pick is 9999-12-31 itself, in a period
    # that starts on it. Catches the count search's period loop stopping
    # before a period that starts on the last day (`<`) and its pick test
    # dropping a pick on the last day (`>=`): either ends on the 30th.
    var to_the_end = _timed("9999-12-30T09:00:00", 600, '{"freq":"DAILY","interval":1,"count":3}')
    assert_true(_span(to_the_end) == SeriesSpan(_at("9999-12-30T09:00:00"), _at("9999-12-31T09:10:00")))
    # A first period that starts by 9999-12-31 but picks only after it: the
    # week of Monday 9999-12-27 picks Saturday, which is in the year 10000.
    # No occurrence, no span. Catches series_span taking period 0's first
    # pick without checking it against the last day.
    var past_the_end = _timed(
        "9999-12-27T10:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["SATURDAY"],"count":2}'
    )
    assert_false(Bool(series_span(past_the_end)))
    # The first occurrence is the first picked day, not the event's start.
    var unpicked = _timed("2026-11-04T10:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"],"count":2}')
    assert_true(_span(unpicked) == SeriesSpan(_at("2026-11-09T10:00:00"), _at("2026-11-16T10:10:00")))
    # An until before the first picked day: no occurrence, no span.
    var none = _timed(
        "2026-11-04T10:00:00", 600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"],"until":"2026-11-08"}'
    )
    assert_false(Bool(series_span(none)))
    assert_equal(len(_everything(none)), 0)
    var single = _all_day("2026-12-24", 2, '{"freq":"DAILY","interval":1,"count":1}')
    assert_true(_span(single) == SeriesSpan(_at("2026-12-24T00:00:00"), _at("2026-12-26T00:00:00")))
    var one_off = _timed("2026-11-02T09:00:00", 3600, "")
    assert_true(_span(one_off) == SeriesSpan(_at("2026-11-02T09:00:00"), _at("2026-11-02T10:00:00")))
    # A yearly until whose own year picks nothing before it: the last
    # occurrence is 2029, not the first one. Catches a search back that
    # starts at period 0; one that starts a year early is the row below's.
    var yearly = _all_day("2026-12-24", 1, '{"freq":"YEARLY","interval":1,"until":"2030-01-01"}')
    assert_true(_span(yearly) == SeriesSpan(_at("2026-12-24T00:00:00"), _at("2029-12-25T00:00:00")))
    # An until on or after the pick of its own period, one row per frequency
    # the MONTHLY row above leaves open: the last occurrence is in the
    # until's period. Catches a search back that starts one period early.
    var until_thursday = _timed(
        "2026-11-05T18:30:00", 3600, '{"freq":"WEEKLY","interval":1,"weekdays":["THURSDAY"],"until":"2026-11-26"}'
    )
    assert_true(_span(until_thursday) == SeriesSpan(_at("2026-11-05T18:30:00"), _at("2026-11-26T19:30:00")))
    var until_day = _timed("2026-11-02T09:00:00", 3600, '{"freq":"DAILY","interval":1,"until":"2026-11-04"}')
    assert_true(_span(until_day) == SeriesSpan(_at("2026-11-02T09:00:00"), _at("2026-11-04T10:00:00")))
    var until_year = _all_day("2026-12-24", 1, '{"freq":"YEARLY","interval":1,"until":"2029-12-31"}')
    assert_true(_span(until_year) == SeriesSpan(_at("2026-12-24T00:00:00"), _at("2029-12-25T00:00:00")))
    # Weekly picks on several weekdays, an until (Wednesday 2026-11-25)
    # earlier in its week than the start's weekday (Thursday), and two picks
    # of that week (Monday 23, Tuesday 24) on or before it. The last
    # occurrence is Tuesday 24. Catches a week counted from the start day
    # instead of its Monday (the search starts at the week of the 16th and
    # ends on Thursday 19) and a scan of the until's week from its first
    # pick (ends on Monday 23).
    var mo_tu_th = _timed(
        "2026-11-05T18:30:00",
        3600,
        '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY","TUESDAY","THURSDAY"],"until":"2026-11-25"}',
    )
    assert_true(_span(mo_tu_th) == SeriesSpan(_at("2026-11-05T18:30:00"), _at("2026-11-24T19:30:00")))
    var mo_tu_th_all = _everything(mo_tu_th)
    assert_equal(_span(mo_tu_th).last_end, mo_tu_th_all[len(mo_tu_th_all) - 1].end)


def _span_matches_expand(e: Event, first: String, last_end: String) raises:
    """The span is first to last_end, and last_end is the end of the last
    occurrence `expand` produces."""
    assert_true(_span(e) == SeriesSpan(_at(first), _at(last_end)))
    var occurrences = _everything(e)
    assert_equal(_span(e).last_end, occurrences[len(occurrences) - 1].end)


def test_series_span_period_edges() raises:
    # An until on the first day of a period that picks that day: the last
    # occurrence is the until itself. Catches a search back that starts one
    # period early when the until is the period's first day (a Monday, the
    # 1st of a month, 1 January).
    var mondays = _timed(
        "2026-11-02T09:00:00", 3600, '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"],"until":"2026-11-23"}'
    )
    _span_matches_expand(mondays, "2026-11-02T09:00:00", "2026-11-23T10:00:00")
    var firsts = _timed(
        "2026-11-01T08:00:00", 1800, '{"freq":"MONTHLY","interval":1,"monthDay":1,"until":"2027-03-01"}'
    )
    _span_matches_expand(firsts, "2026-11-01T08:00:00", "2027-03-01T08:30:00")
    var new_year = _all_day("2027-01-01", 1, '{"freq":"YEARLY","interval":1,"until":"2030-01-01"}')
    _span_matches_expand(new_year, "2027-01-01T00:00:00", "2030-01-02T00:00:00")
    # An until inside period 0: the last occurrence is in period 0. Catches a
    # search back that stops before period 0 (no last day, and the span
    # aborts on the missing value).
    var one_week = _timed(
        "2026-11-02T09:00:00",
        3600,
        '{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY","WEDNESDAY","FRIDAY"],"until":"2026-11-06"}',
    )
    _span_matches_expand(one_week, "2026-11-02T09:00:00", "2026-11-06T10:00:00")
    var start_only = _timed("2026-11-02T09:00:00", 3600, '{"freq":"DAILY","interval":1,"until":"2026-11-02"}')
    _span_matches_expand(start_only, "2026-11-02T09:00:00", "2026-11-02T10:00:00")
    # A count the calendar cannot hold, one pick per period: yearly from
    # 9995 asks for ten, five fit by 9999-12-31, and the count search runs
    # out of periods (the year 10000) instead of reaching the count. The
    # last occurrence is 9999-06-01. Catches that exit giving any day but
    # the last pick (the end of the calendar, or none: no span).
    var to_the_end = _all_day("9995-06-01", 1, '{"freq":"YEARLY","interval":1,"count":10}')
    assert_true(_span(to_the_end) == SeriesSpan(_at("9995-06-01T00:00:00"), _at("9999-06-02T00:00:00")))
    assert_equal(
        len(expand(to_the_end, _at("9995-01-01T00:00:00"), parse_local_date("9999-12-31") * 86400 + 86400)), 5
    )
    # The same exit when the last period picks nothing: 29 February picks
    # 9996 only, then 9997 to 9999 pick no day, so the period loop ends on
    # an empty period. Catches that exit returning the last period's final
    # pick instead of the running last pick (there is none to index).
    var last_period_empty = _all_day("9996-02-29", 1, '{"freq":"YEARLY","interval":1,"count":3}')
    assert_true(_span(last_period_empty) == SeriesSpan(_at("9996-02-29T00:00:00"), _at("9996-03-01T00:00:00")))
    assert_equal(
        len(expand(last_period_empty, _at("9996-01-01T00:00:00"), parse_local_date("9999-12-31") * 86400 + 86400)),
        1,
    )


def _refuses(e: Event, window_start: Int, window_end: Int, message: String) raises:
    try:
        _ = expand(e, window_start, window_end)
    except err:
        assert_equal(String(err), message)
        return
    raise Error("expanded; want: " + message)


def test_refusals() raises:
    var both = _timed("2026-11-02T09:00:00", 600, '{"freq":"DAILY","interval":1,"count":2,"until":"2026-11-30"}')
    var lo = _at("2026-11-01T00:00:00")
    var hi = _at("2026-12-01T00:00:00")
    _refuses(
        both,
        lo,
        hi,
        "the event is refused: COUNT_WITH_UNTIL at recurrence.count: a recurrence ends by count or by until, not both",
    )
    try:
        _ = series_span(both)
        raise Error("series_span accepted a refused event")
    except err:
        assert_equal(
            String(err),
            "the event is refused: COUNT_WITH_UNTIL at recurrence.count: a recurrence ends by count or by until,"
            + " not both",
        )
    var daily = _timed("2026-11-02T09:00:00", 600, '{"freq":"DAILY","interval":1}')
    _refuses(daily, hi, hi, "the window is empty: its end is not after its start")
    # The cap: exactly MAX_WINDOW_OCCURRENCES fit, one more is refused.
    var first = parse_local_date("2026-11-02") * 86400
    assert_equal(len(expand(daily, first, first + MAX_WINDOW_OCCURRENCES * 86400)), MAX_WINDOW_OCCURRENCES)
    _refuses(
        daily,
        first,
        first + (MAX_WINDOW_OCCURRENCES + 1) * 86400,
        "the window holds more than 10000 occurrences; narrow it",
    )


def main() raises:
    print("test_expand_rules: the structured rule, the window and series_span")
    test_last_friday()
    test_interval()
    test_until_on_a_picked_day_is_kept()
    test_month_day_skips_short_months()
    test_yearly_on_the_leap_day()
    test_weekly_from_an_unpicked_day()
    test_counted_series_is_counted_from_its_start()
    test_count_includes_removed_occurrences()
    test_all_day_occurrences()
    test_window_on_an_open_series()
    test_window_reaches_back_by_the_length()
    test_window_reaches_back_overnight()
    test_window_inside_a_period()
    test_far_window_keeps_the_interval()
    test_all_day_exdates()
    test_single_event()
    test_series_span()
    test_series_span_period_edges()
    test_refusals()
    print("ALL EXPANSION RULE TESTS PASSED")
