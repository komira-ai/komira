"""L2 byte-level h2 request/response cycle.

Drives the h2 client encoder + decoder paths via raw bytes (no TCP):
  1. Build H2ClientConnectionState; allocate odd stream id; encode
     request headers + (optional) body → pending_out.
  2. Take the bytes from pending_out, route them into a SECOND
     H2ClientConnectionState's recv_buf as if it were the peer.
  3. The receiving side process_received_frames decodes the request
     bytes — but our PEER is the server, which is a separate codec
     surface. So instead, we synthesize SERVER-shaped response frames
     manually via encode_headers_frame + encode_data_frame, route the
     bytes back into the CLIENT's recv_buf, then process_received_frames
     decodes them and populates response_header_lists[idx] +
     response_body_buffers[idx] for the original stream.
  4. extract_response_for_stream returns the (status, headers, body)
     tuple — the gate (a)/(b) acceptance proof.

Tests in this file:
  * basic GET request → 200 OK + body (single HEADERS + single DATA)
  * HEADERS reassembly with simulated multi-frame block (HEADERS + CONTINUATION)
  * multi-stream interleaved (3 streams; responses arrive interleaved)
  * inbound SETTINGS frame from peer → ACK is staged
"""


from komira_http_client.h2_client import (
    H2ClientConnectionState,
    apply_peer_settings_and_ack,
    encode_request_data_frame,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http_client.header_map import HeaderMap
from komira_http_core.codec.h2.continuation_splitter import (
    split_header_block_into_frames,
)
from komira_http_core.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DECODE_OK,
    FRAME_HEADERS,
    FRAME_SETTINGS,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader


def _build_response_bytes(
    mut server_encoder: HpackEncoder,
    stream_id: UInt32,
    status_str: String,
    var content_type: String,
    var body: List[UInt8],
) -> List[UInt8]:
    """Synthesize the server's response: HEADERS (END_HEADERS) + DATA
    (END_STREAM). Single-frame; for multi-frame use the splitter test
    helper below.

    The HpackEncoder for the server is SEPARATE from the client's; both
    maintain independent dynamic tables.
    """
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), status_str))
    hdrs.append(HpackHeader(
        String("content-length"), String(Int(len(body))),
    ))
    hdrs.append(HpackHeader(String("content-type"), content_type^))
    var block = server_encoder.encode_block(hdrs^)
    var body_is_empty = len(body) == 0
    var out = List[UInt8]()
    encode_headers_frame(
        stream_id,
        block^,
        body_is_empty,  # end_stream on HEADERS if no body
        True,           # end_headers
        out,
    )
    if not body_is_empty:
        encode_data_frame(stream_id, body^, True, out)
    return out^


def test_basic_get_request_response_round_trip() raises:
    """Client encodes GET / HEADERS frame; server-style response with
    200 OK + 5-byte body bytes is fed into client recv_buf;
    process_received_frames decodes; extract_response_for_stream returns
    the right tuple."""
    print("  test_basic_get_request_response_round_trip...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    # Discard the staged preface+SETTINGS bytes; we're not driving a
    # peer-side decoder in this test.
    _ = client.take_out_bytes()

    # Allocate stream + create state.
    var sid = client.allocate_client_stream_id()
    _ = client.create_stream(sid)

    # Encode request headers.
    var req_headers = HeaderMap()
    req_headers.append(String("accept"), String("*/*"))
    req_headers.append(String("user-agent"), String("komira-http/1.0"))
    encode_request_headers_to_frames(
        client,
        sid,
        String("GET"),
        String("https"),
        String("example.com"),
        String("/hello"),
        req_headers^,
        True,  # end_stream — GET has no body
    )
    # Verify the client's outbound is a HEADERS frame on `sid`.
    var req_bytes = client.take_out_bytes()
    var req_decoded = decode_frame(Span(req_bytes), 16384)
    if req_decoded.status != FRAME_DECODE_OK:
        raise Error("client request HEADERS did not decode OK")
    if req_decoded.frame.header.kind != FRAME_HEADERS:
        raise Error("expected HEADERS frame; got kind=" + String(Int(req_decoded.frame.header.kind)))
    if req_decoded.frame.header.stream_id != sid:
        raise Error("stream_id mismatch on outbound HEADERS")
    if (req_decoded.frame.header.flags & FLAG_END_STREAM) == UInt8(0):
        raise Error("expected END_STREAM on GET HEADERS")
    if (req_decoded.frame.header.flags & FLAG_END_HEADERS) == UInt8(0):
        raise Error("expected END_HEADERS on single-frame HEADERS")

    # Synthesize server response bytes via a separate HpackEncoder.
    var srv_enc = HpackEncoder(max_table_size=4096)
    var body = List[UInt8]()
    var msg = String("Hello")
    var mb = msg.as_bytes()
    var bi = 0
    while bi < len(mb):
        body.append(mb[bi])
        bi = bi + 1
    var resp_bytes = _build_response_bytes(
        srv_enc,
        sid,
        String("200"),
        String("text/plain"),
        body^,
    )

    # Feed into client recv_buf + dispatch.
    client.append_recv_bytes(Span(resp_bytes))
    var max_sid = process_received_frames(client)
    if max_sid != sid:
        raise Error(
            "process_received_frames max_sid mismatch: got "
            + String(Int(max_sid)) + " expected " + String(Int(sid))
        )
    # Verify the stream now has end_stream_seen + status + body.
    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("stream missing after processing")
    if not client.streams[idx].end_stream_seen:
        raise Error("end_stream_seen should be set after server END_STREAM")
    if client.streams[idx].response_status != UInt16(200):
        raise Error(
            "response_status mismatch: got "
            + String(Int(client.streams[idx].response_status))
        )
    # Extract response tuple.
    var triple = extract_response_for_stream(client, sid)
    var status = triple[0]
    ref hdrs = triple[1]
    ref body_out = triple[2]
    if status != UInt16(200):
        raise Error("status mismatch in extract")
    if len(body_out) != 5:
        raise Error(
            "body length should be 5; got " + String(len(body_out))
        )
    # Body bytes equal "Hello".
    var expected_body = String("Hello")
    var eb = expected_body.as_bytes()
    var k = 0
    while k < 5:
        if body_out[k] != eb[k]:
            raise Error(
                "body byte mismatch at " + String(k)
                + ": got " + String(Int(body_out[k]))
            )
        k = k + 1
    # Caller-visible headers: content-length + content-type (excluding :status pseudo).
    if not hdrs.contains(String("content-length")):
        raise Error("response missing content-length")
    if not hdrs.contains(String("content-type")):
        raise Error("response missing content-type")
    print("    OK")


def test_response_with_multi_frame_headers_via_continuation() raises:
    """A large response header block split via continuation_splitter into
    HEADERS + N CONTINUATION frames; the client reassembles + decodes
    correctly. Gate (b) acceptance: multi-frame HEADERS reassembly."""
    print("  test_response_with_multi_frame_headers_via_continuation...")

    var client = H2ClientConnectionState()
    var sid = client.allocate_client_stream_id()
    _ = client.create_stream(sid)

    # Server encodes a large header block with many entries, then splits
    # via the splitter at a small max_frame_size=64 — this forces multiple
    # CONTINUATION frames.
    var srv_enc = HpackEncoder(max_table_size=4096)
    var resp_hdrs = List[HpackHeader]()
    resp_hdrs.append(HpackHeader(String(":status"), String("200")))
    # Add 12 "x-large-N: value-N" headers — each ~25 bytes; block grows to
    # ~300+ bytes, well over the 64-byte max_frame_size we'll use.
    var k = 0
    while k < 12:
        var name = String("x-large-") + String(k)
        var value = String("value-of-header-number-") + String(k)
        resp_hdrs.append(HpackHeader(name^, value^))
        k = k + 1
    var block = srv_enc.encode_block(resp_hdrs^)
    # Split with a small max_frame_size to force CONTINUATION.
    var small_mfs = 64
    var split_bytes = List[UInt8]()
    split_header_block_into_frames(
        sid, block^, small_mfs, True, split_bytes,
    )
    # Feed the multi-frame bytes into client.
    client.append_recv_bytes(Span(split_bytes))
    var max_sid = process_received_frames(client)
    if max_sid != sid:
        raise Error(
            "max_sid should be the response stream id; got "
            + String(Int(max_sid))
        )
    var idx = client.find_stream_idx(sid)
    if not client.streams[idx].end_stream_seen:
        raise Error("end_stream_seen should be set after multi-frame block")
    if client.streams[idx].response_status != UInt16(200):
        raise Error(
            "status should be 200 after multi-frame reassembly; got "
            + String(Int(client.streams[idx].response_status))
        )
    # 12 caller-visible headers (excluding :status pseudo).
    if client.streams[idx].response_header_count != UInt32(12):
        raise Error(
            "expected 12 regular headers; got "
            + String(Int(client.streams[idx].response_header_count))
        )
    # Verify cont_reasm_buf is cleared after reassembly.
    if client.cont_reasm_stream_id != UInt32(0):
        raise Error("cont_reasm_stream_id should be 0 after reassembly")
    if len(client.cont_reasm_buf) != 0:
        raise Error("cont_reasm_buf should be empty after reassembly")
    print("    OK")


def test_three_concurrent_streams_responses_interleaved() raises:
    """Open 3 streams (1, 3, 5); server response bytes arrive INTERLEAVED
    (HEADERS for sid=1 → HEADERS for sid=3 → DATA for sid=1 → HEADERS
    for sid=5 → DATA for sid=3 → DATA for sid=5); each response is
    correctly routed by stream_id. Gate (h) preview."""
    print("  test_three_concurrent_streams_responses_interleaved...")

    var client = H2ClientConnectionState()
    var sid1 = client.allocate_client_stream_id()
    var sid2 = client.allocate_client_stream_id()
    var sid3 = client.allocate_client_stream_id()
    _ = client.create_stream(sid1)
    _ = client.create_stream(sid2)
    _ = client.create_stream(sid3)

    var srv_enc = HpackEncoder(max_table_size=4096)

    # Build response frames per stream.
    def _make_resp_frames(
        mut enc: HpackEncoder,
        sid: UInt32,
        status_str: String,
        var body: List[UInt8],
    ) -> Tuple[List[UInt8], List[UInt8]]:
        """Returns (headers_frame_bytes, data_frame_bytes)."""
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":status"), status_str))
        hdrs.append(HpackHeader(String("content-type"), String("text/plain")))
        var block = enc.encode_block(hdrs^)
        var hb = List[UInt8]()
        encode_headers_frame(sid, block^, False, True, hb)
        var db = List[UInt8]()
        encode_data_frame(sid, body^, True, db)
        return (hb^, db^)

    var b1 = List[UInt8]()
    var t1 = String("Alpha")
    var tb1 = t1.as_bytes()
    var i = 0
    while i < len(tb1):
        b1.append(tb1[i])
        i = i + 1
    var f1 = _make_resp_frames(srv_enc, sid1, String("200"), b1^)
    var h1 = List[UInt8]()
    var d1 = List[UInt8]()
    swap(h1, f1[0])
    swap(d1, f1[1])

    var b2 = List[UInt8]()
    var t2 = String("Beta-Body")
    var tb2 = t2.as_bytes()
    i = 0
    while i < len(tb2):
        b2.append(tb2[i])
        i = i + 1
    var f2 = _make_resp_frames(srv_enc, sid2, String("404"), b2^)
    var h2_frame = List[UInt8]()
    var d2 = List[UInt8]()
    swap(h2_frame, f2[0])
    swap(d2, f2[1])

    var b3 = List[UInt8]()
    var t3 = String("Gamma-Larger-Body")
    var tb3 = t3.as_bytes()
    i = 0
    while i < len(tb3):
        b3.append(tb3[i])
        i = i + 1
    var f3 = _make_resp_frames(srv_enc, sid3, String("206"), b3^)
    var h3 = List[UInt8]()
    var d3 = List[UInt8]()
    swap(h3, f3[0])
    swap(d3, f3[1])

    # Feed interleaved: H1, H2, D1, H3, D2, D3.
    client.append_recv_bytes(Span(h1))
    client.append_recv_bytes(Span(h2_frame))
    client.append_recv_bytes(Span(d1))
    client.append_recv_bytes(Span(h3))
    client.append_recv_bytes(Span(d2))
    client.append_recv_bytes(Span(d3))
    _ = process_received_frames(client)

    # Verify each stream completed with correct status + body.
    var tri1 = extract_response_for_stream(client, sid1)
    if tri1[0] != UInt16(200):
        raise Error("sid1 status should be 200")
    ref b1_out = tri1[2]
    if len(b1_out) != 5:
        raise Error("sid1 body length should be 5")
    var s1_str = String("Alpha")
    var s1b = s1_str.as_bytes()
    i = 0
    while i < 5:
        if b1_out[i] != s1b[i]:
            raise Error("sid1 body byte mismatch")
        i = i + 1

    var tri2 = extract_response_for_stream(client, sid2)
    if tri2[0] != UInt16(404):
        raise Error("sid2 status should be 404")
    if len(tri2[2]) != len(tb2):
        raise Error("sid2 body length mismatch")

    var tri3 = extract_response_for_stream(client, sid3)
    if tri3[0] != UInt16(206):
        raise Error("sid3 status should be 206")
    if len(tri3[2]) != len(tb3):
        raise Error("sid3 body length mismatch")
    print("    OK — 3 streams, interleaved responses, each routed correctly")


def test_inbound_settings_triggers_ack() raises:
    """Server's non-ACK SETTINGS frame arrives in recv_buf;
    process_received_frames applies + stages SETTINGS-ACK."""
    print("  test_inbound_settings_triggers_ack...")

    var client = H2ClientConnectionState()
    # Discard initial preface/SETTINGS pending bytes.
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()

    # Build a server SETTINGS frame manually.
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE,
        value=UInt32(98304),
    ))
    var settings_bytes = List[UInt8]()
    encode_settings_frame(entries^, settings_bytes)
    client.append_recv_bytes(Span(settings_bytes))
    _ = process_received_frames(client)
    if not client.is_server_settings_seen():
        raise Error("SERVER_SETTINGS_SEEN should be set after inbound settings")
    if Int(client.send_fc.initial_window_size) != 98304:
        raise Error(
            "send_fc.initial_window_size should be 98304; got "
            + String(Int(client.send_fc.initial_window_size))
        )
    # Verify SETTINGS-ACK staged.
    var pending = client.take_out_bytes()
    var res = decode_frame(Span(pending), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error("SETTINGS-ACK didn't decode OK")
    if res.frame.header.kind != FRAME_SETTINGS:
        raise Error("expected SETTINGS-ACK")
    if (res.frame.header.flags & FLAG_ACK) == UInt8(0):
        raise Error("ACK flag must be set")
    print("    OK")


def test_post_with_body_emits_headers_then_data() raises:
    """POST request with a body: encode_request_headers (NO end_stream)
    then encode_request_data_frame (with end_stream). Outbound bytes
    decode as HEADERS (without END_STREAM) + DATA (with END_STREAM).
    Stream state should be HALF_CLOSED_LOCAL after the body is sent."""
    print("  test_post_with_body_emits_headers_then_data...")

    var client = H2ClientConnectionState()
    var sid = client.allocate_client_stream_id()
    _ = client.create_stream(sid)

    # Encode HEADERS (no end_stream — body to follow).
    var hdrs = HeaderMap()
    hdrs.append(String("content-length"), String("11"))
    hdrs.append(String("content-type"), String("text/plain"))
    encode_request_headers_to_frames(
        client,
        sid,
        String("POST"),
        String("https"),
        String("example.com"),
        String("/upload"),
        hdrs^,
        False,  # end_stream — body to follow
    )

    # Encode DATA (with end_stream).
    var body = List[UInt8]()
    var bs = String("Hello, h2!")
    var bsb = bs.as_bytes()
    var bi = 0
    while bi < len(bsb):
        body.append(bsb[bi])
        bi = bi + 1
    # Note: "Hello, h2!" is 10 bytes; content-length header said 11. Test
    # encoder behavior — content-length is opaque metadata for our encoder.
    encode_request_data_frame(client, sid, body^, True)

    # Verify outbound stream sees HEADERS (NO END_STREAM) then DATA (END_STREAM).
    var pending = client.take_out_bytes()
    var res1 = decode_frame(Span(pending), 16384)
    if res1.status != FRAME_DECODE_OK:
        raise Error("HEADERS frame did not decode OK")
    if res1.frame.header.kind != FRAME_HEADERS:
        raise Error("first frame should be HEADERS")
    if (res1.frame.header.flags & FLAG_END_STREAM) != UInt8(0):
        raise Error("HEADERS should NOT have END_STREAM for POST")
    # Pop consumed bytes; decode next.
    var tail = List[UInt8]()
    var ti = res1.consumed
    while ti < len(pending):
        tail.append(pending[ti])
        ti = ti + 1
    var res2 = decode_frame(Span(tail), 16384)
    if res2.status != FRAME_DECODE_OK:
        raise Error("DATA frame did not decode OK")
    if (res2.frame.header.flags & FLAG_END_STREAM) == UInt8(0):
        raise Error("DATA should have END_STREAM")
    # Stream state should now be HALF_CLOSED_LOCAL.
    var idx = client.find_stream_idx(sid)
    from komira_http_core.codec.h2.stream import STREAM_STATE_HALF_CLOSED_LOCAL
    if client.streams[idx].state != STREAM_STATE_HALF_CLOSED_LOCAL:
        raise Error(
            "stream state should be HALF_CLOSED_LOCAL after sending body END_STREAM; got "
            + String(Int(client.streams[idx].state))
        )
    print("    OK")


def main() raises:
    print("== L2 h2 request/response byte-level ==")
    test_basic_get_request_response_round_trip()
    test_response_with_multi_frame_headers_via_continuation()
    test_three_concurrent_streams_responses_interleaved()
    test_inbound_settings_triggers_ack()
    test_post_with_body_emits_headers_then_data()
    print("== L2 PASSED (5 tests) ==")
