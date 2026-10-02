from komira_neg_user import komira_neg_user_value
from std.testing import assert_equal


def main() raises:
    assert_equal(komira_neg_user_value(), 4, "the fixture's own value")
    print("test_komira_neg_user: PASS")
