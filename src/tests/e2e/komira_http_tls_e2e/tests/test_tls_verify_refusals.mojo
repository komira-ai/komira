# =============================================================================
# test_tls_verify_refusals.mojo -- the client refuses a peer it cannot verify,
# and the server lives on
# =============================================================================
#
# One real `HttpServer` holding the fixture leaf (signed by the fixture root,
# naming `localhost` and `127.0.0.1`), three real `HttpClient` dials in turn:
#
#   1. UNTRUSTED ROOT: the client's only trust anchor is an unrelated CA
#      (`smoke_cert.pem`), SNI `localhost`. The chain does not reach an anchor:
#      the handshake must fail on the client with s2n's verification error.
#   2. WRONG NAME: the client trusts the fixture root but presents and verifies
#      `evil.example`, which the leaf does not name. The chain is good and only
#      the name is wrong: the handshake must fail the same way.
#   3. CONTROL ON THE SAME SERVER: root trusted, SNI `localhost`: a 200 with
#      the server's health body. The server drove two failed handshakes to
#      ERROR and closed them; it must still accept, handshake and serve.
#
# Defects it catches: a client that accepts an unanchored chain (1 succeeds), a
# client that checks the chain but not the name (2 succeeds), a server whose
# failed handshake poisons its accept loop (3 fails), a server that leaks the
# entry of a failed handshake (after the clients have gone, the server is
# stepped until its conn table is empty; a leaked entry keeps it non-empty),
# and a
# fixture or harness defect posing as a refusal (3 is the control that the
# setup can succeed, so 1 and 2 fail for their stated reason). Both refusals
# carry s2n's one text for a failed validation, so the text alone does not tell
# a chain failure from a name failure; 2 trusts the real root, which leaves the
# name as its only cause.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_clock import now_ns

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
    OTHER_CA_PATH,
    ROOT_CA_PATH,
    TlsServeLoop,
    client_tls_connector,
    serve_while,
    server_tls_config,
)

comptime _Rt = BlockingRuntime[NoopSink]
comptime _REQUEST_TIMEOUT_US = 10_000_000

# What `TlsConnector.connect` raises when s2n ends the client handshake in
# ERROR, and s2n's text for a certificate that fails validation.
comptime _HANDSHAKE_FAILED = "TlsConnector.connect: handshake failed"
comptime _UNTRUSTED = "Certificate is untrusted"


def _text(bytes: List[UInt8]) -> String:
    var s = String()
    for b in bytes:
        s += chr(Int(b))
    return s^


def _get(
    port: UInt16, trust: StaticString, server_name: String
) raises -> String:
    """GET / and return `<status> <body>`; raises what the client raised."""
    var connector = client_tls_connector(trust, server_name, offer_h2=False)
    var client = HttpClient[
        TlsConnector[KernelTcpConnector]
    ].with_request_timeout_us(connector^, _REQUEST_TIMEOUT_US)
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var req = build_get_request(
        Url.https(String("127.0.0.1"), port, String("/health")), HeaderMap()
    )
    var resp = client.send_buffered[_Rt, EmptyBody](req^, reactor)
    return String(Int(resp.status)) + " " + _text(resp.body.take_bytes())


def _refusal(port: UInt16, trust: StaticString, server_name: String) -> String:
    """The client's error text, or `ACCEPTED: <status> <body>` if it accepted."""
    try:
        return "ACCEPTED: " + _get(port, trust, server_name)
    except e:
        return String(e)


struct _BadBadGood(ClientLeg):
    var port: UInt16
    var untrusted_root: String
    var wrong_name: String
    var control: String

    def __init__(out self, port: UInt16):
        self.port = port
        self.untrusted_root = String()
        self.wrong_name = String()
        self.control = String()

    def run(mut self) raises:
        self.untrusted_root = _refusal(self.port, OTHER_CA_PATH, String("localhost"))
        self.wrong_name = _refusal(self.port, ROOT_CA_PATH, String("evil.example"))
        self.control = _get(self.port, ROOT_CA_PATH, String("localhost"))


def _assert_refused(what: String, err: String) raises:
    assert_true(
        _HANDSHAKE_FAILED in err and _UNTRUSTED in err,
        what + ": want a client verification failure, got: " + err,
    )


def test_client_refuses_and_server_survives() raises:
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
        tls_config=server_tls_config(),
    )
    var port = server.local_port()
    var loop = TlsServeLoop(server^)
    var leg = _BadBadGood(port)
    serve_while(loop, leg)

    _assert_refused("untrusted root", leg.untrusted_root)
    _assert_refused("wrong server name", leg.wrong_name)
    assert_equal(leg.control, String("200 Hello, World!"), "the next good connection")
    var stats = loop.server.serve_for_iterations(0, Int32(0))
    assert_equal(
        Int(stats.reqs_handled), 1, "only the verified connection reached HTTP"
    )
    # Every client has closed its socket. Step the server until it has seen
    # each close; a failed handshake whose entry was never removed stays.
    var give_up = now_ns() + UInt64(5_000_000_000)
    while loop.server.live_conn_count() > 0 and now_ns() < give_up:
        loop.step()
    assert_equal(
        loop.server.live_conn_count(), 0, "live connections after every client left"
    )
    print("  untrusted root: " + leg.untrusted_root)
    print("  wrong name:     " + leg.wrong_name)
    print("  test_client_refuses_and_server_survives PASS")


def main() raises:
    tls_init()
    test_client_refuses_and_server_survives()
    print("PASS komira_http_tls_e2e verification refusals")
