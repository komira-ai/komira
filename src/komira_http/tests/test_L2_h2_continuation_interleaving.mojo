"""RFC 9113 §6.10 — CONTINUATION interleaving conformance, CLIENT side.

WHAT THIS FILE IS FOR. A header block is the ONE place in HTTP/2 where the
frame sequence is not free-form:

    RFC 9113 §6.10
      "A HEADERS frame without the END_HEADERS flag set MUST be followed by
       a CONTINUATION frame for the same stream. A receiver MUST treat the
       receipt of any other type of frame or a frame on a different stream
       as a connection error (Section 5.4.1) of type PROTOCOL_ERROR."

The reason it is a CONNECTION error and not a stream error is that HPACK's
dynamic table is per-connection and strictly ordered. A header block that is
interrupted leaves the decoder mid-block; every subsequent request on that
connection decodes against a table the peer does not have. There is no
recovery short of tearing the connection down — which is exactly why the RFC
says the receiver MUST tear it down.

Groups here, and what each is for:

  A. INTERLEAVED FRAME INSIDE AN OPEN HEADER BLOCK (8 cases, one per frame
     type the client's dispatch switch can reach). h2spec covers this in
     http2/6.10/{2,3,4,5}, http2/5.5/2, http2/4.3/2 and http2/6.2/1; Go's
     `TestReadFrameOrder` pins the same set with eight distinct error
     strings ("got DATA for stream 1; expected CONTINUATION following
     HEADERS for stream 1", and siblings).

  B. CONTINUATION IDENTITY — wrong stream, stream 0, a second complete
     HEADERS on another stream, a CONTINUATION with no block open, a
     CONTINUATION after END_HEADERS already closed the block.

  C. CONTINUATION FLOOD — the CVE-2024-27316 shape. An unbounded
     CONTINUATION stream must be refused with bounded memory. The ceilings
     (`H2_MAX_HEADER_BLOCK_FRAMES` = 64, `H2_MAX_HEADER_BLOCK_BYTES` = 65536)
     exist in `_append_client_header_block` and had NO test.

  D. ⭐ POSITIVE CONTROLS, and they are load-bearing. The fix for group A is
     a check added to a hot dispatch loop, and the cheapest way to get that
     wrong is to become strict about frames the RFC says to IGNORE. An
     over-strict client that GOAWAYs a legitimate extension frame, or a PING
     carrying undefined flag bits, is a self-inflicted outage against any
     server that ships one. These MUST stay green through any group-A fix.

  E. OUTBOUND SPLITTER vs. a MID-CONNECTION SETTINGS. `split_header_block_
     into_frames` takes `max_frame_size` as a parameter and every existing
     splitter test passes a constant — so nothing pins that the CALLER
     re-reads `h2.max_frame_size_peer` instead of capturing it once at
     connection setup. A client that captured it would emit oversized frames
     the moment a server changed SETTINGS_MAX_FRAME_SIZE, and get
     FRAME_SIZE_ERROR'd off the connection.

⚠⚠ THE GROUPS ARE NOT INDEPENDENT, AND THAT WAS MEASURED, NOT ASSUMED.
Mutating `_handle_inbound_headers_or_cont` to DROP each CONTINUATION payload
instead of appending it turns SEVEN of the eight group-A cases GREEN: the
reassembly buffer then holds only the HEADERS half, `decode_block` raises, and
the same GOAWAY(PROTOCOL_ERROR) comes out — the right answer reached by a
client that has simply stopped reassembling. The cases that catch that
pseudo-fix are D1 (the response must still be delivered), C1 and C2 (the flood
ceilings must still be the thing that refuses). So: ⛔ do not "fix" group A by
touching reassembly, and do not read a green group A on its own as the class
being closed — read the whole file.

⚠ All of this is sans-io: raw frame bytes into `append_recv_bytes`, then
`process_received_frames`, then read `take_out_bytes`. No socket, no TLS, no
server. Same idiom as `test_L2_h2_client_request_response.mojo`.
"""

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    process_received_frames,
)
from komira_http.client.header_map import HeaderMap
from komira_http.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    H2_ERR_CANCEL,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_FRAME_SIZE,
    SettingsEntry,
    decode_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader


# =============================================================================
# Wire helpers.
#
# ⚠ These write the 9-byte frame header BY HAND rather than going through
# `encode_frame_header`, for two reasons this file depends on:
#   * `encode_frame_header` MASKS the reserved stream-id bit (`& 0x7fffffff`),
#     so it cannot produce the RFC 9113 §4.1 "R bit set" wire shape test D4 needs.
#   * there is no `encode_continuation_frame` / `encode_priority_frame` in the
#     codec (the client only ever RECEIVES those two), and no encoder at all
#     for an unknown/extension frame type.
# =============================================================================


comptime _MAX_DECODE = 16777215


def _push_u24(v: Int, mut out: List[UInt8]):
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _push_u32(v: Int, mut out: List[UInt8]):
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _raw_frame(
    kind: UInt8,
    flags: UInt8,
    sid_raw: Int,
    payload: Span[UInt8, _],
    mut out: List[UInt8],
):
    """One frame, header written verbatim — `sid_raw` is NOT masked."""
    _push_u24(len(payload), out)
    out.append(kind)
    out.append(flags)
    _push_u32(sid_raw, out)
    var i = 0
    while i < len(payload):
        out.append(payload[i])
        i = i + 1


def _headers_frame(
    sid: Int,
    payload: Span[UInt8, _],
    end_headers: Bool,
    end_stream: Bool,
    mut out: List[UInt8],
):
    var flags = UInt8(0)
    if end_headers:
        flags = flags | FLAG_END_HEADERS
    if end_stream:
        flags = flags | FLAG_END_STREAM
    _raw_frame(FRAME_HEADERS, flags, sid, payload, out)


def _continuation_frame(
    sid: Int,
    payload: Span[UInt8, _],
    end_headers: Bool,
    mut out: List[UInt8],
):
    var flags = FLAG_END_HEADERS if end_headers else UInt8(0)
    _raw_frame(FRAME_CONTINUATION, flags, sid, payload, out)


def _data_frame(sid: Int, n: Int, end_stream: Bool, mut out: List[UInt8]):
    var body = List[UInt8]()
    var i = 0
    while i < n:
        body.append(UInt8(65 + (i % 26)))
        i = i + 1
    var flags = FLAG_END_STREAM if end_stream else UInt8(0)
    _raw_frame(FRAME_DATA, flags, sid, Span(body), out)


def _settings_frame(ident: UInt16, value: UInt32, mut out: List[UInt8]):
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(identifier=ident, value=value))
    encode_settings_frame(entries^, out)


def _ping_frame(seed: UInt8, flags: UInt8, mut out: List[UInt8]):
    """PING with caller-chosen FLAGS — `encode_ping_frame` only offers ACK,
    and test D3 needs every undefined bit set."""
    var payload = List[UInt8]()
    var i = 0
    while i < 8:
        payload.append(seed + UInt8(i))
        i = i + 1
    _raw_frame(FRAME_PING, flags, 0, Span(payload), out)


def _window_update_frame(sid: Int, increment: Int, mut out: List[UInt8]):
    var payload = List[UInt8]()
    _push_u32(increment, payload)
    _raw_frame(FRAME_WINDOW_UPDATE, UInt8(0), sid, Span(payload), out)


def _rst_stream_frame(sid: Int, error_code: UInt32, mut out: List[UInt8]):
    var payload = List[UInt8]()
    _push_u32(Int(error_code), payload)
    _raw_frame(FRAME_RST_STREAM, UInt8(0), sid, Span(payload), out)


def _goaway_frame(last_sid: Int, error_code: UInt32, mut out: List[UInt8]):
    var payload = List[UInt8]()
    _push_u32(last_sid, payload)
    _push_u32(Int(error_code), payload)
    _raw_frame(FRAME_GOAWAY, UInt8(0), 0, Span(payload), out)


def _priority_frame(sid: Int, dep: Int, weight: UInt8, mut out: List[UInt8]):
    """PRIORITY is exactly 5 bytes (RFC 9113 §6.3)."""
    var payload = List[UInt8]()
    _push_u32(dep, payload)
    payload.append(weight)
    _raw_frame(FRAME_PRIORITY, UInt8(0), sid, Span(payload), out)


def _extension_frame(kind: UInt8, sid: Int, n: Int, mut out: List[UInt8]):
    """An UNKNOWN frame type — what RFC 9113 §4.1 says to ignore OUTSIDE a
    header block, and what §6.10 says is a PROTOCOL_ERROR INSIDE one."""
    var payload = List[UInt8]()
    var i = 0
    while i < n:
        payload.append(UInt8(i % 256))
        i = i + 1
    _raw_frame(kind, UInt8(0), sid, Span(payload), out)


def _blob(n: Int, seed: Int) -> List[UInt8]:
    var b = List[UInt8]()
    var i = 0
    while i < n:
        b.append(UInt8((i + seed) % 256))
        i = i + 1
    return b^


# =============================================================================
# Inspection helpers — read the client's OUTBOUND queue as a frame stream.
# =============================================================================


def _first_goaway_error(buf: Span[UInt8, _]) -> Int:
    """Error code of the FIRST GOAWAY in `buf`; -1 if there is none, -2 if
    the buffer does not decode as a frame stream at all."""
    var off = 0
    while off < len(buf):
        var res = decode_frame(buf[off:], _MAX_DECODE)
        if res.status != FRAME_DECODE_OK:
            return -2
        if res.frame.header.kind == FRAME_GOAWAY:
            return Int(res.frame.goaway_error_code)
        off = off + res.consumed
    return -1


def _count_ping_acks(buf: Span[UInt8, _]) -> Int:
    var off = 0
    var n = 0
    while off < len(buf):
        var res = decode_frame(buf[off:], _MAX_DECODE)
        if res.status != FRAME_DECODE_OK:
            return -2
        if res.frame.header.kind == FRAME_PING:
            if (res.frame.header.flags & FLAG_ACK) != UInt8(0):
                n = n + 1
        off = off + res.consumed
    return n


def _max_frame_payload(buf: Span[UInt8, _]) -> Int:
    """Largest payload length over every frame in `buf`; -2 on decode fail."""
    var off = 0
    var best = -1
    while off < len(buf):
        var res = decode_frame(buf[off:], _MAX_DECODE)
        if res.status != FRAME_DECODE_OK:
            return -2
        var ln = Int(res.frame.header.length)
        if ln > best:
            best = ln
        off = off + res.consumed
    return best


# =============================================================================
# Assertions.
# =============================================================================


def _assert_protocol_error(
    mut client: H2ClientConnectionState, case_name: String
) raises:
    """RFC 9113 §6.10 — an interrupted header block is a CONNECTION error of
    type PROTOCOL_ERROR. The client must stage GOAWAY(0x1)."""
    var out = client.take_out_bytes()
    var ec = _first_goaway_error(Span(out))
    if ec == -2:
        raise Error(
            case_name
            + ": the client's outbound queue is not a decodable frame stream"
        )
    if ec == -1:
        raise Error(
            case_name
            + ": expected GOAWAY(PROTOCOL_ERROR) — RFC 9113 §6.10 makes an"
            + " interleaved frame inside an open HEADERS block a CONNECTION"
            + " error. Got NO GOAWAY (outbound = "
            + String(len(out))
            + " bytes). The frame was dispatched against a half-decoded"
            + " per-connection HPACK state and the header block was left open."
        )
    if ec != Int(H2_ERR_PROTOCOL_ERROR):
        raise Error(
            case_name
            + ": expected GOAWAY error_code=1 (PROTOCOL_ERROR); got "
            + String(ec)
        )


def _assert_goaway_code(
    mut client: H2ClientConnectionState, want: UInt32, case_name: String
) raises:
    var out = client.take_out_bytes()
    var ec = _first_goaway_error(Span(out))
    if ec < 0:
        raise Error(
            case_name
            + ": expected GOAWAY with error_code="
            + String(Int(want))
            + "; got no GOAWAY (outbound = "
            + String(len(out))
            + " bytes)"
        )
    if ec != Int(want):
        raise Error(
            case_name
            + ": expected GOAWAY error_code="
            + String(Int(want))
            + "; got "
            + String(ec)
        )


def _require_no_goaway(buf: Span[UInt8, _], case_name: String) raises:
    var ec = _first_goaway_error(buf)
    if ec == -2:
        raise Error(case_name + ": outbound queue does not decode")
    if ec >= 0:
        raise Error(
            case_name
            + ": OVER-STRICT — the client emitted GOAWAY(error_code="
            + String(ec)
            + ") on traffic RFC 9113 requires it to accept. A client that"
            + " tears the connection down here is a self-inflicted outage"
            + " against any server shipping the construct."
        )


def _assert_interrupted_block_never_completed(
    mut client: H2ClientConnectionState, case_name: String
) raises:
    """GROUP A ONLY. The block that the injected frame interrupted must never
    be assembled, so stream 1 must carry no response.

    ⚠ NOT part of `_assert_protocol_error`: in B4/B5 the first header block
    completes LEGITIMATELY and the error is a later stray frame, so stream 1
    holding a 200 there is correct.
    """
    var idx1 = client.find_stream_idx(UInt32(1))
    if idx1 < 0:
        return
    if client.streams[idx1].response_status != UInt16(0):
        raise Error(
            case_name
            + ": the response was DELIVERED on stream 1 (status "
            + String(Int(client.streams[idx1].response_status))
            + ") even though the header block carrying it was interrupted."
            + " RFC 9113 §6.10 makes the interruption a connection error;"
            + " the block must never complete."
        )


# =============================================================================
# Fixture: a client with one open stream, and a SPLIT response header block.
# =============================================================================


def _new_client_with_stream() -> H2ClientConnectionState:
    """A client that has sent a request on stream 1 and is awaiting the
    response HEADERS."""
    var client = H2ClientConnectionState()
    var sid = client.allocate_client_stream_id()  # 1
    _ = client.create_stream(sid)
    return client^


def _response_block(mut enc: HpackEncoder, status: String) -> List[UInt8]:
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), status))
    hdrs.append(HpackHeader(String("content-type"), String("text/plain")))
    hdrs.append(HpackHeader(String("x-trailer-probe"), String("interleave")))
    return enc.encode_block(hdrs^)


def _slice(src: List[UInt8], lo: Int, hi: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var i = lo
    while i < hi:
        out.append(src[i])
        i = i + 1
    return out^


def _open_block_then(
    mut client: H2ClientConnectionState,
    injected: Span[UInt8, _],
) raises:
    """Feed: HEADERS(stream 1, END_HEADERS CLEAR) -> `injected` -> the
    CONTINUATION that would have completed the block. Then dispatch.

    The trailing CONTINUATION is deliberate: without it a conforming client
    could be mistaken for a buggy one that merely buffered. With it, a client
    that ignores §6.10 goes on to deliver the response as if nothing happened,
    which is precisely the silent desync this file exists to catch.
    """
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var mid = len(block) // 2
    var head = _slice(block, 0, mid)
    var tail = _slice(block, mid, len(block))

    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    var j = 0
    while j < len(injected):
        wire.append(injected[j])
        j = j + 1
    _continuation_frame(1, Span(tail), True, wire)

    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)


# =============================================================================
# GROUP A — an interleaved frame inside an open header block.
#
# RFC 9113 §6.10: "A receiver MUST treat the receipt of any other type of
# frame ... as a connection error ... of type PROTOCOL_ERROR."
#
# One test per frame type `process_received_frames` can dispatch. The guard
# the client DOES have lives inside `_handle_inbound_headers_or_cont`, so it
# only ever sees HEADERS and CONTINUATION; every arm below reaches the switch
# before that function is called.
# =============================================================================


def test_data_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/6.10/2. Go frame_test: "got DATA for stream 1; expected
    CONTINUATION following HEADERS for stream 1"."""
    print("  A1 data_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _data_frame(1, 8, False, inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A1 DATA inside header block")
    )
    _assert_protocol_error(client, String("A1 DATA inside header block"))
    print("    OK")


def test_settings_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/6.10/3. SETTINGS is a connection-level frame, which is
    exactly why it looks safe to process here and is not."""
    print("  A2 settings_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _settings_frame(SETTINGS_INITIAL_WINDOW_SIZE, UInt32(98304), inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A2 SETTINGS inside header block")
    )
    _assert_protocol_error(client, String("A2 SETTINGS inside header block"))
    print("    OK")


def test_window_update_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/6.10/3 sibling."""
    print("  A3 window_update_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _window_update_frame(0, 1024, inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A3 WINDOW_UPDATE inside header block")
    )
    _assert_protocol_error(
        client, String("A3 WINDOW_UPDATE inside header block")
    )
    print("    OK")


def test_ping_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/6.10/4 — and the PING must NOT be echoed. Answering a
    PING mid-block is an ACTIVE wire response emitted from a connection whose
    HPACK state is already unrecoverable."""
    print("  A4 ping_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _ping_frame(UInt8(0x11), UInt8(0), inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A4 PING inside header block")
    )
    var out = client.take_out_bytes()
    var acks = _count_ping_acks(Span(out))
    if acks != 0:
        raise Error(
            "A4 PING inside header block: the client ECHOED "
            + String(acks)
            + " PING-ACK(s). RFC 9113 §6.10 makes this frame a connection"
            + " error; a client that answers it has replied on a connection"
            + " it is required to be tearing down."
        )
    var ec = _first_goaway_error(Span(out))
    if ec != Int(H2_ERR_PROTOCOL_ERROR):
        raise Error(
            "A4 PING inside header block: expected GOAWAY(PROTOCOL_ERROR);"
            + " got "
            + String(ec)
            + " (-1 = no GOAWAY at all)"
        )
    print("    OK")


def test_rst_stream_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/6.10/5. The RST also CLOSES the very stream whose header
    block is open, so the block can never be completed."""
    print("  A5 rst_stream_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _rst_stream_frame(1, H2_ERR_CANCEL, inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A5 RST_STREAM inside header block")
    )
    _assert_protocol_error(client, String("A5 RST_STREAM inside header block"))
    print("    OK")


def test_goaway_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/6.10 sibling. A GOAWAY here is indistinguishable from an
    injected one, because the connection is already desynchronised."""
    print("  A6 goaway_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _goaway_frame(1, H2_ERR_NO_ERROR, inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A6 GOAWAY inside header block")
    )
    _assert_protocol_error(client, String("A6 GOAWAY inside header block"))
    print("    OK")


def test_unknown_frame_inside_open_header_block_is_protocol_error() raises:
    """★ h2spec http2/5.5/2. RFC 9113 §5.5 permits extension frames and §4.1
    says unknown types MUST be ignored — but §5.5 states the exception
    explicitly: "Extension frames ... MUST NOT be sent in the middle of a
    header block." The client's unknown-type fallthrough currently swallows
    it, so an extension frame is the CHEAPEST way for a server to desync us.
    """
    print("  A7 unknown_frame_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _extension_frame(UInt8(0xFF), 1, 4, inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A7 extension frame 0xFF inside header block")
    )
    _assert_protocol_error(
        client, String("A7 extension frame 0xFF inside header block")
    )
    print("    OK")


def test_priority_inside_open_header_block_is_protocol_error() raises:
    """h2spec http2/4.3/2 + http2/6.2/1. PRIORITY is deprecated and ignored
    everywhere else, which is why its dispatch arm is a bare `continue`."""
    print("  A8 priority_inside_open_header_block...")
    var client = _new_client_with_stream()
    var inj = List[UInt8]()
    _priority_frame(1, 0, UInt8(16), inj)
    _open_block_then(client, Span(inj))
    _assert_interrupted_block_never_completed(
        client, String("A8 PRIORITY inside header block")
    )
    _assert_protocol_error(client, String("A8 PRIORITY inside header block"))
    print("    OK")


# =============================================================================
# GROUP B — CONTINUATION identity.
# =============================================================================


def test_continuation_on_different_stream_is_protocol_error() raises:
    """Block open on stream 1; CONTINUATION arrives on stream 3."""
    print("  B1 continuation_on_different_stream...")
    var client = H2ClientConnectionState()
    var sid1 = client.allocate_client_stream_id()  # 1
    var sid3 = client.allocate_client_stream_id()  # 3
    _ = client.create_stream(sid1)
    _ = client.create_stream(sid3)

    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var mid = len(block) // 2
    var head = _slice(block, 0, mid)
    var tail = _slice(block, mid, len(block))

    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    _continuation_frame(3, Span(tail), True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)
    _assert_protocol_error(client, String("B1 CONTINUATION on stream 3"))
    print("    OK")


def test_continuation_on_stream_zero_is_protocol_error() raises:
    """CONTINUATION carries a header-block fragment; stream 0 is the
    connection control stream and has none (RFC 9113 §6.10 / §4.1)."""
    print("  B2 continuation_on_stream_zero...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var mid = len(block) // 2
    var head = _slice(block, 0, mid)
    var tail = _slice(block, mid, len(block))

    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    _continuation_frame(0, Span(tail), True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)
    _assert_protocol_error(client, String("B2 CONTINUATION on stream 0"))
    print("    OK")


def test_complete_headers_on_other_stream_mid_block_is_protocol_error() raises:
    """A whole, well-formed HEADERS (END_HEADERS set) on stream 3 while
    stream 1's block is open. Well-formed in isolation; a connection error in
    context — and the case that proves the instrument reaches the ONE guard
    the client already has (`h2_client.mojo` cont_reasm_stream_id check)."""
    print("  B3 complete_headers_on_other_stream_mid_block...")
    var client = H2ClientConnectionState()
    var sid1 = client.allocate_client_stream_id()
    var sid3 = client.allocate_client_stream_id()
    _ = client.create_stream(sid1)
    _ = client.create_stream(sid3)

    var enc = HpackEncoder(max_table_size=4096)
    var open_block = _response_block(enc, String("200"))
    var mid = len(open_block) // 2
    var head = _slice(open_block, 0, mid)

    var enc2 = HpackEncoder(max_table_size=4096)
    var whole = _response_block(enc2, String("204"))

    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    _headers_frame(3, Span(whole), True, True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    # ⚠ THE GOAWAY ALONE DOES NOT DISCRIMINATE, AND THAT WAS MEASURED.
    # With the cont_reasm_stream_id guard DELETED, stream 3's fragment is
    # appended to stream 1's half-filled reassembly buffer, the concatenation
    # is not valid HPACK, `decode_block` raises, and the same
    # GOAWAY(PROTOCOL_ERROR) comes out — a right answer reached by having
    # already corrupted the connection. The two assertions below are what
    # separate "refused" from "corrupted, then noticed": the refusal must
    # happen BEFORE the frame can touch the connection's single reassembly
    # slot, so stream 1 must still own it.
    if client.cont_reasm_stream_id != UInt32(1):
        raise Error(
            "B3: stream 1's in-flight reassembly was HIJACKED —"
            + " cont_reasm_stream_id is now "
            + String(Int(client.cont_reasm_stream_id))
            + ", not 1. The HEADERS on stream 3 must be refused before it"
            + " can take over the connection's single reassembly slot."
        )
    var idx3 = client.find_stream_idx(UInt32(3))
    if idx3 >= 0:
        if client.streams[idx3].response_status != UInt16(0):
            raise Error(
                "B3: a response was DELIVERED on stream 3 (status "
                + String(Int(client.streams[idx3].response_status))
                + ") from a HEADERS frame that RFC 9113 §6.10 makes a"
                + " connection error"
            )
    _assert_protocol_error(
        client, String("B3 complete HEADERS on stream 3 mid-block")
    )
    print("    OK")


def test_continuation_after_end_headers_is_protocol_error() raises:
    """HEADERS carried END_HEADERS, so the block is CLOSED; a CONTINUATION
    now belongs to nothing (RFC 9113 §6.10)."""
    print("  B4 continuation_after_end_headers...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))

    # ⚠ The stray fragment is VALID HPACK on purpose. An arbitrary blob would
    # make `decode_block` raise, and a client with NO identity guard at all
    # would then emit the same GOAWAY(PROTOCOL_ERROR) — the test would pass
    # against broken code.
    var enc2 = HpackEncoder(max_table_size=4096)
    var stray = _response_block(enc2, String("500"))
    var wire = List[UInt8]()
    _headers_frame(1, Span(block), True, False, wire)
    _continuation_frame(1, Span(stray), True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)
    _assert_protocol_error(
        client, String("B4 CONTINUATION after END_HEADERS")
    )
    print("    OK")


def test_continuation_after_block_completed_is_protocol_error() raises:
    """HEADERS(no END_HEADERS) + CONTINUATION(END_HEADERS) closes the block;
    a third frame is a stray CONTINUATION."""
    print("  B5 continuation_after_block_completed...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var mid = len(block) // 2
    var head = _slice(block, 0, mid)
    var tail = _slice(block, mid, len(block))

    # VALID HPACK for the stray, for the reason spelled out in B4.
    var enc2 = HpackEncoder(max_table_size=4096)
    var stray = _response_block(enc2, String("500"))
    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    _continuation_frame(1, Span(tail), True, wire)
    _continuation_frame(1, Span(stray), True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)
    _assert_protocol_error(
        client, String("B5 third CONTINUATION after block completed")
    )
    print("    OK")


# =============================================================================
# GROUP C — CONTINUATION flood (CVE-2024-27316 shape).
#
# HEADERS/CONTINUATION are NOT flow-controlled in either direction, so a
# hostile ORIGIN floods our client exactly as a hostile client floods our
# server. The ceilings live in `_append_client_header_block`; neither had a
# test before this file.
# =============================================================================


def test_continuation_flood_frame_ceiling_is_enforced() raises:
    """70 CONTINUATION frames, none with END_HEADERS. The client must refuse
    with GOAWAY(ENHANCE_YOUR_CALM) and DROP the reassembly buffer rather than
    growing it."""
    print("  C1 continuation_flood_frame_ceiling...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var head = _slice(block, 0, len(block) // 2)

    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    var pad = _blob(4, 1)
    var k = 0
    while k < 70:
        _continuation_frame(1, Span(pad), False, wire)
        k = k + 1
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)
    _assert_goaway_code(
        client,
        H2_ERR_ENHANCE_YOUR_CALM,
        String("C1 CONTINUATION flood (frame ceiling)"),
    )
    if len(client.cont_reasm_buf) != 0:
        raise Error(
            "C1: reassembly buffer retained "
            + String(len(client.cont_reasm_buf))
            + " bytes after refusing the flood — the ceiling must also"
            + " RELEASE the memory, or the DoS lands anyway"
        )
    if client.cont_reasm_stream_id != UInt32(0):
        raise Error("C1: cont_reasm_stream_id not cleared after refusal")
    print("    OK")


def test_continuation_flood_byte_ceiling_is_enforced() raises:
    """Few frames, enormous bytes: 6 x 16000-byte CONTINUATION payloads is
    96000 bytes over the 65536-byte ceiling while staying well under the
    64-frame one — so this pins the SECOND ceiling, not the first."""
    print("  C2 continuation_flood_byte_ceiling...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var head = _slice(block, 0, len(block) // 2)

    var wire = List[UInt8]()
    _headers_frame(1, Span(head), False, False, wire)
    var big = _blob(16000, 5)
    var k = 0
    while k < 6:
        _continuation_frame(1, Span(big), False, wire)
        k = k + 1
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)
    _assert_goaway_code(
        client,
        H2_ERR_ENHANCE_YOUR_CALM,
        String("C2 CONTINUATION flood (byte ceiling)"),
    )
    if len(client.cont_reasm_buf) != 0:
        raise Error(
            "C2: reassembly buffer retained "
            + String(len(client.cont_reasm_buf))
            + " bytes after refusing the flood"
        )
    print("    OK")


# =============================================================================
# GROUP D — POSITIVE CONTROLS.
#
# ⭐ Every one of these must stay GREEN through any fix for group A. They are
# the half of the conformance bar that says what the client must NOT reject.
# =============================================================================


def test_headers_plus_two_continuations_delivers_response() raises:
    """The legitimate shape §6.10 exists to allow: HEADERS(no END_HEADERS)
    + CONTINUATION + CONTINUATION(END_HEADERS). Must decode and deliver."""
    print("  D1 headers_plus_two_continuations_delivers...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))
    var a = len(block) // 3
    var b = (2 * len(block)) // 3
    var p1 = _slice(block, 0, a)
    var p2 = _slice(block, a, b)
    var p3 = _slice(block, b, len(block))

    var wire = List[UInt8]()
    _headers_frame(1, Span(p1), False, True, wire)
    _continuation_frame(1, Span(p2), False, wire)
    _continuation_frame(1, Span(p3), True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    _require_no_goaway(Span(out), String("D1 HEADERS + 2 CONTINUATIONs"))

    var idx = client.find_stream_idx(UInt32(1))
    if idx < 0:
        raise Error("D1: stream 1 disappeared")
    if client.streams[idx].response_status != UInt16(200):
        raise Error(
            "D1: expected :status 200 after 3-frame reassembly; got "
            + String(Int(client.streams[idx].response_status))
        )
    var triple = extract_response_for_stream(client, UInt32(1))
    if triple[0] != UInt16(200):
        raise Error("D1: extracted status is not 200")
    ref hdrs = triple[1]
    if not hdrs.contains(String("x-trailer-probe")):
        raise Error(
            "D1: the header carried in the LAST CONTINUATION fragment is"
            + " missing — reassembly dropped a fragment"
        )
    if client.cont_reasm_stream_id != UInt32(0):
        raise Error("D1: reassembly state not cleared after END_HEADERS")
    print("    OK")


def test_unknown_frame_outside_header_block_is_ignored() raises:
    """RFC 9113 §4.1: "Implementations MUST ignore and discard frames of
    unknown types." Outside a header block that rule is unconditional — and
    a following PING must still be answered, proving the connection kept
    working rather than merely not GOAWAYing."""
    print("  D2 unknown_frame_outside_header_block_ignored...")
    var client = _new_client_with_stream()
    var wire = List[UInt8]()
    _extension_frame(UInt8(0xFF), 0, 12, wire)
    _extension_frame(UInt8(0x42), 1, 3, wire)
    _ping_frame(UInt8(0x70), UInt8(0), wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    _require_no_goaway(Span(out), String("D2 extension frames outside block"))
    var acks = _count_ping_acks(Span(out))
    if acks != 1:
        raise Error(
            "D2: expected exactly 1 PING-ACK after two ignored extension"
            + " frames; got "
            + String(acks)
            + ". An extension frame must not disturb the connection."
        )
    print("    OK")


def test_ping_with_undefined_flags_is_still_a_ping() raises:
    """RFC 9113 §4.1: "Flags that have no defined semantics for a particular
    frame type MUST be ignored." Bits 0x02..0x80 are undefined on PING; only
    0x01 (ACK) is defined. A client that treats 0xFE as "not a PING" stops
    answering keepalives from any peer that sets a reserved bit."""
    print("  D3 ping_with_undefined_flags_still_pings...")
    var client = _new_client_with_stream()
    var wire = List[UInt8]()
    _ping_frame(UInt8(0x90), UInt8(0xFE), wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    _require_no_goaway(Span(out), String("D3 PING with undefined flags"))
    var acks = _count_ping_acks(Span(out))
    if acks != 1:
        raise Error(
            "D3: PING with flags=0xFE (every undefined bit set, ACK clear)"
            + " must still be answered with exactly one PING-ACK; got "
            + String(acks)
        )
    print("    OK")


def test_reserved_stream_id_bit_is_masked_off() raises:
    """RFC 9113 §4.1: the R bit "MUST be ignored when receiving". A response
    HEADERS on stream_id 0x80000001 is a response on stream 1 — a client that
    compares the raw 32 bits routes it to a stream that does not exist and
    loses the response."""
    print("  D4 reserved_stream_id_bit_masked...")
    var client = _new_client_with_stream()
    var enc = HpackEncoder(max_table_size=4096)
    var block = _response_block(enc, String("200"))

    var wire = List[UInt8]()
    # 0x80000001 — reserved bit SET, stream id 1 underneath.
    _headers_frame(0x80000001, Span(block), True, True, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    _require_no_goaway(Span(out), String("D4 reserved stream-id bit"))
    var idx = client.find_stream_idx(UInt32(1))
    if idx < 0:
        raise Error("D4: stream 1 disappeared")
    if client.streams[idx].response_status != UInt16(200):
        raise Error(
            "D4: HEADERS on stream_id 0x80000001 must route to stream 1;"
            + " status on stream 1 is "
            + String(Int(client.streams[idx].response_status))
            + " (0 = the frame never landed)"
        )
    print("    OK")


def test_priority_outside_header_block_is_ignored() raises:
    """PRIORITY is deprecated (RFC 9113 §5.3.2) but legal on the wire; a
    client MUST NOT error on it outside a header block."""
    print("  D5 priority_outside_header_block_ignored...")
    var client = _new_client_with_stream()
    var wire = List[UInt8]()
    _priority_frame(1, 0, UInt8(200), wire)
    _ping_frame(UInt8(0x33), UInt8(0), wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    _require_no_goaway(Span(out), String("D5 PRIORITY outside header block"))
    if _count_ping_acks(Span(out)) != 1:
        raise Error("D5: connection stopped working after a PRIORITY frame")
    print("    OK")


def test_settings_and_window_update_outside_block_still_work() raises:
    """The complement of A2/A3: the SAME frames, OUTSIDE a header block, must
    be processed normally. Without this control an over-strict fix that
    refuses SETTINGS everywhere would still pass A2."""
    print("  D6 settings_and_window_update_outside_block...")
    var client = _new_client_with_stream()
    var wire = List[UInt8]()
    _settings_frame(SETTINGS_INITIAL_WINDOW_SIZE, UInt32(98304), wire)
    _window_update_frame(0, 4096, wire)
    client.append_recv_bytes(Span(wire))
    _ = process_received_frames(client)

    var out = client.take_out_bytes()
    _require_no_goaway(Span(out), String("D6 SETTINGS/WINDOW_UPDATE outside"))
    if not client.is_server_settings_seen():
        raise Error("D6: inbound SETTINGS was not applied")
    if Int(client.send_fc.initial_window_size) != 98304:
        raise Error(
            "D6: SETTINGS_INITIAL_WINDOW_SIZE not applied; got "
            + String(Int(client.send_fc.initial_window_size))
        )
    var acks = 0
    var off = 0
    var span = Span(out)
    while off < len(span):
        var res = decode_frame(span[off:], _MAX_DECODE)
        if res.status != FRAME_DECODE_OK:
            raise Error("D6: outbound does not decode")
        if res.frame.header.kind == FRAME_SETTINGS:
            if (res.frame.header.flags & FLAG_ACK) != UInt8(0):
                acks = acks + 1
        off = off + res.consumed
    if acks != 1:
        raise Error(
            "D6: expected exactly one SETTINGS-ACK; got " + String(acks)
        )
    print("    OK")


# =============================================================================
# GROUP E — the OUTBOUND splitter must re-read max_frame_size_peer.
# =============================================================================


def _encode_big_request(
    mut client: H2ClientConnectionState, sid: UInt32, n_headers: Int
) raises:
    """A request whose HPACK block is comfortably larger than 16384 bytes.

    `HpackEncoder.encode_block` emits literal-incremental with huffman=False,
    so the block size is essentially the sum of the raw name+value bytes — no
    compression to reason about.
    """
    var hdrs = HeaderMap()
    var i = 0
    while i < n_headers:
        var name = String("x-pad-") + String(i)
        var value = (
            String("0123456789abcdefghijklmnopqrstuvwxyz")
            + String("0123456789abcdefghijklmnopqrstuvwxyz")
            + String(i)
        )
        hdrs.append(name^, value^)
        i = i + 1
    encode_request_headers_to_frames(
        client,
        sid,
        String("GET"),
        String("https"),
        String("example.com"),
        String("/big"),
        hdrs^,
        True,
    )


def test_outbound_splitter_rereads_peer_max_frame_size() raises:
    """A server may change SETTINGS_MAX_FRAME_SIZE at ANY time (RFC 9113
    §6.5.3). `split_header_block_into_frames` takes max_frame_size as a
    parameter and all six existing splitter tests pass a constant — nothing
    pinned that the CALLER re-reads `h2.max_frame_size_peer`.

    If it captured the value once at connection setup, a server that LOWERS
    MAX_FRAME_SIZE gets oversized frames back and FRAME_SIZE_ERRORs us off
    the connection. Both directions are asserted here.
    """
    print("  E1 outbound_splitter_rereads_peer_max_frame_size...")
    var client = H2ClientConnectionState()

    # ---- leg 1: server RAISES MAX_FRAME_SIZE to 65536 ---------------------
    var s1 = List[UInt8]()
    _settings_frame(SETTINGS_MAX_FRAME_SIZE, UInt32(65536), s1)
    client.append_recv_bytes(Span(s1))
    _ = process_received_frames(client)
    if client.max_frame_size_peer != 65536:
        raise Error(
            "E1: inbound SETTINGS_MAX_FRAME_SIZE=65536 not applied; peer"
            + " value is "
            + String(client.max_frame_size_peer)
        )
    _ = client.take_out_bytes()  # drop the SETTINGS-ACK

    var sid_a = client.allocate_client_stream_id()
    _ = client.create_stream(sid_a)
    _encode_big_request(client, sid_a, 400)
    var out_a = client.take_out_bytes()
    var max_a = _max_frame_payload(Span(out_a))
    if max_a <= 16384:
        raise Error(
            "E1 leg 1: after the server RAISED MAX_FRAME_SIZE to 65536 the"
            + " largest outbound frame is still "
            + String(max_a)
            + " bytes (<= the 16384 default). Either the block is too small"
            + " to exercise the split, or the splitter is pinned to the"
            + " connection-setup value."
        )
    if max_a > 65536:
        raise Error(
            "E1 leg 1: emitted a "
            + String(max_a)
            + "-byte frame, over the peer's 65536 MAX_FRAME_SIZE"
        )

    # ---- leg 2: server LOWERS MAX_FRAME_SIZE back to 16384 ----------------
    var s2 = List[UInt8]()
    _settings_frame(SETTINGS_MAX_FRAME_SIZE, UInt32(16384), s2)
    client.append_recv_bytes(Span(s2))
    _ = process_received_frames(client)
    if client.max_frame_size_peer != 16384:
        raise Error(
            "E1: mid-connection SETTINGS_MAX_FRAME_SIZE=16384 not applied"
        )
    _ = client.take_out_bytes()

    var sid_b = client.allocate_client_stream_id()
    _ = client.create_stream(sid_b)
    _encode_big_request(client, sid_b, 400)
    var out_b = client.take_out_bytes()
    var max_b = _max_frame_payload(Span(out_b))
    if max_b > 16384:
        raise Error(
            "E1 leg 2: the server LOWERED MAX_FRAME_SIZE to 16384 mid-"
            + "connection and the client still emitted a "
            + String(max_b)
            + "-byte frame. The splitter's max_frame_size was captured, not"
            + " re-read — every such frame is a FRAME_SIZE_ERROR and the"
            + " server drops the connection."
        )
    if max_b <= 0:
        raise Error("E1 leg 2: no outbound frames at all")
    print("    OK")


# =============================================================================
# main
# =============================================================================


# ⛔ THIS main DOES NOT STOP AT THE FIRST RED, DELIBERATELY.
#
# Every case here is an INDEPENDENT conformance question against the same
# dispatch loop. A fail-fast main would report case A1 and hide the other
# seven arms of the same defect, so the first fix would look like it closed
# the class when it closed one eighth of it. Each case is run, each failure
# is recorded verbatim, the whole matrix is printed, and THEN the run fails
# with the count — the test is still RED, it is just RED with the evidence.


def main() raises:
    print("== RFC 9113 §6.10 CONTINUATION interleaving (client) ==")
    var failures = List[String]()
    var n_run = 0
    print(" GROUP A — interleaved frame inside an open header block")
    n_run = n_run + 1
    try:
        test_data_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_settings_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_window_update_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_ping_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_rst_stream_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_goaway_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_unknown_frame_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_priority_inside_open_header_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    print(" GROUP B — CONTINUATION identity")
    n_run = n_run + 1
    try:
        test_continuation_on_different_stream_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_continuation_on_stream_zero_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_complete_headers_on_other_stream_mid_block_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_continuation_after_end_headers_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_continuation_after_block_completed_is_protocol_error()
    except e:
        failures.append(String(e))
        print("    FAIL")
    print(" GROUP C — CONTINUATION flood (CVE-2024-27316 shape)")
    n_run = n_run + 1
    try:
        test_continuation_flood_frame_ceiling_is_enforced()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_continuation_flood_byte_ceiling_is_enforced()
    except e:
        failures.append(String(e))
        print("    FAIL")
    print(" GROUP D — positive controls (must NOT reject)")
    n_run = n_run + 1
    try:
        test_headers_plus_two_continuations_delivers_response()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_unknown_frame_outside_header_block_is_ignored()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_ping_with_undefined_flags_is_still_a_ping()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_reserved_stream_id_bit_is_masked_off()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_priority_outside_header_block_is_ignored()
    except e:
        failures.append(String(e))
        print("    FAIL")
    n_run = n_run + 1
    try:
        test_settings_and_window_update_outside_block_still_work()
    except e:
        failures.append(String(e))
        print("    FAIL")
    print(" GROUP E — outbound splitter vs mid-connection SETTINGS")
    n_run = n_run + 1
    try:
        test_outbound_splitter_rereads_peer_max_frame_size()
    except e:
        failures.append(String(e))
        print("    FAIL")

    print("--------------------------------------------------------------")
    print(
        "ran " + String(n_run) + " cases; "
        + String(n_run - len(failures)) + " PASS, "
        + String(len(failures)) + " FAIL"
    )
    if len(failures) == 0:
        print("== ALL " + String(n_run) + " TESTS PASS ==")
        return
    var report = String(
        "RFC 9113 §6.10 conformance: "
    ) + String(len(failures)) + String(" of ") + String(n_run) + String(
        " cases FAILED.\n"
    )
    var i = 0
    while i < len(failures):
        report += String("  [") + String(i + 1) + String("] ")
        report += failures[i]
        report += String("\n")
        i = i + 1
    raise Error(report)
