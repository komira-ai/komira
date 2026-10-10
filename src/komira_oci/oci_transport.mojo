# =============================================================================
# oci_transport.mojo — the ONE-METHOD registry
#   transport seam + its scripted (test) and HTTP (production) conformers.
# =============================================================================
#
# WHY ONE METHOD AND NOT SIX. The OCI distribution protocol needs six distinct
# operations (GET manifest, PUT manifest, HEAD blob, GET blob, POST upload
# session, PUT blob). A six-method trait would put the PROTOCOL in the seam —
# every double would have to reimplement six things, and any protocol change
# (a new verb, a query parameter) would be a breaking change to the trait.
#
# The protocol belongs in the CLIENT; the transport's whole job is "move bytes
# over HTTP". So the seam is one method — `send(request) -> response`. The
# payoff is concrete: `ScriptedOciTransport` below is ~60 lines and can
# script ANY sequence of registry interactions, including ones the client does
# not yet perform.
#
# WHY THE REGISTRY HOST IS ON THE REQUEST, NOT THE TRANSPORT. A registry-to-
# registry copy talks to TWO registries. Binding a host to the transport would
# force the copier to hold two transports and hard-code which leg uses which —
# and the falsifier for a cross-project copy would no longer be able to prove
# the destination PUT went to the destination host. Host-per-request keeps one
# transport, and makes "which host did that call go to?" an assertable fact.
#
# Encapsulation: the seam moves owned `String` / `List[UInt8]` values. No
# UnsafePointer crosses the boundary; no wildcard origin.
# =============================================================================

from komira_encoding.base64 import base64_encode
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import (
    HttpMethod,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)
from komira_http_core.transport.io_stream import Connector
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime


# The registry API port. Every registry this client speaks to is HTTPS on 443;
# a plaintext registry is deliberately unsupported (a bearer token must never
# leave the process in the clear).
comptime OCI_REGISTRY_PORT: UInt16 = 443


# =============================================================================
# §1 — OciRequest / OciResponse — the values that cross the seam.
# =============================================================================


struct OciRequest(Copyable, Movable, Deinitable):
    """One registry HTTP call: verb + host + path(+query) + headers + body.

    Field layout:
      var method: UInt8              — an `HTTP_METHOD_*` code.
      var registry: String           — the registry HOST this call goes to.
      var path: String               — the `/v2/…` path INCLUDING any query
                                       string (upload sessions are addressed by
                                       an opaque server-chosen URL with its own
                                       query, so the path and query cannot be
                                       modelled separately without lying about
                                       what the server handed us).
      var header_names/_values       — parallel header lists.
      var body: List[UInt8]          — request body; EMPTY for GET/HEAD.

    Owned String / List fields only. No pointer field."""

    var method: UInt8
    var registry: String
    var path: String
    var header_names: List[String]
    var header_values: List[String]
    var body: List[UInt8]

    def __init__(
        out self, method: UInt8, var registry: String, var path: String
    ):
        self.method = method
        self.registry = registry^
        self.path = path^
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = List[UInt8]()

    def with_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def with_bearer(mut self, token: String):
        """Attach `Authorization: Bearer <token>` — a NO-OP on an empty token.

        The empty-token no-op is what lets an anonymous/public-registry read and
        a credentialed read share one code path without the caller branching."""
        if token.byte_length() > 0:
            self.with_header(String("authorization"), String("Bearer ") + token)

    def with_basic(mut self, user: String, password: String):
        """Attach `Authorization: Basic base64(user:password)` — a NO-OP on an
        empty password (the same anonymous/credentialed single-path rule as
        `with_bearer`). Artifact Registry's documented form is user
        `oauth2accesstoken` with the access token as the password; ECR hands out
        a Basic credential directly.

        ⚠ The credential is a SECRET: nothing here logs it, and no error text in
        this package quotes a request header."""
        if password.byte_length() > 0:
            var raw = user + String(":") + password
            self.with_header(
                String("authorization"),
                String("Basic ") + base64_encode(raw.as_bytes()),
            )

    def with_body(mut self, var body: List[UInt8]):
        self.body = body^

    def take_body(mut self) -> List[UInt8]:
        """MOVE the body out, leaving this request bodiless. The way a transport
        hands a large layer to the wire without a second resident copy."""
        var out = self.body^
        self.body = List[UInt8]()
        return out^

    def header_value(self, name: String) -> String:
        """The value of header `name` (ASCII-case-insensitive), or EMPTY."""
        for i in range(len(self.header_names)):
            if _ascii_eq_ignore_case(String(self.header_names[i]), name):
                return String(self.header_values[i])
        return String("")

    def copy(self) -> Self:
        var out = OciRequest(
            self.method, self.registry.copy(), self.path.copy()
        )
        for i in range(len(self.header_names)):
            out.with_header(
                String(self.header_names[i]), String(self.header_values[i])
            )
        out.body = self.body.copy()
        return out^


struct OciResponse(Copyable, Movable, Deinitable):
    """One registry HTTP reply: status + headers + body bytes.

    ⚠ A NON-2xx STATUS IS NOT A RAISE. The distribution protocol uses status
    codes as CONTROL FLOW, not just as errors: a HEAD blob returning 404 means
    "upload it", a mount POST returning 202 instead of 201 means "the registry
    declined the mount, here is an upload session". A transport that raised on
    non-2xx would make both of those unreachable. The transport raises only on a
    genuine transport fault (dial failure, malformed response); STATUS is data.

    `body` is `List[UInt8]`, never `String`: layer blobs are gzip, and a
    manifest's digest covers its exact bytes — decoding either through a
    String would be lossy at best and digest-breaking at worst.

    Owned String / List fields only."""

    var status: Int
    var header_names: List[String]
    var header_values: List[String]
    var body: List[UInt8]

    def __init__(out self, status: Int):
        self.status = status
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = List[UInt8]()

    def with_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def with_body(mut self, var body: List[UInt8]):
        self.body = body^

    def take_body(mut self) -> List[UInt8]:
        """MOVE the body out (the response is left bodiless)."""
        var out = self.body^
        self.body = List[UInt8]()
        return out^

    def header(self, name: String) -> String:
        """The value of response header `name` (ASCII-case-insensitive), or
        EMPTY. Case-insensitivity is load-bearing, not politeness: registries
        differ on `Docker-Content-Digest` vs `docker-content-digest`, and HTTP/2
        lowercases every header name on the wire."""
        for i in range(len(self.header_names)):
            if _ascii_eq_ignore_case(String(self.header_names[i]), name):
                return String(self.header_values[i])
        return String("")

    def copy(self) -> Self:
        var out = OciResponse(self.status)
        for i in range(len(self.header_names)):
            out.with_header(
                String(self.header_names[i]), String(self.header_values[i])
            )
        out.body = self.body.copy()
        return out^


def _ascii_eq_ignore_case(a: String, b: String) -> Bool:
    if a.byte_length() != b.byte_length():
        return False
    for i in range(a.byte_length()):
        var ca = UInt8(ord(a[byte=i]))
        var cb = UInt8(ord(b[byte=i]))
        if ca >= UInt8(65) and ca <= UInt8(90):
            ca += UInt8(32)
        if cb >= UInt8(65) and cb <= UInt8(90):
            cb += UInt8(32)
        if ca != cb:
            return False
    return True


# =============================================================================
# §2 — the seam.
# =============================================================================


trait OciTransport(Movable, Deinitable):
    """The seam an OCI registry client sends every call through.

    One method. Production sends over HTTPS; the test double replays a scripted
    queue. RAISES only on a transport fault — a non-2xx status is returned as an
    `OciResponse` because the distribution protocol uses status as control
    flow (see `OciResponse`)."""

    def send(mut self, var request: OciRequest) raises -> OciResponse:
        ...


# =============================================================================
# §3 — ScriptedOciTransport — the TEST DOUBLE (no sockets, no network).
# =============================================================================


struct ScriptedOciTransport(OciTransport, Movable, Deinitable):
    """An `OciTransport` that replays SCRIPTED responses in FIFO call order and
    records every call, so a falsifier can assert the exact registry
    conversation: which HOST, which verb, which path, which bearer, how many
    bytes.

    Recording the HOST per call is what makes the cross-project falsifier
    possible — "the manifest was read from the build project and written to
    the release project" is otherwise unobservable from outside.

    Owned `List[Int]` / `List[String]` / `List[List[UInt8]]` queues. No
    pointer field, no wildcard origin."""

    var _resp: List[OciResponse]
    var _cursor: Int
    var _call_methods: List[UInt8]
    var _call_registries: List[String]
    var _call_paths: List[String]
    var _call_auths: List[String]
    var _call_bodies: List[List[UInt8]]
    var _call_content_types: List[String]

    def __init__(out self):
        self._resp = List[OciResponse]()
        self._cursor = 0
        self._call_methods = List[UInt8]()
        self._call_registries = List[String]()
        self._call_paths = List[String]()
        self._call_auths = List[String]()
        self._call_bodies = List[List[UInt8]]()
        self._call_content_types = List[String]()

    def queue(mut self, var response: OciResponse):
        """Queue the next scripted response (FIFO). Each `send` consumes one."""
        self._resp.append(response^)

    def call_count(self) -> Int:
        return len(self._call_paths)

    def call_method(self, i: Int) -> UInt8:
        return self._call_methods[i]

    def call_registry(self, i: Int) -> String:
        return String(self._call_registries[i])

    def call_path(self, i: Int) -> String:
        return String(self._call_paths[i])

    def call_auth(self, i: Int) -> String:
        return String(self._call_auths[i])

    def call_body(self, i: Int) -> List[UInt8]:
        return self._call_bodies[i].copy()

    def call_content_type(self, i: Int) -> String:
        """The `content-type` the i-th call declared ("" when it sent none):
        what a manifest PUT told the destination the bytes are."""
        return String(self._call_content_types[i])

    def send(mut self, var request: OciRequest) raises -> OciResponse:
        self._call_methods.append(request.method)
        self._call_registries.append(request.registry.copy())
        self._call_paths.append(request.path.copy())
        self._call_auths.append(request.header_value(String("authorization")))
        self._call_bodies.append(request.body.copy())
        self._call_content_types.append(
            request.header_value(String("content-type"))
        )
        if self._cursor >= len(self._resp):
            raise Error(
                String("ScriptedOciTransport.send: no scripted response for call #")
                + String(self._cursor)
                + String(" (")
                + request.registry
                + request.path
                + String("); queue more responses")
            )
        var out = self._resp[self._cursor].copy()
        self._cursor += 1
        return out^


# =============================================================================
# §4 — HttpOciTransport[C] — the PRODUCTION transport over komira_http.
# =============================================================================


struct HttpOciTransport[C: Connector](
    OciTransport, Movable, Deinitable
):
    """The production `OciTransport`: dials a fresh connector and drives ONE
    synchronous request per call over the shipped `HttpClient[C]`.

    Parametric over the connector `C` (a public-CA `TlsConnector` in
    production). This reinvents no HTTP: TLS, header encoding, chunked
    decoding and body buffering are all the shipped client's.

    ⚠ THE FACTORY TAKES THE HOST, unlike a single-endpoint client's connector
    factory — and the difference is load-bearing, not stylistic. A client that
    talks to ONE endpoint for the life of the process can bake the host into a
    nullary factory.
    A registry COPY talks to two registries, and the connector must present the
    RIGHT SNI + verify against the RIGHT certificate for whichever one this call
    is for. A nullary factory would pin SNI to one host and either fail the
    handshake on the other or, worse, validate the wrong name.

    The connector factory is a `def (String) thin -> C` function-pointer field:
    a code pointer, no heap, no wildcard origin."""

    var _mk_connector: def (String) thin -> Self.C

    def __init__(out self, mk_connector: def (String) thin -> Self.C):
        self._mk_connector = mk_connector

    def send(mut self, var request: OciRequest) raises -> OciResponse:
        var headers = HeaderMap()
        for i in range(len(request.header_names)):
            headers.append(
                String(request.header_names[i]),
                String(request.header_values[i]),
            )
        var url = Url.https(
            request.registry.copy(), OCI_REGISTRY_PORT, request.path.copy()
        )
        var method = HttpMethod(code=request.method)

        var connector = self._mk_connector(request.registry.copy())
        var client = HttpClient[Self.C].with_defaults(connector^)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()

        # The two arms differ ONLY in the body conformer (`RequestBody` is a
        # compile-time parameter, so a bodiless GET and a body-carrying PUT
        # cannot share one `ClientRequest` value). Each arm lowers its response
        # to the seam's `OciResponse` before leaving scope.
        if len(request.body) == 0:
            var req = build_request_with_body[EmptyBody](
                method, url^, headers^, EmptyBody.new()
            )
            var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
                req^, reactor
            )
            return _lower_response(Int(cr.status), cr.headers, cr.body.take_bytes())

        # The body is MOVED into the wire value, never copied: the request is
        # taken by value precisely so a large layer is resident once here, not
        # twice. (Whether the client then copies it into a send buffer is the
        # client's concern; nothing in this file adds a copy.)
        var req2 = build_request_with_body[BytesBody](
            method, url^, headers^, BytesBody.from_bytes(request.take_body())
        )
        var cr2 = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            req2^, reactor
        )
        return _lower_response(Int(cr2.status), cr2.headers, cr2.body.take_bytes())


def _lower_response(
    status: Int, headers: HeaderMap, var body: List[UInt8]
) -> OciResponse:
    """Narrow an `HttpClient` response down to the seam's `OciResponse`.

    Only the headers the distribution protocol assigns meaning to are lifted.
    Forwarding the whole `HeaderMap` would put every vendor / caching / cookie
    header into the value that crosses the seam, widening what a scripted double
    must model for no benefit — and a seam whose value type mirrors the whole of
    HTTP is not a seam."""
    var out = OciResponse(status)
    _lift_header(headers, String("docker-content-digest"), out)
    _lift_header(headers, String("content-type"), out)
    _lift_header(headers, String("location"), out)
    _lift_header(headers, String("www-authenticate"), out)
    out.with_body(body^)
    return out^


def _lift_header(headers: HeaderMap, name: String, mut out: OciResponse):
    var v = headers.get(name)
    if v:
        out.with_header(name.copy(), v.value())
