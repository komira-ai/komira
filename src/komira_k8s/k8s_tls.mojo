# =============================================================================
# komira_k8s/k8s_tls.mojo — apiserver HTTPS over the shared komira_http client
# =============================================================================
#
# The authed-HTTPS request path to the K8s apiserver, driven by `komira_http`'s
# `HttpClient` over a `TlsConnector`. k8s is an HTTP client: it CALLS the
# shared client, which owns HTTP/1.1 framing and all body accumulation on its
# `send_buffered` path. We do NOT hand-write buffer accumulation here.
#
# THE TRANSPORT:
#   * `k8s_build_tls_connector(ca_pem, server_name, verify_cert)` →
#     `TlsConnector[KernelTcpConnector]` configured for the apiserver:
#       - `set_cipher_preferences("default_tls13")` — offer TLS 1.3 (a fresh
#         s2n config defaults to TLS-1.2-only, which the apiserver EOFs before
#         ServerHello).
#       - `set_alpn_protocols(["http/1.1"])` — pin HTTP/1.1 so HttpClient's
#         ALPN dispatch stays on the h1 OutboundDriver (h2 is not used here).
#       - CA pinning: `verify_cert=True` → `wipe_trust()` + `add_trust_pem(ca)`
#         (drop OS roots, pin EXACTLY the cluster CA). `verify_cert=False` →
#         `disable_verify()` (kind dev with a cert that doesn't validate from
#         outside the cluster); `ca_pem` is then ignored.
#       - SNI: `set_server_name_for_next_connect(server_name)`.
#   * `k8s_https_request_authed[RT, A]` — the `[RT]`-parametric round-trip:
#     auth.apply(headers) → build a `ClientRequest` → `HttpClient.send_buffered
#     [RT]` over the connector → collect the buffered body → map to the typed
#     `HttpResponse` the verbs consume. ONE fresh connection per request
#     (Connection: close — a control plane's apiserver traffic is low QPS).
#   * `k8s_https_request_authed_blocking[A]` — the SYNC ESCAPE: stands up a
#     `BlockingRuntime[NoopSink]` on the calling thread and drives the `[RT]`
#     path with it. This is what the reactor-free `K8sPodClient` verbs call, so
#     a control-plane caller stays reactor-free while the `[RT]` capability
#     EXISTS on the transport for async callers.
#
# Encapsulation discipline: no UnsafePointer crosses a
# boundary; no wildcard-origin field; no borrow held across the reactor park
# (HttpClient owns the body accumulation). The typed surface is `HttpResponse`
# (status + decoded body String) — the verbs never see a stream, fd, or pointer.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.auth import AuthProvider
from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.client import (
    HttpClient,
    build_get_request,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.pool import VERIFY_PEER, VERIFY_SKIP
from komira_http_client.service import ClientRequest
from komira_http_client.url import Url
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.codec.types import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HttpMethod,
)
from komira_http_core.tls.s2n_shim import TlsConfig

from komira_k8s.k8s_text import owned_utf8_from_span


# =============================================================================
# HttpResponse — the typed response surface the K8s verbs consume.
# =============================================================================
struct HttpResponse(Movable):
    """A parsed HTTP response: status code + the decoded body string. The body
    is the fully-buffered response body (content-length / chunked decoding done
    by `komira_http`'s state machine). Only what the K8s client needs —
    headers beyond status are not retained."""

    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^


# =============================================================================
# k8s_build_tls_connector — the CA-pinned TLS-1.3 connector for the apiserver.
# =============================================================================
def k8s_build_tls_connector(
    ca_pem: String,
    server_name: String,
    verify_cert: Bool,
) raises -> TlsConnector[KernelTcpConnector]:
    """Build a `TlsConnector[KernelTcpConnector]` configured for the K8s
    apiserver: trust, cipher, ALPN and SNI.

      * `set_cipher_preferences("default_tls13")` — offer TLS 1.3 (required; a fresh config defaults TLS-1.2-only, which the apiserver EOFs).
      * `set_alpn_protocols(["http/1.1"])` — pin HTTP/1.1 (h1 OutboundDriver
        dispatch).
      * `verify_cert=True` → `wipe_trust()` + `add_trust_pem(ca_pem)` (drop OS
        roots, pin the cluster CA — the in-cluster production path).
        `verify_cert=False` → `disable_verify()` (kind dev; `ca_pem` ignored).
      * SNI via `set_server_name_for_next_connect(server_name)`.

    The returned connector owns its `TlsConfig` (via OwnedPointer) and is
    reused for each request the caller drives through it. verify_mode is
    threaded so the session cache buckets correctly."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    if verify_cert:
        # Production trust path: drop OS roots, pin EXACTLY the cluster CA.
        config.wipe_trust()
        config.add_trust_pem(ca_pem)
    else:
        config.disable_verify()

    # VERIFY_PEER / VERIFY_SKIP keep the TlsConnector's session cache bucketed
    # correctly vs same-host + different-verify entries.
    var verify_mode = VERIFY_PEER if verify_cert else VERIFY_SKIP
    var connector = TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), verify_mode,
    )
    connector.set_server_name_for_next_connect(server_name)
    return connector^


# =============================================================================
# _split_path_query — split "path?query" into a Url's path + query halves.
# =============================================================================
def _split_path_query(path_and_query: String) -> Tuple[String, String]:
    """Split a request target `path[?query]` into `(path, query)`. The K8s
    client builds paths with an inline `?...` query (labelSelector, tailLines,
    etc.); `komira_http`'s `Url` carries path + query as separate fields and
    re-joins them via `request_target()`, so we split here. No '?' → empty
    query."""
    var bytes = path_and_query.as_bytes()
    var n = len(bytes)
    var q = -1
    var i = 0
    while i < n:
        if bytes[i] == UInt8(ord("?")):
            q = i
            break
        i += 1
    if q < 0:
        return (path_and_query, String(""))
    var path = String("")
    for k in range(0, q):
        path += chr(Int(bytes[k]))
    var query = String("")
    for k in range(q + 1, n):
        query += chr(Int(bytes[k]))
    return (path^, query^)


def _method_for(method: String) raises -> HttpMethod:
    """Map a K8s verb String ("GET"/"POST"/"DELETE") to the typed HttpMethod."""
    if method == String("GET"):
        return HttpMethod(code=HTTP_METHOD_GET)
    if method == String("POST"):
        return HttpMethod(code=HTTP_METHOD_POST)
    if method == String("DELETE"):
        return HttpMethod(code=HTTP_METHOD_DELETE)
    raise Error("k8s_tls: unsupported HTTP method '" + method + "'")


# =============================================================================
# k8s_https_request_authed[RT, A] — one apiserver round-trip over HttpClient.
# =============================================================================
def k8s_https_request_authed[
    RT: Runtime, A: AuthProvider,
](
    mut client: HttpClient[TlsConnector[KernelTcpConnector]],
    mut reactor: Reactor[RT.Sink],
    host: String,
    port: UInt16,
    method: String,
    path: String,
    auth: A,
    body: String,
) raises -> HttpResponse:
    """One full apiserver HTTPS round-trip driven by the shared `HttpClient`.

    auth.apply(headers) injects `Authorization: Bearer <token>` (the token is
    re-read per request for projected-token rotation — the seam lives in
    `komira_http_client.auth`, not hand-wired here). The request is built into
    a `ClientRequest`, sent via `HttpClient.send_buffered[RT]` (which owns ALL
    body accumulation on its reactor-park path — no borrow across the park
    here), and the buffered body is mapped to the typed `HttpResponse`.

    `client` already owns the TLS connector (built by `k8s_build_tls_connector`);
    `send_buffered` dials a fresh TLS connection (Connection: close — low QPS)
    and runs one request-response cycle.

    The K8s host is an IPv4 dotted-quad (in-cluster the apiserver is the
    ClusterIP 10.96.0.1; off-cluster 127.0.0.1) — `HttpClient` parses it as an
    IP literal (no DNS)."""
    var parts = _split_path_query(path)
    var url_path = parts[0]
    var url_query = parts[1]
    var url = Url.https(host, port, url_path^)
    url.query = url_query^

    var headers = HeaderMap()
    headers.append(String("Accept"), String("application/json"))
    # The pluggable auth seam decorates the headers (Authorization: Bearer).
    auth.apply(headers)

    var resp: HttpResponse
    if method == String("POST"):
        # POST carries the JSON manifest as a buffered BytesBody.
        var body_bytes = List[UInt8]()
        for b in body.as_bytes():
            body_bytes.append(b)
        headers.append(String("Content-Type"), String("application/json"))
        var req = build_request_with_body[BytesBody](
            _method_for(method), url^, headers^, BytesBody.from_bytes(body_bytes^),
        )
        var cr = client.send_buffered[RT, BytesBody](req^, reactor)
        var status = Int(cr.status)
        var decoded = owned_utf8_from_span(cr.body.take_bytes())
        resp = HttpResponse(status, decoded^)
    else:
        # GET / DELETE — no body. build_get_request emits a GET request-line;
        # for DELETE we build the empty-body request with the DELETE method.
        var req: ClientRequest[EmptyBody]
        if method == String("GET"):
            req = build_get_request(url^, headers^)
        else:
            req = build_request_with_body[EmptyBody](
                _method_for(method), url^, headers^, EmptyBody.new(),
            )
        var cr = client.send_buffered[RT, EmptyBody](req^, reactor)
        var status = Int(cr.status)
        var decoded = owned_utf8_from_span(cr.body.take_bytes())
        resp = HttpResponse(status, decoded^)
    return resp^


# =============================================================================
# k8s_https_request_authed_blocking[A] — the SYNC ESCAPE (BlockingRuntime).
# =============================================================================
def k8s_https_request_authed_blocking[
    A: AuthProvider,
](
    ca_pem: String,
    server_name: String,
    verify_cert: Bool,
    host: String,
    port: UInt16,
    method: String,
    path: String,
    auth: A,
    body: String,
) raises -> HttpResponse:
    """Synchronous one-shot apiserver round-trip. Stands up a
    `BlockingRuntime[NoopSink]` (current-thread, single-task — no pthreads, no
    scheduler) on the CALLING thread, builds the TLS connector + HttpClient,
    and drives `k8s_https_request_authed[BlockingRuntime[NoopSink]]` with the
    runtime's reactor. When the single in-flight request parks (EINPROGRESS on
    connect, EWOULDBLOCK on read/write, BLOCKED during the TLS handshake), the
    calling thread blocks on the reactor's ONE fd until ready, then resumes —
    tokio's current-thread `block_on` model.

    This is the entry the reactor-free `K8sPodClient` verbs call, so a
    control-plane loop stays reactor-free (single-shot, low QPS) while the
    `[RT]` capability EXISTS on the transport for async callers."""
    var connector = k8s_build_tls_connector(ca_pem, server_name, verify_cert)
    var client = HttpClient[TlsConnector[KernelTcpConnector]].with_defaults(
        connector^,
    )
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    return k8s_https_request_authed[BlockingRuntime[NoopSink], A](
        client, reactor, host, port, method, path, auth, body,
    )
