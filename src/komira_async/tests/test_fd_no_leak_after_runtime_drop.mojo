# =============================================================================
# test_fd_no_leak_after_runtime_drop.mojo
# =============================================================================
# file descriptor leak detection.
#
# After repeated construct→start→shutdown→drop cycles of
# `PerCoreAsyncRuntime`, the process's open-fd count must NOT grow.
# Even one fd leaked per cycle compounds in soak (24h × thousands of
# cycles → fd-table exhaustion).
#
# Detection mechanism (cross-platform):
#   - Linux: count entries in `/proc/self/fd/` via `opendir + readdir`.
#   - Darwin: `proc_pidinfo(getpid(), PROC_PIDLISTFDS,
#     ...)` via the `komira_mac_fd_count` shim in `_posix_shim.c`.
#     ⛔ THE SENTENCE THAT STOOD HERE DESCRIBED THE BUG AS THE DESIGN. It
#     said the shim divides the return of the zero-buffer "size-query"
#     idiom, and it did — but that return is the fd TABLE CAPACITY, which
#     does not move when a descriptor is opened or closed, so every delta
#     taken on darwin was identically zero for four months. Fixed
#     2026-09-13 to the two-call form: size-query for the buffer, then a
#     REAL FILL, dividing the SECOND call's return (the bytes actually
#     written = one entry per OPEN descriptor). Held there by
#     `test_fd_count_probe_is_not_a_constant` below.
#   - Both report ALL open fds (sockets, pipes, eventfds, regular files).
#
# Pointer discipline: zero new public-API pointers; FFI is
# concrete-typed.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)


# -----------------------------------------------------------------------------
# Helper: count open fds. Cross-platform (Linux /proc + Darwin proc_pidinfo).
# Returns Int64; -1 if unavailable.
# -----------------------------------------------------------------------------
def _fd_count() -> Int64:
    """Count open fds in current process.

    DIR* and dirent* are opaque to us — Int (uintptr) handle.
    SAFETY: handle is local to this function; closedir frees it on
    every path."""
    comptime if CompilationTarget.is_linux():
        var path = String("/proc/self/fd")
        var dirp = external_call["opendir", Int](
            path.as_c_string_slice().unsafe_ptr()
        )
        if dirp == Int(0):
            return Int64(-1)
        var count = Int64(0)
        while True:
            var entry = external_call["readdir", Int](dirp)
            if entry == Int(0):
                break
            count += 1
        _ = external_call["closedir", Int32](dirp)
        # Subtract "." and ".." plus the readdir-temporary fd (the dirp
        # itself is one of the listed entries during the iteration). The
        # exact bookkeeping doesn't matter — we compare relative deltas.
        return count - Int64(2)
    elif CompilationTarget.is_macos():
        # Mach `proc_pidinfo(PROC_PIDLISTFDS)` shim. Returns -1 on error,
        # else the count of open file descriptors. No DIR resource to
        # clean up at the Mojo layer.
        return external_call["komira_mac_fd_count", Int64]()
    else:
        return Int64(-1)


def test_no_fd_leak_mock_backend() raises:
    """50 cycles of construct→start→shutdown→drop with
    BACKEND_MOCK must NOT grow the fd count.

    BACKEND_MOCK is the cleanest signal: it doesn't open epoll/eventfd
    at all, so any fd-count growth is from the runtime infrastructure
    itself (pthread, locks, etc.) and would be a real leak.

    Mac uses Mach `proc_pidinfo(PROC_PIDLISTFDS)`
    via the `_posix_shim.c` shim; before that, this test silently
    returned on non-Linux.
    """
    # Warm-up: one cycle to amortize libc / glibc lazy fd allocation.
    var warmup = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    warmup.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    warmup.start()
    warmup.shutdown()
    _ = warmup^

    var baseline = _fd_count()
    if baseline < Int64(0):
        return

    for _ in range(50):
        var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
        rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
        rt.start()
        rt.shutdown()
        # rt drops here.

    var final = _fd_count()
    if final < Int64(0):
        return

    # Tolerance: ±4 fds for transient state (test runner stdout buffer
    # flush, /proc/self enumeration scratch). Anything larger is leaking.
    var delta = final - baseline
    if delta < Int64(0):
        delta = -delta
    assert_true(
        delta <= Int64(4),
        String("fd leak (mock backend): baseline=") + String(baseline)
        + String(" final=") + String(final)
        + String(" delta=") + String(delta),
    )


def test_no_fd_leak_construct_only_no_start() raises:
    """construct→attach_worker→DROP without start() must
    not leak any fds. This catches teardown-correctness in the
    pre-pthread-launch path."""
    var baseline = _fd_count()
    if baseline < Int64(0):
        return

    for _ in range(100):
        var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
        rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
        # No start() — drop direct.
        _ = rt^

    var final = _fd_count()
    if final < Int64(0):
        return

    var delta = final - baseline
    if delta < Int64(0):
        delta = -delta
    assert_true(
        delta <= Int64(4),
        String("fd leak (no-start path): delta=") + String(delta),
    )


def test_fd_count_probe_works_on_supported_platform() raises:
    """Regression test for the fd-count probe.

    An `_fd_count()` that returned -1 on Mac (no /proc) would silently
    disable the leak-detection assertions on darwin-arm64. The Mach
    `proc_pidinfo(PROC_PIDLISTFDS)`-based path via
    the `_posix_shim.c` `komira_mac_fd_count` shim. This test asserts
    the helper returns a positive count on every supported platform so
    a future regression cannot re-introduce the silent skip.
    """
    comptime if CompilationTarget.is_linux() or CompilationTarget.is_macos():
        var n = _fd_count()
        assert_true(
            n > Int64(0),
            String("fd-count probe must succeed on Linux+Darwin: got ")
            + String(n),
        )


def test_fd_count_probe_is_not_a_constant() raises:
    """⛔ THE NON-VACUITY CONTROL FOR THE PROBE ITSELF.

    Every fd assertion in this file — and in
    `test_sigterm_drains_in_flight_requests`, `test_soak_continuous_churn` and
    `test_soak_http_24h`, which all carry their own copy of `_fd_count` — is a
    DIFFERENCE taken through this probe. A probe that answers the SAME NUMBER
    whatever the process does makes every one of those differences identically
    zero, so they pass no matter what the code does. And nothing about that
    looks suspicious from the outside: a leak test passing is exactly what it
    looks like when there is no leak.

    ⛔ A ZERO-BUFFER SIZE QUERY IS THE TRAP. A `komira_mac_fd_count` that
    returned the `proc_pidinfo(PROC_PIDLISTFDS)` ZERO-BUFFER SIZE QUERY divided
    by `sizeof(struct proc_fdinfo)` — the documented size-query idiom, but it
    answers the fd TABLE CAPACITY, which the kernel does not move when a
    descriptor is opened or closed. MEASURED on darwin 25.5 / macOS 26, one
    process, the two forms side by side:

        baseline / +5 opens / +5 closes / bind+listen
        size query:  45 / 45 / 45 / 45   <- CONSTANT. every delta ZERO
        real fill:    3 /  8 /  3 /  4   <- exact, and sees the listener

    So this test opens descriptors and REQUIRES the probe to see them. It is RED
    against the capacity readout (a delta of 0 where 3 were opened) and green
    against the two-call real-fill form.

    ⛔ DO NOT WEAKEN THIS TO `>= 0` OR TO "the count changed somehow". The
    sibling `test_fd_count_probe_works_on_supported_platform` already asserts a
    positive count, and a positive constant is what hid the defect — it passed
    that assertion every single time. The EXACT delta is the whole test."""

    comptime if not (
        CompilationTarget.is_linux() or CompilationTarget.is_macos()
    ):
        return

    var before = _fd_count()
    assert_true(
        before > Int64(0),
        String(
            "fd-count probe must succeed before the delta can mean anything:"
            " got "
        )
        + String(before),
    )

    # Three descriptors, no filesystem dependency: `dup(0)` cannot fail for a
    # reason that is about this test.
    var a = external_call["dup", Int32](Int32(0))
    var b = external_call["dup", Int32](Int32(0))
    var c = external_call["dup", Int32](Int32(0))
    assert_true(
        a >= Int32(0) and b >= Int32(0) and c >= Int32(0),
        String("dup(0) failed; the instrument, not the probe, is broken"),
    )

    var during = _fd_count()
    _ = external_call["close", Int32](a)
    _ = external_call["close", Int32](b)
    _ = external_call["close", Int32](c)
    var after = _fd_count()

    assert_true(
        during - before == Int64(3),
        String(
            "the fd probe DID NOT SEE three descriptors this process opened:"
            " before="
        )
        + String(before)
        + String(" during=")
        + String(during)
        + String(" delta=")
        + String(during - before)
        + String(
            " (expected 3). A probe whose delta is 0 makes every leak"
            " assertion in this file vacuous — see the docstring for the"
            " measured capacity-vs-real-fill table."
        ),
    )
    assert_true(
        after == before,
        String(
            "the fd probe did not see three descriptors close again: before="
        )
        + String(before)
        + String(" after=")
        + String(after),
    )


def main() raises:
    test_no_fd_leak_mock_backend()
    test_no_fd_leak_construct_only_no_start()
    test_fd_count_probe_works_on_supported_platform()
    test_fd_count_probe_is_not_a_constant()
    print("PASS komira_async.leak.test_fd_no_leak_after_runtime_drop")
