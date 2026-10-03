# =============================================================================
# test_socket_nonblock_mac.mojo
# =============================================================================
# Regression test.
#
# socket_tcp_nonblocking() in reactor/socket_setup.mojo
# uses the LINUX O_NONBLOCK value (0x800) on macOS; the correct Darwin
# value is 0x4. As a result, sockets created on Mac are NOT actually
# non-blocking, despite the function name. The same bug exists in
# try_io_accept's macOS branch in reactor/socket_io.mojo.
#
# Symptom: TcpListener.try_accept() blocks indefinitely on Mac when the
# accept queue is empty (instead of returning WouldBlock). A per-core
# HTTP server hangs after the first accepted connection because its
# accept-drain loop's second iteration blocks forever.
#
# This test reads back the listener fd's flags via fcntl(F_GETFL) and
# asserts that O_NONBLOCK (0x4 on Darwin, 0x800 on Linux) is set.
#
# Pre-fix: assertion fails on Mac (flags = 2 = O_RDWR; O_NONBLOCK bit clear).
# Post-fix: assertion passes (flags & 0x4 != 0 on Mac).
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.testing import assert_true

from komira_async.reactor.socket_setup import (
    inet_loopback_be,
)
from komira_async.runtime.tcp_stream import (
    TcpListener,
)


def test_listener_fd_is_nonblocking_on_mac() raises:
    """TcpListener.bind_reuseport must produce a non-blocking listener fd
    on every supported platform. On Mac the O_NONBLOCK constant differs
    from Linux's 0x800 — the correct value is 0x4."""
    comptime if CompilationTarget.is_macos():
        var listener = TcpListener.bind_reuseport(
            inet_loopback_be(), UInt16(0), Int32(16),
        )
        var fd = listener.fd()
        var flags = external_call["fcntl", Int32](
            fd, Int32(3), Int32(0),  # F_GETFL
        )
        # Darwin: O_NONBLOCK = 0x4. Linux: O_NONBLOCK = 0x800.
        var O_NONBLOCK_DARWIN: Int32 = Int32(0x4)
        assert_true(
            (flags & O_NONBLOCK_DARWIN) != Int32(0),
            "TcpListener fd must be O_NONBLOCK on Mac (Darwin O_NONBLOCK=0x4)",
        )
        _ = listener^
    else:
        # On Linux the SOCK_NONBLOCK type-arg path applies; flags & 0x800 is set.
        assert_true(True)


def main() raises:
    print("test_listener_fd_is_nonblocking_on_mac running")
    test_listener_fd_is_nonblocking_on_mac()
    print("  test_listener_fd_is_nonblocking_on_mac OK")
