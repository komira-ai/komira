# =============================================================================
# test_L0_dispatch_parked_tail.mojo: what a dispatch round owes after a park
# =============================================================================
#
# A dispatch round whose response write blocks parks the unsent bytes and
# ends; the server resumes the write on writable and, once it drains, runs
# the next round. These tests pin what must survive that gap in the two
# pipelining dispatch rounds (komira-ai/komira#1285):
#
#   P  the requests read behind the parked response are answered after the
#      resume, in order, once each (they were consumed and dropped: a client
#      that pipelined them waited forever);
#   H  a partial head read behind the parked response is kept and completed
#      by the next read (it was dropped, so the rest of the head arrived
#      alone and was answered 400);
#   C  `Connection: close` is honoured across the park: on the parked
#      response itself (the resume closes the connection) and on a carried
#      request (the round after the resume answers it and closes);
#   I  a parked 100 Continue keeps its request and the requests behind it
#      (the round returned before dispatching anything);
#   B  a chunked body read from the socket is not carried as a request.
#
# Rig: the server end of an AF_UNIX socketpair whose send side is filled to
# EAGAIN so the next write parks; the peer then reads the filler back. Both
# rounds run against a dispatcher that answers 200 with the request path, so
# a test sees which request each response answers:
#   0 serve_read_round_dispatch
#   1 serve_read_round_dispatch_chained   (behind a no-op middleware)
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
from komira_http_core.codec.types import (
    HttpRequest,
    HttpResponse,
    serialize_response,
)
from komira_http_server.accept_loop import resume_pending_write
from komira_http_server.connection import (
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
)
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    RequestDispatcher,
    serve_read_round_dispatch,
    serve_read_round_dispatch_chained,
)
from komira_http_server.middleware import (
    Middleware,
    MiddlewareChain,
    RequestContext,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime VARIANTS = 2
comptime CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n"


def _get(path: String) -> String:
    return String("GET ") + path + " HTTP/1.1\r\nHost: example.com\r\n\r\n"


def _get_close(path: String) -> String:
    return (
        String("GET ")
        + path
        + " HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
    )


def _post(path: String) -> String:
    """A POST whose 5-byte body is in the same read."""
    return (
        String("POST ")
        + path
        + " HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello"
    )


# -----------------------------------------------------------------------------
# The dispatcher answers 200 with the request path; the middleware passes.
# -----------------------------------------------------------------------------


struct _PathDispatcher(CtxRequestDispatcher, Movable, RequestDispatcher):
    def __init__(out self):
        pass

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        return HttpResponse.ok(String(req.path))

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        return HttpResponse.ok(String(req.path))


struct _PassMiddleware(Deinitable, Middleware, Movable):
    def __init__(out self):
        pass

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


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


def _read_all(fd: Int32) raises -> String:
    """Everything queued on `fd`."""
    var got = List[UInt8]()
    var buf = List[UInt8](length=8192, fill=UInt8(0))
    while True:
        var r = try_io_read(fd, Span(buf))
        if r.is_would_block():
            return _text(got)
        if not r.is_ready():
            raise Error("the peer's read failed")
        var n = Int(r.value())
        if n == 0:
            return _text(got)
        for i in range(n):
            got.append(buf[i])


def _ok(path: String) -> String:
    """Both rounds' answer to a request for `path`."""
    var b = List[UInt8]()
    serialize_response(HttpResponse.ok(path), b)
    return _text(b)


# -----------------------------------------------------------------------------
# The rig: the server's ConnEntry, the peer's descriptor, the round's args.
# -----------------------------------------------------------------------------


struct _Rig(Movable):
    var variant: Int
    var entry: ConnEntry
    var peer: Int32
    var io: Array[UInt8, REQ_BUF_BYTES]
    var reactor: Reactor[NoopSink]
    var chain: MiddlewareChain
    var mw: _PassMiddleware
    var disp: _PathDispatcher
    var reqs: Int64
    var sent: Int64

    def __init__(out self, variant: Int) raises:
        var fds = _socketpair()
        self.variant = variant
        self.entry = ConnEntry(
            stream=TcpStream(fds[0]),
            reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
        )
        self.peer = fds[1]
        self.io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
        self.reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK
        )
        self.chain = MiddlewareChain()
        self.mw = _PassMiddleware()
        self.disp = _PathDispatcher()
        self.reqs = Int64(0)
        self.sent = Int64(0)
        _set_sndbuf(self.entry.fd(), 4096)

    def __deinit__(deinit self):
        if self.peer >= 0:
            _ = external_call["close", Int32](self.peer)

    def read(mut self) raises -> String:
        """Everything the server has written since the last read."""
        return _read_all(self.peer)

    def round(mut self) -> Bool:
        var limits = ParseLimits.defaults()
        if self.variant == 0:
            return serve_read_round_dispatch[_PathDispatcher, _Rt](
                self.entry,
                self.reactor,
                self.io,
                limits,
                True,
                self.disp,
                self.reqs,
                self.sent,
                String(""),
            )
        return serve_read_round_dispatch_chained[
            _PathDispatcher, _PassMiddleware, _Rt
        ](
            self.entry,
            self.reactor,
            self.io,
            limits,
            True,
            self.chain,
            self.mw,
            self.disp,
            self.reqs,
            self.sent,
        )

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
# P: the requests behind a parked response are answered after the resume.
# -----------------------------------------------------------------------------


def test_pipelined_gets_behind_a_parked_response_are_answered_in_order() raises:
    """GET /a parks; GET /b and GET /c, read in the same round, are answered
    by the round after the resume, in order. A request sent afterwards is
    answered once: nothing carried is answered twice."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        assert_true(rig.park(_get("/a") + _get("/b") + _get("/c")))
        assert_equal(rig.reqs, Int64(1))
        assert_true(rig.resume())
        assert_equal(rig.entry.state(), CONN_STATE_READING)
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(3))
        assert_equal(rig.read(), _ok("/a") + _ok("/b") + _ok("/c"))
        _send(rig.peer, _get("/d"))
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(4))
        assert_equal(rig.read(), _ok("/d"))


def test_request_behind_a_parked_post_starts_after_its_body() raises:
    """The parked response answers a POST whose body is in the buffer: the
    carry starts after the body, so GET /b is answered and the body bytes
    are not parsed as a request (that would answer 400)."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        assert_true(rig.park(_post("/a") + _get("/b")))
        assert_true(rig.resume())
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(rig.read(), _ok("/a") + _ok("/b"))


# -----------------------------------------------------------------------------
# H: a partial head behind a parked response is kept.
# -----------------------------------------------------------------------------


def test_partial_head_behind_a_parked_response_is_completed() raises:
    """GET /a parks with the start of GET /b's head behind it. The round
    after the resume keeps the start and waits; the rest of the head
    completes it and /b is answered."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        assert_true(rig.park(_get("/a") + "GET /b HTTP/1.1\r\nHo"))
        assert_true(rig.resume())
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(rig.read(), _ok("/a"))
        _send(rig.peer, "st: example.com\r\n\r\n")
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(rig.read(), _ok("/b"))


# -----------------------------------------------------------------------------
# C: `Connection: close` across the park.
# -----------------------------------------------------------------------------


def test_connection_close_behind_a_parked_response_closes() raises:
    """GET /a parks; the carried GET /b says `Connection: close`. The round
    after the resume answers /b and closes, and GET /c is never answered."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        assert_true(rig.park(_get("/a") + _get_close("/b") + _get("/c")))
        assert_true(rig.resume())
        assert_false(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(rig.read(), _ok("/a") + _ok("/b"))


def test_parked_response_to_connection_close_closes() raises:
    """The parked response is the connection's last: the resume drains it
    and asks the caller to close (False, pending_len -1) instead of
    returning to reading the GET behind it."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        assert_true(rig.park(_get_close("/a") + _get("/b")))
        assert_equal(rig.reqs, Int64(1))
        assert_false(rig.resume())
        assert_equal(rig.entry.pending_len(), -1)
        assert_equal(rig.read(), _ok("/a"))


# -----------------------------------------------------------------------------
# I: a parked interim keeps its request and the next.
# -----------------------------------------------------------------------------


def test_parked_interim_keeps_its_request_and_the_next() raises:
    """The 100 Continue parks: the request is still dispatched and its
    response queued behind the interim, and GET /b is answered after the
    resume. Before, the round returned at the parked interim and neither
    request was ever answered."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        var expect = String(
            "POST /a HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
            "Content-Length: 5\r\n\r\nhello"
        )
        assert_true(rig.park(expect + _get("/b")))
        assert_equal(rig.reqs, Int64(1))
        assert_true(rig.resume())
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(rig.read(), String(CONTINUE) + _ok("/a") + _ok("/b"))


# -----------------------------------------------------------------------------
# B: a chunked body is consumed, not carried.
# -----------------------------------------------------------------------------


def test_chunked_body_behind_a_parked_response_is_not_carried() raises:
    """The parked response answers a chunked POST: its body was decoded
    from the buffer, so nothing is carried and the round after the resume
    answers nothing (carrying the chunk bytes would answer them 400)."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        var chunked = String(
            "POST /a HTTP/1.1\r\nHost: example.com\r\n"
            "Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        )
        assert_true(rig.park(chunked))
        assert_true(rig.resume())
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(rig.read(), _ok("/a"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
