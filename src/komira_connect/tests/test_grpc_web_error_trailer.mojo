# =============================================================================
# test_grpc_web_error_trailer.mojo: a failing gRPC-Web unary call carries
# its status in the trailer envelope
# =============================================================================
#
# gRPC-Web (grpc/grpc PROTOCOL-WEB.md) has no HTTP trailers: the status is
# the LAST length-prefixed frame of the body, flag byte 0x80, whose payload is
# an HTTP/1-style header block (lowercase names, CRLF-separated):
#   `grpc-status: N\r\ngrpc-message: <percent-encoded>\r\n`.
# Before the fix, every gRPC-Web error left the body EMPTY (the dispatcher
# said "let the caller compose" and no caller did). The response was HTTP 200
# with no frame at all, so the client saw no status and no message, and
# `grpc_web_decode_response` reported `saw_trailers = False`.
#
# The error body is the trailer frame alone (a trailers-only response): no
# data frame, so a client cannot mistake the error for an empty message.
#
# Coverage (real `ConnectService`, content-type `application/grpc-web+proto`):
#   T1  a handler raising `[connect:9] café ✓ 100%`: `dispatch_grpc` answers
#       200, gRPC-Web content-type, no h2 trailer, and a body that is EXACTLY
#       one 0x80 frame carrying `grpc-status: 9` and the percent-encoded
#       message; `grpc_web_decode_response` yields status 9, the UTF-8
#       message and no data message.
#   T2  the same answer through the h2 emitter the serve loop uses
#       (`emit_grpc_response`): the DATA bytes on the wire decode the same.
#   T3  an unregistered method: NOT_FOUND (5) with `method <path> not
#       registered` (the `_make_not_found_result` path).
#   T4  an empty request body (no data frame): UNKNOWN (2), `empty grpc-web
#       request` (the decode-error path).
#   T5  control: a successful call is still one data frame + `grpc-status: 0`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import FRAME_DATA, decode_frame
from komira_http_core.transport.grpc_emit import emit_grpc_response

from komira_connect import (
    ConnectService,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_OK,
    GRPC_STATUS_UNKNOWN,
    GRPC_WEB_CONTENT_TYPE_PROTO,
    format_connect_error,
    grpc_web_decode_response,
    grpc_web_encode_request,
)


comptime MSG = "café ✓ 100%"
comptime ENC = "caf%C3%A9 %E2%9C%93 100%25"
comptime FAIL_PATH = "/test.Svc/Fail"
comptime ECHO_PATH = "/test.Svc/Echo"


def _fail_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    raise Error(format_connect_error(GRPC_STATUS_FAILED_PRECONDITION, MSG))


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def _service() -> ConnectService:
    var svc = ConnectService(String("test.Svc"))
    svc.register_method(String(FAIL_PATH), _fail_handler)
    svc.register_method(String(ECHO_PATH), _echo_handler)
    return svc^


def _request() -> List[UInt8]:
    var msg: List[UInt8] = [UInt8(0xAA), UInt8(0xBB)]
    return grpc_web_encode_request(Span(msg))


def _trailer_frame(block: String) -> List[UInt8]:
    """The exact bytes of one gRPC-Web trailer frame around `block`."""
    var out = List[UInt8]()
    var n = block.byte_length()
    out.append(UInt8(0x80))
    out.append(UInt8((n >> 24) & 0xFF))
    out.append(UInt8((n >> 16) & 0xFF))
    out.append(UInt8((n >> 8) & 0xFF))
    out.append(UInt8(n & 0xFF))
    out.extend(block.as_bytes())
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want), "body length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], String("body byte ") + String(i))


def _assert_error_body(
    body: List[UInt8], status: UInt8, message: String, encoded: String
) raises:
    var block = (
        String("grpc-status: ") + String(Int(status)) + "\r\ngrpc-message: " + encoded + "\r\n"
    )
    _assert_bytes(body, _trailer_frame(block))
    var decoded = grpc_web_decode_response(Span(body))
    assert_true(decoded.saw_trailers, "the trailer frame is there")
    assert_equal(len(decoded.messages), 0, "trailers-only: no data frame")
    assert_equal(decoded.trailers.status_code, status)
    assert_equal(decoded.trailers.message, message)


def test_t1_handler_error() raises:
    print("  T1 handler error, dispatch_grpc...")
    var svc = _service()
    var resp = svc.dispatch_grpc(
        String(FAIL_PATH), String(GRPC_WEB_CONTENT_TYPE_PROTO), _request()
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(resp.grpc_status, GRPC_STATUS_FAILED_PRECONDITION)
    assert_equal(resp.content_type, String(GRPC_WEB_CONTENT_TYPE_PROTO))
    assert_false(resp.emit_trailer, "gRPC-Web: status is in the body")
    _assert_error_body(
        resp.body, GRPC_STATUS_FAILED_PRECONDITION, String(MSG), String(ENC)
    )
    print("    OK")


def test_t2_through_h2_emitter() raises:
    print("  T2 the same answer through emit_grpc_response...")
    var svc = _service()
    var resp = svc.dispatch_grpc(
        String(FAIL_PATH), String(GRPC_WEB_CONTENT_TYPE_PROTO), _request()
    )
    var h2 = H2ConnectionState()
    _ = h2.get_or_create_stream(UInt32(1))
    var idx = h2.find_stream_idx(UInt32(1))
    h2.streams[idx].state = UInt8(3)  # STREAM_STATE_OPEN
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(emit_grpc_response(h2, UInt32(1), resp^, reqs, sent))
    var raw = h2.take_out_bytes()
    var data = List[UInt8]()
    var cursor = 0
    while cursor < len(raw):
        var res = decode_frame(Span(raw)[cursor:], 16384)
        assert_equal(Int(res.status), 0)
        cursor += res.consumed
        if res.frame.header.kind == FRAME_DATA:
            for i in range(len(res.frame.payload)):
                data.append(res.frame.payload[i])
    _assert_error_body(
        data, GRPC_STATUS_FAILED_PRECONDITION, String(MSG), String(ENC)
    )
    print("    OK")


def test_t3_not_found() raises:
    print("  T3 unregistered method...")
    var svc = _service()
    var resp = svc.dispatch_grpc(
        String("/test.Svc/Nope"), String(GRPC_WEB_CONTENT_TYPE_PROTO), _request()
    )
    assert_equal(Int(resp.http_status), 200)
    var want = String("method /test.Svc/Nope not registered")
    _assert_error_body(resp.body, GRPC_STATUS_NOT_FOUND, want, want)
    print("    OK")


def test_t4_empty_request() raises:
    print("  T4 empty request body...")
    var svc = _service()
    var empty = List[UInt8]()
    var result = svc.handle_request(
        String(ECHO_PATH), String(GRPC_WEB_CONTENT_TYPE_PROTO), Span(empty)
    )
    assert_equal(Int(result.http_status), 200)
    var want = String("empty grpc-web request")
    _assert_error_body(result.body, GRPC_STATUS_UNKNOWN, want, want)
    print("    OK")


def test_t5_success_control() raises:
    print("  T5 success: data frame + grpc-status 0...")
    var svc = _service()
    var resp = svc.dispatch_grpc(
        String(ECHO_PATH), String(GRPC_WEB_CONTENT_TYPE_PROTO), _request()
    )
    var decoded = grpc_web_decode_response(Span(resp.body))
    assert_true(decoded.saw_trailers)
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK)
    assert_equal(len(decoded.messages), 1)
    assert_equal(len(decoded.messages[0]), 2)
    print("    OK")


def main() raises:
    print("== gRPC-Web error trailer ==")
    test_t1_handler_error()
    test_t2_through_h2_emitter()
    test_t3_not_found()
    test_t4_empty_request()
    test_t5_success_control()
    print("== PASSED (5 legs) ==")
