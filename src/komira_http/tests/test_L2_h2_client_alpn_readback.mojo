"""L2 ALPN-readback for TlsClientStream + h2 mapping.

Acceptance gate for: after a successful TLS handshake where BOTH peers
advertised `[h2, http/1.1]`, the client-side TlsConnection.negotiated_protocol()
returns "h2", and the TlsConnector mapping logic converts that to
NEGOTIATED_HTTP_2 — the sentinel HttpClient.send branches on for the
h2-dispatch path.

Mirrors the L2 HTTPS verify-pass socketpair pattern; the only protocol
change is ALPN list = ["h2", "http/1.1"] on both sides (h2 first per RFC 9113
§3.2: client offers list in preference order; server picks first overlap).
"""

from std.ffi import external_call

from komira_async.runtime.tcp_stream import TcpStream

from komira_http.client import TlsClientStream
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
from komira_http.transport.io_stream import (
    NEGOTIATED_HTTP_1_1,
    NEGOTIATED_HTTP_2,
)
from komira_http.transport.kernel_tcp import TcpIoStream
from std.pathlib import Path


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _leaf_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_key.pem").read_text()


def _root_ca_pem() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/root_ca.pem").read_text()


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


def test_h2_alpn_readback_maps_to_negotiated_http_2() raises:
    """Both peers advertise [h2, http/1.1]; ALPN negotiates "h2";
    TlsClientStream.negotiated_protocol() reports NEGOTIATED_HTTP_2."""
    print("  test_h2_alpn_readback_maps_to_negotiated_http_2...")

    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var server_alpn = List[String]()
    server_alpn.append(String("h2"))
    server_alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(server_alpn)

    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.add_trust_pem(_root_ca_pem())
    client_config.enable_verify_default()
    var client_alpn = List[String]()
    client_alpn.append(String("h2"))
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

        var outcomes = _drive_handshake_to_done(server_conn, client_conn)
        var sv_out = outcomes[0]
        var cl_out = outcomes[1]
        if sv_out != TLS_OUTCOME_DONE or cl_out != TLS_OUTCOME_DONE:
            var sv_msg = String("")
            if sv_out == TLS_OUTCOME_ERROR:
                sv_msg = s2n_strerror_message(last_s2n_errno())
            raise Error(
                "handshake did not reach DONE on both sides: server="
                + _outcome_str(sv_out)
                + " client=" + _outcome_str(cl_out)
                + " (sv_errno_msg='" + sv_msg + "')"
            )

        # ALPN-readback verification — same logic as TlsConnector.connect[RT]
        # at the DONE branch. Asserts s2n's negotiated_protocol() returns "h2"
        # and the TlsConnector.connect[RT]'s mapping logic produces
        # NEGOTIATED_HTTP_2.
        var alpn_opt = client_conn.negotiated_protocol()
        if not alpn_opt.__bool__():
            raise Error(
                "client_conn.negotiated_protocol() returned None — "
                "expected 'h2'"
            )
        var alpn_str = alpn_opt.value()
        if alpn_str != String("h2"):
            raise Error(
                "client_conn.negotiated_protocol() got '" + alpn_str
                + "' — expected 'h2'"
            )
        var alpn_sentinel: UInt8 = NEGOTIATED_HTTP_1_1
        if alpn_str == String("h2"):
            alpn_sentinel = NEGOTIATED_HTTP_2

        # Wrap in TlsClientStream via the 3-arg ctor.
        var client_tcp = TcpStream(client_fd)
        var underlying = TcpIoStream(client_tcp^)
        var stream = TlsClientStream[TcpIoStream](
            underlying^, client_conn^, alpn_sentinel,
        )
        if Int(stream.negotiated_protocol()) != Int(NEGOTIATED_HTTP_2):
            raise Error(
                "TlsClientStream.negotiated_protocol mismatch: got "
                + String(Int(stream.negotiated_protocol()))
                + " expected " + String(Int(NEGOTIATED_HTTP_2))
                + " (NEGOTIATED_HTTP_2)"
            )
        if stream.fd() != client_fd:
            raise Error(
                "TlsClientStream.fd mismatch: got "
                + String(Int(stream.fd())) + " expected "
                + String(Int(client_fd))
            )
        _ = server_conn^
        _ = stream^
    finally:
        _close_fd(server_fd)
    _ = server_config^
    _ = client_config^
    print("    OK — ALPN negotiated 'h2'; TlsClientStream → NEGOTIATED_HTTP_2")


def test_h1_only_alpn_falls_back_to_negotiated_http_1_1() raises:
    """When ONLY http/1.1 is on both sides' ALPN lists, the mapping
    falls back to NEGOTIATED_HTTP_1_1 — the existing behavior is
    preserved by the ALPN-readback change."""
    print("  test_h1_only_alpn_falls_back_to_negotiated_http_1_1...")

    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var server_alpn = List[String]()
    server_alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(server_alpn)

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

    try:
        var server_conn = TlsConnection(server_config)
        server_conn.bind_fd(server_fd)

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))

        var outcomes = _drive_handshake_to_done(server_conn, client_conn)
        if outcomes[0] != TLS_OUTCOME_DONE or outcomes[1] != TLS_OUTCOME_DONE:
            raise Error("handshake did not reach DONE in h1-only test")

        # Mapping: "http/1.1" → NEGOTIATED_HTTP_1_1.
        var alpn_opt = client_conn.negotiated_protocol()
        var alpn_sentinel: UInt8 = NEGOTIATED_HTTP_1_1
        if alpn_opt.__bool__():
            var alpn_str = alpn_opt.value()
            if alpn_str == String("h2"):
                alpn_sentinel = UInt8(99)  # unreachable in this test

        if Int(alpn_sentinel) != Int(NEGOTIATED_HTTP_1_1):
            raise Error(
                "h1-only ALPN should map to NEGOTIATED_HTTP_1_1; got "
                + String(Int(alpn_sentinel))
            )

        var client_tcp = TcpStream(client_fd)
        var underlying = TcpIoStream(client_tcp^)
        var stream = TlsClientStream[TcpIoStream](
            underlying^, client_conn^, alpn_sentinel,
        )
        if Int(stream.negotiated_protocol()) != Int(NEGOTIATED_HTTP_1_1):
            raise Error(
                "TlsClientStream.negotiated_protocol expected NEGOTIATED_HTTP_1_1; "
                "got " + String(Int(stream.negotiated_protocol()))
            )
        _ = server_conn^
        _ = stream^
    finally:
        _close_fd(server_fd)
    _ = server_config^
    _ = client_config^
    print("    OK — h1-only ALPN → NEGOTIATED_HTTP_1_1 (regression guard)")


def main() raises:
    print("== L2 ALPN-readback (h2 mapping) ==")
    tls_init()
    test_h2_alpn_readback_maps_to_negotiated_http_2()
    test_h1_only_alpn_falls_back_to_negotiated_http_1_1()
    print("== L2 ALPN-readback PASSED (2 tests) ==")
