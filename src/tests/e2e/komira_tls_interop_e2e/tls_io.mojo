# =============================================================================
# komira_tls_interop_e2e/tls_io.mojo -- komira's side of a connection to a
# peer process: sockets on 127.0.0.1 and a TLS connection driven to a deadline
# =============================================================================
#
# Everything here is non-blocking and single-threaded. Each loop retries a
# step that would block after one poll tick, pumps the peer group (so a
# peer's pipes never fill while komira waits on the socket), and gives up at
# its deadline with an error naming the step and what the peer printed.
#
# komira's sockets are IPv4 on 127.0.0.1. `listen_loopback` binds 127.0.0.1
# on an ephemeral port. `connect_loopback` connects to 127.0.0.1 and is the
# port handshake with a server peer: until the peer listens, a connection is
# refused, and it is retried on a fresh socket after a tick; it fails at the
# deadline, or as soon as the peer has exited. A `bssl s_server` peer does
# not listen on 127.0.0.1 alone: it binds the dual-stack wildcard `[::]`
# (aws-lc's tool/transport_common.cc, Listener::Init), so it needs a kernel
# with IPv6 and dual-stack sockets, and accepts komira's IPv4 connection as
# an IPv4-mapped one.
# =============================================================================

from komira_async.reactor.socket_io import try_io_accept, try_io_connect
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    getsockname_port,
    inet_loopback_be,
    listen_socket,
    sockaddr_in_bytes,
    socket_tcp_nonblocking,
)
from komira_http_core.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
)

from .children import PeerGroup, deadline_after_ms, past, tick

# Linux errno values a non-blocking connect reports (the bssl target, and so
# these tests, are linux x86_64 only).
comptime _ECONNREFUSED = 111
comptime _EISCONN = 106
comptime _EALREADY = 114


struct Socket(Movable):
    """A socket file descriptor, closed when dropped. A TlsConnection bound
    to it does not close it, so the Socket must outlive the connection."""

    var fd: Int32

    def __init__(out self, fd: Int32):
        self.fd = fd

    def __del__(deinit self):
        if self.fd >= Int32(0):
            close_fd(self.fd)


def listen_loopback() raises -> Socket:
    """A listening socket on 127.0.0.1 and an ephemeral port."""
    var s = Socket(socket_tcp_nonblocking())
    bind_inet(s.fd, inet_loopback_be(), UInt16(0))
    listen_socket(s.fd, Int32(16))
    return s^


def local_port(s: Socket) raises -> UInt16:
    return getsockname_port(s.fd)


def free_loopback_port() raises -> UInt16:
    """A port the kernel just handed out on 127.0.0.1, released again, for a
    server peer that takes its port on the command line. Another process
    could take it before the peer binds it. If the peer then fails to bind,
    it exits and `connect_loopback` reports that; if the other process
    listens on 127.0.0.1, `connect_loopback` succeeds to IT, and the test
    fails later, at the handshake or on what the peer reports (it never
    printed a connection). Either way the test fails loudly, never passes."""
    var s = listen_loopback()
    return local_port(s)


def _peer_context(peers: PeerGroup, peer: Int) -> String:
    return "\n--- peer stdout ---\n" + peers.stdout(peer) + "--- peer stderr ---\n" + peers.stderr(peer)


def accept_one(listener: Socket, mut peers: PeerGroup, peer: Int, timeout_ms: Int) raises -> Socket:
    """The first connection to `listener`, from client peer `peer`."""
    var deadline = deadline_after_ms(timeout_ms)
    while True:
        var r = try_io_accept(listener.fd)
        if r.is_ready():
            return Socket(Int32(Int(r.value())))
        if r.is_error():
            raise Error("accept failed, errno " + String(Int(r.value())))
        _ = peers.pump()
        if peers.exited(peer):
            raise Error("the peer exited before connecting" + _peer_context(peers, peer))
        if past(deadline):
            raise Error("no connection in " + String(timeout_ms) + " ms" + _peer_context(peers, peer))
        tick()


def connect_loopback(port: UInt16, mut peers: PeerGroup, peer: Int, timeout_ms: Int) raises -> Socket:
    """A connection to 127.0.0.1:`port`, where server peer `peer` listens
    (or is about to)."""
    var deadline = deadline_after_ms(timeout_ms)
    var addr = sockaddr_in_bytes(inet_loopback_be(), port)
    while True:
        var s = Socket(socket_tcp_nonblocking())
        while True:
            var r = try_io_connect(s.fd, Span[UInt8](addr))
            if r.is_ready():
                return s^
            var errno = Int(r.value()) if r.is_error() else 0
            if errno == _EISCONN:
                return s^
            if errno == _ECONNREFUSED:
                break
            if r.is_error() and errno != _EALREADY:
                raise Error("connect to 127.0.0.1:" + String(Int(port)) + " failed, errno " + String(errno))
            _ = peers.pump()
            if past(deadline):
                raise Error("connect to 127.0.0.1:" + String(Int(port)) + " did not finish" + _peer_context(peers, peer))
            tick()
        # Refused: the peer is not listening yet, or never will be.
        _ = peers.pump()
        if peers.exited(peer):
            raise Error("the peer exited without listening on " + String(Int(port)) + _peer_context(peers, peer))
        if past(deadline):
            raise Error("nothing listened on " + String(Int(port)) + " in " + String(timeout_ms) + " ms" + _peer_context(peers, peer))
        tick()


def handshake(mut conn: TlsConnection, mut peers: PeerGroup, peer: Int, timeout_ms: Int) raises -> String:
    """Drive `conn`'s handshake: the empty string once it is done, or s2n's
    error text (`s2n_strerror_message`) when it fails. Raises at the
    deadline. A call that fails verifying the peer's certificate returns
    only after s2n's blinding delay (10 to 30 s, slept inside the call),
    which the deadline cannot cut short."""
    var deadline = deadline_after_ms(timeout_ms)
    while True:
        var outcome = conn.handshake()
        if outcome == TLS_OUTCOME_DONE:
            return String("")
        if outcome == TLS_OUTCOME_ERROR:
            return s2n_strerror_message(last_s2n_errno())
        _ = peers.pump()
        if past(deadline):
            raise Error("TLS handshake did not finish in " + String(timeout_ms) + " ms" + _peer_context(peers, peer))
        tick()


def send_all(mut conn: TlsConnection, text: String, mut peers: PeerGroup, peer: Int, timeout_ms: Int) raises:
    """Send every byte of `text` over `conn`."""
    var deadline = deadline_after_ms(timeout_ms)
    var bytes = text.as_bytes()
    var sent = 0
    while sent < len(bytes):
        var r = conn.send(bytes[sent:])
        if r[0] == TLS_OUTCOME_ERROR:
            raise Error("TLS send failed: " + s2n_strerror_message(last_s2n_errno()) + _peer_context(peers, peer))
        if r[1] > 0:
            sent += r[1]
            continue
        _ = peers.pump()
        if past(deadline):
            raise Error("TLS send did not finish in " + String(timeout_ms) + " ms" + _peer_context(peers, peer))
        tick()


def read_until(
    mut conn: TlsConnection, stop: String, mut peers: PeerGroup, peer: Int, timeout_ms: Int
) raises -> String:
    """The plaintext read from `conn` until it holds `stop` (when not empty)
    or the peer ends the stream (close_notify, or the socket closing, which
    s2n reports as an end or an error). Raises at the deadline."""
    var deadline = deadline_after_ms(timeout_ms)
    var text = String("")
    while True:
        var buf = List[UInt8](capacity=4096)
        var r = conn.recv(buf, 4096)
        if r[0] == TLS_OUTCOME_DONE and r[1] > 0:
            for i in range(r[1]):
                text += chr(Int(buf[i]))
            if stop.byte_length() > 0 and stop in text:
                return text^
            continue
        if r[0] == TLS_OUTCOME_DONE or r[0] == TLS_OUTCOME_ERROR:
            return text^
        _ = peers.pump()
        if past(deadline):
            raise Error(
                "TLS read did not end in " + String(timeout_ms) + " ms; read so far: '" + text + "'"
                + _peer_context(peers, peer)
            )
        tick()


def close_notify(mut conn: TlsConnection, mut peers: PeerGroup, timeout_ms: Int):
    """Send close_notify. s2n then waits for the peer's; a peer that closes
    its socket instead ends the wait with an error, which is not one here."""
    var deadline = deadline_after_ms(timeout_ms)
    while True:
        var outcome = conn.shutdown()
        if outcome != TLS_OUTCOME_BLOCKED_ON_WRITE and outcome != TLS_OUTCOME_BLOCKED_ON_READ:
            return
        if outcome == TLS_OUTCOME_BLOCKED_ON_READ:
            # Our close_notify is flushed; the peer's answer is not needed.
            return
        _ = peers.pump()
        if past(deadline):
            return
        tick()
