# =============================================================================
# tests/test_e2e_full_chain.mojo
# =============================================================================
#
# functional e2e.
#
# End-to-end test that exercises the full middleware chain on a live
# server: bind ephemeral port, install MiddlewareChain.default(), send
# a real HTTP/1.1 request through a raw socket, read response, assert:
#   * Response status 200 OK
#   * Response carries Access-Control-Allow-Origin header (CORS.after)
#   * LoggingMiddleware buffer has 1 entry
#
# Coverage parity with's test_e2e_bring_up.mojo (same raw-socket
# harness; adds the middleware-chain integration).
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_http import (
    HttpMethod,
    HttpServer,
    HttpServerConfig,
    LoggingMiddleware,
    MiddlewareChain,
    Router,
    TracingMiddleware,
)


# =============================================================================
# §1 — Raw-socket client helpers (same as's test_e2e_bring_up).
# =============================================================================


comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
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
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


def _create_blocking_client_socket() raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0),
    )
    if fd < Int32(0):
        raise Error("test_e2e_full_chain: socket() failed")
    return fd


def _connect_blocking(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](
        fd, addr_ptr, UInt32(16),
    )
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test_e2e_full_chain: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0),
        )
        if rc <= Int64(0):
            raise Error("test_e2e_full_chain: send() failed or returned 0")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0),
    )
    if n < Int64(0):
        raise Error("test_e2e_full_chain: recv() failed")
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    _ = external_call["close", Int32](fd)


def _build_get_request(path: String) -> List[UInt8]:
    var s = String("GET ") + String(path) + String(
        " HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )
    var bytes = s.as_bytes()
    var out = List[UInt8]()
    var n = len(bytes)
    var i = 0
    while i < n:
        out.append(bytes[i])
        i = i + 1
    return out^


def _bytes_contain(haystack: List[UInt8], needle: String) -> Bool:
    var nbytes = needle.as_bytes()
    var hn = len(haystack)
    var nn = len(nbytes)
    if nn == 0 or nn > hn:
        return nn == 0
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if haystack[i + j] != nbytes[j]:
                matched = False
                break
            j = j + 1
        if matched:
            return True
        i = i + 1
    return False


# =============================================================================
# §2 — The chained-server e2e test.
# =============================================================================


def test_full_chain_request_returns_200_with_cors_and_logging() raises:
    """Bind a server with MiddlewareChain.default() installed, send
    GET /health, assert:
      * Response status 200 OK
      * Response carries Access-Control-Allow-Origin header (CORS.after)
      * LoggingMiddleware buffer has at least 1 entry
    """
    # Build router + server.
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)
    var config = HttpServerConfig.default_ephemeral()
    var server = HttpServer(config=config, router=router^)

    # Install a MiddlewareChain.default() — adds the 4 builtins
    # (error_mapper + cors + tracing-disabled + logging).
    var chain = MiddlewareChain.default()
    # Enable tracing too so we exercise the full 4-builtin chain.
    chain = chain^.with_tracing(TracingMiddleware.new())
    server.install_middleware(chain^)
    assert_true(server.has_middleware())

    var port = server.local_port()
    assert_true(Int(port) > 0)

    # Client socket + connect.
    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)

    # Drive accept.
    var _stats1 = server.serve_for_iterations(
        max_iters=4, timeout_us=Int32(500_000),
    )

    # Send the request.
    var req = _build_get_request(String("/health"))
    _send_all(client_fd, req)

    # Drive server to process + respond.
    var stats2 = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000),
    )
    assert_true(Int(stats2.reqs_handled) >= 1)
    assert_true(Int(stats2.bytes_sent) > 0)

    # Recv response.
    var resp_bytes = _recv_some(client_fd, 1024)
    assert_true(len(resp_bytes) > 0)

    # Assert HTTP/1.1 200 status line.
    assert_true(_bytes_contain(resp_bytes, String("HTTP/1.1 200")))

    # Assert ACAO header present (CORS.after ran).
    assert_true(_bytes_contain(resp_bytes, String("access-control-allow-origin")))

    # Assert middleware state captured the request.
    ref chain_opt = server.middleware_chain_ref()
    assert_true(Bool(chain_opt))
    ref chain_ref = chain_opt.value()
    # Logging buffer has 1 entry.
    ref logging_opt = chain_ref.logging_ref()
    assert_true(Bool(logging_opt))
    ref lg = logging_opt.value()
    assert_true(lg.entries_len() >= 1)
    # Tracing buffer has 1 span.
    ref tracing_opt = chain_ref.tracing_ref()
    assert_true(Bool(tracing_opt))
    ref tr = tracing_opt.value()
    assert_true(tr.spans_len() >= 1)

    _close_socket(client_fd)
    _ = server^


def test_chain_serves_malformed_request_with_error_response() raises:
    """A malformed request (no CRLF terminator at end) is parsed-rejected
    and the chain is NOT invoked. The parser-error path still emits
    a static error response.

    This verifies that the chain integration doesn't BREAK the
    parser-error contract: malformed → 4xx, NOT chain → 500.
    """
    var router = Router()
    var config = HttpServerConfig.default_ephemeral()
    var server = HttpServer(config=config, router=router^)
    var chain = MiddlewareChain.default()
    server.install_middleware(chain^)
    var port = server.local_port()
    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)
    var _stats1 = server.serve_for_iterations(
        max_iters=4, timeout_us=Int32(500_000),
    )
    # Send GIBBERISH — definitely not HTTP/1.1.
    var s = String("THIS IS NOT HTTP\r\n\r\n")
    var bytes = s.as_bytes()
    var req = List[UInt8]()
    var i = 0
    while i < len(bytes):
        req.append(bytes[i])
        i = i + 1
    _send_all(client_fd, req)
    var _stats2 = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000),
    )
    var resp_bytes = _recv_some(client_fd, 1024)
    assert_true(len(resp_bytes) > 0)
    # 4xx status (NOT 500 — chain wasn't invoked).
    assert_true(_bytes_contain(resp_bytes, String("HTTP/1.1 4")))
    _close_socket(client_fd)
    _ = server^


def test_chain_disabled_falls_back_to_canned() raises:
    """If install_middleware was NOT called, the canned-response
    path runs (serve_read_round, not serve_read_round_chained).
    Verifies backward compatibility with the bring-up tests."""
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)
    var config = HttpServerConfig.default_ephemeral()
    var server = HttpServer(config=config, router=router^)
    assert_true(not server.has_middleware())
    var port = server.local_port()
    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)
    var _stats1 = server.serve_for_iterations(
        max_iters=4, timeout_us=Int32(500_000),
    )
    var req = _build_get_request(String("/health"))
    _send_all(client_fd, req)
    var _stats2 = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000),
    )
    var resp_bytes = _recv_some(client_fd, 256)
    assert_true(len(resp_bytes) > 0)
    # Canned response — body is "Hello, World!"
    assert_true(_bytes_contain(resp_bytes, String("HTTP/1.1 200")))
    assert_true(_bytes_contain(resp_bytes, String("Hello, World!")))
    # NO ACAO header (no CORS middleware ran).
    assert_true(not _bytes_contain(resp_bytes, String("access-control-allow-origin")))
    _close_socket(client_fd)
    _ = server^


def main() raises:
    test_chain_disabled_falls_back_to_canned()
    test_full_chain_request_returns_200_with_cors_and_logging()
    test_chain_serves_malformed_request_with_error_response()
    print("test_e2e_full_chain: OK")
