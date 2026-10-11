# =============================================================================
# test_cov_dispatch_bodies.mojo: `serve_one_iteration_dispatch` over a
# loopback socket, for the request shapes the dispatch round refuses or reads
# across several receives
# =============================================================================
#
# A real `HttpServer` and a same-process client socket (non-blocking); the
# test steps the server one poll cycle at a time and reads what came back.
# Every request is sent whole before the server is stepped, so the server's
# first receive sees all of it up to the 4096-byte read buffer, and the rest
# waits in the kernel for the body readers.
#
# Groups (and the defect each would catch):
#   E  the head: a malformed request not answered 400, an incomplete head
#      kept open or answered, `Expect: 100-continue` answered wrong for
#      either setting (417 when disabled, the interim then the response when
#      enabled), the handler run for any of them, a peer's close not
#      dropping the connection.
#   L  a Content-Length body longer than the read buffer: the remainder not
#      read (or read wrong), a truncated body dispatched, a stalled sender
#      holding the connection forever.
#   K  a chunked body: a chunk-size line cut by the read boundary lost, a
#      truncated or stalled body dispatched or kept.
#   X  a reset peer: the handler run on a partial body, the connection kept
#      after a failed read, a failed interim write or a failed response
#      write. Linux returns the bytes that arrived before the reset first,
#      then the error, so each case fails where its name says.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

comptime _Rt = BlockingRuntime[NoopSink]


struct _Probe(RequestDispatcher):
    """Answers 200 `len=<n> sum=<s>` for the body it received (s is the byte
    sum mod 2^16) and counts its calls."""

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
        var n = len(req.body)
        var s = 0
        for i in range(n):
            s = (s + Int(req.body[i])) & 0xFFFF
        self.last_len = n
        return HttpResponse.ok(String("len=") + String(n) + " sum=" + String(s))


# -----------------------------------------------------------------------------
# A same-process client.
# -----------------------------------------------------------------------------


def _sockopt(fd: Int32, linux_opt: Int32, macos_opt: Int32, val: Array[Int32, 2], n: Int) raises:
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


def _sum(b: List[UInt8]) -> Int:
    var s = 0
    for i in range(len(b)):
        s = (s + Int(b[i])) & 0xFFFF
    return s


struct _Client(Movable):
    """A server, one connected client socket, and what the client read."""

    var server: HttpServer[NoopGrpcDispatch]
    var probe: _Probe
    var fd: Int32
    var got: List[UInt8]
    var eof: Bool

    def __init__(out self, expect_continue: Bool = True) raises:
        var cfg = HttpServerConfig.default_ephemeral()
        cfg.enable_expect_continue = expect_continue
        self.server = HttpServer(config=cfg, router=Router())
        self.probe = _Probe()
        self.fd = _connect(self.server.local_port())
        self.got = List[UInt8]()
        self.eof = False
        # Accept the connection.
        for _ in range(50):
            self.step()
            if self.server.live_conn_count() == 1:
                return
        raise Error("the server did not accept the connection")

    def __deinit__(deinit self):
        if self.fd >= 0:
            _ = external_call["close", Int32](self.fd)

    def step(mut self) raises:
        _ = self.server.serve_one_iteration_dispatch[_Probe, _Rt](
            self.probe, Int32(20_000)
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

    def send(mut self, s: String) raises:
        _send_all(self.fd, _bytes(s))


# -----------------------------------------------------------------------------
# E: the head.
# -----------------------------------------------------------------------------


def test_malformed_request_is_400_and_closed() raises:
    """RFC 9112 section 5.1: whitespace between a field name and its colon
    is answered 400."""
    var c = _Client()
    c.send("GET / HTTP/1.1\r\nHost: example.com\r\nAccept : x\r\n\r\n")
    c.run_until_closed()
    assert_true(_text(c.got).startswith("HTTP/1.1 400"), _text(c.got))
    assert_equal(c.probe.calls, 0)


def test_expect_continue_disabled_is_417_and_closed() raises:
    var c = _Client(expect_continue=False)
    c.send(
        "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
        "Content-Length: 5\r\n\r\nhello"
    )
    c.run_until_closed()
    assert_true(_text(c.got).startswith("HTTP/1.1 417"), _text(c.got))
    assert_equal(c.probe.calls, 0)


def test_expect_continue_enabled_sends_interim_then_response() raises:
    var c = _Client()
    c.send(
        "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
        "Content-Length: 5\r\n\r\nhello"
    )
    c.run_until_contains("len=5 sum=")
    var t = _text(c.got)
    assert_true(t.startswith("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"), t)
    assert_equal(c.probe.calls, 1)
    assert_equal(c.server.live_conn_count(), 1)


def test_incomplete_head_is_dropped_unanswered() raises:
    """A head missing its final CRLF, then the client waits. The round does
    no buffering across receives, so it drops the connection unanswered.
    That is a known limitation, not the behaviour RFC 9112 asks for (a head
    may arrive in several segments): komira-ai/komira#1447. The fix for
    that issue changes this test to wait for the rest of the head; until
    then it pins that an incomplete head is neither dispatched nor answered
    as if it were complete."""
    var c = _Client()
    c.send("GET / HTTP/1.1\r\nHost: example.com\r\n")
    c.run_until_closed()
    assert_equal(len(c.got), 0, _text(c.got))
    assert_equal(c.probe.calls, 0)


def test_peer_close_drops_the_connection() raises:
    var c = _Client()
    _ = external_call["shutdown", Int32](c.fd, Int32(1))
    c.run_until_closed()
    assert_equal(len(c.got), 0)
    assert_equal(c.probe.calls, 0)


# -----------------------------------------------------------------------------
# L: a Content-Length body longer than the read buffer.
# -----------------------------------------------------------------------------


def _post_head(n: Int) -> String:
    return (
        String("POST /b HTTP/1.1\r\nHost: example.com\r\nContent-Length: ")
        + String(n)
        + "\r\n\r\n"
    )


def test_long_body_is_read_across_receives() raises:
    """A 20000-byte body: the first receive holds under 4096 of it, the rest
    is read from the kernel by the body reader in 4096-byte pieces."""
    var c = _Client()
    var body = _body(20000)
    var req = _bytes(_post_head(20000))
    req.extend(Span(body))
    _send_all(c.fd, req)
    c.run_until_contains("len=20000 sum=" + String(_sum(body)))
    assert_equal(c.probe.calls, 1)
    assert_equal(c.probe.last_len, 20000)
    assert_equal(c.server.live_conn_count(), 1)


def test_long_body_stops_at_its_content_length() raises:
    """A 20000-byte body and a pipelined GET in one send: the body reader
    reads the remainder from the kernel up to the declared length and no
    further, so the dispatch sees exactly the 20000 body bytes, none of the
    GET behind them."""
    var c = _Client()
    var body = _body(20000)
    var req = _bytes(_post_head(20000))
    req.extend(Span(body))
    req.extend(Span(_bytes("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")))
    _send_all(c.fd, req)
    for _ in range(200):
        c.step()
        c.drain()
        if c.probe.calls > 0 and _text(c.got).find(" sum=") >= 0:
            break
    var t = _text(c.got)
    assert_true(c.probe.calls >= 1, "the POST was not dispatched: " + t)
    assert_true(
        t.find("len=20000 sum=" + String(_sum(body))) >= 0,
        "the body reader over-read: " + t,
    )


def test_truncated_body_is_not_dispatched() raises:
    """10000 bytes declared, 6000 sent, then the client shuts its write side:
    the request is never dispatched and the connection is dropped
    unanswered."""
    var c = _Client()
    var req = _bytes(_post_head(10000))
    req.extend(Span(_body(6000)))
    _send_all(c.fd, req)
    _ = external_call["shutdown", Int32](c.fd, Int32(1))
    c.run_until_closed()
    assert_equal(c.probe.calls, 0)
    assert_equal(len(c.got), 0, _text(c.got))


def test_stalled_body_is_given_up() raises:
    """10000 bytes declared, 6000 sent, and the client then sends nothing
    and keeps the connection open: the body reader gives up after its
    bounded number of empty reads and the connection is dropped."""
    var c = _Client()
    var req = _bytes(_post_head(10000))
    req.extend(Span(_body(6000)))
    _send_all(c.fd, req)
    c.run_until_closed()
    assert_equal(c.probe.calls, 0)
    assert_equal(len(c.got), 0, _text(c.got))


# -----------------------------------------------------------------------------
# K: a chunked body.
# -----------------------------------------------------------------------------


comptime _CHUNKED_HEAD = (
    "POST /c HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
)


def _hex(n: Int) -> String:
    var digits = String("0123456789abcdef")
    var out = String()
    var v = n
    while True:
        out = digits[byte = (v & 15) : (v & 15) + 1] + out
        v >>= 4
        if v == 0:
            return out^


def test_chunk_size_line_cut_by_the_read_boundary() raises:
    """The first chunk is sized so the first 4096-byte receive ends one byte
    into the second chunk's size line ("1" of "100"). The decoder hands back
    that byte unconsumed; it must be kept for the next receive, or the
    second chunk's size reads as "00" and the body is lost."""
    var head = String(_CHUNKED_HEAD)
    var h = head.byte_length()
    # h + len(size line) + d + 2 (CRLF) + 1 ("1") == 4096.
    var d = 4096 - h - 3
    while d + _hex(d).byte_length() + 2 != 4096 - h - 3:
        d -= 1
    var first = _body(d)
    var second = _body(256)
    var req = _bytes(head + _hex(d) + "\r\n")
    req.extend(Span(first))
    req.extend(Span(_bytes("\r\n100\r\n")))
    assert_equal(len(req), 4096 + 4, "the cut is not where this test says")
    req.extend(Span(second))
    req.extend(Span(_bytes("\r\n0\r\n\r\n")))
    var c = _Client()
    _send_all(c.fd, req)
    var all = first.copy()
    all.extend(Span(second))
    c.run_until_contains(
        "len=" + String(d + 256) + " sum=" + String(_sum(all))
    )
    assert_equal(c.probe.last_len, d + 256)


def test_truncated_chunked_body_is_not_dispatched() raises:
    var c = _Client()
    c.send(String(_CHUNKED_HEAD) + "10\r\nabc")
    _ = external_call["shutdown", Int32](c.fd, Int32(1))
    c.run_until_closed()
    assert_equal(c.probe.calls, 0)
    assert_equal(len(c.got), 0, _text(c.got))


def test_stalled_chunked_body_is_given_up() raises:
    var c = _Client()
    c.send(String(_CHUNKED_HEAD) + "10\r\nabc")
    c.run_until_closed()
    assert_equal(c.probe.calls, 0)
    assert_equal(len(c.got), 0, _text(c.got))


# -----------------------------------------------------------------------------
# X: a reset peer.
# -----------------------------------------------------------------------------


def _reset_close(mut c: _Client) raises:
    """Close with SO_LINGER {on, 0}: the kernel sends a reset."""
    var lg = Array[Int32, 2](fill=Int32(0))
    lg[0] = Int32(1)
    _sockopt(c.fd, Int32(13), Int32(0x80), lg, 2)
    _ = external_call["close", Int32](c.fd)
    c.fd = Int32(-1)


def test_reset_during_a_long_body_is_not_dispatched() raises:
    var c = _Client()
    var req = _bytes(_post_head(10000))
    req.extend(Span(_body(6000)))
    _send_all(c.fd, req)
    _reset_close(c)
    for _ in range(200):
        c.step()
        if c.server.live_conn_count() == 0:
            break
    assert_equal(c.server.live_conn_count(), 0)
    assert_equal(c.probe.calls, 0)


def test_reset_during_a_chunked_body_is_not_dispatched() raises:
    var c = _Client()
    c.send(String(_CHUNKED_HEAD) + "10\r\nabc")
    _reset_close(c)
    for _ in range(200):
        c.step()
        if c.server.live_conn_count() == 0:
            break
    assert_equal(c.server.live_conn_count(), 0)
    assert_equal(c.probe.calls, 0)


def _drop_after_reset(mut c: _Client) raises:
    for _ in range(200):
        c.step()
        if c.server.live_conn_count() == 0:
            return
    raise Error("the server kept a reset connection")


def test_reset_before_any_byte_is_dropped() raises:
    """Nothing was sent: the first read fails and the connection goes."""
    var c = _Client()
    _reset_close(c)
    _drop_after_reset(c)
    assert_equal(c.probe.calls, 0)


def test_reset_after_an_expect_request_fails_the_interim_write() raises:
    """The request is read whole; writing `100 Continue` to the reset peer
    fails, and the request is not dispatched."""
    var c = _Client()
    c.send(
        "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
        "Content-Length: 5\r\n\r\nhello"
    )
    _reset_close(c)
    _drop_after_reset(c)
    assert_equal(c.probe.calls, 0)


def test_reset_after_a_request_fails_the_response_write() raises:
    """The request is read whole and dispatched; writing its response to the
    reset peer fails and the connection goes."""
    var c = _Client()
    c.send("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    _reset_close(c)
    _drop_after_reset(c)
    assert_equal(c.probe.calls, 1)
    # A response that never left is not counted as handled.
    assert_equal(c.server._reqs_handled, Int64(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
