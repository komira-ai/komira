# =============================================================================
# test_grpc_http_non_200_status.mojo — a non-200 HTTP status reaches the caller
# as the code the spec's HTTP-to-gRPC table gives, on all four entry points
# =============================================================================
#
# WHY THIS FILE EXISTS. Classic gRPC answers every RPC with `:status: 200`; a
# non-200 means something in FRONT of the service answered: an edge proxy's
# 503, a rate limiter's 429, an auth layer's 401. `grpc/doc/http-grpc-status-
# mapping.md` gives the table (error.mojo §4): 429/502/503/504 -> UNAVAILABLE,
# 401 -> UNAUTHENTICATED, 403 -> PERMISSION_DENIED, 404 -> UNIMPLEMENTED,
# 400 -> INTERNAL, anything else -> UNKNOWN.
#
# THE DEFECT THIS PINS. The table existed but no entry point used it. A proxy's
# 503 page (`text/html`) reached the caller as `[grpc:13]` (the content-type
# check) or `[grpc:2]` (the unary decode), and neither is in
# `RetryPolicy.idempotent()`'s retryable set (UNAVAILABLE only). So the most
# common transient failure there is, an overloaded front end, was never
# replayed. (g6) drives exactly that through `unary_call_retrying`.
#
# WHAT EACH CASE CATCHES:
#   (g1) unary_call, HTTP/1.1 503 + text/html -> [grpc:14], and the message
#        still names status=503. RED if the non-200 check is missing or runs
#        after the content-type check (the result is then [grpc:13]).
#   (g2) unary_call, one row per table class: 401 -> 16, 403 -> 7, 404 -> 12,
#        429 -> 14, 400 -> 13, 500 -> 2. RED on a wrong row; the 500 row
#        guards the opposite mistake, "every 5xx is UNAVAILABLE", which would
#        replay a CREATE that may have landed.
#   (g3) unary_call, HTTP 503 that ALSO states `grpc-status: 7` -> [grpc:7].
#        The spec's table applies only when no grpc-status was sent. RED if
#        the HTTP mapping is moved ahead of the stated status.
#   (g4) server_stream, (g5) client_stream, (g5b) bidi_stream: 503 -> 14.
#        RED if any streaming entry point lacks the check.
#   (g6) unary_call_retrying under the idempotent policy: a 503 page on
#        attempt 1, a success on attempt 2 -> the success comes back. RED
#        whenever the 503 is not UNAVAILABLE (the call raises on attempt 1).
#
# Hermetic: a ScriptedConnector byte script, no socket, no network, no thread.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient
from komira_http_client.url import Url
from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_grpc import (
    BidiStreamCodec,
    CallOptions,
    ClientStreamEncoder,
    GrpcClient,
    ProtocolGrpcProto,
    RETRY_CODES_AIP194,
    RetryPolicy,
    encode_unary_request,
    parse_grpc_status_code,
)


comptime RT = PerCoreAsyncRuntime[NoopSink]

comptime _PATH: String = "/test.EchoService/Call"

comptime _GRPC_UNKNOWN: Int = 2
comptime _GRPC_PERMISSION_DENIED: Int = 7
comptime _GRPC_UNIMPLEMENTED: Int = 12
comptime _GRPC_INTERNAL: Int = 13
comptime _GRPC_UNAVAILABLE: Int = 14
comptime _GRPC_UNAUTHENTICATED: Int = 16

comptime _PROXY_PAGE: String = (
    "<html><head><title>503 Service Unavailable</title></head><body>"
    "<h1>503 Service Unavailable</h1></body></html>"
)


# =============================================================================
# §0 — fixtures
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _text(bytes: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(bytes)):
        s += chr(Int(bytes[i]))
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _http1_response(
    status: Int, var extra_headers: String, body: String
) -> List[UInt8]:
    """One canned HTTP/1.1 response: `status`, `text/html`, an exact
    Content-Length, and any `extra_headers` (each ending CRLF)."""
    return _b(
        String("HTTP/1.1 ")
        + String(status)
        + " Scripted\r\nContent-Type: text/html\r\n"
        + extra_headers
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n\r\n"
        + body
    )


def _h1_client(var wire: List[UInt8]) raises -> GrpcClient[ScriptedConnector]:
    var stream = ScriptedStream.from_read_script(wire^)
    var connector = ScriptedConnector.with_stream(stream^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("http://127.0.0.1:8080/"))
    return GrpcClient[ScriptedConnector](http^, base^)


def _unary_over(var wire: List[UInt8]) raises -> Tuple[Bool, String]:
    """Drive one `unary_call` against `wire`; (raised, error message)."""
    var client = _h1_client(wire^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("req"))
    try:
        var r = client.unary_call[RT, ProtocolGrpcProto](
            String(_PATH), Span(msg), opts, Int(0), reactor, token
        )
        _ = len(r.message_bytes)
    except e:
        return (True, String(e))
    return (False, String(""))


def _expect_code(
    what: String, outcome: Tuple[Bool, String], expected: Int
) raises:
    if not outcome[0]:
        raise Error(what + ": returned a result instead of raising")
    var got = parse_grpc_status_code(outcome[1])
    if got != expected:
        raise Error(
            what
            + ": expected [grpc:"
            + String(expected)
            + "], got: "
            + outcome[1]
        )


# =============================================================================
# §1 — unary_call
# =============================================================================


def test_unary_proxy_503_page_is_unavailable() raises:
    """(g1) A proxy's 503 HTML page -> [grpc:14], status kept in the text."""
    var out = _unary_over(_http1_response(503, String(""), _PROXY_PAGE))
    _expect_code(String("unary 503 text/html"), out, _GRPC_UNAVAILABLE)
    assert_true(
        String("status=503") in out[1],
        String("the HTTP status must stay in the message. got: ") + out[1],
    )


def test_unary_maps_each_table_class() raises:
    """(g2) One row per class of the spec's table, including the 500 row that
    must NOT become UNAVAILABLE."""
    _unary_row(401, _GRPC_UNAUTHENTICATED)
    _unary_row(403, _GRPC_PERMISSION_DENIED)
    _unary_row(404, _GRPC_UNIMPLEMENTED)
    _unary_row(429, _GRPC_UNAVAILABLE)
    _unary_row(400, _GRPC_INTERNAL)
    _unary_row(500, _GRPC_UNKNOWN)


def _unary_row(status: Int, expected: Int) raises:
    var out = _unary_over(_http1_response(status, String(""), String("denied")))
    _expect_code(String("unary HTTP ") + String(status), out, expected)


def test_unary_stated_grpc_status_wins_over_the_http_status() raises:
    """(g3) A non-200 that states its own `grpc-status` keeps that status."""
    var out = _unary_over(
        _http1_response(
            503,
            String("grpc-status: 7\r\ngrpc-message: stated\r\n"),
            String("x"),
        )
    )
    _expect_code(
        String("unary 503 with grpc-status 7"), out, _GRPC_PERMISSION_DENIED
    )


# =============================================================================
# §2 — the three streaming entry points
# =============================================================================


def test_server_stream_proxy_503_is_unavailable() raises:
    """(g4) server_stream: 503 -> [grpc:14], not a decoder of HTML bytes."""
    var client = _h1_client(_http1_response(503, String(""), _PROXY_PAGE))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var req = _b(String("read"))
    var raised = False
    var message = String("")
    try:
        var decoder = client.server_stream[RT, ProtocolGrpcProto](
            String(_PATH), Span(req), opts, Int(0), reactor, token
        )
        _ = decoder^
    except e:
        raised = True
        message = String(e)
    _expect_code(
        String("server_stream 503"), (raised, message), _GRPC_UNAVAILABLE
    )


def test_client_stream_proxy_503_is_unavailable() raises:
    """(g5) client_stream: 503 -> [grpc:14]."""
    var client = _h1_client(_http1_response(503, String(""), _PROXY_PAGE))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
    encoder.encode_message(Span(_b(String("chunk-1"))))
    encoder.mark_close()
    var raised = False
    var message = String("")
    try:
        var r = client.client_stream[RT, ProtocolGrpcProto](
            String(_PATH), encoder^, opts, Int(0), reactor, token
        )
        _ = len(r.message_bytes)
    except e:
        raised = True
        message = String(e)
    _expect_code(
        String("client_stream 503"), (raised, message), _GRPC_UNAVAILABLE
    )


def test_bidi_stream_proxy_503_is_unavailable() raises:
    """(g5b) bidi_stream: 503 -> [grpc:14]."""
    var client = _h1_client(_http1_response(503, String(""), _PROXY_PAGE))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var codec = BidiStreamCodec[ProtocolGrpcProto].new()
    codec.encoder.encode_message(Span(_b(String("Q1"))))
    codec.encoder.mark_close()
    var raised = False
    var message = String("")
    try:
        var decoder = client.bidi_stream[RT, ProtocolGrpcProto](
            String(_PATH), codec^, opts, Int(0), reactor, token
        )
        _ = decoder^
    except e:
        raised = True
        message = String(e)
    _expect_code(
        String("bidi_stream 503"), (raised, message), _GRPC_UNAVAILABLE
    )


# =============================================================================
# §3 — the reason it matters: a proxy 503 is replayed
# =============================================================================


def _h2_script_503_then_success(payload: String) raises -> List[UInt8]:
    """One h2 connection: stream 1 is a proxy's 503 HTML page (no
    grpc-status), stream 3 a successful unary response carrying `payload`.
    One HpackEncoder for the whole script (the dynamic table is shared)."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var hpack = HpackEncoder(max_table_size=4096)

    var page = _b(_PROXY_PAGE)
    var h1 = List[HpackHeader]()
    h1.append(HpackHeader(String(":status"), String("503")))
    h1.append(HpackHeader(String("content-type"), String("text/html")))
    h1.append(HpackHeader(String("content-length"), String(len(page))))
    var b1 = hpack.encode_block(h1^)
    encode_headers_frame(
        UInt32(1), b1^, end_stream=False, end_headers=True, out=out
    )
    encode_data_frame(UInt32(1), page^, end_stream=True, out=out)

    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(payload)))
    var h3 = List[HpackHeader]()
    h3.append(HpackHeader(String(":status"), String("200")))
    h3.append(HpackHeader(String("content-type"), String("application/grpc")))
    h3.append(HpackHeader(String("grpc-status"), String("0")))
    h3.append(HpackHeader(String("content-length"), String(len(body))))
    var b3 = hpack.encode_block(h3^)
    encode_headers_frame(
        UInt32(3), b3^, end_stream=False, end_headers=True, out=out
    )
    encode_data_frame(UInt32(3), body^, end_stream=True, out=out)
    return out^


def test_proxy_503_is_replayed_by_the_idempotent_policy() raises:
    """(g6) `unary_call_retrying` replays a proxy 503 and returns attempt 2.

    h2 rig as in `test_unary_status_retry.mojo`: ALPN h2 reported (or the
    pooled send falls back to HTTP/1.1) and one byte per read (or a greedy
    read swallows stream 3's frames before the replay opens it). An IP
    authority, so the dial resolves no name. The policy is the idempotent
    code set at 1 ms backoff."""
    var s = ScriptedStream.from_read_script(
        _h2_script_503_then_success(String("SECOND-ATTEMPT"))
    )
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream_tls(s^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var client = GrpcClient[ScriptedConnector](
        http^, Url.parse(String("https://127.0.0.1:443/"))
    )
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("req"))
    var policy = RetryPolicy(5, 1, 1, 130, RETRY_CODES_AIP194)
    var returned = String("")
    try:
        var r = client.unary_call_retrying[RT, ProtocolGrpcProto](
            String(_PATH), Span(msg), opts, Int(0), reactor, token, policy
        )
        returned = _text(r.message_bytes)
    except e:
        raise Error(
            String(
                "a proxy 503 was not replayed under the idempotent policy;"
                " the call raised on attempt 1: "
            )
            + String(e)
        )
    assert_equal(
        returned,
        String("SECOND-ATTEMPT"),
        "the replay must return attempt 2's response",
    )


# =============================================================================
# §4 — driver: every case runs, so one RED does not mask the next
# =============================================================================


def main() raises:
    print("test_grpc_http_non_200_status: the HTTP-to-gRPC table, end to end")
    var failures = List[String]()

    try:
        test_unary_proxy_503_page_is_unavailable()
        print("  PASS  (g1) unary 503 page -> UNAVAILABLE")
    except e:
        failures.append(String("g1: ") + String(e))
        print("  FAIL  (g1) unary 503 page -> UNAVAILABLE")

    try:
        test_unary_maps_each_table_class()
        print("  PASS  (g2) unary maps each table class")
    except e:
        failures.append(String("g2: ") + String(e))
        print("  FAIL  (g2) unary maps each table class")

    try:
        test_unary_stated_grpc_status_wins_over_the_http_status()
        print("  PASS  (g3) a stated grpc-status wins over the HTTP status")
    except e:
        failures.append(String("g3: ") + String(e))
        print("  FAIL  (g3) a stated grpc-status wins over the HTTP status")

    try:
        test_server_stream_proxy_503_is_unavailable()
        print("  PASS  (g4) server_stream 503 -> UNAVAILABLE")
    except e:
        failures.append(String("g4: ") + String(e))
        print("  FAIL  (g4) server_stream 503 -> UNAVAILABLE")

    try:
        test_client_stream_proxy_503_is_unavailable()
        print("  PASS  (g5) client_stream 503 -> UNAVAILABLE")
    except e:
        failures.append(String("g5: ") + String(e))
        print("  FAIL  (g5) client_stream 503 -> UNAVAILABLE")

    try:
        test_bidi_stream_proxy_503_is_unavailable()
        print("  PASS  (g5b) bidi_stream 503 -> UNAVAILABLE")
    except e:
        failures.append(String("g5b: ") + String(e))
        print("  FAIL  (g5b) bidi_stream 503 -> UNAVAILABLE")

    try:
        test_proxy_503_is_replayed_by_the_idempotent_policy()
        print("  PASS  (g6) a proxy 503 is replayed and succeeds")
    except e:
        failures.append(String("g6: ") + String(e))
        print("  FAIL  (g6) a proxy 503 is replayed and succeeds")

    if len(failures) > 0:
        var report = String("test_grpc_http_non_200_status: ")
        report += String(len(failures)) + " case(s) FAILED\n"
        for i in range(len(failures)):
            report += String("\n---- ") + failures[i] + "\n"
        raise Error(report)
    print("test_grpc_http_non_200_status: ALL PASS")
