# komira's TLS client (the production `default_client_tls_config`, verifying
# against the fixture root) against a CPython `ssl` server (cpython_peer.py,
# OpenSSL in the pinned interpreter) that selects ALPN: its preference is
# `h2` then `http/1.1`. One TLS version per case, TLS 1.3 and TLS 1.2, each
# with the client offering `h2, http/1.1` and `http/1.1`.
#
# Per case: the handshake completes; komira's negotiated version is the one
# the server was pinned to, and is what CPython reports; the cipher suite
# komira reports is the one CPython reports (both use OpenSSL's name) and
# belongs to that version; the ALPN protocol is `h2` when the client offers
# it and `http/1.1` otherwise, on both sides; and an application round trip:
# komira sends `ping from komira`, CPython answers with its own report and
# `pong from cpython`, read back over TLS, and that report agrees with what it
# printed on stderr; komira closes with close_notify, and CPython exits 0
# only if it received one.
#
# This is the case bssl's s_server cannot make (it selects no ALPN): a
# client that offered a wrong protocol in place of `h2` (`h3`) would be
# given `http/1.1` here, and fail.

from std.testing import assert_equal, assert_true

from komira_http_core.tls import TlsConnection, tls_init
from komira_tls_interop_e2e import (
    LEAF_CERT_PATH,
    LEAF_KEY_PATH,
    LISTENING,
    ROOT_CA_PATH,
    SERVER_NAME,
    PeerGroup,
    client_tls_config,
    close_notify,
    connect_loopback,
    flag,
    handshake,
    is_tls13_suite,
    listening_port,
    parse_report,
    read_until,
    send_all,
    standard_cipher_name,
    start_cpython_peer,
    tls_version_name,
)

comptime _STEP_MS = 10_000
comptime _PONG = "pong from cpython\n"


def _case(python: String, version: String, offer_h2: Bool) raises:
    var name = "komira client -> cpython server " + version + (" alpn=h2,http/1.1" if offer_h2 else " alpn=http/1.1")
    var peers = PeerGroup()
    var args: List[String] = [
        "server", "--cert", String(LEAF_CERT_PATH), "--key", String(LEAF_KEY_PATH),
        "--version", version, "--alpn", "h2,http/1.1",
    ]
    var server = start_cpython_peer(peers, String("cpython server"), python, args)
    peers.wait_for_line(server, String(LISTENING), _STEP_MS)
    var port = listening_port(peers.stdout(server))
    var sock = connect_loopback(port, peers, server, _STEP_MS)
    var config = client_tls_config(ROOT_CA_PATH, offer_h2)
    var conn = TlsConnection.new_client(config)
    conn.bind_fd(sock.fd)
    conn.set_server_name(String(SERVER_NAME))
    var failed = handshake(conn, peers, server, _STEP_MS)
    if failed.byte_length() > 0:
        var o = peers.wait(server, _STEP_MS)
        raise Error(name + ": komira's handshake failed: " + failed + "\n" + o.describe())

    var komira_version = tls_version_name(conn.negotiated_tls_version())
    var komira_cipher = conn.negotiated_cipher()
    var alpn = conn.negotiated_protocol()
    var komira_alpn = alpn.value() if alpn else String("")

    send_all(conn, String("ping from komira\n"), peers, server, _STEP_MS)
    var answer = read_until(conn, String(_PONG), peers, server, _STEP_MS)
    close_notify(conn, peers, _STEP_MS)
    # The socket outlives every use of the connection bound to it (Mojo
    # would otherwise close it after its last named use, at bind_fd).
    _ = sock^
    var outcome = peers.wait(server, _STEP_MS)
    assert_true(outcome.ok(), name + ": the cpython server did not exit 0: " + outcome.describe())
    assert_true(answer.endswith(_PONG), name + ": the answer over TLS: '" + answer + "'")

    var over_tls = parse_report(answer)
    var on_stderr = parse_report(outcome.err)
    var expected_version = String("TLSv1.3") if version == "tls1.3" else String("TLSv1.2")
    var expected_alpn = String("h2") if offer_h2 else String("http/1.1")
    assert_equal(komira_version, expected_version, name + ": komira's version")
    assert_equal(on_stderr.version, expected_version, name + ": cpython's version")
    assert_equal(komira_cipher, on_stderr.cipher, name + ": komira's cipher against cpython's")
    assert_equal(is_tls13_suite(standard_cipher_name(komira_cipher)), version == "tls1.3", name + ": a " + version + " suite")
    assert_equal(komira_alpn, expected_alpn, name + ": komira's ALPN")
    assert_equal(on_stderr.alpn, expected_alpn, name + ": cpython's ALPN")
    assert_equal(over_tls.version, on_stderr.version, name + ": the answer's version")
    assert_equal(over_tls.cipher, on_stderr.cipher, name + ": the answer's cipher")
    assert_equal(over_tls.alpn, on_stderr.alpn, name + ": the answer's ALPN")
    print("  " + name + ": " + komira_version + " " + komira_cipher + " alpn=" + komira_alpn + " OK")


def main() raises:
    tls_init()
    var python = flag(String("python"))
    _case(python, String("tls1.3"), True)
    _case(python, String("tls1.3"), False)
    _case(python, String("tls1.2"), True)
    _case(python, String("tls1.2"), False)
    print("test_komira_client_vs_cpython_server PASS")
