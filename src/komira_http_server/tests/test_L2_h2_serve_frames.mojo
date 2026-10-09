# =============================================================================
# test_L2_h2_serve_frames.mojo: the h2 serve loop's frame dispatcher, one
# frame type at a time
# =============================================================================
#
# Drives `serve_h2._dispatch_h2_frames` with wire bytes appended to the
# connection's receive buffer, then decodes every frame the server queued and
# asserts the exact frames (type, flags, stream, error code, payload), the
# return value (False = close the connection) and the connection state left
# behind. Also `build_initial_server_settings` and `_try_consume_preface`.
#
# Every hostile frame is an h2spec v2.6.0 case and is named for it
# (`http2/<section>/<n>`); the other frames are ordinary client traffic.
#
# Groups (and the defect each would catch):
#   S  initial SETTINGS: an entry dropped, reordered or with the wrong value,
#      and MAX_FRAME_SIZE not read from the connection.
#   P  preface: a short buffer not answered NEED_MORE, the 24 bytes not
#      consumed or the flag not set on OK, bytes consumed on ERROR.
#   L  the loop: an empty or partial buffer not answered True with the bytes
#      kept; a decode error not answered GOAWAY with the decoder's code.
#   R  reassembly: a non-CONTINUATION frame accepted inside a header block.
#   T  SETTINGS: a range check missing or off by one, the wrong error code,
#      an entry not applied, no ACK, an ACK answered.
#   G  PING and GOAWAY: no echo, the ACK flag or data wrong, an ACK
#      answered, the frames after a peer GOAWAY dropped.
#   Y  PRIORITY: self-dependency not refused, or refused on a stream it
#      names but leaves open.
#   W  WINDOW_UPDATE: an overflow not refused at the right scope, an idle
#      stream not refused, a closed stream's update refused.
#   X  RST_STREAM and DATA: idle-stream frames not refused, a closed stream
#      left open, DATA on a closed stream not reset, received bytes not
#      counted.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.connection_preface import (
    PREFACE_ERROR,
    PREFACE_NEED_MORE,
    PREFACE_OK,
)
from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    SettingsEntry,
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
    STREAM_STATE_HALF_CLOSED_LOCAL,
)
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import (
    _dispatch_h2_frames,
    _try_consume_preface,
    build_initial_server_settings,
)


comptime PROTOCOL_ERROR: UInt32 = 0x1
comptime FLOW_CONTROL_ERROR: UInt32 = 0x3
comptime STREAM_CLOSED: UInt32 = 0x5
comptime FRAME_SIZE_ERROR: UInt32 = 0x6
comptime HELLO_LEN = 18  # len("Hello from HTTP/2!"), the canned 200 body


# -----------------------------------------------------------------------------
# A client end: wire bytes in, the server's queued frames out.
# -----------------------------------------------------------------------------


struct _Out(Copyable, Movable):
    """One frame the server queued, decoded."""

    var kind: UInt8
    var flags: UInt8
    var sid: UInt32
    var code: UInt32  # RST_STREAM / GOAWAY error code
    var last_sid: UInt32  # GOAWAY last stream id
    var payload: List[UInt8]  # DATA bytes
    var ping: SIMD[DType.uint8, 8]
    var settings: List[SettingsEntry]
    var headers: List[HpackHeader]

    def __init__(out self):
        self.kind = UInt8(0xFF)
        self.flags = UInt8(0)
        self.sid = UInt32(0)
        self.code = UInt32(0)
        self.last_sid = UInt32(0)
        self.payload = List[UInt8]()
        self.ping = SIMD[DType.uint8, 8](0)
        self.settings = List[SettingsEntry]()
        self.headers = List[HpackHeader]()


def _decode_all(bytes: List[UInt8], mut dec: HpackDecoder) raises -> List[_Out]:
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
            o.last_sid = f.goaway_last_stream_id
        if f.header.kind == FRAME_DATA:
            o.payload = f.payload.copy()
        if f.header.kind == FRAME_PING:
            o.ping = f.ping_data
        if f.header.kind == FRAME_SETTINGS:
            o.settings = f.settings.copy()
        if f.header.kind == FRAME_HEADERS:
            o.headers = dec.decode_block(Span(f.payload))
        outs.append(o^)
    return outs^


def _hval(hs: List[HpackHeader], name: String) -> String:
    for i in range(len(hs)):
        if String(hs[i].name) == name:
            return String(hs[i].value)
    return String("<absent>")


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


def _settings(ids: List[Int], vals: List[UInt32]) -> List[UInt8]:
    var p = List[UInt8]()
    for i in range(len(ids)):
        p.append(UInt8((ids[i] >> 8) & 0xFF))
        p.append(UInt8(ids[i] & 0xFF))
        var v = _u32(vals[i])
        for j in range(4):
            p.append(v[j])
    return _raw(FRAME_SETTINGS, UInt8(0), 0, p)


def _setting(id: Int, val: UInt32) -> List[UInt8]:
    var ids: List[Int] = [id]
    var vals: List[UInt32] = [val]
    return _settings(ids, vals)


def _window_update(sid: Int, inc: UInt32) -> List[UInt8]:
    return _raw(FRAME_WINDOW_UPDATE, UInt8(0), sid, _u32(inc))


def _rst(sid: Int, code: UInt32) -> List[UInt8]:
    return _raw(FRAME_RST_STREAM, UInt8(0), sid, _u32(code))


def _priority(sid: Int, dep: Int) -> List[UInt8]:
    var p = _u32(UInt32(dep))
    p.append(UInt8(15))  # weight
    return _raw(FRAME_PRIORITY, UInt8(0), sid, p)


def _ping(flags: UInt8, first: UInt8) -> List[UInt8]:
    var p = List[UInt8]()
    for i in range(8):
        p.append(first + UInt8(i))
    return _raw(FRAME_PING, flags, 0, p)


def _data(sid: Int, text: String, end_stream: Bool) -> List[UInt8]:
    var p = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        p.append(b[i])
    return _raw(FRAME_DATA, FLAG_END_STREAM if end_stream else UInt8(0), sid, p)


struct _Client(Movable):
    """One server connection past its preface, with the client's HPACK
    contexts. The router serves GET / (so a response has a body)."""

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
        return _decode_all(self.h2.take_out_bytes(), self.dec)

    def get_block(mut self) -> List[UInt8]:
        """h2spec's common request headers: GET / over https."""
        return self.block("GET")

    def block(mut self, method: String) -> List[UInt8]:
        """h2spec's common request headers with `method`."""
        var hs = List[HpackHeader]()
        hs.append(HpackHeader(String(":method"), method))
        hs.append(HpackHeader(String(":scheme"), String("https")))
        hs.append(HpackHeader(String(":path"), String("/")))
        hs.append(HpackHeader(String(":authority"), String("localhost")))
        return self.enc.encode_block(hs^)

    def headers(mut self, sid: Int, flags: UInt8) -> List[UInt8]:
        return _raw(FRAME_HEADERS, flags, sid, self.get_block())

    def get(mut self, sid: Int, end_stream: Bool) -> List[UInt8]:
        var flags = FLAG_END_HEADERS
        if end_stream:
            flags = flags | FLAG_END_STREAM
        return self.headers(sid, flags)


def _assert_goaway(outs: List[_Out], code: UInt32, last_sid: Int = 0) raises:
    assert_equal(len(outs), 1, "exactly one frame: the GOAWAY")
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[0].sid), 0)
    assert_equal(Int(outs[0].code), Int(code))
    assert_equal(Int(outs[0].last_sid), last_sid)


def _assert_rst(o: _Out, sid: Int, code: UInt32) raises:
    assert_equal(Int(o.kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(o.sid), sid)
    assert_equal(Int(o.code), Int(code))


# -----------------------------------------------------------------------------
# S. The server's initial SETTINGS.
# -----------------------------------------------------------------------------


def test_initial_settings_entries_in_order() raises:
    """Five entries, in this order and with these values; MAX_FRAME_SIZE is
    the connection's local limit (set to 32768 here, not the default)."""
    var h2 = H2ConnectionState()
    h2.max_frame_size_local = 32768
    var dec = HpackDecoder()
    var outs = _decode_all(build_initial_server_settings(h2), dec)
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_SETTINGS))
    assert_equal(Int(outs[0].flags), 0, "the initial SETTINGS is not an ACK")
    assert_equal(Int(outs[0].sid), 0)
    ref s = outs[0].settings
    assert_equal(len(s), 5)
    var ids: List[Int] = [1, 3, 4, 5, 6]
    var vals: List[Int] = [4096, 50, 65535, 32768, 8192]
    for i in range(5):
        assert_equal(Int(s[i].identifier), ids[i])
        assert_equal(Int(s[i].value), vals[i])


# -----------------------------------------------------------------------------
# P. The client connection preface.
# -----------------------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


comptime PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"


def test_preface_short_buffer_needs_more() raises:
    var h2 = H2ConnectionState()
    var b = _bytes(PREFACE)
    h2.append_recv_bytes(Span(b)[0:23])
    assert_equal(_try_consume_preface(h2), PREFACE_NEED_MORE)
    assert_equal(len(h2.recv_buf), 23, "a short preface is kept, not consumed")
    assert_false(h2.is_preface_ok())


def test_preface_ok_consumes_exactly_24_bytes() raises:
    """The preface and h2spec http2/3.5/1's first frame arrive together: the
    24 preface bytes go and the frame's bytes stay for the dispatcher."""
    var h2 = H2ConnectionState()
    var b = _bytes(PREFACE)
    var settings = _setting(4, UInt32(65535))
    for i in range(len(settings)):
        b.append(settings[i])
    h2.append_recv_bytes(Span(b))
    assert_equal(_try_consume_preface(h2), PREFACE_OK)
    assert_true(h2.is_preface_ok())
    assert_equal(len(h2.recv_buf), len(settings))
    assert_equal(Int(h2.recv_buf[3]), Int(FRAME_SETTINGS))


def test_preface_invalid_is_error_and_consumes_nothing() raises:
    """h2spec http2/3.5/2: an invalid preface is an error."""
    var h2 = H2ConnectionState()
    var b = _bytes("INVALID CONNECTION PREFACE\r\n\r\n")
    h2.append_recv_bytes(Span(b))
    assert_equal(_try_consume_preface(h2), PREFACE_ERROR)
    assert_equal(len(h2.recv_buf), len(b))
    assert_false(h2.is_preface_ok())


# -----------------------------------------------------------------------------
# L. The decode loop.
# -----------------------------------------------------------------------------


def test_empty_buffer_is_alive_and_silent() raises:
    var c = _Client()
    assert_true(c.send(List[UInt8]()))
    assert_equal(len(c.out()), 0)


def test_partial_frame_waits_for_the_rest() raises:
    """A PING one byte short: nothing is consumed and nothing is answered;
    the last byte completes it and it is answered."""
    var c = _Client()
    var ping = _ping(UInt8(0), UInt8(1))
    var head = List[UInt8]()
    for i in range(len(ping) - 1):
        head.append(ping[i])
    assert_true(c.send(head))
    assert_equal(len(c.h2.recv_buf), 16)
    assert_equal(len(c.out()), 0)
    var tail: List[UInt8] = [ping[len(ping) - 1]]
    assert_true(c.send(tail))
    assert_equal(len(c.h2.recv_buf), 0)
    var outs = c.out()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_PING))


def test_decode_error_goaway_carries_decoder_code() raises:
    """h2spec http2/6.8/1 (GOAWAY on stream 1) is a decode error with
    PROTOCOL_ERROR; h2spec http2/6.5/3 (a SETTINGS length that is not a
    multiple of 6) one with FRAME_SIZE_ERROR. Each closes with that code."""
    var c = _Client()
    var p = _u32(UInt32(0))
    var p2 = _u32(UInt32(0))
    for i in range(4):
        p.append(p2[i])
    assert_false(c.send(_raw(FRAME_GOAWAY, UInt8(0), 1, p)))
    _assert_goaway(c.out(), PROTOCOL_ERROR)
    assert_true(c.h2.is_goaway_sent())

    var c2 = _Client()
    var three: List[UInt8] = [UInt8(0), UInt8(0), UInt8(0)]
    assert_false(c2.send(_raw(FRAME_SETTINGS, UInt8(0), 0, three)))
    _assert_goaway(c2.out(), FRAME_SIZE_ERROR)


def test_push_promise_is_refused() raises:
    """h2spec http2/8.2/1: a client PUSH_PROMISE on stream 1 promising
    stream 3, END_HEADERS, the common request block. A connection
    PROTOCOL_ERROR."""
    var c = _Client()
    var p = _u32(UInt32(3))
    var block = c.get_block()
    for i in range(len(block)):
        p.append(block[i])
    assert_false(c.send(_raw(UInt8(0x5), FLAG_END_HEADERS, 1, p)))
    _assert_goaway(c.out(), PROTOCOL_ERROR)


comptime UNKNOWN_FRAME_TYPE: UInt8 = 0x16  # h2spec http2/5.5's extension type


def _unknown_frame() -> List[UInt8]:
    """h2spec http2/5.5's frame: type 0x16, flags 0, stream 0, eight zero
    bytes."""
    var eight = List[UInt8]()
    for _ in range(8):
        eight.append(UInt8(0))
    return _raw(UNKNOWN_FRAME_TYPE, UInt8(0), 0, eight)


def test_unknown_frame_is_ignored() raises:
    """h2spec http2/5.5/1: the unknown frame, then a PING of eight zero
    bytes: the frame is dropped and the PING is answered with ACK and the
    same bytes."""
    var c = _Client()
    var b = _unknown_frame()
    var zeros = List[UInt8]()
    for _ in range(8):
        zeros.append(UInt8(0))
    var ping = _raw(FRAME_PING, UInt8(0), 0, zeros)
    for i in range(len(ping)):
        b.append(ping[i])
    assert_true(c.send(b))
    var outs = c.out()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_PING))
    assert_equal(Int(outs[0].flags), Int(FLAG_ACK))
    for i in range(8):
        assert_equal(Int(outs[0].ping[i]), 0)


# -----------------------------------------------------------------------------
# R. Frames inside a header block.
# -----------------------------------------------------------------------------


def test_unknown_frame_inside_header_block_is_refused() raises:
    """h2spec http2/5.5/2: HEADERS on stream 1 (END_STREAM, no
    END_HEADERS), then the unknown frame: a connection PROTOCOL_ERROR."""
    var c = _Client()
    var b = c.headers(1, FLAG_END_STREAM)
    var u = _unknown_frame()
    for i in range(len(u)):
        b.append(u[i])
    assert_false(c.send(b))
    _assert_goaway(c.out(), PROTOCOL_ERROR, last_sid=1)


def test_priority_inside_header_block_is_refused() raises:
    """h2spec http2/6.2/1 (and 4.3/2): HEADERS without END_HEADERS, then
    PRIORITY on the same stream."""
    var c = _Client()
    var b = c.headers(1, UInt8(0))
    var p = _priority(1, 0)
    for i in range(len(p)):
        b.append(p[i])
    assert_false(c.send(b))
    _assert_goaway(c.out(), PROTOCOL_ERROR, last_sid=1)


def _dummy_block(mut c: _Client) -> List[UInt8]:
    """h2spec's `DummyHeaders(c, 1)` at its default --max-header-length:
    one field `x-dummy0` whose value is 4000 bytes of 'x'."""
    var value = String("")
    for _ in range(4000):
        value += "x"
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String("x-dummy0"), value))
    return c.enc.encode_block(hs^)


def test_data_after_continuation_is_refused() raises:
    """h2spec http2/6.10/2: HEADERS with the common block as POST (no
    END_STREAM, no END_HEADERS), a CONTINUATION with the dummy header block
    (no END_HEADERS), then DATA "test" with END_STREAM."""
    var c = _Client()
    var b = _raw(FRAME_HEADERS, UInt8(0), 1, c.block("POST"))
    var cont = _raw(FRAME_CONTINUATION, UInt8(0), 1, _dummy_block(c))
    for i in range(len(cont)):
        b.append(cont[i])
    var d = _data(1, "test", True)
    for i in range(len(d)):
        b.append(d[i])
    assert_false(c.send(b))
    _assert_goaway(c.out(), PROTOCOL_ERROR, last_sid=1)


def test_continuation_frames_complete_the_block() raises:
    """h2spec http2/6.10/1: HEADERS with the whole common block (END_STREAM,
    no END_HEADERS), then two CONTINUATIONs each carrying the dummy header
    block, the second with END_HEADERS. The request is answered 200 with the
    route's body."""
    var c = _Client()
    var b = _raw(FRAME_HEADERS, FLAG_END_STREAM, 1, c.get_block())
    var c1 = _raw(FRAME_CONTINUATION, UInt8(0), 1, _dummy_block(c))
    var c2 = _raw(FRAME_CONTINUATION, FLAG_END_HEADERS, 1, _dummy_block(c))
    for i in range(len(c1)):
        b.append(c1[i])
    for i in range(len(c2)):
        b.append(c2[i])
    assert_true(c.send(b))
    var outs = c.out()
    assert_equal(len(outs), 2)
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    assert_equal(_hval(outs[0].headers, ":status"), "200")
    assert_equal(Int(outs[1].kind), Int(FRAME_DATA))
    assert_equal(Int(outs[1].flags), Int(FLAG_END_STREAM))
    assert_equal(len(outs[1].payload), HELLO_LEN)


# -----------------------------------------------------------------------------
# T. SETTINGS.
# -----------------------------------------------------------------------------


def _goaway_for_setting(id: Int, val: UInt32) raises -> UInt32:
    var c = _Client()
    assert_false(c.send(_setting(id, val)), "the connection must close")
    var outs = c.out()
    assert_equal(len(outs), 1, "only the GOAWAY: no ACK")
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(c.h2.max_frame_size_peer, 16384, "nothing applied")
    return outs[0].code


def test_settings_out_of_range_values_are_refused() raises:
    """h2spec http2/6.5.2/1..4 and 6.9.2/3, each with its code."""
    assert_equal(Int(_goaway_for_setting(2, UInt32(2))), Int(PROTOCOL_ERROR))
    assert_equal(
        Int(_goaway_for_setting(4, UInt32(2147483648))),
        Int(FLOW_CONTROL_ERROR),
    )
    assert_equal(Int(_goaway_for_setting(5, UInt32(16383))), Int(PROTOCOL_ERROR))
    assert_equal(
        Int(_goaway_for_setting(5, UInt32(16777216))), Int(PROTOCOL_ERROR)
    )


def _ack_for(id: Int, val: UInt32) raises -> _Client:
    var c = _Client()
    assert_true(c.send(_setting(id, val)))
    var outs = c.out()
    assert_equal(len(outs), 1, "exactly one frame: the ACK")
    assert_equal(Int(outs[0].kind), Int(FRAME_SETTINGS))
    assert_equal(Int(outs[0].flags), Int(FLAG_ACK))
    assert_equal(len(outs[0].settings), 0)
    return c^


def test_settings_in_range_values_are_acked_and_applied() raises:
    """The range boundaries are accepted: ENABLE_PUSH 0 and 1, an initial
    window of 2^31-1, frame sizes 16384 and 2^24-1 (each applied). An
    unknown identifier (h2spec http2/6.5.2/5) is acknowledged and ignored."""
    _ = _ack_for(2, UInt32(0))
    _ = _ack_for(2, UInt32(1))
    var w = _ack_for(4, UInt32(0x7FFFFFFF))
    assert_equal(Int(w.h2.send_fc.initial_window_size), 0x7FFFFFFF)
    var lo = _ack_for(5, UInt32(16384))
    assert_equal(lo.h2.max_frame_size_peer, 16384)
    var hi = _ack_for(5, UInt32(16777215))
    assert_equal(hi.h2.max_frame_size_peer, 16777215)
    var mid = _ack_for(5, UInt32(20000))
    assert_equal(mid.h2.max_frame_size_peer, 20000)
    var unk = _ack_for(0xFF, UInt32(1))
    assert_equal(unk.h2.max_frame_size_peer, 16384)
    assert_equal(Int(unk.h2.max_concurrent_streams_peer), 100)


def test_settings_table_size_and_concurrency_are_applied() raises:
    var t = _ack_for(1, UInt32(1024))
    assert_true(Bool(t.h2.hpack_encoder.pending_final))
    assert_equal(Int(t.h2.hpack_encoder.pending_final.value()), 1024)
    var m = _ack_for(3, UInt32(7))
    assert_equal(Int(m.h2.max_concurrent_streams_peer), 7)
    assert_false(Bool(m.h2.hpack_encoder.pending_final))


def test_settings_ack_is_not_answered() raises:
    var c = _Client()
    assert_true(c.send(_raw(FRAME_SETTINGS, FLAG_ACK, 0, List[UInt8]())))
    assert_equal(len(c.out()), 0)


def _data_lengths(outs: List[_Out], sid: Int) -> List[Int]:
    var lens = List[Int]()
    for i in range(len(outs)):
        if outs[i].kind == FRAME_DATA and Int(outs[i].sid) == sid:
            lens.append(len(outs[i].payload))
    return lens^


def test_initial_window_of_one_limits_the_response() raises:
    """h2spec http2/6.9.1/1: SETTINGS_INITIAL_WINDOW_SIZE = 1, then a GET:
    the response DATA is one byte long; the rest waits."""
    var c = _Client()
    assert_true(c.send(_setting(4, UInt32(1))))
    _ = c.out()
    assert_true(c.send(c.get(1, True)))
    var lens = _data_lengths(c.out(), 1)
    assert_equal(len(lens), 1)
    assert_equal(lens[0], 1)
    assert_equal(c.h2.deferred_response_body_len(UInt32(1)), HELLO_LEN - 1)


def test_initial_window_change_resizes_open_streams() raises:
    """h2spec http2/6.9.2/1: window 0, a GET (no DATA can go), then window
    1: the ACK and one DATA byte, sent by the deferred pump."""
    var c = _Client()
    assert_true(c.send(_setting(4, UInt32(0))))
    assert_true(c.send(c.get(1, True)))
    var first = c.out()
    assert_equal(len(_data_lengths(first, 1)), 0, "no DATA at window 0")
    assert_true(c.send(_setting(4, UInt32(1))))
    var outs = c.out()
    assert_equal(len(outs), 2)
    assert_equal(Int(outs[0].kind), Int(FRAME_SETTINGS))
    assert_equal(Int(outs[1].kind), Int(FRAME_DATA))
    assert_equal(len(outs[1].payload), 1)
    assert_equal(Int(outs[1].flags), 0, "the body is not finished")


def test_negative_window_is_tracked() raises:
    """h2spec http2/6.9.2/2: window 3, a GET (3 bytes go), window 2 (the
    stream window becomes -1), WINDOW_UPDATE +2: exactly one more byte."""
    var c = _Client()
    assert_true(c.send(_setting(4, UInt32(3))))
    assert_true(c.send(c.get(1, True)))
    var lens = _data_lengths(c.out(), 1)
    assert_equal(len(lens), 1)
    assert_equal(lens[0], 3)
    assert_true(c.send(_setting(4, UInt32(2))))
    assert_equal(len(_data_lengths(c.out(), 1)), 0)
    assert_equal(Int(c.h2.streams[c.h2.find_stream_idx(UInt32(1))].send_window), -1)
    assert_true(c.send(_window_update(1, UInt32(2))))
    var after = _data_lengths(c.out(), 1)
    assert_equal(len(after), 1)
    assert_equal(after[0], 1)


# -----------------------------------------------------------------------------
# G. PING and a peer GOAWAY.
# -----------------------------------------------------------------------------


def test_ping_is_echoed_with_ack() raises:
    """h2spec http2/6.7/1."""
    var c = _Client()
    assert_true(c.send(_ping(UInt8(0), UInt8(0x41))))
    var outs = c.out()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_PING))
    assert_equal(Int(outs[0].flags), Int(FLAG_ACK))
    for i in range(8):
        assert_equal(Int(outs[0].ping[i]), 0x41 + i)


def test_ping_ack_is_not_answered() raises:
    """h2spec http2/6.7/2."""
    var c = _Client()
    assert_true(c.send(_ping(FLAG_ACK, UInt8(0))))
    assert_equal(len(c.out()), 0)


def test_peer_goaway_keeps_processing() raises:
    """A GOAWAY then a PING (h2spec's graceful-close probe): the GOAWAY is
    recorded and the PING is still answered."""
    var c = _Client()
    var p = _u32(UInt32(0))
    var code = _u32(UInt32(0))
    for i in range(4):
        p.append(code[i])
    var b = _raw(FRAME_GOAWAY, UInt8(0), 0, p)
    var ping = _ping(UInt8(0), UInt8(7))
    for i in range(len(ping)):
        b.append(ping[i])
    assert_true(c.send(b))
    assert_true(c.h2.is_goaway_received())
    assert_false(c.h2.is_goaway_sent())
    var outs = c.out()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_PING))
    assert_equal(Int(outs[0].ping[0]), 7)


# -----------------------------------------------------------------------------
# Y. PRIORITY.
# -----------------------------------------------------------------------------


def test_priority_self_dependency_on_idle_stream() raises:
    """h2spec http2/5.3.1/2: RST_STREAM(PROTOCOL_ERROR); no stream made."""
    var c = _Client()
    assert_true(c.send(_priority(1, 1)))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, PROTOCOL_ERROR)
    assert_equal(c.h2.find_stream_idx(UInt32(1)), -1)


def test_priority_self_dependency_closes_known_stream() raises:
    """A GET on stream 1 (still open: no END_STREAM), then h2spec
    http2/5.3.1/2's frame on it: RST_STREAM and the stream is closed."""
    var c = _Client()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))
    assert_true(c.send(_priority(1, 1)))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, PROTOCOL_ERROR)
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_CLOSED))


def test_priority_on_another_stream_is_silent() raises:
    var c = _Client()
    assert_true(c.send(_priority(3, 1)))
    assert_equal(len(c.out()), 0)


# -----------------------------------------------------------------------------
# W. WINDOW_UPDATE.
# -----------------------------------------------------------------------------


def test_connection_window_overflow() raises:
    """h2spec http2/6.9.1/2: two connection WINDOW_UPDATEs of 2^31-1; the
    first already overflows. GOAWAY(FLOW_CONTROL_ERROR)."""
    var c = _Client()
    var b = _window_update(0, UInt32(0x7FFFFFFF))
    var b2 = _window_update(0, UInt32(0x7FFFFFFF))
    for i in range(len(b2)):
        b.append(b2[i])
    assert_false(c.send(b))
    _assert_goaway(c.out(), FLOW_CONTROL_ERROR)


def test_connection_window_update_is_applied() raises:
    var c = _Client()
    assert_true(c.send(_window_update(0, UInt32(1000))))
    assert_equal(Int(c.h2.send_fc.conn_send_window), 65535 + 1000)
    assert_equal(len(c.out()), 0)


def test_connection_window_update_releases_a_deferred_body() raises:
    """The connection window, not the stream's, holds the body back. It is
    set to 5 directly (traffic would need 3641 responses to use it up): 5
    bytes go, and a connection WINDOW_UPDATE sends the rest with END_STREAM."""
    var c = _Client()
    c.h2.send_fc.conn_send_window = Int32(5)
    assert_true(c.send(c.get(1, True)))
    var lens = _data_lengths(c.out(), 1)
    assert_equal(len(lens), 1)
    assert_equal(lens[0], 5)
    assert_true(c.send(_window_update(0, UInt32(100))))
    var outs = c.out()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_DATA))
    assert_equal(len(outs[0].payload), HELLO_LEN - 5)
    assert_equal(Int(outs[0].flags), Int(FLAG_END_STREAM))


def test_stream_window_overflow_resets_the_stream() raises:
    """h2spec http2/6.9.1/3: HEADERS without END_STREAM, then two stream
    WINDOW_UPDATEs of 2^31-1. The first overflows: RST_STREAM(
    FLOW_CONTROL_ERROR), and sending it closes the stream (RFC 9113 §5.1).
    The second arrives on a closed stream after our RST_STREAM and is
    ignored (§5.1), so there is exactly one RST_STREAM; the connection stays
    open."""
    var c = _Client()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    var b = _window_update(1, UInt32(0x7FFFFFFF))
    var b2 = _window_update(1, UInt32(0x7FFFFFFF))
    for i in range(len(b2)):
        b.append(b2[i])
    assert_true(c.send(b))
    var outs = c.out()
    assert_equal(len(outs), 1, "one RST_STREAM; the second update is ignored")
    _assert_rst(outs[0], 1, FLOW_CONTROL_ERROR)
    assert_false(c.h2.is_goaway_sent())
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(
        Int(c.h2.streams[idx].state),
        Int(STREAM_STATE_CLOSED),
        "the reset stream is closed",
    )


def test_window_update_on_idle_stream() raises:
    """h2spec http2/5.1/3: connection PROTOCOL_ERROR."""
    var c = _Client()
    assert_false(c.send(_window_update(1, UInt32(100))))
    _assert_goaway(c.out(), PROTOCOL_ERROR)


def test_window_update_on_skipped_stream_is_ignored() raises:
    """Stream 3 is implicitly closed once stream 5 opens (RFC 9113 §5.1.1);
    a WINDOW_UPDATE for it is ignored."""
    var c = _Client()
    assert_true(c.send(c.get(5, True)))
    _ = c.out()
    assert_true(c.send(_window_update(3, UInt32(100))))
    assert_equal(len(c.out()), 0)


# -----------------------------------------------------------------------------
# X. RST_STREAM and DATA.
# -----------------------------------------------------------------------------


def test_rst_stream_on_idle_stream() raises:
    """h2spec http2/5.1/2."""
    var c = _Client()
    assert_false(c.send(_rst(1, UInt32(0x8))))
    _assert_goaway(c.out(), PROTOCOL_ERROR)


def test_rst_stream_on_skipped_stream_is_ignored() raises:
    var c = _Client()
    assert_true(c.send(c.get(5, True)))
    _ = c.out()
    assert_true(c.send(_rst(3, UInt32(0x8))))
    assert_equal(len(c.out()), 0)
    assert_false(c.h2.is_goaway_sent())


def test_data_after_rst_stream_is_stream_closed() raises:
    """h2spec http2/5.1/8: HEADERS, RST_STREAM(CANCEL), DATA. The RST closes
    the stream; the DATA is answered RST_STREAM(STREAM_CLOSED)."""
    var c = _Client()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    assert_true(c.send(_rst(1, UInt32(0x8))))
    assert_equal(len(c.out()), 0)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_CLOSED))
    assert_true(c.send(_data(1, "test", True)))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, STREAM_CLOSED)


def test_data_on_idle_stream() raises:
    """h2spec http2/5.1/1: DATA "test" with END_STREAM on idle stream 1, a
    connection PROTOCOL_ERROR."""
    var c = _Client()
    assert_false(c.send(_data(1, "test", True)))
    _assert_goaway(c.out(), PROTOCOL_ERROR)


def test_data_on_half_closed_remote_stream() raises:
    """h2spec http2/6.1/2 (and 5.1/5): HEADERS with END_STREAM, then DATA:
    RST_STREAM(STREAM_CLOSED), the connection stays."""
    var c = _Client()
    assert_true(c.send(c.get(1, True)))
    _ = c.out()
    assert_true(c.send(_data(1, "test", False)))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_rst(outs[0], 1, STREAM_CLOSED)


def test_data_bytes_are_counted_on_an_answered_stream() raises:
    """A GET without END_STREAM and with no declared length is answered at
    once; its later DATA is counted and flow-controlled, and answers
    nothing."""
    var c = _Client()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    assert_true(c.send(_data(1, "test", False)))
    assert_true(c.send(_data(1, "abcdef", True)))
    assert_equal(len(c.out()), 0)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].recv_data_bytes), 10)
    assert_equal(Int(c.h2.recv_fc.conn_recv_window), 65535 - 10)
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_CLOSED))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
