from std.testing import assert_equal

from relative_link import greet


def main() raises:
    assert_equal(greet("a"), "hello, a")
