# =============================================================================
# tls_front.mojo -- TLS in front of a plaintext komira_http_server
# =============================================================================
#
# komira_http_server answers a TLS connection with its canned health
# response only: `serve_one_iteration_dispatch`, the path that hands a parsed
# request to a `RequestDispatcher`, is plaintext (it drops a TLS connection).
# A client that speaks only HTTPS, as the generated Google clients do, can
# reach a stateful fake only through a TLS terminator, and `TlsFront` is
# that terminator, built from the server side of komira_http_core's TLS
# (`TlsStream`, s2n in server mode):
#
#   * it listens on 127.0.0.1 on an ephemeral port and accepts each
#     connection non-blocking;
#   * it drives the server handshake with the given `TlsConfig` (the
#     fixture leaf, ALPN http/1.1 only), recording the SNI the client sent;
#   * once the handshake is done it dials the plaintext server on loopback
#     (one upstream connection per downstream one), forwards each complete
#     HTTP/1.1 request (head and Content-Length body) in one write, and
#     relays whatever the server answers back through TLS.
#
# A request is forwarded whole because the server's dispatch read round
# does not buffer a request head split across reads; the front never
# rewrites a byte. Either side closing closes the pair. Everything is
# non-blocking and stepped from one thread (the duet's server thread, after
# the server's own step), so the front adds no thread.
#
# The front is test infrastructure, not a product TLS path; the gap it
# covers (a TLS dispatch path in komira_http_server) is stated in BUCK.
# =============================================================================

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.socket_io import try_io_read, try_io_write
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.tcp_stream import TcpListener, TcpStream
from komira_http_core.tls import TlsConfig
from komira_http_core.tls.conn import TlsStream
from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
)

comptime _READ_CHUNK = 16384
comptime _LISTEN_BACKLOG: Int32 = 16


def _find_head_end(buf: List[UInt8]) -> Int:
    """The index just past the first CRLFCRLF in `buf`, or -1."""
    var n = len(buf)
    var i = 0
    while i + 3 < n:
        if (
            buf[i] == 13
            and buf[i + 1] == 10
            and buf[i + 2] == 13
            and buf[i + 3] == 10
        ):
            return i + 4
        i += 1
    return -1


def _content_length(buf: List[UInt8], head_end: Int) raises -> Int:
    """The Content-Length the head `buf[0:head_end]` declares, 0 when it
    declares none. A head with Transfer-Encoding is refused: the front
    frames by length only, and the generated clients always send one."""
    var head = String(unsafe_from_utf8=Span(buf)[0:head_end])
    var lower = head.lower()
    if lower.find("\r\ntransfer-encoding:") >= 0:
        raise Error("TlsFront: a chunked request; the front frames by Content-Length")
    var at = lower.find("\r\ncontent-length:")
    if at < 0:
        return 0
    var start = at + String("\r\ncontent-length:").byte_length()
    var end = lower.find("\r\n", start)
    var digits = String(lower[byte=start:end])
    return Int(atol(String(digits.strip())))


struct _Pair(Movable):
    """One downstream TLS connection and the plaintext upstream it feeds."""

    var down: TcpStream
    var tls: TlsStream
    var up: Optional[TcpStream]
    # Decrypted request bytes not yet forwarded (an incomplete request).
    var pending_request: List[UInt8]
    # Bytes accepted for a side but not yet written to it.
    var to_up: List[UInt8]
    var to_down: List[UInt8]
    var sni: String
    # This pair's slot in `TlsFront.snis`.
    var slot: Int
    var closed: Bool
    var up_eof: Bool

    def __init__(out self, var down: TcpStream, var tls: TlsStream, slot: Int):
        self.slot = slot
        self.down = down^
        self.tls = tls^
        self.up = Optional[TcpStream]()
        self.pending_request = List[UInt8]()
        self.to_up = List[UInt8]()
        self.to_down = List[UInt8]()
        self.sni = String("")
        self.closed = False
        self.up_eof = False


struct TlsFront(Movable):
    """A TLS terminator on 127.0.0.1 relaying to a plaintext server on
    `upstream_port`. Stepped by one thread; see the module header."""

    var _listener: TcpListener
    var _config: TlsConfig
    var _upstream_port: UInt16
    var _rt: BlockingRuntime[NoopSink]
    # ArcPointer so a Movable-only pair can sit in a List; only the
    # stepping thread ever touches one.
    var _pairs: List[ArcPointer[_Pair]]
    # Per accepted connection, in accept order: the SNI the client sent
    # ("" for none), and whether its handshake completed.
    var snis: List[String]
    var handshakes_failed: Int
    # Pairs closed because the client ended its connection, and because
    # the server ended its side.
    var closed_by_client: Int
    var closed_by_server: Int

    def __init__(out self, var config: TlsConfig, upstream_port: UInt16) raises:
        self._listener = TcpListener.bind_loopback(UInt16(0), _LISTEN_BACKLOG)
        self._config = config^
        self._upstream_port = upstream_port
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        self._pairs = List[ArcPointer[_Pair]]()
        self.snis = List[String]()
        self.handshakes_failed = 0
        self.closed_by_client = 0
        self.closed_by_server = 0

    def port(self) raises -> UInt16:
        return self._listener.local_port()

    def open_pairs(self) -> Int:
        return len(self._pairs)

    def step(mut self) raises:
        """Accept what is waiting, then move every pair's bytes as far as
        they go without blocking; drop the pairs that closed."""
        while True:
            var ar = self._listener.try_accept()
            if not ar.is_ready():
                break
            var fd = Int32(Int(ar.value()))
            var down = TcpStream(fd)
            var tls = TlsStream(self._config, fd)
            self._pairs.append(ArcPointer[_Pair](_Pair(down^, tls^, len(self.snis))))
            self.snis.append(String(""))
        var kept = List[ArcPointer[_Pair]]()
        for i in range(len(self._pairs)):
            var pair = self._pairs[i]
            self._step_pair(pair[])
            if not pair[].closed:
                kept.append(pair)
        self._pairs = kept^

    def _step_pair(mut self, mut p: _Pair) raises:
        if not p.tls.handshake_done():
            var hs = p.tls.drive_handshake()
            if hs[0] == TLS_OUTCOME_ERROR:
                self.handshakes_failed += 1
                p.closed = True
                return
            if hs[0] != TLS_OUTCOME_DONE:
                return
            p.sni = p.tls.sni_hostname().or_else(String(""))
            self.snis[p.slot] = p.sni.copy()
            ref reactor = self._rt.reactor()
            p.up = Optional[TcpStream](
                TcpStream.connect_loopback[NoopSink](reactor, self._upstream_port)
            )
        # Downstream: decrypt what has arrived.
        while True:
            var buf = List[UInt8]()
            buf.reserve(_READ_CHUNK)
            buf.resize(unsafe_uninit_length=_READ_CHUNK)
            var r = p.tls.read_app(buf, _READ_CHUNK)
            if r[0] == TLS_OUTCOME_DONE and r[1] > 0:
                p.pending_request.extend(Span(buf)[0 : r[1]])
                continue
            if r[0] == TLS_OUTCOME_DONE or r[0] == TLS_OUTCOME_ERROR:
                # close_notify, or a broken record: the client is gone.
                self.closed_by_client += 1
                p.closed = True
                return
            break
        # Forward each complete request whole.
        while True:
            var head_end = _find_head_end(p.pending_request)
            if head_end < 0:
                break
            var total = head_end + _content_length(p.pending_request, head_end)
            if len(p.pending_request) < total:
                break
            p.to_up.extend(Span(p.pending_request)[0:total])
            var rest = List[UInt8]()
            rest.extend(Span(p.pending_request)[total : len(p.pending_request)])
            p.pending_request = rest^
        var up_fd = p.up.value().fd()
        if len(p.to_up) > 0:
            var w = try_io_write(up_fd, Span(p.to_up))
            if w.is_error():
                p.closed = True
                return
            if w.is_ready():
                var rest = List[UInt8]()
                rest.extend(Span(p.to_up)[Int(w.value()) : len(p.to_up)])
                p.to_up = rest^
        # Upstream: take what the server answered.
        while not p.up_eof:
            var ubuf = List[UInt8]()
            ubuf.resize(_READ_CHUNK, UInt8(0))
            var rr = try_io_read(up_fd, Span(ubuf))
            if rr.is_would_block():
                break
            if rr.is_error() or rr.value() == 0:
                p.up_eof = True
                break
            p.to_down.extend(Span(ubuf)[0 : Int(rr.value())])
        # Encrypt it back.
        while len(p.to_down) > 0:
            var s = p.tls.write_app(Span(p.to_down))
            if s[0] == TLS_OUTCOME_DONE and s[1] > 0:
                var rest = List[UInt8]()
                rest.extend(Span(p.to_down)[s[1] : len(p.to_down)])
                p.to_down = rest^
                continue
            if s[0] == TLS_OUTCOME_BLOCKED_ON_WRITE or s[0] == TLS_OUTCOME_BLOCKED_ON_READ:
                break
            p.closed = True
            return
        if p.up_eof and len(p.to_down) == 0:
            self.closed_by_server += 1
            p.closed = True
