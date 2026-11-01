"""TlsStream (tls/conn.mojo), the server-side orchestrator, through a whole
connection: handshake to DONE, application data both ways, close_notify.

Its handshake test stops at the first BLOCKED_ON_READ (no peer drives the
other end). Here a client TlsConnection drives the other end of a
socketpair, so this proves:

  * drive_handshake's triple at every step: BLOCKED_ON_READ is
    (INTEREST_READ, CONN_STATE_TLS_HANDSHAKE_IN), and DONE is
    (INTEREST_READ, CONN_STATE_READING) with handshake_done() set;
  * the ALPN result reads back, and no SNI means sni_hostname() is None;
  * read_app returns the client's bytes, write_app's bytes reach the client,
    and shutdown_app sends a close_notify the client reads as EOF.

The client skips chain verification (disable_verify), so no host name is
involved.
"""

from std.ffi import external_call
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.completion_queue import INTEREST_READ

from komira_http_core.tls import (
    CONN_STATE_READING,
    CONN_STATE_TLS_HANDSHAKE_IN,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    TlsStream,
    tls_init,
)


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: the pointer's origin is `sv`, alive across the synchronous call,
    # which writes two Int32 into it and keeps no pointer.
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv.unsafe_ptr()
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
        raise Error("_set_nonblock(" + String(Int(fd)) + ") returned " + String(Int(rc)))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var r = s.as_bytes()
    for i in range(len(r)):
        out.append(r[i])
    return out^


def _text(buf: List[UInt8]) -> String:
    var s = String()
    for i in range(len(buf)):
        s += chr(Int(buf[i]))
    return s^


def test_tls_stream_whole_connection() raises:
    var server_config = TlsConfig()
    server_config.load_cert(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text(),
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text(),
    )
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(alpn)
    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.disable_verify()
    client_config.set_alpn_protocols(alpn)

    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    try:
        var server = TlsStream(server_config, server_fd)
        assert_equal(Int(server.state()), Int(CONN_STATE_TLS_HANDSHAKE_IN))
        assert_false(server.handshake_done())
        assert_equal(Int(server.fd()), Int(server_fd))
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(client_fd)

        var server_done = False
        var client_done = False
        var saw_blocked = False
        var i = 0
        while i < 64 and not (server_done and client_done):
            if not server_done:
                var t = server.drive_handshake()
                assert_true(t[0] != TLS_OUTCOME_ERROR, "server handshake ERROR")
                if t[0] == TLS_OUTCOME_DONE:
                    assert_equal(Int(t[1]), Int(INTEREST_READ))
                    assert_equal(Int(t[2]), Int(CONN_STATE_READING))
                    server_done = True
                elif t[0] == TLS_OUTCOME_BLOCKED_ON_READ:
                    assert_equal(Int(t[1]), Int(INTEREST_READ))
                    assert_equal(Int(t[2]), Int(CONN_STATE_TLS_HANDSHAKE_IN))
                    assert_false(server.handshake_done())
                    saw_blocked = True
            if not client_done:
                var c = client.handshake()
                assert_true(c != TLS_OUTCOME_ERROR, "client handshake ERROR")
                if c == TLS_OUTCOME_DONE:
                    client_done = True
            i += 1
        assert_true(server_done and client_done, "handshake did not finish in 64 rounds")
        assert_true(saw_blocked)
        assert_true(server.handshake_done())
        assert_equal(Int(server.state()), Int(CONN_STATE_READING))
        var proto = server.negotiated_protocol()
        assert_true(Bool(proto))
        assert_equal(proto.value(), String("http/1.1"))
        assert_false(Bool(server.sni_hostname()))

        # Client -> server.
        var ping = _bytes(String("ping"))
        var sent = client.send(Span[UInt8](ping))
        assert_equal(Int(sent[0]), Int(TLS_OUTCOME_DONE))
        assert_equal(sent[1], 4)
        var got = List[UInt8](capacity=64)
        var r = server.read_app(got, 64)
        var k = 0
        while r[0] == TLS_OUTCOME_BLOCKED_ON_READ and k < 16:
            r = server.read_app(got, 64)
            k += 1
        assert_equal(Int(r[0]), Int(TLS_OUTCOME_DONE))
        assert_equal(r[1], 4)
        assert_equal(_text(got), String("ping"))

        # Server -> client.
        var pong = _bytes(String("pong!"))
        var w = server.write_app(Span[UInt8](pong))
        assert_equal(Int(w[0]), Int(TLS_OUTCOME_DONE))
        assert_equal(w[1], 5)
        var back = List[UInt8](capacity=64)
        var cr = client.recv(back, 64)
        k = 0
        while cr[0] == TLS_OUTCOME_BLOCKED_ON_READ and k < 16:
            cr = client.recv(back, 64)
            k += 1
        assert_equal(Int(cr[0]), Int(TLS_OUTCOME_DONE))
        assert_equal(_text(back), String("pong!"))

        # close_notify: the server's shutdown waits for the client's alert,
        # and the client reads the server's as EOF (DONE, 0).
        var s1 = server.shutdown_app()
        assert_true(s1 != TLS_OUTCOME_ERROR, "server shutdown ERROR")
        var eof_buf = List[UInt8](capacity=16)
        var e = client.recv(eof_buf, 16)
        assert_equal(Int(e[0]), Int(TLS_OUTCOME_DONE))
        assert_equal(e[1], 0)
        _ = server.s2n_errno()
        _ = client^
        _ = server^
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    _ = server_config^
    _ = client_config^


def main() raises:
    tls_init()
    test_tls_stream_whole_connection()
    print("PASS test_cov_tls_stream_app_data")
