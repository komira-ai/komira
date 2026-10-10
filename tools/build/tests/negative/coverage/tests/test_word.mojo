# Calls word(0) only: the arms for a positive and a negative x never run, so
# covlow's line coverage is below 100% (test 46).
from covlow import word
from std.testing import assert_equal


def main() raises:
    assert_equal(word(0), "zero", "zero")
