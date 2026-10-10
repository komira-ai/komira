# Calls clamp(20) and clamp(5): every line of covbranch runs, and the `if`
# is true once and false once, so both branch arms are taken (test 46).
from covbranch import clamp
from std.testing import assert_equal


def main() raises:
    assert_equal(clamp(20), 10, "clamped")
    assert_equal(clamp(5), 5, "kept")
