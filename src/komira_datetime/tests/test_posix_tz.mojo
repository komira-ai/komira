# =============================================================================
# test_posix_tz.mojo -- the POSIX TZ string: the grammar, the rule dates, DST
# =============================================================================
#
# Rule dates are checked against days_from_civil of dates read off a printed
# calendar (the weekday of the 1st is derived in each comment), and DST
# edges against instants built with seconds_from_fields, so no expected value
# comes from the code under test.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_datetime import (
    PosixRule,
    RULE_DAY_OF_YEAR,
    RULE_JULIAN,
    RULE_MONTH_WEEK_DAY,
    days_from_civil,
    parse_posix_tz,
    seconds_from_fields,
)


def _refused(text: String, message: String) raises:
    var got = String()
    try:
        _ = parse_posix_tz(text)
    except e:
        got = String(e)
    assert_equal(got, 'POSIX TZ string "' + text + '": ' + message)


def test_rule_dates() raises:
    # 2007-03-01 was a Thursday: the Sundays are the 4th and the 11th.
    var second_sunday_march = PosixRule(RULE_MONTH_WEEK_DAY, 0, 3, 2, 0, 7200)
    assert_equal(second_sunday_march.date_in_year(2007), days_from_civil(2007, 3, 11))
    # 2007-11-01 was a Thursday: the first Sunday is the 4th.
    var first_sunday_november = PosixRule(RULE_MONTH_WEEK_DAY, 0, 11, 1, 0, 7200)
    assert_equal(first_sunday_november.date_in_year(2007), days_from_civil(2007, 11, 4))
    # 2040-01-01 is a Sunday; 1 March is day 60 (a Thursday), 1 October day
    # 274 (a Monday). Last Sundays: 25 March and 28 October (week 5 = last).
    var last_sunday_march = PosixRule(RULE_MONTH_WEEK_DAY, 0, 3, 5, 0, 3600)
    assert_equal(last_sunday_march.date_in_year(2040), days_from_civil(2040, 3, 25))
    var last_sunday_october = PosixRule(RULE_MONTH_WEEK_DAY, 0, 10, 5, 0, 3600)
    assert_equal(last_sunday_october.date_in_year(2040), days_from_civil(2040, 10, 28))
    # Jn never counts 29 February: J60 is 1 March in a leap year too.
    var j60 = PosixRule(RULE_JULIAN, 60, 0, 0, 0, 0)
    assert_equal(j60.date_in_year(2028), days_from_civil(2028, 3, 1))
    assert_equal(j60.date_in_year(2027), days_from_civil(2027, 3, 1))
    var j365 = PosixRule(RULE_JULIAN, 365, 0, 0, 0, 0)
    assert_equal(j365.date_in_year(2028), days_from_civil(2028, 12, 31))
    # n counts from 0 and counts 29 February.
    var n59 = PosixRule(RULE_DAY_OF_YEAR, 59, 0, 0, 0, 0)
    assert_equal(n59.date_in_year(2028), days_from_civil(2028, 2, 29))
    assert_equal(n59.date_in_year(2027), days_from_civil(2027, 3, 1))


def test_us_rules() raises:
    var tz = parse_posix_tz("EST5EDT,M3.2.0,M11.1.0")
    assert_equal(tz.standard.utc_offset, -18000)
    assert_equal(tz.daylight.utc_offset, -14400)
    assert_equal(tz.standard.abbreviation, "EST")
    assert_equal(tz.daylight.abbreviation, "EDT")
    assert_true(tz.has_dst)
    assert_equal(tz.start.time, 7200)
    # 2040: DST from Sunday 11 March 02:00 EST (07:00Z) to Sunday 4 November
    # 02:00 EDT (06:00Z).
    var before_start = tz.offset_at(seconds_from_fields(2040, 3, 11, 6, 59, 59))
    assert_equal(before_start.utc_offset, -18000)
    assert_false(before_start.is_dst)
    var at_start = tz.offset_at(seconds_from_fields(2040, 3, 11, 7, 0, 0))
    assert_equal(at_start.utc_offset, -14400)
    assert_equal(at_start.abbreviation, "EDT")
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 11, 4, 5, 59, 59)).abbreviation, "EDT"
    )
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 11, 4, 6, 0, 0)).abbreviation, "EST"
    )
    assert_equal(
        tz.next_edge_after(seconds_from_fields(2040, 1, 1)),
        seconds_from_fields(2040, 3, 11, 7),
    )
    assert_equal(
        tz.next_edge_after(seconds_from_fields(2040, 3, 11, 7)),
        seconds_from_fields(2040, 11, 4, 6),
    )


def test_southern_half_hour_rules() raises:
    # Lord Howe Island: +10:30 standard, +11 daylight, from the first Sunday
    # of October to the first Sunday of April, both at 02:00 local.
    var tz = parse_posix_tz("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0")
    assert_equal(tz.standard.utc_offset, 37800)
    assert_equal(tz.daylight.utc_offset, 39600)
    assert_equal(tz.standard.abbreviation, "+1030")
    # 2040-04-01 is a Sunday: 02:00 +11 is 2040-03-31T15:00Z.
    assert_equal(tz.offset_at(seconds_from_fields(2040, 1, 15)).utc_offset, 39600)
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 3, 31, 14, 59, 59)).utc_offset, 39600
    )
    assert_equal(tz.offset_at(seconds_from_fields(2040, 3, 31, 15)).utc_offset, 37800)
    assert_equal(tz.offset_at(seconds_from_fields(2040, 6, 15)).utc_offset, 37800)
    # 2040-10-07 is the first Sunday: 02:00 +10:30 is 2040-10-06T15:30Z.
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 10, 6, 15, 29, 59)).utc_offset, 37800
    )
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 10, 6, 15, 30)).utc_offset, 39600
    )
    assert_equal(tz.offset_at(seconds_from_fields(2040, 12, 31, 23)).utc_offset, 39600)


def test_negative_rule_time() raises:
    # -02 standard, -01 daylight; DST from the last Sunday of March at -1:00
    # (Saturday 23:00 local, Sunday 01:00Z) to the last Sunday of October at
    # 0:00 daylight (01:00Z).
    var tz = parse_posix_tz("<-02>2<-01>,M3.5.0/-1,M10.5.0/0")
    assert_equal(tz.start.time, -3600)
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 3, 25, 0, 59, 59)).utc_offset, -7200
    )
    assert_equal(tz.offset_at(seconds_from_fields(2040, 3, 25, 1)).utc_offset, -3600)
    assert_equal(
        tz.offset_at(seconds_from_fields(2040, 10, 28, 0, 59, 59)).utc_offset, -3600
    )
    assert_equal(tz.offset_at(seconds_from_fields(2040, 10, 28, 1)).utc_offset, -7200)


def test_dst_all_year() raises:
    # RFC 8536 section 3.3.1: from 1 January 00:00 to 31 December 24:00 plus
    # the one-hour difference is DST all year.
    var tz = parse_posix_tz("EST5EDT4,0/0,J365/25")
    var instants = [
        seconds_from_fields(2040, 1, 1, 4, 59, 59),
        seconds_from_fields(2040, 1, 1, 5),
        seconds_from_fields(2040, 7, 1),
        seconds_from_fields(2040, 12, 31, 23, 59, 59),
        seconds_from_fields(2041, 1, 1, 5),
    ]
    for i in range(len(instants)):
        assert_true(tz.offset_at(instants[i]).is_dst)
        assert_equal(tz.offset_at(instants[i]).utc_offset, -14400)


def test_fixed_offsets() raises:
    var utc = parse_posix_tz("UTC0")
    assert_false(utc.has_dst)
    assert_equal(utc.offset_at(0).utc_offset, 0)
    assert_equal(utc.offset_at(0).abbreviation, "UTC")
    var kathmandu = parse_posix_tz("<+0545>-5:45")
    assert_equal(kathmandu.offset_at(0).utc_offset, 20700)
    var plus = parse_posix_tz("<-03>+3")
    assert_equal(plus.offset_at(0).utc_offset, -10800)
    var seconds = parse_posix_tz("LMT-0:01:15")
    assert_equal(seconds.offset_at(0).utc_offset, 75)
    var default_dst = parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3")
    assert_equal(default_dst.daylight.utc_offset, 7200)
    assert_equal(default_dst.end.time, 10800)
    var long_time = parse_posix_tz("XXX3YYY,M3.2.0/167,M11.1.0")
    assert_equal(long_time.start.time, 167 * 3600)


def test_refusals() raises:
    _refused("EST", "standard offset: expected a digit at byte 3")
    _refused("ES5", "standard time name: fewer than 3 characters")
    _refused("<+05", "standard time name: no closing >")
    _refused("<+0 5>5", "standard time name: byte 3 is not a letter, digit, + or -")
    _refused("EST25", "standard offset: hours 25 are outside 0..24")
    _refused("EST5:60", "standard offset: minutes 60 are outside 0..59")
    _refused("EST5:00:60", "standard offset: seconds 60 are outside 0..59")
    _refused("EST1000", "standard offset: more than 3 digits")
    _refused("EST5EDT", "a DST name needs a rule: ,start[/time],end[/time]")
    _refused("EST5ED,M3.2.0,M11.1.0", "DST name: fewer than 3 characters")
    _refused("EST5EDT,M13.1.0,M11.1.0", "DST start: month 13 is outside 1..12")
    _refused("EST5EDT,M3.6.0,M11.1.0", "DST start: week 6 is outside 1..5")
    _refused("EST5EDT,M3.2-0,M11.1.0", "DST start: expected . after the week")
    _refused("EST5EDT,M3.2.7,M11.1.0", "DST start: weekday 7 is outside 0..6")
    _refused("EST5EDT,M3-2.0,M11.1.0", "DST start: expected . after the month")
    _refused("EST5EDT,J0,J300", "DST start: Julian day 0 is outside 1..365")
    _refused("EST5EDT,366,J300", "DST start: day 366 is outside 0..365")
    _refused("EST5EDT,M3.2.0", "expected , before the DST end rule")
    _refused("EST5EDT,M3.2.0,M11.1.0x", "unexpected byte at 22")
    _refused(
        "XXX3YYY,M3.2.0/168,M11.1.0", "DST start time: hours 168 are outside 0..167"
    )
    _refused("EST5EDT,M3.2.0,M11.1.0/x", "DST end time: expected a digit at byte 23")


def main() raises:
    test_rule_dates()
    test_us_rules()
    test_southern_half_hour_rules()
    test_negative_rule_time()
    test_dst_all_year()
    test_fixed_offsets()
    test_refusals()
    print("all posix tz tests passed")
