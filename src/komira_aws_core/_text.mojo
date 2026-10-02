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


def _is_cont(c: UInt8) -> Bool:
    return (c & UInt8(0xC0)) == UInt8(0x80)


def utf8_valid(b: Span[UInt8, _]) -> Bool:
    """True when `b` is well-formed UTF-8 (RFC 3629): no overlong form, no
    surrogate, nothing above U+10FFFF, no truncated sequence."""
    var i = 0
    var n = len(b)
    while i < n:
        var c = b[i]
        if c < UInt8(0x80):
            i += 1
            continue
        var need: Int
        var lo = UInt8(0x80)
        var hi = UInt8(0xBF)
        if c >= UInt8(0xC2) and c <= UInt8(0xDF):
            need = 1
        elif c >= UInt8(0xE0) and c <= UInt8(0xEF):
            need = 2
            if c == UInt8(0xE0):
                lo = UInt8(0xA0)
            elif c == UInt8(0xED):
                hi = UInt8(0x9F)
        elif c >= UInt8(0xF0) and c <= UInt8(0xF4):
            need = 3
            if c == UInt8(0xF0):
                lo = UInt8(0x90)
            elif c == UInt8(0xF4):
                hi = UInt8(0x8F)
        else:
            return False
        if i + need >= n:
            return False
        var c1 = b[i + 1]
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            if not _is_cont(b[i + k]):
                return False
        i += need + 1
    return True


def utf8_text(b: Span[UInt8, _], what: String) raises -> String:
    """`b` as a String. Refuses bytes that are not well-formed UTF-8, naming
    `what` and nothing of the bytes (a body can hold a secret)."""
    if not utf8_valid(b):
        raise Error(what + " is not well-formed UTF-8")
    return String(unsafe_from_utf8=b)


def bytes_of(s: String) -> List[UInt8]:
    """The UTF-8 bytes of `s`."""
    var out = List[UInt8](capacity=s.byte_length())
    out.extend(Span(s.as_bytes()))
    return out^


def nan64() -> Float64:
    var z = Float64(0.0)
    return z / z


def inf64() -> Float64:
    var z = Float64(0.0)
    return Float64(1.0) / z
