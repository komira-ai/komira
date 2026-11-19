# =============================================================================
# parse_bool — JSON `true` / `false` literal → Bool scalar parser
# =============================================================================
#
# The JSON grammar
# permits exactly two literals: `true` (4 bytes: 't', 'r', 'u', 'e')
# and `false` (5 bytes: 'f', 'a', 'l', 's', 'e'). The Stage 2 walker
# arrives at a non-string, non-numeric scalar; this parser identifies
# which of the two literals it is.
#
# Public surface:
#   - `parse_bool(bytes, start, end) raises -> Bool`
#       Parse the byte range as `true` or `false`. Raises on anything
#       else.
#
# Encapsulation:
#   - `Span[UInt8, _]` input; owned `Bool` return.
# =============================================================================


def parse_bool(bytes: Span[UInt8, _], start: Int, end: Int) raises -> Bool:
    """Parse `bytes[start..end]` as a JSON boolean literal.

    Accepts EXACTLY "true" (4 bytes) or "false" (5 bytes). Anything else
    raises.

    JSON RFC 8259 is strict: `True`, `TRUE`, `1`, etc. are not booleans.
    """
    var n = end - start
    if n == 4:
        # Expect 't','r','u','e'.
        if (
            bytes[start] == UInt8(0x74)
            and bytes[start + 1] == UInt8(0x72)
            and bytes[start + 2] == UInt8(0x75)
            and bytes[start + 3] == UInt8(0x65)
        ):
            return True
        raise Error("parse_bool: 4-byte literal is not 'true'")
    elif n == 5:
        # Expect 'f','a','l','s','e'.
        if (
            bytes[start] == UInt8(0x66)
            and bytes[start + 1] == UInt8(0x61)
            and bytes[start + 2] == UInt8(0x6C)
            and bytes[start + 3] == UInt8(0x73)
            and bytes[start + 4] == UInt8(0x65)
        ):
            return False
        raise Error("parse_bool: 5-byte literal is not 'false'")
    raise Error("parse_bool: literal must be 'true' (4 bytes) or 'false' (5 bytes); got " + String(n) + " bytes")


def parse_null(bytes: Span[UInt8, _], start: Int, end: Int) raises:
    """Parse `bytes[start..end]` as the JSON `null` literal.

    Accepts EXACTLY "null" (4 bytes: 'n', 'u', 'l', 'l'). Anything else
    raises. The function returns nothing — the caller's responsibility
    is to clear the validity bit in the column at the current row index.
    """
    var n = end - start
    if n == 4 and (
        bytes[start] == UInt8(0x6E)
        and bytes[start + 1] == UInt8(0x75)
        and bytes[start + 2] == UInt8(0x6C)
        and bytes[start + 3] == UInt8(0x6C)
    ):
        return
    raise Error("parse_null: literal must be exactly 'null' (4 bytes)")
