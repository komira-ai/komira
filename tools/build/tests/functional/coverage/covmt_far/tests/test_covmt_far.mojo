# The mojo_test in another package: it calls quarter alone (tests 43 and 46).
from covmt import quarter
from std.testing import assert_equal


def main() raises:
    assert_equal(quarter(8), 2)
