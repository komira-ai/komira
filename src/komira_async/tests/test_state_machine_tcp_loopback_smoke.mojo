# =============================================================================
# test_state_machine_tcp_loopback_smoke.mojo
# =============================================================================
# full state-machine track end-to-end loopback test.
#
# Validates the complete state-machine track on a real TCP loopback round-
# trip:
#   1. TcpListener.bind_loopback(port=0) on the SERVER side.
#   2. Direct libc connect() on the CLIENT side (simple driver).
#   3. listener.accept(reactor) on the server (state-machine track).
#   4. Echo loop: stream.read(...) → stream.write(...) on the server.
#   5. Verify byte-for-byte echo.
#
# This is the state-machine production path an HTTP server uses.
#
# Linux-only: epoll backend.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

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
    """Construct a blocking AF_INET TCP socket and connect to 127.0.0.1:port.

    Inline FFI because external_call inside a helper
    def for socket / connect / send / recv has fd-clobbering ABI quirks
    on Mojo 0.26.3. We tolerate it here for readability — if the helper
    misbehaves, the test will fail on the first connect, not silently.
    """
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


def test_state_machine_loopback_one_shot_byte_echo() raises:
    """end-to-end loopback echo via state-machine track.

    Server: TcpListener.bind_loopback → accept → read → write (state-machine
    track APIs only).
    Client: direct libc socket+connect+send+recv (raw test driver).

    Verifies the full state-machine track pipeline (TcpListener.accept,
    TcpStream.read, TcpStream.write) on a real TCP connection, with a
    real Reactor[NoopSink].
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(16),
        )
        var port = listener.local_port()

        # Connect from the test driver.
        var client_fd = _connect_blocking(port)

        # Build the per-test reactor. Reused across all read/write calls.
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )

        # Server: accept the pending connection. With a connected client
        # already present, accept should hit Ready on the first try_accept
        # call inside accept's loop.
        var stream = listener.accept[NoopSink](reactor)

        # Client → server: send 5 bytes.
        var c_buf = Array[UInt8, 5](fill=UInt8(0))
        c_buf[0] = UInt8(0xDE)
        c_buf[1] = UInt8(0xAD)
        c_buf[2] = UInt8(0xBE)
        c_buf[3] = UInt8(0xEF)
        c_buf[4] = UInt8(0x42)
        var sent = external_call["send", Int](
            client_fd, c_buf.unsafe_ptr(), UInt(5), Int32(0),
        )
        assert_equal(sent, Int(5))

        # Server: read up to 16 bytes; should get exactly 5 (try_io fast
        # path; no parking needed since data is already in the kernel
        # buffer).
        var s_recv_buf = Array[UInt8, 16](fill=UInt8(0))
        var s_recv_span = Span[UInt8](s_recv_buf)
        var n = stream.read[NoopSink](reactor, s_recv_span)
        assert_equal(n, Int64(5))
        assert_equal(Int(s_recv_buf[0]), Int(UInt8(0xDE)))
        assert_equal(Int(s_recv_buf[1]), Int(UInt8(0xAD)))
        assert_equal(Int(s_recv_buf[2]), Int(UInt8(0xBE)))
        assert_equal(Int(s_recv_buf[3]), Int(UInt8(0xEF)))
        assert_equal(Int(s_recv_buf[4]), Int(UInt8(0x42)))

        # Server → client: echo the same 5 bytes back.
        var s_write_buf = Array[UInt8, 5](fill=UInt8(0))
        s_write_buf[0] = s_recv_buf[0]
        s_write_buf[1] = s_recv_buf[1]
        s_write_buf[2] = s_recv_buf[2]
        s_write_buf[3] = s_recv_buf[3]
        s_write_buf[4] = s_recv_buf[4]
        var write_span = Span[UInt8](s_write_buf)
        var n_w = stream.write[NoopSink](reactor, write_span)
        assert_equal(n_w, Int64(5))

        # Client: recv the echo.
        var c_recv_buf = Array[UInt8, 5](fill=UInt8(0))
        var got = external_call["recv", Int](
            client_fd, c_recv_buf.unsafe_ptr(), UInt(5), Int32(0),
        )
        assert_equal(got, Int(5))
        assert_equal(Int(c_recv_buf[0]), Int(UInt8(0xDE)))
        assert_equal(Int(c_recv_buf[4]), Int(UInt8(0x42)))

        close_fd(client_fd)


def test_state_machine_loopback_multiple_round_trips() raises:
    """multiple back-to-back round-trips on a single conn.

    Verifies the steady-state read→write→read→write cycle. The first
    EWOULDBLOCK on read should fire register_long_lived; subsequent
    iterations should hit modify (or no-op fast path if interest matches).
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

        # 8 round-trips: client sends 4 bytes, server reads + writes back,
        # client recvs.
        var i = 0
        while i < 8:
            var sb = Array[UInt8, 4](fill=UInt8(0))
            sb[0] = UInt8(i)
            sb[1] = UInt8(i + 1)
            sb[2] = UInt8(i + 2)
            sb[3] = UInt8(i + 3)
            var sent = external_call["send", Int](
                client_fd, sb.unsafe_ptr(), UInt(4), Int32(0),
            )
            assert_equal(sent, Int(4))

            var rb = Array[UInt8, 4](fill=UInt8(0))
            var rspan = Span[UInt8](rb)
            var n = stream.read[NoopSink](reactor, rspan)
            assert_equal(n, Int64(4))
            assert_equal(Int(rb[0]), i)
            assert_equal(Int(rb[3]), i + 3)

            var wspan = Span[UInt8](rb)
            var nw = stream.write[NoopSink](reactor, wspan)
            assert_equal(nw, Int64(4))

            var crb = Array[UInt8, 4](fill=UInt8(0))
            var got = external_call["recv", Int](
                client_fd, crb.unsafe_ptr(), UInt(4), Int32(0),
            )
            assert_equal(got, Int(4))
            assert_equal(Int(crb[0]), i)

            i = i + 1

        close_fd(client_fd)


def main() raises:
    test_state_machine_loopback_one_shot_byte_echo()
    test_state_machine_loopback_multiple_round_trips()
    print(
        "PASS komira_async.runtime state-machine track loopback smoke"
    )
