# =============================================================================
# komira_mail_message/date_parse.mojo -- reading a `Date` value.
# =============================================================================
#
# `parse_date_time` reads RFC 5322 section 3.3 `date-time`, with the obsolete
# forms of section 4.3 that real mail still carries, and returns the instant
# in milliseconds since 1970-01-01T00:00:00Z (before 1970 it is negative).
#
#   [day-of-week ","] day month year hour ":" minute [":" second] zone
#
# - White space, line breaks and comments (nested, with `\` quoting) may stand
#   between any two tokens, before the first and after the last (a trailing
#   `(UTC)` is common). Names are case-insensitive.
# - The day-of-week, when present, must be a day name; it is not checked
#   against the date.
# - The year: 4 digits are the year (1900 or later); 2 digits are 2000 + the
#   value below 50 and 1900 + the value from 50; 3 digits are 1900 + the
#   value (RFC 5322 section 4.3). Any other digit count is refused.
# - The day must exist in its month: 29 February needs a leap year. The
#   hour is 0..23, the minute 0..59, the second 0..60 (60 is a leap second:
#   it reads as the first second of the next minute).
# - The zone is `+hhmm` or `-hhmm` (minutes 0..59), or a name: UT, UTC, GMT,
#   Z (offset 0), EST, EDT, CST, CDT, MST, MDT, PST, PDT (their US offsets);
#   any other alphabetic name, including the military letters, reads as
#   `-0000`, an offset of 0 (section 4.3: a zone whose meaning is not known
#   SHOULD be considered equivalent to `-0000`). A date with no zone is
#   refused.
#
# Anything else raises `Syntax` ("parse_date_time: what, at position n"); the
# error never holds the input.
# =============================================================================

from komira_datetime import days_from_civil, days_in_month

from .chars import BACKSLASH, COLON, HYPHEN, LF, LPAREN, RPAREN, is_alpha, is_digit, is_wsp, lower
from .errors import SYNTAX, message_error

comptime _FN: StaticString = "parse_date_time"
comptime _DAYS: StaticString = "montuewedthufrisatsun"
comptime _MONTHS: StaticString = "janfebmaraprmayjunjulaugsepoctnovdec"
comptime _PLUS: UInt8 = 43
comptime _COMMA: UInt8 = 44
comptime _MAX_TOKENS = 16

comptime _NUM = 0
comptime _WORD = 1
comptime _SYM = 2


struct _Tok(Copyable, Movable):
    var kind: Int
    var start: Int
    var end: Int
    var value: Int  # _NUM: the number; _SYM: the byte

    def __init__(out self, kind: Int, start: Int, end: Int, value: Int):
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value

    def width(self) -> Int:
        return self.end - self.start


def _fail(what: StaticString, position: Int) -> Error:
    return message_error(SYNTAX, _FN, what, position)


def _tokens(text: Span[UInt8, _]) raises -> List[_Tok]:
    """The tokens of `text`: digit runs, letter runs and the symbols
    `, : + -`; white space and comments are skipped."""
    var toks = List[_Tok]()
    var n = len(text)
    var i = 0
    while i < n:
        var c = text[i]
        if is_wsp(c) or c == 13 or c == LF:
            i += 1
        elif c == LPAREN:
            var open = i
            var depth = 0
            while i < n:
                if text[i] == BACKSLASH:
                    i += 1
                elif text[i] == LPAREN:
                    depth += 1
                elif text[i] == RPAREN:
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            if i >= n:
                raise _fail("a comment that is not closed", open)
            i += 1
        else:
            if len(toks) >= _MAX_TOKENS:
                raise _fail("more tokens than a date holds", i)
            if is_digit(c):
                var start = i
                var value = 0
                while i < n and is_digit(text[i]):
                    if i - start >= 9:
                        raise _fail("a number of more than 9 digits", start)
                    value = value * 10 + Int(text[i] - 48)
                    i += 1
                toks.append(_Tok(_NUM, start, i, value))
            elif is_alpha(c):
                var start = i
                while i < n and is_alpha(text[i]):
                    i += 1
                toks.append(_Tok(_WORD, start, i, 0))
            elif c == _COMMA or c == COLON or c == _PLUS or c == HYPHEN:
                toks.append(_Tok(_SYM, i, i + 1, Int(c)))
                i += 1
            else:
                raise _fail("a byte not allowed in a date", i)
    return toks^


def _name_index(text: Span[UInt8, _], tok: _Tok, names: StaticString) -> Int:
    """The index of the 3-letter word `tok` in `names` (lower case, 3 letters
    each), or -1."""
    if tok.kind != _WORD or tok.width() != 3:
        return -1
    var nb = names.as_bytes()
    for k in range(len(nb) // 3):
        var same = True
        for j in range(3):
            if lower(text[tok.start + j]) != nb[k * 3 + j]:
                same = False
                break
        if same:
            return k
    return -1


def _word_is(text: Span[UInt8, _], tok: _Tok, name: StaticString) -> Bool:
    var nb = name.as_bytes()
    if tok.width() != len(nb):
        return False
    for j in range(len(nb)):
        if lower(text[tok.start + j]) != nb[j]:
            return False
    return True


def _zone_name_minutes(text: Span[UInt8, _], tok: _Tok) -> Int:
    if _word_is(text, tok, "est"):
        return -300
    if _word_is(text, tok, "edt"):
        return -240
    if _word_is(text, tok, "cst"):
        return -360
    if _word_is(text, tok, "cdt"):
        return -300
    if _word_is(text, tok, "mst"):
        return -420
    if _word_is(text, tok, "mdt"):
        return -360
    if _word_is(text, tok, "pst"):
        return -480
    if _word_is(text, tok, "pdt"):
        return -420
    return 0  # UT, UTC, GMT, Z, a military letter, any unknown name


def parse_date_time(text: Span[UInt8, _]) raises -> Int:
    """`text` as an RFC 5322 `date-time`, in milliseconds since 1970; see the
    module header for the accepted forms."""
    var t = _tokens(text)
    var n = len(t)
    var i = 0
    if n >= 2 and t[1].kind == _SYM and t[1].value == Int(_COMMA):
        if _name_index(text, t[0], _DAYS) < 0:
            raise _fail("a day-of-week that is not a day name", t[0].start)
        i = 2
    if i >= n or t[i].kind != _NUM:
        raise _fail("a day that is not a number", t[i].start if i < n else len(text))
    var day = t[i].value
    if t[i].width() > 2:
        raise _fail("a day of more than 2 digits", t[i].start)
    i += 1
    if i >= n:
        raise _fail("a date that ends before the month", len(text))
    var month = _name_index(text, t[i], _MONTHS) + 1
    if month == 0:
        raise _fail("a month that is not a month name", t[i].start)
    i += 1
    if i >= n or t[i].kind != _NUM:
        raise _fail("a year that is not a number", t[i].start if i < n else len(text))
    var year = t[i].value
    var year_digits = t[i].width()
    if year_digits == 2:
        year += 2000 if year < 50 else 1900
    elif year_digits == 3:
        year += 1900
    elif year_digits != 4 or year < 1900:
        raise _fail("a year that is not 2, 3 or 4 digits, or before 1900", t[i].start)
    if day < 1 or day > days_in_month(year, month):
        raise _fail("a day that is not in its month", t[i - 2].start)
    i += 1
    # hour ":" minute [":" second]
    if i + 2 >= n or t[i].kind != _NUM or t[i].width() > 2:
        raise _fail("a time that does not start with an hour", t[i].start if i < n else len(text))
    var hour = t[i].value
    if t[i + 1].kind != _SYM or t[i + 1].value != Int(COLON):
        raise _fail("an hour not followed by ':'", t[i + 1].start)
    if t[i + 2].kind != _NUM or t[i + 2].width() != 2:
        raise _fail("a minute that is not 2 digits", t[i + 2].start)
    var minute = t[i + 2].value
    var second = 0
    i += 3
    if i < n and t[i].kind == _SYM and t[i].value == Int(COLON):
        if i + 1 >= n or t[i + 1].kind != _NUM or t[i + 1].width() != 2:
            raise _fail("a second that is not 2 digits", t[i].start)
        second = t[i + 1].value
        i += 2
    if hour > 23 or minute > 59 or second > 60:
        raise _fail("a time outside 00:00:00..23:59:60", t[i - 1].start)
    # zone
    if i >= n:
        raise _fail("a date with no zone", len(text))
    var offset_minutes = 0
    if t[i].kind == _SYM and (t[i].value == Int(_PLUS) or t[i].value == Int(HYPHEN)):
        if i + 1 >= n or t[i + 1].kind != _NUM or t[i + 1].width() != 4:
            raise _fail("a numeric zone that is not 4 digits", t[i].start)
        var hh = t[i + 1].value // 100
        var mm = t[i + 1].value % 100
        if mm > 59:
            raise _fail("a zone with minutes over 59", t[i + 1].start)
        offset_minutes = hh * 60 + mm
        if t[i].value == Int(HYPHEN):
            offset_minutes = -offset_minutes
        i += 2
    elif t[i].kind == _WORD:
        offset_minutes = _zone_name_minutes(text, t[i])
        i += 1
    else:
        raise _fail("a zone that is neither numeric nor a name", t[i].start)
    if i < n:
        raise _fail("text after the zone", t[i].start)
    var seconds = (
        days_from_civil(year, month, day) * 86400
        + hour * 3600
        + minute * 60
        + second
        - offset_minutes * 60
    )
    return seconds * 1000
