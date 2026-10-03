# =============================================================================
# src/komira_http_core/tests/test_tcp_nodelay_parity.mojo
# =============================================================================
#
# TCP_NODELAY parity regression test.
#
# hyper invokes `setsockopt(SOL_TCP, TCP_NODELAY, 1)` on the connect socket;
# `KernelTcpConnector.connect` must too (via `komira_async`'s
# `set_tcp_nodelay()` helper), or the client loses feature parity with hyper.
#
# Without it: `getsockopt(fd, IPPROTO_TCP, TCP_NODELAY)` returns 0 (default
#          Nagle enabled).
# With it: `getsockopt(fd, IPPROTO_TCP, TCP_NODELAY)` returns 1 (Nagle
#          disabled, per HTTP/1.1 client conventions).
#
# The test dials a TcpListener bound to loopback ephemeral via
# `KernelTcpConnector.connect`, then queries the TCP_NODELAY option on
# the returned IoStream's fd via getsockopt. Mirrors the
# test_kernel_tcp_loopback shape (single-threaded server + client in one
# process; Linux-only because the underlying TcpListener.bind_loopback +
# Reactor[BACKEND_EPOLL] loopback path is Linux-only).
# =============================================================================

from std.testing import assert_equal, assert_true
from std.ffi import external_call
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, Reactor
from komira_async.reactor.socket_io import errno_get
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.tcp_stream import TcpListener

from komira_http_core.transport.kernel_tcp import KernelTcpConnector


# -----------------------------------------------------------------------------
# Helper — getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, &len). Returns
# the queried int value (1 = TCP_NODELAY set, 0 = Nagle still active).
#
# Linux + Darwin both share IPPROTO_TCP=6 and TCP_NODELAY=1 for the
# optname pair. (This differs from SOL_SOCKET/SO_ERROR which DO diverge
# per OS — see socket_setup.mojo:341-351 for the rationale.) Confirmed:
# Linux uapi/linux/tcp.h #define TCP_NODELAY 1; Darwin sys/netinet/tcp.h
# #define TCP_NODELAY 0x01. IPPROTO_TCP=6 is universal (RFC 1700).
# -----------------------------------------------------------------------------


def _getsockopt_tcp_nodelay(fd: Int32) raises -> Int32:
    """getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, &len).

    Returns the current TCP_NODELAY value (0 = Nagle on, 1 = Nagle off).
    Raises if the syscall itself fails.

    SAFETY: optval/optlen stack-local; kernel writes back via the
    pointers and does not retain them past the syscall return.
    """
    if fd < Int32(0):
        raise Error("_getsockopt_tcp_nodelay: bad fd")
    var optval = Array[Int32, 1](fill=Int32(-1))
    var optlen = Array[UInt32, 1](fill=UInt32(4))
    var rc = external_call["getsockopt", Int32](
        fd,
        Int32(6),       # IPPROTO_TCP — universal (RFC 1700)
        Int32(1),       # TCP_NODELAY — universal on Linux + Darwin
        optval.unsafe_ptr(),
        optlen.unsafe_ptr(),
    )
    if rc < Int32(0):
        var e = errno_get()
        raise Error(
            "getsockopt(TCP_NODELAY) failed: rc=" + String(rc)
            + " errno=" + String(e)
        )
    return optval[0]


# =============================================================================
# Test 1 — KernelTcpConnector.connect sets TCP_NODELAY on the client fd
# =============================================================================


def test_kernel_tcp_connector_sets_tcp_nodelay() raises:
    """Regression test for.

    Pre-fix: KernelTcpConnector.connect does NOT call set_tcp_nodelay
    on the returned fd. `getsockopt(fd, IPPROTO_TCP, TCP_NODELAY)`
    returns 0 (kernel default = Nagle on). TEST FAILS.

    Post-fix: KernelTcpConnector.connect invokes set_tcp_nodelay(fd)
    after the TcpStream.connect returns. `getsockopt(fd, IPPROTO_TCP,
    TCP_NODELAY)` returns 1. TEST PASSES.

    This is feature parity with hyper (verified via strace: hyper invokes
    `setsockopt(6, SOL_TCP, TCP_NODELAY, [1], 4) = 0` at conn start).

    Linux-only (mirrors test_kernel_tcp_loopback's same-shape gate).
    """
    comptime if not CompilationTarget.is_linux():
        return

    # Set up listener on loopback ephemeral port.
    var listener = TcpListener.bind_loopback(
        port=UInt16(0), backlog=Int32(16),
    )
    var port = listener.local_port()

    # Per-test reactor (owned by this function's frame).
    var reactor = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
    )

    # Dial via the production connector path.
    var connector = KernelTcpConnector.new()
    var client_stream = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor,
        ip_be=inet_loopback_be(),
        port=port,
    )

    # Drain the listener-side accept BEFORE reading the client fd —
    # the listener side picks up the SYN; we don't need its fd for the
    # assertion, but draining keeps the kernel state clean.
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var _server_fd = Int32(Int(ar.value()))

    # Read the kernel-side TCP_NODELAY state on the connected client
    # fd. The getsockopt happens INSIDE this scope where client_stream
    # is still live (Mojo's ASAP-destruction discipline: client_stream
    # is used on the next line via `.fd()` so it stays alive across
    # the syscall — but we explicitly keep_alive via a follow-up
    # method call below to suppress any possibility of premature drop).
    var nodelay = _getsockopt_tcp_nodelay(client_stream.fd())

    # The core assertion: TCP_NODELAY must be SET (1) on the client
    # socket post-KernelTcpConnector.connect. Pre-fix this is 0
    # (Nagle on, default kernel state); post-fix this is 1 (Nagle
    # disabled — feature parity with hyper).
    assert_equal(
        Int(nodelay), 1,
        "TCP_NODELAY must be set on KernelTcpConnector-produced fd",
    )

    # Keep-alive: re-read the fd via the stream's accessor AFTER the
    # syscall to ensure the compiler does not drop client_stream
    # mid-test. Method-based access keeps the value alive past its last
    # syntactic use, which guards against premature destruction.
    var fd_after = client_stream.fd()
    assert_true(fd_after >= Int32(0), "client fd should still be valid")


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    test_kernel_tcp_connector_sets_tcp_nodelay()
    print("  test_kernel_tcp_connector_sets_tcp_nodelay OK")
    print(
        "PASS komira_http.client test_tcp_nodelay_parity"
    )
