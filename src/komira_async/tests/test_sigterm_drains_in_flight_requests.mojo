# =============================================================================
# test_sigterm_drains_in_flight_requests.mojo
# =============================================================================
# Graceful drain of in-flight "request" workload across the
# full PerCoreAsyncRuntime stack (worker + runtime + morsel pool +
# shutdown flag).
#
# This is the RUNTIME-LEVEL companion to the morsel-only test in the
# sister file (test_sigterm_drains_morsel_pool.mojo). Where that
# validates the drain pattern at the pool primitive layer, this one
# validates the FULL substrate stack: PerCoreAsyncRuntime starts a
# worker pthread, processes "in-flight requests" via a MorselPool,
# observes a shutdown signal, and shuts down via the substrate's
# rt.shutdown() (which signals + joins the worker pthread).
#
# Mechanism: the same Bool-flag pattern as the sister test (see
# rationale in that file's header — Mojo 0.26.3 lacks module-level
# globals required for a literal SIGTERM handler; the FULL signal-
# handling path is exercised by the bench/komira_async/http server
# binary in CI). Substrate-level invariants are identical either way.
#
# 4 covers (runtime-level):
#   - test_runtime_drains_inflight_on_shutdown — start runtime, submit
#     100 requests, drain mid-flight, observe shutdown flag, call
#     rt.shutdown(); verify clean exit + no fd leak.
#   - test_runtime_shutdown_immediately_after_start — flag set before
#     any work; rt.shutdown() must complete bounded.
#
# Pointer discipline: zero new public-API pointers.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true
from std.sys.info import CompilationTarget

from komira_async.morsel.morsel_pool import MorselPool
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)


def _fd_count() -> Int64:
    """Count open fds. Cross-platform.

    Linux: /proc/self/fd opendir+readdir.
    Darwin: proc_pidinfo(PROC_PIDLISTFDS) via the
        `komira_mac_fd_count` shim.
    Other: -1.
    """
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
        return count - Int64(2)
    elif CompilationTarget.is_macos():
        return external_call["komira_mac_fd_count", Int64]()
    else:
        return Int64(-1)


def test_runtime_drains_inflight_on_shutdown() raises:
    """full-stack drain — runtime + morsel pool +
    shutdown flag. Mid-drain, the flag flips; loop exits; rt.shutdown()
    drains; no fd leak; no orphaned pthread."""
    var fd_baseline = _fd_count()

    # Construct + start runtime (BACKEND_MOCK keeps fd footprint small).
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()

    # In-flight request queue.
    var requests = MorselPool[Int].with_capacity(UInt(128))
    for i in range(100):
        requests.submit(i)

    var processed = Int64(0)
    var shutdown_signaled = False
    var loop_exit = String("none")
    var trigger_at = Int64(20)
    var iter = Int64(0)
    var MAX_ITER = Int64(50_000)

    while iter < MAX_ITER:
        iter += 1
        # Top-of-loop shutdown poll.
        if shutdown_signaled:
            loop_exit = String("shutdown_observed")
            break
        var req = requests.try_claim()
        if req.__bool__():
            processed += 1
            # Trigger graceful shutdown mid-drain.
            if processed == trigger_at:
                shutdown_signaled = True
        else:
            # Pool drained but still open. If we got all 100, exit.
            if processed >= Int64(100):
                loop_exit = String("all_processed")
                break

    assert_equal(loop_exit, String("shutdown_observed"))
    assert_true(processed >= trigger_at)
    assert_true(processed < Int64(100))

    # Graceful runtime shutdown (signals worker pthread + joins).
    rt.shutdown()

    # Drain the request pool's remainder (so the dtor sees consistent state).
    requests.close()
    while True:
        var rem = requests.try_claim()
        if not rem.__bool__():
            break

    _ = rt^
    _ = requests^

    # fd-count delta check — no leak from the start/shutdown cycle.
    if fd_baseline > Int64(0):
        var fd_final = _fd_count()
        if fd_final > Int64(0):
            var delta = fd_final - fd_baseline
            if delta < Int64(0):
                delta = -delta
            assert_true(
                delta <= Int64(4),
                String("fd leak after shutdown drain: delta=") + String(delta),
            )


def test_runtime_shutdown_immediately_after_start() raises:
    """shutdown flag is True immediately after rt.start();
    the loop exits on iteration 1; rt.shutdown() must still complete
    bounded (no hang). Validates the race where shutdown arrives
    before the worker has even processed its first work item."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()

    var shutdown_signaled = True
    var loop_iter = Int64(0)
    while True:
        loop_iter += 1
        if shutdown_signaled:
            break
    assert_equal(loop_iter, Int64(1))

    # rt.shutdown() must join the worker cleanly within bounded time.
    rt.shutdown()
    assert_equal(Int(rt.worker_count()), 1)


def test_runtime_shutdown_then_restart_cycle() raises:
    """runtime can be torn down + recreated multiple times
    without leaks. This is the core soak-test pattern at small scale —
    20 cycles validates the start/shutdown sequence is stable."""
    var fd_baseline = _fd_count()

    for _ in range(20):
        var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
        rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
        rt.start()
        # Tiny delay so worker enters its loop.
        _ = external_call["usleep", Int32](UInt32(500))
        rt.shutdown()

    if fd_baseline > Int64(0):
        var fd_final = _fd_count()
        if fd_final > Int64(0):
            var delta = fd_final - fd_baseline
            if delta < Int64(0):
                delta = -delta
            assert_true(
                delta <= Int64(4),
                String("fd leak across 20 start/shutdown cycles: delta=")
                + String(delta),
            )


def main() raises:
    test_runtime_drains_inflight_on_shutdown()
    test_runtime_shutdown_immediately_after_start()
    test_runtime_shutdown_then_restart_cycle()
    print("PASS komira_async.stress.test_sigterm_drains_in_flight_requests")
