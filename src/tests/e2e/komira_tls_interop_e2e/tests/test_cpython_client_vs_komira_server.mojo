# A CPython `ssl` client (cpython_peer.py, OpenSSL in the pinned interpreter)
# against komira's TLS server (the fixture leaf, "default_tls13", ALPN `h2`
# then `http/1.1`), the client pinned to one TLS version per case: TLS 1.3
# and TLS 1.2, each offering ALPN `h2,http/1.1`, `http/1.1`, and
# `http/1.1,h2`. CPython verifies komira's chain against the fixture root
# alone, with ssl.create_default_context (certificate required, the name
# `localhost` checked, VERIFY_X509_STRICT).
#
# Per case: the handshake completes on both sides; komira's negotiated
# version is the one the client was pinned to, and is what CPython reports;
# the cipher suite komira reports is the one CPython reports (both use
# OpenSSL's name) and belongs to that version; the ALPN protocol is the
# server's choice on both sides: `h2` whenever the client offers it, in
# either order (the server's preference wins, not the client's), and
# `http/1.1` otherwise; and an application round trip: CPython sends
# `ping from cpython`, komira reads it over TLS, answers `pong from komira`
# and closes with close_notify; CPython prints what it read, exactly, and
# exits 0 only on the close_notify.

from std.testing import assert_equal, assert_true

from komira_http_core.tls import TlsConnection, tls_init
from komira_tls_interop_e2e import (
    ROOT_CA_PATH,
    SERVER_NAME,
    PeerGroup,
    accept_one,
    close_notify,
    flag,
    handshake,
    is_tls13_suite,
    listen_loopback,
    local_port,
    parse_report,
    read_until,
    send_all,
    server_tls_config,
    standard_cipher_name,
    start_cpython_peer,
    tls_version_name,
)

comptime _STEP_MS = 10_000
comptime _PING = "ping from cpython\n"
comptime _PONG = "pong from komira\n"


def _case(python: String, version: String, offer: String, expected_alpn: String) raises:
    var name = "cpython client " + version + " alpn=" + offer + " -> komira server"
    var peers = PeerGroup()
    var listener = listen_loopback()
    var port = local_port(listener)
    var args: List[String] = [
        "client", "--port", String(Int(port)), "--ca", String(ROOT_CA_PATH), "--server-name", String(SERVER_NAME),
        "--version", version, "--alpn", offer,
    ]
    var client = start_cpython_peer(peers, String("cpython client"), python, args)
    var sock = accept_one(listener, peers, client, _STEP_MS)
    var config = server_tls_config()
    var conn = TlsConnection(config)
    conn.bind_fd(sock.fd)
    var failed = handshake(conn, peers, client, _STEP_MS)
    if failed.byte_length() > 0:
        var o = peers.wait(client, _STEP_MS)
        raise Error(name + ": komira's handshake failed: " + failed + "\n" + o.describe())

    var komira_version = tls_version_name(conn.negotiated_tls_version())
    var komira_cipher = conn.negotiated_cipher()
    var alpn = conn.negotiated_protocol()
    var komira_alpn = alpn.value() if alpn else String("")

    var got = read_until(conn, String("\n"), peers, client, _STEP_MS)
    assert_equal(got, String(_PING), name + ": what komira read over TLS")
    send_all(conn, String(_PONG), peers, client, _STEP_MS)
    close_notify(conn, peers, _STEP_MS)
    # The socket outlives every use of the connection bound to it (Mojo
    # would otherwise close it after its last named use, at bind_fd).
    _ = sock^
    var outcome = peers.wait(client, _STEP_MS)
    assert_true(outcome.ok(), name + ": the cpython client did not exit 0: " + outcome.describe())
    assert_equal(outcome.out, String(_PONG), name + ": what cpython read over TLS")

    var report = parse_report(outcome.err)
    var expected_version = String("TLSv1.3") if version == "tls1.3" else String("TLSv1.2")
    assert_equal(komira_version, expected_version, name + ": komira's version")
    assert_equal(report.version, expected_version, name + ": cpython's version")
    assert_equal(komira_cipher, report.cipher, name + ": komira's cipher against cpython's")
    assert_equal(is_tls13_suite(standard_cipher_name(komira_cipher)), version == "tls1.3", name + ": a " + version + " suite")
    assert_equal(komira_alpn, expected_alpn, name + ": komira's ALPN")
    assert_equal(report.alpn, expected_alpn, name + ": cpython's ALPN")
    print("  " + name + ": " + komira_version + " " + komira_cipher + " alpn=" + komira_alpn + " OK")


def main() raises:
    tls_init()
    var python = flag(String("python"))
    for v in [String("tls1.3"), String("tls1.2")]:
        _case(python, v, String("h2,http/1.1"), String("h2"))
        _case(python, v, String("http/1.1"), String("http/1.1"))
        _case(python, v, String("http/1.1,h2"), String("h2"))
    print("test_cpython_client_vs_komira_server PASS")
