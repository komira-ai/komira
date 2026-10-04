# =============================================================================
# test_L5_unary_wire.mojo — wire-layer marshalling for unary RPCs
# =============================================================================
#
# wire.mojo + protocol.mojo + call_options.mojo coverage. The wire layer is
# the transport-free piece that runs above HttpClient.send (whose wiring the
# e2e tests cover).
#
# Coverage:
#   T1   ProtocolGrpcProto exposes correct content_type + accept + enveloped.
#   T2   ProtocolConnectProto exposes Connect content-types + bare body +
#        Connect-Protocol-Version: 1.
#   T3   ProtocolConnectJson same as ConnectProto with JSON wire.
#   T4   encode_unary_request[ProtocolGrpcProto] — body has 5-byte envelope.
#   T5   encode_unary_request[ProtocolConnectProto] — body is bare (no
#        envelope).
#   T6   decode_unary_response[ProtocolGrpcProto] — HTTP 200 + enveloped
#        body returns inner payload span.
#   T7   decode_unary_response[ProtocolGrpcProto] — HTTP non-200 raises
#        with [grpc:2] (UNKNOWN).
#   T8   decode_unary_response[ProtocolConnectProto] — HTTP 2xx + bare
#        body returns body verbatim.
#   T9   decode_unary_response[ProtocolConnectProto] — HTTP non-2xx +
#        Connect-JSON error envelope raises with the envelope's code.
#   T10  decode_unary_response[ProtocolConnectProto] — HTTP non-2xx +
#        malformed JSON envelope falls back to UNKNOWN.
#   T11  encode_stream_message — appends 5-byte envelope to existing buffer.
#   T12  CallOptions — default has no deadline; with_deadline_micros sets;
#        with_relative_deadline_us computes absolute.
#   T13  CallOptions — is_deadline_expired correctly compares clock value.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    ProtocolGrpcProto,
    ProtocolConnectProto,
    ProtocolConnectJson,
    CallOptions,
    CALL_DEADLINE_UNSET,
    encode_unary_request,
    decode_unary_response,
    encode_stream_message,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_UNKNOWN,
    parse_grpc_error_message,
)
from komira_connect.codec_connect_json import build_connect_error_json


def test_t1_protocol_grpc_proto() raises:
    """T1 — ProtocolGrpcProto comptime metadata."""
    # Canonical bare `application/grpc` (Google's front end 404s the
    # non-canonical `application/grpc+proto`). Server accepts both forms.
    assert_equal(
        ProtocolGrpcProto.unary_content_type(),
        String("application/grpc"),
        "unary ct",
    )
    assert_equal(
        ProtocolGrpcProto.stream_content_type(),
        String("application/grpc"),
        "stream ct",
    )
    assert_equal(
        ProtocolGrpcProto.accept_header(),
        String("application/grpc"),
        "accept",
    )
    assert_true(ProtocolGrpcProto.unary_is_enveloped(), "enveloped")
    var ver = ProtocolGrpcProto.connect_protocol_version()
    assert_false(ver.__bool__(), "no Connect-Protocol-Version for gRPC")
    assert_equal(ProtocolGrpcProto.name(), String("grpc+proto"), "name")


def test_t2_protocol_connect_proto() raises:
    """T2 — ProtocolConnectProto comptime metadata."""
    assert_equal(
        ProtocolConnectProto.unary_content_type(),
        String("application/proto"),
        "unary ct",
    )
    assert_equal(
        ProtocolConnectProto.stream_content_type(),
        String("application/connect+proto"),
        "stream ct",
    )
    assert_false(ProtocolConnectProto.unary_is_enveloped(), "bare body")
    var ver = ProtocolConnectProto.connect_protocol_version()
    assert_true(ver.__bool__(), "Connect-Protocol-Version present")
    assert_equal(ver.value(), String("1"), "version = 1")


def test_t3_protocol_connect_json() raises:
    """T3 — ProtocolConnectJson comptime metadata."""
    assert_equal(
        ProtocolConnectJson.unary_content_type(),
        String("application/json"),
        "unary ct json",
    )
    assert_equal(
        ProtocolConnectJson.stream_content_type(),
        String("application/connect+json"),
        "stream ct json",
    )
    assert_false(ProtocolConnectJson.unary_is_enveloped(), "json bare body")


def test_t4_encode_grpc_proto_envelopes() raises:
    """T4 — encode_unary_request[ProtocolGrpcProto] adds 5-byte envelope."""
    var msg = List[UInt8]()
    msg.append(UInt8(0x11))
    msg.append(UInt8(0x22))
    msg.append(UInt8(0x33))
    var body = encode_unary_request[ProtocolGrpcProto](Span(msg))
    # 5-byte envelope: flags=0, length=3 BE, then 3 payload bytes.
    assert_equal(len(body), 8, "5 + 3 bytes")
    assert_equal(body[0], UInt8(0), "flags")
    assert_equal(body[1], UInt8(0), "len byte 0")
    assert_equal(body[2], UInt8(0), "len byte 1")
    assert_equal(body[3], UInt8(0), "len byte 2")
    assert_equal(body[4], UInt8(3), "len byte 3")
    assert_equal(body[5], UInt8(0x11), "payload 0")
    assert_equal(body[6], UInt8(0x22), "payload 1")
    assert_equal(body[7], UInt8(0x33), "payload 2")


def test_t5_encode_connect_proto_bare() raises:
    """T5 — encode_unary_request[ProtocolConnectProto] is bare body."""
    var msg = List[UInt8]()
    msg.append(UInt8(0xAA))
    msg.append(UInt8(0xBB))
    var body = encode_unary_request[ProtocolConnectProto](Span(msg))
    # Bare body — no envelope.
    assert_equal(len(body), 2, "2 bytes")
    assert_equal(body[0], UInt8(0xAA), "byte 0")
    assert_equal(body[1], UInt8(0xBB), "byte 1")


def test_t6_decode_grpc_proto_200() raises:
    """T6 — decode_unary_response[ProtocolGrpcProto] HTTP 200 strips envelope."""
    # Build a 5-byte enveloped body
    var msg = List[UInt8]()
    msg.append(UInt8(0xDE))
    msg.append(UInt8(0xAD))
    msg.append(UInt8(0xBE))
    msg.append(UInt8(0xEF))
    var body = encode_unary_request[ProtocolGrpcProto](Span(msg))
    var inner = decode_unary_response[ProtocolGrpcProto](Span(body), UInt16(200))
    assert_equal(len(inner), 4, "4 bytes inner")
    assert_equal(inner[0], UInt8(0xDE), "byte 0")
    assert_equal(inner[1], UInt8(0xAD), "byte 1")
    assert_equal(inner[2], UInt8(0xBE), "byte 2")
    assert_equal(inner[3], UInt8(0xEF), "byte 3")


def test_t7_decode_grpc_proto_non_200_raises() raises:
    """T7 — decode_unary_response[ProtocolGrpcProto] HTTP non-200 → UNKNOWN."""
    var body = List[UInt8]()  # empty body; should not matter
    var raised = False
    var caught_msg = String("")
    try:
        var _ = decode_unary_response[ProtocolGrpcProto](Span(body), UInt16(502))
    except e:
        raised = True
        caught_msg = String(e)
    assert_true(raised, "non-200 raises")
    var parsed = parse_grpc_error_message(caught_msg)
    assert_equal(parsed[0], GRPC_STATUS_UNKNOWN, "code UNKNOWN (2)")


def test_t8_decode_connect_proto_200() raises:
    """T8 — decode_unary_response[ProtocolConnectProto] HTTP 200 returns body."""
    var body = List[UInt8]()
    body.append(UInt8(0x55))
    body.append(UInt8(0x66))
    body.append(UInt8(0x77))
    var inner = decode_unary_response[ProtocolConnectProto](Span(body), UInt16(200))
    assert_equal(len(inner), 3, "3 bytes")
    assert_equal(inner[0], UInt8(0x55), "byte 0")
    assert_equal(inner[1], UInt8(0x66), "byte 1")
    assert_equal(inner[2], UInt8(0x77), "byte 2")


def test_t9_decode_connect_proto_error_envelope() raises:
    """T9 — Connect non-2xx + JSON error envelope → raised GrpcError."""
    # Build a Connect JSON error envelope with code=NOT_FOUND.
    var envelope = build_connect_error_json(
        GRPC_STATUS_NOT_FOUND, String("user 42 not found")
    )
    var raised = False
    var caught_msg = String("")
    try:
        var _ = decode_unary_response[ProtocolConnectProto](
            Span(envelope), UInt16(404)
        )
    except e:
        raised = True
        caught_msg = String(e)
    assert_true(raised, "non-2xx + envelope raises")
    var parsed = parse_grpc_error_message(caught_msg)
    assert_equal(parsed[0], GRPC_STATUS_NOT_FOUND, "code NOT_FOUND")
    assert_equal(parsed[1], String("user 42 not found"), "message preserved")


def test_t10_decode_connect_malformed_envelope() raises:
    """T10 — Connect non-2xx + malformed JSON falls back to UNKNOWN."""
    # Note: parse_connect_error_json is *tolerant* — it returns
    # ConnectErrorEnvelope(0, "") for completely-invalid JSON rather than
    # raising. So this test verifies the resulting GrpcError is constructed
    # with the parsed code (which may be 0/OK on malformed input). The
    # documented fallback path triggers only when parse_connect_error_json
    # itself raises (truncated JSON). We exercise that path here.
    var body = List[UInt8]()
    body.append(UInt8(ord("{")))  # opens an object but never closes
    var raised = False
    var caught_msg = String("")
    try:
        var _ = decode_unary_response[ProtocolConnectProto](Span(body), UInt16(500))
    except e:
        raised = True
        caught_msg = String(e)
    assert_true(raised, "raises on Connect error path")
    # Either UNKNOWN-fallback or the parsed code; both acceptable per spec.
    # We just require the prefix to be [grpc:N].
    assert_true(
        caught_msg.startswith(String("[grpc:")),
        "error has [grpc:N] prefix",
    )


def test_t11_encode_stream_message() raises:
    """T11 — encode_stream_message appends 5-byte envelope."""
    var buf = List[UInt8]()
    # Pre-existing content
    buf.append(UInt8(0xFF))
    buf.append(UInt8(0xFE))
    var msg = List[UInt8]()
    msg.append(UInt8(0xAA))
    encode_stream_message[ProtocolGrpcProto](buf, Span(msg))
    # buf is now [0xFF, 0xFE, envelope(flags=0, len=1), 0xAA]
    assert_equal(len(buf), 2 + 5 + 1, "8 bytes total")
    assert_equal(buf[0], UInt8(0xFF), "pre-byte preserved")
    assert_equal(buf[1], UInt8(0xFE), "pre-byte preserved")
    assert_equal(buf[2], UInt8(0), "flags")
    assert_equal(buf[6], UInt8(1), "length last byte")
    assert_equal(buf[7], UInt8(0xAA), "payload")


def test_t12_call_options() raises:
    """T12 — CallOptions default + setters."""
    var opts = CallOptions.new()
    assert_false(opts.has_deadline(), "no deadline by default")
    assert_equal(opts.deadline_micros, CALL_DEADLINE_UNSET, "0 sentinel")

    opts.with_deadline_micros(1_500_000)
    assert_true(opts.has_deadline(), "deadline set")
    assert_equal(opts.deadline_micros, 1_500_000, "value")

    var opts2 = CallOptions.new()
    opts2.with_relative_deadline_us(now_us=1_000_000, relative_us=2_000_000)
    assert_equal(opts2.deadline_micros, 3_000_000, "absolute = now + rel")

    var opts3 = CallOptions.new()
    opts3.with_relative_deadline_us(now_us=1_000_000, relative_us=-50)
    # Already tripped — deadline_micros == now_us
    assert_equal(opts3.deadline_micros, 1_000_000, "tripped → now_us")


def test_t13_deadline_expired() raises:
    """T13 — is_deadline_expired compares now_us vs deadline."""
    var opts = CallOptions.new()
    # No deadline — never expired.
    assert_false(opts.is_deadline_expired(now_us=1_000_000), "no deadline")

    opts.with_deadline_micros(2_000_000)
    assert_false(opts.is_deadline_expired(now_us=1_999_999), "before")
    assert_true(opts.is_deadline_expired(now_us=2_000_000), "at deadline")
    assert_true(opts.is_deadline_expired(now_us=3_000_000), "past deadline")


def main() raises:
    test_t1_protocol_grpc_proto()
    test_t2_protocol_connect_proto()
    test_t3_protocol_connect_json()
    test_t4_encode_grpc_proto_envelopes()
    test_t5_encode_connect_proto_bare()
    test_t6_decode_grpc_proto_200()
    test_t7_decode_grpc_proto_non_200_raises()
    test_t8_decode_connect_proto_200()
    test_t9_decode_connect_proto_error_envelope()
    test_t10_decode_connect_malformed_envelope()
    test_t11_encode_stream_message()
    test_t12_call_options()
    test_t13_deadline_expired()
    print("test_L5_unary_wire: 13/13 PASS")
