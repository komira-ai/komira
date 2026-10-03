# =============================================================================
# tests/test_chunked_request_body_dispatch.mojo
# =============================================================================
#
# REGRESSION GUARD: `Transfer-Encoding: chunked` REQUEST bodies were
# detected by the parser and decodable by the codec, but NEVER DRIVEN by the
# server's dispatch round. `serve_read_round_dispatch` read `content_length`
# only, so a chunked request reached the handler with an EMPTY body and the
# pipelining scan then re-parsed the chunk-size line as a new request line —
# HTTP 400.
#
# WHY THAT MATTERED: stock `git push` switches to chunked framing for any push
# above `http.postBuffer` (1 MiB default), so every real-sized push to a git
# host on this transport would be answered
#     error: RPC failed; HTTP 400 curl 22 The requested URL returned error: 400
#     fatal: the remote end hung up unexpectedly
# with `GIT_TRACE_CURL` showing `=> Send header: Transfer-Encoding: chunked`.
# Measured on git 2.50.1: 900 KiB push OK, 2 MiB push refused, and the SAME
# 2 MiB push with `-c http.postBuffer=64m` (Content-Length framing) accepted.
#
# `test_chunked_post_body_reaches_handler` asserts the handler observed all 11
# body bytes. Without chunked request handling the handler observes ZERO and
# the transport answers 400 instead of 200 — both assertions fail.
# `test_chunked_body_larger_than_recv_buffer` additionally falsifies the
# cross-recv drain (REQ_BUF_BYTES is 4096; the body here is ~24 KiB).
#
# NOT a decoder test — `test_L2_codec_chunked_encoding.mojo` already covers
# `decode_block` exhaustively, and it passes even when the server answers 400.
# The defect is a missing CALL, so this test drives a REAL `HttpServer` over a
# loopback socket through `serve_one_iteration_dispatch`, the path a git host
# runs.
#
# Same-process raw-socket client (the `test_e2e_bring_up` precedent): no
# subprocess, no curl, no fixed port. Loopback only, no host requirement.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router

# The serve-loop runtime: `.Sink == NoopSink` matches the HttpServer's
# `Reactor[NoopSink]` (the comptime constraint on
# `serve_one_iteration_dispatch[D, RT]`).
comptime _Rt = BlockingRuntime[NoopSink]


# =============================================================================
# §1 — The dispatcher under observation.
# =============================================================================


struct _BodyProbeDispatcher(RequestDispatcher):
    """Answers 200 with `len=<n> sum=<m>` describing the body it ACTUALLY
    received.

    Reporting a checksum as well as a length is deliberate: a decoder that
    concatenates the chunk-size lines into the body, or drops the final chunk,
    can still land on a plausible length. `sum` is the byte sum mod 2^16 — cheap,
    and it changes if any framing byte leaks into the payload.
    """

    var last_len: Int
    """The body length the LAST dispatched request carried (read by the test
    directly, so a failure says what the handler saw, not just what the wire
    said)."""

    def __init__(out self):
        self.last_len = -1

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        var n = len(req.body)
        var s = 0
        for i in range(n):
            s = (s + Int(req.body[i])) & 0xFFFF
        self.last_len = n
        var text = String("len=") + String(n) + String(" sum=") + String(s)
        return HttpResponse.ok(text^)


# =============================================================================
# §2 — Same-process raw-socket client (mirrors tests/.../test_e2e_bring_up).
# =============================================================================

comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)  # sin_len (Apple)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


def _client_socket() raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("test_chunked_request_body: socket() failed")
    return fd


def _connect(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](fd, addr_ptr, UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test_chunked_request_body: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0)
        )
        if rc <= Int64(0):
            raise Error("test_chunked_request_body: send() failed")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](fd, raw, UInt64(max_bytes), Int32(0))
    if n < Int64(0):
        raise Error("test_chunked_request_body: recv() failed")
    var out = List[UInt8]()
    for i in range(Int(n)):
        out.append(buf[i])
    return out^


def _close(fd: Int32):
    _ = external_call["close", Int32](fd)


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _to_str(b: List[UInt8]) -> String:
    var out = String()
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _contains(hay: List[UInt8], needle: String) -> Bool:
    return _to_str(hay).find(needle) >= 0


# =============================================================================
# §3 — Request builders.
# =============================================================================


def _hex_no_prefix(n: Int) -> String:
    """Lowercase hex with NO `0x` — the chunk-size line's wire form."""
    if n == 0:
        return String("0")
    var digits = String("0123456789abcdef")
    var out = String()
    var v = n
    while v > 0:
        out = digits[byte = (v & 15) : (v & 15) + 1] + out
        v = v >> 4
    return out^


def _chunked_request(path: String, chunks: List[String]) -> List[UInt8]:
    """A `Transfer-Encoding: chunked` POST — the framing stock git emits above
    `http.postBuffer`. Deliberately carries NO Content-Length (the two together
    are a smuggling shape the parser rejects outright)."""
    var s = String("POST ") + path + String(" HTTP/1.1\r\n")
    s += String("Host: localhost\r\n")
    s += String("Content-Type: application/octet-stream\r\n")
    s += String("Transfer-Encoding: chunked\r\n\r\n")
    for i in range(len(chunks)):
        ref c = chunks[i]
        s += _hex_no_prefix(len(c.as_bytes())) + String("\r\n") + c + String("\r\n")
    s += String("0\r\n\r\n")
    return _str_bytes(s)


def _content_length_request(path: String, body: String) -> List[UInt8]:
    var s = String("POST ") + path + String(" HTTP/1.1\r\n")
    s += String("Host: localhost\r\n")
    s += String("Content-Length: ") + String(len(body.as_bytes()))
    s += String("\r\n\r\n") + body
    return _str_bytes(s)


def _make_server() raises -> HttpServer[NoopGrpcDispatch]:
    var cfg = HttpServerConfig.default_ephemeral()
    return HttpServer(config=cfg, router=Router())


def _drive(
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: _BodyProbeDispatcher,
    iters: Int,
    timeout_us: Int32,
) raises:
    for _ in range(iters):
        _ = server.serve_one_iteration_dispatch[_BodyProbeDispatcher, _Rt](
            dispatcher, timeout_us
        )


def _round_trip(
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: _BodyProbeDispatcher,
    port: UInt16,
    request: List[UInt8],
) raises -> List[UInt8]:
    var fd = _client_socket()
    _connect(fd, port)
    _drive(server, dispatcher, 4, Int32(300_000))
    _send_all(fd, request)
    _drive(server, dispatcher, 24, Int32(100_000))
    var resp = _recv_some(fd, 65536)
    _close(fd)
    return resp^


# =============================================================================
# §4 — The falsifiers.
# =============================================================================


def test_chunked_post_body_reaches_handler() raises:
    """★ THE FALSIFIER. A chunked POST must reach the handler with the DECODED
    body and be answered 200.

    FAILS ON CURRENT CODE (pre-fix): the round never called the chunked decoder,
    so `dispatcher.last_len` was 0 (not 11) and the wire answer was
    `HTTP/1.1 400` (the pipelining scan read `5\\r\\n` as a request line).
    """
    var server = _make_server()
    var port = server.local_port()
    var dispatcher = _BodyProbeDispatcher()

    var chunks = List[String]()
    chunks.append(String("hello"))
    chunks.append(String(" world"))
    var resp = _round_trip(
        server, dispatcher, port, _chunked_request(String("/probe"), chunks)
    )

    assert_true(
        _contains(resp, String("HTTP/1.1 200")),
        String("chunked POST answered non-200: ") + _to_str(resp),
    )
    # 'hello' + ' world' = 11 bytes; the handler must see ALL of them and NONE
    # of the chunk framing.
    assert_equal(dispatcher.last_len, 11)
    assert_true(
        _contains(resp, String("len=11")),
        String("handler reported the wrong body length: ") + _to_str(resp),
    )
    _ = server^


def test_chunked_body_larger_than_recv_buffer() raises:
    """A chunked body spanning MANY recvs (REQ_BUF_BYTES is 4096; this is
    ~24 KiB across 12 chunks) — the cross-recv drain, which is the shape a real
    `git push` produces.

    FAILS ON CURRENT CODE (pre-fix): body never read at all -> 400.
    """
    var server = _make_server()
    var port = server.local_port()
    var dispatcher = _BodyProbeDispatcher()

    var one = String()
    for _ in range(2048):
        one += String("z")
    var chunks = List[String]()
    for _ in range(12):
        chunks.append(one)
    var expect = 12 * 2048

    var resp = _round_trip(
        server, dispatcher, port, _chunked_request(String("/probe"), chunks)
    )
    assert_true(
        _contains(resp, String("HTTP/1.1 200")),
        String("large chunked POST answered non-200: ") + _to_str(resp),
    )
    assert_equal(dispatcher.last_len, expect)
    _ = server^


def test_malformed_chunk_size_answers_400_not_silence() raises:
    """A bad chunk-size line must produce a NAMED 400, not a hangup.

    This is why `accumulate_chunked_body` returns a tri-state instead of a Bool:
    a client FRAMING error deserves an answer, a TRANSPORT failure has nobody to
    answer. Collapsing the two turns every malformed body into a mystery
    `remote end hung up unexpectedly`, which is precisely the message that made
    the original defect expensive to diagnose.
    """
    var server = _make_server()
    var port = server.local_port()
    var dispatcher = _BodyProbeDispatcher()

    var s = String("POST /probe HTTP/1.1\r\nHost: localhost\r\n")
    s += String("Transfer-Encoding: chunked\r\n\r\n")
    s += String("zz\r\nnope\r\n0\r\n\r\n")  # 'zz' is not a hex chunk size

    var resp = _round_trip(server, dispatcher, port, _str_bytes(s))
    assert_true(
        _contains(resp, String("HTTP/1.1 400")),
        String("malformed chunked framing did not answer 400: ")
        + _to_str(resp),
    )
    # The handler must NOT have run on a half-decoded body.
    assert_equal(dispatcher.last_len, -1)
    _ = server^


def test_content_length_post_still_works() raises:
    """The Content-Length path is UNCHANGED by the chunked arm — the new branch
    is an `elif`, and this pins that it stayed one."""
    var server = _make_server()
    var port = server.local_port()
    var dispatcher = _BodyProbeDispatcher()

    var resp = _round_trip(
        server,
        dispatcher,
        port,
        _content_length_request(String("/probe"), String("hello world")),
    )
    assert_true(
        _contains(resp, String("HTTP/1.1 200")),
        String("content-length POST answered non-200: ") + _to_str(resp),
    )
    assert_equal(dispatcher.last_len, 11)
    _ = server^


def main() raises:
    test_chunked_post_body_reaches_handler()
    test_chunked_body_larger_than_recv_buffer()
    test_malformed_chunk_size_answers_400_not_silence()
    test_content_length_post_still_works()
    print("test_chunked_request_body_dispatch: all tests passed")
