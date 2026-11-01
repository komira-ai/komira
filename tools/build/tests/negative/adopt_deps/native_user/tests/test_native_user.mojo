from std.testing import assert_equal

from native_user import native_user_one


def main() raises:
    assert_equal(native_user_one(), 1)
    print("test_native_user: PASS")
