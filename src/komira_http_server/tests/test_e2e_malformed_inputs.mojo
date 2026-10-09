# =============================================================================
# tests/test_e2e_malformed_inputs.mojo
# =============================================================================
#
# functional malformed-input tests
# (functional malformed-input
# tests via raw socket).
#
# Pattern mirrors test_e2e_bring_up.mojo: bind an HttpServer to an
# ephemeral port, open a libc TCP socket from the same process, send
# raw malformed HTTP/1.1 bytes, drive the server, then recv() the
# response and assert the status line.
#
# Each case sends a deliberately-malformed request and asserts the
# parser hardening fires on the wire — i.e. the server emits a 400 /
# 413 / 431 / 505 status line and closes (the static error response
# includes Connection: close).
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_http_server.server import HttpServer, HttpServerConfig
from komira_http_server.routing import Router


# =============================================================================
# §1 — Same-process raw-socket client helpers (mirror test_e2e_bring_up).
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
        raise Error("test_e2e_malformed: socket() failed")
    return fd


def _connect_blocking(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](
        fd, addr_ptr, UInt32(16),
    )
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test_e2e_malformed: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0),
        )
        if rc <= Int64(0):
            raise Error("test_e2e_malformed: send() failed")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0),
    )
    if n < Int64(0):
        raise Error("test_e2e_malformed: recv() failed")
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    _ = external_call["close", Int32](fd)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


# =============================================================================
# §2 — One-shot helper: send req, drive server, return response bytes.
# =============================================================================


def _send_and_recv(
    request_bytes: List[UInt8],
) raises -> List[UInt8]:
    """Bind a fresh server, send `request_bytes`, return the server's
    response bytes (up to 512 bytes).

    Each call uses a fresh ephemeral port + fresh server to keep tests
    isolated. The server is dropped before return so its listener fd
    closes.
    """
    var router = Router()
    var config = HttpServerConfig.default_ephemeral()
    var server = HttpServer(config=config, router=router^)
    var port = server.local_port()
    assert_true(Int(port) > 0)

    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)

    # Drive once to register the accept event.
    var _s1 = server.serve_for_iterations(
        max_iters=4, timeout_us=Int32(500_000),
    )

    _send_all(client_fd, request_bytes)

    # Drive more iterations so the server reads the request, parses,
    # writes the error response, and closes.
    var _s2 = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000),
    )

    var resp_bytes = _recv_some(client_fd, 512)
    _close_socket(client_fd)
    _ = server^
    return resp_bytes^


def _bytes_to_string(b: List[UInt8]) -> String:
    var s = String()
    var i = 0
    while i < len(b):
        s = s + chr(Int(b[i]))
        i = i + 1
    return s^


def _assert_status_line(resp: List[UInt8], expected_status_line: String) raises:
    """Assert the response starts with `expected_status_line`."""
    var prefix_bytes = expected_status_line.as_bytes()
    var pn = len(prefix_bytes)
    assert_true(len(resp) >= pn)
    var i = 0
    while i < pn:
        assert_equal(Int(resp[i]), Int(prefix_bytes[i]))
        i = i + 1


# =============================================================================
# §3 — Functional malformed-input cases.
# =============================================================================


def test_e2e_lowercase_method_501() raises:
    """Lowercase method → 501 Not Implemented on the wire: methods are
    case-sensitive, so "post" is an unrecognized method (RFC 9110 §9.1)."""
    var resp = _send_and_recv(_bytes(String("post / HTTP/1.1\r\n\r\n")))
    _assert_status_line(resp, String("HTTP/1.1 501 Not Implemented"))


def test_e2e_unknown_method_501() raises:
    """Unknown method → 501 Not Implemented on the wire (RFC 9110 §9.1)."""
    var resp = _send_and_recv(_bytes(String("FOOBAR / HTTP/1.1\r\n\r\n")))
    _assert_status_line(resp, String("HTTP/1.1 501 Not Implemented"))


def test_e2e_http_2_unsupported_505() raises:
    """HTTP/2.0 → 505 HTTP Version Not Supported on the wire."""
    var resp = _send_and_recv(_bytes(String("GET / HTTP/2.0\r\n\r\n")))
    _assert_status_line(
        resp, String("HTTP/1.1 505 HTTP Version Not Supported"),
    )


def test_e2e_te_and_cl_smuggling_400() raises:
    """Transfer-Encoding: chunked + Content-Length: 5 → 400."""
    var resp = _send_and_recv(_bytes(String(
        "POST / HTTP/1.1\r\n"
        "Content-Length: 5\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
    )))
    _assert_status_line(resp, String("HTTP/1.1 400 Bad Request"))


def test_e2e_expect_unsupported_417() raises:
    """Expect: 200-ok → 417 Expectation Failed."""
    var resp = _send_and_recv(_bytes(String(
        "POST / HTTP/1.1\r\nExpect: 200-ok\r\n\r\n"
    )))
    _assert_status_line(resp, String("HTTP/1.1 417 Expectation Failed"))


def test_e2e_error_response_no_client_input() raises:
    """The error response body MUST NOT echo any client input. Smuggle
    a 'pwn-me' marker in a header and verify the response doesn't
    contain it."""
    var resp = _send_and_recv(_bytes(String(
        "post / HTTP/1.1\r\nX-Pwn-Me: leakthis\r\n\r\n"
    )))
    _assert_status_line(resp, String("HTTP/1.1 501 Not Implemented"))
    # Inspect the full response — 'leakthis' MUST NOT appear.
    var s = _bytes_to_string(resp)
    var needle = String("leakthis")
    var nbytes = needle.as_bytes()
    var nn = len(nbytes)
    var sb = s.as_bytes()
    var sn = len(sb)
    var i = 0
    var found = False
    while i + nn <= sn:
        var ok = True
        var k = 0
        while k < nn:
            if sb[i + k] != nbytes[k]:
                ok = False
                break
            k = k + 1
        if ok:
            found = True
            break
        i = i + 1
    # found MUST be False — server emitted only static bytes.
    assert_true(not found)


def test_e2e_happy_request_still_works() raises:
    """Regression guard: a well-formed request still gets a 200
    response after wiring. e2e is also a regression check; this
    is an extra sanity assertion in the test file itself."""
    var resp = _send_and_recv(_bytes(String(
        "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )))
    _assert_status_line(resp, String("HTTP/1.1 200 "))


def main() raises:
    test_e2e_lowercase_method_501()
    test_e2e_unknown_method_501()
    test_e2e_http_2_unsupported_505()
    test_e2e_te_and_cl_smuggling_400()
    test_e2e_expect_unsupported_417()
    test_e2e_error_response_no_client_input()
    test_e2e_happy_request_still_works()
    print("PASS komira_http functional malformed-inputs")
