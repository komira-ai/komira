# =============================================================================
# komira_datetime/http_date.mojo -- HTTP-date, the IMF-fixdate form
# =============================================================================
#
#     Sun, 06 Nov 1994 08:49:37 GMT
#
# RFC 9110 section 5.6.7 (the grammar RFC 7231 section 7.1.1.1 introduced): a
# three-letter day name, a comma and a space, a two-digit day, a space, a
# three-letter month name, a space, a four-digit year, a space, HH:MM:SS, a
# space, and the literal `GMT`. It is exactly 29 bytes and always UTC. Names
# are case-sensitive, as the grammar's literals are.
#
# WRITING is exact for years 0000..9999.
#
# READING takes only this form. The two obsolete forms RFC 9110 asks a
# recipient to accept (the RFC 850 `Sunday, 06-Nov-94 08:49:37 GMT` and the
# asctime `Sun Nov  6 08:49:37 1994`) are REFUSED, and say so: a two-digit year
# needs a century rule that is the caller's policy, not a calendar fact.
# The day name must be one of the seven; whether it AGREES with the date is
# checked only with `check_weekday` (RFC 9110 calls the name redundant, and
# real peers do mis-state it). A second of 60 is refused: an HTTP-date names an
# instant and POSIX time has no 23:59:60.
# =============================================================================

from .civil import days_from_civil, days_in_month, weekday_from_days
from .timestamp import (
    SECONDS_PER_DAY,
    _check_year,
    _pad,
    fields_from_seconds,
)

comptime DAY_NAMES = "SunMonTueWedThuFriSat"
comptime MONTH_NAMES = "JanFebMarAprMayJunJulAugSepOctNovDec"


def _append_name(mut out: String, names: String, index: Int):
    var b = names.as_bytes()
    for k in range(index * 3, index * 3 + 3):
        out += chr(Int(b[k]))


def format_http_date(seconds: Int) raises -> String:
    """The IMF-fixdate of an instant (whole seconds), year 0000..9999."""
    var f = fields_from_seconds(seconds)
    _check_year(f)
    var days = seconds // SECONDS_PER_DAY
    var out = String("")
    _append_name(out, String(DAY_NAMES), weekday_from_days(days))
    out += ", "
    _pad(out, f.day, 2)
    out += " "
    _append_name(out, String(MONTH_NAMES), f.month - 1)
    out += " "
    _pad(out, f.year, 4)
    out += " "
    _pad(out, f.hour, 2)
    out += ":"
    _pad(out, f.minute, 2)
    out += ":"
    _pad(out, f.second, 2)
    out += " GMT"
    return out^


def _name_index(names: String, b: Span[UInt8, _], at: Int) -> Int:
    """The index of the three bytes at `at` among the concatenated `names`,
    -1 when they are none of them."""
    var nb = names.as_bytes()
    for k in range(len(nb) // 3):
        if (
            nb[k * 3] == b[at]
            and nb[k * 3 + 1] == b[at + 1]
            and nb[k * 3 + 2] == b[at + 2]
        ):
            return k
    return -1


def _two(b: Span[UInt8, _], at: Int, what: String) raises -> Int:
    var hi = b[at]
    var lo = b[at + 1]
    if hi < UInt8(0x30) or hi > UInt8(0x39) or lo < UInt8(0x30) or lo > UInt8(0x39):
        raise Error("http-date has a non-digit in the " + what)
    return Int(hi - UInt8(0x30)) * 10 + Int(lo - UInt8(0x30))


def _sep(b: Span[UInt8, _], at: Int, c: UInt8) raises:
    if b[at] != c:
        raise Error("http-date is not in IMF-fixdate form")


def parse_http_date(text: String, check_weekday: Bool = False) raises -> Int:
    """Epoch seconds of an IMF-fixdate; the other two HTTP-date forms are
    refused (see this file's header)."""
    var b = text.as_bytes()
    if len(b) != 29:
        raise Error(
            "http-date is not in IMF-fixdate form (29 bytes, e.g."
            " 'Sun, 06 Nov 1994 08:49:37 GMT'); the obsolete rfc850 and"
            " asctime forms are not read"
        )
    var wd = _name_index(String(DAY_NAMES), b, 0)
    if wd < 0:
        raise Error("http-date has an unknown day name")
    _sep(b, 3, UInt8(0x2C))
    _sep(b, 4, UInt8(0x20))
    var day = _two(b, 5, "day")
    _sep(b, 7, UInt8(0x20))
    var mo = _name_index(String(MONTH_NAMES), b, 8) + 1
    if mo == 0:
        raise Error("http-date has an unknown month name")
    _sep(b, 11, UInt8(0x20))
    var year = _two(b, 12, "year") * 100 + _two(b, 14, "year")
    _sep(b, 16, UInt8(0x20))
    var hour = _two(b, 17, "hour")
    _sep(b, 19, UInt8(0x3A))
    var minute = _two(b, 20, "minute")
    _sep(b, 22, UInt8(0x3A))
    var second = _two(b, 23, "second")
    _sep(b, 25, UInt8(0x20))
    if b[26] != UInt8(0x47) or b[27] != UInt8(0x4D) or b[28] != UInt8(0x54):
        raise Error("http-date is not in GMT")
    if mo < 1 or mo > 12 or day < 1 or day > days_in_month(year, mo):
        raise Error("http-date names a day that does not exist")
    if hour > 23 or minute > 59 or second > 59:
        raise Error("http-date has a time field out of range")
    var days = days_from_civil(year, mo, day)
    if check_weekday and weekday_from_days(days) != wd:
        raise Error("http-date day name does not match its date")
    return days * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second
