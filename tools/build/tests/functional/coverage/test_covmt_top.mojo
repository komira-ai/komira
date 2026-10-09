# A mojo_test of covmt's package outside its tests/ directory (tests 43 and
# 46): its gate must set it aside (--test-source), not measure it as covmt's.
from covmt import half
from std.testing import assert_equal


def main() raises:
    assert_equal(half(2), 1)
