# =============================================================================
# test_L5_headers.mojo — build_unary_request_headers + build_stream_request_headers
# =============================================================================
#
# Deadline + metadata + Connect-Protocol-Version header integration.
#
# Coverage:
#   T1   build_unary_request_headers[ProtocolGrpcProto] — content-type +
#        accept + grpc-accept-encoding; NO Connect-Protocol-Version; NO
#        grpc-timeout (no deadline).
#   T2   build_unary_request_headers[ProtocolConnectProto] — Connect-Protocol-
#        Version: 1 present; content-type = application/proto.
#   T3   build_unary_request_headers[ProtocolConnectJson] — same shape +
#        application/json.
#   T4   With deadline: grpc-timeout header set, value derived from
#        (deadline - now_us).
#   T5   Tripped deadline (now_us >= deadline): grpc-timeout = "0u".
#   T6   Stream variant: build_stream_request_headers uses stream_content_type
#        (application/connect+proto vs application/proto for Connect).
#   T7   Metadata: user-set metadata travels VERBATIM on classic gRPC and
#        grpc-metadata- prefixed on Connect.
#   T8   Multi-metadata: multi-value preserved on BOTH arms.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    ProtocolGrpcProto,
    ProtocolConnectProto,
    ProtocolConnectJson,
    CallOptions,
    CALL_DEADLINE_UNSET,
    build_unary_request_headers,
    build_stream_request_headers,
    GRPC_HEADER_CONTENT_TYPE,
    GRPC_HEADER_ACCEPT,
    GRPC_HEADER_CONNECT_PROTOCOL_VERSION,
    GRPC_HEADER_GRPC_TIMEOUT,
    GRPC_HEADER_GRPC_ACCEPT_ENCODING,
    GRPC_METADATA_HEADER_PREFIX,
)


def test_t1_grpc_proto_minimal() raises:
    """T1 — ProtocolGrpcProto headers: content-type, accept, accept-encoding."""
    var opts = CallOptions.new()  # no deadline; empty metadata
    var hdrs = build_unary_request_headers[ProtocolGrpcProto](opts, now_us=0)
    var ct = hdrs.get(GRPC_HEADER_CONTENT_TYPE)
    assert_true(ct.__bool__(), "content-type set")
    # Canonical bare `application/grpc` (Google's front end 404s the
    # non-canonical `application/grpc+proto`). Server accepts both forms.
    assert_equal(ct.value(), String("application/grpc"), "ct value")
    var acc = hdrs.get(GRPC_HEADER_ACCEPT)
    assert_true(acc.__bool__(), "accept set")
    # No Connect-Protocol-Version on classic gRPC
    var cpv = hdrs.get(GRPC_HEADER_CONNECT_PROTOCOL_VERSION)
    assert_false(cpv.__bool__(), "no Connect-Protocol-Version")
    # No grpc-timeout when no deadline
    var to = hdrs.get(GRPC_HEADER_GRPC_TIMEOUT)
    assert_false(to.__bool__(), "no grpc-timeout")
    # grpc-accept-encoding: identity
    var enc = hdrs.get(GRPC_HEADER_GRPC_ACCEPT_ENCODING)
    assert_true(enc.__bool__(), "grpc-accept-encoding set")
    assert_equal(enc.value(), String("identity"), "identity")


def test_t2_connect_proto_has_version() raises:
    """T2 — ProtocolConnectProto sends Connect-Protocol-Version: 1."""
    var opts = CallOptions.new()
    var hdrs = build_unary_request_headers[ProtocolConnectProto](opts, now_us=0)
    var ct = hdrs.get(GRPC_HEADER_CONTENT_TYPE)
    assert_equal(ct.value(), String("application/proto"), "Connect proto ct")
    var cpv = hdrs.get(GRPC_HEADER_CONNECT_PROTOCOL_VERSION)
    assert_true(cpv.__bool__(), "Connect-Protocol-Version present")
    assert_equal(cpv.value(), String("1"), "version 1")


def test_t3_connect_json_content_type() raises:
    """T3 — ProtocolConnectJson uses application/json."""
    var opts = CallOptions.new()
    var hdrs = build_unary_request_headers[ProtocolConnectJson](opts, now_us=0)
    var ct = hdrs.get(GRPC_HEADER_CONTENT_TYPE)
    assert_equal(ct.value(), String("application/json"), "json ct")
    var cpv = hdrs.get(GRPC_HEADER_CONNECT_PROTOCOL_VERSION)
    assert_true(cpv.__bool__(), "Connect-Protocol-Version still set on JSON")


def test_t4_grpc_timeout_with_deadline() raises:
    """T4 — grpc-timeout = (deadline - now) encoded."""
    var opts = CallOptions.new()
    # 5-second deadline from now_us=0: remaining=5_000_000us → "5S"
    opts.with_deadline_micros(5_000_000)
    var hdrs = build_unary_request_headers[ProtocolGrpcProto](opts, now_us=0)
    var to = hdrs.get(GRPC_HEADER_GRPC_TIMEOUT)
    assert_true(to.__bool__(), "grpc-timeout set")
    assert_equal(to.value(), String("5S"), "encoded as 5S (largest unit)")


def test_t5_tripped_deadline_zero() raises:
    """T5 — Tripped deadline → grpc-timeout = '0u'."""
    var opts = CallOptions.new()
    opts.with_deadline_micros(1000)
    # now_us > deadline_micros → remaining = -ve, clamped to 0 by helper
    var hdrs = build_unary_request_headers[ProtocolGrpcProto](
        opts, now_us=2000
    )
    var to = hdrs.get(GRPC_HEADER_GRPC_TIMEOUT)
    assert_true(to.__bool__(), "grpc-timeout set")
    assert_equal(to.value(), String("0u"), "0u for tripped deadline")


def test_t6_stream_content_type() raises:
    """T6 — stream variant uses stream_content_type."""
    var opts = CallOptions.new()
    var hdrs = build_stream_request_headers[ProtocolConnectProto](
        opts, now_us=0
    )
    var ct = hdrs.get(GRPC_HEADER_CONTENT_TYPE)
    assert_equal(
        ct.value(),
        String("application/connect+proto"),
        "Connect streaming ct",
    )


def test_t7_metadata_forwarded() raises:
    """T7 — user metadata is forwarded in THIS protocol's spelling.

    ⚠ NOT the `grpc-metadata-` prefix on the CLASSIC gRPC path. Over gRPC/HTTP2 a
    Custom-Metadata key travels VERBATIM — it IS the header name
    (`grpc/doc/PROTOCOL-HTTP2.md`, "Custom-Metadata"), which is why the gRPC
    interop `custom_metadata` case echoes `x-grpc-test-echo-initial` by that
    exact name. `grpc-metadata-` is a Connect / gRPC-Web HTTP-gateway
    convention for carrying metadata across a protocol translation.

    BOTH POLARITIES are asserted here, so this cannot be read as "delete
    the prefix everywhere": removing it from Connect would break every
    Connect peer.
    """
    var opts = CallOptions.new()
    opts.metadata.set(String("user-id"), String("42"))
    opts.metadata.set(String("request-id"), String("abc"))

    # Classic gRPC — verbatim.
    var grpc_hdrs = build_unary_request_headers[ProtocolGrpcProto](
        opts, now_us=0
    )
    var u = grpc_hdrs.get(String("user-id"))
    assert_true(u.__bool__(), "user-id verbatim on gRPC")
    assert_equal(u.value(), String("42"), "value")
    var r = grpc_hdrs.get(String("request-id"))
    assert_true(r.__bool__(), "request-id verbatim on gRPC")
    assert_equal(r.value(), String("abc"), "value")
    assert_false(
        grpc_hdrs.contains(GRPC_METADATA_HEADER_PREFIX + "user-id"),
        "no grpc-metadata- prefix on the gRPC/HTTP2 wire",
    )

    # Connect — prefixed.
    var connect_hdrs = build_unary_request_headers[ProtocolConnectProto](
        opts, now_us=0
    )
    var cu = connect_hdrs.get(GRPC_METADATA_HEADER_PREFIX + "user-id")
    assert_true(cu.__bool__(), "user-id prefixed on Connect")
    assert_equal(cu.value(), String("42"), "value")
    assert_false(
        connect_hdrs.contains(String("user-id")),
        "Connect does NOT also emit the bare name",
    )


def test_t8_metadata_multi_value() raises:
    """T8 — multi-value metadata (e.g. trace headers) preserves all values.

    As in T7, the gRPC arm reads the VERBATIM key. The property under test —
    a repeated key stays repeated, it is not collapsed to one by an
    insert/REPLACE drain — is asserted on BOTH arms.
    """
    var opts = CallOptions.new()
    opts.metadata.set(String("warning"), String("199 - cache stale"))
    opts.metadata.set(String("warning"), String("214 - misc"))
    var grpc_hdrs = build_unary_request_headers[ProtocolGrpcProto](
        opts, now_us=0
    )
    assert_equal(
        len(grpc_hdrs.get_all(String("warning"))),
        2,
        "two warning values, verbatim key (gRPC)",
    )
    var connect_hdrs = build_unary_request_headers[ProtocolConnectProto](
        opts, now_us=0
    )
    assert_equal(
        len(connect_hdrs.get_all(GRPC_METADATA_HEADER_PREFIX + "warning")),
        2,
        "two warning values, prefixed key (Connect)",
    )


def main() raises:
    test_t1_grpc_proto_minimal()
    test_t2_connect_proto_has_version()
    test_t3_connect_json_content_type()
    test_t4_grpc_timeout_with_deadline()
    test_t5_tripped_deadline_zero()
    test_t6_stream_content_type()
    test_t7_metadata_forwarded()
    test_t8_metadata_multi_value()
    print("test_L5_headers: 8/8 PASS")
