# A test that ends at once: a hang limit must leave it alone.
from hangfix import answer
from std.testing import assert_equal


def main() raises:
    assert_equal(answer(), 42)
