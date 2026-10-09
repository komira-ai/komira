# =============================================================================
# parse.mojo: a strict, depth-limited, non-recursive JSON parser.
# =============================================================================
#
# `parse_json_value(s)` / `parse_json_bytes(b)` parse ONE complete JSON text
# (RFC 8259 §2) into a `JsonValue`, or raise `JsonError: <what> at line L,
# byte column C`.
#
# What is accepted is exactly the RFC 8259 grammar:
#
#   - Whitespace is space, tab, LF and CR only. The value may be surrounded
#     by whitespace and nothing else: trailing content, an empty or
#     all-whitespace document, and a UTF-8 byte-order mark are refused.
#   - Literals are `true`, `false`, `null`, lowercase.
#   - Numbers (§6): `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
#     Refused: a leading zero (`01`, `-01`), a leading `+`, `.5`, `1.`,
#     `1e`, `NaN`, `Infinity`, hex. The text is kept verbatim.
#   - Strings (§7, §8.1): a byte below 0x20 must be escaped; the escapes are
#     `\" \\ \/ \b \f \n \r \t \uXXXX` and nothing else. A `\u` high
#     surrogate (D800-DBFF) must be followed by a `\u` low surrogate
#     (DC00-DFFF), and the pair decodes to one 4-byte UTF-8 code point; a lone
#     high surrogate, a lone low surrogate and a reversed pair are refused (a
#     lone surrogate has no UTF-8 encoding). Raw non-ASCII bytes must be
#     well-formed UTF-8 (no overlong forms, no encoded surrogates, nothing
#     above U+10FFFF) and are copied verbatim. `\u0000` is accepted and
#     yields a NUL byte.
#   - Arrays and objects: no trailing comma, no missing comma, object keys
#     must be strings. Duplicate keys are kept in document order.
#   - Nesting: at most `max_depth` arrays/objects deep (default
#     `JSON_DEFAULT_MAX_DEPTH` = 128, at most `JSON_MAX_DEPTH` = 1000; a
#     larger `max_depth` is refused); `[[[[...` a million deep is a clean
#     refusal at the limit. The parser itself does not recurse (open
#     containers live on an explicit stack). Destroying, copying (`copy()`)
#     and serializing (`write_to()`) a `JsonValue` DO recurse once per
#     nesting level, and a parse that fails part-way destroys what it built,
#     so the cap on `max_depth` is what bounds the stack those take.
#
# Every produced value carries its 1-based source line (`src_line`, plus
# `key_line` on an object member).
# =============================================================================

from .value import JsonValue, JSON_ARRAY, JSON_OBJECT


# The default nesting limit: how many arrays/objects deep a document may be.
# A scalar at the top level is depth 0; `[1]` is depth 1.
comptime JSON_DEFAULT_MAX_DEPTH: Int = 128

# The largest `max_depth` a caller may pass. Destroying, copying and
# serializing a `JsonValue` recurse once per nesting level, so a parsed tree
# must stay shallow enough for those to run on an ordinary thread stack; a
# `max_depth` above this is refused rather than trusted.
comptime JSON_MAX_DEPTH: Int = 1000


def parse_json_value(
    s: String, max_depth: Int = JSON_DEFAULT_MAX_DEPTH
) raises -> JsonValue:
    """Parse the JSON text `s` (see the module header for exactly what is
    accepted). Raises `JsonError: ...` on anything else, or if arrays and
    objects nest deeper than `max_depth`, or if `max_depth` is negative
    or above `JSON_MAX_DEPTH`."""
    var bytes = List[UInt8]()
    bytes.extend(Span(s.as_bytes()))
    return parse_json_bytes(bytes, max_depth)


def parse_json_bytes(
    b: List[UInt8], max_depth: Int = JSON_DEFAULT_MAX_DEPTH
) raises -> JsonValue:
    """Parse the UTF-8 JSON text `b`, as `parse_json_value`. The input is
    not assumed to be valid UTF-8: ill-formed UTF-8 inside a string is
    refused, and outside a string any non-ASCII byte is."""
    if max_depth < 0:
        raise Error("JsonError: max_depth must not be negative")
    if max_depth > JSON_MAX_DEPTH:
        raise Error(
            String("JsonError: max_depth ")
            + String(max_depth)
            + " is above the maximum of "
            + String(JSON_MAX_DEPTH)
        )
    var v = _parse_document(b, max_depth)
    return v^


# =============================================================================
# Internals.
# =============================================================================


@no_inline
def _err(b: List[UInt8], pos: Int, what: String) -> Error:
    """`JsonError: <what> at line L, byte column C` for byte offset `pos`.
    Only runs on the error path, so its O(pos) scan costs nothing on a
    successful parse."""
    var line = 1
    var col = 1
    var end = pos if pos < len(b) else len(b)
    for i in range(end):
        if b[i] == 0x0A:
            line += 1
            col = 1
        else:
            col += 1
    return Error(
        String("JsonError: ")
        + what
        + " at line "
        + String(line)
        + ", byte column "
        + String(col)
    )


@always_inline
def _is_ws(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D


@always_inline
def _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


def _skip_ws(b: List[UInt8], pos: Int) -> Int:
    var p = pos
    var n = len(b)
    while p < n and _is_ws(b[p]):
        p += 1
    return p


def _lit_eq(b: List[UInt8], pos: Int, lit: String) -> Bool:
    """True if the bytes at `pos` equal the ASCII text `lit`."""
    var l = lit.as_bytes()
    var ln = len(l)
    if pos + ln > len(b):
        return False
    for k in range(ln):
        if b[pos + k] != l[k]:
            return False
    return True


def _slice_string(b: List[UInt8], start: Int, end: Int) -> String:
    """Bytes `[start, end)` as a String (callers pass validated UTF-8)."""
    var out = List[UInt8](capacity=end - start)
    for i in range(start, end):
        out.append(b[i])
    return String(unsafe_from_utf8=Span(out))


struct _LineCursor(Copyable, Movable):
    """A monotone byte-offset -> 1-based-line resolver.

    The parser only advances, so one cursor carried through the parse
    answers every query in O(n) total; a per-query count from offset 0 would
    be quadratic in the number of values. `line_at` never walks backwards,
    so it must be queried at non-decreasing offsets, as every caller here
    does."""

    var pos: Int
    var line: Int

    def __init__(out self):
        self.pos = 0
        self.line = 1

    def line_at(mut self, b: List[UInt8], target: Int) -> Int:
        var n = len(b)
        while self.pos < target and self.pos < n:
            if b[self.pos] == 0x0A:  # '\n'
                self.line += 1
            self.pos += 1
        return self.line


struct _ParseResult(Movable):
    """A parsed value and the offset after it.

    The value is held in an `Optional` so `unwrap()` can move it out with
    `Optional.take()`, which leaves the field in a destructor-safe `None`
    state (a bare heap-owning field cannot be moved out of a struct with a
    synthesized destructor)."""

    var value: Optional[JsonValue]
    var new_pos: Int

    def __init__(out self, var value: JsonValue, new_pos: Int):
        self.value = Optional[JsonValue](value^)
        self.new_pos = new_pos

    def unwrap(mut self) -> JsonValue:
        return self.value.take()


struct _StringResult(Movable):
    var value: Optional[String]
    var new_pos: Int

    def __init__(out self, var value: String, new_pos: Int):
        self.value = Optional[String](value^)
        self.new_pos = new_pos

    def unwrap(mut self) -> String:
        return self.value.take()


# The document driver.
#
# The parser does not recurse. Open arrays and objects live on an explicit
# stack (`conts`), so the stack frames of the parse loop itself are the same
# at any nesting depth. (A recursive descent costs several KB of stack per
# level once its temporaries are laid out.) The values it builds are another
# matter: destroying a `JsonValue` recurses once per level, including when a
# parse fails part-way and unwinds what it built, which is why `max_depth`
# is capped at `JSON_MAX_DEPTH`.
#
# An object's key is appended to `obj_keys` as soon as it is read, and its
# value to `children` when that value completes, so the two stay aligned.


def _parse_document(b: List[UInt8], max_depth: Int) raises -> JsonValue:
    var n = len(b)
    var lines = _LineCursor()
    # The open containers, innermost last, and for each one the line of the
    # object key whose value is being parsed (0 for an array).
    var conts = List[JsonValue]()
    var key_lines = List[Int]()
    var p = _skip_ws(b, 0)
    while True:
        # A value starts at `p` (whitespace already skipped).
        var here = lines.line_at(b, p)
        var v: JsonValue
        var is_open = p < n and (b[p] == 0x5B or b[p] == 0x7B)  # '[' / '{'
        if is_open:
            if len(conts) >= max_depth:
                raise _depth_err(b, p, max_depth)
            var is_obj = b[p] == 0x7B
            var c = JsonValue()
            c.kind = JSON_OBJECT if is_obj else JSON_ARRAY
            c.src_line = here
            var q = _skip_ws(b, p + 1)
            var close: UInt8 = 0x7D if is_obj else 0x5D  # '}' / ']'
            if q < n and b[q] == close:
                v = c^
                p = q + 1
            else:
                conts.append(c^)
                key_lines.append(0)
                p = q
                if is_obj:
                    p = _read_key(b, p, lines, conts, key_lines)
                continue
        else:
            var r = _parse_scalar(b, p)
            p = r.new_pos
            v = r.unwrap()
            v.src_line = here
        # `v` is complete: attach it to its parent, closing every container
        # it completes, until a parent wants another value.
        while True:
            var top = len(conts) - 1
            if top < 0:
                var tail = _skip_ws(b, p)
                if tail != n:
                    raise _err(b, tail, "trailing content after the JSON value")
                return v^
            var in_obj = conts[top].kind == JSON_OBJECT
            if in_obj:
                v.key_line = key_lines[top]
            conts[top].children.append(v^)
            p = _skip_ws(b, p)
            if p >= n:
                raise _err(
                    b, p, "unterminated object" if in_obj else "unterminated array"
                )
            var ch = b[p]
            if ch == 0x2C:  # ','
                p += 1
                if in_obj:
                    p = _read_key(b, p, lines, conts, key_lines)
                else:
                    p = _skip_ws(b, p)
                break
            if in_obj and ch == 0x7D:  # '}'
                p += 1
                _ = key_lines.pop()
                v = conts.pop()
                continue
            if not in_obj and ch == 0x5D:  # ']'
                p += 1
                _ = key_lines.pop()
                v = conts.pop()
                continue
            raise _err(
                b,
                p,
                "expected ',' or '}' in object" if in_obj else "expected ',' or ']' in array",
            )


def _read_key(
    b: List[UInt8],
    pos: Int,
    mut lines: _LineCursor,
    mut conts: List[JsonValue],
    mut key_lines: List[Int],
) raises -> Int:
    """Read `"key" :` at `pos` (whitespace allowed before each token) into
    the innermost open object; return the offset of the member's value."""
    var n = len(b)
    var p = _skip_ws(b, pos)
    if p >= n or b[p] != 0x22:
        raise _err(b, p, "expected a string object key")
    # The key's line, read at its opening quote, before the value.
    var top = len(conts) - 1
    key_lines[top] = lines.line_at(b, p)
    var key = _parse_string(b, p)
    p = _skip_ws(b, key.new_pos)
    if p >= n or b[p] != 0x3A:  # ':'
        raise _err(b, p, "expected ':' after object key")
    conts[top].obj_keys.append(key.unwrap())
    return _skip_ws(b, p + 1)



@no_inline
def _depth_err(b: List[UInt8], pos: Int, limit: Int) -> Error:
    return _err(
        b, pos, String("nesting deeper than the limit of ") + String(limit)
    )


@no_inline
def _parse_scalar(b: List[UInt8], pos: Int) raises -> _ParseResult:
    """Parse a string, literal or number at `pos`; raise on anything else
    (including the end of input)."""
    if pos >= len(b):
        raise _err(b, pos, "unexpected end of input")
    var c = b[pos]
    if c == 0x22:  # '"'
        var sr = _parse_string(b, pos)
        var sr_pos = sr.new_pos
        return _ParseResult(JsonValue.from_string(sr.unwrap()), sr_pos)
    if c == 0x74:  # 't'
        if _lit_eq(b, pos, String("true")):
            return _ParseResult(JsonValue.from_bool(True), pos + 4)
        raise _err(b, pos, "malformed literal (expected 'true')")
    if c == 0x66:  # 'f'
        if _lit_eq(b, pos, String("false")):
            return _ParseResult(JsonValue.from_bool(False), pos + 5)
        raise _err(b, pos, "malformed literal (expected 'false')")
    if c == 0x6E:  # 'n'
        if _lit_eq(b, pos, String("null")):
            return _ParseResult(JsonValue.null(), pos + 4)
        raise _err(b, pos, "malformed literal (expected 'null')")
    if c == 0x2D or _is_digit(c):  # '-' or a digit
        return _parse_number(b, pos)
    raise _err(b, pos, "unexpected character at the start of a value")


def _parse_number(b: List[UInt8], pos: Int) raises -> _ParseResult:
    """Parse a number per the RFC 8259 §6 grammar; keep its text."""
    var n = len(b)
    var p = pos
    if b[p] == 0x2D:  # '-'
        p += 1
    if p >= n or not _is_digit(b[p]):
        raise _err(b, p, "expected a digit in number")
    if b[p] == 0x30:  # '0' must stand alone
        p += 1
        if p < n and _is_digit(b[p]):
            raise _err(b, p, "leading zero in number")
    else:
        while p < n and _is_digit(b[p]):
            p += 1
    if p < n and b[p] == 0x2E:  # '.'
        p += 1
        if p >= n or not _is_digit(b[p]):
            raise _err(b, p, "expected a digit after '.' in number")
        while p < n and _is_digit(b[p]):
            p += 1
    if p < n and (b[p] == 0x65 or b[p] == 0x45):  # 'e' / 'E'
        p += 1
        if p < n and (b[p] == 0x2B or b[p] == 0x2D):  # '+' / '-'
            p += 1
        if p >= n or not _is_digit(b[p]):
            raise _err(b, p, "expected a digit in number exponent")
        while p < n and _is_digit(b[p]):
            p += 1
    return _ParseResult(JsonValue.from_number(_slice_string(b, pos, p)), p)


def _hex4(b: List[UInt8], pos: Int) raises -> Int:
    """The 4-hex-digit code unit at `pos`."""
    if pos + 4 > len(b):
        raise _err(b, pos, "truncated \\u escape")
    var acc = 0
    for k in range(4):
        var c = b[pos + k]
        var d: Int
        if c >= 0x30 and c <= 0x39:
            d = Int(c) - 0x30
        elif c >= 0x41 and c <= 0x46:
            d = Int(c) - 0x41 + 10
        elif c >= 0x61 and c <= 0x66:
            d = Int(c) - 0x61 + 10
        else:
            raise _err(b, pos + k, "bad hex digit in \\u escape")
        acc = (acc << 4) | d
    return acc


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Append scalar value `cp` (never a surrogate) as UTF-8."""
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


def _utf8_len(b: List[UInt8], p: Int) raises -> Int:
    """The length of the well-formed UTF-8 sequence starting at `p` (whose
    lead byte is >= 0x80), per the Unicode well-formed byte table: no
    overlong forms, no encoded surrogates, nothing above U+10FFFF."""
    var n = len(b)
    var c0 = b[p]
    var ln: Int
    var lo: UInt8 = 0x80  # allowed range of the SECOND byte
    var hi: UInt8 = 0xBF
    if c0 >= 0xC2 and c0 <= 0xDF:
        ln = 2
    elif c0 == 0xE0:
        ln = 3
        lo = 0xA0
    elif (c0 >= 0xE1 and c0 <= 0xEC) or c0 == 0xEE or c0 == 0xEF:
        ln = 3
    elif c0 == 0xED:
        ln = 3
        hi = 0x9F
    elif c0 == 0xF0:
        ln = 4
        lo = 0x90
    elif c0 >= 0xF1 and c0 <= 0xF3:
        ln = 4
    elif c0 == 0xF4:
        ln = 4
        hi = 0x8F
    else:
        raise _err(b, p, "invalid UTF-8 lead byte in string")
    if p + ln > n:
        raise _err(b, p, "truncated UTF-8 sequence in string")
    if b[p + 1] < lo or b[p + 1] > hi:
        raise _err(b, p, "ill-formed UTF-8 sequence in string")
    for k in range(2, ln):
        if b[p + k] < 0x80 or b[p + k] > 0xBF:
            raise _err(b, p, "ill-formed UTF-8 sequence in string")
    return ln


@no_inline
def _parse_string(b: List[UInt8], pos: Int) raises -> _StringResult:
    """Parse a string literal at its opening `"`; the value is the
    unescaped UTF-8 content."""
    var n = len(b)
    var p = pos + 1
    var out = List[UInt8]()
    while p < n:
        var c = b[p]
        if c == 0x22:  # closing '"'
            return _StringResult(String(unsafe_from_utf8=Span(out)), p + 1)
        if c == 0x5C:  # '\'
            p += 1
            if p >= n:
                raise _err(b, p, "unterminated escape in string")
            var e = b[p]
            if e == 0x22:
                out.append(0x22)
            elif e == 0x5C:
                out.append(0x5C)
            elif e == 0x2F:  # '/'
                out.append(0x2F)
            elif e == 0x62:  # 'b'
                out.append(0x08)
            elif e == 0x66:  # 'f'
                out.append(0x0C)
            elif e == 0x6E:  # 'n'
                out.append(0x0A)
            elif e == 0x72:  # 'r'
                out.append(0x0D)
            elif e == 0x74:  # 't'
                out.append(0x09)
            elif e == 0x75:  # 'u'
                var cp = _hex4(b, p + 1)
                p += 4  # at the last hex digit
                if cp >= 0xD800 and cp <= 0xDBFF:
                    # A high surrogate: a low one must follow as `\uXXXX`.
                    if p + 2 < n and b[p + 1] == 0x5C and b[p + 2] == 0x75:
                        var lo = _hex4(b, p + 3)
                        if lo < 0xDC00 or lo > 0xDFFF:
                            raise _err(
                                b,
                                p - 5,
                                "high surrogate \\u escape not followed by a low surrogate",
                            )
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        p += 6
                    else:
                        raise _err(
                            b, p - 5, "lone high surrogate \\u escape"
                        )
                elif cp >= 0xDC00 and cp <= 0xDFFF:
                    raise _err(b, p - 5, "lone low surrogate \\u escape")
                _append_utf8(out, cp)
            else:
                raise _err(b, p - 1, "invalid escape in string")
            p += 1
        elif c < 0x20:
            raise _err(b, p, "unescaped control character in string")
        elif c < 0x80:
            out.append(c)
            p += 1
        else:
            var ln = _utf8_len(b, p)
            for k in range(ln):
                out.append(b[p + k])
            p += ln
    raise _err(b, pos, "unterminated string")
