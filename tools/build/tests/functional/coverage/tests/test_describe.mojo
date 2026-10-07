from covlib import describe
from std.testing import assert_equal


def main() raises:
    assert_equal(describe(0), "zero", "zero")
