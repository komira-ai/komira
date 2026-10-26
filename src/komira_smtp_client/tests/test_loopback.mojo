# The client against the real komira_smtp_server over 127.0.0.1, with the real
# s2n handshake. One thread runs both ends: the client calls a WaitHook each
# time it would wait, and the hook runs one step of the server. Nothing here
# measures time or gives up: the client's clock is a counter that never moves,
# and each call returns when the exchange has made the progress it waits for.
# The server has no implicit-TLS listener, so the implicit-TLS path is covered
# on ScriptedStream only (test_policy.mojo).
#
# What each case catches:
# - test_starttls_auth_and_message: a MessageBuilder message sent over STARTTLS
#   with AUTH PLAIN to a submission listener is accepted with a queue id, and
#   the stored message is the trace headers (ESMTPSA, the user quoted) followed
#   by the built bytes exactly, a body line starting with `.` included (a
#   client that skips STARTTLS, AUTH, dot-stuffing or CRLF normalisation fails).
# - test_wrong_password: the server's 535 comes back as a permanent `auth`
#   result, without the password, and nothing is stored.
# - test_untrusted_certificate / test_wrong_certificate_name: a certificate that
#   does not chain to the trusted roots, and one that does not name the server,
#   each raise SmtpSecurity and nothing is delivered (a client that continues in
#   the clear, or skips verification, fails).
# - test_starttls_not_offered_by_server: a server without STARTTLS makes the
#   send raise SmtpSecurity and nothing is delivered or authenticated.
# - test_connection_refused: a closed port raises a retryable SmtpTransport.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.socket_setup import inet_loopback_be
from komira_mail_address import AddrSpec
from komira_mail_auth import TestAuthVerifier
from komira_mail_message import MessageBuilder
from komira_mail_store import fetch_message, list_folder
from komira_mail_test_support import read_fixture, yield_cpu
from komira_mail_tls import MailTlsTable
from komira_objectstore import SharedInMemoryConditionalStore
from komira_smtp_client import (
    SmtpClientConfig,
    SmtpClock,
    SmtpCredentials,
    SmtpSecurity,
    WaitHook,
    error_is_retryable,
    send_built_message_with_hook,
    send_message,
)
from komira_smtp_server import (
    ListenSocket,
    LocalDomains,
    LocalMailboxDelivery,
    NoopMailReceiveHook,
    SmtpRegistry,
    SmtpServerConfig,
    bind_smtp_listener,
    serve_one_iteration,
)


struct _Rig(Movable):
    var listener: ListenSocket
    var reg: SmtpRegistry
    var tls: MailTlsTable
    var verifier: TestAuthVerifier
    var delivery: LocalMailboxDelivery[SharedInMemoryConditionalStore, NoopMailReceiveHook]
    var config: SmtpServerConfig
    var view: SharedInMemoryConditionalStore
    var now_ms: Int

    def __init__(out self, var config: SmtpServerConfig) raises:
        self.listener = bind_smtp_listener(inet_loopback_be(), UInt16(0))
        self.reg = SmtpRegistry()
        self.tls = MailTlsTable.from_cert_pem(
            read_fixture(String("leaf_cert.pem")),
            read_fixture(String("leaf_key.pem")),
        )
        self.verifier = TestAuthVerifier()
        self.verifier.add_user(String("alice"), String("s3cret"))
        var store = SharedInMemoryConditionalStore()
        self.view = store.clone()
        var domains = LocalDomains()
        domains.add(String("example.com"))
        self.delivery = LocalMailboxDelivery[SharedInMemoryConditionalStore, NoopMailReceiveHook](
            store^, NoopMailReceiveHook(), config.hostname, domains^
        )
        self.config = config^
        self.now_ms = 1_790_000_000_000

    def step(mut self):
        _ = serve_one_iteration(
            self.reg,
            self.listener,
            self.tls,
            self.verifier,
            self.delivery,
            self.config,
            self.now_ms,
        )


struct _StepServer(WaitHook, Movable, Deinitable):
    """Runs one server step each time the client would wait."""

    var rig: ArcPointer[_Rig]

    def __init__(out self, rig: ArcPointer[_Rig]):
        self.rig = rig

    def on_wait(mut self) raises -> Bool:
        self.rig[].step()
        yield_cpu()
        return True


def _submission_rig() raises -> ArcPointer[_Rig]:
    return ArcPointer[_Rig](
        _Rig(SmtpServerConfig(String("mx.example.com"), True, True))
    )


def _config(rig: ArcPointer[_Rig]) raises -> SmtpClientConfig:
    var cfg = SmtpClientConfig(
        String("127.0.0.1"),
        rig[].listener.local_port(),
        SmtpSecurity.starttls(),
        String("client.test"),
    )
    cfg.tls_server_name = String("localhost")
    cfg.tls_trust_pem = read_fixture(String("root_ca.pem"))
    cfg.clock = SmtpClock.manual(ArcPointer[Int](0))
    return cfg^


def _creds(password: String) -> Optional[SmtpCredentials]:
    return Optional[SmtpCredentials](
        SmtpCredentials(String("alice"), password)
    )


def _rcpts() -> List[String]:
    var l = List[String]()
    l.append(String("bob@example.com"))
    return l^


def _builder() raises -> MessageBuilder:
    var b = MessageBuilder()
    b.set_from("", AddrSpec("sender", "sender.test"))
    b.add_to("", AddrSpec("bob", "example.com"))
    b.set_subject("loopback")
    b.set_date(1790000000)
    b.set_message_id("m1", "sender.test")
    b.set_text("line one\n.leading dot\n..two dots\nlast line without a break")
    return b^


def _inbox_count(rig: ArcPointer[_Rig], who: String) raises -> Int:
    return len(list_folder(rig[].view, who, String("INBOX")))


def test_starttls_auth_and_message() raises:
    var rig = _submission_rig()
    var builder = _builder()
    var built = builder.build()
    var res = send_built_message_with_hook(
        _StepServer(rig),
        _config(rig),
        _creds(String("s3cret")),
        String("sender@sender.test"),
        _rcpts(),
        builder,
    )
    assert_true(res.is_accepted(), res.stage + " " + String(res.code) + " " + res.text)
    assert_equal(res.code, 250)
    var marker = String("queued as ")
    assert_true(res.text.find(marker) >= 0, res.text)
    assert_equal(len(res.recipients), 1)
    assert_true(res.recipients[0].accepted)
    assert_equal(_inbox_count(rig, String("bob@example.com")), 1)
    var entries = list_folder(
        rig[].view, String("bob@example.com"), String("INBOX")
    )
    var got = fetch_message(
        rig[].view, String("bob@example.com"), String("INBOX"), entries[0].leaf
    )
    var stored = String(unsafe_from_utf8=Span(got.bytes))
    var built_text = String(unsafe_from_utf8=Span(built))
    var head = (
        String("Return-Path: <sender@sender.test>\r\n")
        + "Received: from client.test (127.0.0.1)\r\n"
        + '\tby mx.example.com with ESMTPSA (authenticated as "alice") id '
    )
    assert_true(stored.startswith(head), stored)
    assert_true(stored.endswith(built_text), stored)
    assert_true(stored.byte_length() > built_text.byte_length())


def test_wrong_password() raises:
    var rig = _submission_rig()
    var res = send_built_message_with_hook(
        _StepServer(rig),
        _config(rig),
        _creds(String("not-the-password")),
        String("sender@sender.test"),
        _rcpts(),
        _builder(),
    )
    assert_false(res.is_accepted())
    assert_true(res.is_permanent())
    assert_equal(res.stage, "auth")
    assert_equal(res.code, 535)
    assert_false(res.text.find("not-the-password") >= 0, res.text)
    assert_equal(_inbox_count(rig, String("bob@example.com")), 0)
    assert_equal(rig[].delivery.deliveries, 0)


def test_untrusted_certificate() raises:
    var rig = _submission_rig()
    var cfg = _config(rig)
    # The system roots only: the test CA is not among them.
    cfg.tls_trust_pem = String("")
    var msg = String("")
    try:
        _ = send_built_message_with_hook(
            _StepServer(rig),
            cfg,
            _creds(String("s3cret")),
            String("sender@sender.test"),
            _rcpts(),
            _builder(),
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpSecurity"), msg)
    assert_false(error_is_retryable(msg))
    assert_equal(rig[].delivery.deliveries, 0)
    assert_equal(_inbox_count(rig, String("bob@example.com")), 0)


def test_wrong_certificate_name() raises:
    var rig = _submission_rig()
    var cfg = _config(rig)
    cfg.tls_server_name = String("evil.example")
    var msg = String("")
    try:
        _ = send_built_message_with_hook(
            _StepServer(rig),
            cfg,
            _creds(String("s3cret")),
            String("sender@sender.test"),
            _rcpts(),
            _builder(),
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpSecurity"), msg)
    assert_equal(rig[].delivery.deliveries, 0)
    assert_equal(_inbox_count(rig, String("bob@example.com")), 0)


def test_starttls_not_offered_by_server() raises:
    var rig = ArcPointer[_Rig](
        _Rig(
            SmtpServerConfig(
                String("mx.example.com"), False, True, False
            )
        )
    )
    var msg = String("")
    try:
        _ = send_built_message_with_hook(
            _StepServer(rig),
            _config(rig),
            _creds(String("s3cret")),
            String("sender@sender.test"),
            _rcpts(),
            _builder(),
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpSecurity"), msg)
    assert_true(msg.find("STARTTLS") >= 0, msg)
    assert_equal(rig[].delivery.deliveries, 0)
    assert_equal(_inbox_count(rig, String("bob@example.com")), 0)


def test_connection_refused() raises:
    var listener = bind_smtp_listener(inet_loopback_be(), UInt16(0))
    var port = listener.local_port()
    _ = listener^
    var cfg = SmtpClientConfig(
        String("127.0.0.1"), port, SmtpSecurity.plaintext(), String("client.test")
    )
    var msg = String("")
    try:
        _ = send_message(
            cfg,
            None,
            String("sender@sender.test"),
            _rcpts(),
            Span(_builder().build()),
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith("SmtpTransport: connect"), msg)
    assert_true(error_is_retryable(msg))


def main() raises:
    # Every case runs; the failures are reported together.
    var failed = String("")
    try:
        test_starttls_auth_and_message()
    except e:
        failed += "\n  test_starttls_auth_and_message: " + String(e)
    try:
        test_wrong_password()
    except e:
        failed += "\n  test_wrong_password: " + String(e)
    try:
        test_untrusted_certificate()
    except e:
        failed += "\n  test_untrusted_certificate: " + String(e)
    try:
        test_wrong_certificate_name()
    except e:
        failed += "\n  test_wrong_certificate_name: " + String(e)
    try:
        test_starttls_not_offered_by_server()
    except e:
        failed += "\n  test_starttls_not_offered_by_server: " + String(e)
    try:
        test_connection_refused()
    except e:
        failed += "\n  test_connection_refused: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_loopback: FAILED" + failed)
    print("test_loopback: OK")
