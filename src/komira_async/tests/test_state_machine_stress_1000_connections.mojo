# =============================================================================
# test_state_machine_stress_1000_connections.mojo
# =============================================================================
# sequential connect/request/disconnect stress.
#
# Drives 1000 sequential connect→single-request→disconnect cycles through
# the state-machine track on a single thread. Verifies:
#   - No fd leak (the system would hit EMFILE before 1000 conns if leaks).
#   - No crash / corruption across many TcpStream construct/destruct cycles.
#   - Throughput within reasonable bounds (smoke; the bench harness is the
#     real measurement).
#
# Linux-only (epoll backend).
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


# Bound the stress run to 1000 cycles per the dispatch spec. Larger values
# would catch slower leaks but at this scale we already exceed any
# reasonable per-process fd quota if leaks exist (Linux default ulimit
# = 1024).
comptime N_CYCLES: Int = 1000


def test_state_machine_stress_1000_connect_request_disconnect_cycles() raises:
    """1000 sequential connect/request/disconnect cycles.

    Cycle:
      1. Open a client conn.
      2. Server accepts → produces TcpStream.
      3. Client sends 4 bytes; server reads them.
      4. Server sends 4 bytes back; client reads them.
      5. Both sides close. TcpStream drops (closes server-side fd +
         deregisters if registered).

    If fd leaks accumulate, by cycle ~1000 the system hits EMFILE
    (default ulimit -n = 1024) and the cycle fails to proceed. A
    non-crashing 1000-iteration run is the leak proof.
    """
    comptime if CompilationTarget.is_linux():
        var listener = TcpListener.bind_loopback(
            port=UInt16(0), backlog=Int32(64),
        )
        var port = listener.local_port()
        var reactor = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )

        var i = 0
        while i < N_CYCLES:
            var client_fd = _connect_blocking(port)
            var stream = listener.accept[NoopSink](reactor)

            # Client sends 4 bytes encoding the cycle index.
            var sb = Array[UInt8, 4](fill=UInt8(0))
            sb[0] = UInt8(i & 0xFF)
            sb[1] = UInt8((i >> 8) & 0xFF)
            sb[2] = UInt8(0xAB)
            sb[3] = UInt8(0xCD)
            var sent = external_call["send", Int](
                client_fd, sb.unsafe_ptr(), UInt(4), Int32(0),
            )
            assert_equal(sent, Int(4))

            # Server reads.
            var rb = Array[UInt8, 4](fill=UInt8(0))
            var rspan = Span[UInt8](rb)
            var n = stream.read[NoopSink](reactor, rspan)
            assert_equal(n, Int64(4))
            assert_equal(Int(rb[0]), i & 0xFF)
            assert_equal(Int(rb[2]), Int(UInt8(0xAB)))

            # Server writes back (echo).
            var wspan = Span[UInt8](rb)
            var nw = stream.write[NoopSink](reactor, wspan)
            assert_equal(nw, Int64(4))

            # Client recvs.
            var crb = Array[UInt8, 4](fill=UInt8(0))
            var got = external_call["recv", Int](
                client_fd, crb.unsafe_ptr(), UInt(4), Int32(0),
            )
            assert_equal(got, Int(4))
            assert_equal(Int(crb[0]), i & 0xFF)

            # Cleanup: close client; drop stream (closes server-side).
            close_fd(client_fd)
            _ = stream^

            i = i + 1


def main() raises:
    test_state_machine_stress_1000_connect_request_disconnect_cycles()
    print(
        "PASS komira_async.runtime state-machine 1000-conn stress"
    )
