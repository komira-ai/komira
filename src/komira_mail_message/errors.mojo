# =============================================================================
# komira_mail_message/errors.mojo -- the named errors.
# =============================================================================
#
# Every function of the package that can fail raises an `Error` whose message
# starts with `komira_mail_message.<Kind>: `, then the function name and what
# is wrong. A parser error ends with the zero-based byte position in the input
# where it was found:
#
#   komira_mail_message.Syntax: parse_message: a header line without ':' at position 41
#   komira_mail_message.ForbiddenByte: MessageBuilder.set_subject: CR, LF or NUL
#
# The message never contains a byte of the input: messages carry personal data
# and error messages travel to logs.
# =============================================================================

comptime FORBIDDEN_BYTE: StaticString = "ForbiddenByte"
"""CR, LF or NUL in a value the builder writes into a header (a header
injection)."""

comptime INVALID_HEADER: StaticString = "InvalidHeader"
"""A header field name that is not RFC 5322 `ftext` (printable ASCII except
`:`), or one `add_header` refuses: a field the builder writes itself, `Bcc`
or `Sender`."""

comptime INVALID_VALUE: StaticString = "InvalidValue"
"""A builder argument that cannot be written: a media type that is not
`type/subtype` tokens or is `multipart/*`, a `message/*` attachment that is
not 7bit text, a message id that is not `dot-atom-text@dot-atom-text`,
a date outside the range RFC 5322 can write."""

comptime MISSING_FIELD: StaticString = "MissingField"
"""`build()` without a field RFC 5322 section 3.6 requires (`From`, `Date`)."""

comptime LINE_TOO_LONG: StaticString = "LineTooLong"
"""A header line that cannot be folded to at most 998 octets (RFC 5322
section 2.1.1): no white space to fold at within the limit."""

comptime SYNTAX: StaticString = "Syntax"
"""Input that is not an RFC 5322 message or an RFC 2046 multipart body: a
header line without `:`, a continuation line before the first field, a
multipart with no or an invalid `boundary`, or no delimiter line."""

comptime LIMIT: StaticString = "Limit"
"""A message nested deeper or holding more parts than the parse limits."""

comptime ENCODING: StaticString = "Encoding"
"""A body that cannot be decoded: an unknown `Content-Transfer-Encoding`, or
base64 that is not valid after the characters outside the alphabet are
dropped."""

comptime ERROR_PREFIX: StaticString = "komira_mail_message."
"""Every error message of the package starts with this, then the kind."""


def message_error(
    kind: StaticString, function: StaticString, detail: StaticString
) -> Error:
    """An error without a position (a builder argument)."""
    return Error(
        String(ERROR_PREFIX)
        + String(kind)
        + String(": ")
        + String(function)
        + String(": ")
        + String(detail)
    )


def message_error(
    kind: StaticString, function: StaticString, detail: StaticString, position: Int
) -> Error:
    """An error at a byte position of the input."""
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
    """The kind named by a komira_mail_message error (`Syntax`, ...), or the
    empty string for any other error."""
    var msg = String(e)
    var prefix = String(ERROR_PREFIX)
    if not msg.startswith(prefix):
        return String("")
    var rest = String(msg[byte = prefix.byte_length() : msg.byte_length()])
    var colon = rest.find(":")
    if colon < 0:
        return String("")
    return String(rest[byte=0:colon])
