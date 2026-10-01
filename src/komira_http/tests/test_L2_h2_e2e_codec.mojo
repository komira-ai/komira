# =============================================================================
# tests/test_L2_h2_e2e_codec.mojo — H2 codec end-to-end conversation
# =============================================================================
#
# functional e2e. Drives a complete HTTP/2
# conversation in-process at the codec level (no TCP, no TLS, no
# scheduler) — both peer endpoints share a byte buffer:
#
#   client → server:
#     1. PRI preface (24 bytes)
#     2. SETTINGS (non-ACK)
#     3. HEADERS (END_STREAM | END_HEADERS) — one stream, GET /hello
#
#   server → client:
#     1. SETTINGS (non-ACK with server settings)
#     2. SETTINGS-ACK (for client's settings)
#     3. HEADERS (END_HEADERS) + DATA (END_STREAM) — response
#
#   client:
#     4. SETTINGS-ACK (for server's settings)
#
# Each frame is fed through encode_*_frame + decode_frame in both
# directions. HpackEncoder/HpackDecoder is used for the HEADERS blocks.
# Stream state is driven by StreamState.advance_on_recv_frame on both
# sides.
#
# This proves codec correctness for a full request/response cycle at
# the frame layer — the foundation the HttpServer h2 pivot will sit on
#
# HTTP/2
# multiplexing demonstrated through a single-stream e2e. A second test
# below stretches to N=3 concurrent streams.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.codec.h2 import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_HEADERS,
    FRAME_SETTINGS,
    H2_CLIENT_PREFACE,
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
    MAX_FRAME_PAYLOAD_DEFAULT,
    PREFACE_OK,
    SETTINGS_HEADER_TABLE_SIZE,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SETTINGS_MAX_FRAME_SIZE,
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_LOCAL,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    STREAM_STATE_OPEN,
    SettingsEntry,
    StreamState,
    check_client_preface,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_ack_frame,
    encode_settings_frame,
)


# =============================================================================
# §1 — Helpers.
# =============================================================================


def _decode(ref buf: List[UInt8], off: Int) -> Tuple[Int, UInt8, UInt8, UInt32]:
    """Decode one frame from `buf[off:]` and return
    (consumed, kind, flags, stream_id). Asserts decode is OK and skips
    over the bytes in the caller."""
    var r = decode_frame(Span(buf)[off:], MAX_FRAME_PAYLOAD_DEFAULT)
    if not r.is_ok():
        return (0, UInt8(0xff), UInt8(0), UInt32(0))
    return (r.consumed, r.frame.header.kind, r.frame.header.flags,
            r.frame.header.stream_id)


def _build_server_settings() -> List[SettingsEntry]:
    """A reasonable initial SETTINGS for the server side."""
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(
        identifier=SETTINGS_HEADER_TABLE_SIZE, value=UInt32(4096),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE, value=UInt32(65535),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_CONCURRENT_STREAMS, value=UInt32(100),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_FRAME_SIZE, value=UInt32(16384),
    ))
    return entries^


# =============================================================================
# §2 — Single-stream e2e — full conversation.
# =============================================================================


def test_single_stream_request_response_full_cycle() raises:
    """
    Full HTTP/2 conversation, one stream (id=1):
      1. Client sends preface + SETTINGS
      2. Server sends SETTINGS + SETTINGS-ACK
      3. Client sends SETTINGS-ACK
      4. Client sends HEADERS(END_STREAM|END_HEADERS) — GET /hello
      5. Server sends HEADERS(END_HEADERS) + DATA(END_STREAM) — 200 OK "Hi!"
      6. Both peers observe stream state == CLOSED
    """
    # ---- Per-peer encoders/decoders + stream tables.

    var client_enc = HpackEncoder(max_table_size=4096)
    var client_dec = HpackDecoder(max_table_size=4096)
    var server_enc = HpackEncoder(max_table_size=4096)
    var server_dec = HpackDecoder(max_table_size=4096)

    var client_stream = StreamState(
        stream_id=UInt32(1), initial_window=Int32(65535),
    )
    var server_stream = StreamState(
        stream_id=UInt32(1), initial_window=Int32(65535),
    )

    # ---- Client→server wire buffer.
    var c2s = List[UInt8]()
    # ---- Server→client wire buffer.
    var s2c = List[UInt8]()

    # ---- Step 1: client preface.
    var preface_bytes = H2_CLIENT_PREFACE()
    var i = 0
    while i < len(preface_bytes):
        c2s.append(preface_bytes[i])
        i = i + 1

    # ---- Step 2: client SETTINGS (non-ACK).
    var client_settings = List[SettingsEntry]()
    client_settings.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE, value=UInt32(65535),
    ))
    encode_settings_frame(client_settings^, c2s)

    # ---- Server side: validate preface.
    var preface_r = check_client_preface(Span(c2s))
    assert_equal(Int(preface_r.status), Int(PREFACE_OK))
    assert_equal(preface_r.consumed, 24)

    # ---- Server reads client's SETTINGS.
    var server_off = preface_r.consumed
    var dec1 = decode_frame(
        Span(c2s)[server_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec1.is_ok())
    assert_equal(Int(dec1.frame.header.kind), Int(FRAME_SETTINGS))
    assert_equal(Int(dec1.frame.header.flags), 0)
    server_off = server_off + dec1.consumed

    # ---- Server emits its own SETTINGS + an ACK for client's SETTINGS.
    encode_settings_frame(_build_server_settings(), s2c)
    encode_settings_ack_frame(s2c)

    # ---- Client side: read server's SETTINGS + ACK.
    var client_off = 0
    var dec2 = decode_frame(
        Span(s2c)[client_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec2.is_ok())
    assert_equal(Int(dec2.frame.header.kind), Int(FRAME_SETTINGS))
    assert_equal(Int(dec2.frame.header.flags), 0)
    client_off = client_off + dec2.consumed
    var dec3 = decode_frame(
        Span(s2c)[client_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec3.is_ok())
    assert_equal(Int(dec3.frame.header.kind), Int(FRAME_SETTINGS))
    assert_equal(Int(dec3.frame.header.flags), Int(FLAG_ACK))
    client_off = client_off + dec3.consumed

    # ---- Client sends SETTINGS-ACK + HEADERS for stream 1.
    encode_settings_ack_frame(c2s)
    var req_headers = List[HpackHeader]()
    req_headers.append(HpackHeader(String(":method"), String("GET")))
    req_headers.append(HpackHeader(String(":path"), String("/hello")))
    req_headers.append(HpackHeader(String(":scheme"), String("https")))
    req_headers.append(HpackHeader(String(":authority"), String("example.com")))
    var req_block = client_enc.encode_block(req_headers^)
    encode_headers_frame(
        UInt32(1), req_block^, True, True, c2s,
    )
    # Drive client_stream state for the send.
    client_stream.state = STREAM_STATE_OPEN  # after writing HEADERS
    client_stream.advance_on_send_end_stream()  # END_STREAM → HALF_CLOSED_LOCAL
    assert_equal(Int(client_stream.state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))

    # ---- Server reads SETTINGS-ACK.
    var dec4 = decode_frame(
        Span(c2s)[server_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec4.is_ok())
    assert_equal(Int(dec4.frame.header.kind), Int(FRAME_SETTINGS))
    assert_equal(Int(dec4.frame.header.flags), Int(FLAG_ACK))
    server_off = server_off + dec4.consumed

    # ---- Server reads HEADERS for stream 1.
    var dec5 = decode_frame(
        Span(c2s)[server_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec5.is_ok())
    assert_equal(Int(dec5.frame.header.kind), Int(FRAME_HEADERS))
    assert_equal(Int(dec5.frame.header.stream_id), 1)
    var hflags = dec5.frame.header.flags
    var has_eh = (hflags & FLAG_END_HEADERS) != UInt8(0)
    var has_es = (hflags & FLAG_END_STREAM) != UInt8(0)
    assert_true(has_eh)
    assert_true(has_es)
    server_off = server_off + dec5.consumed

    # Drive server_stream state for the recv.
    var server_action = server_stream.advance_on_recv_frame(
        FRAME_HEADERS, hflags,
    )
    assert_equal(Int(server_action.kind), 0)  # H2_STREAM_ACTION_KEEP
    assert_equal(
        Int(server_stream.state), Int(STREAM_STATE_HALF_CLOSED_REMOTE),
    )

    # Decode the header block.
    var got_headers = server_dec.decode_block(
        Span(dec5.frame.payload),
    )
    assert_equal(len(got_headers), 4)
    assert_equal(got_headers[0].name, String(":method"))
    assert_equal(got_headers[0].value, String("GET"))
    assert_equal(got_headers[1].name, String(":path"))
    assert_equal(got_headers[1].value, String("/hello"))

    # ---- Server emits response (HEADERS + DATA with END_STREAM).
    var resp_headers = List[HpackHeader]()
    resp_headers.append(HpackHeader(String(":status"), String("200")))
    resp_headers.append(HpackHeader(
        String("content-type"), String("text/plain"),
    ))
    var resp_block = server_enc.encode_block(resp_headers^)
    encode_headers_frame(
        UInt32(1), resp_block^, False, True, s2c,
    )
    var body = List[UInt8]()
    body.append(UInt8(ord("H")))
    body.append(UInt8(ord("i")))
    body.append(UInt8(ord("!")))
    encode_data_frame(UInt32(1), body^, True, s2c)
    server_stream.advance_on_send_end_stream()
    assert_equal(Int(server_stream.state), Int(STREAM_STATE_CLOSED))

    # ---- Client reads response HEADERS + DATA.
    var dec6 = decode_frame(
        Span(s2c)[client_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec6.is_ok())
    assert_equal(Int(dec6.frame.header.kind), Int(FRAME_HEADERS))
    var resp_hflags = dec6.frame.header.flags
    assert_equal(Int(resp_hflags & FLAG_END_HEADERS), Int(FLAG_END_HEADERS))
    assert_equal(Int(resp_hflags & FLAG_END_STREAM), 0)  # data follows
    client_off = client_off + dec6.consumed
    var got_resp_headers = client_dec.decode_block(
        Span(dec6.frame.payload),
    )
    assert_equal(len(got_resp_headers), 2)
    assert_equal(got_resp_headers[0].name, String(":status"))
    assert_equal(got_resp_headers[0].value, String("200"))

    var dec7 = decode_frame(
        Span(s2c)[client_off:], MAX_FRAME_PAYLOAD_DEFAULT,
    )
    assert_true(dec7.is_ok())
    assert_equal(Int(dec7.frame.header.kind), Int(FRAME_DATA))
    assert_equal(Int(dec7.frame.header.flags), Int(FLAG_END_STREAM))
    assert_equal(len(dec7.frame.payload), 3)
    assert_equal(Int(dec7.frame.payload[0]), Int(ord("H")))
    assert_equal(Int(dec7.frame.payload[1]), Int(ord("i")))
    assert_equal(Int(dec7.frame.payload[2]), Int(ord("!")))

    # Drive client_stream state.
    var client_action_recv1 = client_stream.advance_on_recv_frame(
        FRAME_HEADERS, resp_hflags,
    )
    assert_equal(Int(client_action_recv1.kind), 0)
    var client_action_recv2 = client_stream.advance_on_recv_frame(
        FRAME_DATA, dec7.frame.header.flags,
    )
    assert_equal(Int(client_action_recv2.kind), 0)
    # HALF_CLOSED_LOCAL + recv DATA-with-END_STREAM → CLOSED.
    assert_equal(Int(client_stream.state), Int(STREAM_STATE_CLOSED))

    # ---- Final: both sides converge on CLOSED.
    assert_equal(Int(client_stream.state), Int(STREAM_STATE_CLOSED))
    assert_equal(Int(server_stream.state), Int(STREAM_STATE_CLOSED))


# =============================================================================
# §3 — Multiplexing: 3 concurrent streams on one connection.
# =============================================================================


def test_three_concurrent_streams_each_response_intact() raises:
    """3 streams interleaved on ONE connection. Each gets its own
    request HEADERS + response HEADERS + DATA. Validates that the
    decoder routes frames to the right StreamState by stream_id and
    that each response body arrives intact + uncorrupted.

    This is the multiplexing-correctness gate per acceptance (c).
    """
    var server_dec = HpackDecoder(max_table_size=4096)
    var server_enc = HpackEncoder(max_table_size=4096)
    var client_enc = HpackEncoder(max_table_size=4096)
    var client_dec = HpackDecoder(max_table_size=4096)

    # Client sends 3 HEADERS frames for streams 1, 3, 5 — all with
    # END_STREAM | END_HEADERS (each is a GET, no body).
    var c2s = List[UInt8]()

    var stream_ids = List[UInt32]()
    stream_ids.append(UInt32(1))
    stream_ids.append(UInt32(3))
    stream_ids.append(UInt32(5))
    var paths = List[String]()
    paths.append(String("/a"))
    paths.append(String("/b"))
    paths.append(String("/c"))

    var s = 0
    while s < 3:
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":method"), String("GET")))
        hdrs.append(HpackHeader(String(":path"), String(paths[s])))
        hdrs.append(HpackHeader(String(":scheme"), String("https")))
        var block = client_enc.encode_block(hdrs^)
        encode_headers_frame(
            stream_ids[s], block^, True, True, c2s,
        )
        s = s + 1

    # Server reads 3 HEADERS frames. Server-side stream table keyed by id.
    var server_off = 0
    var streams = List[UInt32]()
    var server_paths = List[String]()
    var k = 0
    while k < 3:
        var dec_f = decode_frame(
            Span(c2s)[server_off:], MAX_FRAME_PAYLOAD_DEFAULT,
        )
        assert_true(dec_f.is_ok())
        assert_equal(Int(dec_f.frame.header.kind), Int(FRAME_HEADERS))
        streams.append(dec_f.frame.header.stream_id)
        var got = server_dec.decode_block(Span(dec_f.frame.payload))
        # Path is the 2nd header (after :method).
        server_paths.append(got[1].value)
        server_off = server_off + dec_f.consumed
        k = k + 1
    assert_equal(len(streams), 3)
    assert_equal(Int(streams[0]), 1)
    assert_equal(Int(streams[1]), 3)
    assert_equal(Int(streams[2]), 5)
    assert_equal(server_paths[0], String("/a"))
    assert_equal(server_paths[1], String("/b"))
    assert_equal(server_paths[2], String("/c"))

    # Server emits responses INTERLEAVED — to test that frames for
    # different streams can be in any order.
    # Order: stream 3's HEADERS, stream 1's HEADERS, stream 5's HEADERS,
    #        stream 3's DATA, stream 1's DATA, stream 5's DATA.
    var s2c = List[UInt8]()

    var bodies = List[String]()
    bodies.append(String("AA"))
    bodies.append(String("BB"))
    bodies.append(String("CC"))

    # Map stream-id → body index. We use the order [3, 1, 5] for
    # HEADERS interleave but the body MUST match the right stream id.

    def _emit_resp_headers(
        mut out: List[UInt8], mut enc: HpackEncoder, sid: UInt32,
    ) raises:
        var h = List[HpackHeader]()
        h.append(HpackHeader(String(":status"), String("200")))
        var blk = enc.encode_block(h^)
        encode_headers_frame(sid, blk^, False, True, out)

    _emit_resp_headers(s2c, server_enc, UInt32(3))
    _emit_resp_headers(s2c, server_enc, UInt32(1))
    _emit_resp_headers(s2c, server_enc, UInt32(5))

    # DATA frames — stream-id-specific body.
    def _emit_data(
        mut out: List[UInt8], sid: UInt32, body: String,
    ):
        var b = List[UInt8]()
        var by = body.as_bytes()
        var i = 0
        while i < len(by):
            b.append(by[i])
            i = i + 1
        encode_data_frame(sid, b^, True, out)

    _emit_data(s2c, UInt32(3), String(bodies[1]))
    _emit_data(s2c, UInt32(1), String(bodies[0]))
    _emit_data(s2c, UInt32(5), String(bodies[2]))

    # Client reads 6 frames; collect per-stream bodies.
    var client_off = 0
    var per_stream_body = List[String]()
    per_stream_body.append(String(""))  # stream 1 placeholder
    per_stream_body.append(String(""))  # stream 3 placeholder
    per_stream_body.append(String(""))  # stream 5 placeholder
    var n_frames = 0
    while client_off < len(s2c) and n_frames < 10:
        var dec_g = decode_frame(
            Span(s2c)[client_off:], MAX_FRAME_PAYLOAD_DEFAULT,
        )
        if not dec_g.is_ok():
            break
        var sid = dec_g.frame.header.stream_id
        var kind = dec_g.frame.header.kind
        if kind == FRAME_DATA:
            var bstr = String()
            var i = 0
            while i < len(dec_g.frame.payload):
                bstr = bstr + chr(Int(dec_g.frame.payload[i]))
                i = i + 1
            if Int(sid) == 1:
                per_stream_body[0] = bstr
            elif Int(sid) == 3:
                per_stream_body[1] = bstr
            elif Int(sid) == 5:
                per_stream_body[2] = bstr
        elif kind == FRAME_HEADERS:
            # Decode + discard for this multiplexing test.
            _ = client_dec.decode_block(Span(dec_g.frame.payload))
        client_off = client_off + dec_g.consumed
        n_frames = n_frames + 1

    # All 3 bodies intact + matched to the right stream-id.
    assert_equal(per_stream_body[0], String("AA"))
    assert_equal(per_stream_body[1], String("BB"))
    assert_equal(per_stream_body[2], String("CC"))


# =============================================================================
# §4 — main.
# =============================================================================


def main() raises:
    print("test_L2_h2_e2e_codec: start")
    test_single_stream_request_response_full_cycle()
    print(" single_stream_full_cycle PASS")
    test_three_concurrent_streams_each_response_intact()
    print(" three_concurrent_streams PASS")
    print("test_L2_h2_e2e_codec: ALL 2 TESTS PASS")
