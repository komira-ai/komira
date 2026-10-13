# Calls full(): every line of covfile has a hit, and kcov reports no branch
# (test 46).
from covfile import full
from std.testing import assert_equal


def main() raises:
    assert_equal(full(), "full", "full")
