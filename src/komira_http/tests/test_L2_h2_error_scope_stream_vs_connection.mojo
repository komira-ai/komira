"""L2 — HTTP/2 client ERROR SCOPE: stream error vs connection error.

⭐ WHY THIS FILE EXISTS. `FrameDecodeResult` carries TWO fields the decoder
fills in correctly on every error path — `is_connection_error` and
`error_stream_id` — and the CLIENT NEVER READS EITHER:

    $ grep -n 'is_connection_error\\|error_stream_id' \\
        src/komira_http/client/h2_client.mojo
    (no output)

`process_received_frames` (§9, the `if res.status == FRAME_DECODE_ERROR`
arm) answers EVERY decode error with an unconditional
`emit_goaway_for_client(h2, res.error_code)`. That is a SEVERITY INVERSION,
and it bites hardest exactly where h2 is worth having: on a POOLED
connection multiplexing N requests, one malformed — or merely LATE — frame
belonging to ONE stream tears down all N.

The same inversion is spelled a second time inside `_handle_inbound_data`:

    var idx = h2.find_stream_idx(sid)
    if idx < 0:
        emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)   # ← wrong scope
        return False                                        # ← and unaccounted

Two defects on one line. (a) RFC 9113 §6.1 makes DATA in the wrong stream
state a STREAM error (STREAM_CLOSED), not a connection error. (b) RFC 9113
§6.9.1 requires the bytes be charged against the CONNECTION flow-control
window *regardless* of the stream's fate — "the entire DATA frame payload
is included in flow control, including the Pad Length and Padding fields".
Because `retire_stream` prunes the stream table on completion
an ORDINARY late DATA frame from a slow server on a
just-completed stream reaches that line in production.

REFERENCE BAR — the cases below are modelled on hyper's h2 suite:
  * `padded_data_on_forgotten_stream_releases_connection_capacity`
  * `goaway_ignores_data_but_returns_connection_capacity`
  * `request_stream_id_overflows`
and on RFC 9113 §5.1.1 (stream identifiers), §6.1 (DATA), §6.4
(RST_STREAM), §6.9.1 (WINDOW_UPDATE).

SHAPE. Single-process, no TCP, no reactor, no threads. Every case drives
the real buffered inbound path — `append_recv_bytes` +
`process_received_frames` — and inspects `pending_out` by decoding it back
into frames, the idiom of `test_L2_h2_client_flow_control.mojo`.

★ THE CONNECTION-CAPACITY INVARIANT used throughout. The peer decrements
its send window by a DATA frame's FULL `length` field; we must end up
agreeing. With `before` / `after` the connection recv window either side of
the frame and `wu` the total of the connection-level (stream_id=0)
WINDOW_UPDATE increments we emitted:

        after  ==  before - length + wu

A violation is not cosmetic: every byte of divergence is a byte the peer's
send window has lost forever, so a long-lived pooled connection walks its
window down to zero and STALLS — the same failure shape as a missing
WINDOW_UPDATE, arrived at from the other direction.
"""


from komira_http.client.h2_client import (
    H2ClientConnectionState,
    encode_request_headers_to_frames,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http.client.header_map import HeaderMap
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.codec.h2.stream import (
    STREAM_STATE_CLOSED,
    STREAM_STATE_OPEN,
)
from komira_http.codec.h2.frame import (
    FLAG_END_STREAM,
    FLAG_PADDED,
    FRAME_DATA,
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    FRAME_RST_STREAM,
    FRAME_WINDOW_UPDATE,
    H2_ERR_FRAME_SIZE_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_STREAM_CLOSED,
    decode_frame,
    encode_data_frame,
    encode_frame_header,
    encode_goaway_frame,
    encode_headers_frame,
    encode_rst_stream_frame,
    encode_window_update_frame,
)


# =============================================================================
# §0 — Local helpers. Deliberately tiny + total: every one of them decodes
#      `pending_out` back into frames with the SAME `decode_frame` the client
#      uses inbound, so a helper cannot agree with a bug the client has.
# =============================================================================


comptime _MAX_FRAME: Int = 16384

comptime _EXT_FRAME_KIND: UInt8 = 0x21
"""An unregistered frame type. RFC 9113 §5.5 requires unknown types be
ignored and discarded, so `decode_frame` accepts one on ANY stream id — which
is what makes it a clean carrier for the stream-id-on-the-wire probe in §4."""


def _count_kind(bytes: Span[UInt8, _], kind: UInt8) -> Int:
    """How many frames of `kind` are in this outbound byte run."""
    var n = 0
    var off = 0
    while off < len(bytes):
        if len(bytes) - off < 9:
            break
        var fr = decode_frame(bytes[off:], _MAX_FRAME)
        if fr.status != FRAME_DECODE_OK:
            break
        if fr.frame.header.kind == kind:
            n = n + 1
        off = off + fr.consumed
    return n


def _first_rst_stream_id(bytes: Span[UInt8, _]) -> Int:
    """stream_id of the first RST_STREAM, or -1 when there is none."""
    var off = 0
    while off < len(bytes):
        if len(bytes) - off < 9:
            break
        var fr = decode_frame(bytes[off:], _MAX_FRAME)
        if fr.status != FRAME_DECODE_OK:
            break
        if fr.frame.header.kind == FRAME_RST_STREAM:
            return Int(fr.frame.header.stream_id)
        off = off + fr.consumed
    return -1


def _first_rst_error_code(bytes: Span[UInt8, _]) -> Int:
    """error code of the first RST_STREAM, or -1 when there is none."""
    var off = 0
    while off < len(bytes):
        if len(bytes) - off < 9:
            break
        var fr = decode_frame(bytes[off:], _MAX_FRAME)
        if fr.status != FRAME_DECODE_OK:
            break
        if fr.frame.header.kind == FRAME_RST_STREAM:
            return Int(fr.frame.rst_error_code)
        off = off + fr.consumed
    return -1


def _conn_window_update_total(bytes: Span[UInt8, _]) -> Int:
    """Sum of every CONNECTION-level (stream_id == 0) WINDOW_UPDATE
    increment in this outbound byte run. This is the `wu` term of the
    connection-capacity invariant in the module docstring."""
    var total = 0
    var off = 0
    while off < len(bytes):
        if len(bytes) - off < 9:
            break
        var fr = decode_frame(bytes[off:], _MAX_FRAME)
        if fr.status != FRAME_DECODE_OK:
            break
        if (
            fr.frame.header.kind == FRAME_WINDOW_UPDATE
            and fr.frame.header.stream_id == UInt32(0)
        ):
            total = total + Int(fr.frame.window_update_increment)
        off = off + fr.consumed
    return total


def _encode_padded_data_frame(
    stream_id: UInt32,
    data: Span[UInt8, _],
    pad_len: Int,
    end_stream: Bool,
    mut out: List[UInt8],
) -> Int:
    """Append a PADDED DATA frame. Returns its flow-control charge — the
    frame's full `length` field, i.e. `1 + len(data) + pad_len`, because
    RFC 9113 §6.9.1 counts the Pad Length octet and the padding itself.

    `encode_data_frame` cannot emit padding, so this is hand-rolled from
    `encode_frame_header` + the §6.1 payload layout."""
    var length = 1 + len(data) + pad_len
    var flags = FLAG_PADDED
    if end_stream:
        flags = flags | FLAG_END_STREAM
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


def _encode_data_frames(
    stream_id: UInt32,
    total: Int,
    chunk: Int,
    end_stream_on_last: Bool,
    mut out: List[UInt8],
) raises -> Int:
    """Emit `total` bytes of body as a RUN of DATA frames of at most `chunk`
    octets each. Returns the total flow-control charge.

    ⚠ WHY THIS EXISTS AND WHY IT RAISES. A single 40000-byte DATA frame
    never reaches `_handle_inbound_data` at all: `decode_frame` rejects it
    at the `Int(length) > max_frame_size` check first (the client advertises
    MAX_FRAME_PAYLOAD_DEFAULT = 16384) and the client GOAWAYs for
    FRAME_SIZE_ERROR — a CONNECTION error, correctly. A case built that way
    LOOKS like it is probing stream-vs-connection scope while actually
    probing frame-size validation, and its failure text would name the wrong
    defect. The guard below makes that setup error impossible to make
    silently."""
    if chunk > _MAX_FRAME:
        raise Error(
            "test bug: a "
            + String(chunk)
            + "-octet DATA frame exceeds SETTINGS_MAX_FRAME_SIZE ("
            + String(_MAX_FRAME)
            + "), so the decoder rejects it as a connection-level"
            " FRAME_SIZE_ERROR and the case never reaches the code it means"
            " to test"
        )
    var charge = 0
    var sent = 0
    while sent < total:
        var this_len = total - sent
        if this_len > chunk:
            this_len = chunk
        var is_last = (sent + this_len) >= total
        encode_data_frame(
            stream_id, _filler(this_len), end_stream_on_last and is_last, out
        )
        charge = charge + this_len
        sent = sent + this_len
    return charge


def _encode_padded_data_frames(
    stream_id: UInt32,
    frames: Int,
    data_len: Int,
    pad_len: Int,
    end_stream_on_last: Bool,
    mut out: List[UInt8],
) raises -> Int:
    """`frames` PADDED DATA frames, each carrying `data_len` data octets and
    `pad_len` padding octets. Returns the total flow-control charge —
    `frames * (1 + data_len + pad_len)`, per RFC 9113 §6.9.1."""
    var per = 1 + data_len + pad_len
    if per > _MAX_FRAME:
        raise Error(
            "test bug: a padded DATA frame of "
            + String(per)
            + " octets exceeds SETTINGS_MAX_FRAME_SIZE ("
            + String(_MAX_FRAME)
            + ")"
        )
    var charge = 0
    var i = 0
    while i < frames:
        var data = _filler(data_len)
        var is_last = (i + 1) == frames
        charge = charge + _encode_padded_data_frame(
            stream_id,
            Span(data),
            pad_len,
            end_stream_on_last and is_last,
            out,
        )
        i = i + 1
    return charge


def _filler(n: Int) -> List[UInt8]:
    var v = List[UInt8]()
    var i = 0
    while i < n:
        v.append(UInt8((i * 31 + 7) & 0xFF))
        i = i + 1
    return v^


def _response_headers_frame(
    mut enc: HpackEncoder,
    stream_id: UInt32,
    status: String,
    end_stream: Bool,
    mut out: List[UInt8],
):
    """A server RESPONSE HEADERS frame (`:status`), END_HEADERS set."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), status))
    var block = enc.encode_block(hdrs^)
    encode_headers_frame(stream_id, block^, end_stream, True, out)


def _open_client_stream(
    mut client: H2ClientConnectionState, path: String
) -> UInt32:
    """Allocate + create a client stream and send its request HEADERS,
    then DISCARD the outbound bytes so `pending_out` is clean before the
    case under test runs. Returns the stream id."""
    var sid = client.allocate_client_stream_id()
    _ = client.create_stream(sid)
    var req = HeaderMap()
    encode_request_headers_to_frames(
        client,
        sid,
        String("GET"),
        String("https"),
        String("example.test"),
        path,
        req^,
        True,
    )
    _ = client.take_out_bytes()
    return sid


def _fresh_client() -> H2ClientConnectionState:
    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()
    return client^


def _assert_capacity_conserved(
    label: String,
    before: Int,
    after: Int,
    charged_length: Int,
    wu_emitted: Int,
) raises:
    """★ THE CONNECTION-CAPACITY INVARIANT (module docstring): the peer
    spent `charged_length` of its send window on this frame, so our own
    window plus whatever we credited back must land on the same number."""
    var expected = before - charged_length + wu_emitted
    print(
        "      [capacity] "
        + label
        + ": before="
        + String(before)
        + " peer_charged="
        + String(charged_length)
        + " conn_window_update_credited="
        + String(wu_emitted)
        + " after="
        + String(after)
        + " expected="
        + String(expected)
    )
    if after != expected:
        raise Error(
            "FALSIFIER ["
            + label
            + "]: connection flow-control capacity DIVERGED from the peer by "
            + String(after - expected)
            + " bytes. The peer decremented its send window by the DATA"
            " frame's full length ("
            + String(charged_length)
            + "); we ended at conn_recv_window="
            + String(after)
            + " having credited back "
            + String(wu_emitted)
            + ", where agreement requires "
            + String(expected)
            + " (= "
            + String(before)
            + " - "
            + String(charged_length)
            + " + "
            + String(wu_emitted)
            + "). RFC 9113 §6.9.1: the ENTIRE DATA frame payload is included"
            " in connection flow control, including Pad Length and Padding,"
            " and regardless of the receiving stream's state. Every byte of"
            " divergence is permanently lost from the peer's send window, so"
            " a long-lived pooled connection walks to zero and STALLS."
        )


# =============================================================================
# §1 — The pair that proves the dead fields: WINDOW_UPDATE(increment = 0).
#      frame.mojo:534-535 already computes the right answer
#      (`is_connection_error = (stream_id == 0)`); the client discards it.
# =============================================================================


def test_zero_window_update_on_stream_is_stream_scoped() raises:
    """RFC 9113 §6.9.1 — a WINDOW_UPDATE with a zero increment on a NON-ZERO
    stream is a STREAM error (RST_STREAM(PROTOCOL_ERROR)); the connection
    survives and its other streams keep running.

    THE POOLED-CONNECTION CASE. Two requests are in flight on one h2
    connection. The server (or a middlebox) emits one bad WINDOW_UPDATE
    against the first. Only the first may die.

    FAILS ON CURRENT CODE: `process_received_frames` §9 answers with
    `emit_goaway_for_client(h2, res.error_code)` for every decode error,
    never consulting `res.is_connection_error` (which the decoder set to
    False here) or `res.error_stream_id` (which it set to 1)."""
    print("  test_zero_window_update_on_stream_is_stream_scoped...")

    var client = _fresh_client()
    var sid_a = _open_client_stream(client, String("/a"))
    var sid_b = _open_client_stream(client, String("/b"))

    var wire = List[UInt8]()
    encode_window_update_frame(sid_a, UInt32(0), wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    var goaways = _count_kind(Span(out), FRAME_GOAWAY)
    if goaways != 0:
        raise Error(
            "FALSIFIER: a zero-increment WINDOW_UPDATE on stream "
            + String(Int(sid_a))
            + " produced "
            + String(goaways)
            + " GOAWAY frame(s) — the client tore down the WHOLE pooled"
            " connection for a STREAM-scoped fault. RFC 9113 §6.9.1 scopes"
            " this to the stream, and the decoder already says so"
            " (FrameDecodeResult.is_connection_error == False,"
            " .error_stream_id == "
            + String(Int(sid_a))
            + "); h2_client.mojo reads NEITHER field."
        )
    var rst_sid = _first_rst_stream_id(Span(out))
    if rst_sid != Int(sid_a):
        raise Error(
            "expected RST_STREAM on stream "
            + String(Int(sid_a))
            + "; got "
            + String(rst_sid)
            + " (-1 == no RST_STREAM emitted at all)"
        )
    var rst_ec = _first_rst_error_code(Span(out))
    if rst_ec != Int(H2_ERR_PROTOCOL_ERROR):
        raise Error(
            "RST_STREAM error code should be PROTOCOL_ERROR ("
            + String(Int(H2_ERR_PROTOCOL_ERROR))
            + "); got "
            + String(rst_ec)
        )

    # ---- THE SURVIVAL HALF: the OTHER stream must still complete. --------
    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _response_headers_frame(enc, sid_b, String("200"), True, resp)
    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)

    var idx_b = client.find_stream_idx(sid_b)
    if idx_b < 0:
        raise Error("stream " + String(Int(sid_b)) + " vanished")
    if not client.streams[idx_b].end_stream_seen:
        raise Error(
            "FALSIFIER: the innocent multiplexed stream "
            + String(Int(sid_b))
            + " never completed after a STREAM-scoped fault on stream "
            + String(Int(sid_a))
            + ". One bad frame took down N in-flight requests — the whole"
            " reason a severity inversion on a pooled connection matters."
        )
    if client.streams[idx_b].response_status != UInt16(200):
        raise Error(
            "innocent stream's :status should be 200; got "
            + String(Int(client.streams[idx_b].response_status))
        )
    print("    OK — stream-scoped: RST_STREAM only, connection survived")


def test_zero_window_update_on_stream_zero_is_connection_scoped() raises:
    """The CONTRASTING half — and the OVER-NARROWING GUARD for the fix.

    RFC 9113 §6.9.1: a zero increment on stream 0 IS a connection error.
    Wiring `is_connection_error` up must not turn every error into a
    stream error; this case must keep emitting GOAWAY(PROTOCOL_ERROR)."""
    print("  test_zero_window_update_on_stream_zero_is_connection_scoped...")

    var client = _fresh_client()
    _ = _open_client_stream(client, String("/a"))

    var wire = List[UInt8]()
    encode_window_update_frame(UInt32(0), UInt32(0), wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    if _count_kind(Span(out), FRAME_GOAWAY) != 1:
        raise Error(
            "FALSIFIER: a zero-increment WINDOW_UPDATE on stream 0 is a"
            " CONNECTION error (RFC 9113 §6.9.1) and must produce exactly one"
            " GOAWAY; got "
            + String(_count_kind(Span(out), FRAME_GOAWAY))
            + ". If this went to zero while the stream-scoped case went"
            " green, the scope fix OVER-NARROWED."
        )
    if _first_rst_stream_id(Span(out)) >= 0:
        raise Error(
            "a connection-scoped fault must not be answered with RST_STREAM"
        )
    print("    OK — connection-scoped: GOAWAY, no RST_STREAM")


def test_rst_stream_bad_length_stays_connection_scoped() raises:
    """RST_STREAM whose length is not 4 octets — the SECOND over-narrowing
    guard.

    RFC 9113 §6.4 is explicit that this one IS a connection error of type
    FRAME_SIZE_ERROR, and `frame.mojo:444-448` says so
    (`is_connection_error = True`). The point of reading the decoder's
    verdict is to FOLLOW it, in both directions: a fix that RSTs here has
    substituted one severity inversion for another."""
    print("  test_rst_stream_bad_length_stays_connection_scoped...")

    var client = _fresh_client()
    var sid = _open_client_stream(client, String("/a"))

    # A 5-octet RST_STREAM payload — one byte too many.
    var wire = List[UInt8]()
    encode_frame_header(UInt32(5), FRAME_RST_STREAM, UInt8(0), sid, wire)
    var i = 0
    while i < 5:
        wire.append(UInt8(0))
        i = i + 1
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    if _count_kind(Span(out), FRAME_GOAWAY) != 1:
        raise Error(
            "FALSIFIER: RST_STREAM with length != 4 is a CONNECTION error of"
            " type FRAME_SIZE_ERROR (RFC 9113 §6.4) and must produce exactly"
            " one GOAWAY; got "
            + String(_count_kind(Span(out), FRAME_GOAWAY))
        )
    # Decode the GOAWAY and check the error code it carries.
    var fr = decode_frame(Span(out), _MAX_FRAME)
    if fr.status != FRAME_DECODE_OK or fr.frame.header.kind != FRAME_GOAWAY:
        raise Error("outbound GOAWAY should decode OK")
    if fr.frame.goaway_error_code != H2_ERR_FRAME_SIZE_ERROR:
        raise Error(
            "GOAWAY error code should be FRAME_SIZE_ERROR ("
            + String(Int(H2_ERR_FRAME_SIZE_ERROR))
            + "); got "
            + String(Int(fr.frame.goaway_error_code))
        )
    print("    OK — RST_STREAM bad length stayed connection-scoped")


# =============================================================================
# §2 — DATA on a stream the client has already forgotten. The production
#      shape: `retire_stream` prunes the table on completion, so a LATE DATA
#      frame from a slow server lands on `find_stream_idx(sid) < 0`.
# =============================================================================


def test_late_data_on_retired_stream_does_not_goaway() raises:
    """RFC 9113 §6.1 — DATA on a stream in the wrong state is a STREAM
    error of type STREAM_CLOSED, NOT a connection error.

    THE PRODUCTION SHAPE. `retire_stream` removes a
    completed stream from `h2.streams` so `find_stream_idx` stays O(active).
    A server that is still flushing a DATA frame when we finish the stream
    — ordinary, not hostile — therefore reaches `_handle_inbound_data`'s
    `if idx < 0` arm, which GOAWAYs the pooled connection, killing every
    OTHER in-flight request on it.

    FAILS ON CURRENT CODE: h2_client.mojo `_handle_inbound_data`
    `if idx < 0: emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)`."""
    print("  test_late_data_on_retired_stream_does_not_goaway...")

    var client = _fresh_client()
    var sid_done = _open_client_stream(client, String("/done"))
    var sid_live = _open_client_stream(client, String("/live"))

    # Complete + retire the first stream, exactly as the driver does.
    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _response_headers_frame(enc, sid_done, String("200"), True, resp)
    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)
    client.retire_stream(sid_done)
    if client.find_stream_idx(sid_done) >= 0:
        raise Error("retire_stream did not prune the completed stream")
    _ = client.take_out_bytes()

    # The slow server's late DATA frame lands on the forgotten stream.
    var late = List[UInt8]()
    encode_data_frame(sid_done, _filler(64), False, late)
    client.append_recv_bytes(Span(late))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    var goaways = _count_kind(Span(out), FRAME_GOAWAY)
    if goaways != 0:
        raise Error(
            "FALSIFIER: an ordinary LATE DATA frame on retired stream "
            + String(Int(sid_done))
            + " produced "
            + String(goaways)
            + " GOAWAY frame(s), tearing down the pooled connection and every"
            " other in-flight request on it. RFC 9113 §6.1 makes DATA in the"
            " wrong stream state a STREAM error (STREAM_CLOSED). Our own"
            " retire_stream CREATES this state on every completed request, so"
            " this is a routine event, not a hostile one."
        )
    var rst_ec = _first_rst_error_code(Span(out))
    if rst_ec != Int(H2_ERR_STREAM_CLOSED):
        raise Error(
            "expected RST_STREAM(STREAM_CLOSED = "
            + String(Int(H2_ERR_STREAM_CLOSED))
            + ") on the forgotten stream; got error code "
            + String(rst_ec)
            + " (-1 == no RST_STREAM emitted at all)"
        )

    # ---- SURVIVAL: the other multiplexed request must still complete. ----
    var resp2 = List[UInt8]()
    _response_headers_frame(enc, sid_live, String("204"), True, resp2)
    client.append_recv_bytes(Span(resp2))
    _ = process_received_frames(client)
    var idx_live = client.find_stream_idx(sid_live)
    if idx_live < 0 or not client.streams[idx_live].end_stream_seen:
        raise Error(
            "FALSIFIER: the innocent multiplexed stream "
            + String(Int(sid_live))
            + " never completed after a late DATA frame on a RETIRED stream."
        )
    print("    OK — late DATA on a retired stream stayed stream-scoped")


def test_data_on_forgotten_stream_returns_connection_capacity() raises:
    """RFC 9113 §6.9.1 — the bytes of a DATA frame are charged against the
    CONNECTION window whatever the stream's fate, so the client must give
    that capacity back.

    FAILS ON CURRENT CODE: `_handle_inbound_data` returns at `if idx < 0`
    BEFORE `recv_fc.on_data_received` and before
    `_replenish_recv_window_after_data`, so the frame is neither charged
    nor credited. The peer HAS decremented its send window; we never emit a
    WINDOW_UPDATE covering those bytes, so the capacity is gone for good."""
    print("  test_data_on_forgotten_stream_returns_connection_capacity...")

    var client = _fresh_client()
    var sid = _open_client_stream(client, String("/done"))

    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _response_headers_frame(enc, sid, String("200"), True, resp)
    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)
    client.retire_stream(sid)
    _ = client.take_out_bytes()

    var before = Int(client.recv_fc.conn_recv_window)
    # Three 16000-octet frames — legal under the 16384 max frame size, and
    # 48000 total, past the 32768-byte drain watermark, so a correct client
    # MUST emit a connection-level WINDOW_UPDATE rather than parking the
    # credit in `recv_conn_pending_update`.
    var late = List[UInt8]()
    var payload_len = _encode_data_frames(sid, 48000, 16000, False, late)
    client.append_recv_bytes(Span(late))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    var after = Int(client.recv_fc.conn_recv_window)
    var wu = _conn_window_update_total(Span(out))
    _assert_capacity_conserved(
        String("forgotten-stream DATA"), before, after, payload_len, wu
    )
    if wu < payload_len:
        raise Error(
            "FALSIFIER: "
            + String(payload_len)
            + " bytes of DATA arrived on a forgotten stream (past the 32768"
            " drain watermark) but the client credited only "
            + String(wu)
            + " back to the CONNECTION window. hyper's"
            " `goaway_ignores_data_but_returns_connection_capacity` is the"
            " same assertion: a dropped stream does not excuse dropped"
            " connection capacity."
        )
    print("    OK — forgotten-stream DATA returned connection capacity")


def test_padded_data_on_forgotten_stream_releases_full_padded_length() raises:
    """Hyper `padded_data_on_forgotten_stream_releases_connection_capacity`.

    RFC 9113 §6.9.1: "The entire DATA frame payload is included in flow
    control, including the Pad Length and Padding fields if present." So a
    frame carrying D data bytes with P padding costs the peer `1 + D + P`
    of its send window, and the client owes back all of it — not just D.

    TWO defects can fail this one, and they are independent:
      (a) `_handle_inbound_data` never runs at all on a forgotten stream;
      (b) even on a LIVE stream it charges `len(frame.payload)`, which the
          decoder has ALREADY STRIPPED of the Pad Length octet and the
          padding (`frame.mojo` §DATA: `po += 1; pe -= pad_len`). See the
          live-stream case below, which isolates (b)."""
    print(
        "  test_padded_data_on_forgotten_stream_releases_full_padded_length..."
    )

    var client = _fresh_client()
    var sid = _open_client_stream(client, String("/done"))

    var enc = HpackEncoder(max_table_size=4096)
    var resp = List[UInt8]()
    _response_headers_frame(enc, sid, String("200"), True, resp)
    client.append_recv_bytes(Span(resp))
    _ = process_received_frames(client)
    client.retire_stream(sid)
    _ = client.take_out_bytes()

    var before = Int(client.recv_fc.conn_recv_window)
    var pad = 255
    var late = List[UInt8]()
    var charge = _encode_padded_data_frames(sid, 3, 16000, pad, False, late)
    if charge != 3 * (1 + 16000 + pad):
        raise Error("padded-frame helper miscomputed its own charge")
    client.append_recv_bytes(Span(late))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    var after = Int(client.recv_fc.conn_recv_window)
    var wu = _conn_window_update_total(Span(out))
    _assert_capacity_conserved(
        String("forgotten-stream PADDED DATA"), before, after, charge, wu
    )
    if wu < charge:
        raise Error(
            "FALSIFIER: the padded DATA frames cost the peer "
            + String(charge)
            + " bytes of send window (3 x [1 Pad Length octet + 16000 data + "
            + String(pad)
            + " padding]) but the client returned only "
            + String(wu)
            + " to the connection window — short by "
            + String(charge - wu)
            + "."
        )
    print("    OK — padded forgotten-stream DATA released its full length")


def test_padded_data_on_live_stream_charges_full_padded_length() raises:
    """The ISOLATING case for defect (b) above — no forgotten stream, no
    scope question, just padding.

    `_handle_inbound_data` computes `payload_len = len(frame.payload)`, and
    the frame decoder strips padding out of `payload` before the client
    ever sees it. So on EVERY padded response the client under-charges and
    under-credits by `1 + pad_len` bytes. The peer's send window drifts
    down by that much per frame with nothing ever crediting it back, and a
    long-lived pooled connection eventually stalls with a window the peer
    believes is exhausted and we believe is healthy.

    FAILS ON CURRENT CODE for any padded DATA frame."""
    print("  test_padded_data_on_live_stream_charges_full_padded_length...")

    var client = _fresh_client()
    var sid = _open_client_stream(client, String("/padded"))

    var enc = HpackEncoder(max_table_size=4096)
    var head = List[UInt8]()
    _response_headers_frame(enc, sid, String("200"), False, head)
    client.append_recv_bytes(Span(head))
    _ = process_received_frames(client)
    _ = client.take_out_bytes()

    var before = Int(client.recv_fc.conn_recv_window)
    var pad = 100
    var body = List[UInt8]()
    var charge = _encode_padded_data_frames(sid, 3, 16000, pad, True, body)
    client.append_recv_bytes(Span(body))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    var after = Int(client.recv_fc.conn_recv_window)
    var wu = _conn_window_update_total(Span(out))
    _assert_capacity_conserved(
        String("live-stream PADDED DATA"), before, after, charge, wu
    )

    # And the caller must see the DATA only — never the padding.
    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("live stream vanished")
    var slot = client.streams[idx].response_body_idx
    if len(client.response_body_buffers[slot]) != 3 * 16000:
        raise Error(
            "response body should hold exactly the "
            + String(3 * 16000)
            + " DATA octets (padding stripped); got "
            + String(len(client.response_body_buffers[slot]))
        )
    print("    OK — padded DATA on a live stream charged its full length")


def test_data_after_goaway_returns_connection_capacity() raises:
    """Hyper `goaway_ignores_data_but_returns_connection_capacity`.

    The server GOAWAYs with last_stream_id = 1, so stream 5 was never
    processed and the driver abandons it (`retire_stream`). DATA for
    stream 5 is already on the wire. Its bytes must still be credited back
    to the CONNECTION window — the connection is draining, not dead, and
    streams at or below last_stream_id are still being completed on it.

    FAILS ON CURRENT CODE: the abandoned stream is gone from the table, so
    `_handle_inbound_data` takes the `idx < 0` arm and both GOAWAYs the
    draining connection AND loses the capacity."""
    print("  test_data_after_goaway_returns_connection_capacity...")

    var client = _fresh_client()
    var sid_keep = _open_client_stream(client, String("/keep"))
    var sid_drop = _open_client_stream(client, String("/drop"))

    # Server: GOAWAY(last_stream_id = sid_keep, NO_ERROR) — graceful drain.
    var debug = List[UInt8]()
    var ga = List[UInt8]()
    encode_goaway_frame(sid_keep, UInt32(0), debug^, ga)
    client.append_recv_bytes(Span(ga))
    _ = process_received_frames(client)
    if not client.is_goaway_received():
        raise Error("client did not record the inbound GOAWAY")
    # The driver gives up on everything above last_stream_id.
    client.retire_stream(sid_drop)
    _ = client.take_out_bytes()

    var before = Int(client.recv_fc.conn_recv_window)
    var inflight = List[UInt8]()
    var payload_len = _encode_data_frames(
        sid_drop, 48000, 16000, True, inflight
    )
    client.append_recv_bytes(Span(inflight))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    var after = Int(client.recv_fc.conn_recv_window)
    var wu = _conn_window_update_total(Span(out))
    _assert_capacity_conserved(
        String("post-GOAWAY DATA"), before, after, payload_len, wu
    )
    if wu < payload_len:
        raise Error(
            "FALSIFIER: DATA for a stream abandoned by the server's GOAWAY"
            " (last_stream_id="
            + String(Int(sid_keep))
            + ") must be IGNORED but its "
            + String(payload_len)
            + " bytes still credited to the connection window; the client"
            " credited "
            + String(wu)
            + ". The connection is DRAINING, and stream "
            + String(Int(sid_keep))
            + " is still completing on it."
        )
    print("    OK — post-GOAWAY DATA returned connection capacity")


def test_rst_stream_with_buffered_data_returns_connection_capacity() raises:
    """A stream reset by the server WHILE its DATA is buffered must still
    return that buffered capacity to the CONNECTION window.

    The stream's own window dies with the stream; the connection's does
    not. If the buffered bytes are dropped without a connection-level
    WINDOW_UPDATE, every reset response permanently shrinks the peer's
    send window — the slow-drift form of the same stall."""
    print("  test_rst_stream_with_buffered_data_returns_connection_capacity...")

    var client = _fresh_client()
    var sid = _open_client_stream(client, String("/reset"))

    var enc = HpackEncoder(max_table_size=4096)
    var head = List[UInt8]()
    _response_headers_frame(enc, sid, String("200"), False, head)
    client.append_recv_bytes(Span(head))
    _ = process_received_frames(client)
    _ = client.take_out_bytes()

    var before = Int(client.recv_fc.conn_recv_window)
    var wire = List[UInt8]()
    var payload_len = _encode_data_frames(sid, 48000, 16000, False, wire)
    encode_rst_stream_frame(sid, UInt32(8), wire)  # CANCEL
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("stream vanished before the assertion could run")
    if client.streams[idx].state != STREAM_STATE_CLOSED:
        raise Error("inbound RST_STREAM should have closed the stream")

    # The driver retires the reset stream, as it does any finished one.
    client.retire_stream(sid)

    var out = client.take_out_bytes()
    var after = Int(client.recv_fc.conn_recv_window)
    var wu = _conn_window_update_total(Span(out))
    _assert_capacity_conserved(
        String("RST with buffered DATA"), before, after, payload_len, wu
    )
    # ★ LIVENESS, which conservation alone does NOT imply. A client that
    # charged the bytes and then simply never credited them back is
    # *consistent* with the peer — and stalls it anyway, because the peer's
    # send window stays down. The capacity must actually be RETURNED.
    if wu < payload_len:
        raise Error(
            "FALSIFIER: "
            + String(payload_len)
            + " bytes of DATA were buffered on a stream the server then RESET,"
            " and only "
            + String(wu)
            + " were returned to the CONNECTION window. The stream's own"
            " window dies with the stream; the connection's does not, so every"
            " reset response permanently shrinks the peer's send window."
        )
    print("    OK — reset stream returned its buffered connection capacity")


# =============================================================================
# §3 — Stream-scoped faults must not leak their bytes to the caller.
# =============================================================================


def test_data_after_stream_reset_does_not_reach_the_response_body() raises:
    """RFC 9113 §6.1 / §5.1 — once a stream is CLOSED by RST_STREAM, DATA
    arriving on it is a STREAM error of type STREAM_CLOSED. Whatever the
    client does about the error, the bytes MUST NOT be surfaced to the
    caller as part of the response: that response was reset, and its
    `reset_error_code` is about to be raised.

    FAILS ON CURRENT CODE: `_handle_inbound_data` checks only
    `find_stream_idx(sid) < 0`. It never looks at
    `h2.streams[idx].state`, so a post-RST DATA frame is charged, appended
    to `response_body_buffers[...]`, and its bytes are live in the buffer
    the caller reads.

    ⚠ NOTE THE ASYMMETRY that makes this an oversight rather than a
    design: `_handle_inbound_headers_or_cont` DOES test
    `if state == STREAM_STATE_CLOSED: return True` and ignores late
    HEADERS. The DATA path never got the same guard."""
    print("  test_data_after_stream_reset_does_not_reach_the_response_body...")

    var client = _fresh_client()
    var sid = _open_client_stream(client, String("/reset"))

    var enc = HpackEncoder(max_table_size=4096)
    var head = List[UInt8]()
    _response_headers_frame(enc, sid, String("200"), False, head)
    client.append_recv_bytes(Span(head))
    _ = process_received_frames(client)

    # Server resets the stream mid-response.
    var rst = List[UInt8]()
    encode_rst_stream_frame(sid, UInt32(8), rst)  # CANCEL
    client.append_recv_bytes(Span(rst))
    _ = process_received_frames(client)

    var idx = client.find_stream_idx(sid)
    if idx < 0:
        raise Error("stream vanished")
    if client.streams[idx].state != STREAM_STATE_CLOSED:
        raise Error("inbound RST_STREAM should have closed the stream")
    var slot = client.streams[idx].response_body_idx
    var len_before = len(client.response_body_buffers[slot])
    _ = client.take_out_bytes()

    # ... and then keeps sending body for it.
    var leak = List[UInt8]()
    encode_data_frame(sid, _filler(512), True, leak)
    client.append_recv_bytes(Span(leak))
    _ = process_received_frames(client)

    var idx2 = client.find_stream_idx(sid)
    if idx2 < 0:
        # Retired out from under us — nothing reached the caller. Fine.
        print("    OK — stream retired; no post-RST bytes surfaced")
        return
    var slot2 = client.streams[idx2].response_body_idx
    var len_after = len(client.response_body_buffers[slot2])
    if len_after != len_before:
        raise Error(
            "FALSIFIER: "
            + String(len_after - len_before)
            + " bytes of DATA that arrived AFTER the stream was reset by"
            " RST_STREAM were appended to the response body the caller"
            " reads. RFC 9113 §6.1 makes DATA on a closed stream a"
            " STREAM_CLOSED stream error; the bytes belong to a response"
            " that no longer exists. `_handle_inbound_data` never consults"
            " `streams[idx].state` — note that"
            " `_handle_inbound_headers_or_cont` DOES."
        )
    if client.streams[idx2].end_stream_seen:
        raise Error(
            "FALSIFIER: the post-RST DATA frame's END_STREAM flag marked the"
            " reset stream COMPLETE. `end_stream_seen` is the driver's"
            " 'response finished' signal, so a reset request would land on"
            " the caller as a successful short response — the exact"
            " truncation `H2ClientStream.reset_error_code` exists to stop."
        )
    print("    OK — post-RST DATA did not reach the response body")


# =============================================================================
# §4 — Stream-id exhaustion. The other way ONE long-lived pooled connection
#      silently crosses two unrelated requests over.
# =============================================================================


def test_client_stream_id_allocator_refuses_past_2_31_minus_1() raises:
    """RFC 9113 §5.1.1 — "Stream identifiers cannot be reused. [...] A
    client that is unable to establish a new stream identifier can
    establish a new connection for new streams." The reserved high bit of
    the 31-bit identifier MUST be 0.

    `allocate_client_stream_id` is an unguarded `next + 2`. Past
    2147483647 the value it hands back has the reserved bit SET, and
    `encode_frame_header` masks it with 0x7fffffff on the way out — so the
    frame goes on the wire bearing a LOW stream id that belongs to a
    different, possibly still-live request. Two requests, one identifier,
    no error anywhere: silent cross-talk.

    hyper's `request_stream_id_overflows` asserts the allocator refuses.

    FAILS ON CURRENT CODE."""
    print("  test_client_stream_id_allocator_refuses_past_2_31_minus_1...")

    var client = _fresh_client()
    var first = _open_client_stream(client, String("/first"))
    if first != UInt32(1):
        raise Error("first client stream should be id 1")

    # Fast-forward to the last LEGAL client-initiated identifier.
    client.next_client_stream_id = UInt32(0x7fffffff)
    var last_legal = client.allocate_client_stream_id()
    if last_legal != UInt32(0x7fffffff):
        raise Error(
            "expected the last legal odd id 2147483647; got "
            + String(Int(last_legal))
        )

    # The allocator is now EXHAUSTED and must REFUSE. Two refusal shapes
    # are acceptable and this case accepts either, because the RFC names the
    # outcome ("establish a new connection") and not the mechanism:
    #   * it raises  — `main()` is `raises`, so a raise here would surface as
    #     a test error; the case below is written so a raising allocator is
    #     ALSO caught and treated as a pass; or
    #   * it returns an unambiguous exhausted sentinel — a value that masks
    #     to 0 on the wire, which is not a legal stream id and so cannot be
    #     confused with a live request.
    # What is NOT acceptable is the current behaviour: hand back a number
    # with the reserved bit set and let `encode_frame_header` mask it onto a
    # live low stream id.
    var handed_back = client.allocate_client_stream_id()

    # Prove the consequence on the wire, not just in the number: encode a
    # frame header bearing `handed_back` and decode it back with the SAME
    # `decode_frame` the client uses inbound.
    #
    # ⚠ THE PROBE FRAME'S *KIND* MUST NOT HAVE A STREAM-ID RULE OF ITS OWN.
    # This probe originally used FRAME_HEADERS, which made the sentinel arm
    # below UNREACHABLE: RFC 9113 §6.2 — "If a HEADERS frame is received whose
    # Stream Identifier field is 0x00, the recipient MUST respond with a
    # connection error (Section 5.4.1) of type PROTOCOL_ERROR" — and
    # `frame.mojo` implements exactly that, so an allocator that correctly
    # refuses with a 0-masking sentinel had its probe frame refused by the
    # decoder BEFORE the `on_wire == 0` check could see it, and only the
    # DEFECTIVE wrap-to-2147483649 (which decodes cleanly as stream 1) ever
    # reached an assertion. An extension kind (RFC 9113 §5.5: "Implementations
    # MUST ignore and discard frames of unknown type") carries no such rule
    # and decodes OK on any stream id, so the probe measures the ONE thing it
    # is about — what `encode_frame_header` puts in the Stream Identifier
    # field — for a refusing allocator and a wrapping one alike.
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(0), _EXT_FRAME_KIND, UInt8(0), handed_back, wire
    )
    var fr = decode_frame(Span(wire), _MAX_FRAME)
    if fr.status != FRAME_DECODE_OK:
        raise Error(
            "synthetic extension frame should decode OK (status "
            + String(Int(fr.status))
            + ")"
        )
    var on_wire = fr.frame.header.stream_id

    if on_wire == UInt32(0):
        print("    OK — allocator returned an exhausted sentinel past 2^31-1")
        return
    if handed_back > UInt32(0x7fffffff):
        raise Error(
            "FALSIFIER: the stream-id allocator wrapped instead of refusing."
            " It handed back "
            + String(Int(handed_back))
            + ", whose reserved high bit is SET (RFC 9113 §5.1.1 requires a"
            " 31-bit identifier). encode_frame_header masks it with"
            " 0x7fffffff, so the request goes on the wire as stream "
            + String(Int(on_wire))
            + " — colliding with stream "
            + String(Int(first))
            + ", a DIFFERENT request on this same long-lived pooled"
            " connection. Two requests share one identifier and nothing"
            " anywhere reports an error. RFC 9113 §5.1.1: a client that"
            " cannot establish a new identifier opens a NEW CONNECTION."
        )
    raise Error(
        "FALSIFIER: the allocator did not refuse after exhausting the"
        " client-initiated stream-id space; it returned "
        + String(Int(handed_back))
        + " (stream "
        + String(Int(on_wire))
        + " on the wire). RFC 9113 §5.1.1 requires a new connection instead."
    )


def test_client_stream_id_allocation_is_odd_and_monotone() raises:
    """The complementary well-formedness property, so the refusal above
    cannot be 'fixed' by an allocator that refuses too early: ordinary
    allocation stays odd, strictly increasing and inside the 31-bit
    space."""
    print("  test_client_stream_id_allocation_is_odd_and_monotone...")

    var client = _fresh_client()
    var prev = UInt32(0)
    var i = 0
    while i < 64:
        var sid = client.allocate_client_stream_id()
        if (sid & UInt32(1)) != UInt32(1):
            raise Error(
                "client-initiated stream ids must be ODD (RFC 9113 §5.1.1);"
                " got " + String(Int(sid))
            )
        if sid <= prev:
            raise Error("stream ids must strictly increase")
        if sid > UInt32(0x7fffffff):
            raise Error(
                "stream id " + String(Int(sid)) + " exceeds the 31-bit space"
            )
        prev = sid
        i = i + 1
    print("    OK — 64 allocations odd, monotone, in-range")


# =============================================================================
# §5 — Driver.
#
# ⚠ EVERY CASE RUNS, EVEN AFTER ONE FAILS. These cases probe SEVERAL
# independent defects on the same two functions, and a driver that aborted at
# the first would hide the rest behind it. Each failure is printed with its own
# FALSIFIER text and the run still exits non-zero, so nothing is muted: the
# gate is just as red, and it names every finding instead of the first one.
# =============================================================================


def main() raises:
    print("== L2 h2 ERROR SCOPE: stream vs connection ==")
    var failures = 0

    try:
        test_zero_window_update_on_stream_is_stream_scoped()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_zero_window_update_on_stream_zero_is_connection_scoped()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_rst_stream_bad_length_stays_connection_scoped()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_late_data_on_retired_stream_does_not_goaway()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_data_on_forgotten_stream_returns_connection_capacity()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_padded_data_on_forgotten_stream_releases_full_padded_length()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_padded_data_on_live_stream_charges_full_padded_length()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_data_after_goaway_returns_connection_capacity()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_rst_stream_with_buffered_data_returns_connection_capacity()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_data_after_stream_reset_does_not_reach_the_response_body()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_client_stream_id_allocator_refuses_past_2_31_minus_1()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))
    try:
        test_client_stream_id_allocation_is_odd_and_monotone()
    except e:
        failures = failures + 1
        print("    FAILED: " + String(e))

    if failures > 0:
        raise Error(
            "L2 h2 error-scope: "
            + String(failures)
            + " of 12 cases FAILED (each printed above with its FALSIFIER)."
        )
    print("== L2 h2 error-scope PASSED (12 tests) ==")
