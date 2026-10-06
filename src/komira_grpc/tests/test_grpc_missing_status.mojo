# =============================================================================
# test_grpc_missing_status.mojo — a classic-gRPC response that carries NO
# `grpc-status` is an error, on every GrpcClient entry point
# =============================================================================
#
# PROTOCOL-HTTP2 ("Responses"): every response ends with `Trailers`, and
# `Trailers -> Status [Status-Message] *Custom-Metadata`, `Status ->
# "grpc-status"`. A trailers-only response carries the same fields in its
# single HEADERS frame. A response with neither is a protocol violation: a
# truncated stream, or an intermediary that dropped the trailers. Reading it
# as OK hands the caller a silent false success, possibly with no message.
#
# THE CODES, as the reference clients choose them:
#   * the response ENDED IN A TRAILERS block that has no `grpc-status`
#       -> UNKNOWN(2)   (grpc-java `statusFromTrailers`: "missing GRPC status
#                        in response"; grpc-go `operateHeaders` starts from
#                        codes.Unknown and keeps it when no grpc-status comes)
#   * the response ended on a DATA frame with NO trailers at all
#       -> INTERNAL(13) (grpc-go `handleData`: "server closed the stream
#                        without sending trailers"; grpc-java: "Received
#                        unexpected EOS on non-empty DATA frame from server")
#   * a bodyless HTTP 200 with no `grpc-status` (a trailers-only response
#     without its status)
#       -> UNKNOWN(2)   (grpc/doc/http-grpc-status-mapping.md: "200 is UNKNOWN
#                        because there should be a grpc-status in case of
#                        truly OK response")
#   * a non-200 with no `grpc-status`
#       -> the spec's HTTP->gRPC table (503 -> UNAVAILABLE(14)), as grpc-java
#          and grpc-go both map it.
#
# Each case names the defect it catches: before the fix every one of these
# calls either RETURNED (unary / streams read the missing status as OK) or
# raised the wrong code. The two CONTROL cases pin that a response which DOES
# carry `grpc-status: 0` is untouched, and that Connect (which carries no
# `grpc-status` by design) is not subject to the check.
#
# Rig: the HTTP/2 ScriptedStream of `test_grpc_client_trailers_only_and_streams`
# (ALPN h2 reported, one byte per read), and its HTTP/1.1 rig for the one case
# about the HTTP/1.1 fallback. Hermetic: no socket, no thread.
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
    ProtocolConnectProto,
    ProtocolGrpcProto,
    ServerStreamDecoder,
    STREAM_OUTCOME_MESSAGE,
    encode_stream_message,
    encode_unary_request,
    parse_grpc_status_code,
)


comptime RT = PerCoreAsyncRuntime[NoopSink]

comptime _PATH: String = "/test.EchoService/Call"

comptime _UNKNOWN: Int = 2
comptime _INTERNAL: Int = 13
comptime _UNAVAILABLE: Int = 14

# The three entry-point kinds a case runs on.
comptime _UNARY: Int = 0
comptime _SERVER_STREAM: Int = 1
comptime _CLIENT_STREAM: Int = 2
comptime _BIDI: Int = 3


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


def _h2_client(var script: List[UInt8]) raises -> GrpcClient[ScriptedConnector]:
    """One scripted h2 connection served one byte per read. ALPN h2 must be
    reported (or the client falls back to HTTP/1.1), and one byte per read
    keeps a greedy read from pulling frames for a stream not yet created."""
    var s = ScriptedStream.from_read_script(script^)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream_tls(s^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("https://run.googleapis.com:443/"))
    return GrpcClient[ScriptedConnector](http^, base^)


def _h1_client(var wire: List[UInt8]) raises -> GrpcClient[ScriptedConnector]:
    var stream = ScriptedStream.from_read_script(wire^)
    var connector = ScriptedConnector.with_stream(stream^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("http://127.0.0.1:8080/"))
    return GrpcClient[ScriptedConnector](http^, base^)


def _http_200(content_type: String, body: List[UInt8]) -> List[UInt8]:
    """A canned HTTP/1.1 200 with an exact Content-Length and NO grpc-status
    header (HTTP/1.1 cannot carry the trailers classic gRPC needs)."""
    var out = _b(
        String("HTTP/1.1 200 OK\r\nContent-Type: ")
        + content_type
        + "\r\nContent-Length: "
        + String(len(body))
        + "\r\n\r\n"
    )
    for i in range(len(body)):
        out.append(body[i])
    return out^


# Response shapes on stream 1. `trailer_status` < 0 sends trailers WITHOUT a
# `grpc-status` (only a `grpc-message`); >= 0 sends `grpc-status: <n>`.
comptime _SHAPE_TRAILERS_ONLY: Int = 0
"""One HEADERS frame with END_STREAM and no body."""
comptime _SHAPE_DATA_EOS: Int = 1
"""HEADERS, then one DATA frame with END_STREAM: no trailers at all."""
comptime _SHAPE_DATA_TRAILERS: Int = 2
"""HEADERS, DATA, then a real TRAILERS block with END_STREAM."""


def _script(
    shape: Int,
    http_status: String,
    var body: List[UInt8],
    trailer_status: Int,
) raises -> List[UInt8]:
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), http_status))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    var block = hpack.encode_block(hdrs^)
    if shape == _SHAPE_TRAILERS_ONLY:
        encode_headers_frame(
            UInt32(1), block^, end_stream=True, end_headers=True, out=out
        )
        return out^
    encode_headers_frame(
        UInt32(1), block^, end_stream=False, end_headers=True, out=out
    )
    if shape == _SHAPE_DATA_EOS:
        encode_data_frame(UInt32(1), body^, end_stream=True, out=out)
        return out^
    encode_data_frame(UInt32(1), body^, end_stream=False, out=out)
    var trailers = List[HpackHeader]()
    if trailer_status >= 0:
        trailers.append(
            HpackHeader(String("grpc-status"), String(trailer_status))
        )
    trailers.append(
        HpackHeader(String("grpc-message"), String("trailer-without-status"))
    )
    var tblock = hpack.encode_block(trailers^)
    encode_headers_frame(
        UInt32(1), tblock^, end_stream=True, end_headers=True, out=out
    )
    return out^


def _two_messages() -> List[UInt8]:
    var body = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("M1"))))
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("M2"))))
    return body^


def _drain(var decoder: ServerStreamDecoder[ProtocolGrpcProto]) raises -> Int:
    var n = 0
    for _ in range(200):
        var o = decoder.try_next_message()
        if o.kind != STREAM_OUTCOME_MESSAGE:
            break
        n += 1
    return n


def _call(
    kind: Int, var client: GrpcClient[ScriptedConnector]
) raises -> Tuple[Bool, String, String]:
    """Run one call of `kind` (classic gRPC). Returns (raised, error text,
    a description of what came back on success)."""
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var req = _b(String("req"))
    try:
        if kind == _UNARY:
            var r = client.unary_call[RT, ProtocolGrpcProto](
                String(_PATH), Span(req), opts, Int(0), reactor, token
            )
            return (False, String(""), String("unary '") + _text(r.message_bytes) + "'")
        elif kind == _SERVER_STREAM:
            var d = client.server_stream[RT, ProtocolGrpcProto](
                String(_PATH), Span(req), opts, Int(0), reactor, token
            )
            return (False, String(""), String(_drain(d^)) + " stream message(s)")
        elif kind == _CLIENT_STREAM:
            var enc = ClientStreamEncoder[ProtocolGrpcProto].new()
            enc.encode_message(Span(req))
            enc.mark_close()
            var r = client.client_stream[RT, ProtocolGrpcProto](
                String(_PATH), enc^, opts, Int(0), reactor, token
            )
            return (False, String(""), String("client-stream '") + _text(r.message_bytes) + "'")
        else:
            var codec = BidiStreamCodec[ProtocolGrpcProto].new()
            codec.encoder.encode_message(Span(req))
            codec.encoder.mark_close()
            var d = client.bidi_stream[RT, ProtocolGrpcProto](
                String(_PATH), codec^, opts, Int(0), reactor, token
            )
            return (False, String(""), String(_drain(d^)) + " bidi message(s)")
    except e:
        return (True, String(e), String(""))


def _expect_status(
    what: String,
    got: Tuple[Bool, String, String],
    code: Int,
) raises:
    """`got` must be a raise carrying `[grpc:<code>]` whose text names the
    missing `grpc-status`."""
    if not got[0]:
        raise Error(
            what
            + ": a response with NO grpc-status was read as OK and returned "
            + got[2]
        )
    if parse_grpc_status_code(got[1]) != code:
        raise Error(
            what + ": expected [grpc:" + String(code) + "], got: " + got[1]
        )
    if String("grpc-status") not in got[1]:
        raise Error(what + ": the error does not name grpc-status: " + got[1])


# =============================================================================
# §1 — trailers present, `grpc-status` absent -> UNKNOWN
# =============================================================================


def test_trailers_without_grpc_status_are_unknown() raises:
    """A real TRAILERS block that carries `grpc-message` but no `grpc-status`.
    Defect caught: the client reads the absent status as OK."""
    _expect_status(
        "unary",
        _call(
            _UNARY,
            _h2_client(
                _script(
                    _SHAPE_DATA_TRAILERS,
                    String("200"),
                    encode_unary_request[ProtocolGrpcProto](Span(_b(String("resp")))),
                    -1,
                )
            ),
        ),
        _UNKNOWN,
    )
    _expect_status(
        "server_stream",
        _call(
            _SERVER_STREAM,
            _h2_client(
                _script(_SHAPE_DATA_TRAILERS, String("200"), _two_messages(), -1)
            ),
        ),
        _UNKNOWN,
    )


# =============================================================================
# §2 — no trailers at all (END_STREAM on DATA) -> INTERNAL
# =============================================================================


def test_stream_ended_without_trailers_is_internal() raises:
    """HEADERS + DATA(END_STREAM), no trailers: the shape a proxy that drops
    trailers produces. All four entry points must raise INTERNAL."""
    _expect_status(
        "unary",
        _call(
            _UNARY,
            _h2_client(
                _script(
                    _SHAPE_DATA_EOS,
                    String("200"),
                    encode_unary_request[ProtocolGrpcProto](Span(_b(String("resp")))),
                    -1,
                )
            ),
        ),
        _INTERNAL,
    )
    _expect_status(
        "server_stream",
        _call(
            _SERVER_STREAM,
            _h2_client(_script(_SHAPE_DATA_EOS, String("200"), _two_messages(), -1)),
        ),
        _INTERNAL,
    )
    _expect_status(
        "client_stream",
        _call(
            _CLIENT_STREAM,
            _h2_client(_script(_SHAPE_DATA_EOS, String("200"), _two_messages(), -1)),
        ),
        _INTERNAL,
    )
    _expect_status(
        "bidi_stream",
        _call(
            _BIDI,
            _h2_client(_script(_SHAPE_DATA_EOS, String("200"), _two_messages(), -1)),
        ),
        _INTERNAL,
    )


def test_http1_fallback_without_grpc_status_is_internal() raises:
    """Classic gRPC answered over HTTP/1.1 (the client's fallback when ALPN
    does not select h2): a 200 with an enveloped body and no `grpc-status`.
    HTTP/1.1 surfaces no trailers, so the outcome is unknowable; it must not be
    read as OK."""
    _expect_status(
        "unary over HTTP/1.1",
        _call(
            _UNARY,
            _h1_client(
                _http_200(
                    String("application/grpc"),
                    encode_unary_request[ProtocolGrpcProto](Span(_b(String("resp")))),
                )
            ),
        ),
        _INTERNAL,
    )


# =============================================================================
# §3 — bodyless response with no status -> UNKNOWN (200) / HTTP table (non-200)
# =============================================================================


def test_trailers_only_without_grpc_status_is_unknown() raises:
    """One HEADERS frame (`:status: 200`, END_STREAM) and no `grpc-status`.
    Defect caught: unary/server_stream return an empty success."""
    _expect_status(
        "unary",
        _call(
            _UNARY,
            _h2_client(
                _script(_SHAPE_TRAILERS_ONLY, String("200"), List[UInt8](), -1)
            ),
        ),
        _UNKNOWN,
    )
    _expect_status(
        "server_stream",
        _call(
            _SERVER_STREAM,
            _h2_client(
                _script(_SHAPE_TRAILERS_ONLY, String("200"), List[UInt8](), -1)
            ),
        ),
        _UNKNOWN,
    )


def test_non_200_without_grpc_status_maps_through_the_http_table() raises:
    """A bodyless `:status: 503` with no `grpc-status` (a proxy's answer) is
    UNAVAILABLE per the spec's HTTP->gRPC table. Defects caught: server_stream
    returned an empty success; unary collapsed it to UNKNOWN, outside the
    retryable set."""
    _expect_status(
        "unary",
        _call(
            _UNARY,
            _h2_client(
                _script(_SHAPE_TRAILERS_ONLY, String("503"), List[UInt8](), -1)
            ),
        ),
        _UNAVAILABLE,
    )
    _expect_status(
        "server_stream",
        _call(
            _SERVER_STREAM,
            _h2_client(
                _script(_SHAPE_TRAILERS_ONLY, String("503"), List[UInt8](), -1)
            ),
        ),
        _UNAVAILABLE,
    )


# =============================================================================
# §4 — controls: a stated status is untouched; Connect is not subject
# =============================================================================


def test_a_stated_ok_status_still_succeeds() raises:
    """`grpc-status: 0` in real trailers: unary returns its message and
    server_stream its two. Catches a check that fires when the status IS
    present."""
    var u = _call(
        _UNARY,
        _h2_client(
            _script(
                _SHAPE_DATA_TRAILERS,
                String("200"),
                encode_unary_request[ProtocolGrpcProto](Span(_b(String("resp")))),
                0,
            )
        ),
    )
    if u[0]:
        raise Error(String("unary with grpc-status 0 raised: ") + u[1])
    assert_equal(u[2], String("unary 'resp'"))
    var s = _call(
        _SERVER_STREAM,
        _h2_client(_script(_SHAPE_DATA_TRAILERS, String("200"), _two_messages(), 0)),
    )
    if s[0]:
        raise Error(String("server_stream with grpc-status 0 raised: ") + s[1])
    assert_equal(s[2], String("2 stream message(s)"))


def test_connect_unary_carries_no_grpc_status_and_succeeds() raises:
    """Connect unary states its outcome in the HTTP status and body, never in
    `grpc-status`. Catches the check applied to a protocol that has no such
    field."""
    var client = _h1_client(_http_200(String("application/proto"), _b(String("ok"))))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var req = _b(String("req"))
    var r = client.unary_call[RT, ProtocolConnectProto](
        String(_PATH), Span(req), CallOptions(), Int(0), reactor, token
    )
    assert_equal(_text(r.message_bytes), String("ok"))


# =============================================================================
# §5 — driver: every case runs, so one RED does not mask the next
# =============================================================================


def main() raises:
    var failures = List[String]()
    try:
        test_trailers_without_grpc_status_are_unknown()
        print("  PASS  trailers without grpc-status are UNKNOWN")
    except e:
        failures.append(String("trailers_without_grpc_status: ") + String(e))
    try:
        test_stream_ended_without_trailers_is_internal()
        print("  PASS  a stream ended without trailers is INTERNAL")
    except e:
        failures.append(String("ended_without_trailers: ") + String(e))
    try:
        test_http1_fallback_without_grpc_status_is_internal()
        print("  PASS  HTTP/1.1 fallback without grpc-status is INTERNAL")
    except e:
        failures.append(String("http1_fallback: ") + String(e))
    try:
        test_trailers_only_without_grpc_status_is_unknown()
        print("  PASS  trailers-only without grpc-status is UNKNOWN")
    except e:
        failures.append(String("trailers_only_without_status: ") + String(e))
    try:
        test_non_200_without_grpc_status_maps_through_the_http_table()
        print("  PASS  non-200 without grpc-status maps through the HTTP table")
    except e:
        failures.append(String("non_200_without_status: ") + String(e))
    try:
        test_a_stated_ok_status_still_succeeds()
        print("  PASS  a stated grpc-status 0 still succeeds")
    except e:
        failures.append(String("stated_ok_control: ") + String(e))
    try:
        test_connect_unary_carries_no_grpc_status_and_succeeds()
        print("  PASS  Connect unary is not subject to the check")
    except e:
        failures.append(String("connect_control: ") + String(e))
    if len(failures) > 0:
        var report = String("test_grpc_missing_status: ")
        report += String(len(failures)) + " case(s) FAILED\n"
        for i in range(len(failures)):
            report += String("\n---- ") + failures[i] + "\n"
        raise Error(report)
    print("test_grpc_missing_status: ALL PASS")
