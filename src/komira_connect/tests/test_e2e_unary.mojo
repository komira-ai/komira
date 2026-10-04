# =============================================================================
# test_e2e_unary.mojo — Connect-RPC unary RPC end-to-end through HttpRequest
# =============================================================================
#
# Unary RPC through the full HTTP request/response surface.
#
# This test simulates the L4 routing layer's pre-dispatch state: an
# HttpRequest is hand-built (method=POST, path=/svc/Method, body=encoded
# message, content-type=<one of 3 codecs>); we then drive
# ConnectService.handle_request and assert that:
#   (a) the response body bytes match what a Connect client would decode;
#   (b) http_status / grpc_status / grpc_message reflect the right outcome;
#   (c) all 3 codecs work through the same ConnectService instance.
#
# This shows "one runtime, three wire formats": the same `ConnectService`
# instance handles `application/grpc+proto` AND `application/grpc-web+proto`
# AND `application/json` requests.
#
# Coverage:
#   T1   gRPC unary RPC through HttpRequest+ConnectService.
#   T2   gRPC-Web unary RPC through HttpRequest+ConnectService.
#   T3   Connect-JSON unary RPC through HttpRequest+ConnectService.
#   T4   Same handler echoes for all 3 wire formats — one handler, three
#        wires.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_CONTENT_TYPE_PROTO,
    GRPC_WEB_CONTENT_TYPE_PROTO,
    CONNECT_JSON_CONTENT_TYPE_UNARY,
    CODEC_ID_GRPC,
    CODEC_ID_GRPC_WEB,
    CODEC_ID_CONNECT_JSON,
    ConnectService,
    grpc_encode_unary,
    grpc_decode_unary,
    grpc_web_encode_request,
    grpc_web_decode_response,
    connect_json_encode_unary,
)


# An echo handler that returns the request bytes back verbatim. The same
# handler works across all 3 wire formats because the dispatcher decodes
# the wire envelope before invoking the handler, and re-encodes after.
def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    return req_body.copy()


# A handler that returns a prefixed version of the request bytes. Used to
# verify that the handler sees the INNER message bytes (not the envelope-
# wrapped form) and that the dispatcher re-wraps for the response.
def _prefix_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0xFE))
    out.append(UInt8(0xED))
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def test_t1_grpc_unary_e2e() raises:
    """T1 — gRPC unary RPC end-to-end through HttpRequest+ConnectService."""
    var svc = ConnectService(String("test.Echo"))
    svc.register_method(String("/test.Echo/Echo"), _echo_handler)

    # Build the request body (what an HTTP/2 client would send)
    var msg = List[UInt8]()
    msg.append(UInt8(0x10))
    msg.append(UInt8(0x20))
    msg.append(UInt8(0x30))
    var request_body = grpc_encode_unary(Span(msg))

    # Drive through ConnectService — this is what the HttpServer's L4
    # router would do after path-matching.
    var result = svc.handle_request(
        String("/test.Echo/Echo"),
        GRPC_CONTENT_TYPE_PROTO,
        Span(request_body),
    )

    assert_true(result.is_ok(), "OK")
    assert_equal(result.http_status, UInt16(200), "HTTP 200 (gRPC always 200)")
    assert_equal(result.grpc_status, GRPC_STATUS_OK, "grpc-status: 0")
    assert_equal(result.codec_id, CODEC_ID_GRPC, "codec_id")

    # Verify response body: envelope-framed message that round-trips
    # to the same bytes a Connect client would decode.
    var resp_msg = grpc_decode_unary(Span(result.body))
    assert_equal(len(resp_msg), 3, "3-byte echo")
    assert_equal(resp_msg[0], UInt8(0x10), "byte 0")
    assert_equal(resp_msg[1], UInt8(0x20), "byte 1")
    assert_equal(resp_msg[2], UInt8(0x30), "byte 2")


def test_t2_grpc_web_unary_e2e() raises:
    """T2 — gRPC-Web unary RPC end-to-end."""
    var svc = ConnectService(String("test.Echo"))
    svc.register_method(String("/test.Echo/Echo"), _echo_handler)

    var msg = List[UInt8]()
    msg.append(UInt8(0xCA))
    msg.append(UInt8(0xFE))
    var request_body = grpc_web_encode_request(Span(msg))

    var result = svc.handle_request(
        String("/test.Echo/Echo"),
        GRPC_WEB_CONTENT_TYPE_PROTO,
        Span(request_body),
    )

    assert_true(result.is_ok(), "OK")
    assert_equal(result.http_status, UInt16(200), "HTTP 200")
    assert_equal(result.codec_id, CODEC_ID_GRPC_WEB, "codec_id")

    # Response body: data envelope + END_STREAM trailer envelope
    var decoded = grpc_web_decode_response(Span(result.body))
    assert_equal(len(decoded.messages), 1, "1 data envelope")
    assert_equal(len(decoded.messages[0]), 2, "echo size")
    assert_equal(decoded.messages[0][0], UInt8(0xCA), "byte 0")
    assert_equal(decoded.messages[0][1], UInt8(0xFE), "byte 1")
    assert_true(decoded.saw_trailers, "saw trailers")
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK, "OK trailer")


def test_t3_connect_json_unary_e2e() raises:
    """T3 — Connect-JSON unary RPC end-to-end."""
    var svc = ConnectService(String("test.Echo"))
    svc.register_method(String("/test.Echo/Echo"), _echo_handler)

    # Build the JSON request body (what a browser fetch / curl would send)
    var json_str = String("{\"name\":\"alice\",\"age\":30}")
    var request_body = List[UInt8]()
    for i in range(json_str.byte_length()):
        request_body.append(UInt8(ord(json_str[byte=i])))

    var result = svc.handle_request(
        String("/test.Echo/Echo"),
        CONNECT_JSON_CONTENT_TYPE_UNARY,
        Span(request_body),
    )

    assert_true(result.is_ok(), "OK")
    assert_equal(result.http_status, UInt16(200), "HTTP 200")
    assert_equal(result.codec_id, CODEC_ID_CONNECT_JSON, "codec_id")

    # Response body IS the JSON message (no envelope)
    var resp_str = String("")
    for i in range(len(result.body)):
        resp_str += String(chr(Int(result.body[i])))
    assert_equal(resp_str, json_str, "echo JSON byte-identical")


def test_t4_one_handler_three_wires() raises:
    """T4 — same handler echoes the right shape for all 3 wires.

    This proves 'one handler, three wires'
    — the same ConnectService instance routes gRPC, gRPC-Web, and
    Connect-JSON requests to the SAME registered handler, and each wire
    gets the correctly-shaped response.
    """
    var svc = ConnectService(String("test.Prefix"))
    svc.register_method(String("/test.Prefix/Run"), _prefix_handler)

    # Same inner payload (3 bytes) sent over 3 wires.
    var inner = List[UInt8]()
    inner.append(UInt8(0x01))
    inner.append(UInt8(0x02))
    inner.append(UInt8(0x03))

    # --- gRPC ---
    var grpc_req = grpc_encode_unary(Span(inner))
    var grpc_res = svc.handle_request(
        String("/test.Prefix/Run"), GRPC_CONTENT_TYPE_PROTO, Span(grpc_req)
    )
    assert_true(grpc_res.is_ok(), "gRPC ok")
    var grpc_resp_msg = grpc_decode_unary(Span(grpc_res.body))
    assert_equal(len(grpc_resp_msg), 5, "prefix + 3 = 5 bytes")
    assert_equal(grpc_resp_msg[0], UInt8(0xFE), "prefix byte 0")
    assert_equal(grpc_resp_msg[1], UInt8(0xED), "prefix byte 1")
    assert_equal(grpc_resp_msg[2], UInt8(0x01), "echo byte 0")

    # --- gRPC-Web ---
    var web_req = grpc_web_encode_request(Span(inner))
    var web_res = svc.handle_request(
        String("/test.Prefix/Run"), GRPC_WEB_CONTENT_TYPE_PROTO, Span(web_req)
    )
    assert_true(web_res.is_ok(), "gRPC-Web ok")
    var web_decoded = grpc_web_decode_response(Span(web_res.body))
    assert_equal(len(web_decoded.messages), 1, "1 data envelope")
    assert_equal(len(web_decoded.messages[0]), 5, "prefix + 3 = 5 bytes")
    assert_equal(web_decoded.messages[0][0], UInt8(0xFE), "prefix byte 0")
    assert_equal(web_decoded.messages[0][2], UInt8(0x01), "echo byte 0")

    # --- Connect-JSON ---
    var json_req = List[UInt8]()
    json_req.append(UInt8(0x01))
    json_req.append(UInt8(0x02))
    json_req.append(UInt8(0x03))
    var json_res = svc.handle_request(
        String("/test.Prefix/Run"),
        CONNECT_JSON_CONTENT_TYPE_UNARY,
        Span(json_req),
    )
    assert_true(json_res.is_ok(), "JSON ok")
    assert_equal(len(json_res.body), 5, "prefix + 3 = 5 bytes")
    assert_equal(json_res.body[0], UInt8(0xFE), "prefix byte 0")
    assert_equal(json_res.body[2], UInt8(0x01), "echo byte 0")


def main() raises:
    test_t1_grpc_unary_e2e()
    test_t2_grpc_web_unary_e2e()
    test_t3_connect_json_unary_e2e()
    test_t4_one_handler_three_wires()
    print("test_e2e_unary: 4/4 PASS")
