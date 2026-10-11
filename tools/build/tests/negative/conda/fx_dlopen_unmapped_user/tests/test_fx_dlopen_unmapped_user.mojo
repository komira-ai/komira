from fx_dlopen_unmapped_user import fx_dlopen_unmapped_user_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_dlopen_unmapped_user_value(), 9, "one more than its dependency")
    print("test_fx_dlopen_unmapped_user: PASS")
