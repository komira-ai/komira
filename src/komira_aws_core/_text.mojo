# =============================================================================
# komira_aws_core/_text.mojo -- byte-level string helpers for the providers
# =============================================================================
#
# Package-private. Every cut is at an ASCII byte, so each result is valid
# UTF-8 when its input is.
# =============================================================================


comptime _SP = UInt8(0x20)
comptime _TAB = UInt8(0x09)
comptime _CR = UInt8(0x0D)
comptime _LF = UInt8(0x0A)


def sub(s: String, i: Int, j: Int) -> String:
    """Bytes [i, j) of `s`, clamped."""
    var b = s.as_bytes()
    var lo = max(0, min(i, len(b)))
    var hi = max(lo, min(j, len(b)))
    return String(StringSlice(unsafe_from_utf8=b[lo:hi]))


def is_space(c: UInt8) -> Bool:
    return c == _SP or c == _TAB or c == _CR or c == _LF


def trim(s: String) -> String:
    """`s` without leading and trailing spaces, tabs, CR and LF."""
    var b = s.as_bytes()
    var lo = 0
    var hi = len(b)
    while lo < hi and is_space(b[lo]):
        lo += 1
    while hi > lo and is_space(b[hi - 1]):
        hi -= 1
    return sub(s, lo, hi)


def ascii_lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def has_crlf(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == _CR or b[i] == _LF:
            return True
    return False


def has_control(s: String) -> Bool:
    """True when `s` holds a byte below 0x20 or DEL."""
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] < _SP or b[i] == UInt8(0x7F):
            return True
    return False


def split_lines(s: String) -> List[String]:
    """`s` split at LF, with a trailing CR dropped from each line."""
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == _LF:
            var end = i
            if end > start and b[end - 1] == _CR:
                end -= 1
            if i < len(b) or end > start:
                out.append(sub(s, start, end))
            start = i + 1
    return out^


def is_true_flag(v: String) -> Bool:
    """The AWS SDK boolean spelling: "true", case-insensitive."""
    return ascii_lower(trim(v)) == "true"
