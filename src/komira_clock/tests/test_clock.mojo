# =============================================================================
# test_clock.mojo -- the process clocks
# =============================================================================
#
# Runs on Linux and macOS.
#
# Verifies:
#   1. now_ns() is non-zero and never decreases across reads.
#   2. now_ns() advances across a sleep, by roughly the slept time.
#   3. now_unix_ms() / now_unix_us() read the same wall clock: us ~= ms * 1000,
#      and the instant is a plausible epoch reading, before 2100.
#   4. thread_cpu_ns() is non-zero, never decreases, and advances while the
#      thread burns CPU.
#   5. _read_ns() answers 0 ("no reading") when clock_gettime refuses the
#      clock id, and a non-zero reading for a clock id it accepts.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.time import sleep

from komira_clock.clock import (
    _CLOCK_REALTIME,
    _read_ns,
    now_ns,
    now_unix_ms,
    now_unix_us,
    thread_cpu_ns,
)


def test_now_ns_monotonic() raises:
    var prev = now_ns()
    assert_true(prev > UInt64(0), "now_ns is non-zero")
    for _ in range(1000):
        var cur = now_ns()
        assert_true(cur >= prev, "now_ns never goes backwards")
        prev = cur
    print("  test_now_ns_monotonic PASS")


def test_now_ns_advances_over_sleep() raises:
    var a = now_ns()
    sleep(0.02)
    var b = now_ns()
    var elapsed = b - a
    assert_true(elapsed >= UInt64(15_000_000), "slept 20ms, saw >= 15ms")
    assert_true(elapsed < UInt64(2_000_000_000), "slept 20ms, saw < 2s")
    print("  test_now_ns_advances_over_sleep PASS")


def test_unix_clocks_agree() raises:
    var ms0 = now_unix_ms()
    var us = now_unix_us()
    var ms1 = now_unix_ms()
    assert_true(ms0 > Int64(1_000_000_000_000), "a 13-digit epoch ms (ms)")
    assert_true(ms0 < Int64(4_102_444_800_000), "before 2100-01-01 (ms)")
    # `us` was read between the two ms reads, so us/1000 lies in [ms0, ms1].
    assert_true(us // Int64(1000) >= ms0, "us clock >= first ms read")
    assert_true(us // Int64(1000) <= ms1, "us clock <= second ms read")
    print("  test_unix_clocks_agree PASS")


def test_thread_cpu_ns_counts_own_cpu() raises:
    var c0 = thread_cpu_ns()
    assert_true(c0 > UInt64(0), "thread_cpu_ns is non-zero")
    var acc = UInt64(0)
    for i in range(20_000_000):
        acc = acc + UInt64(i) * UInt64(i)
    var c1 = thread_cpu_ns()
    assert_true(c1 > c0, "CPU time advanced while computing")
    # Keep the loop observable so it is not optimised away.
    assert_true(acc != UInt64(1), "loop result consumed")
    var before_sleep = thread_cpu_ns()
    sleep(0.05)
    var after_sleep = thread_cpu_ns()
    assert_true(
        after_sleep - before_sleep < UInt64(40_000_000),
        "sleeping burns (almost) no thread CPU",
    )
    print("  test_thread_cpu_ns_counts_own_cpu PASS")


def test_read_ns_refused_clock_id_is_zero() raises:
    # No kernel defines clock id 1_000_000 (Linux accepts ids below 16 and
    # negative CPU-clock encodings; Darwin a handful below 32), so
    # clock_gettime fails with EINVAL and _read_ns takes its failure arm.
    assert_equal(_read_ns(Int32(1_000_000)), UInt64(0), "refused id reads 0")
    # The same helper on an accepted id gives a real reading, so the 0 above
    # is the failure answer, not what _read_ns returns for every clock.
    var real = _read_ns(_CLOCK_REALTIME)
    assert_true(
        real > UInt64(1_000_000_000_000_000_000), "accepted id reads epoch ns"
    )
    print("  test_read_ns_refused_clock_id_is_zero PASS")


def main() raises:
    print("test_clock")
    print("==========")
    test_now_ns_monotonic()
    test_now_ns_advances_over_sleep()
    test_unix_clocks_agree()
    test_thread_cpu_ns_counts_own_cpu()
    test_read_ns_refused_clock_id_is_zero()
    print()
    print("ALL TESTS PASS")
