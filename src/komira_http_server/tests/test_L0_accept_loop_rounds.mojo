# =============================================================================
# test_L0_accept_loop_rounds.mojo: the plaintext half of accept_loop.mojo
# =============================================================================
#
# `serve_read_round` and `serve_read_round_chained` run against the server
# end of an AF_UNIX socketpair in this process (no network): a byte written
# on one end is readable on the other when the write returns, so every round
# sees exactly what the peer sent before it and no test waits on a clock.
# Every round test runs both variants: the canned-bytes one and the one that
# answers through an empty `MiddlewareChain`.
#
# A blocked write is made by filling the server's send side until the kernel
# answers EAGAIN (the send buffer is pinned small first, so the fill is
# short); the peer reads the filler back before it reads a response. A write
# error is made by shutting the server's write side, so `send` fails with
# EPIPE.
#
# The accept tests use a real loopback listener; a test waits for a
# connection with poll(2) and no timeout, which returns as soon as the
# kernel has queued it.
#
# Groups (and the defect each would catch):
#   R  a round: a request not answered, answered twice, a pipelined request
#      skipped or read from the wrong offset, a connection kept after
#      `Connection: close`, an incomplete head or request kept waiting, a
#      malformed request answered with anything but its static error, an
#      expectation answered wrong for either setting, end of stream or a
#      reset not closing.
#   B  a blocked write: the unsent response lost, or not parked with the
#      connection waiting for writable; a resume losing it, finishing early,
#      or not returning the connection to reading.
#   E  a write error: a failed write counted as sent, or the connection kept.
#   C  close_and_remove: an index out of range touching the table, the moved
#      tail's mapping not patched, the wrong descriptor closed.
#   A  accept: a connection not registered or mapped to the wrong slot, a
#      listener error not ending the drain.
#   D  count_complete_requests: a terminator counted from a partial match,
#      or one counted twice.
# =============================================================================

from std.collections.dict import Dict
from std.ffi import external_call
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
from komira_http_core.codec.types import HttpResponse, serialize_response
from komira_http_server.accept_loop import (
    accept_one_and_register,
    close_and_remove,
    count_complete_requests,
    resume_pending_write,
    serve_read_round,
    serve_read_round_chained,
)
from komira_http_server.connection import (
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
    RESP_BUF_CAP,
)
from komira_http_server.middleware.chain import MiddlewareChain


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


# -----------------------------------------------------------------------------
# Sockets.
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
    """Shut `fd`'s write side: the next send on it fails with EPIPE."""
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


def _send(fd: Int32, s: String) raises:
    """Write all of `s`; the (empty) socket must take it in one go."""
    var b = _bytes(s)
    var r = try_io_write(fd, Span(b))
    if not r.is_ready() or Int(r.value()) != len(b):
        raise Error("the peer could not send its request")


def _fill(fd: Int32) raises -> Int:
    """Write filler from `fd` until the kernel answers EAGAIN; returns the
    filler's length."""
    var junk = List[UInt8](length=512, fill=UInt8(0x2E))
    var total = 0
    while True:
        var r = try_io_write(fd, Span(junk))
        if r.is_would_block():
            return total
        if not r.is_ready():
            raise Error("the fill failed")
        total += Int(r.value())


struct _Got(Movable):
    var data: List[UInt8]
    var eof: Bool

    def __init__(out self):
        self.data = List[UInt8]()
        self.eof = False


def _read_all(fd: Int32) raises -> _Got:
    """Read everything queued on `fd`, and whether the other end has closed."""
    var got = _Got()
    var buf = List[UInt8](length=8192, fill=UInt8(0))
    while True:
        var r = try_io_read(fd, Span(buf))
        if r.is_would_block():
            return got^
        if not r.is_ready():
            raise Error("the peer's read failed")
        var n = Int(r.value())
        if n == 0:
            got.eof = True
            return got^
        for i in range(n):
            got.data.append(buf[i])


def _after(got: _Got, skip: Int) -> String:
    """What `got` holds after its first `skip` bytes (the filler)."""
    var out = List[UInt8]()
    for i in range(skip, len(got.data)):
        out.append(got.data[i])
    return _text(out)


def _error_bytes(status: Int) -> String:
    var b = List[UInt8]()
    build_error_response_bytes(UInt16(status), b)
    return _text(b)


def _chained_ok() -> String:
    var b = List[UInt8]()
    serialize_response(HttpResponse.ok(String("Hello, World!")), b)
    return _text(b)


# -----------------------------------------------------------------------------
# The rig: the server's ConnEntry and the peer's descriptor.
# -----------------------------------------------------------------------------


struct _Rig(Movable):
    var entry: ConnEntry
    var peer: Int32
    var io: Array[UInt8, REQ_BUF_BYTES]
    var resp: Array[UInt8, RESP_BUF_CAP]
    var resp_len: Int
    var chain: MiddlewareChain
    var chained: Bool
    var continue_ok: Bool
    var reqs: Int64
    var sent: Int64

    def __init__(out self, chained: Bool) raises:
        var fds = _socketpair()
        self.entry = ConnEntry(
            stream=TcpStream(fds[0]),
            reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
        )
        self.peer = fds[1]
        self.io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self.resp = Array[UInt8, RESP_BUF_CAP](fill=UInt8(0))
        var c = String(CANNED).as_bytes()
        for i in range(len(c)):
            self.resp[i] = c[i]
        self.resp_len = len(c)
        self.chain = MiddlewareChain()
        self.chained = chained
        self.continue_ok = True
        self.reqs = Int64(0)
        self.sent = Int64(0)

    def __deinit__(deinit self):
        _close(self.peer)

    def fd(self) -> Int32:
        return self.entry.fd()

    def read(mut self) raises -> _Got:
        """Everything the server has written so far. A method, so the rig
        (and the peer it closes when dropped) lives through the read."""
        return _read_all(self.peer)

    def round(mut self) -> Bool:
        if self.chained:
            return serve_read_round_chained(
                self.entry,
                self.io,
                ParseLimits.defaults(),
                self.continue_ok,
                self.chain,
                self.reqs,
                self.sent,
            )
        return serve_read_round(
            self.entry,
            self.io,
            self.resp,
            self.resp_len,
            ParseLimits.defaults(),
            self.continue_ok,
            self.reqs,
            self.sent,
        )

    def ok(self) -> String:
        """The success response this variant writes."""
        if self.chained:
            return _chained_ok()
        return String(CANNED)

    def pending(self) -> String:
        var out = List[UInt8]()
        var v = self.entry.pending_view()
        for i in range(self.entry.pending_len()):
            out.append(v[i])
        return _text(out)

    def fill(mut self) raises -> Int:
        _set_sndbuf(self.fd(), 4096)
        return _fill(self.fd())


# -----------------------------------------------------------------------------
# R: one round.
# -----------------------------------------------------------------------------


def test_nothing_to_read_keeps_the_connection() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(0))
        assert_equal(rig.sent, Int64(0))
        assert_equal(len(rig.read().data), 0)


def test_one_request_one_response() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, GET)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(rig.sent, Int64(rig.ok().byte_length()))
        assert_equal(rig.entry.state(), CONN_STATE_READING)
        var got = rig.read()
        assert_equal(_text(got.data), rig.ok())
        assert_false(got.eof)


def test_pipelined_requests_each_answered_in_order() raises:
    """Three requests in one read, the middle one with a body: each is
    answered once, in order."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(
            rig.peer,
            String(GET)
            + "POST /p HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello"
            + GET,
        )
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(3))
        assert_equal(rig.sent, Int64(3 * rig.ok().byte_length()))
        assert_equal(_text(rig.read().data), rig.ok() + rig.ok() + rig.ok())


def test_request_rest_in_a_later_read_closes_after_the_response() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(
            rig.peer,
            "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 10\r\n\r\nhello",
        )
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok())


def test_connection_close_ends_the_round() raises:
    """A request after `Connection: close` in the same read is not answered."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(
            rig.peer,
            String("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
            + GET,
        )
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok())


def test_http10_request_closes_after_its_response() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, "GET / HTTP/1.0\r\n\r\n")
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok())


def test_incomplete_head_closes_without_a_response() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, "GET / HTTP/1.1\r\nHost: exa")
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(0))
        assert_equal(rig.sent, Int64(0))
        assert_equal(len(rig.read().data), 0)


def test_incomplete_second_request_closes_after_the_first() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, String(GET) + "GET / HTTP/1.1\r\n")
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok())


def test_malformed_request_gets_400_and_close() raises:
    """The request after the malformed one is not answered."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, String(BAD_NAME) + GET)
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(0))
        var want = _error_bytes(400)
        assert_true(want.startswith("HTTP/1.1 400 Bad Request\r\n"))
        assert_equal(rig.sent, Int64(want.byte_length()))
        assert_equal(_text(rig.read().data), want)


def test_expect_continue_enabled_sends_interim_then_response() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, EXPECT)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(rig.sent, Int64(String(CONTINUE).byte_length() + rig.ok().byte_length()))
        assert_equal(_text(rig.read().data), String(CONTINUE) + rig.ok())


def test_expect_continue_disabled_gets_417_and_close() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        rig.continue_ok = False
        _send(rig.peer, EXPECT)
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(0))
        var want = _error_bytes(417)
        assert_true(want.startswith("HTTP/1.1 417 "))
        assert_equal(rig.sent, Int64(want.byte_length()))
        assert_equal(_text(rig.read().data), want)


def test_end_of_stream_closes() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _shut_wr(rig.peer)
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(0))


def test_reset_peer_closes() raises:
    """The peer leaves a byte unread and closes. Closing an AF_UNIX socket
    with unread data resets the other end on linux, so the server's read
    fails; where the close reads as end of stream instead, the answer is
    the same."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        var one = _bytes("x")
        _ = try_io_write(rig.fd(), Span(one))
        _close(rig.peer)
        rig.peer = Int32(-1)
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(0))


# -----------------------------------------------------------------------------
# B: a blocked write parks the unsent bytes; resume_pending_write drains them.
# -----------------------------------------------------------------------------


def test_blocked_response_parks_and_resumes() raises:
    """A response that blocks is parked whole, survives a resume that blocks
    again, and reaches the peer in full once it reads; the connection then
    answers the next request."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        var filler = rig.fill()
        _send(rig.peer, GET)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(rig.sent, Int64(0))
        assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
        assert_equal(rig.entry.pending_off(), 0)
        assert_equal(rig.pending(), rig.ok())
        # Still full: nothing moves.
        assert_false(resume_pending_write(rig.entry, rig.sent))
        assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
        assert_equal(rig.entry.pending_len(), rig.ok().byte_length())
        assert_equal(rig.entry.pending_off(), 0)
        assert_equal(rig.sent, Int64(0))
        # The peer reads the filler; the resume drains the rest.
        var head = rig.read()
        assert_equal(len(head.data), filler)
        assert_true(resume_pending_write(rig.entry, rig.sent))
        assert_equal(rig.entry.state(), CONN_STATE_READING)
        assert_equal(rig.entry.pending_len(), 0)
        assert_equal(rig.entry.pending_off(), 0)
        assert_equal(rig.sent, Int64(rig.ok().byte_length()))
        assert_equal(_text(rig.read().data), rig.ok())
        # Back to reading: the next request is answered at once.
        _send(rig.peer, GET)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(_text(rig.read().data), rig.ok())


def test_blocked_error_response_is_parked() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        var filler = rig.fill()
        _send(rig.peer, BAD_NAME)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(0))
        assert_equal(rig.sent, Int64(0))
        assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
        assert_equal(rig.pending(), _error_bytes(400))
        assert_equal(len(rig.read().data), filler)
        assert_true(resume_pending_write(rig.entry, rig.sent))
        assert_equal(_text(rig.read().data), _error_bytes(400))


def test_blocked_417_is_parked() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        rig.continue_ok = False
        _ = rig.fill()
        _send(rig.peer, EXPECT)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(0))
        assert_equal(rig.sent, Int64(0))
        assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
        assert_equal(rig.pending(), _error_bytes(417))


def test_blocked_interim_is_parked_and_ends_the_round() raises:
    """The interim response is parked and the round ends there: the request
    is not answered in this round."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _ = rig.fill()
        _send(rig.peer, EXPECT)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(0))
        assert_equal(rig.sent, Int64(0))
        assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
        assert_equal(rig.pending(), String(CONTINUE))


def test_expect_continue_then_pipelined_request() raises:
    """The interim response, the response, then the next request's response,
    in that order, and the round carries on past the expectation."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _send(rig.peer, String(EXPECT) + GET)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(
            _text(rig.read().data),
            String(CONTINUE) + rig.ok() + rig.ok(),
        )


# -----------------------------------------------------------------------------
# E: a failed write closes and counts nothing.
# -----------------------------------------------------------------------------


def test_write_error_on_each_response_closes() raises:
    """With the server's write side shut, every response kind fails to
    send: the round closes and neither counter moves."""
    for v in range(2):
        for k in range(4):
            var rig = _Rig(chained=v == 1)
            _shut_wr(rig.fd())
            if k == 0:
                _send(rig.peer, GET)
            elif k == 1:
                _send(rig.peer, BAD_NAME)
            elif k == 2:
                rig.continue_ok = False
                _send(rig.peer, EXPECT)
            else:
                _send(rig.peer, EXPECT)
            assert_false(rig.round())
            assert_equal(rig.reqs, Int64(0))
            assert_equal(rig.sent, Int64(0))
            var got = rig.read()
            assert_equal(len(got.data), 0)
            assert_true(got.eof)


def test_resume_write_error_marks_the_entry() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        _ = rig.fill()
        _send(rig.peer, GET)
        assert_true(rig.round())
        _shut_wr(rig.fd())
        assert_false(resume_pending_write(rig.entry, rig.sent))
        assert_equal(rig.entry.pending_len(), -1)
        assert_equal(rig.sent, Int64(0))


# -----------------------------------------------------------------------------
# C: close_and_remove.
# -----------------------------------------------------------------------------


struct _Table(Movable):
    """`n` connections in a slab, each mapped by its descriptor, with the
    peers kept to watch which one is closed."""

    var conns: Slab[ConnEntry]
    var fd_to_idx: Dict[Int, Int]
    var peers: List[Int32]

    def __init__(out self, n: Int) raises:
        self.conns = Slab[ConnEntry]()
        self.fd_to_idx = Dict[Int, Int]()
        self.peers = List[Int32]()
        for i in range(n):
            var fds = _socketpair()
            self.conns.append(
                ConnEntry(
                    stream=TcpStream(fds[0]),
                    reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
                )
            )
            self.fd_to_idx[Int(fds[0])] = i
            self.peers.append(fds[1])

    def __deinit__(deinit self):
        for i in range(len(self.peers)):
            _close(self.peers[i])

    def closed(self, i: Int) raises -> Bool:
        """Whether the server end of peer `i` is closed."""
        return _read_all(self.peers[i]).eof


def test_close_and_remove_out_of_range_is_a_no_op() raises:
    var t = _Table(2)
    # Indices taken from a list, so no inlined copy sees a constant.
    var bad: List[Int] = [-1, t.conns.len()]
    for i in range(len(bad)):
        close_and_remove(t.conns, t.fd_to_idx, bad[i])
    assert_equal(t.conns.len(), 2)
    assert_equal(len(t.fd_to_idx), 2)
    assert_false(t.closed(0))
    assert_false(t.closed(1))


def test_close_and_remove_middle_moves_the_tail() raises:
    var t = _Table(3)
    var fd0 = Int(t.conns[0].fd())
    var fd1 = Int(t.conns[1].fd())
    var fd2 = Int(t.conns[2].fd())
    close_and_remove(t.conns, t.fd_to_idx, 1)
    assert_equal(t.conns.len(), 2)
    assert_equal(len(t.fd_to_idx), 2)
    assert_false(fd1 in t.fd_to_idx)
    assert_equal(t.fd_to_idx[fd0], 0)
    assert_equal(t.fd_to_idx[fd2], 1)
    assert_equal(Int(t.conns[1].fd()), fd2)
    assert_false(t.closed(0))
    assert_true(t.closed(1))
    assert_false(t.closed(2))


def test_close_and_remove_tail() raises:
    var t = _Table(2)
    var fd0 = Int(t.conns[0].fd())
    var fd1 = Int(t.conns[1].fd())
    close_and_remove(t.conns, t.fd_to_idx, 1)
    assert_equal(t.conns.len(), 1)
    assert_false(fd1 in t.fd_to_idx)
    assert_equal(t.fd_to_idx[fd0], 0)
    assert_false(t.closed(0))
    assert_true(t.closed(1))


# -----------------------------------------------------------------------------
# A: accept_one_and_register.
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


def _poll(fds: List[Int32]) raises -> List[Bool]:
    """Wait, without a timeout, until one of `fds` is readable; returns
    which ones are."""
    var pfd = List[Int32](length=2 * len(fds), fill=Int32(0))
    for i in range(len(fds)):
        pfd[2 * i] = fds[i]
        pfd[2 * i + 1] = Int32(1)  # events = POLLIN, revents = 0
    # SAFETY: `pfd` holds `len(fds)` struct pollfd {int; short; short} and
    # outlives the call; poll(2) writes only their revents.
    var rc = external_call["poll", Int32](
        pfd.unsafe_ptr(), UInt64(len(fds)), Int32(-1)
    )
    if rc < 0:
        raise Error("poll() failed")
    var out = List[Bool]()
    for i in range(len(fds)):
        out.append((pfd[2 * i + 1] >> 16) != 0)
    return out^


def test_accept_registers_each_connection_in_order() raises:
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = _reactor()
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var c1 = _connect(l.local_port())
    var c2 = _connect(l.local_port())
    var total = 0
    while total < 2:
        _ = _poll([l.fd()])
        var n = accept_one_and_register(l, r, conns, fd_to_idx)
        assert_true(n >= 1)
        total += n
    assert_equal(total, 2)
    assert_equal(conns.len(), 2)
    for i in range(2):
        assert_equal(fd_to_idx[Int(conns[i].fd())], i)
        assert_equal(conns[i].state(), CONN_STATE_READING)
        assert_equal(conns[i].interest_set(), INTEREST_READ)
        assert_equal(conns[i].registration().fd(), conns[i].fd())
        assert_false(conns[i].is_tls())
    # The accept queue is first in, first out: closing the first client
    # makes only slot 0 readable (end of stream).
    _close(c1)
    var ready = _poll([conns[0].fd(), conns[1].fd()])
    assert_true(ready[0])
    assert_false(ready[1])
    # Nothing left to accept.
    assert_equal(accept_one_and_register(l, r, conns, fd_to_idx), 0)
    _ = conns^
    _close(c2)
    _ = r^
    _ = l^


def test_accept_listener_error_ends_the_drain() raises:
    """accept(2) on a socket that is not listening fails (EINVAL): the drain
    stops with nothing registered."""
    var s = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    var l = TcpListener(s)
    var r = _reactor()
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    assert_equal(accept_one_and_register(l, r, conns, fd_to_idx), 0)
    assert_equal(conns.len(), 0)
    assert_equal(len(fd_to_idx), 0)
    _ = r^
    _ = l^


def test_accept_stale_mapping_is_swept() raises:
    """The table still maps a descriptor number that was closed behind its
    back, and the kernel hands that number out again: the sweep removes the
    stale entry, and the new connection takes its place in the table.
    Whether the new descriptor survives the sweep is tracked in
    komira-ai/komira#936, so this test does not look at it."""
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = _reactor(mock=True)
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var c = _connect(l.local_port())
    _ = _poll([l.fd()])
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
    assert_equal(accept_one_and_register(l, r, conns, fd_to_idx), 1)
    assert_equal(conns.len(), 1)
    assert_equal(len(fd_to_idx), 1)
    assert_equal(conns[0].fd(), stale)
    assert_equal(fd_to_idx[Int(stale)], 0)
    _ = conns^
    _close(c)
    _ = r^
    _ = l^


def test_accept_stale_mapping_to_another_slot_is_survived() raises:
    """The table maps the reused descriptor number to a slot that holds a
    different (unmapped) descriptor, so removing that slot fails. The
    failure is swallowed, the slot is left alone, and the new connection is
    registered, mapped and open."""
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = _reactor(mock=True)
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var c = _connect(l.local_port())
    _ = _poll([l.fd()])
    var next = external_call["dup", Int32](c)
    _close(next)
    conns.append(
        ConnEntry(
            stream=TcpStream(Int32(-1)),
            reg=RegistrationHandle(_fd=Int32(-1), _interest_set=INTEREST_READ),
        )
    )
    fd_to_idx[Int(next)] = 0
    assert_equal(accept_one_and_register(l, r, conns, fd_to_idx), 1)
    assert_equal(conns.len(), 2)
    assert_equal(conns[0].fd(), Int32(-1))
    assert_equal(conns[1].fd(), next)
    assert_equal(len(fd_to_idx), 1)
    assert_equal(fd_to_idx[Int(next)], 1)
    var got = _read_all(c)
    assert_false(got.eof)
    assert_equal(len(got.data), 0)
    _ = conns^
    _close(c)
    _ = r^
    _ = l^


# -----------------------------------------------------------------------------
# D: count_complete_requests.
# -----------------------------------------------------------------------------


def _count(s: String) -> Int:
    var buf = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
    var b = s.as_bytes()
    for i in range(len(b)):
        buf[i] = b[i]
    return count_complete_requests(buf, len(b))


def test_count_partial_terminators_do_not_count() raises:
    """A CR, CRLF and CRLF CR each followed by the wrong byte are not a
    terminator; only the full CRLF CRLF at the end is."""
    assert_equal(_count("x\ry\r\nz\r\n\rw\r\n\r\n"), 1)


def test_count_overlapping_terminator_counts_once() raises:
    """CRLF CRLF CRLF holds one terminator: the scan resumes after it."""
    assert_equal(_count("\r\n\r\n\r\n"), 1)
    assert_equal(_count("\r\n\r\n\r\n\r\n"), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
