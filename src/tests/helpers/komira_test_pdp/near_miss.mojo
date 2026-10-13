# =============================================================================
# komira_test_pdp/near_miss.mojo: the values an exact string comparison must
#   tell apart from the one it expects.
# =============================================================================
#
# `near_misses(s)` returns, for an ASCII `s` of at least two bytes: its
# prefix one byte short, `s` extended at the end and at the front, its
# proper suffix one byte short, its case variant (upper case, or lower case
# when `s` has no lower-case letter), the empty string, and `s` with its
# first, middle and last byte replaced (same length). A comparison written
# as `startswith`, `endswith`, a case-insensitive match, a length check or
# a loop that skips the first, a middle or the last byte accepts at least
# one of them; `==` accepts none.
# =============================================================================


def _replace_byte(s: String, i: Int) -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for j in range(len(b)):
        if j == i:
            # A letter that is not the original, in either case.
            out.append(UInt8(0x71) if b[j] != 0x71 and b[j] != 0x51 else UInt8(0x7A))
        else:
            out.append(b[j])
    return String(unsafe_from_utf8=Span(out))


def near_misses(s: String) raises -> List[String]:
    """The near misses of `s` (module header). Raises when `s` is shorter
    than two bytes or not ASCII."""
    var n = s.byte_length()
    if n < 2:
        raise Error("near_misses: needs at least two bytes")
    var b = s.as_bytes()
    for i in range(n):
        if b[i] >= 0x80:
            raise Error("near_misses: needs ASCII")
    var out = List[String]()
    out.append(String(s[byte = 0 : n - 1]))
    out.append(s + "x")
    out.append(String("x") + s)
    out.append(String(s[byte=1:n]))
    var upper = s.upper()
    if upper == s:
        upper = s.lower()
    if upper != s:
        out.append(upper)
    out.append(String(""))
    out.append(_replace_byte(s, 0))
    out.append(_replace_byte(s, n // 2))
    out.append(_replace_byte(s, n - 1))
    return out^
