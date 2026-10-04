# =============================================================================
# test_e2e_grpc_client.mojo — GrpcClient API → HTTP loopback → Connect server wire
# =============================================================================
#
# Unlike `test_e2e_full_loop.mojo` (which exercises only the transport-free
# WIRE layer directly), this test drives the production `GrpcClient[C]` API
# end-to-end THROUGH the HTTP transport via the `ScriptedConnector`
# substitution — the same loopback harness komira_http's own client tests
# use. The flow at the GrpcClient API level:
#
#   GrpcClient.unary_call[RT, P](path, req_bytes, opts, now_us, reactor, token)
#     -> encode_unary_request[P]  (5-byte envelope for gRPC / bare for Connect)
#     -> HttpClient.send over ScriptedConnector
#     -> ScriptedStream replays the canned HTTP/1.1 200 response whose BODY is
#        komira_connect's ConnectService DispatchResult.body (server-produced wire)
#     -> RecvRingBody.poll_frame drains the body (cancellation-aware)
#     -> decode_unary_response[P] -> inner message bytes
#   assert round-trip identity at the GrpcClient API surface.
#
# The "server" half is the real `ConnectService.handle_request` — the
# SAME dispatch the server runs — so the response body bytes the client
# decodes are bit-identical to what a live server would emit. This is the
# BOTH-WAYS validation (Mojo client API -> HTTP -> Mojo server -> HTTP ->
# Mojo client API), with the HTTP transport in the loop (which
# test_e2e_full_loop.mojo does not have).
#
# Coverage:
#   T1   unary gRPC-proto round-trip via GrpcClient.unary_call.
#   T2   unary Connect-JSON round-trip via GrpcClient.unary_call.
#   T3   server-streaming round-trip via GrpcClient.server_stream — N messages
#        pulled back through ServerStreamDecoder.try_next_message.
#   T4   cancellation: a pre-cancelled token makes RecvRingBody.poll_frame's
#        token.is_cancelled() fire -> the in-flight read aborts -> unary_call
#        raises [grpc:4] (DEADLINE_EXCEEDED).
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_grpc import (
    GrpcClient,
    UnaryResult,
    ProtocolGrpcProto,
    ProtocolConnectJson,
    CallOptions,
    ServerStreamDecoder,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_END_ERROR,
    encode_stream_message,
    GRPC_STATUS_OK,
    GRPC_STATUS_DEADLINE_EXCEEDED,
    parse_grpc_error_message,
)
from komira_connect import (
    ConnectService,
    DispatchResult,
)


# The runtime the whole client path monomorphizes over.
comptime RT = PerCoreAsyncRuntime[NoopSink]


# =============================================================================
# §1 — helpers
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def echo_uppercase_handler(
    codec_id: UInt8, req_body: List[UInt8]
) raises -> List[UInt8]:
    """Stand-in server handler: uppercase ASCII lowercase. Mirrors the
    handler in test_e2e_full_loop.mojo so the two tests share semantics."""
    var out = List[UInt8]()
    var i = 0
    while i < len(req_body):
        var b = Int(req_body[i])
        if b >= ord("a") and b <= ord("z"):
            out.append(UInt8(b - 32))
        else:
            out.append(req_body[i])
        i = i + 1
    return out^


def _server_dispatch(
    content_type: String, request_body: List[UInt8]
) -> DispatchResult:
    """Drive the real ConnectService over one echo method. Returns the
    DispatchResult the server would put on the wire."""
    var svc = ConnectService(String("test.EchoService"))
    svc.register_method(
        String("/test.EchoService/Echo"), echo_uppercase_handler
    )
    return svc.handle_request(
        String("/test.EchoService/Echo"), content_type, Span(request_body)
    )


def _http_200_with_body(body: List[UInt8]) -> List[UInt8]:
    """Wrap a server-produced response BODY into a canned HTTP/1.1 200
    response the ScriptedStream replays. The Content-Length is exact so the
    RecvRingBody drains a single Data frame + End."""
    var head = _b(
        String("HTTP/1.1 200 OK\r\nContent-Length: ")
        + String(len(body))
        + "\r\n\r\n"
    )
    var out = List[UInt8]()
    for i in range(len(head)):
        out.append(head[i])
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _make_grpc_client(
    var response_wire: List[UInt8],
) raises -> GrpcClient[ScriptedConnector]:
    """Build a GrpcClient whose transport is a ScriptedConnector armed with
    the given full HTTP response wire bytes."""
    var stream = ScriptedStream.from_read_script(response_wire^)
    var connector = ScriptedConnector.with_stream(stream^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("http://127.0.0.1:8080/"))
    return GrpcClient[ScriptedConnector](http^, base^)


# =============================================================================
# §2 — T1: unary gRPC-proto round-trip via GrpcClient.unary_call
# =============================================================================


def test_t1_unary_grpc_proto_round_trip() raises:
    # Request message bytes (the generated stub's Req.encode output stand-in).
    var msg = _b(String("hi"))
    # Server: run the request through the real Connect dispatch to get the
    # response BODY (the gRPC-enveloped echo). We feed the dispatch the
    # client's encoded request body so the server sees exactly what the
    # client would send.
    from komira_grpc import encode_unary_request

    var req_wire = encode_unary_request[ProtocolGrpcProto](Span(msg))
    var disp = _server_dispatch(String("application/grpc+proto"), req_wire^)
    assert_equal(disp.http_status, UInt16(200), "server HTTP 200")
    assert_equal(disp.grpc_status, GRPC_STATUS_OK, "server gRPC OK")
    # Wrap the server body into a full HTTP response the ScriptedStream serves.
    var http_resp = _http_200_with_body(disp.body)

    # Client: drive the production GrpcClient API.
    var client = _make_grpc_client(http_resp^)
    var reactor = _make_reactor()
    var token = CancellationToken.new()
    var opts = CallOptions()
    var result = client.unary_call[RT, ProtocolGrpcProto](
        String("/test.EchoService/Echo"),
        Span(msg),
        opts,
        Int(0),
        reactor,
        token,
    )
    assert_equal(result.http_status, UInt16(200), "client sees HTTP 200")
    assert_equal(len(result.message_bytes), 2, "2 bytes back")
    assert_equal(result.message_bytes[0], UInt8(ord("H")), "byte0 H")
    assert_equal(result.message_bytes[1], UInt8(ord("I")), "byte1 I")


# =============================================================================
# §3 — T2: unary Connect-JSON round-trip via GrpcClient.unary_call
# =============================================================================


def test_t2_unary_connect_json_round_trip() raises:
    from komira_grpc import encode_unary_request

    var msg = _b(String("{\"x\":1}"))
    var req_wire = encode_unary_request[ProtocolConnectJson](Span(msg))
    var disp = _server_dispatch(String("application/json"), req_wire^)
    assert_equal(disp.http_status, UInt16(200), "server HTTP 200")
    assert_equal(disp.grpc_status, GRPC_STATUS_OK, "server gRPC OK")
    var http_resp = _http_200_with_body(disp.body)

    var client = _make_grpc_client(http_resp^)
    var reactor = _make_reactor()
    var token = CancellationToken.new()
    var opts = CallOptions()
    var result = client.unary_call[RT, ProtocolConnectJson](
        String("/test.EchoService/Echo"),
        Span(msg),
        opts,
        Int(0),
        reactor,
        token,
    )
    assert_equal(result.http_status, UInt16(200), "client sees HTTP 200")
    # The echo uppercases ASCII letters; "{" / digits / quotes pass through,
    # "x" -> "X".
    assert_equal(result.message_bytes[0], UInt8(ord("{")), "byte0 unchanged")
    assert_equal(result.message_bytes[2], UInt8(ord("X")), "x -> X")


# =============================================================================
# §4 — T3: server-streaming round-trip via GrpcClient.server_stream
# =============================================================================


def test_t3_server_stream_round_trip() raises:
    from komira_grpc import encode_unary_request

    # Build a 3-message streaming response body (envelope-framed, the wire
    # form a server-streaming handler emits). We synthesize it via
    # encode_stream_message (same envelope the server uses).
    var body = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("ALPHA"))))
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("BETA"))))
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("GAMMA"))))
    var http_resp = _http_200_with_body(body)

    var client = _make_grpc_client(http_resp^)
    var reactor = _make_reactor()
    var token = CancellationToken.new()
    var opts = CallOptions()
    var req = _b(String("watch"))
    var decoder = client.server_stream[RT, ProtocolGrpcProto](
        String("/test.EchoService/Watch"),
        Span(req),
        opts,
        Int(0),
        reactor,
        token,
    )

    # Drive the decoder to pull every response message.
    var got = List[String]()
    var iters = 0
    while iters < 100:
        iters = iters + 1
        var outcome = decoder.try_next_message()
        if outcome.kind == STREAM_OUTCOME_MESSAGE:
            var s = String()
            for i in range(len(outcome.message_bytes)):
                s = s + chr(Int(outcome.message_bytes[i]))
            got.append(s^)
        elif outcome.kind == STREAM_OUTCOME_PENDING:
            # All bytes already fed (buffered shape) — PENDING means done
            # pulling messages from the buffered body.
            break
        elif outcome.kind == STREAM_OUTCOME_END_OK:
            break
        else:
            raise Error("T3: unexpected stream error outcome")

    assert_equal(len(got), 3, "3 streamed messages")
    assert_equal(got[0], String("ALPHA"), "msg0")
    assert_equal(got[1], String("BETA"), "msg1")
    assert_equal(got[2], String("GAMMA"), "msg2")


# =============================================================================
# §5 — T4: cancellation aborts the in-flight read
# =============================================================================


def test_t4_cancellation_aborts_in_flight_read() raises:
    """A pre-cancelled token makes RecvRingBody.poll_frame return the
    CANCELLED error frame on its first wire-read; _drain_response_body maps
    that to [grpc:4] (DEADLINE_EXCEEDED). This proves the deadline-tripped
    cancellation_token.cancel() aborts the in-flight body read."""
    from komira_grpc import encode_unary_request

    var msg = _b(String("hi"))
    var req_wire = encode_unary_request[ProtocolGrpcProto](Span(msg))
    var disp = _server_dispatch(String("application/grpc+proto"), req_wire^)
    var http_resp = _http_200_with_body(disp.body)

    var client = _make_grpc_client(http_resp^)
    var reactor = _make_reactor()
    var token = CancellationToken.new()
    # Trip the deadline BEFORE the call drains the body. RecvRingBody's
    # poll_frame checks token.is_cancelled() at the top of every wire-read.
    token.cancel(String("deadline exceeded"))
    assert_true(token.is_cancelled(), "token cancelled pre-call")

    var opts = CallOptions()
    var raised = False
    var caught = String("")
    try:
        var _r = client.unary_call[RT, ProtocolGrpcProto](
            String("/test.EchoService/Echo"),
            Span(msg),
            opts,
            Int(0),
            reactor,
            token,
        )
    except e:
        raised = True
        caught = String(e)
    assert_true(raised, "unary_call raises on cancellation")
    # The drain maps CANCELLED -> [grpc:4] DEADLINE_EXCEEDED.
    var parsed = parse_grpc_error_message(caught)
    assert_equal(
        parsed[0], GRPC_STATUS_DEADLINE_EXCEEDED, "code DEADLINE_EXCEEDED"
    )


def main() raises:
    test_t1_unary_grpc_proto_round_trip()
    test_t2_unary_connect_json_round_trip()
    test_t3_server_stream_round_trip()
    test_t4_cancellation_aborts_in_flight_read()
    print("test_e2e_grpc_client: 4/4 PASS")
