# Passes, leaving a child that sleeps 100 s (test 43). Green in the release
# gate, which waits for the test alone. kcov waits for every process the test
# started, so its coverage run, bounded by a test-only limit of 20 s, must be
# red saying the test left processes running.
from linger import fork_child_sleeping, one
from std.testing import assert_equal, assert_true


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
    assert_true(fork_child_sleeping(UInt32(100)) > 0, "fork")
