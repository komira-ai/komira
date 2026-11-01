# The listening socket of an SMTP server: one owner for the descriptor.

from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    getsockname_port,
    listen_socket,
    set_so_reuseaddr,
    socket_tcp_nonblocking,
)

comptime _BACKLOG: Int32 = Int32(1024)


struct ListenSocket(Movable, Deinitable):
    """A bound, listening, non-blocking TCP socket. It owns its descriptor and
    closes it when it is destroyed, so there is exactly one place that closes
    the listener. `serve_one_iteration` only borrows it."""

    var _fd: Int32
    var _port: UInt16

    def __init__(out self, fd: Int32, port: UInt16):
        self._fd = fd
        self._port = port

    def __deinit__(deinit self):
        close_fd(self._fd)

    def local_port(self) -> UInt16:
        """The port the socket is bound to (the kernel's choice when the
        caller asked for port 0)."""
        return self._port

    def fd(self) -> Int32:
        """The descriptor, for the loop that accepts on it. It stays owned by
        this value: do not close it."""
        return self._fd


def bind_smtp_listener(bind_be: UInt32, port: UInt16) raises -> ListenSocket:
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
