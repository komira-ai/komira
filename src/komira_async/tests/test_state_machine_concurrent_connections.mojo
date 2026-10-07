# =============================================================================
# test_state_machine_concurrent_connections.mojo
# =============================================================================
# N concurrent connections through the state-
# machine track on a single thread.
#
# Validates that the state-machine track can multiplex N=8 simultaneous
# connections through one Reactor + one TcpListener:
#   1. Open 8 client connections (raw libc).
#   2. Server accepts all 8 (each producing a TcpStream).
#   3. Server reads from each (in turn) → writes back.
#   4. Verify every conn round-trips correctly.
#
# This is single-threaded multiplexing — the workload shape that
# tokio's "current-thread" runtime targets, and that the
# HTTP server's per-pthread accept loop will exhibit.
#
# Linux-only (epoll backend).
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer
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
from komira_collections.slab import Slab


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


comptime N_CONNS: Int = 8


def test_state_machine_n8_concurrent_round_trips() raises:
    """8 concurrent client conns through one state-machine
    server thread.

    Steps:
      1. Bind listener.
      2. Open 8 client conns (all the way through TCP handshake before
         server accepts).
      3. Server accepts all 8 in sequence (kernel's listen backlog
         holds them).
      4. Each client sends 4 bytes; server reads + writes each in turn.
      5. Each client recvs the echo.

    Verifies the state-machine track survives N=8 simultaneous connections
    without leaks or crashes.
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(64),
        )
        var port = listener.local_port()
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )

        # Open 8 client conns. Note: each client_fd is held in a List for
        # later cleanup.
        var client_fds = List[Int32]()
        var i = 0
        while i < N_CONNS:
            var cfd = _connect_blocking(port)
            client_fds.append(cfd)
            i = i + 1

        # Server accepts all 8. TcpStream is Movable-only (not Copyable),
        # so we hold each behind an OwnedPointer slot in a Slab — same
        # safe across destroy-recreate pattern as PerCoreAsyncRuntime._workers.
        var streams = Slab[OwnedPointer[TcpStream]]()
        i = 0
        while i < N_CONNS:
            var s = listener.accept[NoopSink](reactor)
            var ow = OwnedPointer[TcpStream](value=s^)
            streams.append(ow^)
            i = i + 1
        assert_equal(streams.len(), N_CONNS)

        # Each client sends 4 unique bytes.
        i = 0
        while i < N_CONNS:
            var sb = Array[UInt8, 4](fill=UInt8(0))
            sb[0] = UInt8(i)
            sb[1] = UInt8(i + 16)
            sb[2] = UInt8(i + 32)
            sb[3] = UInt8(i + 48)
            var sent = external_call["send", Int](
                client_fds[i], sb.unsafe_ptr(), UInt(4), Int32(0),
            )
            assert_equal(sent, Int(4))
            i = i + 1

        # Server reads + writes each.
        i = 0
        while i < N_CONNS:
            var rb = Array[UInt8, 4](fill=UInt8(0))
            var rspan = Span[UInt8](rb)
            var n = streams[i][].read[NoopSink](reactor, rspan)
            assert_equal(n, Int64(4))
            assert_equal(Int(rb[0]), i)
            assert_equal(Int(rb[3]), i + 48)

            var wspan = Span[UInt8](rb)
            var nw = streams[i][].write[NoopSink](reactor, wspan)
            assert_equal(nw, Int64(4))
            i = i + 1

        # Each client recvs.
        i = 0
        while i < N_CONNS:
            var crb = Array[UInt8, 4](fill=UInt8(0))
            var got = external_call["recv", Int](
                client_fds[i], crb.unsafe_ptr(), UInt(4), Int32(0),
            )
            assert_equal(got, Int(4))
            assert_equal(Int(crb[0]), i)
            assert_equal(Int(crb[3]), i + 48)
            i = i + 1

        # Cleanup: close all client fds. Streams drop with the List on
        # scope exit (TcpStream.__del__ closes server-side fds).
        i = 0
        while i < N_CONNS:
            close_fd(client_fds[i])
            i = i + 1


def main() raises:
    test_state_machine_n8_concurrent_round_trips()
    print(
        "PASS komira_async.runtime state-machine concurrent connections"
    )
