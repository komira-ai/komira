# =============================================================================
# test_L5_stream.mojo — ServerStreamDecoder + ClientStreamEncoder + BidiStreamCodec
# =============================================================================
#
# stream.mojo: the streaming modes' wire-marshalling state machines
# (transport-free).
#
# Coverage:
#   T1   Empty ServerStreamDecoder yields PENDING (no bytes fed).
#   T2   ServerStreamDecoder — classic-gRPC server-streaming: feed N envelopes,
#        yield N messages, then feed_trailers(grpc-status=0), yield END_OK.
#   T3   ServerStreamDecoder — classic-gRPC non-OK trailers: yield END_ERROR
#        with the parsed code + message.
#   T4   ServerStreamDecoder — Connect-streaming END_STREAM envelope with `{}`
#        payload yields END_OK.
#   T5   ServerStreamDecoder — Connect-streaming END_STREAM envelope with
#        `{"error":{...}}` payload yields END_ERROR with parsed code.
#   T6   ServerStreamDecoder — fragmented Data feed reconstructs envelope
#        correctly (calls feed across boundaries).
#   T7   ServerStreamDecoder — terminated state is sticky (subsequent calls
#        yield END_OK idempotently).
#   T8   ServerStreamDecoder — compressed envelope (bit 0 set) yields
#        END_ERROR (compression is not supported).
#   T9   ClientStreamEncoder — encode N messages, drain in chunks; pending_bytes
#        reflects state correctly.
#   T10  ClientStreamEncoder — mark_close raises on subsequent encode_message.
#   T11  ClientStreamEncoder — is_drained_and_closed transitions correctly.
#   T12  BidiStreamCodec — encoder + decoder are independent; mutation of one
#        does not affect the other.
#   T13  Interleaved bidi — encode some, decode some, encode more, decode more
#        (the actual bidirectional pattern).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    ProtocolGrpcProto,
    ProtocolConnectProto,
    ServerStreamDecoder,
    ClientStreamEncoder,
    BidiStreamCodec,
    StreamOutcome,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_END_ERROR,
    GRPC_STATUS_OK,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_UNKNOWN,
    encode_stream_message,
)
from komira_connect.envelope import (
    write_envelope,
    ENVELOPE_FLAG_END_STREAM,
    ENVELOPE_FLAG_COMPRESSED,
)
from komira_connect.codec_connect_json import (
    build_connect_end_stream_json,
)
from komira_http_client.header_map import HeaderMap


# =============================================================================
# §1 — ServerStreamDecoder tests
# =============================================================================


def test_t1_empty_pending() raises:
    """T1 — empty decoder yields PENDING."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var o = d.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_PENDING, "PENDING")


def test_t2_grpc_server_stream_ok() raises:
    """T2 — classic-gRPC server-streaming: N messages + OK trailers."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    # Build wire: 3 enveloped messages
    var wire = List[UInt8]()
    var i = 0
    while i < 3:
        var msg = List[UInt8]()
        msg.append(UInt8(i + 1))
        msg.append(UInt8(i + 1))
        encode_stream_message[ProtocolGrpcProto](wire, Span(msg))
        i = i + 1
    d.feed(Span(wire))

    # Pop 3 messages
    var j = 0
    while j < 3:
        var o = d.try_next_message()
        assert_equal(o.kind, STREAM_OUTCOME_MESSAGE, "msg")
        assert_equal(len(o.message_bytes), 2, "2-byte payload")
        assert_equal(o.message_bytes[0], UInt8(j + 1), "byte")
        j = j + 1

    # Now PENDING (no more buffered)
    var o4 = d.try_next_message()
    assert_equal(o4.kind, STREAM_OUTCOME_PENDING, "PENDING after drain")

    # Feed OK trailers
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("0"))
    d.feed_trailers(tr)

    # Next try yields END_OK
    var o5 = d.try_next_message()
    assert_equal(o5.kind, STREAM_OUTCOME_END_OK, "END_OK")


def test_t3_grpc_server_stream_error() raises:
    """T3 — classic-gRPC trailers with non-OK status → END_ERROR."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("14"))
    tr.append(String("grpc-message"), String("upstream-unavailable"))
    d.feed_trailers(tr)
    var o = d.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_END_ERROR, "END_ERROR")
    assert_equal(o.error.code, GRPC_STATUS_UNAVAILABLE, "code 14")
    assert_equal(o.error.message, String("upstream-unavailable"), "msg")


def test_t4_connect_end_stream_ok() raises:
    """T4 — Connect END_STREAM with `{}` → END_OK."""
    var d = ServerStreamDecoder[ProtocolConnectProto].new()
    var empty_json = build_connect_end_stream_json(GRPC_STATUS_OK, String(""))
    # `{}` payload + END_STREAM flag
    var wire = List[UInt8]()
    write_envelope(wire, ENVELOPE_FLAG_END_STREAM, Span(empty_json))
    d.feed(Span(wire))
    var o = d.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_END_OK, "END_OK")


def test_t5_connect_end_stream_error() raises:
    """T5 — Connect END_STREAM with `{"error":{...}}` → END_ERROR."""
    var d = ServerStreamDecoder[ProtocolConnectProto].new()
    var err_json = build_connect_end_stream_json(
        GRPC_STATUS_NOT_FOUND, String("user 42 not found")
    )
    var wire = List[UInt8]()
    write_envelope(wire, ENVELOPE_FLAG_END_STREAM, Span(err_json))
    d.feed(Span(wire))
    var o = d.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_END_ERROR, "END_ERROR")
    assert_equal(o.error.code, GRPC_STATUS_NOT_FOUND, "NOT_FOUND")
    assert_equal(o.error.message, String("user 42 not found"), "msg")


def test_t6_fragmented_feed() raises:
    """T6 — fragmented Data feeds reconstruct envelope correctly."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var msg = List[UInt8]()
    for i in range(10):
        msg.append(UInt8(i))
    var wire = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](wire, Span(msg))
    # wire is 5+10 = 15 bytes. Feed in 3 chunks: 4, 5, 6 bytes.
    var c1 = List[UInt8]()
    for i in range(4):
        c1.append(wire[i])
    d.feed(Span(c1))
    assert_equal(
        d.try_next_message().kind, STREAM_OUTCOME_PENDING, "PENDING 1"
    )
    var c2 = List[UInt8]()
    for i in range(4, 9):
        c2.append(wire[i])
    d.feed(Span(c2))
    assert_equal(
        d.try_next_message().kind, STREAM_OUTCOME_PENDING, "PENDING 2"
    )
    var c3 = List[UInt8]()
    for i in range(9, 15):
        c3.append(wire[i])
    d.feed(Span(c3))
    var o = d.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_MESSAGE, "MESSAGE")
    assert_equal(len(o.message_bytes), 10, "10 bytes")


def test_t7_terminated_sticky() raises:
    """T7 — terminated state is sticky; subsequent calls yield END_OK."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("0"))
    d.feed_trailers(tr)
    var o1 = d.try_next_message()
    assert_equal(o1.kind, STREAM_OUTCOME_END_OK, "END_OK 1")
    var o2 = d.try_next_message()
    assert_equal(o2.kind, STREAM_OUTCOME_END_OK, "END_OK sticky 2")
    var o3 = d.try_next_message()
    assert_equal(o3.kind, STREAM_OUTCOME_END_OK, "END_OK sticky 3")


def test_t8_compressed_envelope_error() raises:
    """T8 — compressed envelope yields END_ERROR (compression is not
    supported)."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var msg = List[UInt8]()
    msg.append(UInt8(0xAA))
    var wire = List[UInt8]()
    write_envelope(wire, ENVELOPE_FLAG_COMPRESSED, Span(msg))
    d.feed(Span(wire))
    var o = d.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_END_ERROR, "END_ERROR")
    assert_equal(o.error.code, GRPC_STATUS_UNKNOWN, "UNKNOWN")


# =============================================================================
# §2 — ClientStreamEncoder tests
# =============================================================================


def test_t9_encoder_drain_chunks() raises:
    """T9 — encode N + drain in chunks."""
    var e = ClientStreamEncoder[ProtocolGrpcProto].new()
    # Encode 3 messages of 2 bytes each → each adds 5+2 = 7 bytes; total 21.
    var i = 0
    while i < 3:
        var m = List[UInt8]()
        m.append(UInt8(i + 1))
        m.append(UInt8(i + 1))
        e.encode_message(Span(m))
        i = i + 1
    assert_equal(e.pending_bytes(), 21, "3*(5+2) bytes pending")
    # Drain in chunks of 8 bytes (3 drains: 8, 8, 5)
    var c1 = e.drain_chunk(8)
    assert_equal(len(c1), 8, "first chunk 8 bytes")
    assert_equal(e.pending_bytes(), 13, "13 remaining")
    var c2 = e.drain_chunk(8)
    assert_equal(len(c2), 8, "second chunk 8 bytes")
    assert_equal(e.pending_bytes(), 5, "5 remaining")
    var c3 = e.drain_chunk(8)
    assert_equal(len(c3), 5, "third chunk 5 bytes")
    assert_equal(e.pending_bytes(), 0, "0 remaining")
    var c4 = e.drain_chunk(8)
    assert_equal(len(c4), 0, "empty drain")


def test_t10_encoder_close_send_then_encode_raises() raises:
    """T10 — encode_message after mark_close raises."""
    var e = ClientStreamEncoder[ProtocolGrpcProto].new()
    e.mark_close()
    assert_true(e.is_closed(), "is_closed")
    var raised = False
    try:
        var m = List[UInt8]()
        e.encode_message(Span(m))
    except _:
        raised = True
    assert_true(raised, "raised")


def test_t11_encoder_drained_closed_transition() raises:
    """T11 — is_drained_and_closed transitions correctly."""
    var e = ClientStreamEncoder[ProtocolGrpcProto].new()
    # Not closed and no bytes: is_drained_and_closed False.
    assert_false(e.is_drained_and_closed(), "not closed → False")
    # Encode, close: now have pending bytes but closed.
    var m = List[UInt8]()
    m.append(UInt8(0xFF))
    e.encode_message(Span(m))
    e.mark_close()
    assert_false(
        e.is_drained_and_closed(),
        "closed but with pending bytes → False",
    )
    # Drain all bytes.
    var _ = e.drain_chunk(1000)
    assert_true(e.is_drained_and_closed(), "closed + drained → True")


# =============================================================================
# §3 — BidiStreamCodec tests
# =============================================================================


def test_t12_bidi_halves_independent() raises:
    """T12 — encoder + decoder are independently-owned (no aliasing)."""
    var bidi = BidiStreamCodec[ProtocolGrpcProto].new()
    # Encode something on the request side
    var m = List[UInt8]()
    m.append(UInt8(0xAA))
    bidi.encoder.encode_message(Span(m))
    # The decoder is completely independent — empty / PENDING
    var o = bidi.decoder.try_next_message()
    assert_equal(o.kind, STREAM_OUTCOME_PENDING, "decoder unaffected")
    # The encoder has the pending bytes
    assert_equal(bidi.encoder.pending_bytes(), 6, "5+1 pending")


def test_t13_bidi_interleaved() raises:
    """T13 — interleaved bidi: encode, decode, encode, decode."""
    var bidi = BidiStreamCodec[ProtocolGrpcProto].new()
    # Encode message 1
    var m1 = List[UInt8]()
    m1.append(UInt8(0x01))
    bidi.encoder.encode_message(Span(m1))
    # Feed response 1 to decoder
    var r1 = List[UInt8]()
    r1.append(UInt8(0xA1))
    var wire1 = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](wire1, Span(r1))
    bidi.decoder.feed(Span(wire1))
    var d1 = bidi.decoder.try_next_message()
    assert_equal(d1.kind, STREAM_OUTCOME_MESSAGE, "MSG 1")
    assert_equal(d1.message_bytes[0], UInt8(0xA1), "byte A1")
    # Encode message 2
    var m2 = List[UInt8]()
    m2.append(UInt8(0x02))
    bidi.encoder.encode_message(Span(m2))
    # Feed response 2
    var r2 = List[UInt8]()
    r2.append(UInt8(0xA2))
    var wire2 = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](wire2, Span(r2))
    bidi.decoder.feed(Span(wire2))
    var d2 = bidi.decoder.try_next_message()
    assert_equal(d2.kind, STREAM_OUTCOME_MESSAGE, "MSG 2")
    assert_equal(d2.message_bytes[0], UInt8(0xA2), "byte A2")
    # close_send on encoder
    bidi.encoder.mark_close()
    # Drain ALL encoder bytes (caller will feed to wire)
    var enc_drain = bidi.encoder.drain_chunk(1000)
    # Two enveloped 1-byte messages: 2 * (5+1) = 12
    assert_equal(len(enc_drain), 12, "12 bytes drained")
    assert_true(bidi.encoder.is_drained_and_closed(), "encoder drained+closed")
    # Server's OK trailers
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("0"))
    bidi.decoder.feed_trailers(tr)
    var d3 = bidi.decoder.try_next_message()
    assert_equal(d3.kind, STREAM_OUTCOME_END_OK, "END_OK")


def main() raises:
    test_t1_empty_pending()
    test_t2_grpc_server_stream_ok()
    test_t3_grpc_server_stream_error()
    test_t4_connect_end_stream_ok()
    test_t5_connect_end_stream_error()
    test_t6_fragmented_feed()
    test_t7_terminated_sticky()
    test_t8_compressed_envelope_error()
    test_t9_encoder_drain_chunks()
    test_t10_encoder_close_send_then_encode_raises()
    test_t11_encoder_drained_closed_transition()
    test_t12_bidi_halves_independent()
    test_t13_bidi_interleaved()
    print("test_L5_stream: 13/13 PASS")
