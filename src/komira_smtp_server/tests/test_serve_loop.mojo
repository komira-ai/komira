# The serve loop over real loopback sockets, one case per rule of the loop.
# Time is the `now_ms` the test passes; nothing here sleeps or measures a
# duration, and each wait is for the next piece of progress (a reply, the end
# of a connection). What each case catches:
# - max_conns: the connection over the limit is answered 421 4.3.2 and closed
#   while the others keep their greeting, and a freed slot is usable again
#   (a loop that accepts without limit, drops a connection that fit, or never
#   frees the slot fails);
# - expiry by now_ms: a connection idle past idle_ms is answered 421 4.4.2 and
#   closed, one that is not idle is left alone, and a connection that keeps
#   sending is still closed once it is older than max_session_ms (a loop that
#   ignores expired_ids, closes without the 421, or measures idleness from the
#   accept fails);
# - the expiry boundaries are exact: idle at connect+idle_ms is alive and one
#   millisecond later expired, and the same for max_session_ms (a `>=` for `>`,
#   or a deadline measured from the wrong instant, fails);
# - a connection with a full send window is dropped one step after its deadline
#   although the 421 could not be written; what it did receive is the replies in
#   order (a loop that waits for the peer to read, or reorders, fails);
# - a peer reset (also in the middle of DATA) removes only its own connection;
#   a peer that sends a malformed TLS hello after STARTTLS loses only its own
#   connection; a peer that goes away in the middle of the handshake loses its
#   TLS state and its connection; the other connection keeps working (a loop
#   that returns, stops or drops everything on one error, or leaks TLS state
#   fails);
# - without a certificate STARTTLS is neither offered nor accepted and the
#   session goes on (a loop that offers an upgrade it cannot do fails);
# - replies written to a peer that does not read, through small socket buffers
#   (so writes are short and the socket fills many times), arrive complete and
#   in order (a loop that drops or repeats the unwritten part of a short write
#   fails).

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.socket_setup import (
    inet_loopback_be,
    set_so_rcvbuf,
    set_so_sndbuf,
)
from komira_http_core.tls import TlsConfig
from komira_mail_auth import TestAuthVerifier
from komira_mail_test_support import Peer, read_fixture, yield_cpu
from komira_mail_tls import MailTlsTable
from komira_objectstore import SharedInMemoryConditionalStore

from komira_smtp_server import (
    ListenSocket,
    LocalDomains,
    LocalMailboxDelivery,
    NoopMailReceiveHook,
    SmtpLimits,
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
    var now_ms: Int
    var refused: Int
    var expired: Int
    var dropped: Int

    def __init__(out self, var tls: MailTlsTable, var config: SmtpServerConfig) raises:
        self.listener = bind_smtp_listener(inet_loopback_be(), UInt16(0))
        self.reg = SmtpRegistry()
        self.tls = tls^
        self.verifier = TestAuthVerifier()
        var domains = LocalDomains()
        domains.add(String("example.com"))
        self.delivery = LocalMailboxDelivery[SharedInMemoryConditionalStore, NoopMailReceiveHook](
            SharedInMemoryConditionalStore(),
            NoopMailReceiveHook(),
            config.hostname,
            domains^,
        )
        self.config = config^
        self.now_ms = 1000
        self.refused = 0
        self.expired = 0
        self.dropped = 0

    def step(mut self):
        var o = serve_one_iteration(
            self.reg,
            self.listener,
            self.tls,
            self.verifier,
            self.delivery,
            self.config,
            self.now_ms,
        )
        self.refused += o.refused
        self.expired += o.expired
        self.dropped += o.dropped

    def pump(mut self, mut peer: Peer):
        self.step()
        _ = peer.poll()
        yield_cpu()


def _plain_rig(var config: SmtpServerConfig) raises -> _Rig:
    # No certificate: the table is empty and STARTTLS is not offered.
    config.offer_starttls = False
    return _Rig(MailTlsTable(TlsConfig()), config^)


def _wait_for(mut rig: _Rig, mut peer: Peer, marker: String) raises:
    while not peer.has(marker):
        if peer.eof:
            raise Error("closed before " + marker + ": " + peer.text())
        rig.pump(peer)


def _wait_line(mut rig: _Rig, mut peer: Peer) raises:
    """Run the server until the peer holds one whole line."""
    while not peer.has(String("\r\n")):
        if peer.eof:
            raise Error("closed before a line: " + peer.text())
        rig.pump(peer)


def _wait_eof(mut rig: _Rig, mut peer: Peer):
    while not peer.eof:
        rig.pump(peer)


def _noop(mut rig: _Rig, mut peer: Peer) raises:
    """One NOOP round trip: proof the connection is alive and served."""
    peer.send(String("NOOP\r\n"))
    _wait_for(rig, peer, String("250 2.0.0"))
    _ = peer.take_through(String("250 2.0.0"))


def test_max_conns_refuses_the_extra_connection() raises:
    var limits = SmtpLimits()
    limits.max_conns = 2
    var cfg = SmtpServerConfig(String("mx.test"))
    cfg.limits = limits^
    var rig = _plain_rig(cfg^)
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    var c = Peer.connect(rig.listener.local_port())
    _wait_for(rig, a, String("220 mx.test"))
    _wait_for(rig, b, String("220 mx.test"))
    # The first step accepted all three: the third was refused in it.
    assert_equal(rig.refused, 1)
    _wait_line(rig, c)
    assert_true(c.text().startswith("421 4.3.2"), c.text())
    _wait_eof(rig, c)
    assert_false(c.has("220"))
    assert_equal(rig.refused, 1)
    assert_equal(rig.reg.conn_count(), 2)
    # The two that fit are still served.
    _noop(rig, a)
    _noop(rig, b)
    # A slot frees when one leaves, and the next connection gets it.
    a.send(String("QUIT\r\n"))
    _wait_eof(rig, a)
    var d = Peer.connect(rig.listener.local_port())
    _wait_for(rig, d, String("220 mx.test"))
    assert_equal(rig.refused, 1)
    assert_equal(rig.reg.conn_count(), 2)
    a.close()
    b.close()
    c.close()
    d.close()


def test_expiry_is_decided_by_now_ms() raises:
    var limits = SmtpLimits()
    limits.idle_ms = 1000
    limits.max_session_ms = 5000
    var cfg = SmtpServerConfig(String("mx.test"))
    cfg.limits = limits^
    var rig = _plain_rig(cfg^)
    var idle = Peer.connect(rig.listener.local_port())
    var busy = Peer.connect(rig.listener.local_port())
    _wait_for(rig, idle, String("220 mx.test"))
    _wait_for(rig, busy, String("220 mx.test"))

    # At 1900 nobody is past idle_ms (1000 after the connect); `busy` speaks.
    rig.now_ms = 1900
    _noop(rig, busy)
    _ = idle.poll()
    assert_equal(rig.expired, 0)
    assert_false(idle.has("421"))
    assert_equal(rig.reg.conn_count(), 2)
    # At 2800 `idle` has been quiet for 1800: it is answered 421 4.4.2 and
    # closed. `busy` speaks again and is left alone.
    rig.now_ms = 2800
    _noop(rig, busy)
    # The step that served `busy` also expired `idle`.
    assert_equal(rig.expired, 1)
    _wait_for(rig, idle, String("421 4.4.2"))
    _wait_eof(rig, idle)
    assert_true(idle.text().startswith("220 mx.test ESMTP ready\r\n421 4.4.2"))
    assert_equal(rig.reg.conn_count(), 1)
    # `busy` keeps speaking, so it is never idle.
    rig.now_ms = 3700
    _noop(rig, busy)
    rig.now_ms = 4600
    _noop(rig, busy)
    rig.now_ms = 5500
    _noop(rig, busy)
    assert_equal(rig.expired, 1)

    # Past max_session_ms of age `busy` is closed although it spoke at 5500.
    rig.now_ms = 6001
    rig.step()
    assert_equal(rig.expired, 2)
    _wait_for(rig, busy, String("421 4.4.2"))
    _wait_eof(rig, busy)
    assert_equal(rig.reg.conn_count(), 0)
    idle.close()
    busy.close()


def test_expiry_boundaries_are_exact() raises:
    var limits = SmtpLimits()
    limits.idle_ms = 1000
    limits.max_session_ms = 5000
    var cfg = SmtpServerConfig(String("mx.test"))
    cfg.limits = limits^
    var rig = _plain_rig(cfg^)
    var idle = Peer.connect(rig.listener.local_port())
    var busy = Peer.connect(rig.listener.local_port())
    _wait_for(rig, idle, String("220 mx.test"))
    _wait_for(rig, busy, String("220 mx.test"))
    # Both connected at 1000. Quiet for exactly idle_ms is not idle.
    rig.now_ms = 2000
    rig.step()
    assert_equal(rig.expired, 0)
    assert_equal(rig.reg.conn_count(), 2)
    # `busy` speaks within idle_ms of its last word up to 5500, so only its
    # age can end it.
    rig.now_ms = 2001
    _noop(rig, busy)
    # The step that served `busy` at 2001 also found `idle` one millisecond
    # past idle_ms.
    assert_equal(rig.expired, 1)
    _wait_for(rig, idle, String("421 4.4.2"))
    _wait_eof(rig, idle)
    rig.now_ms = 3000
    _noop(rig, busy)
    rig.now_ms = 4000
    _noop(rig, busy)
    rig.now_ms = 5000
    _noop(rig, busy)
    rig.now_ms = 5900
    _noop(rig, busy)
    # Exactly max_session_ms old (accepted at 1000) is not too old.
    rig.now_ms = 6000
    _noop(rig, busy)
    assert_equal(rig.expired, 1)
    assert_equal(rig.reg.conn_count(), 1)
    # One millisecond more is.
    rig.now_ms = 6001
    rig.step()
    assert_equal(rig.expired, 2)
    _wait_for(rig, busy, String("421 4.4.2"))
    _wait_eof(rig, busy)
    assert_equal(rig.reg.conn_count(), 0)
    idle.close()
    busy.close()


def test_expiry_with_a_full_send_window_drops_on_the_next_step() raises:
    var limits = SmtpLimits()
    limits.idle_ms = 1000
    var cfg = SmtpServerConfig(String("mx.test"))
    cfg.limits = limits^
    var rig = _plain_rig(cfg^)
    var p = Peer.connect(rig.listener.local_port())
    _wait_for(rig, p, String("220 mx.test"))
    _ = p.take_through(String("220 mx.test ESMTP ready\r\n"))
    p.send(String("EHLO c.test\r\nNOOP\r\nVRFY x\r\n"))
    _wait_for(rig, p, String("502 5.5.1 Command not implemented\r\n"))
    var round = p.take_through(String("502 5.5.1 Command not implemented\r\n"))
    var ids = rig.reg.all_conn_ids()
    var cid = ids[0]
    set_so_sndbuf(rig.reg.fd_of(cid), Int32(4096))
    set_so_rcvbuf(p.fd, Int32(4096))
    var rounds = 400
    var batch = String("")
    for _ in range(rounds):
        batch += "EHLO c.test\r\nNOOP\r\nVRFY x\r\n"
    var bytes = batch.as_bytes()
    var sent = 0
    while sent < len(bytes):
        var end = sent + 2000
        if end > len(bytes):
            end = len(bytes)
        p.send_bytes(bytes[sent:end])
        sent = end
        rig.step()
    # The server has read everything and the peer reads nothing: replies wait.
    rig.step()
    rig.step()
    assert_true(rig.reg.tx_len(cid) > 0)
    assert_equal(rig.expired, 0)

    # Past idle_ms the 421 is queued behind the replies and cannot be written.
    rig.now_ms = 2001
    rig.step()
    assert_equal(rig.expired, 1)
    assert_equal(rig.reg.conn_count(), 1)
    assert_true(rig.reg.is_closing(cid))
    # The next step drops it: the deadline wins over the unwritten reply.
    rig.step()
    assert_equal(rig.reg.conn_count(), 0)
    assert_equal(rig.dropped, 1)
    _wait_eof(rig, p)
    var expected = String("")
    for _ in range(rounds):
        expected += round
    assert_false(p.has("421 4.4.2"))
    assert_true(len(p.inbox) > 0)
    assert_true(len(p.inbox) < expected.byte_length())
    assert_true(expected.startswith(p.text()))
    p.close()


def test_a_peer_reset_drops_only_its_own_connection() raises:
    var rig = _plain_rig(SmtpServerConfig(String("mx.test")))
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    _wait_for(rig, a, String("220 mx.test"))
    _wait_for(rig, b, String("220 mx.test"))
    # `a` is in the middle of DATA when it vanishes.
    a.send(String("EHLO a.test\r\n"))
    _wait_for(rig, a, String("250 "))
    a.send(String("MAIL FROM:<x@y.test>\r\nRCPT TO:<bob@example.com>\r\nDATA\r\nSubject: half"))
    _wait_for(rig, a, String("354"))
    a.reset()
    while rig.reg.conn_count() > 1:
        rig.step()
        _ = b.poll()
        yield_cpu()
    assert_equal(rig.dropped, 1)
    assert_equal(rig.reg.conn_count(), 1)
    # `b` was not touched.
    _noop(rig, b)
    b.send(String("QUIT\r\n"))
    _wait_eof(rig, b)
    assert_equal(rig.reg.conn_count(), 0)
    b.close()


def test_a_bad_tls_hello_drops_only_its_own_connection() raises:
    var table = MailTlsTable.from_cert_pem(
        read_fixture(String("leaf_cert.pem")), read_fixture(String("leaf_key.pem"))
    )
    var rig = _Rig(table^, SmtpServerConfig(String("mx.test")))
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    _wait_for(rig, a, String("220 mx.test"))
    _wait_for(rig, b, String("220 mx.test"))
    a.send(String("EHLO a.test\r\n"))
    _wait_for(rig, a, String("250 "))
    a.send(String("STARTTLS\r\n"))
    _wait_for(rig, a, String("220 2.0.0 Ready to start TLS"))
    # A handshake record whose message type is not a ClientHello.
    var bad = List[UInt8]()
    for v in [22, 3, 1, 0, 32]:
        bad.append(UInt8(v))
    for _ in range(32):
        bad.append(UInt8(0xAA))
    a.send_bytes(Span(bad))
    _wait_eof(rig, a)
    assert_equal(rig.reg.conn_count(), 1)
    assert_equal(rig.dropped, 1)
    _noop(rig, b)
    b.close()
    a.close()


def test_a_peer_that_leaves_mid_handshake_loses_its_tls_state() raises:
    var table = MailTlsTable.from_cert_pem(
        read_fixture(String("leaf_cert.pem")), read_fixture(String("leaf_key.pem"))
    )
    var rig = _Rig(table^, SmtpServerConfig(String("mx.test")))
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    _wait_for(rig, a, String("220 mx.test"))
    _wait_for(rig, b, String("220 mx.test"))
    a.send(String("EHLO a.test\r\n"))
    _wait_for(rig, a, String("250 "))
    a.send(String("STARTTLS\r\n"))
    _wait_for(rig, a, String("220 2.0.0 Ready to start TLS"))
    # The ClientHello goes out; the handshake is not finished.
    a.start_tls(read_fixture(String("root_ca.pem")))
    _ = a.tls_step()
    rig.step()
    assert_equal(rig.reg.conn_count(), 2)
    assert_equal(rig.tls.tls_conn_count(), 1)
    var ids = rig.reg.all_conn_ids()
    for i in range(len(ids)):
        assert_false(rig.reg.tls_active_of(ids[i]))
    # The client vanishes before the handshake ends.
    a.close()
    while rig.reg.conn_count() > 1:
        rig.step()
        _ = b.poll()
        yield_cpu()
    assert_equal(rig.dropped, 1)
    assert_equal(rig.tls.tls_conn_count(), 0)
    _noop(rig, b)
    b.close()


def test_without_a_certificate_starttls_is_not_offered() raises:
    var rig = _plain_rig(SmtpServerConfig(String("mx.test")))
    var p = Peer.connect(rig.listener.local_port())
    _wait_for(rig, p, String("220 mx.test"))
    p.send(String("EHLO c.test\r\n"))
    _wait_for(rig, p, String("\r\n250 "))
    assert_false(p.has("STARTTLS"))
    _ = p.take_through(String("\r\n250 "))
    _ = p.take_through(String("\r\n"))
    p.send(String("STARTTLS\r\n"))
    _wait_for(rig, p, String("502"))
    # The connection goes on in the clear.
    _ = p.take_through(String("502"))
    _ = p.take_through(String("\r\n"))
    _noop(rig, p)
    assert_equal(rig.reg.conn_count(), 1)
    p.close()


def test_a_short_write_is_resumed_in_order() raises:
    # Small socket buffers on both ends and a peer that does not read while
    # the server answers thousands of commands: writes are short and the
    # socket is full many times. The bytes the peer finally reads must be
    # exactly the replies, in order.
    var rig = _plain_rig(SmtpServerConfig(String("mx.test")))
    var p = Peer.connect(rig.listener.local_port())
    _wait_for(rig, p, String("220 mx.test"))
    _ = p.take_through(String("220 mx.test ESMTP ready\r\n"))
    # One round alone, to learn the three replies.
    p.send(String("EHLO c.test\r\nNOOP\r\nVRFY x\r\n"))
    _wait_for(rig, p, String("502 5.5.1 Command not implemented\r\n"))
    var round = p.take_through(String("502 5.5.1 Command not implemented\r\n"))
    var ids = rig.reg.all_conn_ids()
    set_so_sndbuf(rig.reg.fd_of(ids[0]), Int32(4096))
    set_so_rcvbuf(p.fd, Int32(4096))
    var rounds = 3000
    var batch = String("")
    for _ in range(rounds):
        batch += "EHLO c.test\r\nNOOP\r\nVRFY x\r\n"
    var bytes = batch.as_bytes()
    var sent = 0
    while sent < len(bytes):
        var end = sent + 2000
        if end > len(bytes):
            end = len(bytes)
        p.send_bytes(bytes[sent:end])
        sent = end
        rig.step()
    var expected = String("")
    for _ in range(rounds):
        expected += round
    while len(p.inbox) < expected.byte_length():
        rig.step()
        _ = p.poll()
        yield_cpu()
    assert_equal(len(p.inbox), expected.byte_length())
    assert_true(p.text() == expected)
    p.close()


def main() raises:
    test_max_conns_refuses_the_extra_connection()
    test_expiry_is_decided_by_now_ms()
    test_expiry_boundaries_are_exact()
    test_expiry_with_a_full_send_window_drops_on_the_next_step()
    test_a_peer_reset_drops_only_its_own_connection()
    test_a_peer_that_leaves_mid_handshake_loses_its_tls_state()
    test_a_bad_tls_hello_drops_only_its_own_connection()
    test_without_a_certificate_starttls_is_not_offered()
    test_a_short_write_is_resumed_in_order()
    print("test_serve_loop: OK")
