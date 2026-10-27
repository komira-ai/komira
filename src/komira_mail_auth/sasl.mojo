# SASL PLAIN (RFC 4616) and LOGIN payload decoding, and the continuation-line
# cap. RFC 4954 section 4 calls 12288 octets a sufficient line length and has
# a server fail the exchange with 500 (enhanced status 5.5.6) when a line
# exceeds the server's own buffer.

from komira_encoding import base64_decode

# The longest client line that a server accepts in answer to a `334`
# challenge. The count excludes the CRLF; that is this library's choice, the
# RFC does not say. A longer line is answered with 500 5.5.6.
comptime MAX_SASL_LINE_BYTES: Int = 12288

# base64 of "Username:" and of "Password:", the prompts of the LOGIN exchange.
comptime SASL_LOGIN_USERNAME_CHALLENGE: StaticString = "VXNlcm5hbWU6"
comptime SASL_LOGIN_PASSWORD_CHALLENGE: StaticString = "UGFzc3dvcmQ6"


struct SaslCredentials(Copyable, Movable):
    """A decoded username and password. It has no `Writable` form, so printing
    it does not compile. It is Copyable and the password is a plain String: it
    is not zeroed when the value is destroyed, so keep copies few."""

    var authcid: String
    var password: String

    def __init__(out self, var authcid: String, var password: String):
        self.authcid = authcid^
        self.password = password^


def sasl_line_within_cap(length: Int) -> Bool:
    """True iff a continuation line of `length` bytes (CRLF excluded) is at
    most `MAX_SASL_LINE_BYTES`. A server checks the length before it decodes;
    the decoders refuse an over-long payload as well."""
    return length >= 0 and length <= MAX_SASL_LINE_BYTES


def _is_valid_utf8(b: Span[UInt8, _], start: Int, end: Int) -> Bool:
    # RFC 3629: no overlong form, no surrogate, nothing above U+10FFFF.
    var i = start
    while i < end:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        var need: Int
        var cp: Int
        var lo: Int
        if (c & 0xE0) == 0xC0:
            need = 1
            cp = c & 0x1F
            lo = 0x80
        elif (c & 0xF0) == 0xE0:
            need = 2
            cp = c & 0x0F
            lo = 0x800
        elif (c & 0xF8) == 0xF0:
            need = 3
            cp = c & 0x07
            lo = 0x10000
        else:
            return False
        if i + need >= end:
            return False
        for k in range(1, need + 1):
            var cont = Int(b[i + k])
            if (cont & 0xC0) != 0x80:
                return False
            cp = (cp << 6) | (cont & 0x3F)
        if cp < lo or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
            return False
        i += need + 1
    return True


def _text(b: Span[UInt8, _], start: Int, end: Int) -> String:
    # The caller has checked the range with _is_valid_utf8.
    # SAFETY: the bytes b[start:end] are valid UTF-8 and are copied.
    var out = List[UInt8](capacity=end - start)
    for i in range(start, end):
        out.append(b[i])
    return String(unsafe_from_utf8=Span(out))


def decode_sasl_plain(payload: String) -> Optional[SaslCredentials]:
    """Decode the base64 PLAIN response `authzid NUL authcid NUL password`.

    Refused (None): a payload longer than `MAX_SASL_LINE_BYTES`, base64 that
    is not canonical, a payload that does not have exactly three NUL-separated
    fields (a missing or an extra NUL), an empty authcid, an empty password,
    an authzid that is not empty and differs from the authcid, and a field
    that is not UTF-8. When the authzid is the authcid it is accepted and the
    credentials are for the authcid.

    The RFC 4954 empty initial response `=` and the empty string are None
    like any bad payload: the caller treats `AUTH PLAIN =` and a bare
    `AUTH PLAIN` as "send an empty 334 challenge" and decodes the next line.
    The decoded buffer holding the password is not wiped, and no SASLprep
    (RFC 4013) is applied. The authcid may hold CR, LF or other control
    characters: do not log it raw."""
    if not sasl_line_within_cap(payload.byte_length()):
        return None
    var raw: List[UInt8]
    try:
        raw = base64_decode(payload)
    except:
        return None
    var n = len(raw)
    var first = -1
    var second = -1
    for i in range(n):
        if raw[i] == 0:
            if first < 0:
                first = i
            elif second < 0:
                second = i
            else:
                return None
    if first < 0 or second < 0:
        return None
    var authzid_end = first
    var authcid_start = first + 1
    var authcid_end = second
    var pass_start = second + 1
    if authcid_end == authcid_start or pass_start == n:
        return None
    var span = Span(raw)
    if authzid_end > 0:
        if authzid_end != authcid_end - authcid_start:
            return None
        for k in range(authzid_end):
            if raw[k] != raw[authcid_start + k]:
                return None
    if not _is_valid_utf8(span, authcid_start, authcid_end):
        return None
    if not _is_valid_utf8(span, pass_start, n):
        return None
    return Optional[SaslCredentials](
        SaslCredentials(
            _text(span, authcid_start, authcid_end), _text(span, pass_start, n)
        )
    )


def decode_sasl_login_value(reply: String) -> Optional[String]:
    """Decode one base64 LOGIN reply (a username or a password). Refused
    (None): a reply longer than `MAX_SASL_LINE_BYTES`, non-canonical base64,
    an empty value (`=` included), a NUL byte, invalid UTF-8. The decoded
    buffer is not wiped, no SASLprep is applied, and a username may hold
    control characters: do not log it raw."""
    if not sasl_line_within_cap(reply.byte_length()):
        return None
    var raw: List[UInt8]
    try:
        raw = base64_decode(reply)
    except:
        return None
    var n = len(raw)
    if n == 0:
        return None
    for i in range(n):
        if raw[i] == 0:
            return None
    var span = Span(raw)
    if not _is_valid_utf8(span, 0, n):
        return None
    return Optional[String](_text(span, 0, n))


def decode_sasl_login(
    username_reply: String, password_reply: String
) -> Optional[SaslCredentials]:
    """Decode the two replies of a LOGIN exchange. None if either is refused by
    `decode_sasl_login_value`."""
    var user = decode_sasl_login_value(username_reply)
    var password = decode_sasl_login_value(password_reply)
    if not user or not password:
        return None
    return Optional[SaslCredentials](
        SaslCredentials(user.take(), password.take())
    )
