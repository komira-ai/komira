# =============================================================================
# test_morsel_pool_no_leak.mojo
# =============================================================================
# MorselPool[T] heap-leak detection.
#
# After repeated submit-drain-close-drop cycles, the process RSS must
# NOT grow (modulo allocator-arena retention which is bounded). Even
# tiny leaks compound across thousands of soak cycles.
#
# Detection mechanism (cross-platform):
#   - Linux: `getrusage(RUSAGE_SELF, &usage).ru_maxrss` (KB).
#   - Darwin: `task_info(MACH_TASK_BASIC_INFO,
#     ...).resident_size_max` via the `komira_mac_peak_resident_bytes`
#     shim in `_posix_shim.c`. The shim returns BYTES uniformly across
#     platforms (Linux's getrusage returns KB on Linux, bytes on Darwin
#     — we hide this difference at the shim layer and report KB to the
#     caller).
#   - We track DELTA between cycles, not absolute peak — peak_rss is
#     monotonic-peak so we re-read after drop and compare to baseline.
#
# Limitations: peak RSS is "peak resident set size SO FAR" — once
# something allocates 100MB, peak stays at 100MB even if it's
# freed. We use this metric only as a coarse upper-bound check; the
# more precise leak detection comes from `claimed_count` invariants
# (every submitted morsel is consumed exactly once) which catch logic
# leaks even when allocator behavior masks RSS.
#
# Pointer discipline: pure stdlib + komira_async; FFI is
# concrete-typed.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.morsel.morsel_pool import MorselPool


# -----------------------------------------------------------------------------
# Helper: peak RSS in KB. Cross-platform.
# - Linux: getrusage(RUSAGE_SELF).ru_maxrss (KB) — read from offset 32 of
#   struct rusage as Int64.
# - Darwin: komira_mac_peak_resident_bytes shim → bytes / 1024 = KB.
# - Other: -1.
# -----------------------------------------------------------------------------
def _peak_rss_kb() -> Int64:
    """Returns peak resident-set-size in KB. -1 on unsupported platforms."""
    comptime if CompilationTarget.is_linux():
        # Stack-allocated buffer big enough for struct rusage (144 B on x86_64).
        # SAFETY: buffer scope is limited to this function; no escape; no
        # cross-module pointer passing. FFI is exactly one syscall.
        var buf = Array[Int64, 18](fill=Int64(0))
        var rc = external_call["getrusage", Int32](
            Int32(0),  # RUSAGE_SELF
            buf.unsafe_ptr(),
        )
        if rc != Int32(0):
            return Int64(-1)
        # ru_maxrss at offset 32 = element index 4 (4 * 8 = 32). KB on Linux.
        return buf[4]
    elif CompilationTarget.is_macos():
        var bytes = external_call["komira_mac_peak_resident_bytes", Int64]()
        if bytes < Int64(0):
            return Int64(-1)
        return bytes // Int64(1024)
    else:
        return Int64(-1)


def test_morsel_pool_submit_drain_no_growth() raises:
    """submit 10K morsels; close + drain; assert
    `claimed_count == 10K` and `is_drained() == True`. Repeat 50x;
    verify peak RSS doesn't grow more than 50 MB across the loop."""
    var baseline_rss = _peak_rss_kb()

    for _ in range(50):
        var pool = MorselPool[Int].with_capacity(UInt(16384))
        for i in range(10000):
            pool.submit(i)
        pool.close()
        var claimed = Int64(0)
        while True:
            var item = pool.try_claim()
            if not item.__bool__():
                break
            claimed += 1
        assert_equal(claimed, Int64(10000))
        assert_true(pool.is_drained())
        # pool drops here.

    # On Linux, peak RSS should not grow more than 50MB across 50
    # cycles of submit/drain (10K Int = 80KB raw; even with overhead
    # this should not balloon).
    if baseline_rss > Int64(0):
        var final_rss = _peak_rss_kb()
        if final_rss > Int64(0):
            var delta_kb = final_rss - baseline_rss
            # 50MB = 51200 KB tolerance.
            assert_true(
                delta_kb <= Int64(51200),
                String("RSS grew ") + String(delta_kb)
                + String(" KB across 50 morsel-pool cycles (limit 51200 KB)"),
            )


def test_morsel_pool_claimed_count_invariant() raises:
    """across 100 submit-drain cycles, `claimed_count` must
    EXACTLY equal the number of items submitted. This is the
    logic-level leak check — even if RSS metric is fuzzy, this is
    deterministic."""
    for _ in range(100):
        var pool = MorselPool[Int].with_capacity(UInt(256))
        for i in range(200):
            pool.submit(i)
        pool.close()
        var claimed = Int64(0)
        while True:
            var item = pool.try_claim()
            if not item.__bool__():
                break
            claimed += 1
        # Exact match — no morsel left behind, no morsel double-claimed.
        assert_equal(claimed, Int64(200))
        assert_equal(pool.claimed_count(), Int64(200))
        assert_true(pool.is_drained())


def test_morsel_pool_close_without_drain() raises:
    """close() without consuming → drop. Must not leak heap
    or panic; the pool's internal slab must free itself on drop even
    if items remain unclaimed."""
    for _ in range(50):
        var pool = MorselPool[Int].with_capacity(UInt(64))
        for i in range(40):
            pool.submit(i)
        pool.close()
        # Don't drain — drop with items still in the pool.
        # The pool's destructor must walk the slab and properly free
        # any T values still resident.
        _ = pool^


def test_morsel_pool_open_drop() raises:
    """open pool with submitted items + drop without close().
    This is the messiest teardown path; must not leak."""
    for _ in range(50):
        var pool = MorselPool[Int].with_capacity(UInt(32))
        for i in range(20):
            pool.submit(i)
        # No close, no drain — direct drop.
        _ = pool^


def test_peak_rss_probe_works_on_supported_platform() raises:
    """Regression test.

    An earlier shape of `_peak_rss_kb()` returned -1 on Mac, silently
    disabling the RSS-growth assertion in
    `test_morsel_pool_submit_drain_no_growth`. The fix added a Mach
    `task_info(MACH_TASK_BASIC_INFO).resident_size_max`-based path via
    the `_posix_shim.c` `komira_mac_peak_resident_bytes` shim. This
    test asserts the helper returns a positive KB value on every
    supported platform so a future regression cannot re-introduce the
    silent skip.
    """
    comptime if CompilationTarget.is_linux() or CompilationTarget.is_macos():
        var kb = _peak_rss_kb()
        assert_true(
            kb > Int64(0),
            String("peak-RSS probe must succeed on Linux+Darwin: got ")
            + String(kb) + String(" KB"),
        )


def main() raises:
    test_morsel_pool_submit_drain_no_growth()
    test_morsel_pool_claimed_count_invariant()
    test_morsel_pool_close_without_drain()
    test_morsel_pool_open_drop()
    test_peak_rss_probe_works_on_supported_platform()
    print("PASS komira_async.leak.test_morsel_pool_no_leak")
