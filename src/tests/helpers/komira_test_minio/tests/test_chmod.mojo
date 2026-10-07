# Guards `_chmod` in komira_test_minio._sys: each mode written is the mode
# `stat` then reads back, so a call that drops or truncates the mode argument
# fails; a missing path returns False.

from std.os import stat, remove
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_test_minio._sys import _chmod


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
    test_chmod_round_trips_the_mode()
    print("test_chmod: OK")
