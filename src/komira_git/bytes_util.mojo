# =============================================================================
# komira_git/bytes_util.mojo -- byte helpers shared by the object parsers.
# =============================================================================
#
# Git object fields (names, e-mail addresses, messages, tree entry names) are
# byte strings that need not be UTF-8, so the parsers work on `Span[UInt8]`
# and keep fields as `List[UInt8]`. Everything here is package-private
# (underscore-prefixed) and is not re-exported from `__init__.mojo`.
# =============================================================================

comptime _B_NUL: Int = 0
comptime _B_LF: Int = 10
comptime _B_SPACE: Int = 32
comptime _B_0: Int = 48
comptime _B_9: Int = 57


def _append_str(mut out: List[UInt8], s: String):
    """Append the bytes of `s`."""
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])


def _append_span(mut out: List[UInt8], s: Span[UInt8, _]):
    """Append every byte of `s`."""
    for i in range(len(s)):
        out.append(s[i])


def _append_decimal(mut out: List[UInt8], v: Int):
    """Append the decimal digits of `v` (v >= 0), no padding."""
    _append_str(out, String(v))


def _find_byte(s: Span[UInt8, _], start: Int, b: Int) -> Int:
    """The index of the first byte equal to `b` at or after `start`, or -1."""
    for i in range(start, len(s)):
        if Int(s[i]) == b:
            return i
    return -1


def _starts_with(s: Span[UInt8, _], at: Int, prefix: String) -> Bool:
    """True when `s[at:]` begins with the bytes of `prefix`."""
    var p = prefix.as_bytes()
    if at + len(p) > len(s):
        return False
    for i in range(len(p)):
        if s[at + i] != p[i]:
            return False
    return True


def _to_list(s: Span[UInt8, _], start: Int, end: Int) -> List[UInt8]:
    """A copy of `s[start:end]`."""
    var out = List[UInt8](capacity=end - start)
    for i in range(start, end):
        out.append(s[i])
    return out^


def _bytes_equal(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Byte-for-byte equality."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _is_digit(c: Int) -> Bool:
    return c >= _B_0 and c <= _B_9


def _hex_value(c: Int) -> Int:
    """The value of one hex digit in either case, or -1."""
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def _hex_digit(v: Int) -> String:
    """One lowercase hex digit for v in [0, 16)."""
    if v < 10:
        return chr(48 + v)
    return chr(87 + v)


def _parse_decimal(
    s: Span[UInt8, _], start: Int, end: Int, what: String
) raises -> Int:
    """`s[start:end]` as a non-negative decimal: one or more digits, no sign,
    no leading zero (unless the number is `0`), and at most 18 digits so it
    fits an Int64. `what` prefixes the refusal."""
    var n = end - start
    if n <= 0:
        raise Error(what + ": empty number")
    if n > 18:
        raise Error(what + ": number of " + String(n) + " digits overflows")
    if n > 1 and Int(s[start]) == _B_0:
        raise Error(what + ": number has a leading zero")
    var v = 0
    for i in range(start, end):
        var c = Int(s[i])
        if not _is_digit(c):
            raise Error(what + ": non-digit byte " + String(c) + " in number")
        v = v * 10 + (c - _B_0)
    return v
