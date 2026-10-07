# Calls full(): every line of covfull has a hit, and kcov reports no branch
# (test 46).
from covfull import full
from std.testing import assert_equal


def main() raises:
    assert_equal(full(), "full", "full")
