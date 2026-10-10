# =============================================================================
# test_grpc_timeout_enforced.mojo: the h2 serve loop enforces grpc-timeout
# =============================================================================
#
# Spec: grpc/doc/PROTOCOL-HTTP2.md, `Timeout -> "grpc-timeout" TimeoutValue
# TimeoutUnit`. Wire behaviour follows grpc-go's server transport
# (internal/transport/http2_server.go, operateHeaders): a malformed value is
# answered `:status 400`, `grpc-status 13`, `grpc-message: malformed
# grpc-timeout: ...`; an expired deadline `grpc-status 4`,
# `grpc-message: context deadline exceeded`.
#
# Drives the serve loop's frame dispatcher
# (`komira_http_server.serve_h2._dispatch_h2_frames`) with raw h2 frames,
# each leg on its own connection. Time is a manual clock: `_ClockedEcho` overrides
# `GrpcDispatch.grpc_now_ns` and its handler advances the clock by
# `cost_ns`, so "a handler slower than the deadline" is exact arithmetic,
# never a wall-clock sleep. The last leg uses the real `ConnectService` and
# the default clock, with deadlines (0S, 1H) whose outcome does not depend on
# how fast the machine is.
#
# Legs (what each would catch):
#   T1  no grpc-timeout, handler costs an hour: answered OK. Catches a
#       server that invents a deadline when the header is absent.
#   T2  100m, handler costs 99ms: OK, echoed body. Catches a deadline check
#       with the wrong unit or an off-by-one that expires early.
#   T3  100m, handler costs exactly 100ms: DEADLINE_EXCEEDED, the handler ran
#       once, no DATA. Catches an unenforced deadline (the defect) and a
#       `>` where grpc-go's expiry is `now >= deadline`.
#   T4  0S: DEADLINE_EXCEEDED, the handler does not run. Catches a zero
#       read as "no deadline".
#   T5  malformed values: 400 / 13 / exact reason, handler not run. Catches
#       a malformed value treated as absent (an unbounded call). Two fields
#       ["7x", "5S"]: still 400 / 13, as in grpc-go, where a malformed field
#       sets an error a later valid field does not clear. Catches last-wins.
#   T6  HEADERS with 100m at t0, body arrives 150ms later: DEADLINE_EXCEEDED,
#       handler not run. Catches a deadline computed at dispatch instead of
#       at arrival.
#   T7  server-streaming method slower than its deadline: DEADLINE_EXCEEDED,
#       no DATA. Catches enforcement on the unary path only.
#   T8  gRPC-Web with 0S: not enforced (handler runs). Pins the scope.
#   T9  ConnectService, default clock: 0S -> DEADLINE_EXCEEDED without the
#       handler; 1H -> OK; and `grpc_now_ns()` read between two
#       `komira_clock.now_ns()` readings lies between them. Catches a default
#       clock that is constant or in the wrong unit (production would then
#       never time out a slow call).
#   T10 HEADERS with END_STREAM and no DATA (dispatched at once, not deferred
#       for a body): 0S -> DEADLINE_EXCEEDED, handler not run; "1s" -> 400 /
#       13; a client-streaming handler slower than 1S -> DEADLINE_EXCEEDED;
#       no header -> OK. Catches the immediate-dispatch path dropping the
#       deadline.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_RST_STREAM,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
)
from komira_http_core.codec.h2.hpack import (
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
)
from komira_clock import now_ns
from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
)
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import _dispatch_h2_frames

from komira_connect import ConnectService, grpc_encode_unary


comptime UNARY_PATH = "/test.Svc/Echo"
comptime STREAM_PATH = "/test.Svc/Stream"
comptime CLIENT_STREAM_PATH = "/test.Svc/Upload"
comptime MS: UInt64 = 1_000_000
comptime GRPC_CT = "application/grpc+proto"
comptime DEADLINE_MSG = "context deadline exceeded"


struct _ClockedEcho(GrpcDispatch, GrpcStreamDispatch):
    """An echo service on a manual clock; each handler call costs
    `cost_ns`."""

    var now: UInt64
    var cost_ns: UInt64
    var unary_calls: Int
    var stream_calls: Int

    def __init__(out self):
        self.now = UInt64(5_000) * MS
        self.cost_ns = UInt64(0)
        self.unary_calls = 0
        self.stream_calls = 0

    def grpc_now_ns(self) -> UInt64:
        return self.now

    def dispatch_grpc(
        mut self,
        path: String,
        content_type: String,
        request_body: List[UInt8],
    ) -> GrpcResponse:
        self.unary_calls += 1
        self.now += self.cost_ns
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
        var msgs = List[List[UInt8]]()
        msgs.append(request_body.copy())
        return GrpcStreamResponse(
            msgs^, UInt16(200), UInt8(0), String(""), String(GRPC_CT)
        )

    def grpc_stream_kind(self, path: String) -> UInt8:
        if path == STREAM_PATH:
            return GRPC_KIND_SERVER_STREAM
        if path == CLIENT_STREAM_PATH:
            return GRPC_KIND_CLIENT_STREAM
        return GRPC_KIND_UNARY


struct _Answer(Movable):
    """What the server wrote back on one stream."""

    var status: String
    var content_type: String
    var grpc_status: String
    var grpc_message: String
    var data: List[UInt8]
    var headers_frames: Int
    var data_frames: Int
    var closed: Bool
    var saw_reset_or_goaway: Bool

    def __init__(out self):
        self.status = String("<absent>")
        self.content_type = String("<absent>")
        self.grpc_status = String("<absent>")
        self.grpc_message = String("<absent>")
        self.data = List[UInt8]()
        self.headers_frames = 0
        self.data_frames = 0
        self.closed = False
        self.saw_reset_or_goaway = False


def _value(headers: List[HpackHeader], name: String) -> String:
    for i in range(len(headers)):
        if String(headers[i].name) == name:
            return String(headers[i].value)
    return String("<absent>")


def _msg() -> List[UInt8]:
    var m: List[UInt8] = [UInt8(0xAA), UInt8(0xBB)]
    return grpc_encode_unary(Span(m))


struct _Conn[G: GrpcDispatch & GrpcStreamDispatch](Movable):
    """One server connection, the client's HPACK encoder and decoder."""

    var h2: H2ConnectionState
    var router: Router
    var svc: Self.G
    var enc: HpackEncoder
    var dec: HpackDecoder
    var reqs: Int64
    var sent: Int64
    var next_sid: UInt32

    def __init__(out self, var svc: Self.G):
        self.h2 = H2ConnectionState()
        self.router = Router()
        self.svc = svc^
        self.enc = HpackEncoder()
        self.dec = HpackDecoder()
        self.reqs = Int64(0)
        self.sent = Int64(0)
        self.next_sid = UInt32(1)

    def _block(
        mut self, path: String, ct: String, timeout: Optional[String]
    ) -> List[UInt8]:
        var ts = List[String]()
        if timeout:
            ts.append(timeout.value())
        return self._block_fields(path, ct, ts)

    def _block_fields(
        mut self, path: String, ct: String, timeouts: List[String]
    ) -> List[UInt8]:
        """A request header block with one grpc-timeout field per entry of
        `timeouts`, in order."""
        var hs = List[HpackHeader]()
        hs.append(HpackHeader(String(":method"), String("POST")))
        hs.append(HpackHeader(String(":scheme"), String("https")))
        hs.append(HpackHeader(String(":path"), path))
        hs.append(HpackHeader(String(":authority"), String("localhost")))
        hs.append(HpackHeader(String("content-type"), ct))
        hs.append(HpackHeader(String("te"), String("trailers")))
        for i in range(len(timeouts)):
            hs.append(HpackHeader(String("grpc-timeout"), timeouts[i]))
        return self.enc.encode_block(hs^)

    def _pump(mut self) raises:
        var alive = _dispatch_h2_frames(
            self.h2, self.router, self.svc, self.reqs, self.sent
        )
        assert_true(alive, "the connection stays open")

    def send_headers(
        mut self, path: String, ct: String, timeout: Optional[String]
    ) raises -> UInt32:
        """HEADERS without END_STREAM: the body follows in `send_body`."""
        var sid = self.next_sid
        self.next_sid += 2
        var wire = List[UInt8]()
        encode_headers_frame(sid, self._block(path, ct, timeout), False, True, wire)
        self.h2.append_recv_bytes(Span(wire))
        self._pump()
        return sid

    def call_fields(
        mut self, path: String, ct: String, timeouts: List[String]
    ) raises -> _Answer:
        """HEADERS (one grpc-timeout field per entry) then the body."""
        var sid = self.next_sid
        self.next_sid += 2
        var wire = List[UInt8]()
        encode_headers_frame(
            sid, self._block_fields(path, ct, timeouts), False, True, wire
        )
        self.h2.append_recv_bytes(Span(wire))
        self._pump()
        return self.send_body(sid)

    def call_headers_only(
        mut self, path: String, ct: String, timeout: Optional[String]
    ) raises -> _Answer:
        """HEADERS with END_STREAM and no DATA: the serve loop dispatches the
        call with an empty body as soon as the block completes."""
        var sid = self.next_sid
        self.next_sid += 2
        var wire = List[UInt8]()
        encode_headers_frame(sid, self._block(path, ct, timeout), True, True, wire)
        self.h2.append_recv_bytes(Span(wire))
        self._pump()
        return self._read(sid)

    def send_body(mut self, sid: UInt32) raises -> _Answer:
        var wire = List[UInt8]()
        encode_data_frame(sid, _msg(), True, wire)
        self.h2.append_recv_bytes(Span(wire))
        self._pump()
        return self._read(sid)

    def call(
        mut self, path: String, ct: String, timeout: Optional[String]
    ) raises -> _Answer:
        var sid = self.send_headers(path, ct, timeout)
        return self.send_body(sid)

    def _read(mut self, sid: UInt32) raises -> _Answer:
        var out = self.h2.take_out_bytes()
        var ans = _Answer()
        var cursor = 0
        while cursor < len(out):
            var res = decode_frame(Span(out)[cursor:], 16384)
            assert_equal(Int(res.status), 0, "response frame decodes")
            cursor += res.consumed
            ref f = res.frame
            if f.header.kind == FRAME_GOAWAY or f.header.kind == FRAME_RST_STREAM:
                ans.saw_reset_or_goaway = True
                continue
            if f.header.stream_id != sid:
                continue
            if (f.header.flags & FLAG_END_STREAM) != 0:
                ans.closed = True
            if f.header.kind == FRAME_HEADERS:
                ans.headers_frames += 1
                var hs = self.dec.decode_block(Span(f.payload))
                var st = _value(hs, String(":status"))
                if st != String("<absent>"):
                    ans.status = st
                var ct = _value(hs, String("content-type"))
                if ct != String("<absent>"):
                    ans.content_type = ct
                var gs = _value(hs, String("grpc-status"))
                if gs != String("<absent>"):
                    ans.grpc_status = gs
                var gm = _value(hs, String("grpc-message"))
                if gm != String("<absent>"):
                    ans.grpc_message = gm
            elif f.header.kind == FRAME_DATA:
                ans.data_frames += 1
                for i in range(len(f.payload)):
                    ans.data.append(f.payload[i])
        return ans^


def _assert_ok(a: _Answer, what: String) raises:
    assert_false(a.saw_reset_or_goaway, what + ": no RST_STREAM / GOAWAY")
    assert_equal(a.status, String("200"), what + ": :status")
    assert_equal(a.grpc_status, String("0"), what + ": grpc-status")
    assert_equal(a.grpc_message, String("<absent>"), what + ": grpc-message")
    var m = _msg()
    assert_equal(len(a.data), len(m), what + ": echoed body length")
    for i in range(len(m)):
        assert_equal(a.data[i], m[i], what + ": echoed body byte")
    assert_true(a.closed, what + ": stream closed")


def _assert_deadline_exceeded(a: _Answer, what: String) raises:
    assert_false(a.saw_reset_or_goaway, what + ": no RST_STREAM / GOAWAY")
    assert_equal(a.status, String("200"), what + ": :status")
    assert_equal(a.content_type, String(GRPC_CT), what + ": content-type")
    assert_equal(a.grpc_status, String("4"), what + ": grpc-status")
    assert_equal(a.grpc_message, String(DEADLINE_MSG), what + ": grpc-message")
    assert_equal(a.data_frames, 0, what + ": no DATA (handler output dropped)")
    assert_equal(a.headers_frames, 1, what + ": one trailers-only HEADERS")
    assert_true(a.closed, what + ": END_STREAM")


def _assert_malformed(a: _Answer, reason: String, what: String) raises:
    assert_false(a.saw_reset_or_goaway, what + ": no RST_STREAM / GOAWAY")
    assert_equal(a.status, String("400"), what + ": :status")
    assert_equal(a.grpc_status, String("13"), what + ": grpc-status")
    assert_equal(
        a.grpc_message,
        String("malformed grpc-timeout: ") + reason,
        what + ": grpc-message",
    )
    assert_equal(a.data_frames, 0, what + ": no DATA")
    assert_equal(a.headers_frames, 1, what + ": one trailers-only HEADERS")
    assert_true(a.closed, what + ": END_STREAM")


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    return req_body.copy()


def _clocked() -> _Conn[_ClockedEcho]:
    return _Conn[_ClockedEcho](_ClockedEcho())


def test_t1_no_header_no_deadline() raises:
    var c = _clocked()
    c.svc.cost_ns = UInt64(3_600_000) * MS
    _assert_ok(c.call(UNARY_PATH, GRPC_CT, None), "T1")
    assert_equal(c.svc.unary_calls, 1, "T1 handler ran")


def test_t2_fast_handler_succeeds() raises:
    var c = _clocked()
    c.svc.cost_ns = UInt64(99) * MS
    _assert_ok(c.call(UNARY_PATH, GRPC_CT, String("100m")), "T2")
    assert_equal(c.svc.unary_calls, 1, "T2 handler ran")


def test_t3_slow_handler_deadline_exceeded() raises:
    var c = _clocked()
    c.svc.cost_ns = UInt64(100) * MS
    _assert_deadline_exceeded(c.call(UNARY_PATH, GRPC_CT, String("100m")), "T3")
    assert_equal(c.svc.unary_calls, 1, "T3 handler ran to completion once")


def test_t4_zero_expired_on_arrival() raises:
    var c = _clocked()
    _assert_deadline_exceeded(c.call(UNARY_PATH, GRPC_CT, String("0S")), "T4")
    assert_equal(c.svc.unary_calls, 0, "T4 handler not run")


def test_t5_malformed() raises:
    var c = _clocked()
    _assert_malformed(
        c.call(UNARY_PATH, GRPC_CT, String("123456789S")),
        String("timeout string is too long"),
        "T5 nine digits",
    )
    _assert_malformed(
        c.call(UNARY_PATH, GRPC_CT, String("1s")),
        String("timeout unit is not recognized"),
        "T5 lowercase s",
    )
    _assert_malformed(
        c.call(UNARY_PATH, GRPC_CT, String("S")),
        String("timeout string is too short"),
        "T5 unit only",
    )
    _assert_malformed(
        c.call(UNARY_PATH, GRPC_CT, String("-1S")),
        String("timeout value is not a decimal number"),
        "T5 negative",
    )
    _assert_malformed(
        c.call_fields(UNARY_PATH, GRPC_CT, [String("7x"), String("5S")]),
        String("timeout unit is not recognized"),
        "T5 malformed field then a valid one",
    )
    assert_equal(c.svc.unary_calls, 0, "T5 handler not run")


def test_t6_deadline_runs_from_headers() raises:
    var c = _clocked()
    var sid = c.send_headers(UNARY_PATH, GRPC_CT, String("100m"))
    c.svc.now += UInt64(150) * MS
    _assert_deadline_exceeded(c.send_body(sid), "T6")
    assert_equal(c.svc.unary_calls, 0, "T6 handler not run")
    var sid_ok = c.send_headers(UNARY_PATH, GRPC_CT, String("100m"))
    c.svc.now += UInt64(60) * MS
    _assert_ok(c.send_body(sid_ok), "T6 body within the deadline")
    assert_equal(c.svc.unary_calls, 1, "T6 handler ran")


def test_t7_server_streaming() raises:
    var c = _clocked()
    c.svc.cost_ns = UInt64(2_000) * MS
    _assert_deadline_exceeded(c.call(STREAM_PATH, GRPC_CT, String("1S")), "T7")
    assert_equal(c.svc.stream_calls, 1, "T7 stream handler ran once")
    c.svc.cost_ns = UInt64(999) * MS
    _assert_ok(c.call(STREAM_PATH, GRPC_CT, String("1S")), "T7 in time")
    assert_equal(c.svc.stream_calls, 2, "T7 stream handler ran again")


def test_t8_grpc_web_not_enforced() raises:
    var c = _clocked()
    var w = c.call(UNARY_PATH, String("application/grpc-web+proto"), String("0S"))
    assert_equal(w.grpc_status, String("0"), "T8 grpc-status")
    assert_equal(c.svc.unary_calls, 1, "T8 handler ran")


def test_t9_connect_service_default_clock() raises:
    var svc = ConnectService(String("test.Svc"))
    svc.register_method(String(UNARY_PATH), _echo_handler)
    var cs = _Conn[ConnectService](svc^)
    _assert_deadline_exceeded(cs.call(UNARY_PATH, GRPC_CT, String("0S")), "T9 0S")
    _assert_ok(cs.call(UNARY_PATH, GRPC_CT, String("1H")), "T9 1H")
    _assert_ok(cs.call(UNARY_PATH, GRPC_CT, None), "T9 no header")
    var t0 = now_ns()
    var x = cs.svc.grpc_now_ns()
    var t1 = now_ns()
    assert_true(
        t0 <= x and x <= t1,
        String("T9 default clock is komira_clock.now_ns: ")
        + String(t0) + " <= " + String(x) + " <= " + String(t1),
    )


def test_t10_headers_end_stream() raises:
    var c = _clocked()
    _assert_deadline_exceeded(
        c.call_headers_only(UNARY_PATH, GRPC_CT, String("0S")), "T10 0S"
    )
    assert_equal(c.svc.unary_calls, 0, "T10 0S handler not run")
    _assert_malformed(
        c.call_headers_only(UNARY_PATH, GRPC_CT, String("1s")),
        String("timeout unit is not recognized"),
        "T10 malformed",
    )
    assert_equal(c.svc.unary_calls, 0, "T10 malformed handler not run")
    c.svc.cost_ns = UInt64(2_000) * MS
    _assert_deadline_exceeded(
        c.call_headers_only(CLIENT_STREAM_PATH, GRPC_CT, String("1S")),
        "T10 slow client stream",
    )
    assert_equal(c.svc.stream_calls, 1, "T10 client-stream handler ran once")
    var ok = c.call_headers_only(CLIENT_STREAM_PATH, GRPC_CT, None)
    assert_false(ok.saw_reset_or_goaway, "T10 no header: no RST / GOAWAY")
    assert_equal(ok.status, String("200"), "T10 no header: :status")
    assert_equal(ok.grpc_status, String("0"), "T10 no header: grpc-status")
    assert_true(ok.closed, "T10 no header: stream closed")
    assert_equal(c.svc.stream_calls, 2, "T10 no header: handler ran")


def main() raises:
    # Every leg runs, each on its own connection, so one run reports every
    # failing leg; any failure fails the target.
    var failed = List[String]()
    try:
        test_t1_no_header_no_deadline()
    except e:
        failed.append(String("T1 -- ") + String(e))
    try:
        test_t2_fast_handler_succeeds()
    except e:
        failed.append(String("T2 -- ") + String(e))
    try:
        test_t3_slow_handler_deadline_exceeded()
    except e:
        failed.append(String("T3 -- ") + String(e))
    try:
        test_t4_zero_expired_on_arrival()
    except e:
        failed.append(String("T4 -- ") + String(e))
    try:
        test_t5_malformed()
    except e:
        failed.append(String("T5 -- ") + String(e))
    try:
        test_t6_deadline_runs_from_headers()
    except e:
        failed.append(String("T6 -- ") + String(e))
    try:
        test_t7_server_streaming()
    except e:
        failed.append(String("T7 -- ") + String(e))
    try:
        test_t8_grpc_web_not_enforced()
    except e:
        failed.append(String("T8 -- ") + String(e))
    try:
        test_t9_connect_service_default_clock()
    except e:
        failed.append(String("T9 -- ") + String(e))
    try:
        test_t10_headers_end_stream()
    except e:
        failed.append(String("T10 -- ") + String(e))
    for i in range(len(failed)):
        print("FAILED " + failed[i])
    if len(failed) > 0:
        raise Error(String(len(failed)) + " of 10 legs failed")
    print("test_grpc_timeout_enforced: PASSED (10 legs)")
