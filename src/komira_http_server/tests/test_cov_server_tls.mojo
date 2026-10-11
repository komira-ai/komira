# =============================================================================
# test_cov_server_tls.mojo: `HttpServer.serve_one_iteration` on a TLS
# listener, from accept through the handshake to HTTP/1.1 or h2
# =============================================================================
#
# A real TLS `HttpServer` on a loopback listener and an s2n client on a
# non-blocking socket in this process. The test alternates one client
# handshake step with one server poll cycle until both ends are done, then
# speaks HTTP/1.1 or h2 (chosen by ALPN) and reads the answer.
#
# Groups (and the defect each would catch):
#   H  the handshake: a failed handshake (a plaintext client) leaving the
#      connection in the table; a completed one not reaching the HTTP round.
#   A  ALPN: h2 negotiated but the connection left on the HTTP/1.1 round
#      (or the reverse: http/1.1 negotiated and h2 state installed).
#   1  HTTP/1.1 over TLS: no answer, or the connection not dropped when the
#      client closes.
#   2  h2: no answer on stream 1, an invalid preface or a failed write not
#      closing.
#   D  the dispatch loop on a TLS connection: `serve_one_iteration_dispatch`
#      shares the connection table with `serve_one_iteration`, so a TLS
#      connection accepted by the latter can reach the former. It must be
#      dropped, never read as plaintext (komira-ai/komira#635: a
#      RequestDispatcher cannot be served over TLS).
# =============================================================================

from std.ffi import external_call
from std.pathlib import Path
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_HEADERS,
    FRAME_SETTINGS,
    decode_frame,
    encode_frame_header,
)
from komira_http_core.codec.h2.hpack import (
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
)
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_core.codec.types import HttpMethod
from komira_http_core.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    tls_init,
)
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig


comptime CERT = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime KEY = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


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


def _frame(kind: UInt8, flags: UInt8, sid: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    encode_frame_header(UInt32(len(payload)), kind, flags, UInt32(sid), out)
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


struct _Rig(Movable):
    """A TLS server and one client connected to it."""

    var server: HttpServer[NoopGrpcDispatch]
    var cli_cfg: TlsConfig
    var client: TlsConnection
    var fd: Int32
    var got: List[UInt8]

    def __init__(
        out self, server_alpn: List[String], client_alpn: List[String]
    ) raises:
        tls_init()
        var srv_cfg = TlsConfig()
        srv_cfg.load_cert(Path(CERT).read_text(), Path(KEY).read_text())
        if len(server_alpn) > 0:
            srv_cfg.set_alpn_protocols(server_alpn)
        var router = Router()
        router.add(HttpMethod.get(), "/", 1)
        self.server = HttpServer(
            config=HttpServerConfig.default_ephemeral(),
            router=router^,
            tls_config=srv_cfg^,
        )
        assert_true(self.server.is_tls_enabled())
        self.cli_cfg = TlsConfig()
        self.cli_cfg.wipe_trust()
        self.cli_cfg.disable_verify()
        if len(client_alpn) > 0:
            self.cli_cfg.set_alpn_protocols(client_alpn)
        self.client = TlsConnection.new_client(self.cli_cfg)
        self.fd = _connect(self.server.local_port())
        self.client.bind_fd(self.fd)
        self.got = List[UInt8]()
        for _ in range(50):
            self.step()
            if self.server.live_conn_count() == 1:
                return
        raise Error("the server did not accept the connection")

    def __deinit__(deinit self):
        if self.fd >= 0:
            _ = external_call["close", Int32](self.fd)

    def step(mut self) raises:
        _ = self.server.serve_one_iteration(Int32(20_000))

    def handshake(mut self) raises:
        for _ in range(400):
            var o = self.client.handshake()
            if o == TLS_OUTCOME_ERROR:
                raise Error("client handshake failed")
            if o == TLS_OUTCOME_DONE:
                return
            self.step()
        raise Error("the handshake did not finish")

    def write(mut self, bytes: List[UInt8]) raises:
        var off = 0
        while off < len(bytes):
            var r = self.client.send(Span(bytes)[off:])
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                raise Error("client send failed: " + String(Int(r[0])))
            off += r[1]

    def read(mut self) -> Bool:
        """Append what is readable; False once the session has ended."""
        while True:
            var buf = List[UInt8]()
            buf.reserve(16384)
            var r = self.client.recv(buf, 16384)
            if r[0] == TLS_OUTCOME_BLOCKED_ON_READ:
                return True
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                return False
            for i in range(r[1]):
                self.got.append(buf[i])

    def step_until_dropped(mut self) raises:
        for _ in range(200):
            self.step()
            if self.server.live_conn_count() == 0:
                return
        raise Error("the server kept the connection")


# -----------------------------------------------------------------------------
# H: the handshake.
# -----------------------------------------------------------------------------


def test_plaintext_client_fails_the_handshake_and_is_dropped() raises:
    var empty = List[String]()
    var r = _Rig(empty, empty)
    var req = _bytes("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    var rc = external_call["send", Int64](
        r.fd, req.unsafe_ptr(), UInt64(len(req)), Int32(0)
    )
    assert_equal(Int(rc), len(req))
    # The TLS layer reads "GET " as a record header and waits for the rest
    # of that record; the client's end of stream ends the handshake.
    _ = external_call["shutdown", Int32](r.fd, Int32(1))
    r.step_until_dropped()


# -----------------------------------------------------------------------------
# 1: HTTP/1.1 over TLS.
# -----------------------------------------------------------------------------


def _http11_round_trip(server_alpn: List[String], client_alpn: List[String]) raises:
    var r = _Rig(server_alpn, client_alpn)
    r.handshake()
    r.write(_bytes("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
    for _ in range(200):
        r.step()
        _ = r.read()
        if _text(r.got).find("\r\n\r\n") >= 0:
            break
    var t = _text(r.got)
    assert_true(t.startswith("HTTP/1.1 200 OK\r\n"), t)
    assert_equal(r.server.live_conn_count(), 1)
    _ = r.client.shutdown()
    r.step_until_dropped()


def test_http11_over_tls_without_alpn() raises:
    var empty = List[String]()
    _http11_round_trip(empty, empty)


def test_http11_negotiated_by_alpn_stays_on_http11() raises:
    """The server offers h2 and http/1.1, the client only http/1.1: ALPN
    picks http/1.1 and the connection answers HTTP/1.1."""
    var both: List[String] = ["h2", "http/1.1"]
    var h1: List[String] = ["http/1.1"]
    _http11_round_trip(both, h1)


# -----------------------------------------------------------------------------
# 2: h2 by ALPN.
# -----------------------------------------------------------------------------


def test_h2_negotiated_by_alpn_answers_on_stream_1() raises:
    var h2: List[String] = ["h2"]
    var r = _Rig(h2, h2)
    r.handshake()
    var enc = HpackEncoder()
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String(":method"), String("GET")))
    hs.append(HpackHeader(String(":scheme"), String("https")))
    hs.append(HpackHeader(String(":path"), String("/")))
    hs.append(HpackHeader(String(":authority"), String("example.com")))
    var b = _bytes(PREFACE)
    b.extend(Span(_frame(FRAME_SETTINGS, UInt8(0), 0, List[UInt8]())))
    b.extend(
        Span(
            _frame(
                FRAME_HEADERS,
                FLAG_END_HEADERS | FLAG_END_STREAM,
                1,
                enc.encode_block(hs^),
            )
        )
    )
    r.write(b)
    var dec = HpackDecoder()
    var status = String("<none>")
    var data_len = 0
    var cursor = 0
    for _ in range(200):
        r.step()
        _ = r.read()
        while cursor < len(r.got):
            var res = decode_frame(Span(r.got)[cursor:], 1 << 24)
            if res.status != 0:
                break
            cursor += res.consumed
            ref f = res.frame
            if f.header.kind == FRAME_HEADERS and f.header.stream_id == 1:
                var got_hs = dec.decode_block(Span(f.payload))
                for i in range(len(got_hs)):
                    if String(got_hs[i].name) == ":status":
                        status = String(got_hs[i].value)
            if f.header.kind == FRAME_DATA and f.header.stream_id == 1:
                data_len += len(f.payload)
        if status != "<none>" and data_len > 0:
            break
    assert_equal(status, String("200"))
    assert_true(data_len > 0, "no DATA on stream 1")
    assert_equal(r.server.live_conn_count(), 1)


def test_h2_invalid_preface_closes() raises:
    var h2: List[String] = ["h2"]
    var r = _Rig(h2, h2)
    r.handshake()
    r.write(_bytes("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
    r.step_until_dropped()


def test_h2_write_failure_closes() raises:
    """The server's end can no longer write (its write side is shut): the
    round's flush of the server SETTINGS fails and the connection goes."""
    var h2: List[String] = ["h2"]
    var r = _Rig(h2, h2)
    r.handshake()
    for _ in range(20):
        r.step()
    assert_equal(r.server.live_conn_count(), 1)
    _ = external_call["shutdown", Int32](r.server._conns[0].fd(), Int32(1))
    var b = _bytes(PREFACE)
    b.extend(Span(_frame(FRAME_SETTINGS, UInt8(0), 0, List[UInt8]())))
    r.write(b)
    r.step_until_dropped()


# -----------------------------------------------------------------------------
# D: the dispatch loop on a TLS connection.
# -----------------------------------------------------------------------------


comptime _Rt = BlockingRuntime[NoopSink]


struct _Counting(RequestDispatcher):
    """Answers 200 and counts its calls."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.calls += 1
        return HttpResponse.ok(String("dispatched"))


def test_dispatch_loop_drops_a_tls_connection_unread() raises:
    """`serve_one_iteration` accepts a TLS connection, the client sends its
    ClientHello, and the next poll cycle is `serve_one_iteration_dispatch`:
    the connection is dropped, the dispatcher is never called and nothing is
    written back (no plaintext 400 for the ClientHello, no ServerHello)."""
    var empty = List[String]()
    var r = _Rig(empty, empty)
    var o = r.client.handshake()
    assert_equal(Int(o), Int(TLS_OUTCOME_BLOCKED_ON_READ), "no ClientHello sent")
    var d = _Counting()
    for _ in range(200):
        _ = r.server.serve_one_iteration_dispatch[_Counting, _Rt](
            d, Int32(20_000)
        )
        if r.server.live_conn_count() == 0:
            break
    assert_equal(r.server.live_conn_count(), 0, "the TLS connection was kept")
    assert_equal(d.calls, 0, "the dispatcher ran on a TLS connection")
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var n = external_call["recv", Int64](
        r.fd, buf.unsafe_ptr(), UInt64(4096), Int32(0)
    )
    assert_true(n <= 0, "the server wrote " + String(n) + " bytes back")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
