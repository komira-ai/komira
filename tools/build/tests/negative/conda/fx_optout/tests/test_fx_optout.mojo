from fx_optout import fx_optout_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_optout_value(), 3, "the fixture's own value")
    print("test_fx_optout: PASS")
