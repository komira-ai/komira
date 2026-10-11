# =============================================================================
# komira_mail_message/encoded_word.mojo -- RFC 2047 encoded words.
# =============================================================================
#
# Encoding (`encode_words`) writes UTF-8 text as `=?UTF-8?Q?...?=` or
# `=?UTF-8?B?...?=`, whichever is shorter for the whole text, split into
# words of at most 75 characters (section 2) that never split a UTF-8
# sequence (section 5 (3)). The Q form writes letters, digits and `!*+-/` as
# themselves, a space as `_`, and every other byte as `=XX`: the set section 5
# (3) allows in a phrase, so one encoder serves a `Subject` and a display
# name. The words are meant to be joined by single spaces, where a header can
# be folded; a decoder drops white space between two encoded words
# (section 6.2), so every space of the text is inside a word.
#
# Decoding (`decode_header_text`) reads an unfolded unstructured field body.
# A white-space-delimited token of the form `=?charset?Q|B?text?=` (section
# 2; a `*language` suffix of the charset, RFC 2231 section 5, is ignored) is
# replaced by its text; white space between two decoded words is dropped. A
# token that is not a well-formed encoded word, or whose charset this package
# does not read, or whose decoded bytes hold CR, LF or NUL, is kept as written
# (section 6.3). Charsets read: UTF-8, US-ASCII, ISO-8859-1, and the ASCII
# bytes of any other `ISO-8859-*` or `windows-125*` charset (a word holding a
# byte above 0x7F in those is kept). Bytes outside encoded words that are not
# UTF-8 become U+FFFD: there is no charset transcoding.
# =============================================================================

from komira_encoding import base64_decode, base64_encode

from .chars import (
    CR,
    EQ,
    LF,
    QMARK,
    SP,
    STAR,
    UNDERSCORE,
    append_bytes,
    append_hex,
    append_lossy,
    equals_ignore_case,
    hex_value,
    is_alpha,
    is_digit,
    is_token_char,
    is_wsp,
    lossy_string,
    lower,
    range_bytes,
    utf8_invalid_at,
    utf8_sequence_length,
)

comptime ENCODED_WORD_MAX = 75
"""RFC 2047 section 2: an encoded word is at most 75 characters."""

comptime _PREFIX_Q: StaticString = "=?UTF-8?Q?"
comptime _PREFIX_B: StaticString = "=?UTF-8?B?"
comptime _OVERHEAD = 12
"""`=?UTF-8?Q?` and `?=`."""


def _q_literal(c: UInt8) -> Bool:
    """A byte the Q form writes as itself (RFC 2047 section 5 (3))."""
    return (
        is_alpha(c)
        or is_digit(c)
        or c == 33
        or c == 42
        or c == 43
        or c == 45
        or c == 47
    )


def _q_width(c: UInt8) -> Int:
    if c == SP or _q_literal(c):
        return 1
    return 3


def _sequence_at(text: Span[UInt8, _], i: Int) -> Int:
    """The bytes of the character at `i`: a whole UTF-8 sequence, or one
    byte when the bytes there are not UTF-8."""
    var length = utf8_sequence_length(text, i)
    return length if length > 0 else 1


def encode_words(
    text: Span[UInt8, _], first_limit: Int, word_limit: Int
) -> List[List[UInt8]]:
    """`text` (UTF-8) as encoded words: the first at most `first_limit`
    characters long, the rest at most `word_limit` (both clamped to
    16..75)."""
    var n = len(text)
    var q_length = 0
    for i in range(n):
        q_length += _q_width(text[i])
    var use_b = ((n + 2) // 3) * 4 < q_length
    var words = List[List[UInt8]]()
    var limit = min(max(first_limit, 16), ENCODED_WORD_MAX)
    var rest_limit = min(max(word_limit, 16), ENCODED_WORD_MAX)
    var i = 0
    while i < n:
        var room = limit - _OVERHEAD
        var j = i
        var width = 0
        while j < n:
            var length = _sequence_at(text, j)
            var w: Int
            if use_b:
                w = ((j + length - i + 2) // 3) * 4 - width
            else:
                w = 0
                for k in range(length):
                    w += _q_width(text[j + k])
            if width + w > room:
                break
            width += w
            j += length
        if j == i:
            j = i + _sequence_at(text, i)
        var word = List[UInt8](capacity=limit)
        if use_b:
            append_bytes(word, _PREFIX_B.as_bytes())
            var chunk = range_bytes(text, i, j)
            append_bytes(word, base64_encode(Span(chunk)).as_bytes())
        else:
            append_bytes(word, _PREFIX_Q.as_bytes())
            for k in range(i, j):
                var c = text[k]
                if c == SP:
                    word.append(UNDERSCORE)
                elif _q_literal(c):
                    word.append(c)
                else:
                    append_hex(word, c, EQ)
        word.append(QMARK)
        word.append(EQ)
        words.append(word^)
        i = j
        limit = rest_limit
    return words^


def encode_header_text(text: String) -> String:
    """`text` as RFC 2047 encoded words joined by single spaces: the form the
    builder writes for a `Subject` that needs encoding."""
    var words = encode_words(text.as_bytes(), ENCODED_WORD_MAX, ENCODED_WORD_MAX)
    var out = String("")
    for k in range(len(words)):
        if k > 0:
            out += " "
        # Encoded words are ASCII.
        for b in range(len(words[k])):
            out += chr(Int(words[k][b]))
    return out


# --- decoding ----------------------------------------------------------------


def charset_kind(charset: Span[UInt8, _]) -> Int:
    """0: not read; 1: UTF-8; 2: US-ASCII or the ASCII bytes of an
    ISO-8859-* / windows-125* charset; 3: ISO-8859-1."""
    if equals_ignore_case(charset, "utf-8".as_bytes()):
        return 1
    if equals_ignore_case(charset, "us-ascii".as_bytes()):
        return 2
    if equals_ignore_case(charset, "iso-8859-1".as_bytes()):
        return 3
    var n = len(charset)
    if n > 9:
        var head = range_bytes(charset, 0, 9)
        if equals_ignore_case(Span(head), "iso-8859-".as_bytes()):
            return 2
    if n > 11:
        var head = range_bytes(charset, 0, 11)
        if equals_ignore_case(Span(head), "windows-125".as_bytes()):
            return 2
    return 0


def _decode_q(data: Span[UInt8, _], start: Int, end: Int) -> Optional[List[UInt8]]:
    var out = List[UInt8](capacity=end - start)
    var i = start
    while i < end:
        var c = data[i]
        if c == UNDERSCORE:
            out.append(SP)
            i += 1
        elif c == EQ:
            if i + 2 >= end:
                return None
            var hi = hex_value(data[i + 1])
            var lo = hex_value(data[i + 2])
            if hi < 0 or lo < 0:
                return None
            out.append(UInt8(hi * 16 + lo))
            i += 3
        elif c > 32 and c < 127:
            out.append(c)
            i += 1
        else:
            return None
    return out^


def _to_utf8(raw: List[UInt8], kind: Int) -> Optional[List[UInt8]]:
    """The decoded bytes of a word in charset `kind` as UTF-8, or None."""
    for i in range(len(raw)):
        var c = raw[i]
        if c == CR or c == LF or c == 0:
            return None
    if kind == 1:
        if utf8_invalid_at(Span(raw)) >= 0:
            return None
        return raw.copy()
    if kind == 2:
        for i in range(len(raw)):
            if raw[i] >= 128:
                return None
        return raw.copy()
    var out = List[UInt8](capacity=len(raw) * 2)
    for i in range(len(raw)):
        var c = raw[i]
        if c < 128:
            out.append(c)
        else:
            out.append(0xC0 | (c >> 6))
            out.append(0x80 | (c & 0x3F))
    return out^


def decode_encoded_word(
    data: Span[UInt8, _], start: Int, end: Int
) -> Optional[List[UInt8]]:
    """The UTF-8 text of the encoded word `data[start:end]`, or None when it
    is not one this package reads; see the module header."""
    if end - start < 8:
        return None
    if data[start] != EQ or data[start + 1] != QMARK:
        return None
    if data[end - 2] != QMARK or data[end - 1] != EQ:
        return None
    var q1 = start + 2
    while q1 < end and data[q1] != QMARK:
        if not is_token_char(data[q1]):
            return None
        q1 += 1
    if q1 == start + 2 or q1 + 3 > end - 2:
        return None
    if data[q1 + 2] != QMARK:
        return None
    var text_start = q1 + 3
    var text_end = end - 2
    for i in range(text_start, text_end):
        if data[i] == QMARK or is_wsp(data[i]):
            return None
    var charset_end = start + 2
    while charset_end < q1 and data[charset_end] != STAR:
        charset_end += 1
    var charset = range_bytes(data, start + 2, charset_end)
    var kind = charset_kind(Span(charset))
    if kind == 0:
        return None
    var encoding = lower(data[q1 + 1])
    var raw: List[UInt8]
    if encoding == 113:  # q
        var q = _decode_q(data, text_start, text_end)
        if not q:
            return None
        raw = q.value().copy()
    elif encoding == 98:  # b
        var b64 = range_bytes(data, text_start, text_end)
        try:
            raw = base64_decode(Span(b64))
        except:
            return None
    else:
        return None
    return _to_utf8(raw, kind)


def decode_header_text(data: Span[UInt8, _]) raises -> String:
    """An unfolded unstructured field body with its encoded words decoded;
    see the module header."""
    var n = len(data)
    var out = List[UInt8](capacity=n)
    var ws_start = 0
    var ws_end = 0
    var previous_encoded = False
    var i = 0
    while i < n:
        if is_wsp(data[i]):
            ws_start = i
            while i < n and is_wsp(data[i]):
                i += 1
            ws_end = i
            continue
        var start = i
        while i < n and not is_wsp(data[i]):
            i += 1
        var decoded = decode_encoded_word(data, start, i)
        if decoded:
            if not previous_encoded:
                for k in range(ws_start, ws_end):
                    out.append(data[k])
            append_bytes(out, Span(decoded.value()))
            previous_encoded = True
        else:
            for k in range(ws_start, ws_end):
                out.append(data[k])
            var token = range_bytes(data, start, i)
            append_lossy(out, Span(token))
            previous_encoded = False
        ws_start = 0
        ws_end = 0
    for k in range(ws_start, ws_end):
        out.append(data[k])
    return lossy_string(Span(out))


def decode_header_text(text: String) raises -> String:
    """`decode_header_text` over the bytes of `text`."""
    return decode_header_text(text.as_bytes())
