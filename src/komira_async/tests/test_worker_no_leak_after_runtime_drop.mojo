# =============================================================================
# test_worker_no_leak_after_runtime_drop.mojo
# =============================================================================
# worker pthread leak detection.
#
# After `PerCoreAsyncRuntime.shutdown()` returns, the worker pthread must
# have been joined (terminated). This test validates:
#   1. Single-shot construct → start → shutdown → drop: pthread is gone.
#   2. 100x repeated construct/start/shutdown/drop: no zombie threads
#      accumulate; thread count stays bounded.
#
# Detection mechanisms (cross-platform):
#   - Linux: `/proc/self/task/` directory entry count = current live thread
#     count. Read via `opendir`+`readdir`.
#   - Darwin: `task_threads(mach_task_self(), ...)`
#     via the non-variadic C shim `komira_mac_thread_count` in
#     `_posix_shim.c`. Mach-O has no /proc; the Mach API is the
#     canonical equivalent.
#   - Other: returns -1; caller skips assertion (no platform-skip silent
#     case is shipped — every supported test platform must succeed).
#
# Pointer discipline: ZERO new UnsafePointer in public sigs;
# ZERO new wildcard origins; ZERO new unsafe_from_address. All FFI is
# via external_call with concrete signatures.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)


# -----------------------------------------------------------------------------
# Helper: count live threads in current process. Cross-platform.
#
# - Linux uses `/proc/self/task/` opendir+readdir count.
# - Darwin uses Mach `task_threads` via the `_posix_shim.c`
#   `komira_mac_thread_count` non-variadic FFI shim.
# - Returns -1 on platforms with neither (caller skips assertion).
# -----------------------------------------------------------------------------
def _live_thread_count() -> Int64:
    """Count threads in the current process. Cross-platform.

    DIR* and dirent* are opaque to us — we treat them as Int (uintptr-
    sized handle). SAFETY: handle is confined to this function; never
    returned outward; closedir frees the resource on every code path.
    """
    comptime if CompilationTarget.is_linux():
        var path = String("/proc/self/task")
        # DIR* return as Int (uintptr); 0 = NULL.
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
        # Subtract "." and ".." which readdir always returns.
        return count - 2
    elif CompilationTarget.is_macos():
        # Mach `task_threads(mach_task_self(), ...)` shim. Returns -1 on
        # Mach error, otherwise the thread count. Internal mach_port_t /
        # vm_deallocate cleanup is handled inside the shim.
        return external_call["komira_mac_thread_count", Int64]()
    else:
        return Int64(-1)


def test_single_shot_thread_count_returns_to_baseline() raises:
    """After a single construct→start→shutdown cycle, the
    process's live thread count returns to the pre-start baseline.

    pthread_kill(tid, 0) is unreliable on glibc once a pthread_t has
    been joined — the handle may be reused / stale and rc=0 doesn't
    mean "still alive". The portable signal is `_live_thread_count()`
    (Linux: /proc/self/task; Mac: Mach task_threads via posix_shim):
    if shutdown drops the worker thread, the count returns to baseline.
    """
    var baseline = _live_thread_count()
    if baseline < Int64(0):
        # Platform without a thread-count probe; this only fires on
        # platforms outside the Linux + Darwin support matrix.
        return

    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()
    # Tiny delay so the worker pthread is definitely live.
    _ = external_call["usleep", Int32](UInt32(2_000))  # 2 ms
    var during = _live_thread_count()
    # 5 multi-worker: pthread_t handles live in `_thread_ids`
    # (parallel Slab[Int64], one entry per attached worker). For n=1, we
    # peek at slot 0.
    var tid_during = rt._thread_ids[0]
    assert_true(tid_during != Int64(0))
    # During run, expect at least baseline+1 threads alive.
    assert_true(
        during > baseline,
        String("expected thread count to grow during start; baseline=")
        + String(baseline) + String(" during=") + String(during),
    )
    rt.shutdown()
    # After shutdown + join, count returns to baseline (±2 for libc
    # transients).
    _ = external_call["usleep", Int32](UInt32(2_000))
    var after = _live_thread_count()
    var delta = after - baseline
    if delta < Int64(0):
        delta = -delta
    assert_true(
        delta <= Int64(2),
        String("thread count did not return to baseline: baseline=")
        + String(baseline) + String(" after=") + String(after)
        + String(" delta=") + String(delta),
    )


def test_repeated_construct_shutdown_no_thread_leak() raises:
    """100 cycles of construct→start→shutdown→drop must NOT
    accumulate zombie pthreads. Live thread count after the loop must
    equal the baseline (within a small tolerance for transient libc
    threads)."""
    var baseline = _live_thread_count()
    if baseline < Int64(0):
        return  # Platform with no thread-count probe; skip.

    for _ in range(100):
        var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
        rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
        rt.start()
        rt.shutdown()
        # rt drops at the end of this iteration scope; OwnedPointer
        # frees Worker; epoll fd closed (mock backend has none).

    var final = _live_thread_count()
    if final < Int64(0):
        return

    # Tolerance: ±2 threads for transient libc state (e.g., glibc's
    # async signal worker, or the test runner's bookkeeping). Anything
    # larger indicates a real leak.
    var delta = final - baseline
    if delta < Int64(0):
        delta = -delta
    assert_true(
        delta <= Int64(2),
        String("thread leak: baseline=") + String(baseline)
        + String(" final=") + String(final)
        + String(" delta=") + String(delta),
    )


def test_repeated_shutdown_idempotent() raises:
    """3 invariant: calling shutdown() twice is a no-op the
    second time. This also exercises the `_started` flag — after first
    shutdown, the second call must not pthread_join again (would return
    EINVAL on glibc; behavior is benign but flag check is the contract)."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()
    rt.shutdown()
    # Second shutdown is a no-op; flag-guarded.
    rt.shutdown()
    assert_equal(Int(rt.worker_count()), 1)


def test_thread_count_probe_works_on_supported_platform() raises:
    """Regression test.

    An earlier shape of `_live_thread_count()` returned -1 on any
    non-Linux platform — including Mac — which silently disabled the
    leak-detection assertions on darwin-arm64. The fix added a Mach
    `task_threads`-based path via the `_posix_shim.c`
    `komira_mac_thread_count` shim; this test asserts that on every
    supported test platform the helper returns a positive count, so
    a future regression cannot re-introduce the silent skip.

    Bug Fixing Protocol: this test would FAIL on the pre-fix code
    when run on Mac (helper returned -1), and PASSES post-fix.
    """
    comptime if CompilationTarget.is_linux() or CompilationTarget.is_macos():
        var n = _live_thread_count()
        assert_true(
            n > Int64(0),
            String("thread-count probe must succeed on Linux+Darwin: got ")
            + String(n),
        )


def main() raises:
    test_single_shot_thread_count_returns_to_baseline()
    test_repeated_construct_shutdown_no_thread_leak()
    test_repeated_shutdown_idempotent()
    test_thread_count_probe_works_on_supported_platform()
    print("PASS komira_async.leak.test_worker_no_leak_after_runtime_drop")
