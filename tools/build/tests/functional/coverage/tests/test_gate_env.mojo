# Test 47: a branch coverage run gives the test the release gate's
# environment, plus LLVM_PROFILE_FILE: nothing of the run script's own
# (it sets LC_ALL=C for its tools, which the gate does not).
from std.os import getenv
from std.testing import assert_equal


def main() raises:
    assert_equal(getenv("LC_ALL"), "", "LC_ALL is set, which the release gate does not set")
