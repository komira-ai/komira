"""L2 — RFC 9113 §6.1 / §6.9 PADDED DATA flow-control conformance.

WHY THIS FILE EXISTS. `grep -i pad` across the 13 pre-existing
`test_L2_h2_*.mojo` files returns exactly TWO hits, and both are comments
that say "no padding" (`test_L2_h2_frame.mojo:121`,
`test_L2_h2_hpack.mojo:126`). The h2 client had ZERO coverage of a DATA
frame carrying FLAG_PADDED, and padding is precisely what a length-hiding
proxy or intermediary in front of a service emits.

THE CONFORMANCE BAR, which is objective and third-party:
  * RFC 9113 §6.1: "The entire DATA frame payload is included in flow
    control, including the Pad Length and Padding fields if present."
  * RFC 9113 §6.9.1: "A receiver that receives a flow-controlled frame MUST
    always account for its contribution against the connection flow-control
    window, unless the receiver treats this as a connection error."
  * hyper   — `window_updates_include_padded_length`
  * Go      — `TestTransportReturnsDataPaddingFlowControl`,
              `TestTransportReturnsUnusedFlowControl{Single,Multiple}Write(s)`
  * nghttp2 — `flow_control_data_with_padding_recv`

THE SEAM UNDER TEST. `decode_frame` (codec/h2/frame.mojo §DATA) strips the
Pad Length byte and the padding octets BEFORE copying into `frame.payload`
(`po = po + 1; pe = pe - pad_len`). `_handle_inbound_data`
(client/h2_client.mojo) then charges `len(frame.payload)` — the DECODED
byte count — to `recv_fc.on_data_received` and to
`_replenish_recv_window_after_data`. The peer debited the frame's LENGTH
field. Every padded DATA frame therefore drifts the two views of the
window apart by `pad_len + 1` octets, monotonically, in the direction that
ends at zero.

SYMPTOM CLASS. A silent stall: no error is raised, nothing fails fast — the peer
simply stops sending once its view of the window is exhausted and the
client parks until something upstream times out.

Single-process. No TCP, no TLS, no reactor: frames are synthesized as raw
bytes and fed through `append_recv_bytes` + `process_received_frames`,
which is the real buffered-drive inbound path.
"""


from komira_http_client.h2_client import (
    H2ClientConnectionState,
    apply_peer_settings_and_ack,
    encode_request_headers_to_frames,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http_client.header_map import HeaderMap
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.codec.h2.frame import (
    FLAG_END_STREAM,
    FLAG_PADDED,
    FRAME_DATA,
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    FRAME_RST_STREAM,
    FRAME_WINDOW_UPDATE,
    H2_ERR_CANCEL,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_FRAME_SIZE_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_frame_header,
    encode_headers_frame,
    encode_rst_stream_frame,
)


# =============================================================================
# Helpers — a "server" that pads, and a reader for what the client emitted.
# =============================================================================


def _encode_padded_data_frame(
    stream_id: UInt32,
    var data: List[UInt8],
    pad_len: Int,
    end_stream: Bool,
    mut out: List[UInt8],
) -> Int:
    """Serialize a DATA frame WITH padding (RFC 9113 §6.1) and return the
    value written into the frame's LENGTH field — which is what the peer
    debits from its send window, and therefore what the receiver owes back.

    `encode_data_frame` in the tree deliberately never pads ("The server
    doesn't pad"), so the padding wire shape has to be built here. Layout:

        +---------------+
        |Pad Length? (8)|
        +---------------+-----------------------------------------------+
        |                            Data (*)                         ...
        +---------------------------------------------------------------+
        |                           Padding (*)                       ...
        +---------------------------------------------------------------+
    """
    var flags = FLAG_PADDED
    if end_stream:
        flags = flags | FLAG_END_STREAM
    var length = 1 + len(data) + pad_len
    encode_frame_header(UInt32(length), FRAME_DATA, flags, stream_id, out)
    out.append(UInt8(pad_len))
    var i = 0
    while i < len(data):
        out.append(data[i])
        i = i + 1
    var p = 0
    while p < pad_len:
        out.append(UInt8(0))
        p = p + 1
    return length


def _body_bytes(n: Int, seed: Int) -> List[UInt8]:
    """Deterministic filler so a truncated body is detectable by content."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        out.append(UInt8(((seed + i) * 31 + 7) & 0xFF))
        i = i + 1
    return out^


def _scan_window_update_totals(
    bytes: Span[UInt8, _],
    stream_id: UInt32,
) raises -> Tuple[Int, Int]:
    """Sum every WINDOW_UPDATE increment the client staged, split into
    (connection-level total, `stream_id`-level total)."""
    var conn_total = 0
    var stream_total = 0
    var off = 0
    while off < len(bytes):
        if len(bytes) - off < 9:
            break
        var fr = decode_frame(bytes[off:], 16384)
        if fr.status != FRAME_DECODE_OK:
            break
        if fr.frame.header.kind == FRAME_WINDOW_UPDATE:
            if fr.frame.header.stream_id == UInt32(0):
                conn_total = conn_total + Int(fr.frame.window_update_increment)
            elif fr.frame.header.stream_id == stream_id:
                stream_total = (
                    stream_total + Int(fr.frame.window_update_increment)
                )
        off = off + fr.consumed
    return (conn_total, stream_total)


def _count_frames_of_kind(bytes: Span[UInt8, _], kind: UInt8) raises -> Int:
    var n = 0
    var off = 0
    while off < len(bytes):
        if len(bytes) - off < 9:
            break
        var fr = decode_frame(bytes[off:], 16384)
        if fr.status != FRAME_DECODE_OK:
            break
        if fr.frame.header.kind == kind:
            n = n + 1
        off = off + fr.consumed
    return n


def _open_client_stream(mut client: H2ClientConnectionState) raises -> UInt32:
    """Allocate + open a client stream, send its request HEADERS, and
    discard everything staged so far so `pending_out` holds ONLY what the
    inbound response drive produces."""
    var sid = client.allocate_client_stream_id()
    _ = client.create_stream(sid)
    var req_headers = HeaderMap()
    encode_request_headers_to_frames(
        client, sid,
        String("GET"), String("https"),
        String("example.com"), String("/"),
        req_headers^, True,
    )
    _ = client.take_out_bytes()
    return sid


def _append_response_headers(
    mut enc: HpackEncoder,
    sid: UInt32,
    end_stream: Bool,
    mut out: List[UInt8],
) raises:
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = enc.encode_block(hdrs^)
    encode_headers_frame(sid, block^, end_stream, True, out)


# =============================================================================
# CASE 1 — the confirmed defect, in its smallest form.
# =============================================================================


def test_padded_data_credits_the_whole_frame_length() raises:
    """Padded DATA must credit its whole LENGTH field back, per RFC 9113 §6.1.

    "The entire DATA frame payload is included in flow control, INCLUDING
    the Pad Length and Padding fields if present."

    One DATA frame: 4 data octets, pad_len = 8. The LENGTH field on the
    wire is 1 + 4 + 8 = 13, and 13 is what the sender debited from both of
    its send windows. The client therefore owes 13 back on each.

    FAILS ON CURRENT CODE: `_handle_inbound_data` charges
    `len(frame.payload)` = 4 (the decoder already stripped the Pad Length
    byte and the 8 padding octets), so the client credits 4. The 9-octet
    shortfall is permanent and accumulates per frame.

    Reference coverage: hyper `window_updates_include_padded_length`,
    Go `TestTransportReturnsDataPaddingFlowControl`,
    nghttp2 `flow_control_data_with_padding_recv`.
    """
    print("  test_padded_data_credits_the_whole_frame_length...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    var sid = _open_client_stream(client)
    # Emit a WINDOW_UPDATE for every frame rather than at the 32768-octet
    # default watermark: this test is about the ACCOUNTING, not the cadence.
    client.recv_fc.drain_watermark = UInt32(1)

    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _append_response_headers(enc, sid, False, resp)
    var wire_len = _encode_padded_data_frame(
        sid, _body_bytes(4, 0), 8, True, resp,
    )
    if wire_len != 13:
        raise Error("harness bug: frame LENGTH should be 13")

    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)

    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("stream vanished")
    if not client.streams[idx].end_stream_seen:
        raise Error("END_STREAM not seen — the padded DATA frame was rejected")
    # The DECODED body must be the 4 data octets, padding stripped.
    var bslot = client.streams[idx].response_body_idx
    if len(client.response_body_buffers[bslot]) != 4:
        raise Error(
            "decoded body should be 4 octets (padding stripped); got "
            + String(len(client.response_body_buffers[bslot]))
        )

    var out_bytes = client.take_out_bytes()
    var totals = _scan_window_update_totals(Span(out_bytes), sid)
    var conn_credit = totals[0]
    var stream_credit = totals[1]

    if conn_credit != wire_len:
        raise Error(
            "RFC 9113 §6.1 VIOLATION (connection window): the peer debited "
            + String(wire_len) + " octets for this DATA frame (LENGTH field ="
            " 1 Pad Length byte + 4 data + 8 padding) but the client credited"
            " back " + String(conn_credit) + " (delta "
            + String(wire_len - conn_credit) + "). Under-crediting exhausts the"
            " peer's window and stalls it; over-crediting overflows it and"
            " earns GOAWAY. `_handle_inbound_data` charges len(frame.payload),"
            " which decode_frame already stripped the padding from."
        )
    if stream_credit != wire_len:
        raise Error(
            "RFC 9113 §6.1 VIOLATION (stream window): peer debited "
            + String(wire_len) + ", client credited " + String(stream_credit)
        )
    print("    OK — padded DATA credits the full LENGTH field on both windows")


# =============================================================================
# CASE 2 — the cumulative form, which is what actually drifts.
# =============================================================================


def test_padded_data_cumulative_credit_equals_sum_of_length_fields() raises:
    """The two views of the window must not diverge across a whole body.

    Eight padded DATA frames with varying pad lengths. The total the client
    credits back must equal the sum of the frames' LENGTH FIELDS — the
    quantity the sender debited — not the sum of the decoded data.

    FAILS ON CURRENT CODE: the client credits only the decoded data, so it
    is short by `sum(pad_len_i + 1)` octets. That shortfall is the drift;
    it never recovers, and it is monotone toward window exhaustion.
    """
    print("  test_padded_data_cumulative_credit_equals_sum_of_length_fields...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    var sid = _open_client_stream(client)
    client.recv_fc.drain_watermark = UInt32(1)

    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _append_response_headers(enc, sid, False, resp)

    var wire_total = 0
    var data_total = 0
    var n_frames = 8
    var k = 0
    while k < n_frames:
        var data_len = 64 + k * 16
        var pad_len = 1 + k * 7          # 1, 8, 15, ... all < 256
        var is_last = (k == n_frames - 1)
        wire_total = wire_total + _encode_padded_data_frame(
            sid, _body_bytes(data_len, k), pad_len, is_last, resp,
        )
        data_total = data_total + data_len
        k = k + 1

    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)

    var idx = client.find_stream_idx(sid)
    if idx < 0 or not client.streams[idx].end_stream_seen:
        raise Error("response did not complete")
    var bslot = client.streams[idx].response_body_idx
    if len(client.response_body_buffers[bslot]) != data_total:
        raise Error(
            "decoded body length "
            + String(len(client.response_body_buffers[bslot]))
            + " != expected " + String(data_total)
        )

    var out_bytes = client.take_out_bytes()
    var totals = _scan_window_update_totals(Span(out_bytes), sid)
    if totals[0] != wire_total:
        raise Error(
            "CONNECTION-WINDOW DRIFT: peer debited " + String(wire_total)
            + " octets across " + String(n_frames) + " padded DATA frames;"
            " client credited " + String(totals[0]) + " (delta "
            + String(wire_total - totals[0]) + ", the sum of pad_len+1)."
            " The client credited exactly the DECODED data ("
            + String(data_total) + "), which is the bug."
        )
    if totals[1] != wire_total:
        raise Error(
            "STREAM-WINDOW DRIFT: peer debited " + String(wire_total)
            + ", client credited " + String(totals[1])
        )
    print("    OK — cumulative credit tracks the wire, not the decoded body")


# =============================================================================
# CASE 3 — the hang. A bounded drive loop against a window-respecting peer.
# =============================================================================


def test_padded_body_larger_than_the_window_completes_in_bounded_rounds() raises:
    """A 60KB body delivered entirely in padded DATA frames on the default
    65535-octet window must COMPLETE, and must complete in a bounded number
    of drive rounds.

    The "server" here respects flow control the way a real one does: it
    debits its own send windows by each frame's LENGTH FIELD and refuses to
    send when a frame would not fit, resuming only on WINDOW_UPDATE.

    FAILS ON CURRENT CODE — and fails as a STALL, not as an error. With
    data=100 and pad=200 the client credits 100 per frame while the server
    debits 301, so the system converges: total wire octets W satisfies
    W = 65535 + (100/301)*W, i.e. W ~= 98_100, i.e. ~32.6KB of data ever
    gets through. The server then has < 301 octets of window, sends
    nothing, and the client waits. No exception, no timeout, no diagnostic
    — only a request that stalls until an upstream gateway times it out.

    The bound is the assertion: a round that transfers ZERO frames while
    the body is unfinished IS the deadlock, and it is reported as such
    rather than being allowed to spin.
    """
    print(
        "  test_padded_body_larger_than_the_window_completes_in_bounded_rounds..."
    )

    comptime DATA_PER_FRAME = 100
    comptime PAD_PER_FRAME = 200
    comptime BODY_LEN = 60000
    comptime MAX_ROUNDS = 64

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    var sid = _open_client_stream(client)
    # Eager replenishment. With the DEFAULT 32768 watermark the client would
    # not emit its first WINDOW_UPDATE until long after the server had
    # already stalled, so a low watermark makes this test measure the
    # ACCOUNTING rather than the cadence. Correct accounting completes at any
    # watermark; broken accounting stalls at every watermark.
    client.recv_fc.drain_watermark = UInt32(512)

    var enc = HpackEncoder(max_table_size=4096)
    var hdr_wire = List[UInt8]()
    _append_response_headers(enc, sid, False, hdr_wire)
    client.append_recv_bytes(Span(hdr_wire))
    _ = process_received_frames(client)
    _ = client.take_out_bytes()

    # The server's own view of the two windows it is sending against.
    var srv_conn_window = 65535
    var srv_stream_window = 65535
    var sent = 0
    var rounds = 0
    var frames_sent_total = 0

    while sent < BODY_LEN:
        rounds = rounds + 1
        if rounds > MAX_ROUNDS:
            raise Error(
                "EXCEEDED " + String(MAX_ROUNDS) + " drive rounds with only "
                + String(sent) + "/" + String(BODY_LEN) + " body octets sent"
            )
        var wire = List[UInt8]()
        var frames_this_round = 0
        while sent < BODY_LEN:
            var this_data = BODY_LEN - sent
            if this_data > DATA_PER_FRAME:
                this_data = DATA_PER_FRAME
            var frame_len = 1 + this_data + PAD_PER_FRAME
            if frame_len > srv_conn_window or frame_len > srv_stream_window:
                break                      # window-respecting peer: stop here
            var is_last = (sent + this_data) >= BODY_LEN
            _ = _encode_padded_data_frame(
                sid, _body_bytes(this_data, sent), PAD_PER_FRAME, is_last, wire,
            )
            srv_conn_window = srv_conn_window - frame_len
            srv_stream_window = srv_stream_window - frame_len
            sent = sent + this_data
            frames_this_round = frames_this_round + 1

        if frames_this_round == 0:
            raise Error(
                "FLOW-CONTROL DEADLOCK after " + String(rounds) + " rounds: the"
                " peer has conn_window=" + String(srv_conn_window)
                + " stream_window=" + String(srv_stream_window) + ", both below"
                " the " + String(1 + DATA_PER_FRAME + PAD_PER_FRAME)
                + "-octet next frame, and the client has stopped crediting."
                " Only " + String(sent) + " of " + String(BODY_LEN)
                + " body octets were delivered. NO ERROR IS RAISED ON EITHER"
                " SIDE — the client simply parks until something upstream"
                " times out. Root cause: the client credits the DECODED "
                + String(DATA_PER_FRAME) + " octets per frame while the peer"
                " debited the " + String(1 + DATA_PER_FRAME + PAD_PER_FRAME)
                + "-octet LENGTH field (RFC 9113 §6.1)."
            )
        frames_sent_total = frames_sent_total + frames_this_round

        client.append_recv_bytes(Span(wire))
        _ = process_received_frames(client)
        var out_bytes = client.take_out_bytes()
        var totals = _scan_window_update_totals(Span(out_bytes), sid)
        srv_conn_window = srv_conn_window + totals[0]
        srv_stream_window = srv_stream_window + totals[1]

    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("stream vanished")
    if not client.streams[idx].end_stream_seen:
        raise Error("whole body sent but END_STREAM never observed")
    var bslot = client.streams[idx].response_body_idx
    if len(client.response_body_buffers[bslot]) != BODY_LEN:
        raise Error(
            "body truncated: got "
            + String(len(client.response_body_buffers[bslot])) + " of "
            + String(BODY_LEN)
        )
    print(
        "    OK — " + String(BODY_LEN) + " octets over " + String(frames_sent_total)
        + " padded frames in " + String(rounds) + " rounds (bound "
        + String(MAX_ROUNDS) + ")"
    )


# =============================================================================
# CASE 4 — a reset stream still owes the CONNECTION window.
# =============================================================================


def test_padded_data_after_rst_still_credits_connection_window() raises:
    """A reset stream still owes the connection window, per RFC 9113 §6.9.1.

    "A receiver that receives a flow-controlled frame MUST always account
    for its contribution against the connection flow-control window... This
    is necessary even if the frame is in error."

    A DATA frame already in flight when the stream was reset still consumed
    the peer's connection window. If the receiver silently drops it, the
    connection window leaks by that much for the life of the connection —
    a slow-motion version of the same wedge, reached through a different
    door. hyper covers this three ways; this package covered it zero.

    FAILS ON CURRENT CODE for the padding amount: the frame IS accounted
    (the reset stream stays in `streams`, so `_handle_inbound_data` runs),
    but it is accounted at the decoded length, so the connection window
    still leaks `pad_len + 1` octets.
    """
    print("  test_padded_data_after_rst_still_credits_connection_window...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    var sid = _open_client_stream(client)
    client.recv_fc.drain_watermark = UInt32(1)

    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _append_response_headers(enc, sid, False, resp)
    encode_rst_stream_frame(sid, H2_ERR_CANCEL, resp)
    # In-flight DATA that crossed the RST on the wire.
    var wire_len = _encode_padded_data_frame(
        sid, _body_bytes(32, 3), 47, False, resp,
    )

    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)

    var out_bytes = client.take_out_bytes()
    if _count_frames_of_kind(Span(out_bytes), FRAME_GOAWAY) != 0:
        raise Error(
            "in-flight DATA on a reset stream must not tear down the"
            " connection (RFC 9113 §5.1 / §6.9.1)"
        )
    var totals = _scan_window_update_totals(Span(out_bytes), sid)
    if totals[0] != wire_len:
        raise Error(
            "CONNECTION-WINDOW LEAK on a reset stream: the peer debited "
            + String(wire_len) + " octets for the in-flight padded DATA frame;"
            " the client credited " + String(totals[0])
            + ". RFC 9113 §6.9.1 requires the connection window to be"
            " accounted even for a frame that is in error."
        )
    print("    OK — reset stream still credits the connection window in full")


# =============================================================================
# CASES 5 + 6 — the two padding refusals, pinned at the wire level.
# =============================================================================


def test_padded_data_with_zero_length_is_frame_size_error() raises:
    """RFC 9113 §6.1: a DATA frame with FLAG_PADDED must carry at least the
    Pad Length field, so LENGTH == 0 with FLAG_PADDED set is too small to
    contain mandatory frame data: a FRAME_SIZE_ERROR (RFC 9113 §4.2),
    answered as a connection error. Pinning `frame.mojo`'s
    `if length == UInt32(0)` arm — without a test, a refactor of the
    padding block deletes it silently."""
    print("  test_padded_data_with_zero_length_is_frame_size_error...")

    var bytes = List[UInt8]()
    encode_frame_header(UInt32(0), FRAME_DATA, FLAG_PADDED, UInt32(3), bytes)
    var res = decode_frame(Span(bytes), 16384)
    if res.is_ok():
        raise Error(
            "FLAG_PADDED DATA with LENGTH=0 must be a FRAME_SIZE_ERROR"
            " (RFC 9113 §4.2) — there is not even a Pad Length byte to read"
        )
    if res.error_code != H2_ERR_FRAME_SIZE_ERROR:
        raise Error(
            "expected FRAME_SIZE_ERROR; got error_code="
            + String(Int(res.error_code))
        )
    if not res.is_connection_error:
        raise Error("zero-length padded DATA is a CONNECTION error")
    print("    OK")


def test_pad_length_not_less_than_frame_length_is_protocol_error() raises:
    """Padding at or beyond the frame length is a PROTOCOL_ERROR.

    "If the length of the padding is the length of the frame payload or
    greater, the recipient MUST treat this as a connection error of type
    PROTOCOL_ERROR."

    Three points pinned: pad_len == length (illegal), pad_len > length
    (illegal), and pad_len == length - 1 (LEGAL — an all-padding frame with
    zero data octets, which a length-hiding proxy really does emit)."""
    print("  test_pad_length_not_less_than_frame_length_is_protocol_error...")

    # pad_len == length  → illegal.
    var eq = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_DATA, FLAG_PADDED, UInt32(3), eq)
    eq.append(UInt8(4))                    # Pad Length == LENGTH
    var i = 0
    while i < 3:
        eq.append(UInt8(0))
        i = i + 1
    var r_eq = decode_frame(Span(eq), 16384)
    if r_eq.is_ok():
        raise Error("pad_len == LENGTH must be a PROTOCOL_ERROR")
    if r_eq.error_code != H2_ERR_PROTOCOL_ERROR or not r_eq.is_connection_error:
        raise Error("pad_len == LENGTH must be a CONNECTION PROTOCOL_ERROR")

    # pad_len > length → illegal.
    var gt = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_DATA, FLAG_PADDED, UInt32(3), gt)
    gt.append(UInt8(200))
    var j = 0
    while j < 3:
        gt.append(UInt8(0))
        j = j + 1
    var r_gt = decode_frame(Span(gt), 16384)
    if r_gt.is_ok():
        raise Error("pad_len > LENGTH must be a PROTOCOL_ERROR")

    # pad_len == length - 1 → LEGAL, zero data octets.
    var ok_wire = List[UInt8]()
    var ok_len = _encode_padded_data_frame(
        UInt32(3), List[UInt8](), 3, False, ok_wire,
    )
    if ok_len != 4:
        raise Error("harness bug: all-padding frame LENGTH should be 4")
    var r_ok = decode_frame(Span(ok_wire), 16384)
    if not r_ok.is_ok():
        raise Error(
            "an all-padding DATA frame (pad_len == LENGTH-1, zero data"
            " octets) is LEGAL per RFC 9113 §6.1 and must decode"
        )
    if len(r_ok.frame.payload) != 0:
        raise Error("all-padding frame should decode to an empty payload")
    if Int(r_ok.frame.padding_length) != 3:
        raise Error("padding_length should be 3")
    print("    OK — both error arms and the legal boundary pinned")


# =============================================================================
# CASE 7 — replenishment must never OVER-credit.
# =============================================================================


def test_recv_replenishment_never_credits_more_than_was_debited() raises:
    """Go `TestTransportReturnsUnusedFlowControl{Single,MultipleWrites}`.
    Over-crediting is as fatal as under-crediting: it eventually pushes the
    peer's window past 2^31-1 and earns a GOAWAY(FLOW_CONTROL_ERROR).

    Two halves:
      * UNPADDED — credit must equal the debit EXACTLY. This is the control:
        it proves the harness measures the right quantity, and it is the
        half a fix to the padding path must not disturb.
      * PADDED — credit must never EXCEED the frames' LENGTH fields. This is
        the guard-rail on the fix: a fix that adds `padding_length + 1`
        unconditionally (including on frames with no FLAG_PADDED, where
        `padding_length` is 0 but the +1 is not) would over-credit by one
        octet per frame and this half catches it.
    """
    print("  test_recv_replenishment_never_credits_more_than_was_debited...")

    # ---- UNPADDED control: exact equality. --------------------------------
    var c1 = H2ClientConnectionState()
    queue_client_preface_and_settings(c1)
    _ = c1.take_out_bytes()
    var sid1 = _open_client_stream(c1)
    c1.recv_fc.drain_watermark = UInt32(1)

    var enc1 = HpackEncoder(max_table_size=4096)
    var r1 = List[UInt8]()
    _append_response_headers(enc1, sid1, False, r1)
    var unpadded_total = 0
    var k = 0
    while k < 5:
        var n = 300 + k * 111
        encode_data_frame(sid1, _body_bytes(n, k), k == 4, r1)
        unpadded_total = unpadded_total + n
        k = k + 1
    c1.append_recv_bytes(Span(r1))
    _ = process_received_frames(c1)
    var o1 = c1.take_out_bytes()
    var t1 = _scan_window_update_totals(Span(o1), sid1)
    if t1[0] != unpadded_total:
        raise Error(
            "UNPADDED control failed: debited " + String(unpadded_total)
            + " octets, credited " + String(t1[0])
        )
    if t1[1] != unpadded_total:
        raise Error(
            "UNPADDED control failed (stream): debited "
            + String(unpadded_total) + ", credited " + String(t1[1])
        )

    # ---- PADDED guard-rail: never more than the wire length. ---------------
    var c2 = H2ClientConnectionState()
    queue_client_preface_and_settings(c2)
    _ = c2.take_out_bytes()
    var sid2 = _open_client_stream(c2)
    c2.recv_fc.drain_watermark = UInt32(1)

    var enc2 = HpackEncoder(max_table_size=4096)
    var r2 = List[UInt8]()
    _append_response_headers(enc2, sid2, False, r2)
    var padded_total = 0
    var m = 0
    while m < 5:
        padded_total = padded_total + _encode_padded_data_frame(
            sid2, _body_bytes(300 + m * 111, m), 5 + m * 9, m == 4, r2,
        )
        m = m + 1
    c2.append_recv_bytes(Span(r2))
    _ = process_received_frames(c2)
    var o2 = c2.take_out_bytes()
    var t2 = _scan_window_update_totals(Span(o2), sid2)
    if t2[0] > padded_total:
        raise Error(
            "OVER-CREDIT on the connection window: peer debited "
            + String(padded_total) + " octets, client credited "
            + String(t2[0]) + ". An over-credited window overflows the peer's"
            " 2^31-1 ceiling and earns GOAWAY(FLOW_CONTROL_ERROR)."
        )
    if t2[1] > padded_total:
        raise Error(
            "OVER-CREDIT on the stream window: peer debited "
            + String(padded_total) + ", client credited " + String(t2[1])
        )
    print("    OK — exact on unpadded, never over-credits on padded")


# =============================================================================
# CASE 8 — a stream-window violation must not destroy the connection.
# =============================================================================


def test_stream_window_violation_does_not_kill_other_streams() raises:
    """RFC 9113 §6.9 permits EITHER a stream error or a connection error for
    a flow-control violation ("A receiver MAY respond with a stream error
    ... or connection error ... of type FLOW_CONTROL_ERROR"), so the
    RST-vs-GOAWAY choice is not itself a conformance failure. What IS a
    real defect is the consequence: DATA that overruns ONE stream's window
    while fitting comfortably inside the CONNECTION window destroys every
    other in-flight stream on that connection.

    Every reference implementation scopes this to the offending stream:
    hyper, Go's `http2` and nghttp2 all emit RST_STREAM(FLOW_CONTROL_ERROR)
    and keep the connection.

    FAILS ON CURRENT CODE, and the mechanism is structural, not incidental:
    `RecvFlowController.on_data_received` returns
    `FlowResult.flow_control_error(UInt32(0))` — hard-coded stream_id 0 — so
    it cannot tell its caller WHICH window was overrun, and
    `_handle_inbound_data` maps every non-OK result to
    `emit_goaway_for_client(...)` and returns False, which makes
    `process_received_frames` abandon the rest of the receive buffer. The
    `FlowResult.rst(stream_id, ...)` constructor that the same file defines
    is unreachable from the receive path.

    Stream A's window is lowered directly (the connection window is left at
    its full 65535) so the violation is unambiguously stream-scoped.
    """
    print("  test_stream_window_violation_does_not_kill_other_streams...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    var sid_a = _open_client_stream(client)
    var sid_b = _open_client_stream(client)

    var idx_a = client.find_stream_idx(sid_a)
    if idx_a < 0:
        raise Error("stream A vanished")
    # Stream A can take 10 octets; the CONNECTION can take 65535.
    client.streams[idx_a].recv_window = Int32(10)

    var enc = HpackEncoder(max_table_size=4096)
    var wire = List[UInt8]()
    _append_response_headers(enc, sid_a, False, wire)
    # 100 octets: overruns A's 10-octet window, fits the connection window.
    encode_data_frame(sid_a, _body_bytes(100, 1), False, wire)
    # A complete, well-behaved response on an unrelated stream, queued behind it.
    _append_response_headers(enc, sid_b, False, wire)
    encode_data_frame(sid_b, _body_bytes(64, 2), True, wire)

    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out_bytes = client.take_out_bytes()
    var n_goaway = _count_frames_of_kind(Span(out_bytes), FRAME_GOAWAY)
    var n_rst = _count_frames_of_kind(Span(out_bytes), FRAME_RST_STREAM)

    var idx_b = client.find_stream_idx(sid_b)
    if idx_b < 0:
        raise Error("stream B vanished")
    if not client.streams[idx_b].end_stream_seen:
        raise Error(
            "HEAD-OF-LINE DESTRUCTION: stream " + String(Int(sid_a)) + " overran"
            " its own 10-octet receive window with a 100-octet DATA frame that"
            " fit the 65535-octet CONNECTION window, and the unrelated,"
            " well-behaved stream " + String(Int(sid_b)) + " never completed."
            " The client staged " + String(n_goaway) + " GOAWAY and "
            + String(n_rst) + " RST_STREAM frame(s) and abandoned the rest of"
            " the receive buffer. hyper, Go http2 and nghttp2 all scope this"
            " to RST_STREAM(FLOW_CONTROL_ERROR) on the offending stream."
            " `RecvFlowController.on_data_received` hard-codes stream_id=0 in"
            " its FlowResult, so `_handle_inbound_data` cannot distinguish a"
            " stream overrun from a connection overrun."
        )
    if n_rst != 1:
        raise Error(
            "expected exactly one RST_STREAM for the offending stream; got "
            + String(n_rst)
        )
    print("    OK — stream-scoped violation, connection and peer streams survive")


# =============================================================================
# CASE 9 — SETTINGS_INITIAL_WINDOW_SIZE below bytes in flight.
# =============================================================================


def test_settings_initial_window_decrease_drives_send_window_negative() raises:
    """RFC 9113 §6.9.2: a SETTINGS_INITIAL_WINDOW_SIZE change applies
    RETROACTIVELY to every live stream, and "a sender MUST track the
    negative flow-control window" it produces, resuming only once a
    WINDOW_UPDATE lifts it back above zero.

    The controller's arithmetic was already covered
    (`test_send_fc_retroactive_settings_initial_window`); what was NOT
    covered is that `apply_peer_settings_and_ack` actually walks the live
    streams and applies the delta to each. This drives it at the client
    level: consume 40000 octets of a live stream's send window, then have
    the peer lower the initial window to 1024, and require the stream's
    send window to be genuinely negative and to recover only on
    WINDOW_UPDATE.
    """
    print("  test_settings_initial_window_decrease_drives_send_window_negative...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    var sid = _open_client_stream(client)
    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("stream vanished")
    if Int(client.streams[idx].send_window) != 65535:
        raise Error(
            "stream send window should start at 65535; got "
            + String(Int(client.streams[idx].send_window))
        )

    # 40000 octets of request body already handed to the wire.
    client.streams[idx].send_window = client.streams[idx].send_window - Int32(40000)
    if Int(client.streams[idx].send_window) != 25535:
        raise Error("harness bug: send window should be 25535")

    # Peer lowers SETTINGS_INITIAL_WINDOW_SIZE 65535 -> 1024 (delta -64511).
    var s = List[SettingsEntry]()
    s.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE, value=UInt32(1024),
    ))
    if not apply_peer_settings_and_ack(client, s^):
        raise Error("lowering SETTINGS_INITIAL_WINDOW_SIZE must be accepted")

    var expected = 25535 - 64511      # -38976
    if Int(client.streams[idx].send_window) != expected:
        raise Error(
            "RFC 9113 §6.9.2: the retroactive delta must be applied to the"
            " LIVE stream's send window, driving it negative. Expected "
            + String(expected) + "; got "
            + String(Int(client.streams[idx].send_window))
        )
    # A send window of 0 would be indistinguishable from "just exhausted";
    # the negative value is what tells the sender how much it over-sent.
    if Int(client.streams[idx].send_window) >= 0:
        raise Error("send window must be strictly negative here")

    # can_send must refuse while negative, and only a WINDOW_UPDATE that
    # lifts it above zero may unblock it.
    if client.send_fc.can_send(client.streams[idx].send_window, 1) != 0:
        raise Error("can_send must return 0 on a negative stream send window")
    var fr = client.send_fc.on_window_update(
        sid, UInt32(38976), client.streams[idx].send_window,
    )
    if fr.kind != 0:
        raise Error("WINDOW_UPDATE lifting the window should be OK")
    if Int(client.streams[idx].send_window) != 0:
        raise Error(
            "window should be exactly 0 after crediting the deficit; got "
            + String(Int(client.streams[idx].send_window))
        )
    if client.send_fc.can_send(client.streams[idx].send_window, 1) != 0:
        raise Error("a zero window is still not sendable")
    var fr2 = client.send_fc.on_window_update(
        sid, UInt32(100), client.streams[idx].send_window,
    )
    if fr2.kind != 0:
        raise Error("second WINDOW_UPDATE should be OK")
    if client.send_fc.can_send(client.streams[idx].send_window, 1) != 1:
        raise Error("window above zero must unblock the sender")
    print("    OK — retroactive decrease tracked negative, recovers on WINDOW_UPDATE")


def main() raises:
    print("== L2 h2 PADDED DATA flow control (RFC 9113 §6.1 / §6.9) ==")
    test_padded_data_credits_the_whole_frame_length()
    test_padded_data_cumulative_credit_equals_sum_of_length_fields()
    test_padded_body_larger_than_the_window_completes_in_bounded_rounds()
    test_padded_data_after_rst_still_credits_connection_window()
    test_padded_data_with_zero_length_is_frame_size_error()
    test_pad_length_not_less_than_frame_length_is_protocol_error()
    test_recv_replenishment_never_credits_more_than_was_debited()
    test_stream_window_violation_does_not_kill_other_streams()
    test_settings_initial_window_decrease_drives_send_window_negative()
    print("== L2 h2 padded-DATA flow control PASSED (9 tests) ==")
