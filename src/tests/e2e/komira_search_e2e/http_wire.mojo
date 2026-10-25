# =============================================================================
# http_wire.mojo -- the search front door over a real loopback socket
# =============================================================================
#
# The fixture the HTTP legs share. It mounts a `SearchHttpDispatcher` over a
# `LocalFsConditionalStore` behind a real `komira_http_server` `HttpServer` on
# 127.0.0.1 port 0, and talks to it with raw HTTP/1.1 bytes written to a real
# TCP socket.
#
# The server/client pattern is `komira_http_tls_e2e`'s: `DispatchServeLoop`
# steps the server (`serve_one_iteration_dispatch`) on one thread while a
# `ClientLeg` runs on another, and `serve_while` joins them. Here the leg is
# `WireLeg`: it sends each request of a script on a fresh connection, in order,
# and reads each reply to its `Content-Length`.
#
# Bounded: the client socket has a 10 s receive timeout and the whole script a
# 60 s deadline, so a server that stops answering fails the leg with a named
# error; the duet's own deadline fails a leg that never finishes. Nothing sleeps.
# No environment variable is read; the only path is the one the caller passes.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget

from komira_async.reactor.socket_io import errno_get, msg_nosignal, set_nosigpipe
from komira_clock import now_ns
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_objectstore import LocalFsConditionalStore
from komira_search_http import SearchHttpConfig, SearchHttpDispatcher

from komira_http_tls_e2e import ClientLeg, DispatchServeLoop, serve_while

comptime SearchStore = LocalFsConditionalStore
comptime FrontDoor = SearchHttpDispatcher[LocalFsConditionalStore]

comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1
comptime _SOL_SOCKET: Int32 = Int32(0xFFFF) if CompilationTarget.is_macos() else Int32(1)
comptime _SO_RCVTIMEO: Int32 = Int32(0x1006) if CompilationTarget.is_macos() else Int32(20)
comptime _RECV_TIMEOUT_SECONDS = 10
comptime _EINTR: Int32 = 4
# A reply larger than this is a server bug here, not something to buffer.
comptime _MAX_REPLY_BYTES = 8 * 1024 * 1024
comptime _SCRIPT_DEADLINE_NS: UInt64 = 60_000_000_000


struct WireReply(Copyable, Movable):
    """One parsed reply: the status code, the header block (lowercased, one
    `name: value` per line) and the body text."""

    var status: Int
    var head: String
    var body: String

    def __init__(out self, status: Int, var head: String, var body: String):
        self.status = status
        self.head = head^
        self.body = body^

    def __init__(out self, *, copy: Self):
        self.status = copy.status
        self.head = copy.head.copy()
        self.body = copy.body.copy()


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def request_bytes(method: String, target: String, body: String) -> List[UInt8]:
    """A raw HTTP/1.1 request: request line, `Host`, `Content-Type` and an exact
    `Content-Length` (the NDJSON trailing newline is counted), then the body."""
    var head = (
        method
        + String(" ")
        + target
        + String(" HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ")
        + String(len(body.as_bytes()))
        + String("\r\n\r\n")
    )
    return bytes_of(head + body)


def post(target: String, body: String) -> List[UInt8]:
    return request_bytes(String("POST"), target, body)


def new_front_door(
    root: String,
    node_id: String,
    epoch_us: Int,
    max_body_bytes: Int = 1024 * 1024,
    max_bulk_lines: Int = 100_000,
) raises -> FrontDoor:
    """A dispatcher over the directory `root`. A second one built over the same
    `root` is what a restarted process would build: a new store handle, a new
    epoch, nothing carried in memory."""
    var cfg = SearchHttpConfig(
        String("catalog"),
        String("data"),
        String("body"),
        node_id,
        max_body_bytes,
        1024,
        max_bulk_lines,
    )
    return FrontDoor(cfg^, SearchStore(root), 0, Int64(epoch_us))


def _sockaddr_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    return addr^


def _close(fd: Int32):
    _ = external_call["close", Int32](fd)


def _connect(port: UInt16) raises -> Int32:
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < Int32(0):
        raise Error("http_wire: socket() failed")
    # A refusal can make the server close before it reads the whole request;
    # the write then fails with EPIPE rather than killing the process (Linux
    # uses MSG_NOSIGNAL per send, macOS SO_NOSIGPIPE on the fd).
    _ = set_nosigpipe(fd)
    var addr = _sockaddr_loopback(port)
    # SAFETY: `addr` is a 16-byte local that outlives the call; connect() reads
    # at most the 16 bytes passed as the length.
    # FFI-BOUNDARY: the fd is owned by the caller (`WireLeg.run`), which closes
    # it in a `finally`; every failure path here closes it before raising.
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    if external_call["connect", Int32](fd, addr_ptr, UInt32(16)) < Int32(0):
        _close(fd)
        raise Error("http_wire: connect() to the loopback server failed")
    # struct timeval: tv_sec then tv_usec, two little-endian 8-byte words.
    var tv = Array[UInt8, 16](fill=UInt8(0))
    tv[0] = UInt8(_RECV_TIMEOUT_SECONDS)
    # SAFETY: `tv` is a 16-byte local that outlives the call; the kernel reads
    # exactly the 16 bytes passed as the length.
    var tv_ptr = UnsafePointer(to=tv).bitcast[UInt8]()
    if external_call["setsockopt", Int32](
        fd, _SOL_SOCKET, _SO_RCVTIMEO, tv_ptr, UInt32(16)
    ) < Int32(0):
        _close(fd)
        raise Error("http_wire: setsockopt(SO_RCVTIMEO) failed")
    return fd


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    # SAFETY: `bytes` is borrowed for the whole function and `sent < total`, so
    # `raw + sent` and the length stay inside its allocation; send() only reads.
    # FFI-BOUNDARY: `fd` stays owned by the caller, which closes it.
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), msg_nosignal()
        )
        if rc < Int64(0) and errno_get() == _EINTR:
            continue
        if rc <= Int64(0):
            raise Error("http_wire: send() failed")
        sent += Int(rc)


def _header_end(buf: List[UInt8]) -> Int:
    """The index just past the first CRLFCRLF, or -1."""
    var i = 0
    while i + 3 < len(buf):
        if (
            buf[i] == UInt8(13)
            and buf[i + 1] == UInt8(10)
            and buf[i + 2] == UInt8(13)
            and buf[i + 3] == UInt8(10)
        ):
            return i + 4
        i += 1
    return -1


def _text(buf: List[UInt8], start: Int, end: Int) -> String:
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(buf[i])
    return String(unsafe_from_utf8=Span(out))


def _lower(s: String) -> String:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(65) and c <= UInt8(90):
            c += UInt8(32)
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _content_length(head: String) raises -> Int:
    var at = head.find(String("\ncontent-length:"))
    if at < 0:
        raise Error("http_wire: reply has no Content-Length: " + head)
    var b = head.as_bytes()
    var i = at + len(String("\ncontent-length:").as_bytes())
    while i < len(b) and b[i] == UInt8(32):
        i += 1
    var n = 0
    var digits = 0
    while i < len(b) and b[i] >= UInt8(48) and b[i] <= UInt8(57):
        n = n * 10 + Int(b[i]) - 48
        digits += 1
        i += 1
        if digits > 9:
            raise Error("http_wire: Content-Length has too many digits: " + head)
    if digits == 0:
        raise Error("http_wire: malformed Content-Length: " + head)
    if n > _MAX_REPLY_BYTES:
        raise Error("http_wire: Content-Length over the reply cap: " + head)
    return n


def _read_reply(fd: Int32, give_up_ns: UInt64) raises -> WireReply:
    var acc = List[UInt8]()
    var chunk = List[UInt8]()
    chunk.resize(unsafe_uninit_length=16384)
    var head_end = -1
    var head = String()
    var want = -1
    while True:
        if now_ns() >= give_up_ns:
            raise Error("http_wire: the script deadline passed mid-reply")
        if head_end >= 0 and len(acc) - head_end >= want:
            break
        # SAFETY: `chunk` holds 16384 bytes and outlives the call; recv() writes
        # at most the 16384 requested. FFI-BOUNDARY: `fd` is owned by the caller.
        var n = external_call["recv", Int64](
            fd, chunk.unsafe_ptr(), UInt64(16384), Int32(0)
        )
        if n < Int64(0) and errno_get() == _EINTR:
            continue
        if n < Int64(0):
            raise Error(
                "http_wire: recv() timed out or failed after "
                + String(len(acc))
                + " reply bytes"
            )
        if n == Int64(0):
            raise Error(
                "http_wire: the server closed after "
                + String(len(acc))
                + " reply bytes, before the full reply"
            )
        for i in range(Int(n)):
            acc.append(chunk[i])
        if head_end < 0:
            head_end = _header_end(acc)
            if head_end >= 0:
                head = _lower(_text(acc, 0, head_end))
                want = _content_length(head)
    # "HTTP/1.1 200 OK": the code is the second token of the status line.
    var hb = head.as_bytes()
    var sp = 0
    while sp < len(hb) and hb[sp] != UInt8(32):
        sp += 1
    var code = 0
    sp += 1
    while sp < len(hb) and hb[sp] >= UInt8(48) and hb[sp] <= UInt8(57):
        code = code * 10 + Int(hb[sp]) - 48
        sp += 1
    if len(acc) != head_end + want:
        raise Error(
            "http_wire: "
            + String(len(acc) - head_end - want)
            + " bytes followed the reply body"
        )
    return WireReply(code, head^, _text(acc, head_end, head_end + want))


struct WireLeg(ClientLeg):
    """Sends `script` on one fresh connection per request, in order, and keeps
    the replies."""

    var port: UInt16
    var script: List[List[UInt8]]
    var replies: List[WireReply]

    def __init__(out self, port: UInt16, var script: List[List[UInt8]]):
        self.port = port
        self.script = script^
        self.replies = List[WireReply]()

    def run(mut self) raises:
        var give_up = now_ns() + _SCRIPT_DEADLINE_NS
        for i in range(len(self.script)):
            var fd = _connect(self.port)
            try:
                _send_all(fd, self.script[i])
                self.replies.append(_read_reply(fd, give_up))
            finally:
                _close(fd)


def exchange(
    var dispatcher: FrontDoor, var script: List[List[UInt8]]
) raises -> List[WireReply]:
    """Mount `dispatcher` behind a loopback `HttpServer` on port 0, send
    `script` over real sockets, and return one reply per request."""
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=Router()
    )
    var port = server.local_port()
    var loop = DispatchServeLoop(server^, dispatcher^)
    var leg = WireLeg(port, script^)
    serve_while(loop, leg)
    return leg.replies.copy()
