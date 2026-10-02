from fx_dlopen import fx_dlopen_value
from std.testing import assert_equal


def main() raises:
    assert_equal(fx_dlopen_value(), 6, "the fixture's own value")
    print("test_fx_dlopen: PASS")
