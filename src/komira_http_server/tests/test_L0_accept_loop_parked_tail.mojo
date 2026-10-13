# =============================================================================
# test_L0_accept_loop_parked_tail.mojo: what a round owes after a parked write
# =============================================================================
#
# A round whose write blocks parks the unsent bytes and ends; the server
# resumes the write on writable and, once it drains, runs the next round.
# These tests pin what must survive that gap (komira-ai/komira#1285):
#
#   P  the requests the round had read behind the parked one are answered
#      after the resume, in order (they were consumed and dropped: a client
#      that pipelined them waited forever);
#   K  a parked response that is the connection's last (`Connection: close`,
#      a body not all in the buffer, a 400 or a 417) closes the connection
#      when it drains (the resume returned it to reading).
#
# Same rig as test_L0_accept_loop_rounds.mojo: the server end of an AF_UNIX
# socketpair, a write blocked by filling the server's send side to EAGAIN,
# both round variants (canned bytes and an empty `MiddlewareChain`). The
# last test drives `serve_read_round_dispatch`, which parks its error
# responses through the same helper.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    RegistrationHandle,
)
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.reactor.socket_io import try_io_read, try_io_write
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.tcp_stream import TcpStream
from komira_http_core.codec.h1.limits import ParseLimits
from komira_http_core.codec.h1.parser import build_error_response_bytes
from komira_http_core.codec.types import (
    HttpRequest,
    HttpResponse,
    serialize_response,
)
from komira_http_server.accept_loop import (
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
from komira_http_server.dispatch import (
    RequestDispatcher,
    serve_read_round_dispatch,
)
from komira_http_server.middleware.chain import MiddlewareChain


comptime CANNED = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
comptime GET = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
comptime GET_CLOSE = (
    "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
)
# Declares 10 body bytes and sends 5: the rest is not in the buffer.
comptime SHORT_BODY = (
    "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 10\r\n\r\nhello"
)
comptime CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n"
comptime BAD_NAME = "GET / HTTP/1.1\r\nHost: example.com\r\nAccept : */*\r\n\r\n"
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
    """Shrink `fd`'s send buffer so a fill to EAGAIN takes a few writes."""
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


def _text(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _send(fd: Int32, s: String) raises:
    """Write all of `s`; the (empty) socket must take it in one go."""
    var b = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        b.append(src[i])
    var r = try_io_write(fd, Span(b))
    if not r.is_ready() or Int(r.value()) != len(b):
        raise Error("the peer could not send its request")


def _fill(fd: Int32) raises -> Int:
    """Write filler from `fd` until the kernel answers EAGAIN; its length."""
    var junk = List[UInt8](length=512, fill=UInt8(0x2E))
    var total = 0
    while True:
        var r = try_io_write(fd, Span(junk))
        if r.is_would_block():
            return total
        if not r.is_ready():
            raise Error("the fill failed")
        total += Int(r.value())


def _read_all(fd: Int32) raises -> List[UInt8]:
    """Everything queued on `fd`."""
    var got = List[UInt8]()
    var buf = List[UInt8](length=8192, fill=UInt8(0))
    while True:
        var r = try_io_read(fd, Span(buf))
        if r.is_would_block():
            return got^
        if not r.is_ready():
            raise Error("the peer's read failed")
        var n = Int(r.value())
        if n == 0:
            return got^
        for i in range(n):
            got.append(buf[i])


def _error_bytes(status: Int) -> String:
    var b = List[UInt8]()
    build_error_response_bytes(UInt16(status), b)
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
            reg=RegistrationHandle(_fd=fds[0]),
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
        _set_sndbuf(self.entry.fd(), 4096)

    def __deinit__(deinit self):
        _close(self.peer)

    def read(mut self) raises -> String:
        """Everything the server has written since the last read."""
        return _text(_read_all(self.peer))

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
            var b = List[UInt8]()
            serialize_response(HttpResponse.ok(String("Hello, World!")), b)
            return _text(b)
        return String(CANNED)

    def park(mut self, request: String) raises -> Bool:
        """Fill the server's send side, send `request`, run a round (which
        must park), then let the peer read the filler. The round's result."""
        var filler = _fill(self.entry.fd())
        _send(self.peer, request)
        var alive = self.round()
        if self.entry.state() != CONN_STATE_WAITING_FOR_WRITABLE:
            raise Error("the round did not park a write")
        if self.read().byte_length() != filler:
            raise Error("the peer did not read the filler back")
        return alive

    def resume(mut self) -> Bool:
        return resume_pending_write(self.entry, self.sent)


# -----------------------------------------------------------------------------
# P: the requests behind a parked write are answered after the resume.
# -----------------------------------------------------------------------------


def test_parked_interim_keeps_the_pipelined_request() raises:
    """The interim response parks with its response behind it; the GET read
    in the same round is answered by the round after the resume. Before
    the fix the round after the resume read the empty socket and the GET's
    response never came."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        assert_true(rig.park(String(EXPECT) + GET))
        assert_equal(rig.reqs, Int64(1))
        assert_true(rig.resume())
        assert_equal(rig.entry.state(), CONN_STATE_READING)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(rig.read(), String(CONTINUE) + rig.ok() + rig.ok())


def test_parked_response_keeps_the_pipelined_requests() raises:
    """Three pipelined GETs: the first response parks, and the second parks
    again in the round after the resume. Each round after a resume answers
    from the requests carried over, in order, and nothing is answered
    twice."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        assert_true(rig.park(String(GET) + GET + GET))
        assert_equal(rig.reqs, Int64(1))
        assert_true(rig.resume())
        # Block again: the second request's response parks in turn.
        var filler = _fill(rig.entry.fd())
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
        var head = rig.read()
        assert_equal(head.byte_length(), rig.ok().byte_length() + filler)
        assert_true(head.startswith(rig.ok()))
        assert_true(rig.resume())
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(3))
        assert_equal(rig.read(), rig.ok() + rig.ok())
        # Nothing is left over: the next request is answered once.
        _send(rig.peer, GET)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(4))
        assert_equal(rig.read(), rig.ok())


# -----------------------------------------------------------------------------
# K: a parked last response closes the connection once it drains.
# -----------------------------------------------------------------------------


def _assert_resume_closes(mut rig: _Rig, expect: String) raises:
    """The resume drains `expect` to the peer and asks the caller to close
    (False with the -1 sentinel), instead of returning to reading."""
    assert_false(rig.resume())
    assert_equal(rig.entry.pending_len(), -1)
    assert_equal(rig.read(), expect)


def test_parked_response_to_connection_close_closes() raises:
    """`Connection: close`, with a GET pipelined behind it: the response
    drains, the connection closes, and the GET is never answered."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        assert_true(rig.park(String(GET_CLOSE) + GET))
        assert_equal(rig.reqs, Int64(1))
        _assert_resume_closes(rig, rig.ok())


def test_parked_interim_with_connection_close_closes() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        var req = String(
            "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
            "Connection: close\r\nContent-Length: 5\r\n\r\nhello"
        )
        assert_true(rig.park(req))
        _assert_resume_closes(rig, String(CONTINUE) + rig.ok())


def test_parked_response_to_a_short_body_closes() raises:
    """A body not all in the buffer closes the connection after its
    response when the write goes through at once; parked, the same."""
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        assert_true(rig.park(SHORT_BODY))
        _assert_resume_closes(rig, rig.ok())


def test_parked_400_closes() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        assert_true(rig.park(String(BAD_NAME) + GET))
        assert_equal(rig.reqs, Int64(0))
        _assert_resume_closes(rig, _error_bytes(400))


def test_parked_417_closes() raises:
    for v in range(2):
        var rig = _Rig(chained=v == 1)
        rig.continue_ok = False
        assert_true(rig.park(String(EXPECT) + GET))
        assert_equal(rig.reqs, Int64(0))
        _assert_resume_closes(rig, _error_bytes(417))


# -----------------------------------------------------------------------------
# The dispatch round parks its error responses through the same helper.
# -----------------------------------------------------------------------------


struct _Ok(RequestDispatcher):
    def __init__(out self):
        pass

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        return HttpResponse.ok(String("ok"))


def test_dispatch_round_parked_400_closes() raises:
    var rig = _Rig(chained=False)
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var dispatcher = _Ok()
    var filler = _fill(rig.entry.fd())
    _send(rig.peer, String(BAD_NAME) + GET)
    assert_true(
        serve_read_round_dispatch[_Ok, BlockingRuntime[NoopSink]](
            rig.entry,
            reactor,
            rig.io,
            ParseLimits.defaults(),
            True,
            dispatcher,
            rig.reqs,
            rig.sent,
            String(),
        )
    )
    assert_equal(rig.entry.state(), CONN_STATE_WAITING_FOR_WRITABLE)
    assert_equal(rig.read().byte_length(), filler)
    _assert_resume_closes(rig, _error_bytes(400))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
