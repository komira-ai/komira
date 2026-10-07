from covlib import clamp
from std.testing import assert_equal


def main() raises:
    assert_equal(clamp(5, 0, 10), 5, "inside the range")
    assert_equal(clamp(-1, 0, 10), 0, "below the range")
