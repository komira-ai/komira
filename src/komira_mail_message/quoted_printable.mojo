# =============================================================================
# komira_mail_message/quoted_printable.mojo -- RFC 2045 section 6.7.
# =============================================================================
#
# Encoding writes CRLF as a hard line break and every other byte as itself
# when it is printable ASCII other than `=` (rule 2), a space or tab as itself
# unless it would end a line (rule 3), and anything else as `=XX` in upper
# case hex (rule 1). Lines are at most 76 characters: a soft line break (`=`
# CRLF, rule 5) is written before a character that would not fit. A CR or LF
# that is not part of a CRLF pair is written `=0D` / `=0A`.
#
# Decoding is lenient, as section 6.7 suggests: white space at the end of a
# line is dropped (rule 3), `=` at the end of a line is a soft break, `=XX`
# (either case) is the byte, and an `=` followed by anything else is kept as
# it is. A line break is CRLF or a bare LF and is kept as written.
# =============================================================================

from .chars import CR, EQ, HTAB, LF, SP, append_crlf, append_hex, hex_value, is_wsp

comptime QP_LINE_MAX = 76
"""RFC 2045 section 6.7 rule 5: encoded lines are at most 76 characters."""


def _is_crlf_at(data: Span[UInt8, _], i: Int) -> Bool:
    return i + 1 < len(data) and data[i] == CR and data[i + 1] == LF


def _ends_line_after(data: Span[UInt8, _], i: Int) -> Bool:
    """True when the byte at `i` is the last of the data or of its line."""
    return i + 1 == len(data) or _is_crlf_at(data, i + 1)


def quoted_printable_encode(data: Span[UInt8, _]) -> List[UInt8]:
    """`data` in quoted-printable; see the module header."""
    var n = len(data)
    var out = List[UInt8](capacity=n + n // 8 + 8)
    var line = 0
    var i = 0
    while i < n:
        if _is_crlf_at(data, i):
            append_crlf(out)
            line = 0
            i += 2
            continue
        var c = data[i]
        var literal: Bool
        if c == SP or c == HTAB:
            literal = not _ends_line_after(data, i)
        else:
            literal = c >= 33 and c <= 126 and c != EQ
        var width = 1 if literal else 3
        # A character that ends its line may use column 76; any other
        # must leave room for the `=` of a soft break.
        var room = QP_LINE_MAX if _ends_line_after(data, i) else QP_LINE_MAX - 1
        if line + width > room:
            out.append(EQ)
            append_crlf(out)
            line = 0
        if literal:
            out.append(c)
        else:
            append_hex(out, c, EQ)
        line += width
        i += 1
    return out^


def quoted_printable_decode(data: Span[UInt8, _]) -> List[UInt8]:
    """The bytes `data` encodes; see the module header. Never fails."""
    var n = len(data)
    var out = List[UInt8](capacity=n)
    var start = 0
    while start < n:
        # One line: content [start, content_end), break [content_end, next).
        var end = start
        while end < n and data[end] != LF:
            end += 1
        var content_end = end
        if end < n and end > start and data[end - 1] == CR:
            content_end = end - 1
        var next = end + 1 if end < n else n
        while content_end > start and is_wsp(data[content_end - 1]):
            content_end -= 1
        var soft = False
        var i = start
        while i < content_end:
            var c = data[i]
            if c == EQ:
                if i + 1 == content_end:
                    soft = True
                    i += 1
                    continue
                if i + 2 < content_end:
                    var hi = hex_value(data[i + 1])
                    var lo = hex_value(data[i + 2])
                    if hi >= 0 and lo >= 0:
                        out.append(UInt8(hi * 16 + lo))
                        i += 3
                        continue
            out.append(c)
            i += 1
        if not soft:
            for k in range(content_end, next):
                if not is_wsp(data[k]):
                    out.append(data[k])
        start = next
    return out^
