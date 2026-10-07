# Fails (exit 1), leaving a child that exits 0 half a second later (test
# 43). Its coverage run must be red with the test's status, exit 1 (kcov v42
# as released returns the child's 0, and the run went green).
from exits import fork_child_exiting, one
from std.testing import assert_equal, assert_true


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
    assert_true(fork_child_exiting(Int32(0), UInt32(500_000)) > 0, "fork")
    raise Error("test_parent_fails: the test's own failure")
