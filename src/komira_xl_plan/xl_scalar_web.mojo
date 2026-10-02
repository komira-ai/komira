# =============================================================================
# xl_scalar_web.mojo — ★ THE ONE MEMBER OF EXCEL'S **WEB** CATEGORY THAT NEEDS
#                        NO NETWORK, AND THE TWO THAT DO.
# =============================================================================
#
# Encapsulation rule : values only.
# =============================================================================

from .formula_value import FormulaValue


def _text(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` coerced to TEXT, or the error that stops the call. The
    same spelling as `xl_scalar_text._text`, re-spelled rather than imported
    for the reason `xl_scalar_exact._num`'s docstring gives."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_text()


def xl_encodeurl(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ENCODEURL(text)` — the URL-encoded form of `text`.

    ⭐ THE BYTES, NOT THE CHARACTERS. Excel percent-encodes the **UTF-8
    encoding** of the string, so a non-ASCII character becomes SEVERAL escapes:
    `ENCODEURL("ä")` is `%C3%A4`, not `%E4` (Latin-1) and not `%00E4` (a
    code-point spelling). A kernel that walked code points instead of bytes
    produces a plausible-looking escape sequence that no server decodes to the
    original string — and an ASCII-only fixture cannot tell the two apart.

    ⚠ THE HEX DIGITS ARE UPPER-CASE. `%3a` and `%3A` are equivalent to a
    correct server and NOT equal as strings, and a golden test compares
    strings."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    var bs = t.text.as_bytes()
    var hexs = String("0123456789ABCDEF")
    var hex = hexs.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bs)):
        var b = bs[i]
        var unreserved = (
            (b >= UInt8(0x41) and b <= UInt8(0x5A))
            or (b >= UInt8(0x61) and b <= UInt8(0x7A))
            or (b >= UInt8(0x30) and b <= UInt8(0x39))
            or b == UInt8(0x2D)
            or b == UInt8(0x2E)
            or b == UInt8(0x5F)
            or b == UInt8(0x7E)
        )
        if unreserved:
            out.append(b)
        else:
            out.append(UInt8(0x25))
            out.append(hex[Int(b >> UInt8(4))])
            out.append(hex[Int(b & UInt8(0x0F))])
    return FormulaValue.text_val(String(StringSlice(unsafe_from_utf8=Span(out))))
