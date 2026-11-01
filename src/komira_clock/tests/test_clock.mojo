# =============================================================================
# test_clock.mojo -- the process clocks
# =============================================================================
#
# Runs on Linux and macOS.
#
# Verifies:
#   1. now_ns() is non-zero and never decreases across reads.
#   2. now_ns() advances while the thread keeps reading it, and is denominated
#      in nanoseconds: it lies between two reads of the platform's monotonic
#      clock id taken just before and just after it (an ordering, not a
#      duration).
#   3. now_unix_ms() / now_unix_us() read the same wall clock: us ~= ms * 1000,
#      and the instant is a plausible epoch reading, before 2100.
#   4. thread_cpu_ns() is non-zero, never decreases, and advances while the
#      thread burns CPU; and it is the thread's CPU clock, not a wall or
#      process clock: while a thread is blocked in a join, its own CPU reading
#      moves by less than the CPU the other thread burned meanwhile, although
#      the wall clock moved by at least that much.
#   5. _read_ns() answers 0 ("no reading") when clock_gettime refuses the
#      clock id, and a non-zero reading for a clock id it accepts.
# =============================================================================

from std.memory import Pointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_fork_join import ForkJoinBody, fork_join

from komira_clock.clock import (
    _CLOCK_MONOTONIC_LINUX,
    _CLOCK_REALTIME,
    _CLOCK_UPTIME_RAW,
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


def test_now_ns_advances_with_work() raises:
    # Spin until the clock ticks; the loop ends on the clock's own progress,
    # so no wall-clock duration is asserted.
    var a = now_ns()
    var b = now_ns()
    while b == a:
        b = now_ns()
    assert_true(b > a, "now_ns advances while the thread keeps reading it")
    print("  test_now_ns_advances_with_work PASS")


def test_now_ns_is_nanoseconds() raises:
    # `now_ns` reads the platform's monotonic clock; the same clock read
    # through `_read_ns` (whose unit is the timespec's, nanoseconds by
    # construction) just before and just after it must bracket it. A reading in
    # any other unit falls outside the bracket by orders of magnitude. The
    # check is an ordering of three reads, so it holds however long the thread
    # is descheduled between them.
    comptime source = _CLOCK_UPTIME_RAW if CompilationTarget.is_macos() else _CLOCK_MONOTONIC_LINUX
    var before = _read_ns(source)
    var n = now_ns()
    var after = _read_ns(source)
    assert_true(before > UInt64(0), "the reference clock answers")
    assert_true(n >= before, "now_ns is not below the reference clock")
    assert_true(n <= after, "now_ns is not above the reference clock")
    print("  test_now_ns_is_nanoseconds PASS")


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
    var c2 = thread_cpu_ns()
    assert_true(c2 >= c1, "thread CPU time never goes backwards")
    print("  test_thread_cpu_ns_counts_own_cpu PASS")


struct _Burn:
    """Run by one other thread: burns CPU, recording its own CPU reading
    before and after. Written by that thread only and read after the join."""

    var cpu_before: UInt64
    var cpu_after: UInt64
    var acc: UInt64

    def __init__(out self):
        self.cpu_before = 0
        self.cpu_after = 0
        self.acc = 0


struct _BurnBody[o: MutOrigin](ForkJoinBody):
    var burn: Pointer[_Burn, Self.o]

    def __init__(out self, burn: Pointer[_Burn, Self.o]):
        self.burn = burn

    def run(self, tid: Int) raises:
        self.burn[].cpu_before = thread_cpu_ns()
        # A xorshift chain: each step depends on the last and has no closed
        # form, so the loop cannot be folded away.
        var acc = UInt64(88172645463325252)
        for _ in range(100_000_000):
            acc = acc ^ (acc << UInt64(13))
            acc = acc ^ (acc >> UInt64(7))
            acc = acc ^ (acc << UInt64(17))
        self.burn[].acc = acc
        self.burn[].cpu_after = thread_cpu_ns()


def test_thread_cpu_ns_is_not_wall_or_process_time() raises:
    # This thread blocks in `fork_join`'s join (an event: the other thread
    # exiting) while the other thread burns CPU. Across that wait:
    #   * the wall clock advances;
    #   * this thread's CPU reading moves by less than what the other thread
    #     burned. A wall clock would move by the whole wait (more than the
    #     other thread's CPU), and a process-wide CPU clock would include the
    #     other thread's CPU.
    # Both sides are CPU clocks read on their own threads, so nothing here
    # bounds a duration.
    var burn = _Burn()
    var body = _BurnBody(Pointer(to=burn))
    var wall0 = now_ns()
    var cpu0 = thread_cpu_ns()
    fork_join(body, 1)
    var cpu1 = thread_cpu_ns()
    var wall1 = now_ns()
    assert_true(burn.acc != UInt64(1), "burn result consumed")
    var other = burn.cpu_after - burn.cpu_before
    var waited_cpu = cpu1 - cpu0
    var waited_wall = wall1 - wall0
    assert_true(other > UInt64(0), "the other thread burned CPU")
    assert_true(waited_wall > waited_cpu, "the wall clock advanced through the wait")
    assert_true(
        waited_cpu < other,
        "a blocked thread's CPU clock does not follow the wall clock or the other thread",
    )
    print("  test_thread_cpu_ns_is_not_wall_or_process_time PASS")


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
    test_now_ns_advances_with_work()
    test_now_ns_is_nanoseconds()
    test_unix_clocks_agree()
    test_thread_cpu_ns_counts_own_cpu()
    test_thread_cpu_ns_is_not_wall_or_process_time()
    test_read_ns_refused_clock_id_is_zero()
    print()
    print("ALL TESTS PASS")
