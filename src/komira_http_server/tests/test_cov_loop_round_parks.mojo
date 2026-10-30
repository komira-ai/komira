# =============================================================================
# test_cov_loop_round_parks.mojo: the middleware-chained, suspendable and
# type-erased read rounds writing a refusal or an interim into a full socket
# =============================================================================
#
# Each round runs against a plain `ConnEntry` on one end of an AF_UNIX
# socketpair in this process. Before the request is sent, the server's end
# is filled with '.' bytes until the kernel answers EAGAIN; the client never
# reads them, and on a socketpair nothing frees that space but a read, so
# the round's next write parks for certain. The same shapes
# `test_cov_dispatch_round_parks.mojo` drives through the plain round.
#
# Groups (and the defect each would catch):
#   N  a round woken with nothing to read: the connection dropped, a
#      response written, or the dispatcher called.
#   P  a 400 for a malformed head, a 431 for a head that fills the receive
#      buffer without ending, a 417 for a refused expectation, a 400 for bad
#      chunk framing and an interim 100 Continue that cannot be written now:
#      not parked (lost, or the connection dropped), parked with the wrong
#      bytes, the round not reporting the connection alive, or a refused
#      request handed to the dispatcher.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.completion_queue import RegistrationHandle
from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_io import try_io_write
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
from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_core.codec.h1.limits import ParseLimits
from komira_http_core.codec.h1.parser import (
    build_100_continue_bytes,
    build_error_response_bytes,
)
from komira_http_server.connection import (
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
)
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    ErasedDispatcher,
    SuspendableDispatcher,
    serve_read_round_dispatch_chained,
    serve_read_round_erased,
    serve_read_round_suspendable,
)
from komira_http_server.middleware import MiddlewareChain
from komira_http_server.middleware.middleware import RequestContext
from komira_http_server.middleware.passthrough import PassthroughMiddleware

comptime _Rt = BlockingRuntime[NoopSink]

comptime _CHAINED = 1
comptime _SUSPENDABLE = 2
comptime _ERASED = 3


struct _Chain(CtxRequestDispatcher):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.calls += 1
        return HttpResponse.ok(String("ok"))

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        self.calls += 1
        return HttpResponse.ok(String("ok"))


struct _OkSM(SuspendableHandler):
    comptime Resp = HttpResponse

    def __init__(out self):
        pass

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Self.Resp]:
        return HandlerStepResult[Self.Resp].done(
            HttpResponse.ok(String("ok"))
        )


struct _Susp(SuspendableDispatcher):
    comptime Handler = _OkSM
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def make_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> SuspendedFrame[Self.Handler]:
        self.calls += 1
        return SuspendedFrame[Self.Handler](_OkSM(), request_id)


struct _Erased(ErasedDispatcher):
    comptime Sink = NoopSink
    comptime Resp = HttpResponse
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def make_erased_frame[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var req: HttpRequest,
        request_id: Int64,
    ) raises -> ErasedHandlerFrame[Self.Sink]:
        self.calls += 1
        return make_erased_handler_frame[_OkSM, Self.Sink](
            _OkSM(), request_id
        )


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


def _parked_after(
    loop: Int, request: String, expect_continue: Bool
) raises -> Tuple[String, Int]:
    """Fill the server end, send `request`, run one round of `loop`; return
    the parked bytes and the dispatcher's call count. The round must keep the
    connection and leave it waiting to write."""
    var fds = _socketpair()
    var entry = ConnEntry(
        stream=TcpStream(fds[0]),
        reg=RegistrationHandle(_fd=fds[0]),
    )
    var junk = List[UInt8](length=512, fill=UInt8(0x2E))
    var filled = False
    for _ in range(100000):
        var r = try_io_write(fds[0], Span(junk))
        if r.is_would_block():
            filled = True
            break
        if not r.is_ready():
            raise Error("the fill failed")
    assert_true(filled, "the socket never filled")
    var req = _bytes(request)
    var rc = external_call["send", Int64](
        fds[1], req.unsafe_ptr(), UInt64(len(req)), Int32(0)
    )
    assert_equal(Int(rc), len(req))
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
    var reqs = Int64(0)
    var sent = Int64(0)
    var alive = False
    var calls = 0
    if loop == _CHAINED:
        var chain = MiddlewareChain.default()
        var mw = PassthroughMiddleware()
        var d = _Chain()
        alive = serve_read_round_dispatch_chained[
            _Chain, PassthroughMiddleware, _Rt
        ](
            entry,
            reactor,
            io,
            ParseLimits.defaults(),
            expect_continue,
            chain,
            mw,
            d,
            reqs,
            sent,
        )
        calls = d.calls
    elif loop == _SUSPENDABLE:
        var sd = _Susp()
        var drv = SuspendableHandlerDriver[NoopSink, _OkSM]()
        alive = serve_read_round_suspendable[_Susp, _Rt](
            entry,
            reactor,
            io,
            ParseLimits.defaults(),
            expect_continue,
            sd,
            drv,
            Int64(fds[0]),
            reqs,
            sent,
        )
        calls = sd.calls
    else:
        var ed = _Erased()
        var drv = ErasedHandlerDriver[NoopSink, HttpResponse]()
        alive = serve_read_round_erased[_Erased, _Rt](
            entry,
            reactor,
            io,
            ParseLimits.defaults(),
            expect_continue,
            ed,
            drv,
            Int64(fds[0]),
            reqs,
            sent,
        )
        calls = ed.calls
    assert_true(alive, "the round dropped a connection whose write parked")
    assert_equal(entry._state, CONN_STATE_WAITING_FOR_WRITABLE)
    assert_equal(sent, Int64(0), "a parked write was counted as sent")
    var parked = List[UInt8]()
    for i in range(entry._pending_len):
        parked.append(entry._pending_buf[entry._pending_off + i])
    _ = external_call["close", Int32](fds[1])
    _ = entry^
    return (_text(parked), calls)


def _error(status: Int) -> String:
    var b = List[UInt8]()
    build_error_response_bytes(UInt16(status), b)
    return _text(b)


comptime _EXPECT = (
    "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
    "Content-Length: 5\r\n\r\nhello"
)


def _malformed_head_parks_its_400(loop: Int) raises:
    """RFC 9112 section 5.1: whitespace before a field's colon is a 400."""
    var r = _parked_after(
        loop, "GET / HTTP/1.1\r\nHost: example.com\r\nAccept : x\r\n\r\n", True
    )
    assert_equal(r[0], _error(400))
    assert_equal(r[1], 0)


def _head_filling_the_buffer_parks_its_431(loop: Int) raises:
    """A head that fills the receive buffer without ending cannot complete:
    it is answered 431 and the answer parks."""
    var pad = String()
    for _ in range(REQ_BUF_BYTES):
        pad += "p"
    var r = _parked_after(
        loop, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Pad: " + pad, True
    )
    assert_equal(r[0], _error(431))
    assert_equal(r[1], 0)


def _refused_expectation_parks_its_417(loop: Int) raises:
    var r = _parked_after(loop, _EXPECT, False)
    assert_equal(r[0], _error(417))
    assert_equal(r[1], 0)


def _bad_chunk_framing_parks_its_400(loop: Int) raises:
    var r = _parked_after(
        loop,
        "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked"
        "\r\n\r\nzz\r\nnope\r\n0\r\n\r\n",
        True,
    )
    assert_equal(r[0], _error(400))
    assert_equal(r[1], 0)


def _interim_continue_parks(loop: Int) raises:
    """The interim parks first. The chained round also dispatches the request
    behind it and queues its 200 after the interim; the other two loops are
    asserted on the interim prefix only (komira-ai/komira#1998 tracks what
    becomes of the request behind a parked interim there)."""
    var r = _parked_after(loop, _EXPECT, True)
    var want = List[UInt8]()
    build_100_continue_bytes(want)
    var interim = _text(want)
    assert_true(r[0].startswith(interim), r[0])
    if loop == _CHAINED:
        assert_equal(r[1], 1)
        var rest = String(r[0][byte = interim.byte_length() :])
        assert_true(rest.startswith("HTTP/1.1 200 "), rest)
        assert_true(rest.endswith("\r\n\r\nok"), rest)


def _round_with_nothing_to_read(loop: Int) raises:
    """A readiness event for a connection whose bytes are gone (another
    reader took them, or the event was stale): the receive would block, the
    round keeps the connection, writes nothing and hands nothing to the
    dispatcher."""
    var fds = _socketpair()
    var entry = ConnEntry(
        stream=TcpStream(fds[0]),
        reg=RegistrationHandle(_fd=fds[0]),
    )
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
    var reqs = Int64(0)
    var sent = Int64(0)
    var alive = False
    var calls = 0
    if loop == _CHAINED:
        var chain = MiddlewareChain.default()
        var mw = PassthroughMiddleware()
        var d = _Chain()
        alive = serve_read_round_dispatch_chained[
            _Chain, PassthroughMiddleware, _Rt
        ](
            entry,
            reactor,
            io,
            ParseLimits.defaults(),
            True,
            chain,
            mw,
            d,
            reqs,
            sent,
        )
        calls = d.calls
    elif loop == _SUSPENDABLE:
        var sd = _Susp()
        var drv = SuspendableHandlerDriver[NoopSink, _OkSM]()
        alive = serve_read_round_suspendable[_Susp, _Rt](
            entry,
            reactor,
            io,
            ParseLimits.defaults(),
            True,
            sd,
            drv,
            Int64(fds[0]),
            reqs,
            sent,
        )
        calls = sd.calls
    else:
        var ed = _Erased()
        var drv = ErasedHandlerDriver[NoopSink, HttpResponse]()
        alive = serve_read_round_erased[_Erased, _Rt](
            entry,
            reactor,
            io,
            ParseLimits.defaults(),
            True,
            ed,
            drv,
            Int64(fds[0]),
            reqs,
            sent,
        )
        calls = ed.calls
    assert_true(alive, "the round dropped a connection with nothing to read")
    assert_equal(calls, 0)
    assert_equal(reqs, Int64(0))
    assert_equal(sent, Int64(0))
    # Nothing was written to the peer either.
    var buf = List[UInt8](length=64, fill=UInt8(0))
    var n = external_call["recv", Int64](
        fds[1], buf.unsafe_ptr(), UInt64(64), Int32(0)
    )
    assert_true(n < 0, "the round wrote " + String(n) + " bytes")
    _ = external_call["close", Int32](fds[1])
    _ = entry^


def test_chained_malformed_head_parks_its_400() raises:
    _malformed_head_parks_its_400(_CHAINED)


def test_suspendable_malformed_head_parks_its_400() raises:
    _malformed_head_parks_its_400(_SUSPENDABLE)


def test_erased_malformed_head_parks_its_400() raises:
    _malformed_head_parks_its_400(_ERASED)


def test_chained_head_filling_the_buffer_parks_its_431() raises:
    _head_filling_the_buffer_parks_its_431(_CHAINED)


def test_suspendable_head_filling_the_buffer_parks_its_431() raises:
    _head_filling_the_buffer_parks_its_431(_SUSPENDABLE)


def test_erased_head_filling_the_buffer_parks_its_431() raises:
    _head_filling_the_buffer_parks_its_431(_ERASED)


def test_chained_refused_expectation_parks_its_417() raises:
    _refused_expectation_parks_its_417(_CHAINED)


def test_suspendable_refused_expectation_parks_its_417() raises:
    _refused_expectation_parks_its_417(_SUSPENDABLE)


def test_erased_refused_expectation_parks_its_417() raises:
    _refused_expectation_parks_its_417(_ERASED)


def test_chained_bad_chunk_framing_parks_its_400() raises:
    _bad_chunk_framing_parks_its_400(_CHAINED)


def test_suspendable_bad_chunk_framing_parks_its_400() raises:
    _bad_chunk_framing_parks_its_400(_SUSPENDABLE)


def test_erased_bad_chunk_framing_parks_its_400() raises:
    _bad_chunk_framing_parks_its_400(_ERASED)


def test_chained_interim_continue_parks() raises:
    _interim_continue_parks(_CHAINED)


def test_suspendable_interim_continue_parks() raises:
    _interim_continue_parks(_SUSPENDABLE)


def test_erased_interim_continue_parks() raises:
    _interim_continue_parks(_ERASED)


def test_chained_round_with_nothing_to_read_keeps_the_connection() raises:
    _round_with_nothing_to_read(_CHAINED)


def test_suspendable_round_with_nothing_to_read_keeps_the_connection() raises:
    _round_with_nothing_to_read(_SUSPENDABLE)


def test_erased_round_with_nothing_to_read_keeps_the_connection() raises:
    _round_with_nothing_to_read(_ERASED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
