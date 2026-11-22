# =============================================================================
# iceberg_catalog/iceberg_rest_transport.mojo — the Iceberg-REST HTTP
#   transport SEAM + the production HTTP transport + the scripted test double.
# =============================================================================
#
# WHAT THIS IS. The narrow HTTP seam the Iceberg REST catalog client talks
# through. A `IcebergRestTransport` trait — `send(request) ->
# IcebergRestResponse` — carries a GET (config, loadTable) or a POST with a JSON
# body (createTable, commitTable), so the whole REST path is driveable with:
#   * `HttpIcebergRestTransport[C]` — production: one request over the shipped
#     `komira_http` `HttpClient[C]` (C = TlsConnector in prod; `http` over a
#     plaintext connector), exactly the synchronous-per-call shape other
#     komira HTTP transports use.
#   * `ScriptedIcebergRestTransport` — test: returns SCRIPTED JSON responses in
#     FIFO call order + records the method, path, body and every header of each
#     call. ZERO sockets, ZERO network.
#   * `InMemoryIcebergRestCatalog` (iceberg_rest_test_catalog.mojo) — test: a
#     catalog that applies commits, for the committer's cases.
#
# WHY a transport seam. A REST write is a MULTI-call sequence (GET /v1/config
# to learn the prefix, then a load, then a commit POST). A call-level transport
# seam lets a test answer each call and assert what was sent WITHOUT a socket.
# The production transport still rides the full `komira_http` spine underneath
# (NOTHING about transport is reinvented).
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The scripted double holds owned
# `List[String]` queues. `def`-based, Mojo 1.0.0.
# =============================================================================

from std.memory import ArcPointer

from async_rt.ops.waker_sink import NoopSink
from async_rt.runtime.blocking_runtime import BlockingRuntime

from http_client.body import BytesBody
from http_client.client import HttpClient, build_request_with_body
from http_client.header_map import HeaderMap
from http_client.url import Url
from http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST, HttpMethod
from http_core.transport.io_stream import Connector


# =============================================================================
# §0 — IcebergRestMethod + IcebergRestRequest — a fully-formed request.
# =============================================================================


struct IcebergRestMethod(ImplicitlyCopyable, Movable):
    """The HTTP method of an Iceberg REST request: GET (config, loadTable) or
    POST (createTable, commitTable). The only two the client sends, so a
    request can never carry a method the transport does not know."""

    var _post: Bool

    def __init__(out self, *, post: Bool):
        self._post = post

    @staticmethod
    def get() -> IcebergRestMethod:
        return IcebergRestMethod(post=False)

    @staticmethod
    def post() -> IcebergRestMethod:
        return IcebergRestMethod(post=True)

    def is_post(self) -> Bool:
        return self._post

    def name(self) -> String:
        """`GET` or `POST`, as on the request line."""
        if self._post:
            return String("POST")
        return String("GET")


struct IcebergRestRequest(Movable, Deinitable):
    """A ready-to-send Iceberg REST request: the method, the host, the port,
    the absolute request path (already percent-encoded, with any query), the
    outgoing header set, and the JSON body (empty for a GET).

    Field layout:
      var method: IcebergRestMethod     — GET or POST
      var host: String                 — the catalog host (e.g. `catalog.example.com`)
      var port: UInt16                  — the catalog port (443 by default)
      var path: String                  — the absolute request path
                                          (`/v1/config?warehouse=w`,
                                          `/v1/{prefix}/namespaces/{ns}/tables/{tbl}`)
      var header_names: List[String]    — outgoing header names (parallel to values)
      var header_values: List[String]   — outgoing header values
      var body: String                  — the JSON body of a POST; "" for a GET

    a plain owned-field struct — only `String`/`List[String]` heap fields,
    no pointer, no wildcard origin, lives only as a value."""

    var method: IcebergRestMethod
    var host: String
    var port: UInt16
    var path: String
    var header_names: List[String]
    var header_values: List[String]
    var body: String

    def __init__(
        out self,
        var host: String,
        port: UInt16,
        var path: String,
        var header_names: List[String],
        var header_values: List[String],
    ):
        """A GET (no body)."""
        self.method = IcebergRestMethod.get()
        self.host = host^
        self.port = port
        self.path = path^
        self.header_names = header_names^
        self.header_values = header_values^
        self.body = String("")

    @staticmethod
    def post(
        var host: String,
        port: UInt16,
        var path: String,
        var header_names: List[String],
        var header_values: List[String],
        var body: String,
    ) -> IcebergRestRequest:
        """A POST carrying `body` (JSON text)."""
        var r = IcebergRestRequest(
            host^, port, path^, header_names^, header_values^
        )
        r.method = IcebergRestMethod.post()
        r.body = body^
        return r^

    def copy(self) -> IcebergRestRequest:
        """A field-by-field copy: the committer resends a byte-identical
        request under the same idempotency key."""
        var r = IcebergRestRequest(
            String(self.host),
            self.port,
            String(self.path),
            self.header_names.copy(),
            self.header_values.copy(),
        )
        r.method = self.method
        r.body = String(self.body)
        return r^

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
# §2 — IcebergRestTransport — the narrow request seam.
# =============================================================================


trait IcebergRestTransport(Movable, Deinitable):
    """The transport the Iceberg REST catalog client sends a request through.
    One method: `send(request) -> IcebergRestResponse`. Production sends over
    HTTP; the test doubles answer in memory. No UnsafePointer crosses the
    boundary — an `IcebergRestRequest` in, an `IcebergRestResponse` out."""

    def send(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        """Send the request; return the HTTP status + JSON body. RAISES on a
        transport error (a dial failure, a lost connection, a malformed
        response). A non-200 status is NOT a raise here — it is returned as an
        IcebergRestResponse for the client to map to a typed error. A raise
        after the request was written leaves its outcome unknown: the
        committer treats it so."""
        ...


# =============================================================================
# §3 — ScriptedIcebergRestTransport — the TEST DOUBLE (no sockets, no network).
# =============================================================================


struct ScriptedIcebergRestTransport(
    IcebergRestTransport, Movable, Deinitable
):
    """An IcebergRestTransport that returns SCRIPTED responses in FIFO call order
    and records the method, path, body and headers of each call, so a test can
    assert the sequence of requests and exactly what each carried. ZERO
    sockets, ZERO network.

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
    var _call_methods: List[String]
    var _call_paths: List[String]
    var _call_bodies: List[String]
    var _call_header_names: List[List[String]]
    var _call_header_values: List[List[String]]

    def __init__(out self):
        self._resp_status = List[Int]()
        self._resp_body = List[String]()
        self._cursor = 0
        self._call_methods = List[String]()
        self._call_paths = List[String]()
        self._call_bodies = List[String]()
        self._call_header_names = List[List[String]]()
        self._call_header_values = List[List[String]]()

    def queue_response(mut self, status: Int, var body: String):
        """Queue the next scripted response (FIFO). Each `send` consumes one."""
        self._resp_status.append(status)
        self._resp_body.append(body^)

    def call_count(self) -> Int:
        """How many `send` calls the client made (the op-count proof — e.g.
        config is fetched ONCE + cached across loadTable calls)."""
        return len(self._call_paths)

    def call_method(self, i: Int) -> String:
        """The method (`GET` or `POST`) of the i-th call."""
        return String(self._call_methods[i])

    def call_path(self, i: Int) -> String:
        """The request path of the i-th call (call-order path assertion)."""
        return String(self._call_paths[i])

    def call_body(self, i: Int) -> String:
        """The body of the i-th call; "" for a GET."""
        return String(self._call_bodies[i])

    def call_header(self, i: Int, name: String) -> String:
        """The value of header `name` (case-sensitive) on the i-th call; ""
        when the call did not carry it."""
        ref names = self._call_header_names[i]
        for j in range(len(names)):
            if names[j] == name:
                return String(self._call_header_values[i][j])
        return String("")

    def call_has_header(self, i: Int, name: String) -> Bool:
        """True iff the i-th call carried header `name`."""
        ref names = self._call_header_names[i]
        for j in range(len(names)):
            if names[j] == name:
                return True
        return False

    def call_auth(self, i: Int) -> String:
        """The Authorization header of the i-th call (assert the bearer
        token was attached); empty String if the call had no Authorization
        header (the no-auth path)."""
        return self.call_header(i, String("Authorization"))

    def send(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        # Record the call for assertion.
        self._call_methods.append(request.method.name())
        self._call_paths.append(String(request.path))
        self._call_bodies.append(String(request.body))
        self._call_header_names.append(request.header_names.copy())
        self._call_header_values.append(request.header_values.copy())
        if self._cursor >= len(self._resp_status):
            raise Error(
                String(
                    "ScriptedIcebergRestTransport.send: no scripted response"
                    " for call #"
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


def _no_connector[C: Connector]() raises -> C:
    raise Error("HttpIcebergRestTransport: no connector factory")


struct HttpIcebergRestTransport[C: Connector](
    IcebergRestTransport, Movable, Deinitable
):
    """The production IcebergRestTransport: dials a fresh connector + drives ONE
    synchronous request (a GET, or a POST with its JSON body) per call over
    the shipped HttpClient. Parametric over the
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
    var _test_clock: Optional[ArcPointer[Int]]
    """None in production. See `with_test_clock`."""
    var _mk_clocked_connector: Optional[
        def (ArcPointer[Int]) raises thin -> Self.C
    ]
    """None in production. See `with_test_clock`."""

    def __init__(
        out self,
        mk_connector: def () raises thin -> Self.C,
        *,
        request_timeout_us: Int = 0,
    ):
        self._mk_connector = mk_connector
        self._request_timeout_us = request_timeout_us
        self._test_clock = None
        self._mk_clocked_connector = None

    @staticmethod
    def with_test_clock(
        mk_connector: def (ArcPointer[Int]) raises thin -> Self.C,
        clock_cell: ArcPointer[Int],
        *,
        request_timeout_us: Int = 0,
    ) -> Self:
        """A transport whose request deadline reads `clock_cell`
        (microseconds) instead of the system clock, and whose connector
        factory is handed the same cell so the test's peer can move it. A test
        decides how much time passes and when. Production code never calls
        this; the fields stay None and the deadline reads the system clock as
        before."""
        var t = Self(
            _no_connector[Self.C], request_timeout_us=request_timeout_us
        )
        t._test_clock = Optional[ArcPointer[Int]](clock_cell.copy())
        t._mk_clocked_connector = Optional[
            def (ArcPointer[Int]) raises thin -> Self.C
        ](mk_connector)
        return t^

    def send(
        mut self, request: IcebergRestRequest
    ) raises -> IcebergRestResponse:
        # Build the outgoing HeaderMap from the request's header set.
        var headers = HeaderMap()
        for i in range(len(request.header_names)):
            headers.append(
                String(request.header_names[i]),
                String(request.header_values[i]),
            )
        # Dial a fresh connector + drive one synchronous request (one
        # connector per call).
        var connector: Self.C
        if self._mk_clocked_connector:
            connector = self._mk_clocked_connector.value()(
                self._test_clock.value()
            )
        else:
            connector = self._mk_connector()
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
        var method = HttpMethod(code=HTTP_METHOD_GET)
        if request.method.is_post():
            method = HttpMethod(code=HTTP_METHOD_POST)
        var req = build_request_with_body[BytesBody](
            method,
            url^,
            headers^,
            BytesBody.from_str(request.body),
        )
        var client = HttpClient[Self.C].with_request_timeout_us(
            connector^, self._request_timeout_us
        )
        if self._test_clock:
            client.set_test_clock(self._test_clock.value())
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()
        var body = String(unsafe_from_utf8=Span(resp_bytes))
        return IcebergRestResponse(status, body^)
