from std.testing import assert_equal

from unshipped import greet


def main() raises:
    assert_equal(greet("a"), "hello, a")
