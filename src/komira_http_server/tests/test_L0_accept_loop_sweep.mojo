# =============================================================================
# test_L0_accept_loop_sweep.mojo: the accept loop's stale-mapping sweep on
# tables where two slots hold one descriptor
# =============================================================================
#
# `accept_one_and_register` sweeps the table's mapping for the number
# accept(2) just returned before it registers the new connection. The
# simple cases (a stale slot, an orphan holding -1, a live slot) are in
# test_L0_accept_loop_rounds.mojo. These tests hand the sweep tables in
# which two slots hold one live descriptor, the one shape where a slot
# whose own descriptor is mapped is still not live (the mapping reaches the
# other slot), and where removing the orphan's slot could close a
# descriptor a live connection still uses.
#
# The live descriptor is one end of an AF_UNIX socketpair, so whether the
# sweep closed it shows as end of stream on the other end. Every read is
# non-blocking and the listener poll waits on a connection that is already
# queued, so no mutant can make a test wait.
#
# Defects each test would catch:
#   - a slot kept because its descriptor has some mapping, not one that
#     reaches that slot (the table keeps an unreachable slot);
#   - the orphan slot's drop closing its descriptor, which the live slot
#     holding the same number still uses;
#   - the moved tail's mapping rewritten when it reached another slot, so
#     the slot the loop has been driving is no longer reached.
# =============================================================================

from std.collections.dict import Dict
from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    RegistrationHandle,
)
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.reactor.socket_io import try_io_read
from komira_async.reactor.socket_setup import inet_loopback_be
from komira_async.runtime.tcp_stream import TcpListener, TcpStream
from komira_collections.slab import Slab
from komira_http_server.accept_loop import accept_one_and_register
from komira_http_server.connection import ConnEntry


def _socketpair() raises -> Array[Int32, 2]:
    var pair = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: `pair` is a stack local that outlives the call; socketpair(2)
    # writes two ints into it and retains nothing.
    var rc = external_call["socketpair", Int32](
        Int32(1), Int32(1), Int32(0), pair.unsafe_ptr()
    )
    if rc < 0:
        raise Error("socketpair(AF_UNIX, SOCK_STREAM) failed")
    for i in range(2):
        if external_call["komira_fcntl_set_nonblock", Int32](pair[i]) < 0:
            raise Error("set_nonblock failed")
    return pair^


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _peer_sees_eof(fd: Int32) raises -> Bool:
    """Drain what is queued on `fd` without blocking; whether the other end
    has closed."""
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    while True:
        var r = try_io_read(fd, Span(buf))
        if r.is_would_block():
            return False
        if not r.is_ready():
            raise Error("the peer's read failed")
        if Int(r.value()) == 0:
            return True


def _connect(port: UInt16) raises -> Int32:
    """A blocking loopback TCP client connected to `port`."""
    var fd = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    if fd < 0:
        raise Error("socket() failed")
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(2)
    else:
        addr[0] = UInt8(2)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    # SAFETY: `addr` is a stack local read synchronously by connect(2).
    var rc = external_call["connect", Int32](fd, addr.unsafe_ptr(), UInt32(16))
    if rc < 0:
        _close(fd)
        raise Error("connect() failed")
    return fd


def _wait_readable(fd: Int32) raises:
    """Wait, without a timeout, until `fd` is readable (for a listener: a
    connection is queued, which `_connect` has already done)."""
    var pfd = List[Int32](length=2, fill=Int32(0))
    pfd[0] = fd
    pfd[1] = Int32(1)  # events = POLLIN, revents = 0
    # SAFETY: `pfd` holds one struct pollfd {int; short; short} and outlives
    # the call; poll(2) writes only its revents.
    var rc = external_call["poll", Int32](pfd.unsafe_ptr(), UInt64(1), Int32(-1))
    if rc < 0:
        raise Error("poll() failed")


def _entry(fd: Int32) -> ConnEntry:
    return ConnEntry(
        stream=TcpStream(fd),
        reg=RegistrationHandle(_fd=fd, _interest_set=INTEREST_READ),
    )


def _reused_number(listener_port: UInt16) raises -> Array[Int32, 2]:
    """Connect a client, then return [client, n] where `n` is the lowest free
    descriptor number, which the next accept(2) hands out."""
    var c = _connect(listener_port)
    var n = external_call["dup", Int32](c)
    _close(n)
    var out = Array[Int32, 2](fill=Int32(-1))
    out[0] = c
    out[1] = n
    return out^


def test_sweep_removes_a_duplicate_slot_its_fd_does_not_reach() raises:
    """Slots 0 and 1 both hold the live descriptor L, whose mapping reaches
    slot 1; the reused number's stale mapping reaches slot 0. Slot 0 is not
    live (L's mapping does not reach it), so the sweep removes it, without
    closing L, which slot 1 still uses. Slot 1 moves into slot 0 with its
    mapping patched, and the new connection takes slot 1."""
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var live = _socketpair()
    var cn = _reused_number(l.local_port())
    var c = cn[0]
    var next = cn[1]
    _wait_readable(l.fd())
    conns.append(_entry(live[0]))
    conns.append(_entry(live[0]))
    fd_to_idx[Int(live[0])] = 1
    fd_to_idx[Int(next)] = 0
    assert_equal(accept_one_and_register(l, r, conns, fd_to_idx), 1)
    # The duplicate slot no mapping reached is gone: one slot per mapping.
    assert_equal(conns.len(), 2)
    assert_equal(len(fd_to_idx), 2)
    # The live descriptor is open: removing the duplicate closed nothing.
    assert_false(_peer_sees_eof(live[1]))
    # The live slot moved into slot 0, its mapping patched to follow it.
    assert_equal(conns[0].fd(), live[0])
    assert_equal(fd_to_idx[Int(live[0])], 0)
    # The new connection sits at slot 1, mapped and open.
    assert_equal(conns[1].fd(), next)
    assert_equal(fd_to_idx[Int(next)], 1)
    assert_false(_peer_sees_eof(c))
    _ = conns^
    _close(live[1])
    _close(c)
    _ = r^
    _ = l^


def test_sweep_leaves_a_moved_tail_mapping_that_reached_another_slot() raises:
    """Slot 0 holds -1 (an orphan), slot 1 holds the live descriptor L with
    L's mapping reaching it, and the tail, slot 2, holds L as well (a copy
    no mapping reaches). The reused number's stale mapping reaches slot 0,
    so the sweep removes it and the tail moves into slot 0. L's mapping did
    not reach the tail, so it is left alone: it still reaches slot 1, the
    slot the loop has been driving, not the moved copy. The new connection
    takes slot 2."""
    var l = TcpListener.bind_reuseport(inet_loopback_be(), UInt16(0), Int32(8))
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var conns = Slab[ConnEntry]()
    var fd_to_idx = Dict[Int, Int]()
    var live = _socketpair()
    var cn = _reused_number(l.local_port())
    var c = cn[0]
    var next = cn[1]
    _wait_readable(l.fd())
    conns.append(_entry(Int32(-1)))
    conns.append(_entry(live[0]))
    conns.append(_entry(live[0]))
    fd_to_idx[Int(live[0])] = 1
    fd_to_idx[Int(next)] = 0
    assert_equal(accept_one_and_register(l, r, conns, fd_to_idx), 1)
    assert_equal(conns.len(), 3)
    assert_equal(len(fd_to_idx), 2)
    # The orphan's slot now holds the moved copy; L's mapping still reaches
    # slot 1.
    assert_equal(conns[0].fd(), live[0])
    assert_equal(conns[1].fd(), live[0])
    assert_equal(fd_to_idx[Int(live[0])], 1)
    assert_equal(conns[2].fd(), next)
    assert_equal(fd_to_idx[Int(next)], 2)
    assert_false(_peer_sees_eof(live[1]))
    assert_false(_peer_sees_eof(c))
    # The copy must not close L a second time when the table drops.
    conns[0].forget_fd()
    _ = conns^
    _close(live[1])
    _close(c)
    _ = r^
    _ = l^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
