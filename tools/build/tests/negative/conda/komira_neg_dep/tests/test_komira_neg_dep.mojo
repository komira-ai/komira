from komira_neg_dep import komira_neg_dep_value
from std.testing import assert_equal


def main() raises:
    assert_equal(komira_neg_dep_value(), 3, "the fixture's own value")
    print("test_komira_neg_dep: PASS")
