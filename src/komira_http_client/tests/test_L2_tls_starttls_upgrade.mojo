# =============================================================================
# TlsConnector.upgrade: the STARTTLS entry point (plain TCP -> TLS on the same
# connection).
#
# A STARTTLS client speaks plaintext up to the server's go-ahead
# (`220 Ready to start TLS`) and then runs the TLS client handshake on the same
# socket. Anything the server sent after the go-ahead and before the handshake
# is plaintext an on-path attacker can inject (the STARTTLS command-injection
# class): a client that keeps it reads it later as if it had arrived inside
# the TLS session.
#
# What each test proves:
#
#   test_upgrade_refuses_pre_handshake_bytes
#       The client reader took `220 ...` plus an injected `250 ...` off the
#       socket in one read and handed the surplus back with `unread`. The
#       upgrade must raise the exact refusal, send no handshake byte, and
#       close the connection. Mutant: drop the `has_buffered_readable`
#       refusal in `upgrade` (the pushback is kept) -> the handshake starts,
#       a ClientHello goes out, and the call fails on the wall-clock deadline
#       instead: red on the message and on the peer's read.
#
#   test_upgrade_completes_and_carries_tls_application_data
#       After a plaintext 220 line the handshake runs over the same socketpair
#       against a real s2n server on a helper thread; an encrypted request and
#       reply round-trip through the returned TlsClientStream byte-exact.
#
#   test_upgrade_refuses_verify_peer_without_server_name
#       `upgrade` applies `connect`'s server-name rule: a VERIFY_PEER
#       connector with no server name is refused before any handshake byte.
#       Mutant: drop `_refuse_unverifiable_peer()` from `upgrade` -> red.
#
# Pointer discipline: UnsafePointer use is confined to the socketpair and
# pthread FFI of this test: the FFI calls, the heap `_ServerArg` handed to
# the server thread (its fields and the functions that build, run and free
# it) and the PEM buffers it carries, with concrete or MutUntrackedOrigin
# origins. tests/pointer_lint_ffi.tsv lists this file as an FFI module.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.socket_io import try_io_read, try_io_write
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.tcp_stream import TcpStream

from komira_http_client.pool import VERIFY_PEER, VERIFY_SKIP
from komira_http_client.tls_connector import TlsClientStream, TlsConnector
from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    tls_init,
)
from komira_http_core.transport.kernel_tcp import (
    KernelTcpConnector,
    TcpIoStream,
)


comptime _RT = BlockingRuntime[NoopSink]

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

comptime _GO_AHEAD = "220 2.0.0 Ready to start TLS\r\n"
comptime _INJECTED = "250 2.0.0 INJECTED\r\n"
comptime _REQUEST = "EHLO client.example\r\n"
comptime _REPLY = "250 secure.example\r\n"

comptime _REFUSAL = (
    "TlsConnector.upgrade: refusing the TLS upgrade: the plaintext stream"
    " holds bytes the peer sent before the TLS handshake. They are not handed"
    " to TLS and not served after it; the connection is closed."
)
comptime _NO_NAME_REFUSAL = (
    "TlsConnector: refusing VERIFY_PEER connect with an empty server name"
    " (hostname would not be verified); call set_server_name_for_next_connect"
    " or dial via HttpClient"
)

# The handshake budget for the refusal tests: the refusals must fire before
# any handshake, so a mutant that lets the handshake start ends on this
# deadline instead (the peer never answers).
comptime _SHORT_DEADLINE_US: Int64 = 300_000


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


def _leaf_cert() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: `sv` outlives the synchronous call; two Int32 slots.
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv_ptr,
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
        raise Error("_set_nonblock returned " + String(Int(rc)))


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def _write_all(fd: Int32, text: String) raises:
    """Write `text` to `fd` in one send; a socketpair takes it whole."""
    var bytes = _bytes(text)
    var r = try_io_write(fd, Span(bytes))
    if not r.is_ready() or Int(r.value()) != len(bytes):
        raise Error(
            "send wrote " + String(r.value()) + " of " + String(len(bytes))
        )


def _peer_read_state(fd: Int32) -> String:
    """What one non-blocking read on `fd` sees: "EOF", "WOULD_BLOCK",
    "DATA:<n>" or "ERROR:<errno>". The bytes are discarded."""
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var r = try_io_read(fd, Span(buf))
    if r.is_ready():
        if r.value() == 0:
            return String("EOF")
        return String("DATA:") + String(r.value())
    if r.is_would_block():
        return String("WOULD_BLOCK")
    return String("ERROR:") + String(r.value())


def _text(buf: List[UInt8], n: Int) -> String:
    return String(unsafe_from_utf8=Span(buf)[:n])


def _skip_connector(deadline_us: Int64) raises -> TlsConnector[
    KernelTcpConnector
]:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    var connector = TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector(_placeholder=UInt8(0)), VERIFY_SKIP,
    )
    connector.set_server_name_for_next_connect(String("localhost"))
    connector.set_handshake_deadline_us(deadline_us)
    return connector^


def _read_exact_plain[
    o: Origin[mut=True]
](
    mut stream: TcpIoStream,
    mut rt: _RT,
    dst: Span[UInt8, o],
) raises -> Int:
    """Read once into `dst` (the bytes are already in the socketpair)."""
    var r = stream.try_read[_RT](rt.reactor(), dst)
    if not r.is_ready():
        raise Error("plaintext read did not return Ready")
    return Int(r.n_bytes())


# -----------------------------------------------------------------------------
# 1. Pre-handshake bytes held on the stream are refused.
# -----------------------------------------------------------------------------


def test_upgrade_refuses_pre_handshake_bytes() raises:
    print("  test_upgrade_refuses_pre_handshake_bytes...")
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    try:
        # The go-ahead and the injected line arrive in one segment.
        _write_all(server_fd, String(_GO_AHEAD) + String(_INJECTED))
        var plain = TcpIoStream(TcpStream(client_fd))
        var buf = List[UInt8](length=256, fill=UInt8(0))
        var n = _read_exact_plain(plain, rt, Span(buf))
        var go_len = String(_GO_AHEAD).byte_length()
        assert_equal(
            n, go_len + String(_INJECTED).byte_length(),
            "PRECONDITION: one read takes the go-ahead and the injected line",
        )
        assert_equal(_text(buf, go_len), String(_GO_AHEAD))
        # The reader keeps its line and hands the surplus back.
        plain.unread(Span(buf)[go_len:n])
        assert_true(
            plain.has_buffered_readable(),
            "PRECONDITION: the injected bytes are held on the stream",
        )

        var connector = _skip_connector(_SHORT_DEADLINE_US)
        var message = String("")
        try:
            var tls = connector.upgrade[_RT](rt.reactor(), plain^)
            _ = tls^
        except e:
            message = String(e)
        assert_equal(message, String(_REFUSAL))

        # No ClientHello went out and the connection is closed: the peer's
        # next read is EOF, not handshake bytes and not WOULD_BLOCK.
        assert_equal(
            _peer_read_state(server_fd), String("EOF"),
            "the peer must see EOF: no handshake byte, connection closed",
        )
    finally:
        _close_fd(server_fd)
    print("    OK: refused before the handshake; peer sees EOF")


# -----------------------------------------------------------------------------
# 2. A clean upgrade completes and carries application data.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ServerArg(Copyable, Movable, Deinitable):
    var server_fd: Int32
    var cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var cert_len: Int
    var key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var key_len: Int
    # 0 = running, 1 = request read and reply sent, 2 = error,
    # 3 = the decrypted request differed from `_REQUEST`.
    var done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin]


def _server_entry(
    raw: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """Detached server thread; ABI of pthread `void* (*)(void*)`.

    # FFI-BOUNDARY: `raw` is the heap `_ServerArg` this thread owns and frees
    # after copying its POD fields. The cert/key buffers are freed by the main
    # thread after it observes the done flag. Raises are caught in
    # `_run_server` and reported through the flag."""
    var arg = raw.bitcast[_ServerArg]()
    var server_fd = arg[].server_fd
    var cert_ptr = arg[].cert_ptr
    var cert_len = arg[].cert_len
    var key_ptr = arg[].key_ptr
    var key_len = arg[].key_len
    var done_flag_ptr = arg[].done_flag_ptr
    arg.bitcast[UInt8]().free()
    done_flag_ptr[] = _run_server(
        server_fd, cert_ptr, cert_len, key_ptr, key_len,
    )
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_server(
    server_fd: Int32,
    cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    cert_len: Int,
    key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    key_len: Int,
) -> Int32:
    """TLS server: handshake, read `_REQUEST`, answer `_REPLY`, close."""
    try:
        var cert_bytes = List[UInt8]()
        for i in range(cert_len):
            cert_bytes.append(cert_ptr[i])
        var key_bytes = List[UInt8]()
        for i in range(key_len):
            key_bytes.append(key_ptr[i])
        var config = TlsConfig()
        config.load_cert(
            String(unsafe_from_utf8=Span(cert_bytes)),
            String(unsafe_from_utf8=Span(key_bytes)),
        )
        var conn = TlsConnection(config)
        conn.bind_fd(server_fd)
        var iters = 0
        var done = False
        while iters < 2_000_000:
            iters = iters + 1
            var o = conn.handshake()
            if o == TLS_OUTCOME_DONE:
                done = True
                break
            if o == TLS_OUTCOME_ERROR:
                return Int32(2)
            _ = external_call["usleep", Int32](UInt32(100))
        if not done:
            return Int32(2)

        var want = String(_REQUEST).byte_length()
        var got = List[UInt8](length=want, fill=UInt8(0))
        var have = 0
        iters = 0
        while have < want and iters < 2_000_000:
            iters = iters + 1
            var r = conn.recv_into_span(Span(got)[have:])
            if r[0] == TLS_OUTCOME_ERROR:
                return Int32(2)
            if r[0] == TLS_OUTCOME_DONE:
                if r[1] == 0:
                    return Int32(2)
                have = have + r[1]
            else:
                _ = external_call["usleep", Int32](UInt32(100))
        if have < want:
            return Int32(2)
        if String(unsafe_from_utf8=Span(got)) != String(_REQUEST):
            return Int32(3)

        var reply = _bytes(String(_REPLY))
        var sent = 0
        iters = 0
        while sent < len(reply) and iters < 2_000_000:
            iters = iters + 1
            var w = conn.send(Span(reply)[sent:])
            if w[0] == TLS_OUTCOME_ERROR:
                return Int32(2)
            if w[0] == TLS_OUTCOME_DONE:
                sent = sent + w[1]
            else:
                _ = external_call["usleep", Int32](UInt32(100))
        if sent < len(reply):
            return Int32(2)
        _ = conn^
        _close_fd(server_fd)
        return Int32(1)
    except:
        return Int32(2)


def _spawn_server_thread(
    server_fd: Int32,
    cert: String,
    key: String,
    done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin],
) raises -> Tuple[
    UnsafePointer[UInt8, MutUntrackedOrigin],
    UnsafePointer[UInt8, MutUntrackedOrigin],
]:
    """pthread_create a detached server thread over heap copies of the cert
    and key; returns those buffers for the main thread to free."""
    var cert_len = cert.byte_length()
    var key_len = key.byte_length()
    var cert_buf = alloc[UInt8](cert_len).unsafe_origin_cast[MutUntrackedOrigin]()
    var key_buf = alloc[UInt8](key_len).unsafe_origin_cast[MutUntrackedOrigin]()
    var cs = cert.as_bytes()
    for i in range(cert_len):
        cert_buf[i] = cs[i]
    var ks = key.as_bytes()
    for i in range(key_len):
        key_buf[i] = ks[i]
    var raw = alloc[_ServerArg](1)
    UnsafePointer(to=raw[]).unsafe_write(
        _ServerArg(
            server_fd=server_fd,
            cert_ptr=cert_buf,
            cert_len=cert_len,
            key_ptr=key_buf,
            key_len=key_len,
            done_flag_ptr=done_flag_ptr,
        )
    )
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    var tid: Int64 = 0
    # SAFETY: `tid` outlives the synchronous pthread_create.
    var slot = UnsafePointer(to=tid)
    var rc = external_call["pthread_create", Int32](
        slot.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _server_entry,
        raw_void,
    )
    if rc != Int32(0):
        raise Error("pthread_create returned " + String(Int(rc)))
    _ = external_call["pthread_detach", Int32](tid)
    return (cert_buf, key_buf)


def test_upgrade_completes_and_carries_tls_application_data() raises:
    print("  test_upgrade_completes_and_carries_tls_application_data...")
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))

    # Plaintext phase: the go-ahead, read exactly.
    _write_all(server_fd, String(_GO_AHEAD))
    var plain = TcpIoStream(TcpStream(client_fd))
    var go_len = String(_GO_AHEAD).byte_length()
    var buf = List[UInt8](length=go_len, fill=UInt8(0))
    var n = _read_exact_plain(plain, rt, Span(buf))
    assert_equal(n, go_len)
    assert_equal(_text(buf, n), String(_GO_AHEAD))

    var done_flag: Int32 = 0
    # SAFETY: `done_flag` lives until this function returns, after the
    # server thread has written its final value (or the wait gave up).
    var done_flag_ptr = UnsafePointer(to=done_flag).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var bufs = _spawn_server_thread(
        server_fd, _leaf_cert(), _leaf_key(), done_flag_ptr,
    )

    # The default 30 s budget: this handshake must succeed.
    var connector = _skip_connector(Int64(30_000_000))
    var tls = connector.upgrade[_RT](rt.reactor(), plain^)

    var req = _bytes(String(_REQUEST))
    var sent = 0
    var iters = 0
    while sent < len(req) and iters < 200_000:
        iters = iters + 1
        var w = tls.try_write[_RT](rt.reactor(), Span(req)[sent:])
        if w.is_error():
            raise Error("try_write error " + String(w.errno()))
        if w.is_ready():
            sent = sent + Int(w.n_bytes())
        else:
            _ = external_call["usleep", Int32](UInt32(100))
    assert_equal(sent, len(req), "the request must go out whole")

    var want = String(_REPLY).byte_length()
    var got = List[UInt8](length=want, fill=UInt8(0))
    var have = 0
    iters = 0
    while have < want and iters < 200_000:
        iters = iters + 1
        var r = tls.try_read[_RT](rt.reactor(), Span(got)[have:])
        if r.is_error() or r.is_eof():
            break
        if r.is_ready():
            have = have + Int(r.n_bytes())
        else:
            _ = external_call["usleep", Int32](UInt32(100))
    assert_equal(_text(got, have), String(_REPLY))

    var wait = 0
    while done_flag == 0 and wait < 2000:
        wait = wait + 1
        _ = external_call["usleep", Int32](UInt32(5000))
    assert_equal(
        Int(done_flag), 1,
        "server thread: 1 = request matched and reply sent, 2 = error,"
        " 3 = decrypted request differed",
    )
    bufs[0].free()
    bufs[1].free()
    _ = tls^
    print("    OK: upgraded on the same socket; request and reply round-trip")


# -----------------------------------------------------------------------------
# 3. The server-name rule of `connect` applies to `upgrade`.
# -----------------------------------------------------------------------------


def test_upgrade_refuses_verify_peer_without_server_name() raises:
    print("  test_upgrade_refuses_verify_peer_without_server_name...")
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    try:
        var connector = TlsConnector[KernelTcpConnector](
            TlsConfig(), KernelTcpConnector(_placeholder=UInt8(0)),
            VERIFY_PEER,
        )
        connector.set_handshake_deadline_us(_SHORT_DEADLINE_US)
        var plain = TcpIoStream(TcpStream(client_fd))
        var message = String("")
        try:
            var tls = connector.upgrade[_RT](rt.reactor(), plain^)
            _ = tls^
        except e:
            message = String(e)
        assert_equal(message, String(_NO_NAME_REFUSAL))
        assert_equal(
            _peer_read_state(server_fd), String("EOF"),
            "the peer must see EOF: no handshake byte, connection closed",
        )
    finally:
        _close_fd(server_fd)
    print("    OK: VERIFY_PEER without a server name refused")


def main() raises:
    print("== L2 TlsConnector.upgrade (STARTTLS) ==")
    tls_init()
    test_upgrade_refuses_pre_handshake_bytes()
    test_upgrade_completes_and_carries_tls_application_data()
    test_upgrade_refuses_verify_peer_without_server_name()
    print("== L2 TlsConnector.upgrade PASSED (3 tests) ==")
