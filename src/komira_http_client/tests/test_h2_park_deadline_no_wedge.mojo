# =============================================================================
# src/komira_http_client/tests/test_h2_park_deadline_no_wedge.mojo
# =============================================================================
#
# REPRO — a multi-chunk object-store read hang, isolated
# to its TRUE root cause: the gRPC/h2 reactor PARK has NO deadline.
#
# THE SYMPTOM (Cloud Run, deterministic): a store over GCS gRPC opens fine on a
# 1-chunk store (~4 sequential ReadObject/ListObjects RPCs on ONE reused h2
# connection) but HANGS FOREVER opening a 4-chunk store (~7 sequential RPCs) —
# no error, no progress, no timeout, until the startup probe kills it. The
# store's own logic is correct and terminating against a reactor-less fake;
# the defect is in the gRPC/h2/reactor TRANSPORT.
#
# THE DEFECT:
#   `drive_h2_streams_to_completion` (h2_client.mojo) drives the h2 conn
#   SYNCHRONOUSLY: on a read/write that returns Pending it calls the private
#   `_park_on_fd_readiness`, which (PRE-FIX) does
#       reactor.register_read(fd, op_id)
#       reactor.poll_completions(timeout_us = Int32(-1))   # <-- INFINITE wait
#       reactor.deregister(op_id)
#   The park has NO deadline. The h2 driver's own deadline/iteration-cap checks
#   live in the loop body and run only BETWEEN poll boundaries. Once parked on
#   `poll_completions(-1)`, an unresponsive peer / MISSED WAKEUP (the documented
#   AsyncRT dispatch_semaphore / kqueue-readiness race family) leaves the wait
#   blocked FOREVER: the loop never regains control, so the iteration cap never
#   trips and no DEADLINE_EXCEEDED is ever raised. That is the EXACT "no error,
#   no progress, no timeout" Cloud-Run symptom — and why it bites after N
#   sequential RPCs (each sequential RPC re-arms a fresh park on the reused
#   conn's fd; more parks => higher cumulative odds of one stuck park).
#
# WHY A REACTOR-LESS FAKE CANNOT REPRODUCE IT (and why this test uses a REAL
# fd): the ScriptedStream substrate the existing
# `test_grpc_pooled_send_multiplex.mojo` uses has fd < 0, so
# `_park_on_fd_readiness` early-returns (`if fd < 0: return`) and NEVER parks —
# the bytes are pre-buffered. The live hang requires a REAL kernel fd whose read
# never completes. This test drives the REAL `drive_h2_streams_to_completion`
# over a REAL loopback `TcpIoStream` whose server peer is SILENT (sends the h2
# preface/SETTINGS so the conn is healthy, then withholds the response) —
# modeling the unresponsive-peer / missed-wakeup state the live hang is.
#
# TEST SHAPE:
#   * `test_h2_drive_silent_peer_does_not_wedge` (THE FALSIFIER): drive the h2
#     client to completion against a peer that never sends the response.
#     With `poll_completions(-1)` this HANGS FOREVER (the test
#     timeout fires — the exact Cloud-Run wedge). The bounded-deadline
#     park returns control to the driver loop, which trips its iteration cap and
#     RAISES `HttpError[TIMEOUT]` instead of hanging.
#   * `test_h2_drive_healthy_peer_completes`: the healthy path — a real loopback
#     peer that DOES send a full h2 response must drive to END_STREAM promptly
#     (no false timeout from the new deadline on a healthy slow RPC).
#
# Pointer discipline: the only UnsafePointer use is the socketpair /
# send / recv FFI thunk (confined to this file's helpers, concrete origins, no
# wildcard, no cross-module pointer). Mirrors `test_kqueue_wake.mojo`.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
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
from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.kernel_tcp import TcpIoStream
from komira_async.runtime.tcp_stream import TcpStream


comptime _RT = PerCoreAsyncRuntime[NoopSink]

# socketpair(2) constants (Linux + Darwin agree on these values).
comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _socketpair() -> SIMD[DType.int32, 2]:
    """libc socketpair(2): connected AF_UNIX SOCK_STREAM pair. Returns
    (a_fd, b_fd), or (-1,-1) on failure. Both ends readable + writable.
    SAFETY: stack-local SIMD pair; libc writes 2 int32 into it; never escapes —
    UnsafePointer confined to this FFI thunk per the encapsulation rule."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0),
        UnsafePointer(to=fds).bitcast[UInt8](),
    )
    if rc < 0:
        return SIMD[DType.int32, 2](-1, -1)
    return fds


def _set_nonblocking(fd: Int32):
    """fcntl(fd, F_SETFL, O_NONBLOCK). F_GETFL=3, F_SETFL=4, O_NONBLOCK=0x4
    (Linux) / 0x4 (Darwin) — both agree. The client stream must be
    non-blocking so try_read returns Pending (the path that parks)."""
    var flags = external_call["fcntl", Int32](fd, Int32(3), Int32(0))  # F_GETFL
    _ = external_call["fcntl", Int32](
        fd, Int32(4), flags | Int32(0x4),  # F_SETFL, O_NONBLOCK
    )


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _send_all(fd: Int32, data: List[UInt8]) -> Int64:
    """send(2) the whole buffer (blocking). SAFETY: borrows `data`'s storage
    via a confined FFI thunk; the pointer never escapes the call."""
    if len(data) == 0:
        return 0
    return external_call["send", Int64](
        fd, data.unsafe_ptr(), UInt(len(data)), Int32(0),
    )


def _h2_server_response_script(sid: UInt32) raises -> List[UInt8]:
    """A complete server-side h2 response for stream `sid`: initial SETTINGS +
    HEADERS(:status=200, END_STREAM). END_STREAM on the HEADERS => no body =>
    the client's drive sees end_stream_seen and completes."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        sid, block^, end_stream=True, end_headers=True, out=out,
    )
    return out^


def _h2_server_settings_only() raises -> List[UInt8]:
    """JUST the server's initial SETTINGS frame — a healthy h2 conn handshake,
    but NO response to the client's request. Models the unresponsive-peer state:
    the conn is up, but the response never comes."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    return out^


def _drive_client_request(
    var client_stream: TcpIoStream,
    mut reactor: Reactor[NoopSink],
) raises:
    """Build a minimal h2 client conn over `client_stream`, send one HEADERS
    request, and drive to completion. Raises on the driver's iteration cap /
    transport error. HANGS FOREVER pre-fix if the peer is silent (the bug)."""
    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid,
        String("GET"), String("https"),
        String("localhost"), String("/pkg.Svc/M"),
        hdrs^, end_stream=True,
    )
    var awaited = List[UInt32]()
    awaited.append(sid)
    # A SMALL wall-clock budget (2s) so the FIXED driver trips its wall-clock
    # deadline quickly on a silent peer — proving the bounded-park terminates
    # the drive. PRE-FIX the driver never reaches this check: it is stuck
    # inside poll_completions(-1) on the FIRST read-Pending park (the test
    # timeout fires). A generous iteration cap ensures it is the WALL-CLOCK
    # bound (not the iter cap) that terminates the silent-peer case.
    drive_h2_streams_to_completion[TcpIoStream, _RT](
        h2, client_stream, reactor, awaited^,
        max_iterations=1_000_000, max_wall_us=Int64(2_000_000),
    )
    _ = client_stream^


# =============================================================================
# THE FALSIFIER — a silent peer must NOT wedge the h2 driver forever.
# =============================================================================


def test_h2_drive_silent_peer_does_not_wedge() raises:
    """FALSIFIER. Drive the REAL `drive_h2_streams_to_completion` over a REAL
    loopback fd whose server peer sends ONLY its initial SETTINGS (healthy
    handshake) and then NEVER sends the response.

    FAILS / WEDGES ON CURRENT CODE: on the client's read-Pending,
    `_park_on_fd_readiness` parks via `poll_completions(timeout_us = Int32(-1))`
    — an INFINITE wait. With the peer silent, that call blocks FOREVER and the
    test timeout fires — the exact "no error, no progress, no timeout"
    Cloud-Run wedge. The pre-fix driver can never reach its iteration cap
    because it never regains control from the park.

    PASSES POST-FIX: the bounded-deadline park returns control to the driver
    loop on each unwoken park; the loop spins its (small) iteration budget and
    RAISES `HttpError[TIMEOUT]`. The test asserts the call RAISES (terminates)
    rather than hangs.
    """
    print("  test_h2_drive_silent_peer_does_not_wedge...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0, "socketpair(2) should succeed")
    var client_fd = fds[0]
    var server_fd = fds[1]
    _set_nonblocking(client_fd)

    # Server side: send ONLY the initial SETTINGS (healthy handshake), then go
    # silent. The client's request write succeeds into the socket buffer; its
    # response read returns Pending forever.
    var settings = _h2_server_settings_only()
    _ = _send_all(server_fd, settings)

    var reactor = _make_reactor()
    var client_stream = TcpIoStream(TcpStream(client_fd))

    var raised = False
    try:
        _drive_client_request(client_stream^, reactor)
    except e:
        # POST-FIX: the driver trips its iteration cap (HttpError[TIMEOUT]) once
        # the bounded park lets it regain control. ANY raise is termination —
        # the antithesis of the wedge.
        _ = e
        raised = True

    assert_true(
        raised,
        "silent peer must make the h2 driver TERMINATE (raise), not wedge"
        " forever on poll_completions(-1)",
    )

    _close_fd(server_fd)
    _ = reactor^
    print("    [OK] silent peer => driver terminated (no infinite wedge)")


def test_h2_drive_healthy_peer_completes() raises:
    """HEALTHY PATH — a real loopback peer that sends a full h2 response
    (SETTINGS + HEADERS/END_STREAM) must drive to END_STREAM and RETURN with no
    error. Guards against the fix introducing a false TIMEOUT on a healthy RPC:
    the bounded park is a safety net, NOT the normal wake path — when bytes
    really arrive, the park wakes and the driver completes.
    """
    print("  test_h2_drive_healthy_peer_completes...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= 0)
    var client_fd = fds[0]
    var server_fd = fds[1]
    _set_nonblocking(client_fd)

    # Server: full response for the client's first stream id (1). SETTINGS +
    # HEADERS(:status=200, END_STREAM). Pre-loaded so it's readable as soon as
    # the client parks (level-triggered registration reports it immediately).
    var script = _h2_server_response_script(UInt32(1))
    _ = _send_all(server_fd, script)

    var reactor = _make_reactor()
    var client_stream = TcpIoStream(TcpStream(client_fd))

    var completed = False
    try:
        _drive_client_request(client_stream^, reactor)
        completed = True
    except e:
        _ = e
        completed = False

    assert_true(
        completed,
        "a healthy peer's full h2 response must drive to END_STREAM with no"
        " error (no false TIMEOUT from the deadline-bounded park)",
    )

    _close_fd(server_fd)
    _ = reactor^
    print("    [OK] healthy peer => driver completed (no false timeout)")


def main() raises:
    print("=== h2 reactor park must honor a deadline (no wedge) ===")
    test_h2_drive_silent_peer_does_not_wedge()
    test_h2_drive_healthy_peer_completes()
    print("=== h2 park deadline verified (terminates, no false timeout) ===")
