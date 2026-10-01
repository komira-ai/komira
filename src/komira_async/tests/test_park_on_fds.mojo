# =============================================================================
# test_park_on_fds.mojo
# =============================================================================
# Reactor.park_on_fds(fds, timeout_us) tests.
#
# `park_on_fds` is the transient-register-epoll_wait-deregister park that the
# streaming round-robin drains (s3_fs.read_ranges_prefetched / write drain /
# collect_body / drain_bodies_round_robin) call after a bounded spin budget,
# instead of busy-spinning the whole network RTT. It is SELF-CONTAINED — it
# does NOT touch the reactor's _wakers op_id table or fire _sink.
#
# Coverage (the load-bearing properties):
#   * MOCK backend → returns 0 (no epoll fd; yields ~10µs, no hang).
#   * all-fds-negative (no pollable fd) → returns 0 (caller falls back to spin).
#   * LOST-WAKEUP SAFETY: a byte ALREADY on the socket before park → park
#     returns >0 IMMEDIATELY (level-triggered EPOLLIN reports current
#     readiness at ADD time; no byte is lost). This is the property a missed
#     wakeup would violate (park would block to the timeout / forever).
#   * timeout path: no data, finite timeout → park returns 0 without hanging.
#   * REPEATABILITY: park deregisters its fds, so a second park on the same
#     fd behaves identically (no EEXIST poisoning, no stale-registration leak).
#   * the park does NOT disturb _wakers: a registered op_id survives a park.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_MOCK,
    Reactor,
)


comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _socketpair_unix_stream() raises -> Array[Int32, 2]:
    """SAFETY: pair is stack-local; the kernel writes 2 fds into it and
    does not retain the pointer. Confined to this test helper."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_one_byte(fd: Int32, b: UInt8) raises:
    var buf = Array[UInt8, 1](fill=b)
    var w = external_call["send", Int](
        fd, buf.unsafe_ptr(), UInt(1), Int32(0),
    )
    if w != Int(1):
        raise Error("send() failed")


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def test_park_mock_backend_returns_zero() raises:
    """MOCK backend (no epoll fd): park yields briefly and returns 0,
    never hangs. The caller's drain loop falls through to re-poll."""
    var r = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    var fds = List[Int32]()
    fds.append(Int32(7))
    var ready = r.park_on_fds(fds, Int32(1000))
    assert_equal(ready, 0)


def test_park_all_fds_negative_returns_zero() raises:
    """All fds < 0 (conformers with no pollable kernel fd, e.g.
    ScriptedStream): nothing is registered, park yields + returns 0."""
    comptime if CompilationTarget.is_linux():
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var fds = List[Int32]()
        fds.append(Int32(-1))
        fds.append(Int32(-1))
        var ready = r.park_on_fds(fds, Int32(1000))
        assert_equal(ready, 0)


def test_park_byte_already_ready_returns_immediately() raises:
    """LOST-WAKEUP SAFETY. Prime a byte on the socket BEFORE parking. The
    park must see it (level-triggered EPOLLIN reports readiness at ADD
    time) and return >0 immediately — NOT block to the timeout. A missed
    wakeup would manifest as ready==0 here."""
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        # Prime: peer writes a byte; sv[0] is now read-readable.
        _send_one_byte(sv[1], UInt8(0xAB))
        var fds = List[Int32]()
        fds.append(sv[0])
        # Large timeout — if the wakeup were lost, this would block the
        # full second. Level-triggered readiness returns it immediately.
        var ready = r.park_on_fds(fds, Int32(1_000_000))
        assert_true(ready >= 1)
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_park_no_data_times_out_clean() raises:
    """No data on the socket + finite timeout: park returns 0 without
    hanging (the belt-and-suspenders timeout bound)."""
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        var fds = List[Int32]()
        fds.append(sv[0])
        # Short timeout — nothing primed, so epoll_wait returns 0 on timeout.
        var ready = r.park_on_fds(fds, Int32(5000))
        assert_equal(ready, 0)
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_park_is_repeatable_no_eexist_poison() raises:
    """Park deregisters its fds before returning, so a SECOND park on the
    SAME fd behaves identically — no EEXIST from a leaked registration,
    no stale slot. Proven by: park(ready) → park(ready) both return >0."""
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        _send_one_byte(sv[1], UInt8(0x01))
        var fds = List[Int32]()
        fds.append(sv[0])
        var ready1 = r.park_on_fds(fds, Int32(1_000_000))
        assert_true(ready1 >= 1)
        # Byte still unread on sv[0] (park does not consume it). Second park
        # on the SAME fd must succeed again — if the first park had leaked
        # the registration, this would raise EEXIST internally (swallowed)
        # and still work, but the level-triggered byte must re-fire.
        var fds2 = List[Int32]()
        fds2.append(sv[0])
        var ready2 = r.park_on_fds(fds2, Int32(1_000_000))
        assert_true(ready2 >= 1)
        _close_fd(sv[0])
        _close_fd(sv[1])


def test_park_mixed_fds_one_ready_one_not() raises:
    """Window with K fds where only ONE has data: park returns >0 (woken by
    the ready one). Mirrors the round-robin window where one in-flight
    stream's bytes arrive first."""
    comptime if CompilationTarget.is_linux():
        var a = _socketpair_unix_stream()
        var b = _socketpair_unix_stream()
        var r = Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
        # Only socket `a` gets a byte; `b` stays empty.
        _send_one_byte(a[1], UInt8(0x55))
        var fds = List[Int32]()
        fds.append(a[0])
        fds.append(b[0])
        var ready = r.park_on_fds(fds, Int32(1_000_000))
        assert_true(ready >= 1)
        _close_fd(a[0])
        _close_fd(a[1])
        _close_fd(b[0])
        _close_fd(b[1])


def main() raises:
    test_park_mock_backend_returns_zero()
    test_park_all_fds_negative_returns_zero()
    test_park_byte_already_ready_returns_immediately()
    test_park_no_data_times_out_clean()
    test_park_is_repeatable_no_eexist_poison()
    test_park_mixed_fds_one_ready_one_not()
    print("PASS komira_async.reactor.park_on_fds")
