# =============================================================================
# strptime_format — DuckDB's strptime / try_strptime format directives
# =============================================================================
#
# A port of DuckDB v1.5's `StrTimeFormat::ParseFormatSpecifier` (compile a
# format) and `StrpTimeFormat::Parse` (match a text against it), restricted
# to the directives this engine reproduces exactly:
#
#   %Y %y %-y   year (up to 4 digits) / two-digit year (69..99 -> 19xx)
#   %m %-m      month 1-12            %b %h %B   month name (any case)
#   %d %-d      day 1-31              %a %A      weekday name, matched, unused
#   %H %-H      hour 0-23             %I %-I %p  hour 1-12 and AM / PM
#   %M %-M      minute 0-59           %S %-S     second 0-59
#   %f          microseconds          %g         milliseconds
#   %j %-j      day of the year 1-366
#   %c %x %X %T the ISO shapes %Y-%m-%d %H:%M:%S, %Y-%m-%d, %H:%M:%S, %H:%M:%S
#   %%          a literal %
#
# Refused by name, at compile time: %z %Z (DuckDB returns TIMESTAMP WITH TIME
# ZONE for them), %n (DuckDB returns TIMESTAMP_NS), and the week-based %G %V
# %u %U %W %w. Anything else is DuckDB's own "Unrecognized format" error.
#
# Numeric directives read up to their width in digits (no minimum: `%d`
# accepts `5`), fields the format does not set default to DuckDB's
# (year 1900, January, day 1, midnight), a run of spaces in the format
# matches a run of spaces in the text, and leading and trailing spaces of the text are skipped.
#
# Reference: https://duckdb.org/docs/stable/sql/functions/dateformat.html
# =============================================================================

from arrow.primitive_array import PrimitiveArray
from arrow.string_array import StringArray

from .temporal_parse import (
    TP_FORMAT,
    TP_INFINITE,
    TP_OK,
    TP_RANGE,
    _MICROS_PER_DAY,
    _civil_from_days,
    _date_is_valid,
    _days_from_civil,
    _is_alpha,
    _is_digit,
    _is_space,
    _lower,
    _match_special,
)


# ---- directives ---------------------------------------------------------------

comptime SP_DAY: UInt8 = 1
comptime SP_MONTH: UInt8 = 2
comptime SP_YEAR2: UInt8 = 3
comptime SP_YEAR4: UInt8 = 4
comptime SP_HOUR24: UInt8 = 5
comptime SP_HOUR12: UInt8 = 6
comptime SP_MINUTE: UInt8 = 7
comptime SP_SECOND: UInt8 = 8
comptime SP_MICRO: UInt8 = 9
comptime SP_MILLI: UInt8 = 10
comptime SP_YEARDAY: UInt8 = 11
comptime SP_AMPM: UInt8 = 12
comptime SP_WDAY_ABBR: UInt8 = 13
comptime SP_WDAY_FULL: UInt8 = 14
comptime SP_MON_ABBR: UInt8 = 15
comptime SP_MON_FULL: UInt8 = 16


def _width(spec: UInt8) -> Int:
    """DuckDB's `NumericSpecifierWidth`: the most digits a numeric directive
    reads; 0 for the name and AM/PM directives."""
    if spec == SP_YEAR4:
        return 4
    if spec == SP_MICRO:
        return 6
    if spec == SP_MILLI or spec == SP_YEARDAY:
        return 3
    if spec >= SP_AMPM:
        return 0
    return 2


struct StrptimeFormat(Copyable, Movable):
    """A compiled format: `specs[i]` follows `literals[i]`, and one more
    literal ends it (`len(literals) == len(specs) + 1`). `text` is the format
    as written, for error messages."""

    var text: String
    var literals: List[String]
    var specs: List[UInt8]

    def __init__(out self, text: String, var literals: List[String], var specs: List[UInt8]):
        self.text = text
        self.literals = literals^
        self.specs = specs^


def _format_error(fmt: String, why: String) -> String:
    return "Invalid Input Error: Failed to parse format specifier " + fmt + ": " + why


def _refused_directive(c: UInt8) -> String:
    var d = "%" + chr(Int(c))
    if c == UInt8(ord("z")) or c == UInt8(ord("Z")):
        return (
            "SQL not supported: the strptime directive " + d + ". DuckDB's"
            " strptime returns TIMESTAMP WITH TIME ZONE when the format holds"
            " %z or %Z, and the instant that names depends on a session time"
            " zone this engine does not have. Parse the text without its zone."
        )
    if c == UInt8(ord("n")):
        return (
            "SQL not supported: the strptime directive %n. DuckDB's strptime"
            " returns TIMESTAMP_NS (nanoseconds) when the format holds %n, and"
            " this engine's strptime returns TIMESTAMP (microseconds). %f"
            " reads up to six fraction digits."
        )
    return (
        "SQL not supported: the strptime directive " + d + ". It is one of"
        " the week-based directives (%G %V %u %U %W %w), which DuckDB turns"
        " into a date through ISO and Sunday- or Monday-first week rules that"
        " this engine does not reproduce. Use %Y with %m and %d, or %j."
    )


def _is_refused(c: UInt8) -> Bool:
    return (
        c == UInt8(ord("z"))
        or c == UInt8(ord("Z"))
        or c == UInt8(ord("n"))
        or c == UInt8(ord("G"))
        or c == UInt8(ord("V"))
        or c == UInt8(ord("u"))
        or c == UInt8(ord("U"))
        or c == UInt8(ord("W"))
        or c == UInt8(ord("w"))
    )


def _dash_spec(c: UInt8) -> UInt8:
    """The `%-x` (unpadded) directives; 0 for none."""
    if c == UInt8(ord("d")):
        return SP_DAY
    if c == UInt8(ord("m")):
        return SP_MONTH
    if c == UInt8(ord("y")):
        return SP_YEAR2
    if c == UInt8(ord("H")):
        return SP_HOUR24
    if c == UInt8(ord("I")):
        return SP_HOUR12
    if c == UInt8(ord("M")):
        return SP_MINUTE
    if c == UInt8(ord("S")):
        return SP_SECOND
    if c == UInt8(ord("j")):
        return SP_YEARDAY
    return 0


def _plain_spec(c: UInt8) -> UInt8:
    """The `%x` directives this file serves; 0 for none."""
    if c == UInt8(ord("Y")):
        return SP_YEAR4
    if c == UInt8(ord("f")):
        return SP_MICRO
    if c == UInt8(ord("g")):
        return SP_MILLI
    if c == UInt8(ord("p")):
        return SP_AMPM
    if c == UInt8(ord("a")):
        return SP_WDAY_ABBR
    if c == UInt8(ord("A")):
        return SP_WDAY_FULL
    if c == UInt8(ord("b")) or c == UInt8(ord("h")):
        return SP_MON_ABBR
    if c == UInt8(ord("B")):
        return SP_MON_FULL
    return _dash_spec(c)


def _expansion(c: UInt8) -> String:
    """`%c`, `%x`, `%X` and `%T` stand for an ISO shape; "" for any other."""
    if c == UInt8(ord("c")):
        return "%Y-%m-%d %H:%M:%S"
    if c == UInt8(ord("x")):
        return "%Y-%m-%d"
    if c == UInt8(ord("X")) or c == UInt8(ord("T")):
        return "%H:%M:%S"
    return ""


def compile_strptime_format(fmt: String) raises -> StrptimeFormat:
    """Compile a strptime format, or raise naming the directive it cannot
    serve. The error texts for an empty format, a trailing `%` and an
    unknown directive are DuckDB's."""
    if fmt.byte_length() == 0:
        raise Error(_format_error(fmt, "Empty format string"))
    var f = fmt.as_bytes()
    var n = len(f)
    var literals = List[String]()
    var specs = List[UInt8]()
    var current = String("")
    var pos = 0
    var i = 0
    while i < n:
        if f[i] != UInt8(ord("%")):
            i += 1
            continue
        if i + 1 == n:
            raise Error(_format_error(fmt, "Trailing format character %"))
        if i > pos:
            current += String(fmt[byte=pos:i])
        i += 1
        var c = f[i]
        if c == UInt8(ord("%")):
            # `%%`: the second `%` starts the next stretch of literal text.
            pos = i
            i += 1
            continue
        var spec: UInt8 = 0
        if c == UInt8(ord("-")) and i + 1 < n:
            i += 1
            c = f[i]
            spec = _dash_spec(c)
            if spec == 0:
                raise Error(
                    _format_error(
                        fmt, "Unrecognized format for strftime/strptime: %-" + chr(Int(c))
                    )
                )
        else:
            var sub = _expansion(c)
            if sub.byte_length() > 0:
                var inner = compile_strptime_format(sub)
                for k in range(len(inner.specs)):
                    if k == 0:
                        literals.append(current + inner.literals[0])
                    else:
                        literals.append(inner.literals[k])
                    specs.append(inner.specs[k])
                current = String("")
                pos = i + 1
                i += 1
                continue
            if _is_refused(c):
                raise Error(_refused_directive(c))
            spec = _plain_spec(c)
            if spec == 0:
                raise Error(
                    _format_error(
                        fmt, "Unrecognized format for strftime/strptime: %" + chr(Int(c))
                    )
                )
        literals.append(current)
        specs.append(spec)
        current = String("")
        pos = i + 1
        i += 1
    if pos < n:
        current += String(fmt[byte=pos:n])
    literals.append(current)
    return StrptimeFormat(fmt, literals^, specs^)


# ---- matching -----------------------------------------------------------------


@fieldwise_init
struct StrptimeOutcome(Copyable, Movable):
    """One text matched against a format: `status` is `TP_OK` (value is
    microseconds since the Unix epoch), `TP_FORMAT` (the text does not match;
    `message` and `position` say where), `TP_RANGE` (the fields name no
    calendar day) or `TP_INFINITE`. `position` is -1 when there is none."""

    var status: UInt8
    var value: Int64
    var message: String
    var position: Int


def _fail(message: String, position: Int) -> StrptimeOutcome:
    return StrptimeOutcome(TP_FORMAT, 0, message, position)


comptime _OFF_NONE: UInt8 = 0
comptime _OFF_DM: UInt8 = 1
comptime _OFF_Y: UInt8 = 2
comptime _OFF_J: UInt8 = 3


def _match_name(
    b: Span[UInt8, _], mut pos: Int, names: List[StaticString]
) -> Int:
    """DuckDB's `TryParseCollection`: the first name that matches at `pos`
    (case-insensitively) wins; returns its index and moves past it, or -1."""
    for c in range(len(names)):
        var w = names[c].as_bytes()
        if pos + len(w) > len(b):
            continue
        var k = 0
        while k < len(w) and _lower(w[k]) == _lower(b[pos + k]):
            k += 1
        if k == len(w):
            pos += len(w)
            return c
    return -1


def _day_names_abbr() -> List[StaticString]:
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]


def _day_names() -> List[StaticString]:
    return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]


def _month_names_abbr() -> List[StaticString]:
    return ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def _month_names() -> List[StaticString]:
    return [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    ]


# DuckDB's default fields (year 1900, January, day 1, midnight) in
# microseconds: the value of a format that sets no field.
comptime _DEFAULT_MICROS: Int64 = -2208988800000000


def strptime_parse(
    f: StrptimeFormat, b: Span[UInt8, _], try_mode: Bool
) -> StrptimeOutcome:
    """Match `b` against `f` as DuckDB's `strptime` (or, with `try_mode`,
    `try_strptime`) does.

    The two modes differ beyond NULL-for-error in one place, and the
    difference is DuckDB's: for the special texts `epoch` / `infinity`,
    strict strptime answers the Unix epoch / an infinite timestamp, while
    try_strptime answers the format's default fields (its
    conversion reads the parsed fields and not the special value)."""
    var size = len(b)
    var off = 0
    while off < size and _is_space(b[off]):
        off += 1
    if size - off > 4:
        var kind = 0
        var after = -1
        if _is_alpha(b[off]):
            after = _match_special(b, off, "infinity", 3)
            if after >= 0:
                kind = 1
            else:
                after = _match_special(b, off, "epoch", 5)
                if after >= 0:
                    kind = 2
        elif b[off] == UInt8(ord("-")):
            after = _match_special(b, off, "-infinity", 4)
            if after >= 0:
                kind = 1
        if kind != 0:
            while after < size and _is_space(b[after]):
                after += 1
            if after != size:
                return _fail(
                    "Special timestamp did not match: trailing characters", after - off
                )
            if try_mode:
                return StrptimeOutcome(TP_OK, _DEFAULT_MICROS, "", -1)
            if kind == 2:
                return StrptimeOutcome(TP_OK, 0, "", -1)
            return StrptimeOutcome(TP_INFINITE, 0, "", -1)

    var year = 1900
    var month = 1
    var day = 1
    var hour = 0
    var minute = 0
    var second = 0
    var micros = 0
    var ampm = 0  # 0 none, 1 AM, 2 PM
    var offset = _OFF_NONE
    var yearday = 0
    var pos = off
    var nspec = len(f.specs)
    for i in range(nspec + 1):
        var lit = f.literals[i].as_bytes()
        var l = 0
        while l < len(lit):
            if _is_space(lit[l]):
                if pos >= size or not _is_space(b[pos]):
                    return _fail(
                        "Space does not match, expected " + f.literals[i], pos - off
                    )
                pos += 1
                while pos < size and _is_space(b[pos]):
                    pos += 1
                l += 1
                while l < len(lit) and _is_space(lit[l]):
                    l += 1
                continue
            if pos >= size or b[pos] != lit[l]:
                return _fail(
                    "Literal does not match, expected " + f.literals[i], pos + 1 - off
                )
            pos += 1
            l += 1
        if i == nspec:
            break
        var spec = f.specs[i]
        var width = _width(spec)
        if width > 0:
            var start = pos
            var number = 0
            var digits = 0
            while pos < size and pos < start + width and _is_digit(b[pos]):
                number = number * 10 + Int(b[pos]) - 48
                pos += 1
                digits += 1
            if digits == 0:
                return _fail("Expected a number", start - off)
            if spec == SP_DAY:
                if number < 1 or number > 31:
                    return _fail(
                        "Day out of range, expected a value between 1 and 31", start - off
                    )
                day = number
                offset = _OFF_DM
            elif spec == SP_MONTH:
                if number < 1 or number > 12:
                    return _fail(
                        "Month out of range, expected a value between 1 and 12", start - off
                    )
                month = number
                offset = _OFF_DM
            elif spec == SP_YEAR2:
                if offset == _OFF_NONE:
                    offset = _OFF_Y
                year = 1900 + number if number >= 69 else 2000 + number
            elif spec == SP_YEAR4:
                if offset == _OFF_NONE:
                    offset = _OFF_Y
                year = number
            elif spec == SP_HOUR24:
                if number >= 24:
                    return _fail(
                        "Hour out of range, expected a value between 0 and 23", start - off
                    )
                hour = number
            elif spec == SP_HOUR12:
                if number < 1 or number > 12:
                    return _fail(
                        "Hour12 out of range, expected a value between 1 and 12", start - off
                    )
                hour = number
            elif spec == SP_MINUTE:
                if number >= 60:
                    return _fail(
                        "Minutes out of range, expected a value between 0 and 59", start - off
                    )
                minute = number
            elif spec == SP_SECOND:
                if number >= 60:
                    return _fail(
                        "Seconds out of range, expected a value between 0 and 59", start - off
                    )
                second = number
            elif spec == SP_MICRO or spec == SP_MILLI:
                # Fewer digits than the width are the leading ones: `.5` under
                # %f is 500000 microseconds.
                while digits < width:
                    number *= 10
                    digits += 1
                micros = number if spec == SP_MICRO else number * 1000
            else:
                # SP_YEARDAY. A month or day already read wins over it; a
                # second %j is an error.
                if offset == _OFF_J:
                    return _fail("Multiple year offsets specified", start - off)
                if offset != _OFF_DM:
                    offset = _OFF_J
                if number < 1 or number > 366:
                    return _fail(
                        "Year day out of range, expected a value between 1 and 366",
                        start - off,
                    )
                yearday = number
        elif spec == SP_AMPM:
            if pos + 2 > size:
                return _fail("Expected AM/PM", pos - off)
            var pa = _lower(b[pos])
            if _lower(b[pos + 1]) != UInt8(ord("m")):
                return _fail("Expected AM/PM", pos - off)
            if pa == UInt8(ord("p")):
                ampm = 2
            elif pa == UInt8(ord("a")):
                ampm = 1
            else:
                return _fail("Expected AM/PM", pos - off)
            pos += 2
        elif spec == SP_WDAY_ABBR:
            if _match_name(b, pos, _day_names_abbr()) < 0:
                return _fail(
                    "Expected an abbreviated day name (Mon, Tue, Wed, Thu, Fri, Sat, Sun)",
                    pos - off,
                )
        elif spec == SP_WDAY_FULL:
            if _match_name(b, pos, _day_names()) < 0:
                return _fail("Expected a full day name (Monday, Tuesday, etc...)", pos - off)
        elif spec == SP_MON_ABBR:
            var m = _match_name(b, pos, _month_names_abbr())
            if m < 0:
                return _fail(
                    "Expected an abbreviated month name (Jan, Feb, Mar, etc..)", pos - off
                )
            month = m + 1
        else:
            # SP_MON_FULL
            var m = _match_name(b, pos, _month_names())
            if m < 0:
                return _fail(
                    "Expected a full month name (January, February, etc...)", pos - off
                )
            month = m + 1
    while pos < size and _is_space(b[pos]):
        pos += 1
    if pos != size:
        return _fail("Full specifier did not match: trailing characters", pos - off)
    if ampm != 0:
        if hour > 12:
            return _fail(
                "Invalid hour: " + String(hour)
                + " AM/PM, expected an hour within the range [0..12]",
                -1,
            )
        if ampm == 1 and hour == 12:
            hour = 0
        elif ampm == 2 and hour != 12:
            hour += 12
    if offset == _OFF_J:
        var ymd = _civil_from_days(_days_from_civil(year, 1, 1) + yearday - 1)
        year = ymd[0]
        month = ymd[1]
        day = ymd[2]
    if not _date_is_valid(year, month, day):
        return StrptimeOutcome(
            TP_RANGE,
            0,
            "Conversion Error: Date out of range: " + String(year) + "-"
            + String(month) + "-" + String(day),
            -1,
        )
    # Every year a format can name (0-9999) is inside TIMESTAMP's range, so
    # this sum cannot overflow.
    var days = _days_from_civil(year, month, day)
    var time_us = ((hour * 60 + minute) * 60 + second) * 1000000 + micros
    return StrptimeOutcome(TP_OK, Int64(days * _MICROS_PER_DAY + time_us), "", -1)


def strptime_error(text: String, f: StrptimeFormat, o: StrptimeOutcome) -> String:
    """The message strict strptime raises for outcome `o` of `text`: DuckDB's
    text, with its caret line under the position the match failed at."""
    if o.status == TP_RANGE:
        return o.message
    if o.status == TP_INFINITE:
        return (
            "SQL not supported: strptime of \"" + text + "\" is an INFINITE"
            " TIMESTAMP in DuckDB, and an Arrow timestamp column has no"
            " infinite value to hold it."
        )
    var caret = String("")
    if o.position >= 0:
        caret = text + "\n"
        for _ in range(o.position):
            caret += " "
        caret += "^"
    return (
        "Invalid Input Error: Could not parse string \"" + text
        + "\" according to format specifier \"" + f.text + "\"\n" + caret
        + "\nError: " + o.message
    )


def strptime_column(
    sa: StringArray, f: StrptimeFormat, try_mode: Bool
) raises -> PrimitiveArray[DType.int64]:
    """`strptime(<text column>, <format>)` (`try_mode`: try_strptime) ->
    microseconds since the Unix epoch (Arrow TIMESTAMP_US).

    Null in -> null out. A row that does not match raises DuckDB's message
    in strict mode and is NULL in try mode."""
    var n = sa.length
    var out = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var o = strptime_parse(f, sa.get_span(i), try_mode)
        if o.status == TP_OK:
            out.set(i, Scalar[DType.int64](o.value))
        elif try_mode:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise Error(strptime_error(sa.get(i), f, o))
    out.null_count = nc
    return out^
