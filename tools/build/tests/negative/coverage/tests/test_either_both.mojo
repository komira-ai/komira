# Runs every line of covandor and takes both arms of its `or`: the right
# operand skipped once and evaluated once (test 46).
from covandor import either
from std.testing import assert_true


def main() raises:
    assert_true(either(True, False), "the left operand decides")
    assert_true(either(False, True), "the right operand decides")
