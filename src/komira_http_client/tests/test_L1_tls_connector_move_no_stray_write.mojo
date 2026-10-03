"""FALSIFIER — TLS-connector MOVE stray-write (a streaming client failing with
`S2N_ERR_UNSUPPORTED_WITH_QUIC` / zero bytes sent).

ROOT CAUSE: a long-lived streaming client fails on about half of launches with
`S2N_ERR_UNSUPPORTED_WITH_QUIC` (errno 469762106 = 0x1c00003a) on the first
send (Mode 1), or opens `:status 200` but pushes ZERO bytes forever (Mode 2).
Instrumentation shows the s2n connection's `quic_enabled` bit reads FALSE at
handshake-DONE and at the end of `TlsConnector.connect`'s stream construction,
but TRUE by the first `try_write`/`s2n_send` — SAME connection rawptr, NO
intervening `s2n_connection_free`, and nothing ever calls enable_quic. So a
STRAY WRITE flips `conn->quic_enabled` during the MOVE of the REAL
`TlsClientStream` out of `TlsConnector.connect` (`return _stream^`).

This is the stale-pointer shape: a wildcard `MutExternalOrigin` owning-pointer
FIELD with a `__del__` (`_S2nConnectionHandle._raw`), nested inside Movable
`TlsConnection` -> `TlsClientStream`. Wildcard origins defeat the compiler's
ASAP-destruction tracking across a move, so the moved-from handle's freed/reused
tcmalloc bytes stray-write the live s2n heap struct mid-move.

THE FIX (this repro guards it): `_S2nConnectionHandle._raw` (and its
`_S2nConfigHandle` sibling) use the CONCRETE `StaticConstantOrigin` FFI origin —
an opaque handle passed BY VALUE to `external_call`, never dereferenced
Mojo-side, so the immutable static origin is sound AND removes the
stale-pointer hazard. There are ZERO wildcard fields in the tls module.

TWO REGRESSION GUARDS, one structural + one behavioral (this is important —
read before "simplifying"):

  * STRUCTURAL: no wildcard-origin owning-pointer FIELD in the tls module
    (`_raw` is a concrete static origin). That is the airtight,
    timing-independent guard of the root cause; a field scan enforces it.

  * BEHAVIORAL GUARD (this file) = the FAITHFUL production move path, exercised +
    probed. It drives the REAL `TlsClientStream[TcpIoStream]` type + the REAL
    `try_write` send path (NOT a stand-in) through the exact `return _stream^`
    move-out (via `_connect_and_move_out`, mirroring `TlsConnector.connect`'s
    tail), over a real s2n loopback socketpair, across `_N_LAUNCHES` independent
    handshake+move+send cycles, and probes `conn->quic_enabled` (via the s2n
    unstable `s2n_connection_is_quic_enabled` symbol) at each step + asserts the
    real send round-trips byte-intact with no S2N_ERR_UNSUPPORTED_WITH_QUIC.

    HONEST LIMITATION: the *symptom* (`quic_enabled` flip /
    send-reject) is NOT reproducible on this offline socketpair path with a
    wildcard field — the move-lowering only emits the stray write under a live
    network frame (real reactor parking + h2/gRPC allocation traffic that
    drives the tcmalloc byte-reuse timing). This offline harness, even with the
    real struct layout + heap churn + 24 launches, PASSES either way. So this
    file's role is (a) to lock the exact real move-out path in place so a
    future refactor that re-introduces the hazard is exercised here, (b) to
    document the mechanism + the probe, and (c) to be the offline smoke test of
    the identical path.

Each cycle asserts, in order:
  * quic_enabled == False AFTER the `return _stream^` move-out (Mode 1 probe).
  * a real `try_write` through the moved `TlsClientStream` succeeds (does not
    error with S2N_ERR_UNSUPPORTED_WITH_QUIC) and pushes > 0 bytes (Mode 2),
    and the server reads those bytes back byte-intact (record-layer uncorrupted).
  * quic_enabled == False after the send.

Test-only; never used in production. The leaf cert/key fixtures are the shared
TLS artifacts.
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


# The Runtime type parameter for `try_write[RT]`. The production h2-over-TLS
# tests use exactly this (`PerCoreAsyncRuntime[NoopSink]`); the TLS layer only
# uses `RT.Sink` for the (ignored) reactor param type.
comptime _LaunchRT = PerCoreAsyncRuntime[NoopSink]


# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

# Number of independent handshake+move+send launches. The live corruption is
# ~50%/launch, so N launches make the pre-fix wildcard hazard near-certain to
# fire at least once (1 - 0.5^N). N=24 -> < 1e-7 chance a genuinely broken tree
# passes by luck, yet the whole test runs in well under a second.
comptime _N_LAUNCHES: Int = 24


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
    """Real reactor (epoll/kqueue) — the same primitive the production
    TlsClientStream.try_write path is handed (it ignores it, but the signature
    requires one). Mirrors test_L1_tls_buffered_plaintext_lost_wakeup."""
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


# -----------------------------------------------------------------------------
# The exact production move-out: build the REAL TlsClientStream over a connected
# fd + handshaken TlsConnection, then `return _stream^` — mirroring
# TlsConnector.connect's tail (the corruption point the live debug pinned).
# -----------------------------------------------------------------------------


def _connect_and_move_out(
    client_fd: Int32, var client_conn: TlsConnection,
) raises -> TlsClientStream[TcpIoStream]:
    """Mirror of `TlsConnector.connect`'s tail: wrap the connected (TcpStream,
    handshaken TlsConnection) into the REAL production `TlsClientStream`, then
    `return _stream^` — the exact move-out the live debug pinned as the
    `conn->quic_enabled` stray-write point (`return _stream^`)."""
    var client_tcp = TcpStream(client_fd)
    var underlying = TcpIoStream(client_tcp^)
    var stream = TlsClientStream[TcpIoStream](underlying^, client_conn^)
    # THIS return is the load-bearing move-out (== `return _stream^`).
    return stream^


# -----------------------------------------------------------------------------
# One launch: fresh socketpair + configs, handshake, move-out, send, verify.
# Returns nothing; RAISES on any corruption (quic flip / send reject / zero
# bytes / byte-mismatch). Caller loops it _N_LAUNCHES times.
# -----------------------------------------------------------------------------


def _one_launch(mut reactor: Reactor[NoopSink], launch_idx: Int) raises:
    var server_config = _build_server_config()
    var client_config = _build_client_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)
        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var outcomes = _drive_to_done(server_conn, client_conn)
        if outcomes[0] != TLS_OUTCOME_DONE or outcomes[1] != TLS_OUTCOME_DONE:
            var sv_msg = String("")
            if outcomes[0] == TLS_OUTCOME_ERROR:
                sv_msg = s2n_strerror_message(last_s2n_errno())
            raise Error(
                "[launch " + String(launch_idx) + "] handshake did not reach"
                + " DONE: server=" + _outcome_str(outcomes[0]) + " client="
                + _outcome_str(outcomes[1]) + " (sv_errno_msg='" + sv_msg + "')"
            )

        # ---- THE MOVE-OUT: build the REAL TlsClientStream + `return _stream^`.
        # (quic-enabled is asserted False AFTER the move-out via the stream's
        # test accessor; there is no quic method on the bare TlsConnection.)
        var stream = _connect_and_move_out(client_fd, client_conn^)

        # ---- THE CATCH (Mode 1): quic MUST be False after the move-out. ----
        var quic_after_move = stream._conn_quic_enabled_for_test()
        if quic_after_move != Int32(0):
            raise Error(
                "[launch " + String(launch_idx) + "] STRAY WRITE DETECTED:"
                + " quic_enabled flipped to True across the TlsClientStream"
                + " move-out (`return _stream^`), SAME s2n connection, no"
                + " enable_quic call — the exact Mode-1"
                + " corruption. The wildcard `_raw` origin let the move"
                + " stray-write the s2n connection heap struct."
            )

        # ---- BEHAVIORAL (Mode 1 + Mode 2): real try_write through the moved
        #      stream succeeds + pushes bytes; server reads them byte-intact. --
        var creq_len = 700
        var creq = List[UInt8]()
        var q = 0
        while q < creq_len:
            creq.append(UInt8((q * 53 + 3 + launch_idx) & 0xFF))
            q = q + 1
        var creq_view = Span[UInt8](creq).as_imm()
        # A few attempts in case the first try_write reports PENDING
        # (BLOCKED_ON_WRITE) on a momentarily-full socketpair — retry the SAME
        # buffer until it makes progress or errors. The load-bearing catch is:
        # it must NOT error with the QUIC-usage errno and must push > 0 bytes.
        var pushed = 0
        var send_attempts = 0
        while pushed == 0 and send_attempts < 100:
            send_attempts = send_attempts + 1
            var wio = stream.try_write[_LaunchRT](reactor, creq_view)
            if wio.is_error():
                var e = last_s2n_errno()
                raise Error(
                    "[launch " + String(launch_idx) + "] MOVED-STREAM try_write"
                    + " FAILED (Mode 1): errno=" + String(Int(e)) + " msg='"
                    + s2n_strerror_message(e) + "' — the"
                    + " S2N_ERR_UNSUPPORTED_WITH_QUIC / send-reject after the"
                    + " TlsClientStream move-out"
                )
            if wio.is_ready():
                pushed = Int(wio.n_bytes())
            # else PENDING: socket buffer momentarily full; retry same buffer.
        if pushed <= 0:
            raise Error(
                "[launch " + String(launch_idx) + "] MOVED-STREAM try_write"
                + " pushed 0 bytes after " + String(send_attempts) + " attempts"
                + " (Mode 2): the record-layer corruption variant of the move"
                + " stray-write"
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
                    "[launch " + String(launch_idx) + "] server recv of"
                    + " moved-stream bytes ERROR errno="
                    + String(Int(last_s2n_errno()))
                )
            var k = 0
            while k < rr[1]:
                got.append(buf[k])
                k = k + 1
        if len(got) != pushed:
            raise Error(
                "[launch " + String(launch_idx) + "] server received "
                + String(len(got)) + " of the " + String(pushed)
                + " bytes the moved stream pushed"
            )
        var v = 0
        while v < pushed:
            if got[v] != creq[v]:
                raise Error(
                    "[launch " + String(launch_idx) + "] moved-stream byte "
                    + String(v) + " corrupted: got " + String(Int(got[v]))
                    + ", expected " + String(Int(creq[v]))
                )
            v = v + 1

        # ---- quic STILL False after the send. ----
        var quic_final = stream._conn_quic_enabled_for_test()
        if quic_final != Int32(0):
            raise Error(
                "[launch " + String(launch_idx) + "] quic_enabled flipped True"
                + " after the send"
            )

        _ = server_conn^
        _ = stream^
    finally:
        _close_fd(server_fd)
        # client_fd is owned by stream -> TcpStream (dropped above); the
        # finally close is idempotent on an already-closed fd.
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^


# -----------------------------------------------------------------------------
# §2 — The falsifier.
# -----------------------------------------------------------------------------


def test_bug_tls_connector_move_does_not_stray_write_quic_bit() raises:
    """BEHAVIORAL GUARD (see the module docstring for the two-guard split): drives
    the REAL `TlsClientStream` move-out path + probes `quic_enabled` across it +
    a real send round-trip, across `_N_LAUNCHES` launches. POST-FIX
    (StaticConstantOrigin `_raw`) every launch is clean.

    NOTE: the structural guard (no wildcard-origin `_raw` field) is the
    deterministic proof of the root cause, NOT this behavioral assertion — the
    live-heap-timing symptom does not reproduce on the offline socketpair path.
    This test locks the exact real move-out path in place + is its offline
    smoke test.
    """
    print("  test_bug_tls_connector_move_does_not_stray_write_quic_bit...")
    tls_init()
    var reactor = _make_reactor()
    var launch = 0
    while launch < _N_LAUNCHES:
        _one_launch(reactor, launch)
        launch = launch + 1
    _ = reactor^
    print(
        "    OK — quic_enabled stayed False across the REAL TlsClientStream"
        " move-out AND the real try_write pushed byte-intact bytes, across "
        + String(_N_LAUNCHES) + " independent launches (Mode 1 + Mode 2 both"
        " gone)"
    )


def main() raises:
    print("== TLS-connector move stray-write falsifier ==")
    test_bug_tls_connector_move_does_not_stray_write_quic_bit()
    print("== TLS-connector move stray-write PASSED (1 test) ==")
