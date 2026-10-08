# =============================================================================
# komira_mail_message/params.mojo -- `Content-Type` and
# `Content-Disposition` values and their parameters (RFC 2045 section 5.1,
# RFC 2183, RFC 2231).
# =============================================================================
#
# Parsing (`parse_media_header`) reads `type/subtype` (or a disposition type)
# and `; attribute=value` parameters with comments and white space between
# the parts. Names and the type are lower-cased; a value is a token or a
# quoted string. RFC 2231 sections 3 and 4 are applied: `name*0`, `name*1`,
# ... are joined in order (a gap ends the value), `name*` and `name*N*` are
# percent-decoded and read in the charset of the first section (UTF-8,
# US-ASCII, ISO-8859-1; any other charset's bytes are kept, ill-formed UTF-8
# as U+FFFD), the language is dropped, and an RFC 2231 form wins over a plain
# `name=` of the same name. Parsing never fails: a part that does not follow
# the grammar ends the parameters, and a value that is not a media type
# leaves `value()` empty.
#
# Formatting (`append_param`) writes a token as itself, other printable
# ASCII of at most 60 octets as a quoted string, and anything else as RFC
# 2231 `name*=utf-8''...` percent-encoded, split into `name*0*`, `name*1*`,
# ... sections of at most 60 characters, each after `; ` so a header folds
# between them.
# =============================================================================

from .chars import (
    BACKSLASH,
    DQUOTE,
    EQ,
    LPAREN,
    PERCENT,
    RPAREN,
    SEMI,
    SLASH,
    SP,
    SQUOTE,
    STAR,
    append_bytes,
    append_hex,
    append_lossy,
    hex_value,
    is_digit,
    is_token_char,
    is_wsp,
    lossy_string,
    lower,
    lower_ascii_string,
    range_bytes,
    utf8_invalid_at,
)
from .encoded_word import charset_kind

comptime PARAM_SECTION_MAX = 60
"""The longest value written as one quoted string or one RFC 2231 section."""

comptime _MAX_SECTIONS = 1000
"""RFC 2231 sections above this number are ignored."""


struct Param(Copyable, Movable):
    """One parameter: its name in lower case (no RFC 2231 `*` suffix) and its
    decoded value."""

    var name: String
    var value: String

    def __init__(out self, name: String, value: String):
        self.name = name
        self.value = value


struct MediaHeader(Copyable, Movable):
    """A parsed `Content-Type` or `Content-Disposition` value."""

    var _value: String
    var _params: List[Param]

    def __init__(out self, value: String, var params: List[Param]):
        self._value = value
        self._params = params^

    def value(self) -> String:
        """`type/subtype` or the disposition type, in lower case; empty when
        the field did not start with one."""
        return self._value

    def params(self) -> List[Param]:
        return self._params.copy()

    def param(self, name: String) -> Optional[String]:
        """The value of the parameter `name` (lower case), if present."""
        for i in range(len(self._params)):
            if self._params[i].name == name:
                return Optional[String](self._params[i].value)
        return None


def _skip_cfws(data: Span[UInt8, _], mut i: Int):
    var n = len(data)
    while i < n:
        var c = data[i]
        if is_wsp(c):
            i += 1
        elif c == LPAREN:
            var depth = 0
            while i < n:
                var d = data[i]
                if d == BACKSLASH:
                    i += 2
                    continue
                if d == LPAREN:
                    depth += 1
                elif d == RPAREN:
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
        else:
            return


def _read_token(data: Span[UInt8, _], mut i: Int) -> Int:
    """Advance `i` over a token; return where it started."""
    var start = i
    while i < len(data) and is_token_char(data[i]):
        i += 1
    return start


struct _RawParam(Copyable, Movable):
    var name: List[UInt8]
    var value: List[UInt8]

    def __init__(out self, var name: List[UInt8], var value: List[UInt8]):
        self.name = name^
        self.value = value^


def _read_value(data: Span[UInt8, _], mut i: Int) -> Optional[List[UInt8]]:
    var n = len(data)
    if i < n and data[i] == DQUOTE:
        var out = List[UInt8]()
        i += 1
        while i < n:
            var c = data[i]
            if c == DQUOTE:
                i += 1
                return out^
            if c == BACKSLASH and i + 1 < n:
                out.append(data[i + 1])
                i += 2
                continue
            out.append(c)
            i += 1
        return None
    var start = _read_token(data, i)
    if i == start:
        return None
    return range_bytes(data, start, i)


def _section_suffix(name: List[UInt8], star: Int) -> Int:
    """For `base*N` or `base*N*`, N (at most `_MAX_SECTIONS`); -1 for
    `base*`; -2 when the suffix is not one of these."""
    var n = len(name)
    if star == n - 1:
        return -1
    var end = n - 1 if name[n - 1] == STAR else n
    if end == star + 1:
        return -2
    if name[star + 1] == 48 and end > star + 2:
        return -2
    var number = 0
    for k in range(star + 1, end):
        if not is_digit(name[k]):
            return -2
        number = number * 10 + Int(name[k]) - 48
        if number > _MAX_SECTIONS:
            return -2
    return number


def _percent_decode(mut out: List[UInt8], value: Span[UInt8, _], start: Int):
    var i = start
    var n = len(value)
    while i < n:
        var c = value[i]
        if c == PERCENT and i + 2 < n:
            var hi = hex_value(value[i + 1])
            var lo = hex_value(value[i + 2])
            if hi >= 0 and lo >= 0:
                out.append(UInt8(hi * 16 + lo))
                i += 3
                continue
        out.append(c)
        i += 1


def _bytes_in_charset(raw: List[UInt8], kind: Int) raises -> String:
    if kind == 3:
        var out = List[UInt8](capacity=len(raw) * 2)
        for i in range(len(raw)):
            var c = raw[i]
            if c < 128:
                out.append(c)
            else:
                out.append(0xC0 | (c >> 6))
                out.append(0x80 | (c & 0x3F))
        return lossy_string(Span(out))
    return lossy_string(Span(raw))


def _join_sections(raws: List[_RawParam], base: List[UInt8]) raises -> Optional[String]:
    """The RFC 2231 value of parameter `base`, or None when it has no
    starred form."""
    var single = -1
    var found_any = False
    for r in range(len(raws)):
        var name = raws[r].name.copy()
        var star = len(base)
        if len(name) <= star or name[star] != STAR:
            continue
        var same = True
        for k in range(star):
            if name[k] != base[k]:
                same = False
                break
        if not same:
            continue
        var section = _section_suffix(name, star)
        if section == -1 and single < 0:
            single = r
        if section >= 0:
            found_any = True
    if single >= 0:
        var value = raws[single].value.copy()
        return _decode_extended(value)
    if not found_any:
        return None
    var joined = List[UInt8]()
    var kind = 1
    var index = 0
    while index <= _MAX_SECTIONS:
        var hit = -1
        var extended = False
        for r in range(len(raws)):
            var name = raws[r].name.copy()
            var star = len(base)
            if len(name) <= star or name[star] != STAR:
                continue
            var same = True
            for k in range(star):
                if name[k] != base[k]:
                    same = False
                    break
            if same and _section_suffix(name, star) == index:
                hit = r
                extended = name[len(name) - 1] == STAR
                break
        if hit < 0:
            break
        var value = raws[hit].value.copy()
        if not extended:
            append_bytes(joined, Span(value))
        elif index == 0:
            var start = _after_language(value)
            if start < 0:
                return None
            kind = _charset_of(value)
            _percent_decode(joined, Span(value), start)
        else:
            _percent_decode(joined, Span(value), 0)
        index += 1
    return _bytes_in_charset(joined, kind)


def _after_language(value: List[UInt8]) -> Int:
    """Where the text of `charset'language'text` starts, or -1."""
    var quotes = 0
    for i in range(len(value)):
        if value[i] == SQUOTE:
            quotes += 1
            if quotes == 2:
                return i + 1
    return -1


def _charset_of(value: List[UInt8]) -> Int:
    var end = 0
    while end < len(value) and value[end] != SQUOTE:
        end += 1
    if end == 0:
        return 2
    var charset = range_bytes(Span(value), 0, end)
    return charset_kind(Span(charset))


def _decode_extended(value: List[UInt8]) raises -> Optional[String]:
    var start = _after_language(value)
    if start < 0:
        return None
    var raw = List[UInt8]()
    _percent_decode(raw, Span(value), start)
    return Optional[String](_bytes_in_charset(raw, _charset_of(value)))


def parse_media_header(data: Span[UInt8, _]) raises -> MediaHeader:
    """A `Content-Type` (`type/subtype`) or `Content-Disposition` (a single
    token) field body; see the module header."""
    var n = len(data)
    var i = 0
    _skip_cfws(data, i)
    var start = _read_token(data, i)
    var value_end = i
    if i < n and data[i] == SLASH:
        i += 1
        var sub = _read_token(data, i)
        if i == sub:
            return MediaHeader(String(""), List[Param]())
        value_end = i
    var value = lower_ascii_string(data, start, value_end)
    var raws = List[_RawParam]()
    while True:
        _skip_cfws(data, i)
        if i >= n or data[i] != SEMI:
            break
        i += 1
        _skip_cfws(data, i)
        if i >= n:
            break
        var name_start = _read_token(data, i)
        if i == name_start:
            break
        var name = List[UInt8](capacity=i - name_start)
        for k in range(name_start, i):
            name.append(lower(data[k]))
        _skip_cfws(data, i)
        if i >= n or data[i] != EQ:
            break
        i += 1
        _skip_cfws(data, i)
        var v = _read_value(data, i)
        if not v:
            break
        raws.append(_RawParam(name^, v.value().copy()))
    var params = List[Param]()
    for r in range(len(raws)):
        var name = raws[r].name.copy()
        var star = -1
        for k in range(len(name)):
            if name[k] == STAR:
                star = k
                break
        var base_end = star if star >= 0 else len(name)
        var base = range_bytes(Span(name), 0, base_end)
        var base_name = lossy_string(Span(base))
        var seen = False
        for p in range(len(params)):
            if params[p].name == base_name:
                seen = True
                break
        if seen or base_end == 0:
            continue
        var joined = _join_sections(raws, base)
        if joined:
            params.append(Param(base_name, joined.value()))
            continue
        if star >= 0:
            continue
        params.append(Param(base_name, lossy_string(Span(raws[r].value))))
    return MediaHeader(value, params^)


# --- formatting --------------------------------------------------------------


def _is_attr_char(c: UInt8) -> Bool:
    """RFC 2231 `attribute-char`: a token octet other than `*`, `'`, `%`."""
    return is_token_char(c) and c != STAR and c != SQUOTE and c != PERCENT


def _append_section_name(mut out: List[UInt8], name: StaticString, section: Int):
    append_bytes(out, name.as_bytes())
    out.append(STAR)
    if section >= 0:
        append_bytes(out, String(section).as_bytes())
        out.append(STAR)
    out.append(EQ)


def append_param(mut out: List[UInt8], name: StaticString, value: Span[UInt8, _]):
    """Append `; name=value` in the form the module header describes."""
    out.append(SEMI)
    out.append(SP)
    var n = len(value)
    var token = n > 0 and n <= PARAM_SECTION_MAX
    var printable = n <= PARAM_SECTION_MAX
    for i in range(n):
        var c = value[i]
        if not is_token_char(c):
            token = False
        if c < 32 or c > 126:
            printable = False
    if token:
        append_bytes(out, name.as_bytes())
        out.append(EQ)
        append_bytes(out, value)
        return
    if printable:
        append_bytes(out, name.as_bytes())
        out.append(EQ)
        out.append(DQUOTE)
        for i in range(n):
            if value[i] == DQUOTE or value[i] == BACKSLASH:
                out.append(BACKSLASH)
            out.append(value[i])
        out.append(DQUOTE)
        return
    var prefix = "utf-8''"
    var encoded_length = 7
    for i in range(n):
        encoded_length += 1 if _is_attr_char(value[i]) else 3
    var split = encoded_length > PARAM_SECTION_MAX
    var section = 0
    _append_section_name(out, name, 0 if split else -1)
    append_bytes(out, prefix.as_bytes())
    var used = 7
    for i in range(n):
        var c = value[i]
        var width = 1 if _is_attr_char(c) else 3
        # A new section starts only at the start of a UTF-8 sequence.
        if split and used + width > PARAM_SECTION_MAX and (c < 0x80 or c >= 0xC0):
            section += 1
            out.append(SEMI)
            out.append(SP)
            _append_section_name(out, name, section)
            used = 0
        if width == 1:
            out.append(c)
        else:
            append_hex(out, c, PERCENT)
        used += width
