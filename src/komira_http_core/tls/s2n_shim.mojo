# =============================================================================
# src/komira_http_core/tls/s2n_shim.mojo — opaque-handle wrappers + safe public API
# =============================================================================
#
#
#
# This module is the SAFE BOUNDARY over the FFI declarations in
# `ffi.mojo`. It exposes:
#
#   - `_S2nConfigHandle`     — internal RAII wrap; ArcPointer-stored on
#                              TlsConfig; __deinit__ calls s2n_config_free,
#                              then frees every cert chain load_cert added.
#   - `_S2nConnectionHandle` — internal RAII wrap; OwnedPointer-stored on
#                              TlsConnection; __del__ calls s2n_connection_free.
#   - `TlsConfig`            — public safe wrapper; ALPN + cert loading.
#   - `TlsConnection`        — public safe wrapper; handshake / send /
#                              recv / shutdown / SNI extraction /
#                              TLS 1.3 key update (types in key_update.mojo).
#   - `HandshakeOutcome`     — enum-like UInt8 alias for the 3-state result.
#   - `TlsIoOutcome`         — same shape for send/recv/shutdown.
#
# ENCAPSULATION DISCIPLINE:
# The public `TlsConfig` / `TlsConnection` surface NEVER exposes an
# UnsafePointer. The opaque-handle structs hold the raw s2n pointer as a
# private field (the FFI-POD opaque-handle carve-out).
#
# Mirroring discipline: every method body that touches the raw pointer
# has a `# SAFETY:` comment. The OwnedPointer-on-public-type pattern
# prevents the destroy-recreate / wildcard-origin
# hazard on TlsConnection (which IS a destroy-recreate struct,
# one per accepted conn).
#
# CALLBACK API EXPLICITLY UNUSED:
# `s2n_connection_set_send_cb` / `s2n_connection_set_recv_cb` are NOT bound
# in `ffi.mojo` and are NOT used here. The fd-direct path (set_fd) is the
# only supported shape.
# =============================================================================

from std.ffi import external_call, _Global
from std.memory import ArcPointer, OwnedPointer, alloc, unsafe_memcpy

# ★ s2n does its own bare `write(2)` on the fd we hand it and documents that it
# does NOT handle SIGPIPE (s2n.h:1713 @ s2n_connection_set_fd). MSG_NOSIGNAL
# cannot reach that syscall, so the TLS path needs the process-level ignore.
# Installed once per process (incl. forked children) in `_init_s2n_once`.
from komira_async.reactor.graceful_shutdown import ignore_sigpipe

from komira_http_core.tls.ffi import (
    S2N_BLOCKED_ON_READ,
    S2N_BLOCKED_ON_WRITE,
    S2N_CLIENT,
    S2N_ERR_T_BLOCKED,
    S2N_ERR_T_CLOSED,
    S2N_FAILURE,
    S2N_NOT_BLOCKED,
    S2N_SERVER,
    S2N_SUCCESS,
    S2N_TLS13,
    S2nBytePtr,
    S2nInt32Ptr,
    S2nOpaquePtr,
    _S2N_FFI_ORIGIN,
    s2n_cert_chain_and_key_free,
    s2n_cert_chain_and_key_load_pem_bytes,
    s2n_cert_chain_and_key_new,
    s2n_config_add_cert_chain_and_key_to_store,
    s2n_config_add_pem_to_trust_store,
    s2n_config_append_protocol_preference,
    s2n_config_disable_x509_verification,
    s2n_config_free,
    s2n_config_new,
    s2n_config_set_cipher_preferences,
    s2n_config_set_protocol_preferences,
    s2n_config_set_session_tickets_onoff,
    s2n_config_wipe_trust_store,
    s2n_connection_free,
    s2n_connection_get_actual_protocol_version,
    s2n_connection_get_cipher,
    s2n_connection_get_session,
    s2n_connection_get_session_length,
    s2n_connection_is_session_resumed,
    s2n_connection_new,
    s2n_connection_set_config,
    s2n_connection_set_fd,
    s2n_connection_set_session,
    s2n_connection_get_key_update_counts,
    s2n_connection_request_key_update,
    s2n_connection_get_wire_bytes_in,
    s2n_connection_get_wire_bytes_out,
    s2n_errno_location,
    s2n_error_get_type,
    s2n_get_application_protocol,
    s2n_get_server_name,
    s2n_connection_get_last_message_name,
    s2n_init,
    s2n_negotiate,
    s2n_peek,
    s2n_recv,
    s2n_send,
    s2n_set_server_name,
    s2n_shutdown,
    s2n_strerror,
    s2n_strerror_debug,
)
from komira_http_core.tls.key_update import KeyUpdateCounts, PeerKeyUpdate


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL pointer sentinels / FFI NULL args.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# =============================================================================
# Outcome enums — UInt8 aliases for safe-surface handshake / IO results
# =============================================================================
#
# Phase-1 result classes that all TLS state-transition methods return.
# Maps from s2n_blocked_status (0=NOT_BLOCKED, 1=READ, 2=WRITE) plus an
# error sentinel for S2N_FAILURE return paths.

comptime TLS_OUTCOME_DONE: UInt8 = 0
"""Handshake / IO operation completed successfully. For handshake: the
TLS session is established and recv/send is now valid. For send/recv:
the requested byte count was accepted/produced."""

comptime TLS_OUTCOME_BLOCKED_ON_READ: UInt8 = 1
"""Operation needs more wire bytes from the peer. Caller should arm
INTEREST_READ on the reactor (see `handshake_state.mojo`) and retry
when EPOLLIN / EVFILT_READ fires."""

comptime TLS_OUTCOME_BLOCKED_ON_WRITE: UInt8 = 2
"""Operation needs the kernel send buffer to drain. Caller should arm
INTEREST_WRITE and retry on EPOLLOUT / EVFILT_WRITE."""

comptime TLS_OUTCOME_ERROR: UInt8 = 3
"""Operation failed irrecoverably (e.g. handshake alert, peer reset,
protocol-violation). The caller MUST close the connection. The
specific s2n errno is queryable via `last_s2n_errno()` immediately
after the call (thread-local; do not call into s2n in between)."""

comptime TLS_VERSION_TLS12: Int = 33
"""`TlsConnection.negotiated_tls_version()` for TLS 1.2 (s2n's S2N_TLS12)."""

comptime TLS_VERSION_TLS13: Int = 34
"""`TlsConnection.negotiated_tls_version()` for TLS 1.3 (s2n's S2N_TLS13)."""


@always_inline
def _blocked_status_to_outcome(blocked: Int32, rc: Int64) -> UInt8:
    """Map an (rc, *blocked) pair from s2n_negotiate / send / recv /
    shutdown to a TLS_OUTCOME_*.

    ⛔ THIS HELPER IS PRIVATE TO `_error_typed_outcome` AND
    `_recv_outcome_and_n`, AND IT IS NOT THE CLASSIFIER. Do not call it
    directly, and do not read the mapping below as the shim's contract. EVERY
    s2n entry point routes through an
    ERROR-TYPE-keyed classifier first — `handshake` (`s2n_negotiate`),
    `send`, `recv_into_span` and `shutdown` — and this helper is reached only
    on the two arms where `*blocked` is genuinely meaningful: `rc >= 0`
    (success) and `s2n_error_get_type() == S2N_ERR_T_BLOCKED` (a real
    would-block).

    ⛔⛔ `*blocked` IS A PRESET, NOT AN ANSWER. *"s2n returns -1 on BOTH
    blocked-by-IO AND hard-error cases, the canonical disambiguator is
    `*blocked`"* IS FALSE. s2n sets `*blocked` at ENTRY, before it
    attempts any I/O, and every reset to `S2N_NOT_BLOCKED` sits on a SUCCESS
    path (`tls/s2n_recv.c:176` + `:281-290`, `tls/s2n_send.c:85`/`:156`,
    `tls/s2n_handshake_io.c:1626`/`:1658`, `tls/s2n_shutdown.c:129`), so on
    EVERY failure return it still claims `BLOCKED_ON_*`. The disambiguator is
    `s2n_error_get_type(s2n_errno)`. `_recv_outcome_and_n` below carries the
    full measurement.

    ⚠ The warning comes FIRST on purpose: a reader who meets the false claim
    before its refutation is sent the wrong way. A stale docstring on a hot
    path is a defect with a measurable cost, not cosmetics.

    The mapping below is applied ONLY on the two arms named above:

      rc == -1 + blocked == BLOCKED_ON_READ  → blocked-on-read (retry)
      rc == -1 + blocked == BLOCKED_ON_WRITE → blocked-on-write (retry)
      rc == -1 + blocked == NOT_BLOCKED      → hard error (caller closes)
      rc >= 0  + blocked == NOT_BLOCKED      → done (n bytes for send/recv;
                                                handshake complete for negotiate)
      rc >= 0  + blocked != NOT_BLOCKED      → partial (treat as blocked)

    Phase 1: S2N_BLOCKED_ON_APPLICATION_INPUT (3) +
    S2N_BLOCKED_ON_EARLY_DATA (4) treated as hard error (no client-hello-CB
    / 0-RTT support).

    Per s2n.h `s2n_negotiate` documentation + observed runtime behavior
    on macOS (errno 201326592 = "underlying I/O operation would block",
    set when the bound fd is non-blocking and read() returns EWOULDBLOCK).
    """
    if blocked == S2N_BLOCKED_ON_READ:
        return TLS_OUTCOME_BLOCKED_ON_READ
    if blocked == S2N_BLOCKED_ON_WRITE:
        return TLS_OUTCOME_BLOCKED_ON_WRITE
    if blocked == S2N_NOT_BLOCKED:
        if rc < Int64(0):
            return TLS_OUTCOME_ERROR
        return TLS_OUTCOME_DONE
    # S2N_BLOCKED_ON_APPLICATION_INPUT (3) or S2N_BLOCKED_ON_EARLY_DATA (4):
    # not supported in Phase 1; treat as error so caller closes the conn.
    return TLS_OUTCOME_ERROR


@always_inline
def _recv_outcome_and_n(blocked: Int32, rc: Int64) -> Tuple[UInt8, Int]:
    """Map an (rc, *blocked) pair from `s2n_recv` to a (TLS_OUTCOME_*, n).

    ★ `*blocked` IS NOT A DISAMBIGUATOR ON THE RECV PATH, AND
    `_blocked_status_to_outcome`'s docstring above is WRONG FOR THIS CASE. Read
    the s2n-tls v1.5.6 source:

      tls/s2n_recv.c:176      `*blocked = S2N_BLOCKED_ON_READ;` — set at ENTRY,
                              unconditionally, before any I/O is attempted. The
                              comment above it says so in as many words: "The
                              only case in which it should be updated is on a
                              successful read into the provided buffer."
      tls/s2n_recv.c:281-290  the ONLY reset to S2N_NOT_BLOCKED sits AFTER the
                              read loop, so NO error return ever reaches it.

    ⇒ EVERY `s2n_recv` FAILURE — a closed peer, an ECONNRESET, a protocol
    error — comes back claiming BLOCKED_ON_READ, and a shim that believes it
    returns `Pending`.

    ★★ AND `*blocked` LIES A SECOND WAY, ON SUCCESS — THE POSITIVE PARTIAL.
    Read the same reset again and notice what it is gated on:

      tls/s2n_recv.c:281-290  `if (s2n_stuffer_data_available(&conn->in) == 0)`

    That is s2n's OWN userspace buffer, NOT the socket. So `*blocked` also
    means "conn->in still holds plaintext you had no room for", and EVERY read
    whose destination is smaller than the record it lands on returns
    `rc > 0` WITH `*blocked = S2N_BLOCKED_ON_READ`. Those bytes are ALREADY
    GONE — `s2n_stuffer_erase_and_read` copied them into the caller's buffer
    and erased them — so a caller that reads the block label as "nothing
    happened" DISCARDS THEM PERMANENTLY (for example by mapping it to a
    `StreamIo.pending`, a variant with no byte-count field).

    ⚠ THIS IS THE ORDINARY READ, NOT AN EDGE. 4096 is the h1 client's own
    scratch (`client.mojo`, `state_machine.mojo`) and s2n's default outgoing
    fragment is 8087 plaintext bytes (`S2N_DEFAULT_RECORD_LENGTH 8092` − 5,
    tls/s2n_tls_parameters.h), so just over HALF of every large TLS
    response would be thrown away: exactly 32768 of 65536 bytes through
    the production `TlsClientStream.try_read` seam. `send` already reserves a
    BLOCKED outcome for "accepted NOTHING"; this is that rule, mirrored.
    Falsifier: `test_L1_tls_recv_partial_plaintext_lost`.

    THE CLOSED-PEER SPIN. Without the error-type check a request on a reaped
    connection ends as

        HttpError[TIMEOUT]: h2 driver iteration cap exceeded
        (iters=100001, elapsed_ms=753, wall_budget_ms=120000,
         parks=100000, idle_parks=0)

    A peer FIN with NO close_notify — what every load balancer and every GFE
    does when it reaps an idle pooled connection — sets `conn->read_closed`
    (s2n_recv.c:66-70 via utils/s2n_io.c:33-38) and thereafter EVERY call
    short-circuits at s2n_recv.c:178 and returns -1, still claiming
    BLOCKED_ON_READ. Laundered into `Pending`, that makes a CLOSED connection
    indistinguishable from a slow one: `drive_h2_streams_to_completion` parks
    on read-readiness, a closed socket is PERMANENTLY readable (level-triggered
    EPOLLIN; read() returns 0), so every park returns READY without waiting —
    `idle_parks=0`, exactly — the retry returns Pending again, and the loop
    spins ~7.5us a trip until its budget runs out. The spin lives here, not in
    the driver's give-up word.

    THE ANSWER s2n ITSELF NAMES is the error TYPE (api/s2n.h:140-143, 168-176):

      S2N_ERR_T_BLOCKED  — a genuine would-block. Trust `*blocked`, retry.
      S2N_ERR_T_CLOSED   — the peer is gone. s2n's own doc comment for this
                           enumerator is one word: "EOF".
      anything else      — a hard error; the caller must close.

    A CLOSED read is reported as `(TLS_OUTCOME_DONE, 0)`, which is the SAME
    shape a graceful close_notify already produces, so every existing consumer
    handles it unchanged (`_map_tls_outcome_to_stream_io` turns DONE + n==0 on
    a read into `StreamIo.eof()`). Conflating abrupt with graceful is
    deliberate AT THIS LAYER: both mean "no more bytes will arrive". The
    distinction that matters — whether the application-level message was
    complete — belongs to the protocol above, and h2 already keeps it (an
    unfinished stream raises EOF_MID_RESPONSE, a finished one returns).

    ⚠ Only consulted when `rc < 0`. A successful call must not have its errno
    read: `s2n_errno` is thread-local and STICKY, so a stale value from an
    earlier failure would otherwise be attributed to this one.

    ⚠ CALL IMMEDIATELY AFTER `s2n_recv`, with no intervening s2n call, for the
    same reason `last_s2n_errno()` documents.

    Falsifier: `test_L2_h2_over_tls_abrupt_close_no_spin`
    — §0 pins the s2n contract by calling `s2n_recv` directly (so it keeps
    holding after this mapping changes, and reds on an s2n bump), §1 drives the
    real `TlsClientStream` transport through an abrupt peer close and requires
    EOF_MID_RESPONSE with no spin.

    ★ THE SEND PATH HAS THE SAME SHAPE:
    `test_L2_h2_over_tls_send_to_departed_peer_no_spin`.
    See `_error_typed_outcome`, which is this function's rule with the
    recv-only CLOSED->EOF arm removed.
    """
    if rc > Int64(0):
        # ★ THE SECOND WAY `*blocked` LIES, AND IT IS DATA LOSS. See the
        # POSITIVE-PARTIAL section of this docstring: s2n has DECRYPTED `rc`
        # bytes into the caller's buffer and ERASED them from `conn->in`, so
        # DONE-with-n is the only truthful answer regardless of `*blocked`.
        # This is the mirror of the same special case in `send`.
        return (TLS_OUTCOME_DONE, Int(rc))
    if rc == Int64(0):
        # Success with zero bytes — the graceful close_notify EOF (or, if
        # `*blocked` is set, a degenerate zero-capacity read).
        return (_blocked_status_to_outcome(blocked, rc), 0)
    var err_type = s2n_error_get_type(last_s2n_errno())
    if err_type == S2N_ERR_T_BLOCKED:
        return (_blocked_status_to_outcome(blocked, rc), -1)
    if err_type == S2N_ERR_T_CLOSED:
        # EOF. `_map_tls_outcome_to_stream_io` renders DONE + 0 on a read as
        # `StreamIo.eof()`; the protocol layer decides whether that is graceful.
        return (TLS_OUTCOME_DONE, 0)
    return (TLS_OUTCOME_ERROR, -1)


@always_inline
def _error_typed_outcome(blocked: Int32, rc: Int64) -> UInt8:
    """Map an (rc, `*blocked`) pair from ANY s2n entry point that is NOT a read
    to a `TLS_OUTCOME_*`, keying a FAILURE on `s2n_error_get_type` rather than
    on `*blocked`.

    ★ THE GENERALISATION OF `_recv_outcome_and_n`, AND THE FIX FOR THE SEND-SIDE
    LIVELOCK. `_recv_outcome_and_n` established that `*blocked` is not a
    disambiguator on `s2n_recv`, because s2n presets it at entry and resets it
    only on success. **EVERY s2n ENTRY POINT DOES THAT** — it is a property of
    how s2n reports, not of the recv path:

      tls/s2n_send.c:85          `s2n_flush`: `*blocked = S2N_BLOCKED_ON_WRITE;`
                                 set at ENTRY, before the first `write(2)`.
                                 The ONLY reset is line 102, AFTER the write
                                 loop, so no error return reaches it.
      tls/s2n_send.c:156         `s2n_sendv_with_offset_impl` sets it again
                                 before the record loop; the reset is line 242,
                                 after the loop.
      tls/s2n_handshake_io.c:    `s2n_negotiate_impl` sets BLOCKED_ON_WRITE
        1626 / 1658              (writer) or BLOCKED_ON_READ (reader) BEFORE
                                 the I/O it is about to attempt, and reaches
                                 `*blocked = S2N_NOT_BLOCKED` (line 1691) only
                                 by completing the whole handshake.

    ⇒ A `write(2)` that fails EPIPE / ECONNRESET — what the kernel returns the
    instant a load balancer or a GFE reaps the pooled connection we are sending
    on — comes back from `s2n_send` as **`(-1, S2N_BLOCKED_ON_WRITE)`**, with
    `s2n_errno = S2N_ERR_IO` (`S2N_ERR_T_IO`; utils/s2n_io.c:22-30 reserves
    `S2N_ERR_IO_BLOCKED` for EWOULDBLOCK/EAGAIN and nothing else).

    THE SPIN THAT PRODUCES, AND WHY IT IS PERMANENT. Believing `*blocked` returns
    `TLS_OUTCOME_BLOCKED_ON_WRITE`;
    `_map_tls_outcome_to_stream_io` turns that into `StreamIo.pending`; the h2
    drive parks on WRITE-readiness. A socket whose peer is gone is
    PERMANENTLY write-ready (`EPOLLERR`/`EPOLLHUP` are reported whatever you
    registered), so `park_on_pending` returns READY on its first poll every
    time — `idle_parks=0` — and the retried `s2n_send` re-enters `s2n_flush`
    over the SAME undrained `conn->out` stuffer and fails identically. Nothing
    clears the state: a failed write does NOT set `conn->write_closed` (the only
    two writers are `s2n_shutdown` and `s2n_connection_set_io_status`), so the
    next call repeats it rather than short-circuiting to `S2N_ERR_CLOSED`.
    ⇒ `HttpError[LIVELOCK]: ... 4096 consecutive READY parks`, on POOLED
    connections.

    THE MAPPING, and how it differs from the read one:

      rc >= 0                       — the caller's own success rule (this
                                      function is only for `rc < 0`; callers
                                      handle their positive-partial first).
      S2N_ERR_T_BLOCKED             — a GENUINE would-block. `*blocked` is
                                      trustworthy here and only here.
      anything else                 — `TLS_OUTCOME_ERROR`. The caller closes.

    ⚠ **THERE IS DELIBERATELY NO `S2N_ERR_T_CLOSED -> DONE(0)` ARM.** On a read,
    "closed" IS the answer — it is EOF, and every consumer already renders it.
    On a send or a handshake there is no such thing as a successful zero-byte
    outcome: `_map_tls_outcome_to_stream_io` maps DONE+0 on a write to
    `StreamIo.ready(0)`, and a READY that moved zero bytes increments the h2
    drive's `ready_no_progress` exactly like a Pending does
    (see `drive_h2_streams_to_completion`) — i.e. it would relocate the identical spin
    one branch over. CLOSED on a write means the request cannot be delivered,
    which is an ERROR.

    ⚠ Only consulted when `rc < 0`, for the same reason `_recv_outcome_and_n`
    documents: `s2n_errno` is thread-local and STICKY, so reading it after a
    SUCCESSFUL call attributes an older failure to this one.

    ⚠ CALL IMMEDIATELY AFTER THE s2n CALL, with no intervening s2n call.

    Falsifier:
    `test_L2_h2_over_tls_send_to_departed_peer_no_spin` —
    §0 pins the s2n contract by calling `s2n_send` directly over the raw
    connection (so it survives any change to this mapping and reds on an s2n
    bump), §1 drives the real `TlsClientStream` transport into a departed peer
    and requires a classified raise with no spin.
    """
    if rc >= Int64(0):
        return _blocked_status_to_outcome(blocked, rc)
    var err_type = s2n_error_get_type(last_s2n_errno())
    if err_type == S2N_ERR_T_BLOCKED:
        return _blocked_status_to_outcome(blocked, rc)
    return TLS_OUTCOME_ERROR


# =============================================================================
# Library init — process-once (idempotent within s2n itself)
# =============================================================================


# -----------------------------------------------------------------------------
# Process-local s2n_init-once guard (the `_Global` KGEN runtime slot).
#
# WHY NOT AN ENVIRONMENT VARIABLE:
# An "already initialized" flag kept in the environment is INHERITED across
# `fork()` / `fork+exec`, but s2n's C library
# state is PER-PROCESS and does NOT survive fork — `s2n_init()` must run once
# in EACH process. A nested child process (a CLI run by a script the parent
# spawned) would inherit the flag, its `tls_init()` would short-circuit,
# `s2n_init()` would never run for the child, and every TLS handle would fail
# (`s2n_config_new` returns NULL).
#
# So init state lives in the stdlib `_Global[name, init_fn]` slot — the
# same process-lifetime, init-once, KGEN-serialized idiom the core packages' codec
# singletons use. `_Global` storage lives in the process's OWN
# memory and is NOT inherited across a process boundary: a freshly `fork`ed
# child gets a fresh, uninitialized slot and runs `s2n_init()` exactly once for
# ITSELF. The slot stores the `s2n_init` return code (0 on success) so
# `tls_init()` can re-raise the same error semantics as before on the first
# call's S2N_FAILURE. Init-once is guaranteed by `_Global` (the init_fn runs at
# most once per process); the KGEN runtime serializes the init so it is safe
# under concurrent `tls_init()` from multiple threads.
# -----------------------------------------------------------------------------


def _init_s2n_once() -> OwnedPointer[Int32]:
    """`_Global` init_fn (non-raising): call `s2n_init()` EXACTLY ONCE for THIS
    process and return the `s2n_init` return code stored behind an
    `OwnedPointer`.

    Mirrors the `snappy_ffi._init_snappy_mojo_flag` process-flag idiom
    (`alloc` + raw store + `OwnedPointer(unsafe_from_raw_pointer=)`). The
    return code (0 == S2N_SUCCESS) is inspected by `tls_init()`, which raises
    on the first call if init failed — preserving the pre-fix error semantics.

    ★ IT ALSO IGNORES SIGPIPE, AND THAT IS NOT OPTIONAL HERE.
    `socket_io.try_send` passes MSG_NOSIGNAL, which makes the PLAINTEXT path
    safe against a departed peer. **It does not reach the TLS path at all.**
    We bind s2n fd-direct (`s2n_connection_set_fd`, `TlsConnection.bind_fd`),
    so s2n owns the syscall, and s2n issues a bare `write(2)`:

        s2n-tls/utils/s2n_socket.c:221   ssize_t result = write(wfd, buf, len);

    `write(2)` takes NO flags argument, so MSG_NOSIGNAL is not expressible
    there — and s2n's own header states the consequence verbatim, on the very
    function we call:

        s2n.h:1713-1714 (@ s2n_connection_set_fd)
          "If the read end of the pipe is closed unexpectedly, writing to the
           pipe will raise a SIGPIPE signal. s2n-tls does NOT handle SIGPIPE.
           A SIGPIPE signal will cause the process to terminate unless it is
           handled or ignored by the application."

    So for every HTTPS server in this repo, a client that closes mid-response
    terminates the whole process — dropping every OTHER connection it was
    serving — and the socket-layer fix cannot prevent it. A process-level
    SIG_IGN is the ONLY mechanism that can, because the syscall is not ours.

    WHY HERE. This slot is (a) reached by exactly the processes that use s2n,
    (b) run at most ONCE per process, so the cost is one `sigaction` at first
    TLS use and nothing in the connection path, and (c) — the ordering-robust
    part — re-run independently in each FORKED CHILD, because `_Global` storage
    is process-private and is not inherited (see the rationale block above).

    (c) is worth stating precisely, because the obvious version of it is WRONG:
    signal dispositions DO survive `fork()`, so a child forked AFTER the parent
    initialised TLS would inherit the ignore regardless. The case that needs
    (c) is a child forked BEFORE the parent ever touched TLS — the normal shape
    for a server that preforks its workers during startup. Such a child
    inherits nothing useful and installs the disposition itself, at its own
    first TLS use. So this is correct wherever the fork falls relative to TLS
    init, which a one-shot call in `main()` would not be.

    Putting it in each binary's `main()` would also work, and would have to be
    remembered in every binary that serves TLS; this cannot be forgotten.

    Best-effort by design: a failed `sigaction` must not stop TLS from
    initialising — it degrades to the default SIGPIPE disposition, which is
    what the caller had anyway.
    """
    _ = ignore_sigpipe()
    var raw = alloc[Int32](1)
    raw[0] = s2n_init()
    return OwnedPointer[Int32](unsafe_from_raw_pointer=raw)


comptime _S2N_INIT_GLOBAL = _Global["komira_s2n_init_once", _init_s2n_once]


def tls_init() raises:
    """Initialize the s2n-tls library exactly once per process. The init-once
    guard is a TRUE process-local flag (the stdlib `_Global` KGEN runtime slot)
    — NOT an environment variable, so it NEVER crosses a `fork()` / `fork+exec`
    boundary. Each forked process re-runs `s2n_init()` exactly once for itself.

    `s2n_init()` itself is NOT idempotent (returns S2N_FAILURE on a second call
    per s2n.h:230 "should only be called once"), so the `_Global` slot is what
    makes THIS function idempotent within a process.

    Per s2n docs: `s2n_init()` should be called once per process before any
    other s2n function. We call this lazily from `TlsConfig.__init__` (first
    config constructed in the process).

    Raises Error on the first call's S2N_FAILURE return. Subsequent calls in
    the same process are no-ops (the slot's init_fn ran once). See the
    process-local-guard rationale block above for the fork-inheritance bug this
    replaced.

    SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    process-lifetime static storage; `MutUntrackedOrigin` is the stdlib
    `_Global` API's own return type, confined to this call. The init_fn runs
    `s2n_init()` at most once per process (thread-safe via the KGEN runtime).
    """
    # First deref: the process-global OwnedPointer (running init_fn on first
    # touch). Second deref: the stored `s2n_init` return code.
    var rc = _S2N_INIT_GLOBAL.get_or_create_ptr()[][]
    if rc != S2N_SUCCESS:
        raise Error(
            "tls_init: s2n_init returned " + String(Int(rc))
            + " (errno=" + String(Int(last_s2n_errno())) + ")"
        )


# =============================================================================
# _S2nConfigHandle — internal RAII wrap for s2n_config_t*
# =============================================================================
#
# Internal wrapper struct; __deinit__ calls s2n_config_free, then
# s2n_cert_chain_and_key_free on each chain it owns. The opaque-handle field is the
# canonical FFI-POD opaque-handle precedent (the opaque-handle carve-out
# applied to opaque-handle FIELDS via the
# OwnedPointer-of-handle pattern on the public TlsConfig — the handle
# itself never lives directly on a destroy-recreate struct).


struct _S2nConfigHandle(Movable, Deinitable):
    """RAII wrap over an s2n_config_t*.

    The handle is constructed via `s2n_config_new()` and freed via
    `s2n_config_free()` in `__deinit__`, which then frees every cert chain
    in `_chains`. Field set:

      var _raw: S2nOpaquePtr  # UnsafePointer[NoneType, _S2N_FFI_ORIGIN]
        # SAFETY: opaque s2n_config_t pointer; never dereferenced
        # outside the FFI boundary. CONCRETE StaticConstantOrigin (NOT the
        # banned MutExternalOrigin wildcard) — stale-pointer fix. Null
        # sentinel (==0) = no live config (already freed, moved-from, or
        # default-constructed). The __del__ null-guard ensures double-free
        # safety on the moved-from instance.

    Movable, NOT Copyable — copy would double-free.
    """

    # SAFETY: opaque s2n_config_t pointer. Stored as `S2nOpaquePtr` =
    # `UnsafePointer[NoneType, _S2N_FFI_ORIGIN]` — the CONCRETE
    # `StaticConstantOrigin` FFI origin (the `komira_db_sqlite/ffi.mojo`
    # `_FFI_ORIGIN` precedent), NOT the banned `MutExternalOrigin` wildcard.
    # stale-pointer fix: the wildcard origin defeated
    # ASAP-destruction tracking across the `TlsConfig`/`TlsConnection` move,
    # which is what let the sibling connection handle's move stray-write the
    # live s2n heap struct (the Firestore Listen quic_enabled corruption). The
    # handle is opaque-by-value to external_call and never dereferenced
    # Mojo-side, so the immutable static origin is sound. It still lives inside
    # an OwnedPointer field on TlsConfig for a stable heap address.
    var _raw: S2nOpaquePtr

    # FFI-BOUNDARY: every s2n_cert_chain_and_key_t that
    # `TlsConfig.load_cert` handed to `s2n_config_add_cert_chain_and_key_to_store`.
    # s2n allocates each one (s2n_cert_chain_and_key_new); this handle owns
    # and frees each one (s2n_cert_chain_and_key_free) in `__deinit__`, after
    # s2n_config_free. s2n_config_free frees none of them: that API marks the
    # config's chains application-owned, and s2n's
    # `s2n_config_free_cert_chain_and_key` returns early for those
    # (tls/s2n_config.c). The config only borrows them, so they must outlive
    # it, and every connection bound to the config co-owns this handle
    # through the ArcPointer on TlsConfig.
    # SAFETY: each entry is an opaque pointer only passed to s2n, never
    # dereferenced Mojo-side; concrete `_S2N_FFI_ORIGIN` as for `_raw`.
    var _chains: List[S2nOpaquePtr]

    def __init__(out self):
        """Construct an empty handle (null sentinel). Call
        `Self.create()` to eagerly allocate the s2n config."""
        self._raw = _null_ptr[NoneType, _S2N_FFI_ORIGIN]()
        self._chains = List[S2nOpaquePtr]()

    @staticmethod
    def create() raises -> _S2nConfigHandle:
        """Allocate a fresh s2n_config_t and wrap it. Raises on OOM."""
        var h = _S2nConfigHandle()
        # SAFETY: s2n_config_new returns either a valid heap pointer or
        # NULL on OOM. We check for NULL and convert to a Mojo error.
        h._raw = s2n_config_new()
        if Int(h._raw) == 0:
            raise Error("_S2nConfigHandle.create: s2n_config_new returned NULL")
        return h^

    def __deinit__(deinit self):
        """Release the s2n_config_t if non-null, then every cert chain the
        config borrowed. Null-safe for moved-from and default-constructed
        instances."""
        # SAFETY: idempotent free + null-guard. The concrete
        # `_S2N_FFI_ORIGIN` opaque-handle origin justification is on the
        # field declaration above (stale-pointer fix).
        if Int(self._raw) != 0:
            var _rc = s2n_config_free(self._raw)
            # s2n_config_free can technically fail, but the only failure
            # mode is the config being already freed — which is the
            # double-free scenario we explicitly guard against. Ignore.
            # NO post-free null-out: `deinit self` means this value is being
            # destroyed, so the store is dead (the compiler reports it as
            # such, x177 across the build). The double-free guard is the
            # `if Int(self._raw) != 0` above, which is unaffected.
        # The chains go after the config that borrows them (FFI-BOUNDARY on
        # `_chains`).
        for chain in self._chains:
            # SAFETY: each chain came from s2n_cert_chain_and_key_new, is in
            # the list once, and no config uses it any more.
            var _rc_chain = s2n_cert_chain_and_key_free(chain)


# =============================================================================
# _S2nConnectionHandle — internal RAII wrap for s2n_connection_t*
# =============================================================================


struct _S2nConnectionHandle(Movable, Deinitable):
    """RAII wrap over an s2n_connection_t*.

    Same shape as `_S2nConfigHandle`. Constructed via `s2n_connection_new`
    + mode, freed via `s2n_connection_free` in `__del__` (which also
    wipes the connection internally).
    """

    # SAFETY: opaque s2n_connection_t pointer, stored as `S2nOpaquePtr` =
    # `UnsafePointer[NoneType, _S2N_FFI_ORIGIN]` (CONCRETE StaticConstantOrigin,
    # NOT the banned MutExternalOrigin wildcard). This is THE stale-pointer fix
    # this Movable owning-pointer FIELD (with a `__del__`) is
    # nested inside `TlsConnection` -> `TlsClientStream`; the prior wildcard
    # origin defeated ASAP-destruction tracking across the `return _stream^`
    # move out of `TlsConnector.connect`, letting the move stray-write the live
    # s2n connection heap struct (`conn->quic_enabled` flipped False->True
    # ~50%/launch on the live Firestore Listen path ->
    # S2N_ERR_UNSUPPORTED_WITH_QUIC / zero-bytes). A concrete static origin
    # removes the hazard; the handle is opaque-by-value to external_call and
    # never dereferenced Mojo-side, so the immutable static origin is sound. See
    # _S2nConfigHandle for the full precedent. Regression guard:
    # tests/test_L1_tls_connector_move_no_stray_write.mojo.
    var _raw: S2nOpaquePtr

    def __init__(out self):
        """Construct an empty handle (null sentinel)."""
        self._raw = _null_ptr[NoneType, _S2N_FFI_ORIGIN]()

    @staticmethod
    def create(mode: Int32) raises -> _S2nConnectionHandle:
        """Allocate a fresh s2n_connection_t in the given mode
        (S2N_SERVER or S2N_CLIENT)."""
        var h = _S2nConnectionHandle()
        # SAFETY: s2n_connection_new returns valid pointer or NULL on OOM.
        h._raw = s2n_connection_new(mode)
        if Int(h._raw) == 0:
            raise Error(
                "_S2nConnectionHandle.create: s2n_connection_new returned NULL"
            )
        return h^

    def __deinit__(deinit self):
        """Release the s2n_connection_t (also wipes internally)."""
        # SAFETY: idempotent free + null-guard. Per s2n.h:2305-2306,
        # s2n_connection_free wipes the connection internally before
        # freeing — handles in-flight crypto state cleanup transparently.
        if Int(self._raw) != 0:
            var _rc = s2n_connection_free(self._raw)
            # NO post-free null-out — see `_S2nConfigHandle.__del__`: on a
            # `deinit self` the store is dead, and the null-guard above is
            # what makes the free idempotent.


# =============================================================================
# TlsConfig — public safe wrapper over _S2nConfigHandle
# =============================================================================
#
# per-server TLS config (cert chain + private key + ALPN list).
# OwnedPointer-of-handle storage gives the handle a stable heap address
# (Rust's `Box<T>`) and prevents the destroy-recreate / wildcard-origin
# hazard. The public surface accepts safe Mojo types only — no
# raw pointer crosses any module boundary.


struct TlsConfig(Copyable, Movable, Deinitable):
    """Per-server / per-client TLS configuration.

    Lifecycle:
      - `TlsConfig()` constructs the underlying s2n_config_t (raises on OOM).
        Lazily ensures `tls_init()` has been called.
      - `load_cert(cert_pem, key_pem)` parses the PEM cert chain + private
        key and attaches them to the config.
      - `set_alpn_protocols(["http/1.1"])` configures ALPN.
      - Moves transfer ownership of the underlying Arc handle.
      - `.copy()` is a REFCOUNT BUMP that shares the SAME s2n_config_t
        (see the SHARE-OWNERSHIP note below).
      - Drop decrements the Arc; the s2n_config_t, and then every cert
        chain `load_cert` added, are freed only when the LAST clone drops.

    SHARE-OWNERSHIP.
    s2n's `s2n_connection_set_config(conn, config)` stashes `conn->config`
    as a RAW C borrow the Mojo type system cannot see. s2n then reads
    `config->quic_enabled` (via `s2n_connection_is_quic_enabled`) on the
    hot send path — so the s2n_config_t MUST outlive every connection that
    was ever bound to it. The PRIOR shape (`OwnedPointer[_S2nConfigHandle]`
    on TlsConfig + NO config reference on TlsConnection) made this contract
    UNENFORCED: a dial-once caller that dropped the `TlsConnector` (whose
    `OwnedPointer[TlsConfig]` was the sole owner) right after `connect()`
    freed the config out from under the still-live returned
    `TlsClientStream`, and the next `s2n_send`'s `conn->config->quic_enabled`
    read was a HEAP-USE-AFTER-FREE (garbage `quic_enabled=1` →
    S2N_ERR_UNSUPPORTED_WITH_QUIC / zero bytes on the live Firestore Listen
    path). The FIX makes the s2n_config_t SHARE-OWNED via `ArcPointer`:
    `TlsConnection` now holds a CLONE (`self._config`) of the config it was
    bound to (taken in `__init__`), so the Arc keeps the s2n_config_t alive
    until BOTH the connector AND every connection that cloned it are dropped.
    The `conn->config` borrow is therefore ALWAYS valid — compiler-enforced
    by the Arc refcount, not an unenforced field-lifetime convention.
    Regression guard: tests/test_L1_tls_config_lifetime_uaf.mojo.
    """

    # ArcPointer-of-handle: SHARE-OWNED s2n_config_t with a stable heap
    # address. `.copy()` is a refcount bump sharing the same underlying
    # handle; the s2n_config_t is freed by _S2nConfigHandle.__del__ only
    # when the last Arc clone drops. This is the
    # fix (see the SHARE-OWNERSHIP note above): TlsConnection co-owns a
    # clone so `conn->config` outlives the connection provably.
    var _handle: ArcPointer[_S2nConfigHandle]

    def __init__(out self) raises:
        """Construct an empty TlsConfig. Lazily initializes s2n-tls on
        first call within a process.
        """
        # Lazy library init. s2n_init is internally idempotent.
        tls_init()
        # Allocate the inner handle behind an Arc (SHARE-OWNED). The
        # handle's __del__ calls s2n_config_free when the last clone drops.
        self._handle = ArcPointer[_S2nConfigHandle](
            _S2nConfigHandle.create()
        )

    def copy(self) -> Self:
        """Return a SHARE-OWNED clone of this config — a single Arc
        refcount bump that shares the SAME underlying s2n_config_t.

        This is the mechanism the fix relies on:
        `TlsConnection.__init__` clones the caller's config into its own
        `self._config` field so the s2n_config_t (borrowed by `conn->config`)
        outlives the connection. Cloning does NOT duplicate the s2n config;
        both clones point at the same heap struct, freed only when the last
        one drops.
        """
        return Self(_handle=self._handle.copy())

    def __init__(out self, *, var _handle: ArcPointer[_S2nConfigHandle]):
        """Internal ctor from an existing Arc handle (used by `copy()`).
        Does NOT re-run `tls_init()` — the handle is already live."""
        self._handle = _handle^

    def load_cert(mut self, cert_pem: String, key_pem: String) raises:
        """Load a PEM-encoded cert chain + PKCS#8 private key into the
        config. This supports a single default cert
        + chain per config (multi-cert / SNI-routed is a follow-on).

        Raises on s2n parse error (e.g. malformed PEM, mismatched key) or
        when s2n refuses the chain for the config (e.g. its security policy
        forbids the key).
        """
        # Allocate a chain-and-key struct, load PEM into it, then attach
        # it to the config. A chain whose load fails is freed here. Once the
        # attach is attempted, the config handle owns the chain and frees it
        # after s2n_config_free (FFI-BOUNDARY on `_S2nConfigHandle._chains`).
        # SAFETY: chain_ptr is opaque; only the FFI calls below
        # dereference it. The PEM byte buffers (cert_pem / key_pem
        # strings) are borrowed via `as_bytes()` and held in scope
        # across the external_call (synchronous).
        var chain_ptr = s2n_cert_chain_and_key_new()
        if Int(chain_ptr) == 0:
            raise Error(
                "TlsConfig.load_cert: s2n_cert_chain_and_key_new returned NULL"
            )

        var cert_bytes = cert_pem.as_bytes()
        var key_bytes = key_pem.as_bytes()
        # SAFETY: load_pem_bytes is synchronous; both byte slices are
        # held in scope (cert_pem + key_pem locals) across the call.
        # The cast to _S2N_FFI_ORIGIN matches the FFI ABI.
        # Order: unsafe_mut_cast[True]() BEFORE unsafe_origin_cast (matches
        # _span_ptr in compression_codecs.mojo:205-209).
        var cert_ptr = cert_bytes.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var key_ptr = key_bytes.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc_load = s2n_cert_chain_and_key_load_pem_bytes(
            chain_ptr,
            cert_ptr,
            UInt32(len(cert_bytes)),
            key_ptr,
            UInt32(len(key_bytes)),
        )
        if rc_load != S2N_SUCCESS:
            # SAFETY: we still own the chain on the failure path; free it.
            var _rc_free = s2n_cert_chain_and_key_free(chain_ptr)
            raise Error(
                "TlsConfig.load_cert: s2n_cert_chain_and_key_load_pem_bytes "
                "failed (rc=" + String(Int(rc_load)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

        # SAFETY: read the raw config pointer via the handle. The
        # handle is alive (we just constructed self). The handle takes the
        # chain BEFORE the attach: a failed attach can leave the pointer in
        # the config's SNI map (s2n builds the map before its last check),
        # so the chain is freed with the config, not here.
        self._handle[]._chains.append(chain_ptr)
        var config_ptr = self._handle[]._raw
        var rc_add = s2n_config_add_cert_chain_and_key_to_store(
            config_ptr, chain_ptr
        )
        if rc_add != S2N_SUCCESS:
            raise Error(
                "TlsConfig.load_cert: "
                "s2n_config_add_cert_chain_and_key_to_store failed (rc="
                + String(Int(rc_add)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )
        # The config borrows the chain; _S2nConfigHandle.__deinit__ frees it.

    def set_alpn_protocols(mut self, protocols: List[String]) raises:
        """Set the ALPN protocol list. Phase 1: `["http/1.1"]`.
        (HTTP/2) will pass `["h2", "http/1.1"]`.

        Implementation: loops `s2n_config_append_protocol_preference`
        per-protocol (simpler + safer than the argv-style
        `s2n_config_set_protocol_preferences` which requires a
        pointer-to-pointer marshaling that has surprising shape
        constraints in Mojo's FFI.

        Per s2n.h:1096 contract: protocol_len cannot be 0 (raises here).

        Not atomic: when protocol `i` is refused (empty, over 255 bytes, or
        by s2n), protocols `0..i-1` stay appended on the config.
        """
        var n = len(protocols)
        if n == 0:
            raise Error(
                "TlsConfig.set_alpn_protocols: empty protocol list"
            )
        var config_ptr = self._handle[]._raw
        var i = 0
        while i < n:
            var s = protocols[i]
            var bs = s.as_bytes()
            var blen = len(bs)
            if blen == 0:
                raise Error(
                    "TlsConfig.set_alpn_protocols: protocol "
                    + String(i) + " is empty (s2n disallows zero-length)"
                )
            if blen > 255:
                raise Error(
                    "TlsConfig.set_alpn_protocols: protocol "
                    + String(i) + " length " + String(blen)
                    + " exceeds 255-byte limit"
                )
            # SAFETY: synchronous FFI call; s2n copies the protocol
            # bytes into its own config arena before returning, so the
            # `bs` view (rooted at the local `s` String) can be
            # released after this call.
            var p = bs.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
            var rc = s2n_config_append_protocol_preference(
                config_ptr, p, UInt8(blen)
            )
            if rc != S2N_SUCCESS:
                raise Error(
                    "TlsConfig.set_alpn_protocols: "
                    "s2n_config_append_protocol_preference[" + String(i)
                    + "] failed (rc=" + String(Int(rc)) + ", errno="
                    + String(Int(last_s2n_errno())) + ")"
                )
            i = i + 1

    def set_cipher_preferences(mut self, version: String) raises:
        """Set the s2n security policy (cipher / signature / ecc preferences
        + protocol-version range) on this config by named version string.

        The default policy
        a fresh config carries in s2n-tls 1.5.6 (`"default"`) offers ONLY
        TLS 1.2 cipher suites, so a CLIENT built on it sends a TLS-1.2-only
        ClientHello that TLS-1.3-preferring servers (Postgres 16 OpenSSL,
        K8s apiserver Go crypto/tls) reject before ServerHello. Calling
        this with `"default_tls13"` makes the client offer TLS 1.3 and
        interop with both server families.

        Common version strings (s2n 1.5.6):
          - "default_tls13" - modern; offers TLS 1.3 + 1.2. Use for clients.
          - "20230317"      - FIPS-style modern policy; also TLS 1.3-capable.
          - "default"       - TLS 1.2 ONLY in 1.5.6 (no 1.3 suites).

        Additive + symmetric: usable on both server and client configs. The
        existing server path (HttpServer.with_tls) does not call this and
        keeps its current default-policy behavior unchanged.

        Raises on s2n FFI failure (e.g. an unknown / unsupported version
        string returns S2N_FAILURE).
        """
        # SAFETY: synchronous FFI call. s2n looks up the named policy in
        # its static table and stores a pointer to the STATIC policy
        # struct on the config; it does not retain the `version` buffer.
        # The String borrow is held alive across the external_call via the
        # `version_local` rebind (as_c_string_slice is mutating; can't be
        # called on a function-arg rvalue). `as_c_string_slice().unsafe_ptr()`
        # returns Int8*; s2n's `const char *version` matches that ABI. We
        # bitcast to UInt8 to satisfy our typed FFI binding's UInt8*
        # signature (same pattern as add_trust_pem / set_server_name).
        var version_local = version
        var version_ptr = version_local.as_c_string_slice().unsafe_ptr(
        ).bitcast[UInt8]().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_config_set_cipher_preferences(
            self._handle[]._raw, version_ptr
        )
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConfig.set_cipher_preferences: "
                "s2n_config_set_cipher_preferences failed for version='"
                + version + "' (rc=" + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    # -------------------------------------------------------------------------
    # Client-mode extensions
    # -------------------------------------------------------------------------
    #
    # Additive methods for client-mode TLS configuration. ZERO modification
    # of the existing server-side path: `load_cert`, `set_alpn_protocols`,
    # `_raw_config_ptr` are unchanged and continue to work for the
    # server path (HttpServer.with_tls).
    #
    # Client-mode config surface:
    #   - enable_verify_default() — see "no-op" note below.
    #   - disable_verify()        — wraps s2n_config_disable_x509_verification.
    #   - add_trust_pem(pem)      — wraps s2n_config_add_pem_to_trust_store.
    #   - wipe_trust()            — wraps s2n_config_wipe_trust_store.
    #   - enable_session_tickets() — see its docstring.

    def enable_verify_default(mut self):
        """Configure the client side to verify the server's certificate
        chain against the trust store using default behavior.

        IMPORTANT: there is no
        `s2n_config_set_verification_type(config, VERIFY_PEER)`;
        that symbol DOES NOT EXIST in upstream s2n-tls 1.5.6
        (`api/s2n.h`). The closest concept in s2n
        is the DEFAULT behavior: a freshly-allocated `s2n_config_t`
        already verifies the peer's cert chain. There is no "enable
        verify" call to bind.

        This method is therefore a documented **no-op** that exists for
        symmetry with `disable_verify()`. Callers can write
        `config.enable_verify_default()` to make intent explicit at the
        call site; the actual behavior is "verification is already on".

        To customize trust roots, call `add_trust_pem(pem)` (and
        optionally `wipe_trust()` first to remove the default OS roots).

        Does NOT raise — no FFI call.
        """
        # Documented no-op. The fresh config returned by s2n_config_new()
        # already verifies the peer cert chain; no FFI symbol needs to
        # be invoked to "turn verification on".
        _ = self  # mark self as used

    def disable_verify(mut self) raises:
        """Disable X.509 certificate-chain verification on the client
        side. Used for self-signed test fixtures or other test paths
        where verification is intentionally skipped.

        DO NOT use in production. There is no s2n symbol to re-enable
        verification on the same config after this call — it is
        one-way.

        Raises on s2n FFI failure (S2N_FAILURE rc).
        """
        # SAFETY: synchronous FFI call. The handle is alive (we hold
        # &self); the raw pointer never escapes this function.
        var rc = s2n_config_disable_x509_verification(self._handle[]._raw)
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConfig.disable_verify: "
                "s2n_config_disable_x509_verification failed (rc="
                + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    def add_trust_pem(mut self, pem: String) raises:
        """Append a PEM-encoded CA cert (or chain) to the config's
        trust store. The client side uses the trust store to verify
        the server's cert chain at handshake time.

        Per s2n.h:849: the trust store is INITIALIZED with the host
        OS's common CA locations by default. This call APPENDS to that
        set. To start from empty (for deterministic tests with EXACTLY
        one trusted root), call `wipe_trust()` first.

        `pem` must be a NUL-terminated PEM-encoded cert. The String
        type stores its bytes with a trailing NUL (per Mojo's String
        contract), so we pass `as_c_string_slice().unsafe_ptr()`
        directly.

        Raises on s2n FFI failure (malformed PEM, OOM, etc).
        """
        # SAFETY: synchronous FFI call. s2n COPIES the parsed cert into
        # its config arena before returning, so the `pem` String can be
        # released after this call. The String borrow is alive across
        # the external_call.
        # `as_c_string_slice().unsafe_ptr()` returns `UnsafePointer[Int8]`
        # (the C `char *` ABI); s2n's `const char *pem` expects the same
        # byte ABI. We bitcast to `UInt8` to match our typed FFI binding
        # signature (which uses UInt8 throughout for consistency with
        # other byte-buffer bindings like s2n_send/s2n_recv).
        # Order: unsafe_mut_cast[True]() BEFORE unsafe_origin_cast
        # (matches existing _span_ptr / load_cert pattern).
        var pem_local = pem
        var pem_ptr = pem_local.as_c_string_slice().unsafe_ptr(
        ).bitcast[UInt8]().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_config_add_pem_to_trust_store(
            self._handle[]._raw, pem_ptr
        )
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConfig.add_trust_pem: "
                "s2n_config_add_pem_to_trust_store failed (rc="
                + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    def wipe_trust(mut self) raises:
        """Empty the config's trust store. After this call, the trust
        store contains NO roots; the next `add_trust_pem` calls build
        it from scratch.

        Use case: deterministic tests that need EXACTLY one specific
        root trusted (no OS-default roots polluting the verification
        path).

        Raises on s2n FFI failure (rare; documented as always-success
        in practice).
        """
        # SAFETY: synchronous FFI call. No pointer crosses any boundary
        # other than the opaque config handle.
        var rc = s2n_config_wipe_trust_store(self._handle[]._raw)
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConfig.wipe_trust: s2n_config_wipe_trust_store "
                "failed (rc=" + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    def enable_session_tickets(mut self) raises:
        """Enable client-side TLS session-resumption-via-tickets. After
        this call, s2n negotiates the session-ticket extension in the
        ClientHello and accepts tickets the server issues; subsequent
        `TlsConnection.get_session(...)` calls return non-empty blobs
        on handshake DONE.

        real impl
        replaces a no-op stub. Wires the s2n FFI binding
        `s2n_config_set_session_tickets_onoff(config, 1)`.

        Idempotent: calling twice is harmless (s2n just re-sets the
        same internal flag).

        Raises on s2n FFI failure. In s2n-tls 1.5.6 that is a NULL config
        or an allocation failure while creating the ticket keys; the call
        has no guard against a config already bound to a connection.
        """
        # SAFETY: synchronous config mutation. No pointer escapes; the
        # config handle's lifetime is owned by self via ArcPointer.
        var rc = s2n_config_set_session_tickets_onoff(
            self._handle[]._raw, UInt8(1),
        )
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConfig.enable_session_tickets: "
                "s2n_config_set_session_tickets_onoff failed (rc="
                + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    def _raw_config_ptr(
        ref self,
    ) -> S2nOpaquePtr:
        """Internal: return the raw s2n_config_t pointer. ONLY called by
        TlsConnection.__init__ to thread the config into s2n_connection_set_config.
        NEVER exposed publicly; module-internal.
        """
        # SAFETY: caller (TlsConnection.__init__) holds a `ref` to self
        # and never escapes the pointer beyond the synchronous
        # s2n_connection_set_config FFI call. Lifetime: the borrow
        # checker rejects code that drops self while the connection
        # still holds a non-owning reference into config.
        return self._handle[]._raw


# =============================================================================
# TlsConnection — public safe wrapper over _S2nConnectionHandle
# =============================================================================


struct TlsConnection(Movable, Deinitable):
    """Per-connection TLS state. One per accepted fd on a TLS-enabled listener.

    Lifecycle:
      - `TlsConnection(config)` constructs an s2n_connection_t in
        S2N_SERVER mode and attaches the config.
      - `bind_fd(fd)` attaches a socket fd.
      - `handshake()` drives one step of the TLS handshake; returns
        TLS_OUTCOME_*.
      - `send(data)` / `recv(buf)` post-handshake plaintext IO; same
        outcome shape.
      - `shutdown()` graceful TLS close_notify.
      - `sni_hostname()` queries the SNI hostname (server-side).
      - Drop frees the s2n_connection_t (which wipes internally).

    The fd's lifetime is OWNED BY THE CALLER — TlsConnection does NOT
    close the fd on drop. Callers (HttpServer's per-conn state machine)
    own the fd via TcpStream's RAII close-on-drop.

    The TLS CONFIG's lifetime, by contrast, is CO-OWNED: `__init__` /
    `new_client` clone the caller's `TlsConfig` into `self._config` (an Arc
    refcount bump sharing the same s2n_config_t). This is the
    fix — see the `_config` field note + TlsConfig's
    SHARE-OWNERSHIP docstring. The connection provably outlives its
    `conn->config` C borrow because it holds a share of the config.
    """

    var _handle: OwnedPointer[_S2nConnectionHandle]
    var _fd: Int32
    # SHARE-OWNED clone of the TlsConfig this connection was bound to.
    # fix: `s2n_connection_set_config`
    # stashes `conn->config` as a raw C borrow the type system cannot see,
    # and s2n reads `config->quic_enabled` on the hot send path — so the
    # s2n_config_t MUST outlive this connection. Holding a clone (Arc
    # refcount bump, same underlying s2n_config_t) makes the compiler
    # keep the config alive for exactly as long as this connection exists.
    # Freed only when BOTH the connector's TlsConfig AND this clone drop.
    # See TlsConfig's SHARE-OWNERSHIP note for the full root cause.
    var _config: TlsConfig
    # Set when `handshake()` first returns TLS_OUTCOME_DONE; gates
    # `negotiated_tls_version()`, whose s2n field holds a placeholder before.
    var _handshake_done: Bool

    def __init__(out self, ref config: TlsConfig) raises:
        """Construct a server-mode TLS connection bound to `config`.
        The fd is NOT bound yet — call `bind_fd` after.
        """
        var inner = _S2nConnectionHandle.create(S2N_SERVER)
        # Attach the config to the connection.
        # SAFETY: synchronous call; `config` borrow alive throughout.
        # The config's raw pointer is threaded directly. LIFETIME: we clone
        # `config` into `self._config` below so the s2n_config_t that
        # `conn->config` borrows outlives this connection (TLS-CONFIG-LIFETIME
        # -UAF fix) — the Arc refcount, not an unenforced ref-borrow, is what
        # keeps it alive.
        var rc = s2n_connection_set_config(inner._raw, config._raw_config_ptr())
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConnection.__init__: s2n_connection_set_config failed "
                "(rc=" + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )
        self._handle = OwnedPointer[_S2nConnectionHandle](inner^)
        self._fd = Int32(-1)
        # Co-own the config (share-ownership Arc clone) so `conn->config`
        # is provably valid for this connection's whole lifetime.
        self._config = config.copy()
        self._handshake_done = False

    # NOTE: client-mode construction lives in the
    # `__init__(out self, ref config: TlsConfig, _client_mode: Bool)`
    # overload BELOW. The public client-mode entry point is the
    # `new_client(ref config)` static factory immediately after that
    # overload. This pattern (additive `__init__` overload + static
    # factory) avoids modifying the existing default server-mode
    # `__init__` body and gives the public API a clean, readable name.

    def __init__(
        out self, ref config: TlsConfig, _client_mode: Bool
    ) raises:
        """Internal CLIENT-mode constructor (distinguished from the
        default server-mode `__init__` by the `_client_mode` flag arg).

        Same shape as the default server-mode `__init__` but allocates
        the s2n_connection_t with `S2N_CLIENT` instead of `S2N_SERVER`.
        ZERO modification of the default server-mode __init__ body.

        NOT a public API — callers use the `new_client(config)` static
        factory below for readability. The `_client_mode` arg is
        present only to disambiguate this overload from the
        server-mode `__init__(ref config: TlsConfig)`.
        """
        _ = _client_mode  # flag arg only used for overload selection
        var inner = _S2nConnectionHandle.create(S2N_CLIENT)
        # SAFETY: synchronous call; `config` borrow is alive throughout.
        # The config's raw pointer is threaded directly. LIFETIME: we clone
        # `config` into `self._config` below so the s2n_config_t that
        # `conn->config` borrows outlives this connection (TLS-CONFIG-LIFETIME
        # -UAF fix) — the Arc refcount keeps it alive, not the `ref` borrow.
        var rc = s2n_connection_set_config(
            inner._raw, config._raw_config_ptr()
        )
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConnection.new_client: s2n_connection_set_config "
                "failed (rc=" + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )
        self._handle = OwnedPointer[_S2nConnectionHandle](inner^)
        self._fd = Int32(-1)
        # Co-own the config (share-ownership Arc clone) so `conn->config`
        # is provably valid for this connection's whole lifetime.
        self._config = config.copy()
        self._handshake_done = False

    @staticmethod
    def new_client(ref config: TlsConfig) raises -> TlsConnection:
        """Construct a CLIENT-mode TLS connection bound to `config`.
        Mirror of the default server-mode `__init__`, but passes
        `S2N_CLIENT` to `s2n_connection_new` instead of `S2N_SERVER`.

        The fd is NOT bound yet — caller must `bind_fd(fd)` after.

        Server-mode `__init__` behavior is unchanged. The server-mode ctor remains
        the default (`TlsConnection(config)` constructs in server
        mode); client-mode is reached via this explicit static ctor.

        Lifetime contract is identical to the server-mode ctor: the
        TlsConfig MUST outlive the TlsConnection (s2n holds a
        non-owning ref via s2n_connection_set_config).

        Raises on s2n_connection_new OOM or s2n_connection_set_config
        failure.
        """
        return TlsConnection(config, True)

    def bind_fd(mut self, fd: Int32) raises:
        """Attach a connected socket fd to the connection. After this,
        s2n_negotiate / send / recv read/write via the fd directly
        (no callback indirection).

        The caller (HttpServer) owns the fd's lifetime. This call does
        NOT take ownership of the fd; the caller MUST keep the fd open
        until after `shutdown()` returns TLS_OUTCOME_DONE (or after
        the TlsConnection is dropped without a graceful shutdown).
        """
        # SAFETY: synchronous call. The fd is an integer (POD); s2n
        # stores it in its connection struct for subsequent
        # read/write syscalls.
        var rc = s2n_connection_set_fd(self._handle[]._raw, fd)
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConnection.bind_fd: s2n_connection_set_fd failed "
                "(rc=" + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )
        self._fd = fd

    def set_server_name(mut self, host: String) raises:
        """Set the SNI hostname the CLIENT will send to the server in
        its ClientHello. Counterpart to the server-side `sni_hostname()`
        which reads what the peer client sent.

        Per s2n.h:2121 (upstream symbol `s2n_set_server_name`): "Sets
        the server name for the connection. ... Provides the server
        name to the client for the SNI extension."

        Lifetime contract: s2n COPIES the NUL-terminated `host` bytes
        into its per-connection arena before returning (verified
        against upstream tls/s2n_connection.c::s2n_set_server_name).
        The `host` String can be released after this call.

        Should be called BEFORE `handshake()` — once the ClientHello
        has been flushed, the SNI value is fixed.

        Raises on s2n FFI failure (e.g. empty host, OOM in
        per-connection arena).
        """
        # SAFETY: synchronous FFI call. s2n copies the bytes synchronously;
        # the `host` String borrow is alive across the external_call via
        # the `host_local` rebind (as_c_string_slice is mutating; can't
        # be called on a function-arg rvalue).
        # `as_c_string_slice().unsafe_ptr()` returns Int8*; s2n's
        # `const char *server_name` matches that ABI. We bitcast to
        # UInt8 to satisfy our typed FFI binding's UInt8* signature
        # (same pattern as TlsConfig.add_trust_pem above).
        var host_local = host
        var host_ptr = host_local.as_c_string_slice().unsafe_ptr(
        ).bitcast[UInt8]().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_set_server_name(self._handle[]._raw, host_ptr)
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConnection.set_server_name: s2n_set_server_name "
                "failed (rc=" + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    def handshake(mut self) -> UInt8:
        """Drive one step of the TLS handshake. Returns:

          TLS_OUTCOME_DONE             — handshake complete; recv/send valid.
          TLS_OUTCOME_BLOCKED_ON_READ  — caller should arm INTEREST_READ.
          TLS_OUTCOME_BLOCKED_ON_WRITE — caller should arm INTEREST_WRITE.
          TLS_OUTCOME_ERROR            — caller should close the conn.

        Callers loop until DONE or ERROR, calling reactor.modify between
        BLOCKED returns to switch the registered interest set.
        """
        # SAFETY: stack-local out-parameter for blocked status. The
        # external_call writes to *blocked_local exactly once before
        # returning; we read it immediately. The OwnedPointer access
        # to the handle's raw field is safe — handle is alive.
        var blocked_local = Int32(0)
        var blocked_ptr = UnsafePointer(to=blocked_local).unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        var rc = s2n_negotiate(self._handle[]._raw, blocked_ptr)
        # ★ `_error_typed_outcome`, NOT `_blocked_status_to_outcome`.
        # `s2n_negotiate_impl` presets `*blocked` to the direction it is ABOUT
        # to attempt (s2n_handshake_io.c:1626/1658) and clears it only on a
        # COMPLETED handshake (line 1691), so a peer that RSTs or alerts
        # mid-handshake comes back as `(-1, BLOCKED_ON_*)`. Believed, that would make
        # `TlsConnector.connect`'s handshake loop park on a dead fd — which is
        # permanently ready in both directions — instead of failing in
        # microseconds with the s2n error.
        #
        # ⚠⚠ MEASURED: it does NOT "spin to its wall deadline". **THE
        # MISREPORT IS EXACTLY ONE CALL DEEP ON THIS PATH, and the cost of
        # believing it is ONE WASTED PARK, not a burnt wall budget.** Probes 2..N short-circuit on the
        # connection's now-closed io-status BEFORE the `*blocked` assignment,
        # so `*blocked` keeps the CALLER's initial value (`S2N_NOT_BLOCKED`)
        # and `_blocked_status_to_outcome` maps `(NOT_BLOCKED, rc<0)`
        # to `TLS_OUTCOME_ERROR` on trip 2. Measured 1/64 misreporting probes,
        # `S2N_ERR_T_CLOSED` on all 64:
        # `test_L1_tls_handshake_departed_peer_fails_fast`
        # (§0 pins the DEPTH so the stronger claim cannot be re-derived from
        # the source alone; §1 pins the ERROR to trip 1 — RED at trip 2
        # against `_blocked_status_to_outcome`).
        #
        # ⛔ DO NOT GENERALISE THAT DOWNWARD TO `send`. There the misreport IS
        # permanent — a failed `write(2)` never sets `conn->write_closed`, so
        # there is no closed-status short-circuit to reach — and it is measured
        # at 128/128 by
        # `test_L2_h2_over_tls_send_to_departed_peer_no_spin`.
        # The two arms of `_error_typed_outcome` fix faults of very different
        # severity; only one of them was a spin.
        #
        # Pure-Int8/Int32 marshaling out of FFI; no pointer escapes.
        var outcome = _error_typed_outcome(blocked_local, Int64(rc))
        if outcome == TLS_OUTCOME_DONE:
            self._handshake_done = True
        return outcome

    def send(mut self, data: Span[UInt8, _]) -> Tuple[UInt8, Int]:
        """Encrypt + send `data` via the bound fd. Returns a (outcome, n)
        tuple. The KEY CONTRACT — a latent partial-write correctness bug that
        bites on any send larger than one socket-buffer's worth (congested
        socket / >~8-64KB flush) — is how a POSITIVE-PARTIAL-that-BLOCKED is
        surfaced:

          outcome == TLS_OUTCOME_DONE             — n plaintext bytes were
                                                    ACCEPTED into the TLS
                                                    stream (n may be < len(data)
                                                    — a partial). The caller
                                                    MUST advance its buffer by
                                                    EXACTLY n and re-call with
                                                    `data[n:]`.
          outcome == TLS_OUTCOME_BLOCKED_ON_WRITE — n == 0; NOTHING was
                                                    accepted (socket buffer was
                                                    already full). Caller arms
                                                    INTEREST_WRITE and re-calls
                                                    with the SAME `data`.
          outcome == TLS_OUTCOME_BLOCKED_ON_READ  — n == 0; only on TLS rekey.
          outcome == TLS_OUTCOME_ERROR            — n == -1; close the conn.

        WHY THE (rc>0, blocked=WRITE) HANDLING IS LOAD-BEARING (the bug).
        `s2n_send` returns `user_data_sent` = the bytes it CONSUMED-AND-
        COMMITTED this call, and sets `*blocked = S2N_BLOCKED_ON_WRITE` when
        it ALSO ran out of socket-buffer room. s2n has internally advanced
        `current_user_data_consumed` by that same `user_data_sent`, so on the
        NEXT call the caller MUST advance its buffer by `user_data_sent` too —
        the s2n usage-guide contract: "repeated calls should update the inputs
        per the indication of size written." s2n sanity-checks the update with
        `POSIX_ENSURE(current_user_data_consumed <= total_size, S2N_ERR_SEND_SIZE)`
        (tls/s2n_send.c) — err_type 7 (S2N_ERR_T_USAGE), errno 0x1c00003a =
        469762106.

        The PRE-FIX bug was in `_map_tls_outcome_to_stream_io`: it mapped a
        (rc>0, blocked=WRITE) result to `StreamIo.pending(...)` — a PENDING
        that DISCARDED the positive `rc`. The h2 drive then never advanced its
        `pending_out` buffer (PENDING skips `consume_out_bytes_prefix`), parked,
        and re-called `s2n_send` with the FULL unshrunk buffer while s2n's
        `consumed` had already been decremented — so s2n re-sent from the
        start (re-transmit / mis-framed record) or, once the buffer state
        diverged, tripped S2N_ERR_SEND_SIZE. Verified end-to-end over a
        congested loopback socket in test_L1_tls_partial_send_resumption
        (256KB payload re-transmitted to 16GB pre-fix; byte-intact post-fix).
        The FIX: surface a positive `rc` as DONE-with-n (a genuine partial the
        caller advances by), and reserve BLOCKED-with-0 for the case where s2n
        accepted NOTHING. The caller (both h2 drives and any TLS send loop)
        then advances by exactly the bytes s2n consumed — matching s2n's own
        `consumed` advance — so the sanity check never trips and no bytes are
        re-sent.

        NOTE — this is NOT the fix for the live Firestore `Listen`
        bytes_seen=0 / S2N_ERR_UNSUPPORTED_WITH_QUIC failure. That is a
        SEPARATE memory-corruption of the s2n connection struct during the
        TlsClientStream move out of TlsConnector.connect (a stray write flips
        conn->quic_enabled ~50% of launches); see the in the
        fix-commit message. This partial-write fix is necessary and correct on
        its own (the ListenRequest first flush is only ~687 bytes, so this
        path is not what fails there — but any larger TLS write would).
        """
        # SAFETY: synchronous call; `data` held in scope via the Span local
        # across the s2n_send call. `blocked_local` is a stack out-parameter.
        var total = Int64(len(data))
        if total == Int64(0):
            # No s2n call: s2n accepts a zero-length send, but flushes any
            # pending record first and can block doing so, which would turn
            # "nothing to send" into a BLOCKED_ON_WRITE.
            return (TLS_OUTCOME_DONE, 0)
        var blocked_local = Int32(0)
        var blocked_ptr = UnsafePointer(to=blocked_local).unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        # Order matters: unsafe_mut_cast[True]() BEFORE unsafe_origin_cast
        # (matches _span_ptr in compression_codecs.mojo:205-209).
        var buf_ptr = data.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_send(self._handle[]._raw, buf_ptr, total, blocked_ptr)
        if rc > Int64(0):
            # POSITIVE return — s2n CONSUMED `rc` bytes (and advanced its
            # internal `current_user_data_consumed` by rc). Surface as
            # DONE-with-n REGARDLESS of `*blocked`: a (rc>0, blocked=WRITE)
            # result means "I took rc bytes AND the socket is now full" — the
            # caller MUST advance by rc (not treat it as a bare block that
            # re-sends the whole buffer). This is THE fix.
            return (TLS_OUTCOME_DONE, Int(rc))
        # rc <= 0: either a hard error or a pure block (nothing consumed).
        #
        # ★ `_error_typed_outcome`, NOT `_blocked_status_to_outcome`.
        # `s2n_flush` presets `*blocked = S2N_BLOCKED_ON_WRITE` at entry
        # (tls/s2n_send.c:85) and resets it only after the write loop, so a
        # `write(2)` that fails EPIPE/ECONNRESET on a reaped pooled connection
        # returns `(-1, BLOCKED_ON_WRITE)` — indistinguishable from a full
        # socket buffer unless you read `s2n_error_get_type`. Believing
        # `*blocked` here is the SEND-side half of the closed-peer spin
        # (`HttpError[LIVELOCK]` on pooled connections). See
        # `_error_typed_outcome`.
        var outcome = _error_typed_outcome(blocked_local, rc)
        if outcome == TLS_OUTCOME_ERROR:
            return (TLS_OUTCOME_ERROR, -1)
        if rc == Int64(0):
            # rc == 0 with a block status is degenerate (s2n normally returns
            # -1 on a pure block); treat as "nothing accepted", caller retries
            # the same buffer.
            return (outcome, 0)
        # rc < 0 with BLOCKED_ON_WRITE / BLOCKED_ON_READ — nothing consumed;
        # caller parks + re-calls with the SAME unshrunk buffer.
        return (outcome, 0)

    def recv_into_span[o: Origin[mut=True]](
        mut self, dst: Span[UInt8, o],
    ) -> Tuple[UInt8, Int]:
        """Receive + decrypt plaintext into `dst`. Symmetric with `send`'s
        Span-based shape — INCLUDING the positive-partial rule. Returns
        (outcome, n):

          outcome == TLS_OUTCOME_DONE             — n bytes decrypted into
                                                    dst[0:n]. n MAY be a
                                                    partial (< len(dst)) and
                                                    s2n MAY still hold more
                                                    plaintext — re-call to get
                                                    it (`bytes_buffered()`
                                                    says whether it will come
                                                    without touching the fd).
                                                    Special: n == 0 means peer
                                                    sent close_notify
                                                    (graceful EOF).
          outcome == TLS_OUTCOME_BLOCKED_ON_READ  — n == -1; NOTHING was
                                                    decrypted. Retry on
                                                    INTEREST_READ.
          outcome == TLS_OUTCOME_BLOCKED_ON_WRITE — n == -1. Not reachable
                                                    through a rekey on
                                                    s2n-tls 1.5.6 (measured;
                                                    see
                                                    test_L2_h2_over_tls_real_rekey).
          outcome == TLS_OUTCOME_ERROR            — n == -1.

        An EMPTY `dst` makes s2n return 0 without reading: the result is
        (BLOCKED_ON_READ, 0) while s2n holds buffered plaintext, and
        (DONE, 0), the same shape as EOF, when it holds none. A caller must
        not pass an empty `dst`.

        WHY THE (rc>0, blocked=READ) HANDLING IS LOAD-BEARING (the bug this
        mirrors from `send`). `*blocked` on the recv side does NOT mean "the
        socket would block". `s2n_recv_impl` (tls/s2n_recv.c) sets

            *blocked = S2N_BLOCKED_ON_READ;      /* unconditional, on entry */

        and resets it EXACTLY ONCE, at the very end, gated on s2n's own
        userspace buffer being drained:

            if (s2n_stuffer_data_available(&conn->in) == 0) {
                *blocked = S2N_NOT_BLOCKED;
            }
            return bytes_read;

        So EVERY read whose destination is smaller than the record it lands on
        comes back `rc > 0` WITH `*blocked = S2N_BLOCKED_ON_READ`. Those bytes
        are ALREADY GONE from `conn->in` — `s2n_stuffer_erase_and_read` copied
        them into `dst` and erased them — and there is no way to ask for them
        again.

        Returning that pair as a BLOCKED outcome makes every caller drop the
        count: `_map_tls_outcome_to_stream_io`
        maps a non-DONE outcome to `StreamIo.pending(token)`, a variant with no
        byte-count field at all, so the h1/h2 client would silently lose the
        bytes. 4096 is the h1 read
        scratch (`client.mojo`, `state_machine.mojo`) and s2n's default
        outgoing fragment is 8087 plaintext bytes, so this is the ORDINARY
        read: exactly 32768 of 65536 bytes discarded through the
        production `TlsClientStream.try_read` seam
        (`test_L1_tls_recv_partial_plaintext_lost`).

        The FIX, identical in shape to `send`'s: surface a positive `rc` as
        DONE-with-n REGARDLESS of `*blocked`, and reserve BLOCKED-with-0 for
        the case where s2n produced NOTHING. Callers advance by exactly n and
        re-call; the next call reports the block.

        NOTE this does NOT make `bytes_buffered()` / `has_buffered_readable()`
        redundant — they answer "will the next read produce bytes without
        touching the fd", which is still the question a driver must ask before
        parking. It does mean a BLOCKED return now implies `conn->in` is empty,
        so the guard has nothing left to catch on this path.

        Origin contract: `dst`'s Origin parameter propagates the caller's
        frame; the borrow checker enforces dst-validity across the FFI
        call. s2n_recv is synchronous; the Span's storage MUST be alive
        across the call (typically a stack/struct buffer in the caller).

        Capacity = `len(dst)`. The method does NOT allocate; it writes
        directly into the caller-provided buffer.
        """
        # SAFETY: synchronous FFI. The Span's underlying storage is alive
        # via the caller's frame (origin parameter propagates the
        # lifetime). `blocked_local` is a stack out-parameter.
        var blocked_local = Int32(0)
        var blocked_ptr = UnsafePointer(to=blocked_local).unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        var capacity = len(dst)
        # Order matters: unsafe_mut_cast[True]() BEFORE unsafe_origin_cast
        # (matches existing _span_ptr / load_cert pattern).
        var buf_ptr = dst.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_recv(
            self._handle[]._raw, buf_ptr, Int64(capacity), blocked_ptr,
        )
        # ★ `_recv_outcome_and_n`, NOT `_blocked_status_to_outcome`. `*blocked`
        # lies in BOTH directions on the recv path — it claims BLOCKED_ON_READ
        # on every FAILURE AND on every POSITIVE
        # PARTIAL (silent plaintext loss). See that helper for both mechanisms.
        return _recv_outcome_and_n(blocked_local, rc)

    def bytes_buffered(self) -> Int:
        """Number of decrypted plaintext bytes s2n has already pulled off
        the socket and buffered in its userspace receive buffer but not yet
        handed back via recv/recv_into_span. A non-zero return means the
        NEXT recv WILL produce bytes without touching the socket fd.

        This is the buffered-plaintext lost-wakeup guard: s2n decrypts in
        TLS-RECORD units (~16KB plaintext) while the h2/h1 drivers read in
        4096-byte chunks, so one recv can drain a whole record off the
        socket and leave the remainder buffered HERE — invisible to a park
        on socket fd-readiness (the kernel socket has no more bytes). A
        driver checks `bytes_buffered() > 0` BEFORE parking on a read
        Pending and re-reads instead of parking on a fd that will never
        wake.

        POD return — a typed Int. No pointer crosses the module boundary;
        the s2n_peek FFI is confined to s2n_shim (FFI carve-out). Pure
        getter: no side effect on the connection, never touches the fd.
        """
        # SAFETY: synchronous read-only FFI. `_handle[]._raw` is the live
        # s2n connection handle (OwnedPointer-backed; alive for this call).
        return Int(s2n_peek(self._handle[]._raw))

    def has_buffered_readable(self) -> Bool:
        """True iff s2n holds decrypted plaintext that a subsequent recv
        would return without touching the socket fd (i.e.
        `bytes_buffered() > 0`). Convenience predicate over
        `bytes_buffered()`; see that method for the lost-wakeup rationale.
        """
        return self.bytes_buffered() > 0

    def wire_bytes_moved(self) -> Int:
        """Total bytes this connection has moved ACROSS THE SOCKET in either
        direction since it was created — s2n's own `wire_bytes_in +
        wire_bytes_out`. Monotone non-decreasing; a driver compares two
        samples and only ever asks whether they DIFFER.

        ★★ THE QUESTION THIS ANSWERS, WHICH `try_read` / `try_write` CANNOT.
        Those report APPLICATION bytes, and a TLS transport routinely moves
        real bytes on the wire while accepting or producing zero application
        bytes:

          * **write.** `s2n_sendv_with_offset_impl` opens with
            `POSIX_GUARD(s2n_flush(conn, blocked))` — an EARLY RETURN that
            bypasses the `user_data_sent > 0` partial-acknowledge arm. So once
            `conn->out` holds an undrained record, every `s2n_send` answers
            `(-1, BLOCKED_ON_WRITE)` with ZERO accepted, no matter how much
            that leading flush just wrote. A peer that drains slowly holds a
            connection in that state for as long as the congestion lasts.
          * **read.** `s2n_recv` returns `-1 / BLOCKED_ON_READ` whenever it
            cannot complete a whole record, and a 16 KiB record arriving across
            many TCP segments produces one such call per segment.

        In BOTH shapes the connection is healthy and transferring, and in both
        the h2 driver's `ready_no_progress` counter — which sees only
        application bytes — climbs toward `_H2_READY_NO_PROGRESS_CAP` and
        raises `HttpError[LIVELOCK]` on a connection that never spun.

        ⇒ **A DRIVER MUST NOT CALL A TRIP "NO PROGRESS" UNLESS THIS VALUE ALSO
        FAILED TO MOVE.** It is exact rather than heuristic: no threshold, no
        timing, no budget. The two spins that ARE real freeze it by
        construction — a departed peer's `write(2)` fails before
        `conn->wire_bytes_out += w` (tls/s2n_send.c:88-91) and a closed peer's
        `read(2)` fails before `conn->wire_bytes_in += r`
        (tls/s2n_recv.c:67-71) — so both existing falsifiers
        (`test_L2_h2_over_tls_send_to_departed_peer_no_spin`,
        `test_L2_h2_over_tls_abrupt_close_no_spin`) keep tripping the detector
        exactly as before.

        POD return — a typed Int. The two s2n_connection_get_wire_bytes_* FFIs
        are confined to this module (the FFI carve-out); no pointer crosses.
        Pure getter: reads two `uint64_t` fields, never touches the fd.

        ⚠ Returns `Int`, not `UInt64`: the caller's only use is inequality
        between two samples taken microseconds apart, and a 64-bit signed count
        of socket bytes cannot wrap in any process lifetime.
        """
        # SAFETY: two synchronous read-only FFI calls. `_handle[]._raw` is the
        # live s2n connection handle (OwnedPointer-backed; alive for this
        # call). Neither callee retains the pointer, allocates, or mutates.
        var wb_in = s2n_connection_get_wire_bytes_in(self._handle[]._raw)
        var wb_out = s2n_connection_get_wire_bytes_out(self._handle[]._raw)
        return Int(wb_in) + Int(wb_out)

    def recv(mut self, mut buf: List[UInt8], capacity: Int) -> Tuple[UInt8, Int]:
        """Receive + decrypt plaintext from the bound fd into `buf` (up
        to `capacity` bytes). Returns (outcome, n):

          outcome == TLS_OUTCOME_DONE             — n bytes received (MAY be
                                                    a partial, and s2n may
                                                    still hold more);
                                                    buf.len() now n. Special:
                                                    n == 0 means peer sent
                                                    close_notify (graceful
                                                    EOF).
          outcome == TLS_OUTCOME_BLOCKED_ON_READ  — n == -1; NOTHING
                                                    decrypted, `buf` left
                                                    alone. Retry on
                                                    INTEREST_READ.
          outcome == TLS_OUTCOME_BLOCKED_ON_WRITE — n == -1.
          outcome == TLS_OUTCOME_ERROR            — n == -1.

        A `capacity` of 0 gives the same two results as an empty `dst` to
        `recv_into_span`: (BLOCKED_ON_READ, 0) or the EOF-shaped (DONE, 0).

        Carries the SAME positive-partial rule as `recv_into_span` — see that
        method for the s2n_recv.c mechanism and the measured data loss. A
        positive `rc` is DONE-with-n regardless of `*blocked`, because those
        bytes are already erased out of s2n's `conn->in`. This variant feeds
        callers that read a TLS connection into their own receive buffer, which
        must not discard them.

        Caller MUST pre-`reserve` `buf` to >= `capacity` bytes (this
        method does not allocate; List is non-growable across the FFI
        call to avoid invalidating the buffer pointer).
        """
        # SAFETY: synchronous call. The List's backing storage must
        # have capacity >= `capacity` bytes (caller's contract). We
        # write directly into the List's buffer via unsafe_ptr() and
        # then resize the List to the byte count s2n produced.
        var blocked_local = Int32(0)
        var blocked_ptr = UnsafePointer(to=blocked_local).unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        var buf_ptr = buf.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        var rc = s2n_recv(
            self._handle[]._raw,
            buf_ptr,
            Int64(capacity),
            blocked_ptr,
        )
        # ★ See `recv_into_span` — `*blocked` lies on every s2n_recv FAILURE
        # AND on every positive partial.
        var mapped = _recv_outcome_and_n(blocked_local, rc)
        var n_out = mapped[1]
        # n_out is -1 for BLOCKED / ERROR and >= 0 otherwise; the >= 0 arm is
        # exactly the old `rc >= 0` arm, plus the new CLOSED-as-EOF case which
        # correctly reports zero live bytes.
        if n_out >= 0:
            # SAFETY: List's backing buffer was pre-`reserve`d by the
            # caller; we tell the List how many bytes are now live.
            buf.resize(unsafe_uninit_length=n_out)
        return (mapped[0], n_out)

    def shutdown(mut self) -> UInt8:
        """Send a TLS close_notify alert + drain peer's close_notify.
        Same outcome semantics as handshake / send / recv.

        Per s2n.h:2318-2323: graceful shutdown by default; both peers
        must exchange close_notify before this returns DONE. May block.
        """
        # SAFETY: synchronous call; stack out-parameter for blocked.
        var blocked_local = Int32(0)
        var blocked_ptr = UnsafePointer(to=blocked_local).unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        var rc = s2n_shutdown(self._handle[]._raw, blocked_ptr)
        # ★ `_error_typed_outcome`. `s2n_shutdown` flushes, so it
        # inherits `s2n_flush`'s entry-time `*blocked = S2N_BLOCKED_ON_WRITE`.
        # The close path is where the peer is MOST likely already gone, and a
        # caller that loops until DONE would otherwise loop
        # on a would-block that can never clear. Callers that ignore the
        # outcome entirely (`TlsClientStream.close`) are unaffected.
        return _error_typed_outcome(blocked_local, Int64(rc))

    def sni_hostname(self) -> Optional[String]:
        """Get the SNI hostname the client requested (server-side only).
        Returns None if no SNI was sent.

        Phase 1: returns a copy of the s2n-owned C string. Phase 2+ may
        switch to a zero-copy slice with connection-scoped origin.
        """
        # SAFETY: s2n_get_server_name returns a pointer to s2n-owned
        # memory (NUL-terminated UTF-8) or NULL. We copy the bytes into
        # a Mojo String immediately so the unsafe pointer never escapes
        # this method.
        var p = s2n_get_server_name(self._handle[]._raw)
        if Int(p) == 0:
            return Optional[String]()
        # Compute the C-string length. SAFETY: we trust s2n's NUL
        # terminator; the loop bounds are unbounded but real s2n SNI
        # hostnames are <= 255 bytes per RFC 6066. Cap at 256 as a
        # safety margin.
        var max_len = 256
        var n = 0
        while n < max_len:
            if p[n] == UInt8(0):
                break
            n = n + 1
        # Build a Mojo String by copying the n bytes.
        var bytes = List[UInt8](capacity=n + 1)
        var i = 0
        while i < n:
            bytes.append(p[i])
            i = i + 1
        bytes.append(UInt8(0))  # NUL terminator
        # Use the FFI-friendly String constructor from a NUL-terminated
        # byte list. Bytes are guaranteed UTF-8 because s2n validates
        # SNI hostnames at parse time per RFC 6066.
        var s = String()
        var j = 0
        while j < n:
            s += chr(Int(bytes[j]))
            j = j + 1
        return Optional[String](s^)

    def fd(self) -> Int32:
        """Return the bound fd, or -1 if `bind_fd` has not been called."""
        return self._fd

    def _raw_conn_ptr_for_test(self) -> S2nOpaquePtr:
        """TEST-ONLY: return the raw opaque s2n_connection_t pointer so the
        stale-pointer regression falsifier
        (`tests/test_L1_tls_connector_move_no_stray_write.mojo`)
        can probe the s2n connection's `quic_enabled` bit directly across the
        `TlsClientStream` move-out. NOT part of the public safe surface and NOT
        called by any production path.

        Returns the CONCRETE `S2nOpaquePtr` (`_S2N_FFI_ORIGIN` = StaticConstant
        origin), NOT a wildcard — the same non-wildcard opaque-handle carrier
        the field itself uses. The pointer is opaque; the test only hands it
        back to a read-only s2n unstable-API accessor and never dereferences
        it Mojo-side.
        """
        # SAFETY: read-only accessor over the live handle (alive for the call
        # via OwnedPointer). The returned opaque pointer carries the concrete
        # FFI origin and never escapes into a non-FFI module (only the sibling
        # test's unstable-API probe consumes it).
        return self._handle[]._raw

    def _config_raw_ptr_for_test(self) -> S2nOpaquePtr:
        """TEST-ONLY: return the raw opaque s2n_config_t pointer this
        connection's `conn->config` borrow points at (via the co-owned
        `self._config` clone), so the regression
        falsifier (`tests/test_L1_tls_config_lifetime_uaf.mojo`)
        can confirm the config is STILL ALLOCATED after the connector that
        originally owned it has been dropped. NOT part of the public safe
        surface and NOT called by any production path.

        Returns the CONCRETE `S2nOpaquePtr` (`_S2N_FFI_ORIGIN`), same
        non-wildcard opaque-handle carrier the field uses; the pointer is
        opaque and the test only reads its value / hands it to a read-only
        s2n unstable-API accessor.
        """
        # SAFETY: read-only accessor over the co-owned config clone (alive
        # for the call via the Arc). The returned opaque pointer carries the
        # concrete FFI origin and never escapes into a non-FFI module.
        return self._config._raw_config_ptr()

    # -------------------------------------------------------------------------
    # Session resumption
    # -------------------------------------------------------------------------
    #
    # Client-side session-resumption-via-tickets API. The connection-level
    # set/get_session pair is the canonical client-side resumption path
    # (the server-side s2n_session_ticket_cb pathway is OUT OF SCOPE — we
    # never bind callbacks: no trampolines).
    #
    # Wire shape:
    #   * PRE-handshake (after bind_fd + set_server_name): cache lookup;
    #     on hit, call `set_session(blob)`. If set_session raises, swallow
    #     + fall through to a full handshake — resumption is best-effort.
    #   * POST-handshake DONE: call `get_session()`. On Some(blob), pass
    #     to `SessionCache.store(key, blob)`. On None, do nothing
    #     (server did not issue a ticket).
    #   * Test assertion: `is_session_resumed()` returns True after a
    #     successful abbreviated handshake (TLS 1.2 ticket resumption
    #     OR TLS 1.3 PSK).

    def set_session(mut self, session: Span[UInt8, _]) raises:
        """De-serialize a session-state blob into the connection. Must
        be called BEFORE `handshake()` — the resumption attempt is fixed
        once the ClientHello goes out.

        On success, the next handshake attempts an abbreviated path
        (TLS 1.2 session-ticket resumption or TLS 1.3 PSK). On s2n-level
        failure (malformed blob, expired ticket, server rejection), the
        handshake falls back to a full negotiation — the caller can
        treat the raise as best-effort and proceed with handshake().

        Lifetime contract: s2n consumes the bytes synchronously into its
        per-connection state; the `session` Span only needs to be alive
        across this call.

        Raises on s2n FFI failure (rc < 0).
        """
        var n = len(session)
        if n == 0:
            raise Error(
                "TlsConnection.set_session: empty session blob"
            )
        # SAFETY: synchronous call. The Span's underlying storage is
        # alive across the external_call (origin parameter propagates
        # the caller's borrow). Order: unsafe_mut_cast[True]() BEFORE
        # unsafe_origin_cast (matches the load_cert / set_server_name
        # / send pattern).
        var buf_ptr = session.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_connection_set_session(
            self._handle[]._raw, buf_ptr, Int64(n),
        )
        if rc < Int32(0):
            raise Error(
                "TlsConnection.set_session: "
                "s2n_connection_set_session failed (rc="
                + String(Int(rc)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )

    def get_session(self) raises -> Optional[List[UInt8]]:
        """Serialize the connection's current session state into a fresh
        List[UInt8]. Returns None if no session is available (handshake
        not yet DONE, or server did not issue a ticket).

        Per s2n.h:2606-2608 the returned blob is the MOST RECENT ticket
        in TLS 1.3 (servers may issue multiple); this matches our LRU
        "newest wins" cache semantics.

        Raises on s2n FFI failure during the get_session call. Returns
        None on the legitimate "no session" path (length == 0).
        """
        # SAFETY: synchronous accessor call; no pointer escapes.
        var length = s2n_connection_get_session_length(self._handle[]._raw)
        if length <= Int32(0):
            # No session state available (handshake not done, or no
            # ticket issued).
            return Optional[List[UInt8]]()
        # Allocate a buffer sized to the reported length.
        var capacity = Int(length)
        var buf = List[UInt8](capacity=capacity)
        # Reserve + reset length to capacity so unsafe_ptr() points at
        # `capacity` writable bytes. The s2n call fills the buffer
        # synchronously.
        buf.resize(unsafe_uninit_length=capacity)
        # SAFETY: synchronous call; `buf` is alive across the
        # external_call. We pre-reserved `capacity` bytes; s2n writes
        # the actual byte count.
        var buf_ptr = buf.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[
            _S2N_FFI_ORIGIN
        ]()
        var written = s2n_connection_get_session(
            self._handle[]._raw, buf_ptr, Int64(capacity),
        )
        if written < Int32(0):
            raise Error(
                "TlsConnection.get_session: "
                "s2n_connection_get_session failed (rc="
                + String(Int(written)) + ", errno="
                + String(Int(last_s2n_errno())) + ")"
            )
        if written == Int32(0):
            # Defensive: should not happen if length > 0, but handle.
            return Optional[List[UInt8]]()
        # SAFETY: resize the buf to the actual byte count s2n produced.
        buf.resize(unsafe_uninit_length=Int(written))
        return Optional[List[UInt8]](buf^)

    def is_session_resumed(self) -> Bool:
        """Check if the most recent handshake completed via session
        resumption (TLS 1.2 ticket OR TLS 1.3 PSK abbreviated path).

        Returns True if the handshake was abbreviated, False otherwise
        (full handshake, or handshake not yet DONE).

        Used by the session-resumption test to empirically assert that
        a second handshake on a reconnected PoolKey was resumption.
        """
        # SAFETY: synchronous accessor; no pointer escapes. s2n returns
        # 1 on resumption-abbreviated, 0 on full / not-yet-DONE.
        var rc = s2n_connection_is_session_resumed(self._handle[]._raw)
        return rc == Int32(1)

    def negotiated_tls_version(self) -> Int:
        """The TLS version the handshake negotiated: `TLS_VERSION_TLS13`,
        `TLS_VERSION_TLS12`, or another s2n protocol-version number for an
        older version.

        -1 until `handshake()` on THIS connection has returned
        TLS_OUTCOME_DONE (and -1 if s2n reports a failure). The guard is not
        cosmetic: before the handshake s2n's `actual_protocol_version` holds
        a placeholder, the highest version it supports (TLS 1.3) on a client
        and 0 on a server, so the raw value would claim TLS 1.3 on a client
        that never negotiated anything."""
        if not self._handshake_done:
            return -1
        # SAFETY: synchronous accessor; no pointer escapes.
        return Int(s2n_connection_get_actual_protocol_version(self._handle[]._raw))

    def negotiated_cipher(self) -> String:
        """The cipher suite the handshake negotiated, in s2n's OpenSSL-style
        spelling: "TLS_AES_128_GCM_SHA256" for a TLS 1.3 suite,
        "ECDHE-RSA-AES128-GCM-SHA256" for a TLS 1.2 one. The empty string
        until `handshake()` on THIS connection has returned TLS_OUTCOME_DONE
        (the guard of `negotiated_tls_version`), or when s2n reports none."""
        if not self._handshake_done:
            return String()
        # SAFETY: s2n_connection_get_cipher returns a pointer into s2n's
        # static cipher-suite table or NULL; it is copied here and does not
        # escape this method.
        var p = s2n_connection_get_cipher(self._handle[]._raw)
        if Int(p) == 0:
            return String()
        return _ptr_to_string(p)

    def last_handshake_message_name(self) -> String:
        """Get the name of the last handshake message the connection was
        processing at the time of a failure.

        use this at the error site
        to determine which TLS handshake step was in progress when the peer
        closed the connection (e.g. "CLIENT_HELLO" = server rejected our hello,
        "SERVER_HELLO" = server closed after responding, etc.).

        Returns a String copy (e.g. "CLIENT_HELLO", "SERVER_HELLO", ...).
        """
        # SAFETY: s2n_connection_get_last_message_name returns a pointer into
        # s2n's static message-name table. We copy the bytes immediately.
        return s2n_last_message_name(self._handle[]._raw)

    def negotiated_protocol(self) -> Optional[String]:
        """Read back the ALPN-negotiated protocol.

        Returns the protocol identifier ALPN negotiated at handshake
        (e.g. "h2", "http/1.1"), or None if no ALPN extension was
        used / no protocol was negotiated.

        Per s2n.h:2156 + RFC 7301: this MAY return NULL even on a
        successful handshake (when ALPN was not requested or no
        overlap with the peer's preferences). Callers treat the
        None branch as "fall back to HTTP/1.1".

        Phase 2 returns a copy of the s2n-owned C string. Safe to
        call any time post-handshake; before handshake completes,
        s2n returns NULL (which surfaces as None).
        """
        # SAFETY: s2n_get_application_protocol returns a pointer to
        # s2n-owned memory (NUL-terminated UTF-8) or NULL. We copy the
        # bytes into a Mojo String immediately so the unsafe pointer
        # never escapes this method. Mirrors the sni_hostname pattern
        # at s2n_shim.mojo:985 exactly.
        var p = s2n_get_application_protocol(self._handle[]._raw)
        if Int(p) == 0:
            return Optional[String]()
        # Compute the C-string length. SAFETY: trust s2n's NUL
        # terminator; cap at 256 as a safety margin (ALPN protocol
        # identifiers are short — "h2", "http/1.1", "h3" etc.; RFC 7301
        # imposes no explicit length cap but real protocols are ~8 chars).
        var max_len = 256
        var n = 0
        while n < max_len:
            if p[n] == UInt8(0):
                break
            n = n + 1
        # Build a Mojo String by copying the n bytes (matches sni_hostname).
        var s = String()
        var j = 0
        while j < n:
            s += chr(Int(p[j]))
            j = j + 1
        return Optional[String](s^)

    def request_key_update(mut self, peer: PeerKeyUpdate) raises:
        """Mark a TLS 1.3 key update pending: the next `send` emits a
        KeyUpdate and switches this side's sending key (key_update.mojo).

        Raises, leaving the connection untouched, before the handshake is
        complete or on a version below TLS 1.3: s2n would accept the request
        there and either send it at the end of the handshake or never (TLS
        1.2 has no key update; s2n drops it silently). Raises with s2n's
        message when s2n refuses `peer` (1.5.6 refuses `REQUESTED`).
        """
        # SAFETY: every call below is synchronous on the live handle this
        # connection owns; no pointer escapes.
        var raw = self._handle[]._raw
        if s2n_last_message_name(raw) != "APPLICATION_DATA":
            raise Error("TlsConnection.request_key_update: handshake not complete")
        var version = s2n_connection_get_actual_protocol_version(raw)
        if version < S2N_TLS13:
            raise Error(
                "TlsConnection.request_key_update: key update needs TLS 1.3"
                " (negotiated protocol version " + String(Int(version)) + ")"
            )
        if s2n_connection_request_key_update(raw, peer.raw()) != S2N_SUCCESS:
            raise Error(
                "TlsConnection.request_key_update: "
                + s2n_strerror_message(last_s2n_errno())
            )

    def key_update_counts(self) raises -> KeyUpdateCounts:
        """How many times this side's sending and receiving keys were
        updated (0 and 0 on a fresh connection; s2n saturates at 255)."""
        var sent = UInt8(0)
        var received = UInt8(0)
        # SAFETY: both out-pointers address the two stack bytes above, alive
        # across the synchronous call; s2n writes one uint8_t through each.
        var sent_ptr = UnsafePointer(to=sent).unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var received_ptr = UnsafePointer(to=received).unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
        var rc = s2n_connection_get_key_update_counts(
            self._handle[]._raw, sent_ptr, received_ptr
        )
        if rc != S2N_SUCCESS:
            raise Error(
                "TlsConnection.key_update_counts: "
                + s2n_strerror_message(last_s2n_errno())
            )
        return KeyUpdateCounts(sent=Int(sent), received=Int(received))


# =============================================================================
# Helpers — errno + strerror
# =============================================================================


def last_s2n_errno() -> Int32:
    """Read the thread-local s2n_errno set by the most recent S2N_FAILURE.
    Useful for formatting Mojo Error messages with the specific s2n cause.
    """
    # SAFETY: returns a pointer to s2n's TLS-thread-local errno slot;
    # we dereference once + copy the Int32 out. The pointer is not
    # retained.
    var p = s2n_errno_location()
    if Int(p) == 0:
        return Int32(-1)
    return p[]


def s2n_strerror_message(errno: Int32) -> String:
    """Get a human-readable error message for a s2n errno value.
    Returns a copy of the s2n-internal static error string.
    """
    # SAFETY: pass NULL for `lang` (English is the only supported
    # language in s2n). The returned pointer is into s2n's static
    # error string table — copy the bytes into a Mojo String here.
    var null_lang = _null_ptr[UInt8, _S2N_FFI_ORIGIN]()
    var p = s2n_strerror(errno, null_lang)
    if Int(p) == 0:
        return String("(unknown errno)")
    var max_len = 1024
    var n = 0
    while n < max_len:
        if p[n] == UInt8(0):
            break
        n = n + 1
    var s = String()
    var i = 0
    while i < n:
        s += chr(Int(p[i]))
        i = i + 1
    return s^


@always_inline
def _ptr_to_string(p: S2nBytePtr, max_len: Int = 256) -> String:
    """Copy a NUL-terminated C string from a static pointer into a Mojo String.
    Returns "(null)" if the pointer is NULL. Copies at most max_len bytes."""
    if Int(p) == 0:
        return String("(null)")
    var n = 0
    while n < max_len:
        if p[n] == UInt8(0):
            break
        n = n + 1
    var s = String()
    var i = 0
    while i < n:
        s += chr(Int(p[i]))
        i = i + 1
    return s^


def s2n_strerror_debug_message(errno: Int32) -> String:
    """Get s2n internal debug info (source file + line) for an errno value.
    Returns a copy of the s2n-internal static debug string.

    use alongside s2n_strerror_message
    to pinpoint the s2n source location that raised the error.
    """
    var null_lang = _null_ptr[UInt8, _S2N_FFI_ORIGIN]()
    var p = s2n_strerror_debug(errno, null_lang)
    return _ptr_to_string(p, 512)


def s2n_last_message_name(
    conn: S2nOpaquePtr,
) -> String:
    """Get the name of the last handshake message the connection was
    processing. Returns a copy of the s2n-internal static name string.

    call this at the handshake
    error site to know which step (CLIENT_HELLO, SERVER_HELLO, etc.)
    the peer closed the connection at.
    """
    var p = s2n_connection_get_last_message_name(conn)
    return _ptr_to_string(p, 64)
