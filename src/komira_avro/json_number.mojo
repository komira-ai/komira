"""The JSON number grammar (RFC 8259 section 6) for the Avro schema parser.

    number = [ "-" ] int [ frac ] [ exp ]
    int    = "0" / ( digit1-9 *DIGIT )
    frac   = "." 1*DIGIT
    exp    = ( "e" / "E" ) [ "-" / "+" ] 1*DIGIT

`scan_json_number` checks a literal against this grammar and returns where it
ends; it does not compute the value. Each refusal names the byte offset (from
the start of the schema text) of the first byte that breaks the grammar.
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
