# The serve loop over real loopback sockets, with a Peer from
# komira_mail_test_support as the client. Time is the `now_ms` the test passes;
# nothing here sleeps or measures a duration, and each wait is for the next
# piece of progress (a reply, a finished handshake, the end of a connection).
# What each case catches:
# - the whole read path over TLS: the greeting offers STARTTLS and
#   LOGINDISABLED, LOGIN in the clear is `NO [PRIVACYREQUIRED]`, STARTTLS and
#   the handshake complete through the loop, CAPABILITY on TLS offers neither,
#   LOGIN, SELECT and FETCH return the stored messages byte for byte, LOGOUT
#   ends the connection (a loop that never upgrades, lets a password cross in
#   the clear, or alters a message fails);
# - ENVELOPE, BODYSTRUCTURE, a header-field section, a partial, INTERNALDATE
#   and SEARCH answered over the same upgraded connection, with every byte of
#   the reply exact (the structures and literals cross TLS whole);
# - three wrong passwords on TLS end the connection with a `* BYE`;
# - lines pipelined behind STARTTLS in the clear: the OK is written, the
#   connection is closed, no TLS state is made, and nothing else is ever
#   written (a loop that runs them, before or after the upgrade, fails);
# - max_conns: the connection over the limit is told `* BYE` and closed, the
#   others keep their greeting, a freed slot is usable again;
# - expiry by now_ms: a connection idle past idle_ms, or old past
#   max_session_ms, or not logged in past max_unauth_ms is told `* BYE` and
#   closed, and the boundaries are exact (one millisecond more, not before); a
#   connection that keeps sending is not idle, and one that logged in is not
#   subject to the unauthenticated limit;
# - a line over the cap closes only its own connection;
# - a peer reset, a malformed TLS hello and a peer that leaves mid-handshake
#   each remove only their own connection (and its TLS state);
# - without a certificate STARTTLS is `NO [CANNOT]` and the session goes on;
# - a message much larger than the socket buffers, with both buffers made
#   small, arrives whole and in order (a loop that drops or repeats the
#   unwritten part of a short write fails).

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.socket_setup import (
    inet_loopback_be,
    set_so_rcvbuf,
    set_so_sndbuf,
)
from komira_http_core.tls import TlsConfig
from komira_mail_auth import TestAuthVerifier
from komira_mail_store import content_hash_hex, store_message
from komira_mail_test_support import Peer, read_fixture, yield_cpu
from komira_mail_tls import MailTlsTable
from komira_objectstore import SharedInMemoryConditionalStore

from komira_imap_server import (
    ImapLimits,
    ImapRegistry,
    ImapServerConfig,
    ListenSocket,
    assign_uid,
    bind_imap_listener,
    serve_one_iteration,
)


struct _Rig(Movable):
    var listener: ListenSocket
    var reg: ImapRegistry
    var tls: MailTlsTable
    var verifier: TestAuthVerifier
    var store: SharedInMemoryConditionalStore
    var view: SharedInMemoryConditionalStore
    var config: ImapServerConfig
    var now_ms: Int
    var refused: Int
    var expired: Int
    var dropped: Int
    var upgraded: Int

    def __init__(out self, var tls: MailTlsTable, var config: ImapServerConfig) raises:
        self.listener = bind_imap_listener(inet_loopback_be(), UInt16(0))
        self.reg = ImapRegistry()
        self.tls = tls^
        self.verifier = TestAuthVerifier()
        self.verifier.add_user(String("bob@example.com"), String("s3cret"))
        self.store = SharedInMemoryConditionalStore()
        self.view = self.store.clone()
        self.config = config^
        self.now_ms = 1000
        self.refused = 0
        self.expired = 0
        self.dropped = 0
        self.upgraded = 0

    def step(mut self):
        var o = serve_one_iteration(
            self.reg,
            self.listener,
            self.tls,
            self.verifier,
            self.store,
            self.config,
            self.now_ms,
        )
        self.refused += o.refused
        self.expired += o.expired
        self.dropped += o.dropped
        self.upgraded += o.upgraded

    def pump(mut self, mut peer: Peer):
        self.step()
        _ = peer.poll()
        yield_cpu()


def _tls_rig(var config: ImapServerConfig) raises -> _Rig:
    var table = MailTlsTable.from_cert_pem(
        read_fixture(String("leaf_cert.pem")), read_fixture(String("leaf_key.pem"))
    )
    return _Rig(table^, config^)


def _plain_rig(var config: ImapServerConfig) raises -> _Rig:
    # No certificate: the table is empty and STARTTLS is not offered. LOGIN is
    # allowed in the clear because nothing else is possible.
    config.offer_starttls = False
    config.require_tls_for_login = False
    return _Rig(MailTlsTable(TlsConfig()), config^)


def _config(limits: ImapLimits = ImapLimits()) -> ImapServerConfig:
    return ImapServerConfig(String("imap.test"), True, True, limits.copy())


def _wait_for(mut rig: _Rig, mut peer: Peer, marker: String) raises:
    while not peer.has(marker):
        if peer.eof:
            raise Error("closed before " + marker + ": " + peer.text())
        rig.pump(peer)


def _wait_eof(mut rig: _Rig, mut peer: Peer):
    while not peer.eof:
        rig.pump(peer)


def _greeting(mut rig: _Rig, mut peer: Peer) raises:
    _wait_for(rig, peer, String("IMAP4rev1 ready\r\n"))
    _ = peer.take_through(String("IMAP4rev1 ready\r\n"))


def _run(mut rig: _Rig, mut peer: Peer, line: String, done: String) raises -> String:
    """Send a line, run the server until `done` has arrived, return what
    arrived up to and including it."""
    peer.send(line + "\r\n")
    _wait_for(rig, peer, done)
    return peer.take_through(done)


def _noop(mut rig: _Rig, mut peer: Peer) raises:
    """One NOOP round trip: proof the connection is alive and served."""
    _ = _run(rig, peer, String("n1 NOOP"), String("n1 OK NOOP completed\r\n"))


def _upgrade(mut rig: _Rig, mut peer: Peer) raises:
    """STARTTLS and the handshake, driven from both ends. One connection only."""
    _ = _run(
        rig, peer, String("u1 STARTTLS"), String("u1 OK Begin TLS negotiation now\r\n")
    )
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


def _text(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _seed(mut rig: _Rig, count: Int, extra: Int = 0) raises -> List[List[UInt8]]:
    """`count` messages in bob's INBOX; `extra` more bytes of body in each."""
    var raws = List[List[UInt8]]()
    for i in range(count):
        var raw = _text(
            String("Subject: m") + String(i) + "\r\n\r\nbody " + String(i) + "\r\n"
        )
        for k in range(extra):
            raw.append(UInt8(0x61 + (k * 7 + i) % 26))
        _ = store_message(
            rig.view, String("bob@example.com"), String("INBOX"), raw
        )
        raws.append(raw^)
    return raws^


def _expected_fetch(
    rig: _Rig, id: Int, raws: List[List[UInt8]], tag: String
) -> List[UInt8]:
    """The answer to `FETCH 1:* (UID BODY.PEEK[])` for messages that were
    stored from `raws`: each found by its UID, so the order of the view does
    not matter."""
    var out = List[UInt8]()
    for seq in range(1, len(raws) + 1):
        var uid = rig.reg.uid_at(id, seq)
        var found = -1
        for k in range(len(raws)):
            if assign_uid(content_hash_hex(raws[k])) == uid:
                found = k
        out.extend(
            (
                String("* ")
                + String(seq)
                + " FETCH (UID "
                + String(uid)
                + " BODY[] {"
                + String(len(raws[found]))
                + "}\r\n"
            ).as_bytes()
        )
        out.extend(Span(raws[found]))
        out.extend(String(")\r\n").as_bytes())
    out.extend((tag + " OK FETCH completed\r\n").as_bytes())
    return out^


def test_read_mail_over_starttls() raises:
    var rig = _tls_rig(_config())
    var raws = _seed(rig, 3, 200)
    var peer = Peer.connect(rig.listener.local_port())
    _wait_for(rig, peer, String("IMAP4rev1 ready\r\n"))
    assert_true(
        peer.text().startswith(
            "* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] imap.test"
        ),
        peer.text(),
    )
    _ = peer.take_through(String("IMAP4rev1 ready\r\n"))
    # In the clear the password does not cross.
    var r = _run(rig, peer, String("c1 LOGIN bob@example.com s3cret"), String("\r\n"))
    assert_equal(r, "c1 NO [PRIVACYREQUIRED] LOGIN is disabled until STARTTLS\r\n")
    _upgrade(rig, peer)
    assert_equal(rig.upgraded, 1)
    r = _run(rig, peer, String("c2 CAPABILITY"), String("c2 OK CAPABILITY completed\r\n"))
    assert_equal(r, "* CAPABILITY IMAP4rev1\r\nc2 OK CAPABILITY completed\r\n")
    # The session started over: the user has to log in on TLS.
    r = _run(rig, peer, String("c3 LOGIN bob@example.com s3cret"), String("\r\n"))
    assert_equal(r, "c3 OK [CAPABILITY IMAP4rev1] LOGIN completed\r\n")
    r = _run(rig, peer, String("c4 SELECT INBOX"), String("c4 OK [READ-WRITE] SELECT completed\r\n"))
    assert_true(r.startswith("* 3 EXISTS\r\n"), r)
    # The messages come back exactly.
    var ids = rig.reg.all_conn_ids()
    var want = _expected_fetch(rig, ids[0], raws, String("c5"))
    peer.send(String("c5 FETCH 1:* (UID BODY.PEEK[])\r\n"))
    while len(peer.inbox) < len(want):
        if peer.eof:
            raise Error("closed early")
        rig.pump(peer)
    assert_true(_same(peer.inbox, want))
    peer.inbox = List[UInt8]()
    r = _run(rig, peer, String("c6 LOGOUT"), String("c6 OK LOGOUT completed\r\n"))
    assert_equal(r, "* BYE imap.test logging out\r\nc6 OK LOGOUT completed\r\n")
    _wait_eof(rig, peer)
    assert_equal(rig.reg.conn_count(), 0)
    assert_equal(rig.tls.tls_conn_count(), 0)
    peer.close()


def test_structures_sections_and_search_over_starttls() raises:
    var rig = _tls_rig(_config())
    var raw = _text(
        String(
            "Date: Tue, 01 Sep 2026 10:00:00 +0000\r\n"
            "From: a@sender.test\r\n"
            "Subject: over tls\r\n"
            "\r\n"
            "secure body\r\n"
        )
    )
    _ = store_message(
        rig.view, String("bob@example.com"), String("INBOX"), raw
    )
    var peer = Peer.connect(rig.listener.local_port())
    _greeting(rig, peer)
    _upgrade(rig, peer)
    var r = _run(rig, peer, String("c3 LOGIN bob@example.com s3cret"), String("\r\n"))
    assert_equal(r, "c3 OK [CAPABILITY IMAP4rev1] LOGIN completed\r\n")
    r = _run(rig, peer, String("c4 SELECT INBOX"), String("c4 OK [READ-WRITE] SELECT completed\r\n"))
    assert_true(r.startswith("* 1 EXISTS\r\n"), r)
    var sender = String('((NIL NIL "a" "sender.test"))')
    r = _run(
        rig,
        peer,
        String(
            "f1 FETCH 1 (ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (SUBJECT)]"
            " BODY.PEEK[1]<0.6> INTERNALDATE)"
        ),
        String("f1 OK FETCH completed\r\n"),
    )
    # "Subject: over tls" and its line break, then the empty line: 21 octets;
    # the body "secure body" and its line break are 13 octets in one line.
    assert_equal(
        r,
        String('* 1 FETCH (ENVELOPE ("Tue, 01 Sep 2026 10:00:00 +0000" "over tls" ')
        + sender
        + " "
        + sender
        + " "
        + sender
        + " NIL NIL NIL NIL NIL)"
        + ' BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 13 1'
        + " NIL NIL NIL NIL)"
        + " BODY[HEADER.FIELDS (SUBJECT)] {21}\r\nSubject: over tls\r\n\r\n"
        + " BODY[1]<0> {6}\r\nsecure"
        + ' INTERNALDATE " 1-Sep-2026 10:00:00 +0000")\r\n'
        + "f1 OK FETCH completed\r\n",
    )
    r = _run(rig, peer, String("s2 SEARCH SUBJECT TLS BODY secure"), String("s2 OK SEARCH completed\r\n"))
    assert_equal(r, "* SEARCH 1\r\ns2 OK SEARCH completed\r\n")
    r = _run(rig, peer, String("s3 SEARCH BODY nothing"), String("s3 OK SEARCH completed\r\n"))
    assert_equal(r, "* SEARCH\r\ns3 OK SEARCH completed\r\n")
    r = _run(rig, peer, String("c6 LOGOUT"), String("c6 OK LOGOUT completed\r\n"))
    _wait_eof(rig, peer)
    peer.close()


def test_failed_logins_on_tls_end_the_connection() raises:
    var rig = _tls_rig(_config())
    var peer = Peer.connect(rig.listener.local_port())
    _greeting(rig, peer)
    _upgrade(rig, peer)
    for i in range(2):
        var r = _run(rig, peer, String("l") + String(i) + " LOGIN bob@example.com wrong", String("\r\n"))
        assert_equal(r, String("l") + String(i) + " NO [AUTHENTICATIONFAILED] Authentication failed\r\n")
    peer.send(String("l2 LOGIN bob@example.com wrong\r\n"))
    _wait_eof(rig, peer)
    assert_equal(
        peer.text(),
        "l2 NO [AUTHENTICATIONFAILED] Authentication failed\r\n* BYE Too many failed login attempts\r\n",
    )
    assert_equal(rig.reg.conn_count(), 0)
    assert_equal(rig.tls.tls_conn_count(), 0)
    peer.close()


def test_lines_pipelined_behind_starttls_close_the_connection() raises:
    var rig = _tls_rig(_config())
    var peer = Peer.connect(rig.listener.local_port())
    _greeting(rig, peer)
    peer.send(String("a1 STARTTLS\r\na2 NOOP\r\na3 LOGIN bob@example.com s3cret\r\n"))
    _wait_for(rig, peer, String("a1 OK Begin TLS negotiation now\r\n"))
    # The step that wrote the OK decided: the connection is already gone and no
    # TLS state was made for it.
    assert_equal(rig.reg.conn_count(), 0)
    assert_equal(rig.tls.tls_conn_count(), 0)
    _wait_eof(rig, peer)
    # Nothing but the OK was ever written: none of the lines ran.
    assert_equal(peer.text(), "a1 OK Begin TLS negotiation now\r\n")
    peer.close()


def test_max_conns_tells_the_extra_connection_bye() raises:
    var limits = ImapLimits()
    limits.max_conns = 2
    var rig = _plain_rig(_config(limits.copy()))
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    var c = Peer.connect(rig.listener.local_port())
    _greeting(rig, a)
    _greeting(rig, b)
    # The first step accepted all three: the third was refused in it.
    assert_equal(rig.refused, 1)
    _wait_for(rig, c, String("\r\n"))
    assert_equal(c.text(), "* BYE Too many connections, try again later\r\n")
    _wait_eof(rig, c)
    assert_equal(rig.refused, 1)
    assert_equal(rig.reg.conn_count(), 2)
    # The two that fit are still served.
    _noop(rig, a)
    _noop(rig, b)
    # A slot frees when one leaves, and the next connection gets it.
    _ = _run(rig, a, String("q1 LOGOUT"), String("q1 OK LOGOUT completed\r\n"))
    _wait_eof(rig, a)
    var d = Peer.connect(rig.listener.local_port())
    _greeting(rig, d)
    assert_equal(rig.refused, 1)
    assert_equal(rig.reg.conn_count(), 2)
    a.close()
    b.close()
    c.close()
    d.close()


def test_expiry_is_decided_by_now_ms_and_exact() raises:
    var limits = ImapLimits()
    limits.idle_ms = 1000
    limits.max_session_ms = 5000
    limits.max_unauth_ms = 0
    var rig = _plain_rig(_config(limits.copy()))
    var idle = Peer.connect(rig.listener.local_port())
    var busy = Peer.connect(rig.listener.local_port())
    _greeting(rig, idle)
    _greeting(rig, busy)
    # Both connected at 1000. Quiet for exactly idle_ms is not idle.
    rig.now_ms = 2000
    rig.step()
    assert_equal(rig.expired, 0)
    assert_equal(rig.reg.conn_count(), 2)
    # One millisecond more: `idle` is told and closed. `busy` speaks in the same
    # step's time, so it is not idle.
    rig.now_ms = 2001
    _noop(rig, busy)
    assert_equal(rig.expired, 1)
    _wait_for(rig, idle, String("\r\n"))
    _wait_eof(rig, idle)
    assert_equal(
        idle.text(), "* BYE Autologout: the connection was idle or open too long\r\n"
    )
    assert_equal(rig.reg.conn_count(), 1)
    # `busy` keeps speaking, so it is never idle ...
    rig.now_ms = 3000
    _noop(rig, busy)
    rig.now_ms = 4000
    _noop(rig, busy)
    rig.now_ms = 5000
    _noop(rig, busy)
    rig.now_ms = 5900
    _noop(rig, busy)
    # ... and exactly max_session_ms old (accepted at 1000) is not too old.
    rig.now_ms = 6000
    _noop(rig, busy)
    assert_equal(rig.expired, 1)
    assert_equal(rig.reg.conn_count(), 1)
    # One millisecond more is.
    rig.now_ms = 6001
    rig.step()
    assert_equal(rig.expired, 2)
    _wait_for(rig, busy, String("* BYE Autologout"))
    _wait_eof(rig, busy)
    assert_equal(rig.reg.conn_count(), 0)
    idle.close()
    busy.close()


def test_a_connection_that_does_not_log_in_is_closed() raises:
    var limits = ImapLimits()
    limits.max_unauth_ms = 3000
    var rig = _plain_rig(_config(limits.copy()))
    var lazy = Peer.connect(rig.listener.local_port())
    var user = Peer.connect(rig.listener.local_port())
    _greeting(rig, lazy)
    _greeting(rig, user)
    _ = _run(rig, user, String("l1 LOGIN bob@example.com s3cret"), String("l1 OK"))
    # Both connected at 1000; lazy keeps talking but never logs in.
    rig.now_ms = 2500
    _noop(rig, lazy)
    rig.now_ms = 4000  # exactly max_unauth_ms after the connect: alive
    _noop(rig, lazy)
    assert_equal(rig.expired, 0)
    rig.now_ms = 4001
    _noop(rig, user)
    assert_equal(rig.expired, 1)
    _wait_for(rig, lazy, String("* BYE Autologout"))
    _wait_eof(rig, lazy)
    # The user who logged in is not subject to that limit.
    rig.now_ms = 50000
    _noop(rig, user)
    assert_equal(rig.expired, 1)
    assert_equal(rig.reg.conn_count(), 1)
    lazy.close()
    user.close()


def test_a_line_over_the_cap_closes_only_its_own_connection() raises:
    var limits = ImapLimits()
    limits.max_line = 1000
    var rig = _plain_rig(_config(limits.copy()))
    var bad = Peer.connect(rig.listener.local_port())
    var good = Peer.connect(rig.listener.local_port())
    _greeting(rig, bad)
    _greeting(rig, good)
    var junk = List[UInt8]()
    for _ in range(5000):
        junk.append(UInt8(0x41))
    bad.send_bytes(Span(junk))
    _wait_eof(rig, bad)
    assert_equal(bad.text(), "* BYE Command line too long\r\n")
    assert_equal(rig.reg.conn_count(), 1)
    _noop(rig, good)
    bad.close()
    good.close()


def test_a_peer_reset_drops_only_its_own_connection() raises:
    var rig = _plain_rig(_config())
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    _greeting(rig, a)
    _greeting(rig, b)
    _ = _run(rig, a, String("a1 LOGIN bob@example.com s3cret"), String("a1 OK"))
    a.send(String("a2 SELECT IN"))  # half a line
    a.reset()
    while rig.reg.conn_count() > 1:
        rig.step()
        _ = b.poll()
        yield_cpu()
    assert_equal(rig.dropped, 1)
    _noop(rig, b)
    _ = _run(rig, b, String("b1 LOGOUT"), String("b1 OK LOGOUT completed\r\n"))
    _wait_eof(rig, b)
    assert_equal(rig.reg.conn_count(), 0)
    b.close()


def test_a_bad_tls_hello_drops_only_its_own_connection() raises:
    var rig = _tls_rig(_config())
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    _greeting(rig, a)
    _greeting(rig, b)
    _ = _run(rig, a, String("a1 STARTTLS"), String("a1 OK Begin TLS negotiation now\r\n"))
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
    assert_equal(rig.tls.tls_conn_count(), 0)
    _noop(rig, b)
    a.close()
    b.close()


def test_a_peer_that_leaves_mid_handshake_loses_its_tls_state() raises:
    var rig = _tls_rig(_config())
    var a = Peer.connect(rig.listener.local_port())
    var b = Peer.connect(rig.listener.local_port())
    _greeting(rig, a)
    _greeting(rig, b)
    _ = _run(rig, a, String("a1 STARTTLS"), String("a1 OK Begin TLS negotiation now\r\n"))
    # The ClientHello goes out; the handshake is not finished.
    a.start_tls(read_fixture(String("root_ca.pem")))
    _ = a.tls_step()
    rig.step()
    assert_equal(rig.reg.conn_count(), 2)
    assert_equal(rig.tls.tls_conn_count(), 1)
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
    var config = _config()
    config.offer_starttls = False
    config.require_tls_for_login = False
    var rig = _Rig(MailTlsTable(TlsConfig()), config^)
    var p = Peer.connect(rig.listener.local_port())
    _wait_for(rig, p, String("IMAP4rev1 ready\r\n"))
    assert_true(p.text().startswith("* OK [CAPABILITY IMAP4rev1] imap.test"), p.text())
    assert_false(p.has("STARTTLS"))
    _ = p.take_through(String("IMAP4rev1 ready\r\n"))
    var r = _run(rig, p, String("a1 STARTTLS"), String("\r\n"))
    assert_equal(r, "a1 NO [CANNOT] STARTTLS is not available\r\n")
    # The connection goes on in the clear.
    _noop(rig, p)
    assert_equal(rig.reg.conn_count(), 1)
    p.close()


def test_a_short_write_is_resumed_in_order() raises:
    # Small socket buffers on both ends and a message much larger than both:
    # writes are short and the socket is full many times. What the peer
    # finally reads must be exactly the answer, in order.
    var rig = _plain_rig(_config())
    var raws = _seed(rig, 2, 300000)
    var p = Peer.connect(rig.listener.local_port())
    _greeting(rig, p)
    _ = _run(rig, p, String("l1 LOGIN bob@example.com s3cret"), String("l1 OK"))
    _ = _run(rig, p, String("s1 SELECT INBOX"), String("s1 OK [READ-WRITE] SELECT completed\r\n"))
    var ids = rig.reg.all_conn_ids()
    set_so_sndbuf(rig.reg.fd_of(ids[0]), Int32(4096))
    set_so_rcvbuf(p.fd, Int32(4096))
    var want = _expected_fetch(rig, ids[0], raws, String("f1"))
    assert_true(len(want) > 600000)
    p.send(String("f1 FETCH 1:2 (UID BODY.PEEK[])\r\n"))
    while len(p.inbox) < len(want):
        if p.eof:
            raise Error("closed early")
        rig.pump(p)
    assert_equal(len(p.inbox), len(want))
    assert_true(_same(p.inbox, want))
    p.close()


def main() raises:
    test_read_mail_over_starttls()
    test_structures_sections_and_search_over_starttls()
    test_failed_logins_on_tls_end_the_connection()
    test_lines_pipelined_behind_starttls_close_the_connection()
    test_max_conns_tells_the_extra_connection_bye()
    test_expiry_is_decided_by_now_ms_and_exact()
    test_a_connection_that_does_not_log_in_is_closed()
    test_a_line_over_the_cap_closes_only_its_own_connection()
    test_a_peer_reset_drops_only_its_own_connection()
    test_a_bad_tls_hello_drops_only_its_own_connection()
    test_a_peer_that_leaves_mid_handshake_loses_its_tls_state()
    test_without_a_certificate_starttls_is_not_offered()
    test_a_short_write_is_resumed_in_order()
    print("test_serve_loop: OK")
