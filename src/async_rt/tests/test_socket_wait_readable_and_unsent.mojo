# =============================================================================
# test_socket_wait_readable_and_unsent.mojo -- wait_readable and
# socket_unsent_bytes over a loopback TCP pair (port 0)
# =============================================================================
#
# What each test holds:
# - test_nothing_sent_is_not_readable: with nothing sent, a zero-timeout wait
#   on the receiving end reports not readable.
# - test_sent_bytes_make_either_slot_readable: once the peer has sent a byte,
#   the receiving end is readable whether it is watched as the first or the
#   second fd (the other slot unwatched, -1).
# - test_a_closed_peer_reads_as_readable: an end whose peer closed is readable
#   (end of stream), so a wait without limit returns.
# - test_no_watched_fd_is_refused: two unwatched fds raise with EINVAL, by the
#   exact message, instead of waiting for nothing.
# - test_a_closed_fd_is_refused: a watched fd that is not open raises with
#   EBADF, by the exact message, instead of reading as ready.
# - test_unsent_bytes_follow_the_peer: a sender that fills the window of a
#   peer that does not read has bytes in its send queue; once the peer has
#   read every byte, the send queue is empty (0).
# - test_unsent_bytes_of_a_bad_fd_is_refused: a negative fd raises with EBADF,
#   by the exact message.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from async_rt.ops.waker_sink import NoopSink
from async_rt.reactor.socket_io import errno_is_would_block, try_recv, try_send
from async_rt.reactor.socket_setup import (
    close_fd,
    socket_tcp_nonblocking,
    socket_unsent_bytes,
    wait_readable,
)
from async_rt.runtime.blocking_runtime import BlockingRuntime
from async_rt.runtime.tcp_stream import TcpListener, TcpStream


def _tcp_pair() raises -> Tuple[Int32, Int32]:
    """A connected loopback TCP pair on a kernel-chosen port, both ends
    non-blocking: (accepted end, connecting end). The caller closes both."""
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(1))
    var client = TcpStream.connect_loopback[NoopSink](
        reactor, listener.local_port()
    )
    var server = listener.accept[NoopSink](reactor)
    var pair = (server.release_fd(), client.release_fd())
    _ = rt^
    return pair


def _send_one(fd: Int32) raises:
    var b = List[UInt8](length=1, fill=UInt8(120))
    assert_equal(try_send(fd, Span(b)), Int64(1))


def test_nothing_sent_is_not_readable() raises:
    var p = _tcp_pair()
    assert_false(wait_readable(p[0], Int32(-1), 0))
    close_fd(p[0])
    close_fd(p[1])


def test_sent_bytes_make_either_slot_readable() raises:
    var p = _tcp_pair()
    _send_one(p[1])
    assert_true(wait_readable(p[0], Int32(-1), -1))
    assert_true(wait_readable(Int32(-1), p[0], -1))
    close_fd(p[0])
    close_fd(p[1])


def test_a_closed_peer_reads_as_readable() raises:
    var p = _tcp_pair()
    close_fd(p[1])
    assert_true(wait_readable(p[0], Int32(-1), -1))
    close_fd(p[0])


def test_no_watched_fd_is_refused() raises:
    var message = String()
    try:
        _ = wait_readable(Int32(-1), Int32(-1), 0)
    except e:
        message = String(e)
    assert_equal(message, "wait_readable failed (errno 22)")


def test_a_closed_fd_is_refused() raises:
    var fd = socket_tcp_nonblocking()
    close_fd(fd)
    var message = String()
    try:
        _ = wait_readable(fd, Int32(-1), 0)
    except e:
        message = String(e)
    assert_equal(message, "wait_readable failed (errno 9)")


def test_unsent_bytes_follow_the_peer() raises:
    var p = _tcp_pair()
    assert_equal(socket_unsent_bytes(p[1]), 0)
    # Fill the window: the peer reads nothing, so sends stop at EAGAIN.
    var chunk = List[UInt8](length=16384, fill=UInt8(97))
    var sent = 0
    while True:
        var n = try_send(p[1], Span(chunk))
        if n > Int64(0):
            sent += Int(n)
            continue
        assert_true(errno_is_would_block(Int32(-Int(n))), "send: " + String(n))
        break
    assert_true(socket_unsent_bytes(p[1]) > 0)
    # The peer reads until every byte sent has arrived; then nothing waits.
    var buf = List[UInt8](length=65536, fill=UInt8(0))
    var got = 0
    while got < sent:
        var n = try_recv(p[0], Span(buf))
        if n > Int64(0):
            got += Int(n)
            continue
        assert_true(errno_is_would_block(Int32(-Int(n))), "recv: " + String(n))
        _ = wait_readable(p[0], Int32(-1), -1)
    assert_equal(got, sent)
    while socket_unsent_bytes(p[1]) > 0:
        _ = wait_readable(p[0], Int32(-1), 0)
    assert_equal(socket_unsent_bytes(p[1]), 0)
    close_fd(p[0])
    close_fd(p[1])


def test_unsent_bytes_of_a_bad_fd_is_refused() raises:
    var message = String()
    try:
        _ = socket_unsent_bytes(Int32(-1))
    except e:
        message = String(e)
    assert_equal(message, "socket_unsent_bytes: failed (errno 9)")


def main() raises:
    test_nothing_sent_is_not_readable()
    test_sent_bytes_make_either_slot_readable()
    test_a_closed_peer_reads_as_readable()
    test_no_watched_fd_is_refused()
    test_a_closed_fd_is_refused()
    test_unsent_bytes_follow_the_peer()
    test_unsent_bytes_of_a_bad_fd_is_refused()
    print("test_socket_wait_readable_and_unsent: OK")
