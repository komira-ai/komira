# Sending one message: connect (or take a session), greet, EHLO, secure the
# connection as the config says, AUTH, MAIL/RCPT/DATA, QUIT.

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.socket_setup import set_tcp_nodelay
from komira_async.runtime.tcp_stream import TcpStream
from komira_http_core.transport.io_stream import IoStream
from komira_http_core.transport.kernel_tcp import TcpIoStream
from komira_mail_message import MessageBuilder
from komira_net.dns import resolve_host_be

from .config import SmtpClientConfig, SmtpCredentials, check_config
from .reply import SmtpReply
from .result import (
    RecipientResult,
    SEND_PERMANENT,
    SEND_TRANSIENT,
    SendResult,
    outcome_of_code,
)
from .session import NoWaitHook, SmtpRuntime, SmtpSession, WaitHook
from .wire import validate_envelope


def _refusal(stage: String, reply: SmtpReply) -> SendResult:
    """A reply that ended the send before any message went out."""
    var outcome = SEND_PERMANENT
    if reply.is_transient():
        outcome = SEND_TRANSIENT
    return SendResult(
        outcome,
        stage,
        reply.code,
        reply.text(),
        reply.enhanced.copy(),
        List[RecipientResult](),
    )


def _quit_quietly[S: IoStream, H: WaitHook](
    mut session: SmtpSession[S, H]
):
    try:
        _ = session.quit()
    except:
        pass
    session.close()


def _authenticate_and_send[S: IoStream, H: WaitHook](
    mut session: SmtpSession[S, H],
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    message: Span[UInt8, _],
) raises -> SendResult:
    """AUTH and send; a failure that is raised (a refused SIZE, an AUTH policy
    error) still ends the connection with a QUIT, so a TLS stream sends its
    close_notify and the server is told."""
    try:
        return _auth_send_inner(
            session, config, creds, mail_from, recipients, message
        )
    except e:
        _quit_quietly(session)
        raise Error(String(e))


def _auth_send_inner[S: IoStream, H: WaitHook](
    mut session: SmtpSession[S, H],
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    message: Span[UInt8, _],
) raises -> SendResult:
    if creds:
        var ar = session.authenticate(
            creds.value(), config.security.is_plaintext()
        )
        if ar.code != 235:
            _quit_quietly(session)
            return _refusal(String("auth"), ar)
    var result = session.send(mail_from, recipients, message)
    _quit_quietly(session)
    return result^


def send_via_session[S: IoStream, H: WaitHook](
    var session: SmtpSession[S, H],
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    message: Span[UInt8, _],
) raises -> SendResult:
    """Send one message over a session that has just been opened: read the
    greeting, EHLO, secure the connection as `config.security` says, AUTH when
    `creds` is given, send, QUIT. `send_message` is this over a new TCP
    connection; it is public for streams other than TCP.

    With `SmtpSecurity.starttls()` a server that does not offer STARTTLS, or
    whose handshake fails, raises `SmtpSecurity` and nothing is sent: there is
    no step down to the clear. With `implicit_tls()` the session must already
    be over TLS (`SmtpSession.is_secure`). Credentials go on the wire only
    after TLS, unless the security is `plaintext()`."""
    check_config(config)
    _ = validate_envelope(mail_from, recipients, message)
    if config.security.is_implicit_tls() and not session.is_secure():
        session.close()
        raise Error(
            "SmtpSecurity: implicit TLS was asked for and the stream is not TLS"
        )
    var greeting = session.read_greeting()
    if greeting.code != 220:
        session.close()
        if greeting.is_positive():
            raise Error(
                "SmtpProtocol: greeting: the greeting code is "
                + String(greeting.code)
                + ", not 220"
            )
        return _refusal(String("greeting"), greeting)
    var hello = session.ehlo()
    if hello.code != 250:
        _quit_quietly(session)
        return _refusal(String("ehlo"), hello)
    if config.security.is_plaintext():
        return _authenticate_and_send(
            session, config, creds, mail_from, recipients, message
        )
    if config.security.is_implicit_tls():
        return _authenticate_and_send(
            session, config, creds, mail_from, recipients, message
        )
    if session.is_secure():
        return _authenticate_and_send(
            session, config, creds, mail_from, recipients, message
        )
    if not session.capabilities().starttls:
        session.close()
        raise Error(
            "SmtpSecurity: STARTTLS is required and the server does not offer"
            " it; nothing was sent"
        )
    var go = session.starttls_command()
    if go.code != 220:
        _quit_quietly(session)
        return _refusal(String("starttls"), go)
    var secure = session.upgrade_tls(
        config.tls_trust_pem, config.effective_tls_server_name()
    )
    var hello2 = secure.ehlo()
    if hello2.code != 250:
        _quit_quietly(secure)
        return _refusal(String("ehlo"), hello2)
    return _authenticate_and_send(
        secure, config, creds, mail_from, recipients, message
    )


def _dial(config: SmtpClientConfig, mut rt: SmtpRuntime) raises -> TcpIoStream:
    # This calls `TcpStream.connect` and not `KernelTcpConnector`: the
    # connector dials with a fixed 5 s connect limit and takes no budget, and
    # `config.connect_budget_us` must bound the connect. It is the same call,
    # wrapped in the same `TcpIoStream`, with `set_tcp_nodelay`. The name is
    # resolved first, with getaddrinfo, which no budget bounds.
    try:
        var ip_be = resolve_host_be(config.host, config.port)
        var budget = config.connect_budget_us
        if budget > 2_000_000_000:
            budget = 2_000_000_000
        var s = TcpStream.connect[NoopSink](
            rt.reactor(),
            ip_be,
            config.port,
            connect_timeout_us=Int32(budget),
        )
        set_tcp_nodelay(s.fd())
        return TcpIoStream(s^)
    except e:
        raise Error("SmtpTransport: connect: " + String(e))


def connect_session[H: WaitHook](
    var hook: H, config: SmtpClientConfig
) raises -> SmtpSession[TcpIoStream, H]:
    """Connect to `config.host:config.port` and return the session over the
    plain TCP stream, before the greeting is read: for a caller that sends
    several messages on one connection. It drives the steps itself
    (`read_greeting`, `ehlo`, `starttls_command`, `upgrade_tls`, `ehlo`,
    `authenticate`, `send`, `quit`), or hands the session to `send_via_session`
    for one message. The session is plain whatever `config.security` says: for
    implicit TLS call `upgrade_tls` on it before the greeting."""
    check_config(config)
    var rt = SmtpRuntime.new(NoopSink(_placeholder=UInt8(0)))
    var stream = _dial(config, rt)
    return SmtpSession[TcpIoStream, H](
        stream^,
        hook^,
        rt^,
        config.clock,
        config.ehlo_name,
        config.command_budget_us,
        config.data_budget_us,
        config.max_reply_line_bytes,
        False,
    )


def send_message_with_hook[H: WaitHook](
    var hook: H,
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    message: Span[UInt8, _],
) raises -> SendResult:
    """`send_message` with a `WaitHook` that is called each time the client
    waits for the server. A test that runs the server in the same thread passes
    a hook that steps it; see `WaitHook`. This is a test seam: production code
    calls `send_message`."""
    check_config(config)
    _ = validate_envelope(mail_from, recipients, message)
    var plain = connect_session[H](hook^, config)
    if config.security.is_implicit_tls():
        var tls = plain.upgrade_tls(
            config.tls_trust_pem, config.effective_tls_server_name()
        )
        return send_via_session(
            tls^, config, creds, mail_from, recipients, message
        )
    return send_via_session(
        plain^, config, creds, mail_from, recipients, message
    )


def send_message(
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    message: Span[UInt8, _],
) raises -> SendResult:
    """Connect to `config.host:config.port`, secure the connection as
    `config.security` says, authenticate with `creds` (when given; they are not
    kept), send `message` (a complete RFC 5322 message; line breaks are
    normalised to CRLF and dot-stuffed) from `mail_from` (empty for a bounce) to
    `recipients` (each `local@domain`, no angle brackets), and QUIT.

    Returns the server's answer: see `SendResult`. Raises, with the kinds of
    `SmtpSession`, for everything that is not a server reply."""
    return send_message_with_hook[NoWaitHook](
        NoWaitHook(), config, creds, mail_from, recipients, message
    )


def send_built_message_with_hook[H: WaitHook](
    var hook: H,
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    builder: MessageBuilder,
) raises -> SendResult:
    """`send_message_with_hook` (a test seam) of the bytes `builder.build()`
    produces."""
    var bytes = builder.build()
    return send_message_with_hook[H](
        hook^, config, creds, mail_from, recipients, Span(bytes)
    )


def send_built_message(
    config: SmtpClientConfig,
    creds: Optional[SmtpCredentials],
    mail_from: String,
    recipients: List[String],
    builder: MessageBuilder,
) raises -> SendResult:
    """`send_message` of the bytes `builder.build()` produces."""
    return send_built_message_with_hook[NoWaitHook](
        NoWaitHook(), config, creds, mail_from, recipients, builder
    )
