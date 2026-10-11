# =============================================================================
# komira_mail_message/chars.mojo -- byte constants and helpers.
# =============================================================================
#
# The package works on bytes (`List[UInt8]`, `Span[UInt8, _]`): a message on
# the wire is octets, and a body or a header may hold bytes that are not
# UTF-8. A `String` is made only from bytes checked to be UTF-8
# (`utf8_string`) or with every ill-formed octet replaced by U+FFFD
# (`lossy_string`).
# =============================================================================

comptime HTAB: UInt8 = 9
comptime LF: UInt8 = 10
comptime CR: UInt8 = 13
comptime SP: UInt8 = 32
comptime DQUOTE: UInt8 = 34
comptime PERCENT: UInt8 = 37
comptime SQUOTE: UInt8 = 39
comptime LPAREN: UInt8 = 40
comptime RPAREN: UInt8 = 41
comptime STAR: UInt8 = 42
comptime HYPHEN: UInt8 = 45
comptime DOT: UInt8 = 46
comptime SLASH: UInt8 = 47
comptime COLON: UInt8 = 58
comptime SEMI: UInt8 = 59
comptime LT: UInt8 = 60
comptime EQ: UInt8 = 61
comptime GT: UInt8 = 62
comptime QMARK: UInt8 = 63
comptime AT: UInt8 = 64
comptime BACKSLASH: UInt8 = 92
comptime UNDERSCORE: UInt8 = 95

comptime HEX_UPPER: StaticString = "0123456789ABCDEF"


def is_wsp(c: UInt8) -> Bool:
    """RFC 5234 `WSP`: space or horizontal tab."""
    return c == SP or c == HTAB


def is_alpha(c: UInt8) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


def is_digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def is_atext(c: UInt8) -> Bool:
    """RFC 5322 `atext`: letters, digits and ``!#$%&'*+-/=?^_`{|}~``."""
    if is_alpha(c) or is_digit(c):
        return True
    return (
        c == 33
        or (c >= 35 and c <= 39)
        or c == 42
        or c == 43
        or c == 45
        or c == 47
        or c == 61
        or c == 63
        or (c >= 94 and c <= 96)
        or (c >= 123 and c <= 126)
    )


def is_tspecial(c: UInt8) -> Bool:
    """RFC 2045 `tspecials`: ``()<>@,;:\\"/[]?=``."""
    return (
        c == 40
        or c == 41
        or c == 60
        or c == 62
        or c == 64
        or c == 44
        or c == 59
        or c == 58
        or c == 92
        or c == 34
        or c == 47
        or c == 91
        or c == 93
        or c == 63
        or c == 61
    )


def is_token_char(c: UInt8) -> Bool:
    """RFC 2045 `token` octet: printable ASCII, not space, not a tspecial."""
    return c > 32 and c < 127 and not is_tspecial(c)


def is_ftext(c: UInt8) -> Bool:
    """RFC 5322 `ftext`: printable ASCII except `:`."""
    return c >= 33 and c <= 126 and c != COLON


def lower(c: UInt8) -> UInt8:
    if c >= 65 and c <= 90:
        return c | 0x20
    return c


def hex_value(c: UInt8) -> Int:
    """The value of a hex digit (either case), or -1."""
    if is_digit(c):
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return -1


def append_bytes(mut out: List[UInt8], data: Span[UInt8, _]):
    for i in range(len(data)):
        out.append(data[i])


def append_range(mut out: List[UInt8], data: Span[UInt8, _], start: Int, end: Int):
    """Append `data[start:end]`."""
    for i in range(start, end):
        out.append(data[i])


def append_hex(mut out: List[UInt8], c: UInt8, mark: UInt8):
    """Append `mark` and the two upper-case hex digits of `c` (`=E9`,
    `%E9`)."""
    var hex = HEX_UPPER.as_bytes()
    out.append(mark)
    out.append(hex[Int(c >> 4)])
    out.append(hex[Int(c & 15)])


def append_crlf(mut out: List[UInt8]):
    out.append(CR)
    out.append(LF)


def append_decimal(mut out: List[UInt8], value: Int, width: Int):
    """Append a non-negative `value` in decimal, zero-padded to `width`."""
    var digits = List[UInt8]()
    var v = value
    while v > 0:
        digits.append(UInt8(48 + v % 10))
        v = v // 10
    while len(digits) < width:
        digits.append(48)
    for k in range(len(digits) - 1, -1, -1):
        out.append(digits[k])


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    append_bytes(out, s.as_bytes())
    return out^


def range_bytes(data: Span[UInt8, _], start: Int, end: Int) -> List[UInt8]:
    """A copy of `data[start:end]`."""
    var out = List[UInt8](capacity=end - start)
    append_range(out, data, start, end)
    return out^


def find_bytes(
    data: Span[UInt8, _], needle: Span[UInt8, _], start: Int, end: Int
) -> Int:
    """The first index `i` in `[start, end)` where `needle` occurs wholly
    inside `data[start:end]`, or -1."""
    var m = len(needle)
    var i = start
    while i + m <= end:
        var k = 0
        while k < m and data[i + k] == needle[k]:
            k += 1
        if k == m:
            return i
        i += 1
    return -1


def equals_ignore_case(data: Span[UInt8, _], t: Span[UInt8, _]) -> Bool:
    """`data` equals `t`, ASCII letters compared without case."""
    if len(data) != len(t):
        return False
    for i in range(len(t)):
        if lower(data[i]) != lower(t[i]):
            return False
    return True


def lower_ascii_string(data: Span[UInt8, _], start: Int, end: Int) raises -> String:
    """`data[start:end]` with ASCII letters in lower case, as a `String`;
    every ill-formed UTF-8 octet becomes U+FFFD."""
    var out = List[UInt8](capacity=end - start)
    for i in range(start, end):
        out.append(lower(data[i]))
    return lossy_string(Span(out))


def is_ascii(data: Span[UInt8, _]) -> Bool:
    for i in range(len(data)):
        if data[i] >= 128:
            return False
    return True


def find_forbidden(data: Span[UInt8, _]) -> Int:
    """The position of the first CR, LF or NUL in `data`, or -1."""
    for i in range(len(data)):
        var c = data[i]
        if c == CR or c == LF or c == 0:
            return i
    return -1


def utf8_invalid_at(data: Span[UInt8, _]) -> Int:
    """The offset of the first octet of `data` that does not start or
    continue a well-formed UTF-8 sequence (RFC 3629 section 4: no overlong
    form, no surrogate, nothing above U+10FFFF), or -1."""
    var n = len(data)
    var i = 0
    while i < n:
        var need = utf8_sequence_length(data, i)
        if need == 0:
            return i
        i += need
    return -1


def utf8_sequence_length(data: Span[UInt8, _], i: Int) -> Int:
    """The length of the well-formed UTF-8 sequence starting at `i`, or 0
    when the octets there are ill-formed."""
    var n = len(data)
    var b0 = Int(data[i])
    if b0 < 0x80:
        return 1
    var need: Int
    var lo = 0x80
    var hi = 0xBF
    if b0 >= 0xC2 and b0 <= 0xDF:
        need = 1
    elif b0 == 0xE0:
        need = 2
        lo = 0xA0
    elif b0 >= 0xE1 and b0 <= 0xEC:
        need = 2
    elif b0 == 0xED:
        need = 2
        hi = 0x9F
    elif b0 >= 0xEE and b0 <= 0xEF:
        need = 2
    elif b0 == 0xF0:
        need = 3
        lo = 0x90
    elif b0 >= 0xF1 and b0 <= 0xF3:
        need = 3
    elif b0 == 0xF4:
        need = 3
        hi = 0x8F
    else:
        return 0
    if i + need >= n:
        return 0
    var b1 = Int(data[i + 1])
    if b1 < lo or b1 > hi:
        return 0
    for k in range(2, need + 1):
        var bk = Int(data[i + k])
        if bk < 0x80 or bk > 0xBF:
            return 0
    return need + 1


def append_lossy(mut out: List[UInt8], data: Span[UInt8, _]):
    """Append `data` with every ill-formed UTF-8 octet replaced by U+FFFD
    (EF BF BD)."""
    var n = len(data)
    var i = 0
    while i < n:
        var need = utf8_sequence_length(data, i)
        if need == 0:
            out.append(0xEF)
            out.append(0xBF)
            out.append(0xBD)
            i += 1
            continue
        for k in range(need):
            out.append(data[i + k])
        i += need


def utf8_string(data: Span[UInt8, _]) raises -> String:
    """`data` as a `String`; the caller has checked it is UTF-8 (the standard
    library's checked constructor raises otherwise)."""
    return String(StringSlice(from_utf8=data))


def lossy_string(data: Span[UInt8, _]) raises -> String:
    """`data` as a `String`, every ill-formed UTF-8 octet replaced by
    U+FFFD."""
    var out = List[UInt8](capacity=len(data))
    append_lossy(out, data)
    return utf8_string(Span(out))
