"""L1 hostname verification: a trusted chain is NOT enough, the leaf must also
name the server the client meant to reach.

Every generated cloud client depends on this and nothing else tested it. The
only negative TLS test (`test_L1_tls_client_verify_fail_no_trust`) covers an
UNTRUSTED ROOT; here the root IS trusted (the test CA is the only trust anchor)
and only the NAME differs. The fixture leaf carries SANs `localhost` and
`127.0.0.1`, so it answers for those and nothing else.

  (a) SNI `evil.example` against that leaf: the client handshake must ERROR.
  (b) No server name at all (the 2-arg `TlsConnector` ctor never calling
      `set_server_name_for_next_connect`, so the connection never calls
      `set_server_name`): the client must fail CLOSED, not skip the name check.
      Whether s2n does is a reading of s2n, so this is the measurement.
  (c) Control: SNI `localhost` completes, so (a) and (b) fail because of the
      name and not because of a broken fixture.
  (d) The connector layer: `build_unpinned_public_ca_tls_connector` has no
      name until `HttpClient` pushes the URL host with `set_dial_host`, and
      then presents exactly that host (the value the handshake in (a) and (c)
      verifies against). A PINNED connector keeps its pinned name.
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

from komira_http_client.tls_connector import (
    build_unpinned_public_ca_tls_connector,
)


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


def _handshake(sni: String, set_sni: Bool) raises -> Tuple[UInt8, UInt8]:
    """Handshake a server holding the fixture leaf against a client trusting
    ONLY the fixture root. Returns (server_outcome, client_outcome)."""
    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(alpn)

    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.add_trust_pem(_root_ca_pem())
    client_config.enable_verify_default()
    var client_alpn = List[String]()
    client_alpn.append(String("http/1.1"))
    client_config.set_alpn_protocols(client_alpn)

    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    var outcomes = Tuple[UInt8, UInt8](UInt8(255), UInt8(255))
    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)
        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        if set_sni:
            client_conn.set_server_name(sni)
        outcomes = _drive_handshake_to_done(server_conn, client_conn)
        _ = server_conn^
        _ = client_conn^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^
    return outcomes


def test_wrong_hostname_fails_handshake() raises:
    print("  test_wrong_hostname_fails_handshake...")
    var o = _handshake(String("evil.example"), True)
    if o[1] == TLS_OUTCOME_DONE:
        raise Error(
            "client completed a handshake for evil.example against a leaf "
            "that only names localhost / 127.0.0.1 — hostname verification "
            "is not happening"
        )
    if o[1] != TLS_OUTCOME_ERROR:
        raise Error("client outcome was " + _outcome_str(o[1]) + ", want ERROR")
    print("    OK — ERROR: '" + s2n_strerror_message(last_s2n_errno()) + "'")


def test_empty_server_name_fails_closed() raises:
    """The connector must refuse a VERIFY_PEER dial with no server name (s2n
    itself installs no host verifier without one). Raised before any dial,
    so no reactor or socket is needed."""
    print("  test_empty_server_name_fails_closed...")
    var c = build_unpinned_public_ca_tls_connector()
    var refused = False
    try:
        c._refuse_unverifiable_peer()
    except e:
        refused = True
    if not refused:
        raise Error(
            "VERIFY_PEER connector with NO server name was not refused — "
            "the hostname check would be skipped"
        )
    c.set_dial_host(String("example.com"))
    c._refuse_unverifiable_peer()  # named: must not raise
    print("    OK")


def test_matching_hostname_completes_control() raises:
    print("  test_matching_hostname_completes_control...")
    var o = _handshake(String("localhost"), True)
    if o[0] != TLS_OUTCOME_DONE or o[1] != TLS_OUTCOME_DONE:
        raise Error(
            "control failed: localhost must complete (server="
            + _outcome_str(o[0]) + " client=" + _outcome_str(o[1]) + ")"
        )
    print("    OK")


def test_unpinned_connector_presents_the_url_host() raises:
    print("  test_unpinned_connector_presents_the_url_host...")
    var c = build_unpinned_public_ca_tls_connector()
    if c.server_name() != String(""):
        raise Error("unpinned connector must start with no name")
    c.set_dial_host(String("bucket.s3.us-east-1.amazonaws.com"))
    if c.server_name() != String("bucket.s3.us-east-1.amazonaws.com"):
        raise Error("unpinned connector must present the pushed URL host")
    c.set_dial_host(String("other.example.com"))
    if c.server_name() != String("other.example.com"):
        raise Error("the next request's host must replace the previous one")

    var pinned = build_unpinned_public_ca_tls_connector()
    pinned.set_server_name_for_next_connect(String("pinned.example.com"))
    pinned.set_dial_host(String("url-host.example.com"))
    if pinned.server_name() != String("pinned.example.com"):
        raise Error("a pinned name must not be overwritten by the URL host")
    print("    OK")


def main() raises:
    print("== L1 hostname verification ==")
    tls_init()
    test_matching_hostname_completes_control()
    test_wrong_hostname_fails_handshake()
    test_empty_server_name_fails_closed()
    test_unpinned_connector_presents_the_url_host()
    print("== L1 hostname verification PASSED (4 tests) ==")
