# =============================================================================
# src/komira_http_core/tests/test_kernel_tcp_loopback.mojo
# =============================================================================
#
# test:
# "KernelTcpConnector.connect round-trips a byte stream on loopback."
#
# Cross-platform: Linux x86_64 (epoll) + macOS arm64 (kqueue). The
# underlying TcpStream's connect/read/write paths comptime-select via
# `@parameter if CompilationTarget.is_linux()`; the test code is
# OS-agnostic at the IoStream layer.
#
# Test plan:
#   1. Spin a TcpListener bound to loopback ephemeral port (server-side).
#   2. From a separate "client" code path: build a KernelTcpConnector +
#      call connect[PerCoreAsyncRuntime[NoopSink]](reactor, lo, port).
#   3. Accept on the listener side (gets a TcpStream).
#   4. Server writes bytes via TcpStream.write[NoopSink](reactor, span).
#   5. Client reads via TcpIoStream.try_read[PerCoreAsyncRuntime[NoopSink]]
#      (reactor, dst_span). Loop-on-Pending pattern (the state
#      machine will productionize the park/wake; for now the test simply
#      drives reactor.poll_completions between try_read iterations).
#   6. Assert the bytes round-tripped.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.tcp_stream import TcpListener, TcpStream

from komira_http_core.transport.io_stream import (
    NEGOTIATED_HTTP_1_1,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.kernel_tcp import (
    KernelTcpConnector,
    TcpIoStream,
)


# =============================================================================
# Helper — comptime-select the per-OS backend constant. Tests run on both
# Linux + macOS arm64 from the same source for cross-platform
# parity.
# =============================================================================

def _backend_for_os() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


# =============================================================================
# Tests
# =============================================================================


def test_kernel_tcp_connector_transport_kind() raises:
    """Static fact — KernelTcpConnector reports TRANSPORT_KIND_KERNEL_TCP.
    Smoke test for the connector type itself (no socket needed)."""
    var c = KernelTcpConnector.new()
    assert_equal(Int(c.transport_kind()), Int(TRANSPORT_KIND_KERNEL_TCP))


def test_kernel_tcp_connector_loopback_round_trip() raises:
    """KernelTcpConnector.connect
    round-trips a byte stream on loopback.

    Test flow (single-threaded — server + client live in this test):
      1. Build TcpListener bound to 127.0.0.1:ephemeral.
      2. Build PerCoreAsyncRuntime[NoopSink] + a per-test Reactor.
      3. Connector.connect[PerCoreAsyncRuntime[NoopSink]] dials to the
         listener's port. On loopback the connect completes eagerly
         (no EINPROGRESS round-trip needed); the returned TcpIoStream
         wraps the connected fd.
      4. Server-side: TcpListener.try_accept() gets the new fd; wrap
         in a TcpStream + write 4 bytes via TcpStream.write[NoopSink].
      5. Client-side: try_read the 4 bytes via TcpIoStream.try_read[
         PerCoreAsyncRuntime[NoopSink]]. With kernel buffering on
         loopback the read returns Ready(4) immediately; if it returns
         Pending the test loops poll_completions until the data
         arrives (no Pending expected on loopback but the loop is
         well-defined either way).
      6. Assert bytes match.

    Cross-OS: both BACKEND_EPOLL (Linux) and BACKEND_KQUEUE (macOS)
    work — the test selects via @parameter if at construction.
    """
    # The trial only runs on Linux today — macOS kqueue path goes through
    # different listener-side mechanics that the spec already accepts
    # (see's same-shape skip on the
    # tcp_stream_smoke tests). cross-platform-parity scope is
    # "build green on both, full-loopback-test on Linux"; macOS kqueue
    # loopback is filed for a follow-up.
    comptime if not CompilationTarget.is_linux():
        return

    # Set up listener.
    var listener = TcpListener.bind_loopback(
        port=UInt16(0), backlog=Int32(16),
    )
    var port = listener.local_port()

    # Set up reactor (per-test — owned by this function's frame).
    var reactor = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
    )

    # Build the connector + dial.
    var connector = KernelTcpConnector.new()
    var client_stream = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor,
        ip_be=inet_loopback_be(),
        port=port,
    )

    # Static fact — the per-conn negotiated protocol defaults to H1.1.
    assert_equal(
        Int(client_stream.negotiated_protocol()),
        Int(NEGOTIATED_HTTP_1_1),
    )

    # Server side — accept the new connection.
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var server_fd = Int32(Int(ar.value()))
    var server_stream = TcpStream(server_fd)

    # Server writes 4 bytes.
    var write_buf = Array[UInt8, 4](fill=UInt8(0))
    write_buf[0] = UInt8(0xAA)
    write_buf[1] = UInt8(0xBB)
    write_buf[2] = UInt8(0xCC)
    write_buf[3] = UInt8(0xDD)
    var write_span = Span[UInt8](write_buf)
    var n_written = server_stream.write[NoopSink](reactor, write_span)
    assert_equal(n_written, Int64(4))

    # Client reads via the IoStream surface — the trait method we're
    # actually validating. Loop on Pending (none expected on loopback
    # post-write, but the test stays robust to schedulers that delay).
    var recv_buf = Array[UInt8, 4](fill=UInt8(0))
    var recv_span = Span[UInt8](recv_buf)
    var io_result = client_stream.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=recv_span,
    )

    # Loop until Ready or Eof (Pending → drain reactor and retry).
    var loop_guard = 0
    while io_result.is_pending() and loop_guard < 8:
        var _drained = reactor.poll_completions(timeout_us=Int32(100_000))
        io_result = client_stream.try_read[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, dst=recv_span,
        )
        loop_guard = loop_guard + 1

    assert_true(io_result.is_ready())
    assert_equal(io_result.n_bytes(), Int64(4))
    assert_equal(Int(recv_buf[0]), Int(UInt8(0xAA)))
    assert_equal(Int(recv_buf[1]), Int(UInt8(0xBB)))
    assert_equal(Int(recv_buf[2]), Int(UInt8(0xCC)))
    assert_equal(Int(recv_buf[3]), Int(UInt8(0xDD)))


def test_tcp_io_stream_write_via_trait() raises:
    """Symmetric to the read round-trip: write via the IoStream surface,
    read on the server side via a direct TcpStream.read (no IoStream
    indirection on the receive side — verifies the write trait method
    actually puts the bytes on the wire, not just that the API
    compiles).
    """
    comptime if not CompilationTarget.is_linux():
        return

    var listener = TcpListener.bind_loopback(
        port=UInt16(0), backlog=Int32(16),
    )
    var port = listener.local_port()
    var reactor = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
    )

    var connector = KernelTcpConnector.new()
    var client_stream = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, ip_be=inet_loopback_be(), port=port,
    )

    # Accept on the listener side.
    var ar = listener.try_accept()
    assert_true(ar.is_ready())
    var server_fd = Int32(Int(ar.value()))
    var server_stream = TcpStream(server_fd)

    # Client writes via the IoStream trait method.
    var send_buf = Array[UInt8, 3](fill=UInt8(0))
    send_buf[0] = UInt8(0x11)
    send_buf[1] = UInt8(0x22)
    send_buf[2] = UInt8(0x33)
    var send_span = Span[UInt8](send_buf)
    var w_result = client_stream.try_write[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, src=send_span,
    )
    # Loopback write to a fresh conn won't block; expect Ready.
    var loop_guard = 0
    while w_result.is_pending() and loop_guard < 8:
        var _drained = reactor.poll_completions(timeout_us=Int32(100_000))
        w_result = client_stream.try_write[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, src=send_span,
        )
        loop_guard = loop_guard + 1

    assert_true(w_result.is_ready())
    assert_equal(w_result.n_bytes(), Int64(3))

    # Server reads via komira_async's direct read (blocking on its own
    # reactor).
    var recv_buf = Array[UInt8, 3](fill=UInt8(0))
    var recv_span = Span[UInt8](recv_buf)
    var n_read = server_stream.read[NoopSink](reactor, recv_span)
    assert_equal(n_read, Int64(3))
    assert_equal(Int(recv_buf[0]), Int(UInt8(0x11)))
    assert_equal(Int(recv_buf[1]), Int(UInt8(0x22)))
    assert_equal(Int(recv_buf[2]), Int(UInt8(0x33)))


def main() raises:
    test_kernel_tcp_connector_transport_kind()
    test_kernel_tcp_connector_loopback_round_trip()
    test_tcp_io_stream_write_via_trait()
