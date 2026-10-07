# =============================================================================
# test_http_date.mojo -- the IMF-fixdate
# =============================================================================
#
# Sections marked DISAGREEMENT pin a decision taken where the AWS timestamp
# codecs disagreed with each other: one required the text to be exactly 29
# bytes and ignored the day name, the other accepted a fraction after the
# seconds and a day name from the seven but never compared it with the date.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_datetime import (
    days_from_civil,
    format_http_date,
    parse_http_date,
    seconds_from_fields,
)


def test_the_rfc_example() raises:
    # RFC 9110 section 5.6.7's own example.
    assert_equal(parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"), 784111777)
    assert_equal(format_http_date(784111777), "Sun, 06 Nov 1994 08:49:37 GMT")


def test_every_weekday_and_month_name() raises:
    # 1970-01-01 Thu .. 1970-01-07 Wed; then one day in each month of 2023.
    var days = [
        "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"
    ]
    for i in range(7):
        var s = format_http_date((i) * 86400)
        assert_true(s.startswith(days[i] + ", 0" + String(i + 1) + " Jan 1970 00:00:00 GMT"))
    var months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]
    for m in range(1, 13):
        var s = format_http_date(seconds_from_fields(2023, m, 15, 13, 5, 9))
        assert_true(s.find(" 15 " + months[m - 1] + " 2023 13:05:09 GMT") == 4)
        assert_equal(
            parse_http_date(s), seconds_from_fields(2023, m, 15, 13, 5, 9)
        )


def test_round_trip_over_a_wide_range() raises:
    var first = days_from_civil(1583, 1, 1)
    var last = days_from_civil(2600, 1, 1)
    for day in range(first, last):
        var s = day * 86400 + (day % 86400 + 86400) % 86400
        var text = format_http_date(s)
        assert_equal(text.byte_length(), 29)
        assert_equal(parse_http_date(text, check_weekday=True), s)
    # Both ends of the writable range, and the instants before 1970.
    assert_equal(format_http_date(-1), "Wed, 31 Dec 1969 23:59:59 GMT")
    assert_equal(format_http_date(253402300799), "Fri, 31 Dec 9999 23:59:59 GMT")
    assert_equal(format_http_date(-62167219200), "Sat, 01 Jan 0000 00:00:00 GMT")
    assert_equal(parse_http_date("Fri, 31 Dec 9999 23:59:59 GMT"), 253402300799)
    assert_equal(parse_http_date("Sat, 01 Jan 0000 00:00:00 GMT"), -62167219200)
    with assert_raises(contains="four digits"):
        _ = format_http_date(253402300800)
    with assert_raises(contains="four digits"):
        _ = format_http_date(-62167219201)


def test_leap_days() raises:
    assert_equal(format_http_date(951782400), "Tue, 29 Feb 2000 00:00:00 GMT")
    assert_equal(parse_http_date("Tue, 29 Feb 2000 00:00:00 GMT"), 951782400)
    with assert_raises(contains="does not exist"):
        _ = parse_http_date("Thu, 29 Feb 1900 00:00:00 GMT")
    with assert_raises(contains="does not exist"):
        _ = parse_http_date("Mon, 29 Feb 2100 00:00:00 GMT")
    with assert_raises(contains="does not exist"):
        _ = parse_http_date("Fri, 31 Apr 2021 00:00:00 GMT")
    with assert_raises(contains="does not exist"):
        _ = parse_http_date("Fri, 00 Apr 2021 00:00:00 GMT")


# DISAGREEMENT: one AWS reader ignored the day name and the other only needed
# it to be one of the seven. Here it must be one of the seven, and it is
# compared with the date only on request (RFC 9110 calls it redundant and real
# peers mis-state it).
def test_day_name() raises:
    # 1994-11-06 was a Sunday.
    assert_equal(parse_http_date("Mon, 06 Nov 1994 08:49:37 GMT"), 784111777)
    with assert_raises(contains="does not match"):
        _ = parse_http_date("Mon, 06 Nov 1994 08:49:37 GMT", check_weekday=True)
    with assert_raises(contains="unknown day name"):
        _ = parse_http_date("Xyz, 06 Nov 1994 08:49:37 GMT")
    with assert_raises(contains="unknown day name"):
        _ = parse_http_date("sun, 06 Nov 1994 08:49:37 GMT")
    with assert_raises(contains="unknown month"):
        _ = parse_http_date("Sun, 06 nov 1994 08:49:37 GMT")
    with assert_raises(contains="unknown month"):
        _ = parse_http_date("Sun, 06 Foo 1994 08:49:37 GMT")


# DISAGREEMENT: one AWS reader took a fraction of a second after the seconds;
# HTTP has none. Anything but the exact 29-byte form is refused, and the two
# obsolete forms are refused by name rather than guessed at.
def test_other_shapes_are_refused() raises:
    with assert_raises(contains="IMF-fixdate"):
        _ = parse_http_date("Sun, 06 Nov 1994 08:49:37.5 GMT")
    with assert_raises(contains="IMF-fixdate"):
        _ = parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT")
    with assert_raises(contains="IMF-fixdate"):
        _ = parse_http_date("Sun Nov  6 08:49:37 1994")
    with assert_raises(contains="IMF-fixdate"):
        _ = parse_http_date("")
    with assert_raises(contains="IMF-fixdate"):
        _ = parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT ")
    with assert_raises(contains="IMF-fixdate"):
        _ = parse_http_date("Sun, 06 Nov 1994 08:49 GMT")


def test_malformed_29_byte_inputs() raises:
    var bad = [
        "Sun; 06 Nov 1994 08:49:37 GMT",
        "Sun,06  Nov 1994 08:49:37 GMT",
        "Sun, 0a Nov 1994 08:49:37 GMT",
        "Sun, 06-Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov-1994 08:49:37 GMT",
        "Sun, 06 Nov 19x4 08:49:37 GMT",
        "Sun, 06 Nov 1994T08:49:37 GMT",
        "Sun, 06 Nov 1994 08-49:37 GMT",
        "Sun, 06 Nov 1994 08:49-37 GMT",
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "Sun, 06 Nov 1994 08:49:37 gmt",
        "Sun, 06 Nov 1994 08:49:37_GMT",
        "Sun, 06 Nov 1994 24:00:00 GMT",
        "Sun, 06 Nov 1994 23:60:00 GMT",
        "Sun, 06 Nov 1994 23:59:60 GMT",
        "Sun, 00 Nov 1994 08:49:37 GMT",
        "Sun, 31 Nov 1994 08:49:37 GMT",
    ]
    for i in range(len(bad)):
        var raised = False
        try:
            _ = parse_http_date(bad[i])
        except:
            raised = True
        assert_true(raised)


def test_errors_name_no_protocol() raises:
    var bad = [
        "Sun, 06 Nov 1994",
        "Sun, 06 Foo 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "Sun, 31 Nov 1994 08:49:37 GMT",
    ]
    for i in range(len(bad)):
        var msg = String("")
        try:
            _ = parse_http_date(bad[i])
        except e:
            msg = String(e)
        assert_true(msg.byte_length() > 0)
        assert_true(msg.find("AWS") < 0)
        assert_true(msg.find("http-date") >= 0)


# Each of the three zone bytes is checked on its own. The 29-byte list above
# varies the zone only as a whole ("UTC", "gmt") or before it ("_GMT"), so a
# reader that compared just "GM" (bytes 26..27) would pass it; these inputs
# keep "GM" and change only byte 28, and one more each changes byte 26 or 27.
def test_every_zone_byte_is_checked() raises:
    # Control: the same shape with "GMT" reads, so the refusals below are
    # about the zone alone. 2026-11-06 is a Friday.
    assert_equal(
        parse_http_date("Fri, 06 Nov 2026 08:49:37 GMT", check_weekday=True),
        1793954977,
    )
    assert_equal(format_http_date(1793954977), "Fri, 06 Nov 2026 08:49:37 GMT")
    var bad = [
        "Fri, 06 Nov 2026 08:49:37 GMX",
        "Fri, 06 Nov 2026 08:49:37 GMt",
        "Fri, 06 Nov 2026 08:49:37 GM ",
        "Fri, 06 Nov 2026 08:49:37 GMZ",
        "Fri, 06 Nov 2026 08:49:37 XMT",
        "Fri, 06 Nov 2026 08:49:37 GXT",
    ]
    for i in range(len(bad)):
        assert_equal(bad[i].byte_length(), 29)
        with assert_raises(contains="not in GMT"):
            _ = parse_http_date(bad[i])


def main() raises:
    test_the_rfc_example()
    test_every_weekday_and_month_name()
    test_round_trip_over_a_wide_range()
    test_leap_days()
    test_day_name()
    test_other_shapes_are_refused()
    test_malformed_29_byte_inputs()
    test_errors_name_no_protocol()
    test_every_zone_byte_is_checked()
    print("all http-date tests passed")
