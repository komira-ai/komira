# =============================================================================
# test_L2_h2_serve_emit.mojo: how the h2 serve loop puts a response on the
# wire under flow control
# =============================================================================
#
# `serve_h2._emit_response` writes a response as HEADERS and DATA frames, as
# much of the body as the stream and connection send windows allow, in
# frames no larger than the peer's SETTINGS_MAX_FRAME_SIZE; the rest waits
# on the deferred-response table. `serve_h2._pump_deferred_responses` sends
# that rest when the windows open, and closes a deferred gRPC stream with
# its grpc-status trailer instead of END_STREAM on the last DATA.
#
# Both are called directly with ordinary responses and windows set on the
# connection state; the frames they queue are decoded and asserted exactly
# (frame sizes, flags, bytes, window arithmetic, stream state, counters).
#
# Groups (and the defect each would catch):
#   E  `_emit_response`: an empty body not closed on HEADERS, the frame size
#      taken from a constant rather than the peer (or no defensive fallback
#      when it is 0, a state set directly: no traffic can produce it),
#      END_STREAM on a frame that is not the last, a window not charged,
#      the residual lost or misplaced, the request counted before the body
#      is out.
#   P  `_pump_deferred_responses`: a residual not sent when the window
#      opens, a chunk over the frame size, END_STREAM when the entry asked
#      for none or on a gRPC DATA frame, the trailer missing, a stuck entry
#      blocking the next, the per-call bound of 64 passes not held, an empty
#      entry left behind.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_HEADERS,
    decode_frame,
)
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackHeader
from komira_http_core.codec.h2.stream import (
    STREAM_STATE_HALF_CLOSED_LOCAL,
    STREAM_STATE_OPEN,
)
from komira_http_core.codec.types import HttpResponse
from komira_http_server.serve_h2 import (
    _emit_response,
    _pump_deferred_responses,
)


struct _Out(Copyable, Movable):
    var kind: UInt8
    var flags: UInt8
    var sid: UInt32
    var payload: List[UInt8]
    var headers: List[HpackHeader]

    def __init__(out self):
        self.kind = UInt8(0xFF)
        self.flags = UInt8(0)
        self.sid = UInt32(0)
        self.payload = List[UInt8]()
        self.headers = List[HpackHeader]()


def _decode(mut h2: H2ConnectionState, mut dec: HpackDecoder) raises -> List[_Out]:
    var bytes = h2.take_out_bytes()
    var outs = List[_Out]()
    var cursor = 0
    while cursor < len(bytes):
        var res = decode_frame(Span(bytes)[cursor:], 1 << 24)
        assert_equal(Int(res.status), 0, "a queued frame does not decode")
        cursor += res.consumed
        ref f = res.frame
        var o = _Out()
        o.kind = f.header.kind
        o.flags = f.header.flags
        o.sid = f.header.stream_id
        if f.header.kind == FRAME_DATA:
            o.payload = f.payload.copy()
        if f.header.kind == FRAME_HEADERS:
            o.headers = dec.decode_block(Span(f.payload))
        outs.append(o^)
    return outs^


def _hval(hs: List[HpackHeader], name: String) -> String:
    for i in range(len(hs)):
        if String(hs[i].name) == name:
            return String(hs[i].value)
    return String("<absent>")


def _body(n: Int) -> List[UInt8]:
    var b = List[UInt8]()
    for i in range(n):
        b.append(UInt8((i * 7 + 3) & 0xFF))
    return b^


def _response(n: Int) -> HttpResponse:
    var r = HttpResponse(Int32(200))
    r.body = _body(n)
    return r^


def _open_stream(mut h2: H2ConnectionState, sid: Int) -> Int:
    """A stream the peer opened and has not finished: OPEN."""
    _ = h2.get_or_create_stream(UInt32(sid))
    var idx = h2.find_stream_idx(UInt32(sid))
    h2.streams[idx].state = STREAM_STATE_OPEN
    return idx


def _assert_data(o: _Out, sid: Int, offset: Int, length: Int, end_stream: Bool) raises:
    """A DATA frame carrying `_body`'s bytes [offset, offset + length)."""
    assert_equal(Int(o.kind), Int(FRAME_DATA))
    assert_equal(Int(o.sid), sid)
    assert_equal(Int(o.flags), Int(FLAG_END_STREAM) if end_stream else 0)
    assert_equal(len(o.payload), length)
    for i in range(length):
        if Int(o.payload[i]) != ((offset + i) * 7 + 3) & 0xFF:
            assert_equal(Int(o.payload[i]), ((offset + i) * 7 + 3) & 0xFF, "byte " + String(offset + i))


def _assert_head(o: _Out, sid: Int, status: String, length: Int, end_stream: Bool) raises:
    assert_equal(Int(o.kind), Int(FRAME_HEADERS))
    assert_equal(Int(o.sid), sid)
    var flags = FLAG_END_HEADERS
    if end_stream:
        flags = flags | FLAG_END_STREAM
    assert_equal(Int(o.flags), Int(flags))
    assert_equal(_hval(o.headers, ":status"), status)
    assert_equal(_hval(o.headers, "content-length"), String(length))
    assert_equal(_hval(o.headers, "content-type"), "text/plain")


# -----------------------------------------------------------------------------
# E. _emit_response.
# -----------------------------------------------------------------------------


def test_empty_body_closes_on_headers() raises:
    """204 with no body: one HEADERS with END_STREAM, the stream half-closed
    (local), the request counted, no DATA bytes. With no stream state the
    frame and the count are the same."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var idx = _open_stream(h2, 1)
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(_emit_response(h2, UInt32(1), HttpResponse(Int32(204)), reqs, sent))
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 1)
    _assert_head(outs[0], 1, "204", 0, True)
    assert_equal(Int(h2.streams[idx].state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))
    assert_equal(Int(reqs), 1)
    assert_equal(Int(sent), 0)

    assert_true(_emit_response(h2, UInt32(3), HttpResponse(Int32(204)), reqs, sent))
    var outs3 = _decode(h2, dec)
    assert_equal(len(outs3), 1)
    _assert_head(outs3[0], 3, "204", 0, True)
    assert_equal(Int(reqs), 2)
    assert_equal(h2.find_stream_idx(UInt32(3)), -1)


def test_body_is_split_at_the_default_frame_size() raises:
    """40000 bytes within both windows: DATA of 16384, 16384 and 7232, only
    the last with END_STREAM; both windows charged 40000."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var idx = _open_stream(h2, 1)
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(_emit_response(h2, UInt32(1), _response(40000), reqs, sent))
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 4)
    _assert_head(outs[0], 1, "200", 40000, False)
    _assert_data(outs[1], 1, 0, 16384, False)
    _assert_data(outs[2], 1, 16384, 16384, False)
    _assert_data(outs[3], 1, 32768, 7232, True)
    assert_equal(Int(sent), 40000)
    assert_equal(Int(reqs), 1)
    assert_equal(Int(h2.send_fc.conn_send_window), 65535 - 40000)
    assert_equal(Int(h2.streams[idx].send_window), 65535 - 40000)
    assert_equal(Int(h2.streams[idx].state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)


def test_frame_size_comes_from_the_peer() raises:
    """With the peer's SETTINGS_MAX_FRAME_SIZE at 20000, 40000 bytes go as
    two frames of 20000."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    _ = _open_stream(h2, 1)
    h2.max_frame_size_peer = 20000
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(_emit_response(h2, UInt32(1), _response(40000), reqs, sent))
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 3)
    _assert_data(outs[1], 1, 0, 20000, False)
    _assert_data(outs[2], 1, 20000, 20000, True)


def test_unset_peer_frame_size_falls_back_to_16384() raises:
    """The peer frame size set to 0 directly. No traffic reaches this
    state: the connection starts at 16384 and SETTINGS refuses any
    MAX_FRAME_SIZE below 16384 (h2spec http2/6.5.2/3). The test exercises
    `_emit_response`'s defensive fallback for a non-positive size: frames
    of 16384."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    _ = _open_stream(h2, 1)
    h2.max_frame_size_peer = 0
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(_emit_response(h2, UInt32(1), _response(20000), reqs, sent))
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 3)
    _assert_data(outs[1], 1, 0, 16384, False)
    _assert_data(outs[2], 1, 16384, 3616, True)


def test_window_limited_body_defers_the_rest() raises:
    """A stream window of 10000: one DATA of 10000 without END_STREAM; the
    other 30000 bytes wait on the deferred table, offset 10000; the request
    is not counted yet and the stream stays open."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var idx = _open_stream(h2, 1)
    h2.streams[idx].send_window = Int32(10000)
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(_emit_response(h2, UInt32(1), _response(40000), reqs, sent))
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 2)
    _assert_data(outs[1], 1, 0, 10000, False)
    assert_equal(Int(sent), 10000)
    assert_equal(Int(reqs), 0)
    assert_equal(Int(h2.streams[idx].send_window), 0)
    assert_equal(Int(h2.send_fc.conn_send_window), 65535 - 10000)
    assert_true(h2.streams[idx].has_deferred_response_body)
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 30000)
    var e = h2.find_deferred_response_idx(UInt32(1))
    assert_equal(h2.deferred_responses[e].offset, 10000)
    assert_true(h2.deferred_response_sends_end_stream(UInt32(1)))
    assert_equal(Int(h2.streams[idx].state), Int(STREAM_STATE_OPEN))


def test_body_for_unknown_stream_is_all_deferred() raises:
    """No stream state: no window, so no DATA; the whole body waits."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_true(_emit_response(h2, UInt32(5), _response(100), reqs, sent))
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 1)
    _assert_head(outs[0], 5, "200", 100, False)
    assert_equal(h2.deferred_response_body_len(UInt32(5)), 100)
    assert_equal(Int(sent), 0)
    assert_equal(Int(h2.send_fc.conn_send_window), 65535)


# -----------------------------------------------------------------------------
# P. _pump_deferred_responses.
# -----------------------------------------------------------------------------


def test_pump_sends_the_rest_when_the_window_opens() raises:
    """The 30000 deferred bytes (from offset 10000) go as 16384 and 13616
    (END_STREAM) once the stream window opens; the entry is dropped, the
    stream half-closed and the request counted."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var idx = _open_stream(h2, 1)
    h2.streams[idx].send_window = Int32(10000)
    var reqs = Int64(0)
    var sent = Int64(0)
    _ = _emit_response(h2, UInt32(1), _response(40000), reqs, sent)
    _ = _decode(h2, dec)
    _pump_deferred_responses(h2, sent, reqs)
    assert_equal(len(_decode(h2, dec)), 0, "the window is still closed")
    h2.streams[idx].send_window = Int32(65535)
    h2.send_fc.conn_send_window = Int32(65535)
    _pump_deferred_responses(h2, sent, reqs)
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 2)
    _assert_data(outs[0], 1, 10000, 16384, False)
    _assert_data(outs[1], 1, 26384, 13616, True)
    assert_equal(Int(sent), 40000)
    assert_equal(Int(reqs), 1)
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_false(h2.streams[idx].has_deferred_response_body)
    assert_equal(Int(h2.streams[idx].state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))
    assert_equal(Int(h2.streams[idx].send_window), 65535 - 30000)
    assert_equal(Int(h2.send_fc.conn_send_window), 65535 - 30000)


def test_pump_frame_size_fallback_and_peer_value() raises:
    """The first half sets the peer frame size to 0 directly, a state no
    traffic reaches (the connection starts at 16384 and SETTINGS refuses
    any MAX_FRAME_SIZE below 16384, h2spec http2/6.5.2/3); it exercises the
    pump's defensive fallback to 16384. The second half uses a value
    SETTINGS can set, 20000: one frame of 20000."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    _ = _open_stream(h2, 1)
    h2.push_deferred_response(UInt32(1), _body(20000), 0, True)
    h2.max_frame_size_peer = 0
    var reqs = Int64(0)
    var sent = Int64(0)
    _pump_deferred_responses(h2, sent, reqs)
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 2)
    _assert_data(outs[0], 1, 0, 16384, False)
    _assert_data(outs[1], 1, 16384, 3616, True)

    var h3 = H2ConnectionState()
    _ = _open_stream(h3, 1)
    h3.push_deferred_response(UInt32(1), _body(20000), 0, True)
    h3.max_frame_size_peer = 20000
    _pump_deferred_responses(h3, sent, reqs)
    var outs3 = _decode(h3, dec)
    assert_equal(len(outs3), 1)
    _assert_data(outs3[0], 1, 0, 20000, True)


def test_pump_without_end_stream_leaves_the_stream_open() raises:
    """An entry pushed with send_end_stream_on_drain=False: its last DATA has
    no END_STREAM and the stream state does not move."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var idx = _open_stream(h2, 1)
    h2.streams[idx].has_deferred_response_body = True
    h2.push_deferred_response(UInt32(1), _body(10), 0, False)
    var reqs = Int64(0)
    var sent = Int64(0)
    _pump_deferred_responses(h2, sent, reqs)
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 1)
    _assert_data(outs[0], 1, 0, 10, False)
    assert_equal(Int(h2.streams[idx].state), Int(STREAM_STATE_OPEN))
    assert_false(h2.streams[idx].has_deferred_response_body)
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_equal(Int(reqs), 1)


def test_pump_drops_an_empty_entry() raises:
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    _ = _open_stream(h2, 1)
    h2.push_deferred_response(UInt32(1), List[UInt8](), 0, True)
    var reqs = Int64(0)
    var sent = Int64(0)
    _pump_deferred_responses(h2, sent, reqs)
    assert_equal(len(_decode(h2, dec)), 0)
    assert_equal(len(h2.deferred_responses), 0)
    assert_equal(Int(reqs), 0)


def test_pump_steps_past_a_stuck_entry() raises:
    """The first entry names a stream with no state (no window: stuck); the
    second drains; the first is still waiting afterwards."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    _ = _open_stream(h2, 3)
    h2.push_deferred_response(UInt32(7), _body(5), 0, True)
    h2.push_deferred_response(UInt32(3), _body(5), 0, True)
    var reqs = Int64(0)
    var sent = Int64(0)
    _pump_deferred_responses(h2, sent, reqs)
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 1)
    _assert_data(outs[0], 3, 0, 5, True)
    assert_equal(h2.deferred_response_body_len(UInt32(7)), 5)
    assert_equal(h2.find_deferred_response_idx(UInt32(3)), -1)


def test_pump_finishes_at_most_64_entries_per_call() raises:
    """65 streams with one deferred byte each: one call finishes 64 of
    them; the next call finishes the last."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    for k in range(65):
        _ = _open_stream(h2, 2 * k + 1)
        h2.push_deferred_response(UInt32(2 * k + 1), _body(1), 0, True)
    var reqs = Int64(0)
    var sent = Int64(0)
    _pump_deferred_responses(h2, sent, reqs)
    assert_equal(len(_decode(h2, dec)), 64)
    assert_equal(Int(reqs), 64)
    assert_equal(len(h2.deferred_responses), 1)
    _pump_deferred_responses(h2, sent, reqs)
    assert_equal(len(_decode(h2, dec)), 1)
    assert_equal(Int(reqs), 65)
    assert_equal(len(h2.deferred_responses), 0)


def test_pump_closes_a_grpc_stream_with_its_trailer() raises:
    """A deferred gRPC residual: its DATA carries no END_STREAM (also when it
    is the last chunk) and the trailer HEADERS with grpc-status 3 and the
    message closes the stream."""
    var h2 = H2ConnectionState()
    var dec = HpackDecoder()
    var idx = _open_stream(h2, 1)
    h2.streams[idx].has_deferred_response_body = True
    h2.push_deferred_grpc_response(UInt32(1), _body(20000), UInt8(3), String("bad"))
    var reqs = Int64(0)
    var sent = Int64(0)
    _pump_deferred_responses(h2, sent, reqs)
    var outs = _decode(h2, dec)
    assert_equal(len(outs), 3)
    _assert_data(outs[0], 1, 0, 16384, False)
    _assert_data(outs[1], 1, 16384, 3616, False)
    assert_equal(Int(outs[2].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs[2].flags), Int(FLAG_END_HEADERS | FLAG_END_STREAM))
    assert_equal(_hval(outs[2].headers, "grpc-status"), "3")
    assert_equal(_hval(outs[2].headers, "grpc-message"), "bad")
    assert_false(h2.streams[idx].has_deferred_response_body)
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_equal(Int(h2.streams[idx].state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))
    assert_equal(Int(reqs), 1)
    assert_equal(Int(sent), 20000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
