# The production seams: SystemClock reads milliseconds, SystemSleeper really
# sleeps, and system_retry_loop runs end to end on both.

from komira_retry import (
    Backoff,
    Jitter,
    NoBudget,
    RetryPolicy,
    SystemClock,
    SystemSleeper,
    Verdict,
    system_retry_loop,
)

from std.testing import assert_equal, assert_true


comptime _NAP_MS: Int64 = 20
# Far above any scheduling delay for a 20 ms sleep, far below the 20_000 a
# clock reading microseconds (1000x) would report.
comptime _NAP_UPPER_MS: Int64 = 2000


def test_sleeper_moves_the_clock_in_milliseconds() raises:
    var clock = SystemClock()
    var sleeper = SystemSleeper()
    var before = clock.now_ms()
    sleeper.sleep_ms(_NAP_MS)
    var moved = clock.now_ms() - before
    assert_true(moved >= _NAP_MS, String("slept ") + String(moved) + " ms, asked 20")
    assert_true(moved < _NAP_UPPER_MS, String("clock moved ") + String(moved) + " for a 20 ms sleep")


def test_zero_and_negative_waits_return() raises:
    var clock = SystemClock()
    var sleeper = SystemSleeper()
    var before = clock.now_ms()
    sleeper.sleep_ms(0)
    sleeper.sleep_ms(-5)
    assert_true(clock.now_ms() - before < _NAP_UPPER_MS)


def test_system_retry_loop_really_sleeps() raises:
    var p = RetryPolicy(
        Backoff(initial_ms=_NAP_MS, multiplier=1.0, max_ms=_NAP_MS, jitter=Jitter.band(0)),
        max_attempts=3,
        deadline_ms=10_000,
    )
    var loop = system_retry_loop(p^)
    loop.start()
    var d = loop.after_failure(Verdict.transient("503"))
    assert_true(d.retry, d.reason)
    assert_equal(d.delay_ms, _NAP_MS)
    assert_equal(loop.attempts(), 2)
    var elapsed = loop.elapsed_ms()
    assert_true(elapsed >= _NAP_MS, String("loop slept ") + String(elapsed) + " ms, decided 20")
    assert_true(elapsed < _NAP_UPPER_MS, String(elapsed))
    var budget = NoBudget()
    loop.after_success(budget)


def main() raises:
    test_sleeper_moves_the_clock_in_milliseconds()
    test_zero_and_negative_waits_return()
    test_system_retry_loop_really_sleeps()
    print("test_system: OK")
