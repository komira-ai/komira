# =============================================================================
# test_L5_codec_grpc_web.mojo — gRPC-Web `application/grpc-web+proto` codec
# =============================================================================
#
# gRPC-Web codec (HTTP/1.1 + HTTP/2).
#
# Coverage:
#   T1   grpc_web_encode_unary + grpc_web_decode_response — single message
#        + OK trailers round-trip.
#   T2   grpc_web_encode_unary with non-OK trailers (status + message).
#   T3   Multi-message server-streaming response: 3 messages + trailers.
#   T4   grpc_web_encode_request + grpc_web_decode_request — client unary
#        (no trailers).
#   T5   grpc_web_decode_request rejects body containing trailer envelope.
#   T6   Response body without trailers — saw_trailers = False.
#   T7   Duplicate trailer envelope rejected.
#   T8   Trailer block missing grpc-status raises.
#   T9   Trailer block with grpc-message percent-encoded round-trips.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_INVALID_ARGUMENT,
    ENVELOPE_FLAG_END_STREAM,
    GRPC_WEB_CONTENT_TYPE,
    GRPC_WEB_CONTENT_TYPE_PROTO,
    GrpcTrailers,
    grpc_make_trailers,
    grpc_make_ok_trailers,
    grpc_web_encode_unary,
    grpc_web_encode_request,
    grpc_web_append_message,
    grpc_web_append_trailers,
    grpc_web_decode_response,
    grpc_web_decode_request,
    write_envelope,
)


def test_t1_unary_round_trip_ok() raises:
    """T1 — encode unary message + OK trailers; decode round-trips."""
    var msg = List[UInt8]()
    msg.append(UInt8(0x42))
    msg.append(UInt8(0x43))

    var body = grpc_web_encode_unary(Span(msg), grpc_make_ok_trailers())
    var decoded = grpc_web_decode_response(Span(body))

    assert_equal(len(decoded.messages), 1, "1 data envelope")
    assert_equal(len(decoded.messages[0]), 2, "data len")
    assert_equal(decoded.messages[0][0], UInt8(0x42), "data byte 0")
    assert_true(decoded.saw_trailers, "saw trailers")
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK, "OK status")
    assert_equal(decoded.trailers.message, String(""), "no message")


def test_t2_unary_with_error_trailers() raises:
    """T2 — non-OK trailers round-trip with status + message."""
    var msg = List[UInt8]()
    msg.append(UInt8(0x01))
    var trailers = grpc_make_trailers(GRPC_STATUS_INVALID_ARGUMENT, String("bad arg"))
    var body = grpc_web_encode_unary(Span(msg), trailers)

    var decoded = grpc_web_decode_response(Span(body))
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_INVALID_ARGUMENT, "status")
    assert_equal(decoded.trailers.message, String("bad arg"), "message")


def test_t3_server_streaming_round_trip() raises:
    """T3 — 3 server-streamed messages + final trailer envelope."""
    var body = List[UInt8]()

    var m1 = List[UInt8]()
    m1.append(UInt8(0x10))
    grpc_web_append_message(body, Span(m1))

    var m2 = List[UInt8]()
    m2.append(UInt8(0x20))
    m2.append(UInt8(0x21))
    grpc_web_append_message(body, Span(m2))

    var m3 = List[UInt8]()
    m3.append(UInt8(0x30))
    m3.append(UInt8(0x31))
    m3.append(UInt8(0x32))
    grpc_web_append_message(body, Span(m3))

    grpc_web_append_trailers(body, grpc_make_ok_trailers())

    var decoded = grpc_web_decode_response(Span(body))
    assert_equal(len(decoded.messages), 3, "3 messages")
    assert_equal(len(decoded.messages[0]), 1, "m1 len")
    assert_equal(len(decoded.messages[1]), 2, "m2 len")
    assert_equal(len(decoded.messages[2]), 3, "m3 len")
    assert_equal(decoded.messages[2][2], UInt8(0x32), "m3 byte 2")
    assert_true(decoded.saw_trailers, "saw trailers")
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK, "OK")


def test_t4_request_round_trip() raises:
    """T4 — client unary request: just data, no trailers."""
    var msg = List[UInt8]()
    msg.append(UInt8(0x99))
    msg.append(UInt8(0x88))

    var body = grpc_web_encode_request(Span(msg))
    var messages = grpc_web_decode_request(Span(body))

    assert_equal(len(messages), 1, "1 message")
    assert_equal(messages[0][0], UInt8(0x99), "byte 0")


def test_t5_request_rejects_trailers() raises:
    """T5 — request body cannot carry END_STREAM envelope."""
    var body = List[UInt8]()
    grpc_web_append_message(body, Span(List[UInt8]()))
    # Force an END_STREAM envelope into the request
    var empty = List[UInt8]()
    write_envelope(body, ENVELOPE_FLAG_END_STREAM, Span(empty))

    var raised = False
    try:
        var _ = grpc_web_decode_request(Span(body))
    except:
        raised = True
    assert_true(raised, "request rejects trailers")


def test_t6_response_without_trailers() raises:
    """T6 — response body with only data envelopes (no closing trailer)."""
    var body = List[UInt8]()
    var m1 = List[UInt8]()
    m1.append(UInt8(0xAA))
    grpc_web_append_message(body, Span(m1))

    var decoded = grpc_web_decode_response(Span(body))
    assert_equal(len(decoded.messages), 1, "1 message")
    assert_false(decoded.saw_trailers, "no trailers seen")
    # Trailers default to OK + empty when not seen
    assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK, "default OK")


def test_t7_duplicate_trailers_rejected() raises:
    """T7 — two END_STREAM envelopes in one body raises."""
    var body = List[UInt8]()
    var m1 = List[UInt8]()
    m1.append(UInt8(0x01))
    grpc_web_append_message(body, Span(m1))
    grpc_web_append_trailers(body, grpc_make_ok_trailers())
    grpc_web_append_trailers(body, grpc_make_ok_trailers())

    var raised = False
    try:
        var _ = grpc_web_decode_response(Span(body))
    except:
        raised = True
    assert_true(raised, "duplicate trailers raised")


def test_t8_trailer_missing_grpc_status() raises:
    """T8 — trailer block without grpc-status raises."""
    var body = List[UInt8]()
    var m1 = List[UInt8]()
    m1.append(UInt8(0x01))
    grpc_web_append_message(body, Span(m1))
    # Craft a trailer envelope with no grpc-status header
    var fake = List[UInt8]()
    var header = String("grpc-message: oops\r\n")
    for i in range(header.byte_length()):
        fake.append(UInt8(ord(header[byte=i])))
    write_envelope(body, ENVELOPE_FLAG_END_STREAM, Span(fake))

    var raised = False
    try:
        var _ = grpc_web_decode_response(Span(body))
    except:
        raised = True
    assert_true(raised, "missing grpc-status raised")


def test_t9_trailer_percent_encoded_message_round_trip() raises:
    """T9 — grpc-message with control chars percent-encodes + decodes."""
    var msg = List[UInt8]()
    msg.append(UInt8(0x01))
    var trailers = grpc_make_trailers(
        GRPC_STATUS_INVALID_ARGUMENT, String("bad\nthings")
    )
    var body = grpc_web_encode_unary(Span(msg), trailers)
    var decoded = grpc_web_decode_response(Span(body))
    assert_equal(decoded.trailers.message, String("bad\nthings"), "percent-encoded round-trip")


def main() raises:
    test_t1_unary_round_trip_ok()
    test_t2_unary_with_error_trailers()
    test_t3_server_streaming_round_trip()
    test_t4_request_round_trip()
    test_t5_request_rejects_trailers()
    test_t6_response_without_trailers()
    test_t7_duplicate_trailers_rejected()
    test_t8_trailer_missing_grpc_status()
    test_t9_trailer_percent_encoded_message_round_trip()
    print("test_L5_codec_grpc_web: 9/9 PASS")
