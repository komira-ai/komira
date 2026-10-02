from neg_noprefix import neg_noprefix_value
from std.testing import assert_equal


def main() raises:
    assert_equal(neg_noprefix_value(), 2, "the fixture's own value")
    print("test_neg_noprefix: PASS")
