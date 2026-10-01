# =============================================================================
# tests/test_e2e_bring_up.mojo
# =============================================================================
#
# functional bring-up test.
# Drives the round trip: server binds an ephemeral port, a
# raw-socket client sends an HTTP/1.1 GET request, server responds, and
# the test asserts on the 200 status line.
#
# Same-process design (no subprocess `curl`):
#   * Server uses the `HttpServer.serve_for_iterations` bounded
#     accept loop (it would otherwise block forever).
#   * Client uses raw libc socket + connect + write/read in the same
#     test process. The accept loop runs INLINE between client send
#     and client read so the test is a sequential script:
#         1. Bind server
#         2. Client socket() + connect() to server's port
#         3. Client send() raw "GET /health HTTP/1.1\r\n\r\n"
#         4. Drive the server's accept loop for a few iterations
#         5. Client recv() into a small buffer
#         6. Assert the bytes start with "HTTP/1.1 200 "
#
# Why same-process: subprocess `curl` would be a test infrastructure
# dependency (assumes curl in $PATH; assumes test runner can fork +
# manage subprocess); both are fragile. The same-process flow exercises
# the same code paths (bind / accept / recv / send / close) and is
# strictly more reproducible.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_http import (
    HttpMethod,
    HttpServer,
    HttpServerConfig,
    Router,
)


# =============================================================================
# §1 — Same-process raw-socket client helpers.
# =============================================================================
# We need a tiny client to write a request + read the response. Mojo
# 1.0.0b1's TcpStream is async/state-machine-driven for the server side;
# a synchronous blocking client over libc is the simplest test fixture.

comptime _AF_INET: Int32 = 2

# SOCK_STREAM is 1 on Linux and 1 on macOS — same value across both.
comptime _SOCK_STREAM: Int32 = 1


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    """Build a sockaddr_in for 127.0.0.1:port. Layout:
       u16 sin_family    (=AF_INET=2)
       u16 sin_port      (network byte order)
       u32 sin_addr      (network byte order; 127.0.0.1 = 0x7F000001 BE)
       u8[8] sin_zero
    On macOS, the leading byte is `sin_len`; we set it = 16 conservatively
    (kernel ignores sin_len if family is set correctly, but Apple docs
    say to fill it).
    """
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)             # sin_len
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    # sin_port (network byte order = big-endian).
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    # sin_addr 127.0.0.1 = 7F 00 00 01.
    addr[4] = UInt8(127)
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


def _create_blocking_client_socket() raises -> Int32:
    """Create a regular blocking TCP socket via libc socket(2)."""
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0),
    )
    if fd < Int32(0):
        raise Error("test_e2e: socket() failed")
    return fd


def _connect_blocking(fd: Int32, port: UInt16) raises:
    """connect() the socket to 127.0.0.1:port. Blocking until the
    kernel accepts the SYN."""
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](
        fd, addr_ptr, UInt32(16),
    )
    if rc < Int32(0):
        # Close fd before raising so we don't leak on failure.
        _ = external_call["close", Int32](fd)
        raise Error("test_e2e: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    """send() loop until all bytes are written. Blocking socket."""
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0),
        )
        if rc <= Int64(0):
            raise Error("test_e2e: send() failed or returned 0")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    """One recv() call — returns up to `max_bytes` bytes."""
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0),
    )
    if n < Int64(0):
        raise Error("test_e2e: recv() failed")
    # Truncate to actual bytes.
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    """close(fd); best-effort."""
    _ = external_call["close", Int32](fd)


def _build_get_request() -> List[UInt8]:
    """Build the bytes for `GET /health HTTP/1.1\\r\\nHost: localhost\\r\\n\\r\\n`."""
    var s = String("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var bytes = s.as_bytes()
    var out = List[UInt8]()
    var n = len(bytes)
    var i = 0
    while i < n:
        out.append(bytes[i])
        i = i + 1
    return out^


# =============================================================================
# §2 — The bring-up test.
# =============================================================================


def test_bind_health_round_trip() raises:
    """End-to-end: bind server, client connects, sends a request, reads
    the response, asserts 200.

    This is the bring-up round-trip test.

    The orchestration interleaves client steps with bounded
    `serve_for_iterations` poll cycles. Each iteration drives ONE
    `poll_completions` cycle; the timeout per iteration is small (~50ms)
    so a stuck-client doesn't hang the test forever — total worst case
    `~max_iters × timeout`.
    """
    # ---- Step 1. Build router + server.
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)
    var config = HttpServerConfig.default_ephemeral()
    var server = HttpServer(config=config, router=router^)
    var port = server.local_port()
    assert_true(Int(port) > 0)

    # ---- Step 2. Client socket + connect.
    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)

    # ---- Step 3. Drive the server's accept loop to pick up the new
    #         conn. On Mac kqueue + Linux epoll the listener-fd event
    #         fires on the next poll cycle after connect SYN-ACK.
    var stats1 = server.serve_for_iterations(
        max_iters=4, timeout_us=Int32(500_000),
    )
    # After accept, no requests handled yet — but the accept itself
    # has been processed (we'd see this in self._conns.len() if we
    # exposed it via a diagnostic accessor; may add one).
    _ = stats1

    # ---- Step 4. Client sends the request.
    var req = _build_get_request()
    _send_all(client_fd, req)

    # ---- Step 5. Drive the server again so it picks up the request +
    #         writes the response. Generous iter count + timeout so the
    #         kernel data-delivery race doesn't flake the test.
    var stats2 = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000),
    )
    # After serve, at least one request has been handled.
    assert_true(Int(stats2.reqs_handled) >= 1)
    assert_true(Int(stats2.bytes_sent) > 0)

    # ---- Step 6. Client recvs the response. Single recv up to 256
    #         bytes is enough for the 92-byte canned response.
    var resp_bytes = _recv_some(client_fd, 256)
    assert_true(len(resp_bytes) > 0)

    # ---- Step 7. Assert the response starts with "HTTP/1.1 200 ".
    var prefix = String("HTTP/1.1 200 ")
    var prefix_bytes = prefix.as_bytes()
    var pn = len(prefix_bytes)
    assert_true(len(resp_bytes) >= pn)
    var i = 0
    while i < pn:
        assert_equal(Int(resp_bytes[i]), Int(prefix_bytes[i]))
        i = i + 1

    # ---- Cleanup.
    _close_socket(client_fd)
    _ = server^


def test_server_construct_ephemeral_port() raises:
    """Smoke: HttpServer can be constructed with default_ephemeral() and
    local_port() returns a kernel-assigned port. No client interaction."""
    var router = Router()
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
    )
    var port = server.local_port()
    assert_true(Int(port) > 0)
    assert_true(Int(port) < 65536)
    _ = server^


def test_server_construct_with_router() raises:
    """Smoke: HttpServer takes ownership of a Router that has routes
    registered, and `server.router()` borrows it back."""
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)
    router.add(HttpMethod.post(), "/api/orders/:id", 1)
    assert_equal(router.len(), 2)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
    )
    # The router moved into the server; borrow it back via the
    # diagnostic accessor.
    assert_equal(server.router().len(), 2)
    _ = server^


def main() raises:
    test_server_construct_ephemeral_port()
    test_server_construct_with_router()
    test_bind_health_round_trip()
    print("PASS komira_http functional bring-up")
