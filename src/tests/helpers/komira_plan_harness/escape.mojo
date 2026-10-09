# =============================================================================
# komira_plan_harness/escape.mojo -- the escapes of canonical result text.
# =============================================================================
#
# A cell is exactly `\N` for NULL and nothing else is: every backslash in a
# value is written `\\`, so the string `\N` is the cell `\\N`. Also escaped:
# TAB `\t`, LF `\n`, CR `\r`, any other control byte (and DEL) `\xHH`, and a
# byte that is not part of well-formed UTF-8 `\xHH`, so a string column whose
# bytes are not UTF-8 still renders losslessly.
#
# Inside a nested value (list, struct, map, union) the bracket syntax is also
# escaped in leaf strings: `\,` `\:` `\[` `\]` `\{` `\}` `\(` `\)`. A NULL
# inside a nested value is the token `\N`.
#
# Names (in the schema line, inside the type tree, as struct keys inside a
# nested cell, in `order: keys=` and `float[<name>]:`) escape the same control
# bytes plus `\:` `\,` `\<` `\>` `\[` `\]` `\{` `\}` `\(` `\)`, and a
# LEADING `#` as `\#` (a schema line must not read as a comment line).
#
# `\xHH` is lower-case hex, and only for a byte canon escapes that way: a
# control byte other than TAB/LF/CR, DEL, or a byte >= 0x80 that does not
# start well-formed UTF-8 with the bytes after it. The parser refuses any
# other escape, in scalar cells and in nested cells alike.
# =============================================================================


def _hex_lower(v: Int) -> UInt8:
    if v < 10:
        return UInt8(48 + v)
    return UInt8(87 + v)


def append_text(mut res: List[UInt8], s: String):
    for b in s.as_bytes():
        res.append(b)


def _push_hex_escape(mut res: List[UInt8], b: UInt8):
    res.append(92)  # '\'
    res.append(120)  # 'x'
    res.append(_hex_lower(Int(b >> 4)))
    res.append(_hex_lower(Int(b & 0xF)))


def _utf8_len(bs: Span[UInt8, _], i: Int) -> Int:
    """Length of the well-formed UTF-8 sequence at `i`, or 0 if the bytes
    there are not one (RFC 3629: no overlongs, no surrogates, <= U+10FFFF)."""
    var n = len(bs)
    var b0 = bs[i]
    if b0 < 0x80:
        return 1
    var need: Int
    var lo: UInt8 = 0x80
    var hi: UInt8 = 0xBF
    if b0 >= 0xC2 and b0 <= 0xDF:
        need = 2
    elif b0 >= 0xE0 and b0 <= 0xEF:
        need = 3
        if b0 == 0xE0:
            lo = 0xA0
        elif b0 == 0xED:
            hi = 0x9F
    elif b0 >= 0xF0 and b0 <= 0xF4:
        need = 4
        if b0 == 0xF0:
            lo = 0x90
        elif b0 == 0xF4:
            hi = 0x8F
    else:
        return 0
    if i + need > n:
        return 0
    var b1 = bs[i + 1]
    if b1 < lo or b1 > hi:
        return 0
    for k in range(2, need):
        var bk = bs[i + k]
        if bk < 0x80 or bk > 0xBF:
            return 0
    return need


def _is_struct_byte(b: UInt8) -> Bool:
    # , : [ ] { } ( )
    return (
        b == 44 or b == 58 or b == 91 or b == 93 or b == 123 or b == 125
        or b == 40 or b == 41
    )


def _is_name_struct_byte(b: UInt8) -> Bool:
    # : , < > [ ] { } ( )
    return (
        b == 58 or b == 44 or b == 60 or b == 62 or b == 91 or b == 93
        or b == 123 or b == 125 or b == 40 or b == 41
    )


comptime ESC_SCALAR: Int = 0
comptime ESC_NESTED: Int = 1
comptime ESC_NAME: Int = 2


def escape_bytes_into(mut res: List[UInt8], bs: Span[UInt8, _], mode: Int):
    """Append the escaped text of a value's (or name's) bytes; `mode` is
    ESC_SCALAR, ESC_NESTED or ESC_NAME (see the module header)."""
    var i = 0
    var n = len(bs)
    while i < n:
        var b = bs[i]
        if b == 92:  # backslash
            res.append(92)
            res.append(92)
            i += 1
        elif b == 9:
            res.append(92)
            res.append(116)  # t
            i += 1
        elif b == 10:
            res.append(92)
            res.append(110)  # n
            i += 1
        elif b == 13:
            res.append(92)
            res.append(114)  # r
            i += 1
        elif b < 32 or b == 127:
            _push_hex_escape(res, b)
            i += 1
        elif (mode == ESC_NESTED and _is_struct_byte(b)) or (
            mode == ESC_NAME and (_is_name_struct_byte(b) or (i == 0 and b == 35))
        ):
            res.append(92)
            res.append(b)
            i += 1
        elif b < 0x80:
            res.append(b)
            i += 1
        else:
            var k = _utf8_len(bs, i)
            if k == 0:
                _push_hex_escape(res, b)
                i += 1
            else:
                for j in range(k):
                    res.append(bs[i + j])
                i += k


def _bytes_to_string(res: List[UInt8]) -> String:
    """`res` holds escaped text only: ASCII plus well-formed UTF-8."""
    return String(unsafe_from_utf8=Span(res))


def escape_string(s: String, nested: Bool) -> String:
    var res = List[UInt8]()
    escape_bytes_into(res, s.as_bytes(), ESC_NESTED if nested else ESC_SCALAR)
    return _bytes_to_string(res)


def escape_name(s: String) -> String:
    """A column or child name as written in the schema line and header.
    Escaping is injective, so canon compares names in this form and never
    unescapes them."""
    var res = List[UInt8]()
    escape_bytes_into(res, s.as_bytes(), ESC_NAME)
    return _bytes_to_string(res)


def _hex_val(b: UInt8) -> Int:
    """A LOWER-case hex digit's value, else -1."""
    if b >= 48 and b <= 57:
        return Int(b) - 48
    if b >= 97 and b <= 102:
        return Int(b) - 87
    return -1


def _byte_at(bs: Span[UInt8, _], j: Int, mut after: Int) -> Int:
    """The byte the escaped text at `j` stands for, setting `after` to where
    the following one starts; -1 for an escape that names no byte. A
    structural escape (`\\,` and the like) stands for its ASCII byte."""
    var n = len(bs)
    if bs[j] != 92:
        after = j + 1
        return Int(bs[j])
    if j + 1 >= n:
        after = n
        return -1
    var c = bs[j + 1]
    after = j + 2
    if c == 120:
        if j + 3 >= n:
            after = n
            return -1
        var h = _hex_val(bs[j + 2])
        var l = _hex_val(bs[j + 3])
        if h < 0 or l < 0:
            return -1
        after = j + 4
        return h * 16 + l
    if c == 116:
        return 9
    if c == 110:
        return 10
    if c == 114:
        return 13
    return Int(c)


def _canon_hex_escape(bs: Span[UInt8, _], i: Int) -> Bool:
    """Is `\\xHH` at `i` one canon writes: lower-case hex, for a control
    byte other than TAB/LF/CR, DEL, or a byte >= 0x80 that does not start a
    well-formed UTF-8 sequence with the bytes the text after it stands for
    (canon writes such a sequence raw)?"""
    if i + 3 >= len(bs):
        return False
    var h = _hex_val(bs[i + 2])
    var l = _hex_val(bs[i + 3])
    if h < 0 or l < 0:
        return False
    var v = h * 16 + l
    if v == 9 or v == 10 or v == 13:
        return False
    if v < 32 or v == 127:
        return True
    if v < 128:
        return False
    var seq = InlineArray[UInt8, 4](fill=UInt8(0))
    seq[0] = UInt8(v)
    var count = 1
    var j = i + 4
    while count < 4 and j < len(bs):
        var after = j
        var b = _byte_at(bs, j, after)
        if b < 0:
            break
        seq[count] = UInt8(b)
        count += 1
        j = after
    return _utf8_len(Span(seq)[:count], 0) == 0


def _is_open(b: UInt8) -> Bool:
    return b == 91 or b == 123 or b == 40


def _closer_of(b: UInt8) -> UInt8:
    if b == 91:
        return 93
    if b == 123:
        return 125
    return 41


def _null_left_ok(prev: UInt8) -> Bool:
    # start of a value: after an opener, `,` or `:`
    return prev == 0 or _is_open(prev) or prev == 44 or prev == 58


def _null_right_ok(nb: UInt8) -> Bool:
    return nb == 0 or nb == 44 or nb == 58 or nb == 93 or nb == 125 or nb == 41


def check_nested_cell(cell: String) raises:
    """Refuse a nested cell canon would not write: unbalanced or mismatched
    brackets, text outside the outer brackets, an escape canon does not write,
    or `\\N` that is not a whole value."""
    if cell == "\\N":
        return
    var bs = cell.as_bytes()
    var n = len(bs)
    if n == 0 or not _is_open(bs[0]):
        raise Error("canon: nested cell '" + cell + "' is not \\N or a bracketed value")
    var stack = List[UInt8]()
    var prev: UInt8 = 0  # the last unescaped structural byte, 0 at the start
    var i = 0
    while i < n:
        var b = bs[i]
        if len(stack) == 0 and i > 0:
            raise Error("canon: nested cell '" + cell + "' has text after its value")
        if b == 92:
            if i + 1 >= n:
                raise Error("canon: nested cell '" + cell + "' ends inside an escape")
            var c = bs[i + 1]
            if c == 78:  # \N: a NULL value, whole
                var nxt: UInt8 = 0
                if i + 2 < n:
                    nxt = bs[i + 2]
                if not (_null_left_ok(prev) and _null_right_ok(nxt)):
                    raise Error("canon: nested cell '" + cell + "' holds \\N inside a value")
                prev = 78
                i += 2
                continue
            if c == 120:
                if not _canon_hex_escape(bs, i):
                    raise Error("canon: nested cell '" + cell + "' has a \\x escape canon does not write")
                prev = 1
                i += 4
                continue
            if not (
                c == 92 or c == 116 or c == 110 or c == 114 or c == 35
                or _is_name_struct_byte(c)
            ):
                raise Error("canon: nested cell '" + cell + "' has an unknown escape")
            prev = 1  # an escaped byte is value text
            i += 2
            continue
        if _is_open(b):
            stack.append(_closer_of(b))
            prev = b
        elif b == 93 or b == 125 or b == 41:
            if len(stack) == 0 or stack[len(stack) - 1] != b:
                raise Error("canon: nested cell '" + cell + "' has a mismatched bracket")
            _ = stack.pop()
            prev = b
        elif b == 44 or b == 58:
            prev = b
        else:
            prev = b
        i += 1
    if len(stack) != 0:
        raise Error("canon: nested cell '" + cell + "' has an unclosed bracket")


def check_scalar_cell(cell: String) raises:
    """Refuse a top-level scalar cell whose escapes are not canon's: anything
    but `\\N` that holds `\\N`, a lone backslash, or an unknown escape."""
    if cell == "\\N":
        return
    var bs = cell.as_bytes()
    var n = len(bs)
    var i = 0
    while i < n:
        if bs[i] != 92:
            i += 1
            continue
        if i + 1 >= n:
            raise Error("canon: cell '" + cell + "' ends inside an escape")
        var c = bs[i + 1]
        if c == 92 or c == 116 or c == 110 or c == 114:
            i += 2
        elif c == 120:
            if not _canon_hex_escape(bs, i):
                raise Error("canon: cell '" + cell + "' has a \\x escape canon does not write")
            i += 4
        elif c == 78:
            raise Error(
                "canon: cell '" + cell + "' holds \\N inside a value; NULL is"
                " the whole cell \\N and a literal backslash is \\\\"
            )
        else:
            raise Error("canon: cell '" + cell + "' has an unknown escape")


def find_unescaped(s: String, sep: UInt8, start: Int = 0) -> Int:
    """Byte index of the first `sep` at or after `start` that no backslash
    escapes, or -1."""
    var bs = s.as_bytes()
    var i = start
    while i < len(bs):
        if bs[i] == 92:
            i += 2
            continue
        if bs[i] == sep:
            return i
        i += 1
    return -1


def split_unescaped(s: String, sep: UInt8) -> List[String]:
    """Split on every `sep` no backslash escapes (pieces stay escaped)."""
    var res = List[String]()
    var start = 0
    while True:
        var at = find_unescaped(s, sep, start)
        if at < 0:
            res.append(String(s[byte = start : s.byte_length()]))
            return res^
        res.append(String(s[byte=start:at]))
        start = at + 1
