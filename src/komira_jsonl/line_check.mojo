# =============================================================================
# line_check.mojo -- every JSONL line is blank or exactly one JSON object
# =============================================================================
#
# The JSONL reader (`columnar_materializer`) walks only the Stage 1 tape
# (structural characters and quotes) and parses only the values the schema
# reads. On its own it would skip a line holding a non-object value, skip
# the bytes of keys the schema does not read, and never look at string
# contents. This module checks the whole input against RFC 8259 and the
# JSONL line rule BEFORE any row is built, so a reader either returns rows
# for all of the input or raises naming the first bad line.
#
# What is accepted, per line (a line ends at a raw LF, 0x0A):
#   - a blank line: only space, tab and CR (and the LF). Skipped; no row.
#   - exactly one JSON object, with optional whitespace around it, that
#     opens and closes on that line (a raw LF can not appear inside a JSON
#     string, so an object that continues past its LF is refused).
# Inside the object the grammar is RFC 8259's: string keys, `:`, commas
# between members and elements and none trailing, the literals `true`,
# `false`, `null`, numbers `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]?
# [0-9]+)?`, strings with no raw byte below 0x20, only the escapes
# `\" \\ \/ \b \f \n \r \t \uXXXX`, a `\u` high surrogate followed by a
# `\u` low surrogate (a lone surrogate on either side is refused, as
# komira_json and the reader's string unescaper refuse it), and raw
# non-ASCII bytes that are well-formed UTF-8. A byte-order mark is not
# whitespace, so a file starting with one is refused (komira_json refuses
# it too).
#
# The error, raised by `check_jsonl_lines`, is
#   `komira_jsonl: line <N>: <the line is not a JSON object | not valid
#   JSON>: <what>`
# where N is 1-based: one plus the number of LF bytes before the offending
# byte (plus the lines before the slice, for a partition or a chunk).
#
# Cost: one walk of the tape the reader already built (no second Stage 1
# index, no value tree), plus the bytes outside the tape's quotes (the
# whitespace and scalars between structural characters) and the bytes of
# each string, which are skipped 16 at a time when none of them is a
# control byte, a backslash or non-ASCII. The line number is computed only
# when there is an error.
# =============================================================================

from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_COLON,
    TAG_COMMA,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from komira_json_index.structural_index import (
    StructuralIndex,
    build_structural_index,
)


# What the walk expects next.
comptime _E_RECORD: UInt8 = 0       # between records (depth 0)
comptime _E_KEY_OR_CLOSE: UInt8 = 1  # after `{`
comptime _E_KEY: UInt8 = 2           # after `,` in an object
comptime _E_COLON: UInt8 = 3         # after a key
comptime _E_VALUE: UInt8 = 4         # after `:` or `,` in an array
comptime _E_VALUE_OR_CLOSE: UInt8 = 5  # after `[`
comptime _E_COMMA_OR_CLOSE: UInt8 = 6  # after a value inside a container

comptime _K_OBJECT: UInt8 = 1
comptime _K_ARRAY: UInt8 = 2

# The two kinds of fault; the first words of the error after the line.
comptime NOT_AN_OBJECT = "the line is not a JSON object"
comptime NOT_VALID_JSON = "the line is not valid JSON"


struct JsonlFault(Copyable, Movable):
    """The first fault in a JSONL slice: the byte `offset` it is at
    (relative to the slice), its kind (`NOT_AN_OBJECT` or `NOT_VALID_JSON`)
    and what was found. `offset < 0` means none."""

    var offset: Int
    var kind: String
    var what: String

    def __init__(out self):
        self.offset = -1
        self.kind = String()
        self.what = String()

    def __init__(out self, offset: Int, kind: String, what: String):
        self.offset = offset
        self.kind = kind
        self.what = what

    def found(self) -> Bool:
        return self.offset >= 0


@always_inline
def _is_ws(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= 0x30 and b <= 0x39


def count_lf(bytes: Span[UInt8, _]) -> Int:
    """The number of LF (0x0A) bytes in `bytes`. Error path only."""
    var n = 0
    for i in range(len(bytes)):
        if bytes[i] == 0x0A:
            n += 1
    return n


def _byte_text(b: UInt8) -> String:
    """`b` for an error message: the character when printable ASCII, the
    hex value otherwise."""
    if b >= 0x21 and b <= 0x7E:
        return String("'") + chr(Int(b)) + "'"
    var hex = String("0123456789ABCDEF")
    var hb = hex.as_bytes()
    var out = String("byte 0x")
    out += chr(Int(hb[Int(b >> 4)]))
    out += chr(Int(hb[Int(b & 0x0F)]))
    return out^


def _scalar_end(bytes: Span[UInt8, _], start: Int, end: Int) -> Int:
    """The end of the JSON literal or number at `start` (exclusive), or -1
    when the bytes at `start` do not begin one. Stops at `end`. A literal or
    number must be followed by whitespace, a structural character or `end`;
    the caller checks what follows."""
    var c = bytes[start]
    if c == 0x74:  # true
        if start + 4 <= end and bytes[start + 1] == 0x72 and bytes[start + 2] == 0x75 and bytes[start + 3] == 0x65:
            return start + 4
        return -1
    if c == 0x66:  # false
        if start + 5 <= end and bytes[start + 1] == 0x61 and bytes[start + 2] == 0x6C and bytes[start + 3] == 0x73 and bytes[start + 4] == 0x65:
            return start + 5
        return -1
    if c == 0x6E:  # null
        if start + 4 <= end and bytes[start + 1] == 0x75 and bytes[start + 2] == 0x6C and bytes[start + 3] == 0x6C:
            return start + 4
        return -1
    var i = start
    if bytes[i] == 0x2D:  # '-'
        i += 1
    if i >= end:
        return -1
    if bytes[i] == 0x30:
        i += 1
    elif bytes[i] >= 0x31 and bytes[i] <= 0x39:
        while i < end and _is_digit(bytes[i]):
            i += 1
    else:
        return -1
    if i < end and bytes[i] == 0x2E:  # '.'
        i += 1
        if i >= end or not _is_digit(bytes[i]):
            return -1
        while i < end and _is_digit(bytes[i]):
            i += 1
    if i < end and (bytes[i] == 0x65 or bytes[i] == 0x45):  # e E
        i += 1
        if i < end and (bytes[i] == 0x2B or bytes[i] == 0x2D):
            i += 1
        if i >= end or not _is_digit(bytes[i]):
            return -1
        while i < end and _is_digit(bytes[i]):
            i += 1
    return i


@always_inline
def _hex_val(b: UInt8) -> Int:
    if b >= 0x30 and b <= 0x39:
        return Int(b) - 0x30
    if b >= 0x61 and b <= 0x66:
        return Int(b) - 0x61 + 10
    if b >= 0x41 and b <= 0x46:
        return Int(b) - 0x41 + 10
    return -1


def _u_escape(bytes: Span[UInt8, _], at: Int, end: Int) -> Int:
    """The code unit of the four hex digits at `at`, or -1."""
    if at + 4 > end:
        return -1
    var v = 0
    for k in range(4):
        var h = _hex_val(bytes[at + k])
        if h < 0:
            return -1
        v = v * 16 + h
    return v


def _utf8_len(bytes: Span[UInt8, _], i: Int, end: Int) -> Int:
    """The length of the well-formed UTF-8 sequence whose lead byte (>= 0x80)
    is at `i`, or -1 (RFC 3629 table: no overlong form, no surrogate, nothing
    above U+10FFFF)."""
    var b0 = bytes[i]
    var n: Int
    var lo: UInt8 = 0x80
    var hi: UInt8 = 0xBF
    if b0 >= 0xC2 and b0 <= 0xDF:
        n = 2
    elif b0 == 0xE0:
        n = 3
        lo = 0xA0
    elif (b0 >= 0xE1 and b0 <= 0xEC) or b0 == 0xEE or b0 == 0xEF:
        n = 3
    elif b0 == 0xED:
        n = 3
        hi = 0x9F
    elif b0 == 0xF0:
        n = 4
        lo = 0x90
    elif b0 >= 0xF1 and b0 <= 0xF3:
        n = 4
    elif b0 == 0xF4:
        n = 4
        hi = 0x8F
    else:
        return -1
    if i + n > end:
        return -1
    var b1 = bytes[i + 1]
    if b1 < lo or b1 > hi:
        return -1
    for k in range(2, n):
        var bk = bytes[i + k]
        if bk < 0x80 or bk > 0xBF:
            return -1
    return n


def _check_string(bytes: Span[UInt8, _], start: Int, end: Int) -> JsonlFault:
    """Check the body `bytes[start:end]` of one string (between its quotes)."""
    var i = start
    var n_end = end
    # SAFETY: `p` points into `bytes`, which outlives this call; every load
    # reads 16 bytes at `i` with `i + 16 <= n_end <= len(bytes)`. The pointer
    # stays in this function.
    var p = bytes.unsafe_ptr()
    var lo = SIMD[DType.uint8, 16](0x20)
    var hi = SIMD[DType.uint8, 16](0x80)
    var bs = SIMD[DType.uint8, 16](0x5C)
    var ones = SIMD[DType.uint8, 16](0xFF)
    var zeros = SIMD[DType.uint8, 16](0x00)
    while i < n_end:
        # Fast path: 16 bytes with no control byte, no backslash and no
        # non-ASCII byte need no further look.
        if i + 16 <= n_end:
            var v = (p + i).load[width=16](0)
            var special = (
                v.lt(lo).select(ones, zeros)
                | v.ge(hi).select(ones, zeros)
                | v.eq(bs).select(ones, zeros)
            )
            if special.reduce_or() == 0:
                i += 16
                continue
        var c = bytes[i]
        if c < 0x20:
            return JsonlFault(
                i, NOT_VALID_JSON,
                String("a raw control ") + _byte_text(c)
                + " inside a string (it must be escaped)",
            )
        if c == 0x5C:
            if i + 1 >= n_end:
                return JsonlFault(i, NOT_VALID_JSON, "a string ends in a backslash")
            var e = bytes[i + 1]
            if e == 0x22 or e == 0x5C or e == 0x2F or e == 0x62 or e == 0x66 or e == 0x6E or e == 0x72 or e == 0x74:
                i += 2
                continue
            if e != 0x75:
                return JsonlFault(
                    i, NOT_VALID_JSON,
                    String("the escape '\\") + chr(Int(e)) + "' is not a JSON escape"
                    if e >= 0x21 and e <= 0x7E
                    else String("a backslash followed by ") + _byte_text(e),
                )
            var cu = _u_escape(bytes, i + 2, n_end)
            if cu < 0:
                return JsonlFault(i, NOT_VALID_JSON, "a \\u escape without four hex digits")
            if cu >= 0xDC00 and cu <= 0xDFFF:
                return JsonlFault(i, NOT_VALID_JSON, "a lone low surrogate \\u escape")
            if cu >= 0xD800 and cu <= 0xDBFF:
                var j = i + 6
                if j + 1 >= n_end or bytes[j] != 0x5C or bytes[j + 1] != 0x75:
                    return JsonlFault(
                        i, NOT_VALID_JSON,
                        "a high surrogate \\u escape not followed by a \\u low surrogate",
                    )
                var lo_cu = _u_escape(bytes, j + 2, n_end)
                if lo_cu < 0xDC00 or lo_cu > 0xDFFF:
                    return JsonlFault(
                        i, NOT_VALID_JSON,
                        "a high surrogate \\u escape not followed by a \\u low surrogate",
                    )
                i += 12
                continue
            i += 6
            continue
        if c >= 0x80:
            var n = _utf8_len(bytes, i, n_end)
            if n < 0:
                return JsonlFault(
                    i, NOT_VALID_JSON,
                    String("ill-formed UTF-8 at ") + _byte_text(c) + " inside a string",
                )
            i += n
            continue
        i += 1
    return JsonlFault()


def find_jsonl_fault(
    bytes: Span[UInt8, _], ref idx: StructuralIndex
) -> JsonlFault:
    """The first place where `bytes` (with `idx`, its Stage 1 tape) is not a
    sequence of lines each blank or holding one JSON object (module header).
    Returns a fault with `offset < 0` when there is none."""
    var tape_len = idx.size()
    var input_len = len(bytes)
    var stack = List[UInt8](capacity=16)
    var state = _E_RECORD
    # A record closed on the current line, so only whitespace may follow
    # until the LF.
    var line_has_record = False
    var pos = 0  # the first byte not yet checked
    var t = 0
    while True:
        var off: Int
        var tag: UInt8
        if t < tape_len:
            off = Int(idx.offsets[t])
            tag = idx.tags[t]
        else:
            off = input_len
            tag = 0  # end of input
        # --- the bytes between the previous token and this one ---
        if state == _E_RECORD:
            var i = pos
            while i < off:
                var c = bytes[i]
                if c == 0x0A:
                    line_has_record = False
                elif not _is_ws(c):
                    if line_has_record:
                        return JsonlFault(
                            i, NOT_VALID_JSON,
                            String("content after the object: ") + _byte_text(c),
                        )
                    return JsonlFault(
                        i, NOT_AN_OBJECT,
                        String("it starts with ") + _byte_text(c)
                        + "; a JSONL record must be one JSON object",
                    )
                i += 1
        else:
            var i = pos
            if state == _E_VALUE or state == _E_VALUE_OR_CLOSE:
                while i < off and _is_ws(bytes[i]) and bytes[i] != 0x0A:
                    i += 1
                if i < off and bytes[i] != 0x0A:
                    var se = _scalar_end(bytes, i, off)
                    if se < 0:
                        return JsonlFault(
                            i, NOT_VALID_JSON,
                            String("expected a value, found ") + _byte_text(bytes[i]),
                        )
                    i = se
                    state = _E_COMMA_OR_CLOSE
            while i < off:
                var c = bytes[i]
                if c == 0x0A:
                    return JsonlFault(
                        i, NOT_VALID_JSON,
                        "the object does not end on its line (a JSONL record is one line)",
                    )
                if not _is_ws(c):
                    return JsonlFault(
                        i, NOT_VALID_JSON,
                        String("unexpected ") + _byte_text(c),
                    )
                i += 1
        if t >= tape_len:
            break
        # --- the structural token at `off` ---
        pos = off + 1
        t += 1
        if state == _E_RECORD:
            if line_has_record:
                return JsonlFault(
                    off, NOT_VALID_JSON,
                    String("content after the object: ") + _byte_text(bytes[off]),
                )
            if tag != TAG_OPEN_BRACE:
                return JsonlFault(
                    off, NOT_AN_OBJECT,
                    String("it starts with ") + _byte_text(bytes[off])
                    + "; a JSONL record must be one JSON object",
                )
            stack.append(_K_OBJECT)
            state = _E_KEY_OR_CLOSE
            continue
        if tag == TAG_QUOTE_OPEN:
            if state != _E_KEY_OR_CLOSE and state != _E_KEY and state != _E_VALUE and state != _E_VALUE_OR_CLOSE:
                return JsonlFault(off, NOT_VALID_JSON, "unexpected string")
            # Stage 1 pairs every open quote with a close quote.
            var close = Int(idx.offsets[t])
            t += 1
            var f = _check_string(bytes, off + 1, close)
            if f.found():
                return f^
            pos = close + 1
            if state == _E_KEY_OR_CLOSE or state == _E_KEY:
                state = _E_COLON
            else:
                state = _E_COMMA_OR_CLOSE
            continue
        if tag == TAG_COLON:
            if state != _E_COLON:
                return JsonlFault(off, NOT_VALID_JSON, "unexpected ':'")
            state = _E_VALUE
            continue
        if tag == TAG_OPEN_BRACE or tag == TAG_OPEN_BRACKET:
            if state != _E_VALUE and state != _E_VALUE_OR_CLOSE:
                return JsonlFault(
                    off, NOT_VALID_JSON,
                    String("unexpected ") + _byte_text(bytes[off]),
                )
            if tag == TAG_OPEN_BRACE:
                stack.append(_K_OBJECT)
                state = _E_KEY_OR_CLOSE
            else:
                stack.append(_K_ARRAY)
                state = _E_VALUE_OR_CLOSE
            continue
        if tag == TAG_COMMA:
            if state != _E_COMMA_OR_CLOSE:
                return JsonlFault(off, NOT_VALID_JSON, "unexpected ','")
            state = _E_KEY if stack[len(stack) - 1] == _K_OBJECT else _E_VALUE
            continue
        if tag == TAG_CLOSE_BRACE or tag == TAG_CLOSE_BRACKET:
            var want = _K_OBJECT if tag == TAG_CLOSE_BRACE else _K_ARRAY
            var ok_state = state == _E_COMMA_OR_CLOSE or (
                tag == TAG_CLOSE_BRACE and state == _E_KEY_OR_CLOSE
            ) or (tag == TAG_CLOSE_BRACKET and state == _E_VALUE_OR_CLOSE)
            if not ok_state or stack[len(stack) - 1] != want:
                return JsonlFault(
                    off, NOT_VALID_JSON,
                    String("unexpected ") + _byte_text(bytes[off]),
                )
            _ = stack.pop()
            if len(stack) == 0:
                state = _E_RECORD
                line_has_record = True
            else:
                state = _E_COMMA_OR_CLOSE
            continue
        # TAG_QUOTE_CLOSE is consumed with its open quote; any other tag is
        # not one Stage 1 emits.
        return JsonlFault(off, NOT_VALID_JSON, String("unexpected ") + _byte_text(bytes[off]))
    if state != _E_RECORD:
        return JsonlFault(
            input_len - 1 if input_len > 0 else 0, NOT_VALID_JSON,
            "the object is not closed before the end of the input",
        )
    return JsonlFault()


def jsonl_line_error(
    bytes: Span[UInt8, _],
    offset: Int,
    before: Span[UInt8, _],
    lines_before: Int,
    kind: String,
    what: String,
) -> Error:
    """The error for a fault at `offset` of `bytes`: its 1-based line is
    `lines_before` + the LF bytes in `before` (the bytes of the same input
    that precede `bytes`) + the LF bytes in `bytes[:offset]` + 1."""
    var line = lines_before + count_lf(before) + count_lf(bytes[:offset]) + 1
    return Error(
        String("komira_jsonl: line ") + String(line) + ": " + kind + ": " + what
    )


def check_jsonl_lines(
    bytes: Span[UInt8, _],
    ref idx: StructuralIndex,
    before: Span[UInt8, _],
    lines_before: Int,
) raises:
    """Raise `komira_jsonl: line N: ...` at the first fault in `bytes`
    (module header). `before` and `lines_before` place `bytes` in its input
    for the line number (`jsonl_line_error`)."""
    var f = find_jsonl_fault(bytes, idx)
    if f.found():
        raise jsonl_line_error(bytes, f.offset, before, lines_before, f.kind, f.what)


def _unterminated_string_offset(bytes: Span[UInt8, _]) -> Int:
    """The offset of the first byte at which a string is still open at the
    end of its line (the LF ending it, or the last byte of the input): where
    a line with an unclosed string is. Error path only."""
    var in_string = False
    var i = 0
    while i < len(bytes):
        var c = bytes[i]
        if in_string:
            if c == 0x5C:
                i += 2
                continue
            if c == 0x22:
                in_string = False
            elif c == 0x0A:
                return i
        elif c == 0x22:
            in_string = True
        i += 1
    return len(bytes) - 1 if len(bytes) > 0 else 0


def build_jsonl_index(
    bytes: Span[UInt8, _], before: Span[UInt8, _], lines_before: Int
) raises -> StructuralIndex:
    """`build_structural_index(bytes)`, with its one input error (a string
    still open at the end of the input) re-raised naming the first line
    whose string does not close on it. `before` and `lines_before` as in
    `check_jsonl_lines`."""
    try:
        return build_structural_index(bytes)
    except e:
        var msg = String(e)
        if "unterminated string" not in msg:
            raise e^
        raise jsonl_line_error(
            bytes, _unterminated_string_offset(bytes), before, lines_before,
            NOT_VALID_JSON, "a string is not closed on its line",
        )
