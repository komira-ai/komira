# =============================================================================
# test_L2_h2_serve_flow_control.mojo: the h2 serve loop's receive flow
# control and the scope of its errors (RFC 9113 §5.4, §6.9)
# =============================================================================
#
# Drives `serve_h2._dispatch_h2_frames` with wire bytes appended to the
# connection's receive buffer, then decodes every frame the server queued and
# asserts the exact frames, the return value (False = close the connection)
# and the windows and stream state left behind.
#
# Groups (and the defect each would catch):
#   C  crediting: received DATA never given back with WINDOW_UPDATE, so a
#      compliant client stalls after 65,535 bytes (§6.9), including on an
#      open stream whose request the server has not answered yet (an upload
#      the handler reads before it responds); padding not charged (§6.9.1
#      counts the whole payload).
#   S  stream scope: a stream-window overrun, a PRIORITY of the wrong length
#      (§6.3) or a zero WINDOW_UPDATE increment on a stream (§6.9) answered
#      with GOAWAY instead of RST_STREAM; the connection-scoped exceptions
#      (stream 0, inside a header block, an idle stream, a WINDOW_UPDATE of
#      the wrong length) answered with RST_STREAM; a reset stream left open
#      or still sending its body.
#   B  the buffered-body ceiling: a deferred request body allowed to grow
#      without bound once the windows are credited back, or refused at the
#      ceiling itself; a ceiling per stream, which lets 50 concurrent
#      streams buffer 50 times as much on one connection.
#   R  after our RST_STREAM: a DATA frame already in flight on a stream the
#      server reset answered with RST_STREAM(STREAM_CLOSED) instead of
#      ignored (§5.1), or its octets not charged to and given back on the
#      connection window (§6.9.1); a stream the peer has ended still given
#      a stream WINDOW_UPDATE; the refused frame's octets not given back.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PADDED,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    decode_frame,
    encode_frame_header,
)
from komira_http_core.codec.h2.hpack import (
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
)
from komira_http_core.codec.h2.stream import (
    STREAM_STATE_CLOSED,
    STREAM_STATE_OPEN,
)
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import _dispatch_h2_frames
from komira_http_server.serve_h2_flow import H2_MAX_BUFFERED_REQUEST_BODY


comptime NO_ERROR: UInt32 = 0x0
comptime PROTOCOL_ERROR: UInt32 = 0x1
comptime FLOW_CONTROL_ERROR: UInt32 = 0x3
comptime FRAME_SIZE_ERROR: UInt32 = 0x6
comptime WINDOW = 65535


# -----------------------------------------------------------------------------
# A client end: wire bytes in, the server's queued frames out.
# -----------------------------------------------------------------------------


struct _Out(Copyable, Movable):
    """One frame the server queued, decoded."""

    var kind: UInt8
    var flags: UInt8
    var sid: UInt32
    var code: UInt32  # RST_STREAM / GOAWAY error code
    var inc: UInt32  # WINDOW_UPDATE increment
    var payload: List[UInt8]  # DATA bytes
    var headers: List[HpackHeader]

    def __init__(out self):
        self.kind = UInt8(0xFF)
        self.flags = UInt8(0)
        self.sid = UInt32(0)
        self.code = UInt32(0)
        self.inc = UInt32(0)
        self.payload = List[UInt8]()
        self.headers = List[HpackHeader]()


def _raw(kind: UInt8, flags: UInt8, sid: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    encode_frame_header(UInt32(len(payload)), kind, flags, UInt32(sid), out)
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


def _u32(v: UInt32) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))
    return out^


def _cat(mut a: List[UInt8], b: List[UInt8]):
    for i in range(len(b)):
        a.append(b[i])


def _window_update(sid: Int, inc: UInt32) -> List[UInt8]:
    return _raw(FRAME_WINDOW_UPDATE, UInt8(0), sid, _u32(inc))


def _ping() -> List[UInt8]:
    var p = List[UInt8]()
    for i in range(8):
        p.append(UInt8(i))
    return _raw(FRAME_PING, UInt8(0), 0, p)


def _data(sid: Int, n: Int) -> List[UInt8]:
    """DATA of `n` 'x' bytes, no END_STREAM."""
    var p = List[UInt8]()
    for _ in range(n):
        p.append(UInt8(0x78))
    return _raw(FRAME_DATA, UInt8(0), sid, p)


def _padded_data(sid: Int, text: String, pad: Int) -> List[UInt8]:
    """PADDED DATA: Pad Length, `text`, `pad` zero bytes; no END_STREAM."""
    var p = List[UInt8]()
    p.append(UInt8(pad))
    var b = text.as_bytes()
    for i in range(len(b)):
        p.append(b[i])
    for _ in range(pad):
        p.append(UInt8(0))
    return _raw(FRAME_DATA, FLAG_PADDED, sid, p)


struct _Client(Movable):
    """One server connection past its preface. The router serves GET / and
    POST /up."""

    var h2: H2ConnectionState
    var router: Router
    var grpc: NoopGrpcDispatch
    var enc: HpackEncoder
    var dec: HpackDecoder
    var reqs: Int64
    var sent: Int64

    def __init__(out self) raises:
        self.h2 = H2ConnectionState()
        self.h2.mark_preface_ok()
        self.router = Router()
        self.router.add(HttpMethod.get(), "/", 1)
        self.router.add(HttpMethod.post(), "/up", 2)
        self.grpc = NoopGrpcDispatch()
        self.enc = HpackEncoder()
        self.dec = HpackDecoder()
        self.reqs = Int64(0)
        self.sent = Int64(0)

    def send(mut self, bytes: List[UInt8]) -> Bool:
        """Append `bytes` to the receive buffer and run the dispatcher."""
        self.h2.append_recv_bytes(Span(bytes))
        return _dispatch_h2_frames(
            self.h2, self.router, self.grpc, self.reqs, self.sent
        )

    def out(mut self) raises -> List[_Out]:
        var bytes = self.h2.take_out_bytes()
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
            if f.header.kind == FRAME_RST_STREAM:
                o.code = f.rst_error_code
            if f.header.kind == FRAME_GOAWAY:
                o.code = f.goaway_error_code
            if f.header.kind == FRAME_WINDOW_UPDATE:
                o.inc = f.window_update_increment
            if f.header.kind == FRAME_DATA:
                o.payload = f.payload.copy()
            if f.header.kind == FRAME_HEADERS:
                o.headers = self.dec.decode_block(Span(f.payload))
            outs.append(o^)
        return outs^

    def request(
        mut self, sid: Int, method: String, path: String, length: String
    ) -> List[UInt8]:
        """HEADERS with END_HEADERS and no END_STREAM; a content-length
        header unless `length` is empty."""
        var hs = List[HpackHeader]()
        hs.append(HpackHeader(String(":method"), method))
        hs.append(HpackHeader(String(":scheme"), String("https")))
        hs.append(HpackHeader(String(":path"), path))
        hs.append(HpackHeader(String(":authority"), String("localhost")))
        if length.byte_length() > 0:
            hs.append(HpackHeader(String("content-length"), length))
        return _raw(FRAME_HEADERS, FLAG_END_HEADERS, sid, self.enc.encode_block(hs^))

    def open(mut self, sid: Int) raises:
        """A GET without END_STREAM: answered at once, and the peer may
        still send DATA on it (counted and discarded)."""
        assert_true(self.send(self.request(sid, "GET", "/", "")))
        _ = self.out()

    def state(self, sid: Int) -> Int:
        return Int(self.h2.streams[self.h2.find_stream_idx(UInt32(sid))].state)

    def recv_window(self, sid: Int) -> Int:
        return Int(
            self.h2.streams[self.h2.find_stream_idx(UInt32(sid))].recv_window
        )


def _assert_wu(o: _Out, sid: Int, inc: Int) raises:
    assert_equal(Int(o.kind), Int(FRAME_WINDOW_UPDATE))
    assert_equal(Int(o.sid), sid)
    assert_equal(Int(o.inc), inc)


def _assert_rst(o: _Out, sid: Int, code: UInt32) raises:
    assert_equal(Int(o.kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(o.sid), sid)
    assert_equal(Int(o.code), Int(code))


def _assert_goaway_only(outs: List[_Out], code: UInt32) raises:
    assert_equal(len(outs), 1, "exactly one frame: the GOAWAY")
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[0].code), Int(code))


def _assert_ping_ack(o: _Out) raises:
    assert_equal(Int(o.kind), Int(FRAME_PING))
    assert_equal(Int(o.flags), Int(FLAG_ACK))


# -----------------------------------------------------------------------------
# C. Crediting received DATA back (RFC 9113 §6.9, §6.9.1).
# -----------------------------------------------------------------------------


def test_received_data_is_credited_back() raises:
    """Three 16000-byte DATA frames spend 48000 of both windows, past the
    half-window watermark: WINDOW_UPDATE(1, 48000) then WINDOW_UPDATE(0,
    48000), and both windows are whole again. A client that honours them
    sends four more frames, 112000 bytes in all, past the 65,535 it could
    send before; the third of those spends the watermark again."""
    var c = _Client()
    c.open(1)
    for _ in range(3):
        assert_true(c.send(_data(1, 16000)))
    var outs = c.out()
    assert_equal(len(outs), 2, "a WINDOW_UPDATE for the stream and one for the connection")
    _assert_wu(outs[0], 1, 48000)
    _assert_wu(outs[1], 0, 48000)
    assert_equal(c.recv_window(1), WINDOW)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW)
    for _ in range(4):
        assert_true(c.send(_data(1, 16000)))
    assert_false(c.h2.is_goaway_sent())
    var outs2 = c.out()
    assert_equal(len(outs2), 2)
    _assert_wu(outs2[0], 1, 48000)
    _assert_wu(outs2[1], 0, 48000)
    assert_equal(c.recv_window(1), WINDOW - 16000)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW - 16000)


def test_upload_on_an_unanswered_stream_is_credited_back() raises:
    """A POST declaring a 100000-byte body is deferred until its body ends,
    so stream 1 stays open (not half-closed (local), as after an answered
    GET) while the body arrives: the state of an upload or a gRPC call in
    progress. Three 16000-byte frames draw WINDOW_UPDATE(1, 48000) and
    WINDOW_UPDATE(0, 48000) while the stream is still open; without the
    stream update the fifth frame would overrun the stream window (a
    compliant client stalls at 65,535). The upload goes on past 65,535 to
    all 100000 bytes, a second pair of updates follows, and the
    END_STREAM frame dispatches the request: the router's 200, which the
    content-length check only allows once every byte arrived."""
    var c = _Client()
    assert_true(c.send(c.request(1, "POST", "/up", "100000")))
    assert_equal(len(c.out()), 0, "the request waits for its body")
    assert_equal(c.state(1), Int(STREAM_STATE_OPEN))
    for _ in range(3):
        assert_true(c.send(_data(1, 16000)))
    assert_equal(c.state(1), Int(STREAM_STATE_OPEN))
    var outs = c.out()
    assert_equal(len(outs), 2, "a WINDOW_UPDATE for the open stream and one for the connection")
    _assert_wu(outs[0], 1, 48000)
    _assert_wu(outs[1], 0, 48000)
    assert_equal(c.recv_window(1), WINDOW)
    for _ in range(3):
        assert_true(c.send(_data(1, 16000)))
    var outs2 = c.out()
    assert_equal(len(outs2), 2, "the open stream credited again past 65,535 bytes")
    _assert_wu(outs2[0], 1, 48000)
    _assert_wu(outs2[1], 0, 48000)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_true(c.h2.streams[idx].has_pending_request, "answered before its body ended")
    assert_equal(Int(c.h2.streams[idx].recv_data_bytes), 96000)
    assert_true(c.send(_data_end(1, 4000)))
    assert_false(c.h2.is_goaway_sent())
    var outs3 = c.out()
    assert_equal(len(outs3), 2, "the router's answer: HEADERS and DATA")
    assert_equal(Int(outs3[0].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs3[0].sid), 1)
    var status = String("<absent>")
    for i in range(len(outs3[0].headers)):
        if String(outs3[0].headers[i].name) == ":status":
            status = String(outs3[0].headers[i].value)
    assert_equal(status, "200")
    assert_equal(Int(outs3[1].kind), Int(FRAME_DATA))
    assert_equal(Int(outs3[1].flags), Int(FLAG_END_STREAM))
    assert_equal(Int(c.h2.streams[idx].recv_data_bytes), 100000)


def test_below_the_watermark_nothing_is_credited() raises:
    """32767 bytes is one short of the watermark (32768): no update yet. One
    more byte reaches it, and the update carries all 32768."""
    var c = _Client()
    c.open(1)
    assert_true(c.send(_data(1, 16000)))
    assert_true(c.send(_data(1, 16000)))
    assert_true(c.send(_data(1, 767)))
    assert_equal(len(c.out()), 0)
    assert_equal(c.recv_window(1), WINDOW - 32767)
    assert_true(c.send(_data(1, 1)))
    var outs = c.out()
    assert_equal(len(outs), 2)
    _assert_wu(outs[0], 1, 32768)
    _assert_wu(outs[1], 0, 32768)


def test_padded_data_is_charged_its_padding() raises:
    """PADDED DATA of 15 octets: Pad Length, "test", ten bytes of padding.
    Both windows are charged all 15 (§6.9.1); the body counts 4."""
    var c = _Client()
    c.open(1)
    assert_true(c.send(_padded_data(1, "test", 10)))
    assert_equal(len(c.out()), 0)
    assert_equal(c.recv_window(1), WINDOW - 15)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW - 15)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].recv_data_bytes), 4)


def test_data_on_a_closed_stream_is_credited_to_the_connection() raises:
    """DATA on a stream the peer already ended is refused with
    RST_STREAM(STREAM_CLOSED), but its octets still count against the
    connection window (§6.9.1) and are given back: two 16384-byte frames
    reach the watermark and draw WINDOW_UPDATE(0)."""
    var c = _Client()
    var get = c.request(1, "GET", "/", "")
    get[4] = get[4] | FLAG_END_STREAM
    assert_true(c.send(get))
    _ = c.out()
    assert_true(c.send(_data(1, 16384)))
    assert_true(c.send(_data(1, 16384)))
    var outs = c.out()
    assert_equal(len(outs), 3)
    _assert_rst(outs[0], 1, 0x5)
    _assert_rst(outs[1], 1, 0x5)
    _assert_wu(outs[2], 0, 32768)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW)


# -----------------------------------------------------------------------------
# S. Stream errors and their connection-scoped exceptions (RFC 9113 §5.4).
# -----------------------------------------------------------------------------


def test_stream_window_overrun_is_a_stream_error() raises:
    """Stream 1's receive window is 10 and a 20-byte DATA arrives: the
    connection window has room, so it is RST_STREAM(1, FLOW_CONTROL_ERROR),
    not GOAWAY (§6.9). The octets are still charged to the connection
    (§6.9.1), and stream 3 carries on."""
    var c = _Client()
    c.open(1)
    c.open(3)
    c.h2.streams[c.h2.find_stream_idx(UInt32(1))].recv_window = Int32(10)
    assert_true(c.send(_data(1, 20)), "the connection must stay open")
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, FLOW_CONTROL_ERROR)
    assert_false(c.h2.is_goaway_sent())
    assert_equal(c.state(1), Int(STREAM_STATE_CLOSED))
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW - 20)
    assert_true(c.send(_data(3, 3)))
    assert_equal(len(c.out()), 0)
    var idx3 = c.h2.find_stream_idx(UInt32(3))
    assert_equal(Int(c.h2.streams[idx3].recv_data_bytes), 3)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW - 23)


def test_connection_window_overrun_closes() raises:
    """The connection window is 10 and a 20-byte DATA arrives on an open
    stream: a connection FLOW_CONTROL_ERROR."""
    var c = _Client()
    c.open(1)
    c.h2.recv_fc.conn_recv_window = Int32(10)
    assert_false(c.send(_data(1, 20)))
    _assert_goaway_only(c.out(), FLOW_CONTROL_ERROR)


def test_priority_of_the_wrong_length_is_a_stream_error() raises:
    """A 4-byte PRIORITY (h2spec http2/6.3/2's frame) on open stream 1, then
    a PING: RST_STREAM(1, FRAME_SIZE_ERROR) (§6.3), the frame is skipped and
    the PING after it is answered; stream 1 is closed."""
    var c = _Client()
    c.open(1)
    var b = _raw(FRAME_PRIORITY, UInt8(0), 1, _u32(UInt32(0)))
    _cat(b, _ping())
    assert_true(c.send(b), "the connection must stay open")
    var outs = c.out()
    assert_equal(len(outs), 2)
    _assert_rst(outs[0], 1, FRAME_SIZE_ERROR)
    _assert_ping_ack(outs[1])
    assert_false(c.h2.is_goaway_sent())
    assert_equal(c.state(1), Int(STREAM_STATE_CLOSED))


def test_zero_increment_on_a_stream_is_a_stream_error() raises:
    """WINDOW_UPDATE(1, 0) (h2spec http2/6.9/2's frame), then a PING:
    RST_STREAM(1, PROTOCOL_ERROR) (§6.9) and the PING is answered."""
    var c = _Client()
    c.open(1)
    var b = _window_update(1, UInt32(0))
    _cat(b, _ping())
    assert_true(c.send(b), "the connection must stay open")
    var outs = c.out()
    assert_equal(len(outs), 2)
    _assert_rst(outs[0], 1, PROTOCOL_ERROR)
    _assert_ping_ack(outs[1])
    assert_equal(c.state(1), Int(STREAM_STATE_CLOSED))


def test_zero_increment_on_an_idle_stream_closes() raises:
    """WINDOW_UPDATE(1, 0) before stream 1 opens: any WINDOW_UPDATE on an
    idle stream is a connection PROTOCOL_ERROR (§5.1)."""
    var c = _Client()
    assert_false(c.send(_window_update(1, UInt32(0))))
    _assert_goaway_only(c.out(), PROTOCOL_ERROR)


def test_priority_of_the_wrong_length_on_an_idle_stream_closes() raises:
    """A 4-byte PRIORITY on idle stream 5. RST_STREAM must not name an idle
    stream (§6.4), and a PRIORITY leaves the stream idle (§5.1), so the
    stream error is answered as a connection error (§5.4):
    GOAWAY(FRAME_SIZE_ERROR), and no stream is made."""
    var c = _Client()
    assert_false(c.send(_raw(FRAME_PRIORITY, UInt8(0), 5, _u32(UInt32(0)))))
    _assert_goaway_only(c.out(), FRAME_SIZE_ERROR)
    assert_equal(c.h2.find_stream_idx(UInt32(5)), -1)


def test_window_update_of_the_wrong_length_on_a_stream_closes() raises:
    """A 5-byte WINDOW_UPDATE on open stream 1: a WINDOW_UPDATE whose length
    is not 4 is a connection FRAME_SIZE_ERROR on any stream (§6.9), whatever
    scope the frame decoder reports, so GOAWAY and no RST_STREAM."""
    var c = _Client()
    c.open(1)
    var p = _u32(UInt32(1))
    p.append(UInt8(0))
    assert_false(c.send(_raw(FRAME_WINDOW_UPDATE, UInt8(0), 1, p)))
    _assert_goaway_only(c.out(), FRAME_SIZE_ERROR)


def test_zero_increment_on_a_finished_stream_is_reset() raises:
    """Stream 3 is implicitly closed once stream 5 opens (§5.1.1) and has no
    entry; a zero increment on it is still a stream error, not a GOAWAY."""
    var c = _Client()
    c.open(5)
    assert_true(c.send(_window_update(3, UInt32(0))))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 3, PROTOCOL_ERROR)


def test_stream_scoped_error_on_stream_zero_closes() raises:
    """A 4-byte PRIORITY on stream 0 names no stream to reset: GOAWAY with
    the decoder's FRAME_SIZE_ERROR."""
    var c = _Client()
    assert_false(c.send(_raw(FRAME_PRIORITY, UInt8(0), 0, _u32(UInt32(0)))))
    _assert_goaway_only(c.out(), FRAME_SIZE_ERROR)


def test_stream_scoped_error_inside_a_header_block_closes() raises:
    """HEADERS without END_HEADERS, then a 4-byte PRIORITY: inside a header
    block only CONTINUATION may follow (§6.10), so it is a connection
    PROTOCOL_ERROR whatever the frame's own fault."""
    var c = _Client()
    var hs = c.request(1, "GET", "/", "")
    hs[4] = UInt8(0)  # clear END_HEADERS
    var b = hs^
    _cat(b, _raw(FRAME_PRIORITY, UInt8(0), 1, _u32(UInt32(0))))
    assert_false(c.send(b))
    _assert_goaway_only(c.out(), PROTOCOL_ERROR)


def test_reset_stream_stops_its_unsent_body() raises:
    """With a peer initial window of 1, a GET's 18-byte answer sends one
    byte and defers the rest. A zero increment on the stream resets it; a
    connection WINDOW_UPDATE afterwards sends no more DATA on it."""
    var c = _Client()
    var w = List[UInt8]()
    w.append(UInt8(0))
    w.append(UInt8(4))
    _cat(w, _u32(UInt32(1)))
    assert_true(c.send(_raw(FRAME_SETTINGS, UInt8(0), 0, w)))
    c.open(1)
    assert_equal(c.h2.deferred_response_body_len(UInt32(1)), 17)
    assert_true(c.send(_window_update(1, UInt32(0))))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, PROTOCOL_ERROR)
    assert_equal(c.h2.deferred_response_body_len(UInt32(1)), 0)
    assert_true(c.send(_window_update(0, UInt32(100))))
    assert_equal(len(c.out()), 0, "DATA was sent on a reset stream")


# -----------------------------------------------------------------------------
# B. The buffered-body ceiling.
# -----------------------------------------------------------------------------


def test_buffered_body_at_the_ceiling_is_kept() raises:
    """A POST declaring a large body is deferred; with 4 bytes left to the
    ceiling, 4 more are kept and nothing is answered."""
    var c = _Client()
    assert_true(c.send(c.request(1, "POST", "/up", "20000000")))
    var idx = c.h2.find_stream_idx(UInt32(1))
    c.h2.streams[idx].recv_data_bytes = Int64(H2_MAX_BUFFERED_REQUEST_BODY - 4)
    assert_true(c.send(_data(1, 4)))
    assert_equal(len(c.out()), 0)
    assert_true(c.h2.streams[idx].has_pending_request)
    assert_equal(c.h2.find_pending_request_idx(UInt32(1)), 0)


def test_buffered_body_over_the_ceiling_is_answered_413() raises:
    """One byte over the ceiling: a 413 with END_STREAM, then
    RST_STREAM(NO_ERROR) (§8.1); the deferred request is dropped, never
    dispatched, and the connection stays open."""
    var c = _Client()
    assert_true(c.send(c.request(1, "POST", "/up", "20000000")))
    var idx = c.h2.find_stream_idx(UInt32(1))
    c.h2.streams[idx].recv_data_bytes = Int64(H2_MAX_BUFFERED_REQUEST_BODY - 3)
    assert_true(c.send(_data(1, 4)))
    var outs = c.out()
    assert_equal(len(outs), 2)
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs[0].flags), Int(FLAG_END_HEADERS | FLAG_END_STREAM))
    var status = String("<absent>")
    for i in range(len(outs[0].headers)):
        if String(outs[0].headers[i].name) == ":status":
            status = String(outs[0].headers[i].value)
    assert_equal(status, "413")
    _assert_rst(outs[1], 1, NO_ERROR)
    assert_equal(c.state(1), Int(STREAM_STATE_CLOSED))
    assert_false(c.h2.streams[idx].has_pending_request)
    assert_equal(c.h2.find_pending_request_idx(UInt32(1)), -1)
    assert_false(c.h2.is_goaway_sent())


def test_buffered_bodies_share_one_connection_ceiling() raises:
    """The ceiling bounds the request bodies buffered on the whole
    connection, not each stream. Stream 1 holds the ceiling less 10 bytes;
    4 more on stream 1 are kept, then 7 on stream 3 take the connection one
    byte over: stream 3 is answered 413 + RST_STREAM(NO_ERROR) and stream 1
    keeps its request."""
    var c = _Client()
    assert_true(c.send(c.request(1, "POST", "/up", "20000000")))
    assert_true(c.send(c.request(3, "POST", "/up", "20000000")))
    _ = c.out()
    var idx1 = c.h2.find_stream_idx(UInt32(1))
    c.h2.streams[idx1].recv_data_bytes = Int64(
        H2_MAX_BUFFERED_REQUEST_BODY - 10
    )
    assert_true(c.send(_data(1, 4)))
    assert_true(c.send(_data(3, 7)))
    var outs = c.out()
    assert_equal(len(outs), 2, "a 413 and an RST_STREAM on stream 3")
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs[0].sid), 3)
    _assert_rst(outs[1], 3, NO_ERROR)
    assert_equal(c.h2.find_pending_request_idx(UInt32(3)), -1)
    assert_true(c.h2.streams[idx1].has_pending_request)
    assert_true(c.h2.find_pending_request_idx(UInt32(1)) >= 0)
    assert_false(c.h2.is_goaway_sent())


# -----------------------------------------------------------------------------
# R. After the server's own RST_STREAM (RFC 9113 §5.1, §6.9.1).
# -----------------------------------------------------------------------------


def _data_end(sid: Int, n: Int) -> List[UInt8]:
    """DATA of `n` 'x' bytes with END_STREAM."""
    var d = _data(sid, n)
    d[4] = d[4] | FLAG_END_STREAM
    return d^


def test_data_after_our_413_is_ignored() raises:
    """The DATA frame that crosses the ceiling also takes the connection to
    the watermark: 413, RST_STREAM(NO_ERROR) and WINDOW_UPDATE(0, 32768),
    and no stream update for the reset stream. A DATA frame already in
    flight on stream 1 then arrives: after sending RST_STREAM the server
    MUST ignore it (§5.1), so nothing is queued, and it is still charged to
    the connection window (§6.9.1)."""
    var c = _Client()
    assert_true(c.send(c.request(1, "POST", "/up", "20000000")))
    _ = c.out()
    var idx = c.h2.find_stream_idx(UInt32(1))
    c.h2.streams[idx].recv_data_bytes = Int64(H2_MAX_BUFFERED_REQUEST_BODY - 3)
    c.h2.recv_fc.conn_recv_window = Int32(WINDOW - 32764)
    assert_true(c.send(_data(1, 4)))
    var outs = c.out()
    assert_equal(len(outs), 3, "a 413, an RST_STREAM and a connection update")
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    _assert_rst(outs[1], 1, NO_ERROR)
    _assert_wu(outs[2], 0, 32768)
    assert_true(c.send(_data(1, 4)), "the connection must stay open")
    assert_equal(len(c.out()), 0, "a frame was sent for DATA on a stream we reset")
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW - 4)
    assert_false(c.h2.is_goaway_sent())


def test_data_after_our_flow_control_reset_is_ignored() raises:
    """Stream 1 overruns its window with the connection 20 short of the
    watermark: RST_STREAM(1, FLOW_CONTROL_ERROR) then WINDOW_UPDATE(0,
    32768), the octets given back on the connection only. More DATA on
    stream 1 is ignored and charged."""
    var c = _Client()
    c.open(1)
    c.h2.streams[c.h2.find_stream_idx(UInt32(1))].recv_window = Int32(10)
    c.h2.recv_fc.conn_recv_window = Int32(WINDOW - 32748)
    assert_true(c.send(_data(1, 20)))
    var outs = c.out()
    assert_equal(len(outs), 2, "an RST_STREAM and a connection update")
    _assert_rst(outs[0], 1, FLOW_CONTROL_ERROR)
    _assert_wu(outs[1], 0, 32768)
    assert_true(c.send(_data(1, 5)))
    assert_equal(len(c.out()), 0, "a frame was sent for DATA on a stream we reset")
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW - 5)


def test_data_after_a_decode_error_reset_is_charged_and_given_back() raises:
    """A zero increment resets stream 1. Two 16384-byte DATA frames in
    flight on it are ignored (no RST_STREAM) but reach the connection
    watermark, so the only frame queued is WINDOW_UPDATE(0, 32768)."""
    var c = _Client()
    c.open(1)
    assert_true(c.send(_window_update(1, UInt32(0))))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, PROTOCOL_ERROR)
    assert_true(c.send(_data(1, 16384)))
    assert_true(c.send(_data(1, 16384)))
    var outs2 = c.out()
    assert_equal(len(outs2), 1, "exactly one frame: the connection update")
    _assert_wu(outs2[0], 0, 32768)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), WINDOW)


def test_an_ended_stream_is_credited_on_the_connection_only() raises:
    """32000 bytes on stream 1, then 768 more with END_STREAM: both windows
    reach the watermark, but the peer can send nothing more on stream 1
    (it is closed), so a stream WINDOW_UPDATE would be a frame sent on a
    closed stream (§5.1). Only WINDOW_UPDATE(0, 32768) is queued."""
    var c = _Client()
    c.open(1)
    assert_true(c.send(_data(1, 16000)))
    assert_true(c.send(_data(1, 16000)))
    assert_equal(len(c.out()), 0)
    assert_true(c.send(_data_end(1, 768)))
    var outs = c.out()
    assert_equal(len(outs), 1, "exactly one frame: the connection update")
    _assert_wu(outs[0], 0, 32768)
    assert_equal(c.state(1), Int(STREAM_STATE_CLOSED))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
