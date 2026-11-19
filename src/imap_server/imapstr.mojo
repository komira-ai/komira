# IMAP4rev1 syntax for the replies that carry text from a message: NIL,
# numbers, quoted strings and literals (RFC 3501 section 4.3). Text goes into
# a byte list, never a `String`: a header value can hold any byte.
#
# A string is sent quoted when it is 7-bit text without NUL, CR and LF, with a
# backslash before each `"` and `\`. Anything else (a byte over 0x7F, a NUL, a
# CR or an LF) is a literal, `{n}` CRLF and the n bytes, because a quoted
# string cannot hold it (RFC 3501 section 9, `quoted` and `TEXT-CHAR`).

comptime _DQUOTE: UInt8 = 0x22
comptime _BACKSLASH: UInt8 = 0x5C


def append_text(mut out: List[UInt8], text: String):
    out.extend(text.as_bytes())


def append_nil(mut out: List[UInt8]):
    out.extend(String("NIL").as_bytes())


def append_number(mut out: List[UInt8], n: Int):
    out.extend(String(n).as_bytes())


def needs_literal(s: Span[UInt8, _]) -> Bool:
    """True when `s` cannot go in a quoted string."""
    for i in range(len(s)):
        var c = s[i]
        if c == 0 or c == 0x0D or c == 0x0A or c > 0x7F:
            return True
    return False


def append_string(mut out: List[UInt8], s: Span[UInt8, _]):
    """`s` as a quoted string, or as a literal when it holds a byte a quoted
    string cannot."""
    if needs_literal(s):
        out.extend(String("{").as_bytes())
        append_number(out, len(s))
        out.extend(String("}\r\n").as_bytes())
        out.extend(s)
        return
    out.append(_DQUOTE)
    for i in range(len(s)):
        var c = s[i]
        if c == _DQUOTE or c == _BACKSLASH:
            out.append(_BACKSLASH)
        out.append(c)
    out.append(_DQUOTE)


def append_upper_string(mut out: List[UInt8], s: Span[UInt8, _]):
    """`s` upper-cased (ASCII), as a string."""
    var up = List[UInt8](capacity=len(s))
    for i in range(len(s)):
        var c = s[i]
        if c >= 0x61 and c <= 0x7A:
            c -= 32
        up.append(c)
    append_string(out, Span(up))


def append_nstring(mut out: List[UInt8], value: Optional[List[UInt8]]):
    """NIL when the value is absent, else the string (an empty value is
    `""`)."""
    if not value:
        append_nil(out)
        return
    append_string(out, Span(value.value()))
