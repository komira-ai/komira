# =============================================================================
# utf8_check — refuse a byte span that is not well-formed UTF-8
# =============================================================================
#
# RFC 8259 §8.1: JSON text exchanged between systems MUST be UTF-8. Every
# `String` this package builds from input bytes (`parse_string_raw`,
# `parse_string_with_escapes`, the `json_extract` kernel's raw slices) is
# built with an unchecked constructor, so the span is checked here first:
# a `String` holding ill-formed UTF-8 breaks the invariant every `String`
# operation relies on.
#
# Well-formed means RFC 3629 / Unicode Table 3-7: no stray continuation byte,
# no overlong form, no UTF-16 surrogate (U+D800-U+DFFF) encoded in UTF-8,
# nothing above U+10FFFF, no truncated sequence.
#
# One linear pass over the span. ASCII bytes take a single comparison; only a
# byte >= 0x80 enters the sequence check.
# =============================================================================


@always_inline
def _hex_digit(n: UInt8) -> UInt8:
    """One nibble (0-15) as an upper-case ASCII hex digit."""
    if n < UInt8(10):
        return UInt8(ord("0")) + n
    return UInt8(ord("A")) + n - UInt8(10)


def _hex_byte(b: UInt8) -> String:
    """`b` as `0x` plus two upper-case hex digits."""
    var out = List[UInt8](capacity=4)
    out.append(UInt8(ord("0")))
    out.append(UInt8(ord("x")))
    out.append(_hex_digit(b >> 4))
    out.append(_hex_digit(b & 0x0F))
    # All four bytes are ASCII.
    return String(unsafe_from_utf8=Span(out))


def _utf8_error_at(bytes: Span[UInt8, _], i: Int, end: Int) -> String:
    """The reason the sequence starting at `bytes[i]` is ill-formed, or the
    empty string when it is a well-formed sequence. `i < end` holds."""
    var c = bytes[i]
    if c < UInt8(0x80):
        return String()
    if c < UInt8(0xC0):
        return "stray continuation byte " + _hex_byte(c)
    if c < UInt8(0xC2):
        return "overlong encoding: lead byte " + _hex_byte(c)
    if c >= UInt8(0xF5) and c <= UInt8(0xF7):
        return "code point above U+10FFFF: lead byte " + _hex_byte(c)
    if c > UInt8(0xF4):
        return "invalid lead byte " + _hex_byte(c)
    var need: Int
    var lo = UInt8(0x80)
    var hi = UInt8(0xBF)
    if c < UInt8(0xE0):
        need = 1
    elif c < UInt8(0xF0):
        need = 2
        if c == UInt8(0xE0):
            lo = UInt8(0xA0)
        elif c == UInt8(0xED):
            hi = UInt8(0x9F)
    else:
        need = 3
        if c == UInt8(0xF0):
            lo = UInt8(0x90)
        elif c == UInt8(0xF4):
            hi = UInt8(0x8F)
    for k in range(1, need + 1):
        if i + k >= end:
            return (
                "truncated "
                + String(need + 1)
                + "-byte sequence: lead byte "
                + _hex_byte(c)
                + " has "
                + String(k - 1)
                + " of "
                + String(need)
                + " continuation byte(s)"
            )
        var ck = bytes[i + k]
        if ck < UInt8(0x80) or ck > UInt8(0xBF):
            return (
                "lead byte "
                + _hex_byte(c)
                + " is followed by "
                + _hex_byte(ck)
                + ", which is not a continuation byte"
            )
        if k == 1 and (ck < lo or ck > hi):
            var pair = _hex_byte(c) + " " + _hex_byte(ck)
            if c == UInt8(0xED):
                return "UTF-16 surrogate encoded in UTF-8: " + pair
            if c == UInt8(0xF4):
                return "code point above U+10FFFF: " + pair
            return "overlong encoding: " + pair
    return String()


@always_inline
def _utf8_seq_len(c: UInt8) -> Int:
    """Byte length of the sequence a well-formed lead byte `c` opens."""
    if c < UInt8(0x80):
        return 1
    if c < UInt8(0xE0):
        return 2
    if c < UInt8(0xF0):
        return 3
    return 4


def check_utf8(bytes: Span[UInt8, _], start: Int, end: Int, what: String) raises:
    """Raise unless `bytes[start..end)` is well-formed UTF-8.

    The message is `<what>: invalid UTF-8 at byte <i>: <reason>`, where `<i>`
    is the index in `bytes` of the first byte of the ill-formed sequence."""
    if start < 0 or end > len(bytes) or end < start:
        raise Error(
            what
            + ": UTF-8 check range ["
            + String(start)
            + ", "
            + String(end)
            + ") is outside the input of "
            + String(len(bytes))
            + " byte(s)"
        )
    var i = start
    while i < end:
        var c = bytes[i]
        if c < UInt8(0x80):
            i += 1
            continue
        var reason = _utf8_error_at(bytes, i, end)
        if reason.byte_length() > 0:
            raise Error(
                what + ": invalid UTF-8 at byte " + String(i) + ": " + reason
            )
        i += _utf8_seq_len(c)
