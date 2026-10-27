# `parse_date_time` over the forms real mail carries: RFC 5322 section 3.3
# date-time with numeric zones; the obsolete zone names (UT, GMT, the US
# zones, military letters as -0000) and 2- and 3-digit years of section 4.3;
# an optional day-of-week and seconds; comments and folding between tokens; a
# leap day; a leap second; and the inputs refused, each by its exact message
# and none holding an input byte. Expected epoch milliseconds are literals
# computed outside the code under test (Python's calendar.timegm). A last test
# reads what `format_date` writes.

from std.testing import assert_equal, assert_true

from komira_mail_message import error_kind, format_date, parse_date_time

comptime NOT_SET = "not raised"
comptime SYNTAX_PREFIX = "komira_mail_message.Syntax: parse_date_time: "


def _ms(s: String) raises -> Int:
    return parse_date_time(s.as_bytes())


def _err(s: String) -> String:
    try:
        _ = parse_date_time(s.as_bytes())
    except e:
        return String(e)
    return String(NOT_SET)


def test_numeric_zones() raises:
    # RFC 5322 appendix A.1.1.
    assert_equal(_ms("Fri, 21 Nov 1997 09:55:06 -0600"), 880127706000)
    assert_equal(_ms("Fri, 21 Nov 1997 09:55:06 +0530"), 880086306000)
    assert_equal(_ms("Fri, 21 Nov 1997 09:55:06 +0000"), _ms("Fri, 21 Nov 1997 09:55:06 -0000"))
    assert_equal(_ms("Thu, 1 Oct 2026 12:00:00 +0000"), 1790856000000)
    # A zone of -14:39 (the hour and minute digits as 1439).
    assert_equal(_ms("1 Oct 2026 12:00:00 -1439"), 1790908740000)


def test_optional_day_of_week_and_seconds() raises:
    assert_equal(_ms("21 Nov 1997 09:55 +0000"), 880106100000)
    assert_equal(_ms("21 Nov 1997 09:55:00 +0000"), 880106100000)
    assert_equal(_ms("Fri, 21 Nov 1997 09:55 +0000"), 880106100000)
    # The day-of-week is a name, not checked against the date.
    assert_equal(_ms("Mon, 21 Nov 1997 09:55 +0000"), 880106100000)
    assert_equal(_ms("fri, 21 nov 1997 09:55 gmt"), 880106100000)
    assert_equal(_ms("FRI, 21 NOV 1997 09:55 UT"), 880106100000)
    assert_equal(_ms("1 Jan 1970 00:00:00 +0000"), 0)
    assert_equal(_ms("1 Jan 1900 00:00:00 +0000"), -2208988800000)


def test_obs_zone_names() raises:
    var noon = 1790856000000
    assert_equal(_ms("1 Oct 2026 12:00:00 UT"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 GMT"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 UTC"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 Z"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 EST"), 1790874000000)
    assert_equal(_ms("1 Oct 2026 12:00:00 EDT"), 1790870400000)
    assert_equal(_ms("1 Oct 2026 12:00:00 CST"), 1790877600000)
    assert_equal(_ms("1 Oct 2026 12:00:00 CDT"), 1790874000000)
    assert_equal(_ms("1 Oct 2026 12:00:00 MST"), 1790881200000)
    assert_equal(_ms("1 Oct 2026 12:00:00 MDT"), 1790877600000)
    assert_equal(_ms("1 Oct 2026 12:00:00 PST"), 1790884800000)
    assert_equal(_ms("1 Oct 2026 12:00:00 PDT"), 1790881200000)
    assert_equal(_ms("1 Oct 2026 12:00:00 pdt"), 1790881200000)


def test_military_and_unknown_zone_names_are_minus_zero() raises:
    # RFC 5322 section 4.3: military letters, and any name whose meaning is
    # not known, SHOULD be read as -0000.
    var noon = 1790856000000
    assert_equal(_ms("1 Oct 2026 12:00:00 A"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 J"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 M"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 N"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 Y"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 CEST"), noon)
    assert_equal(_ms("1 Oct 2026 12:00:00 ESTT"), noon)


def test_two_and_three_digit_years() raises:
    assert_equal(_ms("1 Jan 49 00:00:00 +0000"), 2493072000000)
    assert_equal(_ms("1 Jan 50 00:00:00 +0000"), -631152000000)
    assert_equal(_ms("1 Jan 00 00:00:00 +0000"), 946684800000)
    assert_equal(_ms("1 Jun 99 12:00:00 +0000"), 928238400000)
    # Three digits: 1900 + the value.
    assert_equal(_ms("1 Jan 100 00:00:00 +0000"), 946684800000)
    assert_equal(_ms("1 Jun 099 12:00:00 +0000"), 928238400000)
    assert_equal(_ms("1 Jan 000 00:00:00 +0000"), -2208988800000)


def test_leap_day_and_leap_second() raises:
    assert_equal(_ms("Thu, 29 Feb 2024 00:00:00 +0000"), 1709164800000)
    assert_equal(_ms("29 Feb 2000 00:00:00 +0000"), 951782400000)
    assert_equal(_ms("29 Feb 00 00:00:00 +0000"), 951782400000)
    assert_equal(_ms("29 Feb 2028 00:00:00 +0000") - _ms("28 Feb 2028 00:00:00 +0000"), 86400000)
    # 1900 and 2023 are not leap years.
    assert_equal(_err("29 Feb 1900 00:00:00 +0000"), String(SYNTAX_PREFIX) + "a day that is not in its month at position 0")
    assert_equal(_err("29 Feb 2023 00:00:00 +0000"), String(SYNTAX_PREFIX) + "a day that is not in its month at position 0")
    # 23:59:60 is the first second of the next minute.
    assert_equal(_ms("31 Dec 2016 23:59:60 +0000"), 1483228800000)
    assert_equal(_ms("31 Dec 2016 23:59:60 +0000"), _ms("1 Jan 2017 00:00:00 +0000"))


def test_comments_and_folding() raises:
    var expected = 880127706000
    assert_equal(_ms("Fri, 21 Nov 1997 09:55:06 -0600 (CST)"), expected)
    assert_equal(_ms("(a date) Fri, 21 Nov 1997 09:55:06 -0600"), expected)
    assert_equal(_ms("Fri (a (nested) \\) comment), 21 Nov\r\n 1997 09:55:06 -0600"), expected)
    assert_equal(_ms("  Fri,\t21   Nov\r\n\t1997\r\n 09 : 55 : 06\r\n -0600  "), expected)
    assert_equal(_ms("Fri, 21 Nov 1997 09:55:06 (zone follows) -0600"), expected)
    # A folded value read straight from a header: LF only.
    assert_equal(_ms("Fri, 21 Nov\n 1997 09:55:06 -0600"), expected)
    assert_equal(_ms("Fri,21 Nov 1997 09:55:06-0600"), expected)


def test_malformed_dates_are_refused() raises:
    var p = String(SYNTAX_PREFIX)
    assert_equal(_err(""), p + "a day that is not a number at position 0")
    assert_equal(_err("  (only a comment)  "), p + "a day that is not a number at position 20")
    assert_equal(_err("not a date"), p + "a day that is not a number at position 0")
    assert_equal(_err("Xyz, 21 Nov 1997 09:55:06 -0600"), p + "a day-of-week that is not a day name at position 0")
    assert_equal(_err("Fridays, 21 Nov 1997 09:55:06 -0600"), p + "a day-of-week that is not a day name at position 0")
    assert_equal(_err("21"), p + "a date that ends before the month at position 2")
    assert_equal(_err("21 Nox 1997 09:55:06 -0600"), p + "a month that is not a month name at position 3")
    assert_equal(_err("21 November 1997 09:55:06 -0600"), p + "a month that is not a month name at position 3")
    assert_equal(_err("21 Nov"), p + "a year that is not a number at position 6")
    assert_equal(_err("21 Nov x 09:55:06 -0600"), p + "a year that is not a number at position 7")
    assert_equal(_err("0 Nov 1997 09:55:06 -0600"), p + "a day that is not in its month at position 0")
    assert_equal(_err("31 Nov 1997 09:55:06 -0600"), p + "a day that is not in its month at position 0")
    assert_equal(_err("32 Jan 1997 09:55:06 -0600"), p + "a day that is not in its month at position 0")
    assert_equal(_err("021 Nov 1997 09:55:06 -0600"), p + "a day of more than 2 digits at position 0")
    assert_equal(_err("21 Nov 7 09:55:06 -0600"), p + "a year that is not 2, 3 or 4 digits, or before 1900 at position 7")
    assert_equal(_err("21 Nov 19970 09:55:06 -0600"), p + "a year that is not 2, 3 or 4 digits, or before 1900 at position 7")
    assert_equal(_err("21 Nov 1899 09:55:06 -0600"), p + "a year that is not 2, 3 or 4 digits, or before 1900 at position 7")
    assert_equal(_err("21 Nov 1997"), p + "a time that does not start with an hour at position 11")
    assert_equal(_err("21 Nov 1997 09:"), p + "a time that does not start with an hour at position 12")
    assert_equal(_err("21 Nov 1997 09:55"), p + "a date with no zone at position 17")
    assert_equal(_err("21 Nov 1997 123:55:06 -0600"), p + "a time that does not start with an hour at position 12")
    assert_equal(_err("21 Nov 1997 09 55 06 -0600"), p + "an hour not followed by ':' at position 15")
    assert_equal(_err("21 Nov 1997 09:5:06 -0600"), p + "a minute that is not 2 digits at position 15")
    assert_equal(_err("21 Nov 1997 09:55:6 -0600"), p + "a second that is not 2 digits at position 17")
    assert_equal(_err("21 Nov 1997 09:55: -0600"), p + "a second that is not 2 digits at position 17")
    assert_equal(_err("21 Nov 1997 24:00:00 -0600"), p + "a time outside 00:00:00..23:59:60 at position 18")
    assert_equal(_err("21 Nov 1997 09:60:00 -0600"), p + "a time outside 00:00:00..23:59:60 at position 18")
    assert_equal(_err("21 Nov 1997 09:55:61 -0600"), p + "a time outside 00:00:00..23:59:60 at position 18")
    assert_equal(_err("21 Nov 1997 09:55:06"), p + "a date with no zone at position 20")
    assert_equal(_err("21 Nov 1997 09:55:06 (UTC)"), p + "a date with no zone at position 26")
    assert_equal(_err("21 Nov 1997 09:55:06 +01"), p + "a numeric zone that is not 4 digits at position 21")
    assert_equal(_err("21 Nov 1997 09:55:06 +"), p + "a numeric zone that is not 4 digits at position 21")
    assert_equal(_err("21 Nov 1997 09:55:06 +01000"), p + "a numeric zone that is not 4 digits at position 21")
    assert_equal(_err("21 Nov 1997 09:55:06 +0160"), p + "a zone with minutes over 59 at position 22")
    assert_equal(_err("21 Nov 1997 09:55:06 , 1"), p + "a zone that is neither numeric nor a name at position 21")
    assert_equal(_err("21 Nov 1997 09:55:06 12"), p + "a zone that is neither numeric nor a name at position 21")
    assert_equal(_err("21 Nov 1997 09:55:06 GMT extra"), p + "text after the zone at position 25")
    assert_equal(_err("21 Nov 1997 09:55:06 +0000 +0000"), p + "text after the zone at position 27")


def test_malformed_lexical_forms_are_refused() raises:
    var p = String(SYNTAX_PREFIX)
    assert_equal(_err("21 Nov 1997 (never closed 09:55:06 -0600"), p + "a comment that is not closed at position 12")
    assert_equal(_err("21 Nov 1997 (a (nested) 09:55:06 -0600"), p + "a comment that is not closed at position 12")
    assert_equal(_err("21 Nov 1997 (a \\"), p + "a comment that is not closed at position 12")
    assert_equal(_err("21 Nov 1997 09:55:06 @0000"), p + "a byte not allowed in a date at position 21")
    assert_equal(_err("21 Nov 1997 09:55:06 \"GMT\""), p + "a byte not allowed in a date at position 21")
    assert_equal(_err("21 Nov 1234567890 09:55:06 GMT"), p + "a number of more than 9 digits at position 7")
    assert_equal(_err("1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17"), p + "more tokens than a date holds at position 39")
    # A NUL is not white space.
    var with_nul = String("21 Nov 1997 09:55:06 ") + chr(0) + "GMT"
    assert_equal(_err(with_nul), p + "a byte not allowed in a date at position 21")


def test_errors_are_named_and_hold_no_input() raises:
    var msg = _err("secret-token 21 Nov 1997")
    assert_true(msg.startswith("komira_mail_message.Syntax: parse_date_time: "), msg)
    assert_true("secret" not in msg, msg)
    try:
        _ = _ms("")
        assert_true(False, "an empty date was read")
    except e:
        assert_equal(error_kind(e), "Syntax")


def test_reads_what_format_date_writes() raises:
    var seconds = List[Int]()
    seconds.append(0)
    seconds.append(951782400)  # 2000-02-29
    seconds.append(1709164800)  # 2024-02-29
    seconds.append(1790856000)
    seconds.append(253402300799)  # 9999-12-31T23:59:59Z
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(330)
    offsets.append(-480)
    offsets.append(1439)
    for i in range(len(seconds)):
        for k in range(len(offsets)):
            # Instants within an offset of 1970 are skipped: the written
            # local time would precede 1970.
            if seconds[i] + offsets[k] * 60 < 0:
                continue
            # Nor those whose local time is past 9999.
            if seconds[i] + offsets[k] * 60 > 253402300799:
                continue
            var text = format_date(seconds[i], offsets[k])
            assert_equal(_ms(text), seconds[i] * 1000, text)


def main() raises:
    test_numeric_zones()
    test_optional_day_of_week_and_seconds()
    test_obs_zone_names()
    test_military_and_unknown_zone_names_are_minus_zero()
    test_two_and_three_digit_years()
    test_leap_day_and_leap_second()
    test_comments_and_folding()
    test_malformed_dates_are_refused()
    test_malformed_lexical_forms_are_refused()
    test_errors_are_named_and_hold_no_input()
    test_reads_what_format_date_writes()
    print("test_date_parse: OK")
