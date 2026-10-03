# =============================================================================
# test_L5_grpc_stream_emit.mojo
# =============================================================================
#
# Locks the gRPC STREAMING server-tier pieces:
#   1. emit_grpc_stream_response — HEADERS(:status 200, content-type grpc) ->
#      N DATA frames (one per response message, each a valid 5-byte-framed gRPC
#      envelope) -> trailing HEADERS(grpc-status, END_STREAM). The per-message
#      DATA framing + the trailer-after-DATA close are what is pinned.
#   2. ConnectService.dispatch_grpc_stream — GrpcStreamDispatch conformance:
#      * server-streaming: 1 request msg -> N response msgs.
#      * client-streaming: N request msgs -> 1 response msg (fold).
#      * error mid-stream: handler raise -> non-zero grpc-status close trailer,
#        HTTP still 200.
#   3. grpc_stream_kind routing: a registered server/client stream method
#      reports its kind; an unregistered path reports UNARY.
#
# These exercise the emit + dispatch surfaces directly (no socket, no real
# gRPC client).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_HEADERS,
    decode_frame,
)
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackHeader
from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcStreamResponse,
    emit_grpc_stream_response,
)

from komira_connect.codec_grpc import (
    GRPC_CONTENT_TYPE_PROTO,
    grpc_append_message,
    grpc_decode_unary,
    grpc_encode_unary,
)
from komira_connect.service import ConnectService


# -----------------------------------------------------------------------------
# Frame-walk helpers (same shape as test_L5_grpc_trailer_emit.mojo).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _DecodedFrame(Movable, Deinitable):
    var kind: UInt8
    var flags: UInt8
    var stream_id: UInt32
    var payload: List[UInt8]


def _count_frames(raw: List[UInt8]) raises -> Int:
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


def _header_value(headers: List[HpackHeader], name: String) -> String:
    for i in range(len(headers)):
        if String(headers[i].name) == name:
            return String(headers[i].value)
    return String("")


def _open_conn_with_stream(stream_id: UInt32) -> H2ConnectionState:
    var h2 = H2ConnectionState()
    _ = h2.get_or_create_stream(stream_id)
    var idx = h2.find_stream_idx(stream_id)
    if idx >= 0:
        # STREAM_STATE_OPEN == 3
        h2.streams[idx].state = UInt8(3)
    return h2^


def _msg(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


# -----------------------------------------------------------------------------
# T1 — emit_grpc_stream_response OK: HEADERS + 3 DATA + grpc-status:0 trailer.
# -----------------------------------------------------------------------------


def test_emit_stream_ok_three_messages() raises:
    print("  test_emit_stream_ok_three_messages...")
    var h2 = _open_conn_with_stream(UInt32(1))

    # Three response messages, each already gRPC-envelope framed.
    var messages = List[List[UInt8]]()
    var m0 = _msg("alpha")
    messages.append(grpc_encode_unary(Span(m0)))
    var m1 = _msg("beta")
    messages.append(grpc_encode_unary(Span(m1)))
    var m2 = _msg("gamma")
    messages.append(grpc_encode_unary(Span(m2)))

    var resp = GrpcStreamResponse(
        messages^,
        UInt16(200),
        UInt8(0),  # OK
        String(""),
        String(GRPC_CONTENT_TYPE_PROTO),
    )
    var reqs = Int64(0)
    var bytes = Int64(0)
    var ok = emit_grpc_stream_response(h2, UInt32(1), resp^, reqs, bytes)
    assert_true(ok)

    var raw = h2.take_out_bytes()
    # HEADERS + 3 DATA + trailing HEADERS = 5 frames.
    assert_equal(_count_frames(raw), 5)
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

    # Frames 1..3 — one DATA frame per message, NONE carries END_STREAM. Each
    # DATA payload is a valid gRPC envelope decoding back to the message text.
    var expect = List[String]()
    expect.append(String("alpha"))
    expect.append(String("beta"))
    expect.append(String("gamma"))
    for k in range(3):
        var fd = _nth_frame(raw, 1 + k)
        assert_equal(Int(fd.kind), Int(FRAME_DATA))
        assert_false((fd.flags & FLAG_END_STREAM) != UInt8(0))
        var inner = grpc_decode_unary(Span(fd.payload))
        var s = String()
        for i in range(len(inner)):
            s += chr(Int(inner[i]))
        assert_equal(s, expect[k])

    # Frame 4 — trailing HEADERS, grpc-status:0, END_STREAM.
    var f4 = _nth_frame(raw, 4)
    assert_equal(Int(f4.kind), Int(FRAME_HEADERS))
    assert_true((f4.flags & FLAG_END_STREAM) != UInt8(0))
    var ht = dec.decode_block(Span(f4.payload))
    assert_equal(_header_value(ht, String("grpc-status")), String("0"))
    print("    OK — HEADERS + 3 DATA + grpc-status:0 trailer")


# -----------------------------------------------------------------------------
# T2 — emit_grpc_stream_response zero messages: HEADERS + trailer (no DATA).
# -----------------------------------------------------------------------------


def test_emit_stream_zero_messages() raises:
    print("  test_emit_stream_zero_messages...")
    var h2 = _open_conn_with_stream(UInt32(1))
    var resp = GrpcStreamResponse(
        List[List[UInt8]](),
        UInt16(200),
        UInt8(0),
        String(""),
        String(GRPC_CONTENT_TYPE_PROTO),
    )
    var reqs = Int64(0)
    var bytes = Int64(0)
    _ = emit_grpc_stream_response(h2, UInt32(1), resp^, reqs, bytes)
    var raw = h2.take_out_bytes()
    # Just HEADERS + trailing HEADERS — an empty server-stream still closes
    # with a valid grpc-status trailer.
    assert_equal(_count_frames(raw), 2)
    var dec = HpackDecoder()
    var f1 = _nth_frame(raw, 1)
    assert_equal(Int(f1.kind), Int(FRAME_HEADERS))
    assert_true((f1.flags & FLAG_END_STREAM) != UInt8(0))
    var ht = dec.decode_block(Span(f1.payload))
    assert_equal(_header_value(ht, String("grpc-status")), String("0"))
    print("    OK — empty stream -> HEADERS + grpc-status:0 trailer (no DATA)")


# -----------------------------------------------------------------------------
# T3 — emit_grpc_stream_response error: non-zero grpc-status trailer, HTTP 200.
# -----------------------------------------------------------------------------


def test_emit_stream_error_trailer() raises:
    print("  test_emit_stream_error_trailer...")
    var h2 = _open_conn_with_stream(UInt32(1))
    # One partial message then an error close.
    var messages = List[List[UInt8]]()
    var m0 = _msg("partial")
    messages.append(grpc_encode_unary(Span(m0)))
    var resp = GrpcStreamResponse(
        messages^,
        UInt16(200),
        UInt8(8),  # RESOURCE_EXHAUSTED
        String("quota%20exceeded"),
        String(GRPC_CONTENT_TYPE_PROTO),
    )
    var reqs = Int64(0)
    var bytes = Int64(0)
    _ = emit_grpc_stream_response(h2, UInt32(1), resp^, reqs, bytes)
    var raw = h2.take_out_bytes()
    # HEADERS + 1 DATA + trailing HEADERS.
    assert_equal(_count_frames(raw), 3)
    var dec = HpackDecoder()
    var f0 = _nth_frame(raw, 0)
    var h0 = dec.decode_block(Span(f0.payload))
    # HTTP :status STILL 200 even on a streaming error.
    assert_equal(_header_value(h0, String(":status")), String("200"))
    var f2 = _nth_frame(raw, 2)
    assert_equal(Int(f2.kind), Int(FRAME_HEADERS))
    assert_true((f2.flags & FLAG_END_STREAM) != UInt8(0))
    var ht = dec.decode_block(Span(f2.payload))
    assert_equal(_header_value(ht, String("grpc-status")), String("8"))
    assert_equal(
        _header_value(ht, String("grpc-message")), String("quota%20exceeded")
    )
    print("    OK — 200 + DATA + grpc-status:8 + grpc-message trailer")


# -----------------------------------------------------------------------------
# Streaming handlers for the dispatch_grpc_stream tests.
# -----------------------------------------------------------------------------


def _server_stream_echo3(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    # Server-streaming: 1 request -> 3 responses (the request bytes + index).
    var out = List[List[UInt8]]()
    if len(req_messages) != 1:
        raise Error("[connect:3] server-stream expects exactly 1 request")
    for k in range(3):
        var m = List[UInt8]()
        for i in range(len(req_messages[0])):
            m.append(req_messages[0][i])
        m.append(UInt8(ord("0") + k))
        out.append(m^)
    return out^


def _client_stream_sum(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    # Client-streaming: N requests -> 1 response = sum of the first byte of each.
    var total = 0
    for r in range(len(req_messages)):
        if len(req_messages[r]) > 0:
            total = total + Int(req_messages[r][0])
    var resp = List[UInt8]()
    resp.append(UInt8(total & 0xFF))
    var out = List[List[UInt8]]()
    out.append(resp^)
    return out^


def _stream_err(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    raise Error("[connect:8] quota exceeded mid-stream")


# -----------------------------------------------------------------------------
# T4 — grpc_stream_kind routing.
# -----------------------------------------------------------------------------


def test_grpc_stream_kind() raises:
    print("  test_grpc_stream_kind...")
    var svc = ConnectService(String("flight.v1.FlightService"))
    svc.register_server_stream(
        String("/flight.v1.FlightService/DoGet"), _server_stream_echo3
    )
    svc.register_client_stream(
        String("/flight.v1.FlightService/DoPut"), _client_stream_sum
    )
    assert_equal(
        Int(svc.grpc_stream_kind(String("/flight.v1.FlightService/DoGet"))),
        Int(GRPC_KIND_SERVER_STREAM),
    )
    assert_equal(
        Int(svc.grpc_stream_kind(String("/flight.v1.FlightService/DoPut"))),
        Int(GRPC_KIND_CLIENT_STREAM),
    )
    # Unregistered path -> UNARY (serve loop takes the unary fast path).
    assert_equal(
        Int(svc.grpc_stream_kind(String("/flight.v1.FlightService/Nope"))),
        Int(GRPC_KIND_UNARY),
    )
    print("    OK — server/client/unary kind routing")


# -----------------------------------------------------------------------------
# T5 — dispatch_grpc_stream SERVER-streaming: 1 request -> 3 responses.
# -----------------------------------------------------------------------------


def test_dispatch_server_stream() raises:
    print("  test_dispatch_server_stream...")
    var svc = ConnectService(String("flight.v1.FlightService"))
    svc.register_server_stream(
        String("/flight.v1.FlightService/DoGet"), _server_stream_echo3
    )

    # Request body = one envelope around "x".
    var m = _msg("x")
    var req_body = grpc_encode_unary(Span(m))

    var resp = svc.dispatch_grpc_stream(
        String("/flight.v1.FlightService/DoGet"),
        String("application/grpc+proto"),
        GRPC_KIND_SERVER_STREAM,
        req_body^,
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 0)
    assert_equal(len(resp.messages), 3)
    # Each response message is a framed envelope of "x" + index digit.
    for k in range(3):
        var inner = grpc_decode_unary(Span(resp.messages[k]))
        var s = String()
        for i in range(len(inner)):
            s += chr(Int(inner[i]))
        assert_equal(s, String("x") + chr(ord("0") + k))
    print("    OK — server-stream 1 req -> 3 framed responses, grpc-status:0")


# -----------------------------------------------------------------------------
# T6 — dispatch_grpc_stream CLIENT-streaming: N requests -> 1 response (fold).
# -----------------------------------------------------------------------------


def test_dispatch_client_stream() raises:
    print("  test_dispatch_client_stream...")
    var svc = ConnectService(String("flight.v1.FlightService"))
    svc.register_client_stream(
        String("/flight.v1.FlightService/DoPut"), _client_stream_sum
    )

    # Request body = THREE envelopes, first bytes 10, 20, 12 -> sum 42.
    var body = List[UInt8]()
    var a = List[UInt8]()
    a.append(UInt8(10))
    grpc_append_message(body, Span(a))
    var b = List[UInt8]()
    b.append(UInt8(20))
    grpc_append_message(body, Span(b))
    var c = List[UInt8]()
    c.append(UInt8(12))
    grpc_append_message(body, Span(c))

    var resp = svc.dispatch_grpc_stream(
        String("/flight.v1.FlightService/DoPut"),
        String("application/grpc+proto"),
        GRPC_KIND_CLIENT_STREAM,
        body^,
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 0)
    assert_equal(len(resp.messages), 1)
    var inner = grpc_decode_unary(Span(resp.messages[0]))
    assert_equal(len(inner), 1)
    assert_equal(Int(inner[0]), 42)
    print("    OK — client-stream 3 reqs -> 1 fold response (sum=42)")


# -----------------------------------------------------------------------------
# T7 — dispatch_grpc_stream error: handler raise -> non-zero grpc-status, 200.
# -----------------------------------------------------------------------------


def test_dispatch_stream_error() raises:
    print("  test_dispatch_stream_error...")
    var svc = ConnectService(String("flight.v1.FlightService"))
    svc.register_server_stream(
        String("/flight.v1.FlightService/DoGet"), _stream_err
    )
    var m = _msg("x")
    var req_body = grpc_encode_unary(Span(m))
    var resp = svc.dispatch_grpc_stream(
        String("/flight.v1.FlightService/DoGet"),
        String("application/grpc+proto"),
        GRPC_KIND_SERVER_STREAM,
        req_body^,
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 8)  # RESOURCE_EXHAUSTED from [connect:8]
    assert_equal(len(resp.messages), 0)
    assert_true(len(resp.grpc_message.as_bytes()) > 0)
    print("    OK — handler raise -> 200 + grpc-status:8, no messages")


# -----------------------------------------------------------------------------
# T8 — dispatch_grpc_stream unregistered path -> NOT_FOUND close trailer.
# -----------------------------------------------------------------------------


def test_dispatch_stream_unregistered() raises:
    print("  test_dispatch_stream_unregistered...")
    var svc = ConnectService(String("flight.v1.FlightService"))
    var m = _msg("x")
    var req_body = grpc_encode_unary(Span(m))
    var resp = svc.dispatch_grpc_stream(
        String("/flight.v1.FlightService/Missing"),
        String("application/grpc+proto"),
        GRPC_KIND_SERVER_STREAM,
        req_body^,
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 5)  # NOT_FOUND
    assert_equal(len(resp.messages), 0)
    print("    OK — unregistered stream path -> grpc-status:5")


def main() raises:
    print("== gRPC streaming emit + dispatch_grpc_stream ==")
    test_emit_stream_ok_three_messages()
    test_emit_stream_zero_messages()
    test_emit_stream_error_trailer()
    test_grpc_stream_kind()
    test_dispatch_server_stream()
    test_dispatch_client_stream()
    test_dispatch_stream_error()
    test_dispatch_stream_unregistered()
    print("== gRPC streaming emit unit PASSED (8 tests) ==")
