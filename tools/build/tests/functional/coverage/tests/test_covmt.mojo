# The mojo_test in covmt's package: it calls half alone (tests 43 and 46).
from covmt import half
from std.testing import assert_equal


def main() raises:
    assert_equal(half(8), 4)
