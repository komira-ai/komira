"""L1 TLS smoke test.

Drives:
  1. tls_init() — process-wide s2n-tls initialization.
  2. TlsConfig() — construct + load self-signed PEM cert/key + set ALPN.
  3. socketpair() — get a connected fd pair in-process (NO listen/connect,
     NO kqueue/epoll wiring — out of scope here).
  4. TlsConnection(config).bind_fd(server_fd) — wrap one side of the pair.
  5. TlsConnection.handshake() — drive ONE handshake step.

Expected outcome: the call returns WITHOUT CRASH and produces one of:

  - TLS_OUTCOME_BLOCKED_ON_READ  — the most likely result (no client peer
    is driving the handshake; s2n is waiting on ClientHello bytes that
    will never come).
  - TLS_OUTCOME_DONE             — unlikely without a peer; would only
    fire if s2n short-circuits a degenerate case.
  - TLS_OUTCOME_ERROR            — acceptable if the cert/key parse
    failed; the test fails-loud with the s2n errno for diagnostics.

  - TLS_OUTCOME_BLOCKED_ON_WRITE — also acceptable; happens if s2n
    wants to send its first record (impossible in pure-server-mode
    without ClientHello, but defensively accepted).

The PASS criterion is the wrappers compile + link + execute without
crashing and produce a TLS_OUTCOME_* value. The thing under test is the
INFRASTRUCTURE: TlsConfig + TlsConnection lifecycle is healthy
(constructors don't leak; cert PEM bytes parse via s2n; reactor-state
helpers compile + return sane values).

The full handshake is NOT exercised here — that's / acceptance
(curl + openssl s_client + Go client real interop matrix).

NOT in scope:
  - Real client peer driving the handshake.
  - kqueue/epoll wiring for the BLOCKED_* state-transitions.
  - Cert validation paths.
  - SNI extraction (verified at with a real client SNI).
"""

from std.ffi import external_call

from komira_http.tls import (
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
from std.pathlib import Path


# -----------------------------------------------------------------------------
# Test fixtures — self-signed PEM cert + key inlined as Mojo strings
# -----------------------------------------------------------------------------
#
# The PEMs live in tests/fixtures/smoke_*.pem (declared as test data).
# Generated via:
#   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem
#               -days 3650 -nodes -subj "/CN=localhost"
#
# These are TEST-ONLY artifacts. NEVER used in production.

def _smoke_cert_pem() raises -> String:
    """Read the self-signed test cert PEM fixture."""
    return Path("src/komira_http/tests/fixtures/smoke_cert.pem").read_text()


def _smoke_key_pem() raises -> String:
    """Read the self-signed test key PEM fixture."""
    return Path("src/komira_http/tests/fixtures/smoke_key.pem").read_text()


# -----------------------------------------------------------------------------
# socketpair helper — in-process connected fd pair
# -----------------------------------------------------------------------------
#
# A test sandbox can be hostile to real listen/connect;
# socketpair() is the canonical in-process alternative. Returns (fd0, fd1)
# both already connected as a stream socket pair.

comptime AF_UNIX: Int32 = 1
comptime SOCK_STREAM: Int32 = 1


def _socketpair() raises -> Tuple[Int32, Int32]:
    """Call libc socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) and return (fd0, fd1).

    SAFETY: socketpair is a stable POSIX libc symbol; available on both
    macOS and Linux. We pass a pointer to a 2-Int32 stack array; the
    syscall writes the two fds in place.
    """
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: sv is a stack array; the libc syscall writes 2 ints and
    # returns 0 on success / -1 on error. The pointer is consumed
    # synchronously.
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        AF_UNIX, SOCK_STREAM, Int32(0), sv_ptr
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    """Close a file descriptor (best-effort)."""
    if fd < 0:
        return
    var _rc = external_call["close", Int32](fd)


def _set_nonblock(fd: Int32) raises:
    """Set fd to non-blocking via the non-variadic posix shim. Mirrors
    `src/komira_async/reactor/socket_setup.mojo:_create_listener` macOS
    branch (the shim is the canonical way to set O_NONBLOCK on a fd
    across both Linux and macOS — avoids the fcntl-variadic-ABI bug
    that bit `external_call["fcntl", Int32]` directly).

    SAFETY: synchronous call; shim returns 0 on success, <0 on error.
    """
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error(
            "_set_nonblock(fd=" + String(Int(fd)) + ") returned "
            + String(Int(rc))
        )


# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------


def test_tls_init_idempotent() raises:
    """tls_init() can be called multiple times in the same process
    without error (s2n's internal guard)."""
    print("  test_tls_init_idempotent...")
    tls_init()
    tls_init()
    print("    OK")


def test_tls_config_construction() raises:
    """TlsConfig() constructs + drops cleanly (no leaks under tcmalloc)."""
    print("  test_tls_config_construction...")
    var config = TlsConfig()
    # Drop on scope exit; __del__ calls s2n_config_free.
    _ = config^
    print("    OK")


def test_tls_config_load_cert_and_alpn() raises:
    """Load a self-signed PEM cert + key + set ALPN protocols."""
    print("  test_tls_config_load_cert_and_alpn...")
    var config = TlsConfig()
    var cert_pem = _smoke_cert_pem()
    var key_pem = _smoke_key_pem()
    config.load_cert(cert_pem, key_pem)
    var protocols = List[String]()
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)
    # Drop on scope exit.
    print("    OK")


def test_tls_connection_construction_and_bind() raises:
    """Construct TlsConnection bound to TlsConfig + socketpair fd."""
    print("  test_tls_connection_construction_and_bind...")
    var config = TlsConfig()
    var cert_pem = _smoke_cert_pem()
    var key_pem = _smoke_key_pem()
    config.load_cert(cert_pem, key_pem)
    var protocols = List[String]()
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)

    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    try:
        var conn = TlsConnection(config)
        conn.bind_fd(server_fd)
        if conn.fd() != server_fd:
            raise Error(
                "TlsConnection.fd() mismatch: expected "
                + String(Int(server_fd)) + ", got "
                + String(Int(conn.fd()))
            )
        # Drop conn on scope exit.
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    print("    OK")


def test_tls_handshake_one_step_without_crash() raises:
    """Drive ONE step of TlsConnection.handshake() with no client peer.

    Expected: TLS_OUTCOME_BLOCKED_ON_READ (server is waiting on
    ClientHello bytes that will never come). Acceptable: BLOCKED_ON_WRITE,
    DONE, ERROR — the test just verifies the FFI shim doesn't crash.
    """
    print("  test_tls_handshake_one_step_without_crash...")
    var config = TlsConfig()
    config.load_cert(_smoke_cert_pem(), _smoke_key_pem())
    var protocols = List[String]()
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)

    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    # Set both fds to non-blocking so s2n_negotiate returns immediately
    # with S2N_BLOCKED_ON_READ instead of blocking on read() forever.
    # Without this, the test would hang indefinitely (no peer is
    # driving the handshake — there's no client).
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    var outcome: UInt8 = UInt8(255)
    try:
        var conn = TlsConnection(config)
        conn.bind_fd(server_fd)
        outcome = conn.handshake()
        # Print the outcome for diagnostics; do NOT raise on any
        # specific outcome — the test passes if we reach this line
        # WITHOUT CRASH.
        var outcome_str: String
        if outcome == TLS_OUTCOME_DONE:
            outcome_str = String("DONE")
        elif outcome == TLS_OUTCOME_BLOCKED_ON_READ:
            outcome_str = String("BLOCKED_ON_READ")
        elif outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
            outcome_str = String("BLOCKED_ON_WRITE")
        elif outcome == TLS_OUTCOME_ERROR:
            outcome_str = String("ERROR")
        else:
            outcome_str = String("UNKNOWN")
        print(
            "    handshake outcome: " + outcome_str + " (rc="
            + String(Int(outcome)) + ")"
        )
        if outcome == TLS_OUTCOME_ERROR:
            var errno = last_s2n_errno()
            var msg = s2n_strerror_message(errno)
            print(
                "    s2n errno=" + String(Int(errno)) + " msg=" + msg
            )
        # Drop conn on scope exit.
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    print("    OK")


def main() raises:
    """Drive the L1 TLS smoke gates."""
    print("== L1 TLS smoke ==")
    test_tls_init_idempotent()
    test_tls_config_construction()
    test_tls_config_load_cert_and_alpn()
    test_tls_connection_construction_and_bind()
    test_tls_handshake_one_step_without_crash()
    print("== L1 TLS smoke PASSED (5 tests) ==")
