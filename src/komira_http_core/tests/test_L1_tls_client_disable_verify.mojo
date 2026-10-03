"""L1 disable_verify path:
client connects to server with `disable_verify()`, EMPTY trust store,
and handshake STILL reaches DONE because verification is OFF.

Drives the same in-process handshake as the positive test BUT the
client config:
  - calls `wipe_trust()` (no roots)
  - calls `disable_verify()` (turn off X.509 chain validation)
  - does NOT add any cert to the trust store

Expected: handshake reaches DONE on both sides. This proves that
`disable_verify()` actually disables the chain-validation gate, which
is the canonical pattern for self-signed test fixtures.

Inverse of `test_L1_tls_client_verify_fail_no_trust.mojo` — the only
difference is the `disable_verify()` call.
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


def _drive_to_done(
    mut server: TlsConnection, mut client: TlsConnection
) raises -> Tuple[UInt8, UInt8]:
    var sv_out: UInt8 = UInt8(255)
    var cl_out: UInt8 = UInt8(255)
    var sv_done = False
    var cl_done = False
    var i = 0
    while i < 64:
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
        "_drive_to_done: exceeded 64 iterations "
        + "(server=" + _outcome_str(sv_out)
        + ", client=" + _outcome_str(cl_out) + ")"
    )


def test_client_disable_verify_handshake_succeeds() raises:
    """Client with disable_verify() + empty trust store reaches DONE
    against the test-CA leaf server cert (which it would otherwise
    reject as untrusted)."""
    print("  test_client_disable_verify_handshake_succeeds...")

    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var server_alpn = List[String]()
    server_alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(server_alpn)

    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.disable_verify()  # the critical line
    var client_alpn = List[String]()
    client_alpn.append(String("http/1.1"))
    client_config.set_alpn_protocols(client_alpn)

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
        var sv_out = outcomes[0]
        var cl_out = outcomes[1]
        if sv_out != TLS_OUTCOME_DONE or cl_out != TLS_OUTCOME_DONE:
            var sv_msg = String("")
            var cl_msg = String("")
            if sv_out == TLS_OUTCOME_ERROR:
                sv_msg = s2n_strerror_message(last_s2n_errno())
            raise Error(
                "disable_verify handshake did not reach DONE: server="
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
    print("    OK — handshake DONE with disable_verify + empty trust")


def main() raises:
    print(
        "== L1 disable_verify =="
    )
    tls_init()
    test_client_disable_verify_handshake_succeeds()
    print("== L1 client disable-verify PASSED (1 test) ==")
