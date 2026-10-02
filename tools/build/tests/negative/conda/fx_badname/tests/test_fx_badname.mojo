from fx_badname import fx_badname_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_badname_value(), 3, "the fixture's own value")
    print("test_fx_badname: PASS")
