# =============================================================================
# test_e2e_server_streaming.mojo — Connect-RPC server-streaming e2e
# =============================================================================
#
# Server-streaming RPC.
#
# A server-streaming RPC: client sends one request message, server
# responds with N data messages followed by a closing trailer envelope
# (gRPC-Web / Connect-JSON) or closing HTTP/2 trailers (gRPC).
#
# The streaming primitives are direct calls on the wire-codec functions
# (grpc_append_message + grpc_web_append_message + grpc_web_append_trailers
# + connect_json_append_message + connect_json_append_end_stream) — the
# ConnectService.handle_request shape is unary-only; streaming handlers go
# through `dispatch_grpc_stream`. This test covers the framing.
#
# Coverage:
#   T1   gRPC server-streaming: N=3 messages + (HTTP/2 trailers
#        emitted out-of-band; for this test we just verify the body).
#   T2   gRPC-Web server-streaming: 3 data envelopes + 1 trailer envelope
#        in body — full round-trip.
#   T3   Connect-JSON server-streaming: 3 data envelopes + 1 END_STREAM
#        envelope with `{}` body — full round-trip.
#   T4   Error mid-stream: 2 data messages then an error trailer.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    grpc_append_message,
    grpc_decode_stream,
    grpc_make_ok_trailers,
    grpc_make_trailers,
    grpc_web_append_message,
    grpc_web_append_trailers,
    grpc_web_decode_response,
    connect_json_append_message,
    connect_json_append_end_stream,
    connect_json_decode_stream,
    build_connect_end_stream_json,
)


def _row(n: Int) -> List[UInt8]:
    """Helper — build a 3-byte 'row' payload."""
    var row = List[UInt8]()
    row.append(UInt8(n & 0xFF))
    row.append(UInt8((n + 1) & 0xFF))
    row.append(UInt8((n + 2) & 0xFF))
    return row^


def test_t1_grpc_server_streaming_body() raises:
    """T1 — gRPC server-streaming body: 3 envelope-framed messages."""
    var body = List[UInt8]()
    var r1 = _row(1)
    grpc_append_message(body, Span(r1))
    var r2 = _row(2)
    grpc_append_message(body, Span(r2))
    var r3 = _row(3)
    grpc_append_message(body, Span(r3))

    # Decode the stream and verify all 3 envelopes
    var envs = grpc_decode_stream(Span(body))
    assert_equal(len(envs), 3, "3 messages")
    assert_equal(envs[0].payload[0], UInt8(1), "row 1 first byte")
    assert_equal(envs[1].payload[0], UInt8(2), "row 2 first byte")
    assert_equal(envs[2].payload[0], UInt8(3), "row 3 first byte")
    # Note: for gRPC, the closing grpc-status: 0 trailer is sent in
    # the HTTP/2 TRAILERS frame, NOT in the body — out-of-band relative
    # to this body-bytes check.


def test_t2_grpc_web_server_streaming_round_trip() raises:
    """T2 — gRPC-Web server-streaming: 3 data envelopes + trailer envelope."""
    var body = List[UInt8]()
    var r1 = _row(10)
    grpc_web_append_message(body, Span(r1))
    var r2 = _row(20)
    grpc_web_append_message(body, Span(r2))
    var r3 = _row(30)
    grpc_web_append_message(body, Span(r3))
    grpc_web_append_trailers(body, grpc_make_ok_trailers())

    var decoded = grpc_web_decode_response(Span(body))
    assert_equal(len(decoded.messages), 3, "3 data envelopes")
    assert_equal(decoded.messages[0][0], UInt8(10), "msg 0 byte 0")
    assert_equal(decoded.messages[1][0], UInt8(20), "msg 1 byte 0")
    assert_equal(decoded.messages[2][0], UInt8(30), "msg 2 byte 0")
    assert_true(decoded.saw_trailers, "trailers seen")
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK, "OK")


def test_t3_connect_json_server_streaming_round_trip() raises:
    """T3 — Connect-JSON server-streaming: 3 envelope-framed JSON messages
    + 1 END_STREAM envelope with empty `{}` payload."""
    var body = List[UInt8]()
    var m1 = List[UInt8]()
    var m1s = String("{\"row\":1}")
    for i in range(m1s.byte_length()):
        m1.append(UInt8(ord(m1s[byte=i])))
    connect_json_append_message(body, Span(m1))

    var m2 = List[UInt8]()
    var m2s = String("{\"row\":2}")
    for i in range(m2s.byte_length()):
        m2.append(UInt8(ord(m2s[byte=i])))
    connect_json_append_message(body, Span(m2))

    var m3 = List[UInt8]()
    var m3s = String("{\"row\":3}")
    for i in range(m3s.byte_length()):
        m3.append(UInt8(ord(m3s[byte=i])))
    connect_json_append_message(body, Span(m3))

    var es = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    connect_json_append_end_stream(body, Span(es))

    var decoded = connect_json_decode_stream(Span(body))
    assert_equal(len(decoded.messages), 3, "3 data envelopes")
    assert_true(decoded.saw_end_stream, "end stream seen")
    # Reconstruct JSON string for first message
    var got1 = String("")
    for i in range(len(decoded.messages[0])):
        got1 += String(chr(Int(decoded.messages[0][i])))
    assert_equal(got1, String("{\"row\":1}"), "msg 0 content")


def test_t4_grpc_web_mid_stream_error() raises:
    """T4 — gRPC-Web: 2 data messages + error trailer (RESOURCE_EXHAUSTED)."""
    var body = List[UInt8]()
    var r1 = _row(100)
    grpc_web_append_message(body, Span(r1))
    var r2 = _row(101)
    grpc_web_append_message(body, Span(r2))
    var err_trailers = grpc_make_trailers(
        GRPC_STATUS_RESOURCE_EXHAUSTED, String("quota exceeded")
    )
    grpc_web_append_trailers(body, err_trailers)

    var decoded = grpc_web_decode_response(Span(body))
    assert_equal(len(decoded.messages), 2, "2 partial messages")
    assert_true(decoded.saw_trailers, "trailer seen")
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_RESOURCE_EXHAUSTED, "error status")
    assert_equal(decoded.trailers.message, String("quota exceeded"), "error message")


def main() raises:
    test_t1_grpc_server_streaming_body()
    test_t2_grpc_web_server_streaming_round_trip()
    test_t3_connect_json_server_streaming_round_trip()
    test_t4_grpc_web_mid_stream_error()
    print("test_e2e_server_streaming: 4/4 PASS")
