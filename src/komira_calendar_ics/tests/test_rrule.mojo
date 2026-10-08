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
# The first day is 2030-09-02, a Monday (2030-09-05 a Thursday).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_datetime import days_from_civil
from komira_proto_codec import encode_json
from komira_calendar_ics.rrule import format_rrule, parse_rrule, weekday_name


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
    var thu = _day(2030, 9, 5)
    _ok("FREQ=DAILY", mon, '{"freq":"DAILY","interval":1}')
    _ok("freq=daily;interval=3;count=10", mon, '{"freq":"DAILY","interval":3,"count":10}')
    _ok("FREQ=DAILY;UNTIL=20301224T000000Z", mon, '{"freq":"DAILY","interval":1}', "20301224T000000Z")
    _ok("FREQ=WEEKLY", mon, '{"freq":"WEEKLY","interval":1}')
    _ok(
        "FREQ=WEEKLY;BYDAY=TU,TH,TU;WKST=SU",
        mon,
        '{"freq":"WEEKLY","interval":1,"weekdays":["TUESDAY","THURSDAY"]}',
    )
    _ok(
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;WKST=SU",
        mon,
        '{"freq":"WEEKLY","interval":2,"weekdays":["MONDAY","WEDNESDAY","FRIDAY"]}',
    )
    _ok(
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=MO",
        mon,
        '{"freq":"WEEKLY","interval":2,"weekdays":["TUESDAY","SUNDAY"]}',
    )
    _ok("FREQ=WEEKLY;INTERVAL=2;WKST=SU", thu, '{"freq":"WEEKLY","interval":2}')
    _ok("FREQ=MONTHLY", thu, '{"freq":"MONTHLY","interval":1,"monthDay":5}')
    _ok("FREQ=MONTHLY;BYMONTHDAY=31", mon, '{"freq":"MONTHLY","interval":1,"monthDay":31}')
    _ok(
        "FREQ=MONTHLY;COUNT=10;BYDAY=1FR",
        mon,
        '{"freq":"MONTHLY","interval":1,"ordinal":1,"ordinalWeekday":"FRIDAY","count":10}',
    )
    _ok(
        "FREQ=MONTHLY;BYDAY=-1FR",
        mon,
        '{"freq":"MONTHLY","interval":1,"ordinal":-1,"ordinalWeekday":"FRIDAY"}',
    )
    _ok(
        "FREQ=MONTHLY;BYDAY=+4SA",
        mon,
        '{"freq":"MONTHLY","interval":1,"ordinal":4,"ordinalWeekday":"SATURDAY"}',
    )
    _ok(
        "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2",
        mon,
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
    print("test_rrule")
    test_accepted()
    test_out_of_subset()
    test_malformed()
    test_weekday_names()
    print("ALL TESTS PASS")
