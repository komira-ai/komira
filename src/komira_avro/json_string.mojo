"""JSON string-literal decoding and UTF-8 checking for the Avro schema parser.

The schema JSON is untrusted (it is the `avro.schema` entry of a file header),
so this module never hands a code point it has not checked to `chr()` and never
builds a `String` from bytes it has not validated.

Two rules carry the module:

  * Output is accumulated as BYTES. `chr()` maps a CODE POINT to UTF-8, so
    `chr(byte)` over the raw bytes of `ü` (C3 BC) yields `Ã¼` (C3 83 C2 BC).
    Raw input bytes are copied through unchanged; escapes are encoded to UTF-8
    here (`_append_utf8`).
  * A `\\uXXXX` escape names a UTF-16 code unit. A high surrogate (D800-DBFF)
    must be followed by a `\\u` low surrogate (DC00-DFFF) and the two join into
    one code point above U+FFFF. Anything else involving a surrogate is
    malformed: `chr()` of a surrogate aborts the process.
"""


def decode_json_string(
    data: Span[UInt8, _], start: Int, mut value: String
) raises -> Int:
    """Decode the JSON string literal whose opening quote is `data[start]`
    into `value`; return the index just past its closing quote.

    Raises `AvroSchemaError.MALFORMED_JSON` on an unescaped control character
    (U+0000..U+001F), an unknown escape, a bad or short `\\u` escape, a lone
    or mis-ordered surrogate, an unterminated string, or a result that is not
    well-formed UTF-8.
    """
    var n = len(data)
    var pos = start + 1  # past the opening quote
    var out = List[UInt8]()
    while pos < n:
        var c = data[pos]
        if c == UInt8(ord('"')):
            if not utf8_well_formed(Span(out)):
                raise Error(
                    "AvroSchemaError.MALFORMED_JSON: string is not valid UTF-8"
                )
            # The bytes were just validated, so the unchecked constructor's
            # precondition holds.
            value = String(unsafe_from_utf8=Span(out))
            return pos + 1
        if c != UInt8(ord("\\")):
            # A run of unescaped bytes is copied through byte-exact. RFC 8259
            # section 7: U+0000..U+001F must be escaped inside a string.
            var run_end = pos
            while run_end < n:
                var d = data[run_end]
                if d == UInt8(ord('"')) or d == UInt8(ord("\\")):
                    break
                if d < 0x20:
                    raise Error(
                        String(
                            "AvroSchemaError.MALFORMED_JSON: unescaped control"
                            " character 0x"
                        )
                        + _hex2(d)
                        + " in a string at byte "
                        + String(run_end)
                    )
                run_end += 1
            for i in range(pos, run_end):
                out.append(data[i])
            pos = run_end
            continue
        pos += 1
        if pos >= n:
            raise Error("AvroSchemaError.MALFORMED_JSON: bad escape")
        var e = data[pos]
        if e == UInt8(ord('"')):
            out.append(UInt8(0x22))
        elif e == UInt8(ord("\\")):
            out.append(UInt8(0x5C))
        elif e == UInt8(ord("/")):
            out.append(UInt8(0x2F))
        elif e == UInt8(ord("n")):
            out.append(UInt8(0x0A))
        elif e == UInt8(ord("t")):
            out.append(UInt8(0x09))
        elif e == UInt8(ord("r")):
            out.append(UInt8(0x0D))
        elif e == UInt8(ord("b")):
            out.append(UInt8(0x08))
        elif e == UInt8(ord("f")):
            out.append(UInt8(0x0C))
        elif e == UInt8(ord("u")):
            var cp = _read_hex4(data, pos + 1)
            pos += 4  # now on the last hex digit
            if cp >= 0xDC00 and cp <= 0xDFFF:
                raise Error(
                    "AvroSchemaError.MALFORMED_JSON: \\u escape is a low"
                    " surrogate with no high surrogate before it"
                )
            if cp >= 0xD800 and cp <= 0xDBFF:
                if (
                    pos + 2 >= n
                    or data[pos + 1] != UInt8(ord("\\"))
                    or data[pos + 2] != UInt8(ord("u"))
                ):
                    raise Error(
                        "AvroSchemaError.MALFORMED_JSON: \\u escape is a high"
                        " surrogate not followed by a \\u low surrogate"
                    )
                var lo = _read_hex4(data, pos + 3)
                if lo < 0xDC00 or lo > 0xDFFF:
                    raise Error(
                        "AvroSchemaError.MALFORMED_JSON: \\u escape is a high"
                        " surrogate not followed by a \\u low surrogate"
                    )
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                pos += 6  # now on the last hex digit of the low half
            _append_utf8(out, cp)
        else:
            raise Error("AvroSchemaError.MALFORMED_JSON: unknown escape")
        pos += 1
    raise Error("AvroSchemaError.MALFORMED_JSON: unterminated string")


def utf8_to_string(data: Span[UInt8, _], what: String) raises -> String:
    """`data` copied byte-exact into a String, or raise `what` (an error
    prefix naming the caller's context) when it is not well-formed UTF-8."""
    if not utf8_well_formed(data):
        raise Error(what + ": not valid UTF-8")
    # Validated on the line above.
    return String(unsafe_from_utf8=data)


def utf8_well_formed(b: Span[UInt8, _]) -> Bool:
    """RFC 3629 well-formedness: no overlong form, no surrogate, nothing above
    U+10FFFF, no stray continuation byte, no truncated sequence."""
    var i = 0
    var n = len(b)
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        if c < 0xC2 or c > 0xF4:
            return False  # a continuation byte, an overlong lead, > U+10FFFF
        var need = 1
        var lo = 0x80
        var hi = 0xBF
        if c == 0xE0:
            need = 2
            lo = 0xA0
        elif c == 0xED:
            need = 2
            hi = 0x9F  # no UTF-16 surrogates
        elif c >= 0xE1 and c <= 0xEF:
            need = 2
        elif c == 0xF0:
            need = 3
            lo = 0x90
        elif c == 0xF4:
            need = 3
            hi = 0x8F
        elif c >= 0xF1 and c <= 0xF3:
            need = 3
        if i + need >= n:  # the sequence needs bytes i+1 .. i+need
            return False
        var c1 = Int(b[i + 1])
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = Int(b[i + k])
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def _read_hex4(data: Span[UInt8, _], at: Int) raises -> Int:
    """The 16-bit value of the four hex digits at `data[at : at + 4]`."""
    if at + 4 > len(data):
        raise Error("AvroSchemaError.MALFORMED_JSON: short \\u escape")
    var v = 0
    for k in range(4):
        var d = _hex_digit(data[at + k])
        if d < 0:
            raise Error(
                "AvroSchemaError.MALFORMED_JSON: non-hex digit in \\u escape"
            )
        v = v * 16 + d
    return v


def _hex2(b: UInt8) -> String:
    """`b` as two uppercase hex digits."""
    var hi = Int(b >> 4)
    var lo = Int(b & 0x0F)
    return chr(hi + 48 if hi < 10 else hi + 55) + chr(
        lo + 48 if lo < 10 else lo + 55
    )


@always_inline
def _hex_digit(c: UInt8) -> Int:
    """The value of one hex digit, or -1 when `c` is not one."""
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c - UInt8(ord("0")))
    elif c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c - UInt8(ord("a")) + 10)
    elif c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c - UInt8(ord("A")) + 10)
    return -1


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Append the UTF-8 encoding of `cp`. The caller guarantees `cp` is a
    Unicode scalar value (0..10FFFF, not a surrogate)."""
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
