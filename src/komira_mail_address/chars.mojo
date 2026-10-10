# =============================================================================
# komira_mail_address/chars.mojo -- byte classes, the input check, quoting.
# =============================================================================
#
# Byte classes are RFC 5322 section 3.2.3 (`atext`), 3.2.2 (`ctext`, here the
# bytes 33..126 other than `(`, `)` and `\`, which the comment scanner
# handles first) and 3.2.4 (`qtext`), RFC 5234 `WSP` and `VCHAR`.
#
# `check_input` is the first thing every parser runs: it refuses CR, LF and
# NUL (`ForbiddenByte`) and any byte at or above 0x80 (`NonAscii`), naming the
# first one. Every later step may therefore treat the input as ASCII, and
# every `String` the package builds holds only bytes from it or ASCII
# punctuation.
# =============================================================================

from .errors import FORBIDDEN_BYTE, NON_ASCII, address_error

comptime HTAB: UInt8 = 9
comptime LF: UInt8 = 10
comptime CR: UInt8 = 13
comptime SP: UInt8 = 32
comptime DQUOTE: UInt8 = 34
comptime LPAREN: UInt8 = 40
comptime RPAREN: UInt8 = 41
comptime COMMA: UInt8 = 44
comptime HYPHEN: UInt8 = 45
comptime DOT: UInt8 = 46
comptime COLON: UInt8 = 58
comptime SEMI: UInt8 = 59
comptime LT: UInt8 = 60
comptime GT: UInt8 = 62
comptime AT: UInt8 = 64
comptime LBRACKET: UInt8 = 91
comptime BACKSLASH: UInt8 = 92


@always_inline
def is_wsp(c: UInt8) -> Bool:
    """RFC 5234 `WSP`: space or horizontal tab."""
    return c == SP or c == HTAB


@always_inline
def is_vchar(c: UInt8) -> Bool:
    """RFC 5234 `VCHAR`: 33..126."""
    return c >= 33 and c <= 126


@always_inline
def is_alpha(c: UInt8) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


@always_inline
def is_digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def is_atext(c: UInt8) -> Bool:
    """RFC 5322 `atext`: letters, digits and ``!#$%&'*+-/=?^_`{|}~``."""
    if is_alpha(c) or is_digit(c):
        return True
    return (
        c == 33  # !
        or (c >= 35 and c <= 39)  # # $ % & '
        or c == 42  # *
        or c == 43  # +
        or c == 45  # -
        or c == 47  # /
        or c == 61  # =
        or c == 63  # ?
        or (c >= 94 and c <= 96)  # ^ _ `
        or (c >= 123 and c <= 126)  # { | } ~
    )


@always_inline
def is_qtext(c: UInt8) -> Bool:
    """RFC 5322 `qtext`: 33, 35..91, 93..126 (not `"` or `\\`)."""
    return c == 33 or (c >= 35 and c <= 91) or (c >= 93 and c <= 126)


def check_input(data: Span[UInt8, _], function: StaticString) raises:
    """Refuse the first CR, LF or NUL, or byte at or above 0x80."""
    for i in range(len(data)):
        var c = data[i]
        if c == CR or c == LF or c == 0:
            raise address_error(FORBIDDEN_BYTE, function, "CR, LF or NUL", i)
        if c >= 128:
            raise address_error(
                NON_ASCII,
                function,
                "a byte above 0x7F (SMTPUTF8 and IDNA are not supported)",
                i,
            )


def ascii_string(bytes: List[UInt8]) -> String:
    """A `String` of `bytes`. Every caller passes only ASCII bytes (input that
    passed `check_input`, or ASCII punctuation), which is valid UTF-8."""
    return String(unsafe_from_utf8=Span(bytes))


def is_dot_atom_text(s: Span[UInt8, _]) -> Bool:
    """RFC 5322 `dot-atom-text`: one or more atoms of `atext` joined by single
    dots, with no dot at either end."""
    var n = len(s)
    if n == 0:
        return False
    var run = 0
    for i in range(n):
        var c = s[i]
        if c == DOT:
            if run == 0:
                return False
            run = 0
        elif is_atext(c):
            run += 1
        else:
            return False
    return run > 0


def append_quoted(mut out: List[UInt8], content: Span[UInt8, _]):
    """Append `content` as an RFC 5322 / RFC 5321 quoted string: wrapped in
    `"`, with a backslash before each `"` and `\\` and no other escape."""
    out.append(DQUOTE)
    for i in range(len(content)):
        var c = content[i]
        if c == DQUOTE or c == BACKSLASH:
            out.append(BACKSLASH)
        out.append(c)
    out.append(DQUOTE)


def is_atom_phrase(s: Span[UInt8, _]) -> Bool:
    """True when `s` is atoms of `atext` joined by single spaces, so it can be
    written as a display name without quotes."""
    var n = len(s)
    if n == 0:
        return False
    var run = 0
    for i in range(n):
        var c = s[i]
        if c == SP:
            if run == 0:
                return False
            run = 0
        elif is_atext(c):
            run += 1
        else:
            return False
    return run > 0


def append_phrase(mut out: List[UInt8], phrase: Span[UInt8, _]):
    """Append a display name: as it is when it is an atom phrase, else as a
    quoted string."""
    if is_atom_phrase(phrase):
        for i in range(len(phrase)):
            out.append(phrase[i])
    else:
        append_quoted(out, phrase)


def append_str(mut out: List[UInt8], s: StaticString):
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
