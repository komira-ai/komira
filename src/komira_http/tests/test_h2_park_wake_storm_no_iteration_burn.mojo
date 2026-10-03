# =============================================================================
# src/komira_http/tests/test_h2_park_wake_storm_no_iteration_burn.mojo
# =============================================================================
#
# FALSIFIER — `HttpError[TIMEOUT]: h2 driver iteration cap exceeded` on every
# outbound gRPC seam a service uses (IAM, Cloud Run, Service Usage alike).
#
# THE MESSAGE IS THE DIAGNOSIS. `drive_h2_streams_to_completion` is bounded by
# BOTH an iteration cap (100_000) and a WALL CLOCK (120 s), checked on the same
# loop trip. Those two bounds cannot both be plausible for the same failure:
#
#   * a park that WAITS costs up to `_H2_PARK_DEADLINE_US` (250 ms). A loop
#     that is genuinely waiting on a slow or silent peer therefore completes at
#     most ~480 trips inside the 120 s wall and can NEVER reach 100_000. It
#     must surface "wall-clock deadline exceeded".
#   * reaching 100_000 trips therefore PROVES the trips were not waiting —
#     they averaged under 1.2 ms each. That is a BUSY SPIN, not a timeout.
#
# So the observed error is not "the peer was slow" and not "the cap is too
# small". It is a LIVELOCK, and raising the cap makes it spin longer and report
# the same thing.
#
# THE DEFECT is a park that does:
#
#       reactor.register_read(fd, op_id, ...)
#       var _drained = reactor.poll_completions(timeout_us=_H2_PARK_DEADLINE_US)
#       reactor.deregister(op_id)
#
# and DISCARDS the result. `Reactor.poll_completions` is documented to return
# on ANY reactor event — its own docstring: wake-channel completions "cause the
# syscall to return early with whatever non-wake completions also arrived", and
# a drained wake-eventfd contributes an EMPTY list. A foreign fd that is
# level-triggered readable does the same thing on every call. So a park can
# return in microseconds WITHOUT this fd ever becoming ready, the driver treats
# that as "go around again", and 100_000 trips evaporate in about a second.
#
# THE SIBLING LOOP HAS THE SAME RULE. `TlsConnector.connect`'s handshake loop
# holds two invariants ("a give-up counted in loop trips, where a trip can cost
# zero time, fails a HEALTHY handshake"):
#     (i)  the budget is WALL CLOCK, not a count of trips;
#     (ii) a park that returns WITHOUT this fd becoming ready RE-PARKS for the
#          remainder of its slice instead of re-entering the caller.
# The h2 driver needs BOTH. Invariant (i) alone does not save it, because a
# spin exhausts 100_000 trips long before 120 s of wall clock elapses — which
# is precisely why the failure reports the ITERATION CAP and never the wall
# clock.
#
# TEST SHAPE — hermetic, no network, no fixture server, no thread:
#   * `_arm_wake_storm` registers a PERMANENTLY-READABLE socketpair end on the
#     reactor and never drains it. Every `poll_completions` thereafter returns
#     immediately with THAT op's completion — never the h2 stream's. This is
#     the client-side wake storm, made deterministic.
#   * the h2 peer is a socketpair end that sends its initial SETTINGS (so the
#     connection is HEALTHY) and then never answers.
#
# The falsifier asserts three things a raised constant cannot satisfy:
#   1. the error is the WALL-CLOCK class, not the iteration cap;
#   2. elapsed >= the STATED wall (a give-up that does not wait is the other
#      half of this defect — a spinning driver gives up in ~1 s and calls it a
#      120 s timeout);
#   3. the elapsed time TRACKS the stated wall at TWO different values. One
#      value is satisfied by any constant; two are not.
#
# Pointer discipline: the only UnsafePointer use is the socketpair /
# send FFI thunk, confined to this file's helpers, concrete origins, no
# wildcard, no cross-module pointer. Mirrors the sibling
# `test_h2_park_deadline_no_wedge.mojo`.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.testing import assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_clock import now_ns as _mono_now_ns

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    drive_h2_streams_to_completion,
    encode_request_headers_to_frames,
    queue_client_preface_and_settings,
)
from komira_http.client.header_map import HeaderMap
from komira_http.codec.h2.frame import (
    SettingsEntry,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.kernel_tcp import TcpIoStream
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
    (a_fd, b_fd), or (-1,-1) on failure.

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
    """fcntl(fd, F_SETFL, O_NONBLOCK). F_GETFL=3, F_SETFL=4, O_NONBLOCK=0x4 on
    both Linux and Darwin. The client stream must be non-blocking so try_read
    returns Pending — the path that parks."""
    var flags = external_call["fcntl", Int32](fd, Int32(3), Int32(0))
    _ = external_call["fcntl", Int32](fd, Int32(4), flags | Int32(0x4))


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _send_all(fd: Int32, data: List[UInt8]) -> Int64:
    """send(2) the whole buffer. SAFETY: borrows `data`'s storage via a
    confined FFI thunk; the pointer never escapes the call."""
    if len(data) == 0:
        return 0
    return external_call["send", Int64](
        fd, data.unsafe_ptr(), UInt(len(data)), Int32(0),
    )


def _h2_server_settings_only() raises -> List[UInt8]:
    """JUST the server's initial SETTINGS frame — a HEALTHY h2 connection
    handshake, but no response to the client's request: the connection is up,
    the answer never comes."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    return out^


def _h2_server_full_response(sid: UInt32) raises -> List[UInt8]:
    """SETTINGS + HEADERS(:status=200, END_STREAM) — a complete response, so
    the client's drive reaches end_stream_seen and returns."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(sid, block^, end_stream=True, end_headers=True, out=out)
    return out^


def _arm_wake_storm(mut reactor: Reactor[NoopSink]) raises -> SIMD[
    DType.int32, 2
]:
    """Register a PERMANENTLY-READABLE fd on `reactor` and never drain it.

    THIS IS THE WHOLE FIXTURE. The registration is level-triggered EPOLLIN
    (epoll) / EVFILT_READ without EV_CLEAR (kqueue) and the byte is never read,
    so the fd is readable forever. Every `poll_completions` call therefore
    returns IMMEDIATELY, with a completion for THIS op and never for the h2
    stream's op — a foreign completion, exactly what a busy reactor delivers to
    a park that does not check whose readiness it got.

    Returns the (a, b) fds so the caller can close them. The registration is
    deliberately never deregistered: it models a peer conn left armed on the
    shared per-core reactor, which is the production shape (an h2 POOL keeps
    several conns registered at once)."""
    var noise = _socketpair()
    if noise[0] < Int32(0):
        return noise
    var payload = List[UInt8]()
    payload.append(UInt8(0x42))
    _ = _send_all(noise[1], payload)
    var op = reactor.alloc_op_id()
    reactor.register_read(noise[0], op, UInt16(0))
    return noise


def _drive_silent_peer(
    var client_stream: TcpIoStream,
    mut reactor: Reactor[NoopSink],
    max_wall_us: Int64,
) raises -> Tuple[String, Int64]:
    """Drive ONE h2 request through the REAL `drive_h2_streams_to_completion`
    against a silent peer, with the PRODUCTION iteration cap (100_000) and the
    caller's wall bound. Returns (error_message, elapsed_ms).

    The production cap is used deliberately: shrinking it would manufacture the
    very symptom under test."""
    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid,
        String("GET"), String("https"),
        String("localhost"), String("/google.iam.v1.IAMPolicy/GetIamPolicy"),
        hdrs^, end_stream=True,
    )
    var awaited = List[UInt32]()
    awaited.append(sid)

    var t0 = Int64(_mono_now_ns())
    var msg = String("")
    try:
        drive_h2_streams_to_completion[TcpIoStream, _RT](
            h2, client_stream, reactor, awaited^,
            max_iterations=100_000, max_wall_us=max_wall_us,
        )
    except e:
        msg = String(e)
    var elapsed_ms = (Int64(_mono_now_ns()) - t0) // Int64(1_000_000)
    _ = client_stream^
    return (msg^, elapsed_ms)


# =============================================================================
# CONTROL 1 — the wake storm is REAL (positive control for the premise)
# =============================================================================


def test_control_wake_storm_actually_returns_polls_early() raises:
    """POSITIVE CONTROL. Every claim below rests on 'a park returns early
    without this fd becoming ready'. That premise must be shown to HOLD, in
    both directions, or the falsifier is asserting the absence of something
    that never happens.

    Asserts, on the SAME reactor and the SAME 250 ms budget:
      * WITHOUT the storm, `poll_completions` waits out its full budget;
      * WITH the storm armed, it returns essentially instantly;
      * and in the armed case `is_ready` for a FRESHLY registered, NOT-ready
        op is False — i.e. the early return carries no readiness for the op a
        park would care about. That last assertion is the actual defect.
    """
    print("  test_control_wake_storm_actually_returns_polls_early...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var reactor = _make_reactor()

    # --- direction 1: NO storm. A 250ms poll must actually take ~250ms.
    var t0 = Int64(_mono_now_ns())
    var _d0 = reactor.poll_completions(timeout_us=Int32(250_000))
    var idle_ms = (Int64(_mono_now_ns()) - t0) // Int64(1_000_000)
    assert_true(
        idle_ms >= Int64(200),
        "CONTROL: an unarmed reactor must wait out its 250ms budget; measured "
        + String(idle_ms) + "ms. If this is small the fixture proves nothing.",
    )

    # --- direction 2: storm armed. The same call must return at once.
    var noise = _arm_wake_storm(reactor)
    assert_true(noise[0] >= Int32(0), "socketpair(2) should succeed")

    # A silent stream fd, registered but never readable — the op a park cares
    # about.
    var quiet = _socketpair()
    assert_true(quiet[0] >= Int32(0))
    _set_nonblocking(quiet[0])
    var quiet_op = reactor.alloc_op_id()
    reactor.register_read(quiet[0], quiet_op, UInt16(0))

    var t1 = Int64(_mono_now_ns())
    var _d1 = reactor.poll_completions(timeout_us=Int32(250_000))
    var stormed_ms = (Int64(_mono_now_ns()) - t1) // Int64(1_000_000)
    assert_true(
        stormed_ms < Int64(50),
        "CONTROL: with a permanently-ready foreign fd armed, poll_completions"
        " must return early; measured " + String(stormed_ms) + "ms",
    )
    assert_false(
        reactor.is_ready(quiet_op),
        "CONTROL (THE DEFECT): the early return must carry NO readiness for"
        " the quiet op — that is precisely what the h2 park failed to check",
    )

    reactor.deregister(quiet_op)
    _close_fd(quiet[0])
    _close_fd(quiet[1])
    _close_fd(noise[0])
    _close_fd(noise[1])
    _ = reactor^
    print(
        "    [OK] unarmed poll " + String(idle_ms) + "ms; stormed poll "
        + String(stormed_ms) + "ms; quiet op not ready"
    )


# =============================================================================
# THE FALSIFIER — a wake storm must not convert a wall bound into a spin
# =============================================================================


def test_h2_wake_storm_does_not_burn_iteration_cap() raises:
    """FALSIFIER — the observed failure, hermetic.

    A HEALTHY h2 connection (peer sent its SETTINGS) whose response never
    arrives, driven on a reactor that has a foreign readable fd armed. The
    driver's own wall bound is STATED by the caller; the iteration cap is the
    production 100_000.

    RED PRE-FIX: `_park_on_fd_readiness` discards `poll_completions`' result,
    so each park returns in microseconds on the foreign completion. 100_000
    trips burn in about a second and the driver reports
    'h2 driver iteration cap exceeded' — a TIMEOUT that fired ~100x faster than
    its own stated timeout, which is the observed symptom exactly.

    GREEN POST-FIX: the park keeps polling until ITS op is ready or the slice
    is spent, so a trip costs real time, the iteration cap is unreachable, and
    the driver surfaces the WALL-CLOCK deadline it actually stated.

    Two wall values are checked. One value is satisfiable by any constant; two
    are not.
    """
    print("  test_h2_wake_storm_does_not_burn_iteration_cap...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var wall_a_ms = Int64(1200)
    var wall_b_ms = Int64(2600)

    # ---- case A -----------------------------------------------------------
    var fds_a = _socketpair()
    assert_true(fds_a[0] >= Int32(0), "socketpair(2) should succeed")
    _set_nonblocking(fds_a[0])
    var settings_a = _h2_server_settings_only()
    _ = _send_all(fds_a[1], settings_a)
    var reactor_a = _make_reactor()
    var noise_a = _arm_wake_storm(reactor_a)
    assert_true(noise_a[0] >= Int32(0))
    var res_a = _drive_silent_peer(
        TcpIoStream(TcpStream(fds_a[0])), reactor_a,
        max_wall_us=wall_a_ms * Int64(1000),
    )
    var msg_a = res_a[0]
    var ms_a = res_a[1]
    print("    case A: stated " + String(wall_a_ms) + "ms, measured "
          + String(ms_a) + "ms")
    print("    case A msg: " + msg_a)

    # ---- case B -----------------------------------------------------------
    var fds_b = _socketpair()
    assert_true(fds_b[0] >= Int32(0))
    _set_nonblocking(fds_b[0])
    var settings_b = _h2_server_settings_only()
    _ = _send_all(fds_b[1], settings_b)
    var reactor_b = _make_reactor()
    var noise_b = _arm_wake_storm(reactor_b)
    assert_true(noise_b[0] >= Int32(0))
    var res_b = _drive_silent_peer(
        TcpIoStream(TcpStream(fds_b[0])), reactor_b,
        max_wall_us=wall_b_ms * Int64(1000),
    )
    var msg_b = res_b[0]
    var ms_b = res_b[1]
    print("    case B: stated " + String(wall_b_ms) + "ms, measured "
          + String(ms_b) + "ms")
    print("    case B msg: " + msg_b)

    # ---- 1. it must terminate at all --------------------------------------
    assert_true(
        msg_a.byte_length() > 0 and msg_b.byte_length() > 0,
        "a silent peer must make the drive RAISE, not complete or hang",
    )

    # ---- 2. the CLASS of the give-up --------------------------------------
    # This is the discriminator the observed message handed us. Under a wake storm
    # the loop is not waiting on anything, so reporting the iteration cap is
    # reporting a spin as a timeout.
    assert_false(
        String("iteration cap exceeded") in msg_a,
        "PRE-FIX SYMPTOM (case A): the drive burned its 100_000-trip cap under"
        " a wake storm instead of spending its stated "
        + String(wall_a_ms) + "ms wall. Raising the cap makes this spin longer"
        " and report the same thing. msg=" + msg_a,
    )
    assert_false(
        String("iteration cap exceeded") in msg_b,
        "PRE-FIX SYMPTOM (case B): iteration cap burned under a wake storm."
        " msg=" + msg_b,
    )
    assert_true(
        String("wall-clock deadline") in msg_a,
        "a silent peer must surface the WALL-CLOCK deadline the caller stated;"
        " msg=" + msg_a,
    )
    assert_true(
        String("wall-clock deadline") in msg_b,
        "a silent peer must surface the WALL-CLOCK deadline; msg=" + msg_b,
    )

    # ---- 3. LOWER bound: a give-up that does not wait is the other half ----
    # 80% of the stated wall, to tolerate clock granularity and the final trip.
    assert_true(
        ms_a >= (wall_a_ms * Int64(8)) // Int64(10),
        "case A gave up after " + String(ms_a) + "ms but stated a "
        + String(wall_a_ms) + "ms deadline — a deadline that does not wait is"
        " not a deadline",
    )
    assert_true(
        ms_b >= (wall_b_ms * Int64(8)) // Int64(10),
        "case B gave up after " + String(ms_b) + "ms but stated a "
        + String(wall_b_ms) + "ms deadline",
    )

    # ---- 4. UPPER bound: the bound is still a bound ------------------------
    assert_true(
        ms_a < wall_a_ms + Int64(4000) and ms_b < wall_b_ms + Int64(4000),
        "the wall bound must still terminate promptly: A=" + String(ms_a)
        + "ms B=" + String(ms_b) + "ms",
    )

    # ---- 5. TWO values: the wall is TRACKED, not a constant ----------------
    # Any single hardcoded duration satisfies one case. Only a driver that
    # actually reads `max_wall_us` satisfies both, so the measured gap must
    # follow the stated gap (at least half of it, for scheduling noise).
    var stated_gap = wall_b_ms - wall_a_ms
    var measured_gap = ms_b - ms_a
    assert_true(
        measured_gap >= stated_gap // Int64(2),
        "the give-up must TRACK the stated wall: stated gap "
        + String(stated_gap) + "ms, measured gap " + String(measured_gap)
        + "ms (A=" + String(ms_a) + " B=" + String(ms_b) + "). A constant"
        " timeout satisfies one case and fails this one.",
    )

    _close_fd(fds_a[1])
    _close_fd(noise_a[0])
    _close_fd(noise_a[1])
    _close_fd(fds_b[1])
    _close_fd(noise_b[0])
    _close_fd(noise_b[1])
    _ = reactor_a^
    _ = reactor_b^
    print("    [OK] wake storm spends the stated wall, not the iteration cap")


# =============================================================================
# CONTROL 2 — the fix must not slow down a healthy RPC
# =============================================================================


def test_control_healthy_peer_completes_under_wake_storm() raises:
    """NO-FALSE-TIMEOUT / NO-SLOWDOWN CONTROL. The re-park invariant makes an
    UNWOKEN park spend its slice; it must not make a WOKEN one spend anything.

    A peer whose full response is already readable must drive to END_STREAM
    with NO error and promptly (well inside one 250 ms park slice), even with
    the wake storm armed. If the fix made the park sleep unconditionally, this
    reds.
    """
    print("  test_control_healthy_peer_completes_under_wake_storm...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var fds = _socketpair()
    assert_true(fds[0] >= Int32(0))
    _set_nonblocking(fds[0])
    var response = _h2_server_full_response(UInt32(1))
    _ = _send_all(fds[1], response)

    var reactor = _make_reactor()
    var noise = _arm_wake_storm(reactor)
    assert_true(noise[0] >= Int32(0))

    var res = _drive_silent_peer(
        TcpIoStream(TcpStream(fds[0])), reactor,
        max_wall_us=Int64(5_000_000),
    )
    var msg = res[0]
    var ms = res[1]

    assert_true(
        msg.byte_length() == 0,
        "a healthy peer must complete with NO error even under a wake storm;"
        " got: " + msg,
    )
    assert_true(
        ms < Int64(250),
        "a healthy RPC must not be delayed by the re-park invariant; took "
        + String(ms) + "ms",
    )

    _close_fd(fds[1])
    _close_fd(noise[0])
    _close_fd(noise[1])
    _ = reactor^
    print("    [OK] healthy peer completed in " + String(ms) + "ms under storm")


def main() raises:
    print("test_h2_park_wake_storm_no_iteration_burn.mojo")
    test_control_wake_storm_actually_returns_polls_early()
    test_h2_wake_storm_does_not_burn_iteration_cap()
    test_control_healthy_peer_completes_under_wake_storm()
    print("[PASS] h2 park wake-storm suite")
