from kflib import answer
from std.testing import assert_equal


def main() raises:
    assert_equal(answer(), 42, "the library value, read back")
    print("test_passes_too: PASS")
