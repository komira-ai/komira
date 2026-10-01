# =============================================================================
# tests/test_e2e_bind_any_addr.mojo
# =============================================================================
#
# Loopback-bind regression test.
#
# THE BUG: HttpServer hardcoded a 127.0.0.1 (loopback) bind, so a server
# running inside a k8s pod was unreachable from the kubelet readiness
# probe and from any Service/NodePort (a 127.0.0.1-bound listener is only
# reachable from inside the pod's own netns). On the macbook this was
# invisible (server + client both on localhost).
#
# THE FIX: HttpServerConfig gained a `bind_addr_be` field (default
# loopback, preserving all existing behavior); `inet_any_be()` (0.0.0.0)
# was added to socket_setup. A deployed server binds 0.0.0.0.
#
# WHAT THIS TEST PROVES: a server constructed with
# `bind_addr_be = inet_any_be()` (0.0.0.0) STILL accepts a loopback
# client connection — i.e. binding all interfaces is a strict superset of
# binding loopback, so the all-interfaces bind does not break local serving. A
# 0.0.0.0 listener serving a 127.0.0.1 client is exactly the path the
# kubelet probe (localhost inside the pod) AND an external Service both
# rely on.
#
# Same-process raw-socket client (no subprocess curl), mirroring
# test_e2e_bring_up.mojo: the client connects to 127.0.0.1:<port> and the
# server's accept loop is driven inline.
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
from komira_async.reactor.socket_setup import inet_any_be, inet_loopback_be


# =============================================================================
# §1 — Same-process raw-socket client helpers (blocking libc client).
# =============================================================================

comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    """Build a sockaddr_in for 127.0.0.1:port. The client always connects
    via loopback — the point of the test is that a 0.0.0.0-bound server
    still serves it."""
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)             # sin_len
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    # sin_addr 127.0.0.1 = 7F 00 00 01.
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
        raise Error("test_bind_any: socket() failed")
    return fd


def _connect_blocking(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](
        fd, addr_ptr, UInt32(16),
    )
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test_bind_any: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0),
        )
        if rc <= Int64(0):
            raise Error("test_bind_any: send() failed or returned 0")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0),
    )
    if n < Int64(0):
        raise Error("test_bind_any: recv() failed")
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    _ = external_call["close", Int32](fd)


def _build_get_request() -> List[UInt8]:
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
# §2 — Config-carries-the-bind-address assertion (fails-before the field).
# =============================================================================


def test_config_carries_bind_addr() raises:
    """The config field exists and round-trips both bind addresses.

    Pre-fix this test does not compile (HttpServerConfig had no
    `bind_addr_be` field). Post-fix it asserts the default is loopback
    (preserving existing behavior) and that 0.0.0.0 (INADDR_ANY) is the
    network-byte-order zero word + distinct from loopback."""
    # inet_any_be() is 0.0.0.0 == 0 in network byte order; loopback is not.
    assert_equal(Int(inet_any_be()), 0)
    assert_true(Int(inet_loopback_be()) != 0)

    # default_ephemeral preserves the existing loopback bind.
    var cfg = HttpServerConfig.default_ephemeral()
    assert_equal(Int(cfg.bind_addr_be), Int(inet_loopback_be()))

    # Flipping to 0.0.0.0 carries through the value-typed config.
    cfg.bind_addr_be = inet_any_be()
    assert_equal(Int(cfg.bind_addr_be), 0)

    # with_port inherits the loopback default too.
    var cfg2 = HttpServerConfig.with_port(UInt16(0))
    assert_equal(Int(cfg2.bind_addr_be), Int(inet_loopback_be()))

    # with_port_bind_any (the deploy serve-path factory — Cloud Run / k8s)
    # binds INADDR_ANY (0.0.0.0) so the listener is reachable by a Cloud Run
    # startup probe / a k8s Service. A serve path bound to loopback gets
    # ERROR_CONNECTION_FAILED from the Cloud Run /health probe. The port is carried through; the bind is 0.0.0.0.
    var cfg3 = HttpServerConfig.with_port_bind_any(UInt16(8081))
    assert_equal(Int(cfg3.port), 8081)
    assert_equal(Int(cfg3.bind_addr_be), 0)
    assert_equal(Int(cfg3.bind_addr_be), Int(inet_any_be()))


# =============================================================================
# §3 — 0.0.0.0-bound server still serves a loopback client (the fix).
# =============================================================================


def test_bind_any_serves_loopback_client() raises:
    """A server bound to INADDR_ANY (0.0.0.0) accepts a 127.0.0.1 client.

    This proves the all-interfaces bind is safe: binding all interfaces is a strict
    superset of binding loopback, so the path the kubelet readiness probe
    uses (localhost from inside the pod) keeps working while the Service
    path (external interface) is also reachable."""
    var router = Router()
    router.add(HttpMethod.get(), "/health", 0)

    var config = HttpServerConfig.default_ephemeral()
    config.bind_addr_be = inet_any_be()      # 0.0.0.0 — the deployed shape
    var server = HttpServer(config=config, router=router^)
    var port = server.local_port()
    assert_true(Int(port) > 0)

    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)

    var stats1 = server.serve_for_iterations(
        max_iters=4, timeout_us=Int32(500_000),
    )
    _ = stats1

    var req = _build_get_request()
    _send_all(client_fd, req)

    var stats2 = server.serve_for_iterations(
        max_iters=8, timeout_us=Int32(50_000),
    )
    assert_true(Int(stats2.reqs_handled) >= 1)
    assert_true(Int(stats2.bytes_sent) > 0)

    var resp_bytes = _recv_some(client_fd, 256)
    assert_true(len(resp_bytes) > 0)

    var prefix = String("HTTP/1.1 200 ")
    var prefix_bytes = prefix.as_bytes()
    var pn = len(prefix_bytes)
    assert_true(len(resp_bytes) >= pn)
    var i = 0
    while i < pn:
        assert_equal(Int(resp_bytes[i]), Int(prefix_bytes[i]))
        i = i + 1

    _close_socket(client_fd)
    _ = server^


def main() raises:
    test_config_carries_bind_addr()
    test_bind_any_serves_loopback_client()
    print("PASS komira_http functional bind-any-addr")
