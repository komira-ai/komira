# One SMTP connection, driven command by command (RFC 5321). `SmtpSession[S, H]`
# is generic over the byte stream (`IoStream`: a kernel socket, a TLS stream
# over one, or a scripted stream in tests) and over a `WaitHook`.
#
# POINTERS: none. The stream, the hook and the runtime sit in `Optional` fields
# so that the STARTTLS upgrade can move them into the next session with
# `Optional.take()`; a struct's fields cannot be moved out one by one.
#
# BLOCKING: every call blocks the calling thread until its reply has arrived or
# its budget on the injected clock has run out. It waits on the socket's
# readiness with a bounded park (`park_on_pending`), never on a count of
# attempts. A caller that owns both ends of a loopback connection in one
# thread supplies a `WaitHook` that runs the peer instead; production code uses
# `NoWaitHook`.
#
# PIPELINING is not used: each command is written and its reply read before the
# next is written, whatever the server announces.

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_encoding import base64_encode
from komira_http_client.tls_connector import TlsClientStream
from komira_http_core.tls import (
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
)
from komira_http_core.transport.io_stream import IoStream
from komira_http_core.transport.stream_park import park_on_pending

from .clock import SmtpClock
from .config import SmtpClientConfig, SmtpCredentials, check_ehlo_name
from .reply import (
    ReplyLine,
    SmtpCapabilities,
    SmtpReply,
    assemble_reply,
    parse_reply_line,
    reply_line_budget_ok,
)
from .result import (
    RecipientResult,
    SEND_PERMANENT,
    SEND_TRANSIENT,
    SendResult,
    outcome_of_code,
)
from .tls import tls_client_config
from .wire import (
    Envelope,
    dot_stuff_and_terminate,
    normalize_line_endings,
    validate_envelope,
)

comptime SmtpRuntime = BlockingRuntime[NoopSink]
"""The runtime whose reactor a session parks on."""

comptime _READ_CHUNK: Int = 4096
comptime _PARK_SLICE_US: Int = 100_000


trait WaitHook(Movable, Deinitable):
    """A test seam: production code uses `NoWaitHook`. Called each time a
    session is about to wait for the peer (a read or a write was not ready),
    before it parks."""

    def on_wait(mut self) raises -> Bool:
        """Return True when the hook made progress for the peer (it ran the
        other end of a loopback connection) and the session should retry at
        once instead of parking; False to let the session park on the socket."""
        ...


struct NoWaitHook(WaitHook, Movable, Deinitable):
    """The production hook: never makes progress for the peer."""

    def __init__(out self):
        pass

    def on_wait(mut self) raises -> Bool:
        return False


def _redact(text: String, needle: String) -> String:
    """`text` with every occurrence of `needle` replaced by `***`."""
    if needle.byte_length() == 0 or text.find(needle) < 0:
        return text
    var out = String("")
    var at = 0
    while True:
        var i = text.find(needle, at)
        if i < 0:
            out += String(text[byte=at : text.byte_length()])
            break
        out += String(text[byte=at:i])
        out += "***"
        at = i + needle.byte_length()
    return out^


def _scrub(var reply: SmtpReply, needles: List[String]) -> SmtpReply:
    var lines = List[String]()
    for i in range(len(reply.lines)):
        var t = reply.lines[i]
        for j in range(len(needles)):
            t = _redact(t, needles[j])
        lines.append(t^)
    var enhanced = reply.enhanced.copy()
    return SmtpReply(reply.code, lines^, enhanced^)


struct SmtpSession[S: IoStream, H: WaitHook](Movable):
    """One connection. Call `read_greeting`, `ehlo`, then (as the security
    needs) `starttls_command` and `upgrade_tls`, `authenticate`, and `send`
    once or several times (an RSET goes between messages), then `quit`.

    A reply the server gives is returned as a value (`SmtpReply`, or a
    `SendResult` for a whole message). A failure that is not a reply (a
    timeout, a broken connection, a malformed or over-long reply, a refused
    policy) is raised with a kind prefix: `SmtpTimeout`, `SmtpTransport`,
    `SmtpProtocol`, `SmtpSecurity`, `SmtpAuth`, `SmtpEnvelope`. After a raised
    error the connection is closed and the session refuses further commands."""

    var _stream: Optional[Self.S]
    var _hook: Optional[Self.H]
    var _rt: Optional[SmtpRuntime]
    var _clock: SmtpClock
    var _ehlo_name: String
    var _command_us: Int
    var _data_us: Int
    var _max_line: Int
    var _secure: Bool
    var _closed: Bool
    var _ehlo_done: Bool
    var _dirty: Bool
    var _caps: SmtpCapabilities
    var _rbuf: List[UInt8]
    var _scratch: List[UInt8]

    def __init__(
        out self,
        var stream: Self.S,
        var hook: Self.H,
        var rt: SmtpRuntime,
        clock: SmtpClock,
        ehlo_name: String,
        command_us: Int,
        data_us: Int,
        max_line: Int,
        secure: Bool,
    ):
        self._stream = Optional[Self.S](stream^)
        self._hook = Optional[Self.H](hook^)
        self._rt = Optional[SmtpRuntime](rt^)
        self._clock = clock.copy()
        self._ehlo_name = ehlo_name
        self._command_us = command_us
        self._data_us = data_us
        self._max_line = max_line
        self._secure = secure
        self._closed = False
        self._ehlo_done = False
        self._dirty = False
        self._caps = SmtpCapabilities()
        self._rbuf = List[UInt8]()
        self._scratch = List[UInt8](length=_READ_CHUNK, fill=UInt8(0))

    @staticmethod
    def new(
        var stream: Self.S,
        var hook: Self.H,
        config: SmtpClientConfig,
        secure: Bool = False,
    ) raises -> Self:
        """A session over `stream`. Only the budgets, the clock, `ehlo_name`
        and `max_reply_line_bytes` of `config` are used. `secure` says the
        stream is already TLS-protected (an implicit-TLS connection)."""
        check_ehlo_name(config.ehlo_name)
        var rt = SmtpRuntime.new(NoopSink(_placeholder=UInt8(0)))
        return Self(
            stream^,
            hook^,
            rt^,
            config.clock,
            config.ehlo_name,
            config.command_budget_us,
            config.data_budget_us,
            config.max_reply_line_bytes,
            secure,
        )

    # ----- state ----------------------------------------------------------

    def is_secure(self) -> Bool:
        """Whether the stream is TLS-protected."""
        return self._secure

    def is_closed(self) -> Bool:
        """Whether the connection has been closed (after an error, a 421, or
        `quit`/`close`)."""
        return self._closed

    def capabilities(self) -> SmtpCapabilities:
        """What the last EHLO announced (empty before one, and after a
        STARTTLS upgrade until the next EHLO)."""
        return self._caps.copy()

    def close(mut self):
        """Close the connection now (a TLS stream sends close_notify)."""
        self._shut()

    def _shut(mut self):
        self._closed = True
        if self._stream:
            var s = self._stream.take()
            s^.close()

    def _check_open(self) raises:
        if self._closed:
            raise Error("SmtpProtocol: the session is closed")

    # ----- errors ---------------------------------------------------------

    def _transport(mut self, stage: String, what: String) -> Error:
        self._shut()
        return Error("SmtpTransport: " + stage + ": " + what)

    def _protocol(mut self, stage: String, what: String) -> Error:
        self._shut()
        return Error("SmtpProtocol: " + stage + ": " + what)

    def _check_deadline(mut self, stage: String, deadline_us: Int) raises:
        if self._clock.now_us() >= deadline_us:
            self._shut()
            raise Error(
                "SmtpTimeout: "
                + stage
                + ": no progress within the budget; the connection was closed"
            )

    # ----- waiting --------------------------------------------------------

    def _wait(mut self, token: Int64, is_write: Bool, deadline_us: Int) raises:
        if self._hook.value().on_wait():
            return
        var left = deadline_us - self._clock.now_us()
        if left <= 0:
            return
        var slice = left
        if slice > _PARK_SLICE_US:
            slice = _PARK_SLICE_US
        _ = park_on_pending[Self.S, SmtpRuntime](
            self._stream.value(),
            self._rt.value().reactor(),
            token,
            is_write,
            Int32(slice),
        )

    def _read_some(mut self, stage: String, deadline_us: Int) raises:
        """Append at least one byte from the server to the receive buffer."""
        while True:
            self._check_deadline(stage, deadline_us)
            var r = self._stream.value().try_read[SmtpRuntime](
                self._rt.value().reactor(), Span(self._scratch)
            )
            if r.is_ready():
                var n = Int(r.n_bytes())
                if n <= 0:
                    raise self._transport(
                        stage, String("the server closed the connection")
                    )
                self._rbuf.extend(Span(self._scratch)[0:n])
                return
            if r.is_eof():
                raise self._transport(
                    stage, String("the server closed the connection")
                )
            if r.is_error():
                raise self._transport(
                    stage, String("read failed, errno ") + String(Int(r.errno()))
                )
            self._wait(r.pending_token(), False, deadline_us)

    def _write_all(
        mut self, data: Span[UInt8, _], stage: String, deadline_us: Int
    ) raises:
        var sent = 0
        var total = len(data)
        while sent < total:
            self._check_deadline(stage, deadline_us)
            var r = self._stream.value().try_write[SmtpRuntime](
                self._rt.value().reactor(), data[sent:total]
            )
            if r.is_ready():
                var n = Int(r.n_bytes())
                if n > 0:
                    sent += n
                else:
                    self._wait(Int64(0), True, deadline_us)
            elif r.is_error():
                raise self._transport(
                    stage, String("write failed, errno ") + String(Int(r.errno()))
                )
            elif r.is_eof():
                raise self._transport(
                    stage, String("the server closed the connection")
                )
            else:
                self._wait(r.pending_token(), True, deadline_us)

    def _send_line(mut self, line: String, stage: String, deadline_us: Int) raises:
        var b = line.as_bytes()
        for i in range(len(b)):
            if b[i] == 0x0D or b[i] == 0x0A:
                raise self._protocol(stage, String("a command with a line break"))
        var out = List[UInt8](capacity=len(b) + 2)
        out.extend(b)
        out.append(UInt8(0x0D))
        out.append(UInt8(0x0A))
        self._write_all(Span(out), stage, deadline_us)

    def _next_line(mut self, stage: String, deadline_us: Int) raises -> List[UInt8]:
        var scanned = 0
        while True:
            var n = len(self._rbuf)
            var i = scanned
            while i < n:
                if self._rbuf[i] == 0x0A:
                    break
                i += 1
            if i < n:
                var end = i
                if end > 0 and self._rbuf[end - 1] == 0x0D:
                    end -= 1
                if end > self._max_line:
                    raise self._protocol(
                        stage,
                        String("a reply line longer than ")
                        + String(self._max_line)
                        + " bytes",
                    )
                var line = List[UInt8](capacity=end)
                line.extend(Span(self._rbuf)[0:end])
                var rest = List[UInt8](capacity=n - i - 1)
                rest.extend(Span(self._rbuf)[i + 1 : n])
                self._rbuf = rest^
                return line^
            scanned = n
            if n > self._max_line + 1:
                raise self._protocol(
                    stage,
                    String("a reply line longer than ")
                    + String(self._max_line)
                    + " bytes",
                )
            self._read_some(stage, deadline_us)

    def _parse(mut self, raw: List[UInt8], stage: String) raises -> ReplyLine:
        try:
            return parse_reply_line(Span(raw))
        except e:
            raise self._protocol(stage, String(e))

    def _read_reply(mut self, stage: String, deadline_us: Int) raises -> SmtpReply:
        var texts = List[String]()
        var code = 0
        var total = 0
        while True:
            var raw = self._next_line(stage, deadline_us)
            var parsed = self._parse(raw, stage)
            if len(texts) > 0 and parsed.code != code:
                raise self._protocol(
                    stage, String("reply lines with different codes")
                )
            code = parsed.code
            total += len(raw)
            texts.append(parsed.text.copy())
            if not reply_line_budget_ok(len(texts), total):
                raise self._protocol(stage, String("a reply over the size caps"))
            if parsed.is_last:
                break
        if code == 421:
            # The server is closing the connection (RFC 5321 section 3.8).
            self._shut()
        return assemble_reply(code, texts)

    def _exchange(mut self, line: String, stage: String) raises -> SmtpReply:
        self._check_open()
        var deadline = self._clock.now_us() + self._command_us
        self._send_line(line, stage, deadline)
        return self._read_reply(stage, deadline)

    # ----- commands -------------------------------------------------------

    def read_greeting(mut self) raises -> SmtpReply:
        """Read the server's greeting. 220 means ready; anything else (554 is
        a refusal, 421 a closing server) is returned for the caller to act on."""
        self._check_open()
        var deadline = self._clock.now_us() + self._command_us
        return self._read_reply(String("greeting"), deadline)

    def ehlo(mut self) raises -> SmtpReply:
        """EHLO, read into `capabilities()`. A server that answers 500 or 502
        is asked HELO instead and has no capabilities. Any other reply is
        returned as it is, and the capabilities stay empty unless it is 250."""
        var r = self._exchange(String("EHLO ") + self._ehlo_name, String("EHLO"))
        if r.code == 500 or r.code == 502:
            r = self._exchange(String("HELO ") + self._ehlo_name, String("HELO"))
            if r.code == 250:
                self._caps = SmtpCapabilities()
                self._ehlo_done = True
            return r^
        if r.code == 250:
            self._caps = SmtpCapabilities.from_ehlo(r)
            self._ehlo_done = True
        else:
            self._caps = SmtpCapabilities()
            self._ehlo_done = False
        return r^

    def starttls_command(mut self) raises -> SmtpReply:
        """Send STARTTLS and read the reply. After a 220 the server must send
        nothing before the client's handshake: bytes that arrived behind the
        220 are an injection (RFC 3207 section 6) and end the session with
        `SmtpSecurity`."""
        var r = self._exchange(String("STARTTLS"), String("STARTTLS"))
        if r.code == 220 and len(self._rbuf) > 0:
            self._shut()
            raise Error(
                "SmtpSecurity: STARTTLS: the server sent bytes before the TLS"
                " handshake; the connection was closed"
            )
        return r^

    def _open_conn(
        mut self, trust_pem: String, server_name: String, fd: Int32
    ) raises -> TlsConnection:
        try:
            var cfg = tls_client_config(trust_pem)
            var conn = TlsConnection.new_client(cfg)
            conn.bind_fd(fd)
            conn.set_server_name(server_name)
            return conn^
        except e:
            self._shut()
            raise Error(
                "SmtpSecurity: TLS: could not set up the client: " + String(e)
            )

    def upgrade_tls(
        mut self, trust_pem: String, server_name: String
    ) raises -> SmtpSession[TlsClientStream[Self.S], Self.H]:
        """Run the TLS client handshake on this connection (after a 220 to
        STARTTLS, or at once for implicit TLS) and return the session over TLS.
        This session gives up its stream, hook and runtime. The server's
        certificate must chain to `trust_pem` (the system roots when empty) and
        name `server_name`; if not, `SmtpSecurity` is raised and the
        connection closed. The returned session has no capabilities: EHLO again
        (RFC 3207 section 4.2). A stream without a descriptor (a scripted one)
        cannot be upgraded.

        The handshake is stepped here, on the session's own clock and hook,
        instead of with `TlsConnector.upgrade` of komira_http_client: that
        call parks until its own deadline on the descriptor, which cannot work
        when a test steps the server in the same thread. `TlsClientStream`
        (the wrapper of a stream and its TLS connection) is komira_http_client's
        and belongs in komira_http_core; the move is a follow-up."""
        self._check_open()
        if len(self._rbuf) > 0:
            self._shut()
            raise Error(
                "SmtpSecurity: TLS: bytes were received before the handshake;"
                " the connection was closed"
            )
        if server_name.byte_length() == 0:
            raise Error(
                "SmtpSecurity: TLS: no server name to check the certificate against"
            )
        var fd = self._stream.value().fd()
        if fd < Int32(0):
            raise Error(
                "SmtpSecurity: TLS: this stream has no descriptor to run TLS on"
            )
        var conn = self._open_conn(trust_pem, server_name, fd)
        var deadline = self._clock.now_us() + self._command_us
        while True:
            var outcome = conn.handshake()
            if outcome == TLS_OUTCOME_DONE:
                break
            if outcome == TLS_OUTCOME_ERROR:
                var errno = last_s2n_errno()
                self._shut()
                raise Error(
                    "SmtpSecurity: TLS: the handshake or the certificate check"
                    " failed (s2n_errno="
                    + String(Int(errno))
                    + ", "
                    + s2n_strerror_message(errno)
                    + ")"
                )
            self._check_deadline(String("TLS handshake"), deadline)
            if self._hook.value().on_wait():
                continue
            var left = deadline - self._clock.now_us()
            var slice = left
            if slice > _PARK_SLICE_US:
                slice = _PARK_SLICE_US
            if slice > 0:
                _ = park_on_pending[Self.S, SmtpRuntime](
                    self._stream.value(),
                    self._rt.value().reactor(),
                    Int64(0),
                    outcome == TLS_OUTCOME_BLOCKED_ON_WRITE,
                    Int32(slice),
                )
        var tls = TlsClientStream[Self.S](self._stream.take(), conn^)
        self._closed = True
        return SmtpSession[TlsClientStream[Self.S], Self.H](
            tls^,
            self._hook.take(),
            self._rt.take(),
            self._clock,
            self._ehlo_name,
            self._command_us,
            self._data_us,
            self._max_line,
            True,
        )

    def authenticate(
        mut self, creds: SmtpCredentials, allow_clear: Bool
    ) raises -> SmtpReply:
        """AUTH with PLAIN (RFC 4616), or LOGIN when PLAIN is not offered
        (RFC 4954). Refused with `SmtpSecurity` on a connection that is not TLS
        unless `allow_clear`; with `SmtpAuth` when the server offers neither
        mechanism. The reply is returned (235 on success); its text has the
        password, and its base64 forms, replaced by `***`."""
        self._check_open()
        if not self._ehlo_done:
            raise Error("SmtpProtocol: AUTH before a successful EHLO")
        if not self._secure and not allow_clear:
            raise Error(
                "SmtpSecurity: AUTH: refusing to send credentials on a"
                " connection that is not TLS"
            )
        var ub = creds.username.as_bytes()
        var pb = creds.password.as_bytes()
        if len(ub) == 0 or len(pb) == 0:
            raise Error("SmtpAuth: the user name and the password must not be empty")
        for i in range(len(ub)):
            if ub[i] == 0:
                raise Error("SmtpAuth: the user name holds a NUL byte")
        for i in range(len(pb)):
            if pb[i] == 0:
                raise Error("SmtpAuth: the password holds a NUL byte")
        var use_plain = self._caps.offers_auth(String("PLAIN"))
        if not use_plain and not self._caps.offers_auth(String("LOGIN")):
            raise Error(
                "SmtpAuth: the server offers no AUTH mechanism this client"
                " supports (PLAIN, LOGIN)"
            )
        var needles = List[String]()
        needles.append(creds.password)
        needles.append(base64_encode(pb))
        var reply: SmtpReply
        if use_plain:
            var raw = List[UInt8](capacity=len(ub) + len(pb) + 2)
            raw.append(UInt8(0))
            raw.extend(ub)
            raw.append(UInt8(0))
            raw.extend(pb)
            var payload = base64_encode(Span(raw))
            needles.append(payload)
            reply = self._exchange(String("AUTH PLAIN ") + payload, String("AUTH"))
            if reply.code == 334:
                reply = self._exchange(payload, String("AUTH"))
        else:
            reply = self._exchange(String("AUTH LOGIN"), String("AUTH"))
            if reply.code == 334:
                reply = self._exchange(base64_encode(ub), String("AUTH"))
                if reply.code == 334:
                    reply = self._exchange(base64_encode(pb), String("AUTH"))
        if reply.code == 334:
            # A further challenge: this client has nothing more to answer.
            _ = self._exchange(String("*"), String("AUTH"))
            raise self._protocol(
                String("AUTH"), String("the server asked for more than the user name and the password")
            )
        return _scrub(reply^, needles)

    # ----- the message ----------------------------------------------------

    def _check_caps(self, env: Envelope) raises:
        if self._caps.size_limit > 0 and env.size > self._caps.size_limit:
            raise Error(
                "SmtpEnvelope: the message is "
                + String(env.size)
                + " bytes, over the server's advertised SIZE limit of "
                + String(self._caps.size_limit)
            )
        if env.eight_bit:
            var allowed = self._caps.eight_bit_mime or (
                env.needs_smtputf8 and self._caps.smtputf8
            )
            if not allowed:
                raise Error(
                    "SmtpEnvelope: the message has 8-bit bytes and the server does"
                    " not offer 8BITMIME; encode it 7-bit (quoted-printable or"
                    " base64) first"
                )
        if env.needs_smtputf8 and not self._caps.smtputf8:
            raise Error(
                "SmtpEnvelope: an address needs SMTPUTF8 and the server does not offer it"
            )

    def _failed(
        self, stage: String, reply: SmtpReply, var recipients: List[RecipientResult]
    ) -> SendResult:
        # Only a 4xx can be retried; a reply that is neither 4xx nor 5xx (a
        # 2xx where a refusal belongs) is not a success of this stage.
        var outcome = SEND_PERMANENT
        if reply.is_transient():
            outcome = SEND_TRANSIENT
        return SendResult(
            outcome,
            stage,
            reply.code,
            reply.text(),
            reply.enhanced.copy(),
            recipients^,
        )

    def _rset(mut self) raises:
        if self._closed:
            return
        _ = self._exchange(String("RSET"), String("RSET"))
        self._dirty = False

    def send(
        mut self,
        mail_from: String,
        recipients: List[String],
        message: Span[UInt8, _],
    ) raises -> SendResult:
        """Send one message: MAIL FROM, one RCPT TO per recipient, DATA. The
        envelope and the message are checked first (`SmtpEnvelope` is raised
        for a bad address, a message over the advertised SIZE, 8-bit bytes
        without 8BITMIME, an address needing SMTPUTF8 the server does not
        offer). A reply that ends the message is returned in the `SendResult`.
        If no recipient is accepted, RSET is sent and DATA is not. An RSET goes
        before a message when a transaction came before it on this
        connection."""
        self._check_open()
        if not self._ehlo_done:
            raise Error("SmtpProtocol: send before a successful EHLO")
        var env = validate_envelope(mail_from, recipients, message)
        self._check_caps(env)
        var none = List[RecipientResult]()
        if self._dirty:
            var rs = self._exchange(String("RSET"), String("RSET"))
            if not rs.is_positive():
                return self._failed(String("rset"), rs, none^)
            self._dirty = False
        var cmd = String("MAIL FROM:<") + env.mail_from + ">"
        if self._caps.size_limit >= 0:
            cmd += " SIZE=" + String(env.size)
        if env.eight_bit and self._caps.eight_bit_mime:
            cmd += " BODY=8BITMIME"
        if env.needs_smtputf8:
            cmd += " SMTPUTF8"
        var mr = self._exchange(cmd, String("MAIL FROM"))
        if not mr.is_positive():
            return self._failed(String("mail"), mr, none^)
        self._dirty = True
        var results = List[RecipientResult]()
        var accepted = 0
        for i in range(len(env.recipients)):
            var rr = self._exchange(
                String("RCPT TO:<") + env.recipients[i] + ">", String("RCPT TO")
            )
            var ok = rr.is_positive()
            if ok:
                accepted += 1
            results.append(
                RecipientResult(
                    env.recipients[i], ok, rr.code, rr.text(), rr.enhanced.copy()
                )
            )
            if self._closed:
                # A 421 closed the connection (RFC 5321 section 3.8): the
                # rest cannot be tried here, and a retry can succeed.
                return SendResult(
                    outcome_of_code(rr.code),
                    String("rcpt"),
                    rr.code,
                    rr.text(),
                    rr.enhanced.copy(),
                    results^,
                )
        if accepted == 0:
            self._rset()
            # The reply that decides: the first 4xx (a retry may help), else
            # the first refusal.
            var pick = 0
            for i in range(len(results)):
                if results[i].code >= 400 and results[i].code < 500:
                    pick = i
                    break
            return SendResult(
                outcome_of_code(results[pick].code),
                String("rcpt"),
                results[pick].code,
                results[pick].text,
                results[pick].enhanced,
                results^,
            )
        var dr = self._exchange(String("DATA"), String("DATA"))
        if dr.code != 354:
            if dr.is_positive():
                raise self._protocol(
                    String("DATA"),
                    String("the server answered DATA with ")
                    + String(dr.code)
                    + ", not 354; the message was not sent",
                )
            if not self._closed:
                self._rset()
            return self._failed(String("data"), dr, results^)
        var normalized = normalize_line_endings(message)
        var wire = dot_stuff_and_terminate(Span(normalized))
        var deadline = self._clock.now_us() + self._data_us
        self._write_all(Span(wire), String("DATA body"), deadline)
        var fr = self._read_final(deadline)
        self._dirty = True
        if fr.is_positive():
            return SendResult(
                outcome_of_code(fr.code),
                String("accepted"),
                fr.code,
                fr.text(),
                fr.enhanced.copy(),
                results^,
            )
        return self._failed(String("end-of-data"), fr, results^)

    def _read_final(mut self, deadline_us: Int) raises -> SmtpReply:
        """The reply that ends DATA. A failure here (a timeout, a closed
        connection) leaves it unknown whether the server kept the message
        (RFC 5321 section 6.1), and the error says so."""
        try:
            return self._read_reply(String("end-of-data"), deadline_us)
        except e:
            raise Error(
                String(e)
                + " (the server may have accepted the message; a retry may"
                " deliver it twice)"
            )

    def quit(mut self) raises -> SmtpReply:
        """QUIT, read the 221 and close. The connection is closed even when the
        reply does not come."""
        if self._closed:
            raise Error("SmtpProtocol: the session is closed")
        try:
            var r = self._exchange(String("QUIT"), String("QUIT"))
            self._shut()
            return r^
        except e:
            self._shut()
            raise Error(String(e))
