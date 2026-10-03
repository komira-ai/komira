# =============================================================================
# test_L5_dispatch.mojo — Connect-RPC dispatch + ConnectService
# =============================================================================
#
# Method dispatch + service builder.
#
# Coverage:
#   T1   codec_id_for_content_type — recognized + unrecognized types.
#   T2   ConnectService.register_method + lookup_handler.
#   T3   ConnectService.handle_request — gRPC unary echo round-trip.
#   T4   ConnectService.handle_request — gRPC-Web unary echo round-trip.
#   T5   ConnectService.handle_request — Connect-JSON unary echo round-trip.
#   T6   ConnectService.handle_request — NOT_FOUND for unregistered path.
#   T7   ConnectService.handle_request — handler raising error mapped to status.
#   T8   ConnectService.handle_request — unknown content-type → UNIMPLEMENTED.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_CONTENT_TYPE_PROTO,
    GRPC_WEB_CONTENT_TYPE_PROTO,
    CONNECT_JSON_CONTENT_TYPE_UNARY,
    CODEC_ID_UNKNOWN,
    CODEC_ID_GRPC,
    CODEC_ID_GRPC_WEB,
    CODEC_ID_CONNECT_JSON,
    ConnectHandlerFn,
    ConnectService,
    DispatchResult,
    codec_id_for_content_type,
    dispatch,
    format_connect_error,
    grpc_encode_unary,
    grpc_decode_unary,
    grpc_web_encode_request,
    grpc_web_decode_response,
    connect_json_encode_unary,
    connect_json_decode_unary,
)


# A simple echo handler — returns a copy of the request bytes. The
# handler-fn parameter `req_body` is `read`-binding by default; copying
# is the canonical way to materialize an owned List inside.
def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    return req_body.copy()


# A handler that always raises INVALID_ARGUMENT.
def _bad_request_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    raise Error(String(format_connect_error(GRPC_STATUS_INVALID_ARGUMENT, String("bad input"))))


def test_t1_codec_id_for_content_type() raises:
    """T1 — content-type → codec_id classifier."""
    assert_equal(codec_id_for_content_type(GRPC_CONTENT_TYPE_PROTO), CODEC_ID_GRPC, "grpc+proto")
    assert_equal(codec_id_for_content_type(String("application/grpc")), CODEC_ID_GRPC, "bare grpc")
    assert_equal(codec_id_for_content_type(GRPC_WEB_CONTENT_TYPE_PROTO), CODEC_ID_GRPC_WEB, "grpc-web+proto")
    assert_equal(codec_id_for_content_type(CONNECT_JSON_CONTENT_TYPE_UNARY), CODEC_ID_CONNECT_JSON, "json")
    assert_equal(codec_id_for_content_type(String("application/connect+json")), CODEC_ID_CONNECT_JSON, "connect+json stream")
    # Connect-proto unary + streaming route onto the
    # Connect codec path (bare-body framing + JSON error envelope are
    # byte-identical to Connect-JSON).
    assert_equal(codec_id_for_content_type(String("application/proto")), CODEC_ID_CONNECT_JSON, "connect proto unary")
    assert_equal(codec_id_for_content_type(String("application/connect+proto")), CODEC_ID_CONNECT_JSON, "connect+proto stream")
    assert_equal(codec_id_for_content_type(String("application/proto;charset=utf-8")), CODEC_ID_CONNECT_JSON, "connect proto with param")
    assert_equal(codec_id_for_content_type(String("text/plain")), CODEC_ID_UNKNOWN, "plain text")
    # With params stripped
    assert_equal(codec_id_for_content_type(String("application/grpc+proto;charset=utf-8")), CODEC_ID_GRPC, "with charset param")


def test_t2_service_register_lookup() raises:
    """T2 — register + lookup + has_method."""
    var svc = ConnectService(String("test.Service"))
    assert_equal(svc.method_count(), 0, "empty count")
    assert_false(svc.has_method(String("/test.Service/Echo")), "not registered")

    svc.register_method(String("/test.Service/Echo"), _echo_handler)
    assert_equal(svc.method_count(), 1, "1 method")
    assert_true(svc.has_method(String("/test.Service/Echo")), "registered")

    # Re-register overwrites
    svc.register_method(String("/test.Service/Echo"), _bad_request_handler)
    assert_equal(svc.method_count(), 1, "still 1 method (overwrite)")


def test_t3_grpc_unary_echo() raises:
    """T3 — gRPC unary round-trip through ConnectService."""
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Echo"), _echo_handler)

    # Build a gRPC request body: envelope-framed message
    var msg = List[UInt8]()
    msg.append(UInt8(0xAA))
    msg.append(UInt8(0xBB))
    var req_body = grpc_encode_unary(Span(msg))

    var result = svc.handle_request(
        String("/test.Service/Echo"),
        GRPC_CONTENT_TYPE_PROTO,
        Span(req_body),
    )

    assert_true(result.is_ok(), "OK status")
    assert_equal(result.grpc_status, GRPC_STATUS_OK, "code 0")
    assert_equal(result.codec_id, CODEC_ID_GRPC, "codec_id")
    # Decode the response body — should be same envelope-framed echo.
    var resp_msg = grpc_decode_unary(Span(result.body))
    assert_equal(len(resp_msg), 2, "echo len")
    assert_equal(resp_msg[0], UInt8(0xAA), "echo byte 0")
    assert_equal(resp_msg[1], UInt8(0xBB), "echo byte 1")


def test_t4_grpc_web_unary_echo() raises:
    """T4 — gRPC-Web unary round-trip."""
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Echo"), _echo_handler)

    var msg = List[UInt8]()
    msg.append(UInt8(0x11))
    msg.append(UInt8(0x22))
    msg.append(UInt8(0x33))
    var req_body = grpc_web_encode_request(Span(msg))

    var result = svc.handle_request(
        String("/test.Service/Echo"),
        GRPC_WEB_CONTENT_TYPE_PROTO,
        Span(req_body),
    )

    assert_true(result.is_ok(), "OK status")
    assert_equal(result.codec_id, CODEC_ID_GRPC_WEB, "codec_id")
    # Decode the response body (envelope-framed data + END_STREAM trailer)
    var decoded = grpc_web_decode_response(Span(result.body))
    assert_equal(len(decoded.messages), 1, "1 data envelope")
    assert_equal(decoded.messages[0][0], UInt8(0x11), "echo byte 0")
    assert_true(decoded.saw_trailers, "trailers present")
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK, "OK trailer")


def test_t5_connect_json_unary_echo() raises:
    """T5 — Connect-JSON unary round-trip (body IS the JSON message)."""
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Echo"), _echo_handler)

    var req_str = String("{\"name\":\"alice\"}")
    var req_body = List[UInt8]()
    for i in range(req_str.byte_length()):
        req_body.append(UInt8(ord(req_str[byte=i])))

    var result = svc.handle_request(
        String("/test.Service/Echo"),
        CONNECT_JSON_CONTENT_TYPE_UNARY,
        Span(req_body),
    )

    assert_true(result.is_ok(), "OK status")
    assert_equal(result.codec_id, CODEC_ID_CONNECT_JSON, "codec_id")
    # Connect-JSON body IS the JSON; no envelope
    var resp_str = String("")
    for i in range(len(result.body)):
        resp_str += String(chr(Int(result.body[i])))
    assert_equal(resp_str, req_str, "echo JSON")


def test_t6_not_found() raises:
    """T6 — unregistered path → NOT_FOUND."""
    var svc = ConnectService(String("test.Service"))

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    var req_body = grpc_encode_unary(Span(msg))

    var result = svc.handle_request(
        String("/test.Service/Missing"),
        GRPC_CONTENT_TYPE_PROTO,
        Span(req_body),
    )

    assert_equal(result.grpc_status, GRPC_STATUS_NOT_FOUND, "NOT_FOUND")
    assert_false(result.is_ok(), "not OK")


def test_t7_handler_error_mapped() raises:
    """T7 — handler raising format_connect_error → status mapped."""
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/BadRequest"), _bad_request_handler)

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    var req_body = grpc_encode_unary(Span(msg))

    var result = svc.handle_request(
        String("/test.Service/BadRequest"),
        GRPC_CONTENT_TYPE_PROTO,
        Span(req_body),
    )

    assert_equal(result.grpc_status, GRPC_STATUS_INVALID_ARGUMENT, "INVALID_ARGUMENT mapped")
    assert_equal(result.grpc_message, String("bad input"), "message preserved")


def test_t8_unknown_content_type() raises:
    """T8 — content-type that doesn't match any codec → UNIMPLEMENTED."""
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Echo"), _echo_handler)

    var msg = List[UInt8]()
    msg.append(UInt8(0))
    # not-grpc-not-connect content-type
    var req_body = msg.copy()

    var result = svc.handle_request(
        String("/test.Service/Echo"),
        String("text/plain"),
        Span(req_body),
    )

    # Unknown content-type results in UNIMPLEMENTED on dispatch.
    # But the path IS registered, so the codec check happens first;
    # NOT_FOUND check happens before dispatch in handle_request, so for
    # a registered path with bad content-type we expect UNIMPLEMENTED.
    assert_equal(result.grpc_status, GRPC_STATUS_UNIMPLEMENTED, "UNIMPLEMENTED")


def main() raises:
    test_t1_codec_id_for_content_type()
    test_t2_service_register_lookup()
    test_t3_grpc_unary_echo()
    test_t4_grpc_web_unary_echo()
    test_t5_connect_json_unary_echo()
    test_t6_not_found()
    test_t7_handler_error_mapped()
    test_t8_unknown_content_type()
    print("test_L5_dispatch: 8/8 PASS")
