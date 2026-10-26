# The command state machine: one complete line in, a reply and an action out.
#
# RFC 5321 with the RFC 3207 (STARTTLS) and RFC 4954 (AUTH) additions. No
# socket, no clock: the time is a parameter, the connection is a value.

from komira_mail_address import parse_path, parse_reverse_path
from komira_mail_auth import MailAuthVerifier

from .auth import AUTH_NONE, handle_auth_command, handle_auth_line, text_of_printable
from .connection import (
    CommandResult,
    SMTP_ACTION_CLOSE,
    SMTP_ACTION_CONTINUE,
    SMTP_ACTION_ENTER_DATA,
    SMTP_ACTION_START_TLS,
    SMTP_STATE_DATA,
    SMTP_STATE_GREETED,
    SMTP_STATE_MAIL,
    SMTP_STATE_RCPT,
    SMTP_STATE_READY,
    SmtpConnection,
)
from .data import session_info
from .delivery import MailDelivery, rcpt_reply
from .limits import SmtpServerConfig

comptime _SP: UInt8 = 0x20
comptime _LT: UInt8 = 0x3C
comptime _GT: UInt8 = 0x3E
comptime _QUOTE: UInt8 = 0x22
comptime _BACKSLASH: UInt8 = 0x5C
comptime _COLON: UInt8 = 0x3A
comptime _EQUALS: UInt8 = 0x3D
comptime _MAX_NAME_BYTES: Int = 255


def _upper(c: UInt8) -> UInt8:
    if c >= 0x61 and c <= 0x7A:
        return c - 32
    return c


def _eq_ci(line: Span[UInt8, _], start: Int, end: Int, word: String) -> Bool:
    """`line[start:end]` equals the upper-case ASCII `word`, ignoring case."""
    var w = word.as_bytes()
    if end - start != len(w):
        return False
    for i in range(len(w)):
        if _upper(line[start + i]) != w[i]:
            return False
    return True


def _token_end(line: Span[UInt8, _], start: Int) -> Int:
    var i = start
    while i < len(line) and line[i] != _SP:
        i += 1
    return i


def _skip_spaces(line: Span[UInt8, _], start: Int) -> Int:
    var i = start
    while i < len(line) and line[i] == _SP:
        i += 1
    return i


def _bad_sequence() -> CommandResult:
    return CommandResult(String("503 5.5.1 Bad sequence of commands\r\n"))


def _syntax(text: String) -> CommandResult:
    return CommandResult(String("501 5.5.4 ") + text + "\r\n")


def ehlo_reply(config: SmtpServerConfig, tls_active: Bool) -> String:
    """The multi-line answer to EHLO. PIPELINING, 8BITMIME, SIZE and
    ENHANCEDSTATUSCODES always; STARTTLS while the channel is clear and a
    certificate is configured; AUTH only once AUTH is allowed (on TLS, unless
    `require_tls_for_auth` is off)."""
    var caps = List[String]()
    caps.append(String("PIPELINING"))
    caps.append(String("8BITMIME"))
    caps.append(String("SIZE ") + String(config.limits.max_message_bytes))
    caps.append(String("ENHANCEDSTATUSCODES"))
    if config.offer_starttls and not tls_active:
        caps.append(String("STARTTLS"))
    if tls_active or not config.require_tls_for_auth:
        caps.append(String("AUTH PLAIN LOGIN"))
    var out = String("250-") + config.hostname + " greets you\r\n"
    for i in range(len(caps)):
        if i + 1 < len(caps):
            out += String("250-") + caps[i] + "\r\n"
        else:
            out += String("250 ") + caps[i] + "\r\n"
    return out^


def greeting(config: SmtpServerConfig) -> String:
    """The 220 a connection starts with."""
    return String("220 ") + config.hostname + " ESMTP ready\r\n"


# ---- addresses and parameters -----------------------------------------------


def _path_end(line: Span[UInt8, _], start: Int) -> Int:
    """`line[start]` is `<`. The index just past the `>` that closes the path,
    or -1. A `>` inside a quoted local part does not close it."""
    var n = len(line)
    var i = start + 1
    var quoted = False
    while i < n:
        var c = line[i]
        if quoted:
            if c == _BACKSLASH:
                i += 2
                continue
            if c == _QUOTE:
                quoted = False
        else:
            if c == _QUOTE:
                quoted = True
            elif c == _GT:
                return i + 1
        i += 1
    return -1


struct _PathArg(Movable):
    """The part of `MAIL FROM:<path> params` or `RCPT TO:<path> params` after
    the keyword: where the path is, and where the parameters start. `ok`
    False means the keyword or the brackets are wrong."""

    var ok: Bool
    var path_start: Int
    var path_end: Int
    var params_start: Int

    def __init__(out self):
        self.ok = False
        self.path_start = 0
        self.path_end = 0
        self.params_start = 0


def _split_path_arg(line: Span[UInt8, _], args: Int, keyword: String) -> _PathArg:
    """Check `<keyword>:` (for example `FROM:`) at `args`, then a bracketed
    path, then either the end or a space and parameters. The keyword must
    match exactly (any case); spaces after the colon are tolerated."""
    var out = _PathArg()
    var i = _skip_spaces(line, args)
    var kw = keyword.as_bytes()
    var n = len(line)
    if i + len(kw) + 1 > n:
        return out^
    for k in range(len(kw)):
        if _upper(line[i + k]) != kw[k]:
            return out^
    i += len(kw)
    if line[i] != _COLON:
        return out^
    i += 1
    i = _skip_spaces(line, i)
    if i >= n or line[i] != _LT:
        return out^
    var end = _path_end(line, i)
    if end < 0:
        return out^
    if end < n and line[end] != _SP:
        return out^
    out.ok = True
    out.path_start = i
    out.path_end = end
    out.params_start = _skip_spaces(line, end)
    return out^


def _parse_size(line: Span[UInt8, _], start: Int, end: Int) -> Int:
    """The decimal value of `line[start:end]`, or -1 for no digits, a
    non-digit, or more than 15 digits."""
    if end <= start or end - start > 15:
        return -1
    var v = 0
    for i in range(start, end):
        var c = line[i]
        if c < 0x30 or c > 0x39:
            return -1
        v = v * 10 + Int(c - 0x30)
    return v


def _mail_params(
    line: Span[UInt8, _],
    start: Int,
    config: SmtpServerConfig,
    mut declared_size: Int,
    mut body_8bit: Bool,
) -> Optional[String]:
    """Check the parameters of MAIL FROM. None: all fine, and `declared_size`
    and `body_8bit` hold what was declared. Else the reply. SIZE=n above the
    cap is 552 before any DATA; BODY=7BIT or 8BITMIME is accepted; anything
    else is 555."""
    var n = len(line)
    var i = start
    var seen_size = False
    var seen_body = False
    while i < n:
        var end = _token_end(line, i)
        var eq = i
        while eq < end and line[eq] != _EQUALS:
            eq += 1
        if _eq_ci(line, i, eq, "SIZE") and eq < end:
            if seen_size:
                return Optional[String](
                    String("501 5.5.4 Syntax error: SIZE given twice\r\n")
                )
            seen_size = True
            var v = _parse_size(line, eq + 1, end)
            if v < 0:
                return Optional[String](
                    String("501 5.5.4 Syntax error: bad SIZE value\r\n")
                )
            if v > config.limits.max_message_bytes:
                return Optional[String](
                    String("552 5.3.4 Message size exceeds fixed maximum\r\n")
                )
            declared_size = v
        elif _eq_ci(line, i, eq, "BODY") and eq < end:
            if seen_body:
                return Optional[String](
                    String("501 5.5.4 Syntax error: BODY given twice\r\n")
                )
            seen_body = True
            if not (
                _eq_ci(line, eq + 1, end, "7BIT")
                or _eq_ci(line, eq + 1, end, "8BITMIME")
            ):
                return Optional[String](
                    String("555 5.5.4 BODY value not recognized\r\n")
                )
            body_8bit = _eq_ci(line, eq + 1, end, "8BITMIME")
        else:
            return Optional[String](
                String("555 5.5.4 MAIL FROM parameter not recognized\r\n")
            )
        i = _skip_spaces(line, end)
    return None


# ---- the verbs ----------------------------------------------------------------


def _handle_ehlo(
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    args: Int,
    is_ehlo: Bool,
    config: SmtpServerConfig,
) -> CommandResult:
    var start = _skip_spaces(line, args)
    var end = _token_end(line, start)
    if end == start or _skip_spaces(line, end) != len(line):
        return _syntax(String("EHLO and HELO need one domain or address literal"))
    if end - start > _MAX_NAME_BYTES:
        return _syntax(String("domain too long"))
    var name = text_of_printable(line, start, end)
    if not name:
        return _syntax(String("domain holds a character that is not allowed"))
    # RFC 5321 section 4.1.4: EHLO and HELO end any transaction, like RSET.
    # The verified user stays (RFC 4954 section 4 does not clear it).
    conn.reset_transaction()
    conn.helo = name.take()
    conn.state = SMTP_STATE_READY
    if is_ehlo:
        return CommandResult(ehlo_reply(config, conn.tls_active))
    return CommandResult(String("250 ") + config.hostname + "\r\n")


def _handle_starttls(
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    args: Int,
    config: SmtpServerConfig,
) -> CommandResult:
    if not config.offer_starttls:
        return CommandResult(String("502 5.5.1 STARTTLS not available\r\n"))
    if _skip_spaces(line, args) != len(line):
        return _syntax(String("STARTTLS takes no parameters"))
    if conn.tls_active:
        return CommandResult(String("503 5.5.1 TLS already active\r\n"))
    if conn.state != SMTP_STATE_READY:
        return CommandResult(
            String("503 5.5.1 Bad sequence of commands (send EHLO first)\r\n")
        )
    conn.reset_for_tls()
    conn.starttls_pending = True
    return CommandResult(
        String("220 2.0.0 Ready to start TLS\r\n"), SMTP_ACTION_START_TLS
    )


def _handle_mail(
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    args: Int,
    config: SmtpServerConfig,
) -> CommandResult:
    if conn.state != SMTP_STATE_READY:
        return _bad_sequence()
    if config.submission:
        if config.require_tls_for_auth and not conn.tls_active:
            return CommandResult(
                String("530 5.7.0 Must issue a STARTTLS command first\r\n")
            )
        if conn.authed_user.byte_length() == 0:
            return CommandResult(String("530 5.7.0 Authentication required\r\n"))
    var arg = _split_path_arg(line, args, String("FROM"))
    if not arg.ok:
        return _syntax(String("expected MAIL FROM:<address>"))
    var path = Span(line)[arg.path_start : arg.path_end]
    var from_text = String("")
    try:
        var parsed = parse_reverse_path(path)
        if parsed:
            from_text = parsed.value().format()
    except:
        return CommandResult(String("501 5.1.7 Bad sender address syntax\r\n"))
    var declared = -1
    var eight_bit = False
    var refusal = _mail_params(line, arg.params_start, config, declared, eight_bit)
    if refusal:
        return CommandResult(refusal.take())
    conn.mail_from = from_text^
    conn.declared_size = declared
    conn.body_8bit = eight_bit
    conn.recipients = List[String]()
    conn.state = SMTP_STATE_MAIL
    return CommandResult(String("250 2.1.0 Ok\r\n"))


def _handle_rcpt[
    D: MailDelivery
](
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    args: Int,
    config: SmtpServerConfig,
    mut delivery: D,
) -> CommandResult:
    if conn.state != SMTP_STATE_MAIL and conn.state != SMTP_STATE_RCPT:
        return CommandResult(
            String("503 5.5.1 Bad sequence of commands (send MAIL first)\r\n")
        )
    var arg = _split_path_arg(line, args, String("TO"))
    if not arg.ok:
        return _syntax(String("expected RCPT TO:<address>"))
    var rcpt: String
    var path = Span(line)[arg.path_start : arg.path_end]
    if _eq_ci(path, 1, len(path) - 1, "POSTMASTER") and path[0] == _LT:
        # RFC 5321 section 4.5.1: the reserved mailbox is accepted without a
        # domain (it names the postmaster of this server's domain).
        rcpt = String("postmaster")
    else:
        try:
            rcpt = parse_path(path).format()
        except:
            return CommandResult(
                String("501 5.1.3 Bad recipient address syntax\r\n")
            )
    if arg.params_start < len(line):
        return CommandResult(
            String("555 5.5.4 RCPT TO parameter not recognized\r\n")
        )
    if len(conn.recipients) >= config.limits.max_recipients:
        return CommandResult(String("452 4.5.3 Too many recipients\r\n"))
    var info = session_info(conn, config)
    var decision = delivery.accept_recipient(info, conn.mail_from, rcpt)
    if decision.code != 0 and decision.code != 250:
        return CommandResult(rcpt_reply(decision))
    conn.recipients.append(rcpt^)
    conn.state = SMTP_STATE_RCPT
    return CommandResult(String("250 2.1.5 Ok\r\n"))


def handle_command_line[
    V: MailAuthVerifier,
    D: MailDelivery,
](
    mut conn: SmtpConnection,
    line: Span[UInt8, _],
    config: SmtpServerConfig,
    verifier: V,
    mut delivery: D,
    now_ms: Int,
) -> CommandResult:
    """Run one complete command line (CRLF excluded) on `conn`.

    While an AUTH exchange waits for a `334` answer the line is that answer.
    Otherwise the first word is the verb. The connection's state and
    transaction change here; the returned action says what the serving loop
    must do: nothing, close after the reply, start TLS after the reply, or
    (after DATA) read message text."""
    if conn.auth_stage != AUTH_NONE:
        return handle_auth_line(conn, line, config, verifier)

    conn.commands_in_txn += 1
    if conn.commands_in_txn > config.limits.max_commands:
        conn.mark_closing()
        return CommandResult(
            String("421 4.7.0 Too many commands, closing\r\n"), SMTP_ACTION_CLOSE
        )

    var verb_end = _token_end(line, 0)
    if verb_end == 0:
        return CommandResult(String("500 5.5.2 Syntax error, command expected\r\n"))

    if _eq_ci(line, 0, verb_end, "EHLO"):
        return _handle_ehlo(conn, line, verb_end, True, config)
    if _eq_ci(line, 0, verb_end, "HELO"):
        return _handle_ehlo(conn, line, verb_end, False, config)
    if _eq_ci(line, 0, verb_end, "STARTTLS"):
        return _handle_starttls(conn, line, verb_end, config)
    if _eq_ci(line, 0, verb_end, "AUTH"):
        return handle_auth_command(conn, line, verb_end, config, verifier)
    if _eq_ci(line, 0, verb_end, "MAIL"):
        return _handle_mail(conn, line, verb_end, config)
    if _eq_ci(line, 0, verb_end, "RCPT"):
        return _handle_rcpt(conn, line, verb_end, config, delivery)
    if _eq_ci(line, 0, verb_end, "DATA"):
        if _skip_spaces(line, verb_end) != len(line):
            return _syntax(String("DATA takes no parameters"))
        if conn.state != SMTP_STATE_RCPT:
            return CommandResult(
                String("503 5.5.1 Bad sequence of commands (need RCPT first)\r\n")
            )
        conn.state = SMTP_STATE_DATA
        conn.data_started_ms = now_ms
        return CommandResult(
            String("354 End data with <CR><LF>.<CR><LF>\r\n"),
            SMTP_ACTION_ENTER_DATA,
        )
    if _eq_ci(line, 0, verb_end, "RSET"):
        if _skip_spaces(line, verb_end) != len(line):
            return _syntax(String("RSET takes no parameters"))
        conn.reset_transaction()
        return CommandResult(String("250 2.0.0 Ok\r\n"))
    if _eq_ci(line, 0, verb_end, "NOOP"):
        return CommandResult(String("250 2.0.0 Ok\r\n"))
    if _eq_ci(line, 0, verb_end, "QUIT"):
        conn.mark_closing()
        return CommandResult(
            String("221 2.0.0 ") + config.hostname + " closing connection\r\n",
            SMTP_ACTION_CLOSE,
        )
    if (
        _eq_ci(line, 0, verb_end, "VRFY")
        or _eq_ci(line, 0, verb_end, "HELP")
        or _eq_ci(line, 0, verb_end, "EXPN")
    ):
        return CommandResult(String("502 5.5.1 Command not implemented\r\n"))
    return CommandResult(String("500 5.5.1 Command unrecognized\r\n"))
