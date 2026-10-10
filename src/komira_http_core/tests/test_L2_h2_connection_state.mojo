# =============================================================================
# tests/test_L2_h2_connection_state.mojo — per-connection HTTP/2 state
# =============================================================================
#
# L2 unit tests of `codec/h2/connection_state.mojo`, the container a server
# connection owns once ALPN picks h2. Every method is driven and its exact
# result asserted:
#   * construction: every field's initial value (stream 1 expected first,
#     RFC 9113 §5.1.1; 16384-byte frames, §6.5.2; 4096-byte HPACK tables);
#   * the lifecycle flags: each mark sets its own bit and no other;
#   * the HEADERS/CONTINUATION reassembly ceilings (CVE-2024-27316 shape):
#     64 frames and 65536 bytes are accepted, one more is refused and the
#     buffer is left as it was; reset clears the block and its counter;
#   * the inbound and outbound byte queues: order, the consume edge cases
#     (n <= 0, n == len, n > len), prepend overtaking queued frames but
#     not the pinned prefix;
#   * the stream list: lookup, create-once, the windows a new stream takes
#     from the flow controllers, the GOAWAY last-stream-id high-water mark;
#   * the deferred-response and pending-request side tables: absent-entry
#     answers, chunked draining with the residual and offset, gRPC trailer
#     fields, removal from the middle of the table.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2 import (
    H2_CONN_FLAG_GOAWAY_SENT,
    H2_CONN_FLAG_PEER_SETTINGS_ACK,
    H2_CONN_FLAG_PREFACE_OK,
    H2_CONN_FLAG_SETTINGS_SENT,
    H2ConnectionState,
    HpackHeader,
    STREAM_STATE_IDLE,
)
from komira_http_core.codec.h2.connection_state import (
    H2_CONN_FLAG_GOAWAY_RECEIVED,
    H2_MAX_HEADER_BLOCK_BYTES,
    H2_MAX_HEADER_BLOCK_FRAMES,
)


# =============================================================================
# Helpers.
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    var view = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(view)):
        out.append(view[i])
    return out^


def _filled(n: Int, v: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(v)
    return out^


def _heap_string(unit: String, count: Int) -> String:
    """A String built at run time, so it owns heap storage (a literal does
    not), exercising the owned-storage paths of copy and destroy."""
    var out = String()
    for _ in range(count):
        out += unit
    return out^


def _assert_bytes(got: List[UInt8], want: String, what: String) raises:
    var w = want.as_bytes()
    assert_equal(len(got), len(w), what + ": length")
    for i in range(len(w)):
        assert_equal(Int(got[i]), Int(w[i]), what + ": byte " + String(i))


# =============================================================================
# §1 — construction.
# =============================================================================


def test_init_defaults() raises:
    var h2 = H2ConnectionState()
    assert_equal(h2.hpack_encoder.table.max_size, 4096)
    assert_equal(h2.hpack_decoder.table.max_size, 4096)
    assert_equal(len(h2.streams), 0)
    assert_equal(len(h2.recv_buf), 0)
    assert_equal(len(h2.pending_out), 0)
    assert_equal(h2.max_frame_size_peer, 16384)
    assert_equal(h2.max_frame_size_local, 16384)
    assert_equal(Int(h2.max_concurrent_streams_peer), 100)
    assert_equal(Int(h2.next_expected_stream_id), 1)
    assert_equal(Int(h2.last_processed_stream_id), 0)
    assert_equal(Int(h2.flags), 0)
    assert_equal(Int(h2.goaway_error_code), 0)
    assert_equal(Int(h2.cont_reasm_stream_id), 0)
    assert_equal(len(h2.cont_reasm_buf), 0)
    assert_equal(h2.cont_reasm_frames, 0)
    assert_equal(h2._slab_len_deferred(), 0)
    assert_equal(h2._slab_len_pending(), 0)
    assert_false(h2.is_preface_ok())
    assert_false(h2.is_settings_sent())
    assert_false(h2.is_goaway_sent())
    assert_false(h2.is_goaway_received())


# =============================================================================
# §2 — lifecycle flags: one bit each.
# =============================================================================


def test_flag_values_are_distinct_bits() raises:
    assert_equal(Int(H2_CONN_FLAG_PREFACE_OK), 1)
    assert_equal(Int(H2_CONN_FLAG_SETTINGS_SENT), 2)
    assert_equal(Int(H2_CONN_FLAG_PEER_SETTINGS_ACK), 4)
    assert_equal(Int(H2_CONN_FLAG_GOAWAY_SENT), 8)
    assert_equal(Int(H2_CONN_FLAG_GOAWAY_RECEIVED), 16)


def test_mark_preface_ok_sets_only_its_bit() raises:
    var h2 = H2ConnectionState()
    h2.mark_preface_ok()
    assert_equal(Int(h2.flags), 1)
    assert_true(h2.is_preface_ok())
    assert_false(h2.is_settings_sent())
    assert_false(h2.is_goaway_sent())
    assert_false(h2.is_goaway_received())


def test_mark_settings_sent_sets_only_its_bit() raises:
    var h2 = H2ConnectionState()
    h2.mark_settings_sent()
    assert_equal(Int(h2.flags), 2)
    assert_true(h2.is_settings_sent())
    assert_false(h2.is_preface_ok())
    assert_false(h2.is_goaway_sent())
    assert_false(h2.is_goaway_received())


def test_mark_goaway_sent_records_code_and_bit() raises:
    var h2 = H2ConnectionState()
    h2.mark_goaway_sent(UInt32(0xB))
    assert_equal(Int(h2.flags), 8)
    assert_equal(Int(h2.goaway_error_code), 0xB)
    assert_true(h2.is_goaway_sent())
    assert_false(h2.is_preface_ok())
    assert_false(h2.is_settings_sent())
    assert_false(h2.is_goaway_received())


def test_mark_goaway_received_sets_only_its_bit() raises:
    var h2 = H2ConnectionState()
    h2.mark_goaway_received()
    assert_equal(Int(h2.flags), 16)
    assert_true(h2.is_goaway_received())
    assert_false(h2.is_goaway_sent())
    assert_false(h2.is_preface_ok())
    assert_false(h2.is_settings_sent())
    # A received GOAWAY records no error code of ours.
    assert_equal(Int(h2.goaway_error_code), 0)


def test_marks_accumulate() raises:
    """Marks OR into the bitset: a later mark keeps the earlier bits."""
    var h2 = H2ConnectionState()
    h2.mark_preface_ok()
    h2.mark_settings_sent()
    h2.mark_goaway_received()
    h2.mark_goaway_sent(UInt32(1))
    assert_equal(Int(h2.flags), 1 | 2 | 8 | 16)
    assert_true(h2.is_preface_ok())
    assert_true(h2.is_settings_sent())
    assert_true(h2.is_goaway_sent())
    assert_true(h2.is_goaway_received())


# =============================================================================
# §3 — header-block reassembly ceilings.
# =============================================================================


def test_append_header_block_accumulates() raises:
    var h2 = H2ConnectionState()
    var a = _bytes("abc")
    var b = _bytes("de")
    assert_true(h2.append_header_block(Span(a)))
    assert_true(h2.append_header_block(Span(b)))
    _assert_bytes(h2.cont_reasm_buf, "abcde", "reasm buf")
    assert_equal(h2.cont_reasm_frames, 2)


def test_frame_ceiling_accepts_64_refuses_65th() raises:
    """Empty CONTINUATIONs add no bytes; the frame count alone bounds them.
    Frame 64 is accepted, frame 65 refused, the buffer untouched."""
    assert_equal(H2_MAX_HEADER_BLOCK_FRAMES, 64)
    var h2 = H2ConnectionState()
    var one = _bytes("x")
    var empty = List[UInt8]()
    assert_true(h2.append_header_block(Span(one)))
    for i in range(2, 65):
        assert_true(
            h2.append_header_block(Span(empty)),
            "frame " + String(i) + " must be accepted",
        )
    assert_equal(h2.cont_reasm_frames, 64)
    assert_false(h2.append_header_block(Span(one)), "frame 65 must be refused")
    _assert_bytes(h2.cont_reasm_buf, "x", "buffer after refusal")
    # The refused frame is still counted: every later frame stays refused.
    assert_equal(h2.cont_reasm_frames, 65)
    assert_false(h2.append_header_block(Span(empty)))


def test_byte_ceiling_exact_boundary() raises:
    """65536 bytes in total is accepted; one byte more is refused and the
    buffer keeps exactly what it had."""
    assert_equal(H2_MAX_HEADER_BLOCK_BYTES, 65536)
    var h2 = H2ConnectionState()
    var first = _filled(65535, UInt8(0x41))
    var last = _filled(1, UInt8(0x42))
    assert_true(h2.append_header_block(Span(first)))
    assert_true(h2.append_header_block(Span(last)), "exactly 65536 accepted")
    assert_equal(len(h2.cont_reasm_buf), 65536)
    assert_equal(Int(h2.cont_reasm_buf[65535]), 0x42)
    var extra = _filled(1, UInt8(0x43))
    assert_false(h2.append_header_block(Span(extra)), "65537 refused")
    assert_equal(len(h2.cont_reasm_buf), 65536)
    assert_equal(Int(h2.cont_reasm_buf[65535]), 0x42)


def test_byte_ceiling_single_oversize_frame() raises:
    var h2 = H2ConnectionState()
    var big = _filled(65537, UInt8(0))
    assert_false(h2.append_header_block(Span(big)))
    assert_equal(len(h2.cont_reasm_buf), 0)


def test_reset_header_block_clears_block_and_counter() raises:
    var h2 = H2ConnectionState()
    h2.cont_reasm_stream_id = UInt32(7)
    var empty = List[UInt8]()
    var a = _bytes("hdr")
    assert_true(h2.append_header_block(Span(a)))
    for _ in range(63):
        _ = h2.append_header_block(Span(empty))
    h2.reset_header_block()
    assert_equal(Int(h2.cont_reasm_stream_id), 0)
    assert_equal(len(h2.cont_reasm_buf), 0)
    assert_equal(h2.cont_reasm_frames, 0)
    # A fresh block has its full budget again.
    for _ in range(64):
        assert_true(h2.append_header_block(Span(empty)))
    assert_false(h2.append_header_block(Span(empty)))


# =============================================================================
# §4 — inbound and outbound byte queues.
# =============================================================================


def test_recv_bytes_append_and_consume() raises:
    var h2 = H2ConnectionState()
    var a = _bytes("hello")
    var b = _bytes("world")
    h2.append_recv_bytes(Span(a))
    h2.append_recv_bytes(Span(b))
    _assert_bytes(h2.recv_buf, "helloworld", "after append")
    h2.consume_recv_bytes(0)
    _assert_bytes(h2.recv_buf, "helloworld", "consume 0 is a no-op")
    h2.consume_recv_bytes(-1)
    _assert_bytes(h2.recv_buf, "helloworld", "consume -1 is a no-op")
    h2.consume_recv_bytes(3)
    _assert_bytes(h2.recv_buf, "loworld", "consume 3")
    h2.consume_recv_bytes(6)
    _assert_bytes(h2.recv_buf, "d", "consume 6 of 7")
    h2.consume_recv_bytes(1)
    assert_equal(len(h2.recv_buf), 0, "consume exactly the rest")


def test_recv_bytes_consume_more_than_buffered() raises:
    var h2 = H2ConnectionState()
    var a = _bytes("abc")
    h2.append_recv_bytes(Span(a))
    h2.consume_recv_bytes(10)
    assert_equal(len(h2.recv_buf), 0)
    # The emptied buffer still accepts bytes.
    var b = _bytes("z")
    h2.append_recv_bytes(Span(b))
    _assert_bytes(h2.recv_buf, "z", "after refill")


def test_out_bytes_append_prepend_take() raises:
    var h2 = H2ConnectionState()
    h2.prepend_out_bytes(_bytes("P0"))
    _assert_bytes(h2.pending_out, "P0", "prepend onto empty")
    h2.append_out_bytes(_bytes("A1"))
    h2.append_out_bytes(_bytes("A2"))
    _assert_bytes(h2.pending_out, "P0A1A2", "appends go to the back")
    h2.prepend_out_bytes(_bytes("RST"))
    _assert_bytes(h2.pending_out, "RSTP0A1A2", "prepend overtakes the queue")
    var out = h2.take_out_bytes()
    _assert_bytes(out, "RSTP0A1A2", "take returns the whole queue")
    assert_equal(len(h2.pending_out), 0, "take empties the queue")
    var again = h2.take_out_bytes()
    assert_equal(len(again), 0, "take of an empty queue")
    h2.append_out_bytes(_bytes("B"))
    _assert_bytes(h2.pending_out, "B", "append after take")
    h2.prepend_out_bytes(List[UInt8]())
    _assert_bytes(h2.pending_out, "B", "empty prepend")


def test_prepend_goes_behind_the_pinned_prefix() raises:
    """A pinned prefix (the server preface, an unwritten tail) is never
    overtaken: prepends go in right behind it, the last one first. Bytes
    appended after the pin are overtaken as before. Take clears the pin."""
    var h2 = H2ConnectionState()
    assert_equal(h2.out_pinned, 0)
    h2.append_out_bytes(_bytes("SET"))
    h2.pin_out_bytes()
    assert_equal(h2.out_pinned, 3)
    h2.append_out_bytes(_bytes("A1"))
    h2.prepend_out_bytes(_bytes("RST"))
    h2.prepend_out_bytes(_bytes("GO"))
    _assert_bytes(h2.pending_out, "SETGORSTA1", "prepends go behind the pin")
    var out = h2.take_out_bytes()
    _assert_bytes(out, "SETGORSTA1", "take returns the whole queue")
    assert_equal(h2.out_pinned, 0, "take clears the pin")
    h2.append_out_bytes(_bytes("B"))
    h2.prepend_out_bytes(_bytes("P"))
    _assert_bytes(h2.pending_out, "PB", "no pin after take")


# =============================================================================
# §5 — the stream list.
# =============================================================================


def test_stream_lookup_and_create_once() raises:
    var h2 = H2ConnectionState()
    assert_equal(h2.find_stream_idx(UInt32(1)), -1)
    assert_false(h2.has_stream(UInt32(1)))
    assert_true(h2.get_or_create_stream(UInt32(1)))
    assert_true(h2.get_or_create_stream(UInt32(3)))
    assert_true(h2.get_or_create_stream(UInt32(5)))
    assert_equal(len(h2.streams), 3)
    assert_equal(h2.find_stream_idx(UInt32(1)), 0)
    assert_equal(h2.find_stream_idx(UInt32(3)), 1)
    assert_equal(h2.find_stream_idx(UInt32(5)), 2)
    assert_equal(h2.find_stream_idx(UInt32(7)), -1)
    assert_true(h2.has_stream(UInt32(5)))
    assert_false(h2.has_stream(UInt32(7)))
    # A second create of a known id adds nothing.
    assert_false(h2.get_or_create_stream(UInt32(3)))
    assert_equal(len(h2.streams), 3)
    assert_equal(Int(h2.streams[1].stream_id), 3)
    assert_equal(Int(h2.streams[1].state), Int(STREAM_STATE_IDLE))


def test_new_stream_windows_come_from_flow_controllers() raises:
    """send_window takes the PEER's SETTINGS_INITIAL_WINDOW_SIZE (send_fc),
    recv_window ours (recv_fc); distinct values catch a swap."""
    var h2 = H2ConnectionState()
    assert_true(h2.get_or_create_stream(UInt32(1)))
    assert_equal(Int(h2.streams[0].send_window), 65535)
    assert_equal(Int(h2.streams[0].recv_window), 65535)
    h2.send_fc.initial_window_size = UInt32(1000)
    h2.recv_fc.initial_recv_window = UInt32(2000)
    assert_true(h2.get_or_create_stream(UInt32(3)))
    assert_equal(Int(h2.streams[1].send_window), 1000)
    assert_equal(Int(h2.streams[1].recv_window), 2000)
    # An existing stream is not re-initialised.
    assert_false(h2.get_or_create_stream(UInt32(1)))
    assert_equal(Int(h2.streams[0].send_window), 65535)


def test_last_processed_stream_id_is_high_water_mark() raises:
    var h2 = H2ConnectionState()
    assert_true(h2.get_or_create_stream(UInt32(5)))
    assert_equal(Int(h2.last_processed_stream_id), 5)
    assert_true(h2.get_or_create_stream(UInt32(3)))
    assert_equal(Int(h2.last_processed_stream_id), 5, "a lower id keeps it")
    assert_true(h2.get_or_create_stream(UInt32(9)))
    assert_equal(Int(h2.last_processed_stream_id), 9)
    assert_false(h2.get_or_create_stream(UInt32(9)))
    assert_equal(Int(h2.last_processed_stream_id), 9)


# =============================================================================
# §6 — deferred-response side table.
# =============================================================================


def test_deferred_absent_answers() raises:
    var h2 = H2ConnectionState()
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(1))), -1)
    assert_equal(h2.deferred_response_grpc_trailer_message(UInt32(1)), "")
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 0)
    assert_false(h2.deferred_response_sends_end_stream(UInt32(1)))
    var chunk = h2.take_deferred_response_body_chunk(UInt32(1), 4)
    assert_equal(len(chunk), 0)
    h2.drop_deferred_response(UInt32(1))
    assert_equal(h2._slab_len_deferred(), 0)


def test_deferred_plain_push_and_drain() raises:
    var h2 = H2ConnectionState()
    h2.push_deferred_response(UInt32(1), _bytes("0123456789"), 7, True)
    h2.push_deferred_response(UInt32(3), _bytes("xy"), 0, False)
    assert_equal(h2._slab_len_deferred(), 2)
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), 0)
    assert_equal(h2.find_deferred_response_idx(UInt32(3)), 1)
    assert_equal(h2.find_deferred_response_idx(UInt32(5)), -1)
    # An ordinary deferred body carries no gRPC trailer.
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(1))), -1)
    assert_equal(h2.deferred_response_grpc_trailer_message(UInt32(1)), "")
    assert_true(h2.deferred_response_sends_end_stream(UInt32(1)))
    assert_false(h2.deferred_response_sends_end_stream(UInt32(3)))
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 10)
    assert_equal(h2.deferred_response_body_len(UInt32(3)), 2)

    var c1 = h2.take_deferred_response_body_chunk(UInt32(1), 4)
    _assert_bytes(c1, "0123", "first chunk")
    _assert_bytes(h2.deferred_responses[0].body, "456789", "residual")
    assert_equal(h2.deferred_responses[0].offset, 11)
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 6)
    # The other stream's entry is untouched.
    _assert_bytes(h2.deferred_responses[1].body, "xy", "other entry")

    # n past the residual is clamped to it.
    var c2 = h2.take_deferred_response_body_chunk(UInt32(1), 100)
    _assert_bytes(c2, "456789", "clamped chunk")
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 0)
    assert_equal(h2.deferred_responses[0].offset, 17)
    # Draining leaves the entry in place until it is dropped.
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), 0)
    var c3 = h2.take_deferred_response_body_chunk(UInt32(1), 4)
    assert_equal(len(c3), 0)
    assert_equal(h2.deferred_responses[0].offset, 17)


def test_deferred_grpc_push_fields() raises:
    var h2 = H2ConnectionState()
    h2.push_deferred_grpc_response(
        UInt32(5), _bytes("msg"), UInt8(13), String("internal"),
    )
    h2.push_deferred_grpc_response(
        UInt32(7), _bytes(""), UInt8(255), String(""),
    )
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(5))), 13)
    assert_equal(h2.deferred_response_grpc_trailer_message(UInt32(5)), "internal")
    # The trailer carries END_STREAM, the final DATA chunk does not.
    assert_false(h2.deferred_response_sends_end_stream(UInt32(5)))
    assert_equal(h2.deferred_responses[0].offset, 0)
    assert_equal(h2.deferred_response_body_len(UInt32(5)), 3)
    # The whole UInt8 range is a status, none of it the -1 sentinel.
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(7))), 255)
    assert_equal(h2.deferred_response_grpc_trailer_message(UInt32(7)), "")
    # A message built at run time (heap storage, not a static literal) and
    # too long for a String's inline storage is kept whole.
    var long_msg = String("deadline exceeded ")
    long_msg += "while draining the residual body"
    h2.push_deferred_grpc_response(UInt32(9), _bytes("z"), UInt8(4), long_msg)
    assert_equal(
        h2.deferred_response_grpc_trailer_message(UInt32(9)),
        "deadline exceeded while draining the residual body",
    )
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(9))), 4)


def test_deferred_drop_from_middle() raises:
    var h2 = H2ConnectionState()
    h2.push_deferred_response(UInt32(1), _bytes("a"), 0, True)
    h2.push_deferred_response(UInt32(3), _bytes("bb"), 0, False)
    h2.push_deferred_grpc_response(
        UInt32(5), _bytes("ccc"), UInt8(2), _heap_string("m", 40),
    )
    h2.drop_deferred_response(UInt32(9))
    assert_equal(h2._slab_len_deferred(), 3, "dropping an absent id")
    h2.drop_deferred_response(UInt32(1))
    assert_equal(h2._slab_len_deferred(), 2)
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 0)
    # The survivors keep their own data wherever they now sit.
    assert_equal(h2.deferred_response_body_len(UInt32(3)), 2)
    assert_equal(h2.deferred_response_body_len(UInt32(5)), 3)
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(5))), 2)
    assert_equal(h2.deferred_response_grpc_trailer_message(UInt32(5)), "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm")
    assert_equal(Int(h2.deferred_response_grpc_trailer_status(UInt32(3))), -1)
    # An entry whose heap message nothing else shares is dropped whole.
    h2.push_deferred_grpc_response(
        UInt32(11), _bytes("d"), UInt8(1), _heap_string("n", 30),
    )
    assert_equal(h2._slab_len_deferred(), 3)
    h2.drop_deferred_response(UInt32(11))
    assert_equal(h2._slab_len_deferred(), 2)
    assert_equal(h2.find_deferred_response_idx(UInt32(11)), -1)
    # A copy of the message taken before the drop outlives the entry.
    var kept = h2.deferred_response_grpc_trailer_message(UInt32(5))
    h2.drop_deferred_response(UInt32(5))
    assert_equal(kept.byte_length(), 40)
    assert_equal(kept, String("mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm"))
    h2.drop_deferred_response(UInt32(3))
    assert_equal(h2._slab_len_deferred(), 0)


# =============================================================================
# §7 — pending-request side table.
# =============================================================================


def _headers() -> List[HpackHeader]:
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String(":method"), String("POST")))
    hs.append(HpackHeader(String(":path"), String("/svc/M")))
    return hs^


def test_pending_push_defaults_and_explicit() raises:
    var h2 = H2ConnectionState()
    assert_equal(h2.find_pending_request_idx(UInt32(1)), -1)
    h2.push_pending_request(UInt32(1), _headers(), String("POST"), String("/a"))
    h2.push_pending_request(
        UInt32(3),
        List[HpackHeader](),
        String("GET"),
        String("/b"),
        String("application/grpc"),
        UInt64(123456789),
    )
    assert_equal(h2._slab_len_pending(), 2)
    assert_equal(h2.find_pending_request_idx(UInt32(1)), 0)
    assert_equal(h2.find_pending_request_idx(UInt32(3)), 1)
    assert_equal(h2.find_pending_request_idx(UInt32(5)), -1)
    ref p1 = h2.pending_requests[0]
    assert_equal(p1.content_type, "")
    assert_equal(Int(p1.arrival_ns), 0)
    assert_equal(len(p1.body), 0)
    ref p3 = h2.pending_requests[1]
    assert_equal(p3.content_type, "application/grpc")
    assert_equal(Int(p3.arrival_ns), 123456789)
    assert_equal(p3.method_str, "GET")
    assert_equal(p3.path_str, "/b")


def test_pending_body_appends_in_order() raises:
    var h2 = H2ConnectionState()
    h2.push_pending_request(UInt32(1), _headers(), String("POST"), String("/a"))
    h2.push_pending_request(UInt32(3), _headers(), String("POST"), String("/b"))
    var a = _bytes("abc")
    var b = _bytes("de+hi")
    var other = _bytes("Q")
    h2.append_pending_request_body(UInt32(1), Span(a))
    h2.append_pending_request_body(UInt32(3), Span(other))
    h2.append_pending_request_body(UInt32(1), Span(b))
    _assert_bytes(h2.pending_requests[0].body, "abcde+hi", "s1")
    _assert_bytes(h2.pending_requests[1].body, "Q", "s3")
    # A stream with no pending entry discards its DATA: nothing is created.
    h2.append_pending_request_body(UInt32(9), Span(other))
    assert_equal(h2._slab_len_pending(), 2)
    _assert_bytes(h2.pending_requests[0].body, "abcde+hi", "s1")
    _assert_bytes(h2.pending_requests[1].body, "Q", "s3")


def test_take_pending_request_present_and_absent() raises:
    var h2 = H2ConnectionState()
    h2.push_pending_request(UInt32(1), _headers(), String("POST"), String("/a"))
    h2.push_pending_request(
        UInt32(3), _headers(), String("PUT"), String("/b"),
        String("application/grpc+proto"), UInt64(42),
    )
    var body = _bytes("payload")
    h2.append_pending_request_body(UInt32(3), Span(body))

    var miss = h2.take_pending_request(UInt32(7))
    assert_equal(Int(miss.stream_id), 0)
    assert_equal(len(miss.headers), 0)
    assert_equal(miss.method_str, "")
    assert_equal(miss.path_str, "")
    assert_equal(len(miss.body), 0)
    assert_equal(miss.content_type, "")
    assert_equal(Int(miss.arrival_ns), 0)
    assert_equal(h2._slab_len_pending(), 2, "a miss removes nothing")

    var got = h2.take_pending_request(UInt32(3))
    assert_equal(Int(got.stream_id), 3)
    assert_equal(len(got.headers), 2)
    assert_equal(got.headers[0].name, ":method")
    assert_equal(got.headers[1].value, "/svc/M")
    assert_equal(got.method_str, "PUT")
    assert_equal(got.path_str, "/b")
    _assert_bytes(got.body, "payload", "taken body")
    assert_equal(got.content_type, "application/grpc+proto")
    assert_equal(Int(got.arrival_ns), 42)
    assert_equal(h2._slab_len_pending(), 1)
    assert_equal(h2.find_pending_request_idx(UInt32(3)), -1)
    assert_equal(h2.find_pending_request_idx(UInt32(1)), 0)

    var first = h2.take_pending_request(UInt32(1))
    assert_equal(Int(first.stream_id), 1)
    assert_equal(first.method_str, "POST")
    assert_equal(first.path_str, "/a")
    assert_equal(h2._slab_len_pending(), 0)


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("test_L2_h2_connection_state: start")
    test_init_defaults()
    test_flag_values_are_distinct_bits()
    test_mark_preface_ok_sets_only_its_bit()
    test_mark_settings_sent_sets_only_its_bit()
    test_mark_goaway_sent_records_code_and_bit()
    test_mark_goaway_received_sets_only_its_bit()
    test_marks_accumulate()
    test_append_header_block_accumulates()
    test_frame_ceiling_accepts_64_refuses_65th()
    test_byte_ceiling_exact_boundary()
    test_byte_ceiling_single_oversize_frame()
    test_reset_header_block_clears_block_and_counter()
    test_recv_bytes_append_and_consume()
    test_recv_bytes_consume_more_than_buffered()
    test_out_bytes_append_prepend_take()
    test_prepend_goes_behind_the_pinned_prefix()
    test_stream_lookup_and_create_once()
    test_new_stream_windows_come_from_flow_controllers()
    test_last_processed_stream_id_is_high_water_mark()
    test_deferred_absent_answers()
    test_deferred_plain_push_and_drain()
    test_deferred_grpc_push_fields()
    test_deferred_drop_from_middle()
    test_pending_push_defaults_and_explicit()
    test_pending_body_appends_in_order()
    test_take_pending_request_present_and_absent()
    print("test_L2_h2_connection_state: PASS (26 tests)")
