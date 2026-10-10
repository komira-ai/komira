# =============================================================================
# values.mojo -- the iCalendar value forms this package reads and writes
# (RFC 5545 §3.3): DATE, DATE-TIME and DURATION, and the UTC offset of a
# VTIMEZONE observance.
# =============================================================================
#
# DATE is `YYYYMMDD`. DATE-TIME is `YYYYMMDDTHHMMSS`, a local time, or the
# same with a trailing `Z`, UTC (§3.3.5). Which one a value is follows from
# its VALUE parameter when it has one, else from its length. A date or time
# that does not exist is refused, and so is second 60 (leap seconds are not
# modelled). A local time carries the TZID parameter beside it (or none: a
# floating time); a UTC time must not carry one.
#
# DURATION (§3.3.6) is read by its grammar:
#     dur-value  = ["+" / "-"] "P" (dur-date / dur-time / dur-week)
#     dur-date   = dur-day [dur-time]        dur-day    = 1*DIGIT "D"
#     dur-time   = "T" (dur-hour / dur-minute / dur-second)
#     dur-hour   = 1*DIGIT "H" [dur-minute]  dur-minute = 1*DIGIT "M" [dur-second]
#     dur-second = 1*DIGIT "S"               dur-week   = 1*DIGIT "W"
# Its days and weeks are nominal (a day on the wall clock) and its hours,
# minutes and seconds exact, so the two are kept apart.
# =============================================================================

from komira_datetime import civil_from_days, days_from_date

comptime SECONDS_PER_DAY = 86400
# A number in a DURATION has at most this many digits, so no sum overflows.
comptime _MAX_DURATION_DIGITS = 9


struct IcsTime(Copyable, Movable):
    """A DATE or DATE-TIME value. `local` is seconds on the wall clock since
    1970-01-01T00:00:00 (a DATE is its midnight); for a UTC value it is the
    UTC instant. `tzid` is the TZID parameter written beside a local
    DATE-TIME, empty for a floating one."""

    var is_date: Bool
    var is_utc: Bool
    var tzid: String
    var local: Int

    def __init__(out self, is_date: Bool, is_utc: Bool, var tzid: String, local: Int):
        self.is_date = is_date
        self.is_utc = is_utc
        self.tzid = tzid^
        self.local = local

    def day(self) -> Int:
        """The day of `local`, as days since 1970-01-01."""
        return self.local // SECONDS_PER_DAY

    def second_of_day(self) -> Int:
        """The second of the day of `local`, 0..86399."""
        return self.local - self.day() * SECONDS_PER_DAY

    def is_floating(self) -> Bool:
        """A DATE-TIME with neither `Z` nor a TZID."""
        return not self.is_date and not self.is_utc and self.tzid.byte_length() == 0


@fieldwise_init
struct IcsDuration(Copyable, Movable, ImplicitlyCopyable):
    """A DURATION value: `days` (weeks counted as seven days) are nominal,
    `seconds` exact; `negative` is the sign written before the `P`."""

    var negative: Bool
    var days: Int
    var seconds: Int


def _digits(b: Span[UInt8, _], at: Int, n: Int) -> Int:
    """The number in `n` ASCII digits at `at`, or -1 when one is not a digit."""
    var v = 0
    for i in range(at, at + n):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            return -1
        v = v * 10 + (c - 0x30)
    return v


def _date_days(b: Span[UInt8, _], text: String) raises -> Int:
    var y = _digits(b, 0, 4)
    var m = _digits(b, 4, 2)
    var d = _digits(b, 6, 2)
    if y < 0 or m < 0 or d < 0:
        raise Error('"' + text + '" is not a DATE (YYYYMMDD)')
    try:
        return days_from_date(y, m, d)
    except e:
        raise Error('"' + text + '" names no day: ' + String(e))


def parse_ics_time(text: String, value_type: String, tzid: String) raises -> IcsTime:
    """A DATE or DATE-TIME value (module header). `value_type` is the VALUE
    parameter (`DATE`, `DATE-TIME`, or empty); `tzid` the TZID parameter
    (or empty)."""
    var b = text.as_bytes()
    var n = len(b)
    var is_date: Bool
    if value_type == "DATE":
        is_date = True
    elif value_type == "DATE-TIME":
        is_date = False
    elif value_type.byte_length() == 0:
        is_date = n == 8
    else:
        raise Error("VALUE=" + value_type + " is not DATE or DATE-TIME")
    if is_date:
        if n != 8:
            raise Error('"' + text + '" is not a DATE (YYYYMMDD)')
        return IcsTime(True, False, String(), _date_days(b, text) * SECONDS_PER_DAY)
    if n != 15 and n != 16:
        raise Error('"' + text + '" is not a DATE-TIME (YYYYMMDDTHHMMSS, optionally ending in Z)')
    if b[8] != UInt8(ord("T")) or (n == 16 and b[15] != UInt8(ord("Z"))):
        raise Error('"' + text + '" is not a DATE-TIME (YYYYMMDDTHHMMSS, optionally ending in Z)')
    var days = _date_days(b, text)
    var hh = _digits(b, 9, 2)
    var mm = _digits(b, 11, 2)
    var ss = _digits(b, 13, 2)
    if hh < 0 or mm < 0 or ss < 0 or hh > 23 or mm > 59 or ss > 59:
        raise Error('"' + text + '" has no time of day 00:00:00..23:59:59')
    var is_utc = n == 16
    if is_utc and tzid.byte_length() > 0:
        raise Error('"' + text + '" is UTC and also names TZID ' + tzid)
    return IcsTime(False, is_utc, tzid.copy(), days * SECONDS_PER_DAY + hh * 3600 + mm * 60 + ss)


def _pad(v: Int, width: Int) -> String:
    var s = String(v)
    while s.byte_length() < width:
        s = "0" + s
    return s^


def format_ics_date(day: Int) raises -> String:
    """`YYYYMMDD` of a day count since 1970-01-01 (years 0..9999)."""
    var c = civil_from_days(day)
    if c.year < 0 or c.year > 9999:
        raise Error("year " + String(c.year) + " cannot be written in four digits")
    return _pad(c.year, 4) + _pad(c.month, 2) + _pad(c.day, 2)


def format_ics_datetime(seconds: Int, utc: Bool) raises -> String:
    """`YYYYMMDDTHHMMSS` of wall-clock seconds, with `Z` when `utc`."""
    var day = seconds // SECONDS_PER_DAY
    var sod = seconds - day * SECONDS_PER_DAY
    var out = format_ics_date(day) + "T" + _pad(sod // 3600, 2) + _pad((sod % 3600) // 60, 2) + _pad(sod % 60, 2)
    if utc:
        out += "Z"
    return out^


def parse_ics_duration(text: String) raises -> IcsDuration:
    """A DURATION value by the grammar in the module header."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var negative = False
    if i < n and (b[i] == UInt8(ord("+")) or b[i] == UInt8(ord("-"))):
        negative = b[i] == UInt8(ord("-"))
        i += 1
    if i >= n or b[i] != UInt8(ord("P")):
        raise Error('"' + text + '" is not a DURATION (it starts with P, after an optional sign)')
    i += 1
    var days = 0
    var seconds = 0
    var in_time = False
    # The designators allowed next, in grammar order: W or D first; after
    # T, H then M then S, each only after the one before it.
    var last = 0  # 0 nothing, 1 D, 2 W, 3 T, 4 H, 5 M, 6 S
    while i < n:
        var c = b[i]
        if c == UInt8(ord("T")):
            if in_time or last == 2:
                raise Error('"' + text + '" is not a DURATION (a misplaced T)')
            in_time = True
            last = 3
            i += 1
            continue
        var start = i
        while i < n and b[i] >= 0x30 and b[i] <= 0x39:
            i += 1
        var len_d = i - start
        if len_d == 0 or len_d > _MAX_DURATION_DIGITS or i >= n:
            raise Error('"' + text + '" is not a DURATION (a number and a designator: W, D, H, M or S)')
        var v = _digits(b, start, len_d)
        var d = b[i]
        i += 1
        if not in_time and d == UInt8(ord("W")) and last == 0:
            days = v * 7
            last = 2
        elif not in_time and d == UInt8(ord("D")) and last == 0:
            days = v
            last = 1
        elif in_time and d == UInt8(ord("H")) and last == 3:
            seconds += v * 3600
            last = 4
        elif in_time and d == UInt8(ord("M")) and (last == 3 or last == 4):
            seconds += v * 60
            last = 5
        elif in_time and d == UInt8(ord("S")) and (last == 3 or last == 5):
            seconds += v
            last = 6
        else:
            raise Error('"' + text + '" is not a DURATION (designators out of order)')
        if last == 2 and i < n:
            raise Error('"' + text + '" is not a DURATION (weeks stand alone)')
    if last == 0 or last == 3:
        raise Error('"' + text + '" is not a DURATION (no amount)')
    return IcsDuration(negative, days, seconds)


def format_ics_seconds(seconds: Int) -> String:
    """A non-negative exact duration as `PT[nH][nM][nS]` (`PT0S` for zero),
    writing M between H and S when both are present, as the grammar needs."""
    if seconds == 0:
        return "PT0S"
    var h = seconds // 3600
    var m = (seconds % 3600) // 60
    var s = seconds % 60
    var out = String("PT")
    if h > 0:
        out += String(h) + "H"
    if m > 0 or (h > 0 and s > 0):
        out += String(m) + "M"
    if s > 0:
        out += String(s) + "S"
    return out^


def format_utc_offset(seconds_east: Int) -> String:
    """A UTC offset as `+HHMM` or `+HHMMSS` (RFC 5545 §3.3.14); zero is
    `+0000`, since `-0000` is not allowed."""
    var sign = "+"
    var v = seconds_east
    if v < 0:
        sign = "-"
        v = -v
    var out = sign + _pad(v // 3600, 2) + _pad((v % 3600) // 60, 2)
    if v % 60 != 0:
        out += _pad(v % 60, 2)
    return out^
