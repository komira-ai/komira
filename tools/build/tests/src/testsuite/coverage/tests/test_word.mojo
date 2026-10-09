# Calls word(0) only: the arms for a positive and a negative x never run, so
# covnotinfo's line coverage is below 100% (test 46), as covlow's is.
from covnotinfo import word
from std.testing import assert_equal


def main() raises:
    assert_equal(word(0), "zero", "zero")
