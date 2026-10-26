# STARTTLS and AUTH over real loopback sockets: a Peer from
# komira_mail_test_support talks to serve_one_iteration, which the test calls
# between reads. No test here measures time; each waits for the next piece of
# progress (a reply, a finished handshake, the end of the connection).
# What each case catches:
# - the whole submission path: EHLO offers STARTTLS and no AUTH, the TLS
#   handshake completes through the loop, the second EHLO offers AUTH, AUTH
#   PLAIN is verified by the verifier, MAIL, RCPT and DATA end in a 250, and
#   the stored bytes are the trace headers (ESMTPSA, the user quoted) followed
#   by the body exactly (a handshake that never finishes, an AUTH that is not
#   offered after TLS, a message stored without its headers or cut short fails);
# - "STARTTLS\r\nMAIL FROM:<..>\r\n" in one write: the 220 is written, the
#   connection is closed, and the MAIL never runs (no 250 reaches the client,
#   the connection is gone) (a loop that upgrades anyway, or runs the pipelined
#   line before or after the upgrade, fails);
# - AUTH on a clear connection is 538 and the user stays unverified (a loop
#   that lets credentials cross in the clear fails).

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.socket_setup import inet_loopback_be
from komira_encoding import base64_encode
from komira_http_core.tls import TlsConfig
from komira_mail_auth import TestAuthVerifier
from komira_mail_store import fetch_message, list_folder
from komira_mail_test_support import Peer, read_fixture, yield_cpu
from komira_mail_tls import MailTlsTable
from komira_objectstore import SharedInMemoryConditionalStore

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

    def __init__(out self, var tls: MailTlsTable, var config: SmtpServerConfig) raises:
        self.listener = bind_smtp_listener(inet_loopback_be(), UInt16(0))
        self.reg = SmtpRegistry()
        self.tls = tls^
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


def _tls_rig() raises -> _Rig:
    var table = MailTlsTable.from_cert_pem(
        read_fixture(String("leaf_cert.pem")), read_fixture(String("leaf_key.pem"))
    )
    return _Rig(table^, SmtpServerConfig(String("mx.example.com")))


def _final_reply_end(text: String) -> Int:
    """The index just past the first complete final reply line (`NNN text`,
    not `NNN-text`) in `text`, or -1."""
    var bytes = text.as_bytes()
    var start = 0
    var i = 0
    while i + 1 < len(bytes):
        if bytes[i] == 0x0D and bytes[i + 1] == 0x0A:
            if i - start >= 4 and bytes[start + 3] == 0x20:
                return i + 2
            start = i + 2
            i += 2
        else:
            i += 1
    return -1


def _reply(mut rig: _Rig, mut peer: Peer) raises -> String:
    """Run the server until a whole reply has reached the client; return it."""
    while True:
        var end = _final_reply_end(peer.text())
        if end >= 0:
            var all = peer.text()
            var head = String(unsafe_from_utf8=all.as_bytes()[0:end])
            _ = peer.take_through(head)
            return head^
        if peer.eof:
            raise Error("the connection closed before a reply: " + peer.text())
        rig.step()
        _ = peer.poll()
        yield_cpu()


def _command(mut rig: _Rig, mut peer: Peer, line: String) raises -> String:
    peer.send(line + "\r\n")
    return _reply(rig, peer)


def _upgrade(mut rig: _Rig, mut peer: Peer) raises:
    """STARTTLS and the handshake, driven from both ends."""
    var r = _command(rig, peer, String("STARTTLS"))
    assert_true(r.startswith("220 "), r)
    peer.start_tls(read_fixture(String("root_ca.pem")))
    var client_done = False
    while True:
        rig.step()
        if not client_done:
            client_done = peer.tls_step()
        var ids = rig.reg.all_conn_ids()
        if client_done and len(ids) == 1 and rig.reg.tls_active_of(ids[0]):
            break
        yield_cpu()


def _plain_payload() -> String:
    var raw = String("") + chr(0) + "alice" + chr(0) + "s3cret"
    return base64_encode(raw.as_bytes())


def test_starttls_auth_and_a_message() raises:
    var rig = _tls_rig()
    var peer = Peer.connect(rig.listener.local_port())
    var greeting = _reply(rig, peer)
    assert_true(greeting.startswith("220 mx.example.com"), greeting)

    var clear = _command(rig, peer, String("EHLO client.test"))
    assert_true(clear.find("STARTTLS") >= 0, clear)
    assert_false(clear.find("AUTH") >= 0, clear)

    _upgrade(rig, peer)

    var secure = _command(rig, peer, String("EHLO client.test"))
    assert_true(secure.find("AUTH PLAIN") >= 0, secure)
    assert_false(secure.find("STARTTLS") >= 0, secure)

    var auth = _command(rig, peer, String("AUTH PLAIN ") + _plain_payload())
    assert_true(auth.startswith("235"), auth)
    assert_true(_command(rig, peer, String("MAIL FROM:<a@sender.test>")).startswith("250"))
    assert_true(_command(rig, peer, String("RCPT TO:<bob@example.com>")).startswith("250"))
    assert_true(_command(rig, peer, String("DATA")).startswith("354"))
    var done = _command(rig, peer, String("Subject: t\r\n\r\nline one\r\n."))
    assert_true(done.startswith("250"), done)
    assert_true(done.find("queued as q") >= 0, done)

    var entries = list_folder(rig.view, String("bob@example.com"), String("INBOX"))
    assert_equal(len(entries), 1)
    var got = fetch_message(
        rig.view, String("bob@example.com"), String("INBOX"), entries[0].leaf
    )
    var text = String(unsafe_from_utf8=Span(got.bytes))
    var head = String(
        "Return-Path: <a@sender.test>\r\n"
        "Received: from client.test (127.0.0.1)\r\n"
        '\tby mx.example.com with ESMTPSA (authenticated as "alice") id q'
    )
    assert_true(text.startswith(head), text)
    assert_true(text.endswith("Authentication-Results: mx.example.com; none\r\nSubject: t\r\n\r\nline one\r\n"), text)

    assert_true(_command(rig, peer, String("QUIT")).startswith("221"))
    while not peer.eof:
        rig.step()
        _ = peer.poll()
        yield_cpu()
    assert_equal(rig.reg.conn_count(), 0)
    peer.close()


def test_pipelined_command_after_starttls_closes_the_connection() raises:
    var rig = _tls_rig()
    var peer = Peer.connect(rig.listener.local_port())
    _ = _reply(rig, peer)
    _ = _command(rig, peer, String("EHLO client.test"))
    peer.send(String("STARTTLS\r\nMAIL FROM:<a@sender.test>\r\n"))
    var first = _reply(rig, peer)
    assert_true(first.startswith("220 "), first)
    # The step that wrote the 220 decided: the connection is already gone and
    # no TLS state was made for it.
    assert_equal(rig.reg.conn_count(), 0)
    assert_equal(rig.tls.tls_conn_count(), 0)
    # The client sees the end of the connection.
    while not peer.eof:
        rig.step()
        _ = peer.poll()
        yield_cpu()
    # Nothing but the 220 was ever written: the MAIL did not run.
    assert_equal(peer.text(), "")
    assert_equal(rig.reg.conn_count(), 0)
    assert_equal(len(list_folder(rig.view, String("bob@example.com"), String("INBOX"))), 0)
    peer.close()


def test_auth_on_a_clear_connection_is_538() raises:
    var rig = _tls_rig()
    var peer = Peer.connect(rig.listener.local_port())
    _ = _reply(rig, peer)
    _ = _command(rig, peer, String("EHLO client.test"))
    var r = _command(rig, peer, String("AUTH PLAIN ") + _plain_payload())
    assert_true(r.startswith("538"), r)
    var ids = rig.reg.all_conn_ids()
    assert_equal(len(ids), 1)
    assert_equal(rig.reg.authed_user_of(ids[0]), "")
    # MAIL still works on the clear connection (port-25 behaviour) and the
    # session carries no user.
    assert_true(_command(rig, peer, String("MAIL FROM:<a@sender.test>")).startswith("250"))
    peer.close()


def main() raises:
    test_starttls_auth_and_a_message()
    test_pipelined_command_after_starttls_closes_the_connection()
    test_auth_on_a_clear_connection_is_538()
    print("test_smtp_starttls: OK")
