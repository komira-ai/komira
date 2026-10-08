# komira's TLS client (the production `default_client_tls_config`, which
# verifies the server) refuses `bssl s_server` when it cannot verify it, with
# s2n's exact error, `Certificate is untrusted`:
#
#   untrusted root  the client trusts only an unrelated certificate;
#   wrong name      the client trusts the fixture root but expects the name
#                   `evil.example`, which the leaf does not certify;
#
# and, against the same server configuration, accepts it when it trusts the
# fixture root and expects `localhost` (the control: a refusal is about trust,
# not a server that cannot complete a handshake). In each refused case bssl's
# server never completes its side of the handshake (it never prints
# `Connected.`) and exits non-zero.
#
# Each refusal takes 10 to 30 seconds: s2n's default blinding sleeps that long
# inside the failing handshake call (komira does not set self-service
# blinding), so the test runs for up to about a minute.

from std.testing import assert_equal, assert_true

from komira_http_core.tls import TlsConnection, tls_init
from komira_tls_interop_e2e import (
    LEAF_CERT_PATH,
    LEAF_KEY_PATH,
    OTHER_CA_PATH,
    ROOT_CA_PATH,
    SERVER_NAME,
    PeerGroup,
    client_tls_config,
    connect_loopback,
    flag,
    free_loopback_port,
    handshake,
)

comptime _STEP_MS = 10_000
comptime _UNTRUSTED = "Certificate is untrusted"


def _handshake_with_bssl(bssl: String, trust: StaticString, server_name: String, name: String) raises -> String:
    """komira's client handshake with a fresh `bssl s_server` (TLS 1.3): the
    empty string when it completed, else s2n's error text. Checks that bssl's
    side ended accordingly."""
    var peers = PeerGroup()
    var port = free_loopback_port()
    var args: List[String] = [
        "s_server", "-accept", String(Int(port)), "-cert", String(LEAF_CERT_PATH), "-key", String(LEAF_KEY_PATH),
        "-min-version", "tls1.3", "-www",
    ]
    var server = peers.start(String("bssl s_server"), bssl, args)
    var sock = connect_loopback(port, peers, server, _STEP_MS)
    var config = client_tls_config(trust, offer_h2=False)
    var conn = TlsConnection.new_client(config)
    conn.bind_fd(sock.fd)
    conn.set_server_name(server_name)
    var failed = handshake(conn, peers, server, _STEP_MS)
    _ = conn^
    _ = sock^
    if failed.byte_length() == 0:
        # Accepted: bssl completes its side once it reads komira's Finished,
        # already sent; with no request on the closed connection it then
        # exits (non-zero, which is not checked here).
        peers.wait_for_line(server, String("Connected."), _STEP_MS)
        _ = peers.wait(server, _STEP_MS)
        return failed^
    var o = peers.wait(server, _STEP_MS)
    assert_true(not o.ok(), name + ": bssl exited 0 after komira refused it: " + o.describe())
    assert_true("Connected." not in o.err, name + ": bssl completed a handshake komira refused: " + o.describe())
    return failed^


def main() raises:
    tls_init()
    var bssl = flag(String("bssl"))

    var untrusted = _handshake_with_bssl(bssl, OTHER_CA_PATH, String(SERVER_NAME), String("untrusted root"))
    assert_equal(untrusted, String(_UNTRUSTED), "untrusted root: komira's refusal")
    print("  untrusted root: refused: " + untrusted)

    var wrong_name = _handshake_with_bssl(bssl, ROOT_CA_PATH, String("evil.example"), String("wrong name"))
    assert_equal(wrong_name, String(_UNTRUSTED), "wrong name: komira's refusal")
    print("  wrong name: refused: " + wrong_name)

    var control = _handshake_with_bssl(bssl, ROOT_CA_PATH, String(SERVER_NAME), String("control"))
    assert_equal(control, String(""), "control: the verified handshake")
    print("  control: accepted")
    print("test_komira_client_refuses_bssl_server PASS")
