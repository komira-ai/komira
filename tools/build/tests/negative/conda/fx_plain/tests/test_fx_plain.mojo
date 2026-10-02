from fx_plain import fx_plain_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_plain_value(), 3, "the fixture's own value")
    print("test_fx_plain: PASS")
