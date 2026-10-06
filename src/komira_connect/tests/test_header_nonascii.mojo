# =============================================================================
# test_header_nonascii.mojo: non-ASCII request headers on the server side
# =============================================================================
#
# `content-type`, `grpc-timeout` and `Connect-Timeout-Ms` are the peer's
# header values: any byte can be in them. Reading one with `s[byte=i]`
# asserts on the first UTF-8 continuation byte ("does not lie on a codepoint
# boundary") and aborts the whole process, so before the fix every leg below
# killed the test binary (and, in production, the server) instead of
# answering.
#
# Spec:
#   * content-type (RFC 9110 8.3.1): only type/subtype picks the codec; a
#     parameter, ASCII or not, is ignored.
#   * grpc-timeout (gRPC PROTOCOL-HTTP2.md): `1*8DIGIT TimeoutUnit`. A
#     non-ASCII byte is neither, so the value is malformed and the call runs
#     with no deadline (DEADLINE_UNSET_MICROS), as for any malformed value.
#   * Connect-Timeout-Ms (Connect protocol): `1*10DIGIT`; same treatment.
#
# Coverage:
#   T1  codec_id_for_content_type: a non-ASCII parameter keeps the codec; a
#       non-ASCII base type is UNKNOWN.
#   T2  parse_grpc_timeout: a non-ASCII unit, digit or tail is unset; a
#       well-formed value next to it still parses.
#   T3  parse_connect_timeout_ms: the same.
#   T4  ConnectService.dispatch_grpc with `application/grpc+proto;
#       charset=café`: the echo answers grpc-status 0 with the request bytes,
#       and the same service then answers a plain request (it survived).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    CODEC_ID_CONNECT_JSON,
    CODEC_ID_GRPC,
    CODEC_ID_GRPC_WEB,
    CODEC_ID_UNKNOWN,
    ConnectService,
    DEADLINE_UNSET_MICROS,
    codec_id_for_content_type,
    grpc_decode_unary,
    grpc_encode_unary,
    parse_connect_timeout_ms,
    parse_grpc_timeout,
)


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def test_t1_content_type() raises:
    print("  T1 content-type codec...")
    assert_equal(
        codec_id_for_content_type(String("application/grpc+proto; charset=café")),
        CODEC_ID_GRPC,
    )
    assert_equal(
        codec_id_for_content_type(String("application/grpc-web;✓")),
        CODEC_ID_GRPC_WEB,
    )
    assert_equal(
        codec_id_for_content_type(String("application/json; charset=é")),
        CODEC_ID_CONNECT_JSON,
    )
    assert_equal(codec_id_for_content_type(String("application/jsoné")), CODEC_ID_UNKNOWN)
    assert_equal(codec_id_for_content_type(String("é; x=1")), CODEC_ID_UNKNOWN)
    print("    OK")


def test_t2_grpc_timeout() raises:
    print("  T2 grpc-timeout...")
    assert_equal(parse_grpc_timeout(String("1Mé")), DEADLINE_UNSET_MICROS)
    assert_equal(parse_grpc_timeout(String("é1M")), DEADLINE_UNSET_MICROS)
    assert_equal(parse_grpc_timeout(String("1éM")), DEADLINE_UNSET_MICROS)
    assert_equal(parse_grpc_timeout(String("é")), DEADLINE_UNSET_MICROS)
    # Control: the parser still parses (1 minute in microseconds).
    assert_equal(parse_grpc_timeout(String("1M")), 60_000_000)
    print("    OK")


def test_t3_connect_timeout_ms() raises:
    print("  T3 Connect-Timeout-Ms...")
    assert_equal(parse_connect_timeout_ms(String("10é")), DEADLINE_UNSET_MICROS)
    assert_equal(parse_connect_timeout_ms(String("é10")), DEADLINE_UNSET_MICROS)
    assert_equal(parse_connect_timeout_ms(String("10")), 10_000)
    print("    OK")


def test_t4_dispatch_survives() raises:
    print("  T4 dispatch_grpc with a non-ASCII content-type parameter...")
    var svc = ConnectService(String("test.Svc"))
    svc.register_method(String("/test.Svc/Echo"), _echo_handler)
    var msg = List[UInt8]()
    msg.append(UInt8(0xAA))
    msg.append(UInt8(0xBB))

    var resp = svc.dispatch_grpc(
        String("/test.Svc/Echo"),
        String("application/grpc+proto; charset=café"),
        grpc_encode_unary(Span(msg)),
    )
    assert_equal(Int(resp.http_status), 200)
    assert_equal(Int(resp.grpc_status), 0)
    var echoed = grpc_decode_unary(Span(resp.body))
    assert_equal(len(echoed), 2)
    assert_equal(echoed[0], UInt8(0xAA))
    assert_equal(echoed[1], UInt8(0xBB))

    var resp2 = svc.dispatch_grpc(
        String("/test.Svc/Echo"),
        String("application/grpc+proto"),
        grpc_encode_unary(Span(msg)),
    )
    assert_equal(Int(resp2.grpc_status), 0)
    print("    OK")


def main() raises:
    print("== non-ASCII request headers ==")
    test_t1_content_type()
    test_t2_grpc_timeout()
    test_t3_connect_timeout_ms()
    test_t4_dispatch_survives()
    print("== PASSED (4 legs) ==")
