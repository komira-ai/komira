# =============================================================================
# komira_encoding/errors.mojo -- the named decode errors.
# =============================================================================
#
# A decoder raises an `Error` whose message starts with
# `komira_encoding.<Kind>: `, where `<Kind>` is one of the names below,
# followed by the function name, what is wrong, and the zero-based byte
# position in the input where it was found:
#
#   komira_encoding.InvalidCharacter: base64_decode: byte is not in the
#   alphabet at position 7
#
# The message never contains the offending byte or any other input byte: the
# input of a decoder is often a key or a token, and an error message travels
# to logs.
# =============================================================================

comptime INVALID_CHARACTER: StaticString = "InvalidCharacter"
"""A byte outside the scheme's alphabet (this includes whitespace, and `=`
anywhere but the trailing padding). Position: the first such byte."""

comptime INVALID_PADDING: StaticString = "InvalidPadding"
"""Padding that is missing where it is required, present where it is not
allowed, or of the wrong length. Position: where the padding starts (or the
end of the input, when it is missing)."""

comptime INVALID_LENGTH: StaticString = "InvalidLength"
"""A number of symbols that no input encodes to (for example one base64
character, or an odd number of hex digits). Position: the end of the
symbols."""

comptime NON_CANONICAL: StaticString = "NonCanonical"
"""Non-zero unused bits in the last symbol (RFC 4648 section 3.5): the input
is not the encoding of any byte string. Position: the last symbol."""

comptime INVALID_BOUNDARY: StaticString = "InvalidBoundary"
"""PEM (pem.mojo): no BEGIN line, a malformed encapsulation boundary, a block
with no END line, or an END label that differs from the BEGIN label.
Position: the start of the offending boundary (or the end of the input)."""

comptime LABEL_MISMATCH: StaticString = "LabelMismatch"
"""PEM (pem.mojo): the first block is well-formed but its label is not the
one asked for. Position: the start of the label on the BEGIN line."""

comptime ERROR_PREFIX: StaticString = "komira_encoding."
"""Every decode error message starts with this, then the kind."""


def encoding_error(
    kind: StaticString, function: StaticString, detail: StaticString, position: Int
) -> Error:
    """The error a decoder raises; see the module header for its shape."""
    return Error(
        String(ERROR_PREFIX)
        + String(kind)
        + String(": ")
        + String(function)
        + String(": ")
        + String(detail)
        + String(" at position ")
        + String(position)
    )


def error_kind(e: Error) -> String:
    """The kind named by a komira_encoding error (`InvalidCharacter`, ...),
    or the empty string for any other error."""
    var msg = String(e)
    var prefix = String(ERROR_PREFIX)
    if not msg.startswith(prefix):
        return String("")
    var rest = String(msg[byte=prefix.byte_length():])
    var colon = rest.find(":")
    if colon < 0:
        return String("")
    return String(rest[byte=:colon])
