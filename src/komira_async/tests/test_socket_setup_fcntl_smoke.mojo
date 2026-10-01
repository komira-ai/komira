# =============================================================================
# test_socket_setup_fcntl_smoke.mojo
# =============================================================================
# Regression test for the fcntl FFI signature ambiguity that blocked a
# per-core HTTP server's Mac build in `reactor/socket_setup.mojo`.
#
# Failure shape (pre-fix on darwin-arm64):
#
#   src/komira_async/reactor/socket_setup.mojo: note: called from
#       var flags = external_call["fcntl", Int32](fd, _F_GETFL)
#   stdlib/std/ffi/__init__.mojo:986:10: error: existing function with
#     conflicting signature
#   ... failed to legalize operation 'pop.external_call' that was explicitly
#     marked illegal:
#     %221 = "pop.external_call"(%75, %28) <{func = "fcntl"}> :
#     (!pop.scalar<si32>, !pop.scalar<si32>) -> !pop.scalar<si32>
#
# Root cause: the alias-resolved 2-arg `external_call["fcntl", Int32](fd,
# _F_GETFL)` and the literal-resolved 2-arg form in `socket_io.mojo`
# (`Int32(3)`) elaborate through different Mojo overload-resolution paths.
# When `socket_setup` + `socket_io` + `kqueue_subsystem` are all in the
# same compilation unit (which a per-core HTTP server's BACKEND_KQUEUE +
# `TcpListener.bind_reuseport` chain triggers), the compiler decides the
# alias-form's signature is "conflicting" with stdlib's pre-existing
# `fcntl` declaration and fails to legalize.
#
# Standalone tests like `test_tcp_stream_smoke` build clean because they
# only pull in `socket_setup` + `socket_io` (no kqueue_subsystem). Tests
# that pull in `kqueue_subsystem`
# build clean because they don't invoke `socket_tcp_nonblocking()`. The
# a per-core HTTP server is the FIRST consumer that puts all three modules
# into one compilation unit AND drives `socket_tcp_nonblocking()`.
#
# Fix: inline the literals in `socket_setup.mojo` to match
# `socket_io.mojo`'s working pattern (alias declarations removed, no
# parallel API).
#
# This regression test reproduces the full compilation context: imports
# from `Reactor` (which transitively pulls in kqueue_subsystem on Mac
# via BACKEND_KQUEUE), `socket_io` (try_io_accept fast path), AND
# `socket_setup` (socket_tcp_nonblocking + bind_inet + listen_socket
# + close_fd). Exercises the full listener-side syscall chain on Mac
# (the same chain a per-core HTTP server's per-thread setup walks).
#
# Pre-fix: building this test FAILS with the "conflicting signature" error.
# Post-fix: builds + runs clean on Mac; trivially passes on Linux (the
#          fcntl path is `is_macos()`-guarded; Linux uses SOCK_NONBLOCK).
# =============================================================================

from std.sys.info import CompilationTarget

from std.testing import assert_equal, assert_true

# IMPORTANT — the import combination below is what reproduces the bug.
# Removing any one of these three modules from the import set may make
# the regression test build clean even pre-fix. DO NOT prune.
#
# Reactor pulls in kqueue_subsystem transitively on Mac (the Reactor's
# BACKEND_KQUEUE branch instantiates KqueueSubsystem-typed code paths).
from komira_async.reactor.reactor import (
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    Reactor,
)
from komira_async.reactor.socket_io import (
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
)
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    inet_loopback_be,
    listen_socket,
    set_so_reuseaddr,
    set_so_reuseport,
    set_tcp_nodelay,
    socket_tcp_nonblocking,
)
from komira_async.ops.waker_sink import NoopSink


# -----------------------------------------------------------------------------
# Test 1 — substrate fcntl-path smoke: socket_tcp_nonblocking on Mac walks
# socket() → fcntl(F_GETFL) → fcntl(F_SETFL, ... | O_NONBLOCK), which is
# the EXACT site that fails to legalize pre-fix. If `socket_setup.mojo:162`
# is broken, this test never builds; if the runtime fcntl call fails on
# Mac, this test fails fast at `socket_tcp_nonblocking()`.
# -----------------------------------------------------------------------------


def test_socket_tcp_nonblocking_smoke() raises:
    """Pre-fix: build FAILS at lower-to-llvm with `pop.external_call ...
    fcntl ...` legalization error (the fcntl FFI signature ambiguity
    when kqueue_subsystem + socket_setup are co-instantiated). The
    primary regression assertion is COMPILE-TIME — if `socket_setup.mojo`
    `socket_tcp_nonblocking` regresses to mixed-arity fcntl, this
    test fails to BUILD.
    Post-fix: builds clean; the fd is created, made non-blocking via
    fcntl(F_GETFL) + fcntl(F_SETFL), and closed without raising.

    Runtime-side we exercise the full listener-side syscall chain:
    socket → fcntl(F_GETFL) → fcntl(F_SETFL) → setsockopt(SO_REUSEADDR)
    → setsockopt(SO_REUSEPORT) → setsockopt(TCP_NODELAY) → bind →
    listen → close. This catches both the fcntl arity bug (compile-
    time) AND the Mac SOL_SOCKET=0xffff bug that was discovered
    while landing this fix (runtime: pre-SOL_SOCKET-fix, set_so_reuseaddr
    raised "setsockopt(SO_REUSEADDR) failed" at runtime on Mac because
    the constant was hardcoded to Linux's `SOL_SOCKET=1`).
    """
    var fd = socket_tcp_nonblocking()
    assert_true(fd >= Int32(0), "socket(AF_INET, SOCK_STREAM) should succeed")
    # Mac SOL_SOCKET regression — set_so_reuseaddr / set_so_reuseport
    # use _sol_socket_value() which on Mac is 0xffff (NOT 1). Pre-fix
    # this raised "setsockopt(SO_REUSEADDR) failed" at runtime.
    set_so_reuseaddr(fd)
    set_so_reuseport(fd)
    set_tcp_nodelay(fd)
    bind_inet(fd, inet_loopback_be(), UInt16(0))    # ephemeral port
    listen_socket(fd, Int32(64))
    close_fd(fd)


# -----------------------------------------------------------------------------
# Test 2 — kqueue link-coverage: construct a Reactor[BACKEND_KQUEUE] on
# Mac to ensure kqueue_subsystem.mojo is fully elaborated in this
# compilation unit. Without this, the compiler may dead-code-elide the
# import and the regression test wouldn't reproduce the bug. We don't
# need to drive it — construction is enough to force elaboration.
# -----------------------------------------------------------------------------


def test_kqueue_link_coverage() raises:
    """Construct + drop a Reactor[BACKEND_KQUEUE] on Mac. Mirrors the
    a per-core HTTP server's per-thread Reactor instantiation. On Linux,
    BACKEND_KQUEUE construction RAISES per design — we use BACKEND_MOCK
    instead so the kqueue module is still on the include path (via the
    `from komira_async.reactor.reactor import BACKEND_KQUEUE` import
    above) but no kqueue syscall fires.
    """
    comptime if CompilationTarget.is_macos():
        var sink = NoopSink(_placeholder=UInt8(0))
        var r = Reactor[NoopSink](sink^, BACKEND_KQUEUE)
        _ = r^
    else:
        var sink = NoopSink(_placeholder=UInt8(0))
        var r = Reactor[NoopSink](sink^, BACKEND_MOCK)
        _ = r^


# -----------------------------------------------------------------------------
# Test 3 — io_path-coverage: a comptime-touch on TryIoResult to ensure
# socket_io.mojo (the WORKING fcntl call site) is in the
# compilation unit. A per-core HTTP server pulls in socket_io for the
# try_io_accept / try_io_read / try_io_write fast paths.
# -----------------------------------------------------------------------------


def test_socket_io_link_coverage() raises:
    """Touch a TryIoResult so socket_io.mojo's literal-form fcntl at
 is in the compilation unit. The bug only repros when both
    fcntl call sites (alias-form at socket_setup:162 + literal-form at
    socket_io:423) are co-instantiated.
    """
    var r = TryIoResult(_state=TRY_IO_WOULD_BLOCK, _value=Int64(0))
    assert_equal(r._state, TRY_IO_WOULD_BLOCK)
    var r2 = TryIoResult(_state=TRY_IO_READY, _value=Int64(7))
    assert_equal(r2._value, Int64(7))


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    test_socket_tcp_nonblocking_smoke()
    print("  test_socket_tcp_nonblocking_smoke OK")
    test_kqueue_link_coverage()
    print("  test_kqueue_link_coverage OK")
    test_socket_io_link_coverage()
    print("  test_socket_io_link_coverage OK")
    print(
        "PASS komira_async.runtime test_socket_setup_fcntl_smoke"
    )
