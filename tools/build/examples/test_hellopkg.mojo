from hellopkg import greeting
from std.testing import assert_equal


def main() raises:
    assert_equal(greeting(), "hello from hellopkg")
    print("test_hellopkg: PASS")
