# =============================================================================
# test_cov_h2_guards.mojo: the h2 serve loop's refusals that ordinary peer
# traffic does not reach
# =============================================================================
#
# Two kinds of guard:
#   * a helper's contract checked by calling it directly: the connection-only
#     charge refusing an overrun, the decode-error scoping refusing a fault
#     that is not one of the two stream errors, the request-header check
#     refusing a non-numeric content-length;
#   * the frame dispatcher acting on such a refusal. The server tops the
#     connection receive window back up at half the initial window, so a
#     frame within the advertised frame size cannot overrun it through the
#     wire alone; these tests set the window low first, which is the state a
#     connection with that much DATA still uncredited would be in.
#
# Groups (and the defect each would catch):
#   F  flow: an overrun on a closed or reset stream not refused, refused
#      without a GOAWAY(FLOW_CONTROL_ERROR), or the connection kept.
#   S  decode-error scope: a connection fault on a stream answered with a
#      RST_STREAM (the connection kept) instead of a GOAWAY.
#   H  headers: a non-numeric content-length accepted as a length.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_RST_STREAM,
    decode_frame,
    encode_frame_header,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import _dispatch_h2_frames
from komira_http_server.serve_h2_flow import (
    _answer_stream_decode_error,
    _charge_connection_only,
    _reset_stream,
)
from komira_http_server.serve_h2_headers import _validate_h2_request_headers


comptime PROTOCOL_ERROR: UInt32 = 0x1
comptime FLOW_CONTROL_ERROR: UInt32 = 0x3
comptime STREAM_CLOSED: UInt32 = 0x5
comptime FRAME_SIZE_ERROR: UInt32 = 0x6
comptime CANCEL: UInt32 = 0x8


@fieldwise_init
struct _Frame(Copyable, Movable):
    var kind: UInt8
    var sid: UInt32
    var code: UInt32


def _frames(bytes: List[UInt8]) raises -> List[_Frame]:
    """Every queued frame's type, stream and error code (RST_STREAM and
    GOAWAY; 0 for the rest)."""
    var out = List[_Frame]()
    var cursor = 0
    while cursor < len(bytes):
        var res = decode_frame(Span(bytes)[cursor:], 1 << 24)
        assert_equal(Int(res.status), 0, "a queued frame does not decode")
        cursor += res.consumed
        ref f = res.frame
        var code = UInt32(0)
        if f.header.kind == FRAME_RST_STREAM:
            code = f.rst_error_code
        if f.header.kind == FRAME_GOAWAY:
            code = f.goaway_error_code
        out.append(_Frame(f.header.kind, f.header.stream_id, code))
    return out^


def _raw(kind: UInt8, flags: UInt8, sid: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    encode_frame_header(UInt32(len(payload)), kind, flags, UInt32(sid), out)
    for i in range(len(payload)):
        out.append(payload[i])
    return out^


def _data(sid: Int, n: Int) -> List[UInt8]:
    return _raw(FRAME_DATA, UInt8(0), sid, List[UInt8](length=n, fill=UInt8(0x61)))


struct _Conn(Movable):
    var h2: H2ConnectionState
    var router: Router
    var grpc: NoopGrpcDispatch
    var enc: HpackEncoder
    var reqs: Int64
    var sent: Int64

    def __init__(out self) raises:
        self.h2 = H2ConnectionState()
        self.h2.mark_preface_ok()
        self.router = Router()
        self.router.add(HttpMethod.get(), "/", 1)
        self.grpc = NoopGrpcDispatch()
        self.enc = HpackEncoder()
        self.reqs = Int64(0)
        self.sent = Int64(0)

    def send(mut self, bytes: List[UInt8]) -> Bool:
        self.h2.append_recv_bytes(Span(bytes))
        return _dispatch_h2_frames(
            self.h2, self.router, self.grpc, self.reqs, self.sent
        )

    def get(mut self, sid: Int, end_stream: Bool) -> List[UInt8]:
        var hs = List[HpackHeader]()
        hs.append(HpackHeader(String(":method"), String("GET")))
        hs.append(HpackHeader(String(":scheme"), String("https")))
        hs.append(HpackHeader(String(":path"), String("/")))
        hs.append(HpackHeader(String(":authority"), String("example.com")))
        var flags = FLAG_END_HEADERS
        if end_stream:
            flags = flags | FLAG_END_STREAM
        return _raw(FRAME_HEADERS, flags, sid, self.enc.encode_block(hs^))

    def out(mut self) raises -> List[_Frame]:
        return _frames(self.h2.take_out_bytes())


def _assert_goaway(f: _Frame, code: UInt32) raises:
    assert_equal(Int(f.kind), Int(FRAME_GOAWAY))
    assert_equal(Int(f.sid), 0)
    assert_equal(Int(f.code), Int(code))


# -----------------------------------------------------------------------------
# F: flow.
# -----------------------------------------------------------------------------


def test_connection_only_charge_refuses_an_overrun() raises:
    """Within the window the octets are charged; one octet past it is a
    connection FLOW_CONTROL_ERROR and the window is left as it was."""
    var h2 = H2ConnectionState()
    h2.recv_fc.conn_recv_window = Int32(10)
    assert_false(_charge_connection_only(h2, 11))
    assert_equal(Int(h2.recv_fc.conn_recv_window), 10)
    var outs = _frames(h2.take_out_bytes())
    assert_equal(len(outs), 1)
    _assert_goaway(outs[0], FLOW_CONTROL_ERROR)
    var h2b = H2ConnectionState()
    h2b.recv_fc.conn_recv_window = Int32(10)
    assert_true(_charge_connection_only(h2b, 10))
    assert_false(h2b.is_goaway_sent())


def test_data_on_a_reset_stream_past_the_window_closes() raises:
    """The server reset stream 1; the peer's in-flight DATA is ignored but
    charged to the connection, and 5 octets against a window of 4 close the
    connection with GOAWAY(FLOW_CONTROL_ERROR) and nothing else."""
    var c = _Conn()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    _reset_stream(c.h2, UInt32(1), CANCEL)
    var rst = c.out()
    assert_equal(len(rst), 1)
    assert_equal(Int(rst[0].kind), Int(FRAME_RST_STREAM))
    c.h2.recv_fc.conn_recv_window = Int32(4)
    assert_false(c.send(_data(1, 5)))
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_goaway(outs[0], FLOW_CONTROL_ERROR)


def test_data_on_a_reset_stream_within_the_window_is_ignored() raises:
    var c = _Conn()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    _reset_stream(c.h2, UInt32(1), CANCEL)
    _ = c.out()
    c.h2.recv_fc.conn_recv_window = Int32(5)
    assert_true(c.send(_data(1, 5)))
    assert_false(c.h2.is_goaway_sent())


def test_data_on_a_closed_stream_past_the_window_closes() raises:
    """Stream 1 is half-closed (remote): DATA on it is answered
    RST_STREAM(STREAM_CLOSED), and its octets, past the connection window,
    then close the connection with GOAWAY(FLOW_CONTROL_ERROR) behind it."""
    var c = _Conn()
    assert_true(c.send(c.get(1, True)))
    _ = c.out()
    c.h2.recv_fc.conn_recv_window = Int32(4)
    assert_false(c.send(_data(1, 5)))
    var outs = c.out()
    assert_equal(len(outs), 2)
    assert_equal(Int(outs[0].kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(outs[0].sid), 1)
    assert_equal(Int(outs[0].code), Int(STREAM_CLOSED))
    _assert_goaway(outs[1], FLOW_CONTROL_ERROR)


# -----------------------------------------------------------------------------
# S: decode-error scope.
# -----------------------------------------------------------------------------


def test_a_connection_fault_on_a_stream_is_a_goaway() raises:
    """Only a PRIORITY FRAME_SIZE_ERROR and a WINDOW_UPDATE PROTOCOL_ERROR
    are stream errors. Any other fault scoped to an open stream closes the
    connection with the decoder's code, and the stream is not reset."""
    var c = _Conn()
    assert_true(c.send(c.get(1, False)))
    _ = c.out()
    assert_false(
        _answer_stream_decode_error(
            c.h2, FRAME_RST_STREAM, UInt32(1), FRAME_SIZE_ERROR
        )
    )
    var outs = c.out()
    assert_equal(len(outs), 1)
    _assert_goaway(outs[0], FRAME_SIZE_ERROR)
    var c2 = _Conn()
    assert_true(c2.send(c2.get(1, False)))
    _ = c2.out()
    assert_false(
        _answer_stream_decode_error(
            c2.h2, FRAME_DATA, UInt32(1), PROTOCOL_ERROR
        )
    )
    var outs2 = c2.out()
    assert_equal(len(outs2), 1)
    _assert_goaway(outs2[0], PROTOCOL_ERROR)


# -----------------------------------------------------------------------------
# H: headers.
# -----------------------------------------------------------------------------


def _request_with_length(value: String) -> List[HpackHeader]:
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String(":method"), String("POST")))
    hs.append(HpackHeader(String(":scheme"), String("https")))
    hs.append(HpackHeader(String(":path"), String("/")))
    hs.append(HpackHeader(String("content-length"), value))
    return hs^


def test_non_numeric_content_length_is_refused() raises:
    """RFC 9113 section 8.1.1: a content-length that is not a number makes the
    request malformed. The same request with "12" is accepted at 12."""
    var bad: List[String] = ["12x", "", "-1", " 12"]
    for v in bad:
        var r = _validate_h2_request_headers(_request_with_length(v))
        assert_false(r.ok, "content-length '" + v + "' accepted")
        assert_false(r.has_content_length)
    var good = _validate_h2_request_headers(_request_with_length(String("12")))
    assert_true(good.ok)
    assert_true(good.has_content_length)
    assert_equal(good.content_length, 12)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
