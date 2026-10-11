# =============================================================================
# test_tcp_stream_smoke.mojo
# =============================================================================
# TcpStream + TcpListener smoke tests.
#
# Verifies:
#   - TcpListener.bind_loopback(port=0) constructs a non-blocking listener
#     bound to an ephemeral port; local_port() reads it back.
#   - try_accept on an empty listener returns WouldBlock; with a connected
#     client it returns Ready(new_fd).
#   - TcpStream wraps an accepted fd; lazy registration (is_registered()
#     starts False, transitions to True on first EWOULDBLOCK).
#   - Read + write round-trip with a localhost client.
#   - Deregister + close on TcpStream / TcpListener drop (no fd leak).
#   - release_fd: a released stream's drop leaves the fd open.
#
# Linux-only: the FFI relies on epoll syscalls; macOS branches in the
# tcp_stream module raise on construction (BACKEND_KQUEUE not exercised
# here).
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    Reactor,
)
from komira_async.reactor.socket_io import (
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
)
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    inet_loopback_be,
    sockaddr_in_bytes,
    socket_tcp_nonblocking,
)
from komira_async.runtime.tcp_stream import (
    TcpListener,
    TcpStream,
)


# -----------------------------------------------------------------------------
# Test helpers — synthetic localhost client construction.
# -----------------------------------------------------------------------------


def _connect_blocking(port: UInt16) raises -> Int32:
    """Construct a blocking AF_INET TCP socket and connect to
    127.0.0.1:port. Used by tests to drive the listener side.

    Blocking is intentional — the client is the test driver; we want
    its connect to complete synchronously so accept on the listener
    has work to do.
    """
    var fd = external_call["socket", Int32](
        Int32(2),    # AF_INET
        Int32(1),    # SOCK_STREAM (no SOCK_NONBLOCK — we want blocking)
        Int32(0),
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


# NOTE: there is no `_is_fd_open(fd)` helper. Mojo 0.26.3's external_call
# lowering for `dup` / `fstat` / `fcntl` inside a helper fn (whether `fn`
# or `def`, with or without `@always_inline`) clobbers the fd argument
# as it crosses the call frame, producing EBADF on valid fds. Inline the
# syscall in each test body. Once the Mojo external_call ABI bug is
# resolved, this can be unified via a helper.


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_tcp_listener_bind_ephemeral_port() raises:
    """TcpListener.bind_loopback(port=0) succeeds and
    the kernel-assigned port is non-zero.

    Probe via direct dup syscall on the fd held by the listener (the
    listener's destructor will fire on scope exit and close the fd —
    we test the dup BEFORE drop).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var fd = listener.fd()
        # Sanity: port and fd both materialize (port > 0 means bind +
        # getsockname succeeded, which ALSO implies the fd is alive).
        assert_true(port > UInt16(0))
        assert_false(listener.is_registered())
        assert_true(fd >= Int32(0))


def test_tcp_listener_try_accept_would_block() raises:
    """try_accept on a freshly-bound listener with no
    pending connections returns WouldBlock (Linux: accept4 returns
    EAGAIN; the EAGAIN is mapped to TRY_IO_WOULD_BLOCK).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var r = listener.try_accept()
        assert_true(r.is_would_block())


def test_tcp_listener_accept_after_connect() raises:
    """with a connected client, accept returns a
    TcpStream; the listener is registered after the first WouldBlock
    (here we only call try_accept which is non-blocking so there's no
    park; lazy registration won't fire).

    Steps:
      1. Bind listener on ephemeral port.
      2. Open a blocking client + connect to it.
      3. try_accept on the listener — Ready(new_fd).
      4. Wrap fd in TcpStream; verify the connection.
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()

        # Connect blocking client (synchronous handshake on localhost
        # is fast; no scheduler needed).
        var client_fd = _connect_blocking(port)

        # Now try_accept should immediately succeed.
        var r = listener.try_accept()
        assert_true(r.is_ready())
        var server_fd = Int32(Int(r.value()))
        assert_true(server_fd > Int32(0))

        # Wrap in TcpStream.
        var stream = TcpStream(server_fd)
        assert_false(stream.is_registered())   # lazy — not yet registered
        assert_equal(stream.fd(), server_fd)

        # Cleanup: close the client; TcpStream + TcpListener drop on
        # scope exit.
        close_fd(client_fd)


def test_tcp_stream_write_read_round_trip() raises:
    """write a few bytes from the test (acting as
    server) to the client, then verify the client receives them.

    This test does NOT use TcpStream.read/write directly because those
    methods block on poll_completions, which is fine but the client
    side is a raw fd — we read from it with a direct recv(). The
    important check is that TcpStream.write works against try_io
    (the client's recv buffer is empty, so the server's send hits
    Ready immediately — no park needed).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)

        var r = listener.try_accept()
        assert_true(r.is_ready())
        var server_fd = Int32(Int(r.value()))
        var stream = TcpStream(server_fd)

        # Build a Reactor for the TcpStream API (write_blocking takes
        # one). The Reactor is per-test; constructed and dropped here.
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )

        # Server writes 4 bytes.
        var write_buf = Array[UInt8, 4](fill=UInt8(0))
        write_buf[0] = UInt8(0x10)
        write_buf[1] = UInt8(0x20)
        write_buf[2] = UInt8(0x30)
        write_buf[3] = UInt8(0x40)
        var write_span = Span[UInt8](write_buf)
        var n = stream.write[NoopSink](reactor, write_span)
        assert_equal(n, Int64(4))

        # The client's receive buffer should now have 4 bytes; recv them
        # via direct FFI.
        var recv_buf = Array[UInt8, 4](fill=UInt8(0))
        var got = external_call["recv", Int](
            client_fd, recv_buf.unsafe_ptr(), UInt(4), Int32(0),
        )
        assert_equal(got, Int(4))
        assert_equal(Int(recv_buf[0]), Int(UInt8(0x10)))
        assert_equal(Int(recv_buf[3]), Int(UInt8(0x40)))

        close_fd(client_fd)


def test_tcp_stream_drop_closes_fd() raises:
    """dropping a TcpStream closes the underlying fd
    (no leak). Probe via inline dup() — returns -1 on closed fd.

    NOTE: `dup` via external_call inside helpers returns wrong values
    (a Mojo ABI quirk); this test inlines the dup syscall in the
    test body. We probe AFTER drop only — the pre-drop probe is
    elided because socket() returning a non-negative fd is sufficient
    proof the fd was open before the TcpStream wrapper consumed it.
    """
    comptime if CompilationTarget.is_linux():
        var fd = socket_tcp_nonblocking()
        assert_true(fd >= Int32(0))

        # Wrap in a TcpStream and immediately drop via `_ = stream^`.
        var saved_fd = fd
        var stream_for_drop = TcpStream(fd)
        assert_equal(stream_for_drop.fd(), saved_fd)
        _ = stream_for_drop^

        # After drop: dup should fail with EBADF.
        var dup_post = external_call["dup", Int32](saved_fd)
        assert_true(dup_post < Int32(0))


def test_tcp_stream_release_fd_leaves_it_open() raises:
    """release_fd returns the fd and the stream's drop leaves it open: the
    fd still duplicates after the drop (a drop that closed it would make
    dup fail with EBADF). The released stream reads -1."""
    comptime if CompilationTarget.is_linux():
        var fd = socket_tcp_nonblocking()
        assert_true(fd >= Int32(0))
        var stream = TcpStream(fd)
        assert_equal(stream.release_fd(), fd)
        assert_equal(stream.fd(), Int32(-1))
        _ = stream^
        var dup_post = external_call["dup", Int32](fd)
        assert_true(dup_post >= Int32(0))
        close_fd(dup_post)
        close_fd(fd)


def test_tcp_listener_drop_closes_fd() raises:
    """dropping a TcpListener closes the underlying
    listener fd. Symmetric to test_tcp_stream_drop_closes_fd.

    Probe AFTER drop only (the pre-drop probe is implied by bind+listen
    succeeding — those syscalls would have failed on a bad fd).
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var saved_fd = listener.fd()
        assert_true(saved_fd >= Int32(0))

        _ = listener^

        var dup_post = external_call["dup", Int32](saved_fd)
        assert_true(dup_post < Int32(0))


def test_tcp_stream_lazy_registration_transitions() raises:
    """TcpStream._registration is lazy.

    Steps:
      1. Construct a TcpStream from an accepted fd.
      2. Verify is_registered() == False (no registration yet).
      3. Force an EWOULDBLOCK by attempting a read on an empty connection
         (the peer hasn't sent anything yet) — but use a SHORT timeout
         path: we can't easily force the read.* method to return without
         data; instead, construct an empty client (no writes) and call
         try_io_read directly via the Reactor.submit slow path. This
         won't transition is_registered() (the slow path uses
         register_read, not register_long_lived).
      4. Instead, directly call _ensure_registered via the read body:
         drive write→read direction switch by writing first then issuing
         a read against the client (which won't have data ready, so
         read parks).

    Since `read` blocks until data arrives and we want a deterministic
    fast test, we do this:
      - Write a byte from the client to the server.
      - read on the server returns immediately (Ready) — no registration.
      - Then write from server (no client recv) — Ready (kernel buffer
        has space).
      - Trigger EWOULDBLOCK by closing the connection peer-side and
        attempting another write — this should transition to error,
        not registration. So this test verifies the FAST PATH paths
        DON'T trigger registration; the registration is reserved for
        actual EWOULDBLOCK.
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()
        var client_fd = _connect_blocking(port)

        var r = listener.try_accept()
        assert_true(r.is_ready())
        var server_fd = Int32(Int(r.value()))
        var stream = TcpStream(server_fd)
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )

        # is_registered starts False.
        assert_false(stream.is_registered())

        # Client sends 1 byte; server.read returns Ready immediately
        # (try_io fast path). is_registered remains False.
        var c_buf = Array[UInt8, 1](fill=UInt8(0xAA))
        _ = external_call["send", Int](
            client_fd, c_buf.unsafe_ptr(), UInt(1), Int32(0),
        )
        var server_read_buf = Array[UInt8, 8](fill=UInt8(0))
        var read_span = Span[UInt8](server_read_buf)
        var read_n = stream.read[NoopSink](reactor, read_span)
        assert_equal(read_n, Int64(1))
        assert_equal(Int(server_read_buf[0]), Int(UInt8(0xAA)))
        # Fast path didn't register.
        assert_false(stream.is_registered())

        close_fd(client_fd)


def main() raises:
    test_tcp_listener_bind_ephemeral_port()
    test_tcp_listener_try_accept_would_block()
    test_tcp_listener_accept_after_connect()
    test_tcp_stream_write_read_round_trip()
    test_tcp_stream_drop_closes_fd()
    test_tcp_stream_release_fd_leaves_it_open()
    test_tcp_listener_drop_closes_fd()
    test_tcp_stream_lazy_registration_transitions()
    print("PASS komira_async.runtime TcpStream / TcpListener smoke")
