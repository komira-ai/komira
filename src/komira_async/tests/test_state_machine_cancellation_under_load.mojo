# =============================================================================
# test_state_machine_cancellation_under_load.mojo
# =============================================================================
# cancellation under multiple in-flight connections.
#
# Verifies that read_with_token / write_with_token / accept_with_token
# observe cancellation cleanly even when in the middle of a workload:
#   1. accept_with_token raises CancelledError on a pre-cancelled token.
#   2. read_with_token raises CancelledError on a pre-cancelled token.
#   3. write_with_token raises CancelledError on a pre-cancelled token.
#
# We can't easily exercise the per-iter cancellation path (which fires
# during a parked poll_completions) without a cross-thread signaler, so
# this test focuses on the pre-entry fast-path. Per-iter cancellation
# (100ms bounded latency) is covered by the cancellation tests
# under controlled fixture conditions.
#
# Linux-only (epoll backend).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    Reactor,
)
from komira_async.reactor.socket_setup import (
    close_fd,
    inet_loopback_be,
    sockaddr_in_bytes,
)
from komira_async.runtime.tcp_stream import (
    TcpListener,
    TcpStream,
)


def _connect_blocking(port: UInt16) raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(2), Int32(1), Int32(0),
    )
    if fd < Int32(0):
        raise Error("client socket() failed")
    var sa = sockaddr_in_bytes(inet_loopback_be(), port)
    var rc = external_call["connect", Int32](
        fd, sa.unsafe_ptr(), UInt32(16),
    )
    if rc < Int32(0):
        close_fd(fd)
        raise Error("client connect() failed")
    return fd


def test_accept_with_token_raises_on_pre_cancelled_token() raises:
    """accept_with_token short-circuits on a token that is
    already cancelled before the call.

    Pre-entry check fires; no syscalls hit; no listener registration
    happens (the lazy registration is gated on the first EWOULDBLOCK
    AFTER the token check passes).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var token = CancellationToken.new()
        token.cancel(String("pre-cancelled by test"))

        var raised = False
        try:
            var s = listener.accept_with_token[NoopSink](reactor, token)
            _ = s^
        except e:
            raised = True
            assert_true(String(e).startswith("CancelledError"))
        assert_true(raised)


def test_read_with_token_raises_on_pre_cancelled_token() raises:
    """read_with_token short-circuits on pre-cancelled token."""
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var stream = listener.accept[NoopSink](reactor)

        var token = CancellationToken.new()
        token.cancel(String("test cancellation"))

        var rb = Array[UInt8, 4](fill=UInt8(0))
        var rspan = Span[UInt8](rb)
        var raised = False
        try:
            var n = stream.read_with_token[NoopSink](reactor, rspan, token)
            _ = n
        except e:
            raised = True
            assert_true(String(e).startswith("CancelledError"))
        assert_true(raised)

        close_fd(client_fd)


def test_write_with_token_raises_on_pre_cancelled_token() raises:
    """write_with_token short-circuits on pre-cancelled token."""
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var stream = listener.accept[NoopSink](reactor)

        var token = CancellationToken.new()
        token.cancel(String("test cancellation"))

        var wb = Array[UInt8, 4](fill=UInt8(0xCC))
        var wspan = Span[UInt8](wb)
        var raised = False
        try:
            var n = stream.write_with_token[NoopSink](reactor, wspan, token)
            _ = n
        except e:
            raised = True
            assert_true(String(e).startswith("CancelledError"))
        assert_true(raised)

        close_fd(client_fd)


def test_read_with_token_succeeds_on_uncancelled_token() raises:
    """read_with_token completes normally when the token is
    fresh and uncancelled (the cancellation surface is purely additive
    to the base read API).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var stream = listener.accept[NoopSink](reactor)
        var token = CancellationToken.new()

        # Send 3 bytes from client.
        var sb = Array[UInt8, 3](fill=UInt8(0))
        sb[0] = UInt8(0x77)
        sb[1] = UInt8(0x88)
        sb[2] = UInt8(0x99)
        var sent = external_call["send", Int](
            client_fd, sb.unsafe_ptr(), UInt(3), Int32(0),
        )
        assert_equal(sent, Int(3))

        # Server reads with token.
        var rb = Array[UInt8, 8](fill=UInt8(0))
        var rspan = Span[UInt8](rb)
        var n = stream.read_with_token[NoopSink](reactor, rspan, token)
        assert_equal(n, Int64(3))
        assert_equal(Int(rb[0]), Int(UInt8(0x77)))
        assert_equal(Int(rb[2]), Int(UInt8(0x99)))

        close_fd(client_fd)


def main() raises:
    test_accept_with_token_raises_on_pre_cancelled_token()
    test_read_with_token_raises_on_pre_cancelled_token()
    test_write_with_token_raises_on_pre_cancelled_token()
    test_read_with_token_succeeds_on_uncancelled_token()
    print(
        "PASS komira_async.runtime state-machine cancellation under load"
    )
