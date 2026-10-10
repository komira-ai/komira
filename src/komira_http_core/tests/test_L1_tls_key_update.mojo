"""TLS 1.3 key update on a live connection (`TlsConnection.request_key_update`
and `TlsConnection.key_update_counts`).

A komira server and a komira client `TlsConnection` handshake in-process over
an AF_UNIX socketpair, then exchange application data. Every chunk is one
`send` (one TLS record); the receiver decrypts between sends and every byte
is compared against what was sent.

  * test_counts_zero_and_refused_before_handshake: on fresh client and server
    connections the counts are (0, 0) and a request raises "handshake not
    complete". The handshake and an exchange afterwards still leave (0, 0):
    the refusal set nothing pending in s2n. Without the check s2n accepts the
    request and sends the KeyUpdate when the handshake ends (counts 1).
  * test_refused_on_tls12: the default s2n policy negotiates TLS 1.2, where
    s2n would drop the request silently; the wrapper refuses it naming
    version 33.
  * test_peer_requested_refused_by_s2n: s2n 1.5.6 refuses
    `PeerKeyUpdate.REQUESTED` with S2N_ERR_INVALID_ARGUMENT; the wrapper
    passes s2n's message through and nothing becomes pending. Red if the
    wrapper sends NOT_REQUESTED for a REQUESTED caller.
  * test_key_update_mid_stream_both_sides: three rounds, each a client update
    then a server update, with 16 records each way between updates. After
    each update the counts are exact on both sides: the updater's `sent` and
    the peer's `received` step by one and the other two stay. Red if the
    wrapper sends REQUESTED for a NOT_REQUESTED caller (s2n refuses it), if
    the counts swap sides, or if a record crosses a key change garbled
    (the receiver would fail to decrypt or the bytes would differ).
"""

from std.ffi import external_call

from komira_http_core.tls import (
    KeyUpdateCounts,
    PeerKeyUpdate,
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
# One `send` per chunk, so one record per chunk; 16 records per phase.
comptime _CHUNK: Int = 4096
comptime _PHASE_BYTES: Int = 65536
comptime _NOT_COMPLETE = "TlsConnection.request_key_update: handshake not complete"


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: the pointer's origin is `sv`, which outlives the synchronous
    # socketpair call (it is read below); the call writes two Int32 into it
    # and keeps no pointer.
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv.unsafe_ptr()
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    for i in range(2):
        if external_call["komira_fcntl_set_nonblock", Int32](sv[i]) < 0:
            raise Error("komira_fcntl_set_nonblock failed")
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd >= 0:
        var _rc = external_call["close", Int32](fd)


def _server_config(tls13: Bool) raises -> TlsConfig:
    var config = TlsConfig()
    config.load_cert(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text(),
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text(),
    )
    if tls13:
        config.set_cipher_preferences(String("default_tls13"))
    return config^


def _client_config(tls13: Bool) raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    if tls13:
        config.set_cipher_preferences(String("default_tls13"))
    return config^


def _handshake(mut server: TlsConnection, mut client: TlsConnection) raises:
    var sv_done = False
    var cl_done = False
    for _ in range(256):
        if not sv_done:
            var o = server.handshake()
            if o == TLS_OUTCOME_ERROR:
                raise Error("server handshake: " + s2n_strerror_message(last_s2n_errno()))
            sv_done = o == TLS_OUTCOME_DONE
        if not cl_done:
            var o = client.handshake()
            if o == TLS_OUTCOME_ERROR:
                raise Error("client handshake: " + s2n_strerror_message(last_s2n_errno()))
            cl_done = o == TLS_OUTCOME_DONE
        if sv_done and cl_done:
            return
    raise Error("handshake did not finish in 256 steps")


def _payload(n: Int, salt: Int) -> List[UInt8]:
    """Position-hashed bytes: a replayed or dropped record cannot match."""
    var out = List[UInt8](capacity=n)
    for p in range(n):
        out.append(UInt8((((p + salt * 7919) * 2654435761) >> 13) & 0xFF))
    return out^


def _pump(
    mut tx: TlsConnection, mut rx: TlsConnection, n: Int, salt: Int, what: String
) raises:
    """Send `n` bytes from `tx` in `_CHUNK` records, decrypting on `rx` in
    between, and require `rx` to have received exactly those bytes."""
    var payload = _payload(n, salt)
    var got = List[UInt8](capacity=n)
    var buf = List[UInt8](capacity=16384)
    for _ in range(16384):
        buf.append(UInt8(0))
    var off = 0
    var iters = 0
    while off < n or len(got) < n:
        iters += 1
        if iters > 100000:
            raise Error(what + ": stalled at sent=" + String(off) + " received=" + String(len(got)))
        if off < n:
            var end = min(off + _CHUNK, n)
            var res = tx.send(Span[UInt8](payload)[off:end].as_imm())
            if res[0] == TLS_OUTCOME_ERROR:
                raise Error(what + ": send: " + s2n_strerror_message(last_s2n_errno()))
            off += res[1]
        var rr = rx.recv_into_span(Span[UInt8](buf))
        if rr[0] == TLS_OUTCOME_ERROR:
            raise Error(what + ": recv: " + s2n_strerror_message(last_s2n_errno()))
        for k in range(rr[1]):
            got.append(buf[k])
    if len(got) != n:
        raise Error(what + ": received " + String(len(got)) + " bytes of " + String(n))
    for i in range(n):
        if got[i] != payload[i]:
            raise Error(what + ": byte " + String(i) + " differs")


def _expect_counts(conn: TlsConnection, sent: Int, received: Int, who: String) raises:
    var c = conn.key_update_counts()
    if c != KeyUpdateCounts(sent=sent, received=received):
        raise Error(
            who + ": key_update_counts (sent=" + String(c.sent) + ", received="
            + String(c.received) + "), expected (sent=" + String(sent)
            + ", received=" + String(received) + ")"
        )


def _expect_raises(mut conn: TlsConnection, peer: PeerKeyUpdate, message: String, who: String) raises:
    var raised = False
    try:
        conn.request_key_update(peer)
    except e:
        raised = True
        if String(e) != message:
            raise Error(who + ": raised '" + String(e) + "', expected '" + message + "'")
    if not raised:
        raise Error(who + ": request_key_update did not raise, expected '" + message + "'")


def test_counts_zero_and_refused_before_handshake() raises:
    print("  test_counts_zero_and_refused_before_handshake...")
    var server_config = _server_config(True)
    var client_config = _client_config(True)
    var fds = _socketpair()
    try:
        var server = TlsConnection(server_config)
        var client = TlsConnection.new_client(client_config)
        # Unbound and bound: both still before the handshake.
        _expect_counts(server, 0, 0, "fresh server")
        _expect_counts(client, 0, 0, "fresh client")
        _expect_raises(client, PeerKeyUpdate.NOT_REQUESTED, _NOT_COMPLETE, "unbound client")
        server.bind_fd(fds[0])
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _expect_raises(client, PeerKeyUpdate.NOT_REQUESTED, _NOT_COMPLETE, "fresh client")
        _expect_raises(server, PeerKeyUpdate.NOT_REQUESTED, _NOT_COMPLETE, "fresh server")
        # Mid-handshake: the client has sent its ClientHello only.
        _ = client.handshake()
        _expect_raises(client, PeerKeyUpdate.NOT_REQUESTED, _NOT_COMPLETE, "mid-handshake client")
        _handshake(server, client)
        _pump(client, server, _PHASE_BYTES, 1, "client->server")
        _pump(server, client, _PHASE_BYTES, 2, "server->client")
        _expect_counts(server, 0, 0, "server after handshake")
        _expect_counts(client, 0, 0, "client after handshake")
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    print("    OK")


def test_refused_on_tls12() raises:
    print("  test_refused_on_tls12...")
    var server_config = _server_config(False)
    var client_config = _client_config(False)
    var fds = _socketpair()
    try:
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _handshake(server, client)
        var want = String(
            "TlsConnection.request_key_update: key update needs TLS 1.3"
            " (negotiated protocol version 33)"
        )
        _expect_raises(client, PeerKeyUpdate.NOT_REQUESTED, want, "TLS 1.2 client")
        _expect_raises(server, PeerKeyUpdate.NOT_REQUESTED, want, "TLS 1.2 server")
        _pump(client, server, _PHASE_BYTES, 3, "client->server")
        _pump(server, client, _PHASE_BYTES, 4, "server->client")
        _expect_counts(server, 0, 0, "TLS 1.2 server")
        _expect_counts(client, 0, 0, "TLS 1.2 client")
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    print("    OK")


def test_peer_requested_refused_by_s2n() raises:
    print("  test_peer_requested_refused_by_s2n...")
    var server_config = _server_config(True)
    var client_config = _client_config(True)
    var fds = _socketpair()
    try:
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _handshake(server, client)
        var want = String(
            "TlsConnection.request_key_update: invalid argument provided into"
            " a function call"
        )
        _expect_raises(client, PeerKeyUpdate.REQUESTED, want, "client")
        _expect_raises(server, PeerKeyUpdate.REQUESTED, want, "server")
        _pump(client, server, _PHASE_BYTES, 5, "client->server")
        _pump(server, client, _PHASE_BYTES, 6, "server->client")
        _expect_counts(server, 0, 0, "server")
        _expect_counts(client, 0, 0, "client")
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    print("    OK")


def test_key_update_mid_stream_both_sides() raises:
    print("  test_key_update_mid_stream_both_sides...")
    var server_config = _server_config(True)
    var client_config = _client_config(True)
    var fds = _socketpair()
    try:
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _handshake(server, client)
        _expect_counts(server, 0, 0, "server after handshake")
        _expect_counts(client, 0, 0, "client after handshake")
        _pump(client, server, _PHASE_BYTES, 10, "warm-up client->server")
        _pump(server, client, _PHASE_BYTES, 11, "warm-up server->client")
        for r in range(1, 4):
            var tag = "round " + String(r) + " "
            client.request_key_update(PeerKeyUpdate.NOT_REQUESTED)
            # Pending until the next send: no key has changed yet.
            _expect_counts(client, r - 1, r - 1, tag + "client, requested")
            _pump(client, server, _PHASE_BYTES, 20 * r, tag + "client->server")
            _pump(server, client, _PHASE_BYTES, 20 * r + 1, tag + "server->client")
            _expect_counts(client, r, r - 1, tag + "client after its update")
            _expect_counts(server, r - 1, r, tag + "server after client update")

            server.request_key_update(PeerKeyUpdate.NOT_REQUESTED)
            _expect_counts(server, r - 1, r, tag + "server, requested")
            _pump(server, client, _PHASE_BYTES, 20 * r + 2, tag + "server->client")
            _pump(client, server, _PHASE_BYTES, 20 * r + 3, tag + "client->server")
            _expect_counts(server, r, r, tag + "server after its update")
            _expect_counts(client, r, r, tag + "client after server update")
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    print("    OK")


def main() raises:
    print("== L1 TLS 1.3 key update ==")
    tls_init()
    test_counts_zero_and_refused_before_handshake()
    test_refused_on_tls12()
    test_peer_requested_refused_by_s2n()
    test_key_update_mid_stream_both_sides()
    print("== L1 TLS 1.3 key update PASSED (4 tests) ==")
