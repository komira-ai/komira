# =============================================================================
# test_tls_h1_get.mojo -- HTTP/1.1 over TLS, real server, real client
# =============================================================================
#
# A real `HttpServer` holding the fixture leaf (ALPN h2, http/1.1) on
# 127.0.0.1:0, stepped through its TLS accept path
# (`accept_one_and_register_tls`), handshake driver (`drive_tls_handshake`) and
# h1-over-TLS read round; a real `HttpClient` over `TlsConnector` that trusts
# only the fixture root, presents SNI `localhost`, and offers only `http/1.1`.
#
# What it proves: the client verifies the server's chain and name and the two
# agree on http/1.1; the request crosses the TLS record layer both ways; the
# response the client hands back is the server's response, byte for byte: the
# status line, each header, the body. The h1-over-TLS server answers every
# well-formed request with its built-in health response, so those bytes are the
# expected value.
#
# Defects it catches: a handshake or verify regression on either side (the GET
# raises); a broken ALPN choice that pivots an http/1.1-only client to h2 (the
# client cannot parse the reply); a record-layer or framing defect that loses,
# reorders or truncates bytes (a header or the body differs).
# =============================================================================

from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.tls_connector import TlsConnector
from komira_http_client.url import Url
from komira_http_core.codec import HttpMethod
from komira_http_core.tls import tls_init
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_http_tls_e2e import (
    ClientLeg,
    ROOT_CA_PATH,
    TlsServeLoop,
    client_tls_connector,
    serve_while,
    server_tls_config,
)

comptime _Rt = BlockingRuntime[NoopSink]
comptime _REQUEST_TIMEOUT_US = 10_000_000


struct _H1Get(ClientLeg):
    """One GET over TLS; records what the client handed back."""

    var port: UInt16
    var status: Int32
    var reason: String
    var header_count: Int
    var content_type: String
    var content_length: String
    var connection: String
    var body: List[UInt8]

    def __init__(out self, port: UInt16):
        self.port = port
        self.status = Int32(-1)
        self.reason = String()
        self.header_count = -1
        self.content_type = String()
        self.content_length = String()
        self.connection = String()
        self.body = List[UInt8]()

    def run(mut self) raises:
        var connector = client_tls_connector(
            ROOT_CA_PATH, String("localhost"), offer_h2=False
        )
        var client = HttpClient[
            TlsConnector[KernelTcpConnector]
        ].with_request_timeout_us(connector^, _REQUEST_TIMEOUT_US)
        var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var req = build_get_request(
            Url.https(String("127.0.0.1"), self.port, String("/health")),
            HeaderMap(),
        )
        var resp = client.send_buffered[_Rt, EmptyBody](req^, reactor)
        self.status = resp.status
        self.reason = resp.reason.copy()
        self.header_count = resp.headers.len()
        self.content_type = resp.headers.get(String("Content-Type")).or_else(String("<absent>"))
        self.content_length = resp.headers.get(String("Content-Length")).or_else(String("<absent>"))
        self.connection = resp.headers.get(String("Connection")).or_else(String("<absent>"))
        self.body = resp.body.take_bytes()


def _text(bytes: List[UInt8]) -> String:
    var s = String()
    for b in bytes:
        s += chr(Int(b))
    return s^


def test_h1_get_over_tls_is_byte_exact() raises:
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
        tls_config=server_tls_config(),
    )
    var port = server.local_port()
    var loop = TlsServeLoop(server^)
    var leg = _H1Get(port)
    serve_while(loop, leg)

    assert_equal(Int(leg.status), 200, "status")
    assert_equal(leg.reason, String("OK"), "reason phrase")
    assert_equal(leg.header_count, 3, "exactly the server's three headers")
    assert_equal(leg.content_type, String("text/plain"), "Content-Type")
    assert_equal(leg.content_length, String("13"), "Content-Length")
    assert_equal(leg.connection, String("keep-alive"), "Connection")
    assert_equal(len(leg.body), 13, "body length")
    assert_equal(_text(leg.body), String("Hello, World!"), "body bytes")
    var stats = loop.server.serve_for_iterations(0, Int32(0))
    assert_equal(Int(stats.reqs_handled), 1, "the server answered one request")
    print("  test_h1_get_over_tls_is_byte_exact PASS")


def main() raises:
    tls_init()
    test_h1_get_over_tls_is_byte_exact()
    print("PASS komira_http_tls_e2e h1 GET over TLS")
