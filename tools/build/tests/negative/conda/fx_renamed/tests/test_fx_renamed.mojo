from fx_renamed import fx_renamed_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_renamed_value(), 3, "the fixture's own value")
    print("test_fx_renamed: PASS")
