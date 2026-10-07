# Passes, leaving a child that exits 3 half a second after the test has
# exited (test 43). Green in the release gate, and its coverage run must be
# green too: the run's status is the test's, not that of the last process
# kcov traced (kcov v42 as released returns the child's 3).
from exits import fork_child_exiting, one
from std.testing import assert_equal, assert_true


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
    assert_true(fork_child_exiting(Int32(3), UInt32(500_000)) > 0, "fork")
