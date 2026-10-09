# =============================================================================
# komira_mail_message/fold.mojo -- writing one header field, folded.
# =============================================================================
#
# `append_field` writes `Name: value` CRLF. The value is cut before the last
# white space byte of each white space run (the only place RFC 5322 section
# 2.2.3 lets a CRLF go without changing the unfolded value, and never leaving
# a line of white space only). Pieces are packed onto lines of at most 76
# characters (the RFC 2047 section 2 limit for a line holding an encoded word,
# under RFC 5322's recommended 78). A piece that does not fit starts a new
# line; a piece longer than the line stays whole, and a line that would then
# exceed RFC 5322's 998-octet limit is refused as `LineTooLong` (so is a
# `Name: ` prefix over 998 octets, whatever the value). The caller has
# refused CR, LF and NUL in the value.
# =============================================================================

from .chars import COLON, SP, append_bytes, append_crlf, append_range, is_wsp
from .errors import LINE_TOO_LONG, message_error

comptime FOLD_AT = 76
"""The longest line the folder writes when the value can be cut."""

comptime LINE_MAX = 998
"""RFC 5322 section 2.1.1: a line is at most 998 octets without its CRLF."""


def _too_long(function: StaticString) -> Error:
    return message_error(
        LINE_TOO_LONG,
        function,
        "a header line longer than 998 octets with no white space to fold at",
    )


def append_field(
    mut out: List[UInt8],
    name: Span[UInt8, _],
    value: Span[UInt8, _],
    function: StaticString,
) raises:
    """Append the header field `name: value` and its CRLF, folded as the
    module header describes."""
    append_bytes(out, name)
    out.append(COLON)
    out.append(SP)
    var line = len(name) + 2
    if line > LINE_MAX:
        raise _too_long(function)
    var n = len(value)
    var on_line = 0
    var start = 0
    while start < n:
        # A piece is [start, end): it starts at a cut (or at 0) and runs to
        # the next cut, the last white space byte of a run.
        var end = start + 1
        while end < n:
            if is_wsp(value[end]) and end + 1 < n and not is_wsp(value[end + 1]):
                break
            end += 1
        var width = end - start
        if on_line > 0 and line + width > FOLD_AT:
            append_crlf(out)
            line = 0
            on_line = 0
        if line + width > LINE_MAX:
            raise _too_long(function)
        append_range(out, value, start, end)
        line += width
        on_line += 1
        start = end
    append_crlf(out)
