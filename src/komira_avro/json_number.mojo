"""The JSON number grammar (RFC 8259 section 6) for the Avro schema parser.

    number = [ "-" ] int [ frac ] [ exp ]
    int    = "0" / ( digit1-9 *DIGIT )
    frac   = "." 1*DIGIT
    exp    = ( "e" / "E" ) [ "-" / "+" ] 1*DIGIT

`scan_json_number` checks a literal against this grammar and returns where it
ends; it does not compute the value. Each refusal names the byte offset (from
the start of the schema text) of the first byte that breaks the grammar.
`parse_json_int` computes the value of a scanned integer literal, refusing
one outside the 64-bit signed range.
"""


@fieldwise_init
struct JsonNumberScan(Copyable, Movable):
    """Where a number literal ends, and whether it has a fraction or an
    exponent (then it is read as a float, otherwise as an integer)."""

    var end: Int
    var is_float: Bool


def scan_json_number(data: Span[UInt8, _], start: Int) raises -> JsonNumberScan:
    """Scan the number literal starting at `data[start]`.

    Raises `AvroSchemaError.MALFORMED_JSON: bad number at byte N: <reason>`
    for a `-` with no digit after it, a leading zero followed by a digit, a
    `.` with no digit after it, an exponent with no digits, and a `.`, `e`,
    `E`, `+` or `-` right after a complete number (as in `0.1.2` or `1+2`).
    """
    var n = len(data)
    var pos = start
    var is_float = False
    if pos < n and data[pos] == UInt8(ord("-")):
        pos += 1
        if not _digit_at(data, pos):
            raise _number_error(pos, "'-' is not followed by a digit")
    elif not _digit_at(data, pos):
        raise _number_error(pos, "a number starts with '-' or a digit")
    if data[pos] == UInt8(ord("0")):
        pos += 1
        if _digit_at(data, pos):
            raise _number_error(pos, "a leading zero is followed by a digit")
    else:
        pos = _skip_digits(data, pos)
    if pos < n and data[pos] == UInt8(ord(".")):
        is_float = True
        pos += 1
        if not _digit_at(data, pos):
            raise _number_error(pos, "'.' is not followed by a digit")
        pos = _skip_digits(data, pos)
    if pos < n and (data[pos] == UInt8(ord("e")) or data[pos] == UInt8(ord("E"))):
        is_float = True
        pos += 1
        if pos < n and (
            data[pos] == UInt8(ord("+")) or data[pos] == UInt8(ord("-"))
        ):
            pos += 1
        if not _digit_at(data, pos):
            raise _number_error(pos, "the exponent has no digits")
        pos = _skip_digits(data, pos)
    if pos < n:
        var c = data[pos]
        if (
            c == UInt8(ord("."))
            or c == UInt8(ord("e"))
            or c == UInt8(ord("E"))
            or c == UInt8(ord("+"))
            or c == UInt8(ord("-"))
        ):
            raise _number_error(
                pos, String("'") + chr(Int(c)) + "' cannot follow a number"
            )
    return JsonNumberScan(end=pos, is_float=is_float)


def _number_error(at: Int, reason: String) -> Error:
    return Error(
        String("AvroSchemaError.MALFORMED_JSON: bad number at byte ")
        + String(at)
        + ": "
        + reason
    )


@always_inline
def _digit_at(data: Span[UInt8, _], pos: Int) -> Bool:
    return (
        pos < len(data)
        and data[pos] >= UInt8(ord("0"))
        and data[pos] <= UInt8(ord("9"))
    )


def _skip_digits(data: Span[UInt8, _], start: Int) -> Int:
    var pos = start
    while _digit_at(data, pos):
        pos += 1
    return pos


# Max digits accepted in an integer literal (after an optional '-'). 19 digits
# hold every 64-bit magnitude; the accumulation below refuses the 19-digit
# ones past the Int64 range.
comptime MAX_JSON_INT_DIGITS: Int = 19


def parse_json_int(data: Span[UInt8, _], start: Int, end: Int) raises -> Int:
    """The value of the integer literal `data[start:end]`, which
    `scan_json_number` has already checked (an optional '-', then digits).

    UNTRUSTED INPUT. `acc * 10 + digit` in a signed Int silently wraps, so an
    unchecked digit run in a header's schema JSON could name any 64-bit value,
    including one inside the overflow window of a downstream `pos + n` bounds
    check. A literal that cannot be represented is refused, never wrapped.

    The value is accumulated NEGATED (toward Int64.MIN), so the magnitude of
    -9223372036854775808, one past Int64.MAX, fits; a literal without the
    sign whose negation is Int64.MIN (9223372036854775808) is then refused.

    Raises `AvroSchemaError.MALFORMED_JSON: integer literal has N digits,
    which cannot be represented (max 19)` and `AvroSchemaError.MALFORMED_JSON:
    integer literal overflows a 64-bit signed integer`.
    """
    var i = start
    var neg = data[i] == UInt8(ord("-"))
    if neg:
        i += 1
    if end - i > MAX_JSON_INT_DIGITS:
        raise Error(
            String("AvroSchemaError.MALFORMED_JSON: integer literal has ")
            + String(end - i)
            + " digits, which cannot be represented (max "
            + String(MAX_JSON_INT_DIGITS)
            + ")"
        )
    var acc = 0  # minus the value read so far
    while i < end:
        var next_acc = acc * 10 - Int(data[i] - UInt8(ord("0")))
        # With at most 19 digits, a step past Int64.MIN wraps to a positive
        # value, which is above the non-positive `acc`.
        if next_acc > acc:
            raise _int_overflow()
        acc = next_acc
        i += 1
    if neg:
        return acc
    if acc == Int(Int64.MIN):
        raise _int_overflow()
    return -acc


def _int_overflow() -> Error:
    return Error(
        "AvroSchemaError.MALFORMED_JSON: integer literal overflows a 64-bit"
        " signed integer"
    )
