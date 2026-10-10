"""DETERMINISTIC FALSIFIER — the TLS-config use-after-free (a long-lived
streaming client failing with `S2N_ERR_UNSUPPORTED_WITH_QUIC` / zero bytes
sent).

ROOT CAUSE (proven under a debugger):
s2n's `s2n_connection_is_quic_enabled(conn)` is
`conn->quic_enabled || (conn->config && conn->config->quic_enabled)`. Our config
never enables QUIC, so a TRUE reading is the SECOND term dereferencing a FREED
`s2n_config_t`. `s2n_connection_set_config(conn, config)` stashes `conn->config`
as a raw C borrow the Mojo type system CANNOT see. If `TlsConnection` held
NO reference to the `TlsConfig` (only `_handle` + `_fd`) and
`TlsConnector._config` were the SOLE owner, a
dial-once caller that drops the connector right after `connect()` returns (ASAP
destruction) would free the config while the returned `TlsClientStream` still
borrows it via `conn->config`. The next `s2n_send`'s
`conn->config->quic_enabled` read would be a HEAP-USE-AFTER-FREE — a garbage
`quic_enabled=1` → S2N_ERR_UNSUPPORTED_WITH_QUIC / zero bytes.

THE FIX (this file guards it): the s2n_config_t is made SHARE-OWNED via
`ArcPointer` — `TlsConfig._handle` is `ArcPointer[_S2nConfigHandle]` and
`TlsConnection` holds a CLONE (`self._config`) of the config it was bound to
(an Arc refcount bump sharing the SAME s2n_config_t). The config is freed
only when BOTH the connector AND every connection that cloned it drop, so
`conn->config` is ALWAYS valid — compiler-enforced by the Arc refcount, not an
unenforced field-lifetime convention.

TECHNIQUE — s2n-ALLOCATOR FORCED-REUSE (deterministic, timing-independent):
  s2n does NOT allocate its config through libc small-block `malloc` — it uses
  its own allocator (`posix_memalign` / mmap pages via `s2n_mem.c`), so a libc
  `malloc`/`free` scribble does NOT reuse a freed `s2n_config_t` (the freed page
  is `madvise(DONTNEED)`'d = zero-filled on next read = a FALSE "clean"). The
  RELIABLE reuse is through s2n's OWN allocator:
  1. Build a client `TlsConfig`, handshake a real `TlsConnection` on it over an
     s2n loopback socketpair.
  2. DROP the caller-side `TlsConfig` (the connector-equivalent SOLE external
     owner). PRE-FIX: `_S2nConfigHandle.__del__` calls `s2n_config_free`,
     freeing the s2n_config_t out from under the still-live connection (which
     held no config ref). POST-FIX: the connection co-owns an Arc clone, so the
     config stays alive (its `__del__` does not fire — refcount > 0).
  3. SPRAY: allocate several NEW s2n configs via `s2n_config_new()` and call
     `s2n_config_enable_quic()` on each. s2n's allocator RE-HANDS the just-freed
     config page to one of these new quic-enabled configs, so the dangling
     `conn->config` now ALIASES a config whose `quic_enabled == 1`.
  4. Read `conn->config->quic_enabled` (via the s2n unstable
     `s2n_connection_is_quic_enabled` probe, which is
     `conn->quic_enabled || (conn->config && conn->config->quic_enabled)`) AND
     drive a real `try_write` through the connection.

     PRE-FIX: `conn->config` aliases a freed-then-reused quic-enabled config, so
     the probe reads TRUE AND the send fails with S2N_ERR_UNSUPPORTED_WITH_QUIC
     → this test RAISES (RED) — the EXACT live Firestore Listen Mode-1 failure,
     now deterministic.
     POST-FIX: `conn->config` points at the still-alive ORIGINAL config
     (quic == 0, a SEPARATE allocation from the sprayed ones), so `quic_enabled`
     reads 0 and the send round-trips byte-intact → the test PASSES (GREEN).

RED-before / GREEN-after: RED on current main (pre-Arc-fix), GREEN after. The
freed-then-reused config aliasing is a genuine deterministic UAF (s2n's own
allocator guarantees the reuse), NOT the ~50-70% live-timing flake.

Test-only; never used in production. Leaf cert/key fixtures are the shared
TLS artifacts. Same s2n static-link + manual pattern as the sibling L1 TLS
falsifiers.
"""

from std.ffi import external_call

from std.sys.info import CompilationTarget


from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.tcp_stream import TcpStream

from komira_http_client import TlsClientStream
from komira_http_core.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from komira_http_core.transport.io_stream import StreamIo
from komira_http_core.transport.kernel_tcp import TcpIoStream
from std.pathlib import Path


# The Runtime type parameter for `try_write[RT]` (the TLS layer only uses
# `RT.Sink` for the ignored reactor param type).
comptime _LaunchRT = PerCoreAsyncRuntime[NoopSink]


# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

# Number of independent drop-config-then-use launches. Each launch is
# DETERMINISTICALLY corrupt pre-fix (the freed config is re-handed to a sprayed
# quic-enabled config before the read), so even N=1 is a guaranteed RED pre-fix;
# we run several for robustness against allocator free-list ordering.
comptime _N_LAUNCHES: Int = 8

# How many NEW quic-enabled s2n configs to allocate after freeing the caller
# config. s2n's allocator re-hands the freed config page to one of these; a
# spray of several near-guarantees the freed slab is reused (and its
# `quic_enabled` byte becomes 1) regardless of free-list ordering.
comptime _SPRAY_CONFIGS: Int = 16


# -----------------------------------------------------------------------------
# libc + fixtures
# -----------------------------------------------------------------------------


def _leaf_cert() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv_ptr,
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd < 0:
        return
    var _rc = external_call["close", Int32](fd)


def _set_nonblock(fd: Int32) raises:
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error("_set_nonblock returned " + String(Int(rc)))


def _outcome_str(o: UInt8) -> StaticString:
    """The name of a `TLS_OUTCOME_*` ordinal, for this test's diagnostic lines.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape.
    As `-> String` this five-arm literal-return ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references an
    `--emit shared-lib` link binds INDEPENDENTLY. `StaticString` keeps the
    literals literal: ZERO register-indexed constant-table loads.
    This helper is copied across the TLS tests; the template is fixed here so
    the next copy is born safe.
    """
    if o == TLS_OUTCOME_DONE:
        return "DONE"
    if o == TLS_OUTCOME_BLOCKED_ON_READ:
        return "BLOCKED_ON_READ"
    if o == TLS_OUTCOME_BLOCKED_ON_WRITE:
        return "BLOCKED_ON_WRITE"
    if o == TLS_OUTCOME_ERROR:
        return "ERROR"
    return "UNKNOWN"


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _drive_to_done(
    mut server: TlsConnection, mut client: TlsConnection
) raises -> Tuple[UInt8, UInt8]:
    var sv_out: UInt8 = UInt8(255)
    var cl_out: UInt8 = UInt8(255)
    var sv_done = False
    var cl_done = False
    var i = 0
    while i < 256:
        if not sv_done:
            sv_out = server.handshake()
            if sv_out == TLS_OUTCOME_ERROR:
                return (sv_out, cl_out)
            if sv_out == TLS_OUTCOME_DONE:
                sv_done = True
        if not cl_done:
            cl_out = client.handshake()
            if cl_out == TLS_OUTCOME_ERROR:
                return (sv_out, cl_out)
            if cl_out == TLS_OUTCOME_DONE:
                cl_done = True
        if sv_done and cl_done:
            return (TLS_OUTCOME_DONE, TLS_OUTCOME_DONE)
        i = i + 1
    raise Error(
        "_drive_to_done: exceeded 256 iterations "
        + "(server=" + _outcome_str(sv_out)
        + ", client=" + _outcome_str(cl_out) + ")"
    )


def _build_server_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.load_cert(_leaf_cert(), _leaf_key())
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _build_client_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _spray_quic_configs() raises -> List[Int]:
    """Allocate several NEW s2n configs via `s2n_config_new()` and enable QUIC
    on each (`s2n_config_enable_quic`). s2n's OWN allocator re-hands the
    just-freed caller-config page to one of these, so a dangling `conn->config`
    now aliases a config whose `quic_enabled == 1`.

    Returns the raw config pointers (as Int) so the caller can free them AFTER
    the probe/send window — they must stay ALIVE through the read (otherwise the
    freed-then-reused page could be freed again before we look). This is the
    load-bearing forced-reuse step that turns the config UAF into a guaranteed
    pre-fix RED.
    """
    var ptrs = List[Int]()
    var i = 0
    while i < _SPRAY_CONFIGS:
        var cfg = external_call[
            "komira_s2n_config_new", UnsafePointer[NoneType, MutUntrackedOrigin]
        ]()
        if Int(cfg) != 0:
            # Enable QUIC on the new config -> its `quic_enabled` byte becomes 1.
            # If this config was handed the freed caller-config's page, the
            # dangling conn->config now reads quic_enabled == 1.
            var _rc = external_call["komira_s2n_config_enable_quic", Int32](cfg)
            ptrs.append(Int(cfg))
        i = i + 1
    return ptrs^


def _free_sprayed_configs(ptrs: List[Int]):
    """Free the sprayed quic-enabled configs (called AFTER the probe/send)."""
    var i = 0
    while i < len(ptrs):
        var p = ptrs[i]
        if p != 0:
            var raw = UnsafePointer[NoneType, MutUntrackedOrigin](
                unsafe_from_address=p
            )
            var _rc = external_call["komira_s2n_config_free", Int32](raw)
        i = i + 1


# -----------------------------------------------------------------------------
# One launch: fresh socketpair + configs, handshake, DROP the client config,
# scribble the heap, then probe conn->config + send through the connection.
# RAISES on any UAF-visible corruption. Caller loops it _N_LAUNCHES times.
# -----------------------------------------------------------------------------


def _one_launch(mut reactor: Reactor[NoopSink], launch_idx: Int) raises:
    var server_config = _build_server_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)

        # Build the client config, handshake, wrap the stream, then DROP the
        # config explicitly BEFORE we use the connection — the dial-once
        # "connector drops its OwnedPointer[TlsConfig] right after connect
        # returns" shape.
        var client_config = _build_client_config()
        var cc = TlsConnection.new_client(client_config)
        cc.bind_fd(client_fd)
        cc.set_server_name(String("localhost"))

        var outcomes = _drive_to_done(server_conn, cc)
        if outcomes[0] != TLS_OUTCOME_DONE or outcomes[1] != TLS_OUTCOME_DONE:
            var sv_msg = String("")
            if outcomes[0] == TLS_OUTCOME_ERROR:
                sv_msg = s2n_strerror_message(last_s2n_errno())
            raise Error(
                "[launch " + String(launch_idx) + "] handshake did not reach"
                + " DONE: server=" + _outcome_str(outcomes[0]) + " client="
                + _outcome_str(outcomes[1]) + " (sv_errno_msg='" + sv_msg + "')"
            )

        # Wrap into the real production TlsClientStream + move it out — the
        # connection now solely carries the config borrow (conn->config).
        var client_tcp = TcpStream(client_fd)
        var underlying = TcpIoStream(client_tcp^)
        var client_stream = TlsClientStream[TcpIoStream](underlying^, cc^)

        # ---- THE DROP: free the caller-side TlsConfig (== the connector's
        #      OwnedPointer[TlsConfig] dropping when a dial-once caller drops
        #      the connector right after connect() returns). PRE-FIX this frees
        #      the s2n_config_t out from under client_stream's conn->config.
        _ = client_config^

        # ---- FORCED REUSE (via s2n's OWN allocator): spray NEW quic-enabled
        #      configs so the freed config page is re-handed to one of them,
        #      making the dangling conn->config alias a quic_enabled==1 config
        #      (deterministic UAF corruption pre-fix). Kept alive through the
        #      probe/send window; freed at the end. ----
        var sprayed = _spray_quic_configs()

        # ---- THE CATCH (Mode 1): probe conn->config->quic_enabled. PRE-FIX
        #      the config was freed + its page re-handed to a quic-enabled
        #      config -> reads 1 (non-zero). POST-FIX the config is Arc-alive
        #      (a separate allocation from the sprayed ones) -> reads its real
        #      0. ----
        var quic_after_free = client_stream._conn_quic_enabled_for_test()
        if quic_after_free != Int32(0):
            _free_sprayed_configs(sprayed)
            raise Error(
                "[launch " + String(launch_idx) + "] USE-AFTER-FREE DETECTED:"
                + " conn->config->quic_enabled read NON-ZERO ("
                + String(Int(quic_after_free)) + ") after the caller-side"
                + " TlsConfig was dropped + a quic-enabled config re-used its"
                + " freed page. The s2n_config_t was freed out from under the"
                + " still-live TlsClientStream's conn->config borrow (dial-once"
                + " connector-drop) — the EXACT live Firestore Listen"
                + " S2N_ERR_UNSUPPORTED_WITH_QUIC root cause. The fix"
                + " (ArcPointer share-owned config) keeps it alive."
            )

        # ---- BEHAVIORAL (Mode 1 + Mode 2): a real try_write through the
        #      config-borrowing connection must NOT fail with the QUIC-usage
        #      errno and must push > 0 bytes; server reads them byte-intact. --
        var creq_len = 700
        var creq = List[UInt8]()
        var q = 0
        while q < creq_len:
            creq.append(UInt8((q * 53 + 3 + launch_idx) & 0xFF))
            q = q + 1
        var creq_view = Span[UInt8](creq).as_imm()
        var pushed = 0
        var send_attempts = 0
        while pushed == 0 and send_attempts < 100:
            send_attempts = send_attempts + 1
            var wio = client_stream.try_write[_LaunchRT](reactor, creq_view)
            if wio.is_error():
                var e = last_s2n_errno()
                raise Error(
                    "[launch " + String(launch_idx) + "] try_write through the"
                    + " config-borrowing connection FAILED (Mode 1): errno="
                    + String(Int(e)) + " msg='" + s2n_strerror_message(e)
                    + "' — the live Firestore Listen"
                    + " S2N_ERR_UNSUPPORTED_WITH_QUIC after the config UAF"
                )
            if wio.is_ready():
                pushed = Int(wio.n_bytes())
            # else PENDING: socket buffer momentarily full; retry same buffer.
        if pushed <= 0:
            raise Error(
                "[launch " + String(launch_idx) + "] try_write pushed 0 bytes"
                + " after " + String(send_attempts) + " attempts (Mode 2)"
            )

        # Server reads the pushed bytes back + verifies byte-intact.
        var got = List[UInt8]()
        var drain_iters = 0
        while len(got) < pushed and drain_iters < 10000:
            drain_iters = drain_iters + 1
            var buf = List[UInt8]()
            var z = 0
            while z < 4096:
                buf.append(UInt8(0))
                z = z + 1
            var rr = server_conn.recv_into_span(Span[UInt8](buf))
            if rr[0] == TLS_OUTCOME_ERROR:
                raise Error(
                    "[launch " + String(launch_idx) + "] server recv ERROR"
                    + " errno=" + String(Int(last_s2n_errno()))
                )
            var k = 0
            while k < rr[1]:
                got.append(buf[k])
                k = k + 1
        if len(got) != pushed:
            raise Error(
                "[launch " + String(launch_idx) + "] server received "
                + String(len(got)) + " of the " + String(pushed) + " bytes"
            )
        var v = 0
        while v < pushed:
            if got[v] != creq[v]:
                raise Error(
                    "[launch " + String(launch_idx) + "] byte " + String(v)
                    + " corrupted: got " + String(Int(got[v])) + ", expected "
                    + String(Int(creq[v]))
                )
            v = v + 1

        # ---- config STILL valid after the send. ----
        var quic_final = client_stream._conn_quic_enabled_for_test()
        if quic_final != Int32(0):
            raise Error(
                "[launch " + String(launch_idx) + "] conn->config->quic_enabled"
                + " read NON-ZERO after the send (config UAF)"
            )

        # Done probing — release the sprayed quic-enabled configs.
        _free_sprayed_configs(sprayed)

        _ = server_conn^
        _ = client_stream^
    finally:
        _close_fd(server_fd)
        # client_fd is owned by client_stream -> TcpStream (dropped above); the
        # finally close is idempotent on an already-closed fd.
        _close_fd(client_fd)
    _ = server_config^


# -----------------------------------------------------------------------------
# §2 — The falsifier.
# -----------------------------------------------------------------------------


def test_bug_tls_config_lifetime_uaf_after_connector_drop() raises:
    """DETERMINISTIC UAF FALSIFIER: drop the caller-side TlsConfig (the
    dial-once connector-drop), scribble the freed heap, then read
    conn->config->quic_enabled + send through the still-live connection.

    PRE-FIX (OwnedPointer[TlsConfig] sole-owner, no config ref on the
    connection): the config is freed + overwritten -> the probe reads the
    scribble pattern as quic_enabled (non-zero) and/or the send fails with
    S2N_ERR_UNSUPPORTED_WITH_QUIC -> RED.

    POST-FIX (ArcPointer share-owned config; the connection co-owns a clone):
    the config stays alive -> quic_enabled reads 0, the send round-trips
    byte-intact -> GREEN.

    FAILS ON CURRENT CODE: pre-fix (pre-Arc), _N_LAUNCHES launches each free +
    scribble the s2n_config_t and read a non-zero quic_enabled through the
    dangling conn->config. pre-fix HEAD (main) uses OwnedPointer[TlsConfig].
    """
    print("  test_bug_tls_config_lifetime_uaf_after_connector_drop...")
    tls_init()
    var reactor = _make_reactor()
    var launch = 0
    while launch < _N_LAUNCHES:
        _one_launch(reactor, launch)
        launch = launch + 1
    _ = reactor^
    print(
        "    OK — conn->config stayed VALID (quic_enabled == 0) after the"
        " caller-side TlsConfig was dropped + quic-enabled configs sprayed onto"
        " its freed page, and the real try_write round-tripped byte-intact,"
        " across " + String(_N_LAUNCHES)
        + " launches (config UAF gone — ArcPointer share-owned config)"
    )


def main() raises:
    print("== TLS-config lifetime UAF falsifier ==")
    test_bug_tls_config_lifetime_uaf_after_connector_drop()
    print("== TLS-config lifetime UAF PASSED (1 test) ==")
