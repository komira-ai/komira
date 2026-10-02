# =============================================================================
# komira_gcp_core/_text.mojo -- byte-level text helpers private to the package.
# =============================================================================
#
# One copy of the RFC 3986 percent-encoder and of the bytes-to-String step,
# for pagination.mojo (`pageToken`) and v4_sign.mojo (the V4 canonical path
# and query). Nothing here is re-exported by __init__.mojo: a general
# percent-encoder is not part of this package's API.
#
# komira_aws_core has `uri_encode` with the same rule. It is not imported:
# this package does not depend on the AWS core.
# =============================================================================


def _from_utf8_bytes(b: List[UInt8]) -> String:
    """A String from bytes that are valid UTF-8 by construction: ASCII
    output of the encoder, or bytes of a String cut only at ASCII bytes."""
    return String(unsafe_from_utf8=Span(b))


def _is_unreserved(c: UInt8) -> Bool:
    """RFC 3986 section 2.3 unreserved: ALPHA / DIGIT / `-` / `.` / `_` / `~`."""
    return (
        (c >= UInt8(0x41) and c <= UInt8(0x5A))
        or (c >= UInt8(0x61) and c <= UInt8(0x7A))
        or (c >= UInt8(0x30) and c <= UInt8(0x39))
        or c == UInt8(0x2D)
        or c == UInt8(0x2E)
        or c == UInt8(0x5F)
        or c == UInt8(0x7E)
    )


def _hex_upper_digit(v: UInt8) -> UInt8:
    return v + 0x30 if v < 10 else v - 10 + 0x41


def _percent_encode(input: String, keep_slash: Bool) -> String:
    """RFC 3986 percent-encoding of the UTF-8 bytes of `input`, upper-case
    hex, every byte outside the unreserved set encoded, one escape per octet
    (`é` is `%C3%A9`).

    `keep_slash=True` leaves `/` as it is (a path); `keep_slash=False`
    encodes it as `%2F` (a query name or value)."""
    var b = input.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if _is_unreserved(c) or (keep_slash and c == UInt8(0x2F)):
            out.append(c)
        else:
            out.append(UInt8(0x25))
            out.append(_hex_upper_digit(c >> 4))
            out.append(_hex_upper_digit(c & 0x0F))
    return _from_utf8_bytes(out)
