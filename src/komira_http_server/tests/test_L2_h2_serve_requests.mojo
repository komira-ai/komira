# =============================================================================
# test_L2_h2_serve_requests.mojo: the h2 serve loop's request path, from a
# header block to the response it queues
# =============================================================================
#
# Drives `serve_h2._dispatch_h2_frames` (and, where the decoder already
# refuses a frame before the dispatcher sees it, the handler
# `_handle_headers_or_continuation` directly) with HEADERS, CONTINUATION and
# DATA frames, then decodes every frame the server queued and asserts them
# exactly. A manual-clock gRPC service stands in for the application so a
# deadline outcome is arithmetic, never a wall-clock race.
#
# Every malformed request is an h2spec v2.6.0 case and is named for it
# (`http2/<section>/<n>`); the malformed grpc-timeout values come from
# grpc-go's `TestDecodeTimeout` table. The other requests are ordinary.
#
# Groups (and the defect each would catch):
#   H  header-block legality: stream 0, an even or decreasing stream id, a
#      HEADERS or CONTINUATION out of place, an undecodable block, a stream
#      that depends on itself; each must answer the h2spec code at the right
#      scope.
#   C  the concurrent-stream limit: the 51st stream refused with
#      REFUSED_STREAM ahead of the queued responses, the 50th accepted, a
#      second GOAWAY never sent.
#   V  request validation (RFC 9113 §8.1.2): each malformed block is answered
#      RST_STREAM(PROTOCOL_ERROR) and never reaches the router; the method
#      names map to their methods.
#   D  requests with a body: answered once the body has arrived; the
#      h2spec http2/8.1.2.6 cases answered RST_STREAM(PROTOCOL_ERROR) with
#      the held request dropped and never dispatched.
#   R  gRPC: the call reaches the service with its body, unary and
#      streaming; a malformed or expired grpc-timeout answered without
#      running the handler; a handler that overruns its deadline answered
#      DEADLINE_EXCEEDED.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PRIORITY,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    Frame,
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
)
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
)
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import (
    _build_and_dispatch_request,
    _dispatch_h2_frames,
    _handle_headers_or_continuation,
)
from komira_http_server.serve_h2_headers import (
    _is_connection_specific_header,
    _is_lowercase_or_pseudo,
    _parse_int_safe,
)


comptime PROTOCOL_ERROR: UInt32 = 0x1
comptime REFUSED_STREAM: UInt32 = 0x7
comptime COMPRESSION_ERROR: UInt32 = 0x9
comptime US: UInt64 = 1_000
comptime GRPC_CT = "application/grpc"
comptime STREAM_PATH = "/svc.S/List"


# -----------------------------------------------------------------------------
# The application: a router and a gRPC service on a manual clock.
# -----------------------------------------------------------------------------


struct _Rpc(GrpcDispatch, GrpcStreamDispatch):
    """Echoes the request body; each handler call advances the clock by
    `cost_ns`. A streaming call answers `n_msgs` copies of the body."""

    var now: UInt64
    var cost_ns: UInt64
    var unary_calls: Int
    var stream_calls: Int
    var last_body: List[UInt8]
    var last_path: String
    var n_msgs: Int

    def __init__(out self):
        self.now = UInt64(1_000_000_000)
        self.cost_ns = UInt64(0)
        self.unary_calls = 0
        self.stream_calls = 0
        self.last_body = List[UInt8]()
        self.last_path = String("")
        self.n_msgs = 2

    def grpc_now_ns(self) -> UInt64:
        return self.now

    def dispatch_grpc(
        mut self, path: String, content_type: String, request_body: List[UInt8]
    ) -> GrpcResponse:
        self.unary_calls += 1
        self.now += self.cost_ns
        self.last_body = request_body.copy()
        self.last_path = path
        return GrpcResponse(
            request_body.copy(),
            UInt16(200),
            UInt8(0),
            String(""),
            String(GRPC_CT),
            True,
        )

    def dispatch_grpc_stream(
        mut self,
        path: String,
        content_type: String,
        kind: UInt8,
        request_body: List[UInt8],
    ) -> GrpcStreamResponse:
        self.stream_calls += 1
        self.now += self.cost_ns
        self.last_body = request_body.copy()
        var msgs = List[List[UInt8]]()
        for _ in range(self.n_msgs):
            msgs.append(request_body.copy())
        return GrpcStreamResponse(
            msgs^, UInt16(200), UInt8(0), String(""), String(GRPC_CT)
        )

    def grpc_stream_kind(self, path: String) -> UInt8:
        if path == STREAM_PATH:
            return GRPC_KIND_SERVER_STREAM
        return GRPC_KIND_UNARY


struct _Out(Copyable, Movable):
    var kind: UInt8
    var flags: UInt8
    var sid: UInt32
    var code: UInt32
    var last_sid: UInt32
    var payload: List[UInt8]
    var headers: List[HpackHeader]

    def __init__(out self):
        self.kind = UInt8(0xFF)
        self.flags = UInt8(0)
        self.sid = UInt32(0)
        self.code = UInt32(0)
        self.last_sid = UInt32(0)
        self.payload = List[UInt8]()
        self.headers = List[HpackHeader]()


def _hval(hs: List[HpackHeader], name: String) -> String:
    for i in range(len(hs)):
        if String(hs[i].name) == name:
            return String(hs[i].value)
    return String("<absent>")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _raw(kind: UInt8, flags: UInt8, sid: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    encode_frame_header(UInt32(len(payload)), kind, flags, UInt32(sid), out)
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


def _cat(mut a: List[UInt8], b: List[UInt8]):
    for i in range(len(b)):
        a.append(b[i])


def _h(name: String, value: String) -> HpackHeader:
    return HpackHeader(name, value)


def _common(method: String, path: String) -> List[HpackHeader]:
    """h2spec's common request headers."""
    var hs = List[HpackHeader]()
    hs.append(_h(":method", method))
    hs.append(_h(":scheme", "https"))
    hs.append(_h(":path", path))
    hs.append(_h(":authority", "localhost"))
    return hs^


struct _Client(Movable):
    var h2: H2ConnectionState
    var router: Router
    var rpc: _Rpc
    var enc: HpackEncoder
    var dec: HpackDecoder
    var reqs: Int64
    var sent: Int64

    def __init__(out self) raises:
        self.h2 = H2ConnectionState()
        self.h2.mark_preface_ok()
        self.router = Router()
        self.router.add(HttpMethod.get(), "/", 1)
        self.rpc = _Rpc()
        self.enc = HpackEncoder()
        self.dec = HpackDecoder()
        self.reqs = Int64(0)
        self.sent = Int64(0)

    def send(mut self, bytes: List[UInt8]) -> Bool:
        self.h2.append_recv_bytes(Span(bytes))
        return _dispatch_h2_frames(
            self.h2, self.router, self.rpc, self.reqs, self.sent
        )

    def handle(mut self, var frame: Frame) -> Bool:
        """Hand one decoded frame to the HEADERS/CONTINUATION handler."""
        return _handle_headers_or_continuation(
            self.h2, frame^, self.router, self.rpc, self.reqs, self.sent
        )

    def block(mut self, var hs: List[HpackHeader]) -> List[UInt8]:
        return self.enc.encode_block(hs^)

    def request(
        mut self, sid: Int, var hs: List[HpackHeader], end_stream: Bool
    ) -> List[UInt8]:
        var flags = FLAG_END_HEADERS
        if end_stream:
            flags = flags | FLAG_END_STREAM
        return _raw(FRAME_HEADERS, flags, sid, self.block(hs^))

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
                o.last_sid = f.goaway_last_stream_id
            if f.header.kind == FRAME_DATA:
                o.payload = f.payload.copy()
            if f.header.kind == FRAME_HEADERS:
                o.headers = self.dec.decode_block(Span(f.payload))
            outs.append(o^)
        return outs^


def _frame(kind: UInt8, flags: UInt8, sid: Int, var payload: List[UInt8]) -> Frame:
    var f = Frame()
    f.header.length = UInt32(len(payload))
    f.header.kind = kind
    f.header.flags = flags
    f.header.stream_id = UInt32(sid)
    f.payload = payload^
    return f^


def _assert_goaway(outs: List[_Out], code: UInt32, last_sid: Int) raises:
    assert_equal(len(outs), 1, "exactly one frame: the GOAWAY")
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[0].code), Int(code))
    assert_equal(Int(outs[0].last_sid), last_sid)


def _assert_rst_only(outs: List[_Out], sid: Int, code: UInt32) raises:
    assert_equal(len(outs), 1, "exactly one frame: the RST_STREAM")
    assert_equal(Int(outs[0].kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(outs[0].sid), sid)
    assert_equal(Int(outs[0].code), Int(code))


def _assert_answered(outs: List[_Out], sid: Int, status: String, body: String) raises:
    """A router response: HEADERS (:status, content-length, text/plain) and
    one DATA with END_STREAM carrying `body`."""
    assert_equal(len(outs), 2)
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs[0].sid), sid)
    assert_equal(Int(outs[0].flags), Int(FLAG_END_HEADERS))
    assert_equal(_hval(outs[0].headers, ":status"), status)
    assert_equal(_hval(outs[0].headers, "content-type"), "text/plain")
    var b = _bytes(body)
    assert_equal(_hval(outs[0].headers, "content-length"), String(len(b)))
    assert_equal(Int(outs[1].kind), Int(FRAME_DATA))
    assert_equal(Int(outs[1].flags), Int(FLAG_END_STREAM))
    assert_equal(len(outs[1].payload), len(b))
    for i in range(len(b)):
        assert_equal(Int(outs[1].payload[i]), Int(b[i]))


# -----------------------------------------------------------------------------
# H. Header-block legality.
# -----------------------------------------------------------------------------


def test_headers_on_stream_zero() raises:
    """h2spec http2/6.2/3. The decoder refuses it first, so the handler's own
    refusal is driven directly."""
    var c = _Client()
    assert_false(c.handle(_frame(FRAME_HEADERS, FLAG_END_HEADERS, 0, c.block(_common("GET", "/")))))
    _assert_goaway(c.out(), PROTOCOL_ERROR, 0)


def test_headers_to_another_stream_inside_a_block() raises:
    """h2spec http2/4.3/3 and 6.2/2."""
    var c = _Client()
    var b = _raw(FRAME_HEADERS, UInt8(0), 1, c.block(_common("GET", "/")))
    _cat(b, c.request(3, _common("GET", "/"), True))
    assert_false(c.send(b))
    _assert_goaway(c.out(), PROTOCOL_ERROR, 1)


def test_even_stream_id() raises:
    """h2spec http2/5.1.1/1."""
    var c = _Client()
    assert_false(c.send(c.request(2, _common("GET", "/"), True)))
    _assert_goaway(c.out(), PROTOCOL_ERROR, 0)


def test_decreasing_stream_id() raises:
    """h2spec http2/5.1.1/2: stream 5 then stream 3."""
    var c = _Client()
    assert_true(c.send(c.request(5, _common("GET", "/"), True)))
    _ = c.out()
    assert_false(c.send(c.request(3, _common("GET", "/"), True)))
    _assert_goaway(c.out(), PROTOCOL_ERROR, 5)


def _trailers_after_a_body(var trailers: List[HpackHeader], end_stream: Bool) raises -> _Client:
    """HEADERS with the common block as POST (END_HEADERS, no END_STREAM),
    DATA "test" (no END_STREAM), then `trailers` in a HEADERS frame with
    END_HEADERS on the same stream. Returns the client after the trailers."""
    var c = _Client()
    assert_true(c.send(c.request(1, _common("POST", "/"), False)))
    assert_true(c.send(_raw(FRAME_DATA, UInt8(0), 1, _bytes("test"))))
    _ = c.out()
    var flags = FLAG_END_HEADERS
    if end_stream:
        flags = flags | FLAG_END_STREAM
    assert_false(c.send(_raw(FRAME_HEADERS, flags, 1, c.block(trailers^))))
    return c^


def test_trailers_with_pseudo_header_reuse_the_stream() raises:
    """h2spec http2/8.1.2.1/3, frame for frame: HEADERS (POST, END_HEADERS,
    no END_STREAM), DATA "test" (no END_STREAM), then trailers holding
    `:method: POST` (END_HEADERS, no END_STREAM). Then the same request with
    legal trailers (`x-trailer`, END_STREAM).

    Today's behaviour, pinned on purpose: any second HEADERS on an open
    stream is a connection PROTOCOL_ERROR (GOAWAY), because its stream id
    is no longer new, so legal trailers are refused as well as malformed
    ones. This departs from RFC 9113 §8.1 (a trailer section is a HEADERS
    frame on the open stream) and §8.1.1 (a malformed one is a stream
    error, RST_STREAM, which is what h2spec expects); it is tracked in
    komira#897, and a fix flips both halves of this test."""
    var t = List[HpackHeader]()
    t.append(_h(":method", "POST"))
    var c = _trailers_after_a_body(t^, False)
    _assert_goaway(c.out(), PROTOCOL_ERROR, 1)

    var legal = List[HpackHeader]()
    legal.append(_h("x-trailer", "ok"))
    var c2 = _trailers_after_a_body(legal^, True)
    _assert_goaway(c2.out(), PROTOCOL_ERROR, 1)


def _dummy() -> List[HpackHeader]:
    """h2spec's `DummyHeaders(c, 1)` at its default --max-header-length:
    one field `x-dummy0` whose value is 4000 bytes of 'x'."""
    var value = String("")
    for _ in range(4000):
        value += "x"
    var hs = List[HpackHeader]()
    hs.append(_h("x-dummy0", value))
    return hs^


def test_continuation_without_a_block() raises:
    """h2spec http2/5.1/4 (CONTINUATION with the common block, END_HEADERS,
    on idle stream 1) and 6.10/4 (HEADERS with END_STREAM and END_HEADERS,
    then a CONTINUATION with the dummy block and END_HEADERS)."""
    var c = _Client()
    assert_false(c.send(_raw(FRAME_CONTINUATION, FLAG_END_HEADERS, 1, c.block(_common("GET", "/")))))
    _assert_goaway(c.out(), PROTOCOL_ERROR, 0)

    var c2 = _Client()
    var b = c2.request(1, _common("GET", "/"), True)
    _cat(b, _raw(FRAME_CONTINUATION, FLAG_END_HEADERS, 1, c2.block(_dummy())))
    assert_false(c2.send(b))
    var outs = c2.out()
    assert_equal(Int(outs[len(outs) - 1].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[len(outs) - 1].code), Int(PROTOCOL_ERROR))


def test_continuation_on_stream_zero_inside_a_block() raises:
    """h2spec http2/6.10/3: HEADERS on stream 1 (END_STREAM, no
    END_HEADERS), then a CONTINUATION with the dummy block and END_HEADERS
    on stream 0 (driven into the handler: the decoder refuses stream 0
    first)."""
    var c = _Client()
    assert_true(c.handle(_frame(FRAME_HEADERS, FLAG_END_STREAM, 1, c.block(_common("GET", "/")))))
    assert_false(c.handle(_frame(FRAME_CONTINUATION, FLAG_END_HEADERS, 0, c.block(_dummy()))))
    _assert_goaway(c.out(), PROTOCOL_ERROR, 1)


def test_invalid_header_block_fragment() raises:
    """h2spec http2/4.3/1: the block 0x40 (a literal with no name length)
    is a connection COMPRESSION_ERROR."""
    var c = _Client()
    var p: List[UInt8] = [UInt8(0x40)]
    assert_false(c.send(_raw(FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, p)))
    _assert_goaway(c.out(), COMPRESSION_ERROR, 1)


def _priority_headers(mut c: _Client, sid: Int, dep: Int) -> List[UInt8]:
    var p = List[UInt8]()
    p.append(UInt8(0))
    p.append(UInt8(0))
    p.append(UInt8(0))
    p.append(UInt8(dep))
    p.append(UInt8(15))
    _cat(p, c.block(_common("GET", "/")))
    return _raw(FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM | FLAG_PRIORITY, sid, p)


def test_headers_depending_on_itself() raises:
    """h2spec http2/5.3.1/1: RST_STREAM(PROTOCOL_ERROR), the stream closed,
    no response, and the next stream id moves past it."""
    var c = _Client()
    assert_true(c.send(_priority_headers(c, 1, 1)))
    _assert_rst_only(c.out(), 1, PROTOCOL_ERROR)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_CLOSED))
    assert_equal(Int(c.h2.next_expected_stream_id), 3)
    assert_equal(Int(c.reqs), 0)


def test_headers_with_priority_on_another_stream() raises:
    var c = _Client()
    assert_true(c.send(_priority_headers(c, 3, 1)))
    _assert_answered(c.out(), 3, "200", "Hello from HTTP/2!")


# -----------------------------------------------------------------------------
# C. The concurrent-stream limit.
# -----------------------------------------------------------------------------


def test_concurrent_stream_limit() raises:
    """h2spec http2/5.1.2/1: SETTINGS_INITIAL_WINDOW_SIZE 0 (so no response
    finishes), then 51 GETs. The first 50 are answered (HEADERS only); the
    51st is refused: GOAWAY then RST_STREAM, both REFUSED_STREAM, at the
    front of the queue. A 52nd gets its RST_STREAM and no second GOAWAY; a
    malformed frame after that closes without one either."""
    var c = _Client()
    var w = List[UInt8]()
    encode_frame_header(UInt32(6), FRAME_SETTINGS, UInt8(0), UInt32(0), w)
    var s: List[UInt8] = [UInt8(0), UInt8(4), UInt8(0), UInt8(0), UInt8(0), UInt8(0)]
    _cat(w, s)
    assert_true(c.send(w))
    var b = List[UInt8]()
    for k in range(51):
        _cat(b, c.request(2 * k + 1, _common("GET", "/"), True))
    assert_true(c.send(b))
    var outs = c.out()
    assert_equal(len(outs), 1 + 2 + 50)
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[0].code), Int(REFUSED_STREAM))
    assert_equal(Int(outs[0].last_sid), 99)
    assert_equal(Int(outs[1].kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(outs[1].sid), 101)
    assert_equal(Int(outs[1].code), Int(REFUSED_STREAM))
    assert_equal(Int(outs[2].kind), Int(FRAME_SETTINGS), "the SETTINGS ACK")
    for k in range(50):
        assert_equal(Int(outs[3 + k].kind), Int(FRAME_HEADERS))
        assert_equal(Int(outs[3 + k].sid), 2 * k + 1)
    assert_equal(Int(c.h2.next_expected_stream_id), 103)

    assert_true(c.send(c.request(103, _common("GET", "/"), True)))
    _assert_rst_only(c.out(), 103, REFUSED_STREAM)

    var goaway_on_1 = List[UInt8]()
    encode_frame_header(UInt32(8), FRAME_GOAWAY, UInt8(0), UInt32(1), goaway_on_1)
    for _ in range(8):
        goaway_on_1.append(UInt8(0))
    assert_false(c.send(goaway_on_1), "h2spec http2/6.8/1 still closes")
    assert_equal(len(c.out()), 0, "no second GOAWAY")


def test_closed_streams_do_not_count() raises:
    """50 GETs answered in full (their streams closed), then a 51st: it is
    answered, not refused."""
    var c = _Client()
    var b = List[UInt8]()
    for k in range(51):
        _cat(b, c.request(2 * k + 1, _common("GET", "/"), True))
    assert_true(c.send(b))
    var outs = c.out()
    assert_equal(len(outs), 2 * 51)
    assert_false(c.h2.is_goaway_sent())
    assert_equal(Int(c.reqs), 51)


# -----------------------------------------------------------------------------
# V. Request validation and routing.
# -----------------------------------------------------------------------------


def _refused(var hs: List[HpackHeader]) raises:
    var c = _Client()
    assert_true(c.send(c.request(1, hs^, True)), "a stream error only")
    _assert_rst_only(c.out(), 1, PROTOCOL_ERROR)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_CLOSED))
    assert_equal(Int(c.reqs), 0)


def _without(var hs: List[HpackHeader], name: String) -> List[HpackHeader]:
    var out = List[HpackHeader]()
    for i in range(len(hs)):
        if String(hs[i].name) != name:
            out.append(hs[i])
    return out^


def test_malformed_requests_are_reset() raises:
    """h2spec http2/8.1.2/1, 8.1.2.1/1, /2, /4, 8.1.2.2/1, /2 and
    8.1.2.3/1 to /7."""
    var up = _common("GET", "/")
    up.append(_h("X-TEST", "ok"))
    _refused(up^)  # 8.1.2/1
    var unk = _common("GET", "/")
    unk.append(_h(":test", "ok"))
    _refused(unk^)  # 8.1.2.1/1
    var st = _common("GET", "/")
    st.append(_h(":status", "200"))
    _refused(st^)  # 8.1.2.1/2
    var after = List[HpackHeader]()
    after.append(_h("x-test", "ok"))
    var cm = _common("GET", "/")
    for i in range(len(cm)):
        after.append(cm[i])
    _refused(after^)  # 8.1.2.1/4
    var conn = _common("GET", "/")
    conn.append(_h("connection", "keep-alive"))
    _refused(conn^)  # 8.1.2.2/1
    var te = _common("GET", "/")
    te.append(_h("trailers", "test"))
    te.append(_h("te", "trailers, deflate"))
    _refused(te^)  # 8.1.2.2/2
    var empty_path = _without(_common("GET", "/"), ":path")
    empty_path.append(_h(":path", ""))
    _refused(empty_path^)  # 8.1.2.3/1
    _refused(_without(_common("GET", "/"), ":method"))  # 8.1.2.3/2
    _refused(_without(_common("GET", "/"), ":scheme"))  # 8.1.2.3/3
    _refused(_without(_common("GET", "/"), ":path"))  # 8.1.2.3/4
    var dm = _common("GET", "/")
    dm.append(_h(":method", "GET"))
    _refused(dm^)  # 8.1.2.3/5
    var ds = _common("GET", "/")
    ds.append(_h(":scheme", "https"))
    _refused(ds^)  # 8.1.2.3/6
    var dp = _common("GET", "/")
    dp.append(_h(":path", "/"))
    _refused(dp^)  # 8.1.2.3/7


def test_te_trailers_is_allowed() raises:
    """A request with `te: trailers`, the one TE value RFC 9113 §8.2.2
    allows, is answered (h2spec http2/8.1.2.2/2 pins the refusal of any
    other)."""
    var c = _Client()
    var hs = _common("GET", "/")
    hs.append(_h("te", "trailers"))
    hs.append(_h("accept", "*/*"))
    assert_true(c.send(c.request(1, hs^, True)))
    _assert_answered(c.out(), 1, "200", "Hello from HTTP/2!")


def test_duplicate_authority_is_refused() raises:
    var hs = _common("GET", "/")
    hs.append(_h(":authority", "localhost"))
    _refused(hs^)


def test_unrouted_path_is_404() raises:
    var c = _Client()
    assert_true(c.send(c.request(1, _common("GET", "/missing"), True)))
    _assert_answered(c.out(), 1, "404", "Not Found")
    assert_equal(Int(c.reqs), 1)
    assert_equal(Int(c.sent), 9)


def _status(outs: List[_Out], sid: Int) raises -> String:
    assert_true(len(outs) >= 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs[0].sid), sid)
    return _hval(outs[0].headers, ":status")


def test_methods_map_to_their_routes() raises:
    """Each method reaches only its own route (the :status of the answer
    says which).

    Today's behaviour, pinned on purpose by the last request: a method the
    server does not implement (TRACE) is routed as GET and answered by the
    GET route. This departs from RFC 9113 §8.3.1 (`:method` carries the
    request's method, RFC 9110 §9; an unrecognized one is answered 501,
    RFC 9110 §9.1) and is tracked in komira#897; a fix flips the TRACE
    assertion."""
    var names: List[String] = ["POST", "PUT", "DELETE", "HEAD", "PATCH", "OPTIONS"]
    var methods: List[HttpMethod] = [
        HttpMethod.post(), HttpMethod.put(), HttpMethod.delete(),
        HttpMethod.head(), HttpMethod.patch(), HttpMethod.options(),
    ]
    for m in range(len(names)):
        var c = _Client()
        c.router.add(methods[m].copy(), "/r", 7)
        assert_true(c.send(c.request(1, _common(names[m], "/r"), True)))
        assert_equal(_status(c.out(), 1), "200", names[m])
        var other = names[(m + 1) % len(names)]
        assert_true(c.send(c.request(3, _common(other, "/r"), True)))
        assert_equal(_status(c.out(), 3), "404", other)
        assert_true(c.send(c.request(5, _common("GET", "/r"), True)))
        assert_equal(_status(c.out(), 5), "404", "GET")
    var g = _Client()
    assert_true(g.send(g.request(1, _common("TRACE", "/"), True)))
    _assert_answered(g.out(), 1, "200", "Hello from HTTP/2!")


def test_router_path_refuses_malformed_headers_itself() raises:
    """`_build_and_dispatch_request` validates again; driven directly with
    h2spec http2/8.1.2.3/2's block (no :method), for a stream it knows and
    one it does not."""
    var c = _Client()
    _ = c.h2.get_or_create_stream(UInt32(1))
    assert_true(_build_and_dispatch_request(
        c.h2, UInt32(1), _without(_common("GET", "/"), ":method"), True,
        c.router, c.reqs, c.sent,
    ))
    _assert_rst_only(c.out(), 1, PROTOCOL_ERROR)
    assert_equal(Int(c.h2.streams[0].state), Int(STREAM_STATE_CLOSED))
    assert_true(_build_and_dispatch_request(
        c.h2, UInt32(9), _without(_common("GET", "/"), ":method"), True,
        c.router, c.reqs, c.sent,
    ))
    _assert_rst_only(c.out(), 9, PROTOCOL_ERROR)
    assert_equal(c.h2.find_stream_idx(UInt32(9)), -1)


def test_header_name_predicates() raises:
    """The two name checks at their edges: an empty name is not valid; a
    pseudo-header is; 'A' and 'Z' are uppercase and '@' and '[' (their
    neighbours) are not. Each RFC 9113 §8.2.2 connection-specific name is
    caught; `te` and `content-type` are not."""
    assert_false(_is_lowercase_or_pseudo(""))
    assert_true(_is_lowercase_or_pseudo(":path"))
    assert_true(_is_lowercase_or_pseudo("x-test"))
    assert_false(_is_lowercase_or_pseudo("xA"))
    assert_false(_is_lowercase_or_pseudo("xZ"))
    assert_true(_is_lowercase_or_pseudo("x@"))
    assert_true(_is_lowercase_or_pseudo("x["))
    var bad: List[String] = [
        "connection", "proxy-connection", "keep-alive", "transfer-encoding",
        "upgrade",
    ]
    for i in range(len(bad)):
        assert_true(_is_connection_specific_header(bad[i]), bad[i])
    assert_false(_is_connection_specific_header("te"))
    assert_false(_is_connection_specific_header("content-type"))


def test_parse_int_digit_edges() raises:
    """'/' and ':' (the neighbours of '0' and '9') are not digits."""
    assert_false(_parse_int_safe("1/")[0])
    assert_false(_parse_int_safe("1:")[0])
    var r = _parse_int_safe("0909")
    assert_true(r[0])
    assert_equal(r[1], 909)


# -----------------------------------------------------------------------------
# D. Requests with a body.
# -----------------------------------------------------------------------------


def _post(len_value: String) -> List[HpackHeader]:
    var hs = _common("POST", "/up")
    hs.append(_h("content-length", len_value))
    return hs^


def test_body_request_is_answered_after_its_body() raises:
    """A POST declaring a 4-byte body: nothing until the DATA with
    END_STREAM, then the router's answer."""
    var c = _Client()
    c.router.add(HttpMethod.post(), "/up", 2)
    assert_true(c.send(c.request(1, _post("4"), False)))
    assert_equal(len(c.out()), 0)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_true(c.h2.streams[idx].has_pending_request)
    assert_equal(Int(c.h2.streams[idx].expected_content_length), 4)
    assert_equal(c.h2.find_pending_request_idx(UInt32(1)), 0)
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _bytes("test"))))
    _assert_answered(c.out(), 1, "200", "Hello from HTTP/2!")
    assert_equal(c.h2.find_pending_request_idx(UInt32(1)), -1)
    assert_false(c.h2.streams[idx].has_pending_request)


def test_body_length_mismatch_single_frame() raises:
    """h2spec http2/8.1.2.6/1."""
    var c = _Client()
    c.router.add(HttpMethod.post(), "/up", 2)
    assert_true(c.send(c.request(1, _post("1"), False)))
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _bytes("test"))))
    _assert_rst_only(c.out(), 1, PROTOCOL_ERROR)
    var idx = c.h2.find_stream_idx(UInt32(1))
    assert_equal(Int(c.h2.streams[idx].state), Int(STREAM_STATE_CLOSED))
    assert_false(c.h2.streams[idx].has_pending_request)
    assert_equal(c.h2.find_pending_request_idx(UInt32(1)), -1)
    assert_equal(Int(c.reqs), 0)


def test_body_length_mismatch_two_frames() raises:
    """h2spec http2/8.1.2.6/2."""
    var c = _Client()
    c.router.add(HttpMethod.post(), "/up", 2)
    assert_true(c.send(c.request(1, _post("1"), False)))
    assert_true(c.send(_raw(FRAME_DATA, UInt8(0), 1, _bytes("test"))))
    assert_equal(len(c.out()), 0)
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _bytes("test"))))
    _assert_rst_only(c.out(), 1, PROTOCOL_ERROR)


def test_length_with_end_stream_is_answered_at_once() raises:
    var c = _Client()
    c.router.add(HttpMethod.post(), "/up", 2)
    assert_true(c.send(c.request(1, _post("0"), True)))
    _assert_answered(c.out(), 1, "200", "Hello from HTTP/2!")
    assert_equal(c.h2.find_pending_request_idx(UInt32(1)), -1)


# -----------------------------------------------------------------------------
# R. gRPC.
# -----------------------------------------------------------------------------


def _grpc(path: String, timeout: String = "") -> List[HpackHeader]:
    var hs = _common("POST", path)
    hs.append(_h("content-type", GRPC_CT))
    hs.append(_h("te", "trailers"))
    if timeout.byte_length() > 0:
        hs.append(_h("grpc-timeout", timeout))
    return hs^


def _msg() -> List[UInt8]:
    """One gRPC envelope: uncompressed, length 2, payload AA BB."""
    var m: List[UInt8] = [UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(2), UInt8(0xAA), UInt8(0xBB)]
    return m^


def _assert_trailers_only(outs: List[_Out], sid: Int, status: String, grpc_status: String, message: String) raises:
    assert_equal(len(outs), 1, "one trailers-only HEADERS")
    assert_equal(Int(outs[0].kind), Int(FRAME_HEADERS))
    assert_equal(Int(outs[0].sid), sid)
    assert_equal(Int(outs[0].flags), Int(FLAG_END_HEADERS | FLAG_END_STREAM))
    assert_equal(_hval(outs[0].headers, ":status"), status)
    assert_equal(_hval(outs[0].headers, "grpc-status"), grpc_status)
    assert_equal(_hval(outs[0].headers, "grpc-message"), message)


def _assert_grpc_ok(outs: List[_Out], sid: Int, n_data: Int) raises:
    """HEADERS (200, no END_STREAM), `n_data` DATA frames each the echoed
    envelope, then the grpc-status 0 trailer with END_STREAM."""
    assert_equal(len(outs), n_data + 2)
    assert_equal(_hval(outs[0].headers, ":status"), "200")
    assert_equal(_hval(outs[0].headers, "content-type"), GRPC_CT)
    assert_equal(Int(outs[0].flags), Int(FLAG_END_HEADERS))
    var m = _msg()
    for k in range(n_data):
        ref d = outs[1 + k]
        assert_equal(Int(d.kind), Int(FRAME_DATA))
        assert_equal(Int(d.sid), sid)
        assert_equal(Int(d.flags), 0)
        assert_equal(len(d.payload), len(m))
        for i in range(len(m)):
            assert_equal(Int(d.payload[i]), Int(m[i]))
    ref t = outs[n_data + 1]
    assert_equal(Int(t.kind), Int(FRAME_HEADERS))
    assert_equal(Int(t.flags), Int(FLAG_END_HEADERS | FLAG_END_STREAM))
    assert_equal(_hval(t.headers, "grpc-status"), "0")


def test_grpc_unary_waits_for_its_body() raises:
    """A gRPC HEADERS without END_STREAM and with no declared length is
    held; the DATA's body reaches the service, whose answer is the
    response."""
    var c = _Client()
    assert_true(c.send(c.request(1, _grpc("/svc.S/Echo"), False)))
    assert_equal(len(c.out()), 0)
    assert_equal(c.rpc.unary_calls, 0)
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _msg())))
    _assert_grpc_ok(c.out(), 1, 1)
    assert_equal(c.rpc.unary_calls, 1)
    assert_equal(c.rpc.last_path, "/svc.S/Echo")
    assert_equal(len(c.rpc.last_body), len(_msg()))
    assert_equal(Int(c.reqs), 1)


def test_grpc_with_matching_length() raises:
    var c = _Client()
    var hs = _grpc("/svc.S/Echo")
    hs.append(_h("content-length", "7"))
    assert_true(c.send(c.request(1, hs^, False)))
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _msg())))
    _assert_grpc_ok(c.out(), 1, 1)


def test_grpc_headers_only_call_has_an_empty_body() raises:
    var c = _Client()
    assert_true(c.send(c.request(1, _grpc("/svc.S/Echo"), True)))
    var outs = c.out()
    assert_equal(c.rpc.unary_calls, 1)
    assert_equal(len(c.rpc.last_body), 0)
    assert_equal(len(outs), 2, "HEADERS and the trailer: an empty echo has no DATA")
    assert_equal(Int(outs[1].kind), Int(FRAME_HEADERS))
    assert_equal(_hval(outs[1].headers, "grpc-status"), "0")


def test_grpc_malformed_timeout_skips_the_handler() raises:
    """grpc-go TestDecodeTimeout's "1234x": 400, grpc-status 13."""
    var c = _Client()
    assert_true(c.send(c.request(1, _grpc("/svc.S/Echo", "1234x"), False)))
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _msg())))
    var outs = c.out()
    assert_equal(len(outs), 1)
    assert_equal(_hval(outs[0].headers, ":status"), "400")
    assert_equal(_hval(outs[0].headers, "grpc-status"), "13")
    assert_equal(c.rpc.unary_calls, 0)


def test_grpc_zero_timeout_expires_before_the_handler() raises:
    """grpc-go's "0S" is valid and already expired; on the headers-only path
    too."""
    var c = _Client()
    assert_true(c.send(c.request(1, _grpc("/svc.S/Echo", "0S"), True)))
    _assert_trailers_only(c.out(), 1, "200", "4", "context deadline exceeded")
    assert_equal(c.rpc.unary_calls, 0)


def test_grpc_unary_overrun_is_deadline_exceeded() raises:
    """grpc-go's "10u": a handler costing 10 us has overrun (expiry is at
    now >= deadline); one costing 9 us has not."""
    var c = _Client()
    c.rpc.cost_ns = 10 * US
    assert_true(c.send(c.request(1, _grpc("/svc.S/Echo", "10u"), True)))
    _assert_trailers_only(c.out(), 1, "200", "4", "context deadline exceeded")
    assert_equal(c.rpc.unary_calls, 1)
    c.rpc.cost_ns = 9 * US
    assert_true(c.send(c.request(3, _grpc("/svc.S/Echo", "10u"), False)))
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 3, _msg())))
    _assert_grpc_ok(c.out(), 3, 1)


def test_grpc_server_streaming() raises:
    """A streaming method: two DATA frames (one per message) and the
    trailer; with the deadline overrun, DEADLINE_EXCEEDED and no DATA."""
    var c = _Client()
    assert_true(c.send(c.request(1, _grpc(STREAM_PATH), False)))
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _msg())))
    _assert_grpc_ok(c.out(), 1, 2)
    assert_equal(c.rpc.stream_calls, 1)
    assert_equal(c.rpc.unary_calls, 0)
    c.rpc.cost_ns = 10 * US
    assert_true(c.send(c.request(3, _grpc(STREAM_PATH, "10u"), True)))
    _assert_trailers_only(c.out(), 3, "200", "4", "context deadline exceeded")
    assert_equal(c.rpc.stream_calls, 2)


def test_grpc_body_mismatch_is_reset_without_the_handler() raises:
    """h2spec http2/8.1.2.6/1's lengths on a gRPC call."""
    var c = _Client()
    var hs = _grpc("/svc.S/Echo")
    hs.append(_h("content-length", "1"))
    assert_true(c.send(c.request(1, hs^, False)))
    assert_true(c.send(_raw(FRAME_DATA, FLAG_END_STREAM, 1, _bytes("test"))))
    _assert_rst_only(c.out(), 1, PROTOCOL_ERROR)
    assert_equal(c.rpc.unary_calls, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
