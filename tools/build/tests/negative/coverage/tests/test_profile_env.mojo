# Test 47: green in the release gate, red in a branch coverage run, which
# sets LLVM_PROFILE_FILE for the test: the run's verdict is the test's.
from noop import one
from std.os import getenv
from std.testing import assert_equal


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
    assert_equal(getenv("LLVM_PROFILE_FILE"), "", "LLVM_PROFILE_FILE is set: an instrumented run")
