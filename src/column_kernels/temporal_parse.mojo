# =============================================================================
# temporal_parse — text -> DATE32 / TIMESTAMP_US, the way DuckDB parses it
# =============================================================================
#
# Three parsers, each a port of the DuckDB v1.5 routine named beside it:
#
#   parse_date_text        CAST(<text> AS DATE)       Date::TryConvertDate
#   parse_timestamp_text   CAST(<text> AS TIMESTAMP)  Timestamp::TryConvertTimestamp
#   strptime_parse         strptime / try_strptime    StrpTimeFormat::Parse
#
# and the column orchestrators the evaluator calls:
#
#   cast_string_to_date32(sa, try_mode)        -> PrimitiveArray[int32]  (days)
#   cast_string_to_timestamp_us(sa, try_mode)  -> PrimitiveArray[int64]  (micros)
#   strptime_column(sa, fmt, try_mode)         -> PrimitiveArray[int64]  (micros)
#
# Null in -> null out. Strict mode raises DuckDB's own message for the first
# row that does not parse; try mode (TRY_CAST, try_strptime) answers NULL for
# that row instead.
#
# References (the behaviour each rule below reproduces):
#   https://duckdb.org/docs/stable/sql/expressions/cast.html
#   https://duckdb.org/docs/stable/sql/data_types/date.html
#   https://duckdb.org/docs/stable/sql/data_types/timestamp.html
#   https://duckdb.org/docs/stable/sql/functions/dateformat.html
#
# What DuckDB answers that an Arrow column cannot hold is refused by name in
# both modes: the special values `infinity` / `-infinity` (an infinite date or
# timestamp). Answering NULL for them under TRY would be a wrong answer that
# looks like TRY's own output.
#
# The strptime directives served are the ones whose DuckDB result is a plain
# TIMESTAMP and that this file reproduces exactly: %Y %y %-y %m %-m %d %-d %b
# %h %B %a %A %H %-H %I %-I %p %M %-M %S %-S %f %g %j %-j %c %x %X %T %%.
# Refused by name: %z and %Z (DuckDB returns TIMESTAMP WITH TIME ZONE for
# them), %n (DuckDB returns TIMESTAMP_NS), and the week-based %G %V %u %U %W
# %w. Any other directive is DuckDB's own "Unrecognized format" error.
#
# Encapsulation: `Span[UInt8, _]` in, values out; no pointers.
# =============================================================================

from arrow.primitive_array import PrimitiveArray
from arrow.string_array import StringArray


# ---- parse outcome ------------------------------------------------------------

comptime TP_OK: UInt8 = 0
"""The text parsed; `value` holds the answer."""
comptime TP_FORMAT: UInt8 = 1
"""DuckDB's ERROR_INCORRECT_FORMAT: the text does not have the shape."""
comptime TP_RANGE: UInt8 = 2
"""DuckDB's ERROR_RANGE: the shape is right, a field or the result is not."""
comptime TP_NON_UTC: UInt8 = 3
"""A TIMESTAMP text naming a time zone other than UTC (DuckDB's
ERROR_NON_UTC_TIMEZONE)."""
comptime TP_INFINITE: UInt8 = 4
"""`infinity` / `-infinity`: DuckDB answers an infinite value, which an Arrow
column has no representation for."""


@fieldwise_init
struct TemporalParse(Copyable, ImplicitlyCopyable, Movable):
    """The outcome of one text parse: a `TP_*` status and, for `TP_OK`, the
    value (days since the Unix epoch for a date, microseconds for a timestamp)."""

    var status: UInt8
    var value: Int64


# ---- calendar -----------------------------------------------------------------

comptime _DATE_MIN_YEAR: Int = -5877641
comptime _DATE_MIN_MONTH: Int = 6
comptime _DATE_MIN_DAY: Int = 25
comptime _DATE_MAX_YEAR: Int = 5881580
comptime _DATE_MAX_MONTH: Int = 7
comptime _DATE_MAX_DAY: Int = 10
comptime _MICROS_PER_DAY: Int = 86400000000
comptime _INT64_MAX: Int = 9223372036854775807
# The largest day count whose midnight fits an Int64 microsecond count:
# floor((2^63 - 1) / 86400000000).
comptime _MAX_TS_DAYS: Int = 106751991


@always_inline
def _is_leap(year: Int) -> Bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def _days_in_month(year: Int, month: Int) -> Int:
    if month == 2:
        return 29 if _is_leap(year) else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    return 31


def _date_is_valid(year: Int, month: Int, day: Int) -> Bool:
    """DuckDB's `Date::IsValid`: a real calendar day inside DATE's range
    (5877642-06-25 (BC) to 5881580-07-10)."""
    if month < 1 or month > 12 or day < 1:
        return False
    if year < _DATE_MIN_YEAR or year > _DATE_MAX_YEAR:
        return False
    if year == _DATE_MIN_YEAR and (
        month < _DATE_MIN_MONTH or (month == _DATE_MIN_MONTH and day < _DATE_MIN_DAY)
    ):
        return False
    if year == _DATE_MAX_YEAR and (
        month > _DATE_MAX_MONTH or (month == _DATE_MAX_MONTH and day > _DATE_MAX_DAY)
    ):
        return False
    return day <= _days_in_month(year, month)


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Days from a proleptic Gregorian (year, month, day), counted from the
    Unix epoch, by 400-year eras. Mojo's `//` floors, so the era is one flooring divide (no
    `y - 399` adjustment, which assumes a truncating divide)."""
    var yy = y - 1 if m <= 2 else y
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil_from_days(z: Int) -> Tuple[Int, Int, Int]:
    """Inverse of `_days_from_civil` (the same era arithmetic run backwards)."""
    var zz = z + 719468
    var era = zz // 146097
    var doe = zz - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


def _timestamp_from_parts(days: Int, time_us: Int) -> TemporalParse:
    """DuckDB's `Timestamp::TryFromDatetime`: days * 86400000000 + time, with
    overflow and the two infinity sentinels (+-(2^63 - 1)) out of range.
    `time_us` is never negative here."""
    if days > _MAX_TS_DAYS or days < -_MAX_TS_DAYS:
        return TemporalParse(TP_RANGE, 0)
    var base = days * _MICROS_PER_DAY
    if base > 0 and time_us > _INT64_MAX - base:
        return TemporalParse(TP_RANGE, 0)
    var v = base + time_us
    if v == _INT64_MAX or v == -_INT64_MAX:
        return TemporalParse(TP_RANGE, 0)
    return TemporalParse(TP_OK, Int64(v))


# ---- byte classes (DuckDB's StringUtil) ---------------------------------------


@always_inline
def _is_space(c: UInt8) -> Bool:
    """` `, `\\t`, `\\n`, `\\v`, `\\f`, `\\r`."""
    return c == 32 or (c >= 9 and c <= 13)


@always_inline
def _is_digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


@always_inline
def _is_alpha(c: UInt8) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


@always_inline
def _lower(c: UInt8) -> UInt8:
    if c >= 65 and c <= 90:
        return c + 32
    return c


@always_inline
def _is_tz_char(c: UInt8) -> Bool:
    """`Timestamp::CharacterIsTimeZone`: [A-Za-z0-9_/+:-]."""
    return (
        _is_alpha(c)
        or _is_digit(c)
        or c == UInt8(ord("_"))
        or c == UInt8(ord("/"))
        or c == UInt8(ord("+"))
        or c == UInt8(ord("-"))
        or c == UInt8(ord(":"))
    )


def _match_special(b: Span[UInt8, _], pos: Int, word: StaticString, abbr: Int) -> Int:
    """DuckDB's `Date::TryConvertDateSpecial`: match `word` case-insensitively
    at `pos`, or a prefix of it at least `abbr` long that ends the text.
    Returns the position after the match, or -1."""
    var w = word.as_bytes()
    var p = pos
    var k = 0
    while p < len(b) and k < len(w):
        if _lower(b[p]) != w[k]:
            return -1
        p += 1
        k += 1
    if k < len(w) and (p - pos) != abbr:
        return -1
    return p


def _parse_double_digit(b: Span[UInt8, _], mut pos: Int, mut out: Int) -> Bool:
    """DuckDB's `Date::ParseDoubleDigit`: one or two digits."""
    if pos < len(b) and _is_digit(b[pos]):
        out = Int(b[pos]) - 48
        pos += 1
        if pos < len(b) and _is_digit(b[pos]):
            out = out * 10 + Int(b[pos]) - 48
            pos += 1
        return True
    return False


# ---- CAST(<text> AS DATE) -----------------------------------------------------


struct _DateScan(Copyable, ImplicitlyCopyable, Movable):
    """A date scanned from the front of a text: status, day count, the
    position after it, and whether it was a special value."""

    var status: UInt8
    var days: Int
    var pos: Int
    var infinite: Bool

    def __init__(out self, status: UInt8, days: Int, pos: Int, infinite: Bool):
        self.status = status
        self.days = days
        self.pos = pos
        self.infinite = infinite


def _scan_date(b: Span[UInt8, _]) -> _DateScan:
    """DuckDB's `Date::TryConvertDate` in its non-strict mode, the mode plain
    CAST uses:

      * leading whitespace is skipped; a leading `-` negates the year;
      * `infinity` (or a prefix of 3+ letters), `-infinity`, `epoch`, then
        only whitespace;
      * the year is any number of digits (refused past 99999999);
      * one separator out of ` `, `-`, `/`, `\\`, used twice;
      * month and day are one or two digits each;
      * an optional ` (BC)` (any case) turns year Y into 1 - Y;
      * the day must not be followed directly by another digit; any other
        trailing text is ignored (`'2026-09-15 10:11'` is 2026-09-15);
      * the date must be a real calendar day inside DATE's range.
    """
    var n = len(b)
    var pos = 0
    if n == 0:
        return _DateScan(TP_FORMAT, 0, 0, False)
    while pos < n and _is_space(b[pos]):
        pos += 1
    if pos >= n:
        return _DateScan(TP_FORMAT, 0, pos, False)
    var yearneg = False
    if b[pos] == UInt8(ord("-")):
        yearneg = True
        pos += 1
        if pos >= n:
            return _DateScan(TP_FORMAT, 0, pos, False)
    if not _is_digit(b[pos]):
        var infinite = False
        var after = _match_special(b, pos, "infinity", 3)
        if after >= 0:
            infinite = True
        else:
            after = _match_special(b, pos, "epoch", 5)
            if after < 0:
                return _DateScan(TP_FORMAT, 0, pos, False)
        pos = after
        while pos < n and _is_space(b[pos]):
            pos += 1
        if pos != n:
            return _DateScan(TP_FORMAT, 0, pos, False)
        return _DateScan(TP_OK, 0, pos, infinite)
    var year = 0
    while pos < n and _is_digit(b[pos]):
        if year >= 100000000:
            return _DateScan(TP_RANGE, 0, pos, False)
        year = year * 10 + Int(b[pos]) - 48
        pos += 1
    if yearneg:
        year = -year
    if pos >= n:
        return _DateScan(TP_FORMAT, 0, pos, False)
    var sep = b[pos]
    pos += 1
    if (
        sep != UInt8(ord(" "))
        and sep != UInt8(ord("-"))
        and sep != UInt8(ord("/"))
        and sep != UInt8(ord("\\"))
    ):
        return _DateScan(TP_FORMAT, 0, pos, False)
    var month = 0
    if not _parse_double_digit(b, pos, month):
        return _DateScan(TP_FORMAT, 0, pos, False)
    if pos >= n:
        return _DateScan(TP_FORMAT, 0, pos, False)
    if b[pos] != sep:
        return _DateScan(TP_FORMAT, 0, pos, False)
    pos += 1
    if pos >= n:
        return _DateScan(TP_FORMAT, 0, pos, False)
    var day = 0
    if not _parse_double_digit(b, pos, day):
        return _DateScan(TP_FORMAT, 0, pos, False)
    if (
        n - pos >= 5
        and _is_space(b[pos])
        and b[pos + 1] == UInt8(ord("("))
        and _lower(b[pos + 2]) == UInt8(ord("b"))
        and _lower(b[pos + 3]) == UInt8(ord("c"))
        and b[pos + 4] == UInt8(ord(")"))
    ):
        if yearneg or year == 0:
            return _DateScan(TP_FORMAT, 0, pos, False)
        year = -year + 1
        pos += 5
    if pos < n and _is_digit(b[pos]):
        return _DateScan(TP_FORMAT, 0, pos, False)
    if not _date_is_valid(year, month, day):
        return _DateScan(TP_RANGE, 0, pos, False)
    return _DateScan(TP_OK, _days_from_civil(year, month, day), pos, False)


def parse_date_text(b: Span[UInt8, _]) -> TemporalParse:
    """`CAST(<text> AS DATE)`: days since the Unix epoch, or why not.

        '2026-09-15'           -> 20711      ' 2026-9-5 '   -> 20701
        '2026/09/15'           -> 20711      '2026-02-30'   -> TP_RANGE
        '2026-09-15 10:11:12'  -> 20711      '15 Sep 2026'  -> TP_FORMAT
        '-2044-03-15'          -> -1466010   'infinity'     -> TP_INFINITE
    """
    var s = _scan_date(b)
    if s.status != TP_OK:
        return TemporalParse(s.status, 0)
    if s.infinite:
        return TemporalParse(TP_INFINITE, 0)
    return TemporalParse(TP_OK, Int64(s.days))


# ---- CAST(<text> AS TIMESTAMP) ------------------------------------------------


def _scan_time(b: Span[UInt8, _], start: Int, mut pos: Int, mut micros: Int) -> Bool:
    """DuckDB's `Time::TryConvertInternal` in non-strict mode over
    `b[start:]`: optional spaces, an hour of up to nine digits, `:`, a minute
    of one or two digits (or nothing at the end of the text), then an
    optional `:` and second, then an optional `.` and fraction whose digits
    past the sixth are dropped. Trailing text is left for the caller."""
    var n = len(b)
    pos = start
    if pos >= n:
        return False
    while pos < n and _is_space(b[pos]):
        pos += 1
    if pos >= n or not _is_digit(b[pos]):
        return False
    var hour = 0
    var digits = 0
    while pos < n and _is_digit(b[pos]):
        if digits == 9:
            return False
        hour = hour * 10 + Int(b[pos]) - 48
        digits += 1
        pos += 1
    if pos >= n or b[pos] != UInt8(ord(":")):
        return False
    pos += 1
    var minute = 0
    var sec = 0
    if pos < n:
        if not _parse_double_digit(b, pos, minute) or minute >= 60:
            return False
        if pos < n:
            if b[pos] != UInt8(ord(":")):
                return False
            pos += 1
            if pos < n:
                if not _parse_double_digit(b, pos, sec) or sec >= 60:
                    return False
    var frac = 0
    if pos < n and b[pos] == UInt8(ord(".")):
        pos += 1
        var mult = 100000
        while pos < n and _is_digit(b[pos]):
            frac += (Int(b[pos]) - 48) * mult
            mult //= 10
            pos += 1
    micros = ((hour * 60 + minute) * 60 + sec) * 1000000 + frac
    return True


def _parse_utc_offset(b: Span[UInt8, _], mut pos: Int) -> Bool:
    """DuckDB's `Timestamp::TryParseUTCOffset`: `+HH`, `+HHMM`, `+HH:MM`,
    `+HH:MM:SS` (or `-`). Only whether it matched and where it ends matter
    here: a TIMESTAMP keeps the wall clock and drops the offset."""
    var n = len(b)
    var cur = pos
    if cur + 3 > n:
        return False
    if b[cur] != UInt8(ord("+")) and b[cur] != UInt8(ord("-")):
        return False
    cur += 1
    if not _is_digit(b[cur]) or not _is_digit(b[cur + 1]):
        return False
    cur += 2
    if cur >= n:
        pos = cur
        return True
    var colons = b[cur] == UInt8(ord(":"))
    if colons:
        cur += 1
    if cur + 2 > n or not _is_digit(b[cur]) or not _is_digit(b[cur + 1]):
        pos = cur
        return True
    cur += 2
    if cur >= n or not colons or b[cur] != UInt8(ord(":")):
        pos = cur
        return True
    cur += 1
    if cur + 2 > n or not _is_digit(b[cur]) or not _is_digit(b[cur + 1]):
        pos = cur
        return True
    pos = cur + 2
    return True


def parse_timestamp_text(b: Span[UInt8, _]) -> TemporalParse:
    """`CAST(<text> AS TIMESTAMP)`: microseconds since the Unix epoch, or why not.

    The date is `parse_date_text`'s grammar. After it: nothing (midnight), or
    a space or `T`, a time (`HH:MM[:SS[.fraction]]`, hour 24:00:00 meaning
    the next midnight), then optionally `Z`, a UTC offset, or a space and a
    zone name, and trailing spaces. An offset is DROPPED, not applied: DuckDB
    reads `'2026-09-15 10:11:12+02'` as 10:11:12 (a TIMESTAMP has no zone). A
    zone name other than `UTC` (any case) is `TP_NON_UTC`.

        '2026-09-15'                    -> 1789430400000000
        '2026-09-15T10:11:12.1234567'   -> 1789467072123456
        '2026-09-15 24:00:00'           -> 1789516800000000
        '2026-09-15 10'                 -> TP_FORMAT
        '2026-09-15 10:11:12 Europe/Berlin' -> TP_NON_UTC
    """
    var d = _scan_date(b)
    if d.status != TP_OK:
        return TemporalParse(d.status, 0)
    var n = len(b)
    var pos = d.pos
    if pos == n:
        if d.infinite:
            return TemporalParse(TP_INFINITE, 0)
        return _timestamp_from_parts(d.days, 0)
    if b[pos] == UInt8(ord(" ")) or b[pos] == UInt8(ord("T")):
        pos += 1
    var tpos = 0
    var micros = 0
    if not _scan_time(b, pos, tpos, micros):
        return TemporalParse(TP_FORMAT, 0)
    if micros > _MICROS_PER_DAY:
        return TemporalParse(TP_RANGE, 0)
    pos = tpos
    var ts = _timestamp_from_parts(d.days, micros)
    if ts.status != TP_OK:
        return ts
    if pos < n:
        var zone_start = -1
        if b[pos] == UInt8(ord("Z")):
            pos += 1
        elif _parse_utc_offset(b, pos):
            pass
        else:
            if b[pos] != UInt8(ord(" ")):
                return TemporalParse(TP_NON_UTC, 0)
            pos += 1
            zone_start = pos
            while pos < n and _is_tz_char(b[pos]):
                pos += 1
        var zone_end = pos
        while pos < n and _is_space(b[pos]):
            pos += 1
        if pos < n:
            return TemporalParse(TP_FORMAT, 0)
        if zone_start >= 0 and zone_end > zone_start:
            var is_utc = (
                zone_end - zone_start == 3
                and _lower(b[zone_start]) == UInt8(ord("u"))
                and _lower(b[zone_start + 1]) == UInt8(ord("t"))
                and _lower(b[zone_start + 2]) == UInt8(ord("c"))
            )
            if not is_utc:
                return TemporalParse(TP_NON_UTC, 0)
    return ts


# ---- error messages -----------------------------------------------------------


def date_cast_error(text: String, status: UInt8) -> String:
    """The message a strict `CAST(<text> AS DATE)` raises for `status`.
    Format and range errors are DuckDB's own text."""
    if status == TP_RANGE:
        return "Conversion Error: date field value out of range: \"" + text + "\""
    if status == TP_INFINITE:
        return _infinite_error(text, "DATE")
    return (
        "Conversion Error: invalid date field format: \"" + text
        + "\", expected format is (YYYY-MM-DD)"
    )


def timestamp_cast_error(text: String, status: UInt8) -> String:
    """The message a strict `CAST(<text> AS TIMESTAMP)` raises for `status`.
    Format, range and zone errors are DuckDB's own text."""
    if status == TP_RANGE:
        return "Conversion Error: timestamp field value out of range: \"" + text + "\""
    if status == TP_NON_UTC:
        return (
            "Conversion Error: timestamp field value \"" + text + "\" has a"
            " timestamp that is not UTC.\nUse the TIMESTAMPTZ type with the"
            " ICU extension loaded to handle non-UTC timestamps."
        )
    if status == TP_INFINITE:
        return _infinite_error(text, "TIMESTAMP")
    return (
        "Conversion Error: invalid timestamp field format: \"" + text
        + "\", expected format is (YYYY-MM-DD HH:MM:SS[.US][±HH[:MM[:SS]]| ZONE])"
    )


def _infinite_error(text: String, target: String) -> String:
    return (
        "SQL not supported: the text \"" + text + "\" parses to an INFINITE "
        + target + " in DuckDB, and an Arrow " + target.lower() + " column"
        " has no infinite value to hold it. Refused rather than answered"
        " with NULL or a finite stand-in, under TRY as well."
    )


# ---- column orchestrators: CAST -----------------------------------------------


def cast_string_to_date32(
    sa: StringArray, try_mode: Bool = False
) raises -> PrimitiveArray[DType.int32]:
    """`CAST(<text> AS DATE)` over a column (`try_mode`: TRY_CAST).

    Null in -> null out. A row that does not parse raises DuckDB's message in
    strict mode and is NULL in try mode. An infinite date raises in both."""
    var n = sa.length
    var out = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var r = parse_date_text(sa.get_span(i))
        if r.status == TP_OK:
            out.set(i, Scalar[DType.int32](Int32(r.value)))
        elif try_mode and r.status != TP_INFINITE:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise Error(date_cast_error(sa.get(i), r.status))
    out.null_count = nc
    return out^


def cast_string_to_timestamp_us(
    sa: StringArray, try_mode: Bool = False
) raises -> PrimitiveArray[DType.int64]:
    """`CAST(<text> AS TIMESTAMP)` over a column (`try_mode`: TRY_CAST); the
    values are microseconds since the Unix epoch (Arrow TIMESTAMP_US).

    Null in -> null out. A row that does not parse raises DuckDB's message in
    strict mode and is NULL in try mode. An infinite timestamp raises in
    both."""
    var n = sa.length
    var out = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var r = parse_timestamp_text(sa.get_span(i))
        if r.status == TP_OK:
            out.set(i, Scalar[DType.int64](r.value))
        elif try_mode and r.status != TP_INFINITE:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise Error(timestamp_cast_error(sa.get(i), r.status))
    out.null_count = nc
    return out^
