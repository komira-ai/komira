# =============================================================================
# src/komira_http_core/tls/conn.mojo — TLS stream + handshake state machine driver
# =============================================================================
#
#
#
# This module composes's safe `TlsConnection` wrapper with the L0
# handshake state machine. `TlsStream` is the per-conn orchestrator that
# the accept loop installs onto each accepted fd when TLS is enabled.
#
# Responsibilities:
#   - Drive the multi-step s2n_negotiate handshake (TCP-connected →
#     handshake-in-progress → handshake-done → app-data).
#   - Translate `TLS_OUTCOME_*` to the L0 conn-state-machine alphabet
#     (CONN_STATE_TLS_HANDSHAKE_IN/OUT vs CONN_STATE_READING) + reactor
#     INTEREST bitmask.
#   - After handshake DONE: surface `read_app` / `write_app` as the
#     plaintext-substitute primitives the parser/writer code consumes.
#
# Encapsulation discipline:
#   - ZERO new UnsafePointer in public sigs (this module). The single
#     storage field is `TlsConnection`, which is itself an
#     OwnedPointer-of-handle Movable struct — destroy-recreate safe.
#   - All public methods accept/return Mojo-typed values: `Span[UInt8, _]`,
#     `List[UInt8]`, `Int`, `Int32`, `UInt8`, `Bool`, `Optional[String]`,
#     `Tuple[UInt8, Int]`.
#   - ZERO wildcard origins outside the FFI carve-out (ffi.mojo /
#     s2n_shim.mojo).
# =============================================================================

from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
)
from komira_http_core.tls.handshake_state import (
    CONN_STATE_TLS_HANDSHAKE_IN,
    CONN_STATE_TLS_HANDSHAKE_OUT,
    outcome_to_conn_state,
    outcome_to_interest,
)


# =============================================================================
# Phase-2-compat L0 plaintext-state alias
# =============================================================================
# `CONN_STATE_READING` is defined at
# `src/komira_http_server/connection.mojo:29` as the entry plaintext
# state. The TLS path resumes here after the handshake completes —
# pluging straight into the existing parser/writer pipeline. We re-alias
# it locally to avoid a transport→tls circular import (transport already
# imports nothing from tls; we keep that direction clean).
#
# Value (0) is mirrored from `transport/connection.mojo:29` — same byte;
# tests verify both definitions remain in sync.

comptime CONN_STATE_READING: UInt8 = 0
"""Post-handshake state — the plaintext L0 state-machine variant. After
`TlsStream.drive_handshake()` returns `TLS_OUTCOME_DONE`, the conn's
state transitions here and reads go through `read_app()` / writes
through `write_app()`.

Numeric value matches `komira_http_server.connection.CONN_STATE_READING`."""


comptime CONN_STATE_CLOSED: UInt8 = 255
"""Sentinel — TLS conn errored irrecoverably. Caller should close the
underlying fd (the TlsConnection's drop runs s2n_connection_free; the
fd itself is OWNED BY THE CALLER per's contract)."""


# =============================================================================
# TlsStream — the TLS-stream orchestrator type
# =============================================================================


struct TlsStream(Movable, Deinitable):
    """Per-conn TLS state, composing's TlsConnection with the L0
    handshake state machine.

    Lifecycle:
      1. `TlsStream(config, fd)` constructs an s2n server-mode
         TlsConnection bound to `fd`, sets the initial state to
         CONN_STATE_TLS_HANDSHAKE_IN (waiting for the first ClientHello),
         and pre-arms the handshake-not-done flag.
      2. `drive_handshake()` steps the handshake forward. Returns a
         (outcome, suggested_interest_mask, next_conn_state) triple.
         Callers loop until DONE/ERROR or block on the suggested
         interest set (caller arms the reactor + returns to event loop).
      3. After DONE: `read_app(buf, capacity)` decrypts inbound bytes
         into `buf`; `write_app(data)` encrypts + sends `data`. Same
         outcome semantics as the underlying TlsConnection.
      4. `shutdown_app()` initiates the close_notify exchange.
      5. Drop frees the TlsConnection (which transitively frees s2n
         state); the fd is NOT closed by drop — caller owns the fd.

    Encapsulation:
      - Public surface accepts/returns ONLY Mojo-typed values.
      - The underlying `TlsConnection` (which holds the FFI-POD opaque
        handle via OwnedPointer-of-handle) is a private field.

    Movable, NOT Copyable — owns the TlsConnection (which is Movable,
    NOT Copyable, because copy would double-free the s2n_connection_t).

    Lifetime contract: the `TlsConfig` passed to `__init__` MUST outlive
    this TlsStream. Phase 1 server usage: HttpServer owns ONE TlsConfig
    that outlives every accepted TlsStream by construction.
    """

    var _conn: TlsConnection
    var _state: UInt8
    var _handshake_done: Bool

    def __init__(out self, ref config: TlsConfig, fd: Int32) raises:
        """Construct a TlsStream bound to `fd`, with `config` as the
        non-owning cert/ALPN config.

        Initial state: CONN_STATE_TLS_HANDSHAKE_IN (the server's first
        wait is on the ClientHello bytes arriving from the peer).

        Caller must ensure `fd` is set non-blocking BEFORE calling
        `drive_handshake()`. Otherwise s2n_negotiate will block
        indefinitely on the underlying read syscall. Use the
        `komira_fcntl_set_nonblock(fd)` helper from `komira_async`'s
        socket setup.

        Raises if the underlying TlsConnection construction fails
        (s2n_connection_new OOM or s2n_connection_set_config failure).
        """
        var conn = TlsConnection(config)
        conn.bind_fd(fd)
        self._conn = conn^
        self._state = CONN_STATE_TLS_HANDSHAKE_IN
        self._handshake_done = False

    # -------------------------------------------------------------------------
    # Handshake driver
    # -------------------------------------------------------------------------

    def drive_handshake(mut self) -> Tuple[UInt8, UInt8, UInt8]:
        """Step the TLS handshake forward.

        Returns a 3-tuple `(outcome, interest_mask, next_conn_state)`:

          outcome           — `TLS_OUTCOME_*` value:
                              * DONE             → handshake complete
                              * BLOCKED_ON_READ  → s2n wants more wire bytes
                              * BLOCKED_ON_WRITE → s2n wants to flush wire bytes
                              * ERROR            → handshake aborted; close
          interest_mask     — `INTEREST_READ` / `INTEREST_WRITE` / 0; the
                              caller should `reactor.modify(reg, mask)`
                              before returning to the event loop. Mask
                              == 0 means "close the conn, do not modify".
          next_conn_state   — `CONN_STATE_TLS_HANDSHAKE_IN` /
                              `CONN_STATE_TLS_HANDSHAKE_OUT` /
                              `CONN_STATE_READING` (handshake-done,
                              plaintext path resumes) / `CONN_STATE_CLOSED`
                              (error sentinel).

        Side-effects: updates `self._state` to `next_conn_state`. On DONE,
        sets `self._handshake_done = True`.

        The caller invokes this from the reactor's per-fd
        ready-event dispatch loop. On `BLOCKED_ON_*`, the caller arms
        the reactor + returns; on DONE, the caller may immediately
        attempt a `read_app()` / continue into the plaintext parser
        path.
        """
        var outcome = self._conn.handshake()
        var mask = outcome_to_interest(outcome)
        var next_state = outcome_to_conn_state(outcome, self._state)
        # Map the outcome_to_conn_state DONE→0 sentinel to our
        # CONN_STATE_READING constant; ERROR→255 to CONN_STATE_CLOSED.
        # The numeric mapping is identity per the alias values, but the
        # explicit reassignment + named-constant return makes the
        # state-machine alphabet-translation legible.
        if outcome == TLS_OUTCOME_DONE:
            self._handshake_done = True
            next_state = CONN_STATE_READING
        elif outcome == TLS_OUTCOME_ERROR:
            next_state = CONN_STATE_CLOSED
        self._state = next_state
        return (outcome, mask, next_state)

    # -------------------------------------------------------------------------
    # Post-handshake app-data primitives
    # -------------------------------------------------------------------------

    def read_app(
        mut self, mut buf: List[UInt8], capacity: Int,
    ) -> Tuple[UInt8, Int]:
        """Decrypt + read up to `capacity` bytes of inbound plaintext
        into `buf`. Returns `(outcome, n_bytes)`:

          outcome == TLS_OUTCOME_DONE             — `n_bytes` decrypted
                                                    plaintext bytes are now
                                                    in `buf`. MAY be a partial
                                                    (< capacity) with more
                                                    still buffered inside s2n
                                                    — re-call to get it.
                                                    Special: n == 0 means peer
                                                    sent close_notify
                                                    (graceful EOF).
          outcome == TLS_OUTCOME_BLOCKED_ON_READ  — `n_bytes == 0`; NOTHING
                                                    was decrypted. Caller
                                                    should arm INTEREST_READ
                                                    and retry.
          outcome == TLS_OUTCOME_BLOCKED_ON_WRITE — `n_bytes == 0`; arm
                                                    INTEREST_WRITE.
          outcome == TLS_OUTCOME_ERROR            — `n_bytes == -1`; close.

        A POSITIVE byte count is ALWAYS reported as DONE, never as a block —
        s2n has already erased those bytes out of `conn->in`, so a caller that
        reads the result as "nothing happened" loses them permanently. This
        mirrors `write_app`'s partial-send rule; the s2n_recv.c mechanism and
        the measured loss are documented on `TlsConnection.recv_into_span`.

        Caller MUST pre-`reserve` `buf` to >= `capacity` bytes (this
        delegates straight to `TlsConnection.recv` which does no allocation
        across the FFI boundary).

        Pre-condition: `handshake_done() == True`. If called before the
        handshake completes, s2n returns an error (S2N_ERR_HANDSHAKE_NOT_COMPLETE);
        the outcome is ERROR and `last_s2n_errno()` carries the cause.
        """
        return self._conn.recv(buf, capacity)

    def write_app(mut self, data: Span[UInt8, _]) -> Tuple[UInt8, Int]:
        """Encrypt + send `data` via the bound fd. Returns
        `(outcome, n_bytes)` honoring the s2n_send resumption contract:

          outcome == TLS_OUTCOME_DONE             — n_bytes plaintext bytes
                                                    were CONSUMED (may be a
                                                    partial < len(data)). The
                                                    caller MUST advance its
                                                    buffer by EXACTLY n_bytes
                                                    and re-call with data[n:].
          outcome == TLS_OUTCOME_BLOCKED_ON_WRITE — n_bytes == 0; NOTHING was
                                                    accepted. Caller arms
                                                    INTEREST_WRITE and re-calls
                                                    with the SAME `data`.
          outcome == TLS_OUTCOME_BLOCKED_ON_READ  — n_bytes == 0; only on TLS
                                                    rekey; arm INTEREST_READ.
          outcome == TLS_OUTCOME_ERROR            — n_bytes == -1; close.

        See `TlsConnection.send` for the full rationale: a positive
        partial-that-blocked (`rc>0` AND `*blocked=WRITE`) is surfaced as
        DONE-with-n so the caller advances by exactly the bytes s2n consumed;
        a bare block returns BLOCKED-with-0 so the caller re-sends the SAME
        buffer. This never trips the s2n S2N_ERR_SEND_SIZE sanity check and
        never re-transmits.

        Pre-condition: `handshake_done() == True`.
        """
        return self._conn.send(data)

    def shutdown_app(mut self) -> UInt8:
        """Send the TLS close_notify alert and drain the peer's
        close_notify. Returns the same outcome shape as handshake:

          TLS_OUTCOME_DONE             — graceful shutdown completed;
                                          fd may now be closed.
          TLS_OUTCOME_BLOCKED_ON_READ  — waiting for peer's close_notify.
          TLS_OUTCOME_BLOCKED_ON_WRITE — kernel send buffer full.
          TLS_OUTCOME_ERROR            — shutdown failed; close hard.

        Per s2n.h:2318-2323: graceful close_notify by default; both
        peers must exchange close_notify before this returns DONE.
        """
        return self._conn.shutdown()

    # -------------------------------------------------------------------------
    # Accessors
    # -------------------------------------------------------------------------

    def state(self) -> UInt8:
        """Current TLS-layer L0 state — one of CONN_STATE_TLS_HANDSHAKE_IN
        / CONN_STATE_TLS_HANDSHAKE_OUT / CONN_STATE_READING / CONN_STATE_CLOSED.
        """
        return self._state

    def handshake_done(self) -> Bool:
        """True iff the TLS handshake has reached the DONE state. Once
        True, `read_app` / `write_app` are valid; before, they will
        fail with an s2n handshake-not-complete error."""
        return self._handshake_done

    def fd(self) -> Int32:
        """The bound fd. Returns -1 if `bind_fd` was never called
        (should not happen in normal use — __init__ always binds)."""
        return self._conn.fd()

    def sni_hostname(self) -> Optional[String]:
        """The SNI hostname the client requested at handshake, or None
        if no SNI extension was sent. Only meaningful AFTER handshake
        completes (the SNI is parsed from the ClientHello). Phase 1
        returns a copy of the s2n-owned C string."""
        return self._conn.sni_hostname()

    def negotiated_protocol(self) -> Optional[String]:
        """The ALPN-negotiated protocol string
        (e.g. "h2", "http/1.1"), or None if no ALPN extension was
        used / no protocol was selected.

        Only meaningful AFTER handshake completes. Before the handshake
        is DONE, s2n returns NULL → this method returns None.

        The HttpServer.serve_one_iteration accept-loop pivot uses this
        readback immediately after TLS_OUTCOME_DONE to decide:
          * "h2"        → enter CONN_STATE_H2_PREFACE_WAIT and drive
                          the h2 codec path.
          * "http/1.1"
          / None        → enter CONN_STATE_READING and drive the h1
                          path (existing behavior).
        """
        return self._conn.negotiated_protocol()

    def s2n_errno(self) -> Int32:
        """The most-recent s2n_errno value. Useful immediately after an
        ERROR outcome to format diagnostic messages.

        WARNING: thread-local; reads s2n's TLS-thread errno slot. Do
        NOT call any other s2n function between the ERROR outcome and
        this call (which would clobber the slot).
        """
        return last_s2n_errno()
