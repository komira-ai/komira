# =============================================================================
# test_L2_h2_serve_read_round.mojo: `serve_read_round_h2`, one connection's
# read, dispatch and flush, over a real TLS session
# =============================================================================
#
# The server end is a `ConnEntry` holding a server `TlsStream`; the client
# end is an s2n client `TlsConnection`; the two are joined by an AF_UNIX
# socketpair in this process (no network, no listener). Both handshake to
# DONE first. A byte written on one end is readable on the other when the
# write returns, so every round below sees exactly what the client sent
# before it; no test sleeps or waits on a clock.
#
# Every malformed input is an h2spec v2.6.0 case and is named for it; the
# rest is ordinary client traffic.
#
# Groups (and the defect each would catch):
#   A  admission: a connection without TLS or without h2 state not refused.
#   F  the preface: an empty read not kept waiting, the preface not moving
#      the connection to ACTIVE with the server SETTINGS sent first, an
#      invalid preface not closing it.
#   D  dispatch and flush: a response not flushed in the same round, the
#      byte counter wrong, a protocol error closing before its GOAWAY is
#      written or with the peer's bytes left unread (close then sends RST).
#   B  bounds: one round reading without limit (the 32-read bound), a
#      blocked write losing or reordering the unsent tail, a GOAWAY closing
#      the connection before its queue is written; a prepended GOAWAY
#      overtaking the server preface (RFC 9113 §3.4) or an unwritten tail.
#   C  close: the peer's close_notify, a socket closed without one, or a
#      failed TLS read (a reset peer) not closing the connection; a frame
#      queued before the close_notify lost because it was not written
#      before the next read.
# =============================================================================

from std.ffi import external_call
from std.pathlib import Path
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    RegistrationHandle,
)
from komira_async.runtime.tcp_stream import TcpStream
from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    decode_frame,
    encode_frame_header,
)
from komira_http_core.codec.h2.hpack import (
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
)
from komira_http_core.codec.types import HttpMethod
from komira_http_core.tls import (
    CONN_STATE_TLS_HANDSHAKE_IN,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    TlsStream,
    tls_init,
)
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.accept_loop import drive_tls_handshake
from komira_http_server.connection import (
    CONN_STATE_H2_ACTIVE,
    CONN_STATE_H2_PREFACE_WAIT,
    ConnEntry,
)
from komira_http_server.routing import Router
from komira_http_server.serve_h2 import serve_read_round_h2


comptime PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
comptime PROTOCOL_ERROR: UInt32 = 0x1
comptime REFUSED_STREAM: UInt32 = 0x7


# -----------------------------------------------------------------------------
# The rig.
# -----------------------------------------------------------------------------


def _socketpair() raises -> Array[Int32, 2]:
    var pair = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: `pair` is a stack local that outlives the call; socketpair(2)
    # writes two ints into it and retains nothing.
    var rc = external_call["socketpair", Int32](
        Int32(1), Int32(1), Int32(0), pair.unsafe_ptr()
    )
    if rc < 0:
        raise Error("socketpair(AF_UNIX, SOCK_STREAM) failed")
    for i in range(2):
        if external_call["komira_fcntl_set_nonblock", Int32](pair[i]) < 0:
            raise Error("set_nonblock failed")
    return pair^


def _set_sndbuf(fd: Int32, bytes: Int) raises:
    """Shrink `fd`'s send buffer (the kernel raises a tiny value to its
    minimum), so a flush of a few KiB blocks."""
    var val = Int32(bytes)
    var level = Int32(1)
    var opt = Int32(7)
    comptime if CompilationTarget.is_macos():
        level = Int32(0xFFFF)
        opt = Int32(0x1001)
    var rc = external_call["setsockopt", Int32](
        fd,
        level,
        opt,
        # SAFETY: `val` is a stack local read synchronously; nothing retains it.
        UnsafePointer(to=val).bitcast[UInt8](),
        UInt32(4),
    )
    if rc < 0:
        raise Error("setsockopt(SO_SNDBUF) failed")


def _unread_bytes(fd: Int32) -> Int:
    """Bytes waiting unread in `fd`'s receive queue (up to 64), by a
    MSG_PEEK recv on the non-blocking socket; 0 when it would block."""
    var buf = List[UInt8](length=64, fill=UInt8(0))
    # SAFETY: `buf` is a local of 64 bytes that outlives the call; recv(2)
    # writes at most 64 bytes into it and retains nothing.
    var n = external_call["recv", Int64](
        fd, buf.unsafe_ptr(), UInt64(64), Int32(2),  # MSG_PEEK
    )
    return Int(n) if n > Int64(0) else 0


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _cat(mut a: List[UInt8], b: List[UInt8]):
    for i in range(len(b)):
        a.append(b[i])


def _frame(kind: UInt8, flags: UInt8, sid: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    encode_frame_header(UInt32(len(payload)), kind, flags, UInt32(sid), out)
    _cat(out, payload)
    return out^


def _ping(k: Int) -> List[UInt8]:
    """PING number `k`: its 8 data bytes are `k` big-endian."""
    var p = List[UInt8]()
    for i in range(8):
        p.append(UInt8((k >> (8 * (7 - i))) & 0xFF))
    return _frame(FRAME_PING, UInt8(0), 0, p)


def _settings_initial_window(v: Int) -> List[UInt8]:
    var p: List[UInt8] = [
        UInt8(0), UInt8(4),
        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
    ]
    return _frame(FRAME_SETTINGS, UInt8(0), 0, p)


struct _Out(Copyable, Movable):
    var kind: UInt8
    var flags: UInt8
    var sid: UInt32
    var code: UInt32
    var ping_k: Int
    var n_settings: Int
    var payload: List[UInt8]
    var headers: List[HpackHeader]

    def __init__(out self):
        self.kind = UInt8(0xFF)
        self.flags = UInt8(0)
        self.sid = UInt32(0)
        self.code = UInt32(0)
        self.ping_k = -1
        self.n_settings = 0
        self.payload = List[UInt8]()
        self.headers = List[HpackHeader]()


def _hval(hs: List[HpackHeader], name: String) -> String:
    for i in range(len(hs)):
        if String(hs[i].name) == name:
            return String(hs[i].value)
    return String("<absent>")


struct _Link(Movable):
    """A server ConnEntry and an s2n client, handshaken to DONE."""

    var entry: ConnEntry
    var client: TlsConnection
    var client_fd: Int32
    var router: Router
    var grpc: NoopGrpcDispatch
    var enc: HpackEncoder
    var dec: HpackDecoder
    var reqs: Int64
    var sent: Int64
    var received: List[UInt8]  # every plaintext byte the client read
    var cursor: Int  # how much of `received` `frames()` has decoded

    def __init__(out self, h2: Bool = True) raises:
        tls_init()
        var srv_cfg = TlsConfig()
        srv_cfg.load_cert(
            Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text(),
            Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text(),
        )
        var alpn: List[String] = ["h2"]
        srv_cfg.set_alpn_protocols(alpn)
        var cli_cfg = TlsConfig()
        cli_cfg.wipe_trust()
        cli_cfg.disable_verify()
        cli_cfg.set_alpn_protocols(alpn)
        var fds = _socketpair()
        self.entry = ConnEntry(
            stream=TcpStream(fds[0]),
            reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
            tls_stream=TlsStream(srv_cfg, fds[0]),
            initial_state=CONN_STATE_TLS_HANDSHAKE_IN,
        )
        self.client = TlsConnection.new_client(cli_cfg)
        self.client.bind_fd(fds[1])
        self.client_fd = fds[1]
        self.router = Router()
        self.router.add(HttpMethod.get(), "/", 1)
        self.grpc = NoopGrpcDispatch()
        self.enc = HpackEncoder()
        self.dec = HpackDecoder()
        self.reqs = Int64(0)
        self.sent = Int64(0)
        self.received = List[UInt8]()
        self.cursor = 0
        var sv_done = False
        var cl_done = False
        for _ in range(256):
            if not sv_done:
                var o = drive_tls_handshake(self.entry)[0]
                if o == TLS_OUTCOME_ERROR:
                    raise Error("server handshake failed")
                sv_done = o == TLS_OUTCOME_DONE
            if not cl_done:
                var o = self.client.handshake()
                if o == TLS_OUTCOME_ERROR:
                    raise Error("client handshake failed")
                cl_done = o == TLS_OUTCOME_DONE
            if sv_done and cl_done:
                break
        if not (sv_done and cl_done):
            raise Error("the handshake did not finish")
        if h2:
            self.entry.install_h2_state(H2ConnectionState())
            self.entry.set_state(CONN_STATE_H2_PREFACE_WAIT)

    def round(mut self) -> Bool:
        return serve_read_round_h2(
            self.entry, self.router, self.grpc, self.reqs, self.sent
        )

    def write(mut self, bytes: List[UInt8]) raises:
        """Send all of `bytes` to the server; the socket must take them."""
        var off = 0
        while off < len(bytes):
            var r = self.client.send(Span(bytes)[off:])
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                raise Error("the client could not send: outcome " + String(Int(r[0])))
            off += r[1]

    def read(mut self) raises -> Int:
        """Read everything the server has written so far; returns the count."""
        var got = 0
        while True:
            var buf = List[UInt8]()
            buf.reserve(16384)
            var r = self.client.recv(buf, 16384)
            if r[0] == TLS_OUTCOME_BLOCKED_ON_READ:
                return got
            if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
                raise Error("client read ended: outcome " + String(Int(r[0])))
            _cat(self.received, buf)
            got += r[1]

    def frames(mut self) raises -> List[_Out]:
        """Decode the frames received since the last call."""
        var outs = List[_Out]()
        while self.cursor < len(self.received):
            var res = decode_frame(Span(self.received)[self.cursor:], 1 << 24)
            if res.status != 0:
                break  # a frame not yet complete
            self.cursor += res.consumed
            ref f = res.frame
            var o = _Out()
            o.kind = f.header.kind
            o.flags = f.header.flags
            o.sid = f.header.stream_id
            if f.header.kind == FRAME_RST_STREAM:
                o.code = f.rst_error_code
            if f.header.kind == FRAME_GOAWAY:
                o.code = f.goaway_error_code
            if f.header.kind == FRAME_PING:
                var k = 0
                for i in range(8):
                    k = (k << 8) | Int(f.ping_data[i])
                o.ping_k = k
            if f.header.kind == FRAME_SETTINGS:
                o.n_settings = len(f.settings)
            if f.header.kind == FRAME_DATA:
                o.payload = f.payload.copy()
            if f.header.kind == FRAME_HEADERS:
                o.headers = self.dec.decode_block(Span(f.payload))
            outs.append(o^)
        return outs^

    def get(mut self, sid: Int) -> List[UInt8]:
        var hs = List[HpackHeader]()
        hs.append(HpackHeader(String(":method"), String("GET")))
        hs.append(HpackHeader(String(":scheme"), String("https")))
        hs.append(HpackHeader(String(":path"), String("/")))
        hs.append(HpackHeader(String(":authority"), String("localhost")))
        return _frame(
            FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, sid,
            self.enc.encode_block(hs^),
        )

    def queued(mut self) raises -> Int:
        """Bytes the server still holds to write."""
        ref opt = self.entry.h2_state_ref()
        assert_true(Bool(opt), "h2 state installed")
        return len(opt.value().pending_out)

    def settings_sent(mut self) raises -> Bool:
        ref opt = self.entry.h2_state_ref()
        assert_true(Bool(opt), "h2 state installed")
        return opt.value().is_settings_sent()

    def opened(mut self) raises:
        """Preface and an empty SETTINGS; one round; the server's SETTINGS
        and ACK read and checked."""
        var b = _bytes(PREFACE)
        _cat(b, _frame(FRAME_SETTINGS, UInt8(0), 0, List[UInt8]()))
        self.write(b)
        assert_true(self.round())
        _ = self.read()
        var outs = self.frames()
        assert_equal(len(outs), 2)
        assert_equal(Int(outs[0].kind), Int(FRAME_SETTINGS))
        assert_equal(Int(outs[0].flags), 0)
        assert_equal(outs[0].n_settings, 5)
        assert_equal(Int(outs[1].kind), Int(FRAME_SETTINGS))
        assert_equal(Int(outs[1].flags), Int(FLAG_ACK))


# -----------------------------------------------------------------------------
# A. Admission.
# -----------------------------------------------------------------------------


def test_plaintext_connection_is_refused() raises:
    var fds = _socketpair()
    var entry = ConnEntry(
        stream=TcpStream(fds[0]),
        reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
    )
    var router = Router()
    var grpc = NoopGrpcDispatch()
    var reqs = Int64(0)
    var sent = Int64(0)
    assert_false(serve_read_round_h2(entry, router, grpc, reqs, sent))
    _close(fds[1])


def test_tls_connection_without_h2_state_is_refused() raises:
    var link = _Link(h2=False)
    assert_false(link.round())
    assert_equal(link.read(), 0, "nothing written")
    _close(link.client_fd)


# -----------------------------------------------------------------------------
# F. The preface.
# -----------------------------------------------------------------------------


def test_nothing_to_read_keeps_waiting() raises:
    var link = _Link()
    assert_true(link.round())
    assert_equal(Int(link.entry.state()), Int(CONN_STATE_H2_PREFACE_WAIT))
    assert_equal(link.read(), 0)
    _close(link.client_fd)


def test_partial_preface_keeps_waiting() raises:
    var link = _Link()
    var b = _bytes(PREFACE)
    var half = List[UInt8]()
    for i in range(10):
        half.append(b[i])
    link.write(half)
    assert_true(link.round())
    assert_equal(Int(link.entry.state()), Int(CONN_STATE_H2_PREFACE_WAIT))
    assert_equal(link.read(), 0)
    _close(link.client_fd)


def test_preface_activates_and_sends_settings_first() raises:
    """h2spec http2/3.5/1: preface and SETTINGS; the server answers its own
    SETTINGS (5 entries) first, then the ACK, and is ACTIVE."""
    var link = _Link()
    link.opened()
    assert_equal(Int(link.entry.state()), Int(CONN_STATE_H2_ACTIVE))
    assert_true(link.settings_sent())
    assert_equal(Int(link.sent), len(link.received))
    _close(link.client_fd)


def test_invalid_preface_closes() raises:
    """h2spec http2/3.5/2."""
    var link = _Link()
    link.write(_bytes("INVALID CONNECTION PREFACE\r\n\r\n"))
    assert_false(link.round())
    assert_equal(link.read(), 0, "nothing written")
    _close(link.client_fd)


# -----------------------------------------------------------------------------
# D. Dispatch and flush.
# -----------------------------------------------------------------------------


def test_request_is_answered_in_the_same_round() raises:
    """Preface, SETTINGS and a GET in one write: one round answers all of
    it. The byte counter holds the 18 body bytes the response counted plus
    every byte the flush wrote."""
    var link = _Link()
    var b = _bytes(PREFACE)
    _cat(b, _frame(FRAME_SETTINGS, UInt8(0), 0, List[UInt8]()))
    _cat(b, link.get(1))
    link.write(b)
    assert_true(link.round())
    var n = link.read()
    var outs = link.frames()
    assert_equal(len(outs), 4)
    assert_equal(Int(outs[2].kind), Int(FRAME_HEADERS))
    assert_equal(_hval(outs[2].headers, ":status"), "200")
    assert_equal(Int(outs[3].kind), Int(FRAME_DATA))
    assert_equal(Int(outs[3].flags), Int(FLAG_END_STREAM))
    assert_equal(len(outs[3].payload), 18)
    assert_equal(Int(link.reqs), 1)
    assert_equal(Int(link.sent), 18 + n)
    _close(link.client_fd)


def test_protocol_error_writes_goaway_then_closes() raises:
    """h2spec http2/6.8/1 (a GOAWAY on stream 1) once the connection is
    open: the round writes GOAWAY(PROTOCOL_ERROR) and says close."""
    var link = _Link()
    link.opened()
    var p = List[UInt8]()
    for _ in range(8):
        p.append(UInt8(0))
    link.write(_frame(FRAME_GOAWAY, UInt8(0), 1, p))
    assert_false(link.round())
    _ = link.read()
    var outs = link.frames()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[0].code), Int(PROTOCOL_ERROR))
    _close(link.client_fd)


def test_connection_error_reads_the_rest_before_closing() raises:
    """A GOAWAY on stream 1 (h2spec http2/6.8/1, a connection error) and
    then 36 KiB more in the same write. The round writes GOAWAY(
    PROTOCOL_ERROR), then reads and drops what the peer already sent before
    it says close: close(2) on a socket with unread bytes sends RST, which
    can reach the peer ahead of the GOAWAY (h2spec http2/4.2/2 saw exactly
    that)."""
    var link = _Link()
    link.opened()
    var p = List[UInt8]()
    for _ in range(8):
        p.append(UInt8(0))
    var b = _frame(FRAME_GOAWAY, UInt8(0), 1, p)
    var big = List[UInt8]()
    for _ in range(4096):
        big.append(UInt8(0))
    for _ in range(9):
        _cat(b, _frame(UInt8(0x16), UInt8(0), 0, big))
    link.write(b)
    assert_false(link.round())
    assert_equal(_unread_bytes(link.entry.fd()), 0, "unread bytes left at close")
    _ = link.read()
    var outs = link.frames()
    assert_equal(len(outs), 1)
    assert_equal(Int(outs[0].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[0].code), Int(PROTOCOL_ERROR))
    _close(link.client_fd)


# -----------------------------------------------------------------------------
# B. Bounds.
# -----------------------------------------------------------------------------


def _assert_pings_in_order(outs: List[_Out], first: Int) raises -> Int:
    """Every frame is a PING ACK, numbered on from `first`; returns the next
    number."""
    var k = first
    for i in range(len(outs)):
        assert_equal(Int(outs[i].kind), Int(FRAME_PING))
        assert_equal(Int(outs[i].flags), Int(FLAG_ACK))
        assert_equal(outs[i].ping_k, k)
        k += 1
    return k


def test_one_round_reads_at_most_32_chunks() raises:
    """After h2spec http2/5.5/1: nine ignored frames of its unknown type
    0x16, but 16384 bytes long each rather than its 8, and then a PING:
    147554 bytes, more than 32 reads of 4096 can reach, all in the socket
    before the round. The first round does not reach the PING; the second
    answers it."""
    var link = _Link()
    link.opened()
    var big = List[UInt8]()
    for _ in range(16384):
        big.append(UInt8(0))
    var b = List[UInt8]()
    for _ in range(9):
        _cat(b, _frame(UInt8(0x16), UInt8(0), 0, big))
    _cat(b, _ping(77))
    link.write(b)
    assert_true(link.round())
    assert_equal(link.read(), 0, "the first round reached the PING")
    assert_true(link.round())
    _ = link.read()
    var outs = link.frames()
    assert_equal(len(outs), 1)
    assert_equal(outs[0].ping_k, 77)
    _close(link.client_fd)


def test_blocked_write_keeps_the_unsent_tail_in_order() raises:
    """With the smallest send buffer the kernel allows, 1000 PING ACKs
    (17000 bytes) do not fit: the round says alive and keeps the tail
    queued; each later round writes on from where the last stopped, and the
    client gets all 1000 in order."""
    var link = _Link()
    link.opened()
    _set_sndbuf(link.entry.fd(), 1)
    var b = List[UInt8]()
    for k in range(1000):
        _cat(b, _ping(k))
    link.write(b)
    assert_true(link.round())
    assert_true(link.queued() > 0, "the unsent tail was dropped")
    assert_true(link.read() < 1000 * 17, "the first flush was not partial")
    var next = _assert_pings_in_order(link.frames(), 0)
    var rounds = 1
    while next < 1000 and rounds < 400:
        assert_true(link.round())
        _ = link.read()
        next = _assert_pings_in_order(link.frames(), next)
        rounds += 1
    assert_equal(next, 1000)
    assert_equal(link.queued(), 0)
    _close(link.client_fd)


def test_goaway_waits_for_its_queue_before_closing() raises:
    """h2spec http2/5.1.2/1 behind a backlog: 1000 PINGs, a zero initial
    window and 51 GETs, with the smallest send buffer. The 51st GET is refused
    with GOAWAY(REFUSED_STREAM) and RST_STREAM(101), together, ahead of
    everything not yet offered to TLS (the round flushes between reads, so
    the frames of earlier reads were offered already and stay in front, see
    test_refusal_never_overtakes_an_unwritten_tail); the round says alive
    while the queue is unwritten and close once it is all written."""
    var link = _Link()
    link.opened()
    _set_sndbuf(link.entry.fd(), 1)
    var b = _settings_initial_window(0)
    for k in range(1000):
        _cat(b, _ping(k))
    for k in range(51):
        _cat(b, link.get(2 * k + 1))
    link.write(b)
    var alive = link.round()
    var rounds = 1
    while alive and rounds < 400:
        assert_true(link.queued() > 0, "alive with nothing left to write")
        _ = link.read()
        alive = link.round()
        rounds += 1
    assert_false(alive, "the connection was never closed")
    assert_true(rounds > 1, "closed before the queue was written")
    _ = link.read()
    var outs = link.frames()
    assert_equal(link.cursor, len(link.received), "bytes that do not decode as frames")
    var pings = 0
    var heads = 0
    var goaways = 0
    for i in range(len(outs)):
        if outs[i].kind == FRAME_PING:
            pings += 1
        if outs[i].kind == FRAME_HEADERS:
            heads += 1
        if outs[i].kind == FRAME_GOAWAY:
            goaways += 1
            assert_equal(Int(outs[i].code), Int(REFUSED_STREAM))
            assert_true(i + 1 < len(outs), "nothing after the GOAWAY")
            assert_equal(Int(outs[i + 1].kind), Int(FRAME_RST_STREAM))
            assert_equal(Int(outs[i + 1].sid), 101)
    assert_equal(goaways, 1)
    assert_equal(pings, 1000)
    assert_equal(heads, 50)
    assert_equal(link.queued(), 0)
    _close(link.client_fd)


def test_server_settings_precede_a_refusal_in_the_first_read() raises:
    """The client preface, a zero initial window (so no answer completes and
    every stream stays open) and 51 GETs in one write, before the server has
    said anything: the 51st GET is refused with GOAWAY(REFUSED_STREAM),
    which the §5.1.2 gate puts at the front of the queue. The server's own
    SETTINGS is still the first frame on the wire (RFC 9113 §3.4), and the
    GOAWAY comes straight after it."""
    var link = _Link()
    var b = _bytes(PREFACE)
    _cat(b, _settings_initial_window(0))
    for k in range(51):
        _cat(b, link.get(2 * k + 1))
    link.write(b)
    _ = link.round()
    _ = link.read()
    var outs = link.frames()
    assert_true(len(outs) >= 3)
    assert_equal(Int(outs[0].kind), Int(FRAME_SETTINGS), "a frame overtook the server preface")
    assert_equal(Int(outs[0].flags), 0)
    assert_equal(outs[0].n_settings, 5)
    assert_equal(Int(outs[1].kind), Int(FRAME_GOAWAY))
    assert_equal(Int(outs[1].code), Int(REFUSED_STREAM))
    assert_equal(Int(outs[2].kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(outs[2].sid), 101)
    _close(link.client_fd)


def test_refusal_never_overtakes_an_unwritten_tail() raises:
    """With the smallest send buffer, a zero initial window and 1000 PINGs
    leave a partly written queue whose unwritten tail may begin mid-frame.
    Then 51 GETs: the 51st is refused and its GOAWAY and RST_STREAM go to
    the front of the queue, but behind that tail. Every frame the client
    reads decodes: the 1000 PING ACKs in order, then the refusal, then the
    50 answers."""
    var link = _Link()
    link.opened()
    _set_sndbuf(link.entry.fd(), 1)
    var b = _settings_initial_window(0)
    for k in range(1000):
        _cat(b, _ping(k))
    link.write(b)
    assert_true(link.round())
    assert_true(link.queued() > 0, "the first flush was not partial")
    var g = List[UInt8]()
    for k in range(51):
        _cat(g, link.get(2 * k + 1))
    link.write(g)
    var alive = link.round()
    var rounds = 1
    while alive and rounds < 400:
        _ = link.read()
        alive = link.round()
        rounds += 1
    assert_false(alive, "the connection was never closed")
    _ = link.read()
    var outs = link.frames()
    assert_equal(link.cursor, len(link.received), "bytes that do not decode as frames")
    var pings = 0
    var heads = 0
    var goaway_at = -1
    var last_ping_at = -1
    for i in range(len(outs)):
        if outs[i].kind == FRAME_PING:
            assert_equal(outs[i].ping_k, pings, "a PING ACK out of order")
            pings += 1
            last_ping_at = i
        if outs[i].kind == FRAME_HEADERS:
            heads += 1
        if outs[i].kind == FRAME_GOAWAY:
            assert_equal(Int(outs[i].code), Int(REFUSED_STREAM))
            goaway_at = i
    assert_equal(pings, 1000)
    assert_equal(heads, 50)
    assert_true(goaway_at > last_ping_at, "the GOAWAY overtook the unwritten tail")
    _close(link.client_fd)


# -----------------------------------------------------------------------------
# C. Close.
# -----------------------------------------------------------------------------


def test_close_notify_after_a_ping_still_gets_the_ack() raises:
    """A PING then the client's close_notify, both in the socket before the
    round. The round reads the PING, writes its ACK before it reads again
    (once s2n has processed the close_notify it refuses every write), then
    reads the end of the stream and says close: the 17-byte ACK is counted
    and nothing stays queued."""
    var link = _Link()
    link.opened()
    link.write(_ping(5))
    var s = link.client.shutdown()
    assert_true(s == TLS_OUTCOME_BLOCKED_ON_READ or s == TLS_OUTCOME_DONE)
    var before = Int(link.sent)
    assert_false(link.round())
    assert_equal(Int(link.sent), before + 17, "the PING ACK was not written")
    assert_equal(link.queued(), 0)
    _close(link.client_fd)


def test_vanished_peer_closes() raises:
    """The client's socket is closed without a close_notify: s2n reads it
    as the end of the stream, and the round says close."""
    var link = _Link()
    link.opened()
    _close(link.client_fd)
    assert_false(link.round())


def test_reset_peer_closes() raises:
    """The client leaves the server's PING ACK unread and closes its socket.
    Closing an AF_UNIX socket with unread data resets the peer on linux, so
    the server's next TLS read fails and the round says close (where the
    close reads as a plain end of stream instead, the answer is the same)."""
    var link = _Link()
    link.opened()
    link.write(_ping(9))
    assert_true(link.round())
    _close(link.client_fd)
    assert_false(link.round())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
