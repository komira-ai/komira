# The listening socket of an IMAP server.
#
# The socket type is the SMTP server's `ListenSocket` (one owner for the
# descriptor, closed when it is destroyed), so a binary serving both protocols
# holds one kind of listener.

from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    getsockname_port,
    listen_socket,
    set_so_reuseaddr,
    socket_tcp_nonblocking,
)
from komira_smtp_server import ListenSocket

comptime _BACKLOG: Int32 = Int32(1024)


def bind_imap_listener(bind_be: UInt32, port: UInt16) raises -> ListenSocket:
    """Create a non-blocking TCP socket, bind it to `bind_be` (an IPv4 address
    in network byte order) and `port`, and listen. Port 0 lets the kernel pick
    one: read it back with `local_port()`. Raises on any failure; no
    descriptor is leaked."""
    var fd = socket_tcp_nonblocking()
    try:
        set_so_reuseaddr(fd)
        bind_inet(fd, bind_be, port)
        listen_socket(fd, _BACKLOG)
        var bound = getsockname_port(fd)
        return ListenSocket(fd, bound)
    except e:
        close_fd(fd)
        raise e^
