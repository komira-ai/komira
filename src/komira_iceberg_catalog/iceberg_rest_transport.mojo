# =============================================================================
# komira_iceberg_catalog/iceberg_rest_transport.mojo — the Iceberg-REST HTTP
#   transport SEAM + the production HTTP transport + the scripted test double.
# =============================================================================
#
# WHAT THIS IS. The narrow HTTP-GET seam the Iceberg REST catalog client
# resolves through. A `IcebergRestTransport` trait — `get(request) ->
# IcebergRestResponse` — so the whole REST resolve path is driveable with:
#   * `HttpIcebergRestTransport[C]` — production: a real GET over the shipped
#     `komira_http` `HttpClient[C]` (C = TlsConnector in prod; `http` over a
#     plaintext connector), exactly the synchronous-per-call shape other
#     komira HTTP transports use.
#   * `ScriptedIcebergRestTransport` — test: returns SCRIPTED JSON responses in
#     FIFO call order + records the request path AND the request's
#     Authorization header of each call — so the loadTable falsifier can assert
#     BOTH the sequence of GETs (config -> loadTable) AND that the bearer token
#     was attached. ZERO sockets, ZERO network.
#
# WHY a transport seam. The REST resolve is a MULTI-call sequence (GET /v1/config
# to learn the prefix, then GET /v1/{prefix}/namespaces/{ns}/tables/{tbl}). A
# call-level transport seam lets a test queue the exact response for each call in
# order + assert the path + the Authorization header of each — the cleanest way
# to prove the resolve contract + the bearer-token attach WITHOUT a socket. The
# production transport still rides the full `komira_http` spine underneath
# (NOTHING about transport is reinvented). Same substitution-seam discipline
# as the other komira transports.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The scripted double holds owned
# `List[String]` queues. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_GET, HttpMethod
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §0 — IcebergRestRequest — a fully-formed GET (host + port + path + headers).
# =============================================================================


struct IcebergRestRequest(Movable, Deinitable):
    """A ready-to-send Iceberg REST GET: the host, the port, the absolute
    request path (already percent-encoded), and the outgoing header set (which
    carries `Authorization: Bearer <token>` when a credential provider yielded
    one).

    Field layout:
      var host: String                 — the catalog host (e.g. `catalog.example.com`)
      var port: UInt16                  — the catalog port (443 by default)
      var path: String                  — the absolute request path
                                          (`/v1/config`, `/v1/{prefix}/namespaces/
                                          {ns}/tables/{tbl}`)
      var header_names: List[String]    — outgoing header names (parallel to values)
      var header_values: List[String]   — outgoing header values

    a plain owned-field struct — only `String`/`List[String]` heap fields,
    no pointer, no wildcard origin, lives only as a value."""

    var host: String
    var port: UInt16
    var path: String
    var header_names: List[String]
    var header_values: List[String]

    def __init__(
        out self,
        var host: String,
        port: UInt16,
        var path: String,
        var header_names: List[String],
        var header_values: List[String],
    ):
        self.host = host^
        self.port = port
        self.path = path^
        self.header_names = header_names^
        self.header_values = header_values^

    def header_value(self, name: String) -> String:
        """Look up an outgoing header value by (case-sensitive) name; empty
        String if absent. Used by the falsifier to assert the Authorization
        header was attached."""
        for i in range(len(self.header_names)):
            if self.header_names[i] == name:
                return String(self.header_values[i])
        return String("")


# =============================================================================
# §1 — IcebergRestResponse — the transport's reply (status + JSON body).
# =============================================================================


struct IcebergRestResponse(Copyable, Movable, Deinitable):
    """An Iceberg REST HTTP reply: the HTTP status + the JSON body bytes.

    Field layout:
      var status: Int    — the HTTP status (200 OK; 404 for an absent namespace/
                           table — the Iceberg REST spec returns a real 404 with a
                           `NoSuchTableException` / `NoSuchNamespaceException`
                           error envelope, UNLIKE the AWS query protocols which
                           return 400)
      var body: String   — the JSON response body

    a plain owned-field struct (Int + String), no pointer field."""

    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^

    @always_inline
    def is_ok(self) -> Bool:
        return self.status == 200


# =============================================================================
# §2 — IcebergRestTransport — the narrow GET seam.
# =============================================================================


trait IcebergRestTransport(Movable, Deinitable):
    """The transport the Iceberg REST catalog client GETs a request through. One
    method: `get(request) -> IcebergRestResponse`. Production sends over HTTP;
    the test double returns scripted JSON. No UnsafePointer crosses the boundary
    — an `IcebergRestRequest` in, an `IcebergRestResponse` out."""

    def get(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        """Send the GET; return the HTTP status + JSON body. RAISES on a
        transport error (a dial failure / a malformed response). A non-200
        status is NOT a raise here — it is returned as an IcebergRestResponse for
        the client to map to a typed error (a 404 -> NoSuchTable/Namespace)."""
        ...


# =============================================================================
# §3 — ScriptedIcebergRestTransport — the TEST DOUBLE (no sockets, no network).
# =============================================================================


struct ScriptedIcebergRestTransport(
    IcebergRestTransport, Movable, Deinitable
):
    """An IcebergRestTransport that returns SCRIPTED responses in FIFO call order
    + (a) records the request PATH of each call and (b) records the Authorization
    header of each call — so the loadTable falsifier can assert BOTH the sequence
    of GETs (config -> loadTable) AND that the bearer token was threaded onto
    each request. ZERO sockets, ZERO network.

    Usage:
      var t = ScriptedIcebergRestTransport()
      t.queue_response(200, config_json)
      t.queue_response(200, load_table_json)
      ...
      # after driving the client:
      t.call_path(0)  == "/v1/config"
      t.call_path(1)  == "/v1/prod/namespaces/db/tables/orders"
      t.call_auth(1)  == "Bearer <token>"

    a plain owned-field struct — owned `List[Int]`/`List[String]` queues,
    no pointer field, no wildcard origin."""

    var _resp_status: List[Int]
    var _resp_body: List[String]
    var _cursor: Int
    var _call_paths: List[String]
    var _call_auths: List[String]

    def __init__(out self):
        self._resp_status = List[Int]()
        self._resp_body = List[String]()
        self._cursor = 0
        self._call_paths = List[String]()
        self._call_auths = List[String]()

    def queue_response(mut self, status: Int, var body: String):
        """Queue the next scripted response (FIFO). Each `get` consumes one."""
        self._resp_status.append(status)
        self._resp_body.append(body^)

    def call_count(self) -> Int:
        """How many `get` calls the client made (the op-count proof — e.g.
        config is fetched ONCE + cached across loadTable calls)."""
        return len(self._call_paths)

    def call_path(self, i: Int) -> String:
        """The request path of the i-th `get` call (call-order path assertion)."""
        return String(self._call_paths[i])

    def call_auth(self, i: Int) -> String:
        """The Authorization header of the i-th `get` call (assert the bearer
        token was attached); empty String if the call had no Authorization
        header (the no-auth path)."""
        return String(self._call_auths[i])

    def get(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        # Record the call (path + Authorization header) for assertion.
        self._call_paths.append(String(request.path))
        self._call_auths.append(request.header_value(String("Authorization")))
        if self._cursor >= len(self._resp_status):
            raise Error(
                String(
                    "ScriptedIcebergRestTransport.get: no scripted response for"
                    " call #"
                )
                + String(self._cursor)
                + String(" (path ")
                + request.path
                + String("); queue more responses")
            )
        var status = self._resp_status[self._cursor]
        var body = String(self._resp_body[self._cursor])
        self._cursor += 1
        return IcebergRestResponse(status, body^)


# =============================================================================
# §4 — HttpIcebergRestTransport[C] — the PRODUCTION transport over komira_http.
# =============================================================================
#
# A real GET over the `HttpClient[C]` + a fresh `BlockingRuntime` per
# call, the synchronous per-call shape (a fresh connector, a synchronous
# `send_buffered`). C = a public-CA `TlsConnector[KernelTcpConnector]` in
# prod. The URL's scheme follows the connector: `https` over a TLS connector,
# `http` over a plaintext one (the HttpClient refuses any other pairing, so
# the connector is the only source of the scheme that can be right).


struct HttpIcebergRestTransport[C: Connector](
    IcebergRestTransport, Movable, Deinitable
):
    """The production IcebergRestTransport: dials a fresh connector + drives ONE
    synchronous GET per call over the shipped HttpClient. Parametric over the
    HTTP connector `C` (TLS in prod). Reuses the HTTP spine entirely — reinvents
    nothing.

    `mk_connector` makes the connector for each call; it may raise (building a
    `TlsConnector` loads its `TlsConfig`, which raises). `request_timeout_us`
    bounds each request between send-start and the parsed response head; 0
    selects the HttpClient's default (`HttpClientConfig.defaults()`).

    the connector factory is a `def () raises thin -> C` fn-ptr field
    (a code pointer: no heap, no wildcard origin). No owning pointer
    field."""

    # The connector factory — a `thin` (non-capturing) fn-ptr, the
    # plain-old-data fn-ptr field (a code pointer, no heap).
    var _mk_connector: def () raises thin -> Self.C
    var _request_timeout_us: Int

    def __init__(
        out self,
        mk_connector: def () raises thin -> Self.C,
        *,
        request_timeout_us: Int = 0,
    ):
        self._mk_connector = mk_connector
        self._request_timeout_us = request_timeout_us

    def get(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        # Build the outgoing HeaderMap from the request's header set.
        var headers = HeaderMap()
        for i in range(len(request.header_names)):
            headers.append(
                String(request.header_names[i]),
                String(request.header_values[i]),
            )
        # Dial a fresh connector + drive one synchronous GET (one
        # connector per call).
        var connector = self._mk_connector()
        # The scheme follows the connector. A plaintext connector sends the
        # bearer token in cleartext: it is for loopback tests only.
        var url: Url
        if connector.is_tls():
            url = Url.https(
                String(request.host), request.port, String(request.path)
            )
        else:
            url = Url.http(
                String(request.host), request.port, String(request.path)
            )
        var req = build_request_with_body[EmptyBody](
            HttpMethod(code=HTTP_METHOD_GET),
            url^,
            headers^,
            EmptyBody.new(),
        )
        var client = HttpClient[Self.C].with_request_timeout_us(
            connector^, self._request_timeout_us
        )
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()
        var body = String(unsafe_from_utf8=Span(resp_bytes))
        return IcebergRestResponse(status, body^)
