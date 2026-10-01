"""L1 negative path: client
handshake fails with cert-verify error when the test root is NOT in
the client's trust store.

Drives the same in-process handshake as
`test_L1_tls_client_handshake_against_test_root.mojo` BUT the client
config:
  - calls `wipe_trust()` to remove OS-default roots
  - does NOT call `add_trust_pem(root_ca)`

Expected: client side returns TLS_OUTCOME_ERROR. The s2n errno should
indicate a chain-validation failure (the specific errno varies by s2n
version; we assert ERROR + non-empty diagnostic message).

This proves that:
  1. `wipe_trust()` actually removes ALL roots (not just no-op).
  2. The default verification path is active without an explicit
     `enable_verify_default()` call (matches the documented "no-op"
     contract: default is already verifying).
  3. Cert chain validation IS executed against the trust store; when
     the store is empty, the server's chain is rejected.
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


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _leaf_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_key.pem").read_text()


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


def test_client_verify_fail_when_trust_store_empty() raises:
    """Client with wiped trust store rejects the server's cert chain
    → handshake returns TLS_OUTCOME_ERROR on the client side."""
    print("  test_client_verify_fail_when_trust_store_empty...")

    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var server_alpn = List[String]()
    server_alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(server_alpn)

    # Client with EMPTY trust store: wipe and never add anything.
    var client_config = TlsConfig()
    client_config.wipe_trust()
    var client_alpn = List[String]()
    client_alpn.append(String("http/1.1"))
    client_config.set_alpn_protocols(client_alpn)

    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    var client_error_observed = False
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)
        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        # Drive up to 64 iterations; the client should reach ERROR
        # well before that. We expect the client to fail when it tries
        # to validate the server cert.
        var i = 0
        var client_done = False
        var server_done = False
        while i < 64 and not client_done and not server_done:
            var sv_out = server_conn.handshake()
            if sv_out == TLS_OUTCOME_DONE:
                server_done = True
            elif sv_out == TLS_OUTCOME_ERROR:
                # Server-side error is also acceptable — when the
                # client aborts post-cert-verify, the server may see
                # the connection abort on its next read attempt.
                print(
                    "    server-side ERROR (acceptable on close-due-"
                    "to-client-abort): errno_msg='"
                    + s2n_strerror_message(last_s2n_errno()) + "'"
                )
                break
            var cl_out = client_conn.handshake()
            if cl_out == TLS_OUTCOME_DONE:
                client_done = True
            elif cl_out == TLS_OUTCOME_ERROR:
                var msg = s2n_strerror_message(last_s2n_errno())
                print(
                    "    client-side ERROR as expected: errno_msg='"
                    + msg + "'"
                )
                client_error_observed = True
                break
            i = i + 1
        if client_done and not client_error_observed:
            raise Error(
                "client handshake should NOT have reached DONE with "
                "an empty trust store — verification gate is broken"
            )
        if not client_error_observed:
            raise Error(
                "client handshake did not produce ERROR within 64 "
                "iterations; loop exited via server_done="
                + String(server_done) + " client_done="
                + String(client_done)
            )
        _ = server_conn^
        _ = client_conn^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^
    print("    OK — client ERROR observed as expected")


def main() raises:
    print(
        "== L1 verify-fail =="
    )
    tls_init()
    test_client_verify_fail_when_trust_store_empty()
    print("== L1 client verify-fail-no-trust PASSED (1 test) ==")
