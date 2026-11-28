# =============================================================================
# csv/csv_temporal_format.mojo -- DATEFORMAT and TIMESTAMPFORMAT of a COPY
# =============================================================================
#
# `TemporalFormat(option, text)` parses a strftime format as DuckDB's COPY
# reads it, and `date_text(days)` and `timestamp_text(micros, zoned)` write a
# DATE or a microsecond TIMESTAMP with it, as DuckDB's CSV writer does in a
# session whose time zone is UTC. A format is literal text and specifiers:
#
#   %Y  the year: four digits at least from 0 to 9999 (`0005`), all of them
#       past it (`12345`), and `-` then the digits before year 0 (year 0 is
#       1 BC, so 44 BC is `-43`)
#   %y  the year's last two digits, of its magnitude (`05`, `-43` gives `43`)
#   %m %d %H %M %S  month, day, hour (0..23), minute, second, two digits
#   %I  the hour on a 12-hour clock (`12` for 0 and 12), two digits
#   %j  the day of the year, three digits
#   -   between `%` and one of y m d H I M S j: the number without padding
#   %p  `AM` before noon, `PM` from it
#   %f  the microseconds of the second, six digits; %g the milliseconds, three
#   %a %A  `Mon`, `Monday`; %b %h  `Mar`; %B  `March`
#   %w  the weekday from 0 (Sunday); %u  from 1 (Monday) to 7 (Sunday)
#   %U %W  the week of the year, two digits, counting from the year's first
#       Sunday (%U) or Monday (%W); the days before it are week 0
#   %V  the ISO 8601 week, two digits; %G  its year, written as DuckDB
#       writes it: the last four digits of the year read as an unsigned 32-bit
#       number (`2004`; 2 BC, ISO year -1, gives `7295`)
#   %z  `+00`; %Z  `UTC` for a zoned timestamp and nothing otherwise
#   %c  `%Y-%m-%d %H:%M:%S`; %x  `%Y-%m-%d`; %X and %T  `%H:%M:%S`
#   %%  `%`
#
# A date is the timestamp of its midnight. The largest INT64 and its negation,
# DuckDB's infinite timestamps, are written `infinity` and `-infinity`
# whatever the format.
#
# Refused by name when parsed: `CSV_DIALECT_INVALID` with DuckDB's own reason
# for an empty format (`Empty format string`), a `%` at the end (`Trailing
# format character %`) and a specifier DuckDB does not know (`Unrecognized
# format for strftime/strptime: %Q`); `CSV_DIALECT_UNSUPPORTED` for `%n`,
# which DuckDB's COPY writes padded with spaces when another specifier is
# beside it.

from .csv_write_dialect import CSV_DIALECT_INVALID, CSV_DIALECT_UNSUPPORTED

comptime _LIT: UInt8 = 0
comptime _YEAR: UInt8 = 1
comptime _YEAR2: UInt8 = 2
comptime _YEAR2_NP: UInt8 = 3
comptime _MONTH: UInt8 = 4
comptime _MONTH_NP: UInt8 = 5
comptime _DAY: UInt8 = 6
comptime _DAY_NP: UInt8 = 7
comptime _HOUR: UInt8 = 8
comptime _HOUR_NP: UInt8 = 9
comptime _HOUR12: UInt8 = 10
comptime _HOUR12_NP: UInt8 = 11
comptime _MINUTE: UInt8 = 12
comptime _MINUTE_NP: UInt8 = 13
comptime _SECOND: UInt8 = 14
comptime _SECOND_NP: UInt8 = 15
comptime _YDAY: UInt8 = 16
comptime _YDAY_NP: UInt8 = 17
comptime _AMPM: UInt8 = 18
comptime _MICROS: UInt8 = 19
comptime _MILLIS: UInt8 = 20
comptime _WDAY_ABBR: UInt8 = 21
comptime _WDAY_FULL: UInt8 = 22
comptime _MONTH_ABBR: UInt8 = 23
comptime _MONTH_FULL: UInt8 = 24
comptime _WDAY_SUN0: UInt8 = 25
comptime _WDAY_ISO: UInt8 = 26
comptime _WEEK_SUN: UInt8 = 27
comptime _WEEK_MON: UInt8 = 28
comptime _ISO_WEEK: UInt8 = 29
comptime _ISO_YEAR: UInt8 = 30
comptime _UTC_OFFSET: UInt8 = 31
comptime _ZONE_NAME: UInt8 = 32

comptime _PERCENT: UInt8 = 0x25
comptime _HYPHEN: UInt8 = 0x2D

comptime _MICROS_PER_DAY = 86_400_000_000


def _unpadded(spec: UInt8) -> Optional[UInt8]:
    """The unpadded form of a padded number specifier, `%-<c>`."""
    if spec == _YEAR2:
        return Optional[UInt8](_YEAR2_NP)
    if spec == _MONTH:
        return Optional[UInt8](_MONTH_NP)
    if spec == _DAY:
        return Optional[UInt8](_DAY_NP)
    if spec == _HOUR:
        return Optional[UInt8](_HOUR_NP)
    if spec == _HOUR12:
        return Optional[UInt8](_HOUR12_NP)
    if spec == _MINUTE:
        return Optional[UInt8](_MINUTE_NP)
    if spec == _SECOND:
        return Optional[UInt8](_SECOND_NP)
    if spec == _YDAY:
        return Optional[UInt8](_YDAY_NP)
    return Optional[UInt8]()


def _spec_of(c: UInt8) -> Optional[UInt8]:
    """The specifier `%<c>` names, or none for a letter DuckDB does not know
    (`%c`, `%x`, `%X`, `%T`, `%%` and `%n` are read by the parser itself)."""
    if c == UInt8(ord("Y")):
        return Optional[UInt8](_YEAR)
    if c == UInt8(ord("y")):
        return Optional[UInt8](_YEAR2)
    if c == UInt8(ord("m")):
        return Optional[UInt8](_MONTH)
    if c == UInt8(ord("d")):
        return Optional[UInt8](_DAY)
    if c == UInt8(ord("H")):
        return Optional[UInt8](_HOUR)
    if c == UInt8(ord("I")):
        return Optional[UInt8](_HOUR12)
    if c == UInt8(ord("M")):
        return Optional[UInt8](_MINUTE)
    if c == UInt8(ord("S")):
        return Optional[UInt8](_SECOND)
    if c == UInt8(ord("j")):
        return Optional[UInt8](_YDAY)
    if c == UInt8(ord("p")):
        return Optional[UInt8](_AMPM)
    if c == UInt8(ord("f")):
        return Optional[UInt8](_MICROS)
    if c == UInt8(ord("g")):
        return Optional[UInt8](_MILLIS)
    if c == UInt8(ord("a")):
        return Optional[UInt8](_WDAY_ABBR)
    if c == UInt8(ord("A")):
        return Optional[UInt8](_WDAY_FULL)
    if c == UInt8(ord("b")) or c == UInt8(ord("h")):
        return Optional[UInt8](_MONTH_ABBR)
    if c == UInt8(ord("B")):
        return Optional[UInt8](_MONTH_FULL)
    if c == UInt8(ord("w")):
        return Optional[UInt8](_WDAY_SUN0)
    if c == UInt8(ord("u")):
        return Optional[UInt8](_WDAY_ISO)
    if c == UInt8(ord("U")):
        return Optional[UInt8](_WEEK_SUN)
    if c == UInt8(ord("W")):
        return Optional[UInt8](_WEEK_MON)
    if c == UInt8(ord("V")):
        return Optional[UInt8](_ISO_WEEK)
    if c == UInt8(ord("G")):
        return Optional[UInt8](_ISO_YEAR)
    if c == UInt8(ord("z")):
        return Optional[UInt8](_UTC_OFFSET)
    if c == UInt8(ord("Z")):
        return Optional[UInt8](_ZONE_NAME)
    return Optional[UInt8]()


# --- the calendar ------------------------------------------------------------


def _civil(days: Int) -> Tuple[Int, Int, Int]:
    """(year, month, day) of the proleptic Gregorian date `days` after
    1970-01-01; year 0 is 1 BC."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + 3 if mp < 10 else mp - 9
    var year = yoe + era * 400 + (1 if month <= 2 else 0)
    return (year, month, day)


def _days_of(year: Int, month: Int, day: Int) -> Int:
    """The day count from 1970-01-01 of a proleptic Gregorian date."""
    var y = year - 1 if month <= 2 else year
    var era = y // 400
    var yoe = y - era * 400
    var mp = month + 9 if month <= 2 else month - 3
    var doy = (153 * mp + 2) // 5 + day - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _weekday(days: Int) -> Int:
    """0 for Sunday .. 6 for Saturday (1970-01-01 was a Thursday)."""
    return (days + 4) % 7


def _iso_weeks(year: Int) -> Int:
    """52, or 53 for a year that starts on a Thursday, or a leap year that
    starts on a Wednesday."""
    var jan1 = _weekday(_days_of(year, 1, 1))
    var dec31 = _weekday(_days_of(year, 12, 31))
    return 53 if jan1 == 4 or dec31 == 4 else 52


def _iso_week(days: Int, year: Int, yday: Int) -> Tuple[Int, Int]:
    """(ISO year, ISO week) of the date `days`, the `yday`-th (from 1) day of
    `year`."""
    var iso_wday = (_weekday(days) + 6) % 7 + 1
    var week = (yday - iso_wday + 10) // 7
    if week < 1:
        return (year - 1, _iso_weeks(year - 1))
    if week > _iso_weeks(year):
        return (year + 1, 1)
    return (year, week)


def _weekday_name(wday: Int) -> String:
    """`Sunday` for 0 .. `Saturday` for 6."""
    var names: List[String] = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
        "Saturday",
    ]
    return names[wday]


def _month_name(month: Int) -> String:
    """`January` for 1 .. `December` for 12."""
    var names: List[String] = [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    ]
    return names[month - 1]


def _pad(n: Int, width: Int) -> String:
    """`n` (not negative) in decimal, zero-padded to `width` digits."""
    var s = String(n)
    while s.byte_length() < width:
        s = "0" + s
    return s^


def _year_text(year: Int) -> String:
    if year < 0:
        return "-" + String(-year)
    return _pad(year, 4)


struct TemporalFormat(Copyable, Movable):
    """A DATEFORMAT or TIMESTAMPFORMAT, parsed (the module header lists what
    each specifier writes).

    Fields:
        text:   the format as written.
        _specs: one entry per piece: a specifier, or `_LIT` for literal text.
        _lits:  the literal text of each `_LIT` piece (empty for the others).
    """

    var text: String
    var _specs: List[UInt8]
    var _lits: List[String]

    def __init__(out self, option: String, text: String) raises:
        """Parse `text`, the value of the COPY option `option` (`DATEFORMAT`
        or `TIMESTAMPFORMAT`, for the message).

        Raises:
            `CSV_DIALECT_INVALID` with DuckDB's reason for a format DuckDB
            refuses; `CSV_DIALECT_UNSUPPORTED` for `%n`.
        """
        self.text = text
        self._specs = List[UInt8]()
        self._lits = List[String]()
        var shown = option + " '" + text.replace("'", "''") + "'"
        var head = (
            String(CSV_DIALECT_INVALID) + ": COPY ... (" + shown
            + "): Failed to parse format specifier " + text + ": "
        )
        var src = text.as_bytes()
        var n = len(src)
        if n == 0:
            raise Error(head + "Empty format string")
        var lit = List[UInt8]()
        var i = 0
        while i < n:
            if src[i] != _PERCENT:
                lit.append(src[i])
                i += 1
                continue
            if i + 1 >= n:
                raise Error(head + "Trailing format character %")
            var c = src[i + 1]
            if c == _PERCENT:
                lit.append(_PERCENT)
                i += 2
                continue
            if c == UInt8(ord("n")):
                raise Error(
                    String(CSV_DIALECT_UNSUPPORTED) + ": COPY ... (" + shown
                    + "): %n, which DuckDB's COPY writes padded with spaces"
                    " beside another specifier; write %f for the"
                    " microseconds"
                )
            self._flush(lit)
            i += 2
            if c == UInt8(ord("c")):
                self._compound("%Y-%m-%d %H:%M:%S")
                continue
            if c == UInt8(ord("x")):
                self._compound("%Y-%m-%d")
                continue
            if c == UInt8(ord("X")) or c == UInt8(ord("T")):
                self._compound("%H:%M:%S")
                continue
            var start = i - 2
            var spec = Optional[UInt8]()
            if c == _HYPHEN:
                if i < n:
                    var padded = _spec_of(src[i])
                    if padded:
                        spec = _unpadded(padded.value())
                    i += 1
            else:
                spec = _spec_of(c)
            if not spec:
                # The specifier as written, to the end of a multi-byte
                # character.
                while i < n and (src[i] & 0xC0) == 0x80:
                    i += 1
                raise Error(
                    head + "Unrecognized format for strftime/strptime: "
                    + String(text[byte = start:i])
                )
            self._specs.append(spec.value())
            self._lits.append(String(""))
        self._flush(lit)

    def _flush(mut self, mut lit: List[UInt8]):
        """Append the literal text gathered so far as one piece."""
        if len(lit) == 0:
            return
        self._specs.append(_LIT)
        self._lits.append(String(unsafe_from_utf8=Span(lit)))
        lit.clear()

    def _compound(mut self, var parts: String):
        """Append the pieces of a fixed format (`%c`, `%x`, `%X`)."""
        var src = parts.as_bytes()
        var i = 0
        while i < len(src):
            if src[i] == _PERCENT:
                self._specs.append(_spec_of(src[i + 1]).value())
                self._lits.append(String(""))
                i += 2
            else:
                self._specs.append(_LIT)
                self._lits.append(chr(Int(src[i])))
                i += 1

    def date_text(self, days: Int) -> String:
        """The DATE `days` after 1970-01-01 in this format."""
        return self._render(days, 0, False)

    def timestamp_text(self, micros: Int64, zoned: Bool) -> String:
        """The microsecond TIMESTAMP `micros` in this format; `zoned` for a
        TIMESTAMPTZ, shown in UTC."""
        if micros == Int64.MAX:
            return "infinity"
        if micros == -Int64.MAX:
            return "-infinity"
        var v = Int(micros)
        # Floor division: a time before 1970 is the day before at a positive
        # time of day.
        return self._render(
            v // _MICROS_PER_DAY, v % _MICROS_PER_DAY, zoned
        )

    def _render(self, days: Int, tod: Int, zoned: Bool) -> String:
        """The date `days` at `tod` microseconds past midnight."""
        var ymd = _civil(days)
        var year = ymd[0]
        var yday = days - _days_of(year, 1, 1) + 1
        var wday = _weekday(days)
        var secs = tod // 1_000_000
        var hour = secs // 3600
        var minute = (secs // 60) % 60
        var second = secs % 60
        var hour12 = hour % 12
        if hour12 == 0:
            hour12 = 12
        var out = String()
        for p in range(len(self._specs)):
            var s = self._specs[p]
            if s == _LIT:
                out += self._lits[p]
            elif s == _YEAR:
                out += _year_text(year)
            elif s == _YEAR2:
                out += _pad((-year if year < 0 else year) % 100, 2)
            elif s == _YEAR2_NP:
                out += String((-year if year < 0 else year) % 100)
            elif s == _MONTH:
                out += _pad(ymd[1], 2)
            elif s == _MONTH_NP:
                out += String(ymd[1])
            elif s == _DAY:
                out += _pad(ymd[2], 2)
            elif s == _DAY_NP:
                out += String(ymd[2])
            elif s == _HOUR:
                out += _pad(hour, 2)
            elif s == _HOUR_NP:
                out += String(hour)
            elif s == _HOUR12:
                out += _pad(hour12, 2)
            elif s == _HOUR12_NP:
                out += String(hour12)
            elif s == _MINUTE:
                out += _pad(minute, 2)
            elif s == _MINUTE_NP:
                out += String(minute)
            elif s == _SECOND:
                out += _pad(second, 2)
            elif s == _SECOND_NP:
                out += String(second)
            elif s == _YDAY:
                out += _pad(yday, 3)
            elif s == _YDAY_NP:
                out += String(yday)
            elif s == _AMPM:
                out += String("AM") if hour < 12 else String("PM")
            elif s == _MICROS:
                out += _pad(tod % 1_000_000, 6)
            elif s == _MILLIS:
                out += _pad((tod % 1_000_000) // 1000, 3)
            elif s == _WDAY_ABBR:
                out += String(_weekday_name(wday)[byte = 0:3])
            elif s == _WDAY_FULL:
                out += _weekday_name(wday)
            elif s == _MONTH_ABBR:
                out += String(_month_name(ymd[1])[byte = 0:3])
            elif s == _MONTH_FULL:
                out += _month_name(ymd[1])
            elif s == _WDAY_SUN0:
                out += String(wday)
            elif s == _WDAY_ISO:
                out += String((wday + 6) % 7 + 1)
            elif s == _WEEK_SUN:
                out += _pad((yday - 1 + 7 - wday) // 7, 2)
            elif s == _WEEK_MON:
                out += _pad((yday - 1 + 7 - (wday + 6) % 7) // 7, 2)
            elif s == _ISO_WEEK:
                out += _pad(_iso_week(days, year, yday)[1], 2)
            elif s == _ISO_YEAR:
                var iso_year = _iso_week(days, year, yday)[0]
                # DuckDB writes the year's 32 bits read as unsigned, last four
                # digits only.
                out += _pad((iso_year & 0xFFFFFFFF) % 10000, 4)
            elif s == _UTC_OFFSET:
                out += "+00"
            elif zoned:  # _ZONE_NAME, the one specifier left
                out += "UTC"
        return out^
