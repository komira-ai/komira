# =============================================================================
# src/komira_http_core/tls/ffi.mojo — s2n-tls FFI declarations
# =============================================================================
#
# This module declares the s2n-tls C symbols this package binds. Each
# function is a thin `external_call[<symbol>, <ret>](<args>)` wrapper that
# names the symbol explicitly + types the args + return for the Mojo type
# checker. Bodies do NOTHING other than the external_call.
#
# The symbol resolution path: the binary is statically linked against
# s2n-tls (which in turn brings in aws-lc's libcrypto).
#
# ENCAPSULATION DISCIPLINE:
# This module IS the FFI boundary. UnsafePointer types in signatures here
# are PERMITTED because:
#   - This module is inside `src/komira_http_core/tls/`, the canonical FFI
#     carve-out for TLS.
#   - Every `external_call` site carries a `# SAFETY:` comment.
#   - The opaque-handle wrappers in `s2n_shim.mojo`
#     are the public-facing surface that callers reach for; they hide
#     these declarations behind safe APIs (TlsConfig, TlsConnection).
#
# This module MUST NOT be imported by anything other than `s2n_shim.mojo`
# (and the package `__init__.mojo` if it re-exports the safe surface).
#
# C symbol surface:
#   - s2n_init / s2n_cleanup
#   - s2n_config_new / s2n_config_free
#   - s2n_config_add_cert_chain_and_key_to_store
#   - s2n_cert_chain_and_key_new / s2n_cert_chain_and_key_free
#   - s2n_cert_chain_and_key_load_pem_bytes
#   - s2n_config_set_protocol_preferences
#   - s2n_connection_new / s2n_connection_free
#   - s2n_connection_set_config
#   - s2n_connection_set_fd
#   - s2n_negotiate
#   - s2n_send / s2n_recv
#   - s2n_shutdown
#   - s2n_get_server_name
#   - s2n_strerror
#   - s2n_connection_request_key_update / s2n_connection_get_key_update_counts
#     / s2n_connection_get_actual_protocol_version (TLS 1.3 key update)
#
# CALLBACK API DELIBERATELY EXCLUDED (no trampolines):
# s2n_connection_set_send_cb / s2n_connection_set_recv_cb
# are NOT bound here. The fd-direct path (s2n_connection_set_fd) is the
# only supported shape.
# =============================================================================

from std.ffi import external_call


# -----------------------------------------------------------------------------
# Canonical s2n FFI origin (FFI-BOUNDARY).
#
# Every opaque s2n handle + byte-buffer FFI pointer here uses the CONCRETE
# `StaticConstantOrigin` (`_S2N_FFI_ORIGIN`), a non-wildcard origin valid for the
# FFI ABI boundary — never a `MutExternalOrigin` wildcard. The opaque `s2n_config_t*` / `s2n_connection_t*` handles are passed
# BY VALUE to `external_call` and never written through Mojo-side, so an immutable
# static origin is sound. Data-buffer pointers (PEM / SNI / send/recv bytes) are
# coerced to this origin in the `s2n_shim.mojo` `_*_ptr` helpers; the SAFETY
# contract is that the caller holds the buffer's real origin in scope across the
# synchronous external_call (s2n copies retained bytes into its own arena).
#
# WHY: a wildcard origin on
# `_S2nConnectionHandle._raw` (a Movable owning-pointer FIELD with a `__del__`,
# nested in `TlsConnection` -> `TlsClientStream`) defeats the compiler's
# ASAP-destruction tracking across the `return _stream^` move out of
# `TlsConnector.connect`, letting the move stray-write the live s2n connection
# heap struct (`conn->quic_enabled` flipped False->True on about half of
# launches -> S2N_ERR_UNSUPPORTED_WITH_QUIC / zero-bytes). A concrete static
# origin removes that hazard; there are ZERO wildcard fields in the tls module.
# -----------------------------------------------------------------------------
comptime _S2N_FFI_ORIGIN = ImmStaticOrigin

# Opaque s2n handle (s2n_config_t* / s2n_connection_t* / s2n_cert_chain_and_key_t*)
# and s2n-owned static-string pointers. The FFI-POD opaque-pointer shape: never
# dereferenced Mojo-side, only handed back to libs2n. Held as
# `UnsafePointer[NoneType, _S2N_FFI_ORIGIN]` (the existing NoneType opaque carrier)
# / `UnsafePointer[UInt8, _S2N_FFI_ORIGIN]` (byte buffers + returned C strings).
comptime S2nOpaquePtr = UnsafePointer[NoneType, _S2N_FFI_ORIGIN]
comptime S2nBytePtr = UnsafePointer[UInt8, _S2N_FFI_ORIGIN]
comptime S2nInt32Ptr = UnsafePointer[Int32, _S2N_FFI_ORIGIN]


# -----------------------------------------------------------------------------
# s2n_blocked_status enum constants (s2n.h lines 2165-2171)
# -----------------------------------------------------------------------------
# The actual Mojo-side handshake-state-machine enum lives in
# `handshake_state.mojo`; the constants here are the raw C enum values for
# direct comparison against the `s2n_blocked_status` out-parameter that
# s2n_negotiate / s2n_send / s2n_recv / s2n_shutdown populate.

comptime S2N_NOT_BLOCKED: Int32 = 0
comptime S2N_BLOCKED_ON_READ: Int32 = 1
comptime S2N_BLOCKED_ON_WRITE: Int32 = 2
comptime S2N_BLOCKED_ON_APPLICATION_INPUT: Int32 = 3
comptime S2N_BLOCKED_ON_EARLY_DATA: Int32 = 4


# -----------------------------------------------------------------------------
# s2n_mode enum constants (s2n.h lines 1335-1338)
# -----------------------------------------------------------------------------

comptime S2N_SERVER: Int32 = 0
comptime S2N_CLIENT: Int32 = 1


# -----------------------------------------------------------------------------
# s2n return code sentinels
# -----------------------------------------------------------------------------

comptime S2N_SUCCESS: Int32 = 0
comptime S2N_FAILURE: Int32 = -1


# =============================================================================
# Library lifecycle
# =============================================================================


def s2n_init() -> Int32:
    """Initialize s2n-tls. Idempotent within a process (s2n's internal guard).
    Returns S2N_SUCCESS (0) on success, S2N_FAILURE (-1) on error.

    Maps directly to s2n.h:234 `int s2n_init(void)`.
    """
    # SAFETY: void-arg, int-return. Pure library-lifecycle init. No
    # pointer crosses any boundary. Resolves via the static-link path.
    return external_call["komira_s2n_init", Int32]()


def s2n_cleanup() -> Int32:
    """Release per-thread s2n-tls resources. Returns S2N_SUCCESS / FAILURE.

    Maps directly to s2n.h:242 `int s2n_cleanup(void)`.
    """
    # SAFETY: void-arg, int-return. Per-thread cleanup; no pointer
    # crosses any boundary.
    return external_call["komira_s2n_cleanup", Int32]()


# =============================================================================
# s2n_config_t lifecycle
# =============================================================================


def s2n_config_new() -> S2nOpaquePtr:
    """Allocate a fresh s2n_config_t. Returns NULL on OOM.

    Maps to s2n.h:277 `struct s2n_config *s2n_config_new(void)`.
    """
    # SAFETY: void-arg returning an OPAQUE config pointer. The returned
    # pointer is wrapped in `_S2nConfigHandle` (s2n_shim.mojo) which
    # owns the lifetime and calls s2n_config_free in __del__. The
    # CONCRETE `_S2N_FFI_ORIGIN` (StaticConstantOrigin) opaque-handle origin
    # replaces the banned `MutExternalOrigin` wildcard (stale-pointer fix).
    return external_call[
        "komira_s2n_config_new", S2nOpaquePtr
    ]()


def s2n_config_free(config: S2nOpaquePtr) -> Int32:
    """Release a s2n_config_t. Idempotent? — per s2n.h:300 contract: no.

    Maps to s2n.h:300 `int s2n_config_free(struct s2n_config *config)`.
    """
    # SAFETY: caller (s2n_shim's _S2nConfigHandle.__del__) ensures
    # exactly-one call per config pointer (null-sentinel guard prevents
    # double-free on moved-from handles).
    return external_call["komira_s2n_config_free", Int32](config)


# =============================================================================
# s2n_cert_chain_and_key_t lifecycle + load
# =============================================================================


def s2n_cert_chain_and_key_new() -> S2nOpaquePtr:
    """Allocate an empty cert-chain-and-key struct. Returns NULL on OOM.

    Maps to s2n.h:658 `struct s2n_cert_chain_and_key *
        s2n_cert_chain_and_key_new(void)`.
    """
    # SAFETY: void-arg returning an opaque pointer. The caller owns it and
    # frees it with s2n_cert_chain_and_key_free: TlsConfig.load_cert frees it
    # when the PEM load fails, and otherwise hands it to the config handle,
    # which frees it after s2n_config_free.
    return external_call[
        "komira_s2n_cert_chain_and_key_new",
        S2nOpaquePtr,
    ]()


def s2n_cert_chain_and_key_free(
    cert_and_key: S2nOpaquePtr,
) -> Int32:
    """Release a cert-chain-and-key.

    Maps to s2n.h:713 `int s2n_cert_chain_and_key_free(...)`.

    A chain added with s2n_config_add_cert_chain_and_key_to_store stays
    owned by the caller (s2n marks the config's chains application-owned,
    and s2n_config_free then frees none of them, tls/s2n_config.c
    `s2n_config_free_cert_chain_and_key`). The caller frees it with this
    call, and must not free it while a config still uses it.
    """
    # SAFETY: the caller passes a chain no live config uses: one whose load
    # failed (TlsConfig.load_cert) or one whose config was already freed
    # (_S2nConfigHandle.__deinit__).
    return external_call["komira_s2n_cert_chain_and_key_free", Int32](cert_and_key)


def s2n_cert_chain_and_key_load_pem_bytes(
    chain_and_key: S2nOpaquePtr,
    chain_pem: S2nBytePtr,
    chain_pem_len: UInt32,
    private_key_pem: S2nBytePtr,
    private_key_pem_len: UInt32,
) -> Int32:
    """Load PEM-encoded cert chain + private key into the chain object.

    Maps to s2n.h:692 `int s2n_cert_chain_and_key_load_pem_bytes(
        struct s2n_cert_chain_and_key *chain_and_key,
        uint8_t *chain_pem, uint32_t chain_pem_len,
        uint8_t *private_key_pem, uint32_t private_key_pem_len)`.
    """
    # SAFETY: synchronous call. Caller's PEM byte buffers (chain_pem +
    # private_key_pem) MUST remain valid for the duration of this call.
    # s2n COPIES the parsed cert + key into its own arena, so the PEM
    # buffers can be released after this returns.
    return external_call["komira_s2n_cert_chain_and_key_load_pem_bytes", Int32](
        chain_and_key, chain_pem, chain_pem_len,
        private_key_pem, private_key_pem_len,
    )


def s2n_config_add_cert_chain_and_key_to_store(
    config: S2nOpaquePtr,
    cert_key_pair: S2nOpaquePtr,
) -> Int32:
    """Attach a cert-chain-and-key to a config. The config borrows the
    chain and does NOT take ownership: s2n marks the config's chains
    application-owned, and s2n_config_free does not free them. The caller
    frees the chain with s2n_cert_chain_and_key_free after it frees the
    config.

    Maps to s2n.h:819 `int s2n_config_add_cert_chain_and_key_to_store(...)`.
    """
    # SAFETY: synchronous call. The caller keeps ownership of cert_key_pair
    # whatever the result; on S2N_FAILURE the config may already hold the
    # pointer (s2n builds its SNI map before its last check), so the chain
    # must outlive the config either way.
    return external_call[
        "komira_s2n_config_add_cert_chain_and_key_to_store", Int32,
    ](config, cert_key_pair)


# =============================================================================
# ALPN configuration
# =============================================================================


def s2n_config_append_protocol_preference(
    config: S2nOpaquePtr,
    protocol: S2nBytePtr,
    protocol_len: UInt8,
) -> Int32:
    """Append ONE ALPN protocol to the config's preference list. Simpler
    than `s2n_config_set_protocol_preferences` (which takes an argv-style
    array); we use this per-protocol-loop for safer FFI marshaling.

    Maps to s2n.h:1098 `int s2n_config_append_protocol_preference(
        struct s2n_config *config,
        const uint8_t *protocol, uint8_t protocol_len)`.

    Per s2n.h:1096: protocol_len cannot be 0.
    """
    # SAFETY: synchronous call. `protocol` byte buffer held in scope
    # by the caller's wrapper across the external_call. s2n copies the
    # bytes into its own config arena.
    return external_call["komira_s2n_config_append_protocol_preference", Int32](
        config, protocol, protocol_len
    )


def s2n_config_set_protocol_preferences(
    config: S2nOpaquePtr,
    protocols: UnsafePointer[S2nBytePtr, _S2N_FFI_ORIGIN],
    protocol_count: Int32,
) -> Int32:
    """Set the ALPN protocol list. `protocols` is an argv-style array of
    NUL-terminated C strings (e.g. `["http/1.1", NULL-sentinel-not-needed]`).
    `protocol_count` is the number of entries in the array.

    Maps to s2n.h:1117 `int s2n_config_set_protocol_preferences(
        struct s2n_config *config,
        const char *const *protocols, int protocol_count)`.

    Phase 1 usage: `["http/1.1"]` with count=1. (HTTP/2) will pass
    `["h2", "http/1.1"]` with count=2.
    """
    # SAFETY: synchronous call. s2n copies the protocol strings into its
    # config arena; caller's argv array + the strings it points at can be
    # released after this returns.
    return external_call["komira_s2n_config_set_protocol_preferences", Int32](
        config, protocols, protocol_count
    )


# =============================================================================
# s2n_connection_t lifecycle
# =============================================================================


def s2n_connection_new(
    mode: Int32,
) -> S2nOpaquePtr:
    """Allocate a fresh s2n_connection_t. `mode` is S2N_SERVER (0) or
    S2N_CLIENT (1). Returns NULL on OOM.

    Maps to s2n.h:1356 `struct s2n_connection *s2n_connection_new(s2n_mode)`.
    """
    # SAFETY: int-arg, opaque-pointer return. Caller (TlsConnection's
    # _S2nConnectionHandle.__init__) owns the returned pointer; __del__
    # calls s2n_connection_free.
    return external_call[
        "komira_s2n_connection_new", S2nOpaquePtr
    ](mode)


def s2n_connection_free(
    conn: S2nOpaquePtr,
) -> Int32:
    """Release a s2n_connection_t. Wipes the connection internally
    before freeing (per s2n.h:2305-2306).

    Maps to s2n.h:2313 `int s2n_connection_free(struct s2n_connection *)`.
    """
    # SAFETY: caller (s2n_shim's _S2nConnectionHandle.__del__) ensures
    # exactly-one call per connection pointer (null-sentinel guard
    # prevents double-free on moved-from handles).
    return external_call["komira_s2n_connection_free", Int32](conn)


def s2n_connection_set_config(
    conn: S2nOpaquePtr,
    config: S2nOpaquePtr,
) -> Int32:
    """Attach a config to a connection. The connection holds a NON-OWNING
    reference to the config; the config must outlive every connection
    that references it.

    Maps to s2n.h:1365 `int s2n_connection_set_config(...)`.
    """
    # SAFETY: caller (TlsConnection.__init__) holds a `ref` to the
    # owning TlsConfig and threads its raw config pointer. Lifetime
    # discipline: the borrow checker rejects code that destroys the
    # TlsConfig while a TlsConnection still references it (the
    # ref-origin tracking).
    return external_call["komira_s2n_connection_set_config", Int32](conn, config)


def s2n_connection_set_fd(
    conn: S2nOpaquePtr,
    fd: Int32,
) -> Int32:
    """Attach a connected socket file descriptor to a connection. After
    this, s2n_negotiate / s2n_send / s2n_recv read/write via the fd
    directly using readv / writev syscalls (no callback indirection).

    Maps to s2n.h:1721 `int s2n_connection_set_fd(struct s2n_connection *,
                                                  int fd)`.
    """
    # SAFETY: caller (TlsConnection.bind_fd) owns the fd's lifetime —
    # the fd MUST remain valid (not close()'d) for the lifetime of the
    # connection. The s2n_connection_free path does NOT close the fd;
    # that's the caller's responsibility.
    return external_call["komira_s2n_connection_set_fd", Int32](conn, fd)


# =============================================================================
# TLS handshake + IO
# =============================================================================


def s2n_negotiate(
    conn: S2nOpaquePtr,
    blocked: S2nInt32Ptr,
) -> Int32:
    """Drive one step of the TLS handshake. On `S2N_BLOCKED_*` return,
    `*blocked` is set to the blocked-status enum value (mapped to
    reactor INTEREST in `handshake_state.mojo`). Returns S2N_SUCCESS
    when the handshake is complete; S2N_FAILURE on error.

    Maps to s2n.h:2188 `int s2n_negotiate(struct s2n_connection *,
                                          s2n_blocked_status *blocked)`.
    """
    # SAFETY: synchronous call. `blocked` is a 4-byte stack out-parameter
    # owned by the caller (TlsConnection.handshake). The s2n library
    # writes to *blocked but does not retain the pointer past the return.
    return external_call["komira_s2n_negotiate", Int32](conn, blocked)


def s2n_send(
    conn: S2nOpaquePtr,
    buf: S2nBytePtr,
    size: Int64,
    blocked: S2nInt32Ptr,
) -> Int64:
    """Encrypt + send application bytes via the bound fd. Returns the
    number of plaintext bytes accepted (may be partial), or -1 on error.
    Like s2n_negotiate, may set `*blocked` to S2N_BLOCKED_ON_WRITE when
    the kernel send buffer is full.

    Maps to s2n.h:2207 `ssize_t s2n_send(struct s2n_connection *,
        const void *buf, ssize_t size, s2n_blocked_status *blocked)`.

    Note: s2n's ssize_t maps to Mojo Int64 on 64-bit platforms.
    """
    # SAFETY: synchronous call. `buf` MUST outlive the call; the
    # TlsConnection.send wrapper takes a Span[UInt8, _] and holds it
    # in scope across the external_call. `blocked` is a stack
    # out-parameter (same shape as s2n_negotiate).
    return external_call["komira_s2n_send", Int64](conn, buf, size, blocked)


def s2n_recv(
    conn: S2nOpaquePtr,
    buf: S2nBytePtr,
    size: Int64,
    blocked: S2nInt32Ptr,
) -> Int64:
    """Receive + decrypt application bytes from the bound fd. Returns
    the number of plaintext bytes written to `buf` (may be partial),
    0 on graceful close (peer sent close_notify), or -1 on error.

    Maps to s2n.h:2256 `ssize_t s2n_recv(struct s2n_connection *,
        void *buf, ssize_t size, s2n_blocked_status *blocked)`.
    """
    # SAFETY: synchronous call. `buf` MUST outlive the call (typically
    # a pre-allocated List[UInt8]). `blocked` is a stack out-parameter.
    return external_call["komira_s2n_recv", Int64](conn, buf, size, blocked)


def s2n_peek(
    conn: S2nOpaquePtr,
) -> UInt32:
    """Return the number of bytes of DECRYPTED plaintext that s2n has
    already pulled off the socket and buffered in its userspace receive
    buffer but has NOT yet handed back via s2n_recv. A non-zero return
    means another s2n_recv WILL produce bytes WITHOUT touching the socket
    fd.

    Maps to s2n.h:2272 `uint32_t s2n_peek(struct s2n_connection *conn)`.

    Load-bearing for the TLS buffered-plaintext lost-wakeup fix (an h2
    request that otherwise waits out its 120s wall deadline): s2n decrypts in
    ~16KB TLS-RECORD units while the h2/h1 drivers read in 4096-byte
    chunks, so one s2n_recv can drain a whole record off the socket and
    leave the remainder buffered. When s2n then returns BLOCKED_ON_READ
    mid-record the socket fd has NO more bytes — parking on fd-readiness
    would hang. A caller checks `s2n_peek() > 0` BEFORE parking and
    re-reads instead.

    This is a PURE getter — no out-parameter, no blocked status, no side
    effect on the connection. It never touches the fd; it only reports the
    state of s2n's already-decrypted application-data buffer.
    """
    # SAFETY: synchronous, read-only FFI call. `conn` is the live s2n
    # connection handle (owned by the caller's TlsConnection, alive for
    # this call). s2n_peek does not retain the pointer past the return,
    # does not allocate, and does not mutate connection state — it returns
    # the count of buffered plaintext bytes. No pointer escapes.
    return external_call["komira_s2n_peek", UInt32](conn)


def s2n_connection_get_wire_bytes_in(
    conn: S2nOpaquePtr,
) -> UInt64:
    """Total bytes s2n has READ OFF THE SOCKET on this connection, ever —
    ciphertext, record headers and all, counted at the `read(2)`.

    Maps to s2n.h:3098
    `uint64_t s2n_connection_get_wire_bytes_in(struct s2n_connection *)`
    (`tls/s2n_connection.c:900`). The counter is bumped at `tls/s2n_recv.c:71`,
    `conn->wire_bytes_in += r`, AFTER `s2n_io_check_read_result(r)` — so a read
    that returned EAGAIN, EOF or an error adds NOTHING, while a read that moved
    bytes adds them even when the enclosing `s2n_recv` then blocks part-way
    through the record.

    ★ WHY A DRIVER NEEDS THIS: **"`s2n_recv` returned no plaintext" and "this
    connection is not moving" ARE DIFFERENT FACTS**, and a livelock detector
    that can only observe the first misfires. A TLS record is
    up to 16 KiB; a peer delivering one across many TCP segments makes the fd
    readable once per segment, and every one of those reads blocks at the
    APPLICATION layer while moving real bytes at the WIRE layer. Counting them
    as "no progress" is how a healthy-but-slow transfer earns
    `HttpError[LIVELOCK]`. This counter is the layer at which the question has
    an unambiguous answer.

    PURE getter. No out-parameter, no fd access, no allocation, no mutation.
    """
    # SAFETY: synchronous, read-only FFI. `conn` is the live s2n connection
    # handle (owned by the caller's TlsConnection, alive for this call). The
    # callee reads one `uint64_t` field and returns it by value; the pointer is
    # not retained past the return. No pointer escapes.
    return external_call["komira_s2n_connection_get_wire_bytes_in", UInt64](conn)


def s2n_connection_get_wire_bytes_out(
    conn: S2nOpaquePtr,
) -> UInt64:
    """Total bytes s2n has WRITTEN TO THE SOCKET on this connection, ever,
    counted at the `write(2)`.

    Maps to s2n.h:3106
    `uint64_t s2n_connection_get_wire_bytes_out(struct s2n_connection *)`.
    The counter lives inside `s2n_flush`'s drain loop (`tls/s2n_send.c:88-91`):

        int w = s2n_connection_send_stuffer(&conn->out, conn, ...);
        POSIX_GUARD_RESULT(s2n_io_check_write_result(w));
        conn->wire_bytes_out += w;

    ⇒ a `write(2)` that fails EPIPE/ECONNRESET — a departed peer — bails at the
    GUARD and adds NOTHING, so the counter FREEZES; a partial write on a
    congested socket adds exactly what the kernel took.

    ★★ AND THAT IS THE DISCRIMINATOR `s2n_send` ITSELF CANNOT REPORT.
    `s2n_sendv_with_offset_impl` (tls/s2n_send.c:146) opens with

        /* Flush any pending I/O */
        POSIX_GUARD(s2n_flush(conn, blocked));

    and `POSIX_GUARD` is an EARLY RETURN — it bypasses the
    `s2n_errno == S2N_ERR_IO_BLOCKED && user_data_sent > 0` partial-acknowledge
    arm 80 lines below (tls/s2n_send.c:223-230). So once `conn->out` holds an
    undrained record, EVERY subsequent `s2n_send` answers
    `(-1, S2N_BLOCKED_ON_WRITE)` with ZERO plaintext accepted, however many
    bytes its leading flush just pushed onto the wire. A slow-draining peer
    therefore produces an UNBOUNDED run of "ready park, zero bytes accepted"
    trips on a connection that is transferring the whole time.
    `wire_bytes_out` rises across exactly those trips, and is frozen across a
    departed-peer spin.

    PURE getter. Same contract as `s2n_connection_get_wire_bytes_in`.
    """
    # SAFETY: synchronous, read-only FFI. See the sibling above.
    return external_call["komira_s2n_connection_get_wire_bytes_out", UInt64](conn)


def s2n_shutdown(
    conn: S2nOpaquePtr,
    blocked: S2nInt32Ptr,
) -> Int32:
    """Send a TLS close_notify alert + drain peer's close_notify.
    Like negotiate / send / recv, returns S2N_BLOCKED_ON_READ or WRITE
    when more IO is needed. Returns S2N_SUCCESS on full shutdown.

    Maps to s2n.h:2330 `int s2n_shutdown(struct s2n_connection *,
        s2n_blocked_status *blocked)`.
    """
    # SAFETY: synchronous call. `blocked` is a stack out-parameter.
    return external_call["komira_s2n_shutdown", Int32](conn, blocked)


# =============================================================================
# SNI extraction
# =============================================================================


def s2n_get_server_name(
    conn: S2nOpaquePtr,
) -> S2nBytePtr:
    """Get the SNI hostname the client requested (server-side only).
    Returns a pointer to s2n-owned NUL-terminated UTF-8, or NULL if
    no SNI was sent.

    Maps to s2n.h:2132 `const char *s2n_get_server_name(
        struct s2n_connection *conn)`.

    The returned pointer is owned by s2n and remains valid for the
    lifetime of the connection. Callers should COPY the bytes into a
    Mojo String before any subsequent s2n call that might invalidate
    the buffer (e.g. s2n_connection_wipe).
    """
    # SAFETY: the returned pointer is non-owning — caller must NOT free
    # it. The TlsConnection.sni_hostname wrapper copies into a String
    # before returning, so the unsafe pointer never escapes the FFI
    # layer.
    return external_call[
        "komira_s2n_get_server_name", S2nBytePtr
    ](conn)


# =============================================================================
# ALPN readback
# =============================================================================


def s2n_get_application_protocol(
    conn: S2nOpaquePtr,
) -> S2nBytePtr:
    """Get the ALPN protocol negotiated at handshake. Returns a pointer
    to s2n-owned NUL-terminated UTF-8 (e.g., "h2", "http/1.1"), or NULL
    if no ALPN was negotiated.

    Maps to s2n.h:2156 `const char *s2n_get_application_protocol(
        struct s2n_connection *conn)`.

    this is the readback used by the HttpServer
    accept-loop pivot to decide between the h2 path and the h1 path
    AFTER s2n_negotiate completes.

    The returned pointer is owned by s2n and remains valid for the
    lifetime of the connection. Callers MUST COPY the bytes into a
    Mojo String before any subsequent s2n call that could invalidate
    the buffer (e.g. s2n_connection_wipe).
    """
    # SAFETY: the returned pointer is non-owning — caller must NOT free
    # it. The TlsConnection.negotiated_protocol wrapper copies into a
    # String before returning, so the unsafe pointer never escapes the
    # FFI layer.
    return external_call[
        "komira_s2n_get_application_protocol",
        S2nBytePtr,
    ](conn)


# =============================================================================
# Error reporting
# =============================================================================


def s2n_strerror(
    error: Int32,
    lang: S2nBytePtr,
) -> S2nBytePtr:
    """Get a human-readable error message for a s2n errno value.
    `lang` is a NUL-terminated language code; pass NULL for English
    (the only supported language in s2n).

    Maps to s2n.h:411 `const char *s2n_strerror(int error, const char *)`.
    """
    # SAFETY: returns a pointer into s2n's static error string table —
    # never freed by caller. Wrapper code in s2n_shim copies into a
    # Mojo String for error-formatting paths.
    return external_call[
        "komira_s2n_strerror", S2nBytePtr
    ](error, lang)


# `s2n_error_type` (api/s2n.h:147-164). ⚠ THE ENUM IS COMMENT-INTERLEAVED in
# the header — the values are consecutive from 0 and do NOT line up with the
# line numbers around them. S2N_ERR_T_CLOSED's own doc comment is one word:
# "EOF".
comptime S2N_ERR_T_OK: Int32 = 0
comptime S2N_ERR_T_IO: Int32 = 1
comptime S2N_ERR_T_CLOSED: Int32 = 2
comptime S2N_ERR_T_BLOCKED: Int32 = 3


def s2n_error_get_type(error: Int32) -> Int32:
    """The high-level CLASS of an s2n errno — the disambiguator s2n's own docs
    tell non-blocking applications to use.

      "Applications using non-blocking I/O should check the error type to
       determine if the I/O operation failed because it would block or for
       some other error."  — api/s2n.h:140-143

    ★ THIS IS THE ONLY RELIABLE ANSWER ON THE RECV PATH, and `*blocked` is not.
    `s2n_recv_impl` PRESETS `*blocked = S2N_BLOCKED_ON_READ` at entry
    (tls/s2n_recv.c:176) and resets it only after a successful read
    (s2n_recv.c:281-290), so EVERY failure — a closed peer, an ECONNRESET, a
    protocol error — comes back claiming BLOCKED_ON_READ. See
    `s2n_shim._recv_outcome_and_n` for what that costs.

    Maps to s2n.h:176 `int s2n_error_get_type(int error)`.
    """
    # SAFETY: pure integer -> integer classification call into libs2n. No
    # pointer crosses; no connection state is touched.
    return external_call["komira_s2n_error_get_type", Int32](error)


def s2n_errno_location() -> S2nInt32Ptr:
    """Get the address of the thread-local s2n_errno variable. Useful
    for fetching the most recent s2n errno after a S2N_FAILURE return.

    Maps to s2n.h:131 `int *s2n_errno_location(void)`.
    """
    # SAFETY: returns a pointer to s2n's TLS-thread-local errno slot.
    # Pointer is valid for the lifetime of the thread. Wrapper code
    # dereferences once and copies the Int32 out.
    return external_call[
        "komira_s2n_errno_location", S2nInt32Ptr
    ]()


# =============================================================================
# Client-mode extensions
# =============================================================================
#
# Client-mode FFI surface:
#   - 5 external_call decls (s2n_config_set_verification_type does NOT exist
#     in upstream s2n-tls 1.5.6; the default config already verifies).
#   - s2n_set_server_name binds under its actual C symbol name (the slot
#     brief's `s2n_connection_set_server_name` is misspelled; upstream
#     s2n.h:2121 declares `s2n_set_server_name(struct s2n_connection *,
#     const char *)`).
#   - verify_host_callback IS bound for FFI completeness even though the
#     safe surface does not exercise it.
#   - Session-ticket FFI bindings are a separate block below.
# =============================================================================


def s2n_config_disable_x509_verification(
    config: S2nOpaquePtr,
) -> Int32:
    """Disable X.509 certificate-chain verification on this config.

    Maps to s2n.h:1057 `int s2n_config_disable_x509_verification(
        struct s2n_config *config)`.

    After this call, the client side will NOT verify the server's cert
    chain against the trust store; useful for self-signed test fixtures.
    DO NOT use in production. Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: synchronous config mutation. The config pointer is opaque
    # and the caller (TlsConfig.disable_verify) owns its lifetime via
    # the OwnedPointer-of-handle pattern. No pointer escapes.
    return external_call["komira_s2n_config_disable_x509_verification", Int32](config)


def s2n_config_set_verify_host_callback(
    config: S2nOpaquePtr,
    callback: S2nOpaquePtr,
    data: S2nOpaquePtr,
) -> Int32:
    """Set a callback invoked during host-name verification on the
    client side. `callback` is a `s2n_verify_host_fn` (a C fn-ptr
    `uint8_t (*)(const char *host_name, size_t host_name_len, void *data)`).
    `data` is a `void *` user context.

    Maps to s2n.h:1010 `int s2n_config_set_verify_host_callback(
        struct s2n_config *, s2n_verify_host_fn, void *)`.

    Status: bound at the FFI layer for completeness; the safe
    `TlsConfig` surface does NOT currently expose this (no
    `set_verify_host_callback` method). When/if the safe surface adds
    a callback dispatcher, it MUST manage callback + data lifetimes
    against the config's lifetime (the config holds a NON-OWNING
    reference to both).

    Bound for completeness; the safe surface does not use it.

    Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: the callback + data pointers are stored in the config's
    # internal state without copy; both MUST outlive the config. This
    # binding is currently unused on the safe surface — no public method
    # threads a callback through. If/when added, the safe wrapper MUST
    # accept a function-pointer + a lifetime-bound data type.
    return external_call["komira_s2n_config_set_verify_host_callback", Int32](
        config, callback, data
    )


def s2n_config_add_pem_to_trust_store(
    config: S2nOpaquePtr,
    pem: S2nBytePtr,
) -> Int32:
    """Append PEM-encoded CA certs to the config's trust store.

    Maps to s2n.h:888 `int s2n_config_add_pem_to_trust_store(
        struct s2n_config *config, const char *pem)`.

    IMPORTANT: `pem` MUST be NUL-terminated. Unlike
    `s2n_cert_chain_and_key_load_pem_bytes` which takes a (ptr, len)
    pair, this API takes a C-string (the s2n parser scans until NUL).

    Per s2n.h:849: "The trust store will be initialized with the common
    locations for the host operating system by default" — calls to this
    function APPEND to that default. Use `s2n_config_wipe_trust_store`
    first to start from empty.

    Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: synchronous call. s2n COPIES the parsed cert into its
    # config arena before returning, so the `pem` buffer can be released
    # after this returns. The caller (TlsConfig.add_trust_pem) MUST
    # ensure the buffer is NUL-terminated and holds the borrow alive
    # across the external_call.
    return external_call["komira_s2n_config_add_pem_to_trust_store", Int32](
        config, pem
    )


def s2n_config_wipe_trust_store(
    config: S2nOpaquePtr,
) -> Int32:
    """Empty the config's trust store. Subsequent calls to
    `s2n_config_add_pem_to_trust_store` build the trust store from
    empty (vs. appending to the default OS trust roots).

    Maps to s2n.h:901 `int s2n_config_wipe_trust_store(
        struct s2n_config *config)`.

    Use case: deterministic tests that need EXACTLY one specific root
    in the trust store (no OS roots polluting the verification path).

    Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: synchronous config mutation. No pointer crosses any
    # boundary other than the opaque config handle.
    return external_call["komira_s2n_config_wipe_trust_store", Int32](config)


def s2n_config_set_cipher_preferences(
    config: S2nOpaquePtr,
    version: S2nBytePtr,
) -> Int32:
    """Set the security policy (cipher / kem / signature / ecc preferences
    + protocol-version range) on a config by named version string.

    Maps to s2n.h:1087 `int s2n_config_set_cipher_preferences(
        struct s2n_config *config, const char *version)`.

    This is the unblocker
    for the s2n CLIENT <-> OpenSSL/Go-server handshake. The DEFAULT policy a
    fresh `s2n_config_new()` carries in s2n-tls 1.5.6 is `"default"` =
    security_policy_20240501, whose cipher list (cipher_suites_20240331)
    contains ONLY TLS 1.2 suites - NO TLS 1.3 suites. s2n derives the
    MAXIMUM offered protocol version from the presence of TLS 1.3 cipher
    suites in the policy, so the "default" policy makes the client send a
    TLS-1.2-only ClientHello. TLS-1.3-preferring servers (Postgres 16's
    OpenSSL, the K8s apiserver's Go crypto/tls) reject / EOF that
    ClientHello before sending a ServerHello.

    Setting `"default_tls13"` (= security_policy_20240503, whose cipher
    list cipher_suites_cloudfront_tls_1_2_2019 DOES include TLS 1.3 suites
    via S2N_TLS13_CLOUDFRONT_CIPHER_SUITES_20200716) makes the client
    offer TLS 1.3, which interops with both server families.

    `version` MUST be a NUL-terminated ASCII version string (e.g.
    "default_tls13", "20230317"). Returns S2N_SUCCESS / FAILURE (FAILURE
    on an unknown version string).
    """
    # SAFETY: synchronous config mutation. s2n looks up the named policy
    # in its static `security_policy_selection[]` table and stores a
    # pointer to the STATIC policy struct on the config - it does NOT
    # retain the caller's `version` buffer (the string is only read
    # during the table scan). The caller (TlsConfig.set_cipher_preferences)
    # holds the String borrow alive across this synchronous call. No
    # pointer escapes the FFI boundary.
    return external_call["komira_s2n_config_set_cipher_preferences", Int32](
        config, version
    )


def s2n_set_server_name(
    conn: S2nOpaquePtr,
    server_name: S2nBytePtr,
) -> Int32:
    """Set the SNI hostname the CLIENT will send to the server during
    the handshake. Counterpart to the server-side `s2n_get_server_name`
    (which reads what the peer client sent).

    Maps to s2n.h:2121 `int s2n_set_server_name(
        struct s2n_connection *conn, const char *server_name)`.

    NOTE: the actual upstream symbol is `s2n_set_server_name` (NO
    `_connection_` infix); there is no
    `s2n_connection_set_server_name`. The safe-surface method on
    TlsConnection is named `set_server_name(host: String)`.

    `server_name` MUST be a NUL-terminated UTF-8 hostname string.
    Per s2n source (tls/s2n_connection.c::s2n_set_server_name), s2n
    COPIES the name bytes into its per-connection arena synchronously
    — caller's buffer does NOT need to outlive the connection.

    Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: synchronous call. s2n copies the NUL-terminated server_name
    # into its per-connection arena before returning, so the caller
    # (TlsConnection.set_server_name) can free the buffer immediately
    # after. The buffer MUST be alive throughout the synchronous call —
    # the caller holds the String borrow across the external_call.
    return external_call["komira_s2n_set_server_name", Int32](conn, server_name)


# =============================================================================
# Session resumption
# =============================================================================
#
# Additive FFI surface for client-side TLS session-resumption-via-tickets.
# 4 bindings (config_set_session_tickets_onoff, connection_set_session,
# connection_get_session, connection_get_session_length), plus 2 additional
# bindings for completeness:
#   - s2n_config_set_session_state_lifetime — optional ticket TTL knob
#     (default 15h; we leave at default but bind for forward compat).
#   - s2n_connection_is_session_resumed — diagnostic accessor used by the
#     session-resumption test to assert resumption empirically.
#
# CALLBACK API DELIBERATELY EXCLUDED (no trampolines):
# s2n_config_set_session_ticket_cb is NOT bound. The
# connection-level set/get_session pair is sufficient for the client-side
# cache; the cb pathway is for servers issuing fresh tickets.
# =============================================================================


def s2n_config_set_session_tickets_onoff(
    config: S2nOpaquePtr,
    enabled: UInt8,
) -> Int32:
    """Enable or disable session resumption using session tickets on the
    config. `enabled=1` turns ticket-receive on (client side accepts
    tickets from servers); `enabled=0` turns it off.

    Maps to s2n.h:1270 `int s2n_config_set_session_tickets_onoff(
        struct s2n_config *config, uint8_t enabled)`.

    Per s2n: default is OFF; client MUST call this with `enabled=1`
    BEFORE creating connections to allow s2n to negotiate the session-
    ticket extension in the ClientHello.

    Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: synchronous config mutation. No pointer escapes; `config`
    # is the opaque handle whose lifetime the caller (TlsConfig) owns.
    return external_call["komira_s2n_config_set_session_tickets_onoff", Int32](
        config, enabled
    )


def s2n_config_set_session_state_lifetime(
    config: S2nOpaquePtr,
    lifetime_in_secs: UInt64,
) -> Int32:
    """Set the lifetime of the cached session state. The default is
    15 hours. Affects TLS 1.2 session-ticket validity; TLS 1.3 PSK
    lifetime is server-controlled and this knob has no effect on 1.3.

    Maps to s2n.h:1261 `int s2n_config_set_session_state_lifetime(
        struct s2n_config *config, uint64_t lifetime_in_secs)`.

    Status: bound for forward compat; the safe-surface TlsConfig
    does not currently expose a setter for this (default 15h is
    appropriate for the per-process client lifetime).

    Returns S2N_SUCCESS / FAILURE.
    """
    # SAFETY: synchronous config mutation. POD args; no pointer escapes.
    return external_call["komira_s2n_config_set_session_state_lifetime", Int32](
        config, lifetime_in_secs
    )


def s2n_connection_set_session(
    conn: S2nOpaquePtr,
    session: S2nBytePtr,
    length: Int64,
) -> Int32:
    """De-serialize session state into the connection. The next
    s2n_negotiate call attempts an abbreviated handshake (TLS 1.2 ticket
    resumption or TLS 1.3 PSK).

    Maps to s2n.h:2601 `int s2n_connection_set_session(
        struct s2n_connection *conn, const uint8_t *session, size_t length)`.

    Per s2n: if this fails (malformed blob, expired ticket, server
    rejects), the connection FALLS BACK to a full handshake — the
    failure is non-fatal. Callers can treat the return value as
    best-effort.

    `session` MUST be valid + `length` bytes wide for the duration of
    this call. s2n consumes the bytes synchronously into its per-
    connection state; the buffer can be released after this returns.

    Returns the number of consumed bytes (positive int) on success,
    S2N_FAILURE on error.
    """
    # SAFETY: synchronous call. The `session` byte buffer is held alive
    # by the caller (TlsConnection.set_session wraps a List/Span borrow
    # across the external_call). s2n's session-state arena is per-
    # connection; bytes are copied in before return.
    return external_call["komira_s2n_connection_set_session", Int32](
        conn, session, length
    )


def s2n_connection_get_session_length(
    conn: S2nOpaquePtr,
) -> Int32:
    """Query the serialized session state size in bytes before copying
    it. Used to size the buffer passed to `s2n_connection_get_session`.

    Maps to s2n.h:2638 `int s2n_connection_get_session_length(
        struct s2n_connection *conn)`.

    Returns the byte count of the session state (positive int), or 0
    if no session is available (e.g. handshake not yet DONE, server did
    not issue a ticket).
    """
    # SAFETY: synchronous accessor; no pointer escapes.
    return external_call["komira_s2n_connection_get_session_length", Int32](conn)


def s2n_connection_get_session(
    conn: S2nOpaquePtr,
    session: S2nBytePtr,
    max_length: Int64,
) -> Int32:
    """Serialize the session state from the connection into the caller-
    provided buffer. Returns the number of bytes copied (positive int)
    on success, S2N_FAILURE on error.

    Maps to s2n.h:2616 `int s2n_connection_get_session(
        struct s2n_connection *conn, uint8_t *session, size_t max_length)`.

    Caller MUST first query `s2n_connection_get_session_length` to size
    the buffer; passing `max_length < session_length` truncates.

    Per s2n.h:2606-2608: "This function is not recommended for > TLS 1.2
    because in TLS1.3 servers can send multiple session tickets and this
    function will only return the most recently received ticket." For our
    LRU + overwrite semantics, "most recent ticket wins" is the
    desired behavior — newest blob supersedes any earlier cached entry
    for the same PoolKey.
    """
    # SAFETY: synchronous call. The `session` buffer is held alive by
    # the caller (TlsConnection.get_session pre-allocates a List[UInt8]
    # of size `max_length`). s2n writes up to `max_length` bytes into
    # the buffer + returns the count.
    return external_call["komira_s2n_connection_get_session", Int32](
        conn, session, max_length
    )


def s2n_connection_is_session_resumed(
    conn: S2nOpaquePtr,
) -> Int32:
    """Check if the connection was resumed from an earlier handshake
    (i.e. the handshake was abbreviated via session-ticket / PSK
    resumption rather than a full negotiation).

    Maps to s2n.h:2673 `int s2n_connection_is_session_resumed(
        struct s2n_connection *conn)`.

    Returns 1 if the handshake was abbreviated, otherwise 0. Used by
    the session-resumption test to assert that the second handshake
    on a same-PoolKey reconnect was resumption.
    """
    # SAFETY: synchronous accessor; no pointer escapes.
    return external_call["komira_s2n_connection_is_session_resumed", Int32](conn)


def s2n_connection_get_actual_protocol_version(
    conn: S2nOpaquePtr,
) -> Int32:
    """The TLS version the handshake negotiated, as s2n's protocol-version
    number (S2N_TLS12 = 33, S2N_TLS13 = 34), or -1 on failure.

    Maps to s2n.h `int s2n_connection_get_actual_protocol_version(
        struct s2n_connection *conn)`.
    """
    # SAFETY: synchronous accessor; no pointer escapes.
    return external_call["komira_s2n_connection_get_actual_protocol_version", Int32](
        conn
    )


def s2n_connection_get_cipher(conn: S2nOpaquePtr) -> S2nBytePtr:
    """The negotiated cipher suite's name in s2n's OpenSSL-style spelling
    ("TLS_AES_128_GCM_SHA256", "ECDHE-RSA-AES128-GCM-SHA256"): a pointer to a
    NUL-terminated string in s2n's static cipher-suite table, or NULL on
    failure.

    Maps to s2n.h `const char *s2n_connection_get_cipher(
        struct s2n_connection *conn)`.
    """
    # SAFETY: the returned pointer is non-owning (static storage, never
    # freed). TlsConnection.negotiated_cipher copies it into a String, so it
    # never escapes the FFI layer.
    return external_call["komira_s2n_connection_get_cipher", S2nBytePtr](conn)


# =============================================================================
# Handshake diagnostics
# =============================================================================
#
# Used to capture the exact handshake message that was in flight when the
# peer closed the connection (S2N_ERR_CLOSED). Without this, we cannot
# distinguish "peer closed after receiving our ClientHello" (TLS-version /
# cipher mismatch) from "peer closed during certificate verification" etc.
# These are read-only accessors on the connection state; they return
# pointers into static strings owned by s2n — the caller MUST NOT free them.
# =============================================================================


def s2n_connection_get_last_message_name(
    conn: S2nOpaquePtr,
) -> S2nBytePtr:
    """Get the name of the last handshake message processed.

    Maps to s2n.h:3307 `const char *s2n_connection_get_last_message_name(
        struct s2n_connection *conn)`.

    Returns a NUL-terminated static string (e.g. "CLIENT_HELLO",
    "SERVER_HELLO", "CERTIFICATE", "CLIENT_FINISHED"). Returns NULL or an
    empty string if no message has been processed yet.

    DIAGNOSTIC USE ONLY: call this at the handshake error site to pinpoint
    which handshake step the peer closed the connection at.
    """
    # SAFETY: synchronous accessor. Returns a pointer into s2n's static
    # handshake-message-name table — never freed by caller. The string is
    # valid for the process lifetime (static storage in libs2n.a).
    return external_call[
        "komira_s2n_connection_get_last_message_name",
        S2nBytePtr,
    ](conn)


def s2n_strerror_debug(
    error: Int32,
    lang: S2nBytePtr,
) -> S2nBytePtr:
    """Get s2n internal debug information for an errno value, including
    the source file + line number where the error was originally raised.

    Maps to s2n.h:422 `const char *s2n_strerror_debug(int error,
        const char *lang)`.

    Returns a NUL-terminated static string; never freed by caller.

    DIAGNOSTIC USE ONLY: call this alongside s2n_strerror at the error
    site to get the s2n internal file:line origin.
    """
    # SAFETY: synchronous accessor. Returns a pointer into s2n's static
    # error-debug-string table — never freed by caller.
    return external_call[
        "komira_s2n_strerror_debug",
        S2nBytePtr,
    ](error, lang)


# =============================================================================
# TLS 1.3 key update (safe surface: key_update.mojo, TlsConnection)
# =============================================================================

# s2n_peer_key_update (s2n.h): whether the KeyUpdate message also asks the
# peer to update its sending key. s2n 1.5.6 accepts only NOT_REQUESTED.
comptime S2N_KEY_UPDATE_NOT_REQUESTED: Int32 = 0
comptime S2N_KEY_UPDATE_REQUESTED: Int32 = 1

# S2N_TLS13 (s2n.h): the actual_protocol_version value of TLS 1.3.
comptime S2N_TLS13: Int32 = 34


def s2n_connection_request_key_update(
    conn: S2nOpaquePtr, peer_request: Int32
) -> Int32:
    """s2n.h `int s2n_connection_request_key_update(struct s2n_connection
    *conn, s2n_peer_key_update peer_request)`. Only marks the update
    pending: the KeyUpdate goes out (and the sending key changes) on the next
    `s2n_send`. Fails with S2N_ERR_INVALID_ARGUMENT for any `peer_request`
    but NOT_REQUESTED; it does not check the handshake or the version."""
    # SAFETY: synchronous call; `conn` is a live handle owned by the caller's
    # TlsConnection; the enum is passed by value (C int ABI).
    return external_call["komira_s2n_connection_request_key_update", Int32](
        conn, peer_request
    )


def s2n_connection_get_key_update_counts(
    conn: S2nOpaquePtr, send_key_updates: S2nBytePtr, recv_key_updates: S2nBytePtr
) -> Int32:
    """api/unstable/ktls.h `int s2n_connection_get_key_update_counts(struct
    s2n_connection *conn, uint8_t *send_key_updates, uint8_t
    *recv_key_updates)`. Saturates at 255."""
    # SAFETY: synchronous call. Both out-pointers address caller-owned stack
    # bytes alive across the call; s2n writes one uint8_t through each and
    # keeps neither.
    return external_call["komira_s2n_connection_get_key_update_counts", Int32](
        conn, send_key_updates, recv_key_updates
    )
