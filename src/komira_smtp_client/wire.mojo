# The bytes of the DATA phase and the checks on an envelope (RFC 5321 sections
# 4.1.1.4, 4.1.2, 4.5.2).

from komira_mail_address import parse_path

comptime _CR: UInt8 = 0x0D
comptime _LF: UInt8 = 0x0A
comptime _DOT: UInt8 = 0x2E

comptime _MAX_PATH_BYTES: Int = 254


def normalize_line_endings(message: Span[UInt8, _]) -> List[UInt8]:
    """The message with every line break written CRLF: a bare LF and a bare CR
    each become CRLF (RFC 5321 section 2.3.8 allows neither alone), and a final
    CRLF is added when the last line has none. An empty message stays empty."""
    var n = len(message)
    var out = List[UInt8](capacity=n + 2)
    var i = 0
    while i < n:
        var c = message[i]
        if c == _CR:
            out.append(_CR)
            out.append(_LF)
            if i + 1 < n and message[i + 1] == _LF:
                i += 1
        elif c == _LF:
            out.append(_CR)
            out.append(_LF)
        else:
            out.append(c)
        i += 1
    var m = len(out)
    if m > 0 and (m < 2 or not (out[m - 2] == _CR and out[m - 1] == _LF)):
        out.append(_CR)
        out.append(_LF)
    return out^


def dot_stuff_and_terminate(normalized: Span[UInt8, _]) -> List[UInt8]:
    """What goes on the wire after `DATA`'s 354: every line that starts with
    `.` gets a second `.` (RFC 5321 section 4.5.2), then `.` CRLF ends the data.
    `normalized` must be the result of `normalize_line_endings`, so the data
    ends at the start of a line."""
    var n = len(normalized)
    var out = List[UInt8](capacity=n + 8)
    var at_line_start = True
    for i in range(n):
        var c = normalized[i]
        if at_line_start and c == _DOT:
            out.append(_DOT)
        out.append(c)
        at_line_start = c == _LF
    out.append(_DOT)
    out.append(_CR)
    out.append(_LF)
    return out^


def has_eight_bit(message: Span[UInt8, _]) -> Bool:
    """Whether any byte is above 0x7F."""
    for i in range(len(message)):
        if message[i] >= 0x80:
            return True
    return False


def _has_eight_bit_text(s: String) -> Bool:
    return has_eight_bit(s.as_bytes())


def _check_path_text(addr: String, what: String) raises:
    var b = addr.as_bytes()
    if len(b) > _MAX_PATH_BYTES:
        raise Error("SmtpEnvelope: the " + what + " address is longer than 254 bytes")
    for i in range(len(b)):
        var c = b[i]
        if c <= 0x20 or c == 0x7F or c == 0x3C or c == 0x3E:
            raise Error(
                "SmtpEnvelope: the "
                + what
                + " address holds a control byte, a space or an angle bracket"
            )


def check_address(addr: String, what: String, allow_empty: Bool) raises -> Bool:
    """Validate one envelope address given as `local@domain` (no angle
    brackets; empty is the null path of a bounce when `allow_empty`). Returns
    True when it holds a byte above 0x7F and so needs SMTPUTF8 (RFC 6531). An
    ASCII address must be a valid RFC 5321 path (`komira_mail_address`); a
    non-ASCII one is only checked for one `@` between non-empty parts, no
    control byte, space or angle bracket."""
    if addr.byte_length() == 0:
        if allow_empty:
            return False
        raise Error("SmtpEnvelope: the " + what + " address is empty")
    _check_path_text(addr, what)
    if _has_eight_bit_text(addr):
        var b = addr.as_bytes()
        var at = -1
        for i in range(len(b)):
            if b[i] == 0x40:
                if at >= 0:
                    raise Error("SmtpEnvelope: the " + what + " address has two @")
                at = i
        if at <= 0 or at >= len(b) - 1:
            raise Error("SmtpEnvelope: the " + what + " address has no @ between two parts")
        return True
    try:
        _ = parse_path(String("<") + addr + ">")
    except e:
        raise Error("SmtpEnvelope: the " + what + " address is invalid: " + String(e))
    return False


struct Envelope(Copyable, Movable):
    """A validated envelope and message: what the transaction needs to know
    before the first command."""

    var mail_from: String
    var recipients: List[String]
    var needs_smtputf8: Bool
    var eight_bit: Bool
    var size: Int

    def __init__(
        out self,
        var mail_from: String,
        var recipients: List[String],
        needs_smtputf8: Bool,
        eight_bit: Bool,
        size: Int,
    ):
        self.mail_from = mail_from^
        self.recipients = recipients^
        self.needs_smtputf8 = needs_smtputf8
        self.eight_bit = eight_bit
        self.size = size


def validate_envelope(
    mail_from: String, recipients: List[String], message: Span[UInt8, _]
) raises -> Envelope:
    """Check the sender, every recipient and the message before anything is
    sent. `size` is the length of the message after line-ending
    normalisation, which is what SIZE (RFC 1870) counts."""
    if len(recipients) == 0:
        raise Error("SmtpEnvelope: no recipients")
    if len(message) == 0:
        raise Error("SmtpEnvelope: the message is empty")
    var utf8 = check_address(mail_from, String("sender"), True)
    for i in range(len(recipients)):
        if check_address(recipients[i], String("recipient ") + String(i), False):
            utf8 = True
    var normalized = normalize_line_endings(message)
    return Envelope(
        mail_from.copy(),
        recipients.copy(),
        utf8,
        has_eight_bit(message),
        len(normalized),
    )
