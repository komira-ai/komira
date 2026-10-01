# =============================================================================
# test_kqueue_accept_tcp.mojo
# =============================================================================
# Regression — register an accepted TCP fd with
# BACKEND_KQUEUE and verify a peer-side `send` causes the read event to
# fire on the next poll_completions().
#
# Pre-fix: an HTTP server built on this reactor showed that after `try_accept` returns a new connected fd and the worker calls
# `register_long_lived(new_fd, INTEREST_READ)`, subsequent
# `poll_completions(-1)` calls block forever even though the peer (curl)
# wrote a request to the connection. This test isolates that path
# without the worker-loop wrapper.
#
# Pass criterion: poll_completions returns >= 1 event for the registered
# fd within 1 second.
# Fail criterion: poll_completions times out (returns 0 events) — this is
# the production bug and the test must FAIL pre-fix.
#
# Linux: skipped via comptime guard.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import assert_true, assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    Completion, INTEREST_READ, INTEREST_WRITE, RegistrationHandle,
)
from komira_async.reactor.reactor import (
    BACKEND_KQUEUE, Reactor,
)
from komira_async.reactor.socket_setup import (
    inet_loopback_be,
)
from komira_async.runtime.tcp_stream import (
    TcpListener,
)


def test_kqueue_accept_tcp_read_event_fires_server_shape() raises:
    """Same as the simpler test but mirrors a per-core HTTP server flow:
    use poll_completions(-1) (block forever) + drain accept to WOULDBLOCK
    before the conn-register. This is the exact shape of
    server_main.mojo._per_thread_server_main.

    We use a separate thread (or just inline pre-connect) to set up the
    client connection BEFORE issuing the listener poll, and pre-send
    bytes BEFORE issuing the conn poll. timeout=-1 with the data already
    waiting must still return immediately.
    """
    comptime if CompilationTarget.is_macos():
        var sink = NoopSink(_placeholder=UInt8(0))
        var r = Reactor[NoopSink](sink^, BACKEND_KQUEUE)
        var listener = TcpListener.bind_reuseport(
            inet_loopback_be(), UInt16(0), Int32(16),
        )
        var port = listener.local_port()
        var listen_fd = listener.fd()
        var listen_reg = r.register_long_lived(listen_fd, INTEREST_READ)
        _ = listen_reg

        # Connect.
        var client_fd = external_call["socket", Int32](
            Int32(2), Int32(1), Int32(0),
        )
        var addr = Array[UInt8, 16](fill=UInt8(0))
        addr[0] = UInt8(16)
        addr[1] = UInt8(2)
        addr[2] = UInt8((Int(port) >> 8) & 0xFF)
        addr[3] = UInt8(Int(port) & 0xFF)
        addr[4] = UInt8(0x7F)
        addr[7] = UInt8(0x01)
        var rc = external_call["connect", Int32](
            client_fd,
            addr.unsafe_ptr().unsafe_origin_cast[origin_of(addr)](),
            UInt32(16),
        )
        _ = addr[0]
        assert_true(rc == Int32(0), "connect ok")

        # Pre-send bytes BEFORE listener poll: these will be in the
        # kernel recv buffer for the conn fd before we even register it.
        # That mimics curl's "Request completely sent off" before the
        # server poll cycles to the conn fd.
        var msg_buf = Array[UInt8, 8](fill=UInt8(0x42))
        var sent = external_call["send", Int64](
            client_fd,
            msg_buf.unsafe_ptr().unsafe_origin_cast[origin_of(msg_buf)](),
            UInt(8), Int32(0),
        )
        _ = msg_buf[0]
        assert_true(sent == Int64(8))

        # Server-shape: poll_completions with timeout=-1.
        # We use timeout=2_000_000us (2s) for test sanity but the substrate
        # path for -1 vs >0 is platform-branched in kevent_wait_decode.
        # We test BOTH to surface any divergence.
        # First with -1.
        var c1 = r.poll_completions(Int32(-1))
        assert_true(len(c1) >= 1, "listener should fire (timeout=-1)")

        # Drain accept to WOULDBLOCK (server's pattern).
        var accepted_fd = Int32(-1)
        while True:
            var ar = listener.try_accept()
            if ar.is_would_block():
                break
            if ar.is_error():
                break
            accepted_fd = Int32(Int(ar.value()))
        assert_true(accepted_fd >= Int32(0), "accepted fd valid")

        # Register the accepted fd for READ.
        var conn_reg = r.register_long_lived(accepted_fd, INTEREST_READ)
        _ = conn_reg

        # Now poll with timeout=-1. Bytes are already in the buffer;
        # kqueue with EV_CLEAR + EV_ADD on a socket that has data ready
        # MUST fire the event immediately.
        var c2 = r.poll_completions(Int32(-1))
        assert_true(
            len(c2) >= 1,
            "kqueue must fire READ on accepted TCP fd with pre-buffered data",
        )

        _ = external_call["close", Int32](client_fd)
        _ = external_call["close", Int32](accepted_fd)
        _ = listener^
        _ = r^
    else:
        assert_true(True)


def test_kqueue_accept_tcp_read_event_fires() raises:
    """Register an accepted TCP socket for INTEREST_READ; peer writes;
    expect kqueue to deliver the readable event."""
    comptime if CompilationTarget.is_macos():
        var sink = NoopSink(_placeholder=UInt8(0))
        var r = Reactor[NoopSink](sink^, BACKEND_KQUEUE)
        var listener = TcpListener.bind_reuseport(
            inet_loopback_be(), UInt16(0), Int32(16),
        )
        var port = listener.local_port()
        var listen_fd = listener.fd()
        var listen_reg = r.register_long_lived(listen_fd, INTEREST_READ)
        _ = listen_reg

        # Connect a client.
        var client_fd = external_call["socket", Int32](
            Int32(2),  # AF_INET
            Int32(1),  # SOCK_STREAM
            Int32(0),
        )
        assert_true(client_fd >= 0, "socket() failed")

        # Build sockaddr_in for 127.0.0.1:port (network byte order).
        var addr = Array[UInt8, 16](fill=UInt8(0))
        addr[0] = UInt8(16)  # sin_len (Mac)
        addr[1] = UInt8(2)   # AF_INET
        addr[2] = UInt8((Int(port) >> 8) & 0xFF)
        addr[3] = UInt8(Int(port) & 0xFF)
        addr[4] = UInt8(0x7F)  # 127.0.0.1
        addr[5] = UInt8(0x00)
        addr[6] = UInt8(0x00)
        addr[7] = UInt8(0x01)

        var rc = external_call["connect", Int32](
            client_fd,
            addr.unsafe_ptr().unsafe_origin_cast[
                origin_of(addr)
            ](),
            UInt32(16),
        )
        _ = addr[0]  # anchor lifetime
        assert_true(rc == Int32(0), "connect() failed")

        # Wait for accept readiness.
        var c1 = r.poll_completions(Int32(500_000))  # 500ms
        assert_true(len(c1) >= 1, "listener should fire")

        var ar = listener.try_accept()
        assert_true(ar.is_ready(), "try_accept should be ready")
        var accepted_fd = Int32(Int(ar.value()))
        assert_true(accepted_fd >= Int32(0), "accepted fd valid")

        # Register the accepted fd for READ.
        var conn_reg = r.register_long_lived(accepted_fd, INTEREST_READ)
        _ = conn_reg

        # Send some bytes from client side.
        var msg_buf = Array[UInt8, 8](fill=UInt8(0x42))
        var sent = external_call["send", Int64](
            client_fd,
            msg_buf.unsafe_ptr().unsafe_origin_cast[
                origin_of(msg_buf)
            ](),
            UInt(8),
            Int32(0),
        )
        _ = msg_buf[0]
        assert_true(sent == Int64(8), "send 8 bytes")

        # Poll for the conn-fd READ event with 1s timeout.
        var c2 = r.poll_completions(Int32(1_000_000))  # 1 second
        assert_true(
            len(c2) >= 1,
            "kqueue must fire READ on accepted TCP fd after peer send",
        )

        # Cleanup.
        _ = external_call["close", Int32](client_fd)
        _ = external_call["close", Int32](accepted_fd)
        _ = listener^
        _ = r^
    else:
        assert_true(True)


def _server_loop_repro(reactor_ptr_addr: Int, listener_ptr_addr: Int, listen_fd: Int32) raises -> Int:
    """Mirrors _per_thread_server_main's flow: poll+accept+register+poll.
    Runs in the SAME thread as main but with hoisted args to dodge any
    pthread-related optimizer behavior. If this hangs, the bug is shape
    of the loop body. If it passes, the bug is pthread-context-specific.
    """
    var r_ptr = UnsafePointer[Reactor[NoopSink], MutUntrackedOrigin](
        unsafe_from_address=reactor_ptr_addr,
    )
    var l_ptr = UnsafePointer[TcpListener, MutUntrackedOrigin](
        unsafe_from_address=listener_ptr_addr,
    )

    # Poll listener.
    var c1 = r_ptr[].poll_completions(Int32(-1))
    if len(c1) < 1:
        return -1
    # Accept loop.
    var accepted_fd = Int32(-1)
    while True:
        var ar = l_ptr[].try_accept()
        if ar.is_would_block():
            break
        if ar.is_error():
            break
        var nf = Int32(Int(ar.value()))
        if nf < Int32(0):
            break
        accepted_fd = nf
    if accepted_fd < Int32(0):
        return -2
    # Register.
    var conn_reg = r_ptr[].register_long_lived(accepted_fd, INTEREST_READ)
    _ = conn_reg
    # Poll for conn read event.
    var c2 = r_ptr[].poll_completions(Int32(2_000_000))  # 2s
    return Int(len(c2))


def test_kqueue_server_loop_repro() raises:
    """Mirrors a per-core HTTP server's worker loop body exactly."""
    comptime if CompilationTarget.is_macos():
        var sink = NoopSink(_placeholder=UInt8(0))
        var r = Reactor[NoopSink](sink^, BACKEND_KQUEUE)
        var listener = TcpListener.bind_reuseport(
            inet_loopback_be(), UInt16(0), Int32(16),
        )
        var port = listener.local_port()
        var listen_fd = listener.fd()
        var listen_reg = r.register_long_lived(listen_fd, INTEREST_READ)
        _ = listen_reg

        # Connect a client.
        var client_fd = external_call["socket", Int32](
            Int32(2), Int32(1), Int32(0),
        )
        var addr = Array[UInt8, 16](fill=UInt8(0))
        addr[0] = UInt8(16)
        addr[1] = UInt8(2)
        addr[2] = UInt8((Int(port) >> 8) & 0xFF)
        addr[3] = UInt8(Int(port) & 0xFF)
        addr[4] = UInt8(0x7F)
        addr[7] = UInt8(0x01)
        var rc = external_call["connect", Int32](
            client_fd,
            addr.unsafe_ptr().unsafe_origin_cast[origin_of(addr)](),
            UInt32(16),
        )
        _ = addr[0]
        assert_true(rc == Int32(0))

        # Pre-buffer some bytes from client side.
        var msg_buf = Array[UInt8, 8](fill=UInt8(0x42))
        var sent = external_call["send", Int64](
            client_fd,
            msg_buf.unsafe_ptr().unsafe_origin_cast[origin_of(msg_buf)](),
            UInt(8), Int32(0),
        )
        _ = msg_buf[0]
        assert_true(sent == Int64(8))

        # Run repro flow.
        var n = _server_loop_repro(
            Int(UnsafePointer(to=r)),
            Int(UnsafePointer(to=listener)),
            listen_fd,
        )
        assert_true(
            n >= 1,
            "server-loop-shape repro must observe READ event",
        )

        _ = external_call["close", Int32](client_fd)
        _ = listener^
        _ = r^
    else:
        assert_true(True)


def main() raises:
    print("test_kqueue_accept_tcp_read_event_fires running")
    test_kqueue_accept_tcp_read_event_fires()
    print("  test_kqueue_accept_tcp_read_event_fires OK")
    print("test_kqueue_accept_tcp_read_event_fires_server_shape running")
    test_kqueue_accept_tcp_read_event_fires_server_shape()
    print("  test_kqueue_accept_tcp_read_event_fires_server_shape OK")
    print("test_kqueue_server_loop_repro running")
    test_kqueue_server_loop_repro()
    print("  test_kqueue_server_loop_repro OK")
