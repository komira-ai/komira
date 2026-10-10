# =============================================================================
# parse_string — JSON string → String / StringArray entry (with unescape)
# =============================================================================
#
# The Stage 1 walker emits TAG_QUOTE_OPEN / TAG_QUOTE_CLOSE at every
# unescaped quote position. The Stage 2 walker reads the bytes between
# the two quote positions; that range is the string's RAW bytes
# (including any `\<x>` escape sequences that Stage 1 noted but did
# not resolve).
#
# Two parser shapes:
#
#   1. `parse_string_raw(bytes, start, end) -> String`
#       — Fast path: the byte range contains NO escape sequences (Stage 1
#       can flag this as `has_escapes=False` on the structural tag in a
#       future enrichment; today the caller passes the explicit hint).
#       Just memcpy the bytes into a new String.
#
#   2. `parse_string_with_escapes(bytes, start, end) raises -> String`
#       — Slow path: walks the bytes; on each `\`, decodes the
#       2-character escape (\" \\ \/ \b \f \n \r \t) or the 6-character
#       backslash-u-XXXX, including a surrogate PAIR for a code point above
#       the BMP. The output String contains the decoded UTF-8 bytes.
#       (`\u` matters in practice: Python's `json.dumps()` defaults to
#       `ensure_ascii=True`.)
#
# Public surface:
#   - `parse_string(bytes, start, end, has_escapes=False) raises -> String`
#       Top-level dispatcher. `has_escapes=False` shortcuts to the raw
#       path; `True` routes through the unescape kernel.
#
# Encapsulation:
#   - `Span[UInt8, _]` input; owned `String` return. Internal byte
#     construction uses `List[UInt8]` (Mojo's standard String-from-bytes
#     ctor avoids UnsafePointer in the public path).
#
# References:
#   - RFC 8259 §7 (strings + escapes).
# =============================================================================

from komira_json_index.utf8_check import check_utf8


def _string_from_bytes(b: List[UInt8]) raises -> String:
    """Construct a String from a List[UInt8]. Appends a NUL terminator
    (`String` ctor consumes a NUL-terminated buffer)."""
    var scratch = List[UInt8](capacity=len(b) + 1)
    for i in range(len(b)):
        scratch.append(b[i])
    scratch.append(UInt8(0))
    # SAFETY: `scratch` is alive through the ctor call; the ptr it
    # passes is a NUL-terminated buffer that String copies out
    # immediately. Mirrors `StringArray.get` in the core packages.
    return String(unsafe_from_utf8_ptr=scratch.unsafe_ptr())


def parse_string_raw(bytes: Span[UInt8, _], start: Int, end: Int) raises -> String:
    """Fast path: copy `bytes[start..end]` directly into a String.

    Caller MUST guarantee that the range contains no `\\` escapes (the
    Stage 1 tag must carry `has_escapes=False` for this byte range).

    Raises `parse_string_raw: invalid UTF-8 at byte <i>: <reason>` when the
    range is not well-formed UTF-8 (RFC 8259 §8.1; see `utf8_check`).
    """
    if end < start:
        raise Error("parse_string_raw: end < start")
    check_utf8(bytes, start, end, "parse_string_raw")
    var buf = List[UInt8](capacity=(end - start) + 1)
    for i in range(start, end):
        buf.append(bytes[i])
    return _string_from_bytes(buf)


def _hex_nibble(b: UInt8) raises -> Int:
    """One ASCII hex digit -> 0..15. Raises on anything else."""
    if b >= UInt8(0x30) and b <= UInt8(0x39):  # '0'..'9'
        return Int(b) - 0x30
    if b >= UInt8(0x61) and b <= UInt8(0x66):  # 'a'..'f'
        return Int(b) - 0x61 + 10
    if b >= UInt8(0x41) and b <= UInt8(0x46):  # 'A'..'F'
        return Int(b) - 0x41 + 10
    raise Error(
        "parse_string_with_escapes: '\\u' escape has a non-hex digit '"
        + String(chr(Int(b)))
        + "'"
    )


def _read_u_escape(bytes: Span[UInt8, _], at: Int, end: Int) raises -> Int:
    """Read the 4 hex digits of a `\\uXXXX` at `at` (the index of the FIRST hex
    digit, i.e. two past the backslash) and return the 16-bit code unit."""
    if at + 4 > end:
        raise Error(
            "parse_string_with_escapes: truncated '\\u' escape — 4 hex digits"
            " required, fewer remain in the string"
        )
    var v = 0
    for i in range(at, at + 4):
        v = (v << 4) | _hex_nibble(bytes[i])
    return v


def _append_utf8(mut buf: List[UInt8], cp: Int) raises -> None:
    """Append `cp`'s UTF-8 encoding to `buf` (1-4 bytes, RFC 3629)."""
    if cp < 0x80:
        buf.append(UInt8(cp))
    elif cp < 0x800:
        buf.append(UInt8(0xC0 | (cp >> 6)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        buf.append(UInt8(0xE0 | (cp >> 12)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (cp >> 18)))
        buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))


def parse_string_with_escapes(bytes: Span[UInt8, _], start: Int, end: Int) raises -> String:
    """Slow path: walk bytes[start..end], decoding 2-character escapes.

    Recognized escapes (JSON RFC 8259 7):
      backslash-quote     -> 0x22 (double quote)
      backslash-backslash -> 0x5C (backslash)
      backslash-slash     -> 0x2F (forward slash)
      backslash-b         -> 0x08 (backspace)
      backslash-f         -> 0x0C (form feed)
      backslash-n         -> 0x0A (newline)
      backslash-r         -> 0x0D (carriage return)
      backslash-t         -> 0x09 (tab)

      backslash-u-XXXX    -> the code unit, UTF-8 encoded. A HIGH surrogate
                             (D800-DBFF) must be followed by its own `\\u`
                             LOW surrogate (DC00-DFFF); the pair is combined
                             into one code point BEFORE encoding, because
                             encoding each half separately produces CESU-8,
                             which is not valid UTF-8. A lone surrogate on
                             either side, a short escape, or a non-hex digit
                             raises.

    The RAW range is checked first and raises
    `parse_string_with_escapes: invalid UTF-8 at byte <i>: <reason>` when it
    is not well-formed UTF-8. Every escape is ASCII and every decoded escape
    appends a complete, well-formed sequence, so a well-formed raw range
    decodes to well-formed UTF-8.
    """
    if end < start:
        raise Error("parse_string_with_escapes: end < start")
    check_utf8(bytes, start, end, "parse_string_with_escapes")
    var buf = List[UInt8](capacity=(end - start) + 1)
    var i = start
    while i < end:
        var b = bytes[i]
        if b == UInt8(0x5C):  # '\\'
            if i + 1 >= end:
                raise Error("parse_string_with_escapes: trailing '\\' with no follow byte")
            var next = bytes[i + 1]
            if next == UInt8(0x22):  # '\"'
                buf.append(UInt8(0x22))
            elif next == UInt8(0x5C):  # '\\\\'
                buf.append(UInt8(0x5C))
            elif next == UInt8(0x2F):  # '\\/'
                buf.append(UInt8(0x2F))
            elif next == UInt8(0x62):  # '\\b'
                buf.append(UInt8(0x08))
            elif next == UInt8(0x66):  # '\\f'
                buf.append(UInt8(0x0C))
            elif next == UInt8(0x6E):  # '\\n'
                buf.append(UInt8(0x0A))
            elif next == UInt8(0x72):  # '\\r'
                buf.append(UInt8(0x0D))
            elif next == UInt8(0x74):  # '\\t'
                buf.append(UInt8(0x09))
            elif next == UInt8(0x75):  # backslash-u — 4-hex code-unit escape
                # Required, not optional: `json.dumps()` defaults to
                # `ensure_ascii=True`, so EVERY JSONL file a stock Python
                # producer writes containing any non-ASCII text is
                # `\uXXXX`-escaped. Schema INFERENCE walks the same bytes
                # and does not reject them, so without this arm such a file
                # binds and then fails at `.collect()`.
                var cu = _read_u_escape(bytes, i + 2, end)
                i += 6
                if cu >= 0xD800 and cu <= 0xDBFF:
                    # HIGH surrogate — RFC 8259 §7 requires the LOW half to
                    # follow as its own `\u` escape. A code point above the BMP
                    # has no single 4-hex spelling, so a pair is the only way
                    # `\u` can express one and the two halves must be combined
                    # BEFORE encoding: emitting each half on its own produces
                    # CESU-8, which is not valid UTF-8.
                    if i + 1 >= end or bytes[i] != UInt8(0x5C) or bytes[
                        i + 1
                    ] != UInt8(0x75):
                        raise Error(
                            "parse_string_with_escapes: high surrogate"
                            " '\\u"
                            + String(cu)
                            + "' is not followed by a '\\u' low surrogate"
                        )
                    var lo = _read_u_escape(bytes, i + 2, end)
                    if lo < 0xDC00 or lo > 0xDFFF:
                        raise Error(
                            "parse_string_with_escapes: high surrogate is"
                            " followed by '\\u"
                            + String(lo)
                            + "', which is not a low surrogate (DC00-DFFF)"
                        )
                    i += 6
                    _append_utf8(
                        buf, 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00)
                    )
                elif cu >= 0xDC00 and cu <= 0xDFFF:
                    raise Error(
                        "parse_string_with_escapes: lone low surrogate '\\u"
                        + String(cu)
                        + "' with no preceding high surrogate"
                    )
                else:
                    _append_utf8(buf, cu)
                continue
            else:
                raise Error("parse_string_with_escapes: unrecognized escape '\\" + String(chr(Int(next))) + "'")
            i += 2
        else:
            buf.append(b)
            i += 1
    return _string_from_bytes(buf)


def parse_string(bytes: Span[UInt8, _], start: Int, end: Int, has_escapes: Bool = False) raises -> String:
    """Top-level dispatcher: route to raw or unescape based on the hint."""
    if has_escapes:
        return parse_string_with_escapes(bytes, start, end)
    return parse_string_raw(bytes, start, end)
