"""L1 client-mode construction smoke.

Drives:
  1. tls_init() — process-wide s2n-tls init.
  2. TlsConfig() — fresh client config (same shape as server; mode is
     a connection-level setting, not a config-level setting).
  3. TlsConfig.enable_verify_default() — documented no-op (default
     verifies; symbol does not exist in upstream s2n).
  4. TlsConfig.disable_verify() — does not raise.
  5. TlsConfig.add_trust_pem(root_ca_pem) — happy-path PEM load into
     trust store.
  6. TlsConfig.wipe_trust() — empties the trust store.
  7. TlsConfig.enable_session_tickets() — stub, no-op.
  8. TlsConnection.new_client(config) — constructs without crash;
     subsequent bind_fd to socketpair succeeds.
  9. TlsConnection.set_server_name("example.com") — does not raise.

Acceptance: every method on the new client-mode surface runs without
crash; the construction patterns hold under tcmalloc (no leak / no
double-free on drop).

NOT in scope: real handshake drive — that's the next test
(test_L1_tls_client_handshake_against_test_root.mojo).
"""

from std.ffi import external_call

from komira_http_core.tls import (
    TlsConfig,
    TlsConnection,
    tls_init,
)
from std.pathlib import Path


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _root_ca_pem() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/root_ca.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv_ptr
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd < 0:
        return
    var _rc = external_call["close", Int32](fd)


def test_client_config_enable_verify_default_is_noop() raises:
    """`enable_verify_default()` is a no-op; calling it must not raise
    and must not affect any subsequent operation."""
    print("  test_client_config_enable_verify_default_is_noop...")
    var config = TlsConfig()
    config.enable_verify_default()
    # Sanity: we can still do other operations on the config.
    config.enable_verify_default()
    _ = config^
    print("    OK")


def test_client_config_disable_verify() raises:
    """`disable_verify()` calls s2n_config_disable_x509_verification
    and does not raise on a fresh config."""
    print("  test_client_config_disable_verify...")
    var config = TlsConfig()
    config.disable_verify()
    _ = config^
    print("    OK")


def test_client_config_add_trust_pem_and_wipe() raises:
    """`add_trust_pem(root_ca)` parses the PEM into the trust store
    without error. `wipe_trust()` then empties the store; calling
    add_trust_pem after wipe also succeeds (full cycle)."""
    print("  test_client_config_add_trust_pem_and_wipe...")
    var config = TlsConfig()
    var root_pem = _root_ca_pem()
    config.add_trust_pem(root_pem)
    config.wipe_trust()
    # Add it back; verifies wipe didn't break the config.
    config.add_trust_pem(root_pem)
    _ = config^
    print("    OK")


def test_client_config_enable_session_tickets_stub() raises:
    """`enable_session_tickets()` is a stub no-op; must not raise."""
    print("  test_client_config_enable_session_tickets_stub...")
    var config = TlsConfig()
    config.enable_session_tickets()
    config.enable_session_tickets()
    _ = config^
    print("    OK")


def test_client_connection_new_client_construction() raises:
    """`TlsConnection.new_client(config)` constructs a client-mode
    connection without crash. The fd is unbound initially (-1)."""
    print("  test_client_connection_new_client_construction...")
    var config = TlsConfig()
    var conn = TlsConnection.new_client(config)
    if conn.fd() != Int32(-1):
        raise Error(
            "client conn fd should be -1 before bind_fd; got "
            + String(Int(conn.fd()))
        )
    _ = conn^
    _ = config^
    print("    OK")


def test_client_connection_bind_fd() raises:
    """`new_client(config).bind_fd(fd)` succeeds and stores the fd."""
    print("  test_client_connection_bind_fd...")
    var config = TlsConfig()
    var fds = _socketpair()
    var client_fd = fds[0]
    var server_fd = fds[1]
    try:
        var conn = TlsConnection.new_client(config)
        conn.bind_fd(client_fd)
        if conn.fd() != client_fd:
            raise Error(
                "TlsConnection.fd() mismatch after bind_fd: expected "
                + String(Int(client_fd)) + ", got "
                + String(Int(conn.fd()))
            )
        _ = conn^
    finally:
        _close_fd(client_fd)
        _close_fd(server_fd)
    print("    OK")


def test_client_connection_set_server_name() raises:
    """`set_server_name("example.com")` succeeds; multiple calls
    succeed (s2n allows re-setting before ClientHello flush)."""
    print("  test_client_connection_set_server_name...")
    var config = TlsConfig()
    var conn = TlsConnection.new_client(config)
    conn.set_server_name(String("example.com"))
    conn.set_server_name(String("other.example.com"))
    _ = conn^
    _ = config^
    print("    OK")


def main() raises:
    print("== L1 client construction ==")
    tls_init()
    test_client_config_enable_verify_default_is_noop()
    test_client_config_disable_verify()
    test_client_config_add_trust_pem_and_wipe()
    test_client_config_enable_session_tickets_stub()
    test_client_connection_new_client_construction()
    test_client_connection_bind_fd()
    test_client_connection_set_server_name()
    print(
        "== L1 client construction PASSED (7 sub-tests) =="
    )
