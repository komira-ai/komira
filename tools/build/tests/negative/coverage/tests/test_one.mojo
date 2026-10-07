from noop import one
from std.testing import assert_equal


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
