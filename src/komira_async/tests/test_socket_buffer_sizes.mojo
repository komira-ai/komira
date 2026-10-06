# =============================================================================
# test_socket_buffer_sizes.mojo -- set_so_sndbuf / set_so_rcvbuf take effect
# =============================================================================
#
# Sets each buffer on a fresh TCP socket and reads it back with getsockopt.
# Linux stores twice the requested size (its bookkeeping overhead); Darwin
# stores it as given. Either way the read-back lands in [requested,
# 2 * requested], and it differs from the other buffer's request, so the two
# setters cannot be crossed.
#
# Defects it catches: a wrong SO_SNDBUF / SO_RCVBUF optname for the platform
# (the setter either raises or changes the other buffer, and the read-back is
# the kernel default), a crossed pair of optnames, a wrong SOL_SOCKET level, and
# a setter that accepts a closed fd silently.
# =============================================================================

from std.testing import assert_true

from komira_async.reactor.socket_setup import (
    close_fd,
    set_so_rcvbuf,
    set_so_sndbuf,
    so_rcvbuf,
    so_sndbuf,
    socket_tcp_nonblocking,
)

comptime _SND: Int32 = Int32(48 * 1024)
comptime _RCV: Int32 = Int32(160 * 1024)


def _in_range(got: Int32, want: Int32) -> Bool:
    return got >= want and got <= want * Int32(2)


def test_buffers_read_back() raises:
    var fd = socket_tcp_nonblocking()
    set_so_sndbuf(fd, _SND)
    set_so_rcvbuf(fd, _RCV)
    var snd = so_sndbuf(fd)
    var rcv = so_rcvbuf(fd)
    close_fd(fd)
    assert_true(_in_range(snd, _SND), "SO_SNDBUF read back " + String(snd))
    assert_true(_in_range(rcv, _RCV), "SO_RCVBUF read back " + String(rcv))


def test_closed_fd_raises() raises:
    var fd = socket_tcp_nonblocking()
    close_fd(fd)
    var raised = False
    try:
        set_so_sndbuf(fd, _SND)
    except:
        raised = True
    assert_true(raised, "set_so_sndbuf on a closed fd must raise")
    raised = False
    try:
        set_so_rcvbuf(Int32(-1), _RCV)
    except:
        raised = True
    assert_true(raised, "set_so_rcvbuf on fd -1 must raise")


def main() raises:
    test_buffers_read_back()
    print("  test_buffers_read_back OK")
    test_closed_fd_raises()
    print("  test_closed_fd_raises OK")
    print("PASS komira_async test_socket_buffer_sizes")
