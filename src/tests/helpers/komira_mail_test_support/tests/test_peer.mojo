# The loopback client against bare sockets. What each case catches:
# - connect, send and poll move bytes both ways over a real connection, in
#   order, and take_through removes exactly what it returns (a poll that drops
#   or repeats bytes, a take_through that keeps or over-removes text, fails);
# - a server close reads as eof, and a poll after it adds nothing;
# - scratch_dir names a directory that exists.

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.socket_io import try_io_accept, try_recv, try_send
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    getsockname_port,
    inet_loopback_be,
    listen_socket,
    set_so_reuseaddr,
    socket_tcp_nonblocking,
)

from komira_mail_test_support import Peer, scratch_dir, yield_cpu


def test_bytes_both_ways_and_eof() raises:
    var listener = socket_tcp_nonblocking()
    set_so_reuseaddr(listener)
    bind_inet(listener, inet_loopback_be(), UInt16(0))
    listen_socket(listener, Int32(8))
    var peer = Peer.connect(getsockname_port(listener))
    var server = Int32(-1)
    while server < Int32(0):
        var a = try_io_accept(listener)
        if a.is_ready():
            server = Int32(Int(a.value()))
        else:
            yield_cpu()

    # Server to peer: two writes arrive in order.
    var hello = String("220 hello\r\n250 two\r\n")
    assert_equal(Int(try_send(server, hello.as_bytes())), hello.byte_length())
    while not peer.has("250 two\r\n"):
        _ = peer.poll()
        yield_cpu()
    assert_equal(peer.take_through("\r\n"), "220 hello\r\n")
    assert_equal(peer.take_through("nothing"), "")
    assert_equal(peer.text(), "250 two\r\n")

    # Peer to server.
    peer.send(String("EHLO a\r\n"))
    var got = List[UInt8](length=64, fill=UInt8(0))
    var seen = 0
    while seen < 8:
        var n = try_recv(server, Span(got)[seen:64])
        if n > Int64(0):
            seen += Int(n)
        else:
            yield_cpu()
    assert_equal(String(unsafe_from_utf8=Span(got)[0:seen]), "EHLO a\r\n")

    # The server closes: the peer sees the end.
    close_fd(server)
    while not peer.eof:
        _ = peer.poll()
        yield_cpu()
    assert_equal(peer.poll(), 0)
    assert_true(peer.eof)
    peer.close()
    close_fd(listener)


def test_scratch_dir_exists() raises:
    assert_true(Path(scratch_dir()).exists())
    assert_false(scratch_dir().byte_length() == 0)


def main() raises:
    test_bytes_both_ways_and_eof()
    test_scratch_dir_exists()
    print("test_peer: OK")
