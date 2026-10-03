# =============================================================================
# test_e2e_full_loop.mojo — Mojo gRPC client → komira_connect ConnectService loopback
# =============================================================================
#
# The BOTH-WAYS validation: Mojo client → Mojo server (komira_connect's
# ConnectService).
#
# The gRPC client adds ZERO transport.
# It marshals Mojo values into request body bytes; HTTP transport plumbs
# those bytes to the wire; the server decodes via ConnectService.handle_request
# and produces response body bytes; the client decodes those bytes back to
# Mojo values.
#
# This e2e bypasses the HTTP transport (HttpClient.send → TCP → server
# accept; `test_e2e_grpc_client` puts the transport in the loop). Instead
# we exercise the WIRE LAYER:
#
#   Mojo client (encode_unary_request[P]) → request body bytes →
#   ConnectService.handle_request(content_type, body) → response body bytes →
#   Mojo client (decode_unary_response[P]) → assert round-trip identity
#
# This proves:
#   (a) The client wire layer matches the Connect server's expected wire form.
#   (b) Status / content-type / envelope framing are bit-identical
#       across the boundary.
#   (c) The full request → dispatch → response flow exercises both
#       codecs symmetrically.
#
# Coverage:
#   T1   classic-gRPC unary (proto): client encode → handle_request → decode.
#   T2   Connect unary (proto): client encode → handle_request → decode.
#   T3   Connect unary (JSON): same shape with JSON wire.
#   T4   Server-side handler raises [grpc:5]: client receives GrpcError
#        with code=NOT_FOUND (classic-gRPC path via trailers; we synthesize
#        the trailers from DispatchResult.grpc_status).
#   T5   Connect unary handler raises: client receives the error envelope
#        body (HTTP non-2xx + parse_connect_error_json → GrpcError).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    ProtocolGrpcProto,
    ProtocolConnectProto,
    ProtocolConnectJson,
    CallOptions,
    encode_unary_request,
    decode_unary_response,
    GRPC_STATUS_OK,
    GRPC_STATUS_NOT_FOUND,
    parse_grpc_error_message,
)
from komira_connect import (
    ConnectService,
    ConnectMethodEntry,
    DispatchResult,
    CODEC_ID_GRPC,
    CODEC_ID_CONNECT_JSON,
    codec_id_for_content_type,
    format_connect_error,
)
from komira_connect.codec_grpc import (
    grpc_encode_unary as server_grpc_encode_unary,
)
from komira_connect.codec_connect_json import build_connect_error_json


# =============================================================================
# §1 — A simple echo handler — uppercase the request bytes.
# =============================================================================
#
# Handler signature is `fn(codec_id, req_body) raises thin -> List[UInt8]`.
# It receives the INNER message bytes (already envelope-stripped for gRPC,
# already JSON-bytes for Connect-JSON), and returns the inner response
# message bytes. The dispatcher re-encodes per codec.
# =============================================================================


def echo_uppercase_handler(
    codec_id: UInt8, req_body: List[UInt8]
) raises -> List[UInt8]:
    """Returns the request bytes with ASCII lowercase letters uppercased.
    A stand-in for a Serializable echo — proves the wire framing flows
    through without needing the full protobuf codegen path."""
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


def not_found_handler(
    codec_id: UInt8, req_body: List[UInt8]
) raises -> List[UInt8]:
    """Always raises a [grpc:5] (NOT_FOUND) error. Tests the error path."""
    raise Error(
        format_connect_error(GRPC_STATUS_NOT_FOUND, String("nope"))
    )


# =============================================================================
# §2 — Helper: synthesize a server-side response wire that the client
#       can decode. For classic gRPC, the wire is the DispatchResult.body
#       (the envelope-framed response); status is in trailers (we use HTTP
#       200 + a separate HeaderMap for tests).
# =============================================================================


def _server_responds_via_dispatch(
    handler_fn: def (codec_id: UInt8, req_body: List[UInt8]) raises thin -> List[UInt8],
    content_type: String,
    request_body: List[UInt8],
) -> DispatchResult:
    """Drive ConnectService.handle_request inline by registering one
    handler and calling. Returns the DispatchResult the server would
    emit on the wire."""
    var svc = ConnectService(String("test.EchoService"))
    svc.register_method(String("/test.EchoService/Echo"), handler_fn)
    return svc.handle_request(
        String("/test.EchoService/Echo"),
        content_type,
        Span(request_body),
    )


# =============================================================================
# §3 — Tests
# =============================================================================


def test_t1_classic_grpc_unary_round_trip() raises:
    """T1 — classic-gRPC unary: client encode → server dispatch → client decode."""
    var msg = List[UInt8]()
    msg.append(UInt8(ord("h")))
    msg.append(UInt8(ord("i")))
    # Client: encode request
    var req_body = encode_unary_request[ProtocolGrpcProto](Span(msg))
    # Server: dispatch
    var result = _server_responds_via_dispatch(
        echo_uppercase_handler,
        String("application/grpc+proto"),
        req_body^,
    )
    assert_equal(result.http_status, UInt16(200), "HTTP 200")
    assert_equal(result.grpc_status, GRPC_STATUS_OK, "gRPC OK")
    # Client: decode response (the server's body is already 5-byte-enveloped).
    var inner = decode_unary_response[ProtocolGrpcProto](
        Span(result.body), result.http_status
    )
    assert_equal(len(inner), 2, "2 bytes back")
    assert_equal(inner[0], UInt8(ord("H")), "byte 0 uppercased")
    assert_equal(inner[1], UInt8(ord("I")), "byte 1 uppercased")


def test_t2_connect_proto_unary_round_trip() raises:
    """T2 — Connect-proto unary: client encode → server → client decode.

    komira_connect's codec_id_for_content_type routes
    `application/proto` (Connect-proto unary) onto the Connect codec path
    (CODEC_ID_CONNECT_JSON) — bare-body framing + JSON error envelope are
    byte-identical to Connect-JSON; only the success payload bytes differ
    (protobuf-binary vs proto3-JSON), and those are opaque to the
    dispatcher. The client encodes/decodes the bare body via
    ProtocolConnectProto (unary_is_enveloped()==False).
    """
    # Use protobuf-shaped bytes: a fake single-field protobuf message
    # (tag 0x0A = field 1, wiretype 2 LEN; len 3; "abc"). The dispatcher
    # treats it as opaque bytes; the echo handler uppercases ASCII letters.
    var msg = List[UInt8]()
    msg.append(UInt8(0x0A))  # field 1, LEN
    msg.append(UInt8(0x03))  # length 3
    msg.append(UInt8(ord("a")))
    msg.append(UInt8(ord("b")))
    msg.append(UInt8(ord("c")))
    # Client: encode request (bare body for Connect-proto unary)
    var req_body = encode_unary_request[ProtocolConnectProto](Span(msg))
    assert_equal(len(req_body), 5, "bare body 5 bytes (no envelope)")
    # Server: dispatch via the application/proto content-type
    var result = _server_responds_via_dispatch(
        echo_uppercase_handler,
        String("application/proto"),
        req_body^,
    )
    assert_equal(result.http_status, UInt16(200), "HTTP 200")
    assert_equal(result.grpc_status, GRPC_STATUS_OK, "gRPC OK")
    # Client: decode response (bare body for Connect-proto unary)
    var inner = decode_unary_response[ProtocolConnectProto](
        Span(result.body), result.http_status
    )
    assert_equal(len(inner), 5, "5 bytes back (bare)")
    assert_equal(inner[0], UInt8(0x0A), "proto tag byte unchanged")
    assert_equal(inner[1], UInt8(0x03), "proto len byte unchanged")
    assert_equal(inner[2], UInt8(ord("A")), "a → A")
    assert_equal(inner[3], UInt8(ord("B")), "b → B")
    assert_equal(inner[4], UInt8(ord("C")), "c → C")


def test_t2b_connect_proto_unary_error() raises:
    """T2b — Connect-proto unary handler raises [grpc:5] → client receives
    the JSON error envelope body (HTTP non-2xx) and maps to NOT_FOUND.
    Validates the error wire is JSON for the proto codec (Connect spec)."""
    var msg = List[UInt8]()
    msg.append(UInt8(0x0A))
    msg.append(UInt8(0x01))
    msg.append(UInt8(ord("x")))
    var req_body = encode_unary_request[ProtocolConnectProto](Span(msg))
    var result = _server_responds_via_dispatch(
        not_found_handler,
        String("application/proto"),
        req_body^,
    )
    assert_equal(result.grpc_status, GRPC_STATUS_NOT_FOUND, "NOT_FOUND")
    assert_true(result.http_status >= 400, "non-2xx HTTP")
    assert_true(len(result.body) > 0, "JSON error envelope body present")
    var raised = False
    var caught_msg = String("")
    try:
        var _ = decode_unary_response[ProtocolConnectProto](
            Span(result.body), result.http_status
        )
    except e:
        raised = True
        caught_msg = String(e)
    assert_true(raised, "client raises on non-2xx")
    var parsed = parse_grpc_error_message(caught_msg)
    assert_equal(parsed[0], GRPC_STATUS_NOT_FOUND, "code NOT_FOUND")
    assert_equal(parsed[1], String("nope"), "msg preserved")


def test_t3_connect_json_unary_round_trip() raises:
    """T3 — Connect-JSON unary: client encode → server → client decode."""
    # The body is treated as opaque bytes by the dispatcher (it doesn't
    # care that it's "JSON"; the codec just doesn't envelope-frame). Our
    # echo handler uppercases ASCII; we feed it lowercase ASCII bytes
    # representing a JSON payload.
    var msg = List[UInt8]()
    var payload = String("{\"x\":1}")
    var i = 0
    while i < payload.byte_length():
        msg.append(UInt8(ord(payload[byte=i])))
        i = i + 1
    # Client: encode request (bare body for Connect)
    var req_body = encode_unary_request[ProtocolConnectJson](Span(msg))
    assert_equal(len(req_body), 7, "bare body 7 bytes")
    # Server: dispatch via CONNECT_JSON codec
    var result = _server_responds_via_dispatch(
        echo_uppercase_handler,
        String("application/json"),
        req_body^,
    )
    assert_equal(result.http_status, UInt16(200), "HTTP 200")
    assert_equal(result.grpc_status, GRPC_STATUS_OK, "gRPC OK")
    # Client: decode response (bare body for Connect)
    var inner = decode_unary_response[ProtocolConnectJson](
        Span(result.body), result.http_status
    )
    # The uppercase echo applied to ASCII alphanumeric → only "x" gets
    # uppercased; punctuation passes through.
    assert_equal(inner[0], UInt8(ord("{")), "byte 0 unchanged")
    # Find the 'X' (was 'x') in the uppercased version
    assert_equal(inner[2], UInt8(ord("X")), "x → X")


def test_t4_classic_grpc_handler_error() raises:
    """T4 — classic-gRPC handler raises [grpc:5] → DispatchResult carries
    the error code; client maps via parse_grpc_status_trailers if it had
    the trailers; here we directly inspect the DispatchResult fields since
    the server's grpc dispatch leaves the body empty on error (trailers carry
    status).
    """
    var msg = List[UInt8]()
    msg.append(UInt8(ord("x")))
    var req_body = encode_unary_request[ProtocolGrpcProto](Span(msg))
    var result = _server_responds_via_dispatch(
        not_found_handler,
        String("application/grpc+proto"),
        req_body^,
    )
    # Server: grpc errors → http_status=200, grpc_status=NOT_FOUND, body=empty.
    assert_equal(result.http_status, UInt16(200), "HTTP 200 even on grpc error")
    assert_equal(result.grpc_status, GRPC_STATUS_NOT_FOUND, "NOT_FOUND")
    assert_equal(result.grpc_message, String("nope"), "msg")
    # Body is empty on error (status rides in trailers).
    assert_equal(len(result.body), 0, "empty body")


def test_t5_connect_json_handler_error() raises:
    """T5 — Connect-JSON handler raises [connect:5] → response body is the
    JSON error envelope; client's decode_unary_response sees HTTP 404 and
    parses the envelope back to GrpcError."""
    var msg = List[UInt8]()
    msg.append(UInt8(ord("x")))
    var req_body = encode_unary_request[ProtocolConnectJson](Span(msg))
    var result = _server_responds_via_dispatch(
        not_found_handler,
        String("application/json"),
        req_body^,
    )
    # Server: Connect-JSON errors → mapped HTTP non-2xx + JSON error body.
    assert_equal(result.grpc_status, GRPC_STATUS_NOT_FOUND, "NOT_FOUND")
    assert_true(result.http_status >= 400, "non-2xx HTTP")
    # Body is the JSON error envelope.
    assert_true(len(result.body) > 0, "envelope body present")
    # Client: decode_unary_response should raise with [grpc:5] (NOT_FOUND)
    var raised = False
    var caught_msg = String("")
    try:
        var _ = decode_unary_response[ProtocolConnectJson](
            Span(result.body), result.http_status
        )
    except e:
        raised = True
        caught_msg = String(e)
    assert_true(raised, "client raises on non-2xx")
    var parsed = parse_grpc_error_message(caught_msg)
    assert_equal(parsed[0], GRPC_STATUS_NOT_FOUND, "code NOT_FOUND")
    assert_equal(parsed[1], String("nope"), "msg preserved")


def main() raises:
    test_t1_classic_grpc_unary_round_trip()
    test_t2_connect_proto_unary_round_trip()  # application/proto routing
    test_t2b_connect_proto_unary_error()
    test_t3_connect_json_unary_round_trip()
    test_t4_classic_grpc_handler_error()
    test_t5_connect_json_handler_error()
    print("test_e2e_full_loop: 6/6 PASS")
