# A TLS client from komira_http_core against a MailTlsTable entry over a real
# TCP connection on 127.0.0.1 (port 0). What each case catches:
# - the handshake: the entry reports BLOCKED_ON_READ before the client speaks,
#   reaches DONE only through drive_handshake_burst, and handshake_done
#   follows it (a burst that returns DONE early, or never, fails here);
# - data both ways: 40000 bytes each direction arrive intact and in order, a
#   recv asked for 1000 bytes returns at most 1000, and a short message round
#   trips (a recv that drops or duplicates bytes at a chunk boundary, ignores
#   its limit, or a send that ignores a short count, fails here);
# - the client's close_notify reads as (DONE, 0) on the server;
# - a plaintext SMTP peer that then closes makes the burst return ERROR (never
#   DONE), and a malformed hello makes the burst return ERROR;
# - no wait has a time or iteration limit: each loops until its event;
# - drop frees the TLS state and leaves the socket open (the server's
#   connection closes its own fd).

from std.ffi import external_call
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.socket_io import try_io_accept, try_send
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    getsockname_port,
    inet_loopback_be,
    listen_socket,
    set_so_reuseaddr,
    sockaddr_in_bytes,
    socket_tcp_nonblocking,
)
from komira_http_core.tls import (
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
)
from komira_mail_tls import (
    MailTlsTable,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    tls_entries_created,
    tls_entries_freed,
)

comptime _FIXTURES: String = "src/komira_http_core/tests/fixtures/tls/"
comptime _BIG: Int = 40000


def _read(name: String) raises -> String:
    return Path(_FIXTURES + name).read_text()


def _yield():
    """Give up the CPU between two tries of a wait loop. Every wait loop in
    this file runs until the event it awaits (a handshake DONE, the expected
    bytes, the peer's close_notify); none has an iteration or time limit, so
    a test never asserts on how long delivery takes. A hang is the build's
    watchdog to catch."""
    _ = external_call["sched_yield", Int32]()


def _set_nonblock(fd: Int32) -> Int32:
    return external_call["komira_fcntl_set_nonblock", Int32](fd)


struct _Pair(Copyable, Movable):
    """A connected loopback pair: `client` dialled the listener, `server` is
    what the listener accepted. Both are non-blocking. A test closes them with
    `close()` when it is done."""

    var client: Int32
    var server: Int32

    def __init__(out self, client: Int32, server: Int32):
        self.client = client
        self.server = server

    def close(self):
        close_fd(self.client)
        close_fd(self.server)


def _pair() raises -> _Pair:
    var listener = socket_tcp_nonblocking()
    set_so_reuseaddr(listener)
    bind_inet(listener, inet_loopback_be(), UInt16(0))
    listen_socket(listener, Int32(8))
    var port = getsockname_port(listener)

    var client = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    if client < Int32(0):
        raise Error("client socket() failed")
    var sa = sockaddr_in_bytes(inet_loopback_be(), port)
    var rc = external_call["connect", Int32](client, sa.unsafe_ptr(), UInt32(16))
    if rc < Int32(0):
        close_fd(client)
        close_fd(listener)
        raise Error("client connect() to the loopback listener failed")
    if _set_nonblock(client) < Int32(0):
        raise Error("client set_nonblock failed")

    # connect() has completed, so the connection is in the accept queue; wait
    # for the accept itself.
    var server = Int32(-1)
    while server < Int32(0):
        var a = try_io_accept(listener)
        if a.is_ready():
            server = Int32(Int(a.value()))
        else:
            _yield()
    close_fd(listener)
    return _Pair(client, server)


def _client_config() raises -> TlsConfig:
    var cfg = TlsConfig()
    cfg.wipe_trust()
    cfg.add_trust_pem(_read("root_ca.pem"))
    return cfg^


def _payload(n: Int, salt: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + salt) % 251))
    return out^


def test_handshake_and_data_both_ways() raises:
    var pair = _pair()
    var table = MailTlsTable.from_cert_pem(_read("leaf_cert.pem"), _read("leaf_key.pem"))
    var cfg = _client_config()
    var client = TlsConnection.new_client(cfg)
    client.bind_fd(pair.client)
    client.set_server_name(String("localhost"))
    var created0 = tls_entries_created()
    var freed0 = tls_entries_freed()

    table.begin_upgrade(1, pair.server, 0)
    assert_equal(tls_entries_created() - created0, 1)
    assert_false(table.handshake_done(1))
    # The client has said nothing yet: the server waits for its hello.
    assert_equal(Int(table.drive_handshake_burst(1)), Int(TLS_OUTCOME_BLOCKED_ON_READ))
    assert_false(table.handshake_done(1))

    var server_done = False
    var client_done = False
    while not (server_done and client_done):
        _yield()
        if not server_done:
            var so = table.drive_handshake_burst(1)
            if so == TLS_OUTCOME_ERROR:
                raise Error("server handshake: " + s2n_strerror_message(last_s2n_errno()))
            server_done = so == TLS_OUTCOME_DONE
        if not client_done:
            var co = client.handshake()
            if co == TLS_OUTCOME_ERROR:
                raise Error("client handshake: " + s2n_strerror_message(last_s2n_errno()))
            client_done = co == TLS_OUTCOME_DONE
    assert_true(table.handshake_done(1))
    # Once done, more bursts stay done.
    assert_equal(Int(table.drive_handshake_burst(1)), Int(TLS_OUTCOME_DONE))

    # A short message, client to server and back.
    var hello = List[UInt8]()
    for b in String("EHLO client.example\r\n").as_bytes():
        hello.append(b)
    var sent = client.send(Span[UInt8](hello))
    assert_equal(Int(sent[0]), Int(TLS_OUTCOME_DONE))
    assert_equal(sent[1], len(hello))
    var got = List[UInt8]()
    while len(got) < len(hello):
        var r = table.recv(1, got, 4096)
        if r[0] == TLS_OUTCOME_ERROR:
            raise Error("server recv failed")
        if len(got) < len(hello):
            _yield()
    assert_equal(len(got), len(hello))
    for i in range(len(hello)):
        assert_equal(Int(got[i]), Int(hello[i]))

    var reply = List[UInt8]()
    for b in String("250 server.example\r\n").as_bytes():
        reply.append(b)
    var rs = table.send(1, Span[UInt8](reply))
    assert_equal(Int(rs[0]), Int(TLS_OUTCOME_DONE))
    assert_equal(rs[1], len(reply))
    var back = List[UInt8](length=256, fill=UInt8(0))
    var seen = 0
    while seen < len(reply):
        var r = client.recv_into_span(Span[UInt8](back)[seen:256])
        if r[0] == TLS_OUTCOME_ERROR:
            raise Error("client recv failed")
        if r[0] == TLS_OUTCOME_DONE and r[1] > 0:
            seen += r[1]
        if seen < len(reply):
            _yield()
    assert_equal(seen, len(reply))
    for i in range(len(reply)):
        assert_equal(Int(back[i]), Int(reply[i]))

    # 40000 bytes client to server, read in capped chunks.
    var up = _payload(_BIG, 3)
    var off = 0
    while off < _BIG:
        var s = client.send(Span[UInt8](up)[off:_BIG])
        if s[0] == TLS_OUTCOME_ERROR:
            raise Error("client send failed")
        if s[0] == TLS_OUTCOME_DONE and s[1] > 0:
            off += s[1]
        else:
            _yield()
    assert_equal(off, _BIG)
    var heard = List[UInt8]()
    # max_bytes is honoured: a recv asked for 1000 gives at most 1000.
    while len(heard) == 0:
        var first = table.recv(1, heard, 1000)
        if first[0] == TLS_OUTCOME_ERROR:
            raise Error("server recv failed")
        if first[0] == TLS_OUTCOME_DONE and first[1] > 0:
            assert_true(first[1] <= 1000)
            assert_equal(len(heard), first[1])
        else:
            _yield()
    assert_true(len(heard) > 0)
    while len(heard) < _BIG:
        var r = table.recv(1, heard, 1000000)
        if r[0] == TLS_OUTCOME_ERROR:
            raise Error("server recv failed")
        if len(heard) < _BIG:
            _yield()
    assert_equal(len(heard), _BIG)
    for i in range(_BIG):
        assert_equal(Int(heard[i]), Int(up[i]))

    # 40000 bytes server to client.
    var down = _payload(_BIG, 11)
    off = 0
    while off < _BIG:
        var s = table.send(1, Span[UInt8](down)[off:_BIG])
        if s[0] == TLS_OUTCOME_ERROR:
            raise Error("server send failed")
        if s[0] == TLS_OUTCOME_DONE and s[1] > 0:
            off += s[1]
        else:
            _yield()
    assert_equal(off, _BIG)
    var down_got = List[UInt8](length=_BIG, fill=UInt8(0))
    seen = 0
    while seen < _BIG:
        var r = client.recv_into_span(Span[UInt8](down_got)[seen:_BIG])
        if r[0] == TLS_OUTCOME_ERROR:
            raise Error("client recv failed")
        if r[0] == TLS_OUTCOME_DONE and r[1] > 0:
            seen += r[1]
        else:
            _yield()
    assert_equal(seen, _BIG)
    for i in range(_BIG):
        assert_equal(Int(down_got[i]), Int(down[i]))

    # The client's close_notify is the server's end of stream: (DONE, 0).
    var shut = client.shutdown()
    assert_true(shut != TLS_OUTCOME_ERROR)
    var eof = False
    while not eof:
        var sink = List[UInt8]()
        var r = table.recv(1, sink, 100)
        if r[0] == TLS_OUTCOME_ERROR:
            raise Error("server recv failed before the close_notify")
        eof = r[0] == TLS_OUTCOME_DONE and r[1] == 0
        if not eof:
            _yield()

    # Dropping frees the entry and leaves the socket open.
    assert_equal(tls_entries_freed() - freed0, 0)
    assert_true(_set_nonblock(pair.server) >= Int32(0), "fd open before drop")
    table.drop(1)
    assert_equal(tls_entries_freed() - freed0, 1)
    assert_false(table.is_tls(1))
    assert_true(_set_nonblock(pair.server) >= Int32(0), "fd open after drop")
    _ = client^
    pair.close()


def _burst_against(bytes_from_peer: List[UInt8], then_close: Bool) raises -> UInt8:
    """Send `bytes_from_peer` in the clear to a table entry that expects a TLS
    hello, optionally close the peer's end, and drive the entry's handshake
    until a burst returns something other than BLOCKED_ON_READ (the entry has
    consumed the peer's bytes and decided). Return that outcome. The handshake
    is never `DONE` afterwards."""
    var pair = _pair()
    var table = MailTlsTable.from_cert_pem(_read("leaf_cert.pem"), _read("leaf_key.pem"))
    table.begin_upgrade(1, pair.server, 0)
    var n = try_send(pair.client, Span[UInt8](bytes_from_peer))
    assert_equal(Int(n), len(bytes_from_peer))
    if then_close:
        # The peer's end of stream is the event that ends the wait even when
        # the bytes alone leave the server wanting more.
        close_fd(pair.client)
        pair.client = Int32(-1)
    var outcome = table.drive_handshake_burst(1)
    while outcome == TLS_OUTCOME_BLOCKED_ON_READ:
        _yield()
        outcome = table.drive_handshake_burst(1)
    assert_false(table.handshake_done(1))
    table.drop(1)
    if pair.client >= Int32(0):
        close_fd(pair.client)
    close_fd(pair.server)
    return outcome


def test_plaintext_smtp_peer_never_completes() raises:
    var smtp = List[UInt8]()
    for b in String(
        "EHLO plaintext.example\r\nMAIL FROM:<a@b.example>\r\nRCPT TO:<c@d.example>\r\n"
    ).as_bytes():
        smtp.append(b)
    # The plaintext bytes are consumed and the peer then closes; the burst
    # reports ERROR, never DONE.
    assert_equal(Int(_burst_against(smtp, True)), Int(TLS_OUTCOME_ERROR))


def test_malformed_hello_is_an_error() raises:
    # A handshake record (type 22, TLS 1.0 framing) whose message type 0xAA is
    # not a ClientHello.
    var bad = List[UInt8]()
    for b in [22, 3, 1, 0, 32]:
        bad.append(UInt8(b))
    for _ in range(32):
        bad.append(UInt8(0xAA))
    assert_equal(Int(_burst_against(bad, False)), Int(TLS_OUTCOME_ERROR))


def main() raises:
    test_handshake_and_data_both_ways()
    test_plaintext_smtp_peer_never_completes()
    test_malformed_hello_is_an_error()
    print("test_loopback_handshake: OK")
