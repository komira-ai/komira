# =============================================================================
# key_unescape.mojo -- an object key as the text it spells
# =============================================================================
#
# RFC 8259 compares member names as the strings they spell, so `"a"` and
# `"\u0061"` are one key, and `"a\/b"` is `a/b`. The key
# lookups (the materializer's `KeyTable`, a STRUCT's child names, the
# inferrer's registry) compare bytes, so a key holding a backslash is
# decoded first; a key without one (nearly every key) is looked up as its
# raw bytes, with only the backslash scan added.
#
# The decoder writes bytes, not a `String`, so `\u0000` decodes to a NUL
# byte and does not end the key. It raises on what is not a JSON escape:
# the reader has refused such a line before it decodes a key
# (`line_check.mojo`), but the inferrer has not.
# =============================================================================


def key_has_escape(key: Span[UInt8, _]) -> Bool:
    """Whether the raw key bytes (between the quotes) hold a backslash."""
    for i in range(len(key)):
        if key[i] == 0x5C:
            return True
    return False


def _hex4(key: Span[UInt8, _], at: Int) raises -> Int:
    if at + 4 > len(key):
        raise Error("komira_jsonl: a \\u escape in a key is short")
    var v = 0
    for k in range(4):
        var b = key[at + k]
        var h: Int
        if b >= 0x30 and b <= 0x39:
            h = Int(b) - 0x30
        elif b >= 0x61 and b <= 0x66:
            h = Int(b) - 0x61 + 10
        elif b >= 0x41 and b <= 0x46:
            h = Int(b) - 0x41 + 10
        else:
            raise Error("komira_jsonl: a \\u escape in a key has a non-hex digit")
        v = v * 16 + h
    return v


def _append_utf8(mut out: List[UInt8], cp: Int):
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


def unescape_key(key: Span[UInt8, _], mut out: List[UInt8]) raises:
    """Replace `out` with the bytes the raw key `key` spells: each JSON
    escape decoded, a `\\u` surrogate pair joined into one code point, every
    other byte copied. Raises on a backslash that does not start a JSON
    escape and on a lone surrogate."""
    out.clear()
    var n = len(key)
    var i = 0
    while i < n:
        var c = key[i]
        if c != 0x5C:
            out.append(c)
            i += 1
            continue
        if i + 1 >= n:
            raise Error("komira_jsonl: a key ends in a backslash")
        var e = key[i + 1]
        if e == 0x22 or e == 0x5C or e == 0x2F:
            out.append(e)
        elif e == 0x62:
            out.append(0x08)
        elif e == 0x66:
            out.append(0x0C)
        elif e == 0x6E:
            out.append(0x0A)
        elif e == 0x72:
            out.append(0x0D)
        elif e == 0x74:
            out.append(0x09)
        elif e == 0x75:
            var cu = _hex4(key, i + 2)
            i += 6
            if cu >= 0xD800 and cu <= 0xDBFF:
                if i + 1 >= n or key[i] != 0x5C or key[i + 1] != 0x75:
                    raise Error("komira_jsonl: a key holds a lone high surrogate")
                var lo = _hex4(key, i + 2)
                if lo < 0xDC00 or lo > 0xDFFF:
                    raise Error("komira_jsonl: a key holds a lone high surrogate")
                i += 6
                _append_utf8(out, 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00))
            elif cu >= 0xDC00 and cu <= 0xDFFF:
                raise Error("komira_jsonl: a key holds a lone low surrogate")
            else:
                _append_utf8(out, cu)
            continue
        else:
            raise Error("komira_jsonl: a key holds a backslash that is not a JSON escape")
        i += 2
