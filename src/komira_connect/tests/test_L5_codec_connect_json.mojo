# =============================================================================
# test_L5_codec_connect_json.mojo — Connect-JSON `application/json` codec
# =============================================================================
#
# Connect-JSON codec (HTTP/1.1 + HTTP/2).
#
# Coverage:
#   T1   connect_json_encode_unary + connect_json_decode_unary — pass-through.
#   T2   build_connect_error_json — OK code yields {}; non-OK yields
#        {"code":"name","message":"text"}.
#   T3   build_connect_error_json — JSON-escapes \\ and " in message.
#   T4   parse_connect_error_json — round-trip for non-OK envelope.
#   T5   build_connect_end_stream_json — OK yields {}; non-OK wraps in
#        {"error":{...}}.
#   T6   Streaming round-trip: append messages + end-stream envelope;
#        decode_stream returns messages + end_stream_payload.
#   T7   Decode rejects compressed envelope in stream.
#   T8   Decode rejects duplicate END_STREAM envelope in stream.
#   T9   parse_connect_error_json: control-char escape (\\n) round-trips.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_NOT_FOUND,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    CONNECT_JSON_CONTENT_TYPE_UNARY,
    CONNECT_JSON_CONTENT_TYPE_STREAM,
    ConnectStreamDecodedBody,
    ConnectErrorEnvelope,
    connect_json_encode_unary,
    connect_json_decode_unary,
    connect_json_append_message,
    connect_json_append_end_stream,
    connect_json_decode_stream,
    build_connect_error_json,
    build_connect_end_stream_json,
    parse_connect_error_json,
    write_envelope,
)


def _str_to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(s.byte_length()):
        out.append(UInt8(ord(s[byte=i])))
    return out^


def _bytes_to_str(b: Span[UInt8, _]) -> String:
    var buf = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        buf.append(b[i])
    return String(unsafe_from_utf8=Span(buf))


def test_t1_unary_pass_through() raises:
    """T1 — unary encode/decode is byte-identical pass-through."""
    var json = _str_to_bytes(String("{\"hello\":\"world\"}"))
    var encoded = connect_json_encode_unary(Span(json))
    assert_equal(len(encoded), len(json), "byte-length equal")
    for i in range(len(json)):
        assert_equal(encoded[i], json[i], "byte i equal")

    var decoded = connect_json_decode_unary(Span(encoded))
    assert_equal(len(decoded), len(encoded), "decoded length equal")


def test_t2_error_envelope_ok_and_not_found() raises:
    """T2 — build_connect_error_json: OK → {}; non-OK → {"code":..."}."""
    var ok_body = build_connect_error_json(GRPC_STATUS_OK, String(""))
    assert_equal(_bytes_to_str(Span(ok_body)), String("{}"), "OK is empty object")

    var nf_body = build_connect_error_json(GRPC_STATUS_NOT_FOUND, String("user 42 missing"))
    var nf_str = _bytes_to_str(Span(nf_body))
    assert_equal(nf_str, String("{\"code\":\"not_found\",\"message\":\"user 42 missing\"}"), "not_found shape")


def test_t3_error_envelope_json_escape() raises:
    """T3 — build_connect_error_json escapes \\ and " in message."""
    var body = build_connect_error_json(GRPC_STATUS_INVALID_ARGUMENT, String("bad \"quoted\" and \\backslash"))
    var s = _bytes_to_str(Span(body))
    assert_equal(s, String("{\"code\":\"invalid_argument\",\"message\":\"bad \\\"quoted\\\" and \\\\backslash\"}"), "JSON-escaped")


def test_t4_error_envelope_round_trip() raises:
    """T4 — parse_connect_error_json round-trip for non-OK envelope."""
    var body = build_connect_error_json(GRPC_STATUS_INVALID_ARGUMENT, String("bad input"))
    var parsed = parse_connect_error_json(Span(body))
    assert_equal(parsed.code, GRPC_STATUS_INVALID_ARGUMENT, "code round-trip")
    assert_equal(parsed.message, String("bad input"), "message round-trip")


def test_t5_end_stream_json_shapes() raises:
    """T5 — build_connect_end_stream_json: OK → {}; non-OK wraps error."""
    var ok = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    assert_equal(_bytes_to_str(Span(ok)), String("{}"), "OK end-stream")

    var err = build_connect_end_stream_json(GRPC_STATUS_NOT_FOUND, String("nope"))
    var s = _bytes_to_str(Span(err))
    assert_equal(s, String("{\"error\":{\"code\":\"not_found\",\"message\":\"nope\"}}"), "error end-stream shape")


def test_t6_streaming_round_trip() raises:
    """T6 — streaming: append messages + end_stream; decode_stream splits."""
    var body = List[UInt8]()
    var m1 = _str_to_bytes(String("{\"n\":1}"))
    connect_json_append_message(body, Span(m1))
    var m2 = _str_to_bytes(String("{\"n\":2}"))
    connect_json_append_message(body, Span(m2))
    var es = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    connect_json_append_end_stream(body, Span(es))

    var decoded = connect_json_decode_stream(Span(body))
    assert_equal(len(decoded.messages), 2, "2 messages")
    assert_true(decoded.saw_end_stream, "end-stream seen")
    assert_equal(_bytes_to_str(decoded.messages[0]), String("{\"n\":1}"), "m0 content")
    assert_equal(_bytes_to_str(decoded.messages[1]), String("{\"n\":2}"), "m1 content")
    assert_equal(_bytes_to_str(decoded.end_stream_payload), String("{}"), "end-stream payload")


def test_t7_decode_stream_rejects_compressed() raises:
    """T7 — compressed envelope rejected in stream decode."""
    var body = List[UInt8]()
    var m = _str_to_bytes(String("{}"))
    write_envelope(body, ENVELOPE_FLAG_COMPRESSED, Span(m))

    var raised = False
    try:
        var _ = connect_json_decode_stream(Span(body))
    except:
        raised = True
    assert_true(raised, "compressed raised")


def test_t8_decode_stream_rejects_duplicate_end() raises:
    """T8 — two END_STREAM envelopes rejected."""
    var body = List[UInt8]()
    var m = _str_to_bytes(String("{\"n\":1}"))
    connect_json_append_message(body, Span(m))
    var es1 = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    connect_json_append_end_stream(body, Span(es1))
    var es2 = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    connect_json_append_end_stream(body, Span(es2))

    var raised = False
    try:
        var _ = connect_json_decode_stream(Span(body))
    except:
        raised = True
    assert_true(raised, "duplicate END_STREAM raised")


def test_t9_parse_control_char_round_trip() raises:
    """T9 — control char escape (\\n) round-trips through encode + parse."""
    var body = build_connect_error_json(GRPC_STATUS_INVALID_ARGUMENT, String("line one\nline two"))
    var parsed = parse_connect_error_json(Span(body))
    assert_equal(parsed.code, GRPC_STATUS_INVALID_ARGUMENT, "code")
    assert_equal(parsed.message, String("line one\nline two"), "control char round-trip")


def main() raises:
    test_t1_unary_pass_through()
    test_t2_error_envelope_ok_and_not_found()
    test_t3_error_envelope_json_escape()
    test_t4_error_envelope_round_trip()
    test_t5_end_stream_json_shapes()
    test_t6_streaming_round_trip()
    test_t7_decode_stream_rejects_compressed()
    test_t8_decode_stream_rejects_duplicate_end()
    test_t9_parse_control_char_round_trip()
    print("test_L5_codec_connect_json: 9/9 PASS")
