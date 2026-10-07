from reprodep import twice
from std.testing import assert_equal


def main() raises:
    assert_equal(twice(21), 42, "the dependency's value, read back")
