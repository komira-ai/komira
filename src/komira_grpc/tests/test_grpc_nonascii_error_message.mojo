# =============================================================================
# test_grpc_nonascii_error_message.mojo: a non-ASCII error message, end to end
# =============================================================================
#
# A handler that raises an error whose message is not ASCII must produce a
# well-formed error on every codec, and the server must keep serving.
# Reading such a message with `s[byte=i]` asserts on the first UTF-8
# continuation byte ("does not lie on a codepoint boundary") and aborts the
# whole process, so before the fix every leg below except T0 killed the test
# binary (and, in production, the server) instead of answering.
#
# gRPC spec (PROTOCOL-HTTP2.md, "Responses"): `grpc-message` is the UTF-8
# message, percent-encoded: every byte outside 0x20..0x7E, and '%' itself,
# becomes `%XX` (uppercase hex). So MSG below must go on the wire as ENC.
#
# The server half is the real `ConnectService` dispatch and the real h2
# emitter (`emit_grpc_response` / `emit_grpc_stream_response`, the calls the
# h2 serve loop makes); the client half is the real decoders `GrpcClient`
# uses. No socket: the h2 bytes the emitter queued are decoded frame by frame
# with the HPACK decoder.
#
# Coverage:
#   T0  the encoders and parsers on MSG, one function at a time.
#   T1  classic gRPC unary: the trailing HEADERS carry `grpc-status: 9` and
#       exactly `grpc-message: ENC`; the client's trailer parser yields MSG.
#   T2  the same ConnectService then answers an echo with `grpc-status: 0`
#       on the same h2 connection (the server survived T1).
#   T3  server streaming: the close trailer carries exactly ENC.
#   T4  Connect-JSON unary: HTTP 400, body exactly
#       `{"code":"failed_precondition","message":"<MSG as raw UTF-8>"}`, and
#       the client's decode raises `[grpc:9] MSG`. Also the Connect streaming
#       end-of-stream envelope.
#   T5  gRPC-Web: the in-body trailer block the codec writes carries exactly
#       ENC and the client's decoder yields MSG. (Codec level: the unary
#       dispatcher does not compose a gRPC-Web error body today.)
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_client.header_map import HeaderMap
from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_HEADERS,
    decode_frame,
)
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackHeader
from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_SERVER_STREAM,
    emit_grpc_response,
    emit_grpc_stream_response,
)

from komira_connect import (
    ConnectService,
    GRPC_STATUS_FAILED_PRECONDITION,
    format_connect_error,
    grpc_percent_decode_message,
    grpc_percent_encode_message,
    grpc_web_append_trailers,
    grpc_web_decode_response,
    GrpcTrailers,
    parse_connect_error,
    parse_connect_error_json,
)
from komira_connect.codec_connect_json import build_connect_end_stream_json
from komira_connect.codec_grpc import grpc_encode_unary

from komira_grpc import (
    ProtocolConnectJson,
    ProtocolGrpcProto,
    decode_unary_response,
    encode_unary_request,
    parse_grpc_error_message,
    parse_grpc_status_trailers,
)


# The message: a 2-byte character, a 3-byte character and a '%'.
comptime MSG = "café ✓ 100%"
# Its UTF-8 bytes: c a f C3 A9 ' ' E2 9C 93 ' ' 1 0 0 %.
comptime MSG_UTF8_LEN = 14
comptime ENC = "caf%C3%A9 %E2%9C%93 100%25"

comptime FAIL_PATH = "/test.Svc/Fail"
comptime ECHO_PATH = "/test.Svc/Echo"
comptime STREAM_PATH = "/test.Svc/FailStream"


def _fail_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    raise Error(format_connect_error(GRPC_STATUS_FAILED_PRECONDITION, MSG))


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def _fail_stream_handler(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    raise Error(format_connect_error(GRPC_STATUS_FAILED_PRECONDITION, MSG))


def _service() -> ConnectService:
    var svc = ConnectService(String("test.Svc"))
    svc.register_method(String(FAIL_PATH), _fail_handler)
    svc.register_method(String(ECHO_PATH), _echo_handler)
    svc.register_server_stream(String(STREAM_PATH), _fail_stream_handler)
    return svc^


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _str(b: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _open_stream(mut h2: H2ConnectionState, stream_id: UInt32):
    _ = h2.get_or_create_stream(stream_id)
    var idx = h2.find_stream_idx(stream_id)
    # STREAM_STATE_OPEN == 3, so sending END_STREAM moves the state on.
    h2.streams[idx].state = UInt8(3)


def _frames(raw: List[UInt8]) raises -> List[List[UInt8]]:
    """Split `raw` into frames; each entry is [kind, flags, payload...]."""
    var out = List[List[UInt8]]()
    var cursor = 0
    while cursor < len(raw):
        var res = decode_frame(Span(raw)[cursor:], 16384)
        if res.status != UInt8(0):
            raise Error("decode_frame failed at " + String(cursor))
        var f = List[UInt8]()
        f.append(res.frame.header.kind)
        f.append(res.frame.header.flags)
        for i in range(len(res.frame.payload)):
            f.append(res.frame.payload[i])
        out.append(f^)
        cursor += res.consumed
    return out^


def _payload(f: List[UInt8]) -> List[UInt8]:
    var p = List[UInt8]()
    for i in range(2, len(f)):
        p.append(f[i])
    return p^


def _value(headers: List[HpackHeader], name: String) -> String:
    for i in range(len(headers)):
        if String(headers[i].name) == name:
            return String(headers[i].value)
    return String("<absent>")


def _trailer_of(frames: List[List[UInt8]], mut dec: HpackDecoder) raises -> List[HpackHeader]:
    """Decode every HEADERS block in order (HPACK state is shared) and return
    the last one, which must be the END_STREAM trailer."""
    var last = List[HpackHeader]()
    var last_flags = UInt8(0)
    for i in range(len(frames)):
        if frames[i][0] == FRAME_HEADERS:
            var p = _payload(frames[i])
            last = dec.decode_block(Span(p))
            last_flags = frames[i][1]
    assert_true((last_flags & FLAG_END_STREAM) != UInt8(0), "trailer ends the stream")
    return last^


# -----------------------------------------------------------------------------


def test_t0_codec_functions() raises:
    print("  T0 encoders and parsers...")
    assert_equal(String(MSG).byte_length(), MSG_UTF8_LEN)
    assert_equal(grpc_percent_encode_message(String(MSG)), String(ENC))
    assert_equal(grpc_percent_decode_message(String(ENC)), String(MSG))
    # A non-conforming peer may send raw UTF-8; decoding passes it through.
    assert_equal(grpc_percent_decode_message(String("café ✓%21")), String("café ✓!"))
    var pc = parse_connect_error(format_connect_error(GRPC_STATUS_FAILED_PRECONDITION, MSG))
    assert_equal(pc[0], GRPC_STATUS_FAILED_PRECONDITION)
    assert_equal(pc[1], String(MSG))
    var pg = parse_grpc_error_message(String("[grpc:9] ") + MSG)
    assert_equal(pg[0], GRPC_STATUS_FAILED_PRECONDITION)
    assert_equal(pg[1], String(MSG))
    print("    OK")


def test_t1_t2_grpc_unary_trailer_then_survives() raises:
    print("  T1 gRPC unary trailer, T2 the server answers again...")
    var svc = _service()
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var reqs = Int64(0)
    var sent = Int64(0)

    # T1: the failing call.
    _open_stream(h2, UInt32(1))
    var x = _b("x")
    var resp = svc.dispatch_grpc(
        String(FAIL_PATH),
        String("application/grpc+proto"),
        encode_unary_request[ProtocolGrpcProto](Span(x)),
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(resp.grpc_status, GRPC_STATUS_FAILED_PRECONDITION)
    assert_true(emit_grpc_response(h2, UInt32(1), resp^, reqs, sent))
    var raw1 = h2.take_out_bytes()
    var f1 = _frames(raw1)
    assert_equal(len(f1), 2, "HEADERS + trailing HEADERS, no DATA on error")
    var tr = _trailer_of(f1, dec)
    assert_equal(_value(tr, String("grpc-status")), String("9"))
    assert_equal(_value(tr, String("grpc-message")), String(ENC))

    # The client side: the trailer block as GrpcClient sees it.
    var hm = HeaderMap()
    for i in range(len(tr)):
        hm.append(String(tr[i].name), String(tr[i].value))
    var err = parse_grpc_status_trailers(hm)
    assert_equal(err.code, GRPC_STATUS_FAILED_PRECONDITION)
    assert_equal(err.message, String(MSG))

    # T2: same service, same connection, next stream: an ordinary echo.
    _open_stream(h2, UInt32(3))
    var ping = _b("ping")
    var ok = svc.dispatch_grpc(
        String(ECHO_PATH),
        String("application/grpc+proto"),
        encode_unary_request[ProtocolGrpcProto](Span(ping)),
    )
    assert_equal(Int(ok.grpc_status), 0)
    assert_true(emit_grpc_response(h2, UInt32(3), ok^, reqs, sent))
    var raw2 = h2.take_out_bytes()
    var f2 = _frames(raw2)
    assert_equal(len(f2), 3, "HEADERS + DATA + trailing HEADERS")
    var tr2 = _trailer_of(f2, dec)
    assert_equal(_value(tr2, String("grpc-status")), String("0"))
    assert_equal(_value(tr2, String("grpc-message")), String("<absent>"))
    print("    OK")


def test_t3_server_stream_trailer() raises:
    print("  T3 server-stream close trailer...")
    var svc = _service()
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var reqs = Int64(0)
    var sent = Int64(0)
    _open_stream(h2, UInt32(1))
    var x = _b("x")
    var sresp = svc.dispatch_grpc_stream(
        String(STREAM_PATH),
        String("application/grpc+proto"),
        GRPC_KIND_SERVER_STREAM,
        grpc_encode_unary(Span(x)),
    )
    assert_equal(sresp.grpc_status, GRPC_STATUS_FAILED_PRECONDITION)
    assert_true(emit_grpc_stream_response(h2, UInt32(1), sresp^, reqs, sent))
    var raw = h2.take_out_bytes()
    var frames = _frames(raw)
    var tr = _trailer_of(frames, dec)
    assert_equal(_value(tr, String("grpc-status")), String("9"))
    assert_equal(_value(tr, String("grpc-message")), String(ENC))
    print("    OK")


def test_t4_connect_json() raises:
    print("  T4 Connect-JSON error body...")
    var svc = _service()
    var braces = _b("{}")
    var req = encode_unary_request[ProtocolConnectJson](Span(braces))
    var result = svc.handle_request(
        String(FAIL_PATH), String("application/json"), Span(req)
    )
    assert_equal(Int(result.http_status), 400)
    # JSON carries UTF-8 as is; only '"', '\' and controls are escaped.
    var want = String('{"code":"failed_precondition","message":"') + MSG + '"}'
    assert_equal(_str(result.body), want)
    var env = parse_connect_error_json(Span(result.body))
    assert_equal(env.message, String(MSG))

    var raised = String("")
    try:
        _ = decode_unary_response[ProtocolConnectJson](
            Span(result.body), result.http_status
        )
    except e:
        raised = String(e)
    var parsed = parse_grpc_error_message(raised)
    assert_equal(parsed[0], GRPC_STATUS_FAILED_PRECONDITION)
    assert_equal(parsed[1], String(MSG))

    # The Connect streaming end-of-stream envelope uses the same escaper.
    var end = build_connect_end_stream_json(GRPC_STATUS_FAILED_PRECONDITION, String(MSG))
    assert_equal(
        _str(end),
        String('{"error":{"code":"failed_precondition","message":"') + MSG + '"}}',
    )
    print("    OK")


def test_t5_grpc_web() raises:
    print("  T5 gRPC-Web in-body trailer...")
    var body = List[UInt8]()
    grpc_web_append_trailers(
        body, GrpcTrailers(GRPC_STATUS_FAILED_PRECONDITION, String(MSG))
    )
    # One END_STREAM envelope (5-byte header) around the trailer block.
    var block = List[UInt8]()
    for i in range(5, len(body)):
        block.append(body[i])
    assert_equal(
        _str(block),
        String("grpc-status: 9\r\ngrpc-message: ") + ENC + "\r\n",
    )
    var decoded = grpc_web_decode_response(Span(body))
    assert_true(decoded.saw_trailers)
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_FAILED_PRECONDITION)
    assert_equal(decoded.trailers.message, String(MSG))
    print("    OK")


def main() raises:
    print("== non-ASCII error message, end to end ==")
    test_t0_codec_functions()
    test_t1_t2_grpc_unary_trailer_then_survives()
    test_t3_server_stream_trailer()
    test_t4_connect_json()
    test_t5_grpc_web()
    print("== PASSED (6 legs) ==")
