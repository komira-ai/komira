# =============================================================================
# test_h2_serve_nonascii_content_type.mojo: the h2 serve loop survives a
# non-ASCII request content-type
# =============================================================================
#
# The crash in komira-ai/komira#443: the h2 serve loop calls
# `is_grpc_content_type(content-type)` on every request HEADERS
# (serve_h2.mojo, `_handle_headers_or_continuation` and
# `_dispatch_deferred_request`). The HPACK decoder turns each wire byte into
# one char (`chr(byte)`), so any byte >= 0x80 becomes a two-byte UTF-8
# sequence, and the old `ct[byte=i]` scan asserted on its continuation byte
# and aborted the process (exit 132).
#
# This drives the REAL frame dispatcher of the serve loop
# (`komira_http_server.serve_h2._dispatch_h2_frames`, the function
# `serve_read_round_h2` calls after TLS) with raw h2 frames on ONE
# connection state, a real `Router` and a real `ConnectService`. The HPACK
# blocks are written by hand (literal fields, no Huffman) so the
# content-type carries exactly the wire bytes under test, valid UTF-8 or not.
# The response frames are decoded with the real HPACK decoder.
#
# Spec: RFC 9110 8.3.1, only type/subtype picks the handler; a non-ASCII
# byte in it names no gRPC type, so the request takes the ordinary Router
# path (here no route: 404). A non-ASCII parameter is ignored.
#
# Coverage (one connection, one service, stream ids in order):
#   T1  for each wire suffix {C3 A9 (é), 80, FF, C3 (truncated)}:
#       HEADERS(END_STREAM) POST /test.Svc/Echo,
#       content-type `application/grpc` + suffix. The server answers that
#       stream with `:status 404` and no GOAWAY/RST. On the old code the
#       FIRST of these aborted the process.
#   T2  for each suffix: content-type `application/grpc+proto; charset=` +
#       suffix, HEADERS + DATA(a framed 2-byte message, END_STREAM): gRPC,
#       `:status 200`, the echoed message, trailer `grpc-status: 0`.
#   T3  then a plain `application/grpc+proto` echo on the next stream of the
#       same connection: answered, `grpc-status: 0` (the server survived).
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
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackHeader
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import _dispatch_h2_frames

from komira_connect import ConnectService, grpc_decode_unary, grpc_encode_unary


comptime ECHO_PATH = "/test.Svc/Echo"


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _suffixes() -> List[List[UInt8]]:
    """The wire bytes under test: valid UTF-8 `é`, a lone continuation byte,
    0xFF (never valid UTF-8) and a truncated two-byte lead."""
    var out = List[List[UInt8]]()
    out.append([UInt8(0xC3), UInt8(0xA9)])
    out.append([UInt8(0x80)])
    out.append([UInt8(0xFF)])
    out.append([UInt8(0xC3)])
    return out^


def _literal(mut block: List[UInt8], name: String, value: List[UInt8]):
    """RFC 7541 6.2.2 literal field without indexing, new name, no Huffman
    (both lengths < 127, so one length byte each)."""
    block.append(UInt8(0x00))
    block.append(UInt8(name.byte_length()))
    for b in name.as_bytes():
        block.append(b)
    block.append(UInt8(len(value)))
    for i in range(len(value)):
        block.append(value[i])


def _request_block(content_type: List[UInt8]) -> List[UInt8]:
    var block = List[UInt8]()
    _literal(block, String(":method"), _bytes(String("POST")))
    _literal(block, String(":scheme"), _bytes(String("https")))
    _literal(block, String(":path"), _bytes(String(ECHO_PATH)))
    _literal(block, String(":authority"), _bytes(String("localhost")))
    _literal(block, String("content-type"), content_type)
    _literal(block, String("te"), _bytes(String("trailers")))
    return block^


struct _Answer(Movable):
    """What the server wrote back on one stream."""

    var status: String
    var grpc_status: String
    var data: List[UInt8]
    var saw_reset_or_goaway: Bool

    def __init__(out self):
        self.status = String("<absent>")
        self.grpc_status = String("<absent>")
        self.data = List[UInt8]()
        self.saw_reset_or_goaway = False


def _value(headers: List[HpackHeader], name: String) -> String:
    for i in range(len(headers)):
        if String(headers[i].name) == name:
            return String(headers[i].value)
    return String("<absent>")


struct _Conn(Movable):
    """One server-side h2 connection plus the client's response decoder."""

    var h2: H2ConnectionState
    var router: Router
    var svc: ConnectService
    var dec: HpackDecoder
    var reqs: Int64
    var sent: Int64

    def __init__(out self):
        self.h2 = H2ConnectionState()
        self.router = Router()
        self.svc = ConnectService(String("test.Svc"))
        self.svc.register_method(String(ECHO_PATH), _echo_handler)
        self.dec = HpackDecoder()
        self.reqs = Int64(0)
        self.sent = Int64(0)

    def exchange(
        mut self, stream_id: UInt32, content_type: List[UInt8], body: Optional[List[UInt8]]
    ) raises -> _Answer:
        """Feed one request to the serve loop's frame dispatcher and decode
        every frame it wrote back (all on `stream_id` or connection-level)."""
        var wire = List[UInt8]()
        encode_headers_frame(
            stream_id, _request_block(content_type), not body, True, wire
        )
        if body:
            encode_data_frame(stream_id, body.value().copy(), True, wire)
        self.h2.append_recv_bytes(Span(wire))
        var alive = _dispatch_h2_frames(
            self.h2, self.router, self.svc, self.reqs, self.sent
        )
        assert_true(alive, "the connection stays open")

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
            if f.header.stream_id != stream_id:
                continue
            if f.header.kind == FRAME_HEADERS:
                var hs = self.dec.decode_block(Span(f.payload))
                var st = _value(hs, String(":status"))
                if st != String("<absent>"):
                    ans.status = st
                var gs = _value(hs, String("grpc-status"))
                if gs != String("<absent>"):
                    ans.grpc_status = gs
            elif f.header.kind == FRAME_DATA:
                for i in range(len(f.payload)):
                    ans.data.append(f.payload[i])
        return ans^


def _ct(prefix: String, suffix: List[UInt8]) -> List[UInt8]:
    var out = _bytes(prefix)
    for i in range(len(suffix)):
        out.append(suffix[i])
    return out^


def _msg() -> List[UInt8]:
    return [UInt8(0xAA), UInt8(0xBB)]


def main() raises:
    print("== h2 serve loop, non-ASCII content-type ==")
    var conn = _Conn()
    var sid = UInt32(1)
    var suffixes = _suffixes()
    var msg = _msg()

    print("  T1 non-ASCII byte in the type: Router path, 404...")
    for i in range(len(suffixes)):
        var a = conn.exchange(
            sid, _ct(String("application/grpc"), suffixes[i]), None
        )
        assert_false(a.saw_reset_or_goaway, "no RST_STREAM / GOAWAY")
        assert_equal(a.status, String("404"))
        assert_equal(a.grpc_status, String("<absent>"))
        sid += 2
    print("    OK")

    print("  T2 non-ASCII byte in a parameter: gRPC echo...")
    for i in range(len(suffixes)):
        var a = conn.exchange(
            sid,
            _ct(String("application/grpc+proto; charset="), suffixes[i]),
            grpc_encode_unary(Span(msg)),
        )
        assert_false(a.saw_reset_or_goaway, "no RST_STREAM / GOAWAY")
        assert_equal(a.status, String("200"))
        assert_equal(a.grpc_status, String("0"))
        var echoed = grpc_decode_unary(Span(a.data))
        assert_equal(len(echoed), 2)
        assert_equal(echoed[0], UInt8(0xAA))
        assert_equal(echoed[1], UInt8(0xBB))
        sid += 2
    print("    OK")

    print("  T3 a plain request on the same connection...")
    var a = conn.exchange(
        sid, _bytes(String("application/grpc+proto")), grpc_encode_unary(Span(msg))
    )
    assert_equal(a.status, String("200"))
    assert_equal(a.grpc_status, String("0"))
    assert_equal(len(grpc_decode_unary(Span(a.data))), 2)
    print("    OK")
    print("== PASSED (3 legs, 9 streams) ==")
