# `bssl s_client`, aws-lc's client, against komira's TLS server (the fixture
# leaf, "default_tls13", ALPN `h2` then `http/1.1`), the client pinned to one
# TLS version per case: TLS 1.3 and TLS 1.2, each offering ALPN
# `h2,http/1.1` and `http/1.1`. bssl verifies the server against the fixture
# root (`-root-certs`) and sends the SNI `localhost`.
#
# Per case: the handshake completes on both sides; komira's negotiated
# version is the one the client was pinned to, and is what bssl reports; the
# cipher suite komira reports is the one bssl reports, by name, and belongs
# to that version; the ALPN protocol is the server's choice, `h2` when the
# client offers it and `http/1.1` otherwise, on both sides; and an
# application byte round trip: bssl sends the line it reads from its standard
# input (`ping from bssl`), komira reads it over TLS, answers
# `pong from komira`, and closes with close_notify; bssl prints the answer
# on stdout, exactly, and exits 0 on the close_notify.

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
    scratch_file,
    send_all,
    server_tls_config,
    standard_cipher_name,
    tls_version_name,
)

comptime _STEP_MS = 10_000
comptime _PING = "ping from bssl\n"
comptime _PONG = "pong from komira\n"


def _case(bssl: String, busybox: String, stdin_file: String, version: String, offer_h2: Bool) raises:
    var offer = String("h2,http/1.1") if offer_h2 else String("http/1.1")
    var name = "bssl s_client " + version + " alpn=" + offer + " -> komira server"
    var peers = PeerGroup()
    var listener = listen_loopback()
    var port = local_port(listener)
    var args: List[String] = [
        "s_client", "-connect", "127.0.0.1:" + String(Int(port)), "-root-certs", String(ROOT_CA_PATH),
        "-server-name", String(SERVER_NAME), "-alpn-protos", offer,
        "-min-version", version, "-max-version", version,
    ]
    var client = peers.start(String("bssl s_client"), bssl, args, stdin_file, busybox)
    var sock = accept_one(listener, peers, client, _STEP_MS)
    var config = server_tls_config()
    var conn = TlsConnection(config)
    conn.bind_fd(sock.fd)
    var failed = handshake(conn, peers, client, _STEP_MS)
    if failed.byte_length() > 0:
        var o = peers.wait(client, _STEP_MS)
        raise Error(name + ": komira's handshake failed: " + failed + "\n" + o.describe())

    var komira_version = tls_version_name(conn.negotiated_tls_version())
    var komira_cipher = standard_cipher_name(conn.negotiated_cipher())
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
    assert_true(outcome.ok(), name + ": s_client did not exit 0: " + outcome.describe())
    assert_equal(outcome.out, String(_PONG), name + ": what bssl read over TLS")

    var bssl_report = parse_report(outcome.err)
    var expected_version = String("TLSv1.3") if version == "tls1.3" else String("TLSv1.2")
    var expected_alpn = String("h2") if offer_h2 else String("http/1.1")
    assert_equal(komira_version, expected_version, name + ": komira's version")
    assert_equal(bssl_report.version, expected_version, name + ": bssl's version")
    assert_equal(komira_cipher, bssl_report.cipher, name + ": komira's cipher against bssl's")
    assert_equal(is_tls13_suite(komira_cipher), version == "tls1.3", name + ": a " + version + " suite")
    assert_equal(komira_alpn, expected_alpn, name + ": komira's ALPN")
    assert_equal(bssl_report.alpn, expected_alpn, name + ": bssl's ALPN")
    print("  " + name + ": " + komira_version + " " + komira_cipher + " alpn=" + komira_alpn + " OK")


def main() raises:
    tls_init()
    var bssl = flag(String("bssl"))
    var busybox = flag(String("busybox"))
    var stdin_file = scratch_file(String("ping.txt"), String(_PING))
    _case(bssl, busybox, stdin_file, String("tls1.3"), True)
    _case(bssl, busybox, stdin_file, String("tls1.3"), False)
    _case(bssl, busybox, stdin_file, String("tls1.2"), True)
    _case(bssl, busybox, stdin_file, String("tls1.2"), False)
    print("test_bssl_client_vs_komira_server PASS")
