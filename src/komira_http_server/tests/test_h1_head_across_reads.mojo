# =============================================================================
# test_h1_head_across_reads.mojo: a request head that arrives in pieces
# =============================================================================
#
# RFC 9112 section 2.2 lets a request arrive in any number of TCP segments: a
# client may write the request line and the header fields in separate sends,
# or a slow link may cut the head anywhere. Every plaintext HTTP/1.1 read
# round must keep the start of an unfinished head on the connection and
# answer the request once the rest arrives (komira-ai/komira#1447). Before
# the fix each round closed the connection unanswered and threw the received
# bytes away.
#
# Each test runs every plaintext round against the server end of an AF_UNIX
# socketpair in this process (no network, no clock): a byte the peer writes
# is readable when the write returns, so a round sees exactly what was sent
# before it. The rounds:
#   0 serve_read_round                    (canned response)
#   1 serve_read_round_chained            (empty MiddlewareChain)
#   2 serve_read_round_dispatch           (a dispatcher answering its path)
#   3 serve_read_round_dispatch_chained   (the same, behind a no-op middleware)
#   4 serve_read_round_suspendable        (a one-step suspendable handler)
#   5 serve_read_round_erased             (the same handler, type-erased)
# The dispatching rounds answer with the request path, so a test also sees
# that the answered request is the one whose pieces were joined. The TLS
# round has the same tests in test_L0_accept_loop_tls.mojo.
#
# The defect each test catches:
#   a head cut in two or three reads closed unanswered, or its pieces joined
#   in the wrong order; a pipelined request whose head ends the read dropped
#   after the one before it is answered; end of stream after a partial head
#   answered or kept; a head that fills the receive buffer (alone, or grown
#   there across reads) kept forever or closed without its 431.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.completion_queue import RegistrationHandle
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.reactor.socket_io import try_io_read, try_io_write
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.shared_erasure import (
    ErasedHandlerDriver,
    ErasedHandlerFrame,
    make_erased_handler_frame,
)
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
    SuspendableHandlerDriver,
    SuspendedFrame,
)
from komira_async.runtime.tcp_stream import TcpStream
from komira_http_core.codec.h1.limits import ParseLimits
from komira_http_core.codec.h1.parser import build_error_response_bytes
from komira_http_core.codec.types import (
    HttpRequest,
    HttpResponse,
    serialize_response,
)
from komira_http_server.accept_loop import (
    serve_read_round,
    serve_read_round_chained,
)
from komira_http_server.connection import (
    ConnEntry,
    REQ_BUF_BYTES,
    RESP_BUF_CAP,
)
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    ErasedDispatcher,
    RequestDispatcher,
    SuspendableDispatcher,
    serve_read_round_dispatch,
    serve_read_round_dispatch_chained,
    serve_read_round_erased,
    serve_read_round_suspendable,
    write_delivered_to_conn,
)
from komira_http_server.middleware import (
    Middleware,
    MiddlewareChain,
    RequestContext,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime CANNED = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
comptime VARIANTS = 6


# -----------------------------------------------------------------------------
# The handlers: each answers 200 with the request path.
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


struct _PathHandler(SuspendableHandler):
    """Finishes in one step with the request path."""

    comptime Resp = HttpResponse
    var path: String

    def __init__(out self, path: String):
        self.path = path

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Self.Resp]:
        return HandlerStepResult[HttpResponse].done(
            HttpResponse.ok(String(self.path))
        )


struct _PathSuspendable(SuspendableDispatcher):
    comptime Handler = _PathHandler

    def __init__(out self):
        pass

    def make_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> SuspendedFrame[Self.Handler]:
        return SuspendedFrame[_PathHandler](
            _PathHandler(String(req.path)), request_id
        )


struct _PathErased(ErasedDispatcher):
    comptime Sink = NoopSink
    comptime Resp = HttpResponse

    def __init__(out self):
        pass

    def make_erased_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> ErasedHandlerFrame[Self.Sink]:
        return make_erased_handler_frame[_PathHandler, NoopSink](
            _PathHandler(String(req.path)), request_id
        )


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
    """Write all of `s`; the socket must take it in one go."""
    var b = _bytes(s)
    var r = try_io_write(fd, Span(b))
    if not r.is_ready() or Int(r.value()) != len(b):
        raise Error("the peer could not send its request")


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


def _ok_text(body: String) -> String:
    var b = List[UInt8]()
    serialize_response(HttpResponse.ok(body), b)
    return _text(b)


def _error_text(status: Int) -> String:
    var b = List[UInt8]()
    build_error_response_bytes(UInt16(status), b)
    return _text(b)


def _pad(n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += "a"
    return s^


# -----------------------------------------------------------------------------
# The rig: one server ConnEntry, its peer, and every round's arguments.
# -----------------------------------------------------------------------------


struct _Rig(Movable):
    var variant: Int
    var entry: ConnEntry
    var peer: Int32
    var io: Array[UInt8, REQ_BUF_BYTES]
    var resp: Array[UInt8, RESP_BUF_CAP]
    var resp_len: Int
    var reactor: Reactor[NoopSink]
    var chain: MiddlewareChain
    var mw: _PassMiddleware
    var disp: _PathDispatcher
    var susp: _PathSuspendable
    var susp_driver: SuspendableHandlerDriver[NoopSink, _PathHandler]
    var erased: _PathErased
    var erased_driver: ErasedHandlerDriver[NoopSink, HttpResponse]
    var reqs: Int64
    var sent: Int64

    def __init__(out self, variant: Int) raises:
        var fds = _socketpair()
        self.variant = variant
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
        self.reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK
        )
        self.chain = MiddlewareChain()
        self.mw = _PassMiddleware()
        self.disp = _PathDispatcher()
        self.susp = _PathSuspendable()
        self.susp_driver = SuspendableHandlerDriver[NoopSink, _PathHandler]()
        self.erased = _PathErased()
        self.erased_driver = ErasedHandlerDriver[NoopSink, HttpResponse]()
        self.reqs = Int64(0)
        self.sent = Int64(0)

    def __deinit__(deinit self):
        if self.peer >= 0:
            _ = external_call["close", Int32](self.peer)

    def send(mut self, s: String) raises:
        _send(self.peer, s)

    def shut_peer_write(mut self) raises:
        if external_call["shutdown", Int32](self.peer, Int32(1)) < 0:
            raise Error("shutdown(SHUT_WR) failed")

    def read(mut self) raises -> _Got:
        """Everything the server has written so far."""
        return _read_all(self.peer)

    def ok(self, path: String) -> String:
        """This round's answer to a request for `path`."""
        if self.variant == 0:
            return String(CANNED)
        if self.variant == 1:
            return _ok_text(String("Hello, World!"))
        return _ok_text(path)

    def round(mut self) raises -> Bool:
        var limits = ParseLimits.defaults()
        if self.variant == 0:
            return serve_read_round(
                self.entry,
                self.io,
                self.resp,
                self.resp_len,
                limits,
                True,
                self.reqs,
                self.sent,
            )
        if self.variant == 1:
            return serve_read_round_chained(
                self.entry, self.io, limits, True, self.chain, self.reqs, self.sent
            )
        if self.variant == 2:
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
        if self.variant == 3:
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
        if self.variant == 4:
            var alive = serve_read_round_suspendable[_PathSuspendable, _Rt](
                self.entry,
                self.reactor,
                self.io,
                limits,
                True,
                self.susp,
                self.susp_driver,
                Int64(self.entry.fd()),
                self.reqs,
                self.sent,
            )
            var done = self.susp_driver.take_delivered()
            for i in range(len(done)):
                _ = write_delivered_to_conn(
                    self.entry, done[i].response, self.reqs, self.sent
                )
            return alive
        var alive = serve_read_round_erased[_PathErased, _Rt](
            self.entry,
            self.reactor,
            self.io,
            limits,
            True,
            self.erased,
            self.erased_driver,
            Int64(self.entry.fd()),
            self.reqs,
            self.sent,
        )
        var done = self.erased_driver.take_delivered()
        for i in range(len(done)):
            _ = write_delivered_to_conn(
                self.entry, done[i].response, self.reqs, self.sent
            )
        return alive


def _assert_waiting(mut rig: _Rig) raises:
    """Nothing answered yet, and the connection still open."""
    var got = rig.read()
    assert_equal(len(got.data), 0, "answered before the head was complete")
    assert_false(got.eof, "closed while waiting for the head")


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_head_split_across_two_reads_is_answered() raises:
    for v in range(VARIANTS):
        var rig = _Rig(v)
        rig.send("GET /split HTTP/1.1\r\nHost: exa")
        assert_true(rig.round(), "round " + String(v) + " closed on a partial head")
        assert_equal(rig.reqs, Int64(0))
        _assert_waiting(rig)
        rig.send("mple.com\r\n\r\n")
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok("/split"))


def test_head_in_three_pieces_is_answered() raises:
    """The carry grows: the second read still does not end the head."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        rig.send("GET /three HT")
        assert_true(rig.round())
        rig.send("TP/1.1\r\nHost: e")
        assert_true(rig.round(), "round " + String(v) + " lost the grown carry")
        _assert_waiting(rig)
        rig.send("xample.com\r\n\r\n")
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok("/three"))


def test_pipelined_head_cut_at_the_read_end_is_answered() raises:
    """The first request is answered at once; the second, whose head the
    read cut, once its rest arrives. Rounds 4 and 5 admit one request per
    read (a documented limit of those rounds), so they are not run here."""
    for v in range(4):
        var rig = _Rig(v)
        rig.send("GET /one HTTP/1.1\r\nHost: example.com\r\n\r\nGET /two HTTP/1.1\r\n")
        assert_true(rig.round(), "round " + String(v) + " dropped the cut request")
        assert_equal(rig.reqs, Int64(1))
        assert_equal(_text(rig.read().data), rig.ok("/one"))
        rig.send("Host: example.com\r\n\r\n")
        assert_true(rig.round())
        assert_equal(rig.reqs, Int64(2))
        assert_equal(_text(rig.read().data), rig.ok("/two"))


def test_end_of_stream_after_a_partial_head_closes_unanswered() raises:
    for v in range(VARIANTS):
        var rig = _Rig(v)
        rig.send("GET / HTTP/1.1\r\nHost: exa")
        assert_true(rig.round())
        rig.shut_peer_write()
        assert_false(rig.round(), "round " + String(v) + " kept a closed peer")
        assert_equal(rig.reqs, Int64(0))
        assert_equal(len(rig.read().data), 0)


def test_head_filling_the_receive_buffer_gets_431() raises:
    """No end of head within REQ_BUF_BYTES: it can never complete in the
    buffer, so it is refused, not kept."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        rig.send("GET / HTTP/1.1\r\nX-Pad: " + _pad(REQ_BUF_BYTES))
        assert_false(rig.round(), "round " + String(v) + " kept an endless head")
        assert_equal(rig.reqs, Int64(0))
        var got = rig.read()
        assert_equal(_text(got.data), _error_text(431))


def test_carried_head_grown_to_fill_the_buffer_gets_431() raises:
    """The carry plus a later read fill the buffer without ending the head."""
    for v in range(VARIANTS):
        var rig = _Rig(v)
        rig.send("GET / HTTP/1.1\r\nX-Pad: " + _pad(REQ_BUF_BYTES - 1000))
        assert_true(rig.round())
        _assert_waiting(rig)
        rig.send(_pad(2000))
        assert_false(rig.round(), "round " + String(v) + " kept an endless head")
        assert_equal(_text(rig.read().data), _error_text(431))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
