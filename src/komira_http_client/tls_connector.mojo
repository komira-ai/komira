# =============================================================================
# src/komira_http_client/tls_connector.mojo — TLS client Connector + IoStream
# =============================================================================
#
# TlsConnector[KernelTcpConnector] adds ONLY the client-mode connector
# and a client `TlsConfig` ON TOP of the server s2n-tls module: trust
# store, verify-peer, SNI send, ALPN advertise, and a session-resumption
# cache.
#
# Composition: TlsConnector is a Connector decorator over
# another Connector. In production the underlying connector is
# `KernelTcpConnector`; the seam admits any IoStream-producing Connector
# (e.g., `ScriptedConnector` for tests, future `DpdkConnector`).
#
# Public surface:
#   * `TlsConnector[U: Connector]` — generic over the underlying connector.
#     Holds an `OwnedPointer[TlsConfig]` (stable heap address for the
#     long-lived per-client config; the ref-borrow contract requires
#     TlsConfig to outlive every connection) and an owned `U`.
#   * `TlsClientStream[US: IoStream]` — IoStream conformer wrapping the
#     underlying stream + a `TlsConnection`. Owns the underlying stream
#     for fd-lifetime / RAII close discipline; the TlsConnection holds a
#     non-owning fd via `bind_fd(...)` and runs s2n directly on that fd
#     (matches the server-side pattern).
#
# Handshake driver:
#   `TlsConnector.connect[RT]` runs a synchronous handshake-to-DONE loop
#   inside the connect body. On `BLOCKED_ON_READ` / `BLOCKED_ON_WRITE`,
#   the underlying IoStream's `try_read` / `try_write` is invoked with
#   a 0-byte buffer to drive the reactor's park/wake path. Pathological
#   non-progress is bounded by a WALL-CLOCK deadline, NOT by a count of
#   loop trips — see the §1 banner for why.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee` (Optional.take + OwnedPointer.into_inner are the
#     replacement primitives per the pointer rules).
#   * ZERO new ArcPointer (TlsConfig held via OwnedPointer — single
#     owner; underlying connector / stream owned in line).
#   * ZERO additive parallel API.
#
# Pointer audit:
#   * `TlsClientStream[US]` owns `US` (heap-owning IoStream) +
#     `TlsConnection` (Movable, OwnedPointer-of-handle-backed). Both
#     fields move with the struct; neither nests in a byte-slab — they
#     live as struct fields on the consumer's stack/struct directly OR
#     behind the pool's `Slab[OwnedPointer[ClientConn[TlsClientStream[US]]]]`,
#     which is the pointer-safe shape per's finding.
#   * `TlsConnector[U]` owns `OwnedPointer[TlsConfig]` + `U`. OwnedPointer
#     gives the TlsConfig a stable heap address; on TlsConnector move,
#     the OwnedPointer handle (POD 8 bytes) moves; the TlsConfig itself
#     stays put.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

# The MONOTONIC clock the handshake's wall-clock deadline is measured on — the
# same import h2_client.mojo uses for `drive_h2_streams_to_completion`'s wall
# bound, so both loops in this subsystem answer "how long has this taken" from
# one source.
from komira_clock import now_ns as _mono_now_ns
from komira_http_client.slow_phase import (
    SLOW_PHASE_TLS_HANDSHAKE,
    elapsed_ms_since,
    note_slow_phase,
)

from komira_http_client.pool import (
    ALPN_UNKNOWN,
    PoolKey,
    SCHEME_HTTPS,
    VERIFY_PEER,
    VERIFY_SKIP,
)
from komira_http_client.session_cache import SessionCache
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_debug_message,
    s2n_strerror_message,
)

from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    NEGOTIATED_HTTP_2,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)


# =============================================================================
# §1 — Constants
# =============================================================================
#
# ⛔ THE HANDSHAKE BUDGET IS WALL-CLOCK TIME, NOT AN ITERATION COUNT.
#
# WHAT AN ITERATION BUDGET DOES. It fails a live handshake with
#   `TlsConnector.connect: handshake exceeded 256 iterations
#    (s2n_errno=201326592)`
# 201326592 = 0x0C000000 = `3 << S2N_ERR_NUM_VALUE_BITS` = the BASE of s2n's
# `S2N_ERR_T_BLOCKED` range = `S2N_ERR_IO_BLOCKED` ("underlying I/O operation
# would block", error/s2n_errno.h). ⇒ **NOTHING HAS FAILED.** s2n's own
# verdict is "healthy, not finished", and the client hangs up on it.
#
# WHY. An iteration is not a unit of time OR of progress:
#   * an iteration whose park returned EARLY (a wake-eventfd drain, a
#     completion for someone else's op_id, an EINTR-shortened epoll_wait)
#     costs ~0 µs and still spends 1/256th of the budget;
#   * an iteration whose park runs the full slice costs 250 ms.
# So the effective timeout is anywhere in [~0 s, 64 s] and is stated
# nowhere. Any transient that makes a handful of parks return early evaporates
# the budget on a handshake that is milliseconds old, and a plain retry
# succeeds.
#
# THE SIBLING LOOP IN THIS SAME SUBSYSTEM HAS THE SAME ANSWER.
# `drive_h2_streams_to_completion` (h2_client.mojo) takes BOTH bounds, and
# its comment names this failure mode: "WITHOUT the wall-clock bound, a conn that parks-then-repolls-
# Pending in a tight cycle would burn the iteration cap at ~one park-deadline
# per iter — the wall-clock check makes the overall deadline a real,
# configurable wall bound independent of the per-park granularity."
# `TlsConnector.connect` has the bounded PARK and the wall clock.
#
# RAISING THE CAP WOULD BE A BAND-AID: it re-denominates the budget in
# the same broken unit. The unit is the defect.

comptime _HANDSHAKE_DEADLINE_DEFAULT_US: Int64 = 30_000_000
"""THE handshake budget: 30 s of WALL-CLOCK time in `TlsConnector.connect[RT]`,
measured on the monotonic clock, independent of how many times the loop went
round or how long any individual park happened to wait.

Sized the way the h2 driver's `_H2_DRIVE_DEFAULT_WALL_US` is: far above any
healthy handshake (a public-CA TLS 1.3 dial typically completes in tens of
milliseconds, so this is hundreds of times that) and far below the
process-level timeouts that would otherwise mask a genuinely wedged peer.

Override per connector with `TlsConnector.set_handshake_deadline_us` — for a
pathologically slow network, and the knob the regression test drives."""

comptime _HANDSHAKE_DEADLINE_MAX_US: Int64 = 86_400_000_000
"""The largest handshake budget `set_handshake_deadline_us` accepts (24 h). A
larger value is treated as a typo and leaves the budget unchanged: a deadline
can be stated, never effectively disabled."""

comptime _HANDSHAKE_NO_FD_ITER_CAP: Int = 256
"""Spin cap for a stream with no fd to park on. There the loop cannot block on
readiness, so a bounded spin is the only available bound and an iteration IS
the unit. It is NOT the production bound — a real dial always has an fd and is
governed by `_HANDSHAKE_DEADLINE_DEFAULT_US`.

⚠ NOTHING REACHES IT THROUGH `connect`: `_extract_fd` refuses
`fd < 0` before an s2n connection is even allocated, so the fd-less arm of the
handshake loop is a retained backstop rather than a live path. It is kept
because degrading to a bounded spin is the safe failure if a fd-less stream is
ever re-admitted; parking on a non-descriptor is not."""

comptime _HANDSHAKE_POLLS_PER_SLICE_CAP: Int = 4096
"""CPU brake on the inner park loop. If `poll_completions` returns without OUR
op_id becoming ready (a drained wake-eventfd, a foreign completion) the inner
loop RE-PARKS for the remaining slice rather than re-entering s2n — that is the
whole point, since s2n already told us it is blocked and nothing has changed.
This cap bounds the pathological case where such a return happens with no
measurable time elapsed, so the loop cannot pin a core between clock ticks; on
hitting it we fall back to the outer loop, which is still deadline-bounded."""

comptime _HANDSHAKE_PARK_DEADLINE_US: Int32 = 250_000
"""Per-park BOUNDED reactor wait inside the
handshake-to-DONE loop. The PRIOR code parked on
`poll_completions(timeout_us=Int32(-1))` — an UNBOUNDED wait, the same
missed-wakeup hazard the h2 driver's `_park_on_fd_readiness` fixed (an
unresponsive peer / AsyncRT readiness race leaves the wait blocked FOREVER, so
the loop never regains control to convert the hang into a typed handshake
failure). Bounding the wait returns control to the loop, which re-attempts the
handshake and eventually trips the WALL-CLOCK deadline (a typed
TlsHandshakeFailed) instead of hanging. Level-triggered fd registration means a
genuine wake still fires in µs, so a healthy slow handshake never false-trips —
mirrors the h2 driver's `_H2_PARK_DEADLINE_US`.

⚠ THIS IS A GRANULARITY, NOT A BUDGET. It is how finely the loop regains
control; `_HANDSHAKE_DEADLINE_DEFAULT_US` is how long the loop is allowed to
take. Conflating the two is the bug this file's §1 banner describes."""


# =============================================================================
# §2 — TlsClientStream — IoStream conformer wrapping (US, TlsConnection)
# =============================================================================
#
# A TLS-wrapped IoStream. Owns the underlying IoStream `US` (typically
# `TcpIoStream`) for fd-lifetime + close discipline; owns a
# `TlsConnection` post-`new_client(config)` + `bind_fd(...)`.
#
# Method bodies for `try_read[RT, o]` / `try_write[RT]`:
#   - Delegate to `_conn.recv_into_span(dst)` / `_conn.send(src)`.
#   - On `TLS_OUTCOME_DONE`: return `StreamIo.ready(n)` or `StreamIo.eof()`
#     when n==0 (s2n's "peer sent close_notify" convention).
#   - On `TLS_OUTCOME_BLOCKED_ON_READ` / `_ON_WRITE`: return
#     `StreamIo.pending(token)` — the caller's reactor-park loop drives
#     the next read/write retry. The token encodes the underlying fd +
#     interest direction (same shape as TcpIoStream's pending token).
#   - On `TLS_OUTCOME_ERROR`: return `StreamIo.error(errno)` — the s2n
#     errno is read via `last_s2n_errno()` (thread-local; must be queried
#     IMMEDIATELY after the call, before any other s2n FFI).
#
# Movability: TlsClientStream is Movable (US is Movable, TlsConnection
# is Movable) but NOT Copyable (US owns an fd; TlsConnection owns an
# s2n handle).


struct TlsClientStream[US: IoStream & Movable & Deinitable](
    IoStream, Movable, Deinitable,
):
    """IoStream conformer wrapping (US, TlsConnection). The US owns the
    fd lifetime; the TlsConnection holds a non-owning fd via bind_fd and
    runs s2n send/recv directly on that fd.

    Construction:
      * `TlsClientStream(underlying, conn)` — wraps an already-handshaken
        (US, TlsConnection) pair. The factory path is
        `TlsConnector.connect[RT]` which constructs the pair AND drives
        the handshake to DONE before returning.

    Lifecycle:
      * `try_read[RT, o]` — delegates to conn.recv_into_span; outcome
        mapping above.
      * `try_write[RT]` — delegates to conn.send; outcome mapping above.
      * `close(var self)` — initiates a graceful TLS shutdown (best-
        effort; ignores BLOCKED outcomes since we're tearing down), then
        drops the underlying US (which closes the fd via RAII).
      * `negotiated_protocol(self)` — returns the ALPN-negotiated value
        captured at handshake DONE. Defaults to NEGOTIATED_HTTP_1_1
        (the only protocol advertises in its ALPN list).
    """

    var _underlying: Self.US
    var _conn: TlsConnection
    var _negotiated: UInt8
    var _session_resumed: Bool

    # THE CONNECTION'S OWN PUSHBACK BUFFER — PLAINTEXT, and that is the
    # whole reason it cannot live on `_underlying`. `unread` is handed
    # DECRYPTED bytes that a message reader took past its own boundary;
    # the underlying stream speaks ciphertext, so pushing them down there
    # would feed record bytes that are not records into s2n. They belong
    # at this layer, above the decrypt, next to s2n's own peek buffer.
    # Same bound as `TcpIoStream._pushback` (one over-delivered read),
    # drained before any further `s2n_recv`.
    var _pushback: List[UInt8]

    def __init__(
        out self, var underlying: Self.US, var conn: TlsConnection,
    ):
        """Wrap a connected underlying stream + a handshaken TlsConnection.
        The `_negotiated` defaults to NEGOTIATED_HTTP_1_1; the
        TlsConnector handshake driver sets the actual ALPN result via
        the 3-arg ctor below once ALPN-readback FFI is bound.
        `_session_resumed` defaults to False — the 4-arg ctor below sets
        the actual resumption status once the handshake completes.
        """
        self._underlying = underlying^
        self._conn = conn^
        self._negotiated = NEGOTIATED_HTTP_1_1
        self._session_resumed = False
        self._pushback = List[UInt8]()

    def __init__(
        out self, var underlying: Self.US, var conn: TlsConnection,
        negotiated: UInt8,
    ):
        """Wrap with explicit ALPN result. Used by TlsConnector once
        ALPN-readback is wired. `_session_resumed` defaults to False —
        use the 4-arg ctor when the session-cache wire-in is also active.
        """
        self._underlying = underlying^
        self._conn = conn^
        self._negotiated = negotiated
        self._session_resumed = False
        self._pushback = List[UInt8]()

    def __init__(
        out self, var underlying: Self.US, var conn: TlsConnection,
        negotiated: UInt8, session_resumed: Bool,
    ):
        """Wrap with explicit ALPN result + session-resumption status.
        Used by TlsConnector when the session cache is wired — the
        connector reads `is_session_resumed()` from the TlsConnection
        AFTER handshake DONE and threads the boolean here.
        """
        self._underlying = underlying^
        self._conn = conn^
        self._negotiated = negotiated
        self._session_resumed = session_resumed
        self._pushback = List[UInt8]()

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        """Decrypt + read into `dst`. Maps TLS_OUTCOME_* → StreamIo:

          DONE + n>0  → StreamIo.ready(n)
          DONE + n==0 → StreamIo.eof() (peer sent close_notify)
          BLOCKED_ON_READ  → StreamIo.pending(token_for_read)
          BLOCKED_ON_WRITE → StreamIo.pending(token_for_write)
          ERROR            → StreamIo.error(s2n_errno)

        The reactor parameter is currently UNUSED by the TLS layer —
        s2n issues read/write syscalls on the bound fd directly; the
        caller's reactor parks on fd readiness when BLOCKED is returned.
        Reserved here for symmetry with the IoStream trait and for a
        future completion-model rewrite.
        """
        _ = reactor  # reserved for completion-model rewrite
        # PUSHBACK FIRST, AHEAD OF THE DECRYPT. These bytes were already
        # decrypted and already handed out once; s2n has no memory of them,
        # so serving a fresh record ahead of them would re-order the
        # connection's plaintext stream.
        if self._pushback.__len__() > 0 and dst.__len__() > 0:
            return self._drain_pushback(dst)
        var result = self._conn.recv_into_span(dst)
        var outcome = result[0]
        var n = result[1]
        return Self._map_tls_outcome_to_stream_io(
            outcome, n, fd=self.fd(), is_write=False,
        )

    def _drain_pushback[
        o: Origin[mut=True],
    ](mut self, dst: Span[UInt8, o]) -> StreamIo:
        """Serve up to `len(dst)` plaintext bytes out of `_pushback`,
        front-first, retaining the remainder. Only reached with a non-empty
        pushback AND a non-empty dst, so `n > 0` and the 0-byte Ready that
        the TLS mapping reads as peer close_notify is unreachable here."""
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
        """IoStream override — hold `src` (PLAINTEXT) at the front of this
        connection's read sequence. See the `_pushback` field comment for
        why it is held here and not pushed down to `_underlying`.

        Prepends: a later `unread` is pushing back bytes that precede the
        ones already held."""
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

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        """Encrypt + write from `src`. Maps TLS_OUTCOME_* → StreamIo:

          DONE       → StreamIo.ready(n)        (may be partial)
          BLOCKED_ON_WRITE → StreamIo.pending(token_for_write)
          BLOCKED_ON_READ  → StreamIo.pending(token_for_read)
                            (only on TLS rekey; rare)
          ERROR      → StreamIo.error(s2n_errno)

        Reactor parameter currently UNUSED (see try_read).
        """
        _ = reactor  # reserved for completion-model rewrite
        var result = self._conn.send(src)
        var outcome = result[0]
        var n = result[1]
        return Self._map_tls_outcome_to_stream_io(
            outcome, n, fd=self.fd(), is_write=True,
        )

    def close(var self):
        """Tear down the TLS layer + underlying stream. Best-effort
        graceful shutdown (sends close_notify; ignores BLOCKED) then
        drops both fields. The underlying US's `close(var self)` runs
        via the implicit drop on scope exit; the TlsConnection's __del__
        wipes the s2n_connection internally before freeing.

        One-shot — the moved-out `self` cannot be reused.
        """
        # Best-effort graceful shutdown. We don't block on BLOCKED here;
        # the caller already decided to tear down, so a partial
        # close_notify exchange is acceptable.
        var _outcome = self._conn.shutdown()
        # Implicit drop: self._conn's __del__ frees s2n; self._underlying's
        # __del__ closes the fd via TcpStream's RAII close-on-drop path.

    def negotiated_protocol(self) -> UInt8:
        """ALPN-negotiated protocol for THIS connection.

        TlsConnector.connect[RT] now reads s2n's
        `s2n_get_application_protocol` post-handshake-DONE and maps
        the resulting string to one of the NEGOTIATED_* sentinels:

          * "h2"        → NEGOTIATED_HTTP_2
          * "http/1.1"  → NEGOTIATED_HTTP_1_1
          * None / ""   → NEGOTIATED_HTTP_1_1 (defensive: no ALPN
                          extension used / no overlap with peer).

        The caller (HttpClient.send) dispatches to the h1 OutboundDriver
        or the h2 send_request_on_h2_conn path based on this value.
        """
        return self._negotiated

    def fd(self) -> Int32:
        """The underlying socket fd. IoStream trait method.
        Returns the fd both `_underlying` and
        `_conn` are bound to (they share the fd by construction)."""
        return self._conn.fd()

    def _conn_quic_enabled_for_test(self) -> Int32:
        """TEST-ONLY: probe the wrapped s2n connection's `quic_enabled` bit via
        the `s2n_connection_is_quic_enabled` unstable-API symbol, for the
        stray-write regression falsifier
        (`tests/test_L1_tls_connector_move_no_stray_write.mojo`).
        Returns 1 if the bit is set, 0 if clear. NOT part of the public
        surface; not called by any production path.

        This lets the falsifier detect a stray write into the s2n connection
        (`conn->quic_enabled` flipped False->True across the `return _stream^`
        move out of the connector) on the REAL `TlsClientStream` layout, not a
        stand-in. Delegates to `TlsConnection._raw_conn_ptr_for_test()` +
        the read-only s2n probe."""
        # SAFETY: read-only unstable-API probe over the live wrapped s2n
        # connection (alive for the call). The unstable-API signature is
        # `bool s2n_connection_is_quic_enabled(struct s2n_connection*)` — it
        # RETURNS the bit directly (verified against api/unstable/quic.h; there
        # is NO out-parameter). We marshal the bool return.
        var raw = self._conn._raw_conn_ptr_for_test()
        var enabled = external_call["komira_s2n_connection_is_quic_enabled", Bool](raw)
        if enabled:
            return Int32(1)
        return Int32(0)

    def has_buffered_readable(self) -> Bool:
        """IoStream override — True iff s2n holds decrypted plaintext that
        the next `try_read` would return WITHOUT touching the socket fd.

        OVERRIDES the trait's default-False (TcpIoStream / ScriptedStream
        keep the default; they never buffer plaintext above the fd). s2n
        decrypts in TLS-RECORD units (~16KB plaintext) while the h2/h1
        drivers read in 4096-byte chunks, so one decrypt can pull a whole
        record off the socket and leave the remainder buffered inside s2n;
        when s2n then returns BLOCKED_ON_READ mid-record the socket fd has
        no more bytes and a park on fd-readiness would hang. The driver
        calls this BEFORE parking on a read-Pending and re-reads the
        buffered remainder instead.

        Delegates to `TlsConnection.has_buffered_readable()` →
        `s2n_peek(conn) > 0`. The s2n_peek FFI is confined to s2n_shim;
        this method returns only a POD Bool (no pointer crosses). Fix for
        the h2 120s wall-deadline stall.

        ⚠ TWO BUFFERS SIT ABOVE THE FD HERE, NOT ONE. s2n's own record
        remainder is the historical half; `_pushback` — plaintext an
        `unread` returned to the connection — is the second, and it has the
        identical lost-wakeup consequence if it is not reported. The
        predicate is the OR of both."""
        if self._pushback.__len__() > 0:
            return True
        return self._conn.has_buffered_readable()

    def wire_bytes_moved(self) -> Int:
        """IoStream override — s2n's own `wire_bytes_in + wire_bytes_out` for
        this connection.

        OVERRIDES the trait's default-0. `TcpIoStream` / `ScriptedStream` keep
        it, correctly: on a raw socket a Pending IS a bare EAGAIN that moved
        zero bytes, so their application-byte accounting is already exact. On
        THIS conformer it is not, and the gap is the whole reason the method
        exists — `s2n_send` reports zero plaintext accepted while its leading
        `s2n_flush` writes to the socket, and `s2n_recv` reports zero plaintext
        while it accumulates a partial record. A driver that calls either
        "no progress" declares `HttpError[LIVELOCK]` over a healthy transfer.

        Delegates to `TlsConnection.wire_bytes_moved()`; the two
        `s2n_connection_get_wire_bytes_*` FFIs are confined to `s2n_shim`, and
        this method returns only a POD Int (no pointer crosses)."""
        return self._conn.wire_bytes_moved()

    def pending_wait_is_write(
        self, pending_token: Int64, call_is_write: Bool,
    ) -> Bool:
        """IoStream override — THE READER FOR THE DIRECTION BIT THIS FILE
        WRITES. `_map_tls_outcome_to_stream_io` encodes every Pending as
        `(fd << 1) | is_blocked_on_write`; this decodes bit 0.

        TLS MAY INVERT THE DIRECTION AND THE DEFAULT CANNOT KNOW THAT, so this
        override reports what the conformer itself recorded rather than what
        the caller assumed. Parking on the call's direction when they differ is
        a LIVELOCK, not a slow wait: the un-blocked direction is (for a write)
        essentially always ready, so the park returns instantly and the retry
        blocks again.

        ⛔ ON THIS s2n THE TWO NEVER DIFFER, AND THAT IS MEASURED, NOT ASSUMED.
        Neither "`s2n_send` returns BLOCKED_ON_READ on a rekey" nor
        "`s2n_recv` returns BLOCKED_ON_WRITE when it owes the peer a
        record" holds for s2n-tls v1.5.6:
        `s2n_sendv_with_offset_impl` writes only BLOCKED_ON_WRITE/NOT_BLOCKED
        and `s2n_recv_impl` only BLOCKED_ON_READ/NOT_BLOCKED — in the source, in
        a C probe (0 of 1200 calls over 16 real rekeys) and in-repo over 80
        rekeys. The seam stays because it makes a future s2n bump / kTLS / QUIC
        safe by construction. It is NOT the explanation of a spin on an abrupt
        peer close: that is a close laundered into `Pending` one layer down —
        see `s2n_shim._recv_outcome_and_n`. See the trait docstring for both."""
        _ = call_is_write
        return (pending_token & Int64(1)) == Int64(1)

    def session_resumed(self) -> Bool:
        """Session-cache accessor — True if this
        connection's TLS handshake was abbreviated via session resumption
        (TLS 1.2 ticket OR TLS 1.3 PSK). False on a full handshake.

        Used by the session-resumption test to assert that a second
        connect to the same PoolKey resumed via the cache. The value is
        set by `TlsConnector.connect[RT]` after handshake DONE; it does
        NOT update on subsequent connections (one TlsClientStream =
        one handshake outcome).
        """
        return self._session_resumed

    @staticmethod
    @always_inline
    def _map_tls_outcome_to_stream_io(
        outcome: UInt8, n: Int, fd: Int32, is_write: Bool,
    ) -> StreamIo:
        """Map (outcome, n) tuple from TlsConnection.send/recv_into_span
        to StreamIo. Static helper for hot-path inlining."""
        if outcome == TLS_OUTCOME_DONE:
            if n == 0 and not is_write:
                # s2n recv returning 0 = peer sent close_notify (graceful EOF).
                return StreamIo.eof()
            return StreamIo.ready(Int64(n))
        if outcome == TLS_OUTCOME_ERROR:
            return StreamIo.error(Int64(Int(last_s2n_errno())))
        # BLOCKED_ON_READ or BLOCKED_ON_WRITE → Pending.
        # Pending token encoding: (fd << 1) | is_blocked_on_write.
        var token: Int64
        if outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
            token = (Int64(fd) << 1) | Int64(1)
        else:
            token = Int64(fd) << 1
        return StreamIo.pending(token)


# =============================================================================
# §3 — TlsConnector — Connector decorator over an underlying Connector
# =============================================================================
#
# The contract:
#   "A Connector may WRAP another Connector — TLS is TlsConnector[C]
#    wrapping a KernelTcpConnector; a proxy is a ProxyConnector[C]. This
#    composition is exactly how rustls's StreamOwned and tokio-rustls
#    layer."
#
# `connect[RT]` (the trait method):
#   1. Delegates to the underlying connector: `underlying.connect[RT](
#      reactor, ip_be, port)` — produces a connected `U.Stream`.
#   2. Constructs `TlsConnection.new_client(config)` + binds the
#      underlying stream's fd.
#   3. Sets SNI via `set_server_name(server_name)` — the server name is
#      the caller-supplied String (typically the URL host).
#   4. Drives the handshake to DONE: loops `_conn.handshake()` until
#      DONE (success), ERROR (raises), or the WALL-CLOCK deadline
#      `_HANDSHAKE_DEADLINE_DEFAULT_US` elapsed (raises)
#      (raises). On BLOCKED, the loop yields to the underlying stream's
#      `try_read` / `try_write` with a 0-byte buffer to let the reactor
#      drive its park/wake — same pattern as the L1 socketpair
#      handshake test, scaled up for the real-reactor path.
#   5. Wraps the (underlying, conn) pair in a TlsClientStream and
#      returns.
#
# NOTE: The basic `connect[RT]` method on the trait takes `ip_be, port`
# (numeric address); SNI is NOT part of that signature. Callers who need
# SNI (the production HTTPS path) construct the TlsConnector with the
# server name as a field set per-dial via the connector helper
# `set_server_name_for_next_connect(host)`, or receive it per request via
# `Connector.set_dial_host`.

struct TlsConnector[
    U: Connector & Movable & Deinitable,
](Connector, Movable, Deinitable):
    """TLS Connector decorator over an underlying Connector. Generic
    over the underlying connector type via `U: Connector`.

    Construction:
      * `TlsConnector(config, underlying)` — owned config + owned underlying.
      * `TlsConnector.over(config, underlying)` — convenience factory.

    Per-dial setup:
      * `set_server_name_for_next_connect(host)` — set the SNI value the
        NEXT `connect[RT]` call will use. The value is stored on the
        struct and consumed by the next connect; subsequent connects
        re-use the same name until updated.

    Lifetime: the TlsConfig must outlive every TlsClientStream the
    connector produces (the `ref [config]` borrow contract).
    OwnedPointer storage gives the config a stable heap address;
    consumer code typically constructs ONE TlsConnector with a
    long-lived TlsConfig and reuses it for the process lifetime.
    """

    comptime Stream = TlsClientStream[Self.U.Stream]

    var _config: OwnedPointer[TlsConfig]
    var _underlying: Self.U
    var _server_name: String
    # ★ WHETHER `_server_name` WAS SET **EXPLICITLY**.
    #
    # The whole point of this flag is that "the host in the URL" and "the name
    # to present in the handshake" are DIFFERENT QUESTIONS that usually have
    # the same answer — and the case where they differ is a production path,
    # not a hypothetical: `komira_k8s` dials the apiserver by IPv4
    # dotted-quad while presenting the CLUSTER's
    # certificate name, verified against a pinned cluster CA. Handing that dial
    # its URL host as SNI would present an IP literal to a CA-pinned peer.
    #
    # So `set_server_name_for_next_connect` PINS (an operator said this name),
    # and `set_dial_host` — the per-request push `HttpClient` performs —
    # only fills in an UNPINNED connector.
    var _sni_pinned: Bool
    # per-pthread TLS session-ticket cache.
    # OwnedPointer for stable heap address; same Box<T> pattern as _config.
    # Single-thread-access (one TlsConnector per pthread); NO atomics / locks.
    var _session_cache: OwnedPointer[SessionCache]
    # The verify_mode this connector was built with. Used to construct
    # PoolKeys for cache lookup/store so the cache is bucketed correctly
    # vs same-host + different-verify_mode entries.
    # Default: VERIFY_PEER (set via the 2-arg ctor); callers building a
    # `disable_verify()` connector use the 3-arg ctor with VERIFY_SKIP.
    var _verify_mode: UInt8
    # The wall-clock handshake budget for `connect` (µs). Defaults to
    # `_HANDSHAKE_DEADLINE_DEFAULT_US`; `set_handshake_deadline_us` overrides it.
    var _handshake_deadline_us: Int64

    def __init__(
        out self, var config: TlsConfig, var underlying: Self.U,
    ):
        """Construct with owned config + owned underlying connector.
        Initial SNI is empty; callers MUST call
        `set_server_name_for_next_connect(host)` before the first
        `connect[RT]` for production HTTPS (SNI is required by
        virtually every modern HTTPS server).

        verify_mode defaults to VERIFY_PEER for the 2-arg form. Callers
        constructing a disable-verify connector should use the 3-arg
        `__init__(config, underlying, verify_mode)` overload to keep
        the session cache bucketed correctly.

        SessionCache is constructed with DEFAULT_MAX_SESSION_CACHE_ENTRIES
        (1024). Tune via a custom factory if the deployment needs more.
        """
        self._config = OwnedPointer[TlsConfig](config^)
        self._underlying = underlying^
        self._server_name = String("")
        self._sni_pinned = False
        self._session_cache = OwnedPointer[SessionCache](
            SessionCache.with_defaults(),
        )
        self._verify_mode = VERIFY_PEER
        self._handshake_deadline_us = _HANDSHAKE_DEADLINE_DEFAULT_US

    def __init__(
        out self,
        var config: TlsConfig,
        var underlying: Self.U,
        verify_mode: UInt8,
    ):
        """3-arg ctor with explicit verify_mode. Callers using
        `disable_verify()` on the TlsConfig MUST construct with
        verify_mode=VERIFY_SKIP so the session cache buckets the entries
        correctly.
        """
        self._config = OwnedPointer[TlsConfig](config^)
        self._underlying = underlying^
        self._server_name = String("")
        self._sni_pinned = False
        self._session_cache = OwnedPointer[SessionCache](
            SessionCache.with_defaults(),
        )
        self._verify_mode = verify_mode
        self._handshake_deadline_us = _HANDSHAKE_DEADLINE_DEFAULT_US

    @staticmethod
    def over(var config: TlsConfig, var underlying: Self.U) -> Self:
        """Convenience static ctor — equivalent to `Self(config,
        underlying)`. The name reflects the "TlsConnector OVER an
        underlying connector" composition shape. verify_mode defaults
        to VERIFY_PEER (use the 3-arg ctor for VERIFY_SKIP).
        """
        return Self(config^, underlying^)

    def set_handshake_deadline_us(mut self, deadline_us: Int64):
        """Set the wall-clock budget `connect` allows the TLS handshake, in
        microseconds. FAIL-SAFE: a non-positive value, or one above
        `_HANDSHAKE_DEADLINE_MAX_US`, leaves the current budget unchanged —
        there is no input that yields "no deadline", because an unbounded TLS
        handshake is the hang this budget exists to convert into a typed
        error."""
        if deadline_us <= Int64(0) or deadline_us > _HANDSHAKE_DEADLINE_MAX_US:
            return
        self._handshake_deadline_us = deadline_us

    def handshake_deadline_us(self) -> Int64:
        """The wall-clock handshake budget `connect` enforces, in µs."""
        return self._handshake_deadline_us

    def set_server_name_for_next_connect(mut self, var host: String):
        """Set the SNI hostname the NEXT `connect[RT]` call will send, and PIN
        it. Per RFC 6066 §3 the SNI value is the server's hostname (NOT IP).

        ★ "PIN" MEANS: the per-request host push `HttpClient` performs
        (`set_dial_host`) will NOT overwrite this. Calling this
        method is an operator stating a name, and the URL host must not be
        allowed to contradict it — `komira_k8s` dials the apiserver by IPv4
        dotted-quad while presenting the cluster's certificate name,
        and letting the URL win there would present an IP
        literal to a CA-pinned peer.

        ⚠ CONSEQUENCE, STATED RATHER THAN LEFT TO BE DISCOVERED: a PINNED
        connector still dials every host with ONE name. That is correct for
        every caller that pins (they each address exactly one endpoint), and it
        is why a caller whose host VARIES — S3's virtual-hosted buckets, a
        redirect chain — must NOT pin. `build_unpinned_public_ca_tls_connector`
        is that caller's factory."""
        self._server_name = host^
        self._sni_pinned = True

    def set_dial_host(mut self, var host: String):
        """`Connector.set_dial_host` — the per-request host push.

        Sets the SNI for the next dial IFF no explicit name was pinned. See
        `set_server_name_for_next_connect` for why the pin wins, and
        `Connector.set_dial_host` for the defect this closes.

        ⚠ THIS DOES NOT DIAL AND IT DOES NOT INVALIDATE ANYTHING. It writes one
        String field that `connect[RT]` reads at handshake time. Connections
        already established are untouched, and `HttpClient`'s pooled-checkout
        path never reaches `connect` at all — so per-request SNI costs ZERO
        additional handshakes. (It also makes the TLS SESSION CACHE correct for
        an unpinned connector, which it was not before: the resumption
        `PoolKey` is built from `_server_name`, so a connector reused across two
        hosts previously stored and looked up tickets under whichever host it
        was constructed with.)

        The push is forwarded to the underlying connector so a future stacked
        decorator sees it; `KernelTcpConnector` no-ops it."""
        self._underlying.set_dial_host(host.copy())
        if not self._sni_pinned:
            self._server_name = host^

    def _refuse_unverifiable_peer(self) raises:
        """Refuse a VERIFY_PEER dial that carries no server name.

        s2n only installs a hostname verifier when `s2n_set_server_name` was
        called, so a client that never set one checks the chain but NOT the
        host: any certificate chaining to the trust store would be accepted.
        `TlsConfig.enable_verify_default` is a no-op and no verify_host
        callback is installed, so the connector itself must refuse. A
        VERIFY_SKIP connector (explicit `disable_verify`) is exempt.
        """
        if self._verify_mode != VERIFY_SKIP and self._server_name.byte_length() == 0:
            raise Error(
                "TlsConnector: refusing VERIFY_PEER connect with an empty "
                "server name (hostname would not be verified); call "
                "set_server_name_for_next_connect or dial via HttpClient"
            )

    def server_name(self) -> String:
        """The SNI this connector will present on its next dial — `""` if it has
        none. Diagnostic / test accessor, the shape `verify_mode()` and
        `session_cache_len()` already have.

        ★ IT EXISTS SO THE PER-REQUEST PUSH IS ASSERTABLE ON THE REAL TYPE
        rather than on a double. A test that substituted its own connector
        could only prove the CLIENT pushed a host; reading this proves the
        production `TlsConnector` turned that push into the name it will
        actually present."""
        return self._server_name.copy()

    def sni_is_pinned(self) -> Bool:
        """Whether an explicit `set_server_name_for_next_connect` pinned the
        SNI (so `set_dial_host` is inert). Diagnostic / test accessor — the
        falsifier for "a pinned connector is immune to the per-request push"."""
        return self._sni_pinned

    # ----- Session-cache diagnostics ----------------------------------------

    def session_cache_len(self) -> Int:
        """Number of cached TLS session tickets. Diagnostic / test
        accessor."""
        return self._session_cache[].len()

    def session_cache_capacity(self) -> Int:
        """Max cached entries before LRU eviction. Diagnostic / test
        accessor."""
        return self._session_cache[].capacity()

    def verify_mode(self) -> UInt8:
        """The verify_mode this connector was built with. Diagnostic."""
        return self._verify_mode

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> TlsClientStream[Self.U.Stream]:
        """Establish a TLS connection over the underlying connector.

        Sequence:
          1. underlying.connect[RT](reactor, ip_be, port) → U.Stream.
          2. TlsConnection.new_client(config) + bind_fd(stream.fd).
          3. set_server_name(self._server_name) if non-empty.
          4. Drive handshake to DONE (bounded loop).
          5. Wrap + return.

        Raises:
          * If underlying.connect raises (TCP setup failure).
          * If the underlying stream reports NO KERNEL DESCRIPTOR (`fd()` < 0,
            the `IoStream.fd` sentinel). Refused BY NAME in `_extract_fd`,
            before any s2n object is built — see that method for why the
            previous "let s2n discover it" behaviour was a diagnostic defect.
          * If TlsConnection.new_client / bind_fd / set_server_name fails.
          * If handshake hits ERROR, or does not reach DONE within the
            WALL-CLOCK budget (`_HANDSHAKE_DEADLINE_DEFAULT_US`, overridable
            via `set_handshake_deadline_us`).
        """
        # Step 0: fail closed BEFORE any dial when there is no name to verify.
        self._refuse_unverifiable_peer()

        # Step 1: TCP (or whatever the underlying is) connect.
        var underlying = self._underlying.connect[RT](
            reactor=reactor, ip_be=ip_be, port=port,
        )
        return self._handshake_over[RT](
            reactor, underlying^, port, use_session_cache=True,
            verb="connect",
        )

    def upgrade[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var plain: Self.U.Stream,
    ) raises -> TlsClientStream[Self.U.Stream]:
        """Upgrade an already-connected plaintext stream to TLS on the same
        connection: the STARTTLS entry point (RFC 3207 for SMTP; the same
        shape serves IMAP, POP3 and LDAP).

        The caller has spoken the plaintext protocol on `plain` up to the
        server's go-ahead (SMTP `220 Ready to start TLS`) and hands the
        stream over. This method runs the client handshake on the stream's
        descriptor exactly as `connect` does after its dial, and returns the
        TLS stream, which owns `plain`.

        Refuses, and closes the connection (by dropping `plain`), when
        `plain.has_buffered_readable()` is True: the stream holds bytes the
        peer sent before the handshake, which a reader took off the socket
        and handed back with `unread`. Those bytes are plaintext an on-path
        attacker can inject after the go-ahead (the STARTTLS
        command-injection class); they are never handed to the TLS layer
        and never served after it. A caller whose own reader holds bytes
        past the go-ahead line must `unread` them before calling this, so
        the refusal sees them.

        Bytes the peer sent that are still in the kernel socket buffer are
        read by s2n as TLS records. A non-TLS byte sequence fails the
        handshake, or runs into the wall-clock deadline when its bogus
        record header announces more bytes than arrive. A well-formed
        record of a type s2n does not handle during the handshake is
        discarded and the handshake goes on, so the upgrade can succeed.
        Either way none of those bytes is ever served as application data.

        No session ticket is looked up or stored: the session cache is keyed
        for HTTPS dials.

        Preconditions: the caller holds no reactor registration on the
        stream's descriptor (the handshake loop registers and deregisters
        its own each round). The server name rule is that of `connect`: a
        VERIFY_PEER connector with no server name is refused.

        Raises:
          * `TlsConnector.upgrade: refusing the TLS upgrade ...` for
            buffered pre-handshake bytes.
          * `TlsConnector: refusing VERIFY_PEER connect with an empty
            server name ...`, `connect`'s server-name refusal unchanged.
          * Handshake failures, the wall-clock deadline and the no-descriptor
            refusal, with the `TlsConnector.upgrade:` prefix.
          * Errors from creating, binding or naming the s2n connection,
            with their own prefixes.
        """
        self._refuse_unverifiable_peer()
        if plain.has_buffered_readable():
            raise Error(
                "TlsConnector.upgrade: refusing the TLS upgrade: the"
                " plaintext stream holds bytes the peer sent before the"
                " TLS handshake. They are not handed to TLS and not served"
                " after it; the connection is closed."
            )
        return self._handshake_over[RT](
            reactor, plain^, UInt16(0), use_session_cache=False,
            verb="upgrade",
        )

    def _handshake_over[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        var underlying: Self.U.Stream,
        port: UInt16,
        use_session_cache: Bool,
        verb: StaticString,
    ) raises -> TlsClientStream[Self.U.Stream]:
        """Steps 2-5 of `connect`, shared with `upgrade`: bind a client TLS
        connection to `underlying`'s descriptor, drive the handshake to DONE
        within the wall-clock budget, and wrap. `port` keys the session
        cache and is read only when `use_session_cache`; `verb` names the
        public entry point in the handshake, deadline and no-descriptor
        error messages."""
        # Step 2: client-mode TLS connection bound to the underlying fd.
        # SAFETY: ref borrow into self._config — alive for the duration
        # of this method (we hold mut self). new_client + bind_fd happen
        # synchronously here.
        # ⚠ ORDER IS LOAD-BEARING: the fd is extracted (and a non-descriptor
        # REFUSED) BEFORE `new_client`, so a dial with no usable descriptor
        # never allocates an s2n connection it is only going to throw away.
        # Same discipline as step 1 above, where a refused underlying dial
        # returns before any TLS object exists.
        var fd = Self._extract_fd(underlying, verb)
        var conn = TlsConnection.new_client(self._config[])
        conn.bind_fd(fd)

        # Step 3: SNI. s2n COPIES the bytes synchronously; the
        # self._server_name borrow is alive through the call.
        if self._server_name.byte_length() > 0:
            conn.set_server_name(self._server_name)

        # Step 3a: — pre-handshake cache
        # lookup. Compute the PoolKey from the connector's static state
        # (verify_mode, server_name) + the dial port. ALPN bucketed as
        # ALPN_UNKNOWN because tickets are protocol-agnostic at the s2n
        # layer (cipher + master secret / PSK; ALPN re-negotiates each
        # handshake).
        #
        # SAFETY: cache.lookup raises on internal error (e.g. List copy
        # OOM). We treat any failure here as a cache miss — the connection
        # will still attempt a full handshake.
        #
        # Best-effort: if SNI is empty (e.g. IP-literal dial without
        # explicit set_server_name_for_next_connect), we skip cache
        # lookup entirely (no cache key to derive).
        if use_session_cache and self._server_name.byte_length() > 0:
            var lookup_key = PoolKey(
                scheme=SCHEME_HTTPS,
                host=self._server_name,
                port=port,
                verify_mode=self._verify_mode,
                negotiated_alpn=ALPN_UNKNOWN,
            )
            # `_now_us_for_cache` is a monotonically-increasing tag we
            # use just to thread LRU bookkeeping; the cache uses it
            # internally as the timestamp. We fold the iter counter into
            # a connection-scoped tag below to avoid pulling in a clock
            # dependency here.
            var maybe_blob = self._session_cache[].lookup(lookup_key, 0)
            if maybe_blob.__bool__():
                # Best-effort: if set_session raises (malformed blob,
                # expired ticket), swallow + fall through to a full
                # handshake. The s2n connection state remains in a valid
                # pre-handshake form.
                var blob = maybe_blob.take()
                try:
                    conn.set_session(blob)
                except:
                    pass
                # `blob` drops here.

        # Step 4: drive handshake to DONE.
        #
        # The BLOCKED branch PARKS on
        # the reactor instead of busy-spinning. The prior `_ = reactor; iter
        # += 1` loop only completed when the peer's handshake bytes happened
        # to already be in the socket buffer (socketpair / scripted tests).
        # Against a REAL network apiserver the s2n handshake BLOCKS on the
        # ServerHello / Finished round-trips, which take a network RTT to
        # arrive — busy-spinning the 256-iter cap in microseconds exhausts it
        # before any bytes land ("handshake exceeded 256 iterations,
        # s2n_errno=S2N_ERR_T_BLOCKED" against a real apiserver). On BLOCKED
        # we register the fd for the awaited direction, `poll_completions(-1)`
        # (block the calling thread until the fd is ready — for a single-task
        # BlockingRuntime this IS the park), then deregister and re-attempt.
        # Deregister-each-round keeps this from colliding with the TcpStream's
        # OWN lazy long-lived registration, which only fires on the first
        # read/write AFTER the handshake completes.
        #
        # THE BUDGET IS `deadline_us` OF WALL CLOCK, NOT A COUNT OF TRIPS
        # ROUND THIS LOOP. See the §1 banner. Two invariants carry it, and
        # both matter:
        #   (i)  give-up is decided by `_mono_now_ns()`, so it means the same
        #        thing whether the parks were 0 µs or 250 ms each;
        #   (ii) a park that returns WITHOUT this fd becoming ready re-parks
        #        for the remainder of its slice instead of re-entering s2n.
        #        s2n already said BLOCKED and nothing has changed, so calling
        #        it again cannot make progress — it can only spend budget.
        #        Under (i) that is no longer fatal, but it is still wrong, and
        #        it is what made the old loop's budget evaporate.
        var deadline_us = self._handshake_deadline_us
        var start_ns = Int64(_mono_now_ns())
        var parks = 0  # slices spent parked on this fd
        var idle_slices = 0  # slices that expired with NO readiness
        var no_fd_iters = 0  # spins on the fd-less (scripted) path
        while True:
            var outcome = conn.handshake()
            if outcome == TLS_OUTCOME_DONE:
                # read back the ALPN-negotiated protocol BEFORE moving
                # `conn` into TlsClientStream — s2n's negotiated_protocol
                # is safe post-DONE. Map "h2" → NEGOTIATED_HTTP_2; any
                # other value (including "http/1.1", None, "") falls
                # back to NEGOTIATED_HTTP_1_1. The mapping is defensive:
                # ALPN may be absent if the caller did not configure it,
                # or there was no overlap with the peer.
                var alpn_negotiated = conn.negotiated_protocol()
                var alpn_sentinel: UInt8 = NEGOTIATED_HTTP_1_1
                if alpn_negotiated.__bool__():
                    var s = alpn_negotiated.value()
                    if s == String("h2"):
                        alpn_sentinel = NEGOTIATED_HTTP_2

                # Step 4a: — post-DONE
                # session-ticket capture + cache store. Read
                # is_session_resumed BEFORE moving conn into the stream
                # (the connection is still owned by us here).
                var resumed = conn.is_session_resumed()
                if use_session_cache and self._server_name.byte_length() > 0:
                    try:
                        var ticket_opt = conn.get_session()
                        if ticket_opt.__bool__():
                            var store_key = PoolKey(
                                scheme=SCHEME_HTTPS,
                                host=self._server_name,
                                port=port,
                                verify_mode=self._verify_mode,
                                negotiated_alpn=ALPN_UNKNOWN,
                            )
                            self._session_cache[].store(
                                store_key^,
                                ticket_opt.take(),
                                parks + 1,
                            )
                    except:
                        # Best-effort capture; never fail the handshake
                        # because the cache store had an issue.
                        pass

                # Step 5a: the per-PHASE dial
                # breadcrumb. This is the arm that was DARK — the give-up arm
                # already carries `elapsed_ms` inside
                # `_handshake_deadline_error`, so a handshake that COMPLETED
                # after 28 seconds reported nothing at all and was
                # indistinguishable from one that completed in 30 ms.
                #
                # ⛔ IT MEASURES, IT DOES NOT BOUND — the bound on this phase
                # is `deadline_us` a few lines below, and it already exists.
                # See `slow_phase.mojo` for why the threshold is what it is and
                # why this is a `print`.
                #
                # `self._server_name` is the SNI name, i.e. the same string the
                # DNS line names, so the two phases of one dial join on `host=`.
                _ = note_slow_phase(
                    SLOW_PHASE_TLS_HANDSHAKE,
                    self._server_name,
                    elapsed_ms_since(start_ns, Int64(_mono_now_ns())),
                )

                # Step 5: wrap and return with the ALPN sentinel +
                # session-resumption status.
                return TlsClientStream[Self.U.Stream](
                    underlying^, conn^, alpn_sentinel, resumed,
                )
            if outcome == TLS_OUTCOME_ERROR:
                var errno = last_s2n_errno()
                var msg = s2n_strerror_message(errno)
                var dbg = s2n_strerror_debug_message(errno)
                var last_msg = conn.last_handshake_message_name()
                raise Error(
                    "TlsConnector." + String(verb)
                    + ": handshake failed (s2n_errno="
                    + String(Int(errno)) + ", msg='" + msg
                    + "', debug='" + dbg
                    + "', last_handshake_msg='" + last_msg + "')"
                )
            # ---- BLOCKED_ON_READ / BLOCKED_ON_WRITE -------------------------
            # s2n's verdict is "healthy, not finished". The ONLY thing that
            # ends the handshake from here is the wall clock.
            var blocked_on_write = outcome == TLS_OUTCOME_BLOCKED_ON_WRITE
            var elapsed_us = (Int64(_mono_now_ns()) - start_ns) // Int64(1000)
            if elapsed_us >= deadline_us:
                raise self._handshake_deadline_error(
                    elapsed_us, deadline_us, parks, idle_slices,
                    blocked_on_write, verb,
                )
            if fd < Int32(0):
                # ⚠ UNREACHABLE VIA `connect` — `_extract_fd`
                # REFUSES fd < 0 by name, before `new_client`, so `fd` here
                # is always a real descriptor. RETAINED DELIBERATELY as a
                # backstop: this loop reads `fd` from a local, and if a future
                # refactor ever re-admits a fd-less stream, degrading to a
                # BOUNDED SPIN is the safe failure. Parking on a non-descriptor
                # is not — `park_on_fds` skips every fd < 0 and returns
                # immediately when they all are, so the park would wait for
                # nothing and the loop would spin to the 30 s deadline.
                #
                # Readiness is not observable without an fd, so a bounded spin
                # is the only available bound and an iteration IS the unit
                # here. The wall-clock check above still applies and fires
                # first on any spin that takes real time.
                no_fd_iters = no_fd_iters + 1
                if no_fd_iters >= _HANDSHAKE_NO_FD_ITER_CAP:
                    raise self._handshake_deadline_error(
                        elapsed_us, deadline_us, parks, idle_slices,
                        blocked_on_write, verb,
                    )
                continue

            # SAFETY/LIVENESS: register interest on the borrowed fd for ONE
            # BOUNDED slice, then deregister. The fd is
            # owned by `underlying` (alive for this method); we never close it
            # here. op_id is reactor-allocated so it can't collide with another
            # in-flight op. Deregister-each-round keeps this from colliding
            # with the TcpStream's OWN lazy long-lived registration.
            var slice_us = Int64(_HANDSHAKE_PARK_DEADLINE_US)
            var remaining_us = deadline_us - elapsed_us
            if remaining_us < slice_us:
                slice_us = remaining_us
            var op_id = reactor.alloc_op_id()
            if blocked_on_write:
                reactor.register_write(fd, op_id, UInt16(0))
            else:
                reactor.register_read(fd, op_id, UInt16(0))
            # INVARIANT (ii): keep parking until THIS op's readiness lands or
            # the slice is spent. `poll_completions` returns on ANY reactor
            # event — a drained wake-eventfd contributes an EMPTY list — and
            # treating such a return as "the peer answered" is what let a
            # handshake be abandoned microseconds after it started.
            var slice_start_ns = Int64(_mono_now_ns())
            var ready = False
            var polls = 0
            while polls < _HANDSHAKE_POLLS_PER_SLICE_CAP:
                var waited_us = (
                    Int64(_mono_now_ns()) - slice_start_ns
                ) // Int64(1000)
                var left_us = slice_us - waited_us
                if left_us <= Int64(0):
                    break
                var _drained = reactor.poll_completions(
                    timeout_us=Int32(left_us)
                )
                polls = polls + 1
                if reactor.is_ready(op_id):
                    ready = True
                    break
            reactor.deregister(op_id)
            parks = parks + 1
            if not ready:
                idle_slices = idle_slices + 1

    def _handshake_deadline_error(
        self,
        elapsed_us: Int64,
        deadline_us: Int64,
        parks: Int,
        idle_slices: Int,
        blocked_on_write: Bool,
        verb: StaticString,
    ) -> Error:
        """The give-up error, carrying the evidence needed to tell the two
        causes apart WITHOUT a rebuild.

        A message like `handshake exceeded 256 iterations
        (s2n_errno=201326592)` says nothing useful: 256 of WHAT, for HOW LONG,
        waiting on WHICH direction, and
        against WHICH host — none of it is recoverable from the string, and
        the one number it does print (the s2n errno) decodes to "would block",
        i.e. the handshake has not failed at all.

        So: `parks` vs `idle_slices` says whether the loop actually WAITED
        (idle_slices ≈ parks ⇒ a peer that produced no readiness for the whole
        budget: a network/peer fault) or was woken repeatedly without this fd
        becoming ready (idle_slices ≪ parks ⇒ a reactor-side wake storm, which
        is the client-side defect this loop is hardened against). `elapsed_ms`
        against `deadline_ms` proves the budget is wall-clock. The host is the
        SNI value, which is what a reader needs to reproduce the dial."""
        var errno = last_s2n_errno()
        var host = (
            self._server_name if self._server_name.byte_length() > 0
            else String("<no SNI>")
        )
        var direction = (
            String("WRITE") if blocked_on_write else String("READ")
        )
        return Error(
            "TlsConnector." + String(verb) + ": TLS handshake to '" + host
            + "' did not complete within its wall-clock budget — elapsed_ms="
            + String(elapsed_us // Int64(1000))
            + ", deadline_ms=" + String(deadline_us // Int64(1000))
            + ", parks=" + String(parks)
            + ", idle_slices=" + String(idle_slices)
            + ", blocked_on=" + direction
            + ", s2n_errno=" + String(Int(errno))
            + " ('" + s2n_strerror_message(errno) + "')"
            + ". s2n reports BLOCKED, not FAILED: the peer accepted the"
            + " connection and then produced no usable handshake bytes."
            + " Raise the budget with"
            + " TlsConnector.set_handshake_deadline_us if this network is"
            + " genuinely that slow."
        )

    def transport_kind(self) -> UInt8:
        """Per the Connector trait — the underlying transport's kind.
        TLS does not change the transport class (it's still kernel TCP
        for KernelTcpConnector underneath); the pool's `@parameter if`
        selection at the consumer call site sees the underlying class.
        For ScriptedConnector underneath (test mode), this is also
        TRANSPORT_KIND_KERNEL_TCP — the mock pretends to be a TCP
        connector at the codec level.
        """
        return self._underlying.transport_kind()

    def is_tls(self) -> Bool:
        """TlsConnector wraps a TLS handshake — returns True.
        additive trait method used by HttpClient.send to validate that
        the URL scheme matches the connector capability."""
        return True

    @staticmethod
    @always_inline
    def _extract_fd(
        ref stream: Self.U.Stream, verb: StaticString,
    ) raises -> Int32:
        """Extract the underlying fd from the IoStream, REFUSING one that is
        not a descriptor.

        ⭐ THIS IS WHERE THE `IoStream.fd` TRAIT OBLIGATION IS DISCHARGED.
        That trait's own docstring says: "Conformers that have no kernel fd
        (e.g., ScriptedStream) return -1; consumers that depend on a real fd
        (TlsConnector) gracefully error on -1." TlsConnector is the named
        consumer, and this is the check.

        ⚠ s2n DOES NOT DETECT IT. `TlsConnection.bind_fd` forwards straight
        to `s2n_connection_set_fd`, which STORES whatever integer it is
        handed, and `bind_fd(-1)` SUCCEEDS. The dial then fails later, from
        inside `s2n_negotiate`, as `s2n_errno=67108864, msg='underlying I/O
        operation failed, check system errno'` — the `write(2)` on fd -1
        returning EBADF — a message naming neither the descriptor nor the
        connector, that reads as a socket/network fault on a dial that
        performed no network I/O. A diagnostic that points at the wrong
        subsystem IS the defect. And that outcome is only
        incidentally prompt: it depends on s2n classifying EBADF as
        S2N_ERR_T_IO rather than as BLOCKED. Were it BLOCKED, the
        fd-less arm of the handshake loop would spin
        `_HANDSHAKE_NO_FD_ITER_CAP` times and then raise a WALL-CLOCK
        DEADLINE error for a budget that has not been spent — a second
        misleading diagnostic behind the first.

        Raising here (rather than at the `bind_fd` call site) keeps the guard
        welded to the extraction, so every future caller inherits it.
        """
        var fd = stream.fd()
        if fd < Int32(0):
            raise Error(
                "TlsConnector." + String(verb)
                + ": the underlying stream has no kernel"
                " descriptor (fd=" + String(Int(fd)) + "), so there is nothing"
                " for s2n to bind a TLS connection to. This is the"
                " `IoStream.fd` contract's -1 sentinel, not an I/O failure:"
                " no socket was touched and no handshake was attempted."
                " A TLS handshake requires a real descriptor, so a"
                " fd-less transport (ScriptedStream, and any other conformer"
                " returning the sentinel) cannot be dialled through"
                " TlsConnector. Compose TLS over a connector whose stream owns"
                " a real socket, or test the fd-less transport without the TLS"
                " decorator."
            )
        return fd


# =============================================================================
# §4 — Public-CA TLS connector factory.
# =============================================================================
#
# TLS-to-a-public-HTTPS-host is a GENERAL HttpClient
# capability, NOT a per-consumer hack. `build_public_ca_tls_connector(host,
# port)` returns a `TlsConnector[KernelTcpConnector]` configured to verify the
# peer against the SYSTEM / public-CA trust store and send SNI = `host`. Any
# HttpClient consumer (the LLM client, broker, S3, future connectors) can wrap
# its dial path in this connector to reach an arbitrary public HTTPS host by
# hostname — `HttpClient[TlsConnector[KernelTcpConnector]]` is a 1-line
# connector swap at the call site (HttpClient is already parametric over C).
#
# Why this differs from `k8s_build_tls_connector` (the in-cluster sibling):
#   * k8s pins EXACTLY the cluster CA: `wipe_trust()` + `add_trust_pem(ca)`.
#   * Public CA does the OPPOSITE — it KEEPS s2n's default trust store, which
#     is initialized from the host OS's common CA locations (per s2n.h:849;
#     same default `add_trust_pem` documents). We must NOT `wipe_trust()` or
#     the public roots are gone. Verification stays ON (a fresh s2n_config_t
#     verifies the peer by default; `enable_verify_default()` is the explicit
#     no-op marker of that intent).
#
# Encapsulation: returns an owned `TlsConnector[KernelTcpConnector]` value (the
# connector owns its `OwnedPointer[TlsConfig]` + underlying connector). ZERO
# UnsafePointer / wildcard origin / unsafe_from_address crosses this boundary.


def default_client_tls_config(alpn_h2: Bool = False) raises -> TlsConfig:
    """The client TLS configuration both public-CA connectors build on:
    the `"default_tls13"` security policy (TLS 1.3 and 1.2 offered; a fresh
    s2n config offers TLS 1.2 only, which a TLS 1.3-only server refuses
    before ServerHello), ALPN `["http/1.1"]` or `["h2", "http/1.1"]`, and
    peer verification on. The trust store is s2n's default; a caller that
    pins a CA wipes it and adds its own.
    """
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    if alpn_h2:
        alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    config.enable_verify_default()
    return config^


def build_public_ca_tls_connector(
    server_name: String, alpn_h2: Bool = False,
) raises -> TlsConnector[KernelTcpConnector]:
    """Build a `TlsConnector[KernelTcpConnector]` for an arbitrary PUBLIC
    HTTPS host, verifying the peer against the system / public-CA trust store.

    Configuration (the general public-HTTPS dial shape):
      * `set_cipher_preferences("default_tls13")` — offer TLS 1.3 + 1.2 (a
        fresh s2n config defaults TLS-1.2-only, which TLS-1.3-preferring public
        servers reject before ServerHello — the same unblocker the k8s/pg
        client paths needed).
      * `set_alpn_protocols([...])` — `["http/1.1"]` by default; `["h2",
        "http/1.1"]` when `alpn_h2=True` (lets the caller opt into the h2
        client driver via ALPN).
      * SYSTEM TRUST STORE: we do NOT touch the trust store — the fresh config
        already carries the OS's public CA roots, and verification is ON by
        default. `enable_verify_default()` documents the verify-peer intent.
      * SNI: `set_server_name_for_next_connect(server_name)` — RFC 6066 §3
        requires the SNI value to be the server HOSTNAME (not an IP). Virtually
        every modern public HTTPS server requires SNI; pass the URL host.

    The returned connector is built with `verify_mode=VERIFY_PEER` so its
    session cache buckets correctly. It owns its `TlsConfig` (via OwnedPointer)
    and is reused for each request the caller drives through it.

    Raises on any s2n FFI configuration failure.
    """
    var config = default_client_tls_config(alpn_h2)
    # PUBLIC-CA TRUST: keep s2n's default OS trust store (do NOT wipe_trust /
    # add_trust_pem) and keep verification ON. enable_verify_default() is the
    # documented no-op that marks the verify-peer intent at the call site.
    config.enable_verify_default()

    var connector = TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), VERIFY_PEER,
    )
    connector.set_server_name_for_next_connect(server_name)
    return connector^


def build_unpinned_public_ca_tls_connector(
    alpn_h2: Bool = False,
) raises -> TlsConnector[KernelTcpConnector]:
    """★ THE SAME PUBLIC-CA CONNECTOR AS ABOVE, WITH **NO PINNED SNI** — its
    server name comes from each request's URL host, pushed by `HttpClient` via
    `Connector.set_dial_host`.

    ── WHY A SECOND FACTORY RATHER THAN AN ARGUMENT ────────────────────────
    ⛔ IT TAKES NO HOST, AND THAT IS THE ENTIRE POINT — NOT AN OMISSION.
    Its signature is `def () raises -> TlsConnector[...]`, which makes it usable
    as a `def () raises thin -> C` CAPTURELESS connector factory. That is the
    shape every `komira_aws_relay` client's transport seam takes, and a `thin`
    fn cannot capture, so a factory that needed to bake a host could only ever
    bake ONE — read from the environment, decided at process start.

    That constraint is what left the S3 bucket seam unbound. S3 uses
    VIRTUAL-HOSTED addressing (`<bucket>.s3.<region>.amazonaws.com`), so the
    BUCKET is in the host, the host is in the SigV4 signature, and a
    host-baking factory could reach exactly ONE bucket per process. A manifest
    with a second S3 node would sign correctly for a bucket it never dialed —
    invisible until AWS answers `SignatureDoesNotMatch`, an error that names the
    CREDENTIAL and sends every reader to the wrong place.

    ⚠ NOT SUITABLE FOR A DIAL WHOSE URL HOST IS AN IP LITERAL. RFC 6066 §3
    requires SNI to be a hostname, and here the URL host IS the SNI. Any caller
    that addresses by IP while presenting a name (the `komira_k8s` apiserver
    path) must PIN instead — `build_public_ca_tls_connector` /
    `k8s_build_tls_connector`.

    Configuration is otherwise IDENTICAL to `build_public_ca_tls_connector`:
    TLS 1.3 ciphers, system/public-CA trust store, verification ON,
    `verify_mode=VERIFY_PEER`, ALPN `http/1.1` (or `h2, http/1.1`). The one
    difference is the absent `set_server_name_for_next_connect` call — so the
    connector is UNPINNED and `set_dial_host` fills it per request.

    Raises on any s2n FFI configuration failure."""
    var config = default_client_tls_config(alpn_h2)
    config.enable_verify_default()

    # ⛔ NO `set_server_name_for_next_connect` HERE. Adding one "for safety"
    # would PIN the connector and silently restore the exact single-host
    # behaviour this factory exists to remove.
    return TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), VERIFY_PEER,
    )
