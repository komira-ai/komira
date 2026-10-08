from covuser import bounded
from std.testing import assert_equal


def main() raises:
    assert_equal(bounded(12), 9, "clamped by covlib")
