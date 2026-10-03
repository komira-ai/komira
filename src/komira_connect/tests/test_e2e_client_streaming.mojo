# =============================================================================
# test_e2e_client_streaming.mojo — Connect-RPC client-streaming e2e
# =============================================================================
#
# Client-streaming RPC.
#
# A client-streaming RPC: client sends N request messages, server responds
# with one message (typically a summary).
#
# Coverage:
#   T1   gRPC client-streaming: client sends 5 envelope-framed messages;
#        server decodes the stream.
#   T2   gRPC-Web client-streaming: client sends 5 envelope-framed messages
#        (NO trailer envelope from client; client requests cannot carry
#        trailers).
#   T3   Connect-JSON client-streaming: client sends N envelope-framed
#        JSON messages.
#   T4   Empty stream: 0 messages — valid in protocol but server-side
#        decode returns 0 messages.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_connect import (
    grpc_append_message,
    grpc_decode_stream,
    grpc_web_append_message,
    grpc_web_decode_request,
    connect_json_append_message,
    connect_json_decode_stream,
)


def _row(n: Int) -> List[UInt8]:
    var row = List[UInt8]()
    row.append(UInt8(n & 0xFF))
    row.append(UInt8((n + 1) & 0xFF))
    row.append(UInt8((n + 2) & 0xFF))
    return row^


def test_t1_grpc_client_streaming() raises:
    """T1 — gRPC client-streaming: 5 messages."""
    var body = List[UInt8]()
    for i in range(5):
        var r = _row(i)
        grpc_append_message(body, Span(r))

    var envs = grpc_decode_stream(Span(body))
    assert_equal(len(envs), 5, "5 messages")
    for i in range(5):
        assert_equal(envs[i].payload[0], UInt8(i), "msg i byte 0")


def test_t2_grpc_web_client_streaming() raises:
    """T2 — gRPC-Web client-streaming: 5 messages, no trailers."""
    var body = List[UInt8]()
    for i in range(5):
        var r = _row(i + 10)
        grpc_web_append_message(body, Span(r))

    var msgs = grpc_web_decode_request(Span(body))
    assert_equal(len(msgs), 5, "5 messages")
    assert_equal(msgs[0][0], UInt8(10), "first msg")
    assert_equal(msgs[4][0], UInt8(14), "fifth msg")


def test_t3_connect_json_client_streaming() raises:
    """T3 — Connect-JSON client-streaming: 3 JSON messages."""
    var body = List[UInt8]()
    for i in range(3):
        var msg = List[UInt8]()
        var s = String("{\"i\":") + String(i) + String("}")
        for k in range(s.byte_length()):
            msg.append(UInt8(ord(s[byte=k])))
        connect_json_append_message(body, Span(msg))
    # NOTE: client-streaming-from-server perspective decode via
    # connect_json_decode_stream returns saw_end_stream=False because
    # the client never sends an END_STREAM envelope (client requests
    # can't close themselves with a trailer block; the body just ends).

    var decoded = connect_json_decode_stream(Span(body))
    assert_equal(len(decoded.messages), 3, "3 messages")
    assert_false(decoded.saw_end_stream, "no end-stream from client")


def test_t4_empty_stream() raises:
    """T4 — empty client stream: 0 messages."""
    var body = List[UInt8]()
    var grpc_envs = grpc_decode_stream(Span(body))
    assert_equal(len(grpc_envs), 0, "gRPC empty")

    var web_msgs = grpc_web_decode_request(Span(body))
    assert_equal(len(web_msgs), 0, "gRPC-Web empty")

    var json_decoded = connect_json_decode_stream(Span(body))
    assert_equal(len(json_decoded.messages), 0, "JSON empty")


def main() raises:
    test_t1_grpc_client_streaming()
    test_t2_grpc_web_client_streaming()
    test_t3_connect_json_client_streaming()
    test_t4_empty_stream()
    print("test_e2e_client_streaming: 4/4 PASS")
