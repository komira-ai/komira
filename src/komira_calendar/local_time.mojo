"""The calendar's text forms: a local date, a local date-time and the shape of
a time zone name.

A local date is `YYYY-MM-DD`, a local date-time `YYYY-MM-DDTHH:MM:SS`: a wall
clock reading with no offset, read in a time zone named beside it. Both must
name a date that exists. Parsing gives the day count since 1970-01-01 and, for
a date-time, the second of that day; the zone is not consulted (zone rules are
not in this package).
"""

from komira_datetime import parse_iso_date


comptime MAX_TIME_ZONE_BYTES = 64


@fieldwise_init
struct LocalDateTime(Copyable, Movable, ImplicitlyCopyable, Equatable):
    """A wall-clock reading: `days` since 1970-01-01 and `second_of_day` in
    0..86399. Ordered by (days, second_of_day)."""

    var days: Int
    var second_of_day: Int

    def __eq__(self, other: Self) -> Bool:
        return self.days == other.days and self.second_of_day == other.second_of_day

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def __lt__(self, other: Self) -> Bool:
        if self.days != other.days:
            return self.days < other.days
        return self.second_of_day < other.second_of_day

    def seconds(self) -> Int:
        """Seconds since 1970-01-01T00:00:00 on the same wall clock."""
        return self.days * 86400 + self.second_of_day


def parse_local_date(text: String) raises -> Int:
    """`YYYY-MM-DD` to a day count since 1970-01-01. Exactly ten bytes and a
    date that exists; anything else raises."""
    return parse_iso_date(text)


def _two_digits(b: Span[UInt8, _], at: Int, what: String) raises -> Int:
    var hi = Int(b[at]) - 0x30
    var lo = Int(b[at + 1]) - 0x30
    if hi < 0 or hi > 9 or lo < 0 or lo > 9:
        raise Error("the " + what + " is not two digits")
    return hi * 10 + lo


def parse_local_datetime(text: String) raises -> LocalDateTime:
    """`YYYY-MM-DDTHH:MM:SS` to a `LocalDateTime`. Exactly nineteen bytes, an
    upper-case `T`, hours 00..23, minutes and seconds 00..59, a date that
    exists; anything else (an offset, a `Z`, a fraction) raises."""
    var b = text.as_bytes()
    if len(b) != 19:
        raise Error("a local date-time is YYYY-MM-DDTHH:MM:SS, nineteen bytes")
    for i in range(19):
        if b[i] >= 0x80:
            raise Error("a local date-time is ASCII")
    if b[10] != UInt8(0x54):
        raise Error("a local date-time has 'T' between the date and the time")
    if b[13] != UInt8(0x3A) or b[16] != UInt8(0x3A):
        raise Error("a local time is HH:MM:SS")
    var days = parse_iso_date(String(text[byte=0:10]))
    var hour = _two_digits(b, 11, "hour")
    var minute = _two_digits(b, 14, "minute")
    var second = _two_digits(b, 17, "second")
    if hour > 23 or minute > 59 or second > 59:
        raise Error("the time of day is outside 00:00:00..23:59:59")
    return LocalDateTime(days, hour * 3600 + minute * 60 + second)


def is_time_zone_name(text: String) -> Bool:
    """True when `text` has the shape of an IANA time zone name: 1 to 64
    bytes of ASCII letters, digits, `_`, `-`, `+` and `/`, starting with a
    letter, with no empty `/`-separated part. Whether the zone exists is not
    checked here."""
    var b = text.as_bytes()
    var n = len(b)
    if n == 0 or n > MAX_TIME_ZONE_BYTES:
        return False
    var first = b[0]
    if not ((first >= 0x41 and first <= 0x5A) or (first >= 0x61 and first <= 0x7A)):
        return False
    var prev_slash = False
    for i in range(n):
        var c = b[i]
        var letter = (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)
        var digit = c >= 0x30 and c <= 0x39
        if c == 0x2F:
            if prev_slash:
                return False
            prev_slash = True
            continue
        prev_slash = False
        if not (letter or digit or c == 0x5F or c == 0x2D or c == 0x2B):
            return False
    return not prev_slash
