# The dates of a stored message, and the IMAP date forms.
#
# INTERNALDATE of a message is the time in its first `Received` field (the
# trace header the SMTP side adds on delivery, so the time the mail arrived);
# if that is missing or not a date, the time of its `Date` field; if neither
# is a date, the Unix epoch (zero milliseconds). It is written in UTC
# (`+0000`): the zone of the field is not kept. SEARCH compares dates by the
# UTC calendar day of INTERNALDATE; the sent date (`SENTBEFORE`, `SENTON`,
# `SENTSINCE`) is the calendar day written in the `Date` field, in its own
# zone, with no fallback: a message without a readable `Date` matches none of
# the three.

from komira_datetime import civil_from_days, days_from_civil, days_in_month
from komira_mail_message import parse_date_time

from .headers import HdrField, find_field

comptime _MONTHS: StaticString = "JanFebMarAprMayJunJulAugSepOctNovDec"
comptime MS_PER_DAY: Int = 86_400_000


def _date_of(value: List[UInt8]) -> Optional[Int]:
    try:
        return Optional[Int](parse_date_time(Span(value)))
    except:
        return None


def received_ms(fields: List[HdrField]) -> Optional[Int]:
    """The time after the last `;` of the first `Received` field."""
    var at = find_field(fields, String("received"))
    if at < 0:
        return None
    var v = fields[at].value.copy()
    var semi = -1
    for i in range(len(v)):
        if v[i] == 0x3B:
            semi = i
    if semi < 0:
        return None
    var tail = List[UInt8]()
    for i in range(semi + 1, len(v)):
        tail.append(v[i])
    return _date_of(tail)


def sent_ms(fields: List[HdrField]) -> Optional[Int]:
    """The time of the first `Date` field."""
    var at = find_field(fields, String("date"))
    if at < 0:
        return None
    return _date_of(fields[at].value)


def _zone_minutes(v: List[UInt8]) -> Int:
    """The zone of a `Date` value, in minutes east of UTC: its last word,
    `+hhmm`, `-hhmm` or one of the RFC 5322 names `parse_date_time` knows;
    zero for anything else (a trailing `(comment)` is skipped)."""
    var end = len(v)
    # Skip a trailing parenthesised comment and blanks.
    while end > 0:
        var c = v[end - 1]
        if c == 0x20 or c == 0x09 or c == 0x0D or c == 0x0A:
            end -= 1
        elif c == 0x29:
            var depth = 0
            while end > 0:
                var d = v[end - 1]
                end -= 1
                if d == 0x29:
                    depth += 1
                elif d == 0x28:
                    depth -= 1
                    if depth == 0:
                        break
        else:
            break
    var start = end
    while start > 0 and v[start - 1] != 0x20 and v[start - 1] != 0x09:
        start -= 1
    var n = end - start
    if n == 5 and (v[start] == 0x2B or v[start] == 0x2D):
        var val = 0
        for k in range(1, 5):
            if not _is_digit(v[start + k]):
                return 0
            val = val * 10 + Int(v[start + k] - 0x30)
        var mins = (val // 100) * 60 + val % 100
        return mins if v[start] == 0x2B else -mins
    if n == 3:
        var w = String(unsafe_from_utf8=Span(v)[start:end]).lower()
        if w == "est":
            return -300
        if w == "edt" or w == "cst":
            return -240 if w == "edt" else -360
        if w == "cdt" or w == "mst":
            return -300 if w == "cdt" else -420
        if w == "mdt" or w == "pst":
            return -360 if w == "mdt" else -480
        if w == "pdt":
            return -420
    return 0


def sent_local_ms(fields: List[HdrField]) -> Optional[Int]:
    """The `Date` field as the wall-clock time written in it (its own zone
    added back to the UTC time), so that `day_of_ms` of it is the date the
    sender wrote: RFC 3501 compares `SENT*` "disregarding time and
    timezone"."""
    var at = find_field(fields, String("date"))
    if at < 0:
        return None
    var utc = _date_of(fields[at].value)
    if not utc:
        return None
    return Optional[Int](utc.value() + _zone_minutes(fields[at].value) * 60_000)


def internal_date_ms(fields: List[HdrField]) -> Int:
    """The INTERNALDATE of a message, in milliseconds since the Unix epoch."""
    var r = received_ms(fields)
    if r:
        return r.value()
    var s = sent_ms(fields)
    if s:
        return s.value()
    return 0


def day_of_ms(ms: Int) -> Int:
    """The UTC calendar day (days since the Unix epoch) of a time."""
    return ms // MS_PER_DAY


def _pad2(n: Int) -> String:
    if n < 10:
        return String("0") + String(n)
    return String(n)


def format_internal_date(ms: Int) -> String:
    """`dd-Mon-yyyy hh:mm:ss +0000` with the day padded by a space to two
    characters (RFC 3501 `date-time`)."""
    var days = ms // MS_PER_DAY
    var secs = (ms - days * MS_PER_DAY) // 1000
    var d = civil_from_days(days)
    var out = String("")
    if d.day < 10:
        out += String(" ")
    out += String(d.day) + "-"
    var m = _MONTHS.as_bytes()
    out += String(unsafe_from_utf8=m[(d.month - 1) * 3 : (d.month - 1) * 3 + 3])
    out += "-" + String(d.year) + " "
    out += _pad2(secs // 3600) + ":" + _pad2((secs // 60) % 60) + ":"
    out += _pad2(secs % 60) + " +0000"
    return out^


def _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


def parse_search_date(text: String) -> Optional[Int]:
    """A search date, `d-Mon-yyyy` or `dd-Mon-yyyy` (RFC 3501 `date-text`;
    the month in any letter case, the year four digits from 1900), as a day
    count since the Unix epoch. None for anything else, a day the month does not
    have included."""
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    var day = 0
    var digits = 0
    while i < n and _is_digit(b[i]):
        day = day * 10 + Int(b[i] - 0x30)
        digits += 1
        i += 1
        if digits > 2:
            return None
    if digits == 0 or i >= n or b[i] != 0x2D:
        return None
    i += 1
    if i + 3 > n:
        return None
    var month = 0
    var names = _MONTHS.as_bytes()
    for m in range(12):
        var same = True
        for k in range(3):
            var c = b[i + k]
            if c >= 0x41 and c <= 0x5A:
                c += 32
            var want = names[m * 3 + k]
            if want >= 0x41 and want <= 0x5A:
                want += 32
            if c != want:
                same = False
                break
        if same:
            month = m + 1
            break
    if month == 0:
        return None
    i += 3
    if i >= n or b[i] != 0x2D:
        return None
    i += 1
    if n - i != 4:
        return None
    var year = 0
    for k in range(4):
        if not _is_digit(b[i + k]):
            return None
        year = year * 10 + Int(b[i + k] - 0x30)
    if year < 1900:
        return None
    if day < 1 or day > days_in_month(year, month):
        return None
    return Optional[Int](days_from_civil(year, month, day))
