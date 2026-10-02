# =============================================================================
# src/komira_http/tests/test_h2_pending_direction_inversion_no_spin.mojo
# =============================================================================
#
# THE SPIN THIS GUARDS AGAINST shows up as
#
#   HttpError[TIMEOUT]: h2 driver iteration cap exceeded (iters=100001,
#   elapsed_ms=753, wall_budget_ms=120000, parks=100000, idle_parks=0)
#
# READ THE NUMBERS. 100000 parks in 753 ms is 7.5 us per park, and
# `idle_parks=0` says NOT ONE of them waited out its slice — every single park
# was told "ready" and came straight back. A park that WAITS costs up to
# `_H2_PARK_DEADLINE_US` (250 ms), so a genuinely waiting drive completes ~480
# trips inside its 120 s wall and CANNOT reach 100_000. Reaching the iteration
# cap with 119.2 s of wall budget unspent is therefore proof of a SPIN, and a
# `[TIMEOUT]` class on that message is actively misleading.
#
# ONE STATE THAT SPINS — a WAIT-DIRECTION INVERSION.
#
#   A driver that parks on the direction of the CALL IT MADE (write branch on
#   write-readiness, read branch on read-readiness) is right for a kernel
#   socket, where a Pending is always EWOULDBLOCK in the direction of the call.
#   It is wrong for a transport whose write can block on a READ (a TLS layer
#   that must consume a record before it may encrypt another byte), because a
#   socket with room in its send buffer is ALWAYS write-ready:
#
#       try_write -> Pending(blocked on READ)
#         -> park on WRITE readiness -> ready INSTANTLY (send buffer has room)
#         -> retry try_write -> Pending(blocked on READ) -> ...
#
#   No progress, no wait, ~7.5 us a trip, forever. (s2n-tls 1.5.6 does not
#   produce this inversion; an abrupt peer close produces the same numbers and
#   is covered by `test_L2_h2_over_tls_abrupt_close_no_spin`. This file pins the
#   direction seam itself, for any transport that DOES invert.)
#
# THE DIRECTION IS NEVER UNKNOWABLE. `tls_connector.mojo`'s
# `_map_tls_outcome_to_stream_io` encodes it in the Pending token —
# `(fd << 1) | is_blocked_on_write`.
#
# THE SEAM under test: `IoStream.pending_wait_is_write(token, call_is_write)` —
# a default trait method returning `call_is_write` (correct for TcpIoStream /
# ScriptedStream), OVERRIDDEN by `TlsClientStream` to decode its own token's
# direction bit. The driver asks the stream instead of assuming, and never
# decodes a token it did not author.
#
# WHAT THIS TEST ASSERTS — and why it is not a test of the symptom.
# Asserting "the cap eventually fires" would PASS on a spinning driver: the cap
# firing IS the failure. So the assertions are about the loop's
# BEHAVIOUR PER TRIP, taken from the driver's own give-up message:
#
#   1. `idle_parks == parks` — every park WAITED out its slice. A spinning
#      driver shows `idle_parks=0` against `parks=100000`. This discriminator
#      is machine-speed independent.
#   2. the give-up is the WALL-CLOCK class, not the iteration cap / LIVELOCK
#      class — the loop stopped because time ran out, which is the truth about
#      a peer that never becomes readable.
#   3. `iters` is SMALL (a park per trip, 250 ms a park) rather than the 100_001
#      of a spin.
#   4. CONTROL: the premise holds — the socketpair the fixture parks on IS
#      instantly write-ready and is NEVER read-ready. Without that, assertion 1
#      would be asserting the absence of something that cannot happen.
#   5. the LIVELOCK detector fires, by class and by name, when a stream is made
#      to lie about its own direction — the backstop for any future inversion,
#      and proof the class is reachable.
#
# MEASURED BOTH WAYS. Forcing the write branch to `is_write=True` and disabling
# the detector reproduces the spin and fails assertion 1:
#
#   parks=100000 idle_parks=0 iters=100001 elapsed_ms=389 wall_budget_ms=3000
#
# With the seam in place:
#
#   parks=12 idle_parks=12 iters=13 elapsed=3005ms -> wall-clock give-up
#
# 100000 -> 12 parks and 0 -> 12 idle. Same peer, same cap, same wall.
#
# Pointer discipline: the only UnsafePointer use is the socketpair /
# fcntl FFI thunk, confined to this file's helpers, concrete origins, no
# wildcard, no cross-module pointer. Mirrors the sibling
# `test_h2_park_wake_storm_no_iteration_burn.mojo`.
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
from komira_async.runtime.runtime_trait import Runtime
from komira_clock import now_ns as _mono_now_ns

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    drive_h2_streams_to_completion,
    encode_request_headers_to_frames,
    queue_client_preface_and_settings,
)
from komira_http.client.header_map import HeaderMap
from komira_http.transport.io_stream import (
    IoStream,
    NEGOTIATED_HTTP_2,
    StreamIo,
)


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
    both Linux and Darwin."""
    var flags = external_call["fcntl", Int32](fd, Int32(3), Int32(0))
    _ = external_call["fcntl", Int32](fd, Int32(4), flags | Int32(0x4))


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


# =============================================================================
# THE FIXTURE — a stream that models TLS's direction inversion, without TLS.
# =============================================================================


struct RekeyBlockedStream(IoStream, Movable, Deinitable):
    """An `IoStream` over a REAL socketpair fd that is permanently blocked in
    the OPPOSITE direction from the call, exactly as s2n reports a TLS rekey.

    `try_write` returns `StreamIo.pending((fd << 1) | 0)` — bit 0 clear means
    BLOCKED_ON_READ, the encoding `tls_connector._map_tls_outcome_to_stream_io`
    writes for `TLS_OUTCOME_BLOCKED_ON_READ`. `pending_wait_is_write` decodes it
    the same way `TlsClientStream` does. This is the TLS conformer's CONTRACT
    reproduced faithfully, with s2n replaced by a constant — the test needs no
    certificate, no handshake, and no peer that can rekey on demand.

    The fd is a socketpair end whose peer never writes: it is therefore
    ALWAYS write-ready (kernel send buffer empty) and NEVER read-ready. That
    asymmetry is the whole fixture. A driver that waits on write-readiness gets
    an instant wake every time and spins; one that waits on the direction this
    stream ASKED for waits out every slice and correctly runs out of wall clock.

    `_lie_about_direction` inverts the answer `pending_wait_is_write` gives —
    used ONLY by the backstop test, to prove the LIVELOCK detector catches an
    inversion the direction plumbing does not."""

    var _fd: Int32
    var _lie_about_direction: Bool
    var _write_calls: Int
    var _read_calls: Int

    def __init__(out self, fd: Int32, lie_about_direction: Bool = False):
        self._fd = fd
        self._lie_about_direction = lie_about_direction
        self._write_calls = 0
        self._read_calls = 0

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        """Always Pending, blocked on READ (bit 0 clear) — the ordinary
        read-side wait. The driver never reaches this branch in the tests below
        (the write branch drains first) but the conformance is real."""
        _ = reactor
        _ = dst
        self._read_calls = self._read_calls + 1
        return StreamIo.pending(Int64(self._fd) << 1)

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        """Always Pending, blocked on READ — the TLS rekey shape. Bit 0 CLEAR
        on a WRITE call is the whole defect in one value."""
        _ = reactor
        _ = src
        self._write_calls = self._write_calls + 1
        return StreamIo.pending(Int64(self._fd) << 1)

    def close(var self):
        # The fd is owned by the test (it closes both socketpair ends); this
        # conformer never closes it, so a moved-out close is a no-op.
        _ = self._fd

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_2

    def fd(self) -> Int32:
        return self._fd

    def pending_wait_is_write(
        self, pending_token: Int64, call_is_write: Bool,
    ) -> Bool:
        """THE OVERRIDE UNDER TEST — byte-for-byte what `TlsClientStream` does:
        decode bit 0 of the token this stream itself produced, and IGNORE which
        call produced it."""
        _ = call_is_write
        var decoded = (pending_token & Int64(1)) == Int64(1)
        if self._lie_about_direction:
            return not decoded
        return decoded

    def write_calls(self) -> Int:
        return self._write_calls


def _extract_int_after(msg: String, key: String) -> Int:
    """Parse the integer that follows `key` in a driver give-up message, e.g.
    `_extract_int_after(msg, "parks=")`. Returns -1 if `key` is absent or is
    not followed by a digit. Deliberately tiny: the driver's own instrumentation
    is the evidence, so the test reads it rather than re-deriving it."""
    var at = msg.find(key)
    if at < 0:
        return -1
    var i = at + key.byte_length()
    var b = msg.as_bytes()
    var n = b.__len__()
    var seen = False
    var acc = 0
    while i < n:
        var c = Int(b[i])
        if c < 48 or c > 57:
            break
        seen = True
        acc = acc * 10 + (c - 48)
        i = i + 1
    if not seen:
        return -1
    return acc


def _drive_rekey_blocked(
    fd: Int32,
    mut reactor: Reactor[NoopSink],
    max_wall_us: Int64,
    lie_about_direction: Bool = False,
) raises -> Tuple[String, Int64]:
    """Drive ONE h2 request through the REAL `drive_h2_streams_to_completion`
    against a `RekeyBlockedStream`, with the PRODUCTION iteration cap (100_000)
    and the caller's wall bound. Returns (error_message, elapsed_ms).

    The production cap is used deliberately: shrinking it would manufacture the
    very symptom under test. The client preface is queued so `pending_out` is
    non-empty and the drive enters its WRITE branch — the branch the
    livelock runs in."""
    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid,
        String("POST"), String("https"),
        String("iam.googleapis.com"),
        String("/google.iam.v1.IAMPolicy/GetIamPolicy"),
        hdrs^, end_stream=True,
    )
    var awaited = List[UInt32]()
    awaited.append(sid)

    var stream = RekeyBlockedStream(fd, lie_about_direction)
    var t0 = Int64(_mono_now_ns())
    var msg = String("")
    try:
        drive_h2_streams_to_completion[RekeyBlockedStream, _RT](
            h2, stream, reactor, awaited^,
            max_iterations=100_000, max_wall_us=max_wall_us,
        )
    except e:
        msg = String(e)
    var elapsed_ms = (Int64(_mono_now_ns()) - t0) // Int64(1_000_000)
    _ = stream^
    return (msg^, elapsed_ms)


# =============================================================================
# CONTROL — the fixture's premise: write-ready ALWAYS, read-ready NEVER.
# =============================================================================


def test_control_socketpair_is_write_ready_never_read_ready() raises:
    """POSITIVE CONTROL. The falsifier's whole force rests on the asymmetry
    that makes the wrong-direction park free and the right-direction park
    expensive. Assert it directly, on the same reactor and the same 250 ms
    budget the driver's park uses."""
    print("  test_control_socketpair_is_write_ready_never_read_ready...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var reactor = _make_reactor()
    var pair = _socketpair()
    assert_true(pair[0] >= Int32(0), "socketpair(2) should succeed")
    _set_nonblocking(pair[0])

    # --- WRITE readiness: instant. This is the free park the bug took.
    var w_op = reactor.alloc_op_id()
    reactor.register_write(pair[0], w_op, UInt16(0))
    var t0 = Int64(_mono_now_ns())
    var _d0 = reactor.poll_completions(timeout_us=Int32(250_000))
    var w_ms = (Int64(_mono_now_ns()) - t0) // Int64(1_000_000)
    var w_ready = reactor.is_ready(w_op)
    reactor.deregister(w_op)
    assert_true(
        w_ready,
        "CONTROL: an idle socketpair end must be WRITE-ready immediately —"
        " that is why parking on the wrong direction costs nothing and spins",
    )
    assert_true(
        w_ms < Int64(50),
        "CONTROL: the write park must return at once; measured "
        + String(w_ms) + "ms",
    )

    # --- READ readiness: never (the peer never writes). The park that waits.
    var r_op = reactor.alloc_op_id()
    reactor.register_read(pair[0], r_op, UInt16(0))
    var t1 = Int64(_mono_now_ns())
    var _d1 = reactor.poll_completions(timeout_us=Int32(250_000))
    var r_ms = (Int64(_mono_now_ns()) - t1) // Int64(1_000_000)
    var r_ready = reactor.is_ready(r_op)
    reactor.deregister(r_op)
    assert_false(
        r_ready,
        "CONTROL: the socketpair end must NEVER become read-ready (the peer"
        " writes nothing) — this is the direction the stream asks to wait on",
    )
    assert_true(
        r_ms >= Int64(200),
        "CONTROL: the read park must wait out its whole 250ms slice; measured "
        + String(r_ms) + "ms",
    )

    _close_fd(pair[0])
    _close_fd(pair[1])
    _ = reactor^
    print(
        "    [OK] write-ready in " + String(w_ms) + "ms; read park waited "
        + String(r_ms) + "ms and never fired"
    )


# =============================================================================
# THE FALSIFIER — a write blocked on READ must WAIT, not spin.
# =============================================================================


def test_h2_write_blocked_on_read_parks_on_read_not_write() raises:
    """THE SPIN, REPRODUCED AND INVERTED.

    A driver that assumes the call's direction raises `HttpError[TIMEOUT]: h2
    driver iteration cap exceeded (iters=100001, ..., parks=100000,
    idle_parks=0)` in about a second.

    Asking the stream, the driver asks the stream which direction it is waiting on, parks
    on READ, and every park waits out its 250 ms slice, so a 3 s wall budget
    buys ~12 trips and the give-up is the WALL CLOCK — the honest answer for a
    peer that never becomes readable.

    The assertions are on the driver's OWN counters, so none of them depends on
    how fast this machine is."""
    print("  test_h2_write_blocked_on_read_parks_on_read_not_write...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var reactor = _make_reactor()
    var pair = _socketpair()
    assert_true(pair[0] >= Int32(0), "socketpair(2) should succeed")
    _set_nonblocking(pair[0])

    var res = _drive_rekey_blocked(pair[0], reactor, Int64(3_000_000))
    var msg = res[0]
    var elapsed_ms = res[1]

    assert_true(
        msg.byte_length() > 0,
        "the drive must TERMINATE with a raise, never hang",
    )

    var parks = _extract_int_after(msg, String("parks="))
    var idle = _extract_int_after(msg, String("idle_parks="))
    var iters = _extract_int_after(msg, String("iters="))

    # (1) THE DISCRIMINATOR. Pre-fix: parks=100000, idle_parks=0.
    assert_true(
        parks > 0,
        "the drive must have parked at all; message: " + msg,
    )
    assert_equal(
        idle,
        parks,
        "EVERY park must have WAITED OUT its slice — a write blocked on READ"
        " has to wait on READ readiness, which this peer never gives. parks="
        + String(parks) + " idle_parks=" + String(idle)
        + " means " + String(parks - idle) + " park(s) were woken instantly by"
        " a direction the I/O could not use, which is the spin."
        " Message: " + msg,
    )

    # (2) The give-up names the real cause: time ran out, not trips.
    assert_true(
        String("wall-clock deadline") in msg,
        "a drive that waited must give up on the WALL CLOCK; got: " + msg,
    )
    assert_false(
        String("iteration cap exceeded") in msg,
        "the iteration cap must NOT be reachable when every park waits 250ms"
        " inside a 3s budget — reaching it is the spin. Got: " + msg,
    )
    assert_false(
        String("HttpError[LIVELOCK]") in msg,
        "a correctly-waiting drive is not a livelock; got: " + msg,
    )

    # (3) Trips, not time: ~12 expected, 100_001 pre-fix.
    assert_true(
        iters > 0 and iters < 200,
        "a waiting drive makes a HANDFUL of trips (one park each), not tens of"
        " thousands; iters=" + String(iters) + " message: " + msg,
    )

    # (4) And it really did spend the budget rather than giving up early.
    assert_true(
        elapsed_ms >= Int64(2_400),
        "the drive must have spent its 3s wall budget waiting; measured "
        + String(elapsed_ms) + "ms — a give-up that does not wait is the other"
        " half of this defect",
    )

    _close_fd(pair[0])
    _close_fd(pair[1])
    _ = reactor^
    print(
        "    [OK] parks=" + String(parks) + " idle_parks=" + String(idle)
        + " iters=" + String(iters) + " elapsed=" + String(elapsed_ms) + "ms"
        + " -> wall-clock give-up"
    )


# =============================================================================
# BACKSTOP — an inversion the direction plumbing does NOT fix must be NAMED.
# =============================================================================


def test_h2_livelock_detector_names_a_wrong_direction_wait() raises:
    """THE SECOND HALF OF THE FIX, AND THE REASON THE CLASS CHANGED.

    Correct direction plumbing removes the inversion we know about. It cannot
    prove there is no other way to reach a ready-park that yields no progress —
    a future conformer, a reactor change, a protocol we have not written yet.
    So the driver now carries a detector: `_H2_READY_NO_PROGRESS_CAP`
    consecutive trips on which a park said READY and the retried I/O moved zero
    bytes raises `HttpError[LIVELOCK]`, which SAYS what happened.

    This test forces exactly that state by making the stream LIE about its own
    direction (`_lie_about_direction`) — the wire-level equivalent of the bug,
    below the layer the fix operates at. It asserts the detector fires, and
    that its message is not a timeout: the elapsed time is a fraction of the
    stated wall budget, which is the fact the old `[TIMEOUT]` class buried."""
    print("  test_h2_livelock_detector_names_a_wrong_direction_wait...")

    comptime if not (CompilationTarget.is_macos() or CompilationTarget.is_linux()):
        assert_true(True)
        return

    var reactor = _make_reactor()
    var pair = _socketpair()
    assert_true(pair[0] >= Int32(0), "socketpair(2) should succeed")
    _set_nonblocking(pair[0])

    # A 120s wall budget — the production default. If the detector does not
    # fire, this test hangs for two minutes and then reports the iteration cap,
    # which is precisely the failure and precisely a FAIL here.
    var res = _drive_rekey_blocked(
        pair[0], reactor, Int64(120_000_000), lie_about_direction=True,
    )
    var msg = res[0]
    var elapsed_ms = res[1]

    assert_true(
        String("HttpError[LIVELOCK]") in msg,
        "a zero-progress ready-park run must raise the LIVELOCK class, not a"
        " timeout and not a bare cap count; got: " + msg,
    )
    # ⚠ NO BARE `WAIT-DIRECTION` VERDICT TOKEN. On s2n-tls 1.5.6 a direction
    # inversion cannot happen (`s2n_sendv_with_offset_impl` only ever writes
    # BLOCKED_ON_WRITE/NOT_BLOCKED; send -> BLOCKED_ON_READ 0 times across 272
    # sends and 16 real KeyUpdates); an abruptly CLOSED peer that s2n reports
    # as would-block forever produces the same state. The message names THAT
    # cause first and keeps direction-inversion as one of two candidates.
    #
    # The detector cannot tell the two apart at runtime: both present as a READY
    # park that moves zero bytes. A bare verdict would assert a falsified
    # attribution, so the test matches the message's WORDING, which is the
    # contract here. The stable greppable token for this diagnostic is the
    # CLASS, `HttpError[LIVELOCK]`, asserted directly above (its sibling
    # "iteration cap exceeded" is matched verbatim by transport-fault
    # classifiers).
    assert_true(
        String("wait direction is inverted") in msg,
        "the message must ENUMERATE the candidate causes — the danger is a"
        " message that names one cause and names it with certainty; got: "
        + msg,
    )
    assert_false(
        String("HttpError[TIMEOUT]") in msg,
        "753ms is not a timeout and neither is this; got: " + msg,
    )
    # It must fire FAST — well inside the 120s wall it was given. That is the
    # point of a separate budget: the iteration cap needs ~0.75s of pure spin,
    # the detector needs ~30ms.
    assert_true(
        elapsed_ms < Int64(30_000),
        "the detector must fire long before the 120s wall; measured "
        + String(elapsed_ms) + "ms",
    )

    _close_fd(pair[0])
    _close_fd(pair[1])
    _ = reactor^
    print(
        "    [OK] LIVELOCK named in " + String(elapsed_ms)
        + "ms of a 120000ms wall budget"
    )


def main() raises:
    print("test_h2_pending_direction_inversion_no_spin.mojo")
    test_control_socketpair_is_write_ready_never_read_ready()
    test_h2_write_blocked_on_read_parks_on_read_not_write()
    test_h2_livelock_detector_names_a_wrong_direction_wait()
    print("  ALL PASS")
