# =============================================================================
# test_reactor_modify_interest.mojo: a switch of a long-lived registration's
# interest is never skipped as "unchanged" when it is not
# =============================================================================
#
# `Reactor.modify(reg, mask)` skips the syscall when `mask` equals what the
# registration is armed for. That record must be the reactor's own (per fd):
# a `RegistrationHandle` is a copyable value, and if the armed mask lived on
# the handle, a switch made through one copy would leave another copy saying
# the old mask. READ -> WRITE through a copy, then WRITE -> READ through the
# original, would be skipped and the descriptor would stay armed for
# writability only, never reporting readability again (komira-ai/komira#1406:
# an HTTP connection whose parked write drained was never read again).
#
# Each test and the defect it catches:
#   test_read_reported_after_write_and_back
#       the READ switch after a WRITE switch skipped (the armed mask not
#       updated at all): a byte from the peer is not reported.
#   test_read_reported_after_a_switch_through_a_copy
#       the armed mask kept on the handle a caller passes rather than in the
#       reactor: the WRITE switch goes through a copy, the switch back through
#       the original is skipped, and the byte is not reported.
#   test_modify_to_the_armed_mask_issues_no_rearm
#       the documented fast path dropped: an EPOLL_CTL_MOD to the same
#       edge-triggered mask re-reports a writable descriptor.
# What the reactor records for each switch (mock and epoll) is pinned in
# test_reactor_completion_queue_smoke.mojo.
#
# Linux only (socketpair + EPOLLET semantics).
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_async.reactor.reactor import BACKEND_EPOLL, Reactor

comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_STREAM: Int32 = Int32(1)


def _socketpair() raises -> Array[Int32, 2]:
    """SAFETY: `pair` is stack-local; the kernel writes two fds into it and
    keeps no pointer."""
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), pair.unsafe_ptr(),
    )
    if rc < 0:
        raise Error("socketpair() failed")
    return pair^


def _send_one_byte(fd: Int32) raises:
    var buf = Array[UInt8, 1](fill=UInt8(0x5A))
    # SAFETY: `buf` is stack-local; the kernel only reads it.
    if external_call["send", Int](fd, buf.unsafe_ptr(), UInt(1), Int32(0)) != 1:
        raise Error("send() failed")


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _events_for(mut r: Reactor[NoopSink], fd: Int32, timeout_us: Int32) raises -> Int:
    """Completions reported for `fd` (the long-lived cookie is the fd)."""
    var got = r.poll_completions(timeout_us=timeout_us)
    var n = 0
    for i in range(len(got)):
        if got[i].op_id == Int64(fd):
            n += 1
    return n


def test_read_reported_after_write_and_back() raises:
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair()
        var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
        var reg = r.register_long_lived(sv[0], INTEREST_READ)
        r.modify(reg, INTEREST_WRITE)
        # The MOD to EPOLLOUT reports the (writable) socket once; drain it.
        _ = _events_for(r, sv[0], Int32(0))
        r.modify(reg, INTEREST_READ)
        # Nothing is readable yet, and write readiness is no longer armed.
        assert_equal(_events_for(r, sv[0], Int32(0)), 0, "spurious event")
        _send_one_byte(sv[1])
        assert_equal(
            _events_for(r, sv[0], Int32(200_000)),
            1,
            "a readable descriptor was not reported after WRITE -> READ",
        )
        r._deregister_long_lived(sv[0])
        _close(sv[0])
        _close(sv[1])


def test_read_reported_after_a_switch_through_a_copy() raises:
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair()
        var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
        var reg = r.register_long_lived(sv[0], INTEREST_READ)
        # A caller that switches through a copy of its handle (a local, an
        # Optional's value, a struct field read by value).
        var copy = reg
        r.modify(copy, INTEREST_WRITE)
        _ = _events_for(r, sv[0], Int32(0))
        # Back to READ through the original: the descriptor is armed for
        # WRITE, so this must re-arm it.
        r.modify(reg, INTEREST_READ)
        assert_equal(_events_for(r, sv[0], Int32(0)), 0, "spurious event")
        _send_one_byte(sv[1])
        assert_equal(
            _events_for(r, sv[0], Int32(200_000)),
            1,
            "readable descriptor not reported after WRITE (via a copy) -> READ",
        )
        r._deregister_long_lived(sv[0])
        _close(sv[0])
        _close(sv[1])


def test_modify_to_the_armed_mask_issues_no_rearm() raises:
    comptime if CompilationTarget.is_linux():
        var sv = _socketpair()
        var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
        var reg = r.register_long_lived(sv[0], INTEREST_READ)
        r.modify(reg, INTEREST_WRITE)
        # The socket is writable: the MOD reports it once (edge-triggered).
        assert_true(_events_for(r, sv[0], Int32(200_000)) >= 1, "no edge")
        assert_equal(_events_for(r, sv[0], Int32(0)), 0, "edge re-reported")
        # Same mask again: no EPOLL_CTL_MOD, so no fresh edge.
        r.modify(reg, INTEREST_WRITE)
        assert_equal(
            _events_for(r, sv[0], Int32(0)),
            0,
            "modify to the armed mask re-armed the descriptor",
        )
        r._deregister_long_lived(sv[0])
        _close(sv[0])
        _close(sv[1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
