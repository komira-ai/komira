from lostlib import twice
from std.testing import assert_equal


def main() raises:
    assert_equal(twice(21), 42, "the library value, read back")
