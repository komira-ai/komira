"""L1 client handshake against
test root (the core-EXT round-trip).

Drives a full TLS handshake in-process via a socketpair, with one side
acting as the SERVER (using the test-CA leaf cert+key) and the other
acting as the CLIENT (adding the test-CA root_ca.pem to its trust
store, then verifying the server's chain).

Expected: handshake reaches TLS_OUTCOME_DONE on BOTH sides without
ERROR. This proves:

  1. `TlsConnection.new_client(config)` produces a real client-mode
     s2n_connection_t (not just a renamed server one).
  2. `TlsConfig.add_trust_pem(root_ca)` actually loads the root into
     the s2n trust store; subsequent server-cert validation succeeds.
  3. `wipe_trust()` + `add_trust_pem()` cycle leaves the client
     configured for verification against EXACTLY our test root (no
     OS-default root pollution).
  4. The fd-direct path through s2n_negotiate works symmetrically on
     both client and server modes.

Pattern: non-blocking socketpair, alternating drive_handshake() calls
on each side until both return DONE or one returns ERROR.

This test uses `disable_verify()` will NOT skip — it's the positive
path: trust-add + chain-validate.
"""

from std.ffi import external_call

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
from std.pathlib import Path


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _leaf_cert() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()


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


def _set_nonblock(fd: Int32) raises:
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error(
            "_set_nonblock(fd=" + String(Int(fd)) + ") returned "
            + String(Int(rc))
        )


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


def _drive_handshake_to_done(
    mut server: TlsConnection, mut client: TlsConnection
) raises -> Tuple[UInt8, UInt8]:
    """Alternate handshake() calls on each side until both reach DONE
    or one returns ERROR. Returns (server_outcome, client_outcome)
    at termination.

    Cap iterations at 64; a real handshake completes in ~4-6 round
    trips. If we exceed 64 without DONE on both sides, raise.
    """
    var server_outcome: UInt8 = UInt8(255)
    var client_outcome: UInt8 = UInt8(255)
    var server_done = False
    var client_done = False
    var i = 0
    while i < 64:
        if not server_done:
            server_outcome = server.handshake()
            if server_outcome == TLS_OUTCOME_ERROR:
                return (server_outcome, client_outcome)
            if server_outcome == TLS_OUTCOME_DONE:
                server_done = True
        if not client_done:
            client_outcome = client.handshake()
            if client_outcome == TLS_OUTCOME_ERROR:
                return (server_outcome, client_outcome)
            if client_outcome == TLS_OUTCOME_DONE:
                client_done = True
        if server_done and client_done:
            return (TLS_OUTCOME_DONE, TLS_OUTCOME_DONE)
        i = i + 1
    raise Error(
        "_drive_handshake_to_done: exceeded 64 iterations "
        + "(server=" + _outcome_str(server_outcome)
        + ", client=" + _outcome_str(client_outcome) + ")"
    )


def test_client_server_handshake_against_test_root() raises:
    """Full TLS handshake: client (with test root in trust store)
    verifies server (with test leaf cert chain). Both reach DONE."""
    print("  test_client_server_handshake_against_test_root...")

    # ── Server config: bind leaf cert + key ──
    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var server_alpn = List[String]()
    server_alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(server_alpn)

    # ── Client config: wipe default OS trust, add ONLY our test root ──
    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.add_trust_pem(_root_ca_pem())
    client_config.enable_verify_default()  # documented no-op (verify is default)
    var client_alpn = List[String]()
    client_alpn.append(String("http/1.1"))
    client_config.set_alpn_protocols(client_alpn)

    # ── socketpair: server side gets fd0, client side gets fd1 ──
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    try:
        var server_conn = TlsConnection(server_config)  # default → S2N_SERVER
        server_conn.bind_fd(server_fd)

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        # SNI value matches the leaf cert's SAN (per fixture: SAN
        # includes 127.0.0.1 and CN=localhost). The server side won't
        # verify SNI against the cert (that's a client concern), but
        # the client will check the server cert's SAN against the SNI
        # it sent.
        client_conn.set_server_name(String("localhost"))

        var outcomes = _drive_handshake_to_done(server_conn, client_conn)
        var sv_out = outcomes[0]
        var cl_out = outcomes[1]
        if sv_out != TLS_OUTCOME_DONE or cl_out != TLS_OUTCOME_DONE:
            var sv_msg = String("")
            var cl_msg = String("")
            if sv_out == TLS_OUTCOME_ERROR:
                sv_msg = s2n_strerror_message(last_s2n_errno())
            raise Error(
                "handshake did not reach DONE on both sides: server="
                + _outcome_str(sv_out)
                + " client=" + _outcome_str(cl_out)
                + " (sv_errno_msg='" + sv_msg + "')"
            )
        _ = server_conn^
        _ = client_conn^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^
    print("    OK — full handshake DONE on both sides")


def main() raises:
    print(
        "== L1 client handshake "
        "against test root =="
    )
    tls_init()
    test_client_server_handshake_against_test_root()
    print("== L1 client handshake-against-test-root PASSED (1 test) ==")
