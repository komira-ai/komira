from komira_neg_listed import komira_neg_listed_value
from std.testing import assert_equal


def main() raises:
    assert_equal(komira_neg_listed_value(), 7, "the fixture's own value")
    print("test_komira_neg_listed: PASS")
