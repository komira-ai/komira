# =============================================================================
# test_http_transport.mojo -- the HTTP transports against a server in this
# process.
# =============================================================================
#
# The server binds 127.0.0.1 on an ephemeral port and runs on a second thread
# (komira_fork_join) while the client runs on the first. It answers each
# connection, in order, with the raw bytes the test scripted, and records the
# raw bytes it received, so a test asserts what reached the wire and how the
# client treats what came back. Nothing waits on time: the server polls its
# listener, without waiting, until a connection comes and stops when the client
# leg ends, and the time bounds the transports are given are never reached.
#
#   request shape       method, path, protocol, the accept and content type
#                       headers, the exact content length and body, and the host
#                       header with the port (test_request_shape).
#   path and credential the path and the credential header are the configured
#                       ones and differ between two transports; a transport with
#                       no provider sends no credential
#                       (test_configured_path_and_auth_header,
#                       test_no_provider_sends_no_credential).
#   unsafe provider     a header that would break the request, or a provider that
#                       fails, stops the call before any dial
#                       (test_unsafe_auth_header_is_refused_before_dialing).
#   failures            a non-success status is refused with its status and a
#                       bounded quote of the body, never the request
#                       (test_non_success_status_is_refused,
#                       test_non_success_status_quotes_a_bounded_body); a 2xx
#                       status is accepted; a body shorter than it declared
#                       (test_truncated_body_is_refused); a body over the bound,
#                       declared or chunked, and a body exactly at the bound
#                       (test_response_size_is_bounded); a body that is not UTF-8
#                       (test_non_utf8_body_is_refused); one failed call is one
#                       connection (test_a_failed_call_is_not_retried).
#   timeout             the value reaches the connector factory and the client
#                       settings (test_timeout_value_reaches_the_connector).
#   scheme              a connector that reports TLS gets an https request
#                       (test_https_connector_posts_https).
# =============================================================================

from std.memory import Pointer
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.tcp_stream import TcpListener, TcpStream
from komira_atomic_alias import AtomicI64
from komira_fork_join import ForkJoinBody, fork_join
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_core.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)
from komira_kg_llm import (
    AuthHeader,
    AuthHeaderProvider,
    HttpChatTransport,
    HttpEmbedTransport,
    NoAuth,
    StaticAuthHeader,
    WireEndpoint,
)


# -----------------------------------------------------------------------------
# The server.
# -----------------------------------------------------------------------------


def _backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


def _bytes_of(text: String) -> List[UInt8]:
    var out = List[UInt8](capacity=text.byte_length())
    out.extend(text.as_bytes())
    return out^


def _find(hay: List[UInt8], needle: String, start: Int = 0) -> Int:
    """The first index at or after `start` where `needle` occurs, or -1."""
    var nb = needle.as_bytes()
    var m = len(nb)
    var i = start
    while i + m <= len(hay):
        var same = True
        for j in range(m):
            if hay[i + j] != nb[j]:
                same = False
                break
        if same:
            return i
        i += 1
    return -1


def _lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        out.append(c)
    return String(from_utf8_lossy=Span(out))


def _content_length(head_lower: String) -> Int:
    """The Content-Length in a lower-cased request head, or 0."""
    var key = "content-length:"
    var at = head_lower.find(key)
    if at < 0:
        return 0
    var bytes = head_lower.as_bytes()
    var i = at + key.byte_length()
    var value = 0
    while i < len(bytes) and bytes[i] == 0x20:
        i += 1
    while i < len(bytes) and bytes[i] >= 0x30 and bytes[i] <= 0x39:
        value = value * 10 + Int(bytes[i] - 0x30)
        i += 1
    return value


def _read_request(
    mut conn: TcpStream, mut reactor: Reactor[NoopSink]
) raises -> List[UInt8]:
    """Read one request: the head, then the body its head declares."""
    var got = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var need = -1
    while True:
        var n = conn.read[NoopSink](reactor, Span(buf))
        if n <= 0:
            break
        got.extend(Span(buf)[0 : Int(n)])
        if need < 0:
            var head_end = _find(got, "\r\n\r\n")
            if head_end >= 0:
                var head = _lower(String(from_utf8_lossy=Span(got)[0:head_end]))
                if "transfer-encoding: chunked" in head:
                    need = -2
                else:
                    need = head_end + 4 + _content_length(head)
        if need >= 0 and len(got) >= need:
            break
        if need == -2 and _find(got, "\r\n0\r\n\r\n") >= 0:
            break
    return got^


struct _Server(Movable):
    """A loopback server that answers each connection with a scripted reply."""

    var listener: TcpListener
    var reactor: Reactor[NoopSink]
    var replies: List[List[UInt8]]
    var requests: List[List[UInt8]]
    var served: Int
    var fault: String
    var port: UInt16

    def __init__(out self, var replies: List[List[UInt8]]) raises:
        self.listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16)
        )
        self.port = self.listener.local_port()
        self.reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), _backend()
        )
        self.replies = replies^
        self.requests = List[List[UInt8]]()
        self.served = 0
        self.fault = String()

    def step(mut self) raises:
        """Accept and answer one connection if one is waiting."""
        if self.served >= len(self.replies):
            _ = self.reactor.poll_completions(timeout_us=Int32(0))
            return
        var accepted = self.listener.try_accept()
        if not accepted.is_ready():
            _ = self.reactor.poll_completions(timeout_us=Int32(0))
            return
        var conn = TcpStream(Int32(Int(accepted.value())))
        try:
            self.requests.append(_read_request(conn, self.reactor))
            var reply = self.replies[self.served].copy()
            var sent = 0
            while sent < len(reply):
                var n = conn.write[NoopSink](
                    self.reactor, Span(reply)[sent:]
                )
                sent += Int(n)
        except e:
            self.fault = String(e)
        self.served += 1


def http_reply(status: Int, body: String) -> List[UInt8]:
    """A complete reply with the right Content-Length, then the connection ends."""
    var text = (
        "HTTP/1.1 "
        + String(status)
        + " Scripted\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )
    return _bytes_of(text)


# -----------------------------------------------------------------------------
# Running a client leg beside the server.
# -----------------------------------------------------------------------------


trait ClientLeg(Movable):
    def run(mut self) raises:
        ...


struct _StopFlag(Movable):
    var stop: AtomicI64

    def __init__(out self):
        self.stop = AtomicI64(Int64(0))


struct _Duet[
    C: ClientLeg,
    so: MutOrigin,
    co: MutOrigin,
    fo: MutOrigin,
](ForkJoinBody):
    var server: Pointer[_Server, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[_Server, Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
    ):
        self.server = server
        self.client = client
        self.flag = flag

    def run(self, tid: Int) raises:
        if tid == 0:
            while self.flag[].stop.load() == Int64(0):
                self.server[].step()
            return
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def _serve_while[C: ClientLeg](mut server: _Server, mut leg: C) raises:
    var flag = _StopFlag()
    # SAFETY: the three pointers borrow `server`, `leg` and `flag`, which live in
    # this frame until `fork_join` has joined both threads. Thread 0 alone touches
    # the server, thread 1 alone the leg, and the flag only through its atomic.
    var duet = _Duet(Pointer(to=server), Pointer(to=leg), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^


# -----------------------------------------------------------------------------
# The client leg. It catches the error of its call and keeps the message, so a
# test asserts on the refusal rather than on a rethrown error.
# -----------------------------------------------------------------------------

comptime _TIMEOUT_MS: Int = 30_000
comptime _MAX_BYTES: Int = 4096


def _mk(timeout_ms: Int) raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


struct _PostLeg(ClientLeg):
    """One `complete` call on a chat or an embed transport."""

    var port: UInt16
    var embed: Bool
    var path: String
    var auth_name: String
    var auth_value: String
    var request: String
    var max_bytes: Int
    var result: String
    var error: String

    def __init__(
        out self,
        port: UInt16,
        request: String,
        *,
        embed: Bool = False,
        path: String = "/wire/post",
        auth_name: String = "",
        auth_value: String = "",
        max_bytes: Int = _MAX_BYTES,
    ):
        self.port = port
        self.embed = embed
        self.path = path
        self.auth_name = auth_name
        self.auth_value = auth_value
        self.request = request
        self.max_bytes = max_bytes
        self.result = String()
        self.error = String()

    def run(mut self) raises:
        try:
            var ep = WireEndpoint(
                "127.0.0.1",
                self.port,
                self.path,
                timeout_ms=_TIMEOUT_MS,
                max_response_bytes=self.max_bytes,
            )
            if self.auth_name.byte_length() == 0:
                if self.embed:
                    var t = HttpEmbedTransport[KernelTcpConnector, NoAuth](
                        _mk, ep^, NoAuth()
                    )
                    self.result = t.complete(self.request)
                else:
                    var t = HttpChatTransport[KernelTcpConnector, NoAuth](
                        _mk, ep^, NoAuth()
                    )
                    self.result = t.complete(self.request)
            else:
                var auth = StaticAuthHeader(self.auth_name, self.auth_value)
                if self.embed:
                    var t = HttpEmbedTransport[
                        KernelTcpConnector, StaticAuthHeader
                    ](_mk, ep^, auth^)
                    self.result = t.complete(self.request)
                else:
                    var t = HttpChatTransport[
                        KernelTcpConnector, StaticAuthHeader
                    ](_mk, ep^, auth^)
                    self.result = t.complete(self.request)
        except e:
            self.error = String(e)


def _post(
    var replies: List[List[UInt8]],
    request: String,
    *,
    embed: Bool = False,
    path: String = "/wire/post",
    auth_name: String = "",
    auth_value: String = "",
    max_bytes: Int = _MAX_BYTES,
) raises -> Tuple[_PostLeg, _Server]:
    var server = _Server(replies^)
    var leg = _PostLeg(
        server.port,
        request,
        embed=embed,
        path=path,
        auth_name=auth_name,
        auth_value=auth_value,
        max_bytes=max_bytes,
    )
    _serve_while(server, leg)
    return (leg^, server^)


def _one(var reply: List[UInt8]) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(reply^)
    return out^


def _head(server: _Server, i: Int) -> String:
    """The request head of connection `i`, lower-cased."""
    var req = server.requests[i].copy()
    var end = _find(req, "\r\n\r\n")
    return _lower(String(from_utf8_lossy=Span(req)[0:end]))


def _body(server: _Server, i: Int) -> String:
    """The request body of connection `i`, exactly as received."""
    var req = server.requests[i].copy()
    var end = _find(req, "\r\n\r\n")
    return String(from_utf8_lossy=Span(req)[end + 4 :])


# -----------------------------------------------------------------------------
# Request shape, path and credential.
# -----------------------------------------------------------------------------


def test_request_shape() raises:
    var request = String('{"model":"m","note":"a \\"quoted\\" café"}')
    var r = _post(_one(http_reply(200, '{"ok":true}')), request)
    ref leg = r[0]
    ref server = r[1]
    assert_equal(leg.error, "")
    assert_equal(leg.result, '{"ok":true}')
    assert_equal(len(server.requests), 1)
    var head = _head(server, 0)
    assert_true(head.startswith("post /wire/post http/1.1\r\n"), head)
    assert_true("accept: application/json" in head, head)
    assert_true("content-type: application/json" in head, head)
    assert_true(
        "content-length: " + String(request.byte_length()) in head, head
    )
    assert_true("host: 127.0.0.1:" + String(server.port) in head, head)
    assert_equal(_body(server, 0), request)


def test_configured_path_and_auth_header() raises:
    var a = _post(
        _one(http_reply(200, "{}")),
        "{}",
        path="/first/path?x=1",
        auth_name="X-Api-Credential",
        auth_value="scheme-one token-1",
    )
    var head_a = _head(a[1], 0)
    assert_equal(a[0].error, "")
    assert_true(head_a.startswith("post /first/path?x=1 http/1.1\r\n"), head_a)
    assert_true("x-api-credential: scheme-one token-1\r\n" in head_a + "\r\n", head_a)
    var b = _post(
        _one(http_reply(200, "{}")),
        "{}",
        embed=True,
        path="/second",
        auth_name="Other-Name",
        auth_value="v2",
    )
    var head_b = _head(b[1], 0)
    assert_equal(b[0].error, "")
    assert_true(head_b.startswith("post /second http/1.1\r\n"), head_b)
    assert_true("other-name: v2\r\n" in head_b + "\r\n", head_b)
    assert_false("x-api-credential" in head_b, head_b)
    assert_false("token-1" in head_b, head_b)


def test_no_provider_sends_no_credential() raises:
    var r = _post(_one(http_reply(200, "{}")), "{}")
    var head = _head(r[1], 0)
    assert_equal(r[0].error, "")
    assert_false("authorization" in head, head)
    assert_false("credential" in head, head)


struct _FixedProvider(AuthHeaderProvider):
    var name: String
    var value: String
    var fail: Bool

    def __init__(out self, name: String, value: String, fail: Bool):
        self.name = name
        self.value = value
        self.fail = fail

    def header(self) raises -> Optional[AuthHeader]:
        if self.fail:
            raise Error("provider: no credential available")
        return Optional[AuthHeader](AuthHeader(self.name, self.value))


def _mk_probe(timeout_ms: Int) raises -> KernelTcpConnector:
    raise Error("connector made, timeout_ms=" + String(timeout_ms))


def _post_with_provider(name: String, value: String, fail: Bool) -> String:
    """The error of a call whose connector factory records that it was reached."""
    try:
        var ep = WireEndpoint(
            "127.0.0.1",
            UInt16(9),
            "/p",
            timeout_ms=_TIMEOUT_MS,
            max_response_bytes=_MAX_BYTES,
        )
        var t = HttpChatTransport[KernelTcpConnector, _FixedProvider](
            _mk_probe, ep^, _FixedProvider(name, value, fail)
        )
        _ = t.complete("{}")
    except e:
        return String(e)
    return String("no error")


def test_unsafe_auth_header_is_refused_before_dialing() raises:
    # A line break in the value would end the header and start another.
    var split = _post_with_provider("X-Credential", "ok\r\nInjected: 1", False)
    assert_true("control byte" in split, split)
    assert_false("connector made" in split, split)
    assert_false("Injected" in split, split)
    var owned = _post_with_provider("Content-Length", "5", False)
    assert_true("writes itself" in owned, owned)
    assert_false("connector made" in owned, owned)
    var failing = _post_with_provider("X-Credential", "ok", True)
    assert_true("no credential available" in failing, failing)
    assert_false("connector made" in failing, failing)
    # The control: a safe header reaches the connector factory.
    var safe = _post_with_provider("X-Credential", "ok", False)
    assert_true("connector made" in safe, safe)


# -----------------------------------------------------------------------------
# Failures.
# -----------------------------------------------------------------------------


def test_non_success_status_is_refused() raises:
    var statuses = List[Int]()
    statuses.append(500)
    statuses.append(404)
    statuses.append(301)
    for k in range(len(statuses)):
        var status = statuses[k]
        var r = _post(
            _one(http_reply(status, "refused: reason " + String(status))),
            "{}",
            auth_name="X-Credential",
            auth_value="secret-value",
        )
        assert_equal(r[0].result, "")
        assert_true(
            "answered HTTP " + String(status) + ", body begins refused: reason "
            in r[0].error,
            r[0].error,
        )
        # The error never quotes what was sent.
        assert_false("secret-value" in r[0].error, r[0].error)


def test_non_success_status_quotes_a_bounded_body() raises:
    # Longer than what is quoted, shorter than the size bound.
    var long_body = String()
    for _ in range(375):
        long_body += "abcdefgh"
    var r = _post(_one(http_reply(503, long_body)), "{}")
    assert_true("answered HTTP 503" in r[0].error, r[0].error)
    # The status text plus at most 256 bytes of the body.
    assert_true(r[0].error.byte_length() < 400, String(r[0].error.byte_length()))
    assert_true("abcdefgh" in r[0].error)


def test_success_range_is_accepted() raises:
    var r = _post(_one(http_reply(201, "created")), "{}")
    assert_equal(r[0].error, "")
    assert_equal(r[0].result, "created")


def test_truncated_body_is_refused() raises:
    var cut = _bytes_of(
        "HTTP/1.1 200 Scripted\r\nContent-Length: 100\r\nConnection:"
        " close\r\n\r\n0123456789"
    )
    var r = _post(_one(cut^), "{}")
    assert_equal(r[0].result, "")
    assert_true(r[0].error.byte_length() > 0, "a short body must be refused")
    # A refusal is one connection: nothing retried it.
    assert_equal(len(r[1].requests), 1)


def test_response_size_is_bounded() raises:
    # Declared over the bound.
    var big = String()
    for _ in range(100):
        big += "0123456789"
    var over = _post(_one(http_reply(200, big)), "{}", max_bytes=999)
    assert_equal(over[0].result, "")
    assert_true(over[0].error.byte_length() > 0, "a body over the bound")
    # Exactly the bound is accepted, one byte more is not.
    var at = _post(_one(http_reply(200, big)), "{}", max_bytes=1000)
    assert_equal(at[0].error, "")
    assert_equal(at[0].result, big)
    # Chunked, with no declared length: the bound still holds.
    var chunked = String(
        "HTTP/1.1 200 Scripted\r\nTransfer-Encoding: chunked\r\nConnection:"
        " close\r\n\r\n"
    )
    for _ in range(10):
        chunked += "64\r\n" + String("x") * 100 + "\r\n"
    chunked += "0\r\n\r\n"
    var cho = _post(_one(_bytes_of(chunked)), "{}", max_bytes=999)
    assert_equal(cho[0].result, "")
    assert_true(cho[0].error.byte_length() > 0, "a chunked body over the bound")
    var chu = _post(_one(_bytes_of(chunked)), "{}", max_bytes=1000)
    assert_equal(chu[0].error, "")
    assert_equal(chu[0].result.byte_length(), 1000)


def test_non_utf8_body_is_refused() raises:
    var reply = _bytes_of(
        "HTTP/1.1 200 Scripted\r\nContent-Length: 4\r\nConnection:"
        " close\r\n\r\n"
    )
    reply.append(UInt8(0x61))
    reply.append(UInt8(0xFF))
    reply.append(UInt8(0xFE))
    reply.append(UInt8(0x62))
    var r = _post(_one(reply^), "{}")
    assert_equal(r[0].result, "")
    assert_true("not UTF-8" in r[0].error, r[0].error)


def test_a_failed_call_is_not_retried() raises:
    var replies = List[List[UInt8]]()
    replies.append(http_reply(500, "first"))
    replies.append(http_reply(200, "second"))
    var r = _post(replies^, "{}")
    assert_true("answered HTTP 500" in r[0].error, r[0].error)
    assert_equal(r[0].result, "")
    assert_equal(len(r[1].requests), 1)
    assert_equal(r[1].served, 1)


# -----------------------------------------------------------------------------
# The timeout value and the scheme.
# -----------------------------------------------------------------------------


def _timeout_reaches(timeout_ms: Int) -> String:
    try:
        var ep = WireEndpoint(
            "127.0.0.1",
            UInt16(9),
            "/p",
            timeout_ms=timeout_ms,
            max_response_bytes=_MAX_BYTES,
        )
        var t = HttpEmbedTransport[KernelTcpConnector, NoAuth](
            _mk_probe, ep^, NoAuth()
        )
        _ = t.complete("{}")
    except e:
        return String(e)
    return String("no error")


def test_timeout_value_reaches_the_connector() raises:
    # The connector factory is handed the endpoint's time bound; the factory here
    # fails with it, so the call neither dials nor waits.
    assert_equal(_timeout_reaches(1234), "connector made, timeout_ms=1234")
    assert_equal(_timeout_reaches(77), "connector made, timeout_ms=77")
    # The client is configured with the same bound, in microseconds, and with the
    # size bound.
    var ep = WireEndpoint(
        "127.0.0.1",
        UInt16(9),
        "/p",
        timeout_ms=1234,
        max_response_bytes=5678,
    )
    var chat = HttpChatTransport[KernelTcpConnector, NoAuth](
        _mk_probe, ep.copy(), NoAuth()
    )
    assert_equal(chat.client_config().request_timeout_us, 1_234_000)
    assert_equal(chat.client_config().max_response_body_bytes, 5678)
    var embed = HttpEmbedTransport[KernelTcpConnector, NoAuth](
        _mk_probe, ep^, NoAuth()
    )
    assert_equal(embed.client_config().request_timeout_us, 1_234_000)
    assert_equal(embed.client_config().max_response_body_bytes, 5678)


comptime _HTTPS_REPLY: StaticString = (
    "HTTP/1.1 200 Scripted\r\nContent-Length: 7\r\nConnection:"
    " close\r\n\r\n{\"a\":1}"
)


def _mk_tls(timeout_ms: Int) raises -> ScriptedConnector:
    var script = _bytes_of(String(_HTTPS_REPLY))
    return ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script(script^)
    )


def test_https_connector_posts_https() raises:
    var ep = WireEndpoint(
        "model.example.com",
        UInt16(443),
        "/v1/x",
        timeout_ms=_TIMEOUT_MS,
        max_response_bytes=_MAX_BYTES,
    )
    var t = HttpChatTransport[ScriptedConnector, NoAuth](_mk_tls, ep^, NoAuth())
    assert_equal(t.complete("{}"), '{"a":1}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
