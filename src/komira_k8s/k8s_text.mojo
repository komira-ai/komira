# =============================================================================
# komira_k8s/k8s_text.mojo — owning byte<->String + small string helpers
# =============================================================================
#
# Shared text utilities for the K8s client. The load-bearing one is
# `owned_utf8_string`: a conversion that BORROWS a dropping local's heap buffer
# instead of copying it produces a dangling String whose leading bytes get
# clobbered after the local drops. Every byte->String conversion in this
# package goes through an owning copy.
# =============================================================================


def owned_utf8_string(bytes: List[UInt8]) -> String:
    """Build an OWNED String from `bytes`, interpreting them as raw UTF-8 and
    preserving every byte VERBATIM.

    Do NOT use `chr(Int(b))` accumulation: `chr(b)` for any byte >= 0x80 emits
    the CODEPOINT U+00XX as 2-byte UTF-8, double-encoding every multi-byte
    UTF-8 sequence. `String(StringSlice(unsafe_from_utf8=Span(bytes)))` COPIES
    the bytes into a new owned String buffer (does NOT adopt/alias the input),
    so it preserves the bytes verbatim AND returns an owned String that
    survives the caller's local `bytes` dropping."""
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def owned_utf8_from_span(bytes: Span[UInt8, _]) -> String:
    """Owned-String build from a Span (same verbatim-bytes + owned-copy
    guarantee as owned_utf8_string)."""
    return String(StringSlice(unsafe_from_utf8=bytes))


def strip_trailing_ws(s: String) -> String:
    """Trim trailing whitespace/newlines. The namespace file carries a trailing
    newline in some clusters; the SA token does not. Returns an owned copy."""
    var bs = s.as_bytes()
    var n = len(bs)
    while n > 0:
        var c = bs[n - 1]
        if (
            c == UInt8(ord(" "))
            or c == UInt8(0x0A)
            or c == UInt8(0x0D)
            or c == UInt8(0x09)
        ):
            n -= 1
        else:
            break
    var out = String()
    for i in range(n):
        out += chr(Int(bs[i]))
    return out^


def str_find(s: String, needle: String) -> Int:
    """Index of the first occurrence of `needle` in `s`, or -1. Byte-wise."""
    var hb = s.as_bytes()
    var nb = needle.as_bytes()
    var hn = len(hb)
    var nn = len(nb)
    if nn == 0:
        return 0
    var i = 0
    while i + nn <= hn:
        var matched = True
        for j in range(nn):
            if hb[i + j] != nb[j]:
                matched = False
                break
        if matched:
            return i
        i += 1
    return -1


def str_contains(s: String, needle: String) -> Bool:
    return str_find(s, needle) >= 0


def str_substr(s: String, start: Int, end: Int) -> String:
    """Owned substring `s[start:end]` (byte indices, clamped)."""
    var bs = s.as_bytes()
    var n = len(bs)
    var lo = start if start > 0 else 0
    var hi = end if end < n else n
    var out = String()
    var i = lo
    while i < hi:
        out += chr(Int(bs[i]))
        i += 1
    return out^


def json_escape(s: String) -> String:
    """Escape a string for embedding in a JSON string literal. Handles the
    characters K8s manifest values can contain (quotes, backslashes, control
    chars). Returns the escaped body WITHOUT surrounding quotes."""
    var out = String()
    for b in s.as_bytes():
        var c = Int(b)
        if c == ord('"'):
            out += '\\"'
        elif c == ord("\\"):
            out += "\\\\"
        elif c == 0x08:
            out += "\\b"
        elif c == 0x0C:
            out += "\\f"
        elif c == 0x0A:
            out += "\\n"
        elif c == 0x0D:
            out += "\\r"
        elif c == 0x09:
            out += "\\t"
        elif c < 0x20:
            # Other control chars -> \u00XX
            out += "\\u00"
            var hi = (c >> 4) & 0xF
            var lo = c & 0xF
            out += _hex_digit(hi)
            out += _hex_digit(lo)
        else:
            out += chr(c)
    return out^


def _hex_digit(v: Int) -> String:
    if v < 10:
        return chr(ord("0") + v)
    return chr(ord("a") + (v - 10))
