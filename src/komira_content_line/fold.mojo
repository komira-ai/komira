# =============================================================================
# fold.mojo -- logical line to folded physical lines (RFC 6350 §3.2, RFC
# 5545 §3.1).
# =============================================================================
#
# Every physical line is at most `FOLD_OCTETS` (75) octets, not counting its
# CRLF; the SPACE that starts a continuation line counts. A fold never falls
# inside a multi-octet UTF-8 sequence: the cut moves back to the start of the
# sequence. The result ends with CRLF.
# =============================================================================


comptime FOLD_OCTETS: Int = 75


@always_inline
def _is_continuation(c: UInt8) -> Bool:
    return (c & 0xC0) == 0x80


def fold_line(line: String) -> String:
    """`line` folded at 75 octets, ending with CRLF (file header)."""
    var b = line.as_bytes()
    var n = len(b)
    var out = String()
    var start = 0
    var width = FOLD_OCTETS
    while n - start > width:
        var cut = start + width
        while cut > start + 1 and _is_continuation(b[cut]):
            cut -= 1
        if start > 0:
            out += " "
        out += String(line[byte=start:cut])
        out += "\r\n"
        start = cut
        width = FOLD_OCTETS - 1
    if start > 0:
        out += " "
    out += String(line[byte=start:n])
    out += "\r\n"
    return out^
