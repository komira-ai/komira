# =============================================================================
# xml_escape.mojo — XML text/attribute escaping and entity unescaping.
# =============================================================================
#
# BYTE-ORIENTED, NOT CODEPOINT-ORIENTED. Everything here scans `UInt8` and
# appends `UInt8`. That is a correctness requirement before it is a performance
# one: a decoder that builds its output with `out += chr(Int(c))` per byte
# re-encodes every byte >= 0x80 as a 2-byte UTF-8 sequence for the codepoint
# of that byte's numeric value, so any non-ASCII S3 object key comes back
# mojibaked. Scanning bytes and
# appending bytes cannot have that bug, because a multi-byte UTF-8 sequence is
# passed through untouched — none of its bytes can be `&`, which is the only
# byte the scanner reacts to (a UTF-8 continuation byte is always >= 0x80).
#
# The five XML predefined entities are `&amp; &lt; &gt; &quot; &apos;`.
# Numeric character references (`&#38;`, `&#x26;`) are also decoded — they are
# well-formed XML that a general codec must accept even though S3 does not
# currently emit them.
#
# Encapsulation: no `UnsafePointer` in any signature here.
# =============================================================================


comptime _AMP: UInt8 = 0x26  # '&'
comptime _LT: UInt8 = 0x3C  # '<'
comptime _GT: UInt8 = 0x3E  # '>'
comptime _QUOT: UInt8 = 0x22  # '"'
comptime _APOS: UInt8 = 0x27  # "'"
comptime _SEMI: UInt8 = 0x3B  # ';'
comptime _HASH: UInt8 = 0x23  # '#'
comptime _CR: UInt8 = 0x0D  # '\r'


def _append_lit(mut out: List[UInt8], lit: StringSlice):
    """Append a literal's bytes."""
    var b = lit.as_bytes()
    for i in range(len(b)):
        out.append(b[i])


def append_escaped_text(mut out: List[UInt8], s: StringSlice):
    """Append `s` escaped for XML ELEMENT TEXT content.

    Escapes `&`, `<`, `>`. `>` is not strictly required outside the `]]>`
    sequence, but AWS's own serializers escape it unconditionally and the
    conformance corpus's expected bodies do too.
    """
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        var c = b[i]
        if c == _AMP:
            _append_lit(out, "&amp;")
        elif c == _LT:
            _append_lit(out, "&lt;")
        elif c == _GT:
            _append_lit(out, "&gt;")
        elif c == _CR:
            # A literal CR in text is normalised away by every XML parser
            # (XML 1.0 §2.11 line-end handling), so it must be escaped to
            # survive a round trip.
            _append_lit(out, "&#xD;")
        else:
            out.append(c)


def append_escaped_attr(mut out: List[UInt8], s: StringSlice):
    """Append `s` escaped for an XML ATTRIBUTE VALUE (double-quoted).

    Escapes `&`, `<`, `>`, `"`. An `'` needs no escape inside `"..."`.
    """
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        var c = b[i]
        if c == _AMP:
            _append_lit(out, "&amp;")
        elif c == _LT:
            _append_lit(out, "&lt;")
        elif c == _GT:
            _append_lit(out, "&gt;")
        elif c == _QUOT:
            _append_lit(out, "&quot;")
        elif c == _CR:
            _append_lit(out, "&#xD;")
        elif c == 0x0A:
            _append_lit(out, "&#xA;")
        elif c == 0x09:
            _append_lit(out, "&#x9;")
        else:
            out.append(c)


def xml_escape_text(s: StringSlice) -> String:
    """`s` escaped for element text content."""
    var out = List[UInt8]()
    append_escaped_text(out, s)
    return String(unsafe_from_utf8=Span(out))


def xml_escape_attr(s: StringSlice) -> String:
    """`s` escaped for a double-quoted attribute value."""
    var out = List[UInt8]()
    append_escaped_attr(out, s)
    return String(unsafe_from_utf8=Span(out))


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Append the UTF-8 encoding of codepoint `cp`."""
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _match(b: Span[UInt8, _], pos: Int, lit: StringSlice) -> Bool:
    """Whether `b[pos:]` starts with `lit`."""
    var l = lit.as_bytes()
    var n = len(l)
    if pos + n > len(b):
        return False
    for i in range(n):
        if b[pos + i] != l[i]:
            return False
    return True


def append_unescaped(mut out: List[UInt8], b: Span[UInt8, _], lo: Int, hi: Int):
    """Append `b[lo:hi]` with XML entity references decoded.

    An `&` that does not begin a recognised reference is passed through
    verbatim; so is a numeric reference to a surrogate (U+D800..U+DFFF) or
    to a value past U+10FFFF, which have no UTF-8 encoding. `XmlReader`
    refuses such a document before it decodes anything, so this leniency
    only reaches direct callers of `xml_unescape`.
    """
    var i = lo
    while i < hi:
        var c = b[i]
        if c != _AMP:
            out.append(c)
            i += 1
            continue
        if _match(b, i, "&amp;"):
            out.append(_AMP)
            i += 5
        elif _match(b, i, "&lt;"):
            out.append(_LT)
            i += 4
        elif _match(b, i, "&gt;"):
            out.append(_GT)
            i += 4
        elif _match(b, i, "&quot;"):
            out.append(_QUOT)
            i += 6
        elif _match(b, i, "&apos;"):
            out.append(_APOS)
            i += 6
        elif i + 2 < hi and b[i + 1] == _HASH:
            # Numeric character reference: &#DDD; or &#xHHH;
            var j = i + 2
            var hexmode = False
            if j < hi and (b[j] == 0x78 or b[j] == 0x58):  # 'x' / 'X'
                hexmode = True
                j += 1
            var cp = 0
            var digits = 0
            while j < hi:
                var d = b[j]
                var v = -1
                if d >= 0x30 and d <= 0x39:
                    v = Int(d) - 0x30
                elif hexmode and d >= 0x61 and d <= 0x66:
                    v = Int(d) - 0x61 + 10
                elif hexmode and d >= 0x41 and d <= 0x46:
                    v = Int(d) - 0x41 + 10
                if v < 0:
                    break
                cp = cp * (16 if hexmode else 10) + v
                digits += 1
                if cp > 0x10FFFF:
                    break
                j += 1
            # A surrogate (U+D800..U+DFFF) is not a scalar value and has no
            # UTF-8 form: it is passed through like a value past U+10FFFF,
            # so the output stays UTF-8.
            if (
                digits > 0
                and j < hi
                and b[j] == _SEMI
                and cp <= 0x10FFFF
                and not (cp >= 0xD800 and cp <= 0xDFFF)
            ):
                _append_utf8(out, cp)
                i = j + 1
            else:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1


def xml_unescape(s: StringSlice) -> String:
    """`s` with XML entity references decoded."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    append_unescaped(out, b, 0, len(b))
    return String(unsafe_from_utf8=Span(out))
