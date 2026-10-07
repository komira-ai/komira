# Passes and leaves nothing running (test 43): its coverage run under the
# same 20 s limit as test_lingers must be green, so that run's red is the
# child it left, not a limit too short for a run.
from linger import one
from std.testing import assert_equal


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
