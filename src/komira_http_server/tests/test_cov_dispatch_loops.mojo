# =============================================================================
# test_cov_dispatch_loops.mojo: the middleware-chained, suspendable and
# type-erased dispatch loops over a loopback socket, for the request shapes
# each round refuses, reads across several receives, or answers in turn
# =============================================================================
#
# A real `HttpServer` and a same-process client socket (non-blocking); the
# test steps the loop under test one poll cycle at a time and reads what came
# back. Every test runs once per loop (`serve_one_iteration_dispatch_chained`,
# `..._suspendable`, `..._erased`): the three rounds repeat the plain round's
# head, body and error handling in their own code, and each copy can be wrong
# on its own. The handlers answer 200 `len=<n> sum=<s>` for the body they were
# handed (s is the byte sum mod 2^16), so a lost, cut or doubled body shows in
# the response, and count the requests they were handed.
#
# Groups (and the defect each would catch):
#   E  the head: a malformed request not answered 400, an incomplete head
#      answered or dropped before its end arrives, `Expect: 100-continue`
#      answered wrong for either setting (417 when disabled, the interim
#      then the response when enabled), the handler run for a refused
#      request, a peer's close not dropping the connection.
#   B  a body: a Content-Length body longer than the read buffer, or a chunked
#      one, read short, long or wrong; a truncated body dispatched; bad chunk
#      framing not answered 400.
#   P  requests behind one another: in the chained loop every pipelined
#      request answered in order, a `Connection: close` request ending the
#      connection with nothing after it answered; in every loop a request sent
#      after the previous answer served on the same connection.
#   X  a reset peer: the connection kept after a failed read, a failed
#      interim write or a failed response write.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import Reactor
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
from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    ErasedDispatcher,
    SuspendableDispatcher,
)
from komira_http_server.middleware import MiddlewareChain
from komira_http_server.middleware.middleware import RequestContext
from komira_http_server.middleware.passthrough import PassthroughMiddleware
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

comptime _Rt = BlockingRuntime[NoopSink]

comptime _CHAINED = 1
comptime _SUSPENDABLE = 2
comptime _ERASED = 3


def _answer(body: List[UInt8]) -> String:
    var s = 0
    for i in range(len(body)):
        s = (s + Int(body[i])) & 0xFFFF
    return String("len=") + String(len(body)) + " sum=" + String(s)


struct _Chain(CtxRequestDispatcher):
    """The chained loop's dispatcher."""

    var calls: Int
    var last_len: Int

    def __init__(out self):
        self.calls = 0
        self.last_len = -1

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.calls += 1
        self.last_len = len(req.body)
        return HttpResponse.ok(_answer(req.body))

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        self.calls += 1
        self.last_len = len(req.body)
        if req.path == "/boom":
            raise Error("handler failed")
        return HttpResponse.ok(_answer(req.body))


def _mode_of(path: String) -> Int:
    """What the handler does for `path`: answer at once (0), park on a timer
    that is already due and answer when resumed (1) or raise (2)."""
    if path == "/park":
        return 1
    if path == "/boom":
        return 2
    return 0


struct _AnswerSM(SuspendableHandler):
    """A handler that answers `text`, after parking once when its mode says
    so, or fails in the way its mode says."""

    comptime Resp = HttpResponse
    var text: String
    var mode: Int
    var parked: Bool

    def __init__(out self, var text: String, mode: Int = 0):
        self.text = text^
        self.mode = mode
        self.parked = False

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Self.Resp]:
        if self.mode == 2:
            raise Error("handler failed")
        if self.mode == 1 and not self.parked:
            self.parked = True
            return HandlerStepResult[Self.Resp].parked(
                reactor.register_timer(Int64(0))
            )
        return HandlerStepResult[Self.Resp].done(
            HttpResponse.ok(self.text.copy())
        )


struct _Susp(SuspendableDispatcher):
    comptime Handler = _AnswerSM
    var calls: Int
    var last_len: Int

    def __init__(out self):
        self.calls = 0
        self.last_len = -1

    def make_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> SuspendedFrame[Self.Handler]:
        self.calls += 1
        self.last_len = len(req.body)
        return SuspendedFrame[Self.Handler](
            _AnswerSM(_answer(req.body), _mode_of(req.path)), request_id
        )


struct _Erased(ErasedDispatcher):
    comptime Sink = NoopSink
    comptime Resp = HttpResponse
    var calls: Int
    var last_len: Int

    def __init__(out self):
        self.calls = 0
        self.last_len = -1

    def make_erased_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> ErasedHandlerFrame[Self.Sink]:
        self.calls += 1
        self.last_len = len(req.body)
        return make_erased_handler_frame[_AnswerSM, Self.Sink](
            _AnswerSM(_answer(req.body), _mode_of(req.path)), request_id
        )


# -----------------------------------------------------------------------------
# A same-process client.
# -----------------------------------------------------------------------------


def _sockopt(fd: Int32, val: Array[Int32, 2], n: Int) raises:
    """SO_LINGER."""
    var level = Int32(1)
    var opt = Int32(13)
    comptime if CompilationTarget.is_macos():
        level = Int32(0xFFFF)
        opt = Int32(0x80)
    # SAFETY: `val` is a stack local read synchronously; nothing retains it.
    var rc = external_call["setsockopt", Int32](
        fd, level, opt, val.unsafe_ptr().bitcast[UInt8](), UInt32(4 * n)
    )
    if rc < 0:
        raise Error("setsockopt failed")


def _connect(port: UInt16) raises -> Int32:
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
    if external_call["connect", Int32](fd, addr.unsafe_ptr(), UInt32(16)) < 0:
        _ = external_call["close", Int32](fd)
        raise Error("connect() failed")
    if external_call["komira_fcntl_set_nonblock", Int32](fd) < 0:
        raise Error("set_nonblock failed")
    return fd


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var sent = 0
    while sent < len(bytes):
        var rc = external_call["send", Int64](
            fd, bytes.unsafe_ptr() + sent, UInt64(len(bytes) - sent), Int32(0)
        )
        if rc <= 0:
            raise Error("send() failed")
        sent += Int(rc)


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


def _body(n: Int) -> List[UInt8]:
    """`n` bytes cycling through 'a'..'z'."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(0x61 + i % 26))
    return out^


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + 1)
    return n


struct _Client(Movable):
    """A server, one connected client socket, the loop's dispatcher, and what
    the client read."""

    var server: HttpServer[NoopGrpcDispatch]
    var loop: Int
    var chain: MiddlewareChain
    var mw: PassthroughMiddleware
    var cd: _Chain
    var sd: _Susp
    var sdrv: SuspendableHandlerDriver[NoopSink, _AnswerSM]
    var ed: _Erased
    var edrv: ErasedHandlerDriver[NoopSink, HttpResponse]
    var fd: Int32
    var got: List[UInt8]
    var eof: Bool

    def __init__(out self, loop: Int, expect_continue: Bool = True) raises:
        var cfg = HttpServerConfig.default_ephemeral()
        cfg.enable_expect_continue = expect_continue
        self.server = HttpServer(config=cfg, router=Router())
        self.loop = loop
        self.chain = MiddlewareChain.default()
        self.mw = PassthroughMiddleware()
        self.cd = _Chain()
        self.sd = _Susp()
        self.sdrv = SuspendableHandlerDriver[NoopSink, _AnswerSM]()
        self.ed = _Erased()
        self.edrv = ErasedHandlerDriver[NoopSink, HttpResponse]()
        self.fd = _connect(self.server.local_port())
        self.got = List[UInt8]()
        self.eof = False
        for _ in range(50):
            self.step()
            if self.server.live_conn_count() == 1:
                return
        raise Error("the server did not accept the connection")

    def __deinit__(deinit self):
        if self.fd >= 0:
            _ = external_call["close", Int32](self.fd)

    def calls(self) -> Int:
        """Requests the stepped loop's dispatcher was handed."""
        return self.cd.calls + self.sd.calls + self.ed.calls

    def last_len(self) -> Int:
        return max(self.cd.last_len, max(self.sd.last_len, self.ed.last_len))

    def step(mut self) raises:
        if self.loop == _CHAINED:
            _ = self.server.serve_one_iteration_dispatch_chained[
                _Chain, PassthroughMiddleware, _Rt
            ](self.chain, self.mw, self.cd, Int32(20_000))
        elif self.loop == _SUSPENDABLE:
            _ = self.server.serve_one_iteration_dispatch_suspendable[
                _Susp, _Rt
            ](self.sd, self.sdrv, Int32(20_000))
        else:
            _ = self.server.serve_one_iteration_dispatch_erased[_Erased, _Rt](
                self.ed, self.edrv, Int32(20_000)
            )

    def drain(mut self) raises:
        """Read whatever the server has sent; note an end of stream."""
        var buf = List[UInt8](length=65536, fill=UInt8(0))
        while True:
            var n = external_call["recv", Int64](
                self.fd, buf.unsafe_ptr(), UInt64(65536), Int32(0)
            )
            if n > 0:
                for i in range(Int(n)):
                    self.got.append(buf[i])
                continue
            if n == 0:
                self.eof = True
            return

    def run_until_closed(mut self) raises:
        """Step until the server drops the connection and the client reads
        the end of stream (or the peer's reset)."""
        for _ in range(200):
            self.step()
            self.drain()
            if self.server.live_conn_count() == 0 and self.eof:
                return
        raise Error(
            "the connection was not closed; read so far: " + _text(self.got)
        )

    def run_until_contains(mut self, needle: String) raises:
        for _ in range(200):
            self.step()
            self.drain()
            if _text(self.got).find(needle) >= 0:
                return
        raise Error("no '" + needle + "' in: " + _text(self.got))

    def run_until_dropped(mut self) raises:
        """Step until the server has dropped every connection."""
        for _ in range(200):
            self.step()
            if self.server.live_conn_count() == 0:
                return
        raise Error("the server kept the connection")

    def send(mut self, s: String) raises:
        _send_all(self.fd, _bytes(s))

    def reset_close(mut self) raises:
        """Close with SO_LINGER {on, 0}: the kernel sends a reset."""
        var lg = Array[Int32, 2](fill=Int32(0))
        lg[0] = Int32(1)
        _sockopt(self.fd, lg, 2)
        _ = external_call["close", Int32](self.fd)
        self.fd = Int32(-1)


comptime _GET = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
comptime _EXPECT = (
    "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
    "Content-Length: 5\r\n\r\nhello"
)
comptime _CHUNKED_HEAD = (
    "POST /c HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
)


def _post_head(n: Int) -> String:
    return (
        String("POST /b HTTP/1.1\r\nHost: example.com\r\nContent-Length: ")
        + String(n)
        + "\r\n\r\n"
    )


# -----------------------------------------------------------------------------
# E: the head.
# -----------------------------------------------------------------------------


def _malformed_head_is_400_and_closed(loop: Int) raises:
    """RFC 9112 section 5.1: whitespace between a field name and its colon
    is answered 400."""
    var c = _Client(loop)
    c.send("GET / HTTP/1.1\r\nHost: example.com\r\nAccept : x\r\n\r\n")
    c.run_until_closed()
    assert_true(_text(c.got).startswith("HTTP/1.1 400"), _text(c.got))
    assert_equal(c.calls(), 0)


def _expect_continue_disabled_is_417_and_closed(loop: Int) raises:
    var c = _Client(loop, expect_continue=False)
    c.send(_EXPECT)
    c.run_until_closed()
    assert_true(_text(c.got).startswith("HTTP/1.1 417"), _text(c.got))
    assert_equal(c.calls(), 0)


def _expect_continue_enabled_sends_interim_then_response(loop: Int) raises:
    var c = _Client(loop)
    c.send(_EXPECT)
    c.run_until_contains("len=5 sum=")
    var t = _text(c.got)
    assert_true(t.startswith("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"), t)
    assert_equal(c.calls(), 1)
    assert_equal(c.last_len(), 5)
    assert_equal(c.server.live_conn_count(), 1)


def _incomplete_head_waits_for_the_rest(loop: Int) raises:
    """A head missing its final CRLF, then the client waits: the round keeps
    the head's start, neither dispatches nor answers it, and keeps the
    connection open. When the final CRLF arrives the request is dispatched
    once and answered."""
    var c = _Client(loop)
    c.send("GET / HTTP/1.1\r\nHost: example.com\r\n")
    for _ in range(2):
        c.step()
        c.drain()
    assert_equal(len(c.got), 0, _text(c.got))
    assert_equal(c.calls(), 0)
    assert_false(c.eof)
    assert_equal(c.server.live_conn_count(), 1)
    c.send("\r\n")
    c.run_until_contains("len=0 sum=0")
    assert_true(_text(c.got).startswith("HTTP/1.1 200"), _text(c.got))
    assert_equal(c.calls(), 1)
    assert_equal(c.server.live_conn_count(), 1)


def _peer_close_drops_the_connection(loop: Int) raises:
    var c = _Client(loop)
    _ = external_call["shutdown", Int32](c.fd, Int32(1))
    c.run_until_closed()
    assert_equal(len(c.got), 0)
    assert_equal(c.calls(), 0)


# -----------------------------------------------------------------------------
# B: a body.
# -----------------------------------------------------------------------------


def _long_body_is_read_across_receives(loop: Int) raises:
    """A 20000-byte body: the first receive holds under 4096 of it, the rest
    is read from the kernel by the body reader in 4096-byte pieces."""
    var c = _Client(loop)
    var body = _body(20000)
    var req = _bytes(_post_head(20000))
    req.extend(Span(body))
    _send_all(c.fd, req)
    c.run_until_contains(_answer(body))
    assert_equal(c.calls(), 1)
    assert_equal(c.last_len(), 20000)
    assert_equal(c.server.live_conn_count(), 1)


def _truncated_body_is_not_dispatched(loop: Int) raises:
    """10000 bytes declared, 6000 sent, then the client shuts its write side:
    the request is never dispatched and the connection is dropped
    unanswered."""
    var c = _Client(loop)
    var req = _bytes(_post_head(10000))
    req.extend(Span(_body(6000)))
    _send_all(c.fd, req)
    _ = external_call["shutdown", Int32](c.fd, Int32(1))
    c.run_until_closed()
    assert_equal(c.calls(), 0)
    assert_equal(len(c.got), 0, _text(c.got))


def _chunked_body_is_decoded(loop: Int) raises:
    """Two chunks and the terminator: the handler is handed the 11 decoded
    bytes (an empty body would answer `len=0`)."""
    var c = _Client(loop)
    c.send(String(_CHUNKED_HEAD) + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
    c.run_until_contains(_answer(_bytes("hello world")))
    assert_equal(c.calls(), 1)
    assert_equal(c.last_len(), 11)
    assert_equal(c.server.live_conn_count(), 1)


def _bad_chunk_framing_is_400_and_closed(loop: Int) raises:
    var c = _Client(loop)
    c.send(String(_CHUNKED_HEAD) + "zz\r\nabc\r\n0\r\n\r\n")
    c.run_until_closed()
    assert_true(_text(c.got).startswith("HTTP/1.1 400"), _text(c.got))
    assert_equal(c.calls(), 0)


def _truncated_chunked_body_is_not_dispatched(loop: Int) raises:
    var c = _Client(loop)
    c.send(String(_CHUNKED_HEAD) + "10\r\nabc")
    _ = external_call["shutdown", Int32](c.fd, Int32(1))
    c.run_until_closed()
    assert_equal(c.calls(), 0)
    assert_equal(len(c.got), 0, _text(c.got))


# -----------------------------------------------------------------------------
# P: requests behind one another.
# -----------------------------------------------------------------------------


def _request_after_the_answer_is_served(loop: Int) raises:
    """A second request, sent only once the first is answered, is read on the
    same connection and answered in turn."""
    var c = _Client(loop)
    c.send(_GET)
    c.run_until_contains("len=0 sum=0")
    assert_equal(_count(_text(c.got), "HTTP/1.1 200"), 1)
    c.send("POST /b HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\nabc")
    c.run_until_contains(_answer(_bytes("abc")))
    assert_equal(_count(_text(c.got), "HTTP/1.1 200"), 2)
    assert_equal(c.calls(), 2)
    assert_equal(c.server.live_conn_count(), 1)


def test_chained_pipelined_requests_are_answered_in_order() raises:
    """A GET, a POST with a body and a GET in one send: three responses, the
    middle one for the body the POST carried, not the GET behind it."""
    var c = _Client(_CHAINED)
    c.send(
        String(_GET)
        + "POST /b HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello"
        + _GET
    )
    c.run_until_contains("len=0 sum=0")
    for _ in range(20):
        c.step()
        c.drain()
    var t = _text(c.got)
    assert_equal(_count(t, "HTTP/1.1 200"), 3, t)
    var first = t.find("len=0 sum=0")
    var mid = t.find(_answer(_bytes("hello")))
    assert_true(first >= 0 and mid > first, t)
    assert_true(t.find("len=0 sum=0", mid) > mid, t)
    assert_equal(c.calls(), 3)
    assert_equal(c.server.live_conn_count(), 1)


def test_chained_connection_close_ends_the_connection() raises:
    """`Connection: close` on the first of two pipelined requests: it is
    answered, the connection is closed, the second is not dispatched."""
    var c = _Client(_CHAINED)
    c.send(
        "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        + String(_GET)
    )
    c.run_until_closed()
    var t = _text(c.got)
    assert_equal(_count(t, "HTTP/1.1 200"), 1, t)
    assert_equal(c.calls(), 1)


# -----------------------------------------------------------------------------
# X: a reset peer.
# -----------------------------------------------------------------------------


def _reset_before_any_byte_is_dropped(loop: Int) raises:
    """Nothing was sent: the first read fails and the connection goes."""
    var c = _Client(loop)
    c.reset_close()
    c.run_until_dropped()
    assert_equal(c.calls(), 0)


def _reset_after_an_expect_request_fails_the_interim_write(loop: Int) raises:
    """The request is read whole; writing `100 Continue` to the reset peer
    fails, and the request is not dispatched."""
    var c = _Client(loop)
    c.send(_EXPECT)
    c.reset_close()
    c.run_until_dropped()
    assert_equal(c.calls(), 0)


def _reset_after_a_request_fails_the_response_write(loop: Int) raises:
    """The request is read whole and dispatched; writing its response to the
    reset peer fails, the connection goes and nothing is counted handled."""
    var c = _Client(loop)
    c.send(_GET)
    c.reset_close()
    c.run_until_dropped()
    assert_equal(c.calls(), 1)
    assert_equal(c.server._reqs_handled, Int64(0))


def _reset_during_a_body_is_not_dispatched(loop: Int) raises:
    var c = _Client(loop)
    var req = _bytes(_post_head(10000))
    req.extend(Span(_body(6000)))
    _send_all(c.fd, req)
    c.reset_close()
    c.run_until_dropped()
    assert_equal(c.calls(), 0)


def _reset_during_a_chunked_body_is_not_dispatched(loop: Int) raises:
    var c = _Client(loop)
    c.send(String(_CHUNKED_HEAD) + "10\r\nabc")
    c.reset_close()
    c.run_until_dropped()
    assert_equal(c.calls(), 0)


# -----------------------------------------------------------------------------
# F: a handler that parks or fails.
# -----------------------------------------------------------------------------


def _get(path: String) -> String:
    return "GET " + path + " HTTP/1.1\r\nHost: example.com\r\n\r\n"


def _parked_handler_is_resumed_and_answered(loop: Int) raises:
    """The handler parks on a reactor op after the request is read; the loop
    resumes it when the op completes and writes its response to the
    connection that asked."""
    var c = _Client(loop)
    c.send(_get("/park"))
    c.run_until_contains("len=0 sum=0")
    assert_true(_text(c.got).startswith("HTTP/1.1 200"), _text(c.got))
    assert_equal(c.calls(), 1)
    assert_equal(c.server.live_conn_count(), 1)
    # The connection is served again after the resumed answer.
    c.send(_get("/again"))
    for _ in range(200):
        c.step()
        c.drain()
        if _count(_text(c.got), "HTTP/1.1 200") == 2:
            break
    assert_equal(_count(_text(c.got), "HTTP/1.1 200"), 2, _text(c.got))
    assert_equal(c.calls(), 2)


def _parked_handler_whose_peer_left_is_discarded(loop: Int) raises:
    """The peer resets while the handler is parked: when the handler resumes,
    its response has no connection to go to; it is dropped, the server counts
    nothing handled and carries on."""
    var c = _Client(loop)
    c.send(_get("/park"))
    c.reset_close()
    c.run_until_dropped()
    for _ in range(10):
        c.step()
    assert_equal(c.server.live_conn_count(), 0)
    assert_equal(c.server._reqs_handled, Int64(0))
    # A new client is still served.
    var d = _Client(loop)
    d.send(_get("/ok"))
    d.run_until_contains("len=0 sum=0")


def _raising_handler_drops_the_connection(loop: Int) raises:
    """A handler that raises while it is admitted must not take the server
    down: the connection is dropped unanswered and the next client is
    served."""
    var c = _Client(loop)
    c.send(_get("/boom"))
    c.run_until_closed()
    assert_equal(c.calls(), 1)
    assert_equal(len(c.got), 0, _text(c.got))
    var d = _Client(loop)
    d.send(_get("/ok"))
    d.run_until_contains("len=0 sum=0")


def test_chained_raising_handler_is_answered_500() raises:
    """In the chained loop the error mapper turns a handler's raise into a
    500 on the same connection, and the connection stays usable."""
    var c = _Client(_CHAINED)
    c.send(_get("/boom"))
    c.run_until_contains("HTTP/1.1 500")
    assert_equal(c.calls(), 1)
    assert_equal(c.server.live_conn_count(), 1)
    c.send(_get("/ok"))
    c.run_until_contains("len=0 sum=0")


# -----------------------------------------------------------------------------
# One test per loop.
# -----------------------------------------------------------------------------

def test_chained_malformed_head_is_400_and_closed() raises:
    _malformed_head_is_400_and_closed(_CHAINED)


def test_suspendable_malformed_head_is_400_and_closed() raises:
    _malformed_head_is_400_and_closed(_SUSPENDABLE)


def test_erased_malformed_head_is_400_and_closed() raises:
    _malformed_head_is_400_and_closed(_ERASED)


def test_chained_expect_continue_disabled_is_417_and_closed() raises:
    _expect_continue_disabled_is_417_and_closed(_CHAINED)


def test_suspendable_expect_continue_disabled_is_417_and_closed() raises:
    _expect_continue_disabled_is_417_and_closed(_SUSPENDABLE)


def test_erased_expect_continue_disabled_is_417_and_closed() raises:
    _expect_continue_disabled_is_417_and_closed(_ERASED)


def test_chained_expect_continue_enabled_sends_interim_then_response() raises:
    _expect_continue_enabled_sends_interim_then_response(_CHAINED)


def test_suspendable_expect_continue_enabled_sends_interim_then_response() raises:
    _expect_continue_enabled_sends_interim_then_response(_SUSPENDABLE)


def test_erased_expect_continue_enabled_sends_interim_then_response() raises:
    _expect_continue_enabled_sends_interim_then_response(_ERASED)


def test_chained_incomplete_head_waits_for_the_rest() raises:
    _incomplete_head_waits_for_the_rest(_CHAINED)


def test_suspendable_incomplete_head_waits_for_the_rest() raises:
    _incomplete_head_waits_for_the_rest(_SUSPENDABLE)


def test_erased_incomplete_head_waits_for_the_rest() raises:
    _incomplete_head_waits_for_the_rest(_ERASED)


def test_chained_peer_close_drops_the_connection() raises:
    _peer_close_drops_the_connection(_CHAINED)


def test_suspendable_peer_close_drops_the_connection() raises:
    _peer_close_drops_the_connection(_SUSPENDABLE)


def test_erased_peer_close_drops_the_connection() raises:
    _peer_close_drops_the_connection(_ERASED)


def test_chained_long_body_is_read_across_receives() raises:
    _long_body_is_read_across_receives(_CHAINED)


def test_suspendable_long_body_is_read_across_receives() raises:
    _long_body_is_read_across_receives(_SUSPENDABLE)


def test_erased_long_body_is_read_across_receives() raises:
    _long_body_is_read_across_receives(_ERASED)


def test_chained_truncated_body_is_not_dispatched() raises:
    _truncated_body_is_not_dispatched(_CHAINED)


def test_suspendable_truncated_body_is_not_dispatched() raises:
    _truncated_body_is_not_dispatched(_SUSPENDABLE)


def test_erased_truncated_body_is_not_dispatched() raises:
    _truncated_body_is_not_dispatched(_ERASED)


def test_chained_chunked_body_is_decoded() raises:
    _chunked_body_is_decoded(_CHAINED)


def test_suspendable_chunked_body_is_decoded() raises:
    _chunked_body_is_decoded(_SUSPENDABLE)


def test_erased_chunked_body_is_decoded() raises:
    _chunked_body_is_decoded(_ERASED)


def test_chained_bad_chunk_framing_is_400_and_closed() raises:
    _bad_chunk_framing_is_400_and_closed(_CHAINED)


def test_suspendable_bad_chunk_framing_is_400_and_closed() raises:
    _bad_chunk_framing_is_400_and_closed(_SUSPENDABLE)


def test_erased_bad_chunk_framing_is_400_and_closed() raises:
    _bad_chunk_framing_is_400_and_closed(_ERASED)


def test_chained_truncated_chunked_body_is_not_dispatched() raises:
    _truncated_chunked_body_is_not_dispatched(_CHAINED)


def test_suspendable_truncated_chunked_body_is_not_dispatched() raises:
    _truncated_chunked_body_is_not_dispatched(_SUSPENDABLE)


def test_erased_truncated_chunked_body_is_not_dispatched() raises:
    _truncated_chunked_body_is_not_dispatched(_ERASED)


def test_chained_request_after_the_answer_is_served() raises:
    _request_after_the_answer_is_served(_CHAINED)


def test_suspendable_request_after_the_answer_is_served() raises:
    _request_after_the_answer_is_served(_SUSPENDABLE)


def test_erased_request_after_the_answer_is_served() raises:
    _request_after_the_answer_is_served(_ERASED)


def test_chained_reset_before_any_byte_is_dropped() raises:
    _reset_before_any_byte_is_dropped(_CHAINED)


def test_suspendable_reset_before_any_byte_is_dropped() raises:
    _reset_before_any_byte_is_dropped(_SUSPENDABLE)


def test_erased_reset_before_any_byte_is_dropped() raises:
    _reset_before_any_byte_is_dropped(_ERASED)


def test_chained_reset_after_an_expect_request_fails_the_interim_write() raises:
    _reset_after_an_expect_request_fails_the_interim_write(_CHAINED)


def test_suspendable_reset_after_an_expect_request_fails_the_interim_write() raises:
    _reset_after_an_expect_request_fails_the_interim_write(_SUSPENDABLE)


def test_erased_reset_after_an_expect_request_fails_the_interim_write() raises:
    _reset_after_an_expect_request_fails_the_interim_write(_ERASED)


def test_chained_reset_after_a_request_fails_the_response_write() raises:
    _reset_after_a_request_fails_the_response_write(_CHAINED)


def test_suspendable_reset_after_a_request_fails_the_response_write() raises:
    _reset_after_a_request_fails_the_response_write(_SUSPENDABLE)


def test_erased_reset_after_a_request_fails_the_response_write() raises:
    _reset_after_a_request_fails_the_response_write(_ERASED)


def test_chained_reset_during_a_body_is_not_dispatched() raises:
    _reset_during_a_body_is_not_dispatched(_CHAINED)


def test_suspendable_reset_during_a_body_is_not_dispatched() raises:
    _reset_during_a_body_is_not_dispatched(_SUSPENDABLE)


def test_erased_reset_during_a_body_is_not_dispatched() raises:
    _reset_during_a_body_is_not_dispatched(_ERASED)


def test_chained_reset_during_a_chunked_body_is_not_dispatched() raises:
    _reset_during_a_chunked_body_is_not_dispatched(_CHAINED)


def test_suspendable_reset_during_a_chunked_body_is_not_dispatched() raises:
    _reset_during_a_chunked_body_is_not_dispatched(_SUSPENDABLE)


def test_erased_reset_during_a_chunked_body_is_not_dispatched() raises:
    _reset_during_a_chunked_body_is_not_dispatched(_ERASED)


def test_suspendable_parked_handler_is_resumed_and_answered() raises:
    _parked_handler_is_resumed_and_answered(_SUSPENDABLE)


def test_erased_parked_handler_is_resumed_and_answered() raises:
    _parked_handler_is_resumed_and_answered(_ERASED)


def test_suspendable_parked_handler_whose_peer_left_is_discarded() raises:
    _parked_handler_whose_peer_left_is_discarded(_SUSPENDABLE)


def test_erased_parked_handler_whose_peer_left_is_discarded() raises:
    _parked_handler_whose_peer_left_is_discarded(_ERASED)


def test_suspendable_raising_handler_drops_the_connection() raises:
    _raising_handler_drops_the_connection(_SUSPENDABLE)


def test_erased_raising_handler_drops_the_connection() raises:
    _raising_handler_drops_the_connection(_ERASED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
