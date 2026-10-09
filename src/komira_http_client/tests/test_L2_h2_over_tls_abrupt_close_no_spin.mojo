# =============================================================================
# THE CLOSED-PEER SPIN, REPRODUCED — ITS CAUSE IS AN ABRUPT PEER CLOSE,
# NOT A TLS REKEY.
# =============================================================================
#
# A request on a reaped pooled connection used to end as
#
#   HttpError[TIMEOUT]: h2 driver iteration cap exceeded
#   (iters=100001, elapsed_ms=753, wall_budget_ms=120000,
#    parks=100000, idle_parks=0)
#
# A TLS 1.3 rekey answering a `s2n_send` with BLOCKED_ON_READ does NOT explain
# it: s2n-tls v1.5.6 structurally cannot answer a send with BLOCKED_ON_READ nor
# a recv with BLOCKED_ON_WRITE, so no rekey can reach a hardcoded-direction
# site. This file pins the real cause.
#
# -----------------------------------------------------------------------------
# THE MECHANISM, read out of the s2n-tls v1.5.6 source
# -----------------------------------------------------------------------------
#
#   tls/s2n_recv.c:176   `*blocked = S2N_BLOCKED_ON_READ;`   <- set at ENTRY,
#                        unconditionally, BEFORE any I/O is attempted. The
#                        comment above it says so: "The only case in which it
#                        should be updated is on a successful read".
#   tls/s2n_recv.c:281-290  `if (s2n_stuffer_data_available(&conn->in) == 0)
#                            { *blocked = S2N_NOT_BLOCKED; }`  <- the ONLY
#                        reset, and it sits AFTER the read loop, so no error
#                        return ever reaches it.
#   tls/s2n_recv.c:66-70  `s2n_read_in_bytes`: a socket read of 0 (peer FIN)
#                        sets `conn->read_closed` and bails S2N_ERR_CLOSED
#                        (utils/s2n_io.c:33-38).
#   tls/s2n_recv.c:203-206  that error is only swallowed `if (bytes_read && ...)`.
#                        With zero bytes read it falls to
#                        `S2N_ERROR_PRESERVE_ERRNO()` — return -1, and
#                        `*blocked` is still BLOCKED_ON_READ.
#   tls/s2n_recv.c:178   EVERY SUBSEQUENT CALL then short-circuits on
#                        `!s2n_connection_check_io_status(conn, S2N_IO_READABLE)`
#                        (read_closed is set — tls/s2n_connection.c:1707-1745)
#                        and fails `POSIX_ENSURE(close_notify_received,
#                        S2N_ERR_CLOSED)`, returning -1 with `*blocked` still
#                        BLOCKED_ON_READ from line 176.
#
# ⇒ AFTER AN ABRUPT PEER CLOSE (FIN WITHOUT close_notify — what every load
#   balancer and every GFE does when it reaps an idle pooled connection),
#   `s2n_recv` RETURNS (-1, BLOCKED_ON_READ) FOREVER.
#
# `*blocked` IS THEREFORE NOT A DISAMBIGUATOR ON THE RECV PATH, and
# the claim that it is
# is false for exactly this case (see `_blocked_status_to_outcome` in
# s2n_shim.mojo). s2n's own public API
# names the right one: `s2n_error_get_type(s2n_errno)` — S2N_ERR_T_BLOCKED for a
# genuine would-block, S2N_ERR_T_CLOSED for a closed peer (api/s2n.h:149-163,
# 168-176).
#
# -----------------------------------------------------------------------------
# WHY THAT PRODUCES `parks=100000, idle_parks=0` AND NOTHING ELSE DOES
# -----------------------------------------------------------------------------
#
# A shim that maps BLOCKED_ON_READ -> `StreamIo.pending` makes a CLOSED
# connection indistinguishable from a slow one. `drive_h2_streams_to_completion` parks on
# read-readiness — and a socket whose peer has closed is PERMANENTLY readable
# (level-triggered EPOLLIN, read() returns 0). So the park returns READY on its
# first poll, is counted NON-IDLE, the retry returns Pending again, zero bytes
# move, and the loop spins at the cost of one epoll_wait + one s2n_recv until
# the iteration cap. That is `idle_parks=0` exactly, at ~7.5us a trip.
#
# Asking the stream for the wait direction does not help: the Pending token's
# bit 0 says blocked-on-READ, which is the direction the read branch already
# waits on. The LIVELOCK detector only changes the give-up WORD and the budget
# (LIVELOCK at 4096 instead of TIMEOUT at 100000). ⇒ The fix is in the shim's
# recv mapping, and this file is its falsifier.
#
# -----------------------------------------------------------------------------
# WHAT THIS FILE ASSERTS
# -----------------------------------------------------------------------------
#
#   §0  THE s2n CONTRACT, pinned by calling `s2n_recv` DIRECTLY over the raw
#       connection — immune to any fix we make in our own shim, so it keeps
#       telling the truth after §1 goes green and reds if an s2n bump changes
#       the behaviour. Non-vacuity: the handshake must have reached DONE and
#       the peer must actually have closed.
#
#   §1  THE PRODUCTION PATH: `drive_h2_streams_to_completion` over a REAL
#       `TlsClientStream[TcpIoStream]`, real cert, real TLS 1.3 handshake, real
#       h2 frames, peer closes mid-response. It must raise EOF_MID_RESPONSE —
#       the thing a plain TCP socket does — and it must NOT spin. Both halves
#       are asserted: the error CLASS, and the counter signature
#       (`parks` small) that says it did not burn a budget getting there.
#
# Pointer discipline: UnsafePointer use is confined to the
# socketpair / pthread / s2n out-param FFI thunks (concrete or
# MutExternalOrigin AT the FFI boundary, never crossing a non-FFI module) — the
# same carve-out as `test_L2_h2_over_tls_real_rekey.mojo`, which this harness
# clones.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import alloc
from std.testing import assert_true, assert_false, assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.h2_client import (
    H2ClientConnectionState,
    drive_h2_streams_to_completion,
    encode_request_headers_to_frames,
    queue_client_preface_and_settings,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.tls_connector import TlsClientStream
from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.kernel_tcp import TcpIoStream
from komira_async.runtime.tcp_stream import TcpStream

from komira_http_core.tls import (
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
from komira_http_core.tls.ffi import (
    S2N_BLOCKED_ON_READ,
    S2N_NOT_BLOCKED,
    S2nOpaquePtr,
    _S2N_FFI_ORIGIN,
)
from std.pathlib import Path


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Origin `o` is
    # concrete; the NULL sentinel is never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


comptime _RT = PerCoreAsyncRuntime[NoopSink]

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

# `s2n_error_type` (api/s2n.h:147-164). ⚠ THE ENUM IS COMMENT-INTERLEAVED — the
# values are consecutive from 0 and do NOT line up with the header's line
# numbers (reading them off the line numbers gives 3, the value is 2).
# S2N_ERR_T_CLOSED's own doc comment is one word: "EOF".
comptime _S2N_ERR_T_IO: Int32 = Int32(1)
comptime _S2N_ERR_T_CLOSED: Int32 = Int32(2)
comptime _S2N_ERR_T_BLOCKED: Int32 = Int32(3)

# How many consecutive post-close `s2n_recv` calls §0 makes. The point is that
# the state is PERMANENT, not a one-shot: the driver's spin needs it to answer
# the same way on trip 100000 as on trip 1.
comptime _POST_CLOSE_PROBES: Int = 128

# Response prefix the server sends before closing. SETTINGS + HEADERS + one
# short DATA frame WITHOUT end_stream — so the client has an OPEN, INCOMPLETE
# stream when the peer vanishes (an in-flight RPC on a pooled connection the
# peer reaped).
comptime _PARTIAL_BODY_LEN: Int = 64


# -----------------------------------------------------------------------------
# Fixtures + libc helpers (identical to the harness this clones).
# -----------------------------------------------------------------------------


def _leaf_cert() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
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


def _outcome_str(o: UInt8) -> StaticString:
    """The name of a `TLS_OUTCOME_*` ordinal, for the diagnostic lines below.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape.
    As `-> String` this is a five-arm literal-return ladder, which lowers to two
    parallel (pointer, length) constant arrays whose two call-site references an
    `--emit shared-lib` link binds INDEPENDENTLY; `StaticString` keeps the
    literals literal and emits ZERO register-indexed constant-table loads.
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


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _build_client_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
    # TLS 1.3, matching the production client path (tls_connector.mojo:1054).
    # Not load-bearing for THIS defect — the abrupt-close laundering is version
    # independent (s2n_recv.c:176 has no version guard) — but the whole point is
    # to exercise the same negotiation production does.
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("h2"))
    config.set_alpn_protocols(alpn)
    return config^


def _build_server_config_from_pem(cert: String, key: String) raises -> TlsConfig:
    var config = TlsConfig()
    config.load_cert(cert, key)
    config.set_cipher_preferences(String("default_tls13"))
    var alpn = List[String]()
    alpn.append(String("h2"))
    config.set_alpn_protocols(alpn)
    return config^


def _h2_response_prefix(sid: UInt32) raises -> List[UInt8]:
    """SETTINGS + HEADERS(:status 200) + ONE short DATA frame, end_stream=False.

    Deliberately incomplete: the client is left with an OPEN stream, so when the
    peer then vanishes the driver is awaiting bytes
    for a stream that will never complete."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        sid, block^, end_stream=False, end_headers=True, out=out,
    )
    var frame_data = List[UInt8]()
    var j = 0
    while j < _PARTIAL_BODY_LEN:
        frame_data.append(UInt8((j * 31 + 7) & 0xFF))
        j = j + 1
    encode_data_frame(sid, frame_data^, False, out)
    return out^


# -----------------------------------------------------------------------------
# The SERVER, on a detached helper pthread.
#
# ⚠ THE ONE THING THAT MAKES THIS TEST WHAT IT IS: it ends with a bare
# `close(fd)` and NEVER calls `s2n_shutdown`. That is an ABRUPT close — a FIN
# with no close_notify — which is what a load balancer / GFE does when it reaps
# a pooled connection, and it is the ONLY close shape that reaches the defect.
# A graceful close_notify shutdown maps cleanly to `StreamIo.eof()` today
# (tls_connector.mojo `_map_tls_outcome_to_stream_io`: DONE + n==0 on a read)
# and would make this test pass against the broken code.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ServerArg(Copyable, Movable, Deinitable):
    var server_fd: Int32
    var cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var cert_len: Int
    var key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var key_len: Int
    # 0 = running, 1 = handshake done + (optionally) prefix sent + fd closed,
    # 2 = error.
    var done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin]
    # 1 = send an h2 response PREFIX before closing, 0 = close right after the
    # request is seen.
    var send_prefix: Int32


def _server_entry(
    raw: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    """Detached server thread. ABI matches pthread `void* (*)(void*)`.

    SAFETY (FFI-BOUNDARY): `raw` is the heap `_ServerArg` this thread solely
    owns; it reads the POD fields, frees the arg, then drives the server s2n
    connection. The cert/key buffers are freed by the MAIN thread after the
    done_flag is observed. The body is wrapped so a raise sets done_flag=2
    instead of unwinding across the FFI boundary."""
    var arg = raw.bitcast[_ServerArg]()
    var server_fd = arg[].server_fd
    var cert_ptr = arg[].cert_ptr
    var cert_len = arg[].cert_len
    var key_ptr = arg[].key_ptr
    var key_len = arg[].key_len
    var done_flag_ptr = arg[].done_flag_ptr
    var send_prefix = arg[].send_prefix
    arg.bitcast[UInt8]().free()

    var ok = _run_server(
        server_fd, cert_ptr, cert_len, key_ptr, key_len, send_prefix,
    )
    if ok:
        done_flag_ptr[] = Int32(1)
    else:
        done_flag_ptr[] = Int32(2)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_server(
    server_fd: Int32,
    cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    cert_len: Int,
    key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    key_len: Int,
    send_prefix: Int32,
) -> Bool:
    """Handshake, optionally answer with an INCOMPLETE h2 response, then close
    the socket ABRUPTLY. Any raise returns False."""
    try:
        var cert_bytes = List[UInt8]()
        var ci = 0
        while ci < cert_len:
            cert_bytes.append(cert_ptr[ci])
            ci = ci + 1
        var key_bytes = List[UInt8]()
        var ki = 0
        while ki < key_len:
            key_bytes.append(key_ptr[ki])
            ki = ki + 1
        var cert = String(unsafe_from_utf8=Span(cert_bytes))
        var key = String(unsafe_from_utf8=Span(key_bytes))
        var config = _build_server_config_from_pem(cert, key)

        var conn = TlsConnection(config)
        conn.bind_fd(server_fd)

        var hs_iters = 0
        while hs_iters < 5_000_000:
            hs_iters = hs_iters + 1
            var o = conn.handshake()
            if o == TLS_OUTCOME_DONE:
                break
            if o == TLS_OUTCOME_ERROR:
                return False
            _ = external_call["usleep", Int32](UInt32(100))
        if hs_iters >= 5_000_000:
            return False

        # Wait for the client's h2 preamble + request, so the close lands with
        # a request genuinely in flight rather than during the client's own
        # write. 24 bytes is the h2 client connection preface alone.
        var req_seen = 0
        var drain_spins = 0
        while drain_spins < 200000 and req_seen < 24:
            drain_spins = drain_spins + 1
            var buf = List[UInt8]()
            var z = 0
            while z < 16384:
                buf.append(UInt8(0))
                z = z + 1
            var r = conn.recv_into_span(Span[UInt8](buf))
            if r[0] == TLS_OUTCOME_ERROR:
                return False
            if r[1] > 0:
                req_seen = req_seen + r[1]
                continue
            _ = external_call["usleep", Int32](UInt32(200))
        if req_seen < 24:
            return False

        if send_prefix == Int32(1):
            var response = _h2_response_prefix(UInt32(1))
            var offset = 0
            var send_spins = 0
            while offset < len(response):
                send_spins = send_spins + 1
                if send_spins > 5_000_000:
                    return False
                var rem = Span[UInt8](response)[offset:].as_imm()
                var res = conn.send(rem)
                if res[0] == TLS_OUTCOME_ERROR:
                    return False
                if res[1] > 0:
                    offset = offset + res[1]
                    send_spins = 0
                    continue
                _ = external_call["usleep", Int32](UInt32(200))
            # Let the prefix land before the FIN, so the client observes
            # PROGRESS first and only then the close. Without this the client
            # may see the FIN alongside the data and the "in-flight" precondition
            # is weaker.
            _ = external_call["usleep", Int32](UInt32(50000))

        # ★ THE ABRUPT CLOSE. Bare close(2): a FIN, no close_notify, no
        # `s2n_shutdown`. `TlsConnection.__del__` frees the s2n connection
        # without writing an alert, and the fd is already gone, so nothing
        # graceful can leak out behind our back.
        _close_fd(server_fd)
        _ = conn^
        return True
    except:
        return False


def _spawn_server_thread(
    server_fd: Int32,
    cert: String,
    key: String,
    done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin],
    send_prefix: Int32,
) raises -> Tuple[
    UnsafePointer[UInt8, MutUntrackedOrigin],
    UnsafePointer[UInt8, MutUntrackedOrigin],
]:
    """pthread_create a DETACHED server thread. Copies cert + key into heap
    buffers (the thread reads them; the MAIN thread frees them post-done)."""
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
            send_prefix=send_prefix,
        )
    )
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    var tid: Int64 = 0
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


# -----------------------------------------------------------------------------
# §0 — THE s2n CONTRACT, MEASURED DIRECTLY. Immune to our own shim.
# -----------------------------------------------------------------------------


def test_s2n_recv_answers_abrupt_peer_close_with_blocked_on_read() raises:
    """PINS THE s2n BEHAVIOUR THAT MAKES §1 POSSIBLE, by calling `s2n_recv`
    itself over the raw connection pointer — not through our shim, so this
    assertion keeps holding after the shim is fixed and reds if an s2n bump
    changes the contract.

    The claim, from tls/s2n_recv.c (see the file header for the line-by-line
    walk): after a peer FIN with no close_notify, `s2n_recv` returns
    **rc < 0 with `*blocked == S2N_BLOCKED_ON_READ`**, PERMANENTLY, and the
    only thing that says "closed" rather than "would block" is
    `s2n_error_get_type(s2n_errno) == S2N_ERR_T_CLOSED`.

    Non-vacuity, in order:
      1. the handshake must have reached DONE — otherwise this measures a
         failed handshake, not a closed peer;
      2. the FIRST probe must not be a would-block against a live peer — the
         server thread must have reported it closed;
      3. the answer must be the SAME on probe `_POST_CLOSE_PROBES` as on probe
         1, because the driver's spin needs a permanent state, not a transient.
    """
    print("  test_s2n_recv_answers_abrupt_peer_close_with_blocked_on_read...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    tls_init()
    var client_config = _build_client_config()
    var cert = _leaf_cert()
    var key = _leaf_key()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    var done_flag: Int32 = 0
    var done_flag_ptr = UnsafePointer(to=done_flag).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()

    var cert_buf = _null_ptr[UInt8, MutUntrackedOrigin]()
    var key_buf = _null_ptr[UInt8, MutUntrackedOrigin]()
    var spawned = False
    var blocked_on_read_hits = 0
    var closed_type_hits = 0
    try:
        var bufs = _spawn_server_thread(
            server_fd, cert, key, done_flag_ptr, Int32(0),
        )
        cert_buf = bufs[0]
        key_buf = bufs[1]
        spawned = True

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))
        var hs_iters = 0
        var cl_done = False
        while hs_iters < 5_000_000:
            hs_iters = hs_iters + 1
            var o = client_conn.handshake()
            if o == TLS_OUTCOME_DONE:
                cl_done = True
                break
            if o == TLS_OUTCOME_ERROR:
                raise Error(
                    "client handshake ERROR: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            _ = external_call["usleep", Int32](UInt32(100))
        assert_true(
            cl_done,
            "PRECONDITION: the client handshake must reach DONE, or this test"
            " measures a broken handshake and not a closed peer",
        )

        # Send enough application data for the server to see its 24-byte
        # threshold and proceed to the close.
        var req = List[UInt8]()
        var q = 0
        while q < 64:
            req.append(UInt8(65))
            q = q + 1
        var wrote = 0
        var w_spins = 0
        while wrote < 64 and w_spins < 5_000_000:
            w_spins = w_spins + 1
            var wr = client_conn.send(
                Span[UInt8](req)[wrote:].as_imm()
            )
            if wr[0] == TLS_OUTCOME_ERROR:
                raise Error("client send ERROR before close")
            if wr[1] > 0:
                wrote = wrote + wr[1]
                continue
            _ = external_call["usleep", Int32](UInt32(200))
        assert_equal(
            wrote, 64,
            "PRECONDITION: the client must get its bytes out before the peer"
            " closes",
        )

        # Wait for the server thread to report that it CLOSED.
        var wait_iters = 0
        while done_flag == 0 and wait_iters < 2000:
            wait_iters = wait_iters + 1
            _ = external_call["usleep", Int32](UInt32(5000))
        assert_equal(
            Int(done_flag), 1,
            "PRECONDITION: the server thread must reach its abrupt close"
            " (done_flag 1); 0 = still running, 2 = it errored",
        )

        # ---- THE MEASUREMENT. Raw `s2n_recv`, `_POST_CLOSE_PROBES` times. ----
        var raw = client_conn._raw_conn_ptr_for_test()
        var scratch = List[UInt8]()
        var si = 0
        while si < 4096:
            scratch.append(UInt8(0))
            si = si + 1
        var first_rc: Int64 = 0
        var first_blocked: Int32 = -1
        var first_errtype: Int32 = -1
        var p = 0
        while p < _POST_CLOSE_PROBES:
            var blocked_local: Int32 = Int32(0)
            var blocked_ptr = UnsafePointer(
                to=blocked_local
            ).unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
            var buf_ptr = scratch.unsafe_ptr().unsafe_mut_cast[
                False
            ]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
            # SAFETY (FFI-BOUNDARY): synchronous call into the same libs2n the
            # shim uses, over the live connection this frame owns; the scratch
            # List and the stack Int32 out-param are both alive across it and
            # neither pointer escapes.
            var rc = external_call["komira_s2n_recv", Int64](
                raw, buf_ptr, Int64(4096), blocked_ptr,
            )
            var errtype = external_call["komira_s2n_error_get_type", Int32](
                last_s2n_errno()
            )
            if p == 0:
                first_rc = rc
                first_blocked = blocked_local
                first_errtype = errtype
            if rc < Int64(0) and blocked_local == S2N_BLOCKED_ON_READ:
                blocked_on_read_hits = blocked_on_read_hits + 1
            if rc < Int64(0) and errtype == _S2N_ERR_T_CLOSED:
                closed_type_hits = closed_type_hits + 1
            p = p + 1

        assert_true(
            first_rc < Int64(0),
            "s2n_recv on a peer-closed connection returned rc="
            + String(Int(first_rc))
            + "; the whole defect depends on it FAILING rather than reporting"
            " 0 bytes (which our shim already maps to EOF)",
        )
        assert_equal(
            Int(first_blocked), Int(S2N_BLOCKED_ON_READ),
            "★ THE DEFECT'S PREMISE. s2n_recv answered an ABRUPT PEER CLOSE"
            " with *blocked=" + String(Int(first_blocked))
            + ", expected S2N_BLOCKED_ON_READ("
            + String(Int(S2N_BLOCKED_ON_READ))
            + "). s2n_recv.c:176 presets it and only resets it on success"
            " (s2n_recv.c:281-290), so an error return can never clear it. If"
            " this ever fails, s2n changed and `_blocked_status_to_outcome`"
            " may safely trust *blocked again.",
        )
        assert_equal(
            blocked_on_read_hits, _POST_CLOSE_PROBES,
            "★ THE STATE IS PERMANENT, and that is what turns a wrong mapping"
            " into a 100000-trip spin. Only "
            + String(blocked_on_read_hits) + " of "
            + String(_POST_CLOSE_PROBES)
            + " post-close probes answered BLOCKED_ON_READ.",
        )
        assert_equal(
            Int(first_errtype), Int(_S2N_ERR_T_CLOSED),
            "★ THE DISAMBIGUATOR THAT DOES WORK. s2n_error_get_type(s2n_errno)"
            " must say S2N_ERR_T_CLOSED(" + String(Int(_S2N_ERR_T_CLOSED))
            + ") here, not S2N_ERR_T_BLOCKED("
            + String(Int(_S2N_ERR_T_BLOCKED)) + "); got "
            + String(Int(first_errtype))
            + ". This is what the shim must key on instead of *blocked"
            " (api/s2n.h:168-176).",
        )
        assert_equal(
            closed_type_hits, _POST_CLOSE_PROBES,
            "the CLOSED error type must also be permanent, or a shim keyed on"
            " it would fix only the first trip of the spin; got "
            + String(closed_type_hits) + " of "
            + String(_POST_CLOSE_PROBES),
        )
        _ = client_conn^
    finally:
        if spawned:
            var w2 = 0
            while done_flag == 0 and w2 < 200:
                w2 = w2 + 1
                _ = external_call["usleep", Int32](UInt32(10000))
        _close_fd(server_fd)
        _close_fd(client_fd)
        if spawned:
            cert_buf.free()
            key_buf.free()

    _ = client_config^
    _ = cert^
    _ = key^
    print(
        "    [OK] s2n_recv answered BLOCKED_ON_READ on all "
        + String(blocked_on_read_hits) + "/"
        + String(_POST_CLOSE_PROBES)
        + " post-abrupt-close probes, with error type CLOSED on "
        + String(closed_type_hits)
    )


# -----------------------------------------------------------------------------
# §1/§2 — THE REPRODUCTION, through the REAL production transport.
# -----------------------------------------------------------------------------


def _drive_until_peer_close_raises(send_prefix: Int32) raises -> String:
    """Run one full fixture: real TLS 1.3 handshake, real h2 request, peer
    closes abruptly, `drive_h2_streams_to_completion` over the REAL
    `TlsClientStream[TcpIoStream]`. Returns the raise's message.

    Raises (fails the test) if the drive RETURNS instead of raising — that
    would mean the fixture never closed the peer, and every assertion the
    callers make about the message would be vacuous."""
    tls_init()
    var client_config = _build_client_config()
    var cert = _leaf_cert()
    var key = _leaf_key()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    var done_flag: Int32 = 0
    var done_flag_ptr = UnsafePointer(to=done_flag).unsafe_origin_cast[
        MutUntrackedOrigin
    ]()

    var cert_buf = _null_ptr[UInt8, MutUntrackedOrigin]()
    var key_buf = _null_ptr[UInt8, MutUntrackedOrigin]()
    var spawned = False
    var raised = False
    var msg = String("")
    try:
        var bufs = _spawn_server_thread(
            server_fd, cert, key, done_flag_ptr, send_prefix,
        )
        cert_buf = bufs[0]
        key_buf = bufs[1]
        spawned = True

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))
        var hs_iters = 0
        var cl_done = False
        while hs_iters < 5_000_000:
            hs_iters = hs_iters + 1
            var o = client_conn.handshake()
            if o == TLS_OUTCOME_DONE:
                cl_done = True
                break
            if o == TLS_OUTCOME_ERROR:
                raise Error(
                    "client handshake ERROR: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            _ = external_call["usleep", Int32](UInt32(100))
        assert_true(
            cl_done,
            "PRECONDITION: the client handshake must reach DONE, or this"
            " measures a broken handshake and not a closed peer",
        )

        var client_tcp = TcpIoStream(TcpStream(client_fd))
        var client_stream = TlsClientStream[TcpIoStream](
            client_tcp^, client_conn^,
        )

        var reactor = _make_reactor()

        var h2 = H2ClientConnectionState()
        queue_client_preface_and_settings(h2)
        var sid = h2.allocate_client_stream_id()
        _ = h2.create_stream(sid)
        var req_hdrs = HeaderMap()
        encode_request_headers_to_frames(
            h2, sid,
            String("POST"), String("https"),
            String("localhost"),
            String("/google.iam.v1.IAMPolicy/GetIamPolicy"),
            req_hdrs^, end_stream=True,
        )

        var awaited = List[UInt32]()
        awaited.append(sid)
        try:
            # A 6s wall and the STOCK 100_000 iteration cap. The cap is left at
            # its production value deliberately: the spinning give-up comes from
            # it, so shrinking it here would hide the shape under test.
            drive_h2_streams_to_completion[
                TlsClientStream[TcpIoStream], _RT
            ](
                h2, client_stream, reactor, awaited^,
                max_iterations=100_000, max_wall_us=Int64(6_000_000),
            )
        except e:
            raised = True
            msg = String(e)

        _ = reactor^
        _ = client_stream^
    finally:
        if spawned:
            var wait_iters = 0
            while done_flag == 0 and wait_iters < 200:
                wait_iters = wait_iters + 1
                _ = external_call["usleep", Int32](UInt32(10000))
        _close_fd(server_fd)
        _close_fd(client_fd)
        if spawned:
            cert_buf.free()
            key_buf.free()

    assert_true(
        raised,
        "PRECONDITION: the drive must not return normally — the awaited stream"
        " never reaches END_STREAM because the peer vanished. A normal return"
        " means the fixture did not close the peer, and nothing below it means"
        " anything.",
    )
    _ = client_config^
    _ = cert^
    _ = key^
    return msg^


def _assert_did_not_spin(msg: String) raises:
    """The shape assertion, shared by both close shapes and the reason this
    file exists.

    Every give-up `drive_h2_streams_to_completion` can emit for a loop that
    SPUN — the iteration cap, the wall clock, and the `_H2_READY_NO_PROGRESS_CAP`
    livelock detector — prints a `parks=` counter (h2_client.mojo:1907-1985).
    The classified transport raises (EOF_MID_RESPONSE / IO_ERROR) print none.
    So "no `parks=` in the message" is exactly "the loop did not burn a budget
    to discover something the transport had already told it"."""
    assert_false(
        "LIVELOCK" in msg,
        "★ SPIN. The drive spun instead of reporting the close. Got:\n    "
        + msg,
    )
    assert_false(
        "iteration cap exceeded" in msg,
        "★ SPIN. The drive burned its iteration cap. Got:\n    " + msg,
    )
    assert_false(
        "parks=" in msg,
        "★ NO SPIN. Only the driver's spin/wall give-ups carry a `parks=`"
        " counter; reaching one means the loop burned a budget instead of"
        " reporting the close it had already been told about. Got:\n    "
        + msg,
    )


# -----------------------------------------------------------------------------
# §1 — THE SHAPE: the peer reaps the connection and sends NOTHING.
# -----------------------------------------------------------------------------


def test_h2_drive_raises_eof_not_livelock_on_abrupt_peer_close() raises:
    """THE FALSIFIER FOR THE CLOSED-PEER SPIN.

    Real TLS 1.3 session, real h2 request on the wire, and then the peer
    CLOSES WITHOUT ANSWERING — a FIN with no close_notify and no response
    bytes — what an RPC sees when the pooled connection it went out on has been
    reaped.

    REQUIRED BEHAVIOUR — what a plain TCP socket already produces:
    `HttpError[EOF_MID_RESPONSE]`. A stream was in flight when the peer went
    away; that is a connection-level fact the caller re-dials on.

    WHAT A SHIM THAT TRUSTS `*blocked` DOES INSTEAD: it maps s2n's post-close
    `(-1, BLOCKED_ON_READ)` — pinned by §0, 128/128 probes — to
    `StreamIo.pending`, so a CLOSED connection is indistinguishable from a
    slow one. The driver parks on read-readiness; a closed socket is
    PERMANENTLY readable, so every park returns READY without waiting
    (`idle_parks=0`), the retry returns Pending again, and the loop spins.
    Measured on this fixture against such a shim:

        HttpError[LIVELOCK]: ... 4096 consecutive READY parks ...
        (iters=4101, elapsed_ms=66, parks=4097, idle_parks=0)

    — `_H2_READY_NO_PROGRESS_CAP` firing; without that detector the same state
    runs to `iters=100001, parks=100000, idle_parks=0` and calls itself a
    TIMEOUT.
    """
    print("  test_h2_drive_raises_eof_not_livelock_on_abrupt_peer_close...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var msg = _drive_until_peer_close_raises(Int32(0))
    _assert_did_not_spin(msg)
    assert_true(
        "EOF_MID_RESPONSE" in msg,
        "★ An abrupt peer close (FIN, no close_notify) must surface as"
        " HttpError[EOF_MID_RESPONSE] — the same thing a plain TCP socket"
        " produces — because that is what happened. Got:\n    " + msg,
    )
    print("    [OK] " + msg)


# -----------------------------------------------------------------------------
# §2 — THE SAME DEFECT WITH THE PEER'S CLOSE ARRIVING AS A RESET.
# -----------------------------------------------------------------------------


def test_h2_drive_does_not_spin_when_close_surfaces_as_reset() raises:
    """THE SECOND CLOSE SHAPE, and the one that shows the defect was never
    about EOF specifically.

    Here the peer answers with an INCOMPLETE h2 response (SETTINGS + HEADERS +
    a DATA frame with NO end_stream) and only then closes. The client processes
    those frames, queues its SETTINGS-ACK + WINDOW_UPDATE, and writes them into
    a socket whose peer is already gone — so on Linux the *next read* of this
    AF_UNIX socketpair reports **ECONNRESET**, not EOF. s2n surfaces that as
    `S2N_ERR_IO` (`S2N_ERR_T_IO`), and the correct outcome is
    `HttpError[IO_ERROR]`, not EOF: an RST is an I/O failure, not an
    end-of-stream.

    ⚠ THE PRE-FIX SHIM COULD NOT TELL THOSE APART EITHER, because `*blocked`
    says BLOCKED_ON_READ for BOTH (s2n_recv.c:176 presets it and only clears it
    on success — see `_recv_outcome_and_n`). So this shape spun exactly like
    §1's. MEASURED against the pre-fix shim on this fixture:

        HttpError[LIVELOCK]: ... (iters=4101, elapsed_ms=66,
                                  parks=4097, idle_parks=0)

    The assertion is therefore the CLASS + the SHAPE: a classified,
    connection-level raise, reached without burning a budget. Naming both
    acceptable classes rather than one is deliberate — which of EOF or RST the
    kernel delivers is a property of the peer and the timing, and pinning the
    fixture's current answer would make this test fragile about the one thing
    it does not care about."""
    print("  test_h2_drive_does_not_spin_when_close_surfaces_as_reset...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var msg = _drive_until_peer_close_raises(Int32(1))
    _assert_did_not_spin(msg)
    assert_true(
        ("EOF_MID_RESPONSE" in msg) or ("IO_ERROR" in msg),
        "★ A peer that vanishes mid-response must surface as a CLASSIFIED"
        " connection-level failure — EOF_MID_RESPONSE if the kernel gave us a"
        " clean FIN, IO_ERROR if it gave us a reset — never as a driver"
        " give-up. Got:\n    " + msg,
    )
    print("    [OK] " + msg)


def main() raises:
    print("test_L2_h2_over_tls_abrupt_close_no_spin")
    test_s2n_recv_answers_abrupt_peer_close_with_blocked_on_read()
    test_h2_drive_raises_eof_not_livelock_on_abrupt_peer_close()
    test_h2_drive_does_not_spin_when_close_surfaces_as_reset()
    print("ALL PASS")
