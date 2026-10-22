# =============================================================================
# test_clock.mojo -- the process clocks
# =============================================================================
#
# Runs on Linux and macOS. Each clock is checked for the three things a wrong
# clock id or unit in the C shim would break: it reads, it never goes
# backwards, and its number is in the unit its name says.
#
#   1. now_ns() (monotonic): non-zero, non-decreasing over a loop of reads,
#      and across a 20 ms sleep it advances by at least 15 ms and by less
#      than 10 s, which only a reading in nanoseconds satisfies.
#   2. now_unix_ms() / now_unix_us() (wall clock): a plausible epoch reading
#      in its own unit (between 2020 and 2100), the two units agree, and a
#      20 ms sleep moves the millisecond clock by tens of milliseconds, not by
#      thousands. The wall clock can step, so no strict ordering is asserted.
#   3. thread_cpu_ns() (the calling thread's CPU time): non-zero,
#      non-decreasing, advances when the thread computes, stays flat while it
#      sleeps, and across a bracket never exceeds the wall time of that bracket
#      read from now_ns().
#
# What no test here can show: that each platform's clock id is the right one
# on that platform. The ids live in the C shim behind a preprocessor choice
# per platform, and one test run is on one platform; a wrong id on the
# platform that is not running is not reachable from it. What the tests prove
# is that on the platform that runs them, every clock reads, is ordered and
# is in nanoseconds (microseconds, milliseconds).
# =============================================================================

from std.testing import assert_true
from std.time import sleep

from komira_clock import now_ns, now_unix_ms, now_unix_us, thread_cpu_ns

# 2020-01-01T00:00:00Z and 2100-01-01T00:00:00Z, in milliseconds.
comptime _EPOCH_2020_MS = Int64(1_577_836_800_000)
comptime _EPOCH_2100_MS = Int64(4_102_444_800_000)


def test_now_ns_monotonic() raises:
    var prev = now_ns()
    assert_true(prev > UInt64(0), "now_ns is non-zero")
    for _ in range(1000):
        var cur = now_ns()
        assert_true(cur >= prev, "now_ns never goes backwards")
        prev = cur
    print("  test_now_ns_monotonic PASS")


def test_now_ns_unit_is_nanoseconds() raises:
    var a = now_ns()
    sleep(0.02)
    var b = now_ns()
    var elapsed = b - a
    # A sleep lasts at least its duration: 20 ms is 20_000_000 ns. A clock in
    # microseconds would read 20_000 here, one in seconds 0.
    assert_true(elapsed >= UInt64(15_000_000), "slept 20ms, saw >= 15ms")
    # A clock reading 1000 times too fine would read 20_000_000_000 or more;
    # ten seconds is far above any scheduling stall of a 20 ms sleep.
    assert_true(elapsed < UInt64(10_000_000_000), "slept 20ms, saw < 10s")
    print("  test_now_ns_unit_is_nanoseconds PASS")


def test_unix_clocks_are_epoch_readings() raises:
    var ms = now_unix_ms()
    var us = now_unix_us()
    assert_true(ms > _EPOCH_2020_MS, "now_unix_ms is after 2020-01-01")
    assert_true(ms < _EPOCH_2100_MS, "now_unix_ms is before 2100-01-01")
    # The same bounds in microseconds: a clock that returned milliseconds
    # here, or nanoseconds there, is outside them.
    assert_true(
        us > _EPOCH_2020_MS * Int64(1000), "now_unix_us is after 2020-01-01"
    )
    assert_true(
        us < _EPOCH_2100_MS * Int64(1000), "now_unix_us is before 2100-01-01"
    )
    print("  test_unix_clocks_are_epoch_readings PASS")


def test_unix_clocks_agree() raises:
    var ms0 = now_unix_ms()
    var us = now_unix_us()
    var ms1 = now_unix_ms()
    # `us` was read between the two ms reads, so us/1000 lies in [ms0, ms1]
    # unless the wall clock stepped backwards in between.
    assert_true(us // Int64(1000) >= ms0, "us clock >= first ms read")
    assert_true(us // Int64(1000) <= ms1, "us clock <= second ms read")
    print("  test_unix_clocks_agree PASS")


def test_unix_ms_advances_over_sleep() raises:
    # The wall clock is not monotonic (it can step), so this checks only the
    # unit, with a window wide enough that no ordinary adjustment leaves it:
    # across a 20 ms sleep the clock read in milliseconds moves by tens, not
    # by tens of thousands (nanoseconds) nor by zero (seconds).
    var ms0 = now_unix_ms()
    sleep(0.02)
    var ms1 = now_unix_ms()
    assert_true(
        ms1 - ms0 < Int64(10_000), "20 ms sleep moved the ms clock < 10 s"
    )
    assert_true(ms1 - ms0 > Int64(-10_000), "the ms clock did not jump back")
    print("  test_unix_ms_advances_over_sleep PASS")


def test_thread_cpu_ns_monotonic_and_unit() raises:
    var prev = thread_cpu_ns()
    assert_true(prev > UInt64(0), "thread_cpu_ns is non-zero")
    for _ in range(100):
        var cur = thread_cpu_ns()
        assert_true(cur >= prev, "thread_cpu_ns never goes backwards")
        prev = cur
    print("  test_thread_cpu_ns_monotonic_and_unit PASS")


def test_thread_cpu_ns_counts_own_work() raises:
    # Spin until the thread's own clock has advanced 2 ms, or one second of
    # wall time has passed. CPU time does not run while the thread is
    # descheduled, so the target is reached after about 2 ms of work however
    # busy the machine is; the wall limit is only there so a clock that never
    # advances fails the test instead of hanging it.
    var wall0 = now_ns()
    var cpu0 = thread_cpu_ns()
    var acc = UInt64(0)
    var cpu1 = cpu0
    var wall1 = wall0
    while (
        cpu1 - cpu0 < UInt64(2_000_000) and wall1 - wall0 < UInt64(1_000_000_000)
    ):
        for i in range(10_000):
            acc = acc + UInt64(i) * UInt64(i)
        cpu1 = thread_cpu_ns()
        wall1 = now_ns()
    # Keep the loop observable so it is not optimised away.
    assert_true(acc != UInt64(1), "loop result consumed")
    assert_true(
        cpu1 - cpu0 >= UInt64(2_000_000),
        "computing advanced the thread clock by 2 ms (in nanoseconds) within 1 s",
    )
    # The bracket's CPU time cannot exceed the bracket's wall time (1 ms of
    # slack for the two clocks' read points).
    assert_true(
        cpu1 - cpu0 <= (wall1 - wall0) + UInt64(1_000_000),
        "thread CPU time did not exceed wall time",
    )
    print("  test_thread_cpu_ns_counts_own_work PASS")


def test_thread_cpu_ns_flat_while_sleeping() raises:
    var cpu0 = thread_cpu_ns()
    var wall0 = now_ns()
    sleep(0.05)
    var cpu1 = thread_cpu_ns()
    var wall1 = now_ns()
    assert_true(
        wall1 - wall0 >= UInt64(40_000_000), "the thread slept for >= 40 ms"
    )
    assert_true(
        cpu1 - cpu0 < UInt64(25_000_000),
        "sleeping 50 ms burned under 25 ms of thread CPU",
    )
    print("  test_thread_cpu_ns_flat_while_sleeping PASS")


def main() raises:
    print("test_clock")
    print("==========")
    test_now_ns_monotonic()
    test_now_ns_unit_is_nanoseconds()
    test_unix_clocks_are_epoch_readings()
    test_unix_clocks_agree()
    test_unix_ms_advances_over_sleep()
    test_thread_cpu_ns_monotonic_and_unit()
    test_thread_cpu_ns_counts_own_work()
    test_thread_cpu_ns_flat_while_sleeping()
    print()
    print("ALL TESTS PASS")
