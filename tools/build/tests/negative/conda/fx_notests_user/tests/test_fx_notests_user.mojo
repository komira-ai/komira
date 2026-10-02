from fx_notests_user import fx_notests_user_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_notests_user_value(), 4, "the fixture's own value")
    print("test_fx_notests_user: PASS")
