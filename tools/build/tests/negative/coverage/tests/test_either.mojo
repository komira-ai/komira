from branchretor import either
from std.testing import assert_true


def main() raises:
    assert_true(either(False, True), "the right operand decides")
