# =============================================================================
# THE SEND-SIDE HALF OF THE CLOSED-PEER SPIN.
# =============================================================================
#
# On the RECV path s2n presets `*blocked = S2N_BLOCKED_ON_READ` at `s2n_recv`'s
# entry and resets it only on a successful read, so an abrupt peer close comes
# back as "would block" forever; mapped to `Pending`, the h2 drive spins on a
# permanently-read-ready closed socket (`test_L2_h2_over_tls_abrupt_close_no_spin`).
# The send path has the same shape via `s2n_flush`.
#
# ★ THIS FILE IS THE SEND-SIDE REPRODUCTION.
#
# -----------------------------------------------------------------------------
# THE MECHANISM, read out of the s2n-tls v1.5.6 source
# -----------------------------------------------------------------------------
#
#   tls/s2n_send.c:85       `s2n_flush`: `*blocked = S2N_BLOCKED_ON_WRITE;` set
#                           at ENTRY, before the first `write(2)`. The ONLY
#                           reset is line 102, AFTER the write loop, so no
#                           error return can reach it.
#   tls/s2n_send.c:156      `s2n_sendv_with_offset_impl` sets it AGAIN before
#                           the record loop; its reset (line 242) is likewise
#                           only reachable by writing everything.
#   tls/s2n_send.c:222      the in-loop `s2n_flush` failure path returns the
#                           partial ONLY `if (s2n_errno == S2N_ERR_IO_BLOCKED
#                           && user_data_sent > 0)`; otherwise
#                           `S2N_ERROR_PRESERVE_ERRNO()` -> rc = -1 with
#                           `*blocked` still BLOCKED_ON_WRITE.
#   utils/s2n_io.c:22-30    `s2n_io_check_write_result` reserves
#                           `S2N_ERR_IO_BLOCKED` for EWOULDBLOCK/EAGAIN and
#                           bails `S2N_ERR_IO` (type `S2N_ERR_T_IO`) for
#                           everything else — EPIPE and ECONNRESET included.
#
# ⇒ A `write(2)` TO A DEPARTED PEER RETURNS `(-1, S2N_BLOCKED_ON_WRITE)` FROM
#   `s2n_send`, PERMANENTLY. Permanently, because a failed write does NOT set
#   `conn->write_closed` — its only writers are `s2n_shutdown`
#   (tls/s2n_shutdown.c:77) and `s2n_connection_set_io_status`
#   (tls/s2n_connection.c:1324) — so the next call re-enters `s2n_flush` over
#   the same undrained `conn->out` stuffer and fails identically instead of
#   short-circuiting to `S2N_ERR_CLOSED`.
#
# -----------------------------------------------------------------------------
# WHY THAT IS A SPIN AND NOT A WAIT
# -----------------------------------------------------------------------------
#
# `_blocked_status_to_outcome` believed `*blocked` and returned
# `TLS_OUTCOME_BLOCKED_ON_WRITE`; `_map_tls_outcome_to_stream_io` turned that
# into `StreamIo.pending`; `drive_h2_streams_to_completion`'s Step 1 parked on
# WRITE-readiness. A socket whose peer is gone is PERMANENTLY write-ready —
# `EPOLLERR`/`EPOLLHUP` are reported no matter which direction you registered —
# so `park_on_pending` found the op ready on its FIRST poll every time, was
# counted NON-IDLE (`idle_parks` stays 0), the retried `try_write` returned
# Pending again having moved zero bytes, and `ready_no_progress` climbed
# unchecked to `_H2_READY_NO_PROGRESS_CAP`:
#
#     HttpError[LIVELOCK]: h2 driver made no progress across 4096 consecutive
#     READY parks ... (iters=4098, elapsed_ms=..., parks=4096, idle_parks=0)
#
# That is the closed-peer spin line with the direction flipped, recurring on
# POOLED connections even with the recv path fixed.
#
# -----------------------------------------------------------------------------
# WHAT THIS FILE ASSERTS
# -----------------------------------------------------------------------------
#
#   §0  THE s2n CONTRACT, pinned by calling `s2n_send` DIRECTLY over the raw
#       connection — immune to any fix in our own shim, so it keeps telling the
#       truth after §1 goes green and reds if an s2n bump changes the
#       behaviour. Non-vacuity: the handshake must have reached DONE and the
#       server thread must have reported that it closed.
#
#   §1  THE PRODUCTION PATH: `drive_h2_streams_to_completion` over a REAL
#       `TlsClientStream[TcpIoStream]`, real cert, real TLS 1.3 handshake, real
#       h2 frames, peer gone before the request goes out. It must raise a
#       CLASSIFIED, RETRYABLE, connection-level error, and it must NOT spin.
#
#   §2  THE DISPOSITION, asserted separately from the class name: the raise
#       must satisfy the GCS client's retryable-connection set in `komira_gcp_bridge`.
#       This is the assertion that stops a future "cleanup" from replacing the
#       spin with a `HttpError[IO_ERROR]` — which would fix the symptom and
#       silently convert a fault that WAS retried (LIVELOCK is in that set)
#       into one that fails the request outright.
#
# Pointer discipline: UnsafePointer use is confined to the
# socketpair / pthread / s2n out-param FFI thunks (concrete or
# MutExternalOrigin AT the FFI boundary, never crossing a non-FFI module) — the
# same carve-out as `test_L2_h2_over_tls_abrupt_close_no_spin.mojo`, whose
# harness this clones.
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
    S2N_BLOCKED_ON_WRITE,
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

# `s2n_error_type` (api/s2n.h). ⚠ THE ENUM IS COMMENT-INTERLEAVED — the values
# are consecutive from 0 and do NOT line up with the header's line numbers.
comptime _S2N_ERR_T_OK: Int32 = Int32(0)
comptime _S2N_ERR_T_IO: Int32 = Int32(1)
comptime _S2N_ERR_T_CLOSED: Int32 = Int32(2)
comptime _S2N_ERR_T_BLOCKED: Int32 = Int32(3)

# How many consecutive post-departure `s2n_send` calls §0 makes. The point is
# that the state is PERMANENT, not a one-shot: the driver's spin needs it to
# answer the same way on trip 4096 as on trip 1.
comptime _POST_CLOSE_PROBES: Int = 128

# Payload §0 hands `s2n_send`. Small — the defect is about the FIRST `write(2)`
# failing, not about volume.
comptime _PROBE_PAYLOAD: Int = 256


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


def _errtype_str(t: Int32) -> StaticString:
    """Name of an `s2n_error_type` ordinal, for the diagnostic lines below.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape."""
    if t == _S2N_ERR_T_OK:
        return "S2N_ERR_T_OK"
    if t == _S2N_ERR_T_IO:
        return "S2N_ERR_T_IO"
    if t == _S2N_ERR_T_CLOSED:
        return "S2N_ERR_T_CLOSED"
    if t == _S2N_ERR_T_BLOCKED:
        return "S2N_ERR_T_BLOCKED"
    return "S2N_ERR_T_OTHER"


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _build_client_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.wipe_trust()
    config.disable_verify()
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


# -----------------------------------------------------------------------------
# The SERVER, on a detached helper pthread.
#
# ⚠ THE ONE THING THAT MAKES THIS FIXTURE WHAT IT IS, AND THE ONE WAY IT
# DIFFERS FROM `test_L2_h2_over_tls_abrupt_close_no_spin`: the server closes
# **BEFORE READING ANYTHING**. There it drained the client's 24-byte h2 preface
# first, so the client's write had already succeeded and the failure landed on
# the READ path. Here the peer is gone before a single application byte goes
# out, so the failure lands on the WRITE path — which is the path with no
# falsifier until this file.
#
# It is still a bare `close(fd)` with no `s2n_shutdown`: an abrupt close, what
# a load balancer or a GFE does when it reaps a pooled connection.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ServerArg(Copyable, Movable, Deinitable):
    var server_fd: Int32
    var cert_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var cert_len: Int
    var key_ptr: UnsafePointer[UInt8, MutUntrackedOrigin]
    var key_len: Int
    # 0 = running, 1 = handshake done + fd closed, 2 = error.
    var done_flag_ptr: UnsafePointer[Int32, MutUntrackedOrigin]


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
    arg.bitcast[UInt8]().free()

    var ok = _run_server(server_fd, cert_ptr, cert_len, key_ptr, key_len)
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
) -> Bool:
    """Handshake to DONE, then close the socket ABRUPTLY without reading or
    writing one application byte. Any raise returns False."""
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

        # ★ THE DEPARTURE. Bare close(2) — a FIN, no close_notify, no
        # `s2n_shutdown` — with NOTHING read and NOTHING written. The
        # `TlsConnection.__del__` frees the s2n connection without writing an
        # alert, and the fd is already gone, so nothing graceful can leak out
        # behind our back.
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


def _handshake_client(mut conn: TlsConnection) raises:
    var hs_iters = 0
    var cl_done = False
    while hs_iters < 5_000_000:
        hs_iters = hs_iters + 1
        var o = conn.handshake()
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
        " measures a broken handshake and not a departed peer",
    )


# -----------------------------------------------------------------------------
# §0 — THE s2n CONTRACT, MEASURED DIRECTLY. Immune to our own shim.
# -----------------------------------------------------------------------------


def test_s2n_send_answers_departed_peer_with_blocked_on_write() raises:
    """PINS THE s2n BEHAVIOUR THAT MAKES §1 POSSIBLE, by calling `s2n_send`
    itself over the raw connection pointer — not through our shim, so this
    assertion keeps holding after the shim is fixed and reds if an s2n bump
    changes the contract.

    The claim, from tls/s2n_send.c + utils/s2n_io.c (see the file header for
    the line-by-line walk): a `write(2)` to a departed peer makes `s2n_send`
    return **rc < 0 with `*blocked == S2N_BLOCKED_ON_WRITE`**, PERMANENTLY, and
    the only thing that says "dead" rather than "would block" is
    `s2n_error_get_type(s2n_errno)` — which must NOT be `S2N_ERR_T_BLOCKED`.

    Non-vacuity, in order:
      1. the handshake must have reached DONE — otherwise this measures a
         failed handshake, not a departed peer;
      2. the server thread must have reported that it closed;
      3. the answer must be the SAME on probe `_POST_CLOSE_PROBES` as on probe
         1, because the driver's spin needs a permanent state, not a transient.
    """
    print("  test_s2n_send_answers_departed_peer_with_blocked_on_write...")

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
    var blocked_on_write_hits = 0
    var non_blocked_type_hits = 0
    var first_errtype: Int32 = -1
    try:
        var bufs = _spawn_server_thread(server_fd, cert, key, done_flag_ptr)
        cert_buf = bufs[0]
        key_buf = bufs[1]
        spawned = True

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))
        _handshake_client(client_conn)

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

        # ---- THE MEASUREMENT. Raw `s2n_send`, `_POST_CLOSE_PROBES` times. ----
        var raw = client_conn._raw_conn_ptr_for_test()
        var payload = List[UInt8]()
        var si = 0
        while si < _PROBE_PAYLOAD:
            payload.append(UInt8(65))
            si = si + 1
        var first_rc: Int64 = 0
        var first_blocked: Int32 = -1
        var p = 0
        while p < _POST_CLOSE_PROBES:
            var blocked_local: Int32 = Int32(0)
            var blocked_ptr = UnsafePointer(
                to=blocked_local
            ).unsafe_mut_cast[False]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
            var buf_ptr = payload.unsafe_ptr().unsafe_mut_cast[
                False
            ]().unsafe_origin_cast[_S2N_FFI_ORIGIN]()
            # SAFETY (FFI-BOUNDARY): synchronous call into the same libs2n the
            # shim uses, over the live connection this frame owns; the payload
            # List and the stack Int32 out-param are both alive across it and
            # neither pointer escapes.
            var rc = external_call["komira_s2n_send", Int64](
                raw, buf_ptr, Int64(_PROBE_PAYLOAD), blocked_ptr,
            )
            var errtype = external_call["komira_s2n_error_get_type", Int32](
                last_s2n_errno()
            )
            if p == 0:
                first_rc = rc
                first_blocked = blocked_local
                first_errtype = errtype
            if rc < Int64(0) and blocked_local == S2N_BLOCKED_ON_WRITE:
                blocked_on_write_hits = blocked_on_write_hits + 1
            if rc < Int64(0) and errtype != _S2N_ERR_T_BLOCKED:
                non_blocked_type_hits = non_blocked_type_hits + 1
            p = p + 1

        assert_true(
            first_rc < Int64(0),
            "s2n_send to a departed peer returned rc="
            + String(Int(first_rc))
            + "; the whole defect depends on it FAILING. If this ever reports"
            " a positive partial the socket did not actually go away and every"
            " assertion below is vacuous.",
        )
        assert_equal(
            Int(first_blocked), Int(S2N_BLOCKED_ON_WRITE),
            "★ THE DEFECT'S PREMISE. s2n_send answered a write to a DEPARTED"
            " PEER with *blocked=" + String(Int(first_blocked))
            + ", expected S2N_BLOCKED_ON_WRITE("
            + String(Int(S2N_BLOCKED_ON_WRITE))
            + "). s2n_send.c:85 presets it inside s2n_flush and only resets it"
            " after the write loop, so an error return can never clear it. If"
            " this ever fails, s2n changed and `_error_typed_outcome` may"
            " safely trust *blocked again.",
        )
        assert_equal(
            blocked_on_write_hits, _POST_CLOSE_PROBES,
            "★ THE STATE IS PERMANENT, and that is what turns a wrong mapping"
            " into a 4096-trip spin rather than one wasted trip. Only "
            + String(blocked_on_write_hits) + " of "
            + String(_POST_CLOSE_PROBES)
            + " post-departure probes answered BLOCKED_ON_WRITE. (A failed"
            " write does not set conn->write_closed, so nothing retires the"
            " state.)",
        )
        assert_true(
            first_errtype != _S2N_ERR_T_BLOCKED,
            "★ THE DISAMBIGUATOR THAT DOES WORK. s2n_error_get_type(s2n_errno)"
            " must NOT say S2N_ERR_T_BLOCKED("
            + String(Int(_S2N_ERR_T_BLOCKED))
            + ") for a dead socket — utils/s2n_io.c reserves S2N_ERR_IO_BLOCKED"
            " for EWOULDBLOCK/EAGAIN alone and bails S2N_ERR_IO for EPIPE and"
            " ECONNRESET. Got " + String(Int(first_errtype)) + " ("
            + String(_errtype_str(first_errtype))
            + "). This is what the shim keys on instead of *blocked.",
        )
        assert_equal(
            non_blocked_type_hits, _POST_CLOSE_PROBES,
            "the non-BLOCKED error type must ALSO be permanent, or a shim keyed"
            " on it would fix only the first trip of the spin; got "
            + String(non_blocked_type_hits) + " of "
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
        "    [OK] s2n_send answered BLOCKED_ON_WRITE on all "
        + String(blocked_on_write_hits) + "/"
        + String(_POST_CLOSE_PROBES)
        + " post-departure probes, error type "
        + String(_errtype_str(first_errtype))
        + " (NOT S2N_ERR_T_BLOCKED) on "
        + String(non_blocked_type_hits)
    )


# -----------------------------------------------------------------------------
# §1/§2 — THE REPRODUCTION, through the REAL production transport.
# -----------------------------------------------------------------------------


def _drive_against_departed_peer_raises() raises -> String:
    """Run one full fixture: real TLS 1.3 handshake, peer departs, then
    `drive_h2_streams_to_completion` over the REAL `TlsClientStream[TcpIoStream]`
    tries to put the h2 preface + request on the wire. Returns the raise's
    message.

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
        var bufs = _spawn_server_thread(server_fd, cert, key, done_flag_ptr)
        cert_buf = bufs[0]
        key_buf = bufs[1]
        spawned = True

        var client_conn = TlsConnection.new_client(client_config)
        client_conn.bind_fd(client_fd)
        client_conn.set_server_name(String("localhost"))
        _handshake_client(client_conn)

        # ★ THE ORDERING THAT MAKES THIS THE **WRITE** PATH. We do not start
        # driving until the server thread has reported its close, so the very
        # first `try_write` of the h2 preface lands on a departed peer. Drive
        # earlier and the preface would go out fine and the failure would
        # surface on the READ path — which is the already-fixed half, and this
        # test would pass against the broken send path.
        var wait_iters = 0
        while done_flag == 0 and wait_iters < 2000:
            wait_iters = wait_iters + 1
            _ = external_call["usleep", Int32](UInt32(5000))
        assert_equal(
            Int(done_flag), 1,
            "PRECONDITION: the server thread must reach its abrupt close"
            " (done_flag 1) BEFORE the drive starts; 0 = still running,"
            " 2 = it errored",
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
            String("/google.storage.v2.Storage/ReadObject"),
            req_hdrs^, end_stream=True,
        )

        var awaited = List[UInt32]()
        awaited.append(sid)
        try:
            # A 6s wall and the STOCK 100_000 iteration cap, for the same
            # reason the sibling file gives: the observed give-up came from the
            # production budgets, so shrinking them here would hide the shape
            # under test.
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
            var w3 = 0
            while done_flag == 0 and w3 < 200:
                w3 = w3 + 1
                _ = external_call["usleep", Int32](UInt32(10000))
        _close_fd(server_fd)
        _close_fd(client_fd)
        if spawned:
            cert_buf.free()
            key_buf.free()

    assert_true(
        raised,
        "PRECONDITION: the drive must not return normally — the awaited stream"
        " cannot reach END_STREAM because the request never left the box. A"
        " normal return means the fixture did not close the peer, and nothing"
        " below it means anything.",
    )
    _ = client_config^
    _ = cert^
    _ = key^
    return msg^


def test_h2_drive_does_not_spin_when_the_peer_departed_before_the_write(
) raises:
    """★ THE FALSIFIER. Real TLS 1.3 session; the peer is GONE before the h2
    preface goes out; the drive must fail in microseconds with a classified
    transport error rather than spinning on a permanently-write-ready dead
    socket.

    MEASURED against the pre-fix shim on this fixture:

        HttpError[LIVELOCK]: h2 driver made no progress across 4096
        consecutive READY parks ... (iters=4098, parks=4096, idle_parks=0)

    which is the closed-peer spin line with the direction flipped — and the
    shape of the four LIVELOCK recurrences AFTER the recv-side fix landed, all
    of them on pooled connections.

    The assertion is the SHAPE: no LIVELOCK, no iteration cap, no `parks=`
    counter. Only this driver's spin/wall give-ups print one, so "no `parks=`
    in the message" is exactly "the loop did not burn a budget to discover
    something the transport had already told it"."""
    print(
        "  test_h2_drive_does_not_spin_when_the_peer_departed_before_the"
        "_write..."
    )

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var msg = _drive_against_departed_peer_raises()
    assert_false(
        "LIVELOCK" in msg,
        "★ SPIN, SEND SIDE. The drive spun instead of reporting the departed"
        " peer. Got:\n    " + msg,
    )
    assert_false(
        "iteration cap exceeded" in msg,
        "★ SPIN, SEND SIDE. The drive burned its iteration cap. Got:\n    "
        + msg,
    )
    assert_false(
        "parks=" in msg,
        "★ NO SPIN. Only the driver's spin/wall give-ups carry a `parks=`"
        " counter; reaching one means the loop burned a budget instead of"
        " reporting the failure the transport had already handed it. Got:\n"
        "    " + msg,
    )
    print("    [OK] " + msg)


def test_departed_peer_write_failure_is_a_retryable_connection_fault() raises:
    """★ THE DISPOSITION, ASSERTED SEPARATELY FROM THE SHAPE — and the reason
    this test exists as its own function.

    Killing the spin is only half the fix. The pre-fix behaviour raised
    `HttpError[LIVELOCK]`, which IS in
    the GCS client's retryable-connection set in `komira_gcp_bridge`, so the caller
    re-dialled and (slowly, after ~30 ms of spinning per attempt) usually
    recovered. A "fix" that replaced the spin with a bare
    `HttpError[IO_ERROR]` — which is in NO retry set — would make things
    WORSE: a fault that was retried would become one that fails the request
    outright.

    A peer that departed before answering anything means the request got no
    verdict, which is precisely what the connection-level retry predicates are
    for.

    ⚠ **WHY THIS ASSERTS A TOKEN AND NOT THE PREDICATE ITSELF.** The predicate
    (the GCS client's retryable-connection set in `komira_gcp_bridge`) lives in
    `komira_gcp_bridge`, which DEPENDS on `komira_http`; importing it from a
    test welded to `komira_http` would be a dependency cycle. The other half of
    this assertion — that this exact message satisfies that predicate — is
    pinned on the classifier's side. Neither half is
    sufficient alone: this one says the driver emits the token, that one says
    the classifier honours it."""
    print(
        "  test_departed_peer_write_failure_is_a_retryable_connection_fault..."
    )

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var msg = _drive_against_departed_peer_raises()
    assert_true(
        "HttpError[RETRYABLE_TRANSPORT]" in msg,
        "★ THE DISPOSITION. A peer that departed before sending a single"
        " response byte leaves the request with NO verdict, so the raise MUST"
        " carry a class the connection-level retry predicates honour."
        " `HttpError[IO_ERROR]` is in NONE of them — emitting it here would"
        " fix the spin by converting a fault that WAS retried (LIVELOCK is in"
        " the set) into one that fails the request outright, which is a worse"
        " outcome and not a better one. Got:\n    " + msg,
    )
    print("    [OK] " + msg)


def main() raises:
    print("test_L2_h2_over_tls_send_to_departed_peer_no_spin")
    test_s2n_send_answers_departed_peer_with_blocked_on_write()
    test_h2_drive_does_not_spin_when_the_peer_departed_before_the_write()
    test_departed_peer_write_failure_is_a_retryable_connection_fault()
    print("ALL PASS")
