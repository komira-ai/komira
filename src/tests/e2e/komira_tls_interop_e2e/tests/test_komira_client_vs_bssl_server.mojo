# komira's TLS client (the production `default_client_tls_config`, verifying
# against the fixture root) against `bssl s_server -www`, aws-lc's server,
# pinned to one TLS version per case: TLS 1.3 and TLS 1.2, each with the
# client offering ALPN `h2, http/1.1` and `http/1.1`.
#
# Per case: the handshake completes; komira's negotiated version is the one
# the server was pinned to, and is what bssl reports; the cipher suite komira
# reports is the one bssl reports, by name, and belongs to that version; and
# an application byte round trip: komira sends `GET / HTTP/1.0`, the server
# answers (it answers only a request starting `GET `) with an HTTP/1.0 200
# carrying its own view of the connection, read back over TLS, and that view
# agrees with what bssl printed on stderr. bssl's s_server has no ALPN
# support (aws-lc 1.39.0 offers no option to select a protocol), so on both
# sides no protocol is negotiated whatever the client offers: komira reports
# none and bssl prints an empty `ALPN protocol:`.

from std.testing import assert_equal, assert_true

from komira_http_core.tls import TlsConnection, tls_init
from komira_tls_interop_e2e import (
    LEAF_CERT_PATH,
    LEAF_KEY_PATH,
    ROOT_CA_PATH,
    SERVER_NAME,
    PeerGroup,
    client_tls_config,
    connect_loopback,
    flag,
    free_loopback_port,
    handshake,
    is_tls13_suite,
    parse_report,
    read_until,
    send_all,
    standard_cipher_name,
    tls_version_name,
)

comptime _STEP_MS = 10_000


def _case(bssl: String, version: String, offer_h2: Bool) raises:
    var name = "komira client -> bssl s_server " + version + (" alpn=h2,http/1.1" if offer_h2 else " alpn=http/1.1")
    var peers = PeerGroup()
    var port = free_loopback_port()
    var args: List[String] = [
        "s_server", "-accept", String(Int(port)), "-cert", String(LEAF_CERT_PATH), "-key", String(LEAF_KEY_PATH),
        "-min-version", version, "-max-version", version, "-www",
    ]
    var server = peers.start(String("bssl s_server"), bssl, args)
    var sock = connect_loopback(port, peers, server, _STEP_MS)
    var config = client_tls_config(ROOT_CA_PATH, offer_h2)
    var conn = TlsConnection.new_client(config)
    conn.bind_fd(sock.fd)
    conn.set_server_name(String(SERVER_NAME))
    var failed = handshake(conn, peers, server, _STEP_MS)
    assert_equal(failed, String(""), name + ": the handshake failed")

    var komira_version = tls_version_name(conn.negotiated_tls_version())
    var komira_cipher = standard_cipher_name(conn.negotiated_cipher())
    var komira_alpn = conn.negotiated_protocol()

    send_all(conn, String("GET / HTTP/1.0\r\n\r\n"), peers, server, _STEP_MS)
    var answer = read_until(conn, String(""), peers, server, _STEP_MS)
    # The socket outlives every use of the connection bound to it (Mojo
    # would otherwise close it after its last named use, at bind_fd).
    _ = sock^
    var outcome = peers.wait(server, _STEP_MS)
    assert_true(outcome.ok(), name + ": s_server did not exit 0: " + outcome.describe())
    assert_true(answer.startswith("HTTP/1.0 200 OK\r\n"), name + ": the answer over TLS: '" + answer + "'")

    var over_tls = parse_report(answer)
    var on_stderr = parse_report(outcome.err)
    var expected_version = String("TLSv1.3") if version == "tls1.3" else String("TLSv1.2")
    assert_equal(komira_version, expected_version, name + ": komira's version")
    assert_equal(on_stderr.version, expected_version, name + ": bssl's version")
    assert_equal(komira_cipher, on_stderr.cipher, name + ": komira's cipher against bssl's")
    assert_equal(is_tls13_suite(komira_cipher), version == "tls1.3", name + ": a " + version + " suite")
    if komira_alpn:
        raise Error(name + ": komira negotiated ALPN '" + komira_alpn.value() + "' with a server that selects none")
    assert_equal(on_stderr.alpn, String(""), name + ": bssl's ALPN")
    assert_equal(over_tls.version, on_stderr.version, name + ": the answer's version")
    assert_equal(over_tls.cipher, on_stderr.cipher, name + ": the answer's cipher")
    assert_equal(over_tls.alpn, on_stderr.alpn, name + ": the answer's ALPN")
    print("  " + name + ": " + komira_version + " " + komira_cipher + " alpn=(none) OK")


def main() raises:
    tls_init()
    var bssl = flag(String("bssl"))
    _case(bssl, String("tls1.3"), True)
    _case(bssl, String("tls1.3"), False)
    _case(bssl, String("tls1.2"), True)
    _case(bssl, String("tls1.2"), False)
    print("test_komira_client_vs_bssl_server PASS")
