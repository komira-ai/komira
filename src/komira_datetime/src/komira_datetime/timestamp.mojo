# =============================================================================
# komira_datetime/timestamp.mojo -- epoch seconds, fields, ISO 8601 / RFC 3339
# =============================================================================
#
# An instant is a `Timestamp`: whole seconds since 1970-01-01T00:00:00Z (may be
# negative) plus `nanos` in [0, 999999999] counted FORWARD from those seconds,
# so -0.25 s is (seconds = -1, nanos = 750000000). Leap seconds are not
# instants: POSIX time has none, so 23:59:60 is only ever accepted on input (and
# only when asked for) and maps to the following second.
#
# WHAT IS READ (`parse_rfc3339`):
#
#     YYYY-MM-DDTHH:MM:SS[.f{1,}](Z | +HH:MM | -HH:MM)
#
#   * year 0000..9999 (four digits), a real month and day (leap years included),
#     hour 00..23, minute 00..59, second 00..59 (60 with `allow_leap_second`);
#   * the fraction has one or more digits; more than nine is refused unless
#     `truncate_fraction`, which keeps the first nine (it truncates, it does
#     not round, so a parse never moves an instant forward);
#   * the offset is applied: the result is always UTC. Its hour is 00..23 and
#     its minute 00..59. `-00:00` is read as `+00:00`;
#   * `t` and `z` are accepted for `T` and `Z` (RFC 3339 section 5.6 permits
#     it) unless `allow_lowercase=False`;
#   * the offset may carry the instant outside 0000..9999 (0000-01-01T00:00:00
#     +01:00 is in year -1): the result is the true instant, so a caller with a
#     narrower range checks the seconds.
#   * any other byte, a missing zone and text after the zone are refused. No
#     byte past the end of the input is ever read.
#
# WHAT IS WRITTEN (`format_rfc3339`): always UTC with `Z`, year 0000..9999,
# the fraction truncated to `fraction_digits` and optionally trimmed (see the
# function). The compact forms SigV4 and the GCS V4 signer put in a header
# (`20260915T120000Z`, `20260915`) and `YYYY-MM-DD` are here too.
#
# Every error names what is wrong in plain words and never echoes more than a
# field value; none names a protocol or a cloud.
# =============================================================================

from .civil import (
    civil_from_days,
    days_from_civil,
    days_in_month,
)

comptime SECONDS_PER_DAY = 86400
comptime NANOS_PER_SECOND = 1_000_000_000


@fieldwise_init
struct Timestamp(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """UTC seconds since the Unix epoch and a forward `nanos` in [0, 10^9)."""

    var seconds: Int
    var nanos: Int


@fieldwise_init
struct DateTime(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """UTC wall-clock fields. `second` is 0..59 (never 60)."""

    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int


# -----------------------------------------------------------------------------
# Epoch seconds <-> fields
# -----------------------------------------------------------------------------


def seconds_from_fields(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0,
    second: Int = 0,
    allow_leap_second: Bool = False,
) raises -> Int:
    """Epoch seconds of UTC fields. Every field is checked: the day must exist,
    hour 0..23, minute 0..59, second 0..59 (0..60 with `allow_leap_second`, in
    which case 60 counts as the first second of the next minute)."""
    if month < 1 or month > 12:
        raise Error("month " + String(month) + " is outside 1..12")
    if day < 1 or day > days_in_month(year, month):
        raise Error(
            "day "
            + String(day)
            + " does not exist in month "
            + String(month)
            + " of year "
            + String(year)
        )
    if hour < 0 or hour > 23:
        raise Error("hour " + String(hour) + " is outside 0..23")
    if minute < 0 or minute > 59:
        raise Error("minute " + String(minute) + " is outside 0..59")
    var top = 60 if allow_leap_second else 59
    if second < 0 or second > top:
        raise Error("second " + String(second) + " is outside 0.." + String(top))
    return (
        days_from_civil(year, month, day) * SECONDS_PER_DAY
        + hour * 3600
        + minute * 60
        + second
    )


def fields_from_seconds(seconds: Int) -> DateTime:
    """The UTC fields of epoch seconds, floor semantics: -1 is
    1969-12-31T23:59:59."""
    var days = seconds // SECONDS_PER_DAY
    var sod = seconds - days * SECONDS_PER_DAY
    var date = civil_from_days(days)
    return DateTime(
        date.year,
        date.month,
        date.day,
        sod // 3600,
        (sod % 3600) // 60,
        sod % 60,
    )


# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------


def _pad(mut out: String, v: Int, width: Int):
    var s = String(v)
    for _ in range(width - s.byte_length()):
        out += "0"
    out += s


def _check_year(f: DateTime) raises:
    if f.year < 0 or f.year > 9999:
        raise Error(
            "year " + String(f.year) + " cannot be written in four digits"
        )


def _fraction(nanos: Int, digits: Int, trim_group: Int) -> String:
    """`.ddd` for the leading `digits` digits of `nanos`, trimmed; "" when
    nothing is left."""
    if digits == 0:
        return String("")
    var scale = 1
    for _ in range(9 - digits):
        scale *= 10
    var value = nanos // scale  # the first `digits` digits
    var shown = digits
    if trim_group > 0:
        var significant = digits
        var v = value
        while significant > 0 and v % 10 == 0:
            v //= 10
            significant -= 1
        shown = ((significant + trim_group - 1) // trim_group) * trim_group
        if shown > digits:
            shown = digits
    if shown == 0:
        return String("")
    var drop = digits - shown
    for _ in range(drop):
        value //= 10
    var out = String(".")
    _pad(out, value, shown)
    return out^


def format_rfc3339(
    ts: Timestamp, fraction_digits: Int = 0, trim_group: Int = 0
) raises -> String:
    """`YYYY-MM-DDTHH:MM:SS[.f]Z`, UTC.

    `fraction_digits` (0..9) is how many fractional digits are shown; the rest
    are TRUNCATED. With `trim_group` 0 exactly that many are written (none when
    `fraction_digits` is 0). With `trim_group` g > 0 the fraction is cut to the
    shortest length that is a multiple of g and still exact (capped at
    `fraction_digits`), and omitted whole when it is zero. So (9, 3) writes
    `.5` as `.500` and a whole second as nothing (the protobuf JSON rule), and
    (3, 1) writes `.500` as `.5`.

    Raises for `nanos` outside [0, 10^9), `fraction_digits` outside 0..9,
    `trim_group` outside 0..9, and a year outside 0000..9999."""
    if ts.nanos < 0 or ts.nanos >= NANOS_PER_SECOND:
        raise Error("nanos " + String(ts.nanos) + " is outside [0, 999999999]")
    if fraction_digits < 0 or fraction_digits > 9:
        raise Error("fraction_digits must be in 0..9")
    if trim_group < 0 or trim_group > 9:
        raise Error("trim_group must be in 0..9")
    var f = fields_from_seconds(ts.seconds)
    _check_year(f)
    var out = String("")
    _pad(out, f.year, 4)
    out += "-"
    _pad(out, f.month, 2)
    out += "-"
    _pad(out, f.day, 2)
    out += "T"
    _pad(out, f.hour, 2)
    out += ":"
    _pad(out, f.minute, 2)
    out += ":"
    _pad(out, f.second, 2)
    out += _fraction(ts.nanos, fraction_digits, trim_group)
    out += "Z"
    return out^


def format_basic_datetime(seconds: Int) raises -> String:
    """`YYYYMMDDTHHMMSSZ`, the ISO 8601 basic form (UTC), year 0000..9999."""
    var f = fields_from_seconds(seconds)
    _check_year(f)
    var out = String("")
    _pad(out, f.year, 4)
    _pad(out, f.month, 2)
    _pad(out, f.day, 2)
    out += "T"
    _pad(out, f.hour, 2)
    _pad(out, f.minute, 2)
    _pad(out, f.second, 2)
    out += "Z"
    return out^


def format_basic_date(seconds: Int) raises -> String:
    """`YYYYMMDD`, the UTC date of an instant, year 0000..9999."""
    var f = fields_from_seconds(seconds)
    _check_year(f)
    var out = String("")
    _pad(out, f.year, 4)
    _pad(out, f.month, 2)
    _pad(out, f.day, 2)
    return out^


def format_iso_date(days: Int) raises -> String:
    """`YYYY-MM-DD` of a day count since 1970-01-01, year 0000..9999."""
    var d = civil_from_days(days)
    if d.year < 0 or d.year > 9999:
        raise Error(
            "year " + String(d.year) + " cannot be written in four digits"
        )
    var out = String("")
    _pad(out, d.year, 4)
    out += "-"
    _pad(out, d.month, 2)
    out += "-"
    _pad(out, d.day, 2)
    return out^


# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------


def _digits_at(b: Span[UInt8, _], at: Int, n: Int, what: String) raises -> Int:
    if at + n > len(b):
        raise Error("timestamp is truncated before the " + what)
    var v = 0
    for i in range(at, at + n):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error("timestamp has a non-digit in the " + what)
        v = v * 10 + Int(b[i] - UInt8(0x30))
    return v


def _expect(b: Span[UInt8, _], at: Int, c: UInt8, what: String) raises:
    if at >= len(b):
        raise Error("timestamp is truncated before the " + what)
    if b[at] != c:
        raise Error("timestamp has no " + what + " where one belongs")


def parse_rfc3339(
    text: String,
    allow_leap_second: Bool = False,
    truncate_fraction: Bool = False,
    allow_lowercase: Bool = True,
) raises -> Timestamp:
    """An ISO 8601 / RFC 3339 date-time with a zone, as UTC. The accepted
    grammar and each option are in this file's header."""
    var b = text.as_bytes()
    var n = len(b)
    var year = _digits_at(b, 0, 4, "year")
    _expect(b, 4, UInt8(0x2D), "'-'")
    var month = _digits_at(b, 5, 2, "month")
    _expect(b, 7, UInt8(0x2D), "'-'")
    var day = _digits_at(b, 8, 2, "day")
    if n <= 10:
        raise Error("timestamp is truncated before the time")
    if not (
        b[10] == UInt8(0x54) or (allow_lowercase and b[10] == UInt8(0x74))
    ):
        raise Error("timestamp has no 'T' between the date and the time")
    var hour = _digits_at(b, 11, 2, "hour")
    _expect(b, 13, UInt8(0x3A), "':'")
    var minute = _digits_at(b, 14, 2, "minute")
    _expect(b, 16, UInt8(0x3A), "':'")
    var second = _digits_at(b, 17, 2, "second")
    var i = 19
    var nanos = 0
    if i < n and b[i] == UInt8(0x2E):
        i += 1
        var start = i
        var kept = 0
        while i < n and b[i] >= UInt8(0x30) and b[i] <= UInt8(0x39):
            if kept < 9:
                nanos = nanos * 10 + Int(b[i] - UInt8(0x30))
                kept += 1
            i += 1
        var digits = i - start
        if digits == 0:
            raise Error("timestamp has an empty fraction")
        if digits > 9 and not truncate_fraction:
            raise Error("timestamp fraction has more than nine digits")
        for _ in range(9 - kept):
            nanos *= 10
    var offset = 0
    if i < n and (
        b[i] == UInt8(0x5A) or (allow_lowercase and b[i] == UInt8(0x7A))
    ):
        i += 1
    elif i < n and (b[i] == UInt8(0x2B) or b[i] == UInt8(0x2D)):
        var sign = 1 if b[i] == UInt8(0x2B) else -1
        var oh = _digits_at(b, i + 1, 2, "offset hour")
        _expect(b, i + 3, UInt8(0x3A), "':'")
        var om = _digits_at(b, i + 4, 2, "offset minute")
        if oh > 23 or om > 59:
            raise Error("timestamp offset is outside 00:00..23:59")
        offset = sign * (oh * 3600 + om * 60)
        i += 6
    else:
        raise Error("timestamp has no time zone")
    if i != n:
        raise Error("timestamp has text after the time zone")
    var secs = seconds_from_fields(
        year, month, day, hour, minute, second, allow_leap_second
    )
    return Timestamp(secs - offset, nanos)


def parse_iso_date(text: String) raises -> Int:
    """`YYYY-MM-DD` to a day count since 1970-01-01. Exactly ten bytes, a real
    date."""
    var b = text.as_bytes()
    if len(b) != 10:
        raise Error("a date is YYYY-MM-DD, ten bytes")
    var year = _digits_at(b, 0, 4, "year")
    _expect(b, 4, UInt8(0x2D), "'-'")
    var month = _digits_at(b, 5, 2, "month")
    _expect(b, 7, UInt8(0x2D), "'-'")
    var day = _digits_at(b, 8, 2, "day")
    if month < 1 or month > 12:
        raise Error("month " + String(month) + " is outside 1..12")
    if day < 1 or day > days_in_month(year, month):
        raise Error(
            "day "
            + String(day)
            + " does not exist in month "
            + String(month)
            + " of year "
            + String(year)
        )
    return days_from_civil(year, month, day)
