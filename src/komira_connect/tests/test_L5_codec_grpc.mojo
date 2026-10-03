# =============================================================================
# test_L5_codec_grpc.mojo — gRPC `application/grpc+proto` codec tests
# =============================================================================
#
# gRPC codec (HTTP/2 only).
#
# Coverage:
#   T1   grpc_encode_unary + grpc_decode_unary round-trip — single message.
#   T2   grpc_decode_unary rejects empty body.
#   T3   grpc_decode_unary rejects trailing bytes after envelope.
#   T4   grpc_append_message + grpc_decode_stream — N messages back-to-back.
#   T5   GrpcTrailers shape: OK + non-OK examples.
#   T6   grpc_percent_encode_message: ASCII passthrough + % escape.
#   T7   grpc_percent_encode_message: non-ASCII byte escaped to %XX.
#   T8   grpc_percent_decode_message: round-trip + malformed %XX raises.
#   T9   grpc_decode_unary rejects compressed envelope (unsupported).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_INVALID_ARGUMENT,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    GRPC_CONTENT_TYPE,
    GRPC_CONTENT_TYPE_PROTO,
    GRPC_TRAILER_STATUS,
    GRPC_TRAILER_MESSAGE,
    GrpcTrailers,
    grpc_encode_unary,
    grpc_append_message,
    grpc_decode_unary,
    grpc_decode_stream,
    grpc_make_trailers,
    grpc_make_ok_trailers,
    grpc_percent_encode_message,
    grpc_percent_decode_message,
    write_envelope,
)
from komira_connect.codec_grpc import grpc_percent_encode_bytes


def test_t1_unary_round_trip() raises:
    """T1 — encode unary message + decode back."""
    var msg = List[UInt8]()
    msg.append(UInt8(0xAA))
    msg.append(UInt8(0xBB))
    msg.append(UInt8(0xCC))

    var body = grpc_encode_unary(Span(msg))
    assert_equal(len(body), 5 + 3, "5 header + 3 body")

    var decoded = grpc_decode_unary(Span(body))
    assert_equal(len(decoded), 3, "decoded length")
    assert_equal(decoded[0], UInt8(0xAA), "byte 0")
    assert_equal(decoded[1], UInt8(0xBB), "byte 1")
    assert_equal(decoded[2], UInt8(0xCC), "byte 2")


def test_t2_empty_body_rejected() raises:
    """T2 — empty body raises on unary decode."""
    var empty = List[UInt8]()
    var raised = False
    try:
        var _ = grpc_decode_unary(Span(empty))
    except:
        raised = True
    assert_true(raised, "empty body raised")


def test_t3_trailing_bytes_rejected() raises:
    """T3 — extra bytes after one envelope rejected by unary decode."""
    var body = List[UInt8]()
    var msg = List[UInt8]()
    msg.append(UInt8(0x42))
    write_envelope(body, 0x00, Span(msg))
    # Add 3 stray bytes
    body.append(UInt8(0xFF))
    body.append(UInt8(0xFF))
    body.append(UInt8(0xFF))

    var raised = False
    try:
        var _ = grpc_decode_unary(Span(body))
    except:
        raised = True
    assert_true(raised, "trailing bytes raised")


def test_t4_stream_round_trip() raises:
    """T4 — 3-message streaming round-trip."""
    var body = List[UInt8]()
    var m1 = List[UInt8]()
    m1.append(UInt8(0x01))
    grpc_append_message(body, Span(m1))

    var m2 = List[UInt8]()
    m2.append(UInt8(0x02))
    m2.append(UInt8(0x03))
    grpc_append_message(body, Span(m2))

    var m3 = List[UInt8]()
    m3.append(UInt8(0x04))
    m3.append(UInt8(0x05))
    m3.append(UInt8(0x06))
    grpc_append_message(body, Span(m3))

    var envs = grpc_decode_stream(Span(body))
    assert_equal(len(envs), 3, "3 envelopes")
    assert_equal(len(envs[0].payload), 1, "env0 len")
    assert_equal(envs[0].payload[0], UInt8(0x01), "env0 byte")
    assert_equal(len(envs[1].payload), 2, "env1 len")
    assert_equal(envs[1].payload[1], UInt8(0x03), "env1 byte 1")
    assert_equal(len(envs[2].payload), 3, "env2 len")
    assert_equal(envs[2].payload[2], UInt8(0x06), "env2 byte 2")


def test_t5_trailer_shapes() raises:
    """T5 — GrpcTrailers shape: OK + non-OK."""
    var ok = grpc_make_ok_trailers()
    assert_equal(ok.status_code, GRPC_STATUS_OK, "OK status")
    assert_equal(ok.message, String(""), "OK no message")

    var bad = grpc_make_trailers(GRPC_STATUS_INVALID_ARGUMENT, String("bad input"))
    assert_equal(bad.status_code, GRPC_STATUS_INVALID_ARGUMENT, "bad code")
    assert_equal(bad.message, String("bad input"), "bad message")


def test_t6_percent_encode_ascii_passthrough() raises:
    """T6 — printable ASCII passes through; '%' encoded to %25."""
    assert_equal(grpc_percent_encode_message(String("hello world")), String("hello world"), "passthrough")
    assert_equal(grpc_percent_encode_message(String("100% sure")), String("100%25 sure"), "% escaped")
    assert_equal(grpc_percent_encode_message(String("")), String(""), "empty")


def test_t7_percent_encode_non_ascii() raises:
    """T7 — non-ASCII byte → %XX uppercase hex."""
    # Build "X\nY" — \n (0x0A) is non-printable
    var msg = String("X\nY")
    var encoded = grpc_percent_encode_message(msg)
    assert_equal(encoded, String("X%0AY"), "control byte escaped")

    # High byte (0xFF) — encode via byte-level API to avoid String UTF-8
    # validation quirks (a single 0xFF is invalid UTF-8). The gRPC spec
    # says grpc-message is a byte-oriented header value; the byte-level
    # form is the canonical encoder.
    var raw = List[UInt8]()
    raw.append(UInt8(0xFF))
    var enc2 = grpc_percent_encode_bytes(Span(raw))
    assert_equal(enc2, String("%FF"), "0xFF → %FF (byte-level)")

    # Multi-byte UTF-8 (café → c-a-f-eA cc 81 in UTF-8): each non-ASCII
    # byte gets escaped (cc → %CC, 81 → %81)
    var utf8 = List[UInt8]()
    utf8.append(UInt8(0xCC))
    utf8.append(UInt8(0x81))
    var enc3 = grpc_percent_encode_bytes(Span(utf8))
    assert_equal(enc3, String("%CC%81"), "UTF-8 multibyte → %CC%81")


def test_t8_percent_decode_round_trip() raises:
    """T8 — encode-decode round trip + malformed %XX raises."""
    var enc = grpc_percent_encode_message(String("100% sure"))
    var dec = grpc_percent_decode_message(enc)
    assert_equal(dec, String("100% sure"), "round-trip %")

    # Malformed (truncated)
    var raised = False
    try:
        var _ = grpc_percent_decode_message(String("X%"))
    except:
        raised = True
    assert_true(raised, "truncated %XX raised")

    # Malformed (non-hex)
    var raised2 = False
    try:
        var _ = grpc_percent_decode_message(String("X%ZZ"))
    except:
        raised2 = True
    assert_true(raised2, "non-hex %XX raised")


def test_t9_compressed_envelope_rejected() raises:
    """T9 — compressed envelope rejected (compression is not supported)."""
    var body = List[UInt8]()
    var msg = List[UInt8]()
    msg.append(UInt8(0x42))
    write_envelope(body, ENVELOPE_FLAG_COMPRESSED, Span(msg))

    var raised = False
    try:
        var _ = grpc_decode_unary(Span(body))
    except:
        raised = True
    assert_true(raised, "compressed envelope raised")


def main() raises:
    test_t1_unary_round_trip()
    test_t2_empty_body_rejected()
    test_t3_trailing_bytes_rejected()
    test_t4_stream_round_trip()
    test_t5_trailer_shapes()
    test_t6_percent_encode_ascii_passthrough()
    test_t7_percent_encode_non_ascii()
    test_t8_percent_decode_round_trip()
    test_t9_compressed_envelope_rejected()
    print("test_L5_codec_grpc: 9/9 PASS")
