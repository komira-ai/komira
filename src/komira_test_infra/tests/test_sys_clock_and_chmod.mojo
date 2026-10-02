# Guards `_clock_realtime_unix_seconds` and `_chmod` in komira_test_infra._sys.
#
# The clock: a reading is a plausible epoch (after 2026-09-01, before 2100),
# and two readings never go backwards by more than the slack a wall clock may
# step. A constant or a millisecond reading fails the range check.
#
# chmod: each mode written is the mode `stat` then reads back, so a call that
# drops or truncates the mode argument fails; a missing path returns False.

from std.os import stat, remove
from std.testing import assert_equal, assert_false, assert_true

from komira_core_ffi.posix import _read_env
from komira_test_infra._sys import _chmod, _clock_realtime_unix_seconds

comptime _EPOCH_2026_09_01: Int = 1788220800
comptime _EPOCH_2100_01_01: Int = 4102444800


def test_clock_is_a_plausible_epoch() raises:
    var a = _clock_realtime_unix_seconds()
    assert_true(a > _EPOCH_2026_09_01, "clock reads before 2026-09-01")
    assert_true(a < _EPOCH_2100_01_01, "clock reads after 2100 (milliseconds?)")
    var b = _clock_realtime_unix_seconds()
    assert_true(b >= a - 1, "clock went backwards")


def test_chmod_round_trips_the_mode() raises:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    var path = tmp + "/chmod_probe"
    with open(path, "w") as f:
        f.write("x")
    for mode in [0o600, 0o640, 0o755, 0o400]:
        assert_true(_chmod(path, mode))
        assert_equal(Int(stat(path).st_mode) & 0o7777, mode)
    assert_true(_chmod(path, 0o600))
    remove(path)
    assert_false(_chmod(path, 0o600), "chmod of a missing path succeeded")


def main() raises:
    test_clock_is_a_plausible_epoch()
    test_chmod_round_trips_the_mode()
    print("test_sys_clock_and_chmod: OK")
