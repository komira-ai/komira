from komira_neg_dlopen import komira_neg_dlopen_value
from std.testing import assert_equal


def main() raises:
    assert_equal(komira_neg_dlopen_value(), 6, "the fixture's own value")
    print("test_komira_neg_dlopen: PASS")
