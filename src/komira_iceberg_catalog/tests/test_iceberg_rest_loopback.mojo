# =============================================================================
# test_iceberg_rest_loopback.mojo -- the production HttpIcebergRestTransport
#   against an Iceberg REST catalog served over a real socket
# =============================================================================
#
# The welded test (test_iceberg_rest_catalog.mojo) drives the catalog client
# over ScriptedIcebergRestTransport, which records the IcebergRestRequest the
# client built; it never sends a byte. This test sends them: the catalog
# client over `HttpIcebergRestTransport[KernelTcpConnector]`, the transport
# that ships, against a `komira_http_server` HttpServer on 127.0.0.1 (an
# ephemeral port) whose dispatcher, `_FakeCatalog`, plays a standard Iceberg
# REST catalog and records every request as it arrived on the wire.
#
# The server and the client run in one process on two threads
# (komira_http_tls_e2e's `serve_while`): the server is stepped until the
# client leg finishes, and gives up after that runner's SERVE_DEADLINE_NS;
# each client request is bounded by `_REQUEST_TIMEOUT_US`, so a server that
# stops answering fails the leg with a timeout instead of hanging the action.
#
# The fake catalog:
#   * any request whose Authorization is not `Bearer <_TOKEN>` -> 401 with an
#     Iceberg ErrorModel (NotAuthorizedException);
#   * GET /v1/config -> 200, `prefix` "default-prefix" in defaults and
#     `_PREFIX` in overrides (the override must win);
#   * GET /v1/<_PREFIX>/namespaces/sales/tables/orders -> 200, a loadTable
#     response carrying `_LOCATION`;
#   * any other path -> 404 with an Iceberg ErrorModel (NoSuchTableException).
#
# The client leg, in order: an authenticated catalog loads sales.orders
# twice and sales.missing once; then a catalog with no token loads
# sales.orders.
#
# What each assertion proves, and the defect it catches:
#   * the metadata-location of both loads is `_LOCATION`: the 200 body crossed
#     the socket and was parsed (a transport that lost or mangled the body);
#   * the request paths, exactly and in order: the prefix from `overrides`
#     reached the wire (a client that ignored overrides, or dropped the
#     prefix, sends another path); config is fetched once for the three
#     calls of the authenticated catalog (a client that re-fetches config
#     per resolve sends more requests);
#   * the Authorization each request carried: `Bearer <_TOKEN>` on the four
#     authenticated requests and none on the anonymous one (a transport
#     that drops the request's headers);
#   * the Host each request carried is 127.0.0.1:<port> (a client that
#     sends its host without the non-default port);
#   * the 404 and 401 errors by exact message, ErrorModel body included (a
#     transport that swallows an error status, or a client that maps it to
#     anything but its IcebergRestError).
#
# `test_tls_connector_factory_accepted` builds the transport over the TLS
# connector production uses, from a factory that raises (a TlsConfig raises
# when it is built); it compiles only if the factory may raise.
#
# Standalone (`mojo_test`, not `test_srcs`): it opens sockets. The proof is
# `./buck2 test komira//src/komira_iceberg_catalog:test_iceberg_rest_loopback`.
# =============================================================================

from std.testing import assert_equal

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_client.pool import VERIFY_PEER
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_core.tls import TlsConfig
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_http_tls_e2e import ClientLeg, DispatchServeLoop, serve_while

from komira_iceberg_catalog import (
    HttpIcebergRestTransport,
    IcebergRestCatalog,
    StaticBearerToken,
)

comptime _HOST = "127.0.0.1"
comptime _TOKEN = "loopback-token-7f3a"
comptime _PREFIX = "lakehouse-prod"
comptime _LOCATION = "s3://wh/sales/orders/metadata/00007-9c1e.metadata.json"
comptime _ORDERS_PATH = "/v1/lakehouse-prod/namespaces/sales/tables/orders"
comptime _MISSING_PATH = "/v1/lakehouse-prod/namespaces/sales/tables/missing"
# Each request's bound, from send-start to the parsed response head. A
# loopback round trip takes milliseconds; five of these stay well inside the
# server's 120 s deadline.
comptime _REQUEST_TIMEOUT_US = 10_000_000

comptime _Transport = HttpIcebergRestTransport[KernelTcpConnector]
comptime _Catalog = IcebergRestCatalog[_Transport, StaticBearerToken]


def _config_body() -> String:
    return String(
        '{"defaults":{"prefix":"default-prefix"},'
        + '"overrides":{"prefix":"'
        + _PREFIX
        + '"}}'
    )


def _load_table_body() -> String:
    return String(
        '{"metadata-location":"'
        + _LOCATION
        + '","metadata":{"format-version":2,"table-uuid":"5e1f-loopback"},'
        + '"config":{}}'
    )


def _not_found_body() -> String:
    return String(
        '{"error":{"message":"The given table does not exist",'
        + '"type":"NoSuchTableException","code":404}}'
    )


def _unauthorized_body() -> String:
    return String(
        '{"error":{"message":"Not authorized to make this request",'
        + '"type":"NotAuthorizedException","code":401}}'
    )


# -----------------------------------------------------------------------------
# The fake catalog: a RequestDispatcher, stepped on the server's thread.
# -----------------------------------------------------------------------------


struct _FakeCatalog(RequestDispatcher):
    """Answers as described in the file header and records, per request, the
    path, the Authorization header ("" when absent) and the Host header."""

    var paths: List[String]
    var auths: List[String]
    var hosts: List[String]

    def __init__(out self):
        self.paths = List[String]()
        self.auths = List[String]()
        self.hosts = List[String]()

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        var path = String(req.path)
        # "<absent>" (not "") so a missing header and an empty one differ.
        var auth = req.headers.get(String("authorization")).or_else(
            String("<absent>")
        )
        self.paths.append(path.copy())
        self.auths.append(auth.copy())
        self.hosts.append(req.headers.get(String("host")).or_else(String("")))
        if auth != String("Bearer ") + _TOKEN:
            return _json_response(401, _unauthorized_body())
        if path == String("/v1/config"):
            return _json_response(200, _config_body())
        if path == String(_ORDERS_PATH):
            return _json_response(200, _load_table_body())
        return _json_response(404, _not_found_body())


def _json_response(status: Int, body: String) -> HttpResponse:
    var resp = HttpResponse(Int32(status))
    resp.headers[String("content-type")] = String("application/json")
    resp.headers[String("content-length")] = String(body.byte_length())
    var bytes = List[UInt8]()
    bytes.extend(Span(body.as_bytes()))
    resp.body = bytes^
    return resp^


# -----------------------------------------------------------------------------
# The client leg: the production transport, run on the client's thread.
# -----------------------------------------------------------------------------


def _kernel_tcp() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def _catalog(port: UInt16, token: String) -> _Catalog:
    return _Catalog(
        String(_HOST),
        _Transport(_kernel_tcp, request_timeout_us=_REQUEST_TIMEOUT_US),
        StaticBearerToken(token.copy()),
        port=port,
    )


struct _CatalogLeg(ClientLeg):
    """Runs the calls in the file header's order and keeps what each
    returned or raised, for the main thread to assert after the join."""

    var port: UInt16
    var first_location: String
    var second_location: String
    var resolved_prefix: String
    var not_found_error: String
    var unauthorized_error: String

    def __init__(out self, port: UInt16):
        self.port = port
        self.first_location = String("<not run>")
        self.second_location = String("<not run>")
        self.resolved_prefix = String("<not run>")
        self.not_found_error = String("<not run>")
        self.unauthorized_error = String("<not run>")

    def run(mut self) raises:
        var catalog = _catalog(self.port, String(_TOKEN))
        var first = catalog.load_table(String("sales"), String("orders"))
        self.first_location = first.metadata_location.copy()
        var second = catalog.load_table(String("sales"), String("orders"))
        self.second_location = second.metadata_location.copy()
        self.resolved_prefix = catalog.prefix()
        try:
            var found = catalog.load_table(String("sales"), String("missing"))
            self.not_found_error = (
                String("<no error; metadata-location '")
                + found.metadata_location
                + String("'>")
            )
        except e:
            self.not_found_error = String(e)

        var anonymous = _catalog(self.port, String(""))
        try:
            var found = anonymous.load_table(String("sales"), String("orders"))
            self.unauthorized_error = (
                String("<no error; metadata-location '")
                + found.metadata_location
                + String("'>")
            )
        except e:
            self.unauthorized_error = String(e)


def _expect_list(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + String(": count"))
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + String(" #") + String(i))


def test_production_transport_over_loopback() raises:
    var router = Router()
    router.add(HttpMethod.get(), "/", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=router^
    )
    var port = server.local_port()
    var loop = DispatchServeLoop(server^, _FakeCatalog())
    var leg = _CatalogLeg(port)
    serve_while(loop, leg)

    assert_equal(leg.first_location, String(_LOCATION), "first load")
    assert_equal(leg.second_location, String(_LOCATION), "second load")
    assert_equal(leg.resolved_prefix, String(_PREFIX), "prefix from overrides")

    var paths = List[String]()
    paths.append(String("/v1/config"))
    paths.append(String(_ORDERS_PATH))
    paths.append(String(_ORDERS_PATH))
    paths.append(String(_MISSING_PATH))
    paths.append(String("/v1/config"))
    _expect_list(loop.dispatcher.paths, paths, String("request path"))

    var bearer = String("Bearer ") + _TOKEN
    var auths = List[String]()
    for _ in range(4):
        auths.append(bearer.copy())
    auths.append(String("<absent>"))
    _expect_list(loop.dispatcher.auths, auths, String("Authorization"))

    var host = String(_HOST) + String(":") + String(Int(port))
    var hosts = List[String]()
    for _ in range(5):
        hosts.append(host.copy())
    _expect_list(loop.dispatcher.hosts, hosts, String("Host"))

    assert_equal(
        leg.not_found_error,
        String("IcebergRestError: table not found (HTTP 404) for")
        + String(" 'sales.missing' — body: ")
        + _not_found_body(),
        "the 404 error",
    )
    assert_equal(
        leg.unauthorized_error,
        String("IcebergRestError: GET /v1/config returned HTTP 401 — body: ")
        + _unauthorized_body(),
        "the 401 error",
    )
    print("  test_production_transport_over_loopback PASS")


# -----------------------------------------------------------------------------
# The production connector's factory raises.
# -----------------------------------------------------------------------------


def _public_ca_tls() raises -> TlsConnector[KernelTcpConnector]:
    var config = TlsConfig()
    config.enable_verify_default()
    return TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), VERIFY_PEER
    )


def test_tls_connector_factory_accepted() raises:
    var transport = HttpIcebergRestTransport[TlsConnector[KernelTcpConnector]](
        _public_ca_tls, request_timeout_us=_REQUEST_TIMEOUT_US
    )
    _ = transport^
    print("  test_tls_connector_factory_accepted PASS")


def main() raises:
    test_production_transport_over_loopback()
    test_tls_connector_factory_accepted()
    print("PASS komira_iceberg_catalog loopback")
