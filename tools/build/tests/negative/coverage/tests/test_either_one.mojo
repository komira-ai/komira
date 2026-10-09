# Runs every line of covandor, but its `or`, whose result is returned, is
# only ever decided by its right operand (`a` is never true): one arm of
# the `or`, its right operand skipped, is never taken (test 46).
from covandor import either
from std.testing import assert_true


def main() raises:
    assert_true(either(False, True), "the right operand decides")
