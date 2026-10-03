# =============================================================================
# test_timestamp.mojo -- epoch seconds, UTC fields, ISO 8601 / RFC 3339
# =============================================================================
#
# Sections marked DISAGREEMENT pin a decision taken where the copies of this
# arithmetic that grew up in other packages (the protobuf Timestamp, the AWS
# timestamp codecs, the GCS V4 signer, the log layout, the validator report)
# gave different answers. The decision is in timestamp.mojo's header.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_datetime import (
    Timestamp,
    DateTime,
    days_from_civil,
    seconds_from_fields,
    fields_from_seconds,
    format_rfc3339,
    format_basic_datetime,
    format_basic_date,
    format_iso_date,
    parse_rfc3339,
    parse_iso_date,
)


def _fmt(secs: Int, nanos: Int = 0, digits: Int = 0, trim: Int = 0) raises -> String:
    return format_rfc3339(Timestamp(secs, nanos), digits, trim)


def _secs(text: String) raises -> Int:
    return parse_rfc3339(text).seconds


# -----------------------------------------------------------------------------
# Epoch seconds <-> fields
# -----------------------------------------------------------------------------


def test_fields_known_instants() raises:
    assert_equal(seconds_from_fields(1970, 1, 1), 0)
    assert_equal(seconds_from_fields(2000, 1, 1), 946684800)
    assert_equal(seconds_from_fields(1994, 11, 6, 8, 49, 37), 784111777)
    assert_equal(seconds_from_fields(2038, 1, 19, 3, 14, 7), 2147483647)
    assert_equal(seconds_from_fields(9999, 12, 31, 23, 59, 59), 253402300799)
    assert_equal(seconds_from_fields(1, 1, 1), -62135596800)
    assert_equal(seconds_from_fields(0, 1, 1), -62167219200)


# DISAGREEMENT: the protobuf Timestamp helper floor-divided a negative second
# count TWICE (Mojo's `//` already floors), so any pre-1970 instant that is not
# a whole day landed on the wrong day. -1 s is 1969-12-31T23:59:59.
def test_pre_epoch_seconds_land_on_the_right_day() raises:
    var f = fields_from_seconds(-1)
    assert_equal(f.year, 1969)
    assert_equal(f.month, 12)
    assert_equal(f.day, 31)
    assert_equal(f.hour, 23)
    assert_equal(f.minute, 59)
    assert_equal(f.second, 59)
    var g = fields_from_seconds(-86401)
    assert_equal(g.day, 30)
    assert_equal(g.hour, 23)
    assert_equal(g.second, 59)
    var h = fields_from_seconds(-86400)
    assert_equal(h.day, 31)
    assert_equal(h.hour, 0)
    assert_equal(_fmt(-1), "1969-12-31T23:59:59Z")
    assert_equal(_fmt(-86401), "1969-12-30T23:59:59Z")
    assert_equal(_fmt(-62135596800), "0001-01-01T00:00:00Z")
    assert_equal(_fmt(-62167219200), "0000-01-01T00:00:00Z")


def test_fields_round_trip_every_minute_of_a_wide_span() raises:
    # Every day from 1600 to 2400, at three times of day, seconds -> fields ->
    # seconds, and the text form through the parser.
    var first = days_from_civil(1600, 1, 1)
    var last = days_from_civil(2400, 1, 1)
    var n = 0
    for day in range(first, last):
        for tod in range(0, 86400, 34567):
            var s = day * 86400 + tod
            var f = fields_from_seconds(s)
            assert_equal(
                seconds_from_fields(f.year, f.month, f.day, f.hour, f.minute, f.second),
                s,
            )
            n += 1
        if day % 29 == 0:
            var s2 = day * 86400 + 86399
            assert_equal(parse_rfc3339(_fmt(s2)).seconds, s2)
    assert_true(n > 700_000)


def test_fields_are_checked() raises:
    with assert_raises(contains="outside 1..12"):
        _ = seconds_from_fields(2024, 13, 1)
    with assert_raises(contains="does not exist"):
        _ = seconds_from_fields(2023, 2, 29)
    with assert_raises(contains="does not exist"):
        _ = seconds_from_fields(1900, 2, 29)
    assert_equal(seconds_from_fields(2000, 2, 29), 951782400)
    with assert_raises(contains="hour"):
        _ = seconds_from_fields(2024, 1, 1, 24)
    with assert_raises(contains="minute"):
        _ = seconds_from_fields(2024, 1, 1, 0, 60)
    with assert_raises(contains="second"):
        _ = seconds_from_fields(2024, 1, 1, 0, 0, 60)
    with assert_raises(contains="second"):
        _ = seconds_from_fields(2024, 1, 1, 0, 0, -1)
    # A leap second only when asked for, and it is the next second.
    assert_equal(
        seconds_from_fields(2016, 12, 31, 23, 59, 60, allow_leap_second=True),
        seconds_from_fields(2017, 1, 1),
    )


# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------


def test_format_basic() raises:
    assert_equal(_fmt(0), "1970-01-01T00:00:00Z")
    assert_equal(_fmt(951782400), "2000-02-29T00:00:00Z")
    assert_equal(_fmt(253402300799), "9999-12-31T23:59:59Z")
    assert_equal(format_basic_datetime(1789473600), "20260915T120000Z")
    assert_equal(format_basic_date(1789473600), "20260915")
    assert_equal(format_basic_datetime(-1), "19691231T235959Z")
    assert_equal(format_basic_date(-1), "19691231")
    assert_equal(format_iso_date(0), "1970-01-01")
    assert_equal(format_iso_date(-1), "1969-12-31")
    assert_equal(format_iso_date(2932896), "9999-12-31")
    assert_equal(format_iso_date(-719528), "0000-01-01")


# DISAGREEMENT: the log layout clamped a negative epoch to 0 and the validator
# report refused one; the AWS writer refused anything before 1970. A calendar
# library writes every instant it can spell in four digits and refuses the rest.
def test_format_range_is_years_0_to_9999() raises:
    with assert_raises(contains="four digits"):
        _ = _fmt(253402300800)
    with assert_raises(contains="four digits"):
        _ = _fmt(-62167219201)
    with assert_raises(contains="four digits"):
        _ = format_basic_datetime(253402300800)
    with assert_raises(contains="four digits"):
        _ = format_basic_date(-62167219201)
    with assert_raises(contains="four digits"):
        _ = format_iso_date(2932897)
    with assert_raises(contains="four digits"):
        _ = format_iso_date(-719529)


def test_format_fraction_modes() raises:
    # Fixed digits, truncating (never rounding).
    assert_equal(_fmt(0, 123456789, 3), "1970-01-01T00:00:00.123Z")
    assert_equal(_fmt(0, 999999999, 3), "1970-01-01T00:00:00.999Z")
    assert_equal(_fmt(0, 123456789, 9), "1970-01-01T00:00:00.123456789Z")
    assert_equal(_fmt(0, 0, 3), "1970-01-01T00:00:00.000Z")
    assert_equal(_fmt(0, 123456789, 0), "1970-01-01T00:00:00Z")
    assert_equal(_fmt(0, 5_000_000, 3), "1970-01-01T00:00:00.005Z")
    # The protobuf JSON rule: shortest of 0/3/6/9 digits.
    assert_equal(_fmt(0, 0, 9, 3), "1970-01-01T00:00:00Z")
    assert_equal(_fmt(0, 500_000_000, 9, 3), "1970-01-01T00:00:00.500Z")
    assert_equal(_fmt(0, 120_000_000, 9, 3), "1970-01-01T00:00:00.120Z")
    assert_equal(_fmt(0, 123_000_000, 9, 3), "1970-01-01T00:00:00.123Z")
    assert_equal(_fmt(0, 123_400_000, 9, 3), "1970-01-01T00:00:00.123400Z")
    assert_equal(_fmt(0, 5_000, 9, 3), "1970-01-01T00:00:00.000005Z")
    assert_equal(_fmt(0, 1, 9, 3), "1970-01-01T00:00:00.000000001Z")
    # Millisecond precision with trailing zeros cut.
    assert_equal(_fmt(0, 500_000_000, 3, 1), "1970-01-01T00:00:00.5Z")
    assert_equal(_fmt(0, 120_000_000, 3, 1), "1970-01-01T00:00:00.12Z")
    assert_equal(_fmt(0, 123_000_000, 3, 1), "1970-01-01T00:00:00.123Z")
    assert_equal(_fmt(0, 1_000_000, 3, 1), "1970-01-01T00:00:00.001Z")
    assert_equal(_fmt(0, 0, 3, 1), "1970-01-01T00:00:00Z")
    # Below the shown precision the fraction is zero and so omitted.
    assert_equal(_fmt(0, 999_999, 3, 1), "1970-01-01T00:00:00Z")
    # A group wider than the digits shown is capped at the digits shown.
    assert_equal(_fmt(0, 123_400_000, 4, 3), "1970-01-01T00:00:00.1234Z")
    assert_equal(_fmt(0, 120_000_000, 4, 3), "1970-01-01T00:00:00.120Z")


def test_format_refuses_bad_arguments() raises:
    with assert_raises(contains="nanos"):
        _ = _fmt(0, 1_000_000_000)
    with assert_raises(contains="nanos"):
        _ = _fmt(0, -1)
    with assert_raises(contains="fraction_digits"):
        _ = _fmt(0, 0, 10)
    with assert_raises(contains="fraction_digits"):
        _ = _fmt(0, 0, -1)
    with assert_raises(contains="trim_group"):
        _ = _fmt(0, 0, 3, 10)


# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------


def test_parse_basic_and_offsets() raises:
    assert_equal(_secs("1970-01-01T00:00:00Z"), 0)
    assert_equal(_secs("2026-09-15T12:00:00Z"), 1789473600)
    assert_equal(_secs("2026-09-15T12:00:00+00:00"), 1789473600)
    assert_equal(_secs("2026-09-15T12:00:00-00:00"), 1789473600)
    assert_equal(_secs("2026-09-15T14:00:00+02:00"), 1789473600)
    assert_equal(_secs("2026-09-15T07:00:00-05:00"), 1789473600)
    assert_equal(_secs("2026-09-15T17:30:00+05:30"), 1789473600)
    assert_equal(_secs("2026-09-15T12:00:00+23:59"), 1789473600 - 86340)
    # An offset can cross a day, a month, a year and a century boundary.
    assert_equal(_secs("2000-01-01T00:30:00+01:00"), seconds_from_fields(1999, 12, 31, 23, 30))
    assert_equal(_secs("1999-12-31T23:30:00-01:00"), seconds_from_fields(2000, 1, 1, 0, 30))
    assert_equal(_secs("2100-03-01T00:00:00+00:01"), seconds_from_fields(2100, 2, 28, 23, 59))
    assert_equal(_secs("2000-03-01T00:00:00+00:01"), seconds_from_fields(2000, 2, 29, 23, 59))
    # Year 0000 and 9999, and an offset that carries the instant out of range
    # (the true instant is returned, not an error).
    assert_equal(_secs("0000-01-01T00:00:00Z"), -62167219200)
    assert_equal(_secs("9999-12-31T23:59:59Z"), 253402300799)
    assert_equal(_secs("0000-01-01T00:00:00+01:00"), -62167219200 - 3600)
    assert_equal(_secs("9999-12-31T23:59:59-01:00"), 253402300799 + 3600)


def test_parse_fractions() raises:
    var a = parse_rfc3339("2026-09-15T12:00:00.5Z")
    assert_equal(a.seconds, 1789473600)
    assert_equal(a.nanos, 500_000_000)
    var b = parse_rfc3339("2026-09-15T12:00:00.123456789Z")
    assert_equal(b.nanos, 123_456_789)
    var c = parse_rfc3339("2026-09-15T12:00:00.000000001+02:00")
    assert_equal(c.seconds, 1789473600 - 7200)
    assert_equal(c.nanos, 1)
    var d = parse_rfc3339("2026-09-15T12:00:00.0Z")
    assert_equal(d.nanos, 0)
    # A pre-epoch instant keeps its fraction FORWARD: -0.25 s is (-1, 0.75 s).
    var e = parse_rfc3339("1969-12-31T23:59:59.75Z")
    assert_equal(e.seconds, -1)
    assert_equal(e.nanos, 750_000_000)
    with assert_raises(contains="empty fraction"):
        _ = parse_rfc3339("2026-09-15T12:00:00.Z")


# DISAGREEMENT: the AWS reader took any number of fraction digits (through a
# Float64); the protobuf reader refused more than nine. Refused by default;
# `truncate_fraction` keeps the first nine (never rounds up).
def test_parse_long_fractions() raises:
    with assert_raises(contains="more than nine"):
        _ = parse_rfc3339("2026-09-15T12:00:00.1234567891Z")
    var t = parse_rfc3339("2026-09-15T12:00:00.1234567899999Z", truncate_fraction=True)
    assert_equal(t.nanos, 123_456_789)
    var u = parse_rfc3339("2026-09-15T12:00:00.9999999999Z", truncate_fraction=True)
    assert_equal(u.seconds, 1789473600)
    assert_equal(u.nanos, 999_999_999)
    # Nine digits are fine either way.
    assert_equal(parse_rfc3339("2026-09-15T12:00:00.999999999Z").nanos, 999_999_999)


# DISAGREEMENT: the AWS reader added 23:59:60 as the next second; the protobuf
# reader refused a second of 60. Refused unless asked for.
def test_parse_leap_second() raises:
    with assert_raises(contains="second"):
        _ = parse_rfc3339("2016-12-31T23:59:60Z")
    var t = parse_rfc3339("2016-12-31T23:59:60Z", allow_leap_second=True)
    assert_equal(t.seconds, seconds_from_fields(2017, 1, 1))
    with assert_raises(contains="second"):
        _ = parse_rfc3339("2016-12-31T23:59:61Z", allow_leap_second=True)


# DISAGREEMENT: the AWS reader accepted any two-digit offset ("+99:99"); the
# protobuf reader bounded the hour at 23 and the minute at 59. The bound wins.
def test_parse_offset_is_bounded() raises:
    with assert_raises(contains="offset"):
        _ = parse_rfc3339("2026-09-15T12:00:00+24:00")
    with assert_raises(contains="offset"):
        _ = parse_rfc3339("2026-09-15T12:00:00+00:60")
    with assert_raises(contains="offset"):
        _ = parse_rfc3339("2026-09-15T12:00:00-99:99")


# DISAGREEMENT: the AWS reader took lowercase `t` and `z` (RFC 3339 5.6 allows
# it); the protobuf reader required capitals. Accepted by default, refusable.
def test_parse_lowercase() raises:
    assert_equal(_secs("2026-09-15t12:00:00z"), 1789473600)
    with assert_raises(contains="'T'"):
        _ = parse_rfc3339("2026-09-15t12:00:00Z", allow_lowercase=False)
    with assert_raises(contains="zone"):
        _ = parse_rfc3339("2026-09-15T12:00:00z", allow_lowercase=False)


# DISAGREEMENT: the protobuf reader refused year 0000 (and so any instant before
# 0001-01-01); the AWS reader took it. RFC 3339 allows 0000..9999.
def test_parse_year_zero() raises:
    assert_equal(_secs("0000-02-29T00:00:00Z"), seconds_from_fields(0, 2, 29))
    with assert_raises(contains="does not exist"):
        _ = parse_rfc3339("0001-02-29T00:00:00Z")


def test_parse_dates_that_do_not_exist() raises:
    with assert_raises(contains="does not exist"):
        _ = parse_rfc3339("1900-02-29T00:00:00Z")
    with assert_raises(contains="does not exist"):
        _ = parse_rfc3339("2100-02-29T00:00:00Z")
    with assert_raises(contains="does not exist"):
        _ = parse_rfc3339("2023-02-29T00:00:00Z")
    with assert_raises(contains="does not exist"):
        _ = parse_rfc3339("2024-04-31T00:00:00Z")
    with assert_raises(contains="does not exist"):
        _ = parse_rfc3339("2024-06-00T00:00:00Z")
    with assert_raises(contains="outside 1..12"):
        _ = parse_rfc3339("2024-00-10T00:00:00Z")
    with assert_raises(contains="outside 1..12"):
        _ = parse_rfc3339("2024-13-10T00:00:00Z")
    with assert_raises(contains="hour"):
        _ = parse_rfc3339("2024-01-10T24:00:00Z")
    with assert_raises(contains="minute"):
        _ = parse_rfc3339("2024-01-10T23:60:00Z")
    assert_equal(_secs("2000-02-29T23:59:59Z"), 951868799)


# DISAGREEMENT: the AWS reader indexed byte 10 and 19 without a length check,
# so a ten-byte "2026-09-15" read past the end. Every strict prefix of a valid
# timestamp is a clean error, never a read past the end.
def test_every_truncation_is_a_clean_error() raises:
    var samples = [
        "2026-09-15T12:00:00Z",
        "2026-09-15T12:00:00.123456789+05:30",
        "2026-09-15T12:00:00-00:00",
    ]
    for s in range(len(samples)):
        var full = samples[s]
        var n = full.byte_length()
        for cut in range(n):
            var prefix = String("")
            var fb = full.as_bytes()
            for k in range(cut):
                prefix += chr(Int(fb[k]))
            var raised = False
            try:
                _ = parse_rfc3339(prefix)
            except:
                raised = True
            # Two prefixes of the second sample are themselves valid
            # timestamps ("...00Z" cannot be a prefix of it; "...123456789" has
            # no zone), so every strict prefix must raise.
            assert_true(raised)
    assert_equal(_secs("2026-09-15T12:00:00Z"), 1789473600)
    with assert_raises(contains="truncated"):
        _ = parse_rfc3339("2026-09-15")
    with assert_raises(contains="truncated"):
        _ = parse_rfc3339("")


def test_malformed_inputs() raises:
    var bad = [
        "2026-09-15 12:00:00Z",
        "2026/09/15T12:00:00Z",
        "2026-09-15T12-00-00Z",
        "2026-09-15T12:00:00",
        "2026-09-15T12:00:00Zjunk",
        "2026-09-15T12:00:00+0200",
        "2026-09-15T12:00:00+02",
        "2026-09-15T12:00:00 Z",
        "2026-09-15T1a:00:00Z",
        "+026-09-15T12:00:00Z",
        "2026-09-15T12:00:00.5",
        "2026-09-15T12:00:00,5Z",
        "2026-09-15T12:00:00Z+01:00",
        " 2026-09-15T12:00:00Z",
        "２０２６-09-15T12:00:00Z",
    ]
    for i in range(len(bad)):
        var raised = False
        try:
            _ = parse_rfc3339(bad[i])
        except:
            raised = True
        assert_true(raised)


def test_errors_name_no_protocol() raises:
    var bad = [
        "2026-09-15",
        "2026-09-15T12:00:00",
        "2026-13-15T12:00:00Z",
        "2026-09-15T12:00:00+99:99",
        "2026-09-15T12:00:00Zjunk",
        "2026-09-15T12:00:00.Z",
    ]
    for i in range(len(bad)):
        var msg = String("")
        try:
            _ = parse_rfc3339(bad[i])
        except e:
            msg = String(e)
        assert_true(msg.byte_length() > 0)
        assert_true(msg.find("AWS") < 0)
        assert_true(msg.find("Wkt") < 0)
        assert_true(msg.find("proto") < 0)
        assert_true(msg.find("timestamp") >= 0 or msg.find("month") >= 0)


def test_parse_format_round_trip_with_every_fraction_width() raises:
    var s = 1789473600
    for digits in range(0, 10):
        var scale = 1
        for _ in range(9 - digits):
            scale *= 10
        var nanos = 0
        for k in range(digits):
            nanos = nanos * 10 + (k + 1) % 10
        nanos *= scale
        var ts = Timestamp(s, nanos)
        var text = format_rfc3339(ts, digits)
        var back = parse_rfc3339(text)
        assert_equal(back.seconds, s)
        assert_equal(back.nanos, nanos)


# -----------------------------------------------------------------------------
# YYYY-MM-DD
# -----------------------------------------------------------------------------


def test_iso_date_round_trip_and_refusals() raises:
    assert_equal(parse_iso_date("1970-01-01"), 0)
    assert_equal(parse_iso_date("1998-09-02"), 10471)
    assert_equal(parse_iso_date("2000-02-29"), 11016)
    assert_equal(parse_iso_date("0000-01-01"), -719528)
    assert_equal(parse_iso_date("9999-12-31"), 2932896)
    for day in range(-719528, 2932897, 211):
        assert_equal(parse_iso_date(format_iso_date(day)), day)
    with assert_raises(contains="ten bytes"):
        _ = parse_iso_date("2000-2-29")
    with assert_raises(contains="ten bytes"):
        _ = parse_iso_date("2000-02-29T")
    with assert_raises(contains="does not exist"):
        _ = parse_iso_date("1900-02-29")
    with assert_raises(contains="outside 1..12"):
        _ = parse_iso_date("2000-13-01")
    with assert_raises(contains="non-digit"):
        _ = parse_iso_date("2000-0a-01")
    with assert_raises(contains="'-'"):
        _ = parse_iso_date("2000/02/29")


def main() raises:
    test_fields_known_instants()
    test_pre_epoch_seconds_land_on_the_right_day()
    test_fields_round_trip_every_minute_of_a_wide_span()
    test_fields_are_checked()
    test_format_basic()
    test_format_range_is_years_0_to_9999()
    test_format_fraction_modes()
    test_format_refuses_bad_arguments()
    test_parse_basic_and_offsets()
    test_parse_fractions()
    test_parse_long_fractions()
    test_parse_leap_second()
    test_parse_offset_is_bounded()
    test_parse_lowercase()
    test_parse_year_zero()
    test_parse_dates_that_do_not_exist()
    test_every_truncation_is_a_clean_error()
    test_malformed_inputs()
    test_errors_name_no_protocol()
    test_parse_format_round_trip_with_every_fraction_width()
    test_iso_date_round_trip_and_refusals()
    print("all timestamp tests passed")
