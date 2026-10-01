# =============================================================================
# test_epoll_double_add_eexist.mojo
# =============================================================================
# Regression guard — linux epoll double-ADD EEXIST.
#
# Bug: a server crashed at Postgres connect on linux with
#   "Unhandled exception caught during execution: epoll_ctl(ADD) failed".
# Invisible on macOS (kqueue's EV_ADD silently UPDATES an already-registered
# (ident, filter)); only fires on linux (epoll's EPOLL_CTL_ADD on an fd already
# in the set returns -1/EEXIST). Strace of the host binary connecting to TLS pg:
#
#   epoll_ctl(4, EPOLL_CTL_ADD, 6, {EPOLLOUT|EPOLLET, data=0x6})  = 0   # connect
#   epoll_ctl(4, EPOLL_CTL_MOD, 6, {EPOLLIN|EPOLLET,  data=0x6})  = 0   # connected
#   epoll_ctl(4, EPOLL_CTL_ADD, 6, {EPOLLIN,          data=0x1})  = -1 EEXIST  # <-- BUG
#
# The connect phase registers socket fd 6 (op_id 0x6); the post-connect TLS
# handshake / pgwire read phase re-registers the SAME fd 6 with a new interest
# set + cookie (op_id 0x1). Pre-fix: the 2nd register raised "epoll_ctl(ADD)
# failed". Fix (epoll_subsystem.mojo): epoll_ctl_add tries EPOLL_CTL_ADD, and
# on EEXIST falls back to EPOLL_CTL_MOD with the new events+cookie — matching
# kqueue's idempotent-EV_ADD semantics.
#
# This test reproduces the double-register-same-fd scenario at the reactor /
# subsystem level using a real eventfd (which supports epoll). On linux it
# would raise pre-fix and passes post-fix. On macOS the epoll thunks raise
# "Linux only" by branch discipline, so the body is linux-gated and the test
# is a trivial pass elsewhere.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.reactor.epoll_subsystem import (
    EPOLLIN,
    EPOLLOUT,
    EPOLLET,
    epoll_create_v1,
    epoll_ctl_add,
    epoll_ctl_del,
    epoll_close,
)


def _make_eventfd() raises -> Int32:
    """Create a real eventfd (an epoll-pollable fd) for the test. Linux-only;
    callers gate on CompilationTarget.is_linux()."""
    comptime if CompilationTarget.is_linux():
        # eventfd(0, 0) — initval 0, no flags. Returns a pollable fd.
        var fd = external_call["eventfd", Int32](UInt32(0), Int32(0))
        if fd < 0:
            raise Error("eventfd() failed in test setup")
        return fd
    else:
        return Int32(-1)


def _close_fd(fd: Int32):
    comptime if CompilationTarget.is_linux():
        if fd >= 0:
            _ = external_call["close", Int32](fd)


def test_epoll_double_register_same_fd_eexist() raises:
    """Register interest on an fd, then register AGAIN on the SAME fd with a
    DIFFERENT interest set + cookie. Pre-fix the 2nd epoll_ctl_add raised
    "epoll_ctl(ADD) failed" (EEXIST); post-fix it falls back to EPOLL_CTL_MOD
    and succeeds.
    """
    comptime if CompilationTarget.is_linux():
        var epfd = epoll_create_v1()
        assert_true(epfd >= 0)
        var evfd = _make_eventfd()
        assert_true(evfd >= 0)

        # register fd for WRITE-readiness, op_id 0x6.
        # Mirrors the strace EPOLL_CTL_ADD {EPOLLOUT|EPOLLET, data=0x6}.
        epoll_ctl_add(epfd, evfd, EPOLLOUT | EPOLLET, UInt64(0x6))

        # re-register the SAME fd for
        # READ-readiness with a NEW cookie (op_id 0x1). Mirrors the strace
        # EPOLL_CTL_ADD {EPOLLIN, data=0x1} that returned EEXIST pre-fix.
        # This is the exact double-ADD-same-fd that crashed the server.
        epoll_ctl_add(epfd, evfd, EPOLLIN, UInt64(0x1))

        # A THIRD re-register (different cookie again) must also succeed,
        # proving the ADD-or-MOD path is repeatable, not a one-shot.
        epoll_ctl_add(epfd, evfd, EPOLLIN | EPOLLET, UInt64(0x2))

        # Cleanup: DEL then close (epoll_ctl_del swallows ENOENT internally).
        epoll_ctl_del(epfd, evfd)
        _close_fd(evfd)
        epoll_close(epfd)
        # Reaching here without a raised Error is the assertion.
        assert_equal(Int(1), Int(1))
    else:
        # macOS / other: epoll backend is Linux-only; nothing to exercise.
        assert_equal(Int(1), Int(1))


def main() raises:
    test_epoll_double_register_same_fd_eexist()
    print("PASS komira_async.reactor epoll double-ADD EEXIST regression")
