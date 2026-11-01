# =============================================================================
# komira_mail_address/errors.mojo -- the named errors.
# =============================================================================
#
# Every parser and constructor of the package raises an `Error` whose
# message starts with `komira_mail_address.<Kind>: `, then the function name,
# what is wrong, and the zero-based byte position where it was found:
#
#   komira_mail_address.ForbiddenByte: parse_mailbox: CR, LF or NUL at position 9
#
# The position is in the text the function was given (for a constructor, in
# the field it was given). The message never contains a byte of the input:
# addresses are personal data and error messages travel to logs.
# =============================================================================

comptime FORBIDDEN_BYTE: StaticString = "ForbiddenByte"
"""CR, LF or NUL anywhere in the input. These are refused before anything
else is looked at, so no value of this package can carry a line break into a
header or an SMTP command."""

comptime NON_ASCII: StaticString = "NonAscii"
"""A byte at or above 0x80. SMTPUTF8 (RFC 6531) and IDNA are not supported:
a domain must be given in its ASCII (A-label, `xn--`) form."""

comptime SYNTAX: StaticString = "Syntax"
"""Input that is not an address of the form asked for (RFC 5322 section 3.4,
or RFC 5321 section 4.1.2 for a path)."""

comptime OBSOLETE: StaticString = "Obsolete"
"""An RFC 5322 section 4 obsolete form other than a `.` in a display name:
a source route, an empty list element, white space or a comment around a `.`
of a local part or a domain, or a quoted string before or after a `.` of a
local part."""

comptime UNSUPPORTED: StaticString = "Unsupported"
"""A domain literal (`[...]`, the RFC 5321 address literal)."""

comptime INVALID_DOMAIN: StaticString = "InvalidDomain"
"""A domain that is not an RFC 5321 `Domain`: an empty label, a label that
holds a byte other than a letter, digit or `-`, or that starts or ends with
`-`."""

comptime TOO_LONG: StaticString = "TooLong"
"""A local part over 64 octets, a domain label over 63, a domain over 253, or
a path over 256 (RFC 5321 section 4.5.3.1, RFC 1035 section 2.3.4)."""

comptime ERROR_PREFIX: StaticString = "komira_mail_address."
"""Every error message of the package starts with this, then the kind."""


def address_error(
    kind: StaticString, function: StaticString, detail: StaticString, position: Int
) -> Error:
    """The error a function raises; see the module header for its shape."""
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
    """The kind named by a komira_mail_address error (`Syntax`, ...), or the
    empty string for any other error."""
    var msg = String(e)
    var prefix = String(ERROR_PREFIX)
    if not msg.startswith(prefix):
        return String("")
    var rest = String(msg[byte = prefix.byte_length() :])
    var colon = rest.find(":")
    if colon < 0:
        return String("")
    return String(rest[byte=:colon])
