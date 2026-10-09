# =============================================================================
# test_rrule.mojo -- RRULE text to the structured rule, rule by rule.
#
# Each accepted row names an RRULE and the event's first day and asserts the
# rule as the API's JSON (`encode_json` of `Recurrence`), so a part read into
# the wrong field, or dropped, turns its row red. Each refused row asserts
# the code (out of subset or malformed) and the exact message, so a subset
# check that is dropped lets its row through ("accepted"). The writer is
# checked by reading what it writes.
#
# The first day is 2030-09-02, a Monday (2030-09-05 a Thursday), except
# where a row names another: every accepted rule picks its first day, and
# test_start_not_an_occurrence refuses the rules that do not.
# test_first_occurrence pins the first day the model's rule picks from a
# start, which the export writes as DTSTART.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_datetime import days_from_civil
from komira_proto_codec import decode_json, encode_json
from komira_calendar_proto.calendar import Recurrence
from komira_calendar_ics.rrule import first_occurrence, format_rrule, parse_rrule, weekday_name


def _day(y: Int, m: Int, d: Int) -> Int:
    return days_from_civil(y, m, d)


def _ok(text: String, start: Int, want: String, until: String = String()) raises:
    var r = parse_rrule(text, start)
    if not r.ok():
        raise Error(text + ": refused " + r.code + ": " + r.message)
    assert_equal(encode_json(r.rule), want, text)
    assert_equal(r.until, until, text + ": until")
    var again = parse_rrule(format_rrule(r.rule, r.until), start)
    assert_true(again.ok(), "rewritten " + format_rrule(r.rule, r.until))
    assert_equal(encode_json(again.rule), want, "rewritten " + text)


def _no(text: String, start: Int, code: String, message: String) raises:
    var r = parse_rrule(text, start)
    if r.ok():
        raise Error(text + ": accepted as " + encode_json(r.rule) + "; want " + code)
    assert_equal(r.code, code, text + ": code (" + r.message + ")")
    assert_equal(r.message, message, text)


comptime OUT = "RRULE_OUT_OF_SUBSET"
comptime BAD = "RRULE_MALFORMED"


def test_accepted() raises:
    var mon = _day(2030, 9, 2)
    var tue = _day(2030, 9, 3)
    var thu = _day(2030, 9, 5)
    _ok("FREQ=DAILY", mon, '{"freq":"DAILY","interval":1}')
    _ok("freq=daily;interval=3;count=10", mon, '{"freq":"DAILY","interval":3,"count":10}')
    _ok("FREQ=DAILY;UNTIL=20301224T000000Z", mon, '{"freq":"DAILY","interval":1}', "20301224T000000Z")
    _ok("FREQ=WEEKLY", mon, '{"freq":"WEEKLY","interval":1}')
    _ok(
        "FREQ=WEEKLY;BYDAY=TU,TH,TU;WKST=SU",
        tue,
        '{"freq":"WEEKLY","interval":1,"weekdays":["TUESDAY","THURSDAY"]}',
    )
    _ok(
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;WKST=SU",
        mon,
        '{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY","WEDNESDAY","FRIDAY"]}',
    )
    _ok(
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=MO",
        tue,
        '{"freq":"WEEKLY","interval":2,"weekdays":["TUESDAY","SUNDAY"]}',
    )
    _ok("FREQ=WEEKLY;INTERVAL=2;WKST=SU", thu, '{"freq":"WEEKLY","interval":2}')
    _ok("FREQ=MONTHLY", thu, '{"freq":"MONTHLY","interval":1,"monthDay":5}')
    _ok("FREQ=MONTHLY;BYMONTHDAY=31", _day(2030, 10, 31), '{"freq":"MONTHLY","interval":1,"monthDay":31}')
    _ok(
        "FREQ=MONTHLY;COUNT=10;BYDAY=1FR",
        _day(2030, 9, 6),
        '{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY","count":10}',
    )
    _ok(
        "FREQ=MONTHLY;BYDAY=-1FR",
        _day(2030, 9, 27),
        '{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY"}',
    )
    # The last Tuesday of September 2030 is the 24th: 24 + 7 runs past the
    # 30th.
    _ok(
        "FREQ=MONTHLY;BYDAY=-1TU",
        _day(2030, 9, 24),
        '{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"TUESDAY"}',
    )
    _ok(
        "FREQ=MONTHLY;BYDAY=+4SA",
        _day(2030, 9, 28),
        '{"freq":"MONTHLY","interval":1,"ordinal":4,"ordinalWeekday":"SATURDAY"}',
    )
    _ok(
        "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2",
        _day(2030, 9, 10),
        '{"freq":"MONTHLY","interval":1,"ordinal":2,"ordinalWeekday":"TUESDAY"}',
    )
    _ok("FREQ=YEARLY", mon, '{"freq":"YEARLY","interval":1}')
    _ok("FREQ=YEARLY;BYMONTH=9;BYMONTHDAY=2", mon, '{"freq":"YEARLY","interval":1}')
    _ok("FREQ=YEARLY;BYMONTH=9;INTERVAL=4;", mon, '{"freq":"YEARLY","interval":4}')
    _ok("FREQ=DAILY;INTERVAL=999;COUNT=10000", mon, '{"freq":"DAILY","interval":999,"count":10000}')
    print("  test_accepted PASS")


def test_out_of_subset() raises:
    var mon = _day(2030, 9, 2)
    _no("FREQ=HOURLY;INTERVAL=3", mon, OUT, "RRULE FREQ=HOURLY is outside the subset (DAILY, WEEKLY, MONTHLY, YEARLY)")
    _no(
        "FREQ=DAILY;BYHOUR=9,10",
        mon,
        OUT,
        "RRULE part BYHOUR is outside the subset (FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, WKST)",
    )
    _no("FREQ=DAILY;INTERVAL=1000", mon, OUT, "RRULE INTERVAL=1000 is above 999")
    _no("FREQ=DAILY;COUNT=10001", mon, OUT, "RRULE COUNT=10001 is above 10000")
    _no("FREQ=DAILY;BYDAY=MO", mon, OUT, "RRULE BYDAY, BYMONTHDAY or BYMONTH on a DAILY rule is outside the subset")
    _no("FREQ=WEEKLY;BYMONTH=1", mon, OUT, "RRULE BYMONTHDAY or BYMONTH on a WEEKLY rule is outside the subset")
    _no(
        "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU",
        mon,
        OUT,
        "RRULE WKST=SU groups this rule's days into other weeks than a week starting on Monday",
    )
    _no("FREQ=MONTHLY;BYMONTH=1", mon, OUT, "RRULE BYMONTH on a MONTHLY rule is outside the subset")
    _no("FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", mon, OUT, "RRULE BYMONTHDAY with BYDAY on a MONTHLY rule is outside the subset")
    _no("FREQ=MONTHLY;BYMONTHDAY=2,15", mon, OUT, "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset")
    _no("FREQ=MONTHLY;BYMONTHDAY=-3", mon, OUT, "RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset")
    _no("FREQ=MONTHLY;BYMONTHDAY=1;BYSETPOS=1", mon, OUT, "RRULE BYSETPOS with BYMONTHDAY is outside the subset")
    _no("FREQ=MONTHLY;BYDAY=1SU,-1SU", mon, OUT, "RRULE BYDAY on a MONTHLY rule is one weekday in the subset")
    _no("FREQ=MONTHLY;BYDAY=TU", mon, OUT, "RRULE BYDAY on a MONTHLY rule needs an ordinal (1..4 or -1) in the subset")
    _no("FREQ=MONTHLY;BYDAY=-2MO", mon, OUT, "RRULE ordinal -2 is outside 1..4 and -1")
    _no("FREQ=MONTHLY;BYDAY=5FR", mon, OUT, "RRULE ordinal 5 is outside 1..4 and -1")
    _no(
        "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
        mon,
        OUT,
        "RRULE BYDAY on a MONTHLY rule is one weekday in the subset",
    )
    _no(
        "FREQ=MONTHLY;BYDAY=1TU;BYSETPOS=1",
        mon,
        OUT,
        "RRULE BYSETPOS on a MONTHLY rule is one position for one plain weekday in the subset",
    )
    _no(
        "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=1,-1",
        _day(2030, 9, 3),
        OUT,
        "RRULE BYSETPOS on a MONTHLY rule is one position for one plain weekday in the subset",
    )
    _no("FREQ=MONTHLY;BYSETPOS=1", mon, OUT, "RRULE BYSETPOS without BYDAY is outside the subset")
    _no("FREQ=YEARLY;BYDAY=20MO", mon, OUT, "RRULE BYDAY on a YEARLY rule is outside the subset")
    _no("FREQ=YEARLY;BYMONTH=6,7", mon, OUT, "RRULE BYMONTH on a YEARLY rule is the start's month in the subset")
    _no("FREQ=YEARLY;BYMONTH=10", mon, OUT, "RRULE BYMONTH on a YEARLY rule is the start's month in the subset")
    _no(
        "FREQ=YEARLY;BYMONTHDAY=2",
        mon,
        OUT,
        "RRULE BYMONTHDAY on a YEARLY rule is the start's day, with BYMONTH, in the subset",
    )
    _no(
        "FREQ=YEARLY;BYMONTH=9;BYMONTHDAY=3",
        mon,
        OUT,
        "RRULE BYMONTHDAY on a YEARLY rule is the start's day, with BYMONTH, in the subset",
    )
    _no("FREQ=YEARLY;BYSETPOS=1", mon, OUT, "RRULE BYSETPOS on a YEARLY rule is outside the subset")
    print("  test_out_of_subset PASS")


comptime NOT_OCCURRENCE = "DTSTART is not an occurrence of its RRULE; RFC 5545 leaves such a recurrence set undefined"


def test_start_not_an_occurrence() raises:
    # RFC 5545 §3.8.5.3: a DTSTART the rule does not pick gives an undefined
    # set. Each row's start is one the rule skips; the rows above with the
    # same rules and a start the rule picks are accepted.
    var mon = _day(2030, 9, 2)
    _no("FREQ=WEEKLY;BYDAY=TU,TH", mon, OUT, NOT_OCCURRENCE)
    _no("FREQ=MONTHLY;COUNT=10;BYDAY=1FR", mon, OUT, NOT_OCCURRENCE)
    _no("FREQ=MONTHLY;BYDAY=-1FR", _day(2030, 9, 20), OUT, NOT_OCCURRENCE)
    # Monday the 23rd is one week before the last Monday, the 30th: 23 + 7
    # is the month's last day, not past it.
    _no("FREQ=MONTHLY;BYDAY=-1MO", _day(2030, 9, 23), OUT, NOT_OCCURRENCE)
    _no("FREQ=MONTHLY;BYDAY=+4SA", _day(2030, 9, 21), OUT, NOT_OCCURRENCE)
    _no("FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2", _day(2030, 9, 3), OUT, NOT_OCCURRENCE)
    _no("FREQ=MONTHLY;BYMONTHDAY=31", mon, OUT, NOT_OCCURRENCE)
    # Sunday 2030-09-01 with WKST=SU: the RFC's first week is 1-7 September
    # (DTSTART, then Monday the 2nd); the model's Monday weeks would give
    # the 9th and the 23rd. The start's weekday is one of the days WKST
    # groups, so the rule is refused for its WKST.
    _no(
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=SU",
        _day(2030, 9, 1),
        OUT,
        "RRULE WKST=SU groups this rule's days into other weeks than a week starting on Monday",
    )
    # INTERVAL 1: WKST changes nothing, and the start is not a Monday.
    _no("FREQ=WEEKLY;BYDAY=MO;WKST=SU", _day(2030, 9, 1), OUT, NOT_OCCURRENCE)
    print("  test_start_not_an_occurrence PASS")


comptime NONE = "none"


def _first(rule_json: String, start: Int, until: Int) raises -> String:
    """The first day the rule picks, as `days_from_civil` of it, or NONE."""
    var got = first_occurrence(decode_json[Recurrence](rule_json), start, until)
    if got:
        return String(got.value())
    return NONE


def _on(y: Int, m: Int, d: Int) -> String:
    return String(_day(y, m, d))


def _row(mut bad: List[String], got: String, want: String):
    """Records a row whose answer `got` is not `want`; every row of the
    test runs, so each wrong row is listed."""
    if got != want:
        bad.append(" got " + got + ", want " + want + ";")


def _joined(bad: List[String]) -> String:
    var out = String()
    for b in bad:
        out += b
    return out^


def test_first_occurrence() raises:
    # The first day the model's rule picks from a start: the start itself
    # when picked; else a later day of the start's Monday week, or the first
    # named day `interval` weeks on; else the first month `interval` months
    # apart that has the day. None when that day is after the until; the
    # until itself is a day the series may pick.
    var bad = List[String]()
    var mon = _day(2030, 9, 2)
    var end = _day(9999, 12, 31)
    _row(bad, _first('{"freq":"DAILY","interval":3}', mon, end), _on(2030, 9, 2))
    # A start it picks, with the until on the start: the start.
    _row(bad, _first('{"freq":"DAILY","interval":1}', mon, mon), _on(2030, 9, 2))
    _row(bad, _first('{"freq":"DAILY","interval":1}', mon, mon - 1), NONE)
    _row(bad, _first('{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY"]}', mon, end), _on(2030, 9, 2))
    _row(bad, _first('{"freq":"WEEKLY","interval":2,"weekdays":["THURSDAY","TUESDAY"]}', mon, end), _on(2030, 9, 3))
    _row(
        bad,
        _first('{"freq":"WEEKLY","interval":2,"weekdays":["SUNDAY","MONDAY"]}', _day(2030, 9, 3), end), _on(2030, 9, 8)
    )
    _row(bad, _first('{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY"]}', _day(2030, 9, 3), end), _on(2030, 9, 16))
    _row(bad, _first('{"freq":"WEEKLY","interval":1,"weekdays":["MONDAY"]}', _day(2030, 9, 3), end), _on(2030, 9, 9))
    _row(bad, _first('{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY"]}', _day(2030, 9, 3), _day(2030, 9, 15)), NONE)
    # The until on the day it picks.
    _row(
        bad,
        _first('{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY"]}', _day(2030, 9, 3), _day(2030, 9, 16)),
        _on(2030, 9, 16),
    )
    # From Thursday 5 September, nothing later in the week: the smallest
    # named weekday two weeks on, Tuesday the 17th, whatever the list order.
    _row(
        bad,
        _first('{"freq":"WEEKLY","interval":2,"weekdays":["TUESDAY","WEDNESDAY"]}', _day(2030, 9, 5), end),
        _on(2030, 9, 17),
    )
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":2}', mon, end), _on(2030, 9, 2))
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":1}', mon, end), _on(2030, 10, 1))
    # The until on the 1st of the month the answer falls in: that 1st.
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":1}', mon, _day(2030, 10, 1)), _on(2030, 10, 1))
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":31}', mon, end), _on(2030, 10, 31))
    # September and November have no 31st; January 2031, four months on, does.
    _row(bad, _first('{"freq":"MONTHLY","interval":2,"monthDay":31}', mon, end), _on(2031, 1, 31))
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":31}', mon, _day(2030, 10, 30)), NONE)
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":31}', mon, _day(2030, 9, 30)), NONE)
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":31}', mon, _day(2030, 10, 31)), _on(2030, 10, 31))
    # The 30th every 12 months from a February picks no day before 9999.
    _row(bad, _first('{"freq":"MONTHLY","interval":12,"monthDay":30}', _day(2031, 2, 1), end), NONE)
    _row(
        bad,
        _first('{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY"}', mon, end), _on(2030, 9, 6)
    )
    # The first Monday of September 2030 is the 2nd, before a start on the 3rd.
    _row(
        bad,
        _first('{"freq":"MONTHLY","interval":2,"ordinal":1,"ordinalWeekday":"MONDAY"}', _day(2030, 9, 3), end),
        _on(2030, 11, 4),
    )
    # July 2030 begins on a Monday: its first Monday is the 1st.
    _row(
        bad,
        _first('{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"MONDAY"}', _day(2030, 6, 5), end),
        _on(2030, 7, 1),
    )
    # The until on that 1st.
    var first_monday = '{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"MONDAY"}'
    _row(bad, _first(first_monday, _day(2030, 6, 5), _day(2030, 7, 1)), _on(2030, 7, 1))
    _row(
        bad,
        _first('{"freq":"MONTHLY","interval":1,"ordinal":4,"ordinalWeekday":"SATURDAY"}', mon, end), _on(2030, 9, 28)
    )
    _row(
        bad,
        _first('{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"MONDAY"}', mon, end), _on(2030, 9, 30)
    )
    _row(
        bad,
        _first('{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"TUESDAY"}', mon, end), _on(2030, 9, 24)
    )
    _row(bad, _first('{"freq":"YEARLY","interval":4}', _day(2032, 2, 29), end), _on(2032, 2, 29))
    # Before 1970 the day count is negative: 1969-12-31 is day -1, a day
    # like any other.
    var eve = _day(1969, 12, 31)
    _row(bad, String(eve), "-1")
    _row(bad, _first('{"freq":"DAILY","interval":1,"count":3}', eve, end), "-1")
    _row(bad, _first('{"freq":"WEEKLY","interval":1,"weekdays":["WEDNESDAY"]}', eve, end), "-1")
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":31}', _day(1969, 12, 5), end), "-1")
    _row(bad, _first('{"freq":"MONTHLY","interval":1,"monthDay":30}', _day(1969, 12, 31), end), _on(1970, 1, 30))
    _row(bad, _first('{"freq":"YEARLY","interval":1}', _day(1965, 3, 14), end), _on(1965, 3, 14))
    assert_true(len(bad) == 0, String(len(bad)) + " rows wrong:" + _joined(bad))


def test_malformed() raises:
    var mon = _day(2030, 9, 2)
    _no("INTERVAL=2", mon, BAD, "RRULE has no FREQ")
    _no("FREQ=FORTNIGHTLY", mon, BAD, "RRULE FREQ=FORTNIGHTLY is not a frequency")
    _no("FREQ=DAILY;FREQ=WEEKLY", mon, BAD, "RRULE names FREQ twice")
    _no("FREQ=DAILY;COUNT", mon, BAD, 'RRULE part "COUNT" is not NAME=VALUE')
    _no("FREQ=DAILY;=3", mon, BAD, 'RRULE part "=3" is not NAME=VALUE')
    _no("FREQ=DAILY;INTERVAL=0", mon, BAD, "RRULE INTERVAL=0 is not a positive number")
    _no("FREQ=DAILY;COUNT=x", mon, BAD, "RRULE COUNT=X is not a positive number")
    _no("FREQ=DAILY;COUNT=3;UNTIL=20301001", mon, BAD, "RRULE has both COUNT and UNTIL")
    _no("FREQ=WEEKLY;BYDAY=2MO", mon, BAD, "RRULE BYDAY on a WEEKLY rule has an ordinal")
    _no("FREQ=WEEKLY;BYDAY=XX", mon, BAD, 'RRULE BYDAY item "XX" does not end in MO, TU, WE, TH, FR, SA or SU')
    _no("FREQ=MONTHLY;BYDAY=0FR", mon, BAD, 'RRULE BYDAY item "0FR" has an ordinal outside -53..-1 and 1..53')
    _no("FREQ=MONTHLY;BYDAY=F", mon, BAD, 'RRULE BYDAY item "F" is not [+/-][n]weekday')
    _no("FREQ=MONTHLY;BYMONTHDAY=0", mon, BAD, "RRULE BYMONTHDAY=0 is not a list of non-zero numbers")
    _no("FREQ=WEEKLY;WKST=XX", mon, BAD, "RRULE WKST=XX is not a weekday")
    _no("FREQ=DAILY;INTERVAL=", mon, BAD, "RRULE INTERVAL= is not a positive number")
    _no("FREQ=DAILY;COUNT=1234567", mon, BAD, "RRULE COUNT=1234567 is not a positive number")
    print("  test_malformed PASS")


def test_weekday_names() raises:
    assert_equal(weekday_name(1), "MO")
    assert_equal(weekday_name(7), "SU")
    assert_equal(weekday_name(0), "")
    assert_equal(weekday_name(8), "")
    print("  test_weekday_names PASS")


def main() raises:
    # Each test runs even when an earlier one fails; the failures are listed
    # together.
    print("test_rrule")
    var failed = List[String]()
    try:
        test_accepted()
    except e:
        failed.append("test_accepted: " + String(e))
    try:
        test_out_of_subset()
    except e:
        failed.append("test_out_of_subset: " + String(e))
    try:
        test_start_not_an_occurrence()
    except e:
        failed.append("test_start_not_an_occurrence: " + String(e))
    try:
        test_first_occurrence()
        print("  test_first_occurrence PASS")
    except e:
        failed.append("test_first_occurrence: " + String(e))
    try:
        test_malformed()
    except e:
        failed.append("test_malformed: " + String(e))
    try:
        test_weekday_names()
    except e:
        failed.append("test_weekday_names: " + String(e))
    for f in failed:
        print("  FAIL " + f)
    assert_true(len(failed) == 0, String(len(failed)) + " tests failed")
    print("ALL TESTS PASS")
