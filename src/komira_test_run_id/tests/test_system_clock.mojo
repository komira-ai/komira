# `SystemClock` reads the wall clock in whole SECONDS: a reading is a
# plausible epoch (after 2026-09-01, before 2100), and two readings never go
# backwards by more than the slack a wall clock may step. A constant, or a
# millisecond reading passed through unconverted, fails the range check.

from std.testing import assert_true

from komira_test_run_id import SystemClock

comptime _EPOCH_2026_09_01: Int = 1788220800
comptime _EPOCH_2100_01_01: Int = 4102444800


def test_clock_is_a_plausible_epoch() raises:
    var clock = SystemClock()
    var a = clock.now_unix()
    assert_true(a > _EPOCH_2026_09_01, "clock reads before 2026-09-01")
    assert_true(a < _EPOCH_2100_01_01, "clock reads after 2100 (milliseconds?)")
    var b = clock.now_unix()
    assert_true(b >= a - 1, "clock went backwards")


def main() raises:
    test_clock_is_a_plausible_epoch()
    print("test_system_clock: OK")
