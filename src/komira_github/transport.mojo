# =============================================================================
# komira_github/transport.mojo -- the seam between the client and the wire.
# =============================================================================
#
# `GitHubTransport.send` takes one fully formed request (method, target
# relative to the API root, headers including the credential, body) and
# returns GitHub's answer, or raises when no answer came. The client is
# generic over it:
#   * `HttpsGitHubTransport[C]` sends through komira_http_client over the
#     komira_http_core `Connector` the caller gives, to a `GitHubEndpoint`;
#   * komira_github_fake's `FakeGitHub` answers in memory, as GitHub would,
#     so every rule of the client is tested with no network.
#
# Endpoints. `GitHubEndpoint.public()` is https://api.github.com.
# `enterprise(host, port)` is a GitHub Enterprise Server at
# https://<host>:<port>/api/v3. `loopback_plaintext(port)` is plain http to
# 127.0.0.1 for a local fake: the credential would be sent in clear, so the
# host is fixed and cannot be set, and `url` refuses a plaintext endpoint for
# any other host however it was built.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_json import JsonValue, parse_json_bytes

from .error import KIND_BAD_INPUT, KIND_BAD_RESPONSE, github_error
from .header import GitHubHeader, header_value


comptime GITHUB_PUBLIC_HOST: String = "api.github.com"
comptime GITHUB_API_VERSION: String = "2022-11-28"
comptime GITHUB_ACCEPT: String = "application/vnd.github+json"
comptime GITHUB_USER_AGENT: String = "komira-github"
comptime LOOPBACK_HOST: String = "127.0.0.1"


struct GitHubHttpRequest(Copyable, Movable, Deinitable):
    """What a transport sends: `method`, `target` (path and query, relative
    to the API root), every header, and the body."""

    var method: String
    var target: String
    var headers: List[GitHubHeader]
    var body: List[UInt8]

    def __init__(out self, var method: String, var target: String):
        self.method = method^
        self.target = target^
        self.headers = List[GitHubHeader]()
        self.body = List[UInt8]()

    def add_header(mut self, var name: String, var value: String):
        self.headers.append(GitHubHeader(name^, value^))

    def header(self, name: String) -> Optional[String]:
        return header_value(self.headers, name)


struct GitHubResponse(Copyable, Movable, Deinitable):
    """GitHub's answer: status, headers as received, body bytes."""

    var status: Int
    var headers: List[GitHubHeader]
    var body: List[UInt8]

    def __init__(out self, status: Int, var body: List[UInt8]):
        self.status = status
        self.headers = List[GitHubHeader]()
        self.body = body^

    def add_header(mut self, var name: String, var value: String):
        self.headers.append(GitHubHeader(name^, value^))

    def header(self, name: String) -> Optional[String]:
        """The first header named `name` (ASCII case ignored)."""
        return header_value(self.headers, name)

    def ok(self) -> Bool:
        return self.status >= 200 and self.status < 300

    def json(self) raises -> JsonValue:
        """The body as JSON (`GitHubError[BAD_RESPONSE]` when it is not)."""
        try:
            return parse_json_bytes(self.body)
        except:
            raise github_error(KIND_BAD_RESPONSE, "the answer's body is not JSON")


def _check_host(host: String) raises:
    """A non-empty run of `[a-z0-9.-]`: the credential is sent to it, so
    `/`, `@`, `:` or `#` must not be able to name another host."""
    var b = host.as_bytes()
    if len(b) == 0:
        raise github_error(KIND_BAD_INPUT, "the GitHub host is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise github_error(KIND_BAD_INPUT, "the GitHub host holds a byte outside [a-z0-9.-]")


struct GitHubEndpoint(Copyable, Movable, Deinitable):
    """Where requests go: scheme, host, port and the API root path."""

    var tls: Bool
    var host: String
    var port: UInt16
    var base_path: String

    def __init__(out self, tls: Bool, var host: String, port: UInt16, var base_path: String):
        self.tls = tls
        self.host = host^
        self.port = port
        self.base_path = base_path^

    @staticmethod
    def public() -> GitHubEndpoint:
        """https://api.github.com (API root `/`)."""
        return GitHubEndpoint(True, String(GITHUB_PUBLIC_HOST), 443, String(""))

    @staticmethod
    def enterprise(var host: String, port: UInt16) raises -> GitHubEndpoint:
        """A GitHub Enterprise Server: https://<host>:<port>/api/v3."""
        _check_host(host)
        if port == 0:
            raise github_error(KIND_BAD_INPUT, "the GitHub port is 0")
        return GitHubEndpoint(True, host^, port, String("/api/v3"))

    @staticmethod
    def loopback_plaintext(port: UInt16) raises -> GitHubEndpoint:
        """Plain http to 127.0.0.1:<port> (a local fake)."""
        if port == 0:
            raise github_error(KIND_BAD_INPUT, "the GitHub port is 0")
        return GitHubEndpoint(False, String(LOOPBACK_HOST), port, String(""))

    def url(self, target: String) raises -> Url:
        """The URL of `target` (path and query relative to the API root)."""
        if not self.tls and self.host != String(LOOPBACK_HOST):
            raise github_error(
                KIND_BAD_INPUT,
                "plain http is only for 127.0.0.1; the credential would cross the network in clear",
            )
        var full = self.base_path + target
        var path = full.copy()
        var query = String("")
        var q = full.find("?")
        if q >= 0:
            query = String(full[byte = q + 1 : full.byte_length()])
            path = String(full[byte=0:q])
        var url: Url
        if self.tls:
            url = Url.https(self.host.copy(), self.port, path^)
        else:
            url = Url.http(self.host.copy(), self.port, path^)
        url.query = query^
        return url^


trait GitHubTransport(Movable, Deinitable):
    """Sends one request and returns the answer; raises when no answer
    came (no route, refused, timed out)."""

    def send(mut self, req: GitHubHttpRequest) raises -> GitHubResponse:
        ...


def _http_method(method: String) raises -> HttpMethod:
    if method == "GET":
        return HttpMethod.get()
    if method == "POST":
        return HttpMethod.post()
    if method == "PATCH":
        return HttpMethod.patch()
    raise github_error(KIND_BAD_INPUT, String("no route of the subset uses method ") + method)


struct HttpsGitHubTransport[C: Connector](GitHubTransport, Movable, Deinitable):
    """`GitHubTransport` over komira_http_client: one `HttpClient` on the
    caller's connector, driven on its own `BlockingRuntime`, to one
    endpoint."""

    var _http: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]
    var _endpoint: GitHubEndpoint

    def __init__(out self, var http: HttpClient[Self.C], var endpoint: GitHubEndpoint) raises:
        self._http = http^
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        self._endpoint = endpoint^

    def endpoint(self) -> GitHubEndpoint:
        return self._endpoint.copy()

    def send(mut self, req: GitHubHttpRequest) raises -> GitHubResponse:
        var url = self._endpoint.url(req.target)
        var headers = HeaderMap()
        for i in range(len(req.headers)):
            headers.append(req.headers[i].name.copy(), req.headers[i].value.copy())
        var creq = build_request_with_body[BytesBody](
            _http_method(req.method),
            url^,
            headers^,
            BytesBody.from_bytes(req.body.copy()),
        )
        ref reactor = self._rt.reactor()
        var resp = self._http.send_buffered[BlockingRuntime[NoopSink], BytesBody](creq^, reactor)
        var entries = resp.headers.entries()
        var out = GitHubResponse(Int(resp.status), resp.body.take_bytes())
        for i in range(len(entries)):
            out.add_header(entries[i].name.copy(), entries[i].value.copy())
        return out^
