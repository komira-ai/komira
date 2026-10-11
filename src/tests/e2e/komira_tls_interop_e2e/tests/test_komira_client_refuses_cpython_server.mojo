# komira's TLS client (the production `default_client_tls_config`, which
# verifies the server) refuses a CPython `ssl` server (cpython_peer.py) whose
# certificate it cannot verify, with s2n's exact error,
# `Certificate is untrusted`:
#
#   untrusted root  the client trusts only an unrelated certificate;
#
# and, against the same server, accepts it when it trusts the fixture root
# (the control: a refusal is about trust, not a server that cannot complete
# a handshake). In the refused case CPython's server never completes its side
# of the handshake (it never prints `Connected.`) and exits 3. A client with
# verification off would complete the refused handshake, and fail here.
#
# The refusal takes 10 to 30 seconds: s2n's default blinding sleeps that long
# inside the failing handshake call (komira does not set self-service
# blinding).

from std.testing import assert_equal, assert_true

from komira_http_core.tls import TlsConnection, tls_init
from komira_tls_interop_e2e import (
    LEAF_CERT_PATH,
    LEAF_KEY_PATH,
    LISTENING,
    OTHER_CA_PATH,
    ROOT_CA_PATH,
    SERVER_NAME,
    PeerGroup,
    client_tls_config,
    connect_loopback,
    flag,
    handshake,
    listening_port,
    start_cpython_peer,
)

comptime _STEP_MS = 10_000
comptime _UNTRUSTED = "Certificate is untrusted"


def _handshake_with_cpython(python: String, trust: StaticString, name: String) raises -> String:
    """komira's client handshake (TLS 1.3) with a fresh CPython server: the
    empty string when it completed, else s2n's error text. Checks that
    CPython's side ended accordingly."""
    var peers = PeerGroup()
    var args: List[String] = [
        "server", "--cert", String(LEAF_CERT_PATH), "--key", String(LEAF_KEY_PATH),
        "--version", "tls1.3", "--alpn", "http/1.1",
    ]
    var server = start_cpython_peer(peers, String("cpython server"), python, args)
    peers.wait_for_line(server, String(LISTENING), _STEP_MS)
    var port = listening_port(peers.stdout(server))
    var sock = connect_loopback(port, peers, server, _STEP_MS)
    var config = client_tls_config(trust, offer_h2=False)
    var conn = TlsConnection.new_client(config)
    conn.bind_fd(sock.fd)
    conn.set_server_name(String(SERVER_NAME))
    var failed = handshake(conn, peers, server, _STEP_MS)
    _ = conn^
    _ = sock^
    if failed.byte_length() == 0:
        # Accepted: CPython completes its side once it reads komira's
        # Finished, already sent; it then reads a closed connection and
        # exits (4, which is not checked here).
        peers.wait_for_line(server, String("Connected."), _STEP_MS)
        _ = peers.wait(server, _STEP_MS)
        return failed^
    var o = peers.wait(server, _STEP_MS)
    assert_equal(o.exit_code, 3, name + ": cpython's handshake did not fail: " + o.describe())
    assert_true("Connected." not in o.err, name + ": cpython completed a handshake komira refused: " + o.describe())
    return failed^


def main() raises:
    tls_init()
    var python = flag(String("python"))

    var untrusted = _handshake_with_cpython(python, OTHER_CA_PATH, String("untrusted root"))
    assert_equal(untrusted, String(_UNTRUSTED), "untrusted root: komira's refusal")
    print("  untrusted root: refused: " + untrusted)

    var control = _handshake_with_cpython(python, ROOT_CA_PATH, String("control"))
    assert_equal(control, String(""), "control: the verified handshake")
    print("  control: accepted")
    print("test_komira_client_refuses_cpython_server PASS")
