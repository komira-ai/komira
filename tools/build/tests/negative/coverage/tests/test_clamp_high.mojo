# Calls clamp(20) only: every line of covbranch runs, but the `if` is never
# false, so one of its two branch arms is not taken (test 46).
from covbranch import clamp
from std.testing import assert_equal


def main() raises:
    assert_equal(clamp(20), 10, "clamped")
