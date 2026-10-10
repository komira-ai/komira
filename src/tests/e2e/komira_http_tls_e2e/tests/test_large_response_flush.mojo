# =============================================================================
# test_large_response_flush.mojo -- a response far larger than the socket can
# hold arrives byte for byte, through the server's buffered-write path
# =============================================================================
#
# PLAINTEXT, ON PURPOSE. The server's buffered-write path (`_write_all_or_buffer`
# parks the unsent tail in `ConnEntry._pending_buf`; `resume_pending_write`
# drains it on each writable event) serves the plaintext h1 rounds only. Over
# TLS the h1 round answers with a fixed health response and its writer gives up
# on a blocked write rather than buffering it, and the h2 round answers with a
# fixed body; neither can carry a large response. This leg therefore drives the
# path where it exists (TLS has no buffered-write path today; that gap is
# tracked separately): a real `HttpServer` stepped by
# `serve_one_iteration_dispatch`, a dispatcher answering with a 4 MiB body, and a
# real `HttpClient` reading it.
#
# Forcing the tail into `_pending_buf`, whatever the host's TCP defaults:
#   * the listener's SO_SNDBUF is set to 64 KiB before the connection is
#     accepted (an accepted socket inherits it);
#   * the client sets its own SO_RCVBUF to 64 KiB right after connecting,
#     before any response byte arrives, which also caps the window it
#     advertises (an explicit SO_RCVBUF turns off receive autotuning); and
#   * the client's stream holds its FIRST read until the dispatcher has run and
#     a further 100 ms has passed, so the server's write runs against a peer
#     that is reading nothing.
# With both ends capped (Linux doubles each to 128 KiB) the bytes in flight
# before the first read are bounded by about 256 KiB, far below 4 MiB, so the
# write cannot complete inline: it blocks, and the rest is buffered. (The
# pending-buffer cap mutant measured the inline amount on the farm at about
# 188 KiB.)
# Not smaller: at 4 KiB every drain round waits on the receiver's delayed ACK
# (about 40 ms), and 4 MiB then takes about 20 s.
# The client then reads, the socket drains, and the server must flush the whole
# tail across as many writable events as it takes.
#
# What it asserts: status 200, Content-Length 4194304, and every body byte equal
# to its index pattern. The pattern does not repeat within the body: byte i is
# byte (i % 4) of a bijective 32-bit mix of i // 4, so every 4-byte word of the
# body is distinct, and a truncation, a span duplicated or shifted by any
# amount (a resumed write that starts from the wrong offset), or a dropped
# tail all differ. Defect it catches: a cap or a lost tail in the
# pending buffer, or a resume path that stops early (the client times out short
# of Content-Length).
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_setup import set_so_rcvbuf, set_so_sndbuf
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_core.transport import StreamIo
from komira_http_core.transport.io_stream import Connector, IoStream
from komira_http_core.transport.kernel_tcp import KernelTcpConnector, TcpIoStream
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_http_tls_e2e import ClientLeg, DispatchServeLoop, serve_while

comptime _Rt = BlockingRuntime[NoopSink]
comptime _BODY_BYTES = 4 * 1024 * 1024
comptime _SOCKBUF_BYTES: Int32 = 65536
comptime _REQUEST_TIMEOUT_US = 20_000_000


def _pattern(i: Int) -> UInt8:
    """Byte `i % 4` of a bijective 32-bit mix of `i // 4` (multiply by an
    odd constant and xor-shift, each invertible), so no 4-byte word repeats
    within 2^32 words."""
    var x = UInt32(i // 4) * UInt32(0x9E3779B1)
    x ^= x >> 15
    x *= UInt32(0x85EBCA77)
    x ^= x >> 13
    return UInt8((x >> UInt32((i % 4) * 8)) & UInt32(0xFF))


def _spin_until(deadline_ns: UInt64):
    """Busy-wait on the monotonic clock. Not `std.time.sleep`: its
    `nanosleep` declaration conflicts with the komira_async reactor's in one
    binary."""
    while now_ns() < deadline_ns:
        pass


# -----------------------------------------------------------------------------
# The signal between the two threads: the dispatcher has produced the response.
# Shared ownership (the server's dispatcher and the client's stream each hold
# one `ArcPointer`), read and written only through the atomic.
# -----------------------------------------------------------------------------


struct _Signals(Movable):
    var dispatched: AtomicI64

    def __init__(out self):
        self.dispatched = AtomicI64(Int64(0))


struct _BigBody(RequestDispatcher):
    """Answers every request with 200 and `_BODY_BYTES` of `_pattern`."""

    var signals: ArcPointer[_Signals]

    def __init__(out self, signals: ArcPointer[_Signals]):
        self.signals = signals.copy()

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        _ = req^
        var resp = HttpResponse(Int32(200))
        var body = List[UInt8](capacity=_BODY_BYTES)
        for i in range(_BODY_BYTES):
            body.append(_pattern(i))
        resp.body = body^
        # `HttpResponse(status)` leaves the framing headers to the caller.
        resp.headers[String("content-type")] = String("application/octet-stream")
        resp.headers[String("content-length")] = String(_BODY_BYTES)
        _ = self.signals[].dispatched.fetch_add(Int64(1))
        return resp^


# -----------------------------------------------------------------------------
# The client's stream: kernel TCP, with the first read held back.
# -----------------------------------------------------------------------------


struct _HeldStream(IoStream, Movable, Deinitable):
    """`TcpIoStream`, except that the first `try_read` waits until the
    dispatcher has run plus 100 ms, so the server writes into a socket nobody
    is reading."""

    var inner: TcpIoStream
    var signals: ArcPointer[_Signals]
    var held: Bool

    def __init__(out self, var inner: TcpIoStream, signals: ArcPointer[_Signals]):
        self.inner = inner^
        self.signals = signals.copy()
        self.held = False

    def try_read[
        RT: Runtime, o2: Origin[mut=True],
    ](
        mut self, mut reactor: Reactor[RT.Sink], dst: Span[UInt8, o2]
    ) raises -> StreamIo:
        if not self.held:
            self.held = True
            var give_up = now_ns() + UInt64(10_000_000_000)
            while self.signals[].dispatched.load() == Int64(0):
                if now_ns() >= give_up:
                    raise Error("the server never dispatched the request")
            _spin_until(now_ns() + UInt64(100_000_000))
        return self.inner.try_read[RT](reactor, dst)

    def try_write[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], src: Span[UInt8, _]
    ) raises -> StreamIo:
        return self.inner.try_write[RT](reactor, src)

    def close(var self):
        pass  # dropping `inner` closes the socket

    def negotiated_protocol(self) -> UInt8:
        return self.inner.negotiated_protocol()

    def fd(self) -> Int32:
        return self.inner.fd()

    def has_buffered_readable(self) -> Bool:
        return self.inner.has_buffered_readable()

    def unread(mut self, src: Span[UInt8, _]) raises:
        self.inner.unread(src)

    def wire_bytes_moved(self) -> Int:
        return self.inner.wire_bytes_moved()

    def pending_wait_is_write(
        self, pending_token: Int64, call_is_write: Bool
    ) -> Bool:
        return self.inner.pending_wait_is_write(pending_token, call_is_write)


struct _HeldConnector(Connector, Movable, Deinitable):
    comptime Stream = _HeldStream

    var inner: KernelTcpConnector
    var signals: ArcPointer[_Signals]

    def __init__(out self, signals: ArcPointer[_Signals]):
        self.inner = KernelTcpConnector.new()
        self.signals = signals.copy()

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> _HeldStream:
        var stream = self.inner.connect[RT](reactor, ip_be, port)
        # Cap the window the server may fill before the first read.
        set_so_rcvbuf(stream.fd(), _SOCKBUF_BYTES)
        return _HeldStream(stream^, self.signals.copy())

    def transport_kind(self) -> UInt8:
        return self.inner.transport_kind()

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        self.inner.set_dial_host(host^)


# -----------------------------------------------------------------------------
# The client leg.
# -----------------------------------------------------------------------------


struct _BigGet(ClientLeg):
    var port: UInt16
    var signals: ArcPointer[_Signals]
    var status: Int32
    var content_length: String
    var body: List[UInt8]

    def __init__(out self, port: UInt16, signals: ArcPointer[_Signals]):
        self.port = port
        self.signals = signals.copy()
        self.status = Int32(-1)
        self.content_length = String()
        self.body = List[UInt8]()

    def run(mut self) raises:
        var client = HttpClient[_HeldConnector].with_request_timeout_us(
            _HeldConnector(self.signals.copy()), _REQUEST_TIMEOUT_US
        )
        var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var req = build_get_request(
            Url.http(String("127.0.0.1"), self.port, String("/big")),
            HeaderMap(),
        )
        var resp = client.send_buffered[_Rt, EmptyBody](req^, reactor)
        self.status = resp.status
        self.content_length = resp.headers.get(String("Content-Length")).or_else(String("<absent>"))
        self.body = resp.body.take_bytes()


def test_large_response_flushes_byte_for_byte() raises:
    var signals = ArcPointer(_Signals())
    var router = Router()
    router.add(HttpMethod.get(), "/big", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=router^
    )
    # Every socket the listener accepts inherits this send buffer.
    set_so_sndbuf(server.listen_fd(), _SOCKBUF_BYTES)
    var port = server.local_port()
    var loop = DispatchServeLoop(server^, _BigBody(signals.copy()))
    var leg = _BigGet(port, signals.copy())
    serve_while(loop, leg)

    assert_equal(signals[].dispatched.load(), Int64(1), "one request dispatched")
    assert_equal(Int(leg.status), 200, "status")
    assert_equal(leg.content_length, String(_BODY_BYTES), "Content-Length")
    assert_equal(len(leg.body), _BODY_BYTES, "body length")
    var first_bad = -1
    for i in range(_BODY_BYTES):
        if leg.body[i] != _pattern(i):
            first_bad = i
            break
    assert_equal(first_bad, -1, "index of the first body byte that differs")
    print("  test_large_response_flushes_byte_for_byte PASS")


def main() raises:
    test_large_response_flushes_byte_for_byte()
    print("PASS komira_http_tls_e2e large response flush")
