from komira_neg_unlisted import komira_neg_unlisted_value
from std.testing import assert_equal


def main() raises:
    assert_equal(komira_neg_unlisted_value(), 5, "the fixture's own value")
    print("test_komira_neg_unlisted: PASS")
