# =============================================================================
# test_soak_http_24h.mojo
# =============================================================================
# long-running soak test simulating HTTP-server-shaped
# workload over the komira_async substrate.
#
# Why "simulating" not "real HTTP": a full network-bound HTTP-server
# soak that drives bombardier as an external process for 24 hours is
# a heavyweight fixture. This test exercises the
# substrate-side load shape (per-request work + per-request lifecycle)
# at high cadence over a long duration, validating that the
# substrate's concurrency primitives don't degrade or leak across
# millions of "request" cycles.
#
# Workload per "request":
#   1. Spawn child cancellation token from a per-test-run root.
#   2. Submit one morsel to a per-request MorselPool.
#   3. Drain the morsel.
#   4. Cancel the child token.
#   5. Drop request-local state.
#
# This is the SHAPE of what an HTTP server does per-request: token
# bookkeeping + work queue + drain + cancel-on-completion. Soaking
# this for hours surfaces leaks / degradation that 100-iteration unit
# tests miss.
#
# Soak duration comes from the `--soak-hours=N` command-line argument (same
# semantics as test_soak_continuous_churn.mojo):
#   - Absent / 0 → 60 seconds smoke (the gated test run)
#   - N > 0 → N hours (a manual long run of the test binary)
#
# Pointer discipline: zero new public-API pointers.
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


# -----------------------------------------------------------------------------
# Env + resource probes (same idioms as sister soak test).
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
    """Cross-platform peak RSS in KB. Mac uses
    task_info(MACH_TASK_BASIC_INFO).resident_size_max via the
    `komira_mac_peak_resident_bytes` shim."""
    comptime if CompilationTarget.is_linux():
        var buf = Array[Int64, 18](fill=Int64(0))
        var rc = external_call["getrusage", Int32](Int32(0), buf.unsafe_ptr())
        if rc != Int32(0):
            return Int64(-1)
        return buf[4]
    elif CompilationTarget.is_macos():
        var bytes = external_call["komira_mac_peak_resident_bytes", Int64]()
        if bytes < Int64(0):
            return Int64(-1)
        return bytes // Int64(1024)
    else:
        return Int64(-1)


def _fd_count() -> Int64:
    """Cross-platform open-fd count. Mac uses
    proc_pidinfo(PROC_PIDLISTFDS) via the `komira_mac_fd_count` shim."""
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
    """CLOCK_MONOTONIC seconds. Mac CLOCK_MONOTONIC
    is 6 (not 1 — that's CLOCK_PROCESS_CPUTIME_ID on Darwin)."""
    var ts = Array[Int64, 2](fill=Int64(0))
    comptime if CompilationTarget.is_macos():
        _ = external_call["clock_gettime", Int32](Int32(6), ts.unsafe_ptr())
    else:
        _ = external_call["clock_gettime", Int32](Int32(1), ts.unsafe_ptr())
    return ts[0]


# -----------------------------------------------------------------------------
# Per-request workload simulation.
# -----------------------------------------------------------------------------


def _http_request_iteration(mut root: CancellationToken) raises:
    """Simulate one HTTP request: child token + per-request work +
    drain + cancel. The substrate sees one full request lifecycle
    on each call."""
    var req_token = root.child()
    var req_pool = MorselPool[Int].with_capacity(UInt(8))
    req_pool.submit(0)
    req_pool.close()
    while True:
        var item = req_pool.try_claim()
        if not item.__bool__():
            break
    req_token.cancel(String("request_complete"))
    _ = req_token^
    _ = req_pool^


# -----------------------------------------------------------------------------
# Test.
# -----------------------------------------------------------------------------


def test_soak_http_request_shape() raises:
    """HTTP-shape soak. One PerCoreAsyncRuntime stays
    alive for the whole duration; per-iteration we simulate one
    request lifecycle (child token + morsel pool + drain + cancel).
    Validates that the substrate doesn't accumulate per-request
    state over millions of cycles.

    cross-platform via Mach shim; it does not silently return on
    darwin-arm64.
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

    # One long-lived runtime for the whole soak.
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    rt.start()

    var root = CancellationToken.new()

    # Warm-up.
    for _ in range(100):
        _http_request_iteration(root)

    var start_time = _wall_seconds()
    var rss_after_warmup = _peak_rss_kb()
    var fd_after_warmup = _fd_count()

    print("SOAK_HTTP START duration=", duration_sec,
          "s rss_baseline=", rss_after_warmup,
          "KB fd_baseline=", fd_after_warmup)

    var iter_count = Int64(0)
    var deadline = start_time + duration_sec

    while _wall_seconds() < deadline:
        _http_request_iteration(root)
        iter_count += 1
        if iter_count % Int64(10_000) == Int64(0):
            var elapsed = _wall_seconds() - start_time
            var current_rss = _peak_rss_kb()
            print("SOAK_HTTP iter=", iter_count, "elapsed=", elapsed,
                  "s rss=", current_rss, "KB")

    # Tear down + verify.
    rt.shutdown()

    var rss_final = _peak_rss_kb()
    var fd_final = _fd_count()
    var elapsed = _wall_seconds() - start_time

    print("SOAK_HTTP END iters=", iter_count, "elapsed=", elapsed,
          "s rss_final=", rss_final, "KB fd_final=", fd_final)

    # Drop runtime + root.
    _ = rt^
    _ = root^

    # Assertions: same shape as continuous-churn soak.
    assert_true(
        iter_count >= Int64(1_000),
        String("http soak iters=") + String(iter_count) + String(" < 1000"),
    )

    if rss_after_warmup > Int64(0) and rss_final > Int64(0):
        var rss_delta = rss_final - rss_after_warmup
        if rss_delta < Int64(0):
            rss_delta = Int64(0)
        assert_true(
            rss_delta <= rss_budget_kb,
            String("http soak RSS grew ") + String(rss_delta)
            + String(" KB > budget ") + String(rss_budget_kb) + String(" KB"),
        )

    if fd_after_warmup > Int64(0) and fd_final > Int64(0):
        var fd_delta = fd_final - fd_after_warmup
        if fd_delta < Int64(0):
            fd_delta = -fd_delta
        assert_true(
            fd_delta <= Int64(4),
            String("http soak fd leak: delta=") + String(fd_delta),
        )


def test_wall_seconds_advances() raises:
    """Regression test for CLOCK_MONOTONIC constant
    drift on Darwin. Mirror of `test_soak_continuous_churn`'s same-name
    test — both soak files have their own private `_wall_seconds()`,
    both must catch the bug if it ever regresses on either soak path."""
    var t0 = _wall_seconds()
    assert_true(
        t0 > Int64(0),
        String("CLOCK_MONOTONIC must return a positive value; got ")
        + String(t0),
    )
    _ = external_call["usleep", Int32](UInt32(1_500_000))
    var t1 = _wall_seconds()
    assert_true(
        t1 > t0,
        String("_wall_seconds must advance across usleep(1.5s); t0=")
        + String(t0) + String(" t1=") + String(t1),
    )


def main() raises:
    test_wall_seconds_advances()
    test_soak_http_request_shape()
    print("PASS komira_async.soak.test_soak_http_24h")
