# SMTP AUTH (RFC 4954): PLAIN and LOGIN over the decoders and the verifier of
# komira_mail_auth. Pure: the verifier is the only thing consulted.

from komira_mail_auth import (
    MailAuthVerifier,
    SASL_LOGIN_PASSWORD_CHALLENGE,
    SASL_LOGIN_USERNAME_CHALLENGE,
    SaslCredentials,
    decode_sasl_login,
    decode_sasl_login_value,
    decode_sasl_plain,
)

from .connection import (
    CommandResult,
    SMTP_ACTION_CLOSE,
    SMTP_STATE_READY,
    SmtpConnection,
)
from .limits import SmtpServerConfig

# `SmtpConnection.auth_stage`
comptime AUTH_NONE: UInt8 = 0
comptime AUTH_LOGIN_USER: UInt8 = 1  # waiting for the base64 username
comptime AUTH_LOGIN_PASSWORD: UInt8 = 2  # waiting for the base64 password
comptime AUTH_PLAIN: UInt8 = 3  # waiting for the base64 PLAIN payload


def _upper(c: UInt8) -> UInt8:
    if c >= 0x61 and c <= 0x7A:
        return c - 32
    return c


def text_of_printable(line: Span[UInt8, _], start: Int, end: Int) -> Optional[String]:
    """The bytes `line[start:end]` as a String when every byte is printable
    ASCII without a space, else None (a base64 value, an EHLO name)."""
    var out = List[UInt8]()
    for i in range(start, end):
        var c = line[i]
        if c < 0x21 or c > 0x7E:
            return None
        out.append(c)
    return Optional[String](String(unsafe_from_utf8=Span(out)))


def _failure(mut conn: SmtpConnection, config: SmtpServerConfig, text: String) -> CommandResult:
    """A failed attempt: count it. The attempt that reaches the cap is
    answered 421 and the connection closes; no later attempt is tried."""
    conn.auth_failures += 1
    conn.auth_stage = AUTH_NONE
    conn.auth_user_b64 = String("")
    if conn.auth_failures >= config.limits.max_auth_failures:
        conn.mark_closing()
        return CommandResult(
            String("421 4.7.0 Too many failed authentication attempts\r\n"),
            SMTP_ACTION_CLOSE,
        )
    return CommandResult(text)


def _check[
    V: MailAuthVerifier
](
    mut conn: SmtpConnection,
    config: SmtpServerConfig,
    verifier: V,
    var credentials: Optional[SaslCredentials],
) -> CommandResult:
    conn.auth_stage = AUTH_NONE
    conn.auth_user_b64 = String("")
    if not credentials:
        return _failure(
            conn,
            config,
            String("501 5.5.2 Invalid authentication payload\r\n"),
        )
    var c = credentials.take()
    if verifier.verify(c.authcid, c.password):
        conn.authed_user = c.authcid.copy()
        return CommandResult(String("235 2.7.0 Authentication successful\r\n"))
    return _failure(
        conn,
        config,
        String("535 5.7.8 Authentication credentials invalid\r\n"),
    )


def handle_auth_command[
    V: MailAuthVerifier
](
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    args: Int,
    config: SmtpServerConfig,
    verifier: V,
) -> CommandResult:
    """`AUTH <mechanism> [initial-response]`; `args` indexes the first byte
    after the verb. Refused: on a clear channel when TLS is required (538), a
    second AUTH after success and AUTH inside a transaction (503)."""
    if config.require_tls_for_auth and not conn.tls_active:
        return CommandResult(
            String(
                "538 5.7.11 Encryption required for requested authentication"
                " mechanism\r\n"
            )
        )
    if conn.authed_user.byte_length() > 0:
        return CommandResult(String("503 5.5.1 Already authenticated\r\n"))
    if conn.state != SMTP_STATE_READY:
        return CommandResult(
            String("503 5.5.1 Bad sequence of commands (send EHLO first)\r\n")
        )
    var n = len(line)
    var i = args
    while i < n and line[i] == 0x20:
        i += 1
    var mech_start = i
    while i < n and line[i] != 0x20:
        i += 1
    var mech_end = i
    while i < n and line[i] == 0x20:
        i += 1
    var ir_start = i
    var ir_end = n
    if mech_end == mech_start:
        return CommandResult(String("501 5.5.4 Syntax error: AUTH needs a mechanism\r\n"))
    var mech = List[UInt8]()
    for k in range(mech_start, mech_end):
        mech.append(_upper(line[k]))
    var mech_text = String(unsafe_from_utf8=Span(mech))
    var has_ir = ir_end > ir_start
    var ir = Optional[String]()
    if has_ir:
        ir = text_of_printable(line, ir_start, ir_end)
        if not ir:
            return _failure(
                conn,
                config,
                String("501 5.5.2 Invalid authentication payload\r\n"),
            )
    if mech_text == "PLAIN":
        if has_ir and ir.value() != "=":
            return _check(conn, config, verifier, decode_sasl_plain(ir.value()))
        conn.auth_stage = AUTH_PLAIN
        return CommandResult(String("334 \r\n"))
    if mech_text == "LOGIN":
        conn.auth_stage = AUTH_LOGIN_USER
        if has_ir and ir.value() != "=":
            return continue_auth(conn, ir.value(), config, verifier)
        return CommandResult(
            String("334 ") + String(SASL_LOGIN_USERNAME_CHALLENGE) + "\r\n"
        )
    return CommandResult(
        String("504 5.5.4 Unrecognized authentication mechanism\r\n")
    )


def handle_auth_line[
    V: MailAuthVerifier
](
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    config: SmtpServerConfig,
    verifier: V,
) -> CommandResult:
    """A continuation line after a `334`: base64 text, or `*` to cancel."""
    if len(line) == 1 and line[0] == 0x2A:
        conn.auth_stage = AUTH_NONE
        conn.auth_user_b64 = String("")
        return CommandResult(String("501 5.7.0 Authentication cancelled\r\n"))
    var text = text_of_printable(line, 0, len(line))
    if not text:
        return _failure(
            conn,
            config,
            String("501 5.5.2 Invalid authentication payload\r\n"),
        )
    return continue_auth(conn, text.value(), config, verifier)


def continue_auth[
    V: MailAuthVerifier
](
    mut conn: SmtpConnection,
    text: String,
    config: SmtpServerConfig,
    verifier: V,
) -> CommandResult:
    var stage = conn.auth_stage
    if stage == AUTH_PLAIN:
        return _check(conn, config, verifier, decode_sasl_plain(text))
    if stage == AUTH_LOGIN_USER:
        if not decode_sasl_login_value(text):
            return _failure(
                conn,
                config,
                String("501 5.5.2 Invalid authentication payload\r\n"),
            )
        conn.auth_user_b64 = text
        conn.auth_stage = AUTH_LOGIN_PASSWORD
        return CommandResult(
            String("334 ") + String(SASL_LOGIN_PASSWORD_CHALLENGE) + "\r\n"
        )
    # AUTH_LOGIN_PASSWORD
    var user_b64 = conn.auth_user_b64
    return _check(conn, config, verifier, decode_sasl_login(user_b64, text))
