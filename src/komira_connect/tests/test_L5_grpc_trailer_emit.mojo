# =============================================================================
# test_L5_grpc_trailer_emit.mojo
# =============================================================================
#
# Locks the gRPC server-tier pieces:
#   1. emit_grpc_response — HEADERS(:status 200, content-type grpc) -> DATA
#      -> trailing HEADERS(grpc-status, END_STREAM). Without the trailer a
#      gRPC client cannot read the call's status.
#   2. ConnectService.dispatch_grpc — GrpcDispatch conformance: a registered
#      unary echo handler round-trips through dispatch_grpc -> GrpcResponse,
#      and an erroring handler yields http :status 200 + a NON-ZERO grpc-status
#      trailer (never an h2 error).
#
# These exercise the emit + dispatch surfaces directly (no socket, no real
# gRPC client).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.codec.h2.connection_state import H2ConnectionState
from komira_http.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_HEADERS,
    decode_frame,
)
from komira_http.codec.h2.hpack import HpackDecoder, HpackHeader
from komira_http.transport.grpc_emit import (
    GrpcResponse,
    emit_grpc_response,
    is_grpc_content_type,
)

from komira_connect.codec_grpc import (
    GRPC_CONTENT_TYPE_PROTO,
    grpc_decode_unary,
    grpc_encode_unary,
)
from komira_connect.service import ConnectService


# -----------------------------------------------------------------------------
# Frame-walk helpers — decode the bytes emit_grpc_response queued on the wire.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _DecodedFrame(Movable, Deinitable):
    """One decoded frame (Movable-only — owns a List[UInt8] payload, so it is
    NOT stored in a `List[_DecodedFrame]`; the test pulls frames one at a time
    by index via `_nth_frame`)."""

    var kind: UInt8
    var flags: UInt8
    var stream_id: UInt32
    var payload: List[UInt8]


def _count_frames(raw: List[UInt8]) raises -> Int:
    """Count the frames in `raw`."""
    var n = 0
    var cursor = 0
    while cursor < len(raw):
        var view = Span(raw)[cursor:]
        var res = decode_frame(view, 16384)
        if res.status != UInt8(0):
            raise Error("decode_frame failed at cursor " + String(cursor))
        cursor = cursor + res.consumed
        n = n + 1
    return n


def _nth_frame(raw: List[UInt8], target: Int) raises -> _DecodedFrame:
    """Decode the `target`-th frame (0-indexed) out of `raw`."""
    var cursor = 0
    var idx = 0
    while cursor < len(raw):
        var view = Span(raw)[cursor:]
        var res = decode_frame(view, 16384)
        if res.status != UInt8(0):
            raise Error("decode_frame failed at cursor " + String(cursor))
        if idx == target:
            var pcopy = List[UInt8]()
            for i in range(len(res.frame.payload)):
                pcopy.append(res.frame.payload[i])
            return _DecodedFrame(
                res.frame.header.kind,
                res.frame.header.flags,
                res.frame.header.stream_id,
                pcopy^,
            )
        cursor = cursor + res.consumed
        idx = idx + 1
    raise Error("frame index " + String(target) + " out of range")


def _header_value(
    headers: List[HpackHeader], name: String,
) -> String:
    """Return the value of `name` in a decoded header list, or empty."""
    for i in range(len(headers)):
        if String(headers[i].name) == name:
            return String(headers[i].value)
    return String("")


def _open_conn_with_stream(stream_id: UInt32) -> H2ConnectionState:
    var h2 = H2ConnectionState()
    _ = h2.get_or_create_stream(stream_id)
    # Drive to OPEN so advance_on_send_end_stream transitions correctly.
    var idx = h2.find_stream_idx(stream_id)
    if idx >= 0:
        # STREAM_STATE_OPEN == 3
        h2.streams[idx].state = UInt8(3)
    return h2^


# -----------------------------------------------------------------------------
# T1 — is_grpc_content_type detector.
# -----------------------------------------------------------------------------


def test_is_grpc_content_type() raises:
    print("  test_is_grpc_content_type...")
    assert_true(is_grpc_content_type(String("application/grpc")))
    assert_true(is_grpc_content_type(String("application/grpc+proto")))
    assert_true(
        is_grpc_content_type(String("application/grpc+proto; charset=utf-8"))
    )
    assert_true(is_grpc_content_type(String("application/grpc-web+proto")))
    assert_true(is_grpc_content_type(String("application/json")))
    assert_false(is_grpc_content_type(String("text/plain")))
    assert_false(is_grpc_content_type(String("text/html")))
    print("    OK")


# -----------------------------------------------------------------------------
# T2 — emit_grpc_response OK: HEADERS + DATA + trailing HEADERS(grpc-status:0).
# -----------------------------------------------------------------------------


def test_emit_grpc_ok_trailer() raises:
    print("  test_emit_grpc_ok_trailer...")
    var h2 = _open_conn_with_stream(UInt32(1))

    # Build a framed echo body (one envelope around "pong").
    var msg = List[UInt8]()
    for c in String("pong").as_bytes():
        msg.append(c)
    var framed = grpc_encode_unary(Span(msg))
    var framed_len = len(framed)

    var resp = GrpcResponse(
        framed^,
        UInt16(200),
        UInt8(0),  # GRPC_STATUS_OK
        String(""),
        String(GRPC_CONTENT_TYPE_PROTO),
        True,  # emit_trailer
    )
    var reqs = Int64(0)
    var bytes = Int64(0)
    var ok = emit_grpc_response(h2, UInt32(1), resp^, reqs, bytes)
    assert_true(ok)

    var raw = h2.take_out_bytes()
    # Expect exactly 3 frames: HEADERS, DATA, HEADERS(trailer).
    assert_equal(_count_frames(raw), 3)
    var dec = HpackDecoder()

    # Frame 0 — response HEADERS, NOT END_STREAM.
    var f0 = _nth_frame(raw, 0)
    assert_equal(Int(f0.kind), Int(FRAME_HEADERS))
    assert_false((f0.flags & FLAG_END_STREAM) != UInt8(0))
    var h0 = dec.decode_block(Span(f0.payload))
    assert_equal(_header_value(h0, String(":status")), String("200"))
    assert_equal(
        _header_value(h0, String("content-type")),
        String(GRPC_CONTENT_TYPE_PROTO),
    )

    # Frame 1 — DATA, the framed body, NOT END_STREAM.
    var f1 = _nth_frame(raw, 1)
    assert_equal(Int(f1.kind), Int(FRAME_DATA))
    assert_false((f1.flags & FLAG_END_STREAM) != UInt8(0))
    assert_equal(len(f1.payload), framed_len)
    # The DATA payload is the framed envelope; decode it back to "pong".
    var inner = grpc_decode_unary(Span(f1.payload))
    var inner_s = String()
    for i in range(len(inner)):
        inner_s += chr(Int(inner[i]))
    assert_equal(inner_s, String("pong"))

    # Frame 2 — trailing HEADERS, grpc-status: 0, END_STREAM.
    var f2 = _nth_frame(raw, 2)
    assert_equal(Int(f2.kind), Int(FRAME_HEADERS))
    assert_true((f2.flags & FLAG_END_STREAM) != UInt8(0))
    var h2t = dec.decode_block(Span(f2.payload))
    assert_equal(_header_value(h2t, String("grpc-status")), String("0"))
    print("    OK — HEADERS + DATA + grpc-status:0 trailer")


# -----------------------------------------------------------------------------
# T3 — emit_grpc_response ERROR: 200 + NO DATA + trailing grpc-status:<nonzero>.
# -----------------------------------------------------------------------------


def test_emit_grpc_error_trailer() raises:
    print("  test_emit_grpc_error_trailer...")
    var h2 = _open_conn_with_stream(UInt32(3))

    var resp = GrpcResponse(
        List[UInt8](),  # empty body on error
        UInt16(200),  # gRPC always 200 at HTTP layer
        UInt8(5),  # GRPC_STATUS_NOT_FOUND
        String("method%20missing"),  # already percent-encoded
        String(GRPC_CONTENT_TYPE_PROTO),
        True,
    )
    var reqs = Int64(0)
    var bytes = Int64(0)
    _ = emit_grpc_response(h2, UInt32(3), resp^, reqs, bytes)

    var raw = h2.take_out_bytes()
    # Expect exactly 2 frames: HEADERS, HEADERS(trailer) — NO DATA on error.
    assert_equal(_count_frames(raw), 2)

    var dec = HpackDecoder()
    var f0 = _nth_frame(raw, 0)
    var h0 = dec.decode_block(Span(f0.payload))
    # http :status is STILL 200 even on a gRPC error.
    assert_equal(_header_value(h0, String(":status")), String("200"))
    assert_equal(Int(f0.kind), Int(FRAME_HEADERS))
    assert_false((f0.flags & FLAG_END_STREAM) != UInt8(0))

    var f1 = _nth_frame(raw, 1)
    assert_equal(Int(f1.kind), Int(FRAME_HEADERS))
    assert_true((f1.flags & FLAG_END_STREAM) != UInt8(0))
    var h1 = dec.decode_block(Span(f1.payload))
    assert_equal(_header_value(h1, String("grpc-status")), String("5"))
    assert_equal(
        _header_value(h1, String("grpc-message")), String("method%20missing")
    )
    print("    OK — 200 + no DATA + grpc-status:5 + grpc-message trailer")


# -----------------------------------------------------------------------------
# Echo handler for the dispatch_grpc translation test.
# -----------------------------------------------------------------------------


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def _err_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    # Raise a Connect-style error: [connect:5] not found.
    raise Error("[connect:5] resource not found")


# -----------------------------------------------------------------------------
# T4 — ConnectService.dispatch_grpc OK round-trip (GrpcResponse translation).
# -----------------------------------------------------------------------------


def test_dispatch_grpc_ok() raises:
    print("  test_dispatch_grpc_ok...")
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Echo"), _echo_handler)

    var msg = List[UInt8]()
    for c in String("hello").as_bytes():
        msg.append(c)
    var req_body = grpc_encode_unary(Span(msg))

    var resp = svc.dispatch_grpc(
        String("/test.Service/Echo"),
        String("application/grpc+proto"),
        req_body^,
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 0)
    assert_true(resp.emit_trailer)
    assert_equal(resp.content_type, String(GRPC_CONTENT_TYPE_PROTO))
    # The body is the framed echo; decode it back.
    var inner = grpc_decode_unary(Span(resp.body))
    var s = String()
    for i in range(len(inner)):
        s += chr(Int(inner[i]))
    assert_equal(s, String("hello"))
    print("    OK — echo round-trip, grpc_status 0, emit_trailer True")


# -----------------------------------------------------------------------------
# T5 — ConnectService.dispatch_grpc ERROR: 200 + nonzero grpc_status.
# -----------------------------------------------------------------------------


def test_dispatch_grpc_error() raises:
    print("  test_dispatch_grpc_error...")
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Fail"), _err_handler)

    var msg = List[UInt8]()
    msg.append(UInt8(1))
    var req_body = grpc_encode_unary(Span(msg))

    var resp = svc.dispatch_grpc(
        String("/test.Service/Fail"),
        String("application/grpc+proto"),
        req_body^,
    )
    # Erroring handler -> HTTP 200 + non-zero grpc-status (never an h2 error).
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 5)  # NOT_FOUND from [connect:5]
    assert_true(resp.emit_trailer)
    assert_true(len(resp.grpc_message.as_bytes()) > 0)
    print("    OK — error handler -> 200 + grpc-status:5 trailer")


# -----------------------------------------------------------------------------
# T6 — dispatch_grpc NOT_FOUND for an unregistered method path.
# -----------------------------------------------------------------------------


def test_dispatch_grpc_unregistered() raises:
    print("  test_dispatch_grpc_unregistered...")
    var svc = ConnectService(String("test.Service"))
    svc.register_method(String("/test.Service/Echo"), _echo_handler)

    var msg = List[UInt8]()
    msg.append(UInt8(7))
    var req_body = grpc_encode_unary(Span(msg))

    var resp = svc.dispatch_grpc(
        String("/test.Service/DoesNotExist"),
        String("application/grpc+proto"),
        req_body^,
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 5)  # NOT_FOUND
    assert_true(resp.emit_trailer)
    print("    OK — unregistered path -> grpc-status:5")


def main() raises:
    print("== gRPC trailer-emit + dispatch_grpc ==")
    test_is_grpc_content_type()
    test_emit_grpc_ok_trailer()
    test_emit_grpc_error_trailer()
    test_dispatch_grpc_ok()
    test_dispatch_grpc_error()
    test_dispatch_grpc_unregistered()
    print("== gRPC trailer-emit unit PASSED (6 tests) ==")
