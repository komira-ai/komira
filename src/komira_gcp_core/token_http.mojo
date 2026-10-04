# =============================================================================
# komira_gcp_core/token_http.mojo -- the token fetchers' one transport seam
# =============================================================================
#
# A token fetcher (token_sources.mojo) is a REQUEST BUILDER and a RESPONSE
# PARSER (token_wire.mojo, both pure) with one exchange between them, through
# `GcpHttpTransport`:
#
#   * `GcpConnectorTransport[C]` is the production transport: one
#     komira_http_client `HttpClient` on the komira_http `Connector` it is
#     given, built from the CALLER's `HttpClientConfig` (it has no default:
#     it bounds each exchange and the response body), driven on its own
#     `BlockingRuntime`, so a fetch blocks its thread. The metadata server is
#     plain HTTP and the OAuth 2.0 token endpoint is HTTPS, so a caller gives
#     a plain connector to the one and a TLS connector to the other.
#   * a test hands the same transport a komira_http_core `ScriptedConnector`
#     (no socket), or any double of the trait.
#
# A request can carry a secret (a signed JWT assertion, a refresh token and a
# client secret). `TokenHttpRequest` is not `Writable`; `to_wire()` is the
# head and body the request builder wrote, for the byte-exact tests only. A
# response body holds a token. Never log either.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import BytesBody
from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector

from ._text import _from_utf8_bytes, _sub


@fieldwise_init
struct TokenHeader(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One request or response header, as sent or received."""

    var name: String
    var value: String


struct TokenHttpRequest(Copyable, Movable, Deinitable):
    """One HTTP request a token fetcher wants sent.

    `scheme` is "http" or "https"; `host` is the host name or IP literal (an
    IPv6 literal in brackets); `port` is the TCP port; `target` is the path
    and query. `headers` are in send order and include Host. `body` is
    bytes."""

    var method: String
    var scheme: String
    var host: String
    var port: Int
    var target: String
    var headers: List[TokenHeader]
    var body: List[UInt8]

    def __init__(
        out self,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        target: String,
    ):
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.target = target
        self.headers = List[TokenHeader]()
        self.body = List[UInt8]()

    def add_header(mut self, name: String, value: String):
        self.headers.append(TokenHeader(name, value))

    def header(self, name: String) -> String:
        """The first header named `name` (exact case), "" when absent."""
        for i in range(len(self.headers)):
            if self.headers[i].name == name:
                return self.headers[i].value
        return String("")

    def set_body_text(mut self, text: String):
        """Sets the body to the UTF-8 bytes of `text`."""
        var b = List[UInt8]()
        b.extend(Span(text.as_bytes()))
        self.body = b^

    def body_text(self) -> String:
        """The body as text. Every body a request builder writes is ASCII
        (JSON-free form encoding of ASCII and percent escapes)."""
        return _from_utf8_bytes(self.body)

    def to_wire(self) -> String:
        """The request line, the headers the builder set, a blank line and
        the body. komira_http_client adds `User-Agent` and `Content-Length`
        when it sends. Holds secrets; for tests only."""
        var head = self.method + " " + self.target + " HTTP/1.1\r\n"
        for i in range(len(self.headers)):
            head += self.headers[i].name + ": " + self.headers[i].value + "\r\n"
        head += "\r\n"
        return head + self.body_text()


struct TokenHttpResponse(Copyable, Movable, Deinitable):
    """The status, headers and body bytes of a response. Bodies hold
    tokens."""

    var status: Int
    var headers: List[TokenHeader]
    var body: List[UInt8]

    def __init__(out self, status: Int, var body: List[UInt8]):
        self.status = status
        self.headers = List[TokenHeader]()
        self.body = body^

    def add_header(mut self, name: String, value: String):
        self.headers.append(TokenHeader(name, value))

    def header(self, name: String) -> String:
        """The first header named `name`, compared without regard to ASCII
        case; "" when absent."""
        var want = _lower(name)
        for i in range(len(self.headers)):
            if _lower(self.headers[i].name) == want:
                return self.headers[i].value
        return String("")


def _lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


trait GcpHttpTransport(Movable, Deinitable):
    """Sends one request and returns the response. Raises when no response
    arrives (no route, refused, timed out); the message of a
    komira_http_client failure starts `HttpError[<kind>]`."""

    def send(mut self, req: TokenHttpRequest) raises -> TokenHttpResponse:
        ...


def _http_method(method: String) raises -> HttpMethod:
    if method == "GET":
        return HttpMethod.get()
    if method == "POST":
        return HttpMethod.post()
    raise Error("a token request method is GET or POST, not " + method)


def _url_of(req: TokenHttpRequest) -> Url:
    """The request's URL: its scheme, host (an IPv6 literal without its
    brackets), port, and target split at the first '?'."""
    var host = req.host.copy()
    var n = req.host.byte_length()
    if n >= 2 and req.host.startswith("[") and req.host.endswith("]"):
        host = _sub(req.host, 1, n - 1)
    var path = req.target.copy()
    var query = String("")
    var q = req.target.find("?")
    if q >= 0:
        path = _sub(req.target, 0, q)
        query = _sub(req.target, q + 1, req.target.byte_length())
    var url = Url(
        scheme=req.scheme.copy(), host=host^, port=UInt16(req.port), path=path^
    )
    url.query = query^
    return url^


struct GcpConnectorTransport[C: Connector](GcpHttpTransport, Movable, Deinitable):
    """`GcpHttpTransport` over komira_http_client: one `HttpClient` on the
    connector it is given, built from the caller's `HttpClientConfig`, and
    driven on its own `BlockingRuntime`."""

    var _client: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]

    def __init__(out self, config: HttpClientConfig, var connector: Self.C) raises:
        self._client = HttpClient[Self.C](config, connector^)
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))

    def http_config(self) -> HttpClientConfig:
        """The config this transport's HTTP client was built from."""
        return self._client.config()

    def send(mut self, req: TokenHttpRequest) raises -> TokenHttpResponse:
        var headers = HeaderMap()
        for i in range(len(req.headers)):
            headers.append(req.headers[i].name.copy(), req.headers[i].value.copy())
        var creq = build_request_with_body[BytesBody](
            _http_method(req.method),
            _url_of(req),
            headers^,
            BytesBody.from_bytes(req.body.copy()),
        )
        ref reactor = self._rt.reactor()
        var resp = self._client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            creq^, reactor
        )
        var entries = resp.headers.entries()
        var out = TokenHttpResponse(Int(resp.status), resp.body.take_bytes())
        for i in range(len(entries)):
            out.add_header(entries[i].name.copy(), entries[i].value.copy())
        return out^
