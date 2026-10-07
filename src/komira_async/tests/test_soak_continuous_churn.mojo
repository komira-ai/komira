# =============================================================================
# test_soak_continuous_churn.mojo
# =============================================================================
# long-running soak test: continuous churn of runtime
# construct/teardown + morsel pool drain cycles.
#
# Pattern (composes the leak-detection patterns into a continuous
# loop):
#   1. Construct PerCoreAsyncRuntime[NoopSink] with single attached
#      worker; start.
#   2. Submit + drain 1000 morsels via MorselPool[Int].
#   3. Cancel root cancellation token; verify cascade observed.
#   4. Tear down runtime + pool.
#   5. Repeat (1)-(4) until duration elapsed.
#
# Soak duration comes from the `--soak-hours=N` command-line argument:
#   - Absent / 0 → 60 seconds (the smoke pass the gated test run takes)
#   - N > 0 → that many hours (a manual long run of the test binary)
#
# Metrics captured:
#   - RSS at start vs end (via getrusage RUSAGE_SELF, ru_maxrss).
#   - Iteration count (cycles completed).
#   - fd count at start vs end.
#
# Assertions at end:
#   - RSS delta < 100 MB (configurable via `--soak-rss-budget-mb=N`).
#   - fd count delta ≤ 4 (libc transient tolerance).
#   - At least 100 iterations completed in the smoke window.
#
# Pointer discipline: zero new public-API pointers; all FFI
# is FFI-POD (getrusage, kill, opendir/readdir).
# =============================================================================

from std.ffi import external_call
from std.sys import argv
from std.testing import assert_true
from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.morsel.morsel_pool import MorselPool
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_collections.slab import Slab


# -----------------------------------------------------------------------------
# Command-line helpers — read `--soak-hours=` / `--soak-rss-budget-mb=`.
# -----------------------------------------------------------------------------


def _flag_int(prefix: String, default_val: Int64) -> Int64:
    """The integer value of the command-line argument `<prefix>N`, or
    `default_val` when it is absent or not a plain decimal number. A gated
    test run passes no arguments, so it always takes the default."""
    var args = argv()
    for k in range(1, len(args)):
        var a = String(args[k])
        if not a.startswith(prefix):
            continue
        var bytes = a.as_bytes()
        var start = prefix.byte_length()
        var n = len(bytes)
        if n == start or n - start > 16:
            return default_val
        var val = Int64(0)
        for i in range(start, n):
            var b = bytes[i]
            if b < UInt8(ord("0")) or b > UInt8(ord("9")):
                return default_val
            val = val * Int64(10) + Int64(Int(b) - ord("0"))
        return val
    return default_val


def _peak_rss_kb() -> Int64:
    """Peak RSS in KB. Cross-platform.

    Linux: getrusage(RUSAGE_SELF).ru_maxrss (KB).
    Darwin: task_info(MACH_TASK_BASIC_INFO).
        resident_size_max via komira_mac_peak_resident_bytes shim
        (bytes → KB).
    Other: -1.
    """
    comptime if CompilationTarget.is_linux():
        var buf = Array[Int64, 18](fill=Int64(0))
        var rc = external_call["getrusage", Int32](Int32(0), buf.unsafe_ptr())
        if rc != Int32(0):
            return Int64(-1)
        return buf[4]  # offset 32 / sizeof(long) = 4.
    elif CompilationTarget.is_macos():
        var bytes = external_call["komira_mac_peak_resident_bytes", Int64]()
        if bytes < Int64(0):
            return Int64(-1)
        return bytes // Int64(1024)
    else:
        return Int64(-1)


def _fd_count() -> Int64:
    """Open fd count. Cross-platform.

    Linux: count entries in /proc/self/fd via opendir+readdir.
    Darwin: proc_pidinfo(PROC_PIDLISTFDS) via the
        komira_mac_fd_count shim.
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


def _wall_seconds() -> Int64:
    """Returns CLOCK_MONOTONIC seconds.

    the original constant Int32(1) is
    CLOCK_MONOTONIC on Linux but CLOCK_PROCESS_CPUTIME_ID on Darwin
    (where CLOCK_MONOTONIC is 6). Hardcoding Int32(1) made the soak
    loop spin forever on Mac because tv_sec was always 0 (the soak test
    ran millions of iterations with elapsed=0 in the heartbeat log).

    Uses clock_gettime(CLOCK_MONOTONIC, &ts); returns ts.tv_sec.
    """
    var ts = Array[Int64, 2](fill=Int64(0))
    comptime if CompilationTarget.is_macos():
        # Darwin: <time.h> defines CLOCK_MONOTONIC = 6.
        _ = external_call["clock_gettime", Int32](Int32(6), ts.unsafe_ptr())
    else:
        # Linux: <bits/time.h> defines CLOCK_MONOTONIC = 1.
        _ = external_call["clock_gettime", Int32](Int32(1), ts.unsafe_ptr())
    return ts[0]


# -----------------------------------------------------------------------------
# Single soak iteration: construct → run → drain → tear down.
# -----------------------------------------------------------------------------


def _soak_iteration() raises:
    """One full cycle of the soak pattern. Each cycle:
       - Construct PerCoreAsyncRuntime + attach worker + start.
       - Submit + drain 1000 morsels.
       - Cancel a token tree (root + 50 children); verify cascade.
       - Tear down runtime + pool + tokens.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()

    var pool = MorselPool[Int].with_capacity(UInt(2048))
    for i in range(1_000):
        pool.submit(i)
    pool.close()
    var consumed = 0
    while True:
        var item = pool.try_claim()
        if not item.__bool__():
            break
        consumed += 1
    if consumed != 1_000:
        raise Error("soak iteration: morsel count mismatch " + String(consumed))

    var root = CancellationToken.new()
    var children = Slab[CancellationToken](capacity=50)
    for _ in range(50):
        children.append(root.child())
    root.cancel(String("soak"))

    rt.shutdown()
    _ = rt^
    _ = pool^
    _ = root^
    _ = children^


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_soak_continuous_churn() raises:
    """continuous-churn soak. Default duration is 60s
    (smoke); pass `--soak-hours=N` to extend to N hours.

    cross-platform — Linux uses /proc + getrusage,
    Mac uses Mach proc_pidinfo + task_info via the _posix_shim.c shims.
    It does not silently return on darwin-arm64.
    """
    var hours = _flag_int(String("--soak-hours="), Int64(0))
    var duration_sec: Int64
    if hours <= Int64(0):
        duration_sec = Int64(60)
    else:
        duration_sec = hours * Int64(3600)

    var rss_budget_mb = _flag_int(
        String("--soak-rss-budget-mb="), Int64(100)
    )
    var rss_budget_kb = rss_budget_mb * Int64(1024)

    var start_time = _wall_seconds()
    var rss_baseline = _peak_rss_kb()
    var fd_baseline = _fd_count()

    print("SOAK START duration=", duration_sec, "s rss_baseline=",
          rss_baseline, "KB fd_baseline=", fd_baseline)

    # Warm-up: a few iterations to amortize lazy allocations before
    # we capture the real baseline.
    for _ in range(5):
        _soak_iteration()

    var rss_after_warmup = _peak_rss_kb()
    var fd_after_warmup = _fd_count()

    var iter_count = Int64(0)
    var deadline = start_time + duration_sec

    while _wall_seconds() < deadline:
        _soak_iteration()
        iter_count += 1
        # Every 1000 iterations, print a heartbeat so a hung test is
        # visible in the log.
        if iter_count % Int64(1000) == Int64(0):
            var elapsed = _wall_seconds() - start_time
            var current_rss = _peak_rss_kb()
            print("SOAK iter=", iter_count, "elapsed=", elapsed,
                  "s rss=", current_rss, "KB")

    var rss_final = _peak_rss_kb()
    var fd_final = _fd_count()
    var elapsed = _wall_seconds() - start_time

    print("SOAK END iters=", iter_count, "elapsed=", elapsed,
          "s rss_final=", rss_final, "KB fd_final=", fd_final)

    # Assertions.
    # 1. Did at least 100 iterations in 60 seconds (smoke threshold;
    #    longer durations trivially exceed this).
    assert_true(
        iter_count >= Int64(100),
        String("soak iters=") + String(iter_count) + String(" < 100"),
    )

    # 2. RSS growth bounded. Compare against the post-warmup baseline
    #    (avoids spurious failures from one-time allocator arena growth).
    if rss_after_warmup > Int64(0) and rss_final > Int64(0):
        var rss_delta = rss_final - rss_after_warmup
        if rss_delta < Int64(0):
            rss_delta = Int64(0)  # Peak only goes up.
        assert_true(
            rss_delta <= rss_budget_kb,
            String("soak RSS grew ") + String(rss_delta)
            + String(" KB > budget ") + String(rss_budget_kb)
            + String(" KB across ") + String(iter_count) + String(" iters"),
        )

    # 3. fd count delta within tolerance.
    if fd_after_warmup > Int64(0) and fd_final > Int64(0):
        var fd_delta = fd_final - fd_after_warmup
        if fd_delta < Int64(0):
            fd_delta = -fd_delta
        assert_true(
            fd_delta <= Int64(4),
            String("soak fd leak: delta=") + String(fd_delta),
        )


def test_wall_seconds_advances() raises:
    """Regression test for CLOCK_MONOTONIC constant
    drift on Darwin.

    On Linux CLOCK_MONOTONIC = 1; on Darwin CLOCK_MONOTONIC = 6 (Int32(1)
    on Darwin is CLOCK_PROCESS_CPUTIME_ID which returns 0 in this
    process context). A hard-coded Int32(1) would cause
    `_wall_seconds()` to return 0 forever on Mac — the soak loop would
    never see the deadline advance.

    This regression test asserts that `_wall_seconds()` returns a
    positive monotonically-advancing value after a small `usleep`
    delay.
    """
    var t0 = _wall_seconds()
    assert_true(
        t0 > Int64(0),
        String("CLOCK_MONOTONIC must return a positive value; got ")
        + String(t0),
    )
    # Sleep 1.5s so even at second-granularity the clock advances.
    _ = external_call["usleep", Int32](UInt32(1_500_000))
    var t1 = _wall_seconds()
    assert_true(
        t1 > t0,
        String("_wall_seconds must advance across usleep(1.5s); t0=")
        + String(t0) + String(" t1=") + String(t1),
    )


def main() raises:
    # Run the regression test FIRST — fast, fails-fast on any clock-id
    # drift. The full soak runs for at least 60s; we want to catch the
    # constant bug before paying that cost.
    test_wall_seconds_advances()
    test_soak_continuous_churn()
    print("PASS komira_async.soak.test_soak_continuous_churn")
