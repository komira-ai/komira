# =============================================================================
# posix_tz.mojo -- the POSIX TZ string of a TZif footer (RFC 8536 section 3.3)
# =============================================================================
#
#   std offset [dst [offset] [,start[/time],end[/time]]]
#
# A name is three or more letters, or `<...>` around three or more of
# letters, digits, `+` and `-`. An offset is `[+-]hh[:mm[:ss]]`, hours 0..24,
# and counts hours WEST of UTC (`EST5` is UTC-5); a missing DST offset is one
# hour east of the standard one. A rule date is `Jn` (1..365, 29 February
# never counted), `n` (0..365, counted) or `Mm.w.d` (month 1..12, week 1..5
# where 5 is the last, weekday 0..6 from Sunday); its time is
# `[+-]hh[:mm[:ss]]` with hours 0..167 (the RFC 8536 extension of POSIX's
# 0..24), 02:00:00 when absent, and is local time: the start in standard
# time, the end in daylight time. A DST name needs both rules: zic always
# writes them, and POSIX leaves the default to the implementation.
#
# DST is evaluated per year of local standard time: the year's start and end
# instants in UTC, then in effect from start up to end, or outside end..start
# when the end comes first in the year (the southern hemisphere). A rule
# starting 1 January 00:00 and ending 31 December 24:00 plus the DST
# difference is DST all year (RFC 8536 section 3.3.1): its end equals the next
# year's start.
#
# Known limitation, see komira-ai/komira#883: a rule time that carries the
# start past 31 December ("AAA0BBB,J365/120,J30" starts DST on 5 January of
# the next year) is folded into that next year's own end-before-start test,
# so 1..4 January read as DST where tzcode starts DST on 5 January.
# =============================================================================

from .civil import (
    civil_from_days,
    days_from_civil,
    days_in_month,
    is_leap_year,
    weekday_from_days,
)

from .zone_offset import ZoneOffset

comptime RULE_JULIAN = 0  # Jn: 1..365, 29 February never counted
comptime RULE_DAY_OF_YEAR = 1  # n: 0..365, 29 February counted
comptime RULE_MONTH_WEEK_DAY = 2  # Mm.w.d

comptime _SECONDS_PER_DAY = 86400
comptime _DEFAULT_RULE_TIME = 7200


@fieldwise_init
struct PosixRule(Copyable, ImplicitlyCopyable, Movable):
    """One rule date and time. `day` holds n of `Jn` and `n`; `month`,
    `week` and `weekday` hold `Mm.w.d`. `time` is seconds after local
    midnight of that date, possibly negative or past one day."""

    var kind: Int
    var day: Int
    var month: Int
    var week: Int
    var weekday: Int
    var time: Int

    def date_in_year(self, year: Int) -> Int:
        """Days since 1970-01-01 of the rule's date in `year`."""
        if self.kind == RULE_JULIAN:
            var d = days_from_civil(year, 1, 1) + self.day - 1
            if is_leap_year(year) and self.day >= 60:
                d += 1
            return d
        if self.kind == RULE_DAY_OF_YEAR:
            return days_from_civil(year, 1, 1) + self.day
        var first = days_from_civil(year, self.month, 1)
        var d = (
            first
            + (self.weekday - weekday_from_days(first) + 7) % 7
            + (self.week - 1) * 7
        )
        var end = first + days_in_month(year, self.month)
        while d >= end:
            d -= 7
        return d


struct PosixTz(Copyable, Movable):
    """A parsed POSIX TZ string. Without DST, `standard` holds all year and
    `daylight`, `start` and `end` are unused."""

    var text: String
    var standard: ZoneOffset
    var has_dst: Bool
    var daylight: ZoneOffset
    var start: PosixRule
    var end: PosixRule

    def __init__(
        out self,
        var text: String,
        var standard: ZoneOffset,
        has_dst: Bool,
        var daylight: ZoneOffset,
        start: PosixRule,
        end: PosixRule,
    ):
        self.text = text^
        self.standard = standard^
        self.has_dst = has_dst
        self.daylight = daylight^
        self.start = start
        self.end = end

    def _year_of(self, utc: Int) -> Int:
        return civil_from_days(
            (utc + self.standard.utc_offset) // _SECONDS_PER_DAY
        ).year

    def start_utc(self, year: Int) -> Int:
        """The UTC instant DST starts in `year` (the rule time is standard
        time)."""
        return (
            self.start.date_in_year(year) * _SECONDS_PER_DAY
            + self.start.time
            - self.standard.utc_offset
        )

    def end_utc(self, year: Int) -> Int:
        """The UTC instant DST ends in `year` (the rule time is daylight
        time)."""
        return (
            self.end.date_in_year(year) * _SECONDS_PER_DAY
            + self.end.time
            - self.daylight.utc_offset
        )

    def offset_at(self, utc: Int) -> ZoneOffset:
        """The local time type the string gives for the UTC instant `utc`."""
        if not self.has_dst:
            return self.standard.copy()
        var year = self._year_of(utc)
        var s = self.start_utc(year)
        var e = self.end_utc(year)
        var in_dst: Bool
        if s < e:
            in_dst = s <= utc and utc < e
        else:
            in_dst = not (e <= utc and utc < s)
        if in_dst:
            return self.daylight.copy()
        return self.standard.copy()

    def next_edge_after(self, utc: Int) -> Int:
        """The first rule instant (a start or an end) strictly after `utc`.
        Only for a string with DST; an edge may change nothing (DST all
        year), which the caller checks."""
        var year = self._year_of(utc)
        var best = 0
        var found = False
        for y in range(year - 1, year + 3):
            var s = self.start_utc(y)
            var e = self.end_utc(y)
            if s > utc and (not found or s < best):
                best = s
                found = True
            if e > utc and (not found or e < best):
                best = e
                found = True
        return best


# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------


struct _Reader:
    var text: String
    var at: Int

    def __init__(out self, text: String):
        self.text = text.copy()
        self.at = 0

    def fail(self, what: String) -> Error:
        return Error('POSIX TZ string "' + self.text + '": ' + what)

    def done(self) -> Bool:
        return self.at >= self.text.byte_length()

    def peek(self) -> Int:
        """The byte at the cursor, or 0 at the end."""
        if self.done():
            return 0
        return Int(self.text.as_bytes()[self.at])


def _is_digit(b: Int) -> Bool:
    return b >= ord("0") and b <= ord("9")


def _is_alpha(b: Int) -> Bool:
    return (b >= ord("A") and b <= ord("Z")) or (b >= ord("a") and b <= ord("z"))


def _read_name(mut r: _Reader, what: String) raises -> String:
    var name = String()
    if r.peek() == ord("<"):
        r.at += 1
        while not r.done() and r.peek() != ord(">"):
            var b = r.peek()
            if not (_is_alpha(b) or _is_digit(b) or b == ord("+") or b == ord("-")):
                raise r.fail(
                    what + " name: byte " + String(r.at) + " is not a letter, digit, + or -"
                )
            name += chr(b)
            r.at += 1
        if r.done():
            raise r.fail(what + " name: no closing >")
        r.at += 1
    else:
        while _is_alpha(r.peek()):
            name += chr(r.peek())
            r.at += 1
    if name.byte_length() < 3:
        raise r.fail(what + " name: fewer than 3 characters")
    return name^


def _read_number(mut r: _Reader, what: String) raises -> Int:
    if not _is_digit(r.peek()):
        raise r.fail(what + ": expected a digit at byte " + String(r.at))
    var v = 0
    var digits = 0
    while _is_digit(r.peek()):
        v = v * 10 + r.peek() - ord("0")
        digits += 1
        r.at += 1
        if digits > 3:
            raise r.fail(what + ": more than 3 digits")
    return v


def _read_hms(mut r: _Reader, max_hours: Int, what: String) raises -> Int:
    """`[+-]hh[:mm[:ss]]` as signed seconds."""
    var sign = 1
    if r.peek() == ord("+"):
        r.at += 1
    elif r.peek() == ord("-"):
        sign = -1
        r.at += 1
    var h = _read_number(r, what)
    if h > max_hours:
        raise r.fail(
            what + ": hours " + String(h) + " are outside 0.." + String(max_hours)
        )
    var m = 0
    var s = 0
    if r.peek() == ord(":"):
        r.at += 1
        m = _read_number(r, what)
        if m > 59:
            raise r.fail(what + ": minutes " + String(m) + " are outside 0..59")
        if r.peek() == ord(":"):
            r.at += 1
            s = _read_number(r, what)
            if s > 59:
                raise r.fail(what + ": seconds " + String(s) + " are outside 0..59")
    return sign * (h * 3600 + m * 60 + s)


def _read_rule(mut r: _Reader, what: String) raises -> PosixRule:
    var rule = PosixRule(RULE_DAY_OF_YEAR, 0, 0, 0, 0, _DEFAULT_RULE_TIME)
    if r.peek() == ord("J"):
        r.at += 1
        rule.kind = RULE_JULIAN
        rule.day = _read_number(r, what)
        if rule.day < 1 or rule.day > 365:
            raise r.fail(what + ": Julian day " + String(rule.day) + " is outside 1..365")
    elif r.peek() == ord("M"):
        r.at += 1
        rule.kind = RULE_MONTH_WEEK_DAY
        rule.month = _read_number(r, what)
        if rule.month < 1 or rule.month > 12:
            raise r.fail(what + ": month " + String(rule.month) + " is outside 1..12")
        if r.peek() != ord("."):
            raise r.fail(what + ": expected . after the month")
        r.at += 1
        rule.week = _read_number(r, what)
        if rule.week < 1 or rule.week > 5:
            raise r.fail(what + ": week " + String(rule.week) + " is outside 1..5")
        if r.peek() != ord("."):
            raise r.fail(what + ": expected . after the week")
        r.at += 1
        rule.weekday = _read_number(r, what)
        if rule.weekday > 6:
            raise r.fail(what + ": weekday " + String(rule.weekday) + " is outside 0..6")
    else:
        rule.day = _read_number(r, what)
        if rule.day > 365:
            raise r.fail(what + ": day " + String(rule.day) + " is outside 0..365")
    if r.peek() == ord("/"):
        r.at += 1
        rule.time = _read_hms(r, 167, what + " time")
    return rule


def parse_posix_tz(text: String) raises -> PosixTz:
    """Parses a POSIX TZ string in the RFC 8536 form (the module header).
    Raises naming the string and what is wrong with it."""
    var r = _Reader(text)
    var std_name = _read_name(r, "standard time")
    var standard = ZoneOffset(
        -_read_hms(r, 24, "standard offset"), False, std_name
    )
    if r.done():
        var unused = PosixRule(RULE_JULIAN, 1, 0, 0, 0, 0)
        return PosixTz(text.copy(), standard.copy(), False, standard.copy(), unused, unused)
    var dst_name = _read_name(r, "DST")
    var dst_offset = standard.utc_offset + 3600
    var b = r.peek()
    if _is_digit(b) or b == ord("+") or b == ord("-"):
        dst_offset = -_read_hms(r, 24, "DST offset")
    if r.peek() != ord(","):
        raise r.fail("a DST name needs a rule: ,start[/time],end[/time]")
    r.at += 1
    var start = _read_rule(r, "DST start")
    if r.peek() != ord(","):
        raise r.fail("expected , before the DST end rule")
    r.at += 1
    var end = _read_rule(r, "DST end")
    if not r.done():
        raise r.fail("unexpected byte at " + String(r.at))
    return PosixTz(
        text.copy(), standard^, True, ZoneOffset(dst_offset, True, dst_name), start, end
    )
