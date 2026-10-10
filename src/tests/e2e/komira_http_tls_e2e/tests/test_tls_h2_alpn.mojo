# =============================================================================
# test_tls_h2_alpn.mojo -- the ALPN pivot to HTTP/2, real server, real client
# =============================================================================
#
# One real `HttpServer` holding the fixture leaf with ALPN `[h2, http/1.1]`,
# two real `HttpClient`s against it in turn:
#
#   1. a client offering `[h2, http/1.1]`. Both sides must take h2: the client
#      dials into its h2 pool (and never its h1 pool), and the server answers
#      from its h2 serve loop, whose matched-route response is
#      `Hello from HTTP/2!` with `content-length` and `content-type`. The h1
#      serve loop cannot produce that body, so the body is the server-side
#      proof of the pivot.
#   2. the control: a client offering only `http/1.1` to the SAME server gets
#      the h1 health response. So (1) differs because of what was negotiated,
#      not because of the route or the server.
#
# Defects it catches: a server that stops advertising h2 or ignores the
# negotiated protocol (leg 1 gets the h1 body and an h1 dial); a client that
# ignores ALPN (its h2 pool stays empty); an h2 framing, HPACK or flow-control
# defect on either side (the status, a header or the body differs, or the
# request raises).
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


@fieldwise_init
struct _Seen(Copyable, Movable):
    """What one client handed back, and which of its pools it dialed."""

    var status: Int32
    var content_type: String
    var content_length: String
    var body: String
    var h2_dials: Int
    var h1_dials: Int


def _text(bytes: List[UInt8]) -> String:
    var s = String()
    for b in bytes:
        s += chr(Int(b))
    return s^


def _get(port: UInt16, offer_h2: Bool) raises -> _Seen:
    var connector = client_tls_connector(
        ROOT_CA_PATH, String("localhost"), offer_h2=offer_h2
    )
    var client = HttpClient[
        TlsConnector[KernelTcpConnector]
    ].with_request_timeout_us(connector^, _REQUEST_TIMEOUT_US)
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var req = build_get_request(
        Url.https(String("127.0.0.1"), port, String("/hello")), HeaderMap()
    )
    var resp = client.send_buffered[_Rt, EmptyBody](req^, reactor)
    return _Seen(
        status=resp.status,
        content_type=resp.headers.get(String("content-type")).or_else(String("<absent>")),
        content_length=resp.headers.get(String("content-length")).or_else(String("<absent>")),
        body=_text(resp.body.take_bytes()),
        h2_dials=client.h2_pool_dials_total(),
        h1_dials=client.h1_pool_dials_total(),
    )


struct _H2ThenH1(ClientLeg):
    var port: UInt16
    var h2: Optional[_Seen]
    var h1: Optional[_Seen]

    def __init__(out self, port: UInt16):
        self.port = port
        self.h2 = None
        self.h1 = None

    def run(mut self) raises:
        self.h2 = _get(self.port, offer_h2=True)
        self.h1 = _get(self.port, offer_h2=False)


def test_alpn_pivots_both_sides_to_h2() raises:
    var router = Router()
    router.add(HttpMethod.get(), "/hello", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
        tls_config=server_tls_config(),
    )
    var port = server.local_port()
    var loop = TlsServeLoop(server^)
    var leg = _H2ThenH1(port)
    serve_while(loop, leg)

    var h2 = leg.h2.value().copy()
    assert_equal(h2.h2_dials, 1, "the h2-offering client dialed into its h2 pool")
    assert_equal(h2.h1_dials, 0, "and never into its h1 pool")
    assert_equal(Int(h2.status), 200, "h2 status")
    assert_equal(h2.body, String("Hello from HTTP/2!"), "the server's h2 serve loop answered")
    assert_equal(h2.content_length, String("18"), "h2 content-length")
    assert_equal(h2.content_type, String("text/plain"), "h2 content-type")

    var h1 = leg.h1.value().copy()
    assert_equal(h1.h2_dials, 0, "control: an http/1.1-only client never dials h2")
    assert_equal(h1.h1_dials, 1, "control: it dials h1")
    assert_equal(Int(h1.status), 200, "control status")
    assert_equal(h1.body, String("Hello, World!"), "control: the h1 serve loop answered")
    print("  test_alpn_pivots_both_sides_to_h2 PASS")


def main() raises:
    tls_init()
    test_alpn_pivots_both_sides_to_h2()
    print("PASS komira_http_tls_e2e ALPN pivot to h2")
