# =============================================================================
# test_cov_server_parking.mojo: a response the kernel cannot take at once is
# parked and resumed by the server loops, over a loopback socket
# =============================================================================
#
# The test shrinks the server listener's send buffer (an accepted socket
# inherits it, and a set size is not grown by the kernel) and the client's
# receive buffer before connecting, so the server's writes stop with EAGAIN
# after a few KiB and the connection parks
# the unsent tail (CONN_STATE_WAITING_FOR_WRITABLE, write interest). The
# client then reads while the test steps the server: each writable event
# resumes the parked write, and once it drains the connection is READING
# again and the server reads what is already queued, and a request sent
# after the drain is read when it arrives (komira-ai/komira#1406: the switch
# back to read interest was skipped). The loops driven:
# `serve_one_iteration_dispatch` and `serve_one_iteration_dispatch_chained`
# (a dispatcher answering a 256 KiB body, the second behind the middleware
# chain) and `serve_one_iteration` (canned and chained answers to a pipelined
# burst).
#
# What a pipelined burst asserts is chosen not to depend on
# komira-ai/komira#1285 (requests pipelined behind a parked response are not
# answered): every request the server counts as handled has its whole
# response delivered, byte for byte what the server counts as sent, and the
# responses are whole.
#
# Groups (and the defect each would catch):
#   D  dispatch loop: a parked tail lost, reordered or cut short; the
#      connection not back to READING after the drain; a request read after
#      a drain not parked in turn; an end of stream read after a drain not
#      closing; a reset peer with a parked tail not dropped; a request sent
#      after the drain never read (read interest not re-armed, #1406), in
#      the plain and the middleware-chained dispatch loop.
#   C  canned and chained loops: the same, with the chain's answers; a
#      client's end of stream queued behind the burst not closing the
#      connection once the last parked response drains; a request sent
#      after the last drain never read (#1406).
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.connection import (
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
)
from komira_http_server.dispatch import CtxRequestDispatcher, RequestDispatcher
from komira_http_server.middleware import MiddlewareChain
from komira_http_server.middleware.middleware import RequestContext
from komira_http_server.middleware.passthrough import PassthroughMiddleware
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

comptime _Rt = BlockingRuntime[NoopSink]
comptime _BIG = 1 << 18


def _pattern(n: Int) -> List[UInt8]:
    """`n` bytes of i mod 251, so a lost or repeated piece shows."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i % 251))
    return out^


struct _Big(CtxRequestDispatcher):
    """Answers every request with a 256 KiB patterned body (with or without
    the middleware chain's context)."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.calls += 1
        var r = HttpResponse(status=Int32(200))
        r.body = _pattern(_BIG)
        return r^

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        self.calls += 1
        var r = HttpResponse(status=Int32(200))
        r.body = _pattern(_BIG)
        return r^


# -----------------------------------------------------------------------------
# A same-process client with a small receive buffer.
# -----------------------------------------------------------------------------


def _sockopt(fd: Int32, linux_opt: Int32, macos_opt: Int32, a: Int32, b: Int32, n: Int) raises:
    var val = Array[Int32, 2](fill=Int32(0))
    val[0] = a
    val[1] = b
    var level = Int32(1)
    var opt = linux_opt
    comptime if CompilationTarget.is_macos():
        level = Int32(0xFFFF)
        opt = macos_opt
    # SAFETY: `val` is a stack local read synchronously; nothing retains it.
    var rc = external_call["setsockopt", Int32](
        fd, level, opt, val.unsafe_ptr().bitcast[UInt8](), UInt32(4 * n)
    )
    if rc < 0:
        raise Error("setsockopt failed")


def _connect_small(port: UInt16) raises -> Int32:
    var fd = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    if fd < 0:
        raise Error("socket() failed")
    _sockopt(fd, Int32(8), Int32(0x1002), Int32(4096), Int32(0), 1)  # SO_RCVBUF
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


def _small_server(var server: HttpServer[NoopGrpcDispatch]) raises -> HttpServer[NoopGrpcDispatch]:
    """`server` with a 4 KiB send buffer on its listener (SO_SNDBUF)."""
    _sockopt(server.listen_fd(), Int32(7), Int32(0x1001), Int32(4096), Int32(0), 1)
    return server^


def _assert_parked(server: HttpServer[NoopGrpcDispatch]) raises:
    """The one connection holds a parked tail (it reads the server's private
    table on purpose: the park is the point of these tests)."""
    assert_equal(server.live_conn_count(), 1)
    assert_equal(server._conns[0]._state, CONN_STATE_WAITING_FOR_WRITABLE)
    assert_true(server._conns[0]._pending_len > 0, "nothing parked")


def _reset_close(fd: Int32) raises:
    """Close with SO_LINGER {on, 0}: the kernel sends a reset."""
    _sockopt(fd, Int32(13), Int32(0x80), Int32(1), Int32(0), 2)
    _ = external_call["close", Int32](fd)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _recv_into(fd: Int32, mut got: List[UInt8]) -> Bool:
    """Append what is readable now; False at end of stream."""
    var buf = List[UInt8](length=65536, fill=UInt8(0))
    while True:
        var n = external_call["recv", Int64](
            fd, buf.unsafe_ptr(), UInt64(65536), Int32(0)
        )
        if n > 0:
            got.extend(Span(buf)[0 : Int(n)])
            continue
        return n != 0


def _find(hay: List[UInt8], needle: String, start: Int) -> Int:
    var nb = needle.as_bytes()
    var i = start
    while i + len(nb) <= len(hay):
        var k = 0
        while k < len(nb) and hay[i + k] == nb[k]:
            k += 1
        if k == len(nb):
            return i
        i += 1
    return -1


def _count(hay: List[UInt8], needle: String) -> Int:
    var n = 0
    var at = _find(hay, needle, 0)
    while at >= 0:
        n += 1
        at = _find(hay, needle, at + 1)
    return n


# -----------------------------------------------------------------------------
# D: the dispatch loop.
# -----------------------------------------------------------------------------


struct _DLink(Movable):
    var server: HttpServer[NoopGrpcDispatch]
    var d: _Big
    var fd: Int32
    # Step `serve_one_iteration_dispatch_chained` (default chain, inert
    # innermost middleware) instead of `serve_one_iteration_dispatch`.
    var chained: Bool
    var chain: MiddlewareChain
    var mw: PassthroughMiddleware

    def __init__(out self, chained: Bool = False) raises:
        self.server = _small_server(
            HttpServer(
                config=HttpServerConfig.default_ephemeral(), router=Router()
            )
        )
        self.d = _Big()
        self.chained = chained
        self.chain = MiddlewareChain.default()
        self.mw = PassthroughMiddleware()
        self.fd = _connect_small(self.server.local_port())
        for _ in range(50):
            self.step()
            if self.server.live_conn_count() == 1:
                return
        raise Error("the server did not accept the connection")

    def __deinit__(deinit self):
        if self.fd >= 0:
            _ = external_call["close", Int32](self.fd)

    def step(mut self) raises:
        if self.chained:
            _ = self.server.serve_one_iteration_dispatch_chained[
                _Big, PassthroughMiddleware, _Rt
            ](self.chain, self.mw, self.d, Int32(20_000))
        else:
            _ = self.server.serve_one_iteration_dispatch[_Big, _Rt](
                self.d, Int32(20_000)
            )


def test_dispatch_parks_a_large_response_and_resumes_it() raises:
    var l = _DLink()
    _send_all_now(l.fd, "GET /big HTTP/1.1\r\nHost: example.com\r\n\r\n")
    l.step()
    l.step()
    assert_equal(l.d.calls, 1)
    _assert_parked(l.server)
    var got = List[UInt8]()
    var head_end = -1
    for _ in range(5000):
        _ = _recv_into(l.fd, got)
        if head_end < 0:
            head_end = _find(got, "\r\n\r\n", 0)
        if head_end >= 0 and len(got) >= head_end + 4 + _BIG:
            break
        l.step()
    assert_true(head_end > 0, "no response head")
    assert_equal(len(got), head_end + 4 + _BIG, "the body is short or long")
    var want = _pattern(_BIG)
    for i in range(_BIG):
        if got[head_end + 4 + i] != want[i]:
            raise Error("body byte " + String(i) + " differs")
    # Drained: the connection is back to READING with nothing parked.
    for _ in range(20):
        if l.server._conns[0]._state == CONN_STATE_READING:
            break
        l.step()
    assert_equal(l.server._conns[0]._state, CONN_STATE_READING)
    assert_equal(l.server._conns[0]._pending_len, 0)
    assert_equal(l.server.live_conn_count(), 1)


def _reads_a_request_sent_after_the_drain(chained: Bool) raises:
    """komira-ai/komira#1406: once a parked response drains, the connection
    is armed for reads again, so a request the client sends only then (it
    is not buffered when the drain's round reads) is read and answered."""
    var l = _DLink(chained)
    _send_all_now(l.fd, "GET /1 HTTP/1.1\r\nHost: example.com\r\n\r\n")
    l.step()
    l.step()
    _assert_parked(l.server)
    var got = List[UInt8]()
    var head_end = -1
    for _ in range(5000):
        _ = _recv_into(l.fd, got)
        if head_end < 0:
            head_end = _find(got, "\r\n\r\n", 0)
        if head_end >= 0 and len(got) >= head_end + 4 + _BIG:
            break
        l.step()
    var one = head_end + 4 + _BIG
    assert_equal(len(got), one, "the first response is not whole")
    for _ in range(20):
        if l.server._conns[0]._state == CONN_STATE_READING:
            break
        l.step()
    assert_equal(l.server._conns[0]._state, CONN_STATE_READING)
    # Only now does the second request leave the client.
    _send_all_now(l.fd, "GET /2 HTTP/1.1\r\nHost: example.com\r\n\r\n")
    for _ in range(5000):
        _ = _recv_into(l.fd, got)
        if len(got) >= 2 * one:
            break
        l.step()
    assert_equal(l.d.calls, 2, "the request sent after the drain was not read")
    assert_equal(len(got), 2 * one, "the second response is not whole")
    var want = _pattern(_BIG)
    for i in range(_BIG):
        if got[one + head_end + 4 + i] != want[i]:
            raise Error("second body byte " + String(i) + " differs")


def test_dispatch_reads_a_request_sent_after_the_drain() raises:
    _reads_a_request_sent_after_the_drain(chained=False)


def test_chained_dispatch_reads_a_request_sent_after_the_drain() raises:
    _reads_a_request_sent_after_the_drain(chained=True)


def test_dispatch_drops_a_reset_peer_with_a_parked_response() raises:
    var l = _DLink()
    _send_all_now(l.fd, "GET /big HTTP/1.1\r\nHost: example.com\r\n\r\n")
    l.step()
    l.step()
    assert_equal(l.d.calls, 1)
    _assert_parked(l.server)
    _reset_close(l.fd)
    l.fd = Int32(-1)
    for _ in range(200):
        l.step()
        if l.server.live_conn_count() == 0:
            break
    assert_equal(l.server.live_conn_count(), 0)


def test_dispatch_request_read_after_a_drain_parks_again_then_closes() raises:
    """A second request and the client's end of stream arrive while the
    first response is parked. The round after the drain reads the second
    request and parks its response too; the round after that drain reads
    the end of stream and closes. Both responses arrive whole."""
    var l = _DLink()
    _send_all_now(l.fd, "GET /1 HTTP/1.1\r\nHost: example.com\r\n\r\n")
    l.step()
    l.step()
    _assert_parked(l.server)
    _send_all_now(l.fd, "GET /2 HTTP/1.1\r\nHost: example.com\r\n\r\n")
    _ = external_call["shutdown", Int32](l.fd, Int32(1))
    var got = List[UInt8]()
    var alive = True
    for _ in range(10000):
        alive = _recv_into(l.fd, got)
        if not alive:
            break
        l.step()
    assert_false(alive, "the server did not close after the end of stream")
    assert_equal(l.d.calls, 2)
    assert_equal(l.server.live_conn_count(), 0)
    var head_end = _find(got, "\r\n\r\n", 0)
    assert_true(head_end > 0)
    var one = head_end + 4 + _BIG
    assert_equal(len(got), 2 * one, "two whole responses")
    var want = _pattern(_BIG)
    for r in range(2):
        for i in range(_BIG):
            if got[r * one + head_end + 4 + i] != want[i]:
                raise Error(
                    "response " + String(r) + " body byte " + String(i) + " differs"
                )


def _send_all_now(fd: Int32, s: String) raises:
    var b = _bytes(s)
    var sent = 0
    while sent < len(b):
        var rc = external_call["send", Int64](
            fd, b.unsafe_ptr() + sent, UInt64(len(b) - sent), Int32(0)
        )
        if rc <= 0:
            raise Error("send() failed")
        sent += Int(rc)


# -----------------------------------------------------------------------------
# C: the canned and chained loops.
# -----------------------------------------------------------------------------


comptime _BURST = 600


def _burst() -> List[UInt8]:
    """600 pipelined GETs of exactly 64 bytes each: every 4096-byte read the
    server makes holds whole requests (the canned and chained rounds drop a
    connection whose read ends inside a request head)."""
    var one = String("GET / HTTP/1.1\r\nHost: example.com\r\nX-Pad: ")
    while one.byte_length() < 64 - 4:
        one += "p"
    one += "\r\n\r\n"
    var b = _bytes(one)
    var out = List[UInt8](capacity=64 * _BURST)
    for _ in range(_BURST):
        out.extend(Span(b))
    return out^


def _send_burst(fd: Int32) raises:
    """The whole burst in one send: the loopback peer's window takes it, and
    no read of the server's can land between two partial sends."""
    var req = _burst()
    assert_equal(len(req), 64 * _BURST)
    var rc = external_call["send", Int64](
        fd, req.unsafe_ptr(), UInt64(len(req)), Int32(0)
    )
    assert_equal(Int(rc), len(req), "the kernel took part of the burst")


def _run_burst(
    mut server: HttpServer[NoopGrpcDispatch],
    half_close: Bool = False,
    then_one_more: Bool = False,
) raises:
    """Send the burst, step until the server stops sending, and check every
    handled request's response arrived whole. With `then_one_more`, send one
    more request after that and check it is answered (komira-ai/komira#1406)."""
    var fd = _connect_small(server.local_port())
    for _ in range(50):
        _ = server.serve_for_iterations(1, Int32(20_000))
        if server.live_conn_count() == 1:
            break
    assert_equal(server.live_conn_count(), 1)
    _send_burst(fd)
    if half_close:
        _ = external_call["shutdown", Int32](fd, Int32(1))
    var got = List[UInt8]()
    var stats = server.serve_for_iterations(2, Int32(20_000))
    _assert_parked(server)
    # Read and step until a quiet round: nothing more arrives.
    var quiet = 0
    var alive = True
    for _ in range(20000):
        stats = server.serve_for_iterations(1, Int32(5_000))
        var before = len(got)
        alive = _recv_into(fd, got)
        if not alive:
            break
        if len(got) == before and Int(stats.bytes_sent) == len(got):
            quiet += 1
            if quiet >= 3:
                break
        else:
            quiet = 0
    assert_true(len(got) > 32 * 1024, "the responses never filled the socket")
    assert_equal(Int(stats.bytes_sent), len(got), "bytes counted as sent")
    var n = _count(got, "HTTP/1.1 ")
    assert_equal(Int64(n), stats.reqs_handled, "responses vs requests handled")
    # Whole responses: the stream is n copies of the first one.
    var first_end = _find(got, "HTTP/1.1 ", 1)
    assert_true(first_end > 0)
    assert_equal(len(got), first_end * n, "a response is cut or merged")
    for i in range(len(got)):
        if got[i] != got[i % first_end]:
            raise Error("response bytes differ at " + String(i))
    if half_close:
        # All the requests and the client's end of stream were queued before
        # the first park, so the end of stream is read by the round that
        # follows the last drain: the server closes after the last response.
        assert_false(alive, "the client did not see the server close")
        assert_equal(server.live_conn_count(), 0)
    else:
        assert_true(alive)
        assert_equal(server.live_conn_count(), 1)
    if then_one_more:
        assert_equal(server._conns[0]._state, CONN_STATE_READING)
        var handled = stats.reqs_handled
        var one = _bytes("GET /late HTTP/1.1\r\nHost: example.com\r\n\r\n")
        var rc = external_call["send", Int64](
            fd, one.unsafe_ptr(), UInt64(len(one)), Int32(0)
        )
        assert_equal(Int(rc), len(one))
        var late = List[UInt8]()
        for _ in range(200):
            stats = server.serve_for_iterations(1, Int32(20_000))
            _ = _recv_into(fd, late)
            if _find(late, "\r\n\r\n", 0) >= 0:
                break
        assert_true(
            stats.reqs_handled > handled,
            "the request sent after the last drain was not read",
        )
        assert_true(_find(late, "HTTP/1.1 ", 0) == 0, "no answer to it")
    _ = external_call["close", Int32](fd)


def test_canned_loop_parks_and_resumes() raises:
    var server = _small_server(
        HttpServer(config=HttpServerConfig.default_ephemeral(), router=Router())
    )
    _run_burst(server)


def test_canned_loop_closes_after_the_last_drain_on_half_close() raises:
    var server = _small_server(
        HttpServer(config=HttpServerConfig.default_ephemeral(), router=Router())
    )
    _run_burst(server, half_close=True)


def test_canned_loop_reads_a_request_sent_after_the_last_drain() raises:
    var server = _small_server(
        HttpServer(config=HttpServerConfig.default_ephemeral(), router=Router())
    )
    _run_burst(server, then_one_more=True)


def test_chained_loop_parks_and_resumes() raises:
    var server = _small_server(
        HttpServer(config=HttpServerConfig.default_ephemeral(), router=Router())
    )
    server.install_middleware(MiddlewareChain.default())
    _run_burst(server)


def test_canned_loop_drops_a_reset_peer_with_a_parked_response() raises:
    var server = _small_server(
        HttpServer(config=HttpServerConfig.default_ephemeral(), router=Router())
    )
    var fd = _connect_small(server.local_port())
    for _ in range(50):
        _ = server.serve_for_iterations(1, Int32(20_000))
        if server.live_conn_count() == 1:
            break
    _send_burst(fd)
    _ = server.serve_for_iterations(2, Int32(20_000))
    _assert_parked(server)
    _reset_close(fd)
    for _ in range(200):
        _ = server.serve_for_iterations(1, Int32(20_000))
        if server.live_conn_count() == 0:
            break
    assert_equal(server.live_conn_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
