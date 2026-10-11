# =============================================================================
# test_L0_accept_loop_tls.mojo: the TLS half of accept_loop.mojo
# =============================================================================
#
# `serve_read_round_tls` runs against a server `ConnEntry` holding a server
# `TlsStream`, joined to an s2n client `TlsConnection` by an AF_UNIX
# socketpair in this process (no network). Both handshake to DONE first. A
# byte written on one end is readable on the other when the write returns,
# so every round sees exactly what the client sent before it; no test waits
# on a clock.
#
# A blocked write is made by filling the server's send side with plain
# bytes until the kernel answers EAGAIN (the client never reads them); a
# failed write by shutting the server's write side (EPIPE; the TLS library
# ignores SIGPIPE).
#
# The accept tests use a real loopback listener and wait for a connection
# with poll(2) and no timeout, which returns as soon as the kernel has
# queued it.
#
# Groups (and the defect each would catch):
#   S  admission: a connection without TLS driven or served as if it had it.
#   R  a round: a request not answered, a pipelined request skipped or read
#      from the wrong offset, a connection kept after `Connection: close`,
#      an incomplete head or request kept waiting, a malformed request
#      answered with anything but its static error, an expectation answered
#      wrong for either setting, close_notify or a reset not closing.
#   W  a write that fails or blocks: counted as sent, or the connection kept.
#   A  accept: a connection not wrapped in TLS, not waiting for the
#      ClientHello, not registered or mapped; a listener error not ending the
#      drain; a stale mapping swept.
# =============================================================================

from std.collections.dict import Dict
from std.ffi import external_call
from std.pathlib import Path
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    RegistrationHandle,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    Reactor,
)
from komira_async.reactor.socket_io import try_io_read, try_io_write
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.runtime.tcp_stream import TcpListener, TcpStream
from komira_collections.slab import Slab
from komira_http_core.codec.h1.limits import ParseLimits
from komira_http_core.codec.h1.parser import build_error_response_bytes
from komira_http_core.tls import (
    CONN_STATE_CLOSED,
    CONN_STATE_TLS_HANDSHAKE_IN,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    TlsStream,
    tls_init,
)
from komira_http_server.accept_loop import (
    accept_one_and_register_tls,
    drive_tls_handshake,
    serve_read_round_tls,
)
from komira_http_server.connection import (
    ConnEntry,
    REQ_BUF_BYTES,
    RESP_BUF_CAP,
)


comptime CANNED = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
comptime GET = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
comptime CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n"
# RFC 9112 section 5.1: no whitespace is allowed between a field name and its
# colon, and a server must answer such a request with 400.
comptime BAD_NAME = "GET / HTTP/1.1\r\nHost: example.com\r\nAccept : */*\r\n\r\n"
# RFC 9110 section 10.1.1: a client that sends a body may first ask whether
# the server will take it.
comptime EXPECT = (
    "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
    "Content-Length: 5\r\n\r\nhello"
)
comptime CERT = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime KEY = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"


# -----------------------------------------------------------------------------
# Sockets and bytes.
# -----------------------------------------------------------------------------


def _socketpair() raises -> Array[Int32, 2]:
    var pair = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: `pair` is a stack local that outlives the call; socketpair(2)
    # writes two ints into it and retains nothing.
    var rc = external_call["socketpair", Int32](
        Int32(1), Int32(1), Int32(0), pair.unsafe_ptr()
    )
    if rc < 0:
        raise Error("socketpair(AF_UNIX, SOCK_STREAM) failed")
    for i in range(2):
        if external_call["komira_fcntl_set_nonblock", Int32](pair[i]) < 0:
            raise Error("set_nonblock failed")
    return pair^


def _set_sndbuf(fd: Int32, bytes: Int) raises:
    """Shrink `fd`'s send buffer (the kernel raises a tiny value to its
    minimum), so a fill to EAGAIN takes a few writes."""
    var val = Int32(bytes)
    var level = Int32(1)
    var opt = Int32(7)
    comptime if CompilationTarget.is_macos():
        level = Int32(0xFFFF)
        opt = Int32(0x1001)
    var rc = external_call["setsockopt", Int32](
        fd,
        level,
        opt,
        # SAFETY: `val` is a stack local read synchronously; nothing retains it.
        UnsafePointer(to=val).bitcast[UInt8](),
        UInt32(4),
    )
    if rc < 0:
        raise Error("setsockopt(SO_SNDBUF) failed")


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _shut_wr(fd: Int32) raises:
    """Shut `fd`'s write side: the next write on it fails with EPIPE."""
    if external_call["shutdown", Int32](fd, Int32(1)) < 0:
        raise Error("shutdown(SHUT_WR) failed")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _text(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _error_bytes(status: Int) -> String:
    var b = List[UInt8]()
    build_error_response_bytes(UInt16(status), b)
    return _text(b)


def _eof(fd: Int32) raises -> Bool:
    """Whether the other end of `fd` has closed (nothing else is queued)."""
    var buf = List[UInt8](length=64, fill=UInt8(0))
    var r = try_io_read(fd, Span(buf))
    if r.is_would_block():
        return False
    if not r.is_ready():
        raise Error("read failed")
    return Int(r.value()) == 0


def _server_config() raises -> TlsConfig:
    tls_init()
    var cfg = TlsConfig()
    cfg.load_cert(Path(CERT).read_text(), Path(KEY).read_text())
    return cfg^


# -----------------------------------------------------------------------------
# The link: a handshaken server ConnEntry and an s2n client.
# -----------------------------------------------------------------------------


struct _Link(Movable):
    var entry: ConnEntry
    var client: TlsConnection
    var client_fd: Int32
    var io: Array[UInt8, REQ_BUF_BYTES]
    var resp: Array[UInt8, RESP_BUF_CAP]
    var resp_len: Int
    var continue_ok: Bool
    var reqs: Int64
    var sent: Int64

    def __init__(out self) raises:
        var srv_cfg = _server_config()
        var cli_cfg = TlsConfig()
        cli_cfg.wipe_trust()
        cli_cfg.disable_verify()
        var fds = _socketpair()
        self.entry = ConnEntry(
            stream=TcpStream(fds[0]),
            reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
            tls_stream=TlsStream(srv_cfg, fds[0]),
            initial_state=CONN_STATE_TLS_HANDSHAKE_IN,
        )
        self.client = TlsConnection.new_client(cli_cfg)
        self.client.bind_fd(fds[1])
        self.client_fd = fds[1]
        self.io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self.resp = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
        var c = String(CANNED).as_bytes()
        for i in range(len(c)):
            self.resp[i] = c[i]
        self.resp_len = len(c)
        self.continue_ok = True
        self.reqs = Int64(0)
        self.sent = Int64(0)
        var sv_done = False
        var cl_done = False
        for _ in range(256):
            if not sv_done:
                var o = drive_tls_handshake(self.entry)[0]
                if o == TLS_OUTCOME_ERROR:
                    raise Error("server handshake failed")
                sv_done = o == TLS_OUTCOME_DONE
            if not cl_done:
                var o = self.client.handshake()
                if o == TLS_OUTCOME_ERROR:
                    raise Error("client handshake failed")
                cl_done = o == TLS_OUTCOME_DONE
            if sv_done and cl_done:
                break
        if not (sv_done and cl_done):
            raise Error("the handshake did not finish")

    def __deinit__(deinit self):
        _close(self.client_fd)

    def fd(self) -> Int32:
        return self.entry.fd()

    def round(mut self) -> Bool:
        return serve_read_round_tls(
            self.entry,
            self.io,
            self.resp,
            self.resp_len,
            ParseLimits.defaults(),
            self.continue_ok,
            self.reqs,
            self.sent,
        )

    def write(mut self, s: String) raises:
        """Send all of `s` to the server; the socket must take it."""
        var bytes = _bytes(s)
        var off = 0
        while off < len(bytes):
            var r = self.client.send(Span(bytes)[off:])
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                raise Error("the client could not send: outcome " + String(Int(r[0])))
            off += r[1]

    def read(mut self) raises -> String:
        """Everything the server has written so far, decrypted."""
        var out = List[UInt8]()
        while True:
            var buf = List[UInt8]()
            buf.reserve(16384)
            var r = self.client.recv(buf, 16384)
            if r[0] == TLS_OUTCOME_BLOCKED_ON_READ:
                return _text(out)
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                raise Error("client read ended: outcome " + String(Int(r[0])))
            for i in range(r[1]):
                out.append(buf[i])

    def eof(self) raises -> Bool:
        """Whether the server's end has closed its write side. A method, so
        the link (and the socket it closes when dropped) lives through it."""
        return _eof(self.client_fd)

    def fill(mut self) raises:
        """Fill the server's send side with plain bytes until EAGAIN."""
        _set_sndbuf(self.fd(), 4096)
        var junk = List[UInt8](length=512, fill=UInt8(0x2E))
        while True:
            var r = try_io_write(self.fd(), Span(junk))
            if r.is_would_block():
                return
            if not r.is_ready():
                raise Error("the fill failed")


def _plain_entry(fd: Int32) -> ConnEntry:
    return ConnEntry(
        stream=TcpStream(fd),
        reg=RegistrationHandle(_fd=fd, _interest_set=INTEREST_READ),
    )


# -----------------------------------------------------------------------------
# S: admission.
# -----------------------------------------------------------------------------


def test_handshake_on_a_plain_connection_is_refused() raises:
    var fds = _socketpair()
    var entry = _plain_entry(fds[0])
    var hs = drive_tls_handshake(entry)
    assert_equal(hs[0], TLS_OUTCOME_ERROR)
    assert_equal(hs[1], UInt8(0))
    assert_equal(hs[2], CONN_STATE_CLOSED)
    _ = entry^
    _close(fds[1])


def test_tls_round_on_a_plain_connection_closes() raises:
    var fds = _socketpair()
    var entry = _plain_entry(fds[0])
    var peer = fds[1]
    var data = _bytes(GET)
    _ = try_io_write(peer, Span(data))
    var io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
    var resp = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_false(
        serve_read_round_tls(
            entry, io, resp, 0, ParseLimits.defaults(), True, reqs, sent
        )
    )
    assert_equal(reqs, Int64(0))
    assert_equal(sent, Int64(0))
    _ = entry^
    _close(peer)


# -----------------------------------------------------------------------------
# R: one round.
# -----------------------------------------------------------------------------


def test_nothing_to_read_keeps_the_connection() raises:
    var link = _Link()
    assert_true(link.round())
    assert_equal(link.reqs, Int64(0))
    assert_equal(link.read(), String(""))


def test_one_request_one_response() raises:
    var link = _Link()
    link.write(GET)
    assert_true(link.round())
    assert_equal(link.reqs, Int64(1))
    assert_equal(link.sent, Int64(String(CANNED).byte_length()))
    assert_equal(link.read(), String(CANNED))


def test_pipelined_requests_each_answered_in_order() raises:
    """Three requests in one read, the middle one with a body: each is
    answered once, in order."""
    var link = _Link()
    link.write(
        String(GET)
        + "POST /p HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello"
        + GET
    )
    assert_true(link.round())
    assert_equal(link.reqs, Int64(3))
    assert_equal(link.sent, Int64(3 * String(CANNED).byte_length()))
    assert_equal(link.read(), String(CANNED) + CANNED + CANNED)


def test_request_rest_in_a_later_read_closes_after_the_response() raises:
    var link = _Link()
    link.write("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 10\r\n\r\nhello")
    assert_false(link.round())
    assert_equal(link.reqs, Int64(1))
    assert_equal(link.read(), String(CANNED))


def test_connection_close_ends_the_round() raises:
    """A request after `Connection: close` in the same read is not answered."""
    var link = _Link()
    link.write(
        String("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
        + GET
    )
    assert_false(link.round())
    assert_equal(link.reqs, Int64(1))
    assert_equal(link.read(), String(CANNED))


def test_incomplete_head_closes_without_a_response() raises:
    var link = _Link()
    link.write("GET / HTTP/1.1\r\nHost: exa")
    assert_false(link.round())
    assert_equal(link.reqs, Int64(0))
    assert_equal(link.sent, Int64(0))
    assert_equal(link.read(), String(""))


def test_malformed_request_gets_400_and_close() raises:
    """The request after the malformed one is not answered."""
    var link = _Link()
    link.write(String(BAD_NAME) + GET)
    assert_false(link.round())
    assert_equal(link.reqs, Int64(0))
    var want = _error_bytes(400)
    assert_true(want.startswith("HTTP/1.1 400 Bad Request\r\n"))
    assert_equal(link.sent, Int64(want.byte_length()))
    assert_equal(link.read(), want)


def test_expect_continue_enabled_sends_interim_then_response() raises:
    var link = _Link()
    link.write(String(EXPECT) + GET)
    assert_true(link.round())
    assert_equal(link.reqs, Int64(2))
    assert_equal(
        link.sent,
        Int64(String(CONTINUE).byte_length() + 2 * String(CANNED).byte_length()),
    )
    assert_equal(link.read(), String(CONTINUE) + CANNED + CANNED)


def test_expect_continue_request_ending_the_read_is_answered() raises:
    """The TLS twin of the plaintext expectation case: the request's last
    byte is the last byte of the read, and the round answers it and keeps
    the connection."""
    var link = _Link()
    link.write(EXPECT)
    assert_true(link.round())
    assert_equal(link.reqs, Int64(1))
    assert_equal(
        link.sent,
        Int64(String(CONTINUE).byte_length() + String(CANNED).byte_length()),
    )
    assert_equal(link.read(), String(CONTINUE) + CANNED)


def test_expect_continue_disabled_gets_417_and_close() raises:
    var link = _Link()
    link.continue_ok = False
    link.write(EXPECT)
    assert_false(link.round())
    assert_equal(link.reqs, Int64(0))
    var want = _error_bytes(417)
    assert_true(want.startswith("HTTP/1.1 417 "))
    assert_equal(link.sent, Int64(want.byte_length()))
    assert_equal(link.read(), want)


def test_close_notify_closes() raises:
    var link = _Link()
    _ = link.client.shutdown()
    assert_false(link.round())
    assert_equal(link.reqs, Int64(0))


def test_reset_peer_closes() raises:
    """The client leaves a response unread and closes its socket. Closing an
    AF_UNIX socket with unread data resets the peer on linux, so the
    server's next TLS read fails; where the close reads as a plain end of
    stream instead, the answer is the same."""
    var link = _Link()
    link.write(GET)
    assert_true(link.round())
    _close(link.client_fd)
    link.client_fd = Int32(-1)
    assert_false(link.round())
    assert_equal(link.reqs, Int64(1))


# -----------------------------------------------------------------------------
# W: a write that fails or blocks.
# -----------------------------------------------------------------------------


def test_write_error_on_each_response_closes() raises:
    """With the server's write side shut, every response kind fails to
    send: the round closes and neither counter moves."""
    for k in range(4):
        var link = _Link()
        _shut_wr(link.fd())
        if k == 0:
            link.write(GET)
        elif k == 1:
            link.write(BAD_NAME)
        elif k == 2:
            link.continue_ok = False
            link.write(EXPECT)
        else:
            link.write(EXPECT)
        assert_false(link.round())
        assert_equal(link.reqs, Int64(0))
        assert_equal(link.sent, Int64(0))
        assert_true(link.eof())


def test_blocked_write_closes() raises:
    """A response that cannot be written now is not parked on this path:
    the round closes and counts nothing. This covers today's TLS
    blocked-write path; parking TLS writes is tracked in
    komira-ai/komira#947."""
    var link = _Link()
    link.fill()
    link.write(GET)
    assert_false(link.round())
    assert_equal(link.reqs, Int64(0))
    assert_equal(link.sent, Int64(0))


# -----------------------------------------------------------------------------
# A: accept_one_and_register_tls.
# -----------------------------------------------------------------------------


def _reactor(mock: Bool = False) raises -> Reactor[NoopSink]:
    if mock:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _connect(port: UInt16) raises -> Int32:
    """A blocking loopback TCP client connected to `port`."""
    var fd = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    if fd < 0:
        raise Error("socket() failed")
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(2)
    else:
        addr[0] = UInt8(2)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    # SAFETY: `addr` is a stack local read synchronously by connect(2).
    var rc = external_call["connect", Int32](fd, addr.unsafe_ptr(), UInt32(16))
    if rc < 0:
        _close(fd)
        raise Error("connect() failed")
    return fd


def _poll(fd: Int32) raises:
    """Wait, without a timeout, until `fd` is readable."""
    var pfd = Array[Int32, 2](fill=Int32(0))
    pfd[0] = fd
    pfd[1] = Int32(1)  # events = POLLIN, revents = 0
    # SAFETY: `pfd` is one struct pollfd {int; short; short} on the stack
    # and outlives the call; poll(2) writes only its revents.
    if external_call["poll", Int32](pfd.unsafe_ptr(), UInt64(1), Int32(-1)) < 0:
        raise Error("poll() failed")


def test_accept_wraps_the_connection_in_tls() raises:
    """The new connection is registered, mapped, wrapped in TLS and waiting
    for the ClientHello; with nothing sent yet, a handshake step returns at
    once asking to read (the descriptor does not block)."""
    var cfg = _server_config()
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = _reactor()
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var c = _connect(l.local_port())
    _poll(l.fd())
    assert_equal(accept_one_and_register_tls(l, r, conns, fd_to_idx, cfg), 1)
    assert_equal(conns.len(), 1)
    assert_equal(fd_to_idx[Int(conns[0].fd())], 0)
    assert_true(conns[0].is_tls())
    assert_equal(conns[0].state(), CONN_STATE_TLS_HANDSHAKE_IN)
    assert_equal(conns[0].interest_set(), INTEREST_READ)
    assert_equal(conns[0].registration().fd(), conns[0].fd())
    var hs = drive_tls_handshake(conns[0])
    assert_equal(hs[0], TLS_OUTCOME_BLOCKED_ON_READ)
    assert_equal(hs[1], INTEREST_READ)
    assert_equal(hs[2], CONN_STATE_TLS_HANDSHAKE_IN)
    assert_equal(accept_one_and_register_tls(l, r, conns, fd_to_idx, cfg), 0)
    _ = conns^
    _close(c)
    _ = r^
    _ = l^


def test_accept_listener_error_ends_the_drain() raises:
    """accept(2) on a socket that is not listening fails (EINVAL): the drain
    stops with nothing registered."""
    var cfg = _server_config()
    var s = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    var l = TcpListener(s)
    var r = _reactor()
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    assert_equal(accept_one_and_register_tls(l, r, conns, fd_to_idx, cfg), 0)
    assert_equal(conns.len(), 0)
    assert_equal(len(fd_to_idx), 0)
    _ = r^
    _ = l^


def test_accept_stale_mapping_is_swept() raises:
    """The table still maps a descriptor number that was closed behind its
    back, and the kernel hands that number out again: the sweep removes the
    stale entry without closing the number, and the new connection is
    accepted, wrapped in TLS and open (komira-ai/komira#936: the sweep
    closed it, so setting it non-blocking failed and it was dropped)."""
    var cfg = _server_config()
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = _reactor(mock=True)
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var c = _connect(l.local_port())
    _poll(l.fd())
    # The lowest free descriptor number, which accept(2) must use next.
    var stale = external_call["dup", Int32](c)
    _close(stale)
    conns.append(
        ConnEntry(
            stream=TcpStream(stale),
            reg=RegistrationHandle(_fd=stale, _interest_set=INTEREST_READ),
        )
    )
    fd_to_idx[Int(stale)] = 0
    assert_equal(accept_one_and_register_tls(l, r, conns, fd_to_idx, cfg), 1)
    assert_equal(conns.len(), 1)
    assert_equal(len(fd_to_idx), 1)
    assert_equal(conns[0].fd(), stale)
    assert_true(conns[0].is_tls())
    assert_equal(conns[0].state(), CONN_STATE_TLS_HANDSHAKE_IN)
    assert_equal(fd_to_idx[Int(stale)], 0)
    assert_false(_eof(c))
    _ = conns^
    _close(c)
    _ = r^
    _ = l^


def test_accept_stale_mapping_to_an_orphan_slot_removes_it() raises:
    """The table maps the reused descriptor number to a slot that holds a
    different descriptor no mapping reaches (-1 here): the sweep removes
    that slot too, and the new connection is wrapped in TLS, registered,
    mapped and open (komira-ai/komira#947: the slot stayed)."""
    var cfg = _server_config()
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = _reactor(mock=True)
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var c = _connect(l.local_port())
    _poll(l.fd())
    var next = external_call["dup", Int32](c)
    _close(next)
    conns.append(
        ConnEntry(
            stream=TcpStream(Int32(-1)),
            reg=RegistrationHandle(_fd=Int32(-1), _interest_set=INTEREST_READ),
        )
    )
    fd_to_idx[Int(next)] = 0
    assert_equal(accept_one_and_register_tls(l, r, conns, fd_to_idx, cfg), 1)
    assert_equal(conns.len(), 1)
    assert_equal(conns[0].fd(), next)
    assert_true(conns[0].is_tls())
    assert_equal(conns[0].state(), CONN_STATE_TLS_HANDSHAKE_IN)
    assert_equal(len(fd_to_idx), 1)
    assert_equal(fd_to_idx[Int(next)], 0)
    assert_false(_eof(c))
    _ = conns^
    _close(c)
    _ = r^
    _ = l^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
