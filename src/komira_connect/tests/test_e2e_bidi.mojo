# =============================================================================
# test_e2e_bidi.mojo — Connect-RPC bidirectional streaming e2e
# =============================================================================
#
# Bidirectional streaming RPC.
#
# Bidi: client sends N request messages; server interleaves N response
# messages back. ONLY supported over HTTP/2 (gRPC + gRPC-Web over HTTP/2,
# AND Connect-JSON over HTTP/2 — never HTTP/1.1, because HTTP/1.1 can't
# multiplex). gRPC-Web bidi over HTTP/1.1 is NOT supported by the spec.
#
# Coverage:
#   T1   gRPC bidi simulation: client body has 3 messages, server body
#        has 3 messages (different content); decode both independently.
#   T2   gRPC-Web bidi: client 2 messages, server 2 + trailer.
#   T3   Connect-JSON bidi: client 2 messages, server 2 + end-stream.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    GRPC_STATUS_OK,
    grpc_append_message,
    grpc_decode_stream,
    grpc_web_append_message,
    grpc_web_append_trailers,
    grpc_web_decode_request,
    grpc_web_decode_response,
    grpc_make_ok_trailers,
    connect_json_append_message,
    connect_json_append_end_stream,
    connect_json_decode_stream,
    build_connect_end_stream_json,
)


def test_t1_grpc_bidi() raises:
    """T1 — gRPC bidi: client + server bodies decoded independently."""
    # Client side: 3 question messages
    var client_body = List[UInt8]()
    for i in range(3):
        var q = List[UInt8]()
        q.append(UInt8(ord("Q")))
        q.append(UInt8(i))
        grpc_append_message(client_body, Span(q))

    # Server side: 3 answer messages
    var server_body = List[UInt8]()
    for i in range(3):
        var a = List[UInt8]()
        a.append(UInt8(ord("A")))
        a.append(UInt8(i))
        grpc_append_message(server_body, Span(a))

    # Decode client → 3 question envelopes
    var c_envs = grpc_decode_stream(Span(client_body))
    assert_equal(len(c_envs), 3, "3 questions")
    assert_equal(c_envs[0].payload[0], UInt8(ord("Q")), "question prefix")

    # Decode server → 3 answer envelopes
    var s_envs = grpc_decode_stream(Span(server_body))
    assert_equal(len(s_envs), 3, "3 answers")
    assert_equal(s_envs[0].payload[0], UInt8(ord("A")), "answer prefix")


def test_t2_grpc_web_bidi() raises:
    """T2 — gRPC-Web bidi (HTTP/2 only): 2 each + server trailer."""
    var client_body = List[UInt8]()
    var q1 = List[UInt8]()
    q1.append(UInt8(0x01))
    grpc_web_append_message(client_body, Span(q1))
    var q2 = List[UInt8]()
    q2.append(UInt8(0x02))
    grpc_web_append_message(client_body, Span(q2))

    var server_body = List[UInt8]()
    var a1 = List[UInt8]()
    a1.append(UInt8(0x81))
    grpc_web_append_message(server_body, Span(a1))
    var a2 = List[UInt8]()
    a2.append(UInt8(0x82))
    grpc_web_append_message(server_body, Span(a2))
    grpc_web_append_trailers(server_body, grpc_make_ok_trailers())

    var c_msgs = grpc_web_decode_request(Span(client_body))
    assert_equal(len(c_msgs), 2, "2 questions")

    var s_decoded = grpc_web_decode_response(Span(server_body))
    assert_equal(len(s_decoded.messages), 2, "2 answers")
    assert_true(s_decoded.saw_trailers, "server trailers")
    assert_equal(s_decoded.trailers.status_code, GRPC_STATUS_OK, "OK")


def test_t3_connect_json_bidi() raises:
    """T3 — Connect-JSON bidi: 2 each + server end-stream."""
    var client_body = List[UInt8]()
    var qs = String("{\"q\":1}")
    var q1 = List[UInt8]()
    for i in range(qs.byte_length()):
        q1.append(UInt8(ord(qs[byte=i])))
    connect_json_append_message(client_body, Span(q1))
    var qs2 = String("{\"q\":2}")
    var q2 = List[UInt8]()
    for i in range(qs2.byte_length()):
        q2.append(UInt8(ord(qs2[byte=i])))
    connect_json_append_message(client_body, Span(q2))

    var server_body = List[UInt8]()
    var as_s = String("{\"a\":1}")
    var a1 = List[UInt8]()
    for i in range(as_s.byte_length()):
        a1.append(UInt8(ord(as_s[byte=i])))
    connect_json_append_message(server_body, Span(a1))
    var as2 = String("{\"a\":2}")
    var a2 = List[UInt8]()
    for i in range(as2.byte_length()):
        a2.append(UInt8(ord(as2[byte=i])))
    connect_json_append_message(server_body, Span(a2))
    var es = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    connect_json_append_end_stream(server_body, Span(es))

    var c_decoded = connect_json_decode_stream(Span(client_body))
    assert_equal(len(c_decoded.messages), 2, "2 questions")

    var s_decoded = connect_json_decode_stream(Span(server_body))
    assert_equal(len(s_decoded.messages), 2, "2 answers")
    assert_true(s_decoded.saw_end_stream, "end-stream from server")


def main() raises:
    test_t1_grpc_bidi()
    test_t2_grpc_web_bidi()
    test_t3_connect_json_bidi()
    print("test_e2e_bidi: 3/3 PASS")
