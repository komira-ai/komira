# =============================================================================
# src/komira_http_core/transport/io_stream.mojo — IoStream + Connector trait pair
# =============================================================================
#
# The single most
# important structural decision in the client RFC: the
# client never holds a raw fd. It holds a value conforming to an
# `IoStream` trait, produced by a value conforming to a `Connector` trait.
# This split is what unifies QUIC-readiness, DPDK-readiness,
# TLS-as-a-wrapper, and the ScriptedStream mock seam.
#
# The runtime seam is monomorphized:
#   * `HttpClient[RT: Runtime]` monomorphization is PROVEN against two
#     distinct Runtime conformers. ZERO `blr` indirect calls in the
#     disassembly. (The Runtime trait + the dispatcher topology is the
#     same one Connector/IoStream codes against here.)
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature on this file.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address=Int(...)`.
#   * `Pending` is the high-risk shape — a POD struct ≤ 16
#     bytes with a single `UInt64` token field. NEVER a long-lived field.
#   * Span origins on `try_read` / `try_write` are open-origin (`Span[
#     UInt8, _]`) — the caller's frame origin propagates. This is the
#     dst-validity contract enforced by the type system
#     point 2 + M-3.
# =============================================================================


from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime


# =============================================================================
# TransportKind — comptime config selector for the client's connector.
# =============================================================================
#
# paragraph "The transport kind a client uses is a comptime
# config selection." `ClientConfig` carries a `TransportKind`; the
# pool-construction layer selects the connector type from that enum at
# comptime via `@parameter if`. The HTTP client driver code above the
# seam — request writer, response parser, pool, retry — is byte-identical
# regardless.
#
# Mojo 1.0.0b1 has no comptime enums (same situation as `RUNTIME_MODEL`).
# We use a `UInt8` sentinel namespace; the call site compares with
# `@parameter if config.TRANSPORT_KIND == TRANSPORT_KIND_KERNEL_TCP`.
# When Mojo gains comptime enums, this becomes a 1-line refactor.
#
# This version ships exactly KERNEL_TCP live; DPDK and QUIC are reserved sentinels
# (the connector trait shape proves the seam accommodates them).

comptime TRANSPORT_KIND_KERNEL_TCP: UInt8 = 0
"""Kernel TCP (default). epoll on Linux, kqueue on macOS. Built on
komira_async.TcpStream + try_io_*. The production path."""

comptime TRANSPORT_KIND_DPDK: UInt8 = 1
"""Reserved sentinel — DPDK kernel-bypass transport. NOT
implemented here; the Connector seam shape proves accommodation."""

comptime TRANSPORT_KIND_QUIC: UInt8 = 2
"""Reserved sentinel — QUIC / HTTP/3 transport. NOT implemented
here; the Connector seam shape proves accommodation."""


# =============================================================================
# NegotiatedProtocol — comptime-value namespace for per-connection ALPN
# result: `negotiated_protocol` is PER-CONNECTION (a
# `TcpIoStream` to an h2 endpoint and one to an h1-only endpoint have
# identical static class but different negotiated protocols).
#
# UInt8 sentinel namespace (same pattern as TRANSPORT_KIND_*).
# =============================================================================

comptime NEGOTIATED_HTTP_1_1: UInt8 = 0
"""Plaintext HTTP/1.1 (no ALPN). The default."""

comptime NEGOTIATED_HTTP_2: UInt8 = 1
"""HTTP/2 over TCP (ALPN-negotiated `h2`). Reserved sentinel;
client HTTP/2 codec wires it."""

comptime NEGOTIATED_HTTP_3: UInt8 = 2
"""HTTP/3 over QUIC (ALPN-negotiated `h3`). Reserved sentinel."""


# =============================================================================
# StreamIo — outcome variant for try_read / try_write.
# =============================================================================
#
# `try_read`/`try_write` return ONE of:
#   * Ready(n)          — bytes already in dst (the completion-model fast
#                         path AND the readiness-model post-syscall return).
#   * Pending(handle)   — the op has been submitted/registered, will
#                         complete later. handle is OPAQUE.
#   * Eof               — peer-side close; no more bytes.
#   * Error(errno)      — hard error.
#
# Implemented as a POD struct with a `_state: UInt8` discriminator + a
# `_payload: Int64` carrying:
#   * For READY: bytes-transferred (positive Int64; fits ssize_t result).
#   * For PENDING: handle token (encoded as Int64; recovered via
#     `.pending_handle()` which extracts as `Pending`).
#   * For EOF: 0 sentinel.
#   * For ERROR: errno (positive Int64).
#
# Size: 16 bytes (1 byte state + 7 padding + 8 byte payload).
# point 4 requires ≤ 16 bytes — satisfied.

comptime STREAM_IO_READY: UInt8 = 0
"""Bytes-transferred. Payload = n bytes (Int64). The completion-model
fast path AND the readiness-model post-syscall return."""

comptime STREAM_IO_PENDING: UInt8 = 1
"""Operation submitted/registered; will complete later. Payload =
opaque handle token (encoded as Int64). The caller parks via the
runtime; the runtime knows how to wait on it."""

comptime STREAM_IO_EOF: UInt8 = 2
"""Peer-side close (0-byte read on a connected socket). No more bytes."""

comptime STREAM_IO_ERROR: UInt8 = 3
"""Hard error. Payload = errno (positive Int64)."""


@fieldwise_init
struct StreamIo(Movable, Deinitable):
    """Outcome variant for IoStream.try_read / try_write. POD; 16 bytes.

    The discriminator `_state` is one of STREAM_IO_READY / STREAM_IO_PENDING
    / STREAM_IO_EOF / STREAM_IO_ERROR.

    Payload semantics:
      * READY: `_payload` is bytes-transferred (Int64, non-negative).
      * PENDING: `_payload` is the opaque continuation handle token
        (Int64; the caller never inspects it — passes back to the
        runtime for parking).
      * EOF: `_payload` is 0 (sentinel; no info).
      * ERROR: `_payload` is errno (positive Int64).

    Construction helpers below mirror the TryIoResult conveniences in
    `komira_async.reactor.socket_io.TryIoResult` — same shape, different
    discriminator namespace.
    """
    var _state: UInt8
    var _payload: Int64

    @staticmethod
    @always_inline
    def ready(n: Int64) -> StreamIo:
        return StreamIo(_state=STREAM_IO_READY, _payload=n)

    @staticmethod
    @always_inline
    def pending(handle_token: Int64) -> StreamIo:
        return StreamIo(_state=STREAM_IO_PENDING, _payload=handle_token)

    @staticmethod
    @always_inline
    def eof() -> StreamIo:
        return StreamIo(_state=STREAM_IO_EOF, _payload=Int64(0))

    @staticmethod
    @always_inline
    def error(errno: Int64) -> StreamIo:
        return StreamIo(_state=STREAM_IO_ERROR, _payload=errno)

    @always_inline
    def is_ready(self) -> Bool:
        return self._state == STREAM_IO_READY

    @always_inline
    def is_pending(self) -> Bool:
        return self._state == STREAM_IO_PENDING

    @always_inline
    def is_eof(self) -> Bool:
        return self._state == STREAM_IO_EOF

    @always_inline
    def is_error(self) -> Bool:
        return self._state == STREAM_IO_ERROR

    @always_inline
    def n_bytes(self) -> Int64:
        """For STREAM_IO_READY: bytes-transferred. UB for other states."""
        return self._payload

    @always_inline
    def errno(self) -> Int64:
        """For STREAM_IO_ERROR: errno value. UB for other states."""
        return self._payload

    @always_inline
    def pending_token(self) -> Int64:
        """For STREAM_IO_PENDING: opaque continuation-handle token.
        The caller passes this back to the runtime — never inspects."""
        return self._payload


# =============================================================================
# Pending — opaque continuation handle.
# =============================================================================
#
# point 1: "Pending is a concrete Movable struct with a
# CONCRETE origin. The handle is a slab-index / registration token — an
# io_uring SQE identity, an epoll registration index — encoded as an
# integer/index in a normal struct field. It is NEVER `UnsafePointer[_,
# MutAnyOrigin]`, NEVER `unsafe_from_address=Int`, NEVER a wildcard origin."
#
# point 3: "Pending is a transient return value, NEVER a
# long-lived field. It is returned from try_read/try_write, parked on,
# and dropped when it resolves. It must NOT become a wildcard-origin
# field on any pool / connection struct."
#
# point 4: "Pending is register-passable (≤ 16 bytes), NOT
# heap-boxed."
#
# Authorship: this is a PEER type to StreamIo. `StreamIo.pending(token)`
# encodes the handle token in the StreamIo payload directly; this `Pending`
# struct exists for sites that want a typed handle for clarity (e.g. a
# future runtime API accepting `Pending` as a parameter). for now, the
# encoded-as-Int64-payload form is what the IoStream contract uses.

@fieldwise_init
struct Pending(Movable, Deinitable):
    """Opaque continuation handle. Sized at 8 bytes (one UInt64 token).
    POD. Movable, NOT Copyable (the runtime tracks at-most-one parker
    per pending op — the type-system carries the single-owner discipline).

    Token interpretation is CONNECTOR-PRIVATE — the HTTP client never
    inspects it. For KernelTcp the token is a (fd<<32) | (interest_bits)
    pack; for a future io_uring connector it would be the SQE-completion
    index; the runtime knows the convention.
    """
    var _token: UInt64

    @staticmethod
    @always_inline
    def from_token(token: UInt64) -> Pending:
        return Pending(_token=token)

    @always_inline
    def token(self) -> UInt64:
        return self._token


# =============================================================================
# IoStream trait — the steady-state byte contract.
# =============================================================================
#
#
#   "A reliable, ordered byte-stream endpoint to one remote peer — an
#    ALREADY-ESTABLISHED connection. The HTTP/1.1 + HTTP/2 codecs run on
#    top of this; it is the seam at which kernel-bypass and HTTP/3 plug in.
#
#    IoStream is the STEADY-STATE contract only. Connection setup is a
#    separate concern — see Connector. A server's accepted connection is
#    an IoStream that was never connect-ed; this is why the byte contract
#    and the setup contract are different traits.
#
#    Every method is non-blocking and reactor-driven: a method that cannot
#    make progress returns Pending carrying an OPAQUE continuation
#    handle — a slab-index/token the caller parks on; the host
#    Runtime knows how to wait on it.
#
#    The trait does NOT own a reactor; it is driven by the caller's
#    Runtime (rt.reactor()), bring-your-own-event-loop. It is
#    Movable, NOT Copyable — it owns a TcpStream (which owns an fd); the
#    pool stores it behind an OwnedPointer."
#
# The runtime parameterization: each
# byte-touching trait method takes `mut rt: RT` and recovers `RT.Sink`
# inside the conformer body (e.g., TcpIoStream.try_read forwards to
# `try_io_read` then on Pending it forwards to `rt.poll_completions(...)`
# through the Runtime trait surface).

trait IoStream(Movable, Deinitable):
    """ Steady-state byte-stream contract over an
    ALREADY-ESTABLISHED connection. Method-parametric on `[RT: Runtime]`
    so the conformer is generic in which runtime drives its reactor.

    Methods are non-blocking + reactor-driven; a method that cannot make
    progress returns `StreamIo.pending(handle)` where handle is opaque.
    The host Runtime knows how to wait on it (the conformer's `try_*`
    body packages a token encoded for the runtime to recover).

    Authorship discipline:
      * ZERO UnsafePointer in any method signature.
      * ZERO wildcard origins.
      * `dst: Span[UInt8, _]` — open origin propagates from the caller,
        which is what point 2 requires for completion-model
        buffer pinning (the dst must outlive the returned Pending).
    """

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        """Read available bytes into `dst`. Returns:
          * StreamIo.ready(n)        — n bytes already in dst.
          * StreamIo.pending(token)  — op registered; caller parks.
          * StreamIo.eof()           — peer cleanly closed.
          * StreamIo.error(errno)    — syscall error.

        Reactor parameterization: `Reactor[Self.RT.Sink]` recovers the
        WakerSink type from the runtime's associated alias. This is the
         sketch's "[S] parameter moves inside the connector body"
        realized concretely — the conformer's body forwards to TcpStream's
        parametric methods with `Self.RT.Sink` as the bound.

        Why a separate `reactor` parameter (not `rt.reactor()`): Mojo
        1.0.0b1 rejects `ref [self]` returns on trait methods (the
        capability-matrix gap reframed by);
        the bring-your-own-event-loop discipline plumbs the reactor as
        an explicit param. The caller (a worker context) already holds
        the reactor; the trait surface keeps it explicit.

        `dst` must remain valid until the returned Pending resolves
        ( point 2 — enforced by Span's origin propagating
        the caller's frame). For a readiness connector this is trivial
        (dst is used at syscall time); for a future completion
        connector (io_uring read), it is the submit-time pin discipline.
        """
        ...

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        """Write bytes from `src`. Returns:
          * StreamIo.ready(n)        — n bytes accepted by kernel/peer.
          * StreamIo.pending(token)  — op registered; caller parks.
          * StreamIo.error(errno)    — syscall error.

        Note: no `eof` state on the write side (peer-side close on read
        is the only EOF; a closed-peer write surfaces as errno EPIPE).

        Reactor parameterization + `src` validity contract: same as on
        try_read."""
        ...

    def close(var self):
        """Tear down the stream. Consumes `self` (one-shot close;
        attempting another I/O on the moved-out value is a compile
        error). The conformer's __del__ is the normal RAII path; this
        method exists for the explicit-close case (e.g., a state
        machine that has finished its protocol and wants to release the
        fd before the parent scope ends).
        """
        ...

    def negotiated_protocol(self) -> UInt8:
        """Per-connection ALPN result. +:
        HTTP/1.1 vs HTTP/2 is the result of ALPN negotiation on THIS
        specific connection — NOT a static property of the connector
        type. A TcpIoStream to an h2 endpoint and one to an h1-only
        endpoint have identical static class but different
        negotiated_protocol() returns. The L2 codec selector reads
        THIS.

        Returns one of NEGOTIATED_HTTP_1_1 / NEGOTIATED_HTTP_2 /
        NEGOTIATED_HTTP_3. For the plaintext-TCP-only path,
        NEGOTIATED_HTTP_1_1 is the default.
        """
        ...

    def fd(self) -> Int32:
        """The underlying socket fd. Used by TLS connector decorators
        to bind a TlsConnection to the stream's fd via s2n's
        `s2n_connection_set_fd`. Conformers that have no kernel fd
        (e.g., ScriptedStream) return -1; consumers that depend on a
        real fd (TlsConnector) gracefully error on -1.

        ⚠ THAT LAST CLAUSE IS AN OBLIGATION ON THE CONSUMER: s2n does not
        perform the detection (`s2n_connection_set_fd` stores -1 happily). It is discharged in `TlsConnector._extract_fd`;
        any NEW consumer that binds this fd to something owes the same check.

        POD return — Int32. No pointer, no ownership transfer. The
        method does NOT take ownership of the fd; the conformer
        retains exclusive ownership and runs close-on-drop via its
        existing RAII path. Callers who borrow the fd (e.g., for
        s2n_connection_set_fd) MUST NOT close it; the conformer's
        drop closes it.

        Added at — additive trait
        extension. Existing conformers (TcpIoStream, ScriptedStream)
        grow the method body in their respective files.
        """
        ...

    def has_buffered_readable(self) -> Bool:
        """Whether the stream holds ALREADY-READABLE bytes that the next
        `try_read` would return WITHOUT touching (and without depending on
        the readiness of) the underlying socket fd.

        DEFAULT False — kernel-socket conformers (`TcpIoStream`) and the
        test mock (`ScriptedStream`) never buffer plaintext ABOVE the fd:
        for them the fd IS the source of the next byte, so a park on
        fd-readiness is always correct. They inherit this default.

        `TlsClientStream` OVERRIDES this to return `s2n_peek(conn) > 0`.
        s2n decrypts in TLS-RECORD units (~16KB plaintext) while the h2/h1
        drivers read in 4096-byte chunks, so one decrypt can drain a whole
        record off the socket and leave the remainder buffered inside s2n's
        userspace buffer. When s2n then reports BLOCKED_ON_READ mid-record,
        the kernel socket fd has NO more bytes (s2n already pulled them) —
        parking on fd-readiness would hang until a bounded deadline /
        wall-clock backstop fires. This predicate lets the driver SKIP the
        park and re-read the already-decrypted remainder instead. The park
        becomes a true "the socket is genuinely the source of the next
        byte" wait.

        This is the fix for the h2 120s wall-deadline
        stall. It is
        the classic OpenSSL `SSL_pending` / s2n `s2n_peek` lost-wakeup
        guard.

        POD return — a Bool. No UnsafePointer crosses; the only added cost
        on the Pending path is one `s2n_peek` FFI on the TLS conformer (a
        pure getter). The hot path (data already present → Ready) is
        untouched — drivers only call this on a read-Pending, before
        parking.

        Default trait method body: conformers that omit it inherit the `return False` below;
        only `TlsClientStream` overrides.
        """
        return False

    def unread(mut self, src: Span[UInt8, _]) raises:
        """Return `src` to the FRONT of this stream's read sequence, so the
        very next `try_read` hands those bytes back before any new byte is
        taken off the wire.

        ⛔ THIS IS WHAT MAKES A CONNECTION SAFE TO CACHE, AND IT IS NOT A
        CONVENIENCE. A message reader on this stream does NOT get to choose
        how many bytes arrive in one `try_read` — the kernel (or s2n) does.
        So a reader that is handed the last byte of its own message plus the
        first bytes of whatever the peer sent next has over-read by an amount
        it could not have predicted, and those bytes belong to the
        CONNECTION, not to the message. `RecvRingBody.take_stream` hands the
        connection to the h1 keepalive cache the moment the body ends; if the
        surplus is dropped there, the NEXT request over that cached
        connection parses a truncated status line and the failure is
        attributed to a peer that sent correct bytes.

        This is the pushback half of the buffered-reader contract every other
        HTTP stack holds structurally: Go's `persistConn` keeps ONE
        `*bufio.Reader` for the life of the connection and the chunked reader
        reads through it, so a surplus is simply still in `pc.br`; hyper's
        `Decoder::decode` returns the unconsumed tail to the connection; h11
        never reads at all and leaves the remainder in the caller's receive
        buffer (`t_body_reader` asserts exactly that on every case). Here the
        body OWNS the stream for the duration of the message, so the stream
        is the only place the surplus can be put and still survive
        `take_stream`.

        Contract:
          * `src` is a PREFIX of the not-yet-consumed read sequence — the
            bytes most recently handed out by `try_read` and not used.
            Calling it with anything else corrupts the stream.
          * Pushed-back bytes are served by `try_read` BEFORE the wire,
            in order, and are visible to `has_buffered_readable()`.
          * Zero-length `src` is a no-op on every conformer.

        ⛔ THE DEFAULT BODY RAISES; IT DOES NOT SILENTLY DROP. A no-op
        default would be the defect this method exists to remove, wearing a
        trait method's clothes — the caller would have discharged its
        obligation, the bytes would still be gone, and nothing would say so.
        A conformer that cannot hold pushback must make the caller close the
        connection instead of caching it, which is what the raise does.

        No pointer crosses the boundary: `src` is a `Span[UInt8, _]` whose
        origin is the caller's frame (same contract as `try_write`), and the
        conformer COPIES out of it — it never retains the span.
        """
        if src.__len__() == 0:
            return
        raise Error(
            String(
                "IoStream.unread: this conformer holds no pushback buffer,"
                " so the "
            )
            + String(src.__len__())
            + String(
                " byte(s) read past the message boundary cannot be returned"
                " to the connection. The connection must be CLOSED, not"
                " cached for reuse."
            )
        )

    def wire_bytes_moved(self) -> Int:
        """Total bytes this stream has moved ACROSS THE SOCKET in either
        direction since it was opened, if the conformer can observe that.
        Monotone non-decreasing; a caller compares two samples and only ever
        asks whether they DIFFER.

        ★★ THIS EXISTS BECAUSE "the I/O returned no bytes" AND "the connection
        is not moving" ARE DIFFERENT FACTS ON A TLS STREAM, and a driver that
        conflates them declares a LIVELOCK on a healthy transfer. A TLS record
        is up to 16 KiB: a peer that delivers one across many TCP segments, or
        drains our writes a segment at a time, keeps `try_read` / `try_write`
        answering Pending while real bytes cross the wire on every trip. See
        `TlsConnection.wire_bytes_moved` for the two s2n code paths (
        `s2n_sendv_with_offset_impl`'s leading `POSIX_GUARD(s2n_flush(...))`
        early return, and `s2n_recv`'s whole-record requirement).

        **DEFAULT 0 — AND THAT IS THE CORRECT ANSWER FOR A KERNEL SOCKET, NOT
        A STUB.** For `TcpIoStream` / `ScriptedStream` there is no layer
        between the caller and the fd: a Pending IS a bare EAGAIN and it moved
        exactly zero bytes, so application progress and wire progress are the
        same number and a driver's existing application-byte accounting is
        already exact. A constant makes every sample equal, so a caller
        comparing two samples reads "no wire progress" — which is precisely
        what an EAGAIN on a raw socket means. Only `TlsClientStream` overrides.

        ⚠ A CONFORMER THAT BUFFERS BELOW ITSELF MUST OVERRIDE THIS. Inheriting
        the default is a CLAIM, not an abstention: it says "my Pending already
        told you everything the wire did".

        POD return — a typed Int. No UnsafePointer crosses; the TLS conformer's
        implementation is two pure s2n getters confined to `s2n_shim`. The cost
        is paid only on a driver's no-progress branch, never on the hot path.

        Default trait method body.
        """
        return 0

    def pending_wait_is_write(
        self, pending_token: Int64, call_is_write: Bool,
    ) -> Bool:
        """Which fd DIRECTION the caller must wait on for a `StreamIo.pending`
        THIS stream just returned. `pending_token` is that Pending's payload;
        `call_is_write` says which method produced it (`try_write` → True).

        WHY THIS EXISTS. A driver that parks on "the direction of the call I
        made" is right for a kernel socket and NOT GUARANTEED for TLS: a
        conformer may block in the opposite direction, and the wrong wait is a
        LIVELOCK rather than a hang (the un-blocked direction of a socket is
        essentially always ready, so the park returns instantly and the retry
        blocks again).

        ⛔ "s2n_send returns BLOCKED_ON_READ on a TLS 1.3 rekey" IS MEASURED
        FALSE, AND THE METHOD STAYS ANYWAY. s2n-tls v1.5.6 structurally cannot
        do it — `s2n_sendv_with_offset_impl`
        only ever writes BLOCKED_ON_WRITE or NOT_BLOCKED, `s2n_recv_impl` only
        BLOCKED_ON_READ or NOT_BLOCKED — confirmed in the s2n source, by a C
        probe (0 occurrences in 1200 calls across 16 real rekeys) and in-repo
        across 80 rekeys with anti-vacuity controls. **NO
        hardcoded-direction site is reachable through a rekey on this s2n**, so
        do not cite one as a trigger.

        ⇒ What this method is FOR is a future s2n bump, kTLS or QUIC, where the
        inversion becomes real: asking the conformer makes that safe BY
        CONSTRUCTION. What it is NOT is the explanation of the closed-peer spin.

        ★ THAT SPIN'S CAUSE is a peer that CLOSED: s2n answers every
        `s2n_recv` after an abrupt peer close (FIN with no close_notify — what
        a load balancer does when it reaps a pooled connection) with
        `(-1, BLOCKED_ON_READ)` FOREVER, because `s2n_recv_impl` presets
        `*blocked` at entry (tls/s2n_recv.c:176) and clears it only on success.
        Mapped to `Pending`, a closed socket is permanently
        READ-ready — so the driver's park returns READY without waiting,
        `idle_parks=0`, forever. The direction bit is RIGHT and
        this method returns it correctly; the fix is one layer down, in
        `s2n_shim._recv_outcome_and_n`, and its falsifier is
        `test_L2_h2_over_tls_abrupt_close_no_spin`.

        The direction is never unknowable: `TlsClientStream` encodes
        it into the Pending token (`(fd << 1) | is_blocked_on_write`,
        tls_connector.mojo `_map_tls_outcome_to_stream_io`). This method is
        the reader of `StreamIo.pending_token()`, and it keeps the ENCODING private to
        the conformer that wrote it: the driver asks the stream, it never
        decodes a token it did not author.

        DEFAULT — `return call_is_write`: for a kernel-socket conformer
        (`TcpIoStream`) and the test mock (`ScriptedStream`) a Pending always
        means EWOULDBLOCK in the direction of the call, so waiting on that
        direction is exactly right and these conformers inherit the default.
        `TlsClientStream` OVERRIDES it.

        POD in, POD out — an Int64 and two Bools; no pointer crosses."""
        _ = pending_token
        return call_is_write


# =============================================================================
# Connector trait — fallible network setup.
# =============================================================================
#
# The contract:
#   "Fallible network setup. connect produces an IoStream. This is
#    where DNS, happy-eyeballs (RFC 8305), connect_timeout, and a future
#    proxy/SOCKS layer live. A Connector may WRAP another Connector — TLS
#    is TlsConnector[C] wrapping a KernelTcpConnector; a proxy is a
#    ProxyConnector[C]. This composition is exactly how rustls's
#    StreamOwned and tokio-rustls layer."
#
# This version ships KernelTcpConnector (live) + ScriptedConnector (test mock).
# TLS lands in; DPDK / QUIC are reserved Connector instantiations
# (the trait surface accommodates without modification).
#
# Mojo 1.0.0b1 trait associated-type form: `comptime Stream: IoStream &
# Movable & Deinitable`. The conformer fixes the binding
# with `comptime Stream = TcpIoStream` (no `:` on the conformer side).
# Downstream code reads via `Self.C.Stream` when `C: Connector` is a
# generic type parameter.

trait Connector(Movable, Deinitable):
    """ Fallible network setup. `connect` produces an IoStream
    (the conformer's `Self.Stream`).

    Authorship discipline: the
    `Connector` and `TlsConnector[C]` associated-type spellings need
    `Self.`-qualified access to struct parameters on Mojo 1.0.0b1 —
    e.g. inside `TlsConnector[C: Connector]`, the wrapped stream type
    is `comptime Stream = TlsStream[Self.C.Stream]` (`Self.C`, not bare
    `C`).

    `Pending` and `IoStream` doc all the lifetime contracts; this
    trait's contract is JUST that `connect` produces a working IoStream.
    """

    comptime Stream: IoStream & Movable & Deinitable

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> Self.Stream:
        """Establish a connection to `ip_be:port`. Drives `reactor`
        until the connection is up. For KernelTcpConnector this is
        TcpStream.connect[Self.RT.Sink](...) + park; for a future
        TlsConnector it ALSO drives the s2n handshake; for a future
        QuicConnector it does the whole secured handshake. The RESULT
        is always just an IoStream — the L7 client cannot tell the
        connectors apart.

        Reactor parameterization (see IoStream.try_read doc): the
        reactor is plumbed as an explicit parameter rather than via
        `rt.reactor()` because Mojo 1.0.0b1 rejects `ref [self]` returns
        on trait methods (the reframe). The
        caller — typically a worker context — already holds the
        Reactor. `[RT: Runtime]` is still threaded through so the
        connect body can read `Self.RT.RUNTIME_MODEL` / `TASKS_ARE_THREAD
        _PINNED` if a future runtime-model-dependent path needs to.

        The `ip_be: UInt32` / `port: UInt16` argument shape mirrors
        `TcpStream.connect[S](reactor, ip_be, port)` in komira_async.
        Higher-level entry points (string-typed `Endpoint`, DNS
        resolution, happy-eyeballs) layer on top in.
        """
        ...

    def transport_kind(self) -> UInt8:
        """The connector's TransportKind sentinel (KernelTcp / Dpdk /
        Quic). The pool-construction layer uses this for `@parameter if`
        selection. For KernelTcpConnector this is
        TRANSPORT_KIND_KERNEL_TCP; for ScriptedConnector this is also
        TRANSPORT_KIND_KERNEL_TCP (the mock pretends to be a TCP
        connector — the codec layer above can't tell).
        """
        ...

    def is_tls(self) -> Bool:
        """Whether the connector establishes a TLS-secured session
        (vs. plaintext TCP). TlsConnector returns True; KernelTcpConnector
        and ScriptedConnector return False. Used by HttpClient.send to
        emit a clear error if the caller wires an HTTPS request to a
        plaintext connector (or vice versa) — a silent
        plaintext-over-`https://` configuration bug otherwise.

        Added at. POD return — Bool. Default
        implementation pattern: conformers default to False unless they
        explicitly wrap a TLS handshake (TlsConnector returns True;
        future ProxyConnector[TlsConnector[...]] returns True).
        """
        ...

    def set_dial_host(mut self, var host: String):
        """★ TELL THE CONNECTOR WHICH HOST THE NEXT `connect` IS **FOR**.

        `connect` takes `ip_be, port` — a NUMERIC address. That is everything
        the kernel needs and it is NOT everything TLS needs: SNI (RFC 6066 §3)
        is a *name*, and on virtual-hosted services the name is what selects
        the certificate AND, for S3, the bucket. So the one fact a numeric dial
        cannot carry is exactly the fact TLS cannot do without.

        THE DEFECT THIS CLOSES. `HttpClient` resolves DNS from
        `req.url.host_copy()` on every send; telling the connector only the
        ADDRESS and never the NAME is wrong. A connector is
        long-lived and one `HttpClient` sends many requests through it, so any
        consumer whose host VARIES between requests would dial the second host
        with the FIRST host's SNI — signing correctly for a host it never
        reached. Two shapes:
          * ★ S3 virtual-hosted addressing puts the BUCKET in the host
            (`<bucket>.s3.<region>.amazonaws.com`), so one process could reach
            exactly ONE bucket.
          * `RedirectLayer` re-invokes the request against the Location URL
            using the SAME connector (`client/redirect.mojo`). 3xx-following
            is opt-in and the default stack omits it.
            ⚠ A cross-origin redirect over
            a PINNED connector still presents the pinned name, because a pin
            wins by design (below). Closing that properly needs a redirect
            following into an unpinned connector, or a stated policy for
            re-pinning on origin change. NOT done here; named so it is not
            mistaken for solved.

        ⛔ THIS IS A DEFAULT, NOT AN OVERRIDE — see `TlsConnector.set_dial_host`.
        A connector whose SNI was set EXPLICITLY
        (`set_server_name_for_next_connect`) IGNORES this call, because the two
        answer different questions: the URL host is "where the bytes go" and an
        explicit SNI is "what name to present", and they legitimately DIFFER —
        `komira_k8s` dials the apiserver by IPv4 dotted-quad while presenting
        the cluster's certificate name. A blanket
        overwrite would hand that dial an IP literal as its SNI and break
        CA-pinned verification.

        Non-TLS conformers (`KernelTcpConnector`) implement this as a NO-OP:
        plaintext TCP has no name to present. `ScriptedConnector` RECORDS it,
        which is how a test asserts what a client told the transport with zero
        sockets.

        Owned `String` in, nothing out, so it composes through decorators;
        `TlsConnector` forwards to its underlying connector as well as applying
        it, so a future stacked decorator sees it too."""
        ...
