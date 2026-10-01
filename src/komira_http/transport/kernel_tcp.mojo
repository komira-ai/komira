# =============================================================================
# src/komira_http/transport/kernel_tcp.mojo — Kernel-TCP Connector + IoStream
# =============================================================================
#
# The production-path Connector +
# IoStream conformers. Reads/writes via kernel TCP (epoll on Linux,
# kqueue on macOS — both via `komira_async.TcpStream` + `try_io_*`).
#
#   The kernel connector + io-stream — `KernelTcpConnector` producing a
#   `TcpIoStream` (wrapped by `TlsConnector[KernelTcpConnector]` for HTTPS),
#   beside the `ScriptedConnector` / `ScriptedStream` mock. It wraps
#   `TcpStream` + `try_io_connect` + `try_io_read/write` over the
#   `komira_async` reactor.
#
# Dependencies:
#   * `TcpStream.connect[S]` (`komira_async` runtime).
#   * `try_io_read` / `try_io_write` (`komira_async` reactor socket I/O).
#   * `IoStream` / `Connector` traits at `./io_stream.mojo`.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address=Int(...)`.
#   * ZERO new `ArcPointer`.
#   * ZERO `take_pointee` outside primitive modules.
#   * The `TcpStream` field uses standard Movable semantics (the existing
#     OwnedPointer-backed fd-stash discipline in TcpStream); no new
#     pointer-discipline introductions.
# =============================================================================


from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_io import (
    TryIoResult,
    try_io_read,
    try_io_write,
)
from komira_async.reactor.socket_setup import set_tcp_nodelay
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.tcp_stream import TcpStream

from .io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)


# =============================================================================
# TcpIoStream — IoStream conformer over komira_async.TcpStream.
# =============================================================================
#
# The contract:
#   * IoStream is the STEADY-STATE byte contract over an
#     ALREADY-ESTABLISHED connection.
#   * Movable but NOT Copyable — it owns a TcpStream (which owns an fd);
#     the pool stores it behind an OwnedPointer.
#   * `try_read` / `try_write` map to `try_io_read` / `try_io_write` on
#     the underlying fd; TryIoResult.{Ready, WouldBlock, Error} map to
#     StreamIo.{ready, pending, error}; a 0-byte Ready maps to
#     StreamIo.eof (peer cleanly closed — kernel TCP convention).
#
# Pending token encoding: for KernelTcp the runtime parks via
# `reactor.poll_completions(...)` directly — the token is informational
# only (the caller of try_read/try_write loops and re-tries; the explicit
# Pending value is used for higher-level state-machine code).
# We encode (fd << 1) | (1 for write, 0 for read) into the token,
# matching the TcpStream._registration shape so a future
# completion-model rewrite has a unambiguous interpretation.

struct TcpIoStream(IoStream, Movable, Deinitable):
    """ IoStream conformer over kernel TCP. Wraps a
    `komira_async.TcpStream`. Movable, NOT Copyable (TcpStream is not
    Copyable — single-owner fd discipline at drop).

    Construction:
      * `TcpIoStream(stream)` — wraps an already-connected TcpStream
        (typically from KernelTcpConnector.connect).

    The Reactor is plumbed per call ( bring-your-own-
    event-loop). The HTTP client's worker context already holds the
    Reactor; the IoStream surface keeps the seam clean.
    """

    var _stream: TcpStream
    var _negotiated: UInt8

    # THE CONNECTION'S OWN PUSHBACK BUFFER — the bytes a message reader took
    # off this socket and handed back because they were not its to keep.
    #
    # ⛔ THIS IS THE FIELD GO HAS AS `persistConn.br` AND WE DID NOT HAVE.
    # Go keeps ONE `*bufio.Reader` for the life of the connection and every
    # response body reads THROUGH it, so bytes a chunked reader pulled past
    # its own terminator are simply still in `pc.br` when the next response
    # is parsed. Our readers own the stream for the duration of one message
    # and hand it back to the h1 keepalive cache, so the surplus has to live
    # on the STREAM or it lives nowhere -- and "nowhere" is a truncated
    # status line on the next request over a cached connection, blamed on a
    # peer that sent correct bytes.
    #
    # ⚠ BOUNDED BY CONSTRUCTION, so this is not a memory surface: it only
    # ever holds what ONE `try_read` over-delivered past ONE message
    # boundary, i.e. at most the scratch size of the reader that filled it
    # (64 KiB for `RecvRingBody`), and `try_read` drains it before touching
    # the socket again. It is empty on every connection that was not
    # over-read, which is the overwhelming majority.
    var _pushback: List[UInt8]

    def __init__(out self, var stream: TcpStream):
        """Wrap an already-connected TcpStream. The negotiated protocol
        defaults to NEGOTIATED_HTTP_1_1 — plaintext-TCP/H1 is the
        path. TLS-over-TCP / HTTP/2 / HTTP/3 set this via a different
        construction path in.
        """
        self._stream = stream^
        self._negotiated = NEGOTIATED_HTTP_1_1
        self._pushback = List[UInt8]()

    def __init__(out self, var stream: TcpStream, negotiated: UInt8):
        """Wrap with explicit ALPN result. Used by TlsConnector
        once ALPN has materialized the per-connection protocol."""
        self._stream = stream^
        self._negotiated = negotiated
        self._pushback = List[UInt8]()

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        """Try to read available bytes into `dst`. Non-blocking; on
        EWOULDBLOCK returns StreamIo.pending(token) and the caller is
        expected to park via reactor.poll_completions until the fd
        surfaces readable (the existing TcpStream._ensure_registered
        path lazily registers on the first WouldBlock).

        Maps TryIoResult → StreamIo:
          Ready(n>0)   → StreamIo.ready(n)
          Ready(n==0)  → StreamIo.eof()      (peer cleanly closed)
          WouldBlock   → StreamIo.pending(token_for_read)
          Error(errno) → StreamIo.error(errno)
        """
        # PUSHBACK FIRST, AND WITHOUT A SYSCALL. `unread` put these bytes
        # here precisely because they had already been taken off this
        # socket; going to the kernel ahead of them would re-order the
        # connection's byte stream, which is the one thing a stream may
        # never do.
        if self._pushback.__len__() > 0 and dst.__len__() > 0:
            return self._drain_pushback(dst)
        var r = try_io_read(self._stream.fd(), dst)
        return Self._map_try_io_to_stream_io(
            r, fd=self._stream.fd(), is_write=False,
        )

    def _drain_pushback[
        o: Origin[mut=True],
    ](mut self, dst: Span[UInt8, o]) -> StreamIo:
        """Serve up to `len(dst)` bytes out of `_pushback`, front-first,
        and retain whatever did not fit. Returns Ready(n) with n > 0 (the
        caller only reaches here with a non-empty pushback AND a non-empty
        dst), so a 0-byte Ready — which the kernel-TCP mapping reads as EOF
        — is unreachable from this path."""
        var have = self._pushback.__len__()
        var n = have
        if dst.__len__() < n:
            n = dst.__len__()
        var i = 0
        while i < n:
            dst[i] = self._pushback[i]
            i = i + 1
        var rest = List[UInt8]()
        var j = n
        while j < have:
            rest.append(self._pushback[j])
            j = j + 1
        self._pushback = rest^
        return StreamIo.ready(Int64(n))

    def unread(mut self, src: Span[UInt8, _]) raises:
        """IoStream override — hold `src` at the front of this socket's
        read sequence. See the `_pushback` field comment for why the
        connection, not the message reader, is where these bytes belong.

        Prepends rather than appends: a second `unread` before the buffer
        drains is pushing back bytes that come EARLIER in the stream than
        the ones already held, so they must be served first."""
        var n = src.__len__()
        if n == 0:
            return
        var merged = List[UInt8]()
        var i = 0
        while i < n:
            merged.append(src[i])
            i = i + 1
        var j = 0
        var have = self._pushback.__len__()
        while j < have:
            merged.append(self._pushback[j])
            j = j + 1
        self._pushback = merged^

    def has_buffered_readable(self) -> Bool:
        """IoStream override — True iff this stream is holding pushback
        bytes that the next `try_read` will serve WITHOUT touching the fd.

        ⛔ OVERRIDING THIS IS NOT OPTIONAL ONCE THE CONFORMER BUFFERS.
        Inheriting the trait's default-False would tell a driver "the fd is
        the source of the next byte" while the next byte is in `_pushback`,
        and the driver would park on fd-readiness that may never come. That
        is byte-for-byte the TLS lost-wakeup this predicate was introduced
        for; a pushback buffer
        is a buffer above the fd for exactly the same reason an s2n record
        buffer is."""
        return self._pushback.__len__() > 0

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        """Try to write bytes from `src`. Same shape as try_read but
        symmetric on the write side. Note: no EOF state on writes
        (peer-side close on a write surfaces as errno EPIPE)."""
        var r = try_io_write(self._stream.fd(), src)
        return Self._map_try_io_to_stream_io(
            r, fd=self._stream.fd(), is_write=True,
        )

    def close(var self):
        """Explicit close — consumes self. The TcpStream's __del__ on
        the moved-out value closes the fd via the existing
        _tcp_close_helper path (deregister-before-close per epoll
        documentation).
        """
        # Consume self via the implicit drop on scope exit.
        # No explicit `_ = self^` needed — the `var self` arg has
        # been moved here, so this function's frame owns the value;
        # frame exit drops it via __del__.
        _ = self._stream^

    def negotiated_protocol(self) -> UInt8:
        """Per-connection ALPN result. The default is
        NEGOTIATED_HTTP_1_1 (plaintext TCP, no ALPN). HTTPS connectors
        call the 2-arg ctor to set the actual ALPN
        result."""
        return self._negotiated

    @staticmethod
    @always_inline
    def _map_try_io_to_stream_io(
        r: TryIoResult, fd: Int32, is_write: Bool,
    ) -> StreamIo:
        """Map komira_async TryIoResult → StreamIo. Static helper —
        ZERO indirection at the trait dispatch site (the trait method
        body inlines through this).

        Pending-token encoding: `(fd << 1) | is_write`. The token is
        opaque to the caller; the encoding here matches what a future
        completion-model rewrite could decode (this is informational
        for now — the actual park path goes through
        `reactor.poll_completions(...)` directly via the higher-level
        state machine in).
        """
        if r.is_ready():
            var n = r.value()
            if n == Int64(0):
                # Kernel TCP convention: a 0-byte successful read
                # signals peer-side cleanly closed (EOF). A 0-byte
                # write is impossible on a non-zero buffer.
                if is_write:
                    return StreamIo.ready(Int64(0))
                return StreamIo.eof()
            return StreamIo.ready(n)
        if r.is_error():
            # TryIoResult._value is the errno on TRY_IO_ERROR.
            return StreamIo.error(r.value())
        # WouldBlock OR InProgress — map both to Pending.
        var token: Int64
        if is_write:
            token = (Int64(fd) << 1) | Int64(1)
        else:
            token = Int64(fd) << 1
        return StreamIo.pending(token)

    @always_inline
    def fd(self) -> Int32:
        """Public accessor for the underlying fd. Used by tests and by
        future completion-model rewrites. NOT a hot-path API for the
        L7 client — that side codes against the trait surface only."""
        return self._stream.fd()


# =============================================================================
# KernelTcpConnector — Connector conformer that dials via kernel TCP.
# =============================================================================
#
# `KernelTcpConnector` produces a `TcpIoStream`.
#
# `connect[RT]` builds a non-blocking TCP socket via
# `TcpStream.connect[RT.Sink](reactor, ip_be, port)`, wraps the connected
# TcpStream in a TcpIoStream, and returns.

#
# The bounded connect deadline for every kernel-TCP dial. See connect()
# docstring + TcpStream.connect's `connect_timeout_us` for the rationale.
# 5_000_000 us = 5s.
comptime _CONNECT_TIMEOUT_US: Int32 = Int32(5_000_000)


@fieldwise_init
struct KernelTcpConnector(Connector, Movable, Deinitable):
    """Connector conformer. The production path: dials kernel
    TCP, returns a `TcpIoStream`.

    Stateless POD — connector instances are cheap and pool-construction-
    layer-managed. The `_placeholder` field exists so `@fieldwise_init`
    has something to fieldwise-init; it is the natural home for a
    connect_timeout + happy-eyeballs config.
    """
    comptime Stream = TcpIoStream

    var _placeholder: UInt8

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> TcpIoStream:
        """Establish a TCP connection to `ip_be:port`. Delegates to
        `TcpStream.connect[RT.Sink](reactor, ip_be, port)` (the
        glue) — that handles non-blocking
        socket creation, the connect(2) syscall, EINPROGRESS parking,
        SO_ERROR recovery, and the close-on-failure discipline.

        The returned TcpStream is wrapped in a TcpIoStream with the
        default NEGOTIATED_HTTP_1_1 protocol.

        TCP_NODELAY is set on the connected fd before return — feature
        parity with hyper (which invokes
        `setsockopt(SOL_TCP, TCP_NODELAY, 1)` at conn start). Disables
        Nagle's algorithm so small HTTP/1.1 request writes are not
        held up by delayed-ACK interaction. Mirrors the server-side
        per-accepted-conn pattern.
        """
        #
        # bound the dial so a hung / slow connect against a saturated
        # backend FAILS FAST (the caller's retry/backoff then handles it)
        # instead of parking forever on poll_completions(-1). The 5s
        # default is generous vs a healthy LAN/loopback dial (sub-ms) yet
        # far below the multi-second indefinite-park stalls a fresh dial
        # can pay against a saturated S3-compatible endpoint. Eager-loopback connects complete in
        # try_io_connect before the bounded park is even reached, so this
        # adds zero latency to the common path.
        var stream = TcpStream.connect[RT.Sink](
            reactor, ip_be, port,
            connect_timeout_us=_CONNECT_TIMEOUT_US,
        )
        # FEATURE PARITY:
        # setsockopt(IPPROTO_TCP, TCP_NODELAY, 1). Standard for HTTP/1.1
        # clients — Nagle + delayed-ACK interacts badly with short
        # request/response patterns. The same `komira_async` socket-setup
        # helper is used on the listener side.
        set_tcp_nodelay(stream.fd())
        return TcpIoStream(stream^)

    def transport_kind(self) -> UInt8:
        """KernelTcpConnector is the kernel-TCP transport (epoll on
        Linux, kqueue on macOS). Static fact — known from the
        connector type."""
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        """Plaintext TCP — no TLS layer. additive trait method."""
        return False

    def set_dial_host(mut self, var host: String):
        """NO-OP. Plaintext TCP dials a NUMBER; there is no name to present.

        This is not an unimplemented stub — it is the whole answer for this
        conformer. SNI is the only reason the trait carries a host at all (see
        `Connector.set_dial_host`), and a plaintext connector has no handshake
        to put a name into. The `Host:` REQUEST HEADER is a different thing
        entirely: it is written from the URL by the codec layer above, and it
        has always been correct."""
        _ = host^

    @staticmethod
    def new() -> KernelTcpConnector:
        """Convenience static constructor — equivalent to
        `KernelTcpConnector(_placeholder=UInt8(0))`."""
        return KernelTcpConnector(_placeholder=UInt8(0))
