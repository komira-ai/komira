"""Every arm of `tls/s2n_shim.mojo` that a live s2n connection or config can
take, driven in-process: a komira server and a komira client `TlsConnection`
over an AF_UNIX socketpair, with the package's fixture certificates. No test
here makes s2n fail a protocol check, so none pays s2n's blinding delay: every
error below is an I/O, closed or usage error, which s2n does not blind
(tls/s2n_connection.c, `s2n_connection_apply_error_blinding`).

  * test_outcome_table: `_blocked_status_to_outcome` is pure, so its whole
    table is pinned directly, including `*blocked` 3 and 4
    (APPLICATION_INPUT, EARLY_DATA) and NOT_BLOCKED with a failure, which no
    live call reaches (see the shim's docstrings).
  * test_config_refusals: s2n's own refusals reach the caller as raises that
    name the call: an unknown security policy, a PEM that is not one, a
    certificate the policy forbids (RFC 9151 wants RSA 3072 or more; the
    fixture is RSA 2048), and an ALPN list past the extension's 65535 bytes
    (255 protocols of 255 bytes fit, the 256th does not).
  * test_empty_config_refusals: the calls s2n refuses only for a NULL config
    (OOM otherwise) run on the module's own empty handle: each raises.
  * test_before_handshake: the getters' "nothing yet" answers, the SNI and
    session refusals, an empty send that touches no wire byte, and the
    "(null)" of a NULL message-name pointer.
  * test_tls12_session_recv_and_close: a TLS 1.2 handshake with SNI; the
    client's session blob is accepted by a fresh client; `recv` (into a List) keeps the positive partial
    and leaves the List alone on a block; a zero-capacity read reports a block
    while plaintext is buffered and DONE(0) once it is not; the close_notify
    exchange gives EOF and DONE on both sides; a send after shutdown is an
    ERROR (CLOSED), never DONE(0).
  * test_tls13_blocked_send_and_reset: a TLS 1.3 handshake with ALPN; key
    update refusals and one update; a send into a full socket blocks with
    nothing accepted, an empty send then makes no s2n call (s2n's would
    flush, and block), and every byte still arrives intact; a peer that
    closes with unread bytes makes `recv` an ERROR (I/O) and the next send
    too.
  * test_abrupt_close_is_eof: a peer that closes without close_notify is
    EOF on `recv_into_span` and `recv` (CLOSED), not an error and not a block.
"""

from std.ffi import external_call
from std.memory import ArcPointer
from std.pathlib import Path

from komira_async.reactor.socket_setup import set_so_sndbuf, so_sndbuf
from komira_http_core.tls import (
    PeerKeyUpdate,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TLS_VERSION_TLS12,
    TLS_VERSION_TLS13,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
from komira_http_core.tls.ffi import (
    S2N_ERR_T_CLOSED,
    S2N_ERR_T_IO,
    _S2N_FFI_ORIGIN,
    s2n_error_get_type,
)
from komira_http_core.tls.s2n_shim import (
    _S2nConfigHandle,
    _blocked_status_to_outcome,
    _null_ptr,
    s2n_last_message_name,
    s2n_strerror_debug_message,
)


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1
comptime _FIXTURES = "src/komira_http_core/tests/fixtures/tls/"
# The client's send buffer for the blocked-send case. The fill below sends at
# most 1 MiB, so it must block well before that whatever the worker's
# net.core.wmem_default; Linux doubles the request (read back below).
comptime _SMALL_SNDBUF: Int32 = 16384
comptime _MAX_EFFECTIVE_SNDBUF: Int32 = 65536


# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: the pointer's origin is `sv`, alive across the synchronous call,
    # which writes two Int32 into it and keeps no pointer.
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
        Path(_FIXTURES + "leaf_cert.pem").read_text(),
        Path(_FIXTURES + "leaf_key.pem").read_text(),
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


def _zeros(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(0))
    return out^


def _expect_pair(got: Tuple[UInt8, Int], outcome: UInt8, n: Int, what: String) raises:
    if got[0] != outcome or got[1] != n:
        raise Error(
            what + ": got (outcome " + String(Int(got[0])) + ", n "
            + String(got[1]) + "), expected (outcome " + String(Int(outcome))
            + ", n " + String(n) + ")"
        )


def _expect_eq(got: Int, want: Int, what: String) raises:
    if got != want:
        raise Error(what + ": got " + String(got) + ", expected " + String(want))


def _expect_raise_has(e: Error, needle: String, what: String) raises:
    var msg = String(e)
    if msg.find(needle) < 0:
        raise Error(what + ": raised '" + msg + "', expected it to contain '" + needle + "'")


def _expect_err_type(want: Int32, what: String) raises:
    var t = s2n_error_get_type(last_s2n_errno())
    if t != want:
        raise Error(
            what + ": s2n error type " + String(Int(t)) + ", expected "
            + String(Int(want)) + " (" + s2n_strerror_message(last_s2n_errno()) + ")"
        )


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_outcome_table() raises:
    print("  test_outcome_table...")
    # (blocked, rc) -> outcome. 0 NOT_BLOCKED, 1 ON_READ, 2 ON_WRITE,
    # 3 APPLICATION_INPUT, 4 EARLY_DATA (s2n.h s2n_blocked_status). The rows
    # are read from Lists so the always-inline helper runs on runtime values
    # and is not folded away at each call site.
    var blocked: List[Int32] = [1, 1, 2, 2, 0, 0, 0, 3, 4]
    var rcs: List[Int64] = [-1, 0, -1, 7, -1, 0, 5, 0, -1]
    var want: List[UInt8] = [
        TLS_OUTCOME_BLOCKED_ON_READ,
        TLS_OUTCOME_BLOCKED_ON_READ,
        TLS_OUTCOME_BLOCKED_ON_WRITE,
        TLS_OUTCOME_BLOCKED_ON_WRITE,
        TLS_OUTCOME_ERROR,
        TLS_OUTCOME_DONE,
        TLS_OUTCOME_DONE,
        TLS_OUTCOME_ERROR,
        TLS_OUTCOME_ERROR,
    ]
    for i in range(len(want)):
        _expect_eq(
            Int(_blocked_status_to_outcome(blocked[i], rcs[i])),
            Int(want[i]),
            "blocked " + String(Int(blocked[i])) + ", rc " + String(Int(rcs[i])),
        )
    print("    OK")


def test_config_refusals() raises:
    print("  test_config_refusals...")
    var config = TlsConfig()
    try:
        config.set_cipher_preferences(String("no-such-policy"))
        raise Error("unknown policy accepted")
    except e:
        _expect_raise_has(e, "failed for version='no-such-policy'", "unknown policy")
    try:
        config.add_trust_pem(String("-----BEGIN CERTIFICATE-----\nnot a cert\n-----END CERTIFICATE-----\n"))
        raise Error("garbage PEM accepted into the trust store")
    except e:
        _expect_raise_has(e, "TlsConfig.add_trust_pem: s2n_config_add_pem_to_trust_store failed", "garbage PEM")
    config.add_trust_pem(Path(_FIXTURES + "root_ca.pem").read_text())

    # The policy refuses the certificate when it is added, after it parsed.
    var strict = TlsConfig()
    strict.set_cipher_preferences(String("rfc9151"))
    try:
        strict.load_cert(
            Path(_FIXTURES + "leaf_cert.pem").read_text(),
            Path(_FIXTURES + "leaf_key.pem").read_text(),
        )
        raise Error("RSA 2048 certificate accepted under rfc9151")
    except e:
        _expect_raise_has(e, "s2n_config_add_cert_chain_and_key_to_store failed", "rfc9151 cert")

    # ALPN: each protocol costs 1 + its length; 255 * 256 = 65280 fits in the
    # extension's 65535 bytes, the 256th entry does not.
    var long = String()
    for _ in range(255):
        long += "p"
    var protocols = List[String]()
    for _ in range(256):
        protocols.append(long)
    var alpn = TlsConfig()
    try:
        alpn.set_alpn_protocols(protocols)
        raise Error("an ALPN list over 65535 bytes was accepted")
    except e:
        _expect_raise_has(e, "s2n_config_append_protocol_preference[255] failed", "ALPN overflow")
    print("    OK")


def test_empty_config_refusals() raises:
    print("  test_empty_config_refusals...")
    # The handle's null sentinel: s2n refuses each call with S2N_ERR_NULL.
    var empty = TlsConfig(_handle=ArcPointer[_S2nConfigHandle](_S2nConfigHandle()))
    try:
        empty.disable_verify()
        raise Error("disable_verify on a NULL config did not raise")
    except e:
        _expect_raise_has(e, "TlsConfig.disable_verify: s2n_config_disable_x509_verification failed", "disable_verify")
    try:
        empty.wipe_trust()
        raise Error("wipe_trust on a NULL config did not raise")
    except e:
        _expect_raise_has(e, "TlsConfig.wipe_trust: s2n_config_wipe_trust_store failed", "wipe_trust")
    try:
        empty.enable_session_tickets()
        raise Error("enable_session_tickets on a NULL config did not raise")
    except e:
        _expect_raise_has(e, "s2n_config_set_session_tickets_onoff failed", "enable_session_tickets")
    try:
        var _server = TlsConnection(empty)
        raise Error("a server connection was bound to a NULL config")
    except e:
        _expect_raise_has(e, "TlsConnection.__init__: s2n_connection_set_config failed", "server ctor")
    try:
        var _client = TlsConnection.new_client(empty)
        raise Error("a client connection was bound to a NULL config")
    except e:
        _expect_raise_has(e, "TlsConnection.new_client: s2n_connection_set_config failed", "client ctor")
    print("    OK")


def test_before_handshake() raises:
    print("  test_before_handshake...")
    var server_config = _server_config(False)
    var client_config = _client_config(False)
    var server = TlsConnection(server_config)
    var client = TlsConnection.new_client(client_config)
    _expect_eq(Int(server.fd()), -1, "unbound fd")
    if Int(client._config_raw_ptr_for_test()) != Int(client_config._raw_config_ptr()):
        raise Error("the connection's config clone is not the caller's s2n config")
    if server.sni_hostname():
        raise Error("sni_hostname before any ClientHello is not None")
    _expect_eq(client.negotiated_tls_version(), -1, "client version before handshake")
    if client.negotiated_cipher() != String():
        raise Error("negotiated_cipher before handshake: '" + client.negotiated_cipher() + "'")
    if client.negotiated_protocol():
        raise Error("negotiated_protocol before handshake is not None")
    if client.last_handshake_message_name() != String("CLIENT_HELLO"):
        raise Error("last message before handshake: '" + client.last_handshake_message_name() + "'")
    if client.get_session():
        raise Error("get_session before handshake is not None")
    # SNI: client-only, at most 255 bytes.
    try:
        server.set_server_name(String("localhost"))
        raise Error("a server connection accepted set_server_name")
    except e:
        _expect_raise_has(e, "TlsConnection.set_server_name: s2n_set_server_name failed", "server SNI")
    var name = String()
    for _ in range(256):
        name += "a"
    try:
        client.set_server_name(name)
        raise Error("a 256-byte server name was accepted")
    except e:
        _expect_raise_has(e, "s2n_set_server_name failed", "256-byte SNI")
    # Session: empty and malformed blobs are refused.
    var no_bytes = _zeros(0)
    try:
        client.set_session(Span[UInt8](no_bytes))
        raise Error("an empty session blob was accepted")
    except e:
        _expect_raise_has(e, "TlsConnection.set_session: empty session blob", "empty blob")
    var bad = List[UInt8]()
    for _ in range(8):
        bad.append(UInt8(0xFF))
    try:
        client.set_session(Span[UInt8](bad))
        raise Error("a malformed session blob was accepted")
    except e:
        _expect_raise_has(e, "s2n_connection_set_session failed", "malformed blob")
    # An empty send is DONE(0) and writes nothing, even unbound.
    _expect_pair(client.send(Span[UInt8](no_bytes)), TLS_OUTCOME_DONE, 0, "empty send")
    _expect_eq(client.wire_bytes_moved(), 0, "wire bytes after an empty send")
    # A NULL connection has no message name.
    if s2n_last_message_name(_null_ptr[NoneType, _S2N_FFI_ORIGIN]()) != String("(null)"):
        raise Error("s2n_last_message_name(NULL) is not '(null)'")
    if s2n_strerror_debug_message(last_s2n_errno()).byte_length() == 0:
        raise Error("no debug text for the last s2n error")
    print("    OK")


def test_tls12_session_recv_and_close() raises:
    print("  test_tls12_session_recv_and_close...")
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
        _expect_eq(client.negotiated_tls_version(), TLS_VERSION_TLS12, "client version")
        _expect_eq(server.negotiated_tls_version(), TLS_VERSION_TLS12, "server version")
        if client.negotiated_cipher().find("-") < 0:
            raise Error("TLS 1.2 cipher name: '" + client.negotiated_cipher() + "'")
        if client.last_handshake_message_name() != String("APPLICATION_DATA"):
            raise Error("last message after handshake: '" + client.last_handshake_message_name() + "'")
        if client.negotiated_protocol():
            raise Error("ALPN negotiated with no ALPN configured")
        var sni = server.sni_hostname()
        if not sni or sni.value() != String("localhost"):
            raise Error("server did not see SNI 'localhost'")
        try:
            client.request_key_update(PeerKeyUpdate.NOT_REQUESTED)
            raise Error("key update accepted on TLS 1.2")
        except e:
            _expect_raise_has(e, "key update needs TLS 1.3 (negotiated protocol version 33)", "TLS 1.2 key update")

        # The session blob of this connection is accepted by a fresh one.
        var blob = client.get_session()
        if not blob:
            raise Error("no session state after a TLS 1.2 handshake")
        var next_client = TlsConnection.new_client(client_config)
        next_client.set_session(Span[UInt8](blob.value()))

        # recv into a List: 100 bytes in one record, read 64 then 36.
        var payload = _payload(100, 1)
        _expect_pair(server.send(Span[UInt8](payload)), TLS_OUTCOME_DONE, 100, "server send 100")
        var buf = List[UInt8](capacity=64)
        for _ in range(3):
            buf.append(UInt8(0xEE))
        _expect_pair(client.recv(buf, 64), TLS_OUTCOME_DONE, 64, "recv 64 of a 100-byte record")
        _expect_eq(len(buf), 64, "List length after a 64-byte read")
        for i in range(64):
            if buf[i] != payload[i]:
                raise Error("recv byte " + String(i) + " differs")
        _expect_pair(client.recv(buf, 64), TLS_OUTCOME_DONE, 36, "recv the 36 left")
        for i in range(36):
            if buf[i] != payload[64 + i]:
                raise Error("recv byte " + String(64 + i) + " differs")
        _expect_pair(client.recv(buf, 64), TLS_OUTCOME_BLOCKED_ON_READ, -1, "recv with nothing sent")
        _expect_eq(len(buf), 36, "List length after a blocked read")

        # Zero-capacity reads: a block while s2n holds plaintext, DONE(0) once not.
        var ten = _payload(10, 2)
        _expect_pair(server.send(Span[UInt8](ten)), TLS_OUTCOME_DONE, 10, "server send 10")
        var four = _zeros(4)
        _expect_pair(client.recv_into_span(Span[UInt8](four)), TLS_OUTCOME_DONE, 4, "read 4 of 10")
        var none = _zeros(0)
        _expect_pair(client.recv_into_span(Span[UInt8](none)), TLS_OUTCOME_BLOCKED_ON_READ, 0, "zero-capacity, 6 buffered")
        var six = _zeros(16)
        _expect_pair(client.recv_into_span(Span[UInt8](six)), TLS_OUTCOME_DONE, 6, "read the 6 left")
        _expect_pair(client.recv_into_span(Span[UInt8](none)), TLS_OUTCOME_DONE, 0, "zero-capacity, none buffered")

        # close_notify: the server's shutdown waits for the client's alert.
        _expect_eq(Int(server.shutdown()), Int(TLS_OUTCOME_BLOCKED_ON_READ), "server shutdown first")
        _expect_pair(client.recv_into_span(Span[UInt8](six)), TLS_OUTCOME_DONE, 0, "client read of close_notify")
        _expect_pair(client.recv(buf, 64), TLS_OUTCOME_DONE, 0, "client recv after close_notify")
        _expect_eq(len(buf), 0, "List length at EOF")
        _expect_eq(Int(client.shutdown()), Int(TLS_OUTCOME_DONE), "client shutdown")
        _expect_eq(Int(server.shutdown()), Int(TLS_OUTCOME_DONE), "server shutdown second")
        # Sending on a closed connection is an error, not a zero-byte success.
        _expect_pair(client.send(Span[UInt8](ten)), TLS_OUTCOME_ERROR, -1, "send after shutdown")
        _expect_err_type(S2N_ERR_T_CLOSED, "send after shutdown")
    finally:
        _close_fd(fds[0])
        _close_fd(fds[1])
    print("    OK")


def test_tls13_blocked_send_and_reset() raises:
    print("  test_tls13_blocked_send_and_reset...")
    var server_config = _server_config(True)
    var client_config = _client_config(True)
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    server_config.set_alpn_protocols(alpn)
    client_config.set_alpn_protocols(alpn)
    var fds = _socketpair()
    var server_fd = fds[0]
    try:
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        try:
            client.request_key_update(PeerKeyUpdate.NOT_REQUESTED)
            raise Error("key update accepted before the handshake")
        except e:
            _expect_raise_has(e, "TlsConnection.request_key_update: handshake not complete", "early key update")
        _handshake(server, client)
        _expect_eq(client.negotiated_tls_version(), TLS_VERSION_TLS13, "client version")
        if not client.negotiated_cipher().startswith("TLS_"):
            raise Error("TLS 1.3 cipher name: '" + client.negotiated_cipher() + "'")
        var proto = client.negotiated_protocol()
        if not proto or proto.value() != String("h2"):
            raise Error("ALPN did not negotiate h2")
        if client.wire_bytes_moved() <= 0:
            raise Error("no wire bytes counted after a handshake")
        try:
            client.request_key_update(PeerKeyUpdate.REQUESTED)
            raise Error("s2n accepted a REQUESTED key update")
        except e:
            _expect_raise_has(e, "TlsConnection.request_key_update: invalid argument", "REQUESTED")
        client.request_key_update(PeerKeyUpdate.NOT_REQUESTED)

        # Fill the socket: the server reads nothing until a send blocks. A
        # small client send buffer makes the block independent of the
        # worker's default: an AF_UNIX stream send on Linux is charged to the
        # sender's SO_SNDBUF until the peer reads it, and never consults the
        # peer's SO_RCVBUF (net/unix/af_unix.c, unix_stream_sendmsg), so the
        # client side is the only one to set.
        set_so_sndbuf(fds[1], _SMALL_SNDBUF)
        var granted = so_sndbuf(fds[1])
        if granted > _MAX_EFFECTIVE_SNDBUF:
            raise Error("SO_SNDBUF " + String(Int(granted)) + " after asking for " + String(Int(_SMALL_SNDBUF)))
        var total = 1024 * 1024
        var payload = _payload(total, 3)
        var off = 0
        var blocked = False
        for _ in range(4096):
            var end = min(off + 16384, total)
            var res = client.send(Span[UInt8](payload)[off:end].as_imm())
            if res[0] == TLS_OUTCOME_BLOCKED_ON_WRITE:
                _expect_eq(res[1], 0, "bytes accepted by a blocked send")
                blocked = True
                break
            _expect_eq(Int(res[0]), Int(TLS_OUTCOME_DONE), "send before the block")
            off += res[1]
        if not blocked:
            raise Error("4096 sends of 16 KiB never blocked")
        # An empty send makes no s2n call. s2n would take one (it returns 0
        # for an empty send), but only after flushing the pending record,
        # which blocks here.
        var no_bytes = _zeros(0)
        var wire_before = client.wire_bytes_moved()
        _expect_pair(client.send(Span[UInt8](no_bytes)), TLS_OUTCOME_DONE, 0, "empty send with a record pending")
        _expect_eq(client.wire_bytes_moved(), wire_before, "wire bytes after an empty send with a record pending")
        var counts = client.key_update_counts()
        _expect_eq(counts.sent, 1, "client key updates sent")
        # Drain and finish: every byte arrives once, in order.
        var got = List[UInt8](capacity=off + 16384)
        var scratch = _zeros(16384)
        var iters = 0
        while len(got) < total:
            iters += 1
            if iters > 200000:
                raise Error("stalled at sent=" + String(off) + " received=" + String(len(got)))
            if off < total:
                var end = min(off + 16384, total)
                var res = client.send(Span[UInt8](payload)[off:end].as_imm())
                if res[0] == TLS_OUTCOME_ERROR:
                    raise Error("send: " + s2n_strerror_message(last_s2n_errno()))
                off += res[1]
            var rr = server.recv_into_span(Span[UInt8](scratch))
            if rr[0] == TLS_OUTCOME_ERROR:
                raise Error("recv: " + s2n_strerror_message(last_s2n_errno()))
            for k in range(max(rr[1], 0)):
                got.append(scratch[k])
        for i in range(total):
            if got[i] != payload[i]:
                raise Error("byte " + String(i) + " differs after the blocked send")
        _expect_eq(server.key_update_counts().received, 1, "server key updates received")

        # The server closes with a record unread: ECONNRESET on the client.
        # That holds only while the unread record exists: Linux resets the
        # peer when an AF_UNIX stream socket closes with data in its receive
        # queue; with the queue empty the client sees EOF instead
        # (test_abrupt_close_is_eof).
        _expect_pair(client.send(Span[UInt8](payload)[0:100].as_imm()), TLS_OUTCOME_DONE, 100, "send left unread")
        _close_fd(server_fd)
        server_fd = Int32(-1)
        _expect_pair(client.recv_into_span(Span[UInt8](scratch)), TLS_OUTCOME_ERROR, -1, "recv after a reset")
        _expect_err_type(S2N_ERR_T_IO, "recv after a reset")
        _expect_pair(client.send(Span[UInt8](payload)[0:100].as_imm()), TLS_OUTCOME_ERROR, -1, "send after a reset")
        _expect_err_type(S2N_ERR_T_IO, "send after a reset")
    finally:
        _close_fd(server_fd)
        _close_fd(fds[1])
    print("    OK")


def test_abrupt_close_is_eof() raises:
    print("  test_abrupt_close_is_eof...")
    var server_config = _server_config(False)
    var client_config = _client_config(False)
    var fds = _socketpair()
    var server_fd = fds[0]
    try:
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _handshake(server, client)
        var scratch = _zeros(64)
        _expect_pair(client.recv_into_span(Span[UInt8](scratch)), TLS_OUTCOME_BLOCKED_ON_READ, -1, "recv before close")
        # No close_notify: the socket just closes.
        _close_fd(server_fd)
        server_fd = Int32(-1)
        _expect_pair(client.recv_into_span(Span[UInt8](scratch)), TLS_OUTCOME_DONE, 0, "recv after a FIN")
        _expect_err_type(S2N_ERR_T_CLOSED, "recv after a FIN")
        var buf = List[UInt8](capacity=64)
        buf.append(UInt8(1))
        _expect_pair(client.recv(buf, 64), TLS_OUTCOME_DONE, 0, "recv into a List after a FIN")
        _expect_eq(len(buf), 0, "List length at an abrupt EOF")
    finally:
        _close_fd(server_fd)
        _close_fd(fds[1])
    print("    OK")


def main() raises:
    print("== L1 TLS s2n shim arms ==")
    tls_init()
    test_outcome_table()
    test_config_refusals()
    test_empty_config_refusals()
    test_before_handshake()
    test_tls12_session_recv_and_close()
    test_tls13_blocked_send_and_reset()
    test_abrupt_close_is_eof()
    print("== L1 TLS s2n shim arms PASSED (7 tests) ==")
